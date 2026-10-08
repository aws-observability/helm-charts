# AWS
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

## Introduction
The Amazon CloudWatch Observability Helm Chart provides easy mechanisms to setup the [Amazon CloudWatch Agent Operator](https://github.com/aws/amazon-cloudwatch-agent-operator) to manage the [CloudWatch Agent](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Install-CloudWatch-Agent.html) on Kubernetes clusters.

## Getting Started
Full instructions can be found in the [AWS documentation](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/install-CloudWatch-Observability-EKS-addon.html)

### Installation
1. You must have Helm installed to use this chart. For more information about installing Helm, see the [Helm documentation](https://helm.sh/docs/).
2. After you have installed Helm, enter the following commands. Replace my-cluster-name with the name of your cluster, and replace my-cluster-region with the Region that the cluster runs in.

```bash
helm repo add aws-observability https://aws-observability.github.io/helm-charts
helm repo update aws-observability
helm install --wait --create-namespace --namespace amazon-cloudwatch amazon-cloudwatch aws-observability/amazon-cloudwatch-observability --set clusterName=my-cluster-name --set region=my-cluster-region
```

By default, the helm chart will enable [Container Insights](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ContainerInsights.html) enhanced observability with container logging, and [CloudWatch Application Signals](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Application-Monitoring-Sections.html). This helps you to collect infrastructure metrics, application performance telemetry, and container logs from the Amazon EKS cluster.

## vLLM model-server metrics

Set under `otelContainerInsights.solutions.vllm`, on by default. The agent on each node
scrapes the vLLM servers on that node; the cluster-scraper is not involved.

### Which vLLM servers are scraped

One scrape job finds both kinds, with nothing to configure:

- **KServe:** the `kserve-container` of an InferenceService's predictor pods (labels
  `serving.kserve.io/inferenceservice` and `component: predictor`), whatever its image.
  Transformer and explainer pods are not scraped.
- **Anything else:** any container whose image name contains `vllm`
  (`vllm/vllm-openai`, or a mirror of it).

The chart reads no scrape labels or annotations of its own from customer pods. A vLLM server
built from an image without `vllm` in its name is not found automatically; scrape it with a
PodMonitor or a custom agent configuration.

The port is resolved in this order, highest precedence first:

1. on KServe pods, the serving runtime's `prometheus.kserve.io/port` (and `prometheus.kserve.io/path`)
2. the port the container declares
3. the server's default: 8080 for KServe, 8000 for `vllm serve`

On KServe pods only the `kserve-container` is scraped, never the queue-proxy, which serves the
model server's metrics a second time.

Every target carries the resource attribute `aws.service.type = ai_inference`, so a consumer
can find model-serving telemetry without knowing which metric names belong to it. vLLM only
serves inference, so the value is fixed.

### The vLLM metric service name

`service.name` on the engine's metrics is resolved in this order, highest precedence first:

1. the InferenceService name
2. the workload name — Deployment, else StatefulSet, DaemonSet, Job or ReplicaSet
3. the pod name

The InferenceService outranks the Deployment because in KServe Serverless mode the
Deployment name embeds the Knative revision generation
(`<isvc>-predictor-00004-deployment`) and so changes on every redeploy.

The pipeline also promotes the scraped `pod`/`namespace` labels to resource attributes and
runs `k8sattributes` pod association, so `k8s.workload.name` resolves to the owning
Deployment rather than to the ReplicaSet — whose pod-template hash likewise changes on
every redeploy.

## Windows Support
CloudWatch DaemonSet on Windows is officially supported only for containerd runtime.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.

