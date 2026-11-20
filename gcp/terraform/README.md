# Amazon CloudWatch Observability

Installs the `amazon-cloudwatch-observability` Helm chart on an existing Google Kubernetes Engine (GKE) cluster, sending metrics and logs from the cluster to Amazon CloudWatch.

It deploys the CloudWatch agent and its operator, Fluent Bit, kube-state-metrics, node-exporter, and the DCGM (NVIDIA GPU) and Neuron exporters. The GPU and Neuron exporters only run on matching node types.

The module installs onto your existing cluster; it doesn't create one. It's deployed through Google Cloud Marketplace, which runs it with Infrastructure Manager.

**Linux nodes only.** Windows node pools aren't supported.

## Prerequisites

1. **A GKE cluster** in the project you deploy into.
2. **A deployment service account** with `roles/container.admin` on that project. The Marketplace form asks you to pick it.
3. **AWS access for the agent.** The agent authenticates to AWS with a Kubernetes service-account token (audience `sts.amazonaws.com`), exchanged for an IAM role through AWS STS. In AWS:
   - Create an IAM OIDC identity provider with:
     - Provider URL: your cluster's issuer, `https://container.googleapis.com/v1/projects/PROJECT_ID/locations/LOCATION/clusters/CLUSTER_NAME`
     - Audience: `sts.amazonaws.com`
   - Create an IAM role:
     - **Trust policy:** allows `sts:AssumeRoleWithWebIdentity` from that provider. Limit `sub` to `system:serviceaccount:amazon-cloudwatch:*`, or to your namespace if you change it.
     - **Permissions:** writing CloudWatch metrics and logs, for example the `CloudWatchAgentServerPolicy` managed policy.
   - You'll paste the role's ARN as `roleArn` below.

## Inputs

| Name | Required | Description |
|---|---|---|
| `project_id` | yes | GCP project that contains the cluster. |
| `cluster_name` | yes | Name of the existing GKE cluster. |
| `cluster_location` | yes | Zone or region of the cluster. |
| `helm_values_yaml` | yes | Overrides for the chart, as JSON or YAML (the form's **Configuration values** field). Only the keys you set change; everything else keeps the chart's defaults. Must set `clusterName`, `region` and `roleArn`. |
| `namespace` | no | Namespace to install into. Default `amazon-cloudwatch`. Helm creates it if it doesn't exist. |

The module always sets these, and they can't be overridden from `helm_values_yaml`:
- `k8sMode=GKE`
- the container image locations and tags, which Marketplace manages

### Minimum `helm_values_yaml`

```json
{
  "clusterName": "my-gke-cluster",
  "region": "us-east-1",
  "roleArn": "arn:aws:iam::123456789012:role/gke-cloudwatch-agent"
}
```

Add any other setting next to these, for example:

```json
{
  "clusterName": "my-gke-cluster",
  "region": "us-east-1",
  "roleArn": "arn:aws:iam::123456789012:role/gke-cloudwatch-agent",
  "containerInsights": { "enabled": false },
  "otelContainerInsights": { "enabled": true }
}
```

YAML in the same structure works too.

### What is checked

`terraform plan` only checks that `helm_values_yaml` is valid JSON or YAML and that `clusterName` and `roleArn` no longer contain the `REPLACE_WITH_*` placeholders. Keys and types are not checked against a schema: Helm accepts any key, and a misspelled key is silently ignored. `k8sMode` and the image settings are always overridden by the module, whatever the override says.

## One deployment per cluster

Install it **once per cluster**. The chart creates cluster-wide resources (CRDs, ClusterRoles, webhooks). A second Marketplace deployment on the same cluster fails because those resources already belong to the first one.

To change settings or move to a newer version, update the existing deployment instead of creating another.

## Uninstall

Deleting the Marketplace deployment removes the Helm release. The namespace is left in place; delete it with `kubectl delete namespace <namespace>` if you no longer need it.

The chart's CustomResourceDefinitions are left in place. Helm never deletes CRDs, because that would delete every resource of those types in the cluster. To remove them once nothing else uses them:

```bash
kubectl get crd -o name | grep cloudwatch.aws.amazon.com | xargs kubectl delete
```

## Local testing

```bash
terraform init
terraform apply \
  -var="project_id=PROJECT_ID" \
  -var="goog_cm_deployment_name=local-test" \
  -var="cluster_name=CLUSTER_NAME" \
  -var="cluster_location=CLUSTER_LOCATION" \
  -var="helm_values_yaml=$(cat my-values.yaml)"
```

`marketplace_test.tfvars` is used only by Marketplace's own validation, which creates a temporary test cluster (`create_cluster = true`). Real deployments never set `create_cluster`.
