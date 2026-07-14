# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT
#
# Scenario: otel-ci-flag-matrix
#
# Validates the 3-flag OTEL CI gating matrix by exhaustively rendering all
# 8 combinations of:
#
#   otelContainerInsights.enabled        — OTEL CI pipelines (metrics)
#   otelContainerInsights.logs.enabled   — OTEL-native CI log pipelines
#   containerLogs.enabled                — legacy FluentBit DaemonSet
#
# Key contracts locked in:
#   - logs.enabled=true without enabled=true is silently ignored
#   - OTEL logs and FluentBit may run simultaneously (dual-publish, state 8)
#
# Migrated from tests/flag_matrix.sh into the template test framework.

# Fragment shortcuts shared across states.
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

ALL_LOG_FRAGMENTS=("$LOG_EXPORTER_APP" "$LOG_EXPORTER_NODE" "$LOG_SIGV4" "$LOG_PIPELINE_APP" "$FILELOG_APP")

# render_state <otel-enabled> <otel-logs> <fluentbit> — re-render with the
# given flag combination into $RENDERED.
render_state() {
    render \
        --set "otelContainerInsights.enabled=$1" \
        --set "otelContainerInsights.logs.enabled=$2" \
        --set "containerLogs.enabled=$3"
}

# ── State #1: all false — no monitoring ───────────────────────────────────
if render_state false false false; then
    assert_not_contains "$METRICS_EXPORTER" "state 1 (all off): no OTEL metrics exporter"
    assert_not_contains "$FLUENT_BIT_IMAGE" "state 1 (all off): no FluentBit DaemonSet"
fi

# ── State #2: FluentBit only (pure legacy) ────────────────────────────────
if render_state false false true; then
    assert_contains "$FLUENT_BIT_IMAGE" "state 2 (FB only): FluentBit DaemonSet present"
    assert_not_contains "$METRICS_EXPORTER" "state 2 (FB only): no OTEL metrics exporter"
    for f in "${ALL_LOG_FRAGMENTS[@]}"; do
        assert_not_contains "$f" "state 2 (FB only): no OTEL log fragment $f"
    done
fi

# ── State #3: logs=true without enabled — silently ignored ────────────────
if render_state false true false; then
    assert_not_contains "$METRICS_EXPORTER" "state 3 (logs w/o enabled): no OTEL metrics exporter"
    assert_not_contains "$FLUENT_BIT_IMAGE" "state 3 (logs w/o enabled): no FluentBit DaemonSet"
    for f in "${ALL_LOG_FRAGMENTS[@]}"; do
        assert_not_contains "$f" "state 3 (logs w/o enabled): no OTEL log fragment $f"
    done
fi

# ── State #4: same as #3 with FluentBit — only FluentBit ──────────────────
if render_state false true true; then
    assert_contains "$FLUENT_BIT_IMAGE" "state 4 (logs w/o enabled + FB): FluentBit present"
    assert_not_contains "$METRICS_EXPORTER" "state 4 (logs w/o enabled + FB): no OTEL metrics exporter"
    for f in "${ALL_LOG_FRAGMENTS[@]}"; do
        assert_not_contains "$f" "state 4 (logs w/o enabled + FB): no OTEL log fragment $f"
    done
fi

# ── State #5: OTEL metrics only ───────────────────────────────────────────
if render_state true false false; then
    assert_contains "$METRICS_EXPORTER" "state 5 (OTEL metrics): metrics exporter present"
    assert_contains "$METRICS_SIGV4" "state 5 (OTEL metrics): metrics sigv4 auth present"
    assert_not_contains "$FLUENT_BIT_IMAGE" "state 5 (OTEL metrics): no FluentBit DaemonSet"
    for f in "${ALL_LOG_FRAGMENTS[@]}"; do
        assert_not_contains "$f" "state 5 (OTEL metrics): no OTEL log fragment $f"
    done
fi

# ── State #6: hybrid — OTEL metrics + FluentBit logs ──────────────────────
if render_state true false true; then
    assert_contains "$METRICS_EXPORTER" "state 6 (hybrid): metrics exporter present"
    assert_contains "$METRICS_SIGV4" "state 6 (hybrid): metrics sigv4 auth present"
    assert_contains "$FLUENT_BIT_IMAGE" "state 6 (hybrid): FluentBit DaemonSet present"
    for f in "${ALL_LOG_FRAGMENTS[@]}"; do
        assert_not_contains "$f" "state 6 (hybrid): no OTEL log fragment $f"
    done
fi

# ── State #7: full OTEL (metrics + logs, no FluentBit) ────────────────────
if render_state true true false; then
    assert_contains "$METRICS_EXPORTER" "state 7 (full OTEL): metrics exporter present"
    assert_contains "$METRICS_SIGV4" "state 7 (full OTEL): metrics sigv4 auth present"
    assert_contains "$LOG_EXPORTER_APP" "state 7 (full OTEL): app log exporter present"
    assert_contains "$LOG_EXPORTER_NODE" "state 7 (full OTEL): node log exporter present"
    assert_contains "$LOG_SIGV4" "state 7 (full OTEL): log sigv4 auth present"
    assert_contains "$FILELOG_APP" "state 7 (full OTEL): app filelog receiver present"
    assert_not_contains "$FLUENT_BIT_IMAGE" "state 7 (full OTEL): no FluentBit DaemonSet"
fi

# ── State #8: dual-publish — OTEL logs + FluentBit both active ────────────
if render_state true true true; then
    assert_contains "$METRICS_EXPORTER" "state 8 (dual-publish): metrics exporter present"
    assert_contains "$LOG_EXPORTER_APP" "state 8 (dual-publish): app log exporter present"
    assert_contains "$LOG_EXPORTER_NODE" "state 8 (dual-publish): node log exporter present"
    assert_contains "$FILELOG_APP" "state 8 (dual-publish): app filelog receiver present"
    assert_contains "$FLUENT_BIT_IMAGE" "state 8 (dual-publish): FluentBit DaemonSet present"
fi
