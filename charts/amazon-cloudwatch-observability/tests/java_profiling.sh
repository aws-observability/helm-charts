#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins java.profiling: it reaches the operator in --auto-instrumentation-config, with the node agent's OTLP HTTP
# endpoint (from the otlp values) and the 20 MiB payload cap when enabled; its only key is enabled; and nothing else in the
# release changes, including every agent config. Template-level.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
P=manager.autoInstrumentationConfiguration.java.profiling.enabled

# Every render has the node agent's profiles pipeline on (otlp.profiles.enabled), which profiling requires, so a
# pair of renders differs only in java.profiling.
render() {
    "$HELM" template "$CHART_DIR" -n "$1" --set region=us-west-2 --set clusterName=test-cluster \
        --set otlp.profiles.enabled=true "${@:2}"
}

render amazon-cloudwatch > "${TMP_DIR}/off.yaml"
render amazon-cloudwatch --set-string "$P=true" > "${TMP_DIR}/on.yaml"
render amazon-cloudwatch --set-string "$P=false" > "${TMP_DIR}/false.yaml"
# The endpoint follows the otlp values and the release namespace.
render amazon-cloudwatch --set otlp.http.port=14318 --set-string "$P=true" > "${TMP_DIR}/port.yaml"
render observability --set-string "$P=true" > "${TMP_DIR}/namespace.yaml"
render amazon-cloudwatch --set otlp.grpc.enabled=false --set-string "$P=true" > "${TMP_DIR}/http-only.yaml"
# A renamed node agent: agent.name and its agents entry together.
render amazon-cloudwatch --set agent.name=node-agent --set-json 'agents=[{"name":"node-agent"}]' --set-string "$P=true" > "${TMP_DIR}/renamed.yaml"
# Without profiling, OTLP or HTTP may be off.
render amazon-cloudwatch --set otlp.enabled=false > "${TMP_DIR}/otlp-off.yaml"
render amazon-cloudwatch --set otlp.enabled=false --set-string "$P=false" > "${TMP_DIR}/otlp-off-false.yaml"
render amazon-cloudwatch --set otlp.http.enabled=false --set-string "$P=false" > "${TMP_DIR}/http-off-false.yaml"
# The chart default, otlp.profiles.enabled false, with profiling off.
render amazon-cloudwatch --set otlp.profiles.enabled=false --set-string "$P=false" > "${TMP_DIR}/profiles-off-false.yaml"
# Each pair differs only in java.profiling: the agent configs must be identical.
render amazon-cloudwatch --set otelContainerInsights.enabled=true > "${TMP_DIR}/ci-off.yaml"
render amazon-cloudwatch --set otelContainerInsights.enabled=true --set-string "$P=true" > "${TMP_DIR}/ci-on.yaml"
render amazon-cloudwatch --set agent.config=default:otel > "${TMP_DIR}/otel-off.yaml"
render amazon-cloudwatch --set agent.config=default:otel --set-string "$P=true" > "${TMP_DIR}/otel-on.yaml"
CUSTOM='agent.config={"opentelemetry":{"collect":{"otlp":{"http_endpoint":"0.0.0.0:4320"}}}}'
render amazon-cloudwatch --set-json "$CUSTOM" > "${TMP_DIR}/custom-off.yaml"
render amazon-cloudwatch --set-json "$CUSTOM" --set-string "$P=true" > "${TMP_DIR}/custom-on.yaml"
fails=0
expect_fail() {
    if render "$1" "${@:3}" > /dev/null 2> "${TMP_DIR}/err" || ! grep -q "$2" "${TMP_DIR}/err"; then
        echo "  FAIL: expected '$2' for ${*:3}"; fails=$((fails + 1))
    else echo "  PASS: rejects ${*:3} (-n $1)"; fi
}
# The schema is exactly one key, enabled: every other key fails, including the ones the chart itself passes.
for key in endpoint ENDPOINT export_endpoint max_payload_bytes MAX_PAYLOAD_BYTES volume_size_limit data_dir mode window_seconds Enabled; do
    expect_fail amazon-cloudwatch "java.profiling.$key is not a setting: java.profiling accepts only enabled" --set-string "$P=true" --set-string "${P%.enabled}.$key=1"
done
expect_fail amazon-cloudwatch "java.profiling.endpoint is not a setting" --set-string "$P=false" --set-string "${P%.enabled}.endpoint=http://elsewhere:4318"
expect_fail amazon-cloudwatch "java.profiling.window_seconds is not a setting" --set-string "$P=true" --set "${P%.enabled}.window_seconds=30"
# No OTLP HTTP receiver is rendered on the node agent: there is no endpoint to pass.
expect_fail amazon-cloudwatch "requires otlp.profiles.enabled" --set-string "$P=true" --set otlp.profiles.enabled=false
expect_fail amazon-cloudwatch "requires the node agent's OTLP HTTP endpoint" --set-string "$P=true" --set otlp.enabled=false
expect_fail amazon-cloudwatch "requires the node agent's OTLP HTTP endpoint" --set-string "$P=true" --set otlp.http.enabled=false
expect_fail amazon-cloudwatch "requires the node agent's OTLP HTTP endpoint" --set-string "$P=true" --set agent.enabled=false
expect_fail amazon-cloudwatch "requires the node agent's OTLP HTTP endpoint" --set-string "$P=true" \
    --set agent.name=cloudwatch-agent-cluster-scraper --set-json 'agents=[{"name":"cloudwatch-agent-cluster-scraper"}]'
expect_fail amazon-cloudwatch "requires the node agent's OTLP HTTP endpoint" --set-string "$P=true" --set agent.name=node-agent
expect_fail amazon-cloudwatch "requires the node agent's OTLP HTTP endpoint" --set-string "$P=true" --set-json 'agents=[{"name":"custom-agent"}]'
expect_fail amazon-cloudwatch "enabled must be a string" --set "$P=true"
expect_fail amazon-cloudwatch "java.profiling must be a map" --set-json "${P%.enabled}=\"true\""
expect_fail amazon-cloudwatch 'must be "true" or "false"' --set-string "$P=True"
expect_fail amazon-cloudwatch "java.profiling must be a map" --set "${P%.enabled}=false"
expect_fail amazon-cloudwatch "java.profiling must be a map" --set-json "${P%.enabled}=[]"

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


CERT_KINDS = {"Secret", "MutatingWebhookConfiguration", "ValidatingWebhookConfiguration"}


def rest(name):
    """Every rendered document, minus generated cert material, with the operator's java config argument blanked."""
    out = []
    for d in yaml.safe_load_all(open(f"{tmp}/{name}.yaml")):
        if not d or d.get("kind") in CERT_KINDS:
            continue
        if d.get("kind") == "Deployment" and d["metadata"]["name"].endswith("controller-manager"):
            c = d["spec"]["template"]["spec"]["containers"][0]
            c["args"] = [a if not a.startswith("--auto-instrumentation-config=") else "<arg>" for a in c["args"]]
            (d["spec"]["template"]["metadata"].get("annotations") or {}).pop("checksum/config", None)
        out.append(json.dumps(d, sort_keys=True))
    return sorted(out)


def agent_docs(name):
    return [d for d in yaml.safe_load_all(open(f"{tmp}/{name}.yaml")) if d and d.get("kind") == "AmazonCloudWatchAgent"]


def rendered(name):
    docs, agents = configs(name)
    arg = next(a for d in docs if d.get("kind") == "Deployment" and d["metadata"]["name"].endswith("controller-manager")
               for a in d["spec"]["template"]["spec"]["containers"][0]["args"] if a.startswith("--auto-instrumentation-config="))
    return json.loads(arg.split("=", 1)[1])["java"], agents


off_java, off_agents = rendered("off")
on_java, on_agents = rendered("on")
false_java, false_agents = rendered("false")
check("default: no java.profiling for the operator", "profiling" not in off_java)
ENDPOINT = "http://cloudwatch-agent.amazon-cloudwatch:4318/v1development/profiles"
check("enabled: the operator gets exactly enabled, the OTLP HTTP endpoint and the 20 MiB payload cap",
      on_java.get("profiling") == {"enabled": "true", "max_payload_bytes": "20971520", "endpoint": ENDPOINT})
check("otlp.http.port=14318: the endpoint uses it", rendered("port")[0]["profiling"].get("endpoint") == "http://cloudwatch-agent.amazon-cloudwatch:14318/v1development/profiles")
def served_http(name):
    """The rendered CR named by the endpoint's host, and its otlp/cw_k8s_otlp HTTP receiver config (None if absent)."""
    from urllib.parse import urlparse
    endpoint = urlparse(rendered(name)[0]["profiling"]["endpoint"])
    host, namespace = endpoint.hostname.split(".", 1)
    crs = [d for d in agent_docs(name) if d["metadata"]["name"] == host]
    if len(crs) != 1:
        return endpoint, None
    otel = crs[0]["spec"].get("otelConfig") or {}
    otel = yaml.safe_load(otel) if isinstance(otel, str) else otel
    return endpoint, ((otel.get("receivers") or {}).get("otlp/cw_k8s_otlp") or {}).get("protocols", {}).get("http")


for name in ("on", "port", "renamed", "http-only"):
    endpoint, http = served_http(name)
    check(f"{name}: the endpoint host is a rendered agent with the OTLP HTTP receiver, on the endpoint's port",
          http is not None and http["endpoint"].rsplit(":", 1)[1] == str(endpoint.port))
    check(f"{name}: the payload cap equals the receiver's max_request_body_size (otlp.httpMaxRequestBodyBytes)",
          http is not None and str(http.get("max_request_body_size")) == rendered(name)[0]["profiling"]["max_payload_bytes"])
check("renamed node agent: the endpoint uses its name", rendered("renamed")[0]["profiling"]["endpoint"] == "http://node-agent.amazon-cloudwatch:4318/v1development/profiles")
check("release namespace observability: the endpoint host carries it", rendered("namespace")[0]["profiling"].get("endpoint") == "http://cloudwatch-agent.observability:4318/v1development/profiles")
check("gRPC off, HTTP on: the endpoint is passed", rendered("http-only")[0]["profiling"].get("endpoint") == ENDPOINT)
check("otlp.enabled=false without profiling: renders, no java.profiling", "profiling" not in rendered("otlp-off")[0])
check('otlp.enabled=false, enabled "false": renders, no endpoint', rendered("otlp-off-false")[0].get("profiling") == {"enabled": "false"})
check('otlp.http.enabled=false, enabled "false": renders, no endpoint', rendered("http-off-false")[0].get("profiling") == {"enabled": "false"})
check('otlp.profiles.enabled=false, enabled "false": renders, no endpoint', rendered("profiles-off-false")[0].get("profiling") == {"enabled": "false"})
check("enabled: the rest of the java block is unchanged", {k: v for k, v in on_java.items() if k != "profiling"} == off_java)
check('"false": passed as given, without the endpoint or the payload cap', false_java.get("profiling") == {"enabled": "false"})
off_rest, on_rest = rest("off"), rest("on")
check("enabled: the rest of the release is identical (all but the operator's --auto-instrumentation-config and generated certs)",
      off_rest == on_rest and len(off_rest) > 10)
for name in ("", "ci-", "otel-", "custom-"):
    base, with_profiling = (agent_docs("off" if not name else name + "off"), agent_docs("on" if not name else name + "on"))
    check(f"agent configs identical with profiling on ({name.rstrip('-') or 'default config'})", base == with_profiling and base)
check("enabled: Application Signals sections unchanged",
      "application_signals" in on_agents["cloudwatch-agent"]["logs"]["metrics_collected"]
      and "application_signals" in on_agents["cloudwatch-agent"]["traces"]["traces_collected"])
check("enabled: no OTLP receiver added to the agent JSON config", "opentelemetry" not in on_agents["cloudwatch-agent"])
print("\n=== Summary ===")
print(f"{failed} checks failed." if failed else "All checks passed.")
sys.exit(1 if failed else 0)
PY
