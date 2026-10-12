#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins how the chart passes a customer DCGM metrics CSV to the DcgmExporter CR. By default,
# metricsConfigFrom selects the optional ConfigMap dcgm-exporter-metrics-config and
# metricsConfig holds the default list that is used while that ConfigMap does not exist.
# An inline metricsConfig replaces the default list, and metricsConfigFrom is then not rendered.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/dcgm_metrics_config.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

printf '  # customer list\nDCGM_FI_DEV_GPU_UTIL, gauge, GPU utilization (in %%).\nDCGM_FI_DEV_SM_CLOCK, gauge, SM clock frequency (in MHz).\n' > "${TMP_DIR}/extra.csv"

render() {
    local out="$1"; shift
    "$HELM" template "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        "$@" > "$out"
}

render "${TMP_DIR}/default.yaml"
render "${TMP_DIR}/inline.yaml" --set-file dcgmExporter.metricsConfig="${TMP_DIR}/extra.csv"
render "${TMP_DIR}/configmap.yaml" --set dcgmExporter.metricsConfigFrom.configMapKeyRef.name=my-dcgm \
    --set dcgmExporter.metricsConfigFrom.configMapKeyRef.key=gpu.csv \
    --set dcgmExporter.metricsConfigFrom.configMapKeyRef.optional=false
render "${TMP_DIR}/no-configmap.yaml" --set dcgmExporter.metricsConfigFrom.configMapKeyRef.name=
render "${TMP_DIR}/blank-inline.yaml" --set dcgmExporter.metricsConfig=" "
string_optional_rc=0
render "${TMP_DIR}/string-optional.yaml" --set-string dcgmExporter.metricsConfigFrom.configMapKeyRef.optional=true \
    2> "${TMP_DIR}/string-optional.err" || string_optional_rc=$?
no_key_rc=0
render "${TMP_DIR}/no-key.yaml" --set dcgmExporter.metricsConfigFrom.configMapKeyRef.key= 2> "${TMP_DIR}/no-key.err" || no_key_rc=$?

python3 - "${TMP_DIR}" "${no_key_rc}" "${string_optional_rc}" <<'PY'
import os
import sys

import yaml

tmp, no_key_rc, string_optional_rc = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
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


DEFAULT_LIST = """\
DCGM_FI_DEV_GPU_UTIL,      gauge, GPU utilization (in %).
DCGM_FI_DEV_MEM_COPY_UTIL, gauge, Memory utilization (in %).
DCGM_FI_DEV_FB_FREE, gauge, Framebuffer memory free (in MiB).
DCGM_FI_DEV_FB_USED, gauge, Framebuffer memory used (in MiB).
DCGM_FI_DEV_FB_TOTAL, gauge, Framebuffer memory used (in MiB).
DCGM_FI_DEV_FB_USED_PERCENT, gauge, Percentage used of Frame Buffer: Used/(Total - Reserved).
DCGM_FI_DEV_MEMORY_TEMP, gauge, Memory temperature (in C).
DCGM_FI_DEV_GPU_TEMP,    gauge, GPU temperature (in C).
DCGM_FI_DEV_POWER_USAGE,              gauge, Power draw (in W).
DCGM_FI_PROF_PIPE_TENSOR_ACTIVE, gauge, Tensor Core utilization (in %).
DCGM_FI_DRIVER_VERSION, label, Driver Version.
"""

print(f"\n{YELLOW}[default]{RESET}")
default = dcgm_spec("default.yaml")
check("metricsConfig is the full default list", default.get("metricsConfig") == DEFAULT_LIST)
check("metricsConfigFrom selects the optional dcgm-exporter-metrics-config ConfigMap",
      default.get("metricsConfigFrom") == {"configMapKeyRef": {
          "name": "dcgm-exporter-metrics-config", "key": "dcp-metrics-included.csv", "optional": True}})

print(f"\n{YELLOW}[metricsConfig]{RESET}")
inline = dcgm_spec("inline.yaml")
check("metricsConfig is the customer CSV, whitespace included", inline.get("metricsConfig") == read("extra.csv"))
check("no metricsConfigFrom", "metricsConfigFrom" not in inline)

print(f"\n{YELLOW}[metricsConfigFrom]{RESET}")
cmref = dcgm_spec("configmap.yaml")
check("metricsConfig keeps the default list", cmref.get("metricsConfig") == DEFAULT_LIST)
check("metricsConfigFrom selects a custom name, key and optional",
      cmref.get("metricsConfigFrom") == {"configMapKeyRef": {"name": "my-dcgm", "key": "gpu.csv", "optional": False}})
no_configmap = dcgm_spec("no-configmap.yaml")
check("an empty name renders no metricsConfigFrom and keeps the default list",
      "metricsConfigFrom" not in no_configmap and no_configmap.get("metricsConfig") == DEFAULT_LIST)
check("an empty key fails with a clear message", no_key_rc != 0 and "key is required" in read("no-key.err"))
check("a non-bool optional fails with a clear message",
      string_optional_rc != 0 and "optional must be true or false" in read("string-optional.err"))
blank = dcgm_spec("blank-inline.yaml")
check("a blank inline metricsConfig keeps the default list and metricsConfigFrom",
      blank.get("metricsConfig") == DEFAULT_LIST and blank.get("metricsConfigFrom") == default.get("metricsConfigFrom"))

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
