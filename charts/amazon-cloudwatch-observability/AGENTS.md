# Amazon CloudWatch Observability Helm Chart

## Purpose
Single Helm chart (v4.8.0) that deploys the full CloudWatch observability stack on Kubernetes: operator, agents, log collectors, GPU/accelerator exporters, and auto-instrumentation for application tracing.

## Required Values
Every install needs these two — templates use `required` and will hard-fail without them:
- `region` — AWS region (drives image domain resolution, endpoint selection, feature gates)
- `clusterName` — EKS/K8s cluster name (injected into agent configs, log group paths)

## Configuration Architecture
`values.yaml` key sections:
- `containerLogs.fluentBit` — Fluent Bit DaemonSet config (Linux + Windows variants, ADC region overrides)
- `manager` — Operator deployment, auto-instrumentation images (Java/Python/.NET/Node.js), Application Signals
- `agent` — CloudWatch Agent CR defaults (mode, image, config, Prometheus target allocator)
- `agents` — List of agent CRs to create (defaults to one named `cloudwatch-agent`; supports multiple)
- `dcgmExporter` — NVIDIA GPU metrics (node affinity targets GPU instance types)
- `neuronMonitor` — AWS Trainium/Inferentia metrics (node affinity targets trn/inf instance types)
- `admissionWebhooks` — Webhook config with two TLS paths: auto-generated or cert-manager
- `otelContainerInsights` — OTEL-based Container Insights (alternative pipeline, deploys kube-state-metrics + node-exporter + cluster-scraper)

## Image Resolution Pattern
All images resolve through `repositoryDomainMap` in `_helpers.tpl`. The pattern:
1. Look up `region` in the component's `repositoryDomainMap`
2. If no match, fall back to `public` key
3. Construct `domain/repository:tag`

Regions with custom ECR domains: `cn-north-1`, `cn-northwest-1`, `us-gov-east-1`, `us-gov-west-1`. GPU images (DCGM) use `nvcr.io/nvidia/k8s` for public.

Note: `kubeStateMetrics` and `nodeExporter` use a variant of this pattern with `restrictedRepository`/`restrictedTag` for China/GovCloud regions (where the upstream public images aren't available) and `repository`/`tag` for the public fallback.

## Template Helpers (`_helpers.tpl`)
50+ helper functions. The critical ones:
- `cloudwatch-agent.config-modifier` — injects `region`, `clusterName`, dualstack settings into agent JSON config
- `cloudwatch-agent.modify-config` — entry point that decides whether config needs modification
- `cloudwatch-agent.modify-otel-config` — handles YAML-based OTEL config
- `manager.modify-auto-monitor-config` — derives Application Signals monitoring config from agent configs
- `manager.monitorAllServices` — region-based feature gate (disabled for China, GovCloud, ADC, isolated regions)
- `fluent-bit.add-dualstack-endpoints` — injects dualstack endpoints into Fluent Bit OUTPUT sections
- `fluent-bit.add-ipv6-preference` — adds IPv6 DNS preference to Fluent Bit SERVICE section
- `cloudwatch-agent.merge-otel-configs` — merges generated OTLP CI config with user-supplied otelConfig; generated config wins on name collision
- `node-exporter.image` / `kube-state-metrics.image` — image helpers using repositoryDomainMap with restrictedRepository/restrictedTag for China/GovCloud
- Image helpers: `cloudwatch-agent.image`, `fluent-bit.image`, `dcgm-exporter.image`, etc.

## Platform Modes
Set via `k8sMode` (default: `EKS`):
- `EKS` — standard deployment, Fargate exclusion via node affinity
- `ROSA` — adds OpenShift SecurityContextConstraints
- `K8S` — generic Kubernetes, no platform-specific resources

## Anti-Patterns
- Don't put region-specific logic in templates — use `repositoryDomainMap` or `adcEndpointOverrides` in values.
- Don't modify `defaultConfig` in `_helpers.tpl` — override via `agent.config` in values.
- Don't create RBAC resources without checking the conditional guards (`agent.enabled`, `otelContainerInsights.enabled`, etc.).
- The `agents` list merges each entry with `$.Values.agent` defaults — don't duplicate shared config in individual agent entries.

## Related Context
- Linux templates: `templates/linux/AGENTS.md`
- Windows templates: `templates/windows/AGENTS.md`
- ROSA templates: `templates/rosa/AGENTS.md`
- Webhooks: `templates/admission-webhooks/AGENTS.md`
- CRDs: `crds/AGENTS.md`
