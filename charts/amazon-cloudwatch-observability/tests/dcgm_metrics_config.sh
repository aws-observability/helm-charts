#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins how the chart passes a customer DCGM metrics CSV to the DcgmExporter CR. With
# nothing set, metricsConfig is the default list. An inline metricsConfig replaces it.
# metricsConfigFrom selects the customer's ConfigMap, and the default list stays in
# metricsConfig as the fallback. Setting both fails.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/dcgm_metrics_config.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

printf 'DCGM_FI_DEV_SM_CLOCK, gauge, SM clock frequency (in MHz).\n' > "${TMP_DIR}/extra.csv"

render() {
    local out="$1"; shift
    "$HELM" template "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        "$@" > "$out"
}

render "${TMP_DIR}/default.yaml"
render "${TMP_DIR}/inline.yaml" --set-file dcgmExporter.metricsConfig="${TMP_DIR}/extra.csv"
render "${TMP_DIR}/configmap.yaml" --set dcgmExporter.metricsConfigFrom.configMapKeyRef.name=my-dcgm
render "${TMP_DIR}/configmap-key.yaml" --set dcgmExporter.metricsConfigFrom.configMapKeyRef.name=my-dcgm \
    --set dcgmExporter.metricsConfigFrom.configMapKeyRef.key=gpu.csv
both_rc=0
render "${TMP_DIR}/both.yaml" --set-file dcgmExporter.metricsConfig="${TMP_DIR}/extra.csv" \
    --set dcgmExporter.metricsConfigFrom.configMapKeyRef.name=my-dcgm 2> "${TMP_DIR}/both.err" || both_rc=$?

python3 - "${TMP_DIR}" "${both_rc}" <<'PY'
import os
import sys

import yaml

tmp, both_rc = sys.argv[1], int(sys.argv[2])
GREEN, RED, YELLOW, RESET = "\033[0;32m", "\033[0;31m", "\033[1;33m", "\033[0m"
passed = failed = 0


def check(desc, ok):
    global passed, failed
    if ok:
        print(f"  {GREEN}PASS{RESET}: {desc}")
        passed += 1
    else:
        print(f"  {RED}FAIL{RESET}: {desc}")
        failed += 1


def docs(name):
    with open(os.path.join(tmp, name)) as f:
        return [d for d in yaml.safe_load_all(f) if d]


def dcgm_spec(name):
    return next((d["spec"] for d in docs(name) if d.get("kind") == "DcgmExporter"), {})


def read(name):
    with open(os.path.join(tmp, name)) as f:
        return f.read()


print(f"\n{YELLOW}[default]{RESET}")
default = dcgm_spec("default.yaml")
check("metricsConfig is the default list",
      "DCGM_FI_DEV_GPU_UTIL" in default.get("metricsConfig", "")
      and "DCGM_FI_DRIVER_VERSION" in default.get("metricsConfig", ""))
check("no metricsConfigFrom by default", "metricsConfigFrom" not in default)

print(f"\n{YELLOW}[metricsConfig]{RESET}")
inline = dcgm_spec("inline.yaml")
check("metricsConfig is the customer CSV", inline.get("metricsConfig", "").strip() == read("extra.csv").strip())
check("no metricsConfigFrom", "metricsConfigFrom" not in inline)

print(f"\n{YELLOW}[metricsConfigFrom]{RESET}")
cmref = dcgm_spec("configmap.yaml")
check("metricsConfig keeps the default list as the fallback", cmref.get("metricsConfig") == default.get("metricsConfig"))
check("metricsConfigFrom selects the default key",
      cmref.get("metricsConfigFrom") == {"configMapKeyRef": {"name": "my-dcgm", "key": "dcp-metrics-included.csv"}})
check("metricsConfigFrom selects a custom key",
      dcgm_spec("configmap-key.yaml").get("metricsConfigFrom") == {"configMapKeyRef": {"name": "my-dcgm", "key": "gpu.csv"}})

print(f"\n{YELLOW}[both]{RESET}")
check("setting both fails with a clear message",
      both_rc != 0 and "not both" in read("both.err"))

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
