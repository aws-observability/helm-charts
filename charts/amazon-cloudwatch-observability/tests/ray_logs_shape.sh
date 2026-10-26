#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins the shape of the Ray logs branch of the OTEL Container Insights pipeline
# (otelContainerInsights.solutions.ray.logs).
#
# Ray writes its logs to files under /tmp/ray in the pod, not to stdout. The node
# agent reads them from the pod's emptyDir through its read-only /rootfs mount.
# What this script guards:
#
#   1. Discovery is node-scoped and label-scoped: one pod watch on this node, and
#      a receiver_creator rule on the ray.io/is-ray-node=yes label that KubeRay
#      writes. No customer annotation is read.
#   2. The paths stay inside the pod's emptyDir volumes, read only Ray session
#      directories (not the session_latest symlink), and leave out the verbose
#      Python core logs, dashboard logs and event files.
#   3. The Serve copy in worker stderr and Ray's colored copies of other workers'
#      lines are dropped, by filters that match those formats and not Ray core's,
#      vLLM's or a plain print. Tracebacks join their record. The raylet and GCS
#      stats dumps are dropped.
#   4. The pipeline sends to the application log group, with the ray-logs scope,
#      and service.name never comes from app.kubernetes.io/name.
#   5. Ray timestamps (no time zone) are not parsed; file checkpoints follow
#      otelContainerInsights.stateStorage.enabled.
#   6. Off when solutions.ray.logs.enabled or otelContainerInsights.logs.enabled
#      is false.
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text. The
# regular expressions are checked with Python's re on sample Ray lines; the
# patterns use only syntax that Go's RE2 reads the same way.
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/ray_logs_shape.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

render() {
    local out="$1"
    shift
    "$HELM" template "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        --set otelContainerInsights.enabled=true \
        "$@" > "$out"
}

render "${TMP_DIR}/default.yaml"
render "${TMP_DIR}/checkpoints.yaml" --set otelContainerInsights.stateStorage.enabled=true
render "${TMP_DIR}/ray-logs-off.yaml" --set otelContainerInsights.solutions.ray.logs.enabled=false
render "${TMP_DIR}/logs-off.yaml" --set otelContainerInsights.logs.enabled=false

python3 - "${TMP_DIR}" <<'PY'
import os
import re
import sys

import yaml

OBSERVER = "k8s_observer/cw_k8s_ci_v0_ray"
CREATOR = "receiver_creator/cw_k8s_ci_v0_ray_logs"
PIPELINE = "logs/cw_k8s_ci_v0_ray"
PARSE = "transform/cw_k8s_ci_v0_ray_logs_parse"
SERVICE_NAME = "transform/cw_k8s_ci_v0_ray_logs_service_name"
SCOPE = "transform/cw_k8s_ci_v0_logs_set_scope_ray"
EXPORTER = "otlphttp/cw_k8s_ci_v0_app_logs_dest"
RULE = 'type == "pod" && labels["ray.io/is-ray-node"] == "yes"'
VOLUMES = "/rootfs/var/lib/kubelet/pods/`uid`/volumes/kubernetes.io~empty-dir/*/session_[0-9]*/logs/"

GREEN, RED, YELLOW, RESET = "\033[0;32m", "\033[0;31m", "\033[1;33m", "\033[0m"
passed = failed = 0


def check(desc, ok):
    global passed, failed
    if ok:
        print(f"  {GREEN}PASS{RESET}: {desc}")
        passed += 1
    else:
        print(f"  {RED}FAIL{RESET}: {desc}")
        failed += 1
    return ok


def otel_config(name, agent="cloudwatch-agent"):
    """otelConfig of the named AmazonCloudWatchAgent CR, parsed."""
    with open(os.path.join(sys.argv[1], name)) as f:
        for doc in yaml.safe_load_all(f):
            if (doc or {}).get("kind") == "AmazonCloudWatchAgent" and \
                    doc["metadata"]["name"] == agent:
                return yaml.safe_load(doc["spec"].get("otelConfig") or "{}") or {}
    return {}


def statements(processor, key):
    return [st for g in (processor or {}).get(key) or [] for st in g.get("statements") or []]


def ops(receiver, kind):
    return [o for o in receiver["config"].get("operators") or [] if o.get("type") == kind]


def expr_regexes(expr):
    """The regular expressions of an expr `matches` expression, unescaped once."""
    return [m.encode().decode("unicode_escape") for m in re.findall(r'matches "((?:[^"\\]|\\.)*)"', expr)]


def matches_any(expr, line):
    return any(re.search(rx, line) for rx in expr_regexes(expr))


# --- default: solutions.ray.logs.enabled=true ---------------------------------------
print(f"\n{YELLOW}[default]{RESET}")
cfg = otel_config("default.yaml")
ext = cfg.get("extensions") or {}
creator = (cfg.get("receivers") or {}).get(CREATOR) or {}
receivers = creator.get("receivers") or {}
processors = cfg.get("processors") or {}
service = cfg.get("service") or {}
pipe = (service.get("pipelines") or {}).get(PIPELINE) or {}
chain = pipe.get("processors") or []

check("cloudwatch-agent CR renders an otelConfig", bool(cfg))
check(f"{CREATOR} renders three receivers", set(receivers) == {"filelog/ray_serve", "filelog/ray_workers", "filelog/ray_system"})
check(f"{PIPELINE} renders", bool(chain))

# 1. Discovery.
obs = ext.get(OBSERVER) or {}
check(f"{OBSERVER} watches only the pods of this node",
      obs.get("node") == "${env:K8S_NODE_NAME}" and obs.get("observe_pods") is True and
      not any(obs.get(k) for k in ("observe_nodes", "observe_services", "observe_ingresses")))
check(f"{OBSERVER} is a service extension", OBSERVER in (service.get("extensions") or []))
check(f"{CREATOR} watches {OBSERVER}", creator.get("watch_observers") == [OBSERVER])
check("every Ray receiver has the ray.io/is-ray-node rule",
      all(r.get("rule") == RULE for r in receivers.values()))
check("no rule reads a pod annotation", not any("annotations" in r.get("rule", "") for r in receivers.values()))

# 2. Paths.
includes = [p for r in receivers.values() for p in r["config"]["include"]]
check("every path is in a Ray session directory of the pod's emptyDir volumes",
      all(p.startswith(VOLUMES) for p in includes))
check("no path reads session_latest", not any("session_latest" in p or "session_*" in p for p in includes))
names = [p[len(VOLUMES):] for p in includes]
check("Serve logs are read", "serve/*.log" in names)
check("worker stdout and stderr are read, also after the worker exits",
      {"worker-*.out", "worker-*.err", "old/worker-*.out", "old/worker-*.err"} <= set(names))
check("the raylet and GCS logs are read", {"raylet.out", "raylet.err", "gcs_server.out", "gcs_server.err"} <= set(names))
check("the Python core, dashboard, event and profiler logs are not read",
      not any(re.match(r"(python-core-|dashboard|events/|export_events/|nsight/|profiles/|debug_state)", n) for n in names))
check("no receiver deletes a file", not any(r["config"].get("delete_after_read") for r in receivers.values()))

# 3. Record shaping.
serve, workers, system = receivers["filelog/ray_serve"], receivers["filelog/ray_workers"], receivers["filelog/ray_system"]
check("every receiver keeps leading whitespace, for the recombine rules",
      all(r["config"].get("preserve_leading_whitespaces") is True for r in receivers.values()))
check("every receiver recombines per file", all(
    [o.get("source_identifier") for o in ops(r, "recombine")] == ['attributes["log.file.name"]'] for r in receivers.values()))
check("every receiver sets log.file.name, and no full path",
      all(r["config"].get("include_file_name") is True and r["config"].get("include_file_path") is False for r in receivers.values()))

serve_first = ops(serve, "recombine")[0]["is_first_entry"]
check("a Serve JSON record starts a record", matches_any(serve_first, '{"asctime": "2026-10-26 12:34:12,186", "levelname": "INFO"}'))
check("a Serve text record starts a record", matches_any(serve_first, "ERROR 2026-10-26 12:32:17,523 hello_Hello khni0y8q 9894ecc2 -- Request failed."))
check("a traceback line does not start a Serve record", not matches_any(serve_first, '  File "/x/replica.py", line 1310, in f'))

w_first = ops(workers, "recombine")[0]["is_first_entry"]
w_cont = lambda line: matches_any(w_first, line)  # the expression is negated: a match is a continuation
check("traceback lines continue the record before them", all(w_cont(l) for l in [
    "Traceback (most recent call last):", '  File "/x/a.py", line 1, in f', "    raise ValueError(x)",
    "ValueError: boom requested", "During handling of the above exception, another exception occurred:",
    "ray.exceptions.RayTaskError: bad"]))
check("a print starts its own record", not any(w_cont(l) for l in ["hello from my task", "Epoch 1 loss=0.2", "INFO 2026-10-26 12:32:17,523 x y -- m"]))
w_drop = ops(workers, "filter")[0]["expr"]
check("the stderr copy of a Serve record is dropped", all(matches_any(w_drop, l) for l in [
    "INFO 2026-10-26 12:34:12,185 hello_Hello gr2qitox fc29b665-28cd -- hello request for user97",
    "INFO 2026-10-26 12:31:39,027 proxy 192.168.87.86 -- Proxy starting on node 4d4c (HTTP port: 8000).",
    "INFO 2026-10-26 12:31:39,118 controller 1126 -- Received new config for application 'hello'."]))
check("traceback lines after a vLLM subprocess prefix continue the record", all(w_cont(l) for l in [
    '(EngineCore pid=7165)   File "/x/core.py", line 1, in run_engine_core', "(EngineCore pid=7165) Traceback (most recent call last):",
    "(EngineCore_DP0 pid=7165) RuntimeError: CUDA out of memory"]))
check("vLLM's per-line traceback continues the record", all(w_cont(l) for l in [
    "ERROR 10-26 13:23:31 [multiproc_executor.py:1018] Traceback (most recent call last):",
    'ERROR 10-26 13:23:31 [multiproc_executor.py:1018]   File "/x/executor.py", line 1, in f',
    "(EngineCore pid=7165) ERROR 10-26 13:23:31 [core.py:1] RuntimeError: CUDA error"]))
check("a vLLM log line starts its own record", not any(w_cont(l) for l in [
    "INFO 10-26 13:19:01 [model.py:1883] Using max model len 16384",
    "ERROR 10-26 13:23:31 [multiproc_executor.py:1018] WorkerProc hit an exception."]))
check("a vLLM subprocess line starts its own record",
      not w_cont("(EngineCore pid=7165) 2026-10-26 13:24:21,373\tINFO worker.py:1686 -- Using address 10.0.0.1:6379"))
check("Ray's colored copy of another worker's line is dropped", all(matches_any(w_drop, l) for l in [
    "(EngineCore pid=7165) \x1b[36m(RayWorkerProc pid=7303)\x1b[0m (Worker_TP0 pid=7303) Capturing CUDA graphs",
    "\x1b[36m(train_func pid=812, ip=10.0.1.2)\x1b[0m epoch 3 loss 0.1"]))
check("vLLM's own uncolored subprocess prefix is kept", not any(matches_any(w_drop, l) for l in [
    "(EngineCore pid=7165) Transient error StatusCode.UNAVAILABLE encountered while exporting traces",
    "(Worker pid=4406) {\"asctime\": \"2026-10-26 13:19:35,425\", \"levelname\": \"INFO\"}"]))
check("Ray's marker lines are dropped", all(matches_any(w_drop, l) for l in [":job_id:01000000", ":task_name:build_serve_application", ":actor_name:ProxyActor"]))
check("Ray core, warnings and prints are kept", not any(matches_any(w_drop, l) for l in [
    "2026-10-26 12:31:25,789\tINFO worker.py:1 -- Connecting to existing Ray cluster",
    "/x/replica.py:3140: UserWarning: Calling sync method",
    "hello from my task", "INFO: uvicorn running"]))

s_first = ops(system, "recombine")[0]["is_first_entry"]
check("C++ and Python Ray records start a record", matches_any(s_first, "[2026-10-26 12:31:29,825 I 760 760] (raylet) main.cc:279: x")
      and matches_any(s_first, "2026-10-26 12:31:25,737\tINFO monitor.py:314 -- x"))
check("a stats dump line does not start a record", not matches_any(s_first, "Event stats:") and not matches_any(s_first, "- cumulative published messages: 3"))
s_drop = ops(system, "filter")[0]["expr"]
check("only raylet.out and gcs_server.out are level-filtered", 'in ["raylet.out", "gcs_server.out"]' in s_drop)
check("their DEBUG and INFO records are dropped, WARNING and above kept",
      matches_any(s_drop, "[2026-10-26 12:31:29,825 I 760 760] (raylet) x") and
      matches_any(s_drop, "[2026-10-26 12:31:29,825 D 760 760] (raylet) x") and
      not any(matches_any(s_drop, f"[2026-10-26 12:31:29,825 {l} 760 760] (raylet) x") for l in "WEF"))

# 4. Pipeline, attributes and names.
check(f"{PIPELINE} reads only {CREATOR}", pipe.get("receivers") == [CREATOR])
check(f"{PIPELINE} sends to the application log group", pipe.get("exporters") == [EXPORTER])
check(f"every processor in {PIPELINE} is defined", all(p in processors for p in chain))
check("k8sattributes pod association runs on Ray logs", "k8sattributes/cw_k8s_ci_v0_pod" in chain)
scope = statements(processors.get(SCOPE), "log_statements")
check(f"{SCOPE} sets cloudwatch.pipeline=ray-logs", 'set(attributes["cloudwatch.pipeline"], "ray-logs")' in scope)
parse = statements(processors.get(PARSE), "log_statements")
check(f"{PARSE} copies the Serve JSON fields that join a record to its trace", all(
    f'set(attributes["{k}"], cache["{k}"])' in " ".join(parse) for k in ("request_id", "application", "deployment", "replica", "route")))
check(f"{PARSE} parses JSON only for a body that starts with {{", any("ParseJSON(body)" in st and 'IsMatch(body, "^\\\\{")' in st for st in parse))
svc = statements(processors.get(SERVICE_NAME), "log_statements")
check(f"{SERVICE_NAME} falls back to the pod name", any('attributes["service.name"], attributes["k8s.pod.name"]' in st for st in svc))
check("service.name does not use app.kubernetes.io/name (\"kuberay\" on every Ray pod)",
      not any("app.kubernetes.io" in st for st in svc + parse))
check("no aws.service.type (the type is inferred at query time)",
      not any("aws.service.type" in st for st in svc + parse + scope))
check("set_workload runs before the Ray service name",
      chain.index("transform/cw_k8s_ci_v0_logs_set_workload") < chain.index(SERVICE_NAME))

# 5. Time and checkpoints.
check("no Ray timestamp is parsed (Ray writes local time with no zone)",
      not any(o.get("type") == "time_parser" or "timestamp" in o for r in receivers.values() for o in r["config"].get("operators") or []) and
      not any("time_unix_nano" in st or "set(time" in st for st in parse))
check("without stateStorage.enabled: no checkpoints, start_at end (as the application logs)",
      all(r["config"].get("start_at") == "end" and "storage" not in r["config"] for r in receivers.values()))
ck = ((otel_config("checkpoints.yaml").get("receivers") or {}).get(CREATOR) or {}).get("receivers") or {}
check("with stateStorage.enabled: checkpoints in file_storage/cw_k8s_ci_v0_state, start_at beginning",
      bool(ck) and all(r["config"].get("storage") == "file_storage/cw_k8s_ci_v0_state" and
                       r["config"].get("start_at") == "beginning" for r in ck.values()))

# 6. Off switches.
for name, label in (("ray-logs-off.yaml", "solutions.ray.logs.enabled=false"), ("logs-off.yaml", "logs.enabled=false")):
    print(f"\n{YELLOW}[{label}]{RESET}")
    off = otel_config(name)
    check("cloudwatch-agent CR still renders an otelConfig", bool(off))
    check(f"no {OBSERVER}", OBSERVER not in (off.get("extensions") or {}) and
          OBSERVER not in ((off.get("service") or {}).get("extensions") or []))
    check(f"no {CREATOR}", CREATOR not in (off.get("receivers") or {}))
    check(f"no {PARSE}, {SERVICE_NAME} or {SCOPE}", not ({PARSE, SERVICE_NAME, SCOPE} & set(off.get("processors") or {})))
    check(f"no {PIPELINE}", PIPELINE not in ((off.get("service") or {}).get("pipelines") or {}))

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
