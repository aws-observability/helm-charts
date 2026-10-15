#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins where the kube-state-metrics pipeline of the cluster-scraper takes
# cloud.availability_zone from. The scraper runs on one node, so the AZ that
# resource detection finds is that node's, not the AZ of the object a series
# describes.
#
#   1. transform/cw_k8s_ci_v0_ksm_zone runs after nodemetadataenricher and
#      set_cloud_resource_id, and before the attribute limit.
#   2. Except on GKE, it first deletes the AZ from every series without host.id.
#      Only the enricher sets host.id in this pipeline, together with the AZ of
#      the series' node, so what remains is that node's AZ. GKE keeps the
#      detected zone, because it builds cloud.resource_id from it.
#   3. Except on AKS, it then copies the pod's topology.kubernetes.io/zone label
#      into cloud.availability_zone. AKS series have no AZ attribute today.
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text.
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/ksm_availability_zone.sh

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
        --set otelContainerInsights.enabled=true \
        "$@" > "$out"
}

render "${TMP_DIR}/eks.yaml"
render "${TMP_DIR}/rosa.yaml" --set k8sMode=ROSA
render "${TMP_DIR}/k8s.yaml" --set k8sMode=K8S
render "${TMP_DIR}/gke.yaml" --set k8sMode=GKE --set roleArn=arn:aws:iam::123456789012:role/test
render "${TMP_DIR}/aks.yaml" --set k8sMode=AKS --set roleArn=arn:aws:iam::123456789012:role/test
render "${TMP_DIR}/no-ksm.yaml" --set kubeStateMetrics.enabled=false

python3 - "${TMP_DIR}" <<'PY'
import os
import sys

import yaml

GREEN, RED, YELLOW, RESET = "\033[0;32m", "\033[0;31m", "\033[1;33m", "\033[0m"
passed = failed = 0

PIPELINE = "metrics/cw_k8s_ci_v0_kube_state_metrics"
DETECTOR = "resourcedetection/cw_k8s_ci_v0"
ENRICHER = "nodemetadataenricher/cw_k8s_ci_v0"
RESOURCE_ID = "transform/cw_k8s_ci_v0_set_cloud_resource_id"
ZONE = "transform/cw_k8s_ci_v0_ksm_zone"
LIMIT = "awsattributelimit/cw_k8s_ci_v0"
DROP_STATEMENT = 'delete_key(attributes, "cloud.availability_zone") where attributes["host.id"] == nil'
POD_ZONE_STATEMENT = ('set(attributes["cloud.availability_zone"], '
                      'attributes["k8s.pod.label.topology.kubernetes.io/zone"]) '
                      'where attributes["k8s.pod.label.topology.kubernetes.io/zone"] != nil')


def check(desc, ok):
    global passed, failed
    if ok:
        print(f"  {GREEN}PASS{RESET}: {desc}")
        passed += 1
    else:
        print(f"  {RED}FAIL{RESET}: {desc}")
        failed += 1
    return ok


def scraper_config(path):
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if (doc or {}).get("kind") == "AmazonCloudWatchAgent" \
                    and doc["metadata"]["name"] == "cloudwatch-agent-cluster-scraper":
                return yaml.safe_load(doc["spec"]["otelConfig"])
    return None


def before(chain, a, b):
    return a in chain and b in chain and chain.index(a) < chain.index(b)


def resource_statements(processor):
    return [s.strip() for b in (processor or {}).get("metric_statements") or []
            if b.get("context") == "resource" for s in b.get("statements") or []]


# host.id default of each detector in the agent's resourcedetection build; any other detector is assumed to set it.
HOST_ID_DEFAULT = {"eks": False, "ec2": True, "aks": False}


def sets_host_id(name, processor):
    """Whether a processor can write host.id."""
    if name.startswith("resourcedetection"):
        for d in (processor or {}).get("detectors") or []:
            setting = ((processor or {}).get(d) or {}).get("resource_attributes", {}).get("host.id") or {}
            if setting.get("enabled", HOST_ID_DEFAULT.get(d, True)):
                return True
        return False
    return any('attributes["host.id"]' in s.split(",")[0] for s in resource_statements(processor)
               if not s.startswith("delete"))


for mode in ("eks", "rosa", "k8s", "gke", "aks"):
    print(f"\n{YELLOW}[{mode}]{RESET}")
    cfg = scraper_config(os.path.join(sys.argv[1], f"{mode}.yaml"))
    if not check("the cluster-scraper renders an otelConfig", cfg is not None):
        continue
    procs = cfg.get("processors") or {}
    chain = ((cfg.get("service") or {}).get("pipelines") or {}).get(PIPELINE, {}).get("processors") or []
    check(f"{PIPELINE} runs {DETECTOR} before {ENRICHER}", before(chain, DETECTOR, ENRICHER))

    want = {"gke": [POD_ZONE_STATEMENT], "aks": [DROP_STATEMENT]}.get(mode, [DROP_STATEMENT, POD_ZONE_STATEMENT])
    check(f"{ZONE} runs " + " then ".join("the delete" if w == DROP_STATEMENT else "the pod zone copy" for w in want),
          resource_statements(procs.get(ZONE)) == want)
    check(f"{ZONE} runs after {ENRICHER}", before(chain, ENRICHER, ZONE))
    check(f"{ZONE} runs after {RESOURCE_ID}", before(chain, RESOURCE_ID, ZONE))
    check(f"{ZONE} runs before {LIMIT}, which may deny the label", before(chain, ZONE, LIMIT))
    if DROP_STATEMENT in want:
        upstream = [p for p in chain[:chain.index(ZONE)] if p != ENRICHER] if ZONE in chain else chain
        writers = [p for p in upstream if sets_host_id(p, procs.get(p))]
        check(f"only {ENRICHER} sets host.id before {ZONE}" + (f" (also: {writers})" if writers else ""), not writers)

print(f"\n{YELLOW}[no-ksm]{RESET}")
cfg = scraper_config(os.path.join(sys.argv[1], "no-ksm.yaml")) or {}
check(f"with kube-state-metrics off, {ZONE} is not defined", ZONE not in (cfg.get("processors") or {}))

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
