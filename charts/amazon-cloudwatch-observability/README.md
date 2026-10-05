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

## LLM model-serving request traces (vLLM / Knative)

`otelContainerInsights.solutions.vllm.traces` and `otelContainerInsights.solutions.knative.traces`
(both default off; they need `otelContainerInsights.enabled`) collect request
traces from the vLLM engine and from Knative's activator and queue-proxy. One inference
request becomes one trace: activator → queue-proxy → `llm_request` on the engine.

The chart does not add a trace pipeline of its own. It turns on the agent's OTLP endpoint
(`opentelemetry.collect.otlp`) on the node agent, listening on `0.0.0.0:4317` (gRPC) and
`0.0.0.0:4318` (HTTP), and, for vLLM, the agent's `vllm` workload enrichment. Spans go through
the agent's shared OTLP traces pipeline — Kubernetes attribution by connection IP, cluster
name, `service.name` — to the CloudWatch OTLP traces endpoint. The `vllm` workload adds:

- `service.name` from the KServe InferenceService, which vLLM does not set itself; else the
  workload name, as for any OTLP sender
- `gen_ai.system=vllm` and the current `gen_ai.usage.input_tokens`/`output_tokens` names on
  the engine's `llm_request` spans

This needs an agent version that supports `opentelemetry.collect.otlp.workloads`.

### Pointing the senders at the agent

The agent Service is node-local, so this address always
reaches the agent on the sender's node:

```yaml
# vLLM (InferenceService predictor container)
args:
  - --otlp-traces-endpoint=grpc://cloudwatch-agent.amazon-cloudwatch:4317
```

```bash
# Knative
kubectl -n knative-serving patch cm config-observability --type merge -p '{"data":{
  "tracing-protocol":"http/protobuf",
  "tracing-endpoint":"http://cloudwatch-agent.amazon-cloudwatch:4318/v1/traces",
  "tracing-sampling-rate":"1"}}'
```

The endpoint is plaintext. Use `grpc://` or `http://` for vLLM, never `https://`: the scheme
selects TLS. For Knative, give the full `http://` URL as above; an endpoint with no scheme
makes its exporter attempt TLS, and every export fails the handshake. Knative reads `config-observability` when its pods start, so restart
the activator and recreate revision pods after changing it. If a `KnativeServing` resource
manages Knative, set these under its `spec.config.observability` instead.

### Transaction Search must be enabled

The CloudWatch OTLP traces endpoint
only accepts spans when the account's X-Ray trace segment destination is `CloudWatchLogs`;
until then every batch is rejected with HTTP 400 and the agent logs `Exporting failed`.
This is an account-wide, per-Region setting:

```bash
aws logs put-resource-policy --policy-name TransactionSearchAccess --policy-document '{
  "Version":"2012-10-17",
  "Statement":[{"Sid":"TransactionSearchXRayAccess","Effect":"Allow",
    "Principal":{"Service":"xray.amazonaws.com"},"Action":"logs:PutLogEvents",
    "Resource":["arn:aws:logs:<region>:<account>:log-group:aws/spans:*",
                "arn:aws:logs:<region>:<account>:log-group:/aws/application-signals/data:*"],
    "Condition":{"ArnLike":{"aws:SourceArn":"arn:aws:xray:<region>:<account>:*"},
                 "StringEquals":{"aws:SourceAccount":"<account>"}}}]}'
aws xray update-trace-segment-destination --destination CloudWatchLogs
```

### Sampling

Sampling is decided where a trace starts and followed downstream. With Knative,
`tracing-sampling-rate` covers the whole trace, vLLM included. Without Knative, set
`OTEL_TRACES_SAMPLER=parentbased_traceidratio` and `OTEL_TRACES_SAMPLER_ARG` on the engine.

### Application Signals auto-instrumentation on the engine

With Application Signals auto-instrumentation on the engine pod, the ADOT SDK owns the
process's tracer, so vLLM's spans are exported by ADOT, to the Application Signals endpoint
by default. To keep the engine span's name and the enrichment above alongside ADOT's HTTP
spans, point ADOT at this endpoint as well:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
    value: http://cloudwatch-agent.amazon-cloudwatch:4318/v1/traces
```

### What vLLM does not send

The V1 engine never sets span status, and only successfully
finished requests are traced, so errors are not visible in its spans. It sets no model name
on spans (it is a label on vLLM's own Prometheus metrics), and it creates `llm_request` only when
`--otlp-traces-endpoint` is passed.

## Windows Support
CloudWatch DaemonSet on Windows is officially supported only for containerd runtime.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.

