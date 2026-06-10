# Container Insights Custom OTLP Endpoint

## Problem

Customers running thousands of workloads on EKS want to publish application-level metrics to CloudWatch without managing collector infrastructure, configuring exporters per-team, or manually attaching Kubernetes context to every metric. Today they either run their own OTel collectors (operational burden) or use Application Signals (limited to auto-instrumented traces/metrics, not custom business metrics).

## Proposal

Expose a node-local OTLP endpoint from the Container Insights agent that any workload can send custom metrics to. The agent automatically enriches all incoming telemetry with Kubernetes and cloud metadata before forwarding to CloudWatch — zero configuration on the application side beyond a single environment variable.

## Customer Experience

### Setup

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://container-insights-otlp.amazon-cloudwatch:4319"
```

One env var. No sidecars. No collector deployments. No IAM roles per application. No SDK plugins.

### Application Code

Standard OpenTelemetry SDK — any language, no AWS-specific dependencies:

```python
from opentelemetry import metrics
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.resources import Resource

resource = Resource.create({
    "service.name": "order-service",
    "service.version": "1.2.0",
})

exporter = OTLPMetricExporter(insecure=True)
reader = PeriodicExportingMetricReader(exporter, export_interval_millis=10_000)
provider = MeterProvider(resource=resource, metric_readers=[reader])
metrics.set_meter_provider(provider)

meter = metrics.get_meter("order-service", "1.2.0")

orders_processed = meter.create_counter("orders.processed_total", unit="1")
order_value = meter.create_histogram("orders.value_dollars", unit="USD")
active_carts = meter.create_up_down_counter("carts.active", unit="1")

orders_processed.add(1, {"order.region": "us-east", "order.tier": "premium"})
order_value.record(247.50, {"order.region": "us-east", "order.tier": "premium"})
active_carts.add(1, {"order.region": "us-east"})
```

### What the customer sends vs what arrives in CloudWatch

**Customer sends:**

```
orders.processed_total{order.region="us-east", order.tier="premium"} = 1
```

With resource: `service.name=order-service`, `service.version=1.2.0`

**What appears in CloudWatch — the metric arrives with the full enriched attribute set:**

```
Metric: orders.processed_total

── Datapoint attributes (customer-provided) ──────────────────────────
  order.region = "us-east"
  order.tier = "premium"

── Resource attributes (auto-enriched) ───────────────────────────────
  @resource.service.name = "order-service"
  @resource.service.version = "1.2.0"
  @resource.telemetry.sdk.language = "python"
  @resource.telemetry.sdk.name = "opentelemetry"
  @resource.telemetry.sdk.version = "1.25.0"

  # Pod identity (from k8sattributes via connection IP)
  @resource.k8s.pod.name = "order-service-7c54698bc8-kdpjp"
  @resource.k8s.pod.uid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  @resource.k8s.pod.ip = "10.0.145.86"
  @resource.k8s.namespace.name = "orders-team"
  @resource.k8s.pod.label.app = "order-service"

  # Workload identity (derived from pod owner references)
  @resource.k8s.deployment.name = "order-service"
  @resource.k8s.replicaset.name = "order-service-7c54698bc8"
  @resource.k8s.workload.name = "order-service"
  @resource.k8s.workload.type = "Deployment"

  # Node identity
  @resource.k8s.node.name = "ip-10-0-161-222.ec2.internal"
  @resource.k8s.node.uid = "f1e2d3c4-b5a6-7890-fedc-ba0987654321"
  @resource.k8s.node.label.eks.amazonaws.com/capacityType = "ON_DEMAND"
  @resource.k8s.node.label.eks.amazonaws.com/nodegroup = "standard-workers"
  @resource.k8s.node.label.kubernetes.io/arch = "amd64"
  @resource.k8s.node.label.kubernetes.io/os = "linux"
  @resource.k8s.node.label.topology.k8s.aws/zone-id = "use1-az1"

  # Cluster identity
  @resource.k8s.cluster.name = "production-cluster"
  @resource.cloud.resource_id = "arn:aws:eks:us-east-1:123456789012:cluster/production-cluster"

  # Cloud/host identity (from EC2 instance metadata)
  @resource.cloud.provider = "aws"
  @resource.cloud.platform = "aws_eks"
  @resource.cloud.region = "us-east-1"
  @resource.cloud.availability_zone = "us-east-1a"
  @resource.cloud.account.id = "123456789012"
  @resource.host.id = "i-0abc123def456789"
  @resource.host.name = "ip-10-0-161-222.ec2.internal"
  @resource.host.type = "m5.xlarge"
  @resource.host.image.id = "ami-0abcdef1234567890"

  # Pipeline attribution
  @instrumentation.cloudwatch.source = "cloudwatch-agent"
  @instrumentation.cloudwatch.solution = "k8s-otel-container-insights"
  @instrumentation.cloudwatch.pipeline = "custom-otlp"
  @instrumentation.@name = "order-service"
  @instrumentation.@version = "1.2.0"

── Derived fields ────────────────────────────────────────────────────
  @aws.account = "123456789012"
  @aws.region = "us-east-1"
```

The customer wrote 4 attributes. CloudWatch received 40+. Every application in the cluster gets the same dimensional model automatically — no per-team configuration, no enforcement overhead, no drift between services.

## Customer Validation

Demonstrated this capability to Citi who gave very positive feedback. Key takeaways from the session:

- Zero setup is critical — their teams manage hundreds of microservices and cannot add per-service collector configuration
- Automatic enrichment standardizes the dimensional model across all applications without enforcement overhead
- Using the standard OTel SDK (no AWS-specific code) means teams already instrumenting with OTel get CloudWatch integration for free

## Architecture

```
┌─────────────────────────────────────┐
│ Customer Pod (any namespace)        │
│                                     │
│  OTel SDK → OTLP gRPC/HTTP         │
│  env: OTEL_EXPORTER_OTLP_ENDPOINT  │
└──────────────┬──────────────────────┘
               │
               ▼
┌──────────────────────────────────────────────────┐
│ Service: container-insights-otlp                  │
│   type: ClusterIP                                 │
│   internalTrafficPolicy: Local                    │
│   ports: 4319 (gRPC), 4320 (HTTP)                │
│                                                   │
│   Routes to same-node agent only                  │
└──────────────┬───────────────────────────────────┘
               │
               ▼
┌──────────────────────────────────────────────────┐
│ CW Agent DaemonSet (per node)                     │
│                                                   │
│  OTLP Receiver (4319/4320)                        │
│    │                                              │
│    ▼                                              │
│  Enrichment Pipeline:                             │
│    1. set_unit (infer from metric name)           │
│    2. metricstarttime (preserve counters)         │
│    3. set_cluster_name                            │
│    4. k8sattributes (from: connection)            │
│       → pod, namespace, workload, labels          │
│    5. set_node_name                               │
│    6. resourcedetection (eks, ec2)                │
│       → region, AZ, account, host type            │
│    7. set_cloud_resource_id (cluster ARN)         │
│    8. k8sattributes/node (node labels)            │
│    9. set_scope (cloudwatch.pipeline: custom-otlp)│
│   10. set_workload (derive name + type)           │
│   11. awsattributelimit (cap at 150)              │
│   12. batch (500 metrics, 10s timeout)            │
│    │                                              │
│    ▼                                              │
│  OTLP/HTTP Exporter → CloudWatch Metrics          │
│    (SigV4 auth, same endpoint as CI metrics)      │
└──────────────────────────────────────────────────┘
```

### Key design decisions

- **Node-local routing** (`internalTrafficPolicy: Local`) ensures the agent can resolve the sending pod's identity from its connection IP — no ambiguity, no cross-node hops
- **k8sattributes with `from: connection`** resolves pod identity without any client-side configuration. The agent watches the K8s API for pods on its node, maps source IP → pod metadata
- **Same exporter as Container Insights metrics** — custom metrics appear alongside infrastructure metrics in CloudWatch with consistent dimensional model
- **Scope tagging** (`cloudwatch.pipeline: custom-otlp`) distinguishes custom metrics from infrastructure metrics in the backend

## Configuration

```yaml
otelContainerInsights:
  enabled: true
  customTelemetry:
    enabled: true          # default: true (when otelContainerInsights.enabled)
    grpcPort: 4319
    httpPort: 4320
    auth:
      enabled: false       # default: false — plaintext, no client cert required
```

## Optional: mTLS Authentication

For clusters requiring authorization control over which workloads can send metrics, mTLS can be enabled. This uses the OTel spec's standard env vars — still zero code changes.

### How it works

- Agent receiver requires a client certificate signed by the Container Insights CA
- Operator generates a shared client cert and places it as a Secret in opted-in namespaces
- K8s RBAC controls which namespaces can access the Secret — if you have it, you can send; if you don't, you can't
- Pod identity still comes from `k8sattributes` (connection IP), not the certificate

### Enable in helm values

```yaml
otelContainerInsights:
  customTelemetry:
    auth:
      enabled: true
```

### Platform team: opt in a namespace

```bash
kubectl label namespace orders-team container-insights-otlp=enabled
```

Operator copies the client cert Secret (`container-insights-otlp-client`) to that namespace.

### Application team: mount the cert

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
volumeMounts:
  - name: otlp-certs
    mountPath: /var/run/secrets/otlp
    readOnly: true
volumes:
  - name: otlp-certs
    secret:
      secretName: container-insights-otlp-client
```

All env vars are part of the OTel exporter specification — every compliant SDK reads them automatically. Zero code changes regardless of language.

### Security model

| Concern | Mechanism |
|---------|-----------|
| Authorization | mTLS — client cert signed by CI CA required |
| Access control | K8s RBAC — Secret only exists in opted-in namespaces |
| Identity | `k8sattributes` from connection IP (pod-level) |
| Revocation | Remove namespace label → operator deletes Secret |
| Rotation | Operator regenerates on helm upgrade, kubelet refreshes mounted Secrets |

## Scope

- **Metrics only** (v1) — traces and logs can follow the same pattern in future
- **EKS on EC2** — `resourcedetection` uses eks + ec2 detectors
- **Linux nodes** — matches existing Container Insights OTel scope
