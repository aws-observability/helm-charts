# Custom OTLP Endpoint — mTLS Authentication Architecture

## Overview

The Container Insights custom OTLP endpoint allows customers to send application
metrics from their workloads to CloudWatch via a node-local OTel receiver. The agent
enriches metrics with Kubernetes and cloud metadata automatically.

This document describes the mTLS-based authentication layer that controls which
workloads can send to this endpoint.

## Design Principles

1. **Zero application code changes** — auth is configured entirely via OTel spec env vars
2. **K8s RBAC is the access control** — Secret visibility per namespace = authorization
3. **Single shared client cert** — identity comes from `k8sattributes` (connection IP), not the cert
4. **No external dependencies** — no cert-manager, no OIDC, no service mesh required

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Cluster                                                                      │
│                                                                              │
│  ┌──────────────────────────────────────────────────────┐                   │
│  │ amazon-cloudwatch namespace                           │                   │
│  │                                                       │                   │
│  │  ┌─────────────────────┐   ┌──────────────────────┐  │                   │
│  │  │ CA Secret           │   │ Client Cert Secret   │  │                   │
│  │  │ (agent-cert)        │   │ (otlp-client-cert)   │  │                   │
│  │  │  - ca.crt           │   │  - ca.crt            │  │                   │
│  │  │  - tls.crt          │   │  - tls.crt           │  │                   │
│  │  │  - tls.key          │   │  - tls.key           │  │                   │
│  │  └─────────────────────┘   └──────────┬───────────┘  │                   │
│  │                                        │              │                   │
│  │  ┌─────────────────────────────────┐   │              │                   │
│  │  │ CW Agent DaemonSet              │   │              │                   │
│  │  │                                 │   │              │                   │
│  │  │  OTLP Receiver (port 4319)      │   │              │                   │
│  │  │    TLS:                         │   │              │                   │
│  │  │      server cert: server.crt    │   │              │                   │
│  │  │      client_ca_file: ca.crt ────┼───┼── verifies   │                   │
│  │  │                                 │   │   client     │                   │
│  │  │  k8sattributes (from:connection)│   │   certs      │                   │
│  │  │    → pod, namespace, workload   │   │              │                   │
│  │  └─────────────────────────────────┘   │              │                   │
│  │                                        │              │                   │
│  │  Operator/Controller                   │              │                   │
│  │    watches namespaces with label       │              │                   │
│  │    copies client cert Secret ──────────┘              │                   │
│  └──────────────────────────────────────────────────────┘                   │
│                                                                              │
│  ┌─────────────────────────────────────────────┐                            │
│  │ orders-team namespace                        │                            │
│  │   label: container-insights-otlp: enabled    │                            │
│  │                                              │                            │
│  │  ┌────────────────────────────┐              │                            │
│  │  │ Client Cert Secret (copy)  │              │                            │
│  │  │ container-insights-otlp-   │              │                            │
│  │  │ client                     │              │                            │
│  │  │  - ca.crt                  │              │                            │
│  │  │  - tls.crt                 │              │                            │
│  │  │  - tls.key                 │              │                            │
│  │  └────────────┬───────────────┘              │                            │
│  │               │                              │                            │
│  │  ┌────────────┴───────────────────────────┐  │                            │
│  │  │ order-service Pod                      │  │                            │
│  │  │                                        │  │                            │
│  │  │  env:                                  │  │                            │
│  │  │   OTEL_EXPORTER_OTLP_ENDPOINT=         │  │                            │
│  │  │     https://container-insights-otlp    │  │                            │
│  │  │     .amazon-cloudwatch:4319            │  │                            │
│  │  │   OTEL_EXPORTER_OTLP_CERTIFICATE=      │  │                            │
│  │  │     /var/run/secrets/otlp/ca.crt       │  │                            │
│  │  │   OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE│  │                            │
│  │  │     =/var/run/secrets/otlp/tls.crt     │  │                            │
│  │  │   OTEL_EXPORTER_OTLP_CLIENT_KEY=       │  │                            │
│  │  │     /var/run/secrets/otlp/tls.key      │  │                            │
│  │  │                                        │  │                            │
│  │  │  volume: otlp-certs (from Secret)      │  │                            │
│  │  │                                        │  │                            │
│  │  │  Application code: UNCHANGED           │  │                            │
│  │  │    OTLPMetricExporter()                │  │                            │
│  │  │    reads env vars automatically        │  │                            │
│  │  └────────────────────────────────────────┘  │                            │
│  └──────────────────────────────────────────────┘                            │
│                                                                              │
│  ┌──────────────────────────────────────────┐                               │
│  │ payments-team namespace                   │                               │
│  │   (NO label → no Secret → no access)     │                               │
│  └──────────────────────────────────────────┘                               │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Authentication Flow

1. Agent starts with TLS + mTLS on the OTLP receiver (port 4319/4320)
2. Client pod has the shared client cert mounted from a Secret in its namespace
3. SDK reads `OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE` / `CLIENT_KEY` env vars (OTel spec)
4. TLS handshake: agent verifies client cert is signed by our CA → **authorized**
5. `k8sattributes` processor resolves source IP → pod name, namespace, workload → **identified**
6. Metrics flow through enrichment pipeline → CloudWatch

## Security Model

| Concern | Mechanism |
|---------|-----------|
| **Authorization** (can this pod send?) | mTLS — client cert signed by our CA required |
| **Access control** (who gets the cert?) | K8s RBAC — Secret only exists in opted-in namespaces |
| **Identity** (who sent this metric?) | `k8sattributes` from connection IP (not cert-derived) |
| **Revocation** (remove access) | Delete the Secret from the namespace / remove label |
| **Rotation** | Operator regenerates cert on schedule, updates all Secrets |
| **Spoofing** | Cert prevents unauthorized senders; connection IP prevents identity spoofing |

### Why one shared cert is sufficient

The cert answers: "are you authorized to send?" (binary yes/no).
The connection IP answers: "who exactly are you?" (pod, namespace, workload).

Per-namespace or per-pod certs would add identity to the cert, but that identity is
redundant with `k8sattributes` which is already more granular (pod-level) and doesn't
require any client-side cert management. The cert is purely a gate key.

### Threat model

| Threat | Mitigation |
|--------|-----------|
| Unauthorized pod sends metrics | No client cert → TLS handshake rejected |
| Pod spoofs another pod's identity | `k8sattributes` uses source IP assigned by CNI; pod IPs aren't spoofable within a cluster |
| Client cert leaked outside cluster | Cert is cluster-internal; agent only listens on cluster network (no ingress) |
| Compromised namespace | Remove label → operator deletes Secret → immediate revocation |
| Cert expiry | Operator rotates before expiry, updates all namespace Secrets atomically |

## Customer Experience

### Opt-in (platform team)

```bash
kubectl label namespace orders-team container-insights-otlp=enabled
```

Operator automatically creates `container-insights-otlp-client` Secret in that namespace.

### Application setup (dev team)

Add to pod spec — no code changes:

```yaml
containers:
  - name: my-app
    env:
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: "https://container-insights-otlp.amazon-cloudwatch:4319"
      - name: OTEL_EXPORTER_OTLP_CERTIFICATE
        value: "/var/run/secrets/otlp/ca.crt"
      - name: OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE
        value: "/var/run/secrets/otlp/tls.crt"
      - name: OTEL_EXPORTER_OTLP_CLIENT_KEY
        value: "/var/run/secrets/otlp/tls.key"
    volumeMounts:
      - name: otlp-certs
        mountPath: /var/run/secrets/otlp
        readOnly: true
volumes:
  - name: otlp-certs
    secret:
      secretName: container-insights-otlp-client
```

Application code remains:
```python
# No endpoint, no auth, no TLS config in code
# Everything is read from env vars by the SDK automatically
exporter = OTLPMetricExporter()
```

### Optional: webhook auto-injection (v2)

For truly zero pod-spec changes, extend the operator webhook to auto-inject the
volume + env vars for pods in labeled namespaces. Customer experience becomes:

```yaml
# Only this is needed:
metadata:
  namespace: orders-team  # already labeled
```

## Implementation Plan

### Phase 1: TLS on the receiver (agent-side)

**Files to modify:**

- `templates/linux/_otel-container-insights-config.tpl` — add TLS block to OTLP receiver

```yaml
otlp/cw_k8s_ci_v0_custom:
  protocols:
    grpc:
      endpoint: 0.0.0.0:4319
      tls:
        cert_file: /etc/amazon-cloudwatch-observability-agent-server-cert/server.crt
        key_file: /etc/amazon-cloudwatch-observability-agent-server-cert/server.key
        client_ca_file: /etc/amazon-cloudwatch-observability-agent-cert/tls-ca.crt
    http:
      endpoint: 0.0.0.0:4320
      tls:
        cert_file: /etc/amazon-cloudwatch-observability-agent-server-cert/server.crt
        key_file: /etc/amazon-cloudwatch-observability-agent-server-cert/server.key
        client_ca_file: /etc/amazon-cloudwatch-observability-agent-cert/tls-ca.crt
```

The `client_ca_file` enables mTLS. The agent already has these cert files mounted.
No new volumes, secrets, or RBAC needed on the agent side.

- `templates/linux/container-insights-otlp-service.yaml` — port stays 4319/4320 (unchanged)
- `templates/linux/cloudwatch-agent-custom-resource.yaml` — cert SAN already includes
  `container-insights-otlp` (done in prior work)

### Phase 2: Client cert generation

**Files to modify:**

- `templates/linux/cloudwatch-agent-custom-resource.yaml` — generate a client cert
  signed by the same CA, stored as a new Secret

Add after existing cert generation:

```go-template
{{- if and .Values.otelContainerInsights.enabled .Values.otelContainerInsights.customTelemetry.enabled }}
{{- $otlpClientCert := genSignedCert "otlp-client" nil nil (.Values.agent.autoGenerateCert.expiryDays | int) $ca }}
apiVersion: v1
kind: Secret
metadata:
  name: container-insights-otlp-client
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "amazon-cloudwatch-observability.labels" . | nindent 4 }}
type: kubernetes.io/tls
data:
  ca.crt: {{ $ca.Cert | b64enc }}
  tls.crt: {{ $otlpClientCert.Cert | b64enc }}
  tls.key: {{ $otlpClientCert.Key | b64enc }}
{{- end }}
```

This creates the client cert in `amazon-cloudwatch` namespace. It can be
directly mounted by pods in that namespace (for testing), or distributed
to other namespaces by the operator.

### Phase 3: Secret distribution to opted-in namespaces

**Option A: Operator controller (preferred for production)**

Add a controller in the CW Agent Operator that:
1. Watches namespaces with label `container-insights-otlp: enabled`
2. On label add: copies `container-insights-otlp-client` Secret to that namespace
3. On label remove: deletes the Secret from that namespace
4. On source Secret update (rotation): updates all copies

This requires operator code changes (Go) — not helm template changes.

**Option B: Helm hook + CronJob (simpler, less reactive)**

A Job that runs on install/upgrade and copies the Secret to labeled namespaces.
Less ideal because it doesn't react to new namespaces being labeled.

**Option C: Manual copy (v1 — no operator changes)**

Document that platform teams copy the Secret:

```bash
kubectl get secret container-insights-otlp-client -n amazon-cloudwatch -o yaml \
  | sed 's/namespace: amazon-cloudwatch/namespace: orders-team/' \
  | kubectl apply -f -
```

Acceptable for v1/demo. Operator-based distribution for GA.

### Phase 4: values.yaml configuration

Add auth config option:

```yaml
otelContainerInsights:
  customTelemetry:
    enabled: true
    grpcPort: 4319
    httpPort: 4320
    auth:
      enabled: true    # enables mTLS on receiver
      # When false, receiver accepts plaintext (current behavior) — useful
      # for dev/test clusters where auth overhead isn't needed.
```

### Phase 5 (future): Webhook auto-injection

Extend the operator's mutating webhook to:
1. Check if pod is in a namespace with `container-insights-otlp: enabled`
2. If yes, inject:
   - Volume mount for `container-insights-otlp-client` Secret
   - `OTEL_EXPORTER_OTLP_ENDPOINT` env var
   - `OTEL_EXPORTER_OTLP_CERTIFICATE` env var
   - `OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE` env var
   - `OTEL_EXPORTER_OTLP_CLIENT_KEY` env var

Customer experience: zero pod-spec changes, zero code changes.

## Configuration Matrix

| `customTelemetry.enabled` | `customTelemetry.auth.enabled` | Behavior |
|---------------------------|--------------------------------|----------|
| `false` | N/A | No OTLP receiver |
| `true` | `false` | Plaintext receiver (no auth, current state) |
| `true` | `true` | mTLS receiver (client cert required) |

## Cert Rotation Strategy

1. Helm chart generates certs with configurable expiry (`agent.autoGenerateCert.expiryDays`)
2. On `helm upgrade`, new certs are generated (existing helm behavior)
3. Agent pods pick up new server cert on restart
4. Client cert Secret is updated in source namespace
5. Operator propagates to all opted-in namespaces
6. Client pods pick up new cert via Secret volume mount (kubelet refreshes projected
   secrets within ~1 minute without pod restart)

## Comparison with Alternatives

| Approach | Code changes | Dependencies | Scalability | Access control |
|----------|-------------|--------------|-------------|----------------|
| **mTLS (this design)** | None | None | O(1) per request | K8s RBAC on Secrets |
| Bearer token (OIDC) | Python/Node.js need code | OIDC issuer access | O(1) per request | Token audience |
| Bearer token (TokenReview) | Python/Node.js need code | API server | O(pods) API calls/min | SA-based |
| NetworkPolicy | None | CNI support | N/A | Namespace labels |
| No auth (current) | None | None | N/A | None |

## Open Questions

1. **Default for `auth.enabled`** — should mTLS be the default (`true`) or opt-in?
   If default-true, the current plaintext demo breaks without cert setup.
   Recommendation: default `false` for v1, flip to `true` when webhook injection lands.

2. **Client cert CN/SAN** — should the client cert have a meaningful CN (e.g., 
   `container-insights-otlp-client`) or be blank? Doesn't affect security (identity
   comes from k8sattributes) but useful for audit logs.

3. **Multi-cluster** — if customers want to send cross-cluster (e.g., from a workload
   cluster to a monitoring cluster), the shared cert model still works but the Secret
   distribution becomes cross-cluster. Out of scope for v1.

4. **Metrics quotas/rate limiting** — mTLS controls who can send, but not how much.
   Per-namespace rate limiting could be added as a processor. Out of scope for v1.
