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
#      scrape labels or annotations of its own from pods.
#   3. Pod identity reaches resource scope before k8sattributes runs, and
#      service.name is not taken from the app.kubernetes.io/name label, which
#      KubeRay sets to "kuberay" on every Ray pod. The customer's
#      resource.opentelemetry.io/service.name pod annotation wins (DR-0001), and the
#      extracted annotation reaches no other signal.
#   4. The vLLM job drops exactly the pods this job selects (ray.io/is-ray-node=yes),
#      so a Ray image built on a vLLM base is not scraped on every port the Ray
#      container declares, and a vLLM pod with any other value is still scraped.
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
import re
import sys

import yaml

RECEIVER = "prometheus/cw_k8s_ci_v0_ray"
PIPELINE = "metrics/cw_k8s_ci_v0_ray"
KEEP = "filter/cw_k8s_ci_v0_ray_keep"
PROMOTE = "transform/cw_k8s_ci_v0_ray_promote"
SERVICE_NAME = "transform/cw_k8s_ci_v0_ray_service_name"
SCOPE = "transform/cw_k8s_ci_v0_set_scope_ray"
VLLM_RECEIVER = "prometheus/cw_k8s_ci_v0_vllm"
RAY_NODE = "__meta_kubernetes_pod_label_ray_io_is_ray_node"
ANNOTATION = "k8s.pod.annotation.resource.opentelemetry.io/service.name"

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
check("no relabel rule reads a pod annotation",
      not any("__meta_kubernetes_pod_annotation" in l
              for r in rules for l in r.get("source_labels") or []))
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
check(f"{PROMOTE} sets no aws.service.type (the type is inferred at query time)",
      not any("aws.service.type" in st for st in promote_stmts))
svc_stmts = statements(processors.get(SERVICE_NAME), "metric_statements")
check(f"{SERVICE_NAME} falls back to the pod name, then the workload name",
      len(svc_stmts) >= 2 and 'attributes["k8s.pod.name"]' in svc_stmts[0]
      and 'attributes["k8s.workload.name"]' in svc_stmts[1])
check(f"{SERVICE_NAME} does not use app.kubernetes.io/name (\"kuberay\" on every Ray pod)",
      not any("app.kubernetes.io" in st for st in svc_stmts))
# DR-0001: the customer's resource.opentelemetry.io/service.name annotation wins.
pod_k8s = processors.get("k8sattributes/cw_k8s_ci_v0_pod") or {}
check("k8sattributes/cw_k8s_ci_v0_pod extracts the service.name annotation",
      any(a.get("key") == "resource.opentelemetry.io/service.name" and a.get("tag_name") == ANNOTATION
          and a.get("from") == "pod" for a in (pod_k8s.get("extract") or {}).get("annotations") or []))
svc_sets = [st for st in svc_stmts if st.startswith('set(attributes["service.name"]')]
check(f"{SERVICE_NAME} applies the annotation last, so it wins, and only when non-empty",
      bool(svc_sets) and f'attributes["{ANNOTATION}"] != ""' in svc_sets[-1])
check(f"{SERVICE_NAME} removes the extracted annotation",
      f'delete_key(attributes, "{ANNOTATION}")' in svc_stmts)
limit = processors.get("awsattributelimit/cw_k8s_ci_v0") or {}
check("awsattributelimit removes the extracted annotation from every other metrics pipeline",
      ANNOTATION in (limit.get("unconditional_removal_keys") or []))
check(f"{SCOPE} sets the Ray scope name",
      'set(scope.name, "github.com/ray-project/ray")' in statements(processors.get(SCOPE), "metric_statements"))

def before(a, b):
    return a in chain and b in chain and chain.index(a) < chain.index(b)

check(f"{PROMOTE} runs before k8sattributes pod association",
      before(PROMOTE, "k8sattributes/cw_k8s_ci_v0_pod"))
check(f"set_workload runs before {SERVICE_NAME}",
      before("transform/cw_k8s_ci_v0_set_workload", SERVICE_NAME))
check(f"every processor in {PIPELINE} is defined", all(p in processors for p in chain))

# 4. The vLLM job leaves Ray pods to this job.
vllm_rules = job_of(cfg, VLLM_RECEIVER).get("relabel_configs") or []
drop = first(vllm_rules, lambda r: r.get("action") == "drop" and reads(r, RAY_NODE))
check("the vLLM job drops pods labelled ray.io/is-ray-node", drop >= 0)
if drop >= 0:
    # Prometheus anchors the regex; an absent label relabels as the empty string.
    rx = re.compile(vllm_rules[drop].get("regex", "(.*)"))
    for value, dropped in [("yes", True), ("", False), ("no", False), ("false", False)]:
        check(f"the vLLM job {'drops' if dropped else 'keeps'} ray.io/is-ray-node={value!r}",
              bool(rx.fullmatch(value)) == dropped)

scraper = otel_config(sys.argv[1], "cloudwatch-agent-cluster-scraper")
check("the cluster-scraper does not scrape Ray",
      RECEIVER not in (scraper.get("receivers") or {}))

# --- logs.enabled=true: app logs do not carry the extracted annotation -----------
print(f"\n{YELLOW}[otelContainerInsights.logs.enabled=true]{RESET}")
logs = otel_config(sys.argv[3], "cloudwatch-agent")
app_chain = (((logs.get("service") or {}).get("pipelines") or {}).get("logs/cw_k8s_ci_v0_app") or {}).get("processors") or []
logs_workload = "transform/cw_k8s_ci_v0_logs_set_workload"
check("the app logs pipeline uses the shared pod k8sattributes, then the logs workload transform",
      "k8sattributes/cw_k8s_ci_v0_pod" in app_chain and logs_workload in app_chain and
      app_chain.index("k8sattributes/cw_k8s_ci_v0_pod") < app_chain.index(logs_workload))
check(f"{logs_workload} removes the extracted annotation",
      f'delete_key(attributes, "{ANNOTATION}")' in
      statements((logs.get("processors") or {}).get(logs_workload), "log_statements"))

# --- solutions.ray.enabled=false (negative control) ------------------------------
print(f"\n{YELLOW}[solutions.ray.enabled=false]{RESET}")
off = otel_config(sys.argv[2], "cloudwatch-agent")
check("cloudwatch-agent CR still renders an otelConfig", bool(off))
check(f"no {RECEIVER}", RECEIVER not in (off.get("receivers") or {}))
check(f"no {KEEP}, {PROMOTE} or {SERVICE_NAME}",
      not ({KEEP, PROMOTE, SERVICE_NAME} & set(off.get("processors") or {})))
check(f"no {PIPELINE}", PIPELINE not in ((off.get("service") or {}).get("pipelines") or {}))

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
