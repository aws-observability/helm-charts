#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins the shape of the shared KServe model-server receiver
# (prometheus/cw_k8s_ci_v0_kserve_model_server), which scrapes the model container
# of every KServe predictor once and feeds every model-server pipeline (vLLM,
# SGLang). KServe does not label the engine, so each pipeline keeps the series of
# its own engine by metric name. What this script guards:
#
#   1. Discovery stays node-scoped and selects only a predictor's
#      kserve-container, whatever its image; the chart reads no scrape labels or
#      annotations of its own (prometheus.io/*, cloudwatch.aws/*) from pods.
#   2. Port precedence: prometheus.kserve.io/port (the serving runtime's) >
#      declared port > KServe's 8080. Relabel rules are applied in order and
#      later writes win, so the order of the rules is the precedence.
#   3. Routing: the receiver feeds the vLLM and SGLang pipelines, each keeping
#      only its own prefix, and the image jobs leave predictors to it, so a
#      predictor is scraped once.
#   4. Every engine pipeline derives service.name the same way, and the image
#      jobs leave KubeRay pods alone.
#   5. The receiver renders when either solution is on, and not when both are off.
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text.
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/model_server_pipeline_shape.sh

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
        --set "otelContainerInsights.solutions.vllm.enabled=$1" \
        --set "otelContainerInsights.solutions.sglang.enabled=$2" > "$3"
}

render true true "${TMP_DIR}/both.yaml"
render true false "${TMP_DIR}/vllm.yaml"
render false true "${TMP_DIR}/sglang.yaml"
render false false "${TMP_DIR}/none.yaml"

python3 - "${TMP_DIR}" <<'PY'
import os
import sys

import yaml

RECEIVER = "prometheus/cw_k8s_ci_v0_kserve_model_server"
PIPELINES = {"vllm": "metrics/cw_k8s_ci_v0_vllm", "sglang": "metrics/cw_k8s_ci_v0_sglang"}
KEEP = {"vllm": "filter/cw_k8s_ci_v0_vllm_keep", "sglang": "filter/cw_k8s_ci_v0_sglang_keep"}
KEEP_PREFIX = {"vllm": "^(vllm:|http_).*", "sglang": "^sglang:.*"}
ISVC = "__meta_kubernetes_pod_label_serving_kserve_io_inferenceservice"
PREDICTOR = [ISVC, "__meta_kubernetes_pod_label_component", "__meta_kubernetes_pod_container_name"]
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


def otel_config(name):
    """otelConfig of the cloudwatch-agent CR in the named render, parsed."""
    with open(os.path.join(sys.argv[1], name)) as f:
        for doc in yaml.safe_load_all(f):
            if (doc or {}).get("kind") == "AmazonCloudWatchAgent" and \
                    doc["metadata"]["name"] == "cloudwatch-agent":
                return yaml.safe_load(doc["spec"].get("otelConfig") or "{}") or {}
    return {}


def first(rules, pred):
    return next((i for i, r in enumerate(rules) if pred(r)), -1)


def writes(rule, label):
    return rule.get("target_label") == label


def reads(rule, label):
    return label in (rule.get("source_labels") or [])


def job_rules(cfg, receiver):
    rcv = (cfg.get("receivers") or {}).get(receiver) or {}
    job = ((rcv.get("config") or {}).get("scrape_configs") or [{}])[0]
    return job, job.get("relabel_configs") or []


def pipelines(cfg):
    return (cfg.get("service") or {}).get("pipelines") or {}


# --- both solutions on --------------------------------------------------------
print(f"\n{YELLOW}[vllm and sglang enabled]{RESET}")
cfg = otel_config("both.yaml")
job, rules = job_rules(cfg, RECEIVER)
check(f"{RECEIVER} renders with relabel rules", bool(rules))

# 1. Node-scoped discovery of predictor model containers, whatever the image.
sd = (job.get("kubernetes_sd_configs") or [{}])[0]
check("pod discovery is field-selected to this node",
      sd.get("role") == "pod" and
      any(s.get("field") == "spec.nodeName=${env:K8S_NODE_NAME}" for s in sd.get("selectors") or []))
check("the first rule keeps only a predictor's kserve-container",
      bool(rules) and rules[0].get("action") == "keep" and rules[0].get("source_labels") == PREDICTOR
      and rules[0].get("regex") == ".+;predictor;kserve-container")
check("no rule reads the container image (the engine comes from the metric names)",
      not any(reads(r, "__meta_kubernetes_pod_container_image") for r in rules))
check("no relabel rule reads prometheus.io/* or cloudwatch.aws/* from pods",
      not any(("prometheus_io_" in l or "cloudwatch_aws" in l)
              for r in rules for l in r.get("source_labels") or []))

# 2. Port and path precedence, encoded as rule order.
port_rules = [i for i, r in enumerate(rules) if writes(r, "__tmp_port")]
ks_port = first(rules, lambda r: writes(r, "__tmp_port") and reads(r, ANNOTATION + "prometheus_kserve_io_port"))
ks_path = first(rules, lambda r: writes(r, "__metrics_path__") and reads(r, ANNOTATION + "prometheus_kserve_io_path"))
address = first(rules, lambda r: writes(r, "__address__"))
check("an undeclared port defaults to KServe's 8080",
      any(writes(r, "__tmp_port") and r.get("replacement") == "8080" for r in rules))
check("prometheus.kserve.io/port is applied after the default, so it wins",
      ks_port >= 0 and port_rules[-1] == ks_port)
check("prometheus.kserve.io/path sets the metrics path", ks_path >= 0)
check("__address__ is set after every port rule",
      address >= 0 and all(i < address for i in port_rules))
check("annotation rules use the default replacement (no $ to escape)",
      all("replacement" not in rules[i] for i in (ks_port, ks_path) if i >= 0))
check("pod and namespace are carried for k8sattributes",
      any(writes(r, "pod") for r in rules) and any(writes(r, "namespace") for r in rules))

# 3. Routing by metric name; each predictor scraped once.
pls = pipelines(cfg)
processors = cfg.get("processors") or {}
for engine, pl in PIPELINES.items():
    chain = (pls.get(pl) or {}).get("processors") or []
    check(f"{pl} takes {RECEIVER}", RECEIVER in ((pls.get(pl) or {}).get("receivers") or []))
    keep = ((processors.get(KEEP[engine]) or {}).get("metrics") or {}).get("metric") or []
    check(f"{KEEP[engine]} keeps only {KEEP_PREFIX[engine]}",
          f'not IsMatch(name, "{KEEP_PREFIX[engine]}")' in keep)
    check(f"{KEEP[engine]} runs before the series are enriched",
          KEEP[engine] in chain and chain.index(KEEP[engine]) < chain.index("k8sattributes/cw_k8s_ci_v0_pod"))
    _, img = job_rules(cfg, f"prometheus/cw_k8s_ci_v0_{engine}")
    check(f"the {engine} image job leaves KServe predictors to {RECEIVER}",
          any(r.get("action") == "drop" and r.get("source_labels") == PREDICTOR for r in img))
check("no other receiver scrapes KServe predictors",
      not any(name not in (RECEIVER, "prometheus/cw_k8s_ci_v0_vllm", "prometheus/cw_k8s_ci_v0_sglang")
              and any(r.get("action") == "keep" and r.get("source_labels") == PREDICTOR
                      for r in job_rules(cfg, name)[1])
              for name in cfg.get("receivers") or {} if name.startswith("prometheus/")))
for engine, pl in PIPELINES.items():
    promote = [st for g in (processors.get(f"transform/cw_k8s_ci_v0_{engine}_promote") or {}).get("metric_statements") or []
               for st in g.get("statements") or []]
    check(f"the {engine} promote removes the service.name annotation datapoint attribute",
          'delete_key(attributes, "otel_service_name_annotation")' in promote)

svc = {e: [st for g in (processors.get(f"transform/cw_k8s_ci_v0_{e}_service_name") or {}).get("metric_statements") or []
           for st in g.get("statements") or []] for e in PIPELINES}
check("every engine pipeline derives service.name with the same statements",
      bool(svc["vllm"]) and svc["vllm"] == svc["sglang"])
for engine in PIPELINES:
    _, img = job_rules(cfg, f"prometheus/cw_k8s_ci_v0_{engine}")
    check(f"the {engine} image job leaves KubeRay pods to a Ray scrape",
          any(r.get("action") == "drop" and r.get("source_labels") == ["__meta_kubernetes_pod_label_ray_io_is_ray_node"]
              and r.get("regex") == "yes" for r in img))

# 4. Toggles.
print(f"\n{YELLOW}[toggles]{RESET}")
for name, on in (("vllm.yaml", "vllm"), ("sglang.yaml", "sglang")):
    c = otel_config(name)
    off = "sglang" if on == "vllm" else "vllm"
    check(f"only {on} on: {RECEIVER} renders and feeds {PIPELINES[on]} only",
          RECEIVER in (c.get("receivers") or {}) and
          RECEIVER in ((pipelines(c).get(PIPELINES[on]) or {}).get("receivers") or []) and
          PIPELINES[off] not in pipelines(c))
none = otel_config("none.yaml")
check("cloudwatch-agent CR renders with both off", bool(none))
check(f"both off: no {RECEIVER}", RECEIVER not in (none.get("receivers") or {}))

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
