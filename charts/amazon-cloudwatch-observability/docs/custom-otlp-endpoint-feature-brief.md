# Container Insights: Custom OTLP Metrics Endpoint

## What is it

A built-in, node-local OTLP endpoint that ships with Container Insights. Any workload in the cluster can send custom application metrics to CloudWatch — with automatic Kubernetes and cloud enrichment — by setting a single environment variable.

**It's on by default.** When a customer installs the CloudWatch EKS Add-On or the `amazon-cloudwatch-observability` Helm chart with OTel Container Insights enabled, the endpoint is already live and accepting metrics. No additional configuration, no extra installations, no collector sidecars.

```
Endpoint: container-insights-otlp.amazon-cloudwatch:4319 (gRPC)
          container-insights-otlp.amazon-cloudwatch:4320 (HTTP)
```

---

## Benefits

- **Zero infrastructure to manage** — no collector deployments, no sidecars, no per-team configuration. The collector is already running as part of Container Insights.
- **Automatic enrichment** — every metric gets ~40 Kubernetes and cloud attributes (pod, namespace, workload, node, cluster, region, account) without application-side effort. This standardizes the dimensional model across all services in the cluster.
- **Push-based, not pull-based** — applications push metrics when they're ready, not when a scraper decides to poll. No `/metrics` endpoint to expose, no scrape intervals to tune, no missed scrapes during pod restarts.
- **Works with any OTel SDK** — standard OTel protocol, no AWS-specific libraries. Teams already using OTel get CloudWatch integration for free.
- **Node-local, low latency** — traffic never leaves the node. The Service routes exclusively to the agent on the same node as the sending pod.
- **Secure by default** — mTLS out of the box. Access is controlled by which namespaces have the client cert.

## Where does the collector run

The OTLP endpoint is served by the **existing CloudWatch Agent DaemonSet** — the same agent that already collects Container Insights infrastructure metrics (cAdvisor, kubelet, node-exporter, etc.). There is no additional collector deployment.

```
Every node in the cluster:
┌─────────────────────────────────────────────────────┐
│ CloudWatch Agent (DaemonSet pod)                     │
│                                                      │
│  • Container Insights pipelines (existing)           │
│  • Custom OTLP receiver on port 4319/4320 (new)     │
│                                                      │
│  All pipelines share the same agent process,         │
│  same SigV4 credentials, same CloudWatch exporter.   │
└─────────────────────────────────────────────────────┘
```

The custom OTLP receiver is an additional pipeline within the same agent — no new pods, no new resource consumption beyond the metrics being processed.

## How is this better than Prometheus scraping

| | Push (OTLP endpoint) | Pull (Prometheus scrape) |
|--|---|---|
| **Setup for app teams** | 1 env var | Expose `/metrics` endpoint, annotate pods or create ServiceMonitor/PodMonitor |
| **Pod restarts** | No data loss — SDK buffers and retries | Missed scrape windows = data gaps |
| **High-cardinality metrics** | App controls what it sends | Scraper pulls everything exposed — cardinality explosions are silent until the bill arrives |
| **Firewall/network policy** | Outbound only from app pod | Inbound required — agent must reach app pod's metrics port |
| **Ephemeral/batch jobs** | Job pushes metrics before exit | Job may complete between scrape intervals — metrics lost |
| **SDK semantics** | Histograms, exemplars, exponential histograms (OTLP-native) | Limited to Prometheus exposition format (no exemplars in scrape, no exponential histograms) |
| **Discovery** | None needed — app decides to send | Requires service discovery config (labels, annotations, CRDs) |
| **Enrichment** | Automatic (connection IP → full pod/workload/cloud context) | Requires relabel_configs or additional processors |

Prometheus scraping remains valuable for infrastructure components that already expose `/metrics` (node-exporter, kube-state-metrics, etc.) — and Container Insights continues to use it for those. But for **application-owned custom metrics**, the push-based OTLP path is simpler, more reliable, and requires no infrastructure awareness from application teams.

---

## How it works

Customers configure their OTel SDK using standard environment variables defined in the [OpenTelemetry Protocol Exporter specification](https://opentelemetry.io/docs/specs/otel/protocol/exporter/). That's it — the SDK handles everything from there.

### Without auth (dev/test clusters)

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://container-insights-otlp.amazon-cloudwatch:4319"
  - name: OTEL_EXPORTER_OTLP_INSECURE
    value: "true"
```

### With mTLS auth (default, production)

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "https://container-insights-otlp.amazon-cloudwatch:4319"
  - name: OTEL_EXPORTER_OTLP_CERTIFICATE
    value: "/var/run/secrets/otlp/ca.crt"
  - name: OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE
    value: "/var/run/secrets/otlp/tls.crt"
  - name: OTEL_EXPORTER_OTLP_CLIENT_KEY
    value: "/var/run/secrets/otlp/tls.key"
```

All four env vars are defined in the OTel spec. Every spec-compliant SDK reads them automatically — **zero code changes** in the application.

### Application code (any language)

```go
// Go — one line, no endpoint or TLS config in code
exporter, _ := otlpmetricgrpc.New(ctx)
```

```java
// Java — one line, no endpoint or TLS config in code
OtlpGrpcMetricExporter exporter = OtlpGrpcMetricExporter.builder().build();
```

The SDK reads the endpoint and TLS credentials from the environment variables. The application never imports any AWS-specific libraries.

---

## Authentication

### mTLS (default)

mTLS is enabled by default. The agent's OTLP receiver requires clients to present a certificate signed by the Container Insights CA. This is configured using the OTel spec environment variables — no code changes required.

**SDK support for mTLS env vars:**

| Language | `OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE` / `CLIENT_KEY` support | Code changes needed |
|----------|--------------------------------------------------------------|-------------------|
| Go | Fully supported | None |
| Java | Fully supported | None |
| .NET | Fully supported | None |
| Python | Not yet implemented in SDK | ~10 lines to read cert files and build gRPC credentials |
| Node.js | Not yet implemented in SDK | ~8 lines for metadata generator |

The Python/Node.js limitation is an **OTel SDK implementation gap** — the spec defines these env vars, but those SDKs haven't implemented them yet. This is not a CloudWatch limitation. For those languages, customers can either:
- Add a small credential setup block (~10 lines)
- Or disable auth (`auth.type: none`) if their cluster doesn't require it

### Disabling auth

For dev/test clusters or languages without mTLS env var support, auth can be disabled via helm:

```bash
helm upgrade cw-otel amazon-cloudwatch-observability \
  --set otelContainerInsights.customTelemetry.auth.type=none
```

Or in values.yaml:

```yaml
otelContainerInsights:
  customTelemetry:
    auth:
      type: none
```

This switches the endpoint to plaintext — any pod can send without a certificate. The customer pod spec simplifies to just one env var:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://container-insights-otlp.amazon-cloudwatch:4319"
  - name: OTEL_EXPORTER_OTLP_INSECURE
    value: "true"
```

Not recommended for production.

### Configuration

```yaml
otelContainerInsights:
  customTelemetry:
    enabled: true        # endpoint is on (default)
    grpcPort: 4319
    httpPort: 4320
    auth:
      type: mtls         # mtls (default) | none
```

---

## Automatic Enrichment

This is the core value. The customer publishes a simple metric with a few business attributes. Container Insights enriches it with ~40 Kubernetes, cloud, and infrastructure attributes before it reaches CloudWatch.

### Customer publishes

```
orders.processed_total{order.region="us-east", order.tier="premium"} = 1
```

With resource attributes: `service.name=order-service`, `service.version=1.2.0`

### What arrives in CloudWatch

| Category | Attribute | Example value | Source |
|----------|-----------|---------------|--------|
| **Customer-provided** | `order.region` | `us-east` | Application code |
| | `order.tier` | `premium` | Application code |
| **Service identity** | `@resource.service.name` | `order-service` | OTel SDK resource |
| | `@resource.service.version` | `1.2.0` | OTel SDK resource |
| | `@resource.telemetry.sdk.language` | `go` | OTel SDK auto |
| | `@resource.telemetry.sdk.name` | `opentelemetry` | OTel SDK auto |
| | `@resource.telemetry.sdk.version` | `1.25.0` | OTel SDK auto |
| **Pod identity** | `@resource.k8s.pod.name` | `order-service-7c54698bc8-kdpjp` | k8sattributes (connection IP) |
| | `@resource.k8s.pod.uid` | `a1b2c3d4-e5f6-...` | k8sattributes |
| | `@resource.k8s.pod.ip` | `10.0.145.86` | k8sattributes |
| | `@resource.k8s.namespace.name` | `orders-team` | k8sattributes |
| | `@resource.k8s.pod.label.app` | `order-service` | k8sattributes |
| **Workload identity** | `@resource.k8s.deployment.name` | `order-service` | k8sattributes |
| | `@resource.k8s.replicaset.name` | `order-service-7c54698bc8` | k8sattributes |
| | `@resource.k8s.workload.name` | `order-service` | Workload derivation |
| | `@resource.k8s.workload.type` | `Deployment` | Workload derivation |
| **Node** | `@resource.k8s.node.name` | `ip-10-0-161-222.ec2.internal` | Node env var |
| | `@resource.k8s.node.uid` | `f1e2d3c4-...` | k8sattributes |
| | `@resource.k8s.node.label.eks.amazonaws.com/capacityType` | `ON_DEMAND` | k8sattributes |
| | `@resource.k8s.node.label.eks.amazonaws.com/nodegroup` | `standard-workers` | k8sattributes |
| | `@resource.k8s.node.label.kubernetes.io/arch` | `amd64` | k8sattributes |
| | `@resource.k8s.node.label.kubernetes.io/os` | `linux` | k8sattributes |
| | `@resource.k8s.node.label.topology.k8s.aws/zone-id` | `use1-az1` | k8sattributes |
| **Cluster** | `@resource.k8s.cluster.name` | `production-cluster` | Helm config |
| | `@resource.cloud.resource_id` | `arn:aws:eks:us-east-1:123456789012:cluster/production-cluster` | Derived |
| **Cloud / Host** | `@resource.cloud.provider` | `aws` | EC2 metadata |
| | `@resource.cloud.platform` | `aws_eks` | EKS detection |
| | `@resource.cloud.region` | `us-east-1` | EC2 metadata |
| | `@resource.cloud.availability_zone` | `us-east-1a` | EC2 metadata |
| | `@resource.cloud.account.id` | `123456789012` | EC2 metadata |
| | `@resource.host.id` | `i-0abc123def456789` | EC2 metadata |
| | `@resource.host.name` | `ip-10-0-161-222.ec2.internal` | EC2 metadata |
| | `@resource.host.type` | `m5.xlarge` | EC2 metadata |
| | `@resource.host.image.id` | `ami-0abcdef1234567890` | EC2 metadata |
| **Pipeline attribution** | `@instrumentation.cloudwatch.source` | `cloudwatch-agent` | Scope transform |
| | `@instrumentation.cloudwatch.solution` | `k8s-otel-container-insights` | Scope transform |
| | `@instrumentation.cloudwatch.pipeline` | `custom-otlp` | Scope transform |
| | `@instrumentation.@name` | `order-service` | OTel meter name |
| | `@instrumentation.@version` | `1.2.0` | OTel meter version |
| **Derived** | `@aws.account` | `123456789012` | CloudWatch derived |
| | `@aws.region` | `us-east-1` | CloudWatch derived |

**The customer wrote 4 attributes. CloudWatch received 40+.** Every application in the cluster gets this same standardized dimensional model automatically — no per-team configuration, no enforcement overhead, no drift between services.

---

## Bring Your Own Certificate

Customers who want to use their own CA (corporate PKI, Vault, etc.) instead of the auto-generated self-signed cert can do so via cert-manager integration:

```yaml
# Helm values
agent:
  autoGenerateCert:
    enabled: false
  certManager:
    enabled: true
    issuerRef:
      kind: ClusterIssuer
      name: my-corporate-ca    # customer's own CA issuer
```

cert-manager issues all certificates (including the OTLP client cert) from the customer's CA. Applications that already trust that CA don't need any additional CA cert distribution.

For customers without cert-manager, the default self-signed CA works out of the box with zero external dependencies.

---

## Summary

| Aspect | Detail |
|--------|--------|
| **Setup required** | None — endpoint is live by default |
| **Application code changes** | None (Go, Java, .NET) |
| **Configuration** | Standard OTel env vars ([spec](https://opentelemetry.io/docs/specs/otel/protocol/exporter/)) |
| **Auth default** | mTLS (client cert required) |
| **Auth override** | `auth.type: none` for plaintext |
| **Cert management** | Auto-generated self-signed, or bring-your-own via cert-manager |
| **Enrichment** | ~40 attributes (pod, workload, node, cluster, cloud) added automatically |
| **Pod identity** | Resolved from connection IP — no client-side config needed |
| **Routing** | Node-local only (`internalTrafficPolicy: Local`) — no cross-node hops |
| **CloudWatch namespace** | Same OTLP endpoint as Container Insights metrics |
| **AWS dependencies** | None in application code — standard OTel SDK only |

**Zero setup. Point your telemetry at the endpoint. CloudWatch does the rest.**
