#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins the shape of the hourly re-send of the vLLM startup line (log_replay/cw_k8s_ci_v0_vllm):
# rendered only with logs and the vLLM solution on, only on the node agent, and never in logs-off mode.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/vllm_log_replay_shape.sh

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
        "$@" > "$out"
}

render "${TMP_DIR}/on.yaml" --set otelContainerInsights.enabled=true
render "${TMP_DIR}/logs-off.yaml" --set otelContainerInsights.enabled=true --set otelContainerInsights.logs.enabled=false
render "${TMP_DIR}/vllm-off.yaml" --set otelContainerInsights.enabled=true --set otelContainerInsights.solutions.vllm.enabled=false
render "${TMP_DIR}/solutions-off.yaml" --set otelContainerInsights.enabled=true --set otelContainerInsights.solutions.enabled=false
render "${TMP_DIR}/ci-off.yaml"

# maxSurge above 0 on the node agent fails the render with the feature on, and
# renders with it off.
SURGE=(--set otelContainerInsights.enabled=true --set agent.updateStrategy.type=RollingUpdate
    --set agent.updateStrategy.rollingUpdate.maxSurge=1)
if render "${TMP_DIR}/surge.yaml" "${SURGE[@]}" 2> "${TMP_DIR}/surge.err"; then
    echo "surge-on: rendered" > "${TMP_DIR}/surge.result"
else
    echo "surge-on: failed: $(cat "${TMP_DIR}/surge.err")" > "${TMP_DIR}/surge.result"
fi
if render "${TMP_DIR}/surge-off.yaml" "${SURGE[@]}" --set otelContainerInsights.logs.enabled=false 2> "${TMP_DIR}/surge-off.err"; then
    echo "surge-off: rendered" >> "${TMP_DIR}/surge.result"
else
    echo "surge-off: failed: $(cat "${TMP_DIR}/surge-off.err")" >> "${TMP_DIR}/surge.result"
fi

python3 - "${TMP_DIR}" <<'PY'
import os
import sys

import yaml

TMP = sys.argv[1]
CONNECTOR = "log_replay/cw_k8s_ci_v0_vllm"
STORAGE = "file_storage/cw_k8s_ci_v0_state"
APP = "logs/cw_k8s_ci_v0_app"
REPLAY = "logs/cw_k8s_ci_v0_vllm_replay"
APP_EXPORTER = "otlphttp/cw_k8s_ci_v0_app_logs_dest"
STATE_DIR = "/var/lib/amazon-cloudwatch-agent/otel-state"

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


def agents(name):
    """The AmazonCloudWatchAgent CRs of a render, by name."""
    out = {}
    with open(os.path.join(TMP, name)) as f:
        for doc in yaml.safe_load_all(f):
            if (doc or {}).get("kind") == "AmazonCloudWatchAgent":
                out[doc["metadata"]["name"]] = doc
    return out


def otel_config(cr):
    return yaml.safe_load((cr or {}).get("spec", {}).get("otelConfig") or "{}") or {}


def pipelines(cfg):
    return (cfg.get("service") or {}).get("pipelines") or {}


def otelstate(cr):
    spec = (cr or {}).get("spec", {})
    volumes = [v for v in spec.get("volumes") or [] if v.get("name") == "otelstate"]
    mounts = [m for m in spec.get("volumeMounts") or [] if m.get("name") == "otelstate"]
    return volumes, mounts


def absent(desc, name):
    """Nothing of the feature in any agent of a render, and its text has no trace of it."""
    print(f"\n{YELLOW}[{desc}]{RESET}")
    crs = agents(name)
    check("the render has the node agent", "cloudwatch-agent" in crs)
    for agent, cr in crs.items():
        cfg = otel_config(cr)
        check(f"{agent}: no {CONNECTOR}", CONNECTOR not in (cfg.get("connectors") or {}))
        check(f"{agent}: no {STORAGE}", STORAGE not in (cfg.get("extensions") or {}))
        check(f"{agent}: no {REPLAY}", REPLAY not in pipelines(cfg))
        check(f"{agent}: no otelstate volume or mount", otelstate(cr) == ([], []))
        app = pipelines(cfg).get(APP)
        if app:
            check(f"{agent}: {APP} exports only to {APP_EXPORTER}", app.get("exporters") == [APP_EXPORTER])
    with open(os.path.join(TMP, name)) as f:
        text = f.read()
    check("the render text has no log_replay, cw_k8s_ci_v0_state, or otelstate",
          not any(s in text for s in ("log_replay", "cw_k8s_ci_v0_state", "otelstate")))


# --- logs on, vLLM on (the defaults with OTEL Container Insights on) ------------
print(f"\n{YELLOW}[otelContainerInsights.enabled=true, logs and vLLM on]{RESET}")
on = agents("on.yaml")
node = on.get("cloudwatch-agent")
cfg = otel_config(node)
check("the node agent renders an otelConfig", bool(cfg))
connector = (cfg.get("connectors") or {}).get(CONNECTOR)
check(f"{CONNECTOR} renders", bool(connector))
check("the connector configuration is the agent's testdata/vllm_rule.yaml with the storage", connector == {
    "storage": STORAGE,
    "interval": "1h",
    "source_file_attribute": "log.file.path",
    "rules": [{
        "name": "vllm_engine_config",
        "body_contains": [
            "Initializing an LLM engine (v",
            "Initializing a V0 LLM engine (v",
            "Initializing a V1 LLM engine (v",
        ],
        "identity": ["k8s.namespace.name", "k8s.pod.name", "k8s.container.name"],
    }],
})
storage = (cfg.get("extensions") or {}).get(STORAGE) or {}
check(f"{STORAGE} keeps its files in {STATE_DIR}",
      storage.get("directory") == STATE_DIR and (storage.get("compaction") or {}).get("directory") == STATE_DIR)
check(f"{STORAGE} is a service extension", STORAGE in ((cfg.get("service") or {}).get("extensions") or []))

app = pipelines(cfg).get(APP) or {}
check(f"{APP} exports to the application logs and to the connector",
      app.get("exporters") == [APP_EXPORTER, CONNECTOR])
base = pipelines(otel_config(agents("vllm-off.yaml").get("cloudwatch-agent"))).get(APP) or {}
check(f"{APP} receivers and processors are those without the feature",
      bool(base) and app.get("receivers") == base.get("receivers") and app.get("processors") == base.get("processors"))
replay = pipelines(cfg).get(REPLAY) or {}
check(f"{REPLAY} sends the copies from the connector to {APP_EXPORTER}", replay == {
    "receivers": [CONNECTOR],
    "processors": ["batch/cw_k8s_ci_v0_logs_dest"],
    "exporters": [APP_EXPORTER],
})
check("filelog/cw_k8s_ci_v0_app sets log.file.path",
      ((cfg.get("receivers") or {}).get("filelog/cw_k8s_ci_v0_app") or {}).get("include_file_path") is True)

volumes, mounts = otelstate(node)
check(f"the node agent mounts {STATE_DIR} read-write from the node", volumes == [{
    "name": "otelstate", "hostPath": {"path": STATE_DIR, "type": "DirectoryOrCreate"},
}] and mounts == [{"name": "otelstate", "mountPath": STATE_DIR}])
for agent, cr in on.items():
    if agent == "cloudwatch-agent":
        continue
    other = otel_config(cr)
    check(f"{agent}: no connector, storage, or otelstate",
          CONNECTOR not in (other.get("connectors") or {}) and STORAGE not in (other.get("extensions") or {})
          and otelstate(cr) == ([], []))

absent("otelContainerInsights.logs.enabled=false", "logs-off.yaml")
absent("otelContainerInsights.solutions.vllm.enabled=false", "vllm-off.yaml")
absent("otelContainerInsights.solutions.enabled=false", "solutions-off.yaml")
absent("otelContainerInsights.enabled=false", "ci-off.yaml")

print(f"\n{YELLOW}[agent maxSurge 1]{RESET}")
with open(os.path.join(TMP, "surge.result")) as f:
    result = f.read()
check("with the feature on, the render fails on maxSurge 1",
      "surge-on: failed" in result and "requires updateStrategy.rollingUpdate.maxSurge 0, got: 1" in result)
check("with logs off, the render passes", "surge-off: rendered" in result)

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
