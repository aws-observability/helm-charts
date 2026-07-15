# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT
#
# Validates bundling of the community ServiceMonitor/PodMonitor CRDs and the
# Target Allocator's CustomResourceDefinition RBAC (SPEC: Zero-Step SM/PM CRDs +
# TA Resilience, goal G1).
#
# This is a template-level test (helm template only); it does not deploy to a
# cluster. Note: Helm's `lookup` returns empty during `helm template`, so the
# skip-if-exists behavior (skip when an unmanaged copy already exists) is NOT
# exercised here — that path only runs against a live cluster.
#
# Run from the repo root:
#     bash charts/amazon-cloudwatch-observability/tests/prometheus_crds_matrix.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
N='\033[0m'

pass_count=0
fail_count=0

SM_CRD='name: servicemonitors.monitoring.coreos.com'
PM_CRD='name: podmonitors.monitoring.coreos.com'
CRD_RBAC='customresourcedefinitions'

# render <args...> -> echoes the rendered manifests
render() {
    helm template t "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster "$@" 2>&1
}

# expect_count <desc> <pattern> <expected-count> <render-args...>
expect_count() {
    local desc="$1" pattern="$2" want="$3"; shift 3
    local out got
    out="$(render "$@")" || { printf "${R}FAIL${N} %s (helm error)\n%s\n" "$desc" "$out"; fail_count=$((fail_count+1)); return; }
    got="$(printf '%s\n' "$out" | grep -cE "$pattern" || true)"
    if [[ "$got" == "$want" ]]; then
        printf "${G}PASS${N} %s (%s == %s)\n" "$desc" "$got" "$want"
        pass_count=$((pass_count+1))
    else
        printf "${R}FAIL${N} %s (got %s, want %s) [%s]\n" "$desc" "$got" "$want" "$*"
        fail_count=$((fail_count+1))
    fi
}

printf "${Y}== CRD bundling gating ==${N}\n"
# auto (default): bundle only when otelContainerInsights.enabled (and prometheusScrape enabled).
expect_count "auto + otelCI on  => ServiceMonitor CRD bundled" "$SM_CRD" 1 --set otelContainerInsights.enabled=true
expect_count "auto + otelCI on  => PodMonitor CRD bundled"     "$PM_CRD" 1 --set otelContainerInsights.enabled=true
expect_count "auto + otelCI off => ServiceMonitor CRD absent"  "$SM_CRD" 0 --set otelContainerInsights.enabled=false
expect_count "auto + otelCI off => PodMonitor CRD absent"      "$PM_CRD" 0 --set otelContainerInsights.enabled=false
# auto + prometheusScrape disabled: no scraping => no CRDs.
expect_count "auto + scrape off => ServiceMonitor CRD absent"  "$SM_CRD" 0 --set otelContainerInsights.enabled=true --set otelContainerInsights.prometheusScrape.enabled=false
expect_count "auto + scrape off => PodMonitor CRD absent"      "$PM_CRD" 0 --set otelContainerInsights.enabled=true --set otelContainerInsights.prometheusScrape.enabled=false
# never: never bundle, even with otelCI on.
expect_count "never + otelCI on => ServiceMonitor CRD absent"  "$SM_CRD" 0 --set otelContainerInsights.enabled=true --set otelContainerInsights.prometheusScrape.crds.install=never
expect_count "never + otelCI on => PodMonitor CRD absent"      "$PM_CRD" 0 --set otelContainerInsights.enabled=true --set otelContainerInsights.prometheusScrape.crds.install=never
# always: bundle even with otelCI off.
expect_count "always + otelCI off => ServiceMonitor CRD bundled" "$SM_CRD" 1 --set otelContainerInsights.enabled=false --set otelContainerInsights.prometheusScrape.crds.install=always
expect_count "always + otelCI off => PodMonitor CRD bundled"     "$PM_CRD" 1 --set otelContainerInsights.enabled=false --set otelContainerInsights.prometheusScrape.crds.install=always

printf "\n${Y}== resource-policy keep on bundled CRDs ==${N}\n"
expect_count "bundled CRDs carry resource-policy keep" 'helm.sh/resource-policy: keep' 2 --set otelContainerInsights.enabled=true

printf "\n${Y}== Target Allocator CRD RBAC ==${N}\n"
# The TA needs customresourcedefinitions get;list;watch on the prometheus-CR path.
expect_count "CRD RBAC present when otelCI on"       "$CRD_RBAC" 1 --set otelContainerInsights.enabled=true
expect_count "CRD RBAC absent when otelCI off"       "$CRD_RBAC" 0 --set otelContainerInsights.enabled=false
expect_count "CRD RBAC absent when scrape off"       "$CRD_RBAC" 0 --set otelContainerInsights.enabled=true --set otelContainerInsights.prometheusScrape.enabled=false

printf "\n${Y}== Target Allocator prometheusCR gating ==${N}\n"
# prometheusScrape.enabled is the single switch for the TA prometheusCR path. Both the
# per-node targetAgent and the central clusterScraperAgent get a TA + prometheusCR.
expect_count "TA rendered on both agents when otelCI on"           'targetAllocator:' 2 --set otelContainerInsights.enabled=true
expect_count "prometheusCR rendered on both agents when otelCI on" 'prometheusCR:' 2 --set otelContainerInsights.enabled=true
expect_count "TA absent when scrape off"                           'targetAllocator:' 0 --set otelContainerInsights.enabled=true --set otelContainerInsights.prometheusScrape.enabled=false

printf "\n${Y}== Monitor routing (scraperRole + cloudwatch.aws/scraper annotation) ==${N}\n"
# Routing is annotation-based at runtime; the chart only sets scraperRole on the cluster-scraper CR.
# The per-node agent gets no scraperRole (default role). Runtime annotation filtering is covered by
# the operator unit test TestAnnotationRoleMatches.
expect_count "clusterScraper CR sets scraperRole: cluster-scraper"  'scraperRole: cluster-scraper' 1 --set otelContainerInsights.enabled=true
# With both monitor types enabled (default), routing is annotation-based so NO label selector is
# rendered on either agent's prometheusCR (selectors appear only to disable a monitor type).
expect_count "no monitor selectors rendered when enabled"           'onitorSelector:' 0 --set otelContainerInsights.enabled=true
# Disabling a monitor type still renders the discover-nothing sentinel on BOTH agents.
expect_count "SM disabled => sentinel selector on both agents"      'amazon-cloudwatch-observability.aws/otel-ci-scrape: disabled' 2 --set otelContainerInsights.enabled=true --set otelContainerInsights.prometheusScrape.serviceMonitor.enabled=false

printf "\n${Y}== allocation strategy per agent ==${N}\n"
# targetAgent defaults to per-node; clusterScraperAgent is always consistent-hashing.
expect_count "targetAgent per-node by default"                'allocationStrategy: "per-node"' 1 --set otelContainerInsights.enabled=true
expect_count "clusterScraper consistent-hashing by default"   'allocationStrategy: "consistent-hashing"' 1 --set otelContainerInsights.enabled=true
# Overriding prometheusScrape.allocationStrategy applies to the targetAgent only; the
# clusterScraper stays consistent-hashing, so both agents end up consistent-hashing.
expect_count "override => both agents consistent-hashing"     'allocationStrategy: "consistent-hashing"' 2 --set otelContainerInsights.enabled=true --set otelContainerInsights.prometheusScrape.allocationStrategy=consistent-hashing
expect_count "override => no per-node remaining"              'allocationStrategy: "per-node"' 0 --set otelContainerInsights.enabled=true --set otelContainerInsights.prometheusScrape.allocationStrategy=consistent-hashing

printf "\n${Y}== Summary ==${N}\n"
printf "passed: ${G}%s${N}, failed: ${R}%s${N}\n" "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
