#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Validates the cert-manager option for the agent TLS certificates
# (agent.certManager.*). Renders the chart locally and never connects to a
# cluster; the cert-manager-enabled minikube scenario checks the issued
# certificates.
#
# The agent, cluster scraper, target allocator and scrape targets verify each
# other with the ca.crt of a different Secret than the one holding the peer's
# tls.crt, so every agent certificate must be signed by one CA. This test checks
# the rendered objects that guarantee it.
#
# Requires python3 with PyYAML.
#
# Run from the repo root:
#     bash charts/amazon-cloudwatch-observability/tests/cert_manager.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

render() {
    local name="$1"
    shift
    if ! "${HELM}" template amazon-cloudwatch-observability "${CHART_DIR}" \
        --namespace amazon-cloudwatch \
        --set clusterName=test-cluster \
        --set region=us-west-2 \
        "$@" >"${TMP_DIR}/${name}.yaml" 2>"${TMP_DIR}/${name}.err"; then
        echo "FAIL ${name}: helm template failed"
        cat "${TMP_DIR}/${name}.err"
        exit 1
    fi
}

render default
render enabled --set agent.certManager.enabled=true --set otelContainerInsights.enabled=true
render custom-agents --set agent.certManager.enabled=true \
    --set 'agents[0].name=cloudwatch-agent' --set 'agents[1].name=team-a-agent'
render issuer-ref --set agent.certManager.enabled=true \
    --set agent.certManager.issuerRef.kind=ClusterIssuer \
    --set agent.certManager.issuerRef.name=corp-ca \
    --set agent.certManager.issuerAnnotations.ignored=true
render expiry --set agent.certManager.enabled=true --set agent.autoGenerateCert.expiryDays=365
render annotations --set agent.certManager.enabled=true \
    --set agent.certManager.certificateAnnotations.team=observability \
    --set agent.certManager.issuerAnnotations.owner=platform

python3 - "${TMP_DIR}" <<'PY'
import pathlib
import sys

import yaml

out = pathlib.Path(sys.argv[1])
NS = "amazon-cloudwatch"
LEAF_SECRETS = [
    "amazon-cloudwatch-observability-agent-cert",
    "amazon-cloudwatch-observability-agent-server-cert",
    "amazon-cloudwatch-observability-agent-client-cert",
    "amazon-cloudwatch-observability-agent-ta-client-cert",
]
CA_SECRET = "amazon-cloudwatch-observability-agent-ca"

passed = 0
failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        print(f"PASS {name}")
        passed += 1
    else:
        print(f"FAIL {name}{': ' + str(detail) if detail else ''}")
        failed += 1


def load(case):
    return [d for d in yaml.safe_load_all((out / f"{case}.yaml").read_text()) if d]


def objects(docs, kind):
    return {d["metadata"]["name"]: d for d in docs if d.get("kind") == kind and d.get("apiVersion", "").startswith("cert-manager.io/")}


def agent_certs(docs):
    return {c["spec"]["secretName"]: c for c in objects(docs, "Certificate").values() if c["spec"]["secretName"] in LEAF_SECRETS}


def mounted_agent_secrets(docs):
    names = set()
    for d in docs:
        if d.get("kind") != "AmazonCloudWatchAgent":
            continue
        for v in d.get("spec", {}).get("volumes") or []:
            secret = (v.get("secret") or {}).get("secretName", "")
            if secret.startswith("amazon-cloudwatch-observability-agent-"):
                names.add(secret)
    return names


# Default: the agent certificates come from Helm, so there is no agent Certificate.
docs = load("default")
check("default: no agent Certificates", not agent_certs(docs), sorted(agent_certs(docs)))

# Enabled with the chart's issuer.
docs = load("enabled")
certs = agent_certs(docs)
issuers = objects(docs, "Issuer")
all_certs = objects(docs, "Certificate")
check("enabled: one Certificate per agent Secret", sorted(certs) == sorted(LEAF_SECRETS), sorted(certs))

ca = [c for c in all_certs.values() if c["spec"]["secretName"] == CA_SECRET]
check("enabled: one CA Certificate", len(ca) == 1 and ca[0]["spec"].get("isCA") is True, ca)
if ca:
    ref = ca[0]["spec"]["issuerRef"]
    bootstrap = issuers.get(ref.get("name"), {})
    check("enabled: CA Certificate is issued by a selfSigned Issuer",
          ref.get("kind") == "Issuer" and "selfSigned" in bootstrap.get("spec", {}), ref)

if ca:
    spec = ca[0]["spec"]
    check("enabled: CA lasts as long as autoGenerateCert", spec.get("duration") == "87600h", spec.get("duration"))
    check("enabled: CA keeps its private key on renewal",
          (spec.get("privateKey") or {}).get("rotationPolicy") == "Never", spec.get("privateKey"))
secrets = {d["metadata"]["name"] for d in docs if d.get("kind") == "Secret"}
check("enabled: the chart creates the CA Secret, so helm uninstall removes it", CA_SECRET in secrets)

ca_issuers = [i for i in issuers.values() if (i["spec"].get("ca") or {}).get("secretName") == CA_SECRET]
check("enabled: one CA Issuer backed by the CA Secret", len(ca_issuers) == 1, sorted(issuers))
ca_issuer = ca_issuers[0]["metadata"]["name"] if ca_issuers else None

for secret, cert in sorted(certs.items()):
    ref = cert["spec"]["issuerRef"]
    check(f"enabled: {secret} is signed by the CA Issuer",
          ref.get("kind") == "Issuer" and ref.get("name") == ca_issuer and not cert["spec"].get("isCA"), ref)

for secret, cert in sorted(certs.items()):
    check(f"enabled: {secret} lasts as long as autoGenerateCert", cert["spec"].get("duration") == "87600h", cert["spec"].get("duration"))

# A selfSigned Issuer must not sign an agent leaf certificate: each one would be
# its own CA, and no TLS client would trust its peer.
self_signed = {n for n, i in issuers.items() if "selfSigned" in i["spec"]}
check("enabled: no agent certificate is self-signed",
      not any(c["spec"]["issuerRef"]["name"] in self_signed for c in certs.values()))

# Upgrades from the old chart: the CA Issuer must not reuse the old selfSigned
# Issuer's name, or cert-manager keeps the self-signed certificates.
check("enabled: the old agent-ca Issuer name is not reused", "agent-ca" not in issuers, sorted(issuers))

# The chart creates the agent Secrets empty and cert-manager fills them. A volume that
# names the keys it needs (items) does not mount until they exist, so the pod waits for
# the certificate instead of starting without one.
for d in docs:
    spec = None
    if d.get("kind") in ("DaemonSet", "Deployment", "StatefulSet"):
        spec = d["spec"]["template"]["spec"]
    elif d.get("kind") == "AmazonCloudWatchAgent":
        spec = d.get("spec", {})
    for v in (spec or {}).get("volumes") or []:
        secret = v.get("secret") or {}
        if secret.get("secretName", "").startswith("amazon-cloudwatch-observability-agent-"):
            check(f"enabled: {d['metadata']['name']} volume {v['name']} waits for its certificate keys",
                  bool(secret.get("items")) and not secret.get("optional"), secret)

check("enabled: every agent Secret the agent mounts has a Certificate",
      mounted_agent_secrets(docs) <= set(certs), sorted(mounted_agent_secrets(docs) - set(certs)))

dns = set(certs["amazon-cloudwatch-observability-agent-cert"]["spec"]["dnsNames"])
for name in [
    "cloudwatch-agent-target-allocator-service",
    "cloudwatch-agent-cluster-scraper-target-allocator-service",
    "dcgm-exporter-service",
    "neuron-monitor-service",
    "node-exporter-service",
    "kube-state-metrics",
    f"kube-state-metrics.{NS}.svc",
]:
    check(f"enabled: agent-cert dnsNames include {name}", name in dns)

server_dns = set(certs["amazon-cloudwatch-observability-agent-server-cert"]["spec"]["dnsNames"])
check("enabled: agent-server-cert dnsNames include the agent Service",
      {"cloudwatch-agent", f"cloudwatch-agent.{NS}.svc"} <= server_dns, sorted(server_dns))

# One dnsNames entry per custom agent (#381).
docs = load("custom-agents")
dns = set(agent_certs(docs)["amazon-cloudwatch-observability-agent-cert"]["spec"]["dnsNames"])
for name in ["cloudwatch-agent-target-allocator-service", "team-a-agent-target-allocator-service"]:
    check(f"custom-agents: agent-cert dnsNames include {name}", name in dns, sorted(dns))

# A customer issuer replaces the chart's CA.
docs = load("issuer-ref")
certs = agent_certs(docs)
check("issuer-ref: one Certificate per agent Secret", sorted(certs) == sorted(LEAF_SECRETS), sorted(certs))
for secret, cert in sorted(certs.items()):
    check(f"issuer-ref: {secret} uses the customer issuer",
          cert["spec"]["issuerRef"] == {"kind": "ClusterIssuer", "name": "corp-ca"}, cert["spec"]["issuerRef"])
check("issuer-ref: the chart creates no agent Issuer", not objects(docs, "Issuer").keys() - {"amazon-cloudwatch-observability-selfsigned-issuer"},
      sorted(objects(docs, "Issuer")))
check("issuer-ref: the chart creates no CA Certificate",
      not [c for c in objects(docs, "Certificate").values() if c["spec"]["secretName"] == CA_SECRET])

# Annotations.
docs = load("annotations")
for secret, cert in sorted(agent_certs(docs).items()):
    check(f"annotations: {secret} has certificateAnnotations",
          (cert["metadata"].get("annotations") or {}).get("team") == "observability", cert["metadata"].get("annotations"))
ca_issuer = [i for i in objects(docs, "Issuer").values() if (i["spec"].get("ca") or {}).get("secretName") == CA_SECRET]
check("annotations: the CA Issuer has issuerAnnotations",
      bool(ca_issuer) and (ca_issuer[0]["metadata"].get("annotations") or {}).get("owner") == "platform")
bootstrap = objects(docs, "Issuer").get("agent-selfsigned", {})
check("annotations: the selfSigned Issuer has issuerAnnotations",
      (bootstrap.get("metadata", {}).get("annotations") or {}).get("owner") == "platform")

# expiryDays sets the cert-manager durations too.
docs = load("expiry")
durations = {c["spec"]["secretName"]: c["spec"].get("duration") for c in objects(docs, "Certificate").values()}
check("expiry: agent.autoGenerateCert.expiryDays sets every agent Certificate duration",
      set(durations.values()) == {"8760h"} and len(durations) == 5, durations)

print(f"cert-manager render tests: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
