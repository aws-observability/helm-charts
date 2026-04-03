# Amazon CloudWatch Observability Helm Chart

## Purpose
Single Helm chart that deploys the full CloudWatch observability stack on Kubernetes: operator, agents, log collectors, GPU/accelerator exporters, and auto-instrumentation for application tracing.

## Required Values
Every install needs these two — templates use `required` and will hard-fail without them:
- `region` — AWS region (drives image domain resolution, endpoint selection, feature gates)
- `clusterName` — EKS/K8s cluster name (injected into agent configs, log group paths)

## Configuration Architecture

### Feature Flag Structure with Target Agent Routing

Each observability feature declares which agent in the `agents` array receives its configuration via a `targetAgent` field. This ensures config is only injected into the intended agent — not broadcast to all agents.

```yaml
containerInsights:
  enabled: true                    # Legacy CI metrics via logs.metrics_collected.kubernetes
  targetAgent: "cloudwatch-agent"  # Agent that receives legacy CI config

applicationSignals:
  enabled: true                    # Application performance monitoring (traces + metrics)
  targetAgent: "cloudwatch-agent"  # Agent that receives AppSignals config

otelContainerInsights:
  enabled: true                                              # OTLP-based Container Insights pipeline
  targetAgent: "cloudwatch-agent"                            # Agent that receives node-level OTEL CI config
  clusterScraperAgent: "cloudwatch-agent-cluster-scraper"    # Agent that receives cluster-level OTEL CI config
```

When a feature's `targetAgent` does not match an agent's name, that agent simply doesn't receive that feature's config — no error, no crash.

### Agents Array and Cluster-Scraper

The `agents` list defines independent `AmazonCloudWatchAgent` CRs. The cluster-scraper is a CR entry in this array (not a standalone Deployment). It runs as `mode: deployment` and is managed by the operator like every other agent.

```yaml
agents:
  - name: cloudwatch-agent                    # Default DaemonSet agent
  - name: cloudwatch-agent-cluster-scraper    # Cluster-level metrics collector (apiserver, KSM scraping)
    mode: deployment
    replicas: 1
    serviceAccount:
      name: cloudwatch-agent-cluster-scraper
```

When `otelContainerInsights.enabled` is false, the CR template skips rendering the agent whose name matches `clusterScraperAgent`.

### Dynamic Config Construction

Agent configs are built at render time by two helpers — there is no static `defaultConfig`. Each helper checks which features target the current agent and constructs config accordingly.

**`cloudwatch-agent.build-default-config`** — Constructs CW Agent JSON config per agent:
- Always includes `agent.region`
- Includes `logs.metrics_collected.kubernetes` only when `containerInsights.enabled` AND `containerInsights.targetAgent` matches
- Includes `logs.metrics_collected.application_signals` + `traces.traces_collected.application_signals` only when `applicationSignals.enabled` AND `applicationSignals.targetAgent` matches
- Returns minimal `{"agent":{"region":"<region>"}}` when no feature targets the agent
- Called as: `include "cloudwatch-agent.build-default-config" (dict "agentName" $name "context" $)`

**`cloudwatch-agent.build-default-otel-config`** — Constructs OTEL YAML config per agent:
- When `otelContainerInsights.enabled` is false → empty config (`{}`); the CR template omits the `otelConfig` field entirely
- When `otelContainerInsights.targetAgent` matches → node-level OTEL CI config (delegates to `otel-container-insights.config`)
- When `otelContainerInsights.clusterScraperAgent` matches → cluster-level OTEL CI config (delegates to `otel-container-insights-cluster-scraper.config`)
- Default → empty config (`{}`); the CR template omits the `otelConfig` field entirely
- Called as: `include "cloudwatch-agent.build-default-otel-config" (dict "agentName" $name "context" $)`

### Config Override and Merge

- When an agent entry provides an explicit `config` field, it is used instead of `build-default-config` output
- When an agent provides `otelConfig`, it is merged with the generated OTEL config via `cloudwatch-agent.merge-otel-configs` — generated config wins on key collision for maps; `service.extensions` lists are concatenated and deduped; `service.pipelines` maps use generated pipelines winning on collision
- The `merge-otel-configs` helper validates `fromYaml` results — malformed YAML will cause `helm install` to fail with a descriptive error instead of silently producing corrupt config
- The `config-modifier` helper still handles `cluster_name` injection and `hosted_in` injection for AppSignals

### values.yaml Key Sections

- `containerInsights` — Legacy CI feature flag with `targetAgent` routing
- `applicationSignals` — AppSignals feature flag with `targetAgent` routing
- `otelContainerInsights` — OTLP CI feature flag with `targetAgent` and `clusterScraperAgent` routing
- `agents` — List of agent CRs to create (defaults to `cloudwatch-agent` DaemonSet + `cloudwatch-agent-cluster-scraper` Deployment)
- `agent` — Shared defaults merged into each agent entry (mode, image, resources, etc.)
- `containerLogs.fluentBit` — Fluent Bit DaemonSet config (Linux + Windows variants, ADC region overrides)
- `manager` — Operator deployment, auto-instrumentation images (Java/Python/.NET/Node.js)
- `kubeStateMetrics` — KSM Deployment config (`enabled`, `name`, `resources`, `service.port: 8443` for TLS, `serviceAccount`). Resources only created when both `kubeStateMetrics.enabled` and `otelContainerInsights.enabled` are true.
- `nodeExporter` — Node-exporter DaemonSet config (`enabled`, `resources`, `serviceAccount`)
- `dcgmExporter` — NVIDIA GPU metrics (node affinity targets GPU instance types)
- `neuronMonitor` — AWS Trainium/Inferentia metrics (node affinity targets trn/inf instance types)
- `admissionWebhooks` — Webhook config with two TLS paths: auto-generated or cert-manager

## Naming Conventions

OTEL component names in the cluster-scraper config use the `otel_container_insights` prefix (underscores, per OTEL convention). Examples:
- `sigv4auth/otel_container_insights_cwotel`
- `prometheus/otel_container_insights_apiserver`
- `prometheus/otel_container_insights_kube_state_metrics`
- `transform/otel_container_insights_set_unit`
- `batch/otel_container_insights_cwotel`
- Pipeline names: `metrics/otel_container_insights_apiserver`, `metrics/otel_container_insights_kube_state_metrics`

Template file names use `otel-container-insights` (kebab-case, per Helm convention). The `otelci` abbreviation is not used.

## Image Resolution Pattern
All images resolve through `repositoryDomainMap` in `_helpers.tpl`. The pattern:
1. Look up `region` in the component's `repositoryDomainMap`
2. If no match, fall back to `public` key
3. Construct `domain/repository:tag`

Regions with custom ECR domains: `cn-north-1`, `cn-northwest-1`, `us-gov-east-1`, `us-gov-west-1`. GPU images (DCGM) use `nvcr.io/nvidia/k8s` for public.

Note: `kubeStateMetrics` and `nodeExporter` use a variant of this pattern with `restrictedRepository`/`restrictedTag` for China/GovCloud regions (where the upstream public images aren't available) and `repository`/`tag` for the public fallback.

## Template Helpers (`_helpers.tpl`)
50+ helper functions. The critical ones:
- `cloudwatch-agent.build-default-config` — dynamically constructs CW Agent JSON config per agent based on `targetAgent` routing
- `cloudwatch-agent.build-default-otel-config` — dynamically constructs OTEL YAML config per agent based on `targetAgent` routing
- `cloudwatch-agent.config-modifier` — injects `region`, `clusterName`, dualstack settings into agent JSON config
- `cloudwatch-agent.modify-config` — entry point that decides whether config needs modification
- `cloudwatch-agent.modify-otel-config` — handles YAML-based OTEL config
- `cloudwatch-agent.merge-otel-configs` — merges generated OTLP CI config with user-supplied otelConfig; generated config wins on name collision
- `manager.modify-auto-monitor-config` — derives Application Signals monitoring config; checks `applicationSignals.enabled` + `targetAgent` routing, and when the targeted agent has an explicit `config`, verifies it contains `application_signals` keys
- `manager.monitorAllServices` — region-based feature gate (disabled for China, GovCloud, ADC, isolated regions)
- `fluent-bit.add-dualstack-endpoints` — injects dualstack endpoints into Fluent Bit OUTPUT sections
- `fluent-bit.add-ipv6-preference` — adds IPv6 DNS preference to Fluent Bit SERVICE section
- `otel-container-insights.scrapeTimeout` — computes `scrape_timeout` as `min(metricResolution, 10s)` to prevent Prometheus rejection when `metricResolution` < 10s
- `kube-state-metrics.name` / `kube-state-metrics.serviceAccountName` — naming helpers for KSM resources (follows same pattern as dcgm/neuron/node-exporter)
- `node-exporter.image` / `kube-state-metrics.image` — image helpers using repositoryDomainMap with restrictedRepository/restrictedTag for China/GovCloud
- Image helpers: `cloudwatch-agent.image`, `fluent-bit.image`, `dcgm-exporter.image`, etc.

## Platform Modes
Set via `k8sMode` (default: `EKS`):
- `EKS` — standard deployment, Fargate exclusion via node affinity
- `ROSA` — adds OpenShift SecurityContextConstraints
- `K8S` — generic Kubernetes, no platform-specific resources

## Anti-Patterns
- Don't put region-specific logic in templates — use `repositoryDomainMap` or `adcEndpointOverrides` in values.
- Don't hardcode agent configs — use `build-default-config` and `build-default-otel-config` helpers to dynamically construct per-agent configs based on `targetAgent` routing.
- Don't assume a single agent — the `agents` list supports multiple independent `AmazonCloudWatchAgent` CRs with different `targetAgent` routing.
- Don't assume the cluster-scraper is a standalone Deployment — it is an `AmazonCloudWatchAgent` CR entry in the `agents` array, managed by the operator.
- Don't create RBAC resources without checking the conditional guards (`agent.enabled`, `otelContainerInsights.enabled`, `kubeStateMetrics.enabled`, `nodeExporter.enabled`, etc.).
- Don't mix `otelci` and `otel_container_insights` naming — use `otel_container_insights` for OTEL component names and `otel-container-insights` for file names.
- The `agents` list merges each entry with `$.Values.agent` defaults — don't duplicate shared config in individual agent entries.

## Related Context
- Linux templates: `templates/linux/AGENTS.md`
- Windows templates: `templates/windows/AGENTS.md`
- ROSA templates: `templates/rosa/AGENTS.md`
- Webhooks: `templates/admission-webhooks/AGENTS.md`
- CRDs: `crds/AGENTS.md`
