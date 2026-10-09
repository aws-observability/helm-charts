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

## Knative Serving metrics

Set under `otelContainerInsights.solutions.knative`, both on by default:

- `dataPlane`: request metrics from the queue-proxy sidecar of every revision pod, scraped by
  the agent on the pod's node. Revisions of a KServe InferenceService carry
  `aws.service.type = ai_inference`.
- `controlPlane`: autoscaler, activator, controller and webhook metrics, scraped by the
  cluster-scraper and attributed to the component's pod and Deployment.

Which sources exist depends on the KServe deployment mode. In **Serverless** mode (KServe's
default) an InferenceService becomes a Knative Service, so all of them are present. In
**RawDeployment** mode there is no queue-proxy and no `knative-serving` namespace, so only
`vllm` and `kserve.controlPlane` find targets; use the HPA metrics from kube-state-metrics
for the autoscaling view. Note that the request-level metrics are emitted by the Knative
queue-proxy rather than by KServe, which is a control plane only and is never in the request
path — hence `knative.dataPlane`, not `kserve`.

### Knative Serving 1.19 renamed every metric

`solutions.knative.*` handles both name sets. Serving ≤ 1.18 emits OpenCensus names
(`revision_*`, `autoscaler_*`); ≥ 1.19 moved to the OpenTelemetry SDK and renamed them with
a `kn` prefix (`autoscaler_desired_pods` → `kn_revision_pods_desired`).

On ≥ 1.19 Knative exports no metrics by default: the components' port 9090 and the
queue-proxy's port 9091 refuse connections until Knative is told to serve Prometheus.
`metrics-protocol` covers the control plane (`solutions.knative.controlPlane`) and
`request-metrics-protocol` the queue-proxy (`solutions.knative.dataPlane`):

```bash
kubectl -n knative-serving patch cm config-observability --type merge \
  -p '{"data":{"metrics-protocol":"prometheus","request-metrics-protocol":"prometheus"}}'
kubectl -n knative-serving rollout restart deployment
```

The components read `metrics-protocol` only at startup, hence the restart. The queue-proxy
setting applies to revision pods started after the change.

### Istio sidecars with STRICT mTLS

KServe and Knative do not inject Istio sidecars into revision pods by default. If a namespace
turns sidecar injection on and enforces `STRICT` mTLS, the sidecar rejects the agent's
plain-HTTP scrape, because the agent is not part of the mesh. Allow plain text on the metrics
port of those pods, for example for KServe predictors:

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: allow-metrics-scrape
  namespace: <model-namespace>
spec:
  selector:
    matchLabels:
      component: predictor
  mtls:
    mode: STRICT
  portLevelMtls:
    9091:          # queue-proxy metrics (knative.dataPlane)
      mode: PERMISSIVE
```

Port-level settings only take effect with a workload selector. The Knative control plane in
`knative-serving` is not sidecar-injected by default.

## Windows Support
CloudWatch DaemonSet on Windows is officially supported only for containerd runtime.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.

