#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins java.profiling.enabled: when "true" the operator's --auto-instrumentation-config carries it and
# the cloudwatch-agent config gains the otlp receiver on 0.0.0.0:4318. Template-level, no cluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
P=manager.autoInstrumentationConfiguration.java.profiling.enabled

render() {
    "$HELM" template "$CHART_DIR" -n "$1" --set region=us-west-2 --set clusterName=test-cluster "${@:2}"
}

render amazon-cloudwatch > "${TMP_DIR}/off.yaml"
render amazon-cloudwatch --set-string "$P=true" --set-string "${P%.enabled}.mode=cpu" \
    --set-string "${P%.enabled}.volume_size_limit=64Mi" > "${TMP_DIR}/on.yaml"
render amazon-cloudwatch --set-string "$P=false" > "${TMP_DIR}/false.yaml"
render amazon-cloudwatch --set-string "$P=true" --set otelContainerInsights.enabled=true > "${TMP_DIR}/ci.yaml"
fails=0
expect_fail() {
    if render "$1" "${@:3}" > /dev/null 2> "${TMP_DIR}/err" || ! grep -q "$2" "${TMP_DIR}/err"; then
        echo "  FAIL: expected '$2' for ${*:3}"; fails=$((fails + 1))
    else echo "  PASS: rejects ${*:3} (-n $1)"; fi
}
expect_fail other-namespace "requires the release namespace amazon-cloudwatch" --set-string "$P=true"
expect_fail amazon-cloudwatch "enabled must be a string" --set "$P=true"
expect_fail amazon-cloudwatch "java.profiling must be a map" --set-json "${P%.enabled}=\"true\""
expect_fail amazon-cloudwatch "window_seconds must be a string" --set-string "$P=true" --set "${P%.enabled}.window_seconds=30"

python3 - "${TMP_DIR}" "$fails" <<'PY'
import json
import sys
import yaml

tmp, failed = sys.argv[1], int(sys.argv[2])


def check(desc, ok):
    global failed
    print(f"  {'PASS' if ok else 'FAIL'}: {desc}")
    failed += 0 if ok else 1


def configs(name):
    docs = [d for d in yaml.safe_load_all(open(f"{tmp}/{name}.yaml")) if d]
    return docs, {d["metadata"]["name"]: json.loads(d["spec"]["config"]) for d in docs if d.get("kind") == "AmazonCloudWatchAgent"}


def rendered(name):
    docs, agents = configs(name)
    arg = next(a for d in docs if d.get("kind") == "Deployment" and d["metadata"]["name"].endswith("controller-manager")
               for a in d["spec"]["template"]["spec"]["containers"][0]["args"] if a.startswith("--auto-instrumentation-config="))
    return json.loads(arg.split("=", 1)[1])["java"], agents["cloudwatch-agent"]


off_java, off_agent = rendered("off")
on_java, on_agent = rendered("on")
false_java, false_agent = rendered("false")
ci = configs("ci")[1]
check("default: no java.profiling for the operator", "profiling" not in off_java)
check("default: no opentelemetry receiver on cloudwatch-agent", "opentelemetry" not in off_agent)
check('enabled: operator gets java.profiling with the extra and reserved keys',
      on_java.get("profiling") == {"enabled": "true", "mode": "cpu", "volume_size_limit": "64Mi"})
check("enabled: cloudwatch-agent gets otlp http_endpoint 0.0.0.0:4318",
      on_agent.get("opentelemetry") == {"collect": {"otlp": {"http_endpoint": "0.0.0.0:4318"}}})
check('"false": no opentelemetry receiver', "opentelemetry" not in false_agent)
check("otelContainerInsights: only cloudwatch-agent gets the receiver",
      [n for n, c in ci.items() if "opentelemetry" in c] == ["cloudwatch-agent"])
print("\n=== Summary ===")
print(f"{failed} checks failed." if failed else "All checks passed.")
sys.exit(1 if failed else 0)
PY
