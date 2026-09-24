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

## LLM model-serving telemetry (vLLM / KServe / Knative)

Set under `otelContainerInsights.solutions`, all off by default. See `values.yaml` for the
flags.

### vLLM request traces require Transaction Search

`solutions.vllm.traces` exports spans to the CloudWatch OTLP traces endpoint
(`https://xray.<region>.amazonaws.com/v1/traces`). **That endpoint only accepts spans when
the account's X-Ray trace segment destination is `CloudWatchLogs`** — i.e. when Transaction
Search is enabled. Until it is, every batch is rejected:

```
HTTP Status Code 400, Message=The OTLP API is supported with CloudWatch Logs as a
Trace Segment Destination. Please enable the CloudWatch Logs destination for your
traces using the UpdateTraceSegmentDestination API
```

The agent treats this as a permanent, non-retryable error and drops the spans, so the
symptom is silent absence of traces plus `Exporting failed. Dropping data.` in the agent
log.

This setting is **account-wide per Region**, not per cluster, and switches all X-Ray span
ingestion in that Region into CloudWatch Logs. Enable it in the CloudWatch console under
**Application Signals → Transaction Search**, or with the API:

```bash
# 1. allow X-Ray to write the span log groups (the console does this for you)
aws logs put-resource-policy --policy-name TransactionSearchAccess --policy-document '{
  "Version":"2012-10-17",
  "Statement":[{
    "Sid":"TransactionSearchXRayAccess",
    "Effect":"Allow",
    "Principal":{"Service":"xray.amazonaws.com"},
    "Action":"logs:PutLogEvents",
    "Resource":[
      "arn:aws:logs:<region>:<account>:log-group:aws/spans:*",
      "arn:aws:logs:<region>:<account>:log-group:/aws/application-signals/data:*"],
    "Condition":{
      "ArnLike":{"aws:SourceArn":"arn:aws:xray:<region>:<account>:*"},
      "StringEquals":{"aws:SourceAccount":"<account>"}}}]}'

# 2. switch the destination
aws xray update-trace-segment-destination --destination CloudWatchLogs

# 3. choose how much to index as trace summaries (1% is free)
aws xray update-indexing-rule --name Default \
  --rule '{"Probabilistic":{"DesiredSamplingPercentage":1}}'
```

Step 1 is required — without it step 2 fails with
`AccessDeniedException: XRay does not have permission to call PutLogEvents on the aws/spans
Log Group`. Spans take up to 10 minutes to become searchable. 100% of spans are stored in
the `aws/spans` log group; only the indexed percentage becomes a searchable trace summary in
X-Ray. No IAM change is needed on the agent itself — `CloudWatchAgentServerPolicy` already
grants the endpoint.

Note that the prerequisite is not currently mentioned on the
[OTLP Endpoints](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-OTLPEndpoint.html)
page; it is documented on the
[Transaction Search](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Transaction-Search.html)
pages and enforced by the endpoint.

### What lands, and what vLLM does not send

Spans arrive in the `aws/spans` log group in semantic-convention format with W3C trace IDs,
so every attribute vLLM sets stays queryable — there is no indexed subset to declare.

The endpoint also enrols the spans in Application Signals: it injects `aws.local.*` and
`aws.span.kind` server-side, which creates a service entity and emits billed
`ApplicationSignals` metrics (`Latency`, `Error`, `Fault`, `Throttle`, `InputTokens`,
`OutputTokens`). That is not configured by this chart and cannot be turned off from here.

Three limitations come from vLLM itself and are worth knowing before building on this:

- **Errors are not observable.** vLLM never sets span status, and only successfully
  finished requests are traced at all — aborts, timeouts and errors emit no span. So
  Application Signals `Error` and `Fault` stay at zero regardless of what the engine is
  doing. Upstream fix: [vllm#32162](https://github.com/vllm-project/vllm/pull/32162).
- **No model name.** The V1 engine never sets `gen_ai.response.model`, so spans cannot be
  joined to the `vllm:*` metrics by model. `service.name` carries `--served-model-name`.
- **Traces are single-span.** vLLM honours an inbound W3C `traceparent`, but nothing in a
  default Istio/Knative path propagates one, so there is no end-to-end trace and no
  visibility into gateway queueing.

### Enabling tracing on the engine

The chart only opens the receiver. vLLM's tracing is off by default and is enabled on the
model container, which lives on your InferenceService:

```yaml
spec:
  predictor:
    containers:
      - name: kserve-container
        args:
          - --otlp-traces-endpoint=grpc://cloudwatch-agent.amazon-cloudwatch:4319
```

Use `grpc://` or `http://`, never `https://` — the scheme selects TLS, not the protocol, and
the receiver serves plaintext. vLLM's exporter is OTLP/gRPC unless
`OTEL_EXPORTER_OTLP_TRACES_PROTOCOL=http/protobuf` is set, in which case use the HTTP port.
On vLLM 0.11 also set `OTEL_EXPORTER_OTLP_TRACES_INSECURE=true`; 0.26 needs nothing.
`--collect-detailed-traces` is not needed — it does nothing for traces on the V1 engine.

Spans are billed per trace and vLLM emits one per request with no sampling of its own, so on
a high-QPS endpoint set `OTEL_TRACES_SAMPLER` on the engine.

### Knative Serving 1.19 renamed every metric

`solutions.knative.*` handles both name sets. Serving ≤ 1.18 emits OpenCensus names
(`revision_*`, `autoscaler_*`); ≥ 1.19 moved to the OpenTelemetry SDK and renamed them with
a `kn` prefix (`autoscaler_desired_pods` → `kn_revision_pods_desired`). On ≥ 1.19,
`solutions.knative.dataPlane` additionally needs Knative told to export request metrics —
they are off by default and the queue-proxy's port 9091 refuses connections until then:

```bash
kubectl -n knative-serving patch cm config-observability --type merge \
  -p '{"data":{"request-metrics-protocol":"prometheus"}}'
```

This is a separate key from `metrics-protocol`, which governs the control plane only.

## Windows Support
CloudWatch DaemonSet on Windows is officially supported only for containerd runtime.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.

