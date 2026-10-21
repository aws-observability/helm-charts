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

### Engine configuration Info metric

`vllm_engine_config_info` records how each vLLM engine was started. It is a gauge with the
value 1. There is one series per vLLM container. So a pod with two vLLM containers gives two
series. The engine's startup settings are labels on the series:

- version: `vllm_version`, `vllm_engine`
- model: `model`, `served_model_name`, `dtype`, `max_seq_len`, `quantization`, `kv_cache_dtype`
- parallelism: `tensor_parallel_size`, `pipeline_parallel_size`, `data_parallel_size`
- features: `enforce_eager`, `enable_prefix_caching`, `speculative_method`

Older vLLM versions log fewer settings. If the startup line does not log a setting, its label
is left out.

It is off by default. Turn it on with `otelContainerInsights.solutions.vllm.configInfo.enabled=true`.
It needs `otelContainerInsights.logs.enabled=true`, because the agent reads the engine startup
line in the application-log pipeline. With logs off, the chart renders nothing for this metric.
It also needs an agent image with the `signal_to_info_metric` connector. An older agent fails
to start with it on.

The agent on each node reads the engine startup line from the container's log. The line
contains `Initializing ... LLM engine (v...)`. The agent sends each series again every
`configInfo.emitInterval`.
Empty means `otelContainerInsights.metricResolution`. The value is `<N>s`, `<N>m` or `<N>h`,
from 1s to 24h.

The agent identifies each series by the namespace, pod and container in the log file path,
`/var/log/containers/<pod>_<namespace>_<container>-<id>.log`. So it does not wait for the
Kubernetes API.

The agent also keeps the UID of the pod that logged the startup line. Each time it sends a
series, it finds the live pod with that name and compares the two UIDs:

- When a StatefulSet replaces a pod, the new pod has the same name and a new UID. The pod has
  no series until its own engine logs its startup line. Then the series shows the settings of
  the new pod. This time includes the scheduling, the image pull, and the container start.
- If the new pod with the same name never logs a vLLM startup line, it has no series. For
  example, the container now runs another inference server, or it fails before the engine
  starts.
- When a pod is deleted, its series stops about 2 minutes later. The `k8sattributes` processor
  keeps a deleted pod for a grace period of 120 seconds. After that, the agent finds no pod with
  that name and drops the series.

The `k8sattributes` processor of the log pipeline adds the UID to the startup line. When the
agent starts, the processor loads its pod cache from the Kubernetes API. If the cache has no UID
for a startup line, that series has no UID check until the next startup line of the container.

Caps, per agent:

- `maxEntities` (default 500): the number of vLLM containers tracked.
- `maxStateBytes` (default 1048576): the size of the stored settings, in bytes.
- `maxValueLength` (default 256): the length of each label value.

The agent keeps the settings in `otelContainerInsights.stateStorage`, so they survive an agent
restart. The Info metric turns the storage on by itself. The storage is a hostPath directory
(`stateStorage.hostPath`, default `/var/lib/amazon-cloudwatch-agent/otel-state`). It is mounted
read-write into the node agent DaemonSet only. The directory stays on the node after you
uninstall the chart. One agent pod at a time locks the storage files. So the agent's
`updateStrategy.rollingUpdate.maxSurge` must be 0, which is the DaemonSet default. The chart
fails to render otherwise.

The Info metric does not change log shipping. The agent keeps no read positions (checkpoints)
for the application log files by default. A restarted agent then starts at the end of each
file, and the lines written while it was down are not shipped. To keep the checkpoints in the
storage, set `otelContainerInsights.stateStorage.enabled=true`. A restarted agent then continues
each file where it stopped. With logs off, the chart renders no storage, because no component
uses it then.

With logs on, the agent reads only the log lines written after it starts. So a vLLM pod that is
already running when the feature is first turned on gets its series after its next restart.
Without checkpoints, the same applies to a vLLM pod that starts while the agent is down. The
settings that the agent already has survive the restart.

The metric adds almost no cost to the agent. On an EKS test node at 2000 log lines per second,
with application logs shipped, the node agent used 62.47 millicores of CPU with `configInfo` off
and 62.40 millicores with it on. Its mean memory (RSS) was 138.7 MiB with `configInfo` off and
140.3 MiB with it on.

A new `emitInterval` or cap reaches the agent only after its pod restarts, because the operator
updates the agent configuration, not the pod.

Fargate has no node agent DaemonSet. So a vLLM pod on Fargate gets no Info metric.

To add the engine settings to another vLLM metric, join on the pod:

```promql
sum by ("@resource.k8s.pod.uid") ({"vllm:num_requests_running"})
  * on ("@resource.k8s.pod.uid") group_left (vllm_version, model)
    max by ("@resource.k8s.pod.uid", vllm_version, model) (
      last_over_time({"vllm_engine_config_info"}[2m])
    )
```

Resource attributes are labels with the `@resource.` prefix. In the vLLM metrics pipeline, the
`k8sattributes` processor adds the UID of the live pod, `k8s.pod.uid`, to both series. The agent
sends no Info series without it. Except for the series without a UID check, it also sends no
Info series with the settings of a previous pod with the same name. The pod UID is unique across
clusters, and a replacement pod with the same name gets a new one. The `max by` keeps one series
for each pod and set of settings. Use a `last_over_time` window longer than `emitInterval`.

A pod with two vLLM containers whose version or model differ has two Info series with one pod
UID. The join then fails, because PromQL finds two series on the Info side for one pod. For
such a pod, select one container on the Info side, for example
`{"vllm_engine_config_info", "@resource.k8s.container.name"="vllm"}`.

## KServe control-plane metrics

Set under `otelContainerInsights.solutions.kserve.controlPlane`, on by default. The
cluster-scraper finds the `kserve-controller-manager` pod by its
`control-plane: kserve-controller-manager` label in `namespace` (default `kserve`), so a
cluster without KServe has no target. The controller binds its plain metrics to
`127.0.0.1:8080`, so they are scraped through its kube-rbac-proxy on `:8443`, with the agent's
service-account token.

Only the operator's own `controller_runtime_*` and `leader_election_*` families are kept.
client-go's `workqueue_*` and `rest_client_*` are dropped: the apiserver pipeline already
publishes those names under its own scope. The series are attributed to the controller pod
and its Deployment.

KServe is a control plane only and is never in the request path: request-level metrics for
an InferenceService come from the model server (`solutions.vllm`) and, in Serverless mode,
from the Knative queue-proxy (`solutions.knative.dataPlane`).

## Knative Serving metrics

Set under `otelContainerInsights.solutions.knative`, both on by default:

- `dataPlane`: request metrics from the queue-proxy sidecar of every revision pod, scraped by
  the agent on the pod's node. Predictor revisions of a KServe InferenceService carry
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

