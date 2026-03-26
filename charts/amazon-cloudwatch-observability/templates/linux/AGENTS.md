# Linux Templates

## Purpose
Primary deployment templates for all Linux-based observability components. This is where most of the chart's functionality lives.

## Components

### CloudWatch Agent (`cloudwatch-agent-custom-resource.yaml`)
Creates `AmazonCloudWatchAgent` CRs from the `agents` list. Each agent entry merges with `$.Values.agent` defaults. Also generates TLS certificates (auto-gen or cert-manager) as Secrets for agent-to-exporter mTLS.

Key behavior: iterates over `.Values.agents`, merges each with `.Values.agent`, calls `build-default-config` and `build-default-otel-config` to dynamically construct per-agent configs based on `targetAgent` routing, and creates one CR per entry.

Feature-targeted routing: each feature flag (`containerInsights`, `applicationSignals`, `otelContainerInsights`) has a `targetAgent` field. The CR template passes the agent name to the config helpers, which only inject a feature's config when `targetAgent` matches. Agents not targeted by any feature get minimal configs.

Cluster-scraper skip gate: when `otelContainerInsights.enabled` is false, the CR template skips rendering the agent whose name matches `otelContainerInsights.clusterScraperAgent`.

Health probes (liveness/readiness on port 13133) are unconditional for every agent — no `otelContainerInsights.enabled` guard.

### Fluent Bit (`fluent-bit-configmap.yaml`, `fluent-bit-daemonset.yaml`)
Container log collection via DaemonSet. Gated by `containerLogs.enabled`.
- ConfigMap selects between `extraFiles` (standard) and `adcRegionExtraFiles` (ADC/isolated regions) based on `adcEndpointOverrides`
- DaemonSet uses checksum annotation for automatic rollout on config changes
- Dualstack endpoint injection happens in the ConfigMap via `fluent-bit.add-dualstack-endpoints` helper

### DCGM Exporter (`dcgm-exporter-daemonset.yaml`)
GPU metrics via `DcgmExporter` CR (not a raw DaemonSet — operator manages it). Gated by `dcgmExporter.enabled`. Node affinity targets NVIDIA GPU instance types. Has its own RBAC (`dcgm-exporter-role.yaml`, `dcgm-exporter-rolebinding.yaml`).

### Neuron Monitor (`neuron-monitor-daemonset.yaml`)
AWS Trainium/Inferentia metrics via `NeuronMonitor` CR. Gated by `neuronMonitor.enabled`. Node affinity targets trn/inf instance types. Own RBAC files.

### OTEL Container Insights (gated by `otelContainerInsights.enabled`)
Alternative metrics pipeline using OpenTelemetry. Config is dynamically constructed by `build-default-otel-config` and routed to agents via `targetAgent` matching:
- **Node-level config** (`_otel-container-insights-config.tpl`) — injected into the agent matching `otelContainerInsights.targetAgent`. Collects node-exporter, cadvisor, kubeletstats, EFA, EBS CSI, DCGM, and Neuron pipelines.
- **Cluster-level config** (`_otel-container-insights-cluster-scraper-config.tpl`) — injected into the agent matching `otelContainerInsights.clusterScraperAgent`. Scrapes kube-state-metrics and apiserver. Uses `otel_container_insights` naming prefix for all OTEL component names (receivers, processors, exporters, pipelines).
- **Cluster-scraper ClusterRole** (`otel-container-insights-cluster-scraper-clusterrole.yaml`) — RBAC for the cluster-scraper agent. Gated by `otelContainerInsights.enabled`.
- The standalone `otel-container-insights-cluster-scraper-deployment.yaml` has been deleted — the cluster-scraper is now an entry in the `agents` array (`cloudwatch-agent-cluster-scraper` with `mode: deployment`), managed by the operator as an `AmazonCloudWatchAgent` CR like all other agents.

### Kube-State-Metrics
Split across two files, gated by `kubeStateMetrics.enabled`:
- **`kube-state-metrics-rbac.yaml`** — ServiceAccount, ClusterRole, ClusterRoleBinding. RBAC is separated from the Deployment following the node-exporter pattern. Naming uses `{{ template "amazon-cloudwatch-observability.name" . }}-ksm-*`. ClusterRole contains only `list` and `watch` verbs (no `create` permissions for `tokenreviews`/`subjectaccessreviews`).
- **`kube-state-metrics.yaml`** — Deployment, Service, and web-config ConfigMap. The Deployment serves metrics over HTTPS (port 8443) using TLS certificates from the agent cert Secret, configured via a `--web-config-file` argument pointing to the KSM web-config ConfigMap. Service includes Prometheus scrape annotations. Container resources are configurable via `kubeStateMetrics.resources`.

### Node Exporter (`node-exporter-daemonset.yaml`)
Prometheus node-exporter DaemonSet for host-level metrics. Gated by `nodeExporter.enabled`. Has own RBAC (`node-exporter-role.yaml`, `node-exporter-rolebinding.yaml`). Excludes Fargate nodes. Serves metrics over HTTPS using TLS via `--web.config.file=/etc/node-exporter/web.yml` referencing the `node-exporter-web-config` ConfigMap. Container resources are configurable via `nodeExporter.resources`.

## Patterns
- All DaemonSets exclude Fargate nodes via `eks.amazonaws.com/compute-type NotIn fargate`
- GPU/accelerator components use CRs (DcgmExporter, NeuronMonitor) — the operator reconciles the actual DaemonSets
- Fluent Bit is a raw DaemonSet (not operator-managed)
- OTEL components are only created when `otelContainerInsights.enabled` — this is a separate pipeline from the default Container Insights
- The cluster-scraper is an `AmazonCloudWatchAgent` CR entry in the `agents` array (not a standalone Deployment) — the operator manages its lifecycle
- KSM and node-exporter both use TLS via web-config ConfigMaps referencing the agent cert Secret
- KSM and node-exporter RBAC are in dedicated files, separate from their Deployment/DaemonSet definitions
- OTEL component names in the cluster-scraper config use `otel_container_insights` prefix (underscore convention for OTEL names)
- Every agent gets a health-check-only OTEL config (with `health_check` extension on `0.0.0.0:13133`) when not targeted by any OTEL CI feature, ensuring unconditional liveness/readiness probes

## Pitfalls
- The DCGM and Neuron templates create CRs, not DaemonSets — don't add DaemonSet-specific fields to them.
- Fluent Bit config uses `tpl` for variable interpolation — environment variables like `${AWS_REGION}` are resolved at runtime, not template time.
- The OTEL cluster scraper config templates (`_otel-*.tpl`) generate YAML, not JSON — don't mix formats.
- Don't add RBAC resources to `kube-state-metrics.yaml` — they belong in `kube-state-metrics-rbac.yaml`.
- Don't use `otelci` prefix for new OTEL component names — use `otel_container_insights` for consistency.
- Don't assume the cluster-scraper is a standalone Deployment — it is a CR entry in the `agents` array managed by the operator.
