#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Verifies that configurable strings cannot create extra YAML documents. This
# test renders locally and never connects to a cluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"
MARKER="yaml-document-injection-marker"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

python3 - "${TMP_DIR}" "${MARKER}" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
marker = sys.argv[2]


def injected(prefix, tail_api, tail_kind):
    return (
        f"{prefix}\n---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n"
        f"  name: {marker}\n---\napiVersion: {tail_api}\nkind: {tail_kind}\n"
        "metadata:\n  name: sink"
    )


def pair(control, attack):
    return {"control": control, "attack": attack}

cases = {
    "global-agent-name": pair(
        {"agent": {"name": "safe-agent"}},
        {"agent": {"name": injected("safe-agent", "cloudwatch.aws.amazon.com/v1alpha1", "AmazonCloudWatchAgent")}},
    ),
    "custom-agent-name": pair(
        {"agents": [{"name": "safe-agent"}]},
        {"agents": [{"name": injected("safe-agent", "cloudwatch.aws.amazon.com/v1alpha1", "AmazonCloudWatchAgent")}]},
    ),
    "custom-agent-priority-class": pair(
        {"agents": [{"name": "safe-agent", "priorityClassName": "system-node-critical"}]},
        {"agents": [{"name": "safe-agent", "priorityClassName": injected("system-node-critical", "cloudwatch.aws.amazon.com/v1alpha1", "AmazonCloudWatchAgent")}]},
    ),
    "custom-agent-update-strategy": pair(
        {"agents": [{"name": "safe-agent", "updateStrategy": {"type": "OnDelete"}}]},
        {"agents": [{"name": "safe-agent", "updateStrategy": {"type": injected("OnDelete", "cloudwatch.aws.amazon.com/v1alpha1", "AmazonCloudWatchAgent")}}]},
    ),
    "fluent-bit-priority-class": pair(
        {"containerLogs": {"fluentBit": {"priorityClassName": "system-node-critical"}}},
        {"containerLogs": {"fluentBit": {"priorityClassName": injected("system-node-critical", "apps/v1", "DaemonSet")}}},
    ),
    "fluent-bit-update-strategy": pair(
        {"containerLogs": {"fluentBit": {"updateStrategy": {"type": "OnDelete"}}}},
        {"containerLogs": {"fluentBit": {"updateStrategy": {"type": injected("OnDelete", "apps/v1", "DaemonSet")}}}},
    ),
    "fluent-bit-extra-file-key": pair(
        {"containerLogs": {"fluentBit": {"config": {"extraFiles": {"safe.conf": "[INPUT]\n  Name tail"}}}}},
        {"containerLogs": {"fluentBit": {"config": {"extraFiles": {injected("safe.conf", "v1", "ConfigMap"): "[INPUT]\n  Name tail"}}}}},
    ),
    "fluent-bit-windows-extra-file-key": pair(
        {"containerLogs": {"fluentBit": {"configWindows": {"extraFiles": {"safe.conf": "[INPUT]\n  Name tail"}}}}},
        {"containerLogs": {"fluentBit": {"configWindows": {"extraFiles": {injected("safe.conf", "v1", "ConfigMap"): "[INPUT]\n  Name tail"}}}}},
    ),
    "fluent-bit-extra-file-value": pair(
        {"containerLogs": {"fluentBit": {"config": {"extraFiles": {"safe.conf": "[INPUT]\n  Name tail"}}}}},
        {"containerLogs": {"fluentBit": {"config": {"extraFiles": {"safe.conf": injected("[INPUT]", "v1", "ConfigMap")}}}}},
    ),
    "fluent-bit-windows-extra-file-value": pair(
        {"containerLogs": {"fluentBit": {"configWindows": {"extraFiles": {"safe.conf": "[INPUT]\n  Name tail"}}}}},
        {"containerLogs": {"fluentBit": {"configWindows": {"extraFiles": {"safe.conf": injected("[INPUT]", "v1", "ConfigMap")}}}}},
    ),
}

for name, values in cases.items():
    for variant, document in values.items():
        (out / f"{name}.{variant}.json").write_text(json.dumps(document))

(out / "name-empty.json").write_text(json.dumps({"agents": [{"name": ""}]}))
(out / "name-36.json").write_text(json.dumps({"agent": {"name": "a" * 36}}))
(out / "name-37.json").write_text(json.dumps({"agent": {"name": "a" * 37}}))
PY

render() {
    local values_file="$1" output_file="$2" error_file="$3"
    "${HELM}" template security-test "${CHART_DIR}" \
        --namespace amazon-cloudwatch \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        --values "${values_file}" >"${output_file}" 2>"${error_file}"
}

pass_count=0
fail_count=0

for attack_file in "${TMP_DIR}"/*.attack.json; do
    case_name="$(basename "${attack_file}" .attack.json)"
    control_file="${TMP_DIR}/${case_name}.control.json"
    control_output="${TMP_DIR}/${case_name}.control.yaml"
    attack_output="${TMP_DIR}/${case_name}.attack.yaml"
    error_file="${TMP_DIR}/${case_name}.err"

    # A control failure means the test case itself is invalid and must not pass.
    if ! render "${control_file}" "${control_output}" "${error_file}"; then
        echo "FAIL ${case_name}: safe control did not render"
        cat "${error_file}"
        fail_count=$((fail_count + 1))
        continue
    fi

    if render "${attack_file}" "${attack_output}" "${error_file}"; then
        if grep -Eq "^  name:[[:space:]]+\"?${MARKER}\"?[[:space:]]*$" "${attack_output}"; then
            echo "FAIL ${case_name}: rendered an injected Kubernetes object"
            fail_count=$((fail_count + 1))
        else
            echo "PASS ${case_name}: no injected Kubernetes object"
            pass_count=$((pass_count + 1))
        fi
    else
        echo "PASS ${case_name}: Helm rejected the unsafe value"
        pass_count=$((pass_count + 1))
    fi
done

if render "${TMP_DIR}/name-empty.json" "${TMP_DIR}/name-empty.yaml" "${TMP_DIR}/name-empty.err"; then
    echo "PASS agent-name-empty: explicit empty name uses the default"
    pass_count=$((pass_count + 1))
else
    echo "FAIL agent-name-empty: schema-valid empty name was rejected"
    fail_count=$((fail_count + 1))
fi

if render "${TMP_DIR}/name-36.json" "${TMP_DIR}/name-36.yaml" "${TMP_DIR}/name-36.err"; then
    echo "PASS agent-name-boundary-36: 36 characters accepted"
    pass_count=$((pass_count + 1))
else
    echo "FAIL agent-name-boundary-36: 36 characters rejected"
    fail_count=$((fail_count + 1))
fi

if render "${TMP_DIR}/name-37.json" "${TMP_DIR}/name-37.yaml" "${TMP_DIR}/name-37.err"; then
    echo "FAIL agent-name-boundary-37: 37 characters accepted"
    fail_count=$((fail_count + 1))
else
    echo "PASS agent-name-boundary-37: 37 characters rejected"
    pass_count=$((pass_count + 1))
fi

echo "Security render tests: ${pass_count} passed, ${fail_count} failed"
test "${fail_count}" -eq 0
