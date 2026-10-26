#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins how otelContainerInsights.solutions.ray.traces reaches the agent's JSON config:
# it turns on opentelemetry.collect.otlp on the node agent only, with the "ray" workload,
# alongside "vllm" when vLLM traces are on too, and nothing when it is off or when OTel
# Container Insights is off.
#
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/ray_traces_workloads.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

render() {
    local out="$1"; shift
    "$HELM" template "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        "$@" > "$out"
}

render "${TMP_DIR}/off.yaml" --set otelContainerInsights.enabled=true
render "${TMP_DIR}/ray.yaml" --set otelContainerInsights.enabled=true \
    --set otelContainerInsights.solutions.ray.traces.enabled=true
render "${TMP_DIR}/both.yaml" --set otelContainerInsights.enabled=true \
    --set otelContainerInsights.solutions.ray.traces.enabled=true \
    --set otelContainerInsights.solutions.vllm.traces.enabled=true
render "${TMP_DIR}/ci-off.yaml" --set otelContainerInsights.enabled=false \
    --set otelContainerInsights.solutions.ray.traces.enabled=true

python3 - "${TMP_DIR}" <<'PY'
import json
import os
import sys

import yaml

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


def otlp(name, agent):
    """opentelemetry.collect.otlp of the named agent's JSON config, or None."""
    with open(os.path.join(sys.argv[1], name)) as f:
        for doc in yaml.safe_load_all(f):
            if (doc or {}).get("kind") == "AmazonCloudWatchAgent" and doc["metadata"]["name"] == agent:
                cfg = doc["spec"].get("config") or "{}"
                cfg = json.loads(cfg) if isinstance(cfg, str) else cfg
                return ((cfg.get("opentelemetry") or {}).get("collect") or {}).get("otlp")
    return None


print(f"\n{YELLOW}[ray traces]{RESET}")
check("off by default: no otlp section", otlp("off.yaml", "cloudwatch-agent") is None)
ray = otlp("ray.yaml", "cloudwatch-agent") or {}
check("on: node agent listens on 0.0.0.0:4317 and 0.0.0.0:4318",
      ray.get("grpc_endpoint") == "0.0.0.0:4317" and ray.get("http_endpoint") == "0.0.0.0:4318")
check("on: workloads is [\"ray\"]", ray.get("workloads") == ["ray"])
check("on: the cluster-scraper gets no otlp section", otlp("ray.yaml", "cloudwatch-agent-cluster-scraper") is None)
both = otlp("both.yaml", "cloudwatch-agent") or {}
check("with vLLM traces: workloads has both, once each",
      sorted(both.get("workloads") or []) == ["ray", "vllm"])
check("OTel Container Insights off: no otlp section", otlp("ci-off.yaml", "cloudwatch-agent") is None)

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
