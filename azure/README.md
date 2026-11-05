---
page_type: sample
languages:
- yaml
- json
products:
- azure-kubernetes-service
- azure-marketplace
---

# Amazon CloudWatch Observability CNAB package

This directory packages the `amazon-cloudwatch-observability` Helm chart as a CNAB (Cloud Native Application Bundle) for publishing as a Kubernetes application offer on Azure Marketplace, following the structure demonstrated by [`kubernetes-offer-samples/samples/k8s-offer-azure-vote`](../kubernetes-offer-samples/samples/k8s-offer-azure-vote).

## Layout

- `manifest.yaml` — CNAB manifest referencing the Helm chart, ARM template, and UI definition.
- `mainTemplate.json` — ARM template that provisions (or reuses) an AKS cluster and installs the chart as a cluster extension.
- `createUIDefinition.json` — Azure Marketplace portal UI definition collecting cluster and application settings.
- `amazon-cloudwatch-observability/` — the Helm chart being packaged.

## Application settings

The UI collects the following values, which are passed through to the Helm chart's `values.yaml` via the cluster extension's `configurationSettings` / `configurationProtectedSettings`:

| Setting | values.yaml key | Protected | Description |
|---|---|---|---|
| CloudWatch Cluster Name | `clusterName` | No | Identifies the cluster in CloudWatch Container Insights. |
| AWS Region | `region` | No | AWS region metrics/logs are sent to. |
| IAM Role ARN | `roleArn` | Yes | IAM role ARN for AKS workload-identity federation. |
| — | `k8sMode` | No | Hardcoded to `AKS` in `mainTemplate.json`. |

## Publishing

1. Update `registryServer` in `manifest.yaml` to your Azure Container Registry.
2. Push the chart's container images to that registry.
3. Package and validate the CNAB bundle per the [Azure Marketplace Kubernetes app documentation](https://learn.microsoft.com/en-us/partner-center/marketplace/azure-container-technical-assets).
4. Upload the resulting bundle to Partner Center as a Kubernetes app offer.
