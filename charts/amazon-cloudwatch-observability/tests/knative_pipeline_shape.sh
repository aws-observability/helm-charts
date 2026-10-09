#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins the shape of the Knative Serving branches of the OTEL Container Insights
# pipelines (otelContainerInsights.solutions.knative).
#
#   1. Data plane: each agent watches only the revision pods on its own node,
#      filtered by the API server, and attributes them to their Deployment.
#      Revisions of a KServe InferenceService get aws.service.type = ai_inference.
#   2. Control plane: datapoints are attributed to the component pod, and
#      resource detection leaves out the AZ and host of the node the
#      cluster-scraper happens to run on.
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text.
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/knative_pipeline_shape.sh

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
        --set "otelContainerInsights.solutions.knative.dataPlane.enabled=$1" \
        --set "otelContainerInsights.solutions.knative.controlPlane.enabled=$1" > "$2"
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


DP_RECEIVER = "prometheus/cw_k8s_ci_v0_knative_dataplane"
DP_PIPELINE = "metrics/cw_k8s_ci_v0_knative_dataplane"
DP_PROMOTE = "transform/cw_k8s_ci_v0_knative_dataplane_promote"
CP_RECEIVER = "prometheus/cw_k8s_ci_v0_knative_controlplane"

print(f"\n{YELLOW}[solutions.knative.*.enabled=true]{RESET}")
node = otel_config(sys.argv[1], "cloudwatch-agent")
check("cloudwatch-agent CR renders an otelConfig", bool(node))

# Data plane: one queue-proxy per revision pod, scraped by the agent on its node.
job = ((((node.get("receivers") or {}).get(DP_RECEIVER) or {}).get("config") or {})
       .get("scrape_configs") or [{}])[0]
rules = job.get("relabel_configs") or []
check(f"{DP_RECEIVER} renders", bool(rules))
sd = (job.get("kubernetes_sd_configs") or [{}])[0]
sel = sd.get("selectors") or []
# Both filters must run in the API server: a relabel-only node filter still
# makes every agent watch every pod in the cluster.
check("revision pods on this node are selected by the API server",
      any(s.get("field") == "spec.nodeName=${env:K8S_NODE_NAME}" and
          s.get("label") == "serving.knative.dev/revision" for s in sel))
check("no relabel rule filters on the node name",
      not any("__meta_kubernetes_pod_node_name" in (r.get("source_labels") or []) for r in rules))
check("only the queue-proxy http-usermetric port is kept",
      any(r.get("action") == "keep" and r.get("regex") == "http-usermetric" for r in rules))
dp_processors = node.get("processors") or {}
dp_chain = (((node.get("service") or {}).get("pipelines") or {}).get(DP_PIPELINE) or {}).get("processors") or []
check(f"{DP_PROMOTE} runs before k8sattributes pod association",
      DP_PROMOTE in dp_chain and "k8sattributes/cw_k8s_ci_v0_pod" in dp_chain and
      dp_chain.index(DP_PROMOTE) < dp_chain.index("k8sattributes/cw_k8s_ci_v0_pod"))
check("no relabel rule creates an inferenceservice label",
      not any(r.get("target_label") == "inferenceservice" for r in rules))
SERVICE_TYPE = "transform/cw_k8s_ci_v0_knative_dataplane_service_type"
st_stmts = [st for g in (dp_processors.get(SERVICE_TYPE) or {}).get("metric_statements") or []
            for st in g.get("statements") or []]
check(f"{SERVICE_TYPE} sets aws.service.type = ai_inference only for InferenceService revisions",
      st_stmts == ['set(attributes["aws.service.type"], "ai_inference") where attributes["k8s.pod.label.serving.kserve.io/inferenceservice"] != nil'])
check(f"{SERVICE_TYPE} runs after k8sattributes pod association",
      SERVICE_TYPE in dp_chain and "k8sattributes/cw_k8s_ci_v0_pod" in dp_chain and
      dp_chain.index("k8sattributes/cw_k8s_ci_v0_pod") < dp_chain.index(SERVICE_TYPE))
check(f"every processor in {DP_PIPELINE} is defined", all(p in dp_processors for p in dp_chain))

# Control plane: autoscaler, activator, controller, webhook, from the cluster-scraper.
scraper = otel_config(sys.argv[1], "cloudwatch-agent-cluster-scraper")
check("cluster-scraper CR renders an otelConfig", bool(scraper))
control_plane(scraper, "knative_controlplane", CP_RECEIVER)

print(f"\n{YELLOW}[solutions.knative.*.enabled=false]{RESET}")
off_node = otel_config(sys.argv[2], "cloudwatch-agent")
off_scraper = otel_config(sys.argv[2], "cloudwatch-agent-cluster-scraper")
check("both CRs still render an otelConfig", bool(off_node) and bool(off_scraper))
check(f"no {DP_RECEIVER}", DP_RECEIVER not in (off_node.get("receivers") or {}))
check(f"no {CP_RECEIVER}", CP_RECEIVER not in (off_scraper.get("receivers") or {}))
check("no knative processors on either agent",
      not [p for c in (off_node, off_scraper) for p in c.get("processors") or {} if "knative" in p])

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
