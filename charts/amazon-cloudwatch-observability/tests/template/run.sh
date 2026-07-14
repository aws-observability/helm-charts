#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT
#
# Helm template test runner.
#
# A cheap, cluster-free test tier that validates rendering contracts:
# "given this values.yaml, helm template produces (or refuses to produce)
# this manifest shape". Sits below the minikube integration tests, which
# validate CRD acceptance, operator reconciliation, and running pods.
#
# Layout:
#   tests/template/run.sh                     — this runner
#   tests/template/scenarios/<name>/values.yaml  — helm values for the scenario
#   tests/template/scenarios/<name>/test.sh      — assertions, sourced by the runner
#
# Each test.sh runs with these helpers available:
#   render [helm-args...]        — helm template with the scenario values; output in $RENDERED
#   render_expect_failure [...]  — assert helm template fails; stderr in $RENDERED
#   assert_contains <fragment> <description>
#   assert_not_contains <fragment> <description>
#   assert_line_count <grep-pattern> <expected-count> <description>
#   extract_manifest <kind> <name>  — print a single document from $RENDERED
#   assert_doc_contains <doc> <fragment> <description>
#   assert_doc_not_contains <doc> <fragment> <description>
#   fail <message>               — record an explicit failure
#
# Run all scenarios from the repo root:
#     bash charts/amazon-cloudwatch-observability/tests/template/run.sh
# Run a single scenario:
#     bash charts/amazon-cloudwatch-observability/tests/template/run.sh <name>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCENARIOS_DIR="${SCRIPT_DIR}/scenarios"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
N='\033[0m'

total_pass=0
total_fail=0
scenario_fail=0
failed_scenarios=()

RENDERED=""

# ── assertion helpers (used by scenario test.sh files) ───────────────────

fail() {
    echo -e "  ${R}FAIL${N}: $1"
    scenario_fail=$((scenario_fail + 1))
}

pass() {
    echo -e "  ${G}PASS${N}: $1"
    total_pass=$((total_pass + 1))
}

# Render the chart with the scenario's values.yaml plus any extra args.
# Sets $RENDERED. Fails the scenario if helm template errors.
render() {
    local exit_code
    RENDERED=$(helm template test-release "$CHART_DIR" \
        --set clusterName=test-cluster \
        --set region=us-west-2 \
        -f "${scenario_dir}/values.yaml" \
        "$@" 2>&1) && exit_code=0 || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        fail "helm template errored unexpectedly"
        echo "$RENDERED" | tail -5 | sed 's/^/    /'
        return 1
    fi
    pass "helm template rendered successfully"
    return 0
}

# Render and assert helm template FAILS. Sets $RENDERED to the error output.
render_expect_failure() {
    local exit_code
    RENDERED=$(helm template test-release "$CHART_DIR" \
        --set clusterName=test-cluster \
        --set region=us-west-2 \
        -f "${scenario_dir}/values.yaml" \
        "$@" 2>&1) && exit_code=0 || exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        fail "expected helm template to fail, but it succeeded"
        return 1
    fi
    pass "helm template failed as expected"
    return 0
}

assert_contains() {
    local fragment="$1" desc="$2"
    if grep -qF -- "$fragment" <<<"$RENDERED"; then
        pass "$desc"
    else
        fail "$desc — fragment not found: '$fragment'"
    fi
}

assert_not_contains() {
    local fragment="$1" desc="$2"
    if grep -qF -- "$fragment" <<<"$RENDERED"; then
        fail "$desc — forbidden fragment found: '$fragment'"
    else
        pass "$desc"
    fi
}

assert_line_count() {
    local pattern="$1" expected="$2" desc="$3"
    local actual
    actual=$(grep -cE -- "$pattern" <<<"$RENDERED" || true)
    if [[ "$actual" -eq "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc — expected $expected line(s) matching '$pattern', found $actual"
    fi
}

# Scoped variants: assert against a specific document (from extract_manifest)
# instead of the whole render.
assert_doc_contains() {
    local doc="$1" fragment="$2" desc="$3"
    if grep -qF -- "$fragment" <<<"$doc"; then
        pass "$desc"
    else
        fail "$desc — fragment not found in document: '$fragment'"
    fi
}

assert_doc_not_contains() {
    local doc="$1" fragment="$2" desc="$3"
    if grep -qF -- "$fragment" <<<"$doc"; then
        fail "$desc — forbidden fragment found in document: '$fragment'"
    else
        pass "$desc"
    fi
}

# Print the single YAML document with the given kind and metadata.name from
# $RENDERED. Useful to scope assertions to one manifest:
#   doc=$(extract_manifest AmazonCloudWatchAgent cloudwatch-agent-leader)
#   grep ... <<<"$doc"
extract_manifest() {
    local kind="$1" name="$2"
    awk -v kind="$kind" -v name="$name" '
        BEGIN { RS = "\n---" }
        {
            if ($0 ~ ("\nkind: " kind "\n") && $0 ~ ("\n  name: " name "\n")) {
                print
                exit
            }
        }
    ' <<<"$RENDERED"
}

# ── runner ────────────────────────────────────────────────────────────────

run_scenario() {
    local scenario_dir="$1"
    local name
    name="$(basename "$scenario_dir")"
    scenario_fail=0

    printf "\n${Y}[Scenario: %s]${N}\n" "$name"

    if [[ ! -f "${scenario_dir}/values.yaml" ]]; then
        fail "missing values.yaml"
    fi
    if [[ ! -f "${scenario_dir}/test.sh" ]]; then
        fail "missing test.sh"
    fi

    if [[ $scenario_fail -eq 0 ]]; then
        # shellcheck disable=SC1091
        source "${scenario_dir}/test.sh"
    fi

    if [[ $scenario_fail -gt 0 ]]; then
        total_fail=$((total_fail + scenario_fail))
        failed_scenarios+=("$name")
    fi
}

main() {
    local only="${1:-}"
    local dirs=()

    if [[ -n "$only" ]]; then
        if [[ ! -d "${SCENARIOS_DIR}/${only}" ]]; then
            echo "Unknown scenario: ${only}"
            echo "Available: $(ls "$SCENARIOS_DIR")"
            exit 2
        fi
        dirs=("${SCENARIOS_DIR}/${only}")
    else
        for d in "${SCENARIOS_DIR}"/*/; do
            dirs+=("$d")
        done
    fi

    for d in "${dirs[@]}"; do
        run_scenario "${d%/}"
    done

    echo ""
    echo "=== Summary ==="
    if [[ $total_fail -gt 0 ]]; then
        echo -e "${R}${total_fail} assertion(s) failed${N} (${total_pass} passed)"
        echo -e "Failing scenario(s): ${R}${failed_scenarios[*]}${N}"
        exit 1
    fi
    echo -e "${G}All ${total_pass} assertions passed.${N}"
}

main "$@"
