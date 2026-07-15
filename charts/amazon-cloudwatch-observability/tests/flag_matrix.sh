#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Validates the 3-flag OTEL CI gating matrix by exhaustively rendering
# `helm template` across all 8 combinations of:
#
#   otelContainerInsights.enabled
#   otelContainerInsights.logs.enabled
#   containerLogs.enabled
#
# This is a template-level test — it does not deploy anything to a real cluster.
# Minikube integration tests cover deployment; this script fills the gap for:
#   (a) testing all 8 combinations quickly without minikube
#   (b) asserting correct fragment presence/absence for each state
#
# Run from the repo root:
#     bash charts/amazon-cloudwatch-observability/tests/flag_matrix.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for readable output.
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
N='\033[0m'

pass_count=0
fail_count=0

# ──────────────────────────────────────────────────────────────────────────
# run_case — render helm with the given flags and verify expected behavior.
#
# Arguments:
#   $1  case number (for output)
#   $2  otelContainerInsights.enabled  (true|false)
#   $3  otelContainerInsights.logs.enabled     (true|false)
#   $4  containerLogs.enabled          (true|false)
#   $5  expected outcome: "ok" (renders successfully)
#   $6  description shown in output
# Optional args (only checked when $5 == "ok"):
#   $7  comma-separated list of fragments that MUST be present in output
#   $8  comma-separated list of fragments that MUST NOT be present in output
# ──────────────────────────────────────────────────────────────────────────
run_case() {
    local num="$1" enabled="$2" logs="$3" fb="$4" expected="$5" desc="$6"
    local must_have="${7:-}" must_not="${8:-}"

    printf "\n${Y}[State #%s]${N} enabled=%s logs=%s containerLogs=%s  —  %s\n" \
        "$num" "$enabled" "$logs" "$fb" "$desc"

    local output exit_code
    output=$(helm template "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        --set "otelContainerInsights.enabled=$enabled" \
        --set "otelContainerInsights.logs.enabled=$logs" \
        --set "containerLogs.enabled=$fb" 2>&1) && exit_code=0 || exit_code=$?

    if [[ "$expected" == "fail" ]]; then
        if [[ $exit_code -eq 0 ]]; then
            echo -e "  ${R}FAIL${N}: expected helm template to fail, but it succeeded"
            fail_count=$((fail_count + 1))
            return
        fi
        echo -e "  ${G}PASS${N}: helm template failed as expected"
        pass_count=$((pass_count + 1))
        return
    fi

    # Expected success path.
    if [[ $exit_code -ne 0 ]]; then
        echo -e "  ${R}FAIL${N}: helm template failed unexpectedly"
        echo "$output" | tail -5 | sed 's/^/    /'
        fail_count=$((fail_count + 1))
        return
    fi

    local local_fail=0

    if [[ -n "$must_have" ]]; then
        IFS=',' read -ra fragments <<< "$must_have"
        for f in "${fragments[@]}"; do
            if ! grep -q "$f" <<< "$output"; then
                echo -e "  ${R}FAIL${N}: missing required fragment: $f"
                local_fail=1
            fi
        done
    fi

    if [[ -n "$must_not" ]]; then
        IFS=',' read -ra fragments <<< "$must_not"
        for f in "${fragments[@]}"; do
            if grep -q "$f" <<< "$output"; then
                echo -e "  ${R}FAIL${N}: forbidden fragment present: $f"
                local_fail=1
            fi
        done
    fi

    if [[ $local_fail -eq 0 ]]; then
        echo -e "  ${G}PASS${N}"
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
}

# Fragment shortcuts used across states.
METRICS_EXPORTER="otlphttp/cw_k8s_ci_v0_metrics_dest"
METRICS_SIGV4="sigv4auth/cw_k8s_ci_v0_metrics_dest"
LOG_EXPORTER_APP="otlphttp/cw_k8s_ci_v0_app_logs_dest"
LOG_EXPORTER_NODE="otlphttp/cw_k8s_ci_v0_node_logs_dest"
LOG_SIGV4="sigv4auth/cw_k8s_ci_v0_logs_dest"
LOG_PIPELINE_APP="logs/cw_k8s_ci_v0_app"
FILELOG_APP="filelog/cw_k8s_ci_v0_app"
# aws-for-fluent-bit is the container image string — unique to the FluentBit
# DaemonSet. Using this instead of bare "fluent-bit" avoids false matches in
# OTEL config paths like /var/log/containers/fluent-bit* (which exist in the
# filelog exclude list regardless of the FB DaemonSet flag).
FLUENT_BIT_IMAGE="aws-for-fluent-bit"

# All OTEL log pipeline fragments (app + host).
ALL_LOG_FRAGMENTS="$LOG_EXPORTER_APP,$LOG_EXPORTER_NODE,$LOG_SIGV4,$LOG_PIPELINE_APP,$FILELOG_APP"

# ──────────────────────────────────────────────────────────────────────────
# Run all 8 combinations.
# ──────────────────────────────────────────────────────────────────────────

echo "=== OTEL CI flag gating matrix ==="
echo "Chart: $CHART_DIR"

# State #1: all false — no monitoring.
run_case 1 false false false "ok" \
    "No monitoring — all flags off" \
    "" "$METRICS_EXPORTER,$FLUENT_BIT_IMAGE"

# State #2: FluentBit only (pure v1 legacy).
run_case 2 false false true "ok" \
    "FluentBit legacy only" \
    "$FLUENT_BIT_IMAGE" "$METRICS_EXPORTER,$ALL_LOG_FRAGMENTS"

# State #3: logs=true without enabled — silently ignored.
run_case 3 false true false "ok" \
    "logs=true without enabled — no OTEL output" \
    "" "$METRICS_EXPORTER,$ALL_LOG_FRAGMENTS,$FLUENT_BIT_IMAGE"

# State #4: same as #3 with FluentBit.
run_case 4 false true true "ok" \
    "logs=true without enabled + FluentBit — only FluentBit" \
    "$FLUENT_BIT_IMAGE" "$METRICS_EXPORTER,$ALL_LOG_FRAGMENTS"

# State #5: OTEL metrics only.
run_case 5 true false false "ok" \
    "OTEL metrics only, no logs" \
    "$METRICS_EXPORTER,$METRICS_SIGV4" "$ALL_LOG_FRAGMENTS,$FLUENT_BIT_IMAGE"

# State #6: hybrid — OTEL metrics + FluentBit logs.
run_case 6 true false true "ok" \
    "Hybrid — OTEL metrics + FluentBit logs" \
    "$METRICS_EXPORTER,$METRICS_SIGV4,$FLUENT_BIT_IMAGE" "$ALL_LOG_FRAGMENTS"

# State #7: full OTEL (metrics + logs, no FluentBit).
run_case 7 true true false "ok" \
    "Full OTEL (metrics + logs)" \
    "$METRICS_EXPORTER,$METRICS_SIGV4,$LOG_EXPORTER_APP,$LOG_EXPORTER_NODE,$LOG_SIGV4,$FILELOG_APP" \
    "$FLUENT_BIT_IMAGE"

# State #8: dual-publish (migration window — OTEL logs + FluentBit both active).
run_case 8 true true true "ok" \
    "Dual-publish — OTEL logs + FluentBit both active" \
    "$METRICS_EXPORTER,$LOG_EXPORTER_APP,$LOG_EXPORTER_NODE,$FILELOG_APP,$FLUENT_BIT_IMAGE" \
    ""

# ──────────────────────────────────────────────────────────────────────────
# Summary.
# ──────────────────────────────────────────────────────────────────────────
total=$((pass_count + fail_count))
echo ""
echo "=== Summary ==="
if [[ $fail_count -eq 0 ]]; then
    echo -e "${G}All $total cases passed.${N}"
    exit 0
else
    echo -e "${R}$fail_count of $total cases failed.${N}"
    exit 1
fi
