#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins the shape of the vLLM branch of the OTEL Container Insights pipeline
# (otelContainerInsights.solutions.vllm).
#
# The scrape job finds vLLM servers without configuration: the model container
# of a KServe predictor, or a container running a vLLM image. What this script
# guards:
#
#   1. Discovery stays node-scoped: the image match cannot be done by the API
#      server, so an unscoped watch would hold every pod in the cluster on
#      every agent.
#   2. Only those two matches select targets. The chart reads no scrape labels
#      or annotations of its own (prometheus.io/*, cloudwatch.aws/*) from pods,
#      and on KServe pods only the predictor's kserve-container is picked:
#      transformers and explainers share the container name, and the
#      queue-proxy serves the model server's metrics a second time.
#   3. Port precedence: prometheus.kserve.io/port (the serving runtime's) >
#      declared port > server default. Relabel rules are applied in order and
#      later writes win, so the order of the rules is the precedence.
#   4. Pod identity reaches resource scope before k8sattributes runs.
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text.
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/vllm_pipeline_shape.sh

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
        --set "otelContainerInsights.solutions.vllm.enabled=$1" > "$2"
}

render true "${TMP_DIR}/enabled.yaml"
render false "${TMP_DIR}/disabled.yaml"

python3 - "${TMP_DIR}/enabled.yaml" "${TMP_DIR}/disabled.yaml" <<'PY'
import sys

import yaml

RECEIVER = "prometheus/cw_k8s_ci_v0_vllm"
PIPELINE = "metrics/cw_k8s_ci_v0_vllm"
KEEP = "filter/cw_k8s_ci_v0_vllm_keep"
PROMOTE = "transform/cw_k8s_ci_v0_vllm_promote"
SERVICE_NAME = "transform/cw_k8s_ci_v0_vllm_service_name"
ISVC = "__meta_kubernetes_pod_label_serving_kserve_io_inferenceservice"
ANNOTATION = "__meta_kubernetes_pod_annotation_"

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


def first(rules, pred):
    """Index of the first relabel rule matching pred, or -1."""
    return next((i for i, r in enumerate(rules) if pred(r)), -1)


def writes(rule, label):
    return rule.get("target_label") == label


def reads(rule, label):
    return label in (rule.get("source_labels") or [])


# --- solutions.vllm.enabled=true ------------------------------------------------
print(f"\n{YELLOW}[solutions.vllm.enabled=true]{RESET}")
cfg = otel_config(sys.argv[1], "cloudwatch-agent")
receiver = (cfg.get("receivers") or {}).get(RECEIVER) or {}
job = ((receiver.get("config") or {}).get("scrape_configs") or [{}])[0]
rules = job.get("relabel_configs") or []
processors = cfg.get("processors") or {}
chain = (((cfg.get("service") or {}).get("pipelines") or {}).get(PIPELINE) or {}).get("processors") or []

# Guards: without these, every assertion below could pass on empty input.
check("cloudwatch-agent CR renders an otelConfig", bool(cfg))
check(f"{RECEIVER} renders with relabel rules", bool(rules))
check(f"{PIPELINE} renders", bool(chain))

# 1. Node-scoped discovery, filtered by the API server.
sd = (job.get("kubernetes_sd_configs") or [{}])[0]
selectors = sd.get("selectors") or []
check("pod discovery is field-selected to this node",
      sd.get("role") == "pod" and
      any(s.get("field") == "spec.nodeName=${env:K8S_NODE_NAME}" for s in selectors))

# 2. Target selection: KServe predictor container or vLLM image, nothing else.
detect = first(rules, lambda r: r.get("target_label") == "__tmp_vllm_detected")
check("detection reads the inferenceservice and component labels, container name and image",
      detect >= 0 and rules[detect]["source_labels"] == [
          ISVC, "__meta_kubernetes_pod_label_component",
          "__meta_kubernetes_pod_container_name", "__meta_kubernetes_pod_container_image"])
check("on KServe pods only the predictor's kserve-container is detected",
      detect >= 0 and rules[detect].get("regex", "").startswith(".+;predictor;kserve-container;"))
keep = first(rules, lambda r: r.get("action") == "keep" and reads(r, "__tmp_vllm_detected"))
check("only detected targets are kept",
      keep >= 0 and rules[keep]["source_labels"] == ["__tmp_vllm_detected"] and rules[keep].get("regex") == "true")
check("no relabel rule reads prometheus.io/* or cloudwatch.aws/* from pods",
      not any(("prometheus_io_" in l or "cloudwatch_aws" in l)
              for r in rules for l in r.get("source_labels") or []))

# 3. Port and path precedence, encoded as rule order.
port_rules = [i for i, r in enumerate(rules) if writes(r, "__tmp_port")]
ks_port = first(rules, lambda r: writes(r, "__tmp_port") and reads(r, ANNOTATION + "prometheus_kserve_io_port"))
ks_path = first(rules, lambda r: writes(r, "__metrics_path__") and reads(r, ANNOTATION + "prometheus_kserve_io_path"))
address = first(rules, lambda r: writes(r, "__address__"))
check("prometheus.kserve.io/port is applied after the defaults, so it wins",
      ks_port >= 0 and port_rules[-1] == ks_port)
check("prometheus.kserve.io/path sets the metrics path", ks_path >= 0)
check("__address__ is set after every port rule",
      address >= 0 and all(i < address for i in port_rules))
check("annotation rules use the default replacement (no $ to escape)",
      all("replacement" not in rules[i] for i in (ks_port, ks_path) if i >= 0))

# aws.service.type is fixed by the chart, never read from the pod.
check("no relabel rule reads an aws.service.type pod label",
      not any("aws_service_type" in l for r in rules for l in r.get("source_labels") or []))
promote_stmts = [st for g in (processors.get(PROMOTE) or {}).get("metric_statements") or []
                 for st in g.get("statements") or []]
check(f"{PROMOTE} sets aws.service.type to ai_inference",
      'set(resource.attributes["aws.service.type"], "ai_inference")' in promote_stmts)

# No new attribute key for the InferenceService: service.name comes from KServe's
# own pod label as extracted by k8sattributes (k8s.pod.label.*).
check("no relabel rule creates an inferenceservice label",
      not any(r.get("target_label") == "inferenceservice" for r in rules))
check(f"{PROMOTE} does not set a custom inferenceservice attribute",
      not any('"inferenceservice"' in st for st in promote_stmts))
svc_stmts = [st for g in (processors.get(SERVICE_NAME) or {}).get("metric_statements") or []
             for st in g.get("statements") or []]
check(f"{SERVICE_NAME} takes the InferenceService name from k8s.pod.label.serving.kserve.io/inferenceservice",
      any('service.name"], attributes["k8s.pod.label.serving.kserve.io/inferenceservice"]' in st for st in svc_stmts))

# 4. Processor order.
def before(a, b):
    return a in chain and b in chain and chain.index(a) < chain.index(b)

check(f"{PROMOTE} runs before k8sattributes pod association",
      before(PROMOTE, "k8sattributes/cw_k8s_ci_v0_pod"))
check(f"set_workload runs before {SERVICE_NAME}",
      before("transform/cw_k8s_ci_v0_set_workload", SERVICE_NAME))
check(f"every processor in {PIPELINE} is defined", all(p in processors for p in chain))

scraper = otel_config(sys.argv[1], "cloudwatch-agent-cluster-scraper")
check("the cluster-scraper does not scrape vLLM",
      RECEIVER not in (scraper.get("receivers") or {}))

# --- solutions.vllm.enabled=false (negative control) -----------------------------
print(f"\n{YELLOW}[solutions.vllm.enabled=false]{RESET}")
off = otel_config(sys.argv[2], "cloudwatch-agent")
check("cloudwatch-agent CR still renders an otelConfig", bool(off))
check(f"no {RECEIVER}", RECEIVER not in (off.get("receivers") or {}))
check(f"no {KEEP} or {PROMOTE}",
      not ({KEEP, PROMOTE} & set(off.get("processors") or {})))
check(f"no {PIPELINE}", PIPELINE not in ((off.get("service") or {}).get("pipelines") or {}))

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
