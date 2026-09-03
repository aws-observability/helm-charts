#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Validates the pod-level configuration values:
#   podLabels, podAnnotations, topologySpreadConstraints,
#   priorityClassName, podDisruptionBudget
#
# Renders the chart with a values overlay that exercises root-level defaults,
# per-component overrides, override precedence, reserved-label protection,
# PDB naming/scope, and the min-vs-max PDB merge rule. Also renders the
# default case to confirm no PDBs are emitted and pre-existing behavior is
# preserved.
#
# Requires python3 with PyYAML.
#
# Run from the repo root:
#     bash charts/amazon-cloudwatch-observability/tests/pod_level_values.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
N='\033[0m'

pass_count=0
fail_count=0

pass() { echo -e "  ${G}PASS${N} $1"; pass_count=$((pass_count + 1)); }
fail() { echo -e "  ${R}FAIL${N} $1"; fail_count=$((fail_count + 1)); }

assert_grep() {
  local label="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then pass "$label"; else fail "$label: pattern '${pattern}' not found in $file"; fi
}

assert_not_grep() {
  local label="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then fail "$label: pattern '${pattern}' should NOT appear in $file"; else pass "$label"; fi
}

# yaml_query FILE JQ-LIKE-PATH-QUERY
# JQ-LIKE-PATH-QUERY is a python callable body operating on `docs` — the list
# of parsed YAML documents from FILE — that prints the answer.
yaml_query() {
  local file="$1"; shift
  python3 - "$file" <<PY
import sys, yaml
with open(sys.argv[1]) as f:
    docs = [d for d in yaml.safe_load_all(f) if d]
$@
PY
}

# assert_workload_label KIND NAME KEY WANT FILE
# Verifies spec.template.metadata.labels.<KEY> on the resource of type KIND
# with metadata.name == NAME. Uses YAML parsing so semantic "last key wins"
# applies as it would when Kubernetes ingests the manifest.
assert_workload_label() {
  local kind="$1" name="$2" key="$3" want="$4" file="$5" got
  got="$(yaml_query "$file" "\
for d in docs:
    if d.get('kind') == '$kind' and d.get('metadata', {}).get('name') == '$name':
        labels = d['spec']['template']['metadata'].get('labels', {})
        print(labels.get('$key', ''))
        break
")"
  if [[ "$got" == "$want" ]]; then
    pass "$kind/$name pod label '${key}'='${want}'"
  else
    fail "$kind/$name pod label '${key}' expected '${want}' got '${got:-<missing>}'"
  fi
}

# assert_cr_field KIND NAME PATH WANT FILE
# Reads a nested value from a Custom Resource. PATH is a dot-separated path.
assert_cr_field() {
  local kind="$1" name="$2" path="$3" want="$4" file="$5" got
  got="$(yaml_query "$file" "\
def dig(o, path):
    for p in path.split('.'):
        if o is None: return ''
        o = o.get(p, None) if isinstance(o, dict) else None
    return '' if o is None else o
for d in docs:
    if d.get('kind') == '$kind' and d.get('metadata', {}).get('name') == '$name':
        print(dig(d, '$path'))
        break
")"
  if [[ "$got" == "$want" ]]; then
    pass "$kind/$name .$path == '${want}'"
  else
    fail "$kind/$name .$path expected '${want}' got '${got:-<missing>}'"
  fi
}

# assert_pdb_spec NAME PATH WANT FILE — check a specific field on a PDB by name.
assert_pdb_spec() {
  local name="$1" path="$2" want="$3" file="$4" got
  got="$(yaml_query "$file" "\
def dig(o, path):
    for p in path.split('.'):
        if o is None: return ''
        o = o.get(p, None) if isinstance(o, dict) else None
    return '' if o is None else o
for d in docs:
    if d.get('kind') == 'PodDisruptionBudget' and d.get('metadata', {}).get('name') == '$name':
        print(dig(d, '$path'))
        break
")"
  if [[ "$got" == "$want" ]]; then
    pass "PDB $name .$path == '${want}'"
  else
    fail "PDB $name .$path expected '${want}' got '${got:-<missing>}'"
  fi
}

# assert_pdb_absent NAME FIELD FILE — assert a spec field is not present on a PDB.
assert_pdb_absent() {
  local name="$1" field="$2" file="$3" present
  present="$(yaml_query "$file" "\
for d in docs:
    if d.get('kind') == 'PodDisruptionBudget' and d.get('metadata', {}).get('name') == '$name':
        print('yes' if '$field' in (d.get('spec') or {}) else 'no')
        break
")"
  if [[ "$present" == "no" ]]; then
    pass "PDB $name has no .spec.$field"
  else
    fail "PDB $name unexpectedly has .spec.$field"
  fi
}

# count_docs KIND NAME_REGEX FILE — count resources matching KIND and name regex.
count_docs() {
  local kind="$1" name_re="$2" file="$3"
  yaml_query "$file" "\
import re
n = 0
for d in docs:
    if d.get('kind') == '$kind' and re.match(r'$name_re', d.get('metadata', {}).get('name', '')):
        n += 1
print(n)
"
}

VALUES_FILE="$(mktemp)"
RENDER_FILE="$(mktemp)"
RENDER_DEFAULT="$(mktemp)"
RENDER_OVERRIDE="$(mktemp)"
RENDER_RESERVED="$(mktemp)"
RENDER_WINDOWS="$(mktemp)"
RENDER_MIN_VS_MAX="$(mktemp)"
trap 'rm -f "$VALUES_FILE" "$RENDER_FILE" "$RENDER_DEFAULT" "$RENDER_OVERRIDE" "$RENDER_RESERVED" "$RENDER_WINDOWS" "$RENDER_MIN_VS_MAX"' EXIT

# ── Case A: base overlay exercising all 5 fields with root defaults ─────────
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

kubeStateMetrics:
  podDisruptionBudget:
    enabled: true
    minAvailable: 1
YAML

helm template test-release "$CHART_DIR" -f "$VALUES_FILE" > "$RENDER_FILE"
helm template test-release "$CHART_DIR" \
  --set clusterName=test-cluster --set region=us-west-2 > "$RENDER_DEFAULT"

echo -e "${Y}== Case A: root-level fields propagate ==${N}"

# PDB naming — all four end with -pdb.
assert_pdb_spec "amazon-cloudwatch-observability-controller-manager-pdb" "spec.maxUnavailable" "1" "$RENDER_FILE"
assert_pdb_spec "fluent-bit-pdb"                                          "spec.maxUnavailable" "1" "$RENDER_FILE"
assert_pdb_spec "node-exporter-pdb"                                       "spec.maxUnavailable" "1" "$RENDER_FILE"
assert_pdb_spec "kube-state-metrics-pdb"                                  "spec.minAvailable"   "1" "$RENDER_FILE"

# Exactly one fluent-bit PDB (no separate windows PDB emitted).
if [[ "$(count_docs PodDisruptionBudget '^fluent-bit-pdb$' "$RENDER_FILE")" == "1" ]]; then
  pass "exactly one fluent-bit PDB emitted"
else
  fail "expected exactly one fluent-bit-pdb, found $(count_docs PodDisruptionBudget '^fluent-bit-pdb$' "$RENDER_FILE")"
fi
if [[ "$(count_docs PodDisruptionBudget 'fluent-bit-windows' "$RENDER_FILE")" == "0" ]]; then
  pass "no fluent-bit-windows PDB emitted"
else
  fail "unexpected fluent-bit-windows PDB emitted"
fi

# Root podLabels/podAnnotations propagate.
assert_workload_label "Deployment" "amazon-cloudwatch-observability-controller-manager" "team" "cloudwatch" "$RENDER_FILE"
assert_workload_label "DaemonSet"  "fluent-bit"                                          "team" "cloudwatch" "$RENDER_FILE"
assert_grep "root podAnnotation on pods" "root-anno: from-root" "$RENDER_FILE"

# priorityClassName applied to workloads without a component-level override.
assert_grep "operator priorityClassName" 'priorityClassName: "system-cluster-critical"' "$RENDER_FILE"
# topologySpreadConstraints propagate.
assert_grep "topologySpreadConstraints present" "topologyKey: topology.kubernetes.io/zone" "$RENDER_FILE"

# CWA CR wiring on the Linux CR (there are two named cloudwatch-agent* linux CRs).
assert_cr_field "AmazonCloudWatchAgent" "cloudwatch-agent" "spec.podAnnotations.root-anno" "from-root" "$RENDER_FILE"
assert_cr_field "AmazonCloudWatchAgent" "cloudwatch-agent" "spec.podDisruptionBudget.maxUnavailable" "1" "$RENDER_FILE"

echo -e "${Y}== Case B: default render (no new fields set) ==${N}"

assert_not_grep "no PDB when disabled"                             "^kind: PodDisruptionBudget$"                  "$RENDER_DEFAULT"
assert_grep     "fluent-bit keeps system-node-critical by default" 'priorityClassName: "system-node-critical"'   "$RENDER_DEFAULT"

echo -e "${Y}== Case C: per-component podLabels override wins over root ==${N}"

cat > "$VALUES_FILE" <<'YAML'
clusterName: test-cluster
region: us-west-2

podLabels:
  team: cloudwatch
manager:
  podLabels:
    team: engineering
YAML

helm template test-release "$CHART_DIR" -f "$VALUES_FILE" > "$RENDER_OVERRIDE"
assert_workload_label "Deployment" "amazon-cloudwatch-observability-controller-manager" "team" "engineering" "$RENDER_OVERRIDE"
assert_workload_label "DaemonSet"  "fluent-bit"                                          "team" "cloudwatch"  "$RENDER_OVERRIDE"

echo -e "${Y}== Case D: user podLabels cannot override selector keys ==${N}"

cat > "$VALUES_FILE" <<'YAML'
clusterName: test-cluster
region: us-west-2

manager:
  podLabels:
    control-plane: attempted-hijack
containerLogs:
  fluentBit:
    podLabels:
      k8s-app: attempted-hijack
YAML

helm template test-release "$CHART_DIR" -f "$VALUES_FILE" > "$RENDER_RESERVED"
assert_workload_label "Deployment" "amazon-cloudwatch-observability-controller-manager" "control-plane" "controller-manager" "$RENDER_RESERVED"
assert_workload_label "DaemonSet"  "fluent-bit"                                          "k8s-app"       "fluent-bit"         "$RENDER_RESERVED"

# Assert the render has no duplicate keys in the labels blocks (strict-YAML clean output).
dup_keys="$(python3 - <<PY
import yaml, sys
class DupKeyLoader(yaml.SafeLoader):
    pass
def _construct(loader, node, deep=False):
    keys = []
    for k, v in node.value:
        keys.append(loader.construct_scalar(k))
    seen = set()
    for k in keys:
        if k in seen:
            print(f"DUPLICATE: {k}")
        seen.add(k)
    return yaml.constructor.SafeConstructor.construct_mapping(loader, node, deep=deep)
DupKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct)
with open("$RENDER_RESERVED") as f:
    for _ in yaml.load_all(f, Loader=DupKeyLoader):
        pass
PY
)"
if [[ -z "$dup_keys" ]]; then
  pass "no duplicate keys in rendered YAML labels blocks"
else
  fail "duplicate keys detected:\n$dup_keys"
fi

echo -e "${Y}== Case E: Windows-non-CI CWA CR honors root priorityClassName ==${N}"

cat > "$VALUES_FILE" <<'YAML'
clusterName: test-cluster
region: us-west-2

priorityClassName: system-cluster-critical
agent:
  priorityClassName: ~
YAML

helm template test-release "$CHART_DIR" -f "$VALUES_FILE" > "$RENDER_WINDOWS"
assert_cr_field "AmazonCloudWatchAgent" "cloudwatch-agent-windows"                     "spec.priorityClassName" "system-cluster-critical" "$RENDER_WINDOWS"
assert_cr_field "AmazonCloudWatchAgent" "cloudwatch-agent-windows-container-insights"  "spec.priorityClassName" "system-cluster-critical" "$RENDER_WINDOWS"

echo -e "${Y}== Case F: minAvailable wins when both are present after merge ==${N}"

cat > "$VALUES_FILE" <<'YAML'
clusterName: test-cluster
region: us-west-2

podDisruptionBudget:
  enabled: true
  maxUnavailable: 1
manager:
  podDisruptionBudget:
    enabled: true
    minAvailable: 2
YAML

helm template test-release "$CHART_DIR" -f "$VALUES_FILE" > "$RENDER_MIN_VS_MAX"
assert_pdb_spec   "amazon-cloudwatch-observability-controller-manager-pdb" "spec.minAvailable" "2"              "$RENDER_MIN_VS_MAX"
assert_pdb_absent "amazon-cloudwatch-observability-controller-manager-pdb" "maxUnavailable"                     "$RENDER_MIN_VS_MAX"

echo
echo "=== Summary ==="
if [[ $fail_count -eq 0 ]]; then
  echo -e "${G}All ${pass_count} checks passed.${N}"
  exit 0
else
  echo -e "${R}${fail_count} checks failed (${pass_count} passed).${N}"
  exit 1
fi
