#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Checks the default DcgmExporter field list: 3-field CSV lines with valid types and the
# expected names. Run from the repo root:
#     bash charts/amazon-cloudwatch-observability/tests/dcgm_metrics_csv.sh [chart-dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${1:-${SCRIPT_DIR}/..}" && pwd)"
HELM="${HELM:-helm}"
CHECK="${SCRIPT_DIR}/dcgm_metrics_csv.py"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL: python3 is required to parse metricsConfig"
    exit 1
fi

# The default field list: 51 fields and the driver version label.
expected_names=(
    DCGM_FI_DEV_GPU_UTIL
    DCGM_FI_DEV_MEM_COPY_UTIL
    DCGM_FI_DEV_FB_FREE
    DCGM_FI_DEV_FB_USED
    DCGM_FI_DEV_FB_TOTAL
    DCGM_FI_DEV_FB_USED_PERCENT
    DCGM_FI_DEV_MEMORY_TEMP
    DCGM_FI_DEV_GPU_TEMP
    DCGM_FI_DEV_POWER_USAGE
    DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION
    DCGM_FI_DEV_SM_CLOCK
    DCGM_FI_DEV_MEM_CLOCK
    DCGM_FI_PROF_PIPE_TENSOR_ACTIVE
    DCGM_FI_PROF_SM_UTIL_RATIO
    DCGM_FI_PROF_SM_OCCUPANCY_RATIO
    DCGM_FI_PROF_DRAM_UTIL_RATIO
    DCGM_FI_PROF_PCIE_TX_BYTES
    DCGM_FI_PROF_PCIE_RX_BYTES
    DCGM_FI_PROF_NVLINK_TX_BYTES
    DCGM_FI_PROF_NVLINK_RX_BYTES
    DCGM_EXP_XID_ERRORS_COUNT
    DCGM_EXP_CLOCK_EVENTS_COUNT
    DCGM_EXP_GPU_HEALTH_STATUS
    DCGM_FI_DEV_CLOCKS_EVENT_REASONS
    DCGM_FI_DEV_CLOCKS_EVENT_REASON_HW_THERM_SLOWDOWN_NS
    DCGM_FI_DEV_CLOCKS_EVENT_REASON_SW_THERM_SLOWDOWN_NS
    DCGM_FI_DEV_CLOCKS_EVENT_REASON_HW_POWER_BRAKE_SLOWDOWN_NS
    DCGM_FI_DEV_XID_ERROR
    DCGM_FI_DEV_ECC_SBE_VOL_TOTAL
    DCGM_FI_DEV_ECC_DBE_VOL_TOTAL
    DCGM_FI_DEV_PAGE_RETIRED_SBE_TOTAL
    DCGM_FI_DEV_PAGE_RETIRED_DBE_TOTAL
    DCGM_FI_DEV_PAGE_RETIRED_PENDING
    DCGM_FI_DEV_ROW_REMAP_CORRECTABLE_TOTAL
    DCGM_FI_DEV_ROW_REMAP_UNCORRECTABLE_TOTAL
    DCGM_FI_DEV_ROW_REMAP_FAILED
    DCGM_FI_DEV_PCIE_REPLAY_TOTAL
    DCGM_FI_DEV_GPU_TEMP_SLOWDOWN_CELSIUS
    DCGM_FI_DEV_GPU_TEMP_SHUTDOWN_CELSIUS
    DCGM_FI_DEV_BOARD_POWER_LIMIT_REQUESTED_WATTS
    DCGM_FI_DEV_BOARD_POWER_LIMIT_ENFORCED_WATTS
    DCGM_FI_DEV_PCIE_LINK_GEN
    DCGM_FI_DEV_PCIE_LINK_WIDTH
    DCGM_FI_DEV_PCIE_MAX_LINK_GEN
    DCGM_FI_DEV_PCIE_MAX_LINK_WIDTH
    DCGM_FI_DEV_NVLINK_REPLAY_ERROR_TOTAL
    DCGM_FI_DEV_NVLINK_RECOVERY_ERROR_TOTAL
    DCGM_FI_DEV_NVLINK_CRC_FLIT_ERROR_TOTAL
    DCGM_FI_DEV_NVLINK_CRC_DATA_ERROR_TOTAL
    DCGM_FI_DEV_NVLINK_RECOVERY_FAILED_TOTAL
    DCGM_FI_DEV_NVLINK_ECC_ERROR_TOTAL
    DCGM_FI_DRIVER_VERSION
)

echo "=== DCGM metricsConfig CSV shape ==="
echo "Chart: ${CHART_DIR}"

output_file="${TMP_DIR}/defaults.yaml"
error_file="${TMP_DIR}/defaults.err"
if ! "${HELM}" template dcgm-csv-test "${CHART_DIR}" \
    --namespace amazon-cloudwatch \
    --set region=us-west-2 \
    --set clusterName=test-cluster >"${output_file}" 2>"${error_file}"; then
    echo "FAIL defaults: helm template failed"
    tail -n 5 "${error_file}" | sed 's/^/    /'
    exit 1
fi

check_args=()
for name in "${expected_names[@]}"; do
    check_args+=(--name "${name}")
done

if report="$(python3 "${CHECK}" "${check_args[@]}" <"${output_file}")"; then
    echo "PASS defaults: ${report}"
else
    echo "FAIL defaults:"
    sed 's/^/    /' <<<"${report}"
    exit 1
fi
