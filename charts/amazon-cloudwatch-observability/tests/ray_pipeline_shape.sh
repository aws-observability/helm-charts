#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins the shape of the Ray branch of the OTEL Container Insights pipeline
# (otelContainerInsights.solutions.ray).
#
# The scrape job finds Ray pods without configuration, from what KubeRay itself
# writes on every Ray pod. What this script guards:
#
#   1. Discovery is node-scoped and label-scoped by the API server: only this
#      node's pods, and only pods labelled ray.io/is-ray-node=yes. A cluster
#      without Ray finds nothing.
#   2. Only the container port named metrics is scraped (KubeRay declares it,
#      adding metrics:8080 when the pod template has none). The chart reads no
#      scrape labels or annotations of its own from pods; the one annotation read,
#      resource.opentelemetry.io/service.name, names the series and selects nothing.
#   3. Pod identity reaches resource scope before k8sattributes runs, and
#      service.name is not taken from the app.kubernetes.io/name label, which
#      KubeRay sets to "kuberay" on every Ray pod. service.name comes from the
#      chart-wide chain (_service-identity.tpl): the service.name annotation wins
#      when set and not empty, then the workload, then the pod; the chain removes
#      its temporary attributes.
#   4. The vLLM and SGLang jobs drop exactly the pods this job selects
#      (ray.io/is-ray-node=yes), so a Ray image built on a vLLM or SGLang base is
#      not scraped on every port the Ray container declares, and an engine pod with
#      any other value is still scraped.
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text.
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/ray_pipeline_shape.sh

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
        --set "otelContainerInsights.solutions.ray.enabled=$1" "${@:3}" > "$2"
}

render true "${TMP_DIR}/enabled.yaml"
render false "${TMP_DIR}/disabled.yaml"
render true "${TMP_DIR}/logs.yaml" --set otelContainerInsights.logs.enabled=true

python3 - "${TMP_DIR}/enabled.yaml" "${TMP_DIR}/disabled.yaml" "${TMP_DIR}/logs.yaml" <<'PY'
import json
import re
import sys

import yaml

RECEIVER = "prometheus/cw_k8s_ci_v0_ray"
PIPELINE = "metrics/cw_k8s_ci_v0_ray"
KEEP = "filter/cw_k8s_ci_v0_ray_keep"
PROMOTE = "transform/cw_k8s_ci_v0_ray_promote"
SERVICE_NAME = "transform/cw_k8s_ci_v0_service_identity"
SCOPE = "transform/cw_k8s_ci_v0_set_scope_ray"
IMAGE_RECEIVERS = {"vLLM": "prometheus/cw_k8s_ci_v0_vllm", "SGLang": "prometheus/cw_k8s_ci_v0_sglang"}
RAY_NODE = "__meta_kubernetes_pod_label_ray_io_is_ray_node"
ANNOTATION = "__meta_kubernetes_pod_annotation_"
SVC_ANNOTATION = ANNOTATION + "resource_opentelemetry_io_service_name"
SVC_LABEL = "otel_service_name_annotation"
SVC_TMP = "_tmp.service_identity.annotation.service.name"
# Every name the service.name annotation goes by in the config.
SVC_NAMES = ("resource.opentelemetry.io/service.name", "resource_opentelemetry_io_service_name",
             SVC_LABEL, SVC_TMP)
SHARED = ("k8sattributes/cw_k8s_ci_v0_pod", "awsattributelimit/cw_k8s_ci_v0",
          "transform/cw_k8s_ci_v0_logs_set_workload")

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


def reads(rule, label):
    return label in (rule.get("source_labels") or [])


def job_of(cfg, receiver):
    r = (cfg.get("receivers") or {}).get(receiver) or {}
    return ((r.get("config") or {}).get("scrape_configs") or [{}])[0]


def statements(processor, key):
    return [st for g in (processor or {}).get(key) or [] for st in g.get("statements") or []]


def mentions_svc(obj):
    text = json.dumps(obj)
    return any(n in text for n in SVC_NAMES)


# --- solutions.ray.enabled=true ---------------------------------------------------
print(f"\n{YELLOW}[solutions.ray.enabled=true]{RESET}")
cfg = otel_config(sys.argv[1], "cloudwatch-agent")
job = job_of(cfg, RECEIVER)
rules = job.get("relabel_configs") or []
processors = cfg.get("processors") or {}
chain = (((cfg.get("service") or {}).get("pipelines") or {}).get(PIPELINE) or {}).get("processors") or []

# Guards: without these, every assertion below could pass on empty input.
check("cloudwatch-agent CR renders an otelConfig", bool(cfg))
check(f"{RECEIVER} renders with relabel rules", bool(rules))
check(f"{PIPELINE} renders", bool(chain))

# 1. Discovery filtered by the API server, to this node and to Ray pods.
sd = (job.get("kubernetes_sd_configs") or [{}])[0]
selectors = sd.get("selectors") or []
check("pod discovery is field-selected to this node",
      sd.get("role") == "pod" and
      any(s.get("field") == "spec.nodeName=${env:K8S_NODE_NAME}" for s in selectors))
check("pod discovery is label-selected to ray.io/is-ray-node=yes",
      any(s.get("label") == "ray.io/is-ray-node=yes" for s in selectors))

# 2. Only the metrics port; no customer scrape labels or annotations.
port = first(rules, lambda r: r.get("action") == "keep" and
             reads(r, "__meta_kubernetes_pod_container_port_name"))
check("only the container port named metrics is kept",
      port >= 0 and rules[port].get("regex") == "metrics")
check("no relabel rule reads a pod annotation other than resource.opentelemetry.io/service.name",
      not any(l.startswith(ANNOTATION) and l != SVC_ANNOTATION
              for r in rules for l in r.get("source_labels") or []))
svc_rules = [r for r in rules if reads(r, SVC_ANNOTATION)]
check("the service.name annotation is read by one rule, which makes no scrape decision",
      len(svc_rules) == 1 and svc_rules[0].get("source_labels") == [SVC_ANNOTATION]
      and svc_rules[0].get("action") == "replace"
      and not svc_rules[0].get("target_label", "").startswith("__"))
# Prometheus drops a label whose value is empty, so with the default regex and
# replacement an unset or empty annotation leaves no label at all.
check("the service.name annotation is carried as a target label, dropped when empty",
      len(svc_rules) == 1 and svc_rules[0].get("target_label") == SVC_LABEL
      and "regex" not in svc_rules[0] and "replacement" not in svc_rules[0])
check("no relabel rule reads prometheus.io/* or cloudwatch.aws/* from pods",
      not any(("prometheus_io_" in l or "cloudwatch_aws" in l)
              for r in rules for l in r.get("source_labels") or []))
check("init containers are dropped",
      first(rules, lambda r: r.get("action") == "drop" and
            reads(r, "__meta_kubernetes_pod_container_init")) >= 0)

# 3. Metric filter, identity and naming.
keep_stmts = (((processors.get(KEEP) or {}).get("metrics") or {}).get("metric")) or []
check(f"{KEEP} keeps only ray_* series",
      'not IsMatch(name, "^ray_")' in keep_stmts)
check(f"{KEEP} drops summaries", "type == METRIC_DATA_TYPE_SUMMARY" in keep_stmts)
promote_stmts = statements(processors.get(PROMOTE), "metric_statements")
check(f"{PROMOTE} lifts pod and namespace to resource scope",
      any('k8s.pod.name"], attributes["pod"]' in st for st in promote_stmts) and
      any('k8s.namespace.name"], attributes["namespace"]' in st for st in promote_stmts))
check(f"{PROMOTE} carries the service.name annotation to resource scope",
      f'set(resource.attributes["{SVC_TMP}"], attributes["{SVC_LABEL}"]) where attributes["{SVC_LABEL}"] != nil'
      in promote_stmts)
check(f"{PROMOTE} removes the annotation datapoint attribute",
      f'delete_key(attributes, "{SVC_LABEL}")' in promote_stmts)
# Ray serves target_info; the receiver copies its labels, target labels included,
# to resource attributes.
check(f"{PROMOTE} removes the annotation label that target_info copies to the resource",
      f'delete_key(resource.attributes, "{SVC_LABEL}")' in promote_stmts)
check(f"{PROMOTE} sets no aws.service.type (the type is inferred at query time)",
      not any("aws.service.type" in st for st in promote_stmts))
svc = statements(processors.get(SERVICE_NAME), "metric_statements")
R = "resource.attributes"
def source(attr):
    want = f'set({R}["service.name"], {R}["{attr}"])'
    return next((i for i, st in enumerate(svc) if st.startswith(want)), -1)
check("service.name order: annotation, then workload, then pod, then the job name",
      0 <= source(SVC_TMP) < source("k8s.deployment.name") < source("k8s.pod.name")
      < source("_tmp.service_identity.unknown_service"))
check(f"{SERVICE_NAME} does not use app.kubernetes.io/name (\"kuberay\" on every Ray pod)",
      not any("app.kubernetes.io" in st for st in svc))
check("the chain removes its temporary attributes",
      bool(svc) and svc[-1].startswith(f'delete_matching_keys({R}, "^_tmp'))
check(f"in {PIPELINE}, only the promote, pod k8sattributes and service identity read the service.name annotation",
      {n for n in chain if mentions_svc(processors.get(n))} <= {PROMOTE, SHARED[0], SERVICE_NAME})
for name in SHARED[1:2]:
    check(f"{name} does not mention the service.name annotation",
          name in processors and not mentions_svc(processors[name]))
check(f"{SCOPE} sets the Ray scope name",
      'set(scope.name, "github.com/ray-project/ray")' in statements(processors.get(SCOPE), "metric_statements"))

def before(a, b):
    return a in chain and b in chain and chain.index(a) < chain.index(b)

check(f"{PROMOTE} runs before k8sattributes pod association",
      before(PROMOTE, "k8sattributes/cw_k8s_ci_v0_pod"))
check(f"set_workload runs before {SERVICE_NAME}",
      before("transform/cw_k8s_ci_v0_set_workload", SERVICE_NAME))
check(f"every processor in {PIPELINE} is defined", all(p in processors for p in chain))

# 4. The vLLM and SGLang image jobs leave Ray pods to this job.
for engine, receiver in IMAGE_RECEIVERS.items():
    image_rules = job_of(cfg, receiver).get("relabel_configs") or []
    drop = first(image_rules, lambda r: r.get("action") == "drop" and reads(r, RAY_NODE))
    check(f"the {engine} job drops pods labelled ray.io/is-ray-node", drop >= 0)
    if drop >= 0:
        # Prometheus anchors the regex; an absent label relabels as the empty string.
        rx = re.compile(image_rules[drop].get("regex", "(.*)"))
        for value, dropped in [("yes", True), ("", False), ("no", False), ("false", False)]:
            check(f"the {engine} job {'drops' if dropped else 'keeps'} ray.io/is-ray-node={value!r}",
                  bool(rx.fullmatch(value)) == dropped)

# 5. Engine series get their own pipeline from the same scrape, with ai_inference.
ENGINES = "metrics/cw_k8s_ci_v0_ray_engines"
ENGINES_KEEP = "filter/cw_k8s_ci_v0_ray_engines_keep"
SERVICE_TYPE = "transform/cw_k8s_ci_v0_ray_engines_service_type"
pipelines_all = (cfg.get("service") or {}).get("pipelines") or {}
eng_chain = (pipelines_all.get(ENGINES) or {}).get("processors") or []
check(f"{ENGINES} renders and takes {RECEIVER}",
      bool(eng_chain) and (pipelines_all.get(ENGINES) or {}).get("receivers") == [RECEIVER])
ray_keep = ((processors.get(KEEP) or {}).get("metrics") or {}).get("metric") or []
eng_keep = ((processors.get(ENGINES_KEEP) or {}).get("metrics") or {}).get("metric") or []
check(f"{KEEP} drops the engine series", 'IsMatch(name, "^ray_(vllm|sglang)_")' in ray_keep)
check(f"{ENGINES_KEEP} keeps only the engine series", 'not IsMatch(name, "^ray_(vllm|sglang)_")' in eng_keep)
check(f"{SERVICE_TYPE} sets aws.service.type to ai_inference",
      'set(attributes["aws.service.type"], "ai_inference")' in statements(processors.get(SERVICE_TYPE), "metric_statements"))
check(f"only {ENGINES} sets aws.service.type", SERVICE_TYPE in eng_chain and SERVICE_TYPE not in chain)
check(f"{ENGINES} runs the same chain as {PIPELINE} apart from its keep filter and the service type",
      [x for x in eng_chain if x not in (ENGINES_KEEP, SERVICE_TYPE)] == [x for x in chain if x != KEEP])
check(f"every processor in {ENGINES} is defined", all(p in processors for p in eng_chain))

# 6. The pod and namespace target labels, copied to the resource from target_info, are removed.
promote_stmts = statements(processors.get(PROMOTE), "metric_statements")
for key in ("pod", "namespace"):
    check(f"{PROMOTE} deletes the resource {key} target label",
          f'delete_key(resource.attributes, "{key}")' in promote_stmts)

scraper = otel_config(sys.argv[1], "cloudwatch-agent-cluster-scraper")
check("the cluster-scraper does not scrape Ray",
      RECEIVER not in (scraper.get("receivers") or {}))

# --- logs.enabled=true: only the chart-wide chain reads the service.name annotation
print(f"\n{YELLOW}[otelContainerInsights.logs.enabled=true]{RESET}")
logs = otel_config(sys.argv[3], "cloudwatch-agent")
logs_procs = logs.get("processors") or {}
check(f"{SHARED[2]} renders and does not mention the service.name annotation",
      SHARED[2] in logs_procs and not mentions_svc(logs_procs[SHARED[2]]))
logs_chains = [n for k, v in ((logs.get("service") or {}).get("pipelines") or {}).items()
               if k.startswith("logs/") for n in (v or {}).get("processors") or []]
check("logs pipelines render, and read the service.name annotation only in the chart-wide chain",
      bool(logs_chains) and not any(mentions_svc(logs_procs.get(n)) for n in logs_chains
                                    if not (n.startswith("k8sattributes/") or "service_identity" in n)))

# --- solutions.ray.enabled=false (negative control) ------------------------------
print(f"\n{YELLOW}[solutions.ray.enabled=false]{RESET}")
off = otel_config(sys.argv[2], "cloudwatch-agent")
check("cloudwatch-agent CR still renders an otelConfig", bool(off))
check(f"no {RECEIVER}", RECEIVER not in (off.get("receivers") or {}))
check(f"no {KEEP}, {PROMOTE} or Ray engines service type",
      not ({KEEP, PROMOTE, "transform/cw_k8s_ci_v0_ray_engines_service_type"} & set(off.get("processors") or {})))
check(f"no {PIPELINE} or {ENGINES}",
      not ({PIPELINE, ENGINES} & set((off.get("service") or {}).get("pipelines") or {})))

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
