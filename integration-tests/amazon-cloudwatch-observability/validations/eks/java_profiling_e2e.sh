#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Java profiling with Application Signals, end to end. Usage: java_profiling_e2e.sh <region> <service-name> <app.yaml>
#   [otlp-http-port, default 4318]
# Deploys a Java workload with ADOT, then checks that:
#   1. the operator sends traces and Application Signals metrics to the agent on 4316 and profiles to the chart's
#      OTLP HTTP endpoint (otlp.http.port);
#   2. Application Signals metrics, X-Ray traces and profiles for the service all reach CloudWatch.
# Uses kubectl, the aws CLI and curl --aws-sigv4 with the caller's credentials, which are never printed or passed
# as process arguments.
set -uo pipefail
REGION=$1; SERVICE=$2; APP=$3; PORT=${4:-4318}
AGENT=http://cloudwatch-agent.amazon-cloudwatch
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }

sed "s/__SERVICE__/${SERVICE}/g" "$APP" | kubectl apply -f - || exit 1
if ! kubectl -n java-profiling-it rollout status deploy/java-profiling-it --timeout=600s; then
    kubectl -n java-profiling-it describe pods; exit 1
fi
POD=$(kubectl -n java-profiling-it get pods -l app=java-profiling-it -o jsonpath='{.items[0].metadata.name}')
envof() { kubectl -n java-profiling-it get pod "$POD" -o jsonpath="{.spec.containers[0].env[?(@.name==\"$1\")].value}"; }

echo "=== 1. Service name and endpoints in the Java container"
for kv in "OTEL_SERVICE_NAME=${SERVICE}" \
          "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=${AGENT}:4316/v1/traces" \
          "OTEL_AWS_APPLICATION_SIGNALS_EXPORTER_ENDPOINT=${AGENT}:4316/v1/metrics" \
          "OTEL_AWS_PROFILER_ENDPOINT=${AGENT}:${PORT}/v1development/profiles" \
          "OTEL_AWS_PROFILER_MAX_PAYLOAD_BYTES=20971520" \
          "OTEL_AWS_PROFILER_ENABLED=true"; do
    got=$(envof "${kv%%=*}")
    [ "$got" = "${kv#*=}" ] && pass "${kv%%=*}=$got" || fail "${kv%%=*}=${got:-<unset>}, want ${kv#*=}"
done

echo "=== 2. Telemetry for service ${SERVICE} reaches CloudWatch (up to 15 minutes)"
# count <aws args>: prints the number the call returns, summed over the CLI's pages, or nothing (with its error on
# stderr) when the call fails.
count() { local n; n=$(aws "$@" --output text) && awk '{for (i = 1; i <= NF; i++) { if ($i !~ /^[0-9]+$/) { bad = 1; exit 1 }; t += $i }} END {if (!bad) print t + 0}' <<< "$n"; }
# profile_types <start>: the profile types stored for the service, signed with the caller's credentials. They go to
# curl through its config on stdin, so they never appear in process arguments or output.
profile_types() (
    eval "$(aws configure export-credentials --format env)" || exit 1
    [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || { echo "no AWS credentials" >&2; exit 1; }
    body="{\"name\":\"__profile_type__\",\"matchers\":[\"{service_name=\\\"${SERVICE}\\\"}\"],\"start\":$(($1 * 1000)),\"end\":$(( $(date -u +%s) * 1000 ))}"
    out=$(mktemp); trap 'rm -f "$out"' EXIT
    code=$(printf 'user = "%s:%s"\nheader = "x-amz-security-token: %s"\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "${AWS_SESSION_TOKEN:-}" \
        | curl -sS -m 60 -K - -o "$out" -w '%{http_code}' -X POST "https://monitoring.${REGION}.amazonaws.com/querier.v1.QuerierService/LabelValues" \
            -H "Content-Type: application/json" --aws-sigv4 "aws:amz:${REGION}:monitoring" --data-binary "$body")
    [ "$code" = 200 ] || { echo "profiles query: HTTP ${code}" >&2; exit 1; }
    jq -r '(.names // []) | join(",")' "$out"
)
START=$(date -u +%s); metrics=0; traces=0; profiles=0
while [ $(( $(date -u +%s) - START )) -lt 900 ] && [ $((metrics * traces * profiles)) -eq 0 ]; do
    sleep 30
    if [ $metrics -eq 0 ] && [ "$(count cloudwatch list-metrics --region "$REGION" --namespace ApplicationSignals \
        --dimensions Name=Service,Value="$SERVICE" --query 'length(Metrics)')" -gt 0 ] 2>/dev/null; then
        metrics=1; pass "Application Signals metrics for ${SERVICE}"; fi
    if [ $traces -eq 0 ] && [ "$(count xray get-trace-summaries --region "$REGION" --start-time "$START" --end-time "$(date -u +%s)" \
        --filter-expression "service(\"${SERVICE}\")" --query 'length(TraceSummaries)')" -gt 0 ] 2>/dev/null; then
        traces=1; pass "X-Ray traces for ${SERVICE}"; fi
    if [ $profiles -eq 0 ]; then
        types=$(profile_types "$START")
        [ -n "$types" ] && { profiles=1; pass "profiles for ${SERVICE}: ${types}"; }
    fi
done
[ $metrics -eq 1 ] || fail "no Application Signals metrics for ${SERVICE}"
[ $traces -eq 1 ] || fail "no X-Ray traces for ${SERVICE}"
[ $profiles -eq 1 ] || fail "no profiles for ${SERVICE}"
[ $fails -eq 0 ] || { kubectl -n amazon-cloudwatch logs ds/cloudwatch-agent --tail=50 || true; }
echo "=== $([ $fails -eq 0 ] && echo "All checks passed." || echo "${fails} checks failed.")"
[ $fails -eq 0 ]
