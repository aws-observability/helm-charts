#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Validates the OTLP endpoint (the otlp values) by rendering `helm template`
# and checking the node agent's otelConfig and JSON config: the default-on
# receiver and pipelines, the merge with OTEL Container Insights, the
# precedence over "default:otel", ports, span metrics, the validation
# failures, and that every otelFilters setting renders into the OTLP
# pipelines the same way as into the OTEL Container Insights pipelines. This
# test renders locally and never connects to a cluster.
#
# Requires python3 with PyYAML.
#
# Run from the repo root:
#     bash charts/amazon-cloudwatch-observability/tests/otlp_endpoint.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for readable output.
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
N='\033[0m'

pass_count=0
fail_count=0

RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT

# ──────────────────────────────────────────────────────────────────────────
# check — run python assertions that render the chart themselves.
#
# Arguments:
#   $1  description shown in output
#   $2  python assertions
#
# The assertions run with:
#   render(*args)        renders the chart with the extra helm arguments and
#                        returns a dict per AmazonCloudWatchAgent with cfg (the
#                        parsed otelConfig, or None), text (the otelConfig
#                        text), config (the parsed JSON config) and hash (the
#                        otel-config-sha256 annotation, or None)
#   pipeline(cfg, name)  a pipeline's processor list
#   statements(cfg, processor, group)
#                        the statements of a transform processor's first
#                        statement group, for example "log_statements"
#   AGENT                "cloudwatch-agent", the node agent
#   METRICS, TRACES, LOGS, PROFILES  the OTLP pipeline names
#   ENRICH               the OTLP enrichment processors, in order
# ──────────────────────────────────────────────────────────────────────────
check() {
    local desc="$1" assertions="$2"

    printf "\n${Y}[Case]${N} %s\n" "$desc"

    local result
    if result=$(python3 - "$CHART_DIR" "$assertions" <<'PY' 2>&1
import json, re, subprocess, sys, yaml

CHART = sys.argv[1]
HASH = "cloudwatch-agent/otel-config-sha256"
AGENT = "cloudwatch-agent"
METRICS, TRACES, LOGS = "metrics/cw_k8s_otlp", "traces/cw_k8s_otlp", "logs/cw_k8s_otlp"
PROFILES = "profiles/cw_k8s_otlp"
ENRICH = [
    "k8sattributes/cw_k8s_otlp_pod",
    "k8sattributes/cw_k8s_ci_v0_node",
    "resourcedetection/cw_k8s_ci_v0",
    "transform/cw_k8s_otlp_enrich",
    "transform/cw_k8s_service_identity",
]
PROFILES_ENRICH = ["k8sattributes/cw_k8s_otlp_profiles"] + ENRICH[1:]

def render(*args):
    out = subprocess.run(
        ["helm", "template", CHART, "--set", "region=us-west-2",
         "--set", "clusterName=test-cluster", *args],
        check=True, capture_output=True, text=True).stdout
    agents = {}
    for raw in re.split(r"^---\s*$", out, flags=re.M):
        d = yaml.safe_load(raw)
        if not d or d.get("kind") != "AmazonCloudWatchAgent":
            continue
        text = d["spec"].get("otelConfig")
        agents[d["metadata"]["name"]] = {
            "cfg": yaml.safe_load(text) if text else None,
            "text": text,
            "config": json.loads(d["spec"]["config"]),
            "hash": (d["spec"].get("podAnnotations") or {}).get(HASH),
        }
    return agents

def pipeline(cfg, name):
    return cfg["service"]["pipelines"][name]["processors"]

def statements(cfg, processor, group):
    return cfg["processors"][processor][group][0]["statements"]

exec(sys.argv[2])
PY
    ); then
        echo -e "  ${G}PASS${N}"
        pass_count=$((pass_count + 1))
    else
        echo -e "  ${R}FAIL${N}: $(tail -1 <<< "$result")"
        fail_count=$((fail_count + 1))
    fi
}

# ──────────────────────────────────────────────────────────────────────────
# check_fails — render and expect helm template to fail with a message.
#
# Arguments:
#   $1   description shown in output
#   $2   fragment that MUST be in the error message
#   $3+  extra helm arguments
# ──────────────────────────────────────────────────────────────────────────
check_fails() {
    local desc="$1" message="$2"
    shift 2

    printf "\n${Y}[Case]${N} %s\n" "$desc"

    if helm template "$CHART_DIR" --set region=us-west-2 --set clusterName=test-cluster "$@" >"$RENDERED" 2>&1; then
        echo -e "  ${R}FAIL${N}: expected helm template to fail, but it succeeded"
        fail_count=$((fail_count + 1))
    elif ! grep -qF -- "$message" "$RENDERED"; then
        echo -e "  ${R}FAIL${N}: error does not contain: $message"
        tail -3 "$RENDERED" | sed 's/^/    /'
        fail_count=$((fail_count + 1))
    else
        echo -e "  ${G}PASS${N}"
        pass_count=$((pass_count + 1))
    fi
}

# ──────────────────────────────────────────────────────────────────────────
# Default on.
# ──────────────────────────────────────────────────────────────────────────
check "Default values — the node agent serves OTLP on 0.0.0.0:4317 and 0.0.0.0:4318 with one pipeline per signal" '
a = render()
cfg = a[AGENT]["cfg"]
assert cfg["receivers"]["otlp/cw_k8s_otlp"] == {"protocols": {
    "grpc": {"endpoint": "0.0.0.0:4317"}, "http": {"endpoint": "0.0.0.0:4318", "max_request_body_size": 20971520}}}, cfg["receivers"]
pipelines = cfg["service"]["pipelines"]
assert sorted(pipelines) == [LOGS, METRICS, PROFILES, TRACES], sorted(pipelines)
assert pipelines[PROFILES]["receivers"] == ["otlp/cw_k8s_otlp"]
assert pipelines[PROFILES]["exporters"] == ["otlphttp/cw_k8s_otlp_profiles"]
assert pipelines[METRICS]["receivers"] == ["otlp/cw_k8s_otlp", "spanmetrics/cw_k8s_otlp"], pipelines[METRICS]
assert pipelines[TRACES]["receivers"] == ["otlp/cw_k8s_otlp"]
assert pipelines[LOGS]["receivers"] == ["otlp/cw_k8s_otlp"]
assert pipelines[METRICS]["exporters"] == ["otlphttp/cw_k8s_ci_v0_metrics_dest"]
assert pipelines[TRACES]["exporters"] == ["otlphttp/cw_k8s_otlp_traces", "spanmetrics/cw_k8s_otlp"]
assert pipelines[LOGS]["exporters"] == ["otlphttp/cw_k8s_otlp_logs"]
assert a[AGENT]["hash"], "the node agent has no otel-config-sha256 annotation"
assert "opentelemetry" not in a[AGENT]["config"], a[AGENT]["config"]
'

check "Default values — processor order per signal" '
cfg = render()[AGENT]["cfg"]
labels = ["transform/cw_k8s_otlp_labels"]
assert pipeline(cfg, METRICS) == ENRICH + ["transform/cw_k8s_otlp_scope", "awsattributelimit/cw_k8s_ci_v0", "batch/cw_k8s_otlp_metrics"], pipeline(cfg, METRICS)
assert pipeline(cfg, TRACES) == ENRICH + labels + ["transform/cw_k8s_otlp_scope", "batch/cw_k8s_otlp_traces"], pipeline(cfg, TRACES)
assert pipeline(cfg, LOGS) == ENRICH + labels + ["transform/cw_k8s_otlp_scope", "transform/cw_k8s_otlp_logs_routing",
    "attributestocontext/cw_k8s_otlp_logs", "transform/cw_k8s_otlp_logs_cleanup", "batch/cw_k8s_otlp_logs"], pipeline(cfg, LOGS)
assert pipeline(cfg, PROFILES) == PROFILES_ENRICH + labels + ["transform/cw_k8s_otlp_scope"], pipeline(cfg, PROFILES)
'

check "Default values — exporters, signing and the logs header chain" '
cfg = render()[AGENT]["cfg"]
e = cfg["exporters"]
assert e["otlphttp/cw_k8s_ci_v0_metrics_dest"]["endpoint"] == "https://monitoring.us-west-2.amazonaws.com:443"
assert e["otlphttp/cw_k8s_ci_v0_metrics_dest"]["auth"]["authenticator"] == "sigv4auth/cw_k8s_ci_v0_metrics_dest"
assert e["otlphttp/cw_k8s_otlp_traces"]["endpoint"] == "https://xray.us-west-2.amazonaws.com:443"
assert e["otlphttp/cw_k8s_otlp_traces"]["auth"]["authenticator"] == "sigv4auth/cw_k8s_otlp_traces_dest"
assert e["otlphttp/cw_k8s_otlp_logs"]["endpoint"] == "https://logs.us-west-2.amazonaws.com:443"
assert e["otlphttp/cw_k8s_otlp_logs"]["auth"]["authenticator"] == "headers_setter/cw_k8s_otlp_logs"
x = cfg["extensions"]
assert x["sigv4auth/cw_k8s_otlp_traces_dest"] == {"region": "us-west-2", "service": "xray"}
assert x["sigv4auth/cw_k8s_ci_v0_metrics_dest"] == {"region": "us-west-2", "service": "monitoring"}
assert x["sigv4auth/cw_k8s_otlp_logs_dest"] == {"region": "us-west-2", "service": "logs"}
assert x["headers_setter/cw_k8s_otlp_logs"]["additional_auth"] == "awscloudwatchlogsprovisioner/cw_k8s_otlp_logs"
assert [h["from_context"] for h in x["headers_setter/cw_k8s_otlp_logs"]["headers"]] == ["aws.log.group.name", "aws.log.stream.name"]
assert x["awscloudwatchlogsprovisioner/cw_k8s_otlp_logs"] == {"region": "us-west-2", "additional_auth": "sigv4auth/cw_k8s_otlp_logs_dest"}
# Only the metrics signer is shared with Container Insights; the logs ones are not.
assert [n for n in x if "ci_v0" in n] == ["sigv4auth/cw_k8s_ci_v0_metrics_dest"], sorted(x)
assert sorted(cfg["service"]["extensions"]) == sorted(x), cfg["service"]["extensions"]
assert cfg["service"]["telemetry"] == {"metrics": {"level": "none"}}
assert cfg["processors"]["batch/cw_k8s_otlp_logs"]["metadata_keys"] == ["aws.log.group.name", "aws.log.stream.name"]
'

check "Default values — pod association, metadata and the identity sources" '
cfg = render()[AGENT]["cfg"]
p = cfg["processors"]["k8sattributes/cw_k8s_otlp_pod"]
assert p["filter"] == {"node_from_env_var": "K8S_NODE_NAME"}
assert p["pod_association"] == [
    {"sources": [{"from": "resource_attribute", "name": "k8s.pod.uid"}]},
    {"sources": [{"from": "resource_attribute", "name": "k8s.pod.name"}, {"from": "resource_attribute", "name": "k8s.namespace.name"}]},
    {"sources": [{"from": "connection"}]}], p["pod_association"]
for m in ["k8s.namespace.name", "k8s.pod.name", "k8s.pod.uid", "k8s.pod.start_time", "k8s.container.name", "k8s.node.name",
          "k8s.deployment.name", "k8s.replicaset.name", "k8s.statefulset.name", "k8s.daemonset.name", "k8s.job.name", "k8s.cronjob.name"]:
    assert m in p["extract"]["metadata"], m
assert [x["key"] for x in p["extract"]["annotations"]] == ["resource.opentelemetry.io/" + k for k in ["service.name", "service.namespace", "service.version", "service.instance.id"]]
assert [x for x in p["extract"]["labels"] if x.get("tag_name", "").startswith("_tmp.service_identity.")] == [], "well-known labels are opt-in"
p = render("--set", "otelServiceIdentity.useAppLabels=true")[AGENT]["cfg"]["processors"]["k8sattributes/cw_k8s_otlp_pod"]
assert [x["key"] for x in p["extract"]["labels"] if x.get("tag_name", "").startswith("_tmp.service_identity.")] == ["app.kubernetes.io/" + k for k in ["instance", "name", "version"]]
'

check "Default values — service identity per the OTel Kubernetes convention" '
cfg = render()[AGENT]["cfg"]
r = "resource.attributes"
s = statements(cfg, "transform/cw_k8s_service_identity", "metric_statements")
names = [re.search(r"^set\(resource\.attributes\[\"service\.name\"\], resource\.attributes\[\"([^\"]+)\"\]\)", x).group(1)
         for x in s if x.startswith("set(" + r + "[\"service.name\"]")]
assert names == ["_tmp.service_identity.annotation.service.name",
    "k8s.deployment.name", "k8s.replicaset.name", "k8s.statefulset.name", "k8s.daemonset.name", "k8s.cronjob.name", "k8s.job.name",
    "k8s.pod.name", "k8s.container.name", "_tmp.service_identity.unknown_service"], names
assert s[1] == "delete_key(" + r + ", \"service.name\") where IsMatch(" + r + "[\"service.name\"], \"^unknown_service\")", s[1]
assert all(" where " + r + "[\"service.name\"] == nil and " in x for x in s if x.startswith("set(" + r + "[\"service.name\"]"))
assert any(x.startswith("set(" + r + "[\"service.instance.id\"], Concat([" + r + "[\"k8s.namespace.name\"], " + r + "[\"k8s.pod.name\"], " + r + "[\"k8s.container.name\"]], \".\"))") for x in s)
assert any(x.startswith("set(" + r + "[\"deployment.environment.name\"], Concat([" + r + "[\"cloud.platform\"]") for x in s)
assert s[-1] == "delete_matching_keys(" + r + ", \"^_tmp\\\\.service_identity\\\\.\")", s[-1]
for group in ["log_statements", "trace_statements"]:
    assert statements(cfg, "transform/cw_k8s_service_identity", group) == s, group
'

check "Service identity -- the OTLP processor has no receiver default, with Container Insights off and on" '
r = "resource.attributes"
base = render()[AGENT]["cfg"]["processors"]["transform/cw_k8s_service_identity"]
for args in [(), ("--set", "otelContainerInsights.enabled=true"),
             ("--set", "otelContainerInsights.enabled=true", "--set", "kubeStateMetrics.enabled=true")]:
    p = render(*args)[AGENT]["cfg"]["processors"]["transform/cw_k8s_service_identity"]
    assert p == base, args
s = base["metric_statements"][0]["statements"]
assert s[0] == "set(" + r + "[\"_tmp.service_identity.unknown_service\"], " + r + "[\"service.name\"]) where IsMatch(" + r + "[\"service.name\"], \"^unknown_service\")", s[0]
assert not any("receiver.service.instance.id" in x for x in s)
ids = [x for x in s if x.startswith("set(" + r + "[\"service.instance.id\"]") or x.startswith("delete_key(" + r + ", \"service.instance.id\"")]
assert len(ids) == 2 and "annotation.service.instance.id" in ids[0] and "Concat(" in ids[1], ids
'

check "Default values — Container Insights enrichment: cluster, topology, cloud.resource_id and k8s.workload overwrite" '
cfg = render()[AGENT]["cfg"]
r = "resource.attributes"
s = statements(cfg, "transform/cw_k8s_otlp_enrich", "metric_statements")
assert s[0] == "set(" + r + "[\"k8s.cluster.name\"], \"test-cluster\")", s[0]
rid = [x for x in s if x.startswith("set(" + r + "[\"cloud.resource_id\"]")]
assert len(rid) == 1 and "arn:aws:eks:" in rid[0] and "cloud.resource_id\"] == nil" not in rid[0], rid
assert "set(" + r + "[\"k8s.workload.name\"], " + r + "[\"k8s.deployment.name\"]) where " + r + "[\"k8s.deployment.name\"] != nil" in s
assert "set(" + r + "[\"k8s.workload.type\"], \"Deployment\") where " + r + "[\"k8s.deployment.name\"] != nil" in s
assert any(x.startswith("set(" + r + "[\"cloud.availability_zone\"], " + r + "[\"k8s.pod.label.topology.kubernetes.io/zone\"])") for x in s)
'

check "otelServiceIdentity.useAppLabels — app.kubernetes.io labels for service.name and service.version, after the annotation" '
r = "resource.attributes"
def sources(cfg, attr):
    return [re.search(r"^set\(resource\.attributes\[\"[^\"]+\"\], resource\.attributes\[\"([^\"]+)\"\]\)", x).group(1)
            for x in statements(cfg, "transform/cw_k8s_service_identity", "metric_statements")
            if x.startswith("set(" + r + "[\"" + attr + "\"], " + r + "[")]
off = render()[AGENT]["cfg"]
on = render("--set", "otelServiceIdentity.useAppLabels=true")[AGENT]["cfg"]
assert sources(on, "service.name")[:4] == ["_tmp.service_identity.annotation.service.name", "_tmp.service_identity.label.app.kubernetes.io/instance",
    "_tmp.service_identity.label.app.kubernetes.io/name", "k8s.deployment.name"], sources(on, "service.name")
assert sources(on, "service.version") == ["_tmp.service_identity.annotation.service.version", "_tmp.service_identity.label.app.kubernetes.io/version"]
assert sources(off, "service.version") == ["_tmp.service_identity.annotation.service.version"], sources(off, "service.version")
assert not any("app.kubernetes.io" in x for x in statements(off, "transform/cw_k8s_service_identity", "metric_statements"))
assert sources(off, "service.namespace") == sources(on, "service.namespace") == ["_tmp.service_identity.annotation.service.namespace", "k8s.namespace.name"]
'

check "Default values — scope tags, logs routing to /aws/cwagent/<cluster>/<aws.log.source>, span metrics settings" '
cfg = render()[AGENT]["cfg"]
for group in ["metric_statements", "log_statements", "trace_statements"]:
    g = cfg["processors"]["transform/cw_k8s_otlp_scope"][group][0]
    assert g["context"] == "scope" and g["statements"] == [
        "set(scope.attributes[\"cloudwatch.source\"], \"cloudwatch-agent\")",
        "set(scope.attributes[\"cloudwatch.solution\"], \"otel-otlp\")"], g
s = statements(cfg, "transform/cw_k8s_otlp_logs_routing", "log_statements")
assert s[0] == "set(resource.attributes[\"aws.log.source\"], \"otlp\") where resource.attributes[\"aws.log.source\"] == nil", s[0]
assert "Concat([\"/aws/cwagent\", resource.attributes[\"k8s.cluster.name\"], resource.attributes[\"aws.log.source\"]], \"/\")" in s[1], s[1]
c = cfg["connectors"]["spanmetrics/cw_k8s_otlp"]
assert c["add_resource_attributes"] is True and c["namespace"] == "traces.span.metrics"
assert c["metrics_flush_interval"] == "30s" and c["metrics_expiration"] == "5m", c
assert [d["name"] for d in c["dimensions"]] == ["http.response.status_code", "http.request.method", "http.route",
    "http.status_code", "http.method", "rpc.grpc.status_code", "rpc.response.status_code", "error.type"]
'

check "Default values — only the node agent gets the endpoint, not the Windows agents" '
a = render()
assert sorted(a) == ["cloudwatch-agent", "cloudwatch-agent-windows", "cloudwatch-agent-windows-container-insights"], sorted(a)
for name in ["cloudwatch-agent-windows", "cloudwatch-agent-windows-container-insights"]:
    assert a[name]["cfg"] is None, name
'

check "Container Insights steps that change data are not applied to OTLP telemetry" '
cfg = render("--set", "otelContainerInsights.enabled=true")[AGENT]["cfg"]
for p in [METRICS, TRACES, LOGS, PROFILES]:
    for step in pipeline(cfg, p):
        for banned in ["drop_deprecated_semconv", "clear_schema_url", "metricstarttime", "set_unit", "cadvisor", "dcgm", "neuron"]:
            assert banned not in step, (p, step)
'

# ──────────────────────────────────────────────────────────────────────────
# With OTEL Container Insights.
# ──────────────────────────────────────────────────────────────────────────
check "OTEL Container Insights on — its config is unchanged and the OTLP pipelines are merged in" '
for logs in ["true", "false"]:
    args = ["--set", "otelContainerInsights.enabled=true", "--set", "otelContainerInsights.logs.enabled=" + logs]
    on, off = render(*args), render("--set", "otlp.enabled=false", *args)
    merged, ci = on[AGENT]["cfg"], off[AGENT]["cfg"]
    for section in ["extensions", "receivers", "processors", "exporters"]:
        for name, value in ci[section].items():
            assert merged[section][name] == value, (logs, section, name)
    for name, value in ci["service"]["pipelines"].items():
        assert merged["service"]["pipelines"][name] == value, (logs, name)
    assert sorted(set(merged["service"]["pipelines"]) - set(ci["service"]["pipelines"])) == [LOGS, METRICS, PROFILES, TRACES]
    exts = merged["service"]["extensions"]
    assert len(exts) == len(set(exts)) and set(ci["service"]["extensions"]) <= set(exts), exts
    assert merged["service"]["telemetry"] == ci["service"]["telemetry"]
    assert on["cloudwatch-agent-cluster-scraper"] == off["cloudwatch-agent-cluster-scraper"], logs
'

check "OTEL Container Insights logs off — no Container Insights logs component appears for the OTLP logs" '
cfg = render("--set", "otelContainerInsights.enabled=true", "--set", "otelContainerInsights.logs.enabled=false",
             "--set-json", "otelFilters={\"namespaces\":{\"exclude\":[\"kube-system\"]}}")[AGENT]["text"]
for fragment in ["sigv4auth/cw_k8s_ci_v0_logs_dest", "awscloudwatchlogsprovisioner/cw_k8s_ci_v0_logs",
                 "filter/cw_k8s_ci_v0_logs_namespaces", "transform/cw_k8s_ci_v0_logs_labels", "logs/cw_k8s_ci_v0_"]:
    assert fragment not in cfg, fragment
'

check "OTEL Container Insights on — the OTLP pipelines are the same as without it" '
alone = render()[AGENT]["cfg"]
merged = render("--set", "otelContainerInsights.enabled=true")[AGENT]["cfg"]
for p in [METRICS, TRACES, LOGS, PROFILES]:
    assert merged["service"]["pipelines"][p] == alone["service"]["pipelines"][p], p
    for step in alone["service"]["pipelines"][p]["processors"]:
        assert merged["processors"][step] == alone["processors"][step], step
'

# ──────────────────────────────────────────────────────────────────────────
# otlp.enabled=false and default:otel.
# ──────────────────────────────────────────────────────────────────────────
check "otlp.enabled=false — no otelConfig and no hash on the node agent" '
a = render("--set", "otlp.enabled=false")
assert a[AGENT]["cfg"] is None and a[AGENT]["hash"] is None, a[AGENT]["text"]
'

check "otlp.enabled=false with OTEL Container Insights — no OTLP receiver or pipeline" '
cfg = render("--set", "otlp.enabled=false", "--set", "otelContainerInsights.enabled=true")[AGENT]["cfg"]
assert not [r for r in cfg["receivers"] if r.startswith("otlp")], cfg["receivers"]
assert not [p for p in cfg["service"]["pipelines"] if "otlp" in p], cfg["service"]["pipelines"]
'

DEFAULT_OTEL='[{"name":"cloudwatch-agent","config":"default:otel"},{"name":"cloudwatch-agent-cluster-scraper","mode":"deployment","config":"default"}]'
check "default:otel renders the same as default, with otlp on and off, and writes no opentelemetry.collect.otlp" "
for extra in [[], ['--set', 'otlp.enabled=false'], ['--set', 'otelContainerInsights.enabled=true']]:
    alias = render('--set-json', 'agents=$DEFAULT_OTEL', *extra)
    plain = render(*extra)
    for name in plain:
        assert alias[name]['config'] == plain[name]['config'], (extra, name)
        assert alias[name]['text'] == plain[name]['text'], (extra, name)
    assert 'opentelemetry' not in alias[AGENT]['config'], alias[AGENT]['config']
"

check "A custom agent JSON with opentelemetry.collect.otlp renders when otlp.enabled=false" '
render("--set", "otlp.enabled=false", "--set-json", "agents=[{\"name\":\"cloudwatch-agent\",\"config\":{\"opentelemetry\":{\"collect\":{\"otlp\":{}}}}}]")
'

# ──────────────────────────────────────────────────────────────────────────
# Ports and protocols.
# ──────────────────────────────────────────────────────────────────────────
check "Custom ports" '
a = render("--set", "otlp.grpc.port=14317", "--set", "otlp.http.port=14318")
assert a[AGENT]["cfg"]["receivers"]["otlp/cw_k8s_otlp"]["protocols"] == {
    "grpc": {"endpoint": "0.0.0.0:14317"}, "http": {"endpoint": "0.0.0.0:14318", "max_request_body_size": 20971520}}
assert a[AGENT]["hash"] != render()[AGENT]["hash"], "a port change must change the otel-config-sha256 annotation"
'

check "HTTP only" '
cfg = render("--set", "otlp.grpc.enabled=false")[AGENT]["cfg"]
assert cfg["receivers"]["otlp/cw_k8s_otlp"]["protocols"] == {"http": {"endpoint": "0.0.0.0:4318", "max_request_body_size": 20971520}}
'

check "gRPC only" '
cfg = render("--set", "otlp.http.enabled=false")[AGENT]["cfg"]
assert cfg["receivers"]["otlp/cw_k8s_otlp"]["protocols"] == {"grpc": {"endpoint": "0.0.0.0:4317"}}
'

check "A disabled protocol may use any valid port, even a reserved one" '
cfg = render("--set", "otlp.grpc.enabled=false", "--set", "otlp.grpc.port=4318")[AGENT]["cfg"]
assert cfg["receivers"]["otlp/cw_k8s_otlp"]["protocols"] == {"http": {"endpoint": "0.0.0.0:4318", "max_request_body_size": 20971520}}
'

# ──────────────────────────────────────────────────────────────────────────
# Span metrics.
# ──────────────────────────────────────────────────────────────────────────
check "Span metrics off — no connector" '
cfg = render("--set", "otlp.spanMetrics.enabled=false")[AGENT]["cfg"]
assert "connectors" not in cfg, cfg.get("connectors")
assert cfg["service"]["pipelines"][METRICS]["receivers"] == ["otlp/cw_k8s_otlp"]
assert cfg["service"]["pipelines"][TRACES]["exporters"] == ["otlphttp/cw_k8s_otlp_traces"]
'

check "Span metrics on with OTEL Container Insights — the connector survives the merge" '
cfg = render("--set", "otelContainerInsights.enabled=true")[AGENT]["cfg"]
assert "spanmetrics/cw_k8s_otlp" in cfg["connectors"]
assert "spanmetrics/cw_k8s_otlp" in cfg["service"]["pipelines"][METRICS]["receivers"]
'

# ──────────────────────────────────────────────────────────────────────────
# Platforms and endpoints.
# ──────────────────────────────────────────────────────────────────────────
ROLE='arn:aws:iam::123456789012:role/test'
check "AKS and GKE — resource detection as in Container Insights, cloud.resource_id per platform" "
for mode, marker in [('AKS', '/providers/Microsoft.ContainerService/managedClusters/'), ('GKE', '//container.googleapis.com/projects/')]:
    args = ['--set', 'k8sMode=' + mode, '--set', 'roleArn=$ROLE']
    otlp = render(*args)[AGENT]['cfg']
    ci = render('--set', 'otlp.enabled=false', '--set', 'otelContainerInsights.enabled=true', *args)[AGENT]['cfg']
    assert otlp['processors']['resourcedetection/cw_k8s_ci_v0'] == ci['processors']['resourcedetection/cw_k8s_ci_v0'], mode
    s = statements(otlp, 'transform/cw_k8s_otlp_enrich', 'metric_statements')
    assert any(marker in x for x in s), (mode, s)
    assert not any('arn:aws:eks:' in x for x in s), mode
"

check "cloud.resource_id is built before the pod zone replaces the detected zone, as in Container Insights" "
for mode in ['EKS', 'AKS', 'GKE']:
    args = ['--set', 'k8sMode=' + mode, '--set', 'roleArn=$ROLE'] if mode != 'EKS' else []
    s = statements(render(*args)[AGENT]['cfg'], 'transform/cw_k8s_otlp_enrich', 'metric_statements')
    rid = [i for i, x in enumerate(s) if x.split(',')[0] == 'set(resource.attributes[\"cloud.resource_id\"]']
    zone = [i for i, x in enumerate(s) if x.split(',')[0] == 'set(resource.attributes[\"cloud.availability_zone\"]']
    assert rid and len(zone) == 1 and max(rid) < zone[0], (mode, rid, zone)
"

check "Endpoint overrides and adcEndpointOverrides" '
cfg = render("--set", "otelContainerInsights.cloudwatchMetricsEndpoint=https://metrics.example.com",
             "--set", "otelContainerInsights.cloudwatchLogsEndpoint=https://logs.example.com")[AGENT]["cfg"]
assert cfg["exporters"]["otlphttp/cw_k8s_ci_v0_metrics_dest"]["endpoint"] == "https://metrics.example.com"
assert cfg["exporters"]["otlphttp/cw_k8s_otlp_logs"]["endpoint"] == "https://logs.example.com"
cfg = render("--set", "region=us-isof-south-1", "--set-json", "adcEndpointOverrides={\"us-isof-south-1\":\"csp.hci.ic.gov\"}")[AGENT]["cfg"]
assert cfg["exporters"]["otlphttp/cw_k8s_otlp_logs"]["endpoint"] == "https://logs.us-isof-south-1.csp.hci.ic.gov:443"
assert cfg["exporters"]["otlphttp/cw_k8s_otlp_traces"]["endpoint"] == "https://xray.us-isof-south-1.csp.hci.ic.gov:443"
'

# ──────────────────────────────────────────────────────────────────────────
# otelFilters render into the OTLP pipelines as into Container Insights.
# ──────────────────────────────────────────────────────────────────────────
FILTERS=(
    '{}'
    '{"namespaces":{"exclude":["kube-*"]}}'
    '{"namespaces":{"include":["team-*","default"],"exclude":["team-test"]}}'
    '{"metricNames":{"include":["http.server.*","up"]}}'
    '{"metricNames":{"exclude":["go_*","traces.span.metrics.calls"]}}'
    '{"podLabels":{"exclude":["*"]},"nodeLabels":{"exclude":["*"]}}'
    '{"podLabels":{"include":["app","team*"]},"nodeLabels":{"include":["topology.kubernetes.io/zone"]}}'
    '{"podLabels":{"include":["*","pod-template-hash"],"exclude":["secret*"]},"nodeLabels":{"include":["*","feature.node.kubernetes.io/cpu-model.id"],"recommendedExclusions":false}}'
)
for filters in "${FILTERS[@]}"; do
    check "otelFilters $filters — the same label, namespace and metric name processors as Container Insights" "
f = ['--set-json', 'otelFilters=' + '''$filters''']
alone = render(*f)[AGENT]['cfg']
merged = render('--set', 'otelContainerInsights.enabled=true', *f)[AGENT]['cfg']
ci = render('--set', 'otlp.enabled=false', '--set', 'otelContainerInsights.enabled=true', *f)[AGENT]['cfg']
for cfg in [alone, merged]:
    pod = cfg['processors']['k8sattributes/cw_k8s_otlp_pod']['extract']['labels']
    assert [l for l in pod if not l['tag_name'].startswith('_tmp.service_identity.')] == ci['processors']['k8sattributes/cw_k8s_ci_v0_pod']['extract']['labels']
    for shared in ['k8sattributes/cw_k8s_ci_v0_node', 'awsattributelimit/cw_k8s_ci_v0']:
        assert cfg['processors'][shared] == ci['processors'][shared], shared
    m = pipeline(cfg, METRICS)
    for name in ['transform/cw_k8s_ci_v0_metrics_labels', 'filter/cw_k8s_ci_v0_metric_names']:
        assert (name in m) == (name in ci['processors']), (name, m)
        if name in m:
            assert cfg['processors'][name] == ci['processors'][name], name
    if 'filter/cw_k8s_ci_v0_metric_names' in m:
        assert m[-2:] == ['filter/cw_k8s_ci_v0_metric_names', 'batch/cw_k8s_otlp_metrics'], m
    assert m.index('awsattributelimit/cw_k8s_ci_v0') > m.index('transform/cw_k8s_service_identity')
    ns = ci['processors'].get('filter/cw_k8s_ci_v0_logs_namespaces')
    assert (ns is None) == ('filter/cw_k8s_ci_v0_metrics_namespaces' not in ci['processors'])
    for p, name, key in [(METRICS, 'filter/cw_k8s_otlp_metrics_namespaces', 'datapoint'), (LOGS, 'filter/cw_k8s_otlp_logs_namespaces', 'log_record'), (TRACES, 'filter/cw_k8s_otlp_traces_namespaces', 'span'), (PROFILES, 'filter/cw_k8s_otlp_profiles_namespaces', 'profile')]:
        steps = pipeline(cfg, p)
        assert (name in steps) == (ns is not None), (p, steps)
        if ns is not None:
            assert list(cfg['processors'][name]) == ['error_mode', p.split('/')[0]], cfg['processors'][name]
            assert cfg['processors'][name][p.split('/')[0]][key] == ns['logs']['log_record'], name
            assert steps.index(name) > steps.index('transform/cw_k8s_service_identity'), steps
    labels = ci['processors'].get('transform/cw_k8s_ci_v0_logs_labels')
    for p in [LOGS, TRACES, PROFILES]:
        assert ('transform/cw_k8s_otlp_labels' in pipeline(cfg, p)) == (labels is not None), p
    if labels is not None:
        want = labels['log_statements'][0]['statements']
        for group in ['log_statements', 'trace_statements', 'profile_statements']:
            assert statements(cfg, 'transform/cw_k8s_otlp_labels', group) == want, group
"
done

# ──────────────────────────────────────────────────────────────────────────
# Validation failures.
# ──────────────────────────────────────────────────────────────────────────
check_fails "otlp.enabled — not a boolean" "otlp.enabled must be a boolean (true/false)" --set-string otlp.enabled=true
check_fails "otlp.grpc.enabled — not a boolean" "otlp.grpc.enabled must be a boolean (true/false)" --set-string otlp.grpc.enabled=false
check_fails "otlp.http.enabled — not a boolean" "otlp.http.enabled must be a boolean (true/false)" --set-string otlp.http.enabled=yes
check_fails "otelServiceIdentity.useAppLabels — not a boolean" "otelServiceIdentity.useAppLabels must be a boolean (true/false)" --set-string otelServiceIdentity.useAppLabels=on
check_fails "otelServiceIdentity — unknown key" 'otelServiceIdentity has an unknown key "labels"' --set-json 'otelServiceIdentity.labels=[]'
check_fails "otelServiceIdentity — not a map" "otelServiceIdentity must be a map with useAppLabels" --set otelServiceIdentity=on
check_fails "otlp.wellKnownLabels — removed, replaced by otelServiceIdentity.useAppLabels" 'otlp has an unknown key "wellKnownLabels"' --set otlp.wellKnownLabels.enabled=true
check_fails "otlp.spanMetrics.enabled — not a boolean" "otlp.spanMetrics.enabled must be a boolean (true/false)" --set-string otlp.spanMetrics.enabled=on
check_fails "otlp — not a map" "otlp must be a map" --set otlp=on
check_fails "otlp — unknown key" 'otlp has an unknown key "tls"' --set otlp.tls.enabled=true
check_fails "otlp.grpc — unknown key" 'otlp.grpc has an unknown key "endpoint"' --set otlp.grpc.endpoint=0.0.0.0:4317
check_fails "otlp.spanMetrics — unknown key" 'otlp.spanMetrics has an unknown key "dimensions"' --set-json 'otlp.spanMetrics.dimensions=[]'
check_fails "Both protocols disabled" "otlp.grpc.enabled and otlp.http.enabled are both false" \
    --set otlp.grpc.enabled=false --set otlp.http.enabled=false
for port in 0 65536 -1; do
    check_fails "otlp.grpc.port $port — out of range" "otlp.grpc.port must be an integer from 1 to 65535" --set "otlp.grpc.port=$port"
done
check_fails "otlp.http.port — a string" "otlp.http.port must be an integer from 1 to 65535" --set-string otlp.http.port=4318
check_fails "otlp.http.port — a fraction" "otlp.http.port must be an integer from 1 to 65535" --set-json otlp.http.port=4318.5
check_fails "Equal ports" "otlp.grpc.port and otlp.http.port must differ, both are 4318" --set otlp.grpc.port=4318
for port in 2000 4311 4314 4315 4316 8125 25826 25888; do
    check_fails "otlp.http.port $port — already used by the agent" "otlp.http.port $port is already used by the CloudWatch agent" --set "otlp.http.port=$port"
done
# The chart does not check customer receivers for port conflicts with the
# endpoint: avoiding them is the customer's job. A custom agent JSON or
# otelConfig may open its own OTLP receivers next to the chart's endpoint.
check "A custom agent JSON with opentelemetry.collect.otlp renders, and keeps both the custom block and the chart's endpoint" '
for value in ("agent={\"config\":{\"opentelemetry\":{\"collect\":{\"otlp\":{\"grpc_endpoint\":\"0.0.0.0:4317\"}}}}}",
              "agents=[{\"name\":\"cloudwatch-agent\",\"config\":{\"opentelemetry\":{\"collect\":{\"otlp\":{\"grpc_endpoint\":\"0.0.0.0:14317\"}}}}}]"):
    a = render("--set-json", value)
    assert "otlp" in a[AGENT]["config"]["opentelemetry"]["collect"], a[AGENT]["config"]
    assert "otlp/cw_k8s_otlp" in a[AGENT]["cfg"]["receivers"], a[AGENT]["text"]
'
check "A user otelConfig OTLP receiver renders next to the chart's endpoint, on any port" '
for port in (4317, 14317):
    a = render("--set-json", "agents=[{\"name\":\"cloudwatch-agent\",\"otelConfig\":{\"receivers\":{\"otlp/mine\":{\"protocols\":{\"grpc\":{\"endpoint\":\"0.0.0.0:%d\"}}}}}}]" % port)
    assert {"otlp/mine", "otlp/cw_k8s_otlp"} <= set(a[AGENT]["cfg"]["receivers"]), a[AGENT]["text"]
'

# Profiles, as the agent's profiles pipeline (translator_profiles.go).
check "Profiles — the export, the pod association by container.id, and the same enrichment as the other signals" '
cfg = render()[AGENT]["cfg"]
e = cfg["exporters"]["otlphttp/cw_k8s_otlp_profiles"]
assert e == {"profiles_endpoint": "https://monitoring.us-west-2.amazonaws.com/v1development/profiles",
             "tls": {"insecure": False}, "auth": {"authenticator": "sigv4auth/cw_k8s_ci_v0_metrics_dest"},
             "sending_queue": {"queue_size": 100}}, e
k = cfg["processors"]["k8sattributes/cw_k8s_otlp_profiles"]
assert k["pod_association"] == [{"sources": [{"from": "resource_attribute", "name": "container.id"}]},
                                {"sources": [{"from": "connection"}]}], k["pod_association"]
pod = cfg["processors"]["k8sattributes/cw_k8s_otlp_pod"]
assert k["extract"] == pod["extract"] and k["filter"] == pod["filter"], k
for proc in ["transform/cw_k8s_otlp_enrich", "transform/cw_k8s_service_identity", "transform/cw_k8s_otlp_scope"]:
    assert cfg["processors"][proc]["profile_statements"] == cfg["processors"][proc]["trace_statements"], proc
o = render("--set", "otelContainerInsights.cloudwatchMetricsEndpoint=https://metrics.example.com:443")[AGENT]["cfg"]
assert o["exporters"]["otlphttp/cw_k8s_otlp_profiles"]["profiles_endpoint"] == "https://metrics.example.com/v1development/profiles", o["exporters"]["otlphttp/cw_k8s_otlp_profiles"]
assert PROFILES not in (render("--set", "otlp.enabled=false", "--set", "otelContainerInsights.enabled=true")[AGENT]["cfg"]["service"]["pipelines"])
'

# ──────────────────────────────────────────────────────────────────────────
# Helpers for in-cluster senders the chart configures (otlp.httpEndpointURL,
# otlp.httpMaxRequestBodyBytes). Rendered through a probe template in a copy of
# the chart, because no template in the chart prints them.
# ──────────────────────────────────────────────────────────────────────────
PROBE_CHART="$(mktemp -d)"
cp -r "$CHART_DIR" "$PROBE_CHART/chart"
cat > "$PROBE_CHART/chart/templates/zz-otlp-probe.yaml" <<'EOT'
# url={{ include "otlp.httpEndpointURL" . }}
# max={{ include "otlp.httpMaxRequestBodyBytes" . }}
EOT
probe() {
    helm template t "$PROBE_CHART/chart" -n amazon-cloudwatch --set region=us-west-2 --set clusterName=test-cluster "$@" \
        --show-only templates/zz-otlp-probe.yaml 2>&1 | sed -n 's/^# \(url=\|max=\)/\1/p' | tr '\n' ' '
}
probe_case() {
    local desc="$1" want="$2"
    shift 2
    printf "\n${Y}[Case]${N} %s\n" "$desc"
    local got
    got="$(probe "$@")"
    if [[ "$got" == "$want" ]]; then
        echo -e "  ${G}PASS${N}"; pass_count=$((pass_count + 1))
    else
        echo -e "  ${R}FAIL${N}: got '$got', want '$want'"; fail_count=$((fail_count + 1))
    fi
}
probe_case "otlp.httpEndpointURL — defaults" "url=http://cloudwatch-agent.amazon-cloudwatch:4318 max=20971520 "
probe_case "otlp.httpEndpointURL — custom HTTP port" "url=http://cloudwatch-agent.amazon-cloudwatch:14318 max=20971520 " --set otlp.http.port=14318
probe_case "otlp.httpEndpointURL — empty with otlp.enabled=false" "url= max=20971520 " --set otlp.enabled=false
probe_case "otlp.httpEndpointURL — empty with otlp.http.enabled=false" "url= max=20971520 " --set otlp.http.enabled=false
probe_case "otlp.httpEndpointURL — empty when no agents entry renders as the node agent" "url= max=20971520 " --set agent.name=other
probe_case "otlp.httpEndpointURL — renamed node agent with a matching agents entry" "url=http://other.amazon-cloudwatch:4318 max=20971520 " \
    --set agent.name=other --set-json 'agents=[{"name":"other"}]'
rm -rf "$PROBE_CHART"

check "The HTTP receiver sets max_request_body_size from otlp.httpMaxRequestBodyBytes" '
cfg = render()[AGENT]["cfg"]
assert cfg["receivers"]["otlp/cw_k8s_otlp"]["protocols"]["http"]["max_request_body_size"] == 20971520
'

# ──────────────────────────────────────────────────────────────────────────
# Summary.
# ──────────────────────────────────────────────────────────────────────────
total=$((pass_count + fail_count))
echo ""
echo "=== Summary ==="
if [[ $fail_count -eq 0 ]]; then
    echo -e "${G}All $total cases passed.${N}"
    exit 0
else
    echo -e "${R}$fail_count of $total cases failed.${N}"
    exit 1
fi
