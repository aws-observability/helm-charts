#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins the shape of the SGLang branch of the OTEL Container Insights pipeline
# (otelContainerInsights.solutions.sglang).
#
# SGLang servers are found without configuration: a container running an SGLang
# image (this job), or the model container of a KServe predictor (the shared
# KServe model-server receiver, pinned by model_server_pipeline_shape.sh). What
# this script guards:
#
#   1. Discovery stays node-scoped: the image match cannot be done by the API
#      server, so an unscoped watch would hold every pod in the cluster on
#      every agent.
#   2. Only the image selects targets, KServe predictors are left to the shared
#      receiver, and the chart reads no scrape labels or annotations of its own
#      (prometheus.io/*, cloudwatch.aws/*) from pods.
#   3. Port: declared port > sglang.launch_server's 30000.
#   4. service.name from the chart-wide service identity chain
#      (_service-identity.tpl): annotation, then the InferenceService, then
#      workload; no app.kubernetes.io/* label step by default.
#   5. Pod identity reaches resource scope before k8sattributes runs.
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text.
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/sglang_pipeline_shape.sh

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
        --set "otelContainerInsights.solutions.sglang.enabled=$1" > "$2"
}

render true "${TMP_DIR}/enabled.yaml"
render false "${TMP_DIR}/disabled.yaml"

python3 - "${TMP_DIR}/enabled.yaml" "${TMP_DIR}/disabled.yaml" <<'PY'
import sys

import yaml

RECEIVER = "prometheus/cw_k8s_ci_v0_sglang"
PIPELINE = "metrics/cw_k8s_ci_v0_sglang"
KEEP = "filter/cw_k8s_ci_v0_sglang_keep"
PROMOTE = "transform/cw_k8s_ci_v0_sglang_promote"
SERVICE_NAME = "transform/cw_k8s_ci_v0_service_identity"
IMAGE = "__meta_kubernetes_pod_container_image"
ANNOTATION = "__meta_kubernetes_pod_annotation_"
SVC_ANNOTATION = ANNOTATION + "resource_opentelemetry_io_service_name"

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


def statements(processors, name):
    return [st for g in (processors.get(name) or {}).get("metric_statements") or []
            for st in g.get("statements") or []]


def job_rules(cfg, receiver):
    rcv = (cfg.get("receivers") or {}).get(receiver) or {}
    job = ((rcv.get("config") or {}).get("scrape_configs") or [{}])[0]
    return job, job.get("relabel_configs") or []


# --- solutions.sglang.enabled=true ----------------------------------------------
print(f"\n{YELLOW}[solutions.sglang.enabled=true]{RESET}")
cfg = otel_config(sys.argv[1], "cloudwatch-agent")
job, rules = job_rules(cfg, RECEIVER)
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

# 2. Target selection: the SGLang image, outside KServe predictors. Predictors are
#    scraped by the shared KServe model-server receiver (model_server_pipeline_shape.sh).
ISVC = "__meta_kubernetes_pod_label_serving_kserve_io_inferenceservice"
check("the first rule keeps only SGLang images",
      bool(rules) and rules[0].get("action") == "keep" and rules[0]["source_labels"] == [IMAGE]
      and rules[0].get("regex") == "(?i).*sglang.*")
check("KServe predictors are dropped (the shared receiver scrapes them)",
      any(r.get("action") == "drop" and r.get("source_labels") == [ISVC, "__meta_kubernetes_pod_label_component",
          "__meta_kubernetes_pod_container_name"] and r.get("regex") == ".+;predictor;kserve-container" for r in rules))
check("no relabel rule reads prometheus.io/* or cloudwatch.aws/* from pods",
      not any(("prometheus_io_" in l or "cloudwatch_aws" in l)
              for r in rules for l in r.get("source_labels") or []))
check(f"{PIPELINE} also takes the shared KServe model-server receiver",
      "prometheus/cw_k8s_ci_v0_kserve_model_server" in
      ((((cfg.get("service") or {}).get("pipelines") or {}).get(PIPELINE) or {}).get("receivers") or []))

# 3. Port: declared, else sglang.launch_server's 30000.
port_rules = [i for i, r in enumerate(rules) if writes(r, "__tmp_port")]
address = first(rules, lambda r: writes(r, "__address__"))
check("an undeclared port defaults to 30000",
      any(writes(r, "__tmp_port") and r.get("replacement") == "30000" for r in rules))
check("__address__ is set after every port rule",
      address >= 0 and all(i < address for i in port_rules))

# 4. service.name: annotation > InferenceService > workload > pod, no app.kubernetes.io/* labels.
svc_rule = first(rules, lambda r: reads(r, SVC_ANNOTATION))
check("the service.name annotation is carried as a target label",
      svc_rule >= 0 and rules[svc_rule].get("target_label") == "otel_service_name_annotation")
promote = statements(processors, PROMOTE)
check(f"{PROMOTE} sets aws.service.type to ai_inference",
      'set(resource.attributes["aws.service.type"], "ai_inference")' in promote)
check(f"{PROMOTE} removes the annotation datapoint attribute",
      'delete_key(attributes, "otel_service_name_annotation")' in promote)
check(f"{PROMOTE} carries the scraped service.name annotation into the chain's annotation input",
      any(st.startswith('set(resource.attributes["_tmp.service_identity.annotation.service.name"], attributes["otel_service_name_annotation"])') for st in promote))
svc = statements(processors, SERVICE_NAME)
R = "resource.attributes"
def source(attr):
    want = f'set({R}["service.name"], {R}["{attr}"])'
    return next((i for i, st in enumerate(svc) if st.startswith(want)), -1)
check("service.name order: annotation, then InferenceService, then workload, then the job name",
      0 <= source("_tmp.service_identity.annotation.service.name") < source("k8s.pod.label.serving.kserve.io/inferenceservice")
      < source("k8s.deployment.name") < source("_tmp.service_identity.unknown_service"))
check("the chain removes its temporary attributes",
      bool(svc) and svc[-1].startswith(f'delete_matching_keys({R}, "^_tmp'))
check("service.name does not use the app.kubernetes.io/* labels",
      not any("app.kubernetes.io" in st for st in svc))
check("no relabel rule reads an aws.service.type pod label",
      not any("aws_service_type" in l for r in rules for l in r.get("source_labels") or []))

# 5. Processor order.
def before(a, b):
    return a in chain and b in chain and chain.index(a) < chain.index(b)

check(f"{KEEP} runs first after scrape metadata", before(KEEP, PROMOTE))
check(f"{PROMOTE} runs before k8sattributes pod association",
      before(PROMOTE, "k8sattributes/cw_k8s_ci_v0_pod"))
check(f"set_workload runs before {SERVICE_NAME}",
      before("transform/cw_k8s_ci_v0_set_workload", SERVICE_NAME))
check(f"every processor in {PIPELINE} is defined", all(p in processors for p in chain))

scraper = otel_config(sys.argv[1], "cloudwatch-agent-cluster-scraper")
check("the cluster-scraper does not scrape SGLang",
      RECEIVER not in (scraper.get("receivers") or {}))

# --- solutions.sglang.enabled=false (negative control) ---------------------------
print(f"\n{YELLOW}[solutions.sglang.enabled=false]{RESET}")
off = otel_config(sys.argv[2], "cloudwatch-agent")
check("cloudwatch-agent CR still renders an otelConfig", bool(off))
check(f"no {RECEIVER}", RECEIVER not in (off.get("receivers") or {}))
# The service identity processor is shared by every node metrics pipeline, so it stays.
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
