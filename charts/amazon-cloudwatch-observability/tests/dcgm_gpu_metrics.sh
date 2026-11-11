#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${CHART_DIR:-${SCRIPT_DIR}/..}" && pwd)"
TEMPLATE="${CHART_DIR}/templates/linux/dcgm-exporter-daemonset.yaml"
NAMESPACE="${NAMESPACE:-amazon-cloudwatch}"
PORT="${PORT:-9400}"

extract_csv() {
    awk '
        c==0 && index($0, "$metricsConfig") {
            s=$0; sub(/.*`/, "", s); c=1
            if (index(s, "`")) { sub(/`.*/, "", s); print s; exit }
            print s; next
        }
        c==1 {
            s=$0
            if (index(s, "`")) { sub(/`.*/, "", s); print s; exit }
            print s
        }
    ' "${TEMPLATE}"
}

POD="$(kubectl -n "${NAMESPACE}" get pods -o name | grep dcgm-exporter | head -1 || true)"
if [ -z "${POD}" ]; then
    echo "FAIL: no dcgm-exporter pod in namespace ${NAMESPACE} (is a GPU node present?)"
    exit 1
fi

phase="$(kubectl -n "${NAMESPACE}" get "${POD}" -o jsonpath='{.status.phase}')"
ready="$(kubectl -n "${NAMESPACE}" get "${POD}" -o jsonpath='{.status.containerStatuses[0].ready}')"
restarts="$(kubectl -n "${NAMESPACE}" get "${POD}" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
node="$(kubectl -n "${NAMESPACE}" get "${POD}" -o jsonpath='{.spec.nodeName}')"
echo "pod=${POD} node=${node} phase=${phase} ready=${ready} restarts=${restarts}"

if [ "${phase}" != "Running" ] || [ "${ready}" != "true" ]; then
    echo "FAIL: dcgm-exporter is not Running/ready (startup field rejection shows up here as CrashLoopBackOff)"
    kubectl -n "${NAMESPACE}" logs "${POD}" --tail=60 || true
    exit 1
fi

kubectl -n "${NAMESPACE}" port-forward "${POD}" "${PORT}:9400" >/dev/null 2>&1 &
PF=$!
trap 'kill ${PF} 2>/dev/null || true' EXIT
sleep 5

METRICS="$(curl -sk "https://localhost:${PORT}/metrics")"
if [ -z "${METRICS}" ]; then
    echo "FAIL: /metrics returned nothing"
    exit 1
fi

status=0
while IFS= read -r line; do
    [ -n "${line}" ] || continue
    name="$(printf '%s' "${line%%,*}" | tr -d '[:space:]')"
    type="$(printf '%s' "${line}" | awk -F, '{print $2}' | tr -d '[:space:]')"
    [ -n "${name}" ] || continue
    if [ "${type}" = "label" ]; then
        if printf '%s' "${METRICS}" | grep -q "${name}="; then
            echo "ok   label  ${name}"
        else
            echo "MISS label  ${name}"
            status=1
        fi
    else
        if printf '%s' "${METRICS}" | grep -qE "^${name}[{ ]"; then
            echo "ok   metric ${name}"
        else
            echo "MISS metric ${name}"
            status=1
        fi
    fi
done < <(extract_csv)

if [ "${status}" = 0 ]; then
    echo "PASS: dcgm-exporter is running on ${node} and every pinned field is present in /metrics"
else
    echo "FAIL: pinned fields missing from /metrics (see MISS lines above)"
fi
exit "${status}"
