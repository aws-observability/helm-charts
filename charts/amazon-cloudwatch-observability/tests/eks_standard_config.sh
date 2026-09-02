#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Validates the EKS addon standard configuration values:
#   podLabels, podAnnotations, topologySpreadConstraints,
#   podDisruptionBudget, priorityClassName
#
# Renders the chart with a values overlay that exercises root-level defaults
# and per-component overrides, and asserts the resulting objects contain the
# expected values.
#
# Run from the repo root:
#     bash charts/amazon-cloudwatch-observability/tests/eks_standard_config.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
N='\033[0m'

pass_count=0
fail_count=0

assert_grep() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${G}PASS${N} ${label}"
    pass_count=$((pass_count + 1))
  else
    echo -e "  ${R}FAIL${N} ${label}: pattern '${pattern}' not found in $file"
    fail_count=$((fail_count + 1))
  fi
}

assert_not_grep() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${R}FAIL${N} ${label}: pattern '${pattern}' should NOT appear in $file"
    fail_count=$((fail_count + 1))
  else
    echo -e "  ${G}PASS${N} ${label}"
    pass_count=$((pass_count + 1))
  fi
}

VALUES_FILE="$(mktemp)"
trap 'rm -f "$VALUES_FILE" "$RENDER_FILE" "$RENDER_DEFAULT"' EXIT

cat > "$VALUES_FILE" <<'YAML'
clusterName: test-cluster
region: us-west-2

podLabels:
  team: cloudwatch
  environment: test
podAnnotations:
  root-anno: from-root
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: amazon-cloudwatch-observability
priorityClassName: system-cluster-critical
podDisruptionBudget:
  enabled: true
  maxUnavailable: 1

otelContainerInsights:
  enabled: true

# Per-component override: kubeStateMetrics uses minAvailable instead
kubeStateMetrics:
  podDisruptionBudget:
    enabled: true
    minAvailable: 1
YAML

RENDER_FILE="$(mktemp)"
RENDER_DEFAULT="$(mktemp)"

helm template test-release "$CHART_DIR" -f "$VALUES_FILE" > "$RENDER_FILE"
helm template test-release "$CHART_DIR" \
  --set clusterName=test-cluster \
  --set region=us-west-2 > "$RENDER_DEFAULT"

echo -e "${Y}== Custom values render ==${N}"

# PDBs
assert_grep "operator PDB present"     "^  name: amazon-cloudwatch-observability-controller-manager$" "$RENDER_FILE"
assert_grep "fluent-bit PDB present"   "^  name: fluent-bit$"                                          "$RENDER_FILE"
assert_grep "node-exporter PDB present" "^  name: node-exporter-pdb$"                                  "$RENDER_FILE"
assert_grep "KSM PDB present"          "^  name: kube-state-metrics-pdb$"                             "$RENDER_FILE"
assert_grep "KSM PDB uses minAvailable" "minAvailable: 1"                                              "$RENDER_FILE"

# podLabels propagate
assert_grep "root podLabel on operator"    "team: cloudwatch"     "$RENDER_FILE"
# podAnnotations propagate
assert_grep "root podAnnotation propagates" "root-anno: from-root" "$RENDER_FILE"
# priorityClassName override for workloads that don't set their own
assert_grep "operator priorityClassName" 'priorityClassName: "system-cluster-critical"' "$RENDER_FILE"
# topologySpreadConstraints propagate
assert_grep "topologySpreadConstraints present" "topologyKey: topology.kubernetes.io/zone" "$RENDER_FILE"

# CWA CR wired
assert_grep "CWA CR has podAnnotations"        "^  podAnnotations:$"        "$RENDER_FILE"
assert_grep "CWA CR has topologySpreadConstraints" "^  topologySpreadConstraints:$" "$RENDER_FILE"
assert_grep "CWA CR has podDisruptionBudget"   "^  podDisruptionBudget:$"   "$RENDER_FILE"

echo -e "${Y}== Default render (no new fields set) ==${N}"

# Defaults preserved: no PDB objects, fluent-bit / agent still use system-node-critical
assert_not_grep "no PDB when disabled" "^kind: PodDisruptionBudget$" "$RENDER_DEFAULT"
assert_grep "fluent-bit keeps system-node-critical by default" 'priorityClassName: "system-node-critical"' "$RENDER_DEFAULT"

echo
echo "=== Summary ==="
if [[ $fail_count -eq 0 ]]; then
  echo -e "${G}All ${pass_count} checks passed.${N}"
  exit 0
else
  echo -e "${R}${fail_count} checks failed (${pass_count} passed).${N}"
  exit 1
fi
