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

render "${TMP_DIR}/rosa.yaml" --set otelContainerInsights.enabled=true --set k8sMode=ROSA

# Renders that can fail. Each adds "<name>: rendered" or "<name>: failed: <error>" to results.txt.
try_render() {
    local name="$1"
    shift
    if render "${TMP_DIR}/${name}.yaml" "$@" 2> "${TMP_DIR}/${name}.err"; then
        echo "${name}: rendered" >> "${TMP_DIR}/results.txt"
    else
        echo "${name}: failed: $(tr '\n' ' ' < "${TMP_DIR}/${name}.err")" >> "${TMP_DIR}/results.txt"
    fi
}

cat > "${TMP_DIR}/per-agent-surge.values.yaml" <<'EOF'
agents:
  - name: cloudwatch-agent
    updateStrategy:
      type: RollingUpdate
      rollingUpdate:
        maxSurge: 1
  - name: cloudwatch-agent-cluster-scraper
    mode: deployment
    config: "default"
EOF
cat > "${TMP_DIR}/target-agent.values.yaml" <<'EOF'
otelContainerInsights:
  targetAgent: node-b
agents:
  - name: node-a
    updateStrategy:
      type: RollingUpdate
      rollingUpdate:
        maxSurge: 1
  - name: node-b
  - name: cloudwatch-agent-cluster-scraper
    mode: deployment
    config: "default"
EOF
cat > "${TMP_DIR}/user-connectors.values.yaml" <<'EOF'
agent:
  otelConfig:
    connectors:
      forward/user: {}
    receivers:
      otlp/user:
        protocols:
          grpc:
            endpoint: 127.0.0.1:4999
    exporters:
      debug/user: {}
    service:
      pipelines:
        logs/user_in:
          receivers: [otlp/user]
          exporters: [forward/user]
        logs/user_out:
          receivers: [forward/user]
          exporters: [debug/user]
EOF

# The update strategy of the node agent does not change the feature.
CI_ON=(--set otelContainerInsights.enabled=true)
ROLLING=(--set agent.updateStrategy.type=RollingUpdate)
try_render surge-1 "${CI_ON[@]}" "${ROLLING[@]}" --set agent.updateStrategy.rollingUpdate.maxSurge=1
try_render surge-10pct "${CI_ON[@]}" "${ROLLING[@]}" --set-string agent.updateStrategy.rollingUpdate.maxSurge=10%
try_render surge-logs-off "${CI_ON[@]}" "${ROLLING[@]}" --set agent.updateStrategy.rollingUpdate.maxSurge=1 \
    --set otelContainerInsights.logs.enabled=false
try_render surge-0pct "${CI_ON[@]}" "${ROLLING[@]}" --set-string agent.updateStrategy.rollingUpdate.maxSurge=0%
try_render on-delete "${CI_ON[@]}" --set agent.updateStrategy.type=OnDelete --set agent.updateStrategy.rollingUpdate.maxSurge=1
try_render per-agent-surge "${CI_ON[@]}" -f "${TMP_DIR}/per-agent-surge.values.yaml"
try_render target-agent "${CI_ON[@]}" -f "${TMP_DIR}/target-agent.values.yaml"
try_render user-connectors "${CI_ON[@]}" -f "${TMP_DIR}/user-connectors.values.yaml"
try_render user-connectors-logs-off "${CI_ON[@]}" -f "${TMP_DIR}/user-connectors.values.yaml" \
    --set otelContainerInsights.logs.enabled=false

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
check(f"{STORAGE} keeps its files in {STATE_DIR}, with compaction, cleanup, and recreate", storage == {
    "directory": STATE_DIR,
    "create_directory": True,
    "compaction": {"on_start": True, "on_rebound": True, "directory": STATE_DIR, "cleanup_on_start": True},
    "recreate": True,
})
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


def has_feature(cr):
    cfg = otel_config(cr)
    return CONNECTOR in (cfg.get("connectors") or {}) and otelstate(cr) != ([], [])


print(f"\n{YELLOW}[k8sMode=ROSA]{RESET}")
check("the node agent has the connector and the otelstate volume",
      has_feature(agents("rosa.yaml").get("cloudwatch-agent")))

print(f"\n{YELLOW}[agent updateStrategy]{RESET}")
results = {}
with open(os.path.join(TMP, "results.txt")) as f:
    for line in f:
        name, _, rest = line.partition(": ")
        results[name] = rest.strip()
for name, desc in (("surge-1", "maxSurge 1"), ("surge-10pct", "maxSurge 10%"), ("surge-0pct", "maxSurge 0%")):
    check(f"{desc} renders with the feature",
          results[name] == "rendered" and has_feature(agents(f"{name}.yaml").get("cloudwatch-agent")))
check("maxSurge 1 with logs off renders without the feature",
      results["surge-logs-off"] == "rendered" and not has_feature(agents("surge-logs-off.yaml").get("cloudwatch-agent")))
check("OnDelete renders with the feature",
      results["on-delete"] == "rendered" and has_feature(agents("on-delete.yaml").get("cloudwatch-agent")))
check("maxSurge 1 in agents[] of the node agent renders with the feature",
      results["per-agent-surge"] == "rendered" and has_feature(agents("per-agent-surge.yaml").get("cloudwatch-agent")))

print(f"\n{YELLOW}[otelContainerInsights.targetAgent=node-b, node-a has maxSurge 1]{RESET}")
check("the render passes", results["target-agent"] == "rendered")
if results["target-agent"] == "rendered":
    target = agents("target-agent.yaml")
    check("node-b has the connector and the otelstate volume", has_feature(target.get("node-b")))
    check("node-a has no connector and no otelstate volume",
          "node-a" in target and CONNECTOR not in (otel_config(target["node-a"]).get("connectors") or {})
          and otelstate(target["node-a"]) == ([], []))

print(f"\n{YELLOW}[a user connector in agent.otelConfig]{RESET}")
check("the render passes", results["user-connectors"] == "rendered")
if results["user-connectors"] == "rendered":
    user = otel_config(agents("user-connectors.yaml").get("cloudwatch-agent"))
    check("the node agent keeps the chart's connector and the user's connector",
          set(user.get("connectors") or {}) == {CONNECTOR, "forward/user"})
    check("the node agent keeps the chart's pipelines and the user's pipelines",
          {APP, REPLAY, "logs/user_in", "logs/user_out"} <= set(pipelines(user)))
    scraper = otel_config(agents("user-connectors.yaml").get("cloudwatch-agent-cluster-scraper"))
    check("the cluster scraper gets the user's connector and not the chart's",
          set(scraper.get("connectors") or {}) == {"forward/user"})

print(f"\n{YELLOW}[a user connector in agent.otelConfig, logs off]{RESET}")
check("the render passes", results["user-connectors-logs-off"] == "rendered")
if results["user-connectors-logs-off"] == "rendered":
    for agent in ("cloudwatch-agent", "cloudwatch-agent-cluster-scraper"):
        off = otel_config(agents("user-connectors-logs-off.yaml").get(agent))
        check(f"{agent} keeps the user's connector and pipelines",
              set(off.get("connectors") or {}) == {"forward/user"}
              and {"logs/user_in", "logs/user_out"} <= set(pipelines(off)))
    absent("a user connector in agent.otelConfig, logs off", "user-connectors-logs-off.yaml")

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
