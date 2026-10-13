#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins the Karpenter branch of the OTEL Container Insights cluster-scraper
# pipeline (otelContainerInsights.solutions.karpenter): Karpenter's client-go
# and Go runtime families (rest_client_*, workqueue_*, apiserver_*, go_*,
# process_*) are dropped, because the apiserver pipeline owns those names under
# its own scope. Same set as KEDA's filter/cw_k8s_ci_v0_keda_drop_non_keda.
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text.
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/karpenter_pipeline_shape.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

render() {
    "$HELM" template "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        --set otelContainerInsights.enabled=true \
        --set "otelContainerInsights.solutions.karpenter.enabled=$1" > "$2"
}

render true "${TMP_DIR}/enabled.yaml"
render false "${TMP_DIR}/disabled.yaml"

python3 - "${TMP_DIR}/enabled.yaml" "${TMP_DIR}/disabled.yaml" <<'PY'
import re
import sys

import yaml

PIPELINE = "metrics/cw_k8s_ci_v0_karpenter"
DROP = "filter/cw_k8s_ci_v0_karpenter_drop_non_karpenter"
KEDA_DROP = "filter/cw_k8s_ci_v0_keda_drop_non_keda"

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


def otel_config(path):
    """otelConfig of the cluster-scraper CR, parsed."""
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if (doc or {}).get("kind") == "AmazonCloudWatchAgent" and \
                    doc["metadata"]["name"] == "cloudwatch-agent-cluster-scraper":
                return yaml.safe_load(doc["spec"].get("otelConfig") or "{}") or {}
    return {}


print(f"\n{YELLOW}[solutions.karpenter.enabled=true]{RESET}")
cfg = otel_config(sys.argv[1])
processors = cfg.get("processors") or {}
chain = (((cfg.get("service") or {}).get("pipelines") or {}).get(PIPELINE) or {}).get("processors") or []
check("cluster-scraper CR renders an otelConfig", bool(cfg))
check(f"{PIPELINE} renders", bool(chain))
check(f"{DROP} is defined", DROP in processors)
check(f"{DROP} runs right after the scrape-metadata filter",
      chain[:2] == ["filter/cw_k8s_ci_v0_scrape_metadata", DROP])

conds = ((processors.get(DROP) or {}).get("metrics") or {}).get("metric") or []
check(f"{DROP} has the same conditions as {KEDA_DROP}",
      conds == (((processors.get(KEDA_DROP) or {}).get("metrics") or {}).get("metric") or conds))
m = re.search(r'IsMatch\(name, "([^"]+)"\)', conds[0] if conds else "")
check(f"{DROP} is a single drop-list condition", len(conds) == 1 and m is not None)
if m:
    dropped = re.compile(m.group(1))
    for name, want_dropped in [("rest_client_requests_total", True),
                               ("workqueue_depth", True),
                               ("apiserver_storage_objects", True),
                               ("go_goroutines", True),
                               ("process_cpu_seconds_total", True),
                               ("karpenter_nodes_allocatable", False),
                               ("karpenter_pods_state", False),
                               ("controller_runtime_reconcile_total", False)]:
        check(f"{name} is {'dropped' if want_dropped else 'kept'}",
              bool(dropped.match(name)) == want_dropped)
check(f"every processor in {PIPELINE} is defined", all(p in processors for p in chain))

print(f"\n{YELLOW}[solutions.karpenter.enabled=false]{RESET}")
off = otel_config(sys.argv[2])
check("cluster-scraper CR still renders an otelConfig", bool(off))
check(f"no {DROP}", DROP not in (off.get("processors") or {}))
check(f"no {PIPELINE}", PIPELINE not in ((off.get("service") or {}).get("pipelines") or {}))

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
