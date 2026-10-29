#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins the shape of the KServe control-plane branch of the OTEL Container
# Insights cluster-scraper pipeline (otelContainerInsights.solutions.kserve).
#
#   1. The controller is found by label, like Karpenter and KEDA, so a cluster
#      without KServe has no target rather than a scrape failing every interval.
#   2. client-go families (workqueue_*, rest_client_*) are dropped: the
#      apiserver pipeline owns those names under its own scope.
#   3. Datapoints are attributed to the controller pod, and resource detection
#      leaves out the AZ and host of the node the scraper happens to run on.
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text.
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/kserve_pipeline_shape.sh

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
        --set "otelContainerInsights.solutions.kserve.controlPlane.enabled=$1" > "$2"
}

render true "${TMP_DIR}/enabled.yaml"
render false "${TMP_DIR}/disabled.yaml"

python3 - "${TMP_DIR}/enabled.yaml" "${TMP_DIR}/disabled.yaml" <<'PY'
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
    return ok


def otel_config(path, agent):
    """otelConfig of the named AmazonCloudWatchAgent CR, parsed."""
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if (doc or {}).get("kind") == "AmazonCloudWatchAgent" and \
                    doc["metadata"]["name"] == agent:
                return yaml.safe_load(doc["spec"].get("otelConfig") or "{}") or {}
    return {}






# The cluster-scraper runs on one node and scrapes targets elsewhere, so
# attribution must come from the target pod, not from where the scraper runs.
def control_plane(cfg, name, receiver):
    processors = cfg.get("processors") or {}
    pipeline = f"metrics/cw_k8s_ci_v0_{name}"
    detector = f"resourcedetection/cw_k8s_ci_v0_{name}"
    chain = (((cfg.get("service") or {}).get("pipelines") or {}).get(pipeline) or {}).get("processors") or []
    check(f"{pipeline} renders", bool(chain))
    attribution = [f"groupbyattrs/cw_k8s_ci_v0_{name}", f"transform/cw_k8s_ci_v0_{name}_promote",
                   "k8sattributes/cw_k8s_ci_v0_pod", "transform/cw_k8s_ci_v0_set_workload", detector]
    check(f"{pipeline} attributes to the target pod, in order (as Karpenter and KEDA do)",
          all(p in chain for p in attribution) and
          [chain.index(p) for p in attribution] == sorted(chain.index(p) for p in attribution))
    check(f"{pipeline} does not use the scraper-node resourcedetection/cw_k8s_ci_v0",
          "resourcedetection/cw_k8s_ci_v0" not in chain)
    ec2 = ((processors.get(detector) or {}).get("ec2") or {}).get("resource_attributes") or {}
    check(f"{detector} disables cloud.availability_zone and host attributes",
          ec2.get("cloud.availability_zone") == {"enabled": False} and
          ec2.get("host.name") == {"enabled": False} and ec2.get("host.id") == {"enabled": False})
    rules = ((((cfg.get("receivers") or {}).get(receiver) or {}).get("config") or {})
             .get("scrape_configs") or [{}])[0].get("relabel_configs") or []
    check(f"{receiver} sets pod, namespace and node target labels",
          {"pod", "namespace", "node"} <= {r.get("target_label") for r in rules})
    check(f"every processor in {pipeline} is defined", all(p in processors for p in chain))
    return processors, chain


import re

RECEIVER = "prometheus/cw_k8s_ci_v0_kserve_controlplane"
KEEP = "filter/cw_k8s_ci_v0_kserve_controlplane_keep"

print(f"\n{YELLOW}[solutions.kserve.controlPlane.enabled=true]{RESET}")
cfg = otel_config(sys.argv[1], "cloudwatch-agent-cluster-scraper")
check("cluster-scraper CR renders an otelConfig", bool(cfg))
job = (((cfg.get("receivers") or {}).get(RECEIVER) or {}).get("config") or {}).get("scrape_configs") or [{}]
job = job[0]
check(f"{RECEIVER} renders", bool(job))

# A fixed Service address fails every scrape on clusters without KServe;
# discovery by label finds nothing there instead.
check("no static_configs target", "static_configs" not in job)
sd = (job.get("kubernetes_sd_configs") or [{}])[0]
check("pods are discovered by the control-plane=kserve-controller-manager label",
      sd.get("role") == "pod" and
      any(s.get("label") == "control-plane=kserve-controller-manager" for s in sd.get("selectors") or []))
check("scraped over HTTPS with the service-account token (kube-rbac-proxy)",
      job.get("scheme") == "https" and "bearer_token_file" in job)

processors, chain = control_plane(cfg, "kserve_controlplane", RECEIVER)

# client-go's workqueue_* and rest_client_* are owned by the apiserver pipeline
# under its own scope; KEDA drops them for the same reason.
cond = ((processors.get(KEEP) or {}).get("metrics") or {}).get("metric") or []
m = re.search(r'not IsMatch\(name, "([^"]+)"\)', cond[0] if cond else "")
check(f"{KEEP} is a single keep-list condition", len(cond) == 1 and m is not None)
if m:
    kept = re.compile(m.group(1))
    for name, want in [("controller_runtime_reconcile_total", True),
                       ("leader_election_master_status", True),
                       ("workqueue_depth", False),
                       ("rest_client_requests_total", False),
                       ("go_goroutines", False)]:
        check(f"{name} is {'kept' if want else 'dropped'}", bool(kept.match(name)) == want)

print(f"\n{YELLOW}[solutions.kserve.controlPlane.enabled=false]{RESET}")
off = otel_config(sys.argv[2], "cloudwatch-agent-cluster-scraper")
check("cluster-scraper CR still renders an otelConfig", bool(off))
check(f"no {RECEIVER}", RECEIVER not in (off.get("receivers") or {}))
check("no kserve_controlplane processors",
      not [p for p in off.get("processors") or {} if "kserve_controlplane" in p])
check("no kserve_controlplane pipeline",
      "metrics/cw_k8s_ci_v0_kserve_controlplane" not in ((off.get("service") or {}).get("pipelines") or {}))

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
