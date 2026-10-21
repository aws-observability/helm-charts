#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins where Container Insights series take cloud.availability_zone and
# cloud.region from. The cluster scraper runs on one node, so the zone that
# resource detection finds there is that node's, not the zone of the object a
# series describes. On some platforms and pipelines, the pod's topology labels,
# which the attribute limit removes, are the only region and zone a series has.
#
#   1. In the cluster scraper's kube-state-metrics pipeline,
#      transform/cw_k8s_ci_v0_ksm_zone deletes the zone from every series
#      without host.id. Only nodemetadataenricher sets host.id there, together
#      with the zone of the series' node. On those series it then takes the
#      node's topology.kubernetes.io/zone label. It runs after the node labels,
#      the enricher and set_cloud_resource_id, which on GKE builds
#      cloud.resource_id from the detected zone.
#   2. transform/cw_k8s_ci_v0_pod_topology, in both collectors, sets a missing
#      region from the pod's topology.kubernetes.io/region label, and the zone
#      from its /zone label. Every pipeline that adds pod labels runs it after
#      pod enrichment, resource detection, the enricher, the zone transform and
#      set_cloud_resource_id, and before the attribute limit.
#   3. Both copies skip digit-only zones: on AKS nodes outside availability
#      zones, the zone label holds the fault domain, not a zone.
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text.
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/availability_zone.sh

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

NODE_AGENT, SCRAPER = "cloudwatch-agent", "cloudwatch-agent-cluster-scraper"
KSM = "metrics/cw_k8s_ci_v0_kube_state_metrics"
DETECTOR = "resourcedetection/cw_k8s_ci_v0"
POD_ATTRS = "k8sattributes/cw_k8s_ci_v0_pod"
NODE_ATTRS = "k8sattributes/cw_k8s_ci_v0_node"
ENRICHER = "nodemetadataenricher/cw_k8s_ci_v0"
RESOURCE_ID = "transform/cw_k8s_ci_v0_set_cloud_resource_id"
ZONE = "transform/cw_k8s_ci_v0_ksm_zone"
TOPOLOGY = "transform/cw_k8s_ci_v0_pod_topology"
LIMIT = "awsattributelimit/cw_k8s_ci_v0"

NODE_ZONE_LABEL = 'attributes["k8s.node.label.topology.kubernetes.io/zone"]'
ZONE_STATEMENTS = [
    'delete_key(attributes, "cloud.availability_zone") where attributes["host.id"] == nil',
    f'set(attributes["cloud.availability_zone"], {NODE_ZONE_LABEL}) '
    f'where attributes["host.id"] == nil and {NODE_ZONE_LABEL} != nil '
    f'and not IsMatch({NODE_ZONE_LABEL}, "^[0-9]+$")',
]
REGION_LABEL = 'resource.attributes["k8s.pod.label.topology.kubernetes.io/region"]'
POD_ZONE_LABEL = 'resource.attributes["k8s.pod.label.topology.kubernetes.io/zone"]'
TOPOLOGY_STATEMENTS = [
    f'set(resource.attributes["cloud.region"], {REGION_LABEL}) '
    f'where resource.attributes["cloud.region"] == nil and {REGION_LABEL} != nil',
    f'set(resource.attributes["cloud.availability_zone"], {POD_ZONE_LABEL}) '
    f'where {POD_ZONE_LABEL} != nil and not IsMatch({POD_ZONE_LABEL}, "^[0-9]+$")',
]


def check(desc, ok):
    global passed, failed
    if ok:
        print(f"  {GREEN}PASS{RESET}: {desc}")
        passed += 1
    else:
        print(f"  {RED}FAIL{RESET}: {desc}")
        failed += 1
    return ok


def configs(path):
    found = {}
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if (doc or {}).get("kind") == "AmazonCloudWatchAgent" and doc["metadata"]["name"] in (NODE_AGENT, SCRAPER):
                found[doc["metadata"]["name"]] = yaml.safe_load(doc["spec"]["otelConfig"])
    return found


def before(chain, a, b):
    return a in chain and b in chain and chain.index(a) < chain.index(b)


def resource_statements(processor):
    return [" ".join(s.split()) for b in (processor or {}).get("metric_statements") or []
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
    cfgs = configs(os.path.join(sys.argv[1], f"{mode}.yaml"))
    if not check("both collectors render an otelConfig", sorted(cfgs) == sorted((NODE_AGENT, SCRAPER))):
        continue

    procs = cfgs[SCRAPER].get("processors") or {}
    chain = ((cfgs[SCRAPER].get("service") or {}).get("pipelines") or {}).get(KSM, {}).get("processors") or []
    check(f"{KSM} runs {DETECTOR} before {ENRICHER}", before(chain, DETECTOR, ENRICHER))
    check(f"{ZONE} deletes the AZ without host.id, then takes the node's zone label",
          resource_statements(procs.get(ZONE)) == ZONE_STATEMENTS)
    check(f"{ZONE} runs after {NODE_ATTRS}, which attaches the node's labels", before(chain, NODE_ATTRS, ZONE))
    check(f"{ZONE} runs after {ENRICHER}", before(chain, ENRICHER, ZONE))
    check(f"{ZONE} runs after {RESOURCE_ID}", before(chain, RESOURCE_ID, ZONE))
    check(f"{ZONE} runs before {LIMIT}, which may deny the label", before(chain, ZONE, LIMIT))
    upstream = [p for p in chain[:chain.index(ZONE)] if p != ENRICHER] if ZONE in chain else chain
    writers = [p for p in upstream if sets_host_id(p, procs.get(p))]
    check(f"only {ENRICHER} sets host.id before {ZONE}" + (f" (also: {writers})" if writers else ""), not writers)

    for agent, cfg in sorted(cfgs.items()):
        check(f"{agent}: {TOPOLOGY} sets a missing region, then the zone without digit-only values",
              resource_statements((cfg.get("processors") or {}).get(TOPOLOGY)) == TOPOLOGY_STATEMENTS)
        for name, pipeline in sorted(((cfg.get("service") or {}).get("pipelines") or {}).items()):
            steps = pipeline.get("processors") or []
            if POD_ATTRS not in steps or LIMIT not in steps:
                continue
            i = steps.index(TOPOLOGY) if TOPOLOGY in steps else -1
            sources = [p for p in steps if p in (POD_ATTRS, ENRICHER, ZONE, RESOURCE_ID) or p.startswith("resourcedetection")]
            check(f"{agent} {name}: {TOPOLOGY} runs after {', '.join(sources)} and before {LIMIT}",
                  i >= 0 and all(steps.index(p) < i for p in sources) and i < steps.index(LIMIT))

print(f"\n{YELLOW}[no-ksm]{RESET}")
cfg = configs(os.path.join(sys.argv[1], "no-ksm.yaml")).get(SCRAPER) or {}
check(f"with kube-state-metrics off, {ZONE} is not defined", ZONE not in (cfg.get("processors") or {}))

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
