#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins the shape of the vLLM branch of the OTEL Container Insights pipeline
# (otelContainerInsights.solutions.vllm).
#
# vLLM servers are found without configuration: a container running a vLLM image
# (this job), or the model container of a KServe predictor (the shared KServe
# model-server receiver, pinned by model_server_pipeline_shape.sh). What this
# script guards:
#
#   1. Discovery stays node-scoped: the image match cannot be done by the API
#      server, so an unscoped watch would hold every pod in the cluster on
#      every agent.
#   2. Only the image selects targets, KServe predictors are left to the shared
#      receiver, and the chart reads no scrape labels or annotations of its own
#      (prometheus.io/*, cloudwatch.aws/*) from pods.
#   3. Port: declared port > vllm serve's 8000.
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
SERVICE_NAME = "transform/cw_k8s_ci_v0_service_identity"
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

# 2. Target selection: the vLLM image, outside KServe predictors. Predictors are
#    scraped by the shared KServe model-server receiver (model_server_pipeline_shape.sh).
IMAGE = "__meta_kubernetes_pod_container_image"
check("the first rule keeps only vLLM images",
      bool(rules) and rules[0].get("action") == "keep" and rules[0]["source_labels"] == [IMAGE]
      and rules[0].get("regex") == "(?i).*vllm.*")
check("KServe predictors are dropped (the shared receiver scrapes them)",
      any(r.get("action") == "drop" and r.get("source_labels") == [ISVC, "__meta_kubernetes_pod_label_component",
          "__meta_kubernetes_pod_container_name"] and r.get("regex") == ".+;predictor;kserve-container" for r in rules))
check("no relabel rule reads prometheus.io/* or cloudwatch.aws/* from pods",
      not any(("prometheus_io_" in l or "cloudwatch_aws" in l)
              for r in rules for l in r.get("source_labels") or []))
check(f"{PIPELINE} also takes the shared KServe model-server receiver",
      "prometheus/cw_k8s_ci_v0_kserve_model_server" in
      ((((cfg.get("service") or {}).get("pipelines") or {}).get(PIPELINE) or {}).get("receivers") or []))

# 3. Port: declared, else vllm serve's 8000.
port_rules = [i for i, r in enumerate(rules) if writes(r, "__tmp_port")]
address = first(rules, lambda r: writes(r, "__address__"))
check("an undeclared port defaults to 8000",
      any(writes(r, "__tmp_port") and r.get("replacement") == "8000" for r in rules))
check("__address__ is set after every port rule",
      address >= 0 and all(i < address for i in port_rules))

# aws.service.type is fixed by the chart, never read from the pod.
check("no relabel rule reads an aws.service.type pod label",
      not any("aws_service_type" in l for r in rules for l in r.get("source_labels") or []))
promote_stmts = [st for g in (processors.get(PROMOTE) or {}).get("metric_statements") or []
                 for st in g.get("statements") or []]
check(f"{PROMOTE} sets aws.service.type to ai_inference",
      'set(resource.attributes["aws.service.type"], "ai_inference")' in promote_stmts)

# No new attribute key for the InferenceService: service.name comes from KServe's
# own pod label as extracted by k8sattributes (k8s.pod.label.*), through the
# chart's service identity chain (_service-identity.tpl).
check("no relabel rule creates an inferenceservice label",
      not any(r.get("target_label") == "inferenceservice" for r in rules))
check(f"{PROMOTE} does not set a custom inferenceservice attribute",
      not any('"inferenceservice"' in st for st in promote_stmts))
svc_stmts = [st for g in (processors.get(SERVICE_NAME) or {}).get("metric_statements") or []
             for st in g.get("statements") or []]
R = 'resource.attributes'
def source(attr):
    """Index of the statement that sets service.name from the resource attribute attr."""
    want = f'set({R}["service.name"], {R}["{attr}"])'
    return next((i for i, st in enumerate(svc_stmts) if st.startswith(want)), -1)
annotation = source("_tmp.service_identity.annotation.service.name")
isvc = source("k8s.pod.label.serving.kserve.io/inferenceservice")
deployment = source("k8s.deployment.name")
job_name = source("_tmp.service_identity.unknown_service")
check(f"{SERVICE_NAME} takes the InferenceService name from k8s.pod.label.serving.kserve.io/inferenceservice",
      isvc >= 0)
check("service.name order: annotation, then InferenceService, then workload, then the job name",
      0 <= annotation < isvc < deployment < job_name)
# The Prometheus receiver sets service.name to the job name (vllm); it counts as not set.
check(f"{SERVICE_NAME} sets the receiver's service.name aside whenever it is set",
      bool(svc_stmts) and svc_stmts[0] == f'set({R}["_tmp.service_identity.unknown_service"], {R}["service.name"]) where {R}["service.name"] != nil')
# The receiver's service.instance.id (the target address) is always set aside,
# with no k8s.pod.name guard, and restored only where service.name ended up as
# the receiver's job name.
SAVED_ID = f'{R}["_tmp.service_identity.receiver.service.instance.id"]'
JOB = f'{R}["_tmp.service_identity.unknown_service"]'
aside = f'set({SAVED_ID}, {R}["service.instance.id"]) where {R}["service.instance.id"] != nil'
drop = f'delete_key({R}, "service.instance.id")'
restore = (f'set({R}["service.instance.id"], {SAVED_ID}) where {R}["service.instance.id"] == nil'
           f' and {R}["service.name"] == {JOB} and {SAVED_ID} != nil')
check(f"{SERVICE_NAME} sets the receiver's service.instance.id aside unconditionally",
      aside in svc_stmts and drop in svc_stmts and svc_stmts.index(aside) + 1 == svc_stmts.index(drop))
check("no service.instance.id statement is guarded on k8s.pod.name",
      not any("k8s.pod.name\"] != nil" in st for st in svc_stmts
              if "receiver.service.instance.id" in st or st.startswith(f'delete_key({R}, "service.instance.id")')))
name_stmts = [i for i, st in enumerate(svc_stmts) if st.startswith(f'set({R}["service.name"]')]
check("the receiver's service.instance.id is restored only where service.name is the job name, after every service.name statement and before the cleanup",
      restore in svc_stmts and name_stmts and max(name_stmts) < svc_stmts.index(restore) < len(svc_stmts) - 1
      and svc_stmts[-1].startswith(f'delete_matching_keys({R}')
      and sum(1 for st in svc_stmts if st.startswith(f'set({R}["service.instance.id"], {SAVED_ID})')) == 1)
check("transform/cw_k8s_ci_v0_vllm_service_name is gone",
      "transform/cw_k8s_ci_v0_vllm_service_name" not in processors)
check(f"{PROMOTE} carries the scraped service.name annotation into the chain's annotation input",
      any(st.startswith('set(resource.attributes["_tmp.service_identity.annotation.service.name"], attributes["otel_service_name_annotation"])') for st in promote_stmts))

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
