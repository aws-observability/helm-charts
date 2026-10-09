#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Validates the 3-flag OTEL CI gating matrix, plus the global.azure.enabled image
# source switch, by exhaustively rendering
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
# Linux FluentBit inputs that OTEL CI logs replace (forward-slash paths are
# Linux-only; the Windows config uses C:\\ paths).
FB_APP_INPUT="/var/fluent-bit/state/flb_container.db"
FB_HOST_INPUT="/var/fluent-bit/state/flb_dmesg.db"
# Linux FluentBit input OTEL does not replace (dataplane).
FB_DATAPLANE_INPUT="/var/fluent-bit/state/flb_dataplane_tail.db"
OTEL_APP_LOG_GROUP="/aws/otel/containerinsights/test-cluster/application"

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
    "$METRICS_EXPORTER,$METRICS_SIGV4,$FLUENT_BIT_IMAGE,$FB_APP_INPUT,$FB_HOST_INPUT" "$ALL_LOG_FRAGMENTS"

# State #7: full OTEL (metrics + logs, no FluentBit).
run_case 7 true true false "ok" \
    "Full OTEL (metrics + logs)" \
    "$METRICS_EXPORTER,$METRICS_SIGV4,$LOG_EXPORTER_APP,$LOG_EXPORTER_NODE,$LOG_SIGV4,$FILELOG_APP" \
    "$FLUENT_BIT_IMAGE"

# State #8: OTEL logs + FluentBit — no duplicates. OTEL publishes app + host
# logs; FluentBit keeps only what OTEL does not collect (dataplane etc.).
run_case 8 true true true "ok" \
    "OTEL logs + FluentBit for non-OTEL log types only" \
    "$METRICS_EXPORTER,$LOG_EXPORTER_APP,$LOG_EXPORTER_NODE,$FILELOG_APP,$FLUENT_BIT_IMAGE,$FB_DATAPLANE_INPUT,$OTEL_APP_LOG_GROUP" \
    "$FB_APP_INPUT,$FB_HOST_INPUT"

# ──────────────────────────────────────────────────────────────────────────
# Image source matrix — global.azure.enabled on/off.
#
# Every Azure image entry is pointed at a unique sentinel registry so the
# assertions are unambiguous. When global.azure.enabled=false (default, EKS/GKE)
# none of the sentinel registries may appear and the region-based images must
# be used; when true, every image must come from global.azure.images.
# ──────────────────────────────────────────────────────────────────────────

AZ_COMPONENTS="cloudwatchAgent cloudwatchAgentOperator targetAllocator fluentBit fluentBitWindows dcgmExporter neuronMonitor autoInstrumentationJava autoInstrumentationPython autoInstrumentationDotnet autoInstrumentationNodejs nodeExporter kubeStateMetrics"

# run_image_case — $1 case name, $2 region, $3 global.azure.enabled,
#                  $4 must-have fragments, $5 must-not fragments (comma-separated)
run_image_case() {
    local name="$1" region="$2" azure="$3" must_have="${4:-}" must_not="${5:-}"
    printf "\n${Y}[Image source]${N} region=%s global.azure.enabled=%s  —  %s\n" "$region" "$azure" "$name"

    local args=() c
    for c in $AZ_COMPONENTS; do
        args+=(--set "global.azure.images.$c.registry=azsentinel.example.io/$c")
    done

    local output exit_code
    output=$(helm template "$CHART_DIR" \
        --set "region=$region" \
        --set clusterName=test-cluster \
        --set otelContainerInsights.enabled=true \
        --set dcgmExporter.enabled=true \
        --set neuronMonitor.enabled=true \
        --set "global.azure.enabled=$azure" \
        "${args[@]}" 2>&1) && exit_code=0 || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo -e "  ${R}FAIL${N}: helm template failed unexpectedly"
        echo "$output" | tail -5 | sed 's/^/    /'
        fail_count=$((fail_count + 1))
        return
    fi

    local local_fail=0 f
    IFS=',' read -ra fragments <<< "$must_have"
    for f in "${fragments[@]}"; do
        [[ -z "$f" ]] && continue
        if ! grep -q "$f" <<< "$output"; then
            echo -e "  ${R}FAIL${N}: missing required fragment: $f"
            local_fail=1
        fi
    done
    IFS=',' read -ra fragments <<< "$must_not"
    for f in "${fragments[@]}"; do
        [[ -z "$f" ]] && continue
        if grep -q "$f" <<< "$output"; then
            echo -e "  ${R}FAIL${N}: forbidden fragment present: $f"
            local_fail=1
        fi
    done

    if [[ $local_fail -eq 0 ]]; then
        echo -e "  ${G}PASS${N}"
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
}

AZ_ALL=""
for c in $AZ_COMPONENTS; do AZ_ALL="$AZ_ALL,azsentinel.example.io/$c/"; done
AZ_ALL="${AZ_ALL#,}"

echo ""
echo "=== Image source matrix (global.azure.enabled) ==="

# Flag off: EKS/GKE behavior is unchanged — Azure images are ignored.
run_image_case "EKS region, flag off — region images, no Azure images" us-west-2 false \
    "public.ecr.aws/cloudwatch-agent/cloudwatch-agent:,public.ecr.aws/cloudwatch-agent/cloudwatch-agent-operator:" \
    "azsentinel.example.io"
run_image_case "China region, flag off — regional ECR domain" cn-north-1 false \
    "amazonaws.com.cn/cloudwatch-agent:" "azsentinel.example.io"
run_image_case "GKE-style region, flag off — public images" us-central1 false \
    "public.ecr.aws/cloudwatch-agent/cloudwatch-agent:" "azsentinel.example.io"

# Flag on: every image comes from global.azure.images, regardless of region.
run_image_case "Azure, flag on — all images from global.azure.images" eastus true \
    "$AZ_ALL" "public.ecr.aws/cloudwatch-agent/cloudwatch-agent:"
run_image_case "China region, flag on — still global.azure.images" cn-north-1 true \
    "$AZ_ALL" "amazonaws.com.cn"

# Flag on with a missing image entry must fail with a clear message.
printf "\n${Y}[Image source]${N} flag on, missing global.azure.images.fluentBit  —  must fail\n"
if out=$(helm template "$CHART_DIR" --set region=eastus --set clusterName=test-cluster \
        --set global.azure.enabled=true --set global.azure.images.fluentBit=null 2>&1); then
    echo -e "  ${R}FAIL${N}: expected helm template to fail, but it succeeded"
    fail_count=$((fail_count + 1))
elif grep -q "global.azure.images.fluentBit is required" <<< "$out"; then
    echo -e "  ${G}PASS${N}: failed with the expected message"
    pass_count=$((pass_count + 1))
else
    echo -e "  ${R}FAIL${N}: failed, but not with the expected message"
    echo "$out" | tail -3 | sed 's/^/    /'
    fail_count=$((fail_count + 1))
fi

# ──────────────────────────────────────────────────────────────────────────
# Log group prefix by k8sMode — AKS -> /azure, GKE -> /gcp, others -> /aws.
# Checked for both Fluent Bit (/<p>/containerinsights) and OTEL
# (/<p>/otel/containerinsights) log groups, with OTEL logs on and off.
# ──────────────────────────────────────────────────────────────────────────

# run_prefix_case — $1 k8sMode, $2 expected prefix, $3 otel logs enabled (true|false)
run_prefix_case() {
    local mode="$1" prefix="$2" otel_logs="$3"
    printf "\n${Y}[Log group prefix]${N} k8sMode=%s otel logs=%s  —  expect /%s/...\n" "$mode" "$otel_logs" "$prefix"

    local output exit_code
    output=$(helm template "$CHART_DIR" \
        --set region=us-west-2 --set clusterName=test-cluster \
        --set "k8sMode=$mode" --set roleArn=arn:aws:iam::123456789012:role/r \
        --set otelContainerInsights.enabled=true \
        --set "otelContainerInsights.logs.enabled=$otel_logs" \
        --set containerLogs.enabled=true 2>&1) && exit_code=0 || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo -e "  ${R}FAIL${N}: helm template failed unexpectedly"
        echo "$output" | tail -5 | sed 's/^/    /'
        fail_count=$((fail_count + 1))
        return
    fi

    local local_fail=0 p
    # Fluent Bit groups are always rendered; OTEL groups only when OTEL logs are on.
    local must="/$prefix/containerinsights/"
    [[ "$otel_logs" == "true" ]] && must="$must,/$prefix/otel/containerinsights/test-cluster/application,/$prefix/otel/containerinsights/test-cluster/host"
    IFS=',' read -ra frags <<< "$must"
    for f in "${frags[@]}"; do
        grep -q "$f" <<< "$output" || { echo -e "  ${R}FAIL${N}: missing: $f"; local_fail=1; }
    done
    for p in aws azure gcp; do
        [[ "$p" == "$prefix" ]] && continue
        if grep -qE "/$p/(otel/)?containerinsights/" <<< "$output"; then
            echo -e "  ${R}FAIL${N}: unexpected /$p/ log group present"
            local_fail=1
        fi
    done

    if [[ $local_fail -eq 0 ]]; then
        echo -e "  ${G}PASS${N}"
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
}

echo ""
echo "=== Log group prefix by k8sMode ==="
for otel_logs in true false; do
    run_prefix_case AKS  azure "$otel_logs"
    run_prefix_case GKE  gcp   "$otel_logs"
    run_prefix_case EKS  aws   "$otel_logs"
    run_prefix_case ROSA aws   "$otel_logs"
    run_prefix_case K8S  aws   "$otel_logs"
done

# ──────────────────────────────────────────────────────────────────────────
# Windows — OTEL CI never runs on Windows nodes. The Windows Fluent Bit config
# must be identical whether OTEL logs are on or off (it always collects all
# Windows logs), and no OTEL config may be rendered for the Windows agents.
# ──────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Windows (OTEL does not run on Windows) ==="

render_windows() { # $1 k8sMode, $2 otel logs enabled, $3 template
    helm template "$CHART_DIR" --set region=us-west-2 --set clusterName=test-cluster \
        --set "k8sMode=$1" --set roleArn=arn:aws:iam::123456789012:role/r \
        --set otelContainerInsights.enabled=true \
        --set "otelContainerInsights.logs.enabled=$2" \
        --set containerLogs.enabled=true -s "$3" 2>&1
}

for mode in AKS GKE EKS; do
    case "$mode" in AKS) p=azure;; GKE) p=gcp;; *) p=aws;; esac
    printf "\n${Y}[Windows]${N} k8sMode=%s  —  Fluent Bit config independent of OTEL logs, prefix /%s\n" "$mode" "$p"
    cfg_on=$(render_windows "$mode" true templates/windows/fluent-bit-windows-configmap.yaml) || true
    cfg_off=$(render_windows "$mode" false templates/windows/fluent-bit-windows-configmap.yaml) || true
    local_fail=0
    [[ -n "$cfg_on" && "$cfg_on" == "$cfg_off" ]] || { echo -e "  ${R}FAIL${N}: Windows Fluent Bit config differs between OTEL logs on/off"; local_fail=1; }
    for g in application dataplane host; do
        grep -q "/$p/containerinsights/\${CLUSTER_NAME}/$g" <<< "$cfg_on" || { echo -e "  ${R}FAIL${N}: missing Windows /$p/.../$g log group"; local_fail=1; }
    done
    grep -q 'C:\\\\var\\\\log\\\\containers\\\\\*.log' <<< "$cfg_on" || { echo -e "  ${R}FAIL${N}: Windows application logs not collected"; local_fail=1; }
    for t in templates/windows/cloudwatch-agent-windows-daemonset.yaml templates/windows/cloudwatch-agent-windows-container-insights-daemonset.yaml; do
        if render_windows "$mode" true "$t" | grep -qiE "otelConfig|cw_k8s_ci_v0|otlphttp"; then
            echo -e "  ${R}FAIL${N}: OTEL config rendered in $t"; local_fail=1
        fi
    done
    if [[ $local_fail -eq 0 ]]; then echo -e "  ${G}PASS${N}"; pass_count=$((pass_count + 1)); else fail_count=$((fail_count + 1)); fi
done

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
