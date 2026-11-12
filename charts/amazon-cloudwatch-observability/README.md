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

Two receivers find them, with nothing to configure:

- **KServe:** the `kserve-container` of an InferenceService's predictor pods (labels
  `serving.kserve.io/inferenceservice` and `component: predictor`), whatever its image.
  Transformer and explainer pods are not scraped. KServe does not label which engine a
  predictor runs, so one shared receiver scrapes each predictor once and feeds every
  model-server pipeline; this one keeps the vLLM series (`vllm:*`, `http_*`) and the
  [SGLang pipeline](#sglang-model-server-metrics) keeps `sglang:*`.
- **Anything else:** any container whose image name contains `vllm`
  (`vllm/vllm-openai`, or a mirror of it), outside KServe predictors and KubeRay pods.

The chart reads no scrape labels or annotations of its own from customer pods. A vLLM server
outside KServe built from an image without `vllm` in its name is not found automatically;
scrape it with a PodMonitor or a custom agent configuration.

The port is resolved in this order, highest precedence first:

1. on KServe pods, the serving runtime's `prometheus.kserve.io/port` (and `prometheus.kserve.io/path`)
2. the port the container declares
3. the server's default: 8080 for KServe, 8000 for `vllm serve`

On KServe pods only the `kserve-container` is scraped, never the queue-proxy, which serves the
model server's metrics a second time. vLLM's `http_*` series have no engine prefix, so a
predictor running another engine that also exports unprefixed `http_*` series has those in
this pipeline too.

Every target carries the resource attribute `aws.service.type = ai_inference`, so a consumer
can find model-serving telemetry without knowing which metric names belong to it. vLLM only
serves inference, so the value is fixed.

### The vLLM metric service name

`service.name` on the engine's metrics comes from the chart's
[service identity](#service-identity) chain. On a KServe pod it is the InferenceService name
unless the pod has a `resource.opentelemetry.io/service.name` annotation. Without KServe it is
the workload name. The SGLang solution uses the same chain.

The InferenceService outranks the Deployment because in KServe Serverless mode the
Deployment name embeds the Knative revision generation
(`<isvc>-predictor-00004-deployment`) and so changes on every redeploy. The
`app.kubernetes.io/instance` and `app.kubernetes.io/name` labels are used only with
`otelServiceIdentity.useAppLabels`, after the InferenceService.

The pipeline also promotes the scraped `pod`/`namespace` labels to resource attributes and
runs `k8sattributes` pod association, so `k8s.workload.name` resolves to the owning
Deployment rather than to the ReplicaSet — whose pod-template hash likewise changes on
every redeploy.

### Not found automatically

- Pods that KubeRay labels `ray.io/is-ray-node=yes`, whatever their image. `ray.serve.llm`
  runs vLLM as a library and serves no `vllm:*` endpoint; its engine metrics arrive as
  `ray_vllm_*` through Ray's metrics port, which the Ray solution scrapes. Other ways of
  running vLLM in a Ray pod, such as `vllm serve --distributed-executor-backend ray`, serve
  `vllm:*` on their own port, which no solution scrapes; add a scrape for that port.
- A KServe LLMInferenceService running vLLM from the llm-d image (`ghcr.io/llm-d/llm-d-cuda`):
  its pods carry neither the InferenceService labels nor a `vllm` image name, and serve
  HTTPS when KServe's TLS is on.

## SGLang model-server metrics

Set under `otelContainerInsights.solutions.sglang`, on by default. The agent on each node
scrapes the SGLang servers on that node; the cluster-scraper is not involved.

SGLang serves metrics only when started with `--enable-metrics`; add `--enable-mfu-metrics`
for the `sglang:estimated_*` counters. Without the flag the server is still found, and its
scrape fails.

### Which SGLang servers are scraped

- **KServe:** the model container of an InferenceService's predictor pods, whatever its
  image, through the receiver shared with [vLLM](#which-vllm-servers-are-scraped); this
  pipeline keeps its `sglang:*` series.
- **Anything else:** any container whose image name contains `sglang` (`lmsysorg/sglang`, or
  a mirror of it), outside KServe predictors and KubeRay pods, including the model container
  of a KServe LLMInferenceService.

The chart reads no scrape labels or annotations of its own from customer pods.

The port is resolved in this order, highest precedence first:

1. on KServe pods, the serving runtime's `prometheus.kserve.io/port` (and `prometheus.kserve.io/path`)
2. the port the container declares
3. the server's default: 8080 for KServe, 30000 for `sglang.launch_server`

Only `sglang:*` series are kept. Every target carries `aws.service.type = ai_inference`, as
for vLLM.

### The SGLang metric service name

`service.name` is resolved as for [vLLM](#the-vllm-metric-service-name), from the chart's
[service identity](#service-identity) chain: the pod annotation
`resource.opentelemetry.io/service.name`, then the InferenceService name, then (with
`otelServiceIdentity.useAppLabels`) the `app.kubernetes.io` labels, then the workload chain.

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

## OTLP endpoint

The node agent (`cloudwatch-agent`, a DaemonSet) serves an OTLP endpoint on every node, on by
default. It accepts OTLP metrics, traces, logs and profiles over gRPC on port 4317 and HTTP on
port 4318, in plaintext, and exports them to the CloudWatch OTLP endpoints for metrics, traces
(X-Ray), logs and profiles. The agent's IAM role needs the permissions to write to those
endpoints, and traces need CloudWatch Transaction Search to be enabled.

Profiles are on by default (`otlp.profiles.enabled: true`). They need agent image 1.300075.0
or later, which turns on the collector's profiles support; on an older image the agent does
not start with profiles enabled. If you pin an older agent image, set
`otlp.profiles.enabled: false`.

A workload sends to the `cloudwatch-agent` Service in the release namespace, which routes to
the agent on the workload's own node:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: http://cloudwatch-agent.amazon-cloudwatch:4318
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: http/protobuf
```

The SDK appends the signal path, for example `/v1/metrics`. Profiles go to
`/v1development/profiles` (or the same gRPC service on 4317); `v1development` is the OTLP path
for a signal at development status. The agent sends nothing for a signal no workload sends.

To turn the endpoint off, or to move it to other ports:

```yaml
otlp:
  enabled: true
  grpc:
    enabled: true
    port: 4317
  http:
    enabled: true
    port: 4318
  spanMetrics:
    enabled: true
```

The HTTP endpoint accepts request bodies up to 20 MiB (`max_request_body_size`, the collector
default, set explicitly). The endpoint is served by the `agents` entry that renders with the
node agent's name (`agent.name`, default `cloudwatch-agent`); if no entry has that name, the
chart serves no OTLP endpoint.

Charts and integrations that configure their own senders read the endpoint from the
`otlp.httpEndpointURL` helper (`http://<node agent>.<release namespace>:<otlp.http.port>`,
empty when the endpoint does not serve OTLP/HTTP) and the body limit from
`otlp.httpMaxRequestBodyBytes`, instead of restating them.

At least one protocol must be enabled, the two ports must differ, and a port cannot be one
that the agent already uses (2000, 4311, 4314, 4315, 4316, 8125, 25826, 25888). The agent pods
use host networking, so another collector that holds the same ports on the node leaves one of
the two pods `Pending`. Set `otlp.enabled: false` or change the ports.

### Enrichment

The agent finds the sending pod from the `k8s.pod.uid`, `k8s.pod.name` and
`k8s.namespace.name` attributes that the sender set, then from the connection's source IP.
`k8s.pod.ip` is not used: unlike the connection source, it has no exclusion for host-network
pods, so a host-network sender that sets it would get another host-network pod's attributes. For profiles, as in the agent's own profiles pipeline, it finds the pod
from `container.id`, which the eBPF profiler sets, then from the connection's source IP. It then
adds the same attributes that OTEL Container Insights adds for that pod:

- the namespace, pod, container, node and workload attributes (`k8s.*`), including
  `k8s.workload.name` and `k8s.workload.type`;
- pod and node labels (`k8s.pod.label.*`, `k8s.node.label.*`), as allowed by
  `otelFilters.podLabels` and `otelFilters.nodeLabels`;
- the cloud and host attributes of the node, `k8s.cluster.name` and `cloud.resource_id`.

The agent also sets the service identity, each attribute only when the sender did not set it.
See [Service identity](#service-identity).

Logs go to the log group `/aws/cwagent/<clusterName>/otlp`, in a stream named
`<namespace>/<service.namespace>/<service.name>` when those are known. A sender can choose the
group and stream with the `aws.log.group.name` and `aws.log.stream.name` resource attributes.

With `otlp.spanMetrics.enabled`, the agent also computes request count, error and duration
metrics from the traces it receives (`traces.span.metrics.*`). These metrics carry the
resource attributes of the traces, pod and node labels included. A series stops being exported 5 minutes
after its last span, so a pod that is gone stops adding series.

### Cost control

The `otelFilters` settings apply to OTLP telemetry as they do to OTEL Container Insights. Pod
and node labels add attributes to every OTLP metric, span, log record and profile. To send OTLP
telemetry without them:

```yaml
otelFilters:
  podLabels:
    exclude: ["*"]
  nodeLabels:
    exclude: ["*"]
```

This also removes the labels from OTEL Container Insights, which shares the label settings.

### `default:otel`

The `agents[].config` value `default:otel` is ignored: the chart builds the same agent config
as for `default` (or no value), and `otlp.enabled` alone decides whether the OTLP endpoint is
on. With `otlp.enabled: false` and `default:otel`, the agent has no OTLP endpoint. The chart does not check the
agent's other receivers for port conflicts. A custom `agent.config` or `agents[].config`
(`opentelemetry.collect.otlp`) or a user `agent.otelConfig` / `agents[].otelConfig` may open
its own OTLP receivers next to the chart's endpoint, but must use other ports than
`otlp.grpc.port` and `otlp.http.port` (by default 4317 and 4318, which are also the
`opentelemetry.collect.otlp` defaults). On the same port the agent fails to bind and does not
start. `default:otel` on an agent other than
`cloudwatch-agent` no longer adds an OTLP receiver to that agent.

### Security

The endpoint has no TLS and no client authentication. Because the agent pods use host
networking, it is reachable on the node's IP addresses on the OTLP ports by anything that can
reach the node on those ports, not only by pods in the cluster. Kubernetes network policies
do not apply to host-network pods, so restrict the ports with the nodes' security groups or a
host firewall if other senders must not reach them, or set `otlp.enabled: false`.

## Service identity

The agent sets the service identity on OTLP telemetry and on OTEL Container Insights metrics
and application logs from one chain, per the OpenTelemetry Kubernetes convention. Each
attribute is set only when the sender did not set it. The chart-wide `otelServiceIdentity`
values control it:

```yaml
otelServiceIdentity:
  useAppLabels: false
```

| Attribute | Source, first found |
|-|-|
| `service.name` | the `resource.opentelemetry.io/service.name` pod annotation, then the Deployment, ReplicaSet, StatefulSet, DaemonSet, CronJob, Job, pod or container name. With `otelServiceIdentity.useAppLabels`, the `app.kubernetes.io/instance` and `app.kubernetes.io/name` pod labels come after the annotation. A `service.name` that starts with `unknown_service`, the SDK default, counts as not set. |
| `service.namespace` | the `resource.opentelemetry.io/service.namespace` annotation, then the namespace |
| `service.version` | the `resource.opentelemetry.io/service.version` annotation, then, with `otelServiceIdentity.useAppLabels`, the `app.kubernetes.io/version` label |
| `service.instance.id` | the `resource.opentelemetry.io/service.instance.id` annotation, then `<namespace>.<pod>.<container>` |
| `deployment.environment.name` | `<cloud.platform>:<cluster>/<namespace>` |

The `app.kubernetes.io` labels are off by default, as the
[OpenTelemetry Kubernetes convention](https://opentelemetry.io/docs/specs/semconv/non-normative/k8s-attributes/#service-attributes)
asks, because a Helm release usually puts the same `app.kubernetes.io/instance` on all its pods,
which would give them one `service.name`.

OTEL Container Insights uses the same chain on the node agent's metrics and application logs
and on the cluster scraper's kube-state-metrics series, so a pod's resource metrics, state
metrics and logs carry the same service identity. It differs from the OTLP chain in these ways:

- The Prometheus receiver sets `service.name` to the scrape job name (for example `cadvisor` or
  `kube-state-metrics`). That value counts as not set, so a pod's series are named after the
  pod's service. The job name is kept only when nothing else is found, as for node-level series
  such as node-exporter, and kube-state-metrics node and namespace series.
- The Prometheus receiver also sets `service.instance.id` to the scrape target (`<host>:<port>`,
  also kept as `server.address` and `server.port`). The target is kept only where `service.name`
  stays the job name (series about the exporter itself, such as node-exporter, and
  kube-state-metrics node and namespace series). Elsewhere `service.instance.id` is the
  annotation or `<namespace>.<pod>.<container>`, and is not set on series with no single
  container (pod-level series, and kube-state-metrics Deployment, StatefulSet, DaemonSet, Job
  and CronJob series), as the OpenTelemetry convention asks.
- On KServe pods, the InferenceService name (KServe's own `serving.kserve.io/inferenceservice`
  pod label) comes after the `resource.opentelemetry.io/service.name` annotation and before the
  `app.kubernetes.io` labels.
- Control-plane series (apiserver, Karpenter, KEDA, Knative and KServe controllers) keep the
  Prometheus receiver's `service.name` and `service.instance.id`: they describe the chart's
  scrape targets, not customer services.

Host logs carry no service identity: they come from the node, not from a service.

## OTEL filters

The top-level `otelFilters` block holds the filters for the data that the chart's OTEL
pipelines collect: OTEL Container Insights and the OTLP endpoint. Each filter applies only to
the data that this section names. The chart
turns the filters into OTEL processors in the agent configuration.

### Namespaces

`otelFilters.namespaces` applies to OTEL Container Insights metrics and logs, and to OTLP
metrics, traces and logs. One `include` list and one `exclude` list cover all of them.

The filter drops the pod and container metrics of a filtered namespace, from
kube-state-metrics, cAdvisor, kubelet, vLLM and the Knative data plane. It does not apply to
node-level metrics, or to the Karpenter, KEDA, KServe control plane and Knative control plane
metrics. For logs, it applies to application logs and not to host logs.

The filter never drops GPU, Neuron or EFA device metrics, because a device belongs to a pod
only for a while. When the pod of a device is in a filtered namespace, the chart keeps the
device metrics and removes the pod, namespace and container attributes. The device then has
its node attributes only, like a device that no pod uses.

An entry is an exact namespace name, a prefix followed by `*` (for example `prod-*`), or `*`
alone. A namespace name is a lowercase DNS-1123 label of at most 63 characters. An empty
include list, or one that contains `*`, includes every namespace. Exclude wins over include.
An entry cannot be in both lists. Records without a Kubernetes namespace always pass.

```yaml
otelFilters:
  namespaces:
    exclude: ["kube-system", "test-*"]
```

### Metric names

`otelFilters.metricNames` applies to OTEL Container Insights metrics and to OTLP metrics,
span metrics included. It does not apply to logs.

An entry is an exact metric name, a prefix followed by `*` (for example `container_*`), or
`*` alone. A name can contain letters, digits, `_`, `:` and `.`. An empty include list, or one
that contains `*`, includes every metric. Exclude wins over include. An entry cannot be in
both lists. A non-empty include list drops every other Container Insights metric, in every
pipeline, and every OTLP metric that is not on it.

The filter runs last before export in every Container Insights metrics pipeline. So the
entries match the exported metric names. The match is case-sensitive: the entry
`dcgm_fi_dev_gpu_util` does not match the metric `DCGM_FI_DEV_GPU_UTIL`.

```yaml
otelFilters:
  metricNames:
    include: ["container_*", "kube_*"]
    exclude: ["kube_replicaset_*"]
```

### Pod and node labels

`otelFilters.podLabels` and `otelFilters.nodeLabels` decide which pod and node labels arrive
as `k8s.pod.label.*` and `k8s.node.label.*` attributes. The label rules apply wherever the
chart attaches pod or node labels: OTEL Container Insights metrics and logs, and OTLP
metrics, traces and logs. All of them share each list.

An entry is a label key, a key prefix followed by `*` (for example `app.kubernetes.io/*`), or
`*` alone. A label key is an optional DNS subdomain prefix of at most 253 characters and `/`,
then a name of at most 63 characters. A label can be in both lists, for example include
`app*` and exclude `app-secret`.

| Key | Effect |
|-|-|
| `include` | The labels that the chart collects. An empty list, or one that contains `*`, collects every label. |
| `exclude` | The labels that the chart removes after it collects them. Exclude wins over include. `exclude: ["*"]` removes every label of that kind. |
| `recommendedExclusions` | Also removes a built-in list of high-cardinality labels. Examples are the topology, hostname and instance type labels, the Karpenter and EKS Auto Mode instance labels, and controller revision markers. With `k8sMode` `AKS` or `GKE`, the list also holds the node labels that AKS or GKE sets from the VM size, node image, OS, disk and network, such as `kubernetes.azure.com/sku-cpu` and `cloud.google.com/gke-boot-disk`. The node pool, pool mode, spot and accelerator labels are kept. The default is `true`. An unset value also counts as `true`. |

For each label, exclude wins over a named include entry, and a named include entry wins over
the built-in list. A named entry is a label key or a prefix followed by `*`, but not `*` alone.
So with `*` or an empty include list, the whole built-in list stays in effect, and every label
on it is removed. To keep one label from the built-in list, name it in include. To keep every other label too, also add `*`:

```yaml
otelFilters:
  nodeLabels:
    include: ["*", "karpenter.k8s.aws/instance-gpu-name"]
```

The chart's own processors read five labels: the pod labels `topology.kubernetes.io/region`,
`topology.kubernetes.io/zone`, `serving.kserve.io/inferenceservice` and `component`, and the
node label `topology.kubernetes.io/zone`. The chart always collects them. If the include list
leaves one out, or the exclude list names it, the chart removes it after use.

```yaml
otelFilters:
  podLabels:
    include: ["app*", "team"]
    exclude: ["app-secret"]
  nodeLabels:
    exclude: ["*"]
```

### A filter change restarts the agent

The agent reads its configuration only at startup. So the chart adds the annotation
`cloudwatch-agent/otel-config-sha256` to the pods of each agent that has an OTEL
configuration. The value is the SHA-256 of the agent's final `otelConfig`, after the merge
with `agents[].otelConfig`. A change to a filter or to `agents[].otelConfig` changes the
hash, and the operator then rolls the pods of that agent.

## DCGM metrics

The NVIDIA DCGM exporter runs on every NVIDIA GPU node when `dcgmExporter.enabled` is true,
the default. It collects 51 DCGM fields and the driver version label. The list is
`$metricsConfig` in `templates/linux/dcgm-exporter-daemonset.yaml`.

## Windows Support
CloudWatch DaemonSet on Windows is officially supported only for containerd runtime.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.

