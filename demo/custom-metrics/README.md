# Custom Metrics Demo — Container Insights OTLP Endpoint

Shows how a simple application sends custom metrics via the standard OTel SDK
and gets automatic Kubernetes + cloud enrichment from Container Insights.

## What the app does

Simulates an order-processing service that publishes:
- `orders.processed_total` (counter) — with `order.region` and `order.tier` attributes
- `orders.value_dollars` (histogram) — dollar value per order
- `carts.active` (up-down counter) — active shopping carts

The app sets **only** `service.name` and `service.version` on its Resource.
Everything else (pod, namespace, workload, node, cluster, cloud account, region, AZ)
is enriched server-side by the Container Insights collector.

## Deploy

```bash
# Build and load image (for kind/minikube)
docker build -t order-service-demo:latest .
kind load docker-image order-service-demo:latest  # or minikube image load

# Deploy
kubectl apply -f k8s.yaml
```

## What you'll see in CloudWatch

After ~30s, metrics appear in CloudWatch Metrics with these dimensions automatically added:

| Attribute | Source |
|-----------|--------|
| `k8s.pod.name` | k8sattributes (from connection IP) |
| `k8s.namespace.name` | k8sattributes |
| `k8s.deployment.name` | k8sattributes |
| `k8s.workload.name` / `k8s.workload.type` | workload derivation |
| `k8s.node.name` | node env var |
| `k8s.cluster.name` | helm values |
| `cloud.region` / `cloud.availability_zone` | EC2 resource detection |
| `cloud.account.id` | EC2 resource detection |
| `host.type` / `host.id` | EC2 resource detection |
| `cloud.resource_id` | EKS cluster ARN |
| `cloudwatch.pipeline` | `custom-otlp` |

Plus all the application attributes you set: `order.region`, `order.tier`.

## Endpoint

- gRPC: `container-insights-otlp.amazon-cloudwatch:4311`
- HTTP: `container-insights-otlp.amazon-cloudwatch:4312/v1/metrics`
