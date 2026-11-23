#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins the shape of the Neuron branch of the OTEL Container Insights pipeline.
#
# On a node running more than one Neuron runtime, neuron-monitor reports every
# core from every runtime -- the owning runtime publishes the real value, the
# others publish 0 for that same core. runtime_tag is the only attribute
# separating those datapoints. Two things in this template used to destroy it:
#
#   1. groupbyattrs/cw_k8s_ci_v0_neuron did not group on runtime_tag, so every
#      runtime on the node landed in one ResourceMetrics.
#   2. transform/cw_k8s_ci_v0_neuron_promote ran in `context: datapoint` while
#      writing resource attributes. Resource attributes are per-ResourceMetrics,
#      so the statement ran once per datapoint and the last write won -- then it
#      deleted runtime_tag from the datapoint.
#
# The agent drops no datapoints: the export still carries one datapoint per
# (core, runtime). But the two datapoints for a core leave the agent with the
# same label set, so the backend collapses them into one series, and for one
# core the survivor is a legitimate-looking 0. The queryable surface shows too
# FEW series rather than an error -- cardinality is the signal, which is why
# nothing in this repo caught it, and why this script asserts structure rather
# than output size.
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text, so
# they are independent of key order, line folding and string escaping.
#
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/neuron_pipeline_shape.sh

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
        --set "neuronMonitor.enabled=$1" > "$2"
}

render true "${TMP_DIR}/enabled.yaml"
render false "${TMP_DIR}/disabled.yaml"

python3 - "${TMP_DIR}/enabled.yaml" "${TMP_DIR}/disabled.yaml" <<'PY'
import re
import sys

import yaml

AGENT = "cloudwatch-agent"
PIPELINE = "metrics/cw_k8s_ci_v0_neuron"
GROUPBY = "groupbyattrs/cw_k8s_ci_v0_neuron"
PROMOTE = "transform/cw_k8s_ci_v0_neuron_promote"
# Exact statements, in order. Order is load-bearing: in resource context
# `attributes` is the resource map, so a delete_key that runs first makes the
# set's guard false and the rename never happens -- the two per-runtime
# ResourceMetrics become identical again.
PROMOTE_STATEMENTS = [
    'set(attributes["aws.neuron.runtime.tag"], attributes["runtime_tag"]) where attributes["runtime_tag"] != nil',
    'delete_key(attributes, "runtime_tag") where attributes["runtime_tag"] != nil',
]
RESOURCE_WRITE = re.compile(r'resource\.attributes\[')

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


def otel_config(path):
    """otelConfig of the cloudwatch-agent CR, selected by name, parsed."""
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if (doc or {}).get("kind") == "AmazonCloudWatchAgent" and \
                    doc["metadata"]["name"] == AGENT:
                return yaml.safe_load(doc["spec"].get("otelConfig") or "{}") or {}
    return {}


def statement_groups(processor):
    return (processor or {}).get("metric_statements") or []


# --- neuronMonitor.enabled=true -------------------------------------------------
print(f"\n{YELLOW}[neuronMonitor.enabled=true]{RESET}")
cfg = otel_config(sys.argv[1])
processors = cfg.get("processors") or {}
pipeline = ((cfg.get("service") or {}).get("pipelines") or {}).get(PIPELINE) or {}
chain = pipeline.get("processors") or []
groupby = processors.get(GROUPBY)
promote = processors.get(PROMOTE)

# Guards: without these, every assertion below could pass on empty input.
check(f"{AGENT} CR renders an otelConfig", bool(cfg))
check(f"{PIPELINE} renders", bool(chain))
check(f"{GROUPBY} renders", groupby is not None)
check(f"{PROMOTE} renders", promote is not None)

# 1. runtime_tag must be a grouping key: this is what gives each runtime its own
#    ResourceMetrics so the per-core datapoints can no longer collide.
check("runtime_tag is a groupbyattrs grouping key",
      "runtime_tag" in ((groupby or {}).get("keys") or []))

# 2. The promote runs after groupbyattrs (runtime_tag is on the resource only
#    from then on) and is exactly the rename then the cleanup, in resource
#    context, with their guards. The pod/namespace/container promotions that
#    used to live here were unreachable -- groupbyattrs already moved those keys
#    onto the resource -- and re-adding them in datapoint context would
#    reintroduce the defect.
check(f"{PROMOTE} runs after {GROUPBY}",
      GROUPBY in chain and PROMOTE in chain and chain.index(GROUPBY) < chain.index(PROMOTE))
groups = statement_groups(promote)
check("promote has a single statement group in resource context",
      [g.get("context") for g in groups] == ["resource"])
check("promote statements are exactly rename-then-delete, with guards, in order",
      len(groups) == 1 and groups[0].get("statements") == PROMOTE_STATEMENTS)

# 3. No processor used only by the Neuron pipeline writes resource attributes
#    from a non-resource context. Selected by pipeline membership, not by name, so
#    a Neuron-only processor is covered whatever it is called. Processors shared
#    with other pipelines are excluded: several write resource attributes from
#    datapoint context with values that are the same for every datapoint.
pipelines = (cfg.get("service") or {}).get("pipelines") or {}
neuron_only = [
    name for name in chain
    if [n for n, p in pipelines.items() if name in (p.get("processors") or [])] == [PIPELINE]
]
check(f"{PROMOTE} is among the processors used only by {PIPELINE}",
      PROMOTE in neuron_only)
offenders = [
    f"{name}: {stmt}"
    for name in neuron_only
    for group in statement_groups(processors.get(name)) if group.get("context") != "resource"
    for stmt in group.get("statements") or [] if RESOURCE_WRITE.search(stmt)
]
check(f"no processor used only by {PIPELINE} writes resource.attributes outside resource context",
      not offenders)
for o in offenders:
    print(f"        {o}")

# 4. Every processor the pipeline references is defined.
check(f"every processor in {PIPELINE} is defined",
      all(p in processors for p in chain))

# --- neuronMonitor.enabled=false (negative control) -----------------------------
# Without this, renaming the processor keys would make the checks above fail
# loudly but say nothing about whether the gate works.
print(f"\n{YELLOW}[neuronMonitor.enabled=false]{RESET}")
off = otel_config(sys.argv[2])
off_processors = off.get("processors") or {}
off_pipelines = (off.get("service") or {}).get("pipelines") or {}
check(f"{AGENT} CR still renders an otelConfig", bool(off))
check(f"no {GROUPBY} when neuronMonitor is off", GROUPBY not in off_processors)
check(f"no {PROMOTE} when neuronMonitor is off", PROMOTE not in off_processors)
check(f"no {PIPELINE} when neuronMonitor is off", PIPELINE not in off_pipelines)

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
