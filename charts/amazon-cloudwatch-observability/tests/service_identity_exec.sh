#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Runs the rendered service identity processors (templates/_service-identity.tpl)
# in a real OpenTelemetry collector and checks what they emit. The render tests
# (vllm_pipeline_shape.sh, otlp_endpoint.sh, otel_ci_filters.sh) check the text
# of the statements; this test checks their behaviour, which a wrong condition
# can change while the text still looks right.
#
# Processors under test, taken from the node agent's otelConfig:
#   transform/cw_k8s_ci_v0_service_identity       Container Insights metrics
#                                                 (receiverDefault: the
#                                                 Prometheus job name and
#                                                 target count as not set)
#   transform/cw_k8s_ci_v0_logs_service_identity  Container Insights application logs
#   transform/cw_k8s_service_identity             the OTLP endpoint
#
# Each processor runs in a minimal config: an otlpjsonfile receiver reading one
# resource per case, the processor, and a file exporter. A second run with the
# processors removed is a control: every case must fail it, so no case can
# pass without the processor. Each input carries a _tmp.service_identity.probe
# attribute that only the processor's cleanup removes, which makes the cases
# that expect their input unchanged (node-level series, a sender's own value)
# fail the control too.
#
# Requires docker and python3 with PyYAML. Renders locally; never connects to a
# cluster.
#
# Run from the repo root:
#     bash charts/amazon-cloudwatch-observability/tests/service_identity_exec.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The agent ships collector and transformprocessor v0.150.0. There is no
# 0.150.0 contrib image on Docker Hub, so this pins its patch release 0.150.1,
# by digest.
IMAGE="otel/opentelemetry-collector-contrib:0.150.1@sha256:a516c26968aa1feb5e5fc0562e3338ea13755cb4f373603226bcc4e276374ad0"
TIMEOUT_SECONDS="${SERVICE_IDENTITY_EXEC_TIMEOUT:-90}"

WORK_DIR="$(mktemp -d)"
CONTAINERS=()
cleanup() {
    for c in "${CONTAINERS[@]}"; do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

python3 - "$CHART_DIR" "$WORK_DIR" <<'PY'
import json, os, re, subprocess, sys
import yaml

CHART, WORK = sys.argv[1], sys.argv[2]

def node_processors(*args):
    out = subprocess.run(
        ["helm", "template", "t", CHART, "--set", "region=us-west-2", "--set", "clusterName=c1",
         "--set", "otelContainerInsights.enabled=true", *args],
        check=True, capture_output=True, text=True).stdout
    for d in yaml.safe_load_all(out):
        if d and d.get("kind") == "AmazonCloudWatchAgent" and d["metadata"]["name"] == "cloudwatch-agent":
            return yaml.safe_load(d["spec"]["otelConfig"])["processors"]
    sys.exit("no cloudwatch-agent otelConfig rendered")

CI_METRICS = "transform/cw_k8s_ci_v0_service_identity"
CI_LOGS = "transform/cw_k8s_ci_v0_logs_service_identity"
OTLP = "transform/cw_k8s_service_identity"

default = node_processors()
app_labels = node_processors("--set", "otelServiceIdentity.useAppLabels=true")

BASE = {"cloud.platform": "aws_eks", "k8s.cluster.name": "c1", "k8s.namespace.name": "shop"}
POD = {"k8s.pod.name": "checkout-7d9f-abcde", "k8s.deployment.name": "checkout"}
CONTAINER = {**POD, "k8s.container.name": "api"}
SCRAPE = {"service.name": "cadvisor", "service.instance.id": "10.0.0.1:10250"}
ENV = "aws_eks:c1/shop"
INSTANCE = "shop.checkout-7d9f-abcde.api"
ANNOTATION = "_tmp.service_identity.annotation.service.name"
ISVC = "k8s.pod.label.serving.kserve.io/inferenceservice"
APP_INSTANCE = "_tmp.service_identity.label.app.kubernetes.io/instance"

def expect(name, namespace="shop", env=ENV, instance=INSTANCE):
    return {"service.name": name, "service.namespace": namespace,
            "deployment.environment.name": env, "service.instance.id": instance}

# Each case: (name, input resource attributes, expected service attributes; None = absent).
CI_METRIC_CASES = [
    ("container series", {**BASE, **SCRAPE, **CONTAINER}, expect("checkout")),
    ("pod-level series", {**BASE, **SCRAPE, **POD}, expect("checkout", instance=None)),
    ("annotation wins", {**BASE, **SCRAPE, **CONTAINER, ANNOTATION: "payments", ISVC: "llama"},
     expect("payments")),
    ("KServe InferenceService", {**BASE, **SCRAPE, **CONTAINER, ISVC: "llama"}, expect("llama")),
    ("node-level series keeps the job name and target",
     {"cloud.platform": "aws_eks", "k8s.cluster.name": "c1",
      "service.name": "node-exporter", "service.instance.id": "10.0.0.1:9100"},
     expect("node-exporter", namespace=None, env=None, instance="10.0.0.1:9100")),
    ("CronJob pod gets the CronJob name",
     {**BASE, **SCRAPE, "k8s.pod.name": "nightly-123-x", "k8s.container.name": "job",
      "k8s.job.name": "nightly-123", "k8s.cronjob.name": "nightly"},
     expect("nightly", instance="shop.nightly-123-x.job")),
    ("unknown_service:java is replaced",
     {**BASE, **CONTAINER, "service.name": "unknown_service:java", "service.instance.id": "10.0.0.1:10250"},
     expect("checkout")),
    ("app labels are opt-in", {**BASE, **SCRAPE, **CONTAINER, APP_INSTANCE: "shop-release"},
     expect("checkout")),
]
APP_LABEL_CASES = [
    ("app label after the annotation", {**BASE, **SCRAPE, **CONTAINER, APP_INSTANCE: "shop-release"},
     expect("shop-release")),
    ("annotation before the app label",
     {**BASE, **SCRAPE, **CONTAINER, APP_INSTANCE: "shop-release", ANNOTATION: "payments"},
     expect("payments")),
    ("InferenceService before the app label",
     {**BASE, **SCRAPE, **CONTAINER, APP_INSTANCE: "shop-release", ISVC: "llama"}, expect("llama")),
]
LOG_CASES = [
    ("container", {**BASE, **CONTAINER}, expect("checkout")),
    ("annotation wins", {**BASE, **CONTAINER, ANNOTATION: "payments", ISVC: "llama"}, expect("payments")),
    ("KServe InferenceService", {**BASE, **CONTAINER, ISVC: "llama"}, expect("llama")),
    ("sender's value kept", {**BASE, **CONTAINER, "service.name": "checkout-api"}, expect("checkout-api")),
    ("unknown_service:java is replaced", {**BASE, **CONTAINER, "service.name": "unknown_service:java"},
     expect("checkout")),
]
OTLP_CASES = [
    ("container", {**BASE, **CONTAINER}, expect("checkout")),
    ("unknown_service:java is replaced", {**BASE, **CONTAINER, "service.name": "unknown_service:java"},
     expect("checkout")),
    ("sender's value kept", {**BASE, **CONTAINER, "service.name": "checkout-api"}, expect("checkout-api")),
]

# (run, signal, processor, cases)
SUITES = [
    ("default", "metrics", default[CI_METRICS], "ci_metrics", CI_METRIC_CASES),
    ("default", "logs", default[CI_LOGS], "ci_logs", LOG_CASES),
    ("default", "metrics", default[OTLP], "otlp", OTLP_CASES),
    ("applabels", "metrics", app_labels[CI_METRICS], "ci_metrics_applabels", APP_LABEL_CASES),
]

def attributes(d):
    return [{"key": k, "value": {"stringValue": v}} for k, v in d.items()]

def payload(signal, suite, cases):
    resources = []
    for i, (_, attrs, _) in enumerate(cases):
        attrs = {**attrs, "_tmp.service_identity.probe": "x", "test.case": f"{suite}/{i}"}
        if signal == "metrics":
            resources.append({"resource": {"attributes": attributes(attrs)}, "scopeMetrics": [{"metrics": [
                {"name": "m", "gauge": {"dataPoints": [{"asDouble": 1, "timeUnixNano": "1"}]}}]}]})
        else:
            resources.append({"resource": {"attributes": attributes(attrs)}, "scopeLogs": [{"logRecords": [
                {"timeUnixNano": "1", "body": {"stringValue": "x"}}]}]})
    key = "resourceMetrics" if signal == "metrics" else "resourceLogs"
    return json.dumps({key: resources})

def write_run(run, control):
    d = os.path.join(WORK, run + ("_control" if control else ""))
    os.makedirs(d)
    cfg = {"receivers": {}, "processors": {}, "exporters": {}, "service": {"pipelines": {},
           "telemetry": {"logs": {"level": "warn"}}}}
    for r, signal, processor, suite, cases in SUITES:
        if r != run:
            continue
        with open(os.path.join(d, f"in_{suite}.json"), "w") as f:
            f.write(payload(signal, suite, cases) + "\n")
        cfg["receivers"][f"otlpjsonfile/{suite}"] = {"include": [f"/data/in_{suite}.json"], "start_at": "beginning"}
        cfg["exporters"][f"file/{suite}"] = {"path": f"/data/out_{suite}.json"}
        pipeline = {"receivers": [f"otlpjsonfile/{suite}"], "exporters": [f"file/{suite}"]}
        if not control:
            cfg["processors"][f"transform/{suite}"] = processor
            pipeline["processors"] = [f"transform/{suite}"]
        cfg["service"]["pipelines"][f"{signal}/{suite}"] = pipeline
    with open(os.path.join(d, "config.yaml"), "w") as f:
        yaml.safe_dump(cfg, f, width=100000)
    with open(os.path.join(d, "expected.json"), "w") as f:
        json.dump({suite: [[name, exp] for name, _, exp in cases]
                   for r, _, _, suite, cases in SUITES if r == run}, f)

for run in ("default", "applabels"):
    write_run(run, control=False)
    write_run(run, control=True)
PY

# Starts the collector on a run directory and waits until every out_*.json holds
# all of that suite's resources.
run_collector() {
    local dir="$1" name="si-exec-$$-$(basename "$1")"
    chmod 0777 "$dir"
    CONTAINERS+=("$name")
    docker run -d --name "$name" --user "$(id -u):$(id -g)" -v "$dir:/data" "$IMAGE" \
        --config /data/config.yaml >/dev/null
    local deadline=$((SECONDS + TIMEOUT_SECONDS))
    until python3 - "$dir" <<'PY'
import json, os, sys
d = sys.argv[1]
want = json.load(open(os.path.join(d, "expected.json")))
for suite, cases in want.items():
    path = os.path.join(d, f"out_{suite}.json")
    if not os.path.exists(path):
        sys.exit(1)
    got = 0
    for line in open(path):
        line = line.strip()
        if line:
            try:
                doc = json.loads(line)
            except ValueError:
                sys.exit(1)
            got += len(doc.get("resourceMetrics", []) + doc.get("resourceLogs", []))
    if got < len(cases):
        sys.exit(1)
PY
    do
        if ! docker ps -q --filter "name=^${name}$" | grep -q .; then
            echo "collector ${name} exited:" >&2
            docker logs "$name" >&2 || true
            return 1
        fi
        if ((SECONDS >= deadline)); then
            echo "timed out after ${TIMEOUT_SECONDS}s waiting for ${dir}/out_*.json" >&2
            docker logs "$name" >&2 || true
            return 1
        fi
        sleep 1
    done
    docker rm -f "$name" >/dev/null
}

for dir in "$WORK_DIR"/*/; do
    run_collector "${dir%/}"
done

python3 - "$WORK_DIR" <<'PY'
import json, os, sys

WORK = sys.argv[1]
GREEN, RED, YELLOW, RESET = "\033[0;32m", "\033[0;31m", "\033[1;33m", "\033[0m"
KEYS = ["service.name", "service.namespace", "deployment.environment.name", "service.instance.id"]

def outputs(d, suite):
    by_case = {}
    for line in open(os.path.join(d, f"out_{suite}.json")):
        if not line.strip():
            continue
        doc = json.loads(line)
        for r in doc.get("resourceMetrics", []) + doc.get("resourceLogs", []):
            attrs = {a["key"]: a["value"].get("stringValue") for a in r["resource"].get("attributes", [])}
            by_case[attrs.get("test.case")] = attrs
    return by_case

def problems(attrs, expected):
    if attrs is None:
        return ["no output resource"]
    found = [f"{k}={attrs.get(k)!r}, want {expected[k]!r}" for k in KEYS if attrs.get(k) != expected[k]]
    found += [f"{k} left over" for k in attrs if k.startswith("_tmp.service_identity.")]
    return found

passed = failed = 0
for run in ("default", "applabels"):
    d = os.path.join(WORK, run)
    control = os.path.join(WORK, run + "_control")
    for suite, cases in json.load(open(os.path.join(d, "expected.json"))).items():
        print(f"\n{YELLOW}[{suite}]{RESET}")
        got, ctl = outputs(d, suite), outputs(control, suite)
        for i, (name, expected) in enumerate(cases):
            case = f"{suite}/{i}"
            bad = problems(got.get(case), expected)
            if not problems(ctl.get(case), expected):
                bad.append("passes with the processor removed")
            if bad:
                failed += 1
                print(f"  {RED}FAIL{RESET}: {name}: " + "; ".join(bad))
            else:
                passed += 1
                print(f"  {GREEN}PASS{RESET}: {name}")

print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {passed + failed} cases failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {passed} cases passed.{RESET}")
PY
