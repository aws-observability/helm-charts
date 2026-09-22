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
# The two datapoints for a core then shared one identity and for one core the
# survivor was a legitimate-looking 0. This fails SILENTLY: the collision happens
# in-agent, so the exported surface shows too FEW series rather than duplicated
# ones. Cardinality is the signal, not duplication -- which is why nothing in this
# repo caught it, and why this script asserts structure rather than output size.
#
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/neuron_pipeline_shape.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
N='\033[0m'

pass_count=0
fail_count=0

check() {
    local desc="$1"
    shift
    if "$@"; then
        echo -e "  ${G}PASS${N}: $desc"
        pass_count=$((pass_count + 1))
    else
        echo -e "  ${R}FAIL${N}: $desc"
        fail_count=$((fail_count + 1))
    fi
}

# has/lacks — whether $1 contains a line matching the regex $2.
#
# Note the negations are `! grep -q`, NOT `grep -qv`: -v inverts per line, so it
# succeeds as soon as ONE line fails to match, which is true of almost any
# multi-line block and would make every "must not contain" assertion vacuous.
has() {
    grep -q -- "$2" <<< "$1"
}

lacks() {
    ! grep -q -- "$2" <<< "$1"
}

has_line() {
    grep -qx -- "$2" <<< "$1"
}

lacks_line() {
    ! grep -qx -- "$2" <<< "$1"
}

# render_otel_config — the agent CR's otelConfig, as readable YAML.
#
# The chart emits otelConfig as a single-line escaped string inside the
# AmazonCloudWatchAgent CR, so unescape it rather than trying to grep the
# escaped form. The sed expressions run in order:
#
#   1. strip the `  otelConfig: "` key and opening quote
#   2. strip the closing quote
#   3. unescape \n into real newlines, so the block parsers below can work
#      line-by-line
#   4. unescape \" into ", so OTTL statements read as they do in the template
#
# If the chart ever changes how it serializes otelConfig, this is the function
# to update -- the assertions below all consume its output.
#
# The render is captured into a variable before filtering rather than piped
# straight into grep: `grep -m1` exits at the first match, and otelConfig appears
# early in a render of tens of kilobytes, so helm can still be writing when the
# read end closes. That SIGPIPEs helm, and `set -o pipefail` turns it into a
# failure of the whole script -- intermittently, depending on whether the render
# happened to fit in the pipe buffer first. Filtering from a herestring has no
# upstream process to kill.
render_otel_config() {
    local neuron_enabled="$1" rendered
    rendered="$("$HELM" template "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        --set otelContainerInsights.enabled=true \
        --set "neuronMonitor.enabled=$neuron_enabled")"
    grep -m1 '^  otelConfig: ' <<< "$rendered" \
        | sed -e 's/^  otelConfig: "//' -e 's/"$//' -e 's/\\n/\n/g' -e 's/\\"/"/g'
}

# processor_block — the body of one processor, from its key to the next key at
# the same indent. Keeps assertions scoped so a match elsewhere in the config
# cannot satisfy them.
processor_block() {
    local name="$1"
    awk -v key="  $name:" '
        $0 == key { inside = 1; next }
        inside && /^  [^ ]/ { exit }
        inside { print }
    '
}

echo "=== Neuron pipeline shape ==="
echo "Chart: $CHART_DIR"

enabled_config="$(render_otel_config true)"
groupby="$(printf '%s\n' "$enabled_config" | processor_block "groupbyattrs/cw_k8s_ci_v0_neuron")"
promote="$(printf '%s\n' "$enabled_config" | processor_block "transform/cw_k8s_ci_v0_neuron_promote")"

printf "\n${Y}[neuronMonitor.enabled=true]${N}\n"

# Guard: if these blocks are empty the assertions below would pass vacuously.
check "groupbyattrs/cw_k8s_ci_v0_neuron renders" \
    test -n "$groupby"
check "transform/cw_k8s_ci_v0_neuron_promote renders" \
    test -n "$promote"

# 1. runtime_tag must be a grouping key: this is what gives each runtime its own
#    ResourceMetrics so the per-core datapoints can no longer collide.
check "runtime_tag is a groupbyattrs grouping key" \
    has_line "$groupby" '    - runtime_tag'

# 2. The promote must run in resource context. runtime_tag is on the resource by
#    this point (groupbyattrs MOVES its grouping keys), and resource attributes
#    are per-ResourceMetrics -- writing them from datapoint context is the
#    last-write-wins defect itself.
check "promote runs in resource context" \
    has_line "$promote" '    - context: resource'
check "promote does NOT run in datapoint context" \
    lacks_line "$promote" '    - context: datapoint'

# 3. Exactly the rename and its cleanup. The pod/namespace/container promotions
#    that used to live here were dead code -- groupbyattrs already moved those
#    keys onto the resource one processor earlier -- and re-adding them in
#    datapoint context would reintroduce the defect.
check "promote renames runtime_tag to aws.neuron.runtime.tag" \
    has "$promote" 'set(attributes\["aws.neuron.runtime.tag"\], attributes\["runtime_tag"\])'
check "promote deletes runtime_tag after renaming" \
    has "$promote" 'delete_key(attributes, "runtime_tag")'
check "promote does not re-promote pod/namespace/container" \
    lacks "$promote" 'resource.attributes\["k8s\.'
check "promote has exactly 2 statements" \
    test "$(grep -c '^      - ' <<< "$promote")" -eq 2

# 4. Negative control: with neuronMonitor off the Neuron processors must not
#    render at all. Without this, a rename of the processor keys would make every
#    assertion above pass against empty input.
printf "\n${Y}[neuronMonitor.enabled=false]${N}\n"
disabled_config="$(render_otel_config false)"
check "no groupbyattrs/cw_k8s_ci_v0_neuron when neuronMonitor is off" \
    lacks "$disabled_config" '^  groupbyattrs/cw_k8s_ci_v0_neuron:'
check "no transform/cw_k8s_ci_v0_neuron_promote when neuronMonitor is off" \
    lacks "$disabled_config" '^  transform/cw_k8s_ci_v0_neuron_promote:'

total=$((pass_count + fail_count))
echo ""
echo "=== Summary ==="
if [[ $fail_count -eq 0 ]]; then
    echo -e "${G}All $total checks passed.${N}"
    exit 0
else
    echo -e "${R}$fail_count of $total checks failed.${N}"
    exit 1
fi
