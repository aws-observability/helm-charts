# Proposal: Feature-Targeted Agent Design

## Background

### The `agents` / `agent` Pattern

The Helm chart uses a two-key pattern to manage CloudWatch Agent instances:

- **`agent:` (singular)** — A defaults template defining every possible field: `mode`, `replicas`, `image`, `config`, `otelConfig`, `resources`, `affinity`, etc. Never rendered directly.
- **`agents:` (plural)** — A list of agent instances to deploy. Each entry is a sparse override object. Default: `[{name: cloudwatch-agent}]`.

The CR template iterates the list and merges each entry onto a deep copy of the defaults:

```yaml
{{- range .Values.agents }}
{{- $agent := merge . (deepCopy $.Values.agent) }}
# ... render AmazonCloudWatchAgent CR
{{- end }}
```

This lets users deploy multiple independent agents (e.g., a DaemonSet for Container Insights + a Deployment for Prometheus scraping), each inheriting defaults but overriding as needed. The operator reconciles each CR into the actual workload.

### The `defaultConfig` Contract

Previously, `agent.defaultConfig` was a hardcoded JSON blob in values.yaml:

```yaml
agent:
  defaultConfig:
    logs:
      metrics_collected:
        kubernetes: { enhanced_container_insights: true }
        application_signals: {}
    traces:
      traces_collected:
        application_signals: {}
```

Every agent that didn't override `config` inherited this. The expectation: defaults flow to all, overrides are per-entry.

---

## Problems with the Original OTLP CI Implementation

### 1. OTLP CI Config Injected into All Agents

The original code injected the OTLP CI otelConfig inside the `range .Values.agents` loop using a global flag:

```yaml
{{- if $.Values.otelContainerInsights.enabled }}
otelConfig: {{ generated OTLP CI config }}
{{- end }}
```

This meant every agent in the list received the full 676-line OTLP CI pipeline — including agents that shouldn't have it. Consider a user adding a Prometheus scraping agent:

```yaml
agents:
  - name: cloudwatch-agent          # primary DaemonSet — should get OTLP CI
  - name: prometheus-agent           # Deployment for Prometheus TA — should NOT get OTLP CI
    mode: deployment
    replicas: 2
    prometheus:
      config: { ... }
      targetAllocator:
        enabled: true
```

Both agents would receive the full OTLP CI otelConfig. The `prometheus-agent` Deployment — which only exists to scrape custom Prometheus targets — would also spin up node-exporter, cAdvisor, kubeletstats, and EFA receivers, attempting to collect node-level metrics from a Deployment pod that has no host-level access. This would cause errors at best and duplicate metrics at worst.

The same problem existed for the `defaultConfig`. Because it was a static JSON blob on `agent:`, every agent inherited Container Insights and Application Signals config via the merge:

```yaml
agent:
  defaultConfig:    # ← inherited by ALL agents
    logs:
      metrics_collected:
        kubernetes: { enhanced_container_insights: true }
        application_signals: {}
    traces:
      traces_collected:
        application_signals: {}
```

The `prometheus-agent` would inherit `kubernetes` metrics collection and `application_signals` tracing — features it has no business running. The user would have to explicitly set `config: { agent: { region: us-west-2 } }` on the Prometheus agent entry to suppress the defaults, which is non-obvious and error-prone.

In practice, most Prometheus agent users already override `config` with their actual scrape configuration, so the `defaultConfig` inheritance was rarely a problem for the JSON config path. The real issue surfaced with `otelConfig` — a Prometheus agent configured via `otelConfig` (rather than the JSON `config`) would have no reason to override `config`, and would silently inherit the full Container Insights + Application Signals defaults.

### 2. Cluster Scraper Was a Vanilla Deployment

The cluster-scraper was implemented as a raw Kubernetes Deployment with its own ConfigMap, ServiceAccount, and pod spec — completely outside the `agents` pattern. Every other CW Agent workload in the chart is an `AmazonCloudWatchAgent` CR managed by the operator. The cluster-scraper deviated from this, creating:

- A parallel management path (Helm-managed Deployment vs. operator-managed CR)
- Duplicated template logic (image resolution, tolerations, labels, env vars)
- Inconsistency in how the chart's agent workloads are represented

### 3. Health Probes Were Feature-Gated

Liveness and readiness probes were only added when `otelContainerInsights.enabled` was true, because the health check endpoint (port 13133) only existed when the OTel collector pipeline was running. This meant the primary DaemonSet agent had no health probes in the default (non-OTLP) case — a gap in operational observability.

### 4. Feature Flags Lacked Targeting

`containerInsights.enabled` and `otelContainerInsights.enabled` were global booleans with no way to specify which agent they applied to. Combined with the hardcoded `defaultConfig`, there was no clean way to:

- Run Container Insights on one agent and Application Signals on another
- Add a new agent without inheriting all features
- Disable a feature for a specific agent without overriding the entire config

---

## Proposed Design

### Feature Flags with Agent Targeting

Each feature gets an `enabled` flag and a `targetAgent` that controls which agent in the `agents` list receives the feature's config:

```yaml
containerInsights:
  enabled: true
  targetAgent: cloudwatch-agent

applicationSignals:
  enabled: true
  targetAgent: cloudwatch-agent

otelContainerInsights:
  enabled: true
  targetAgent: cloudwatch-agent
  clusterScraperAgent: cloudwatch-agent-cluster-scraper
```

Features only inject config into the agent whose name matches `targetAgent`. This keeps multi-agent setups safe by default.

### Dynamic Config Construction

`agent.defaultConfig` is removed from values.yaml. Instead, a helper (`build-default-config`) constructs the CW Agent JSON config dynamically based on which features target the given agent:

```
build-default-config(agentName):
  if containerInsights.enabled AND containerInsights.targetAgent == agentName:
    add logs.metrics_collected.kubernetes
  if applicationSignals.enabled AND applicationSignals.targetAgent == agentName:
    add logs.metrics_collected.application_signals
    add traces.traces_collected.application_signals
  return config
```

An agent that isn't targeted by any feature gets an empty config `{}`. A user can still override `config` per-agent to bypass dynamic construction entirely — the override path is unchanged.

### OTLP CI Config Routing

A second helper (`build-default-otel-config`) routes the OTLP CI otelConfig based on `targetAgent` matching:

- `otelContainerInsights.targetAgent` match → node-level OTLP CI config (DaemonSet pipelines)
- `otelContainerInsights.clusterScraperAgent` match → cluster-level OTLP CI config (apiserver + kube-state-metrics pipelines)
- No match → minimal health-check-only otelConfig (see below)

### Cluster Scraper as a CR

The cluster-scraper is now an entry in the `agents` array:

```yaml
agents:
  - name: cloudwatch-agent
  - name: cloudwatch-agent-cluster-scraper
    mode: deployment
    replicas: 1
    serviceAccount:
      name: cloudwatch-agent-cluster-scraper
```

It follows the same pattern as every other agent — merged with `agent` defaults, rendered as an `AmazonCloudWatchAgent` CR, managed by the operator. The standalone Deployment template is deleted.

The CR is gated: when `otelContainerInsights.enabled` is false, the cluster-scraper entry is skipped in the loop. This is the only feature-specific conditional remaining in the CR template (see "Design Constraints" below for why).

### Universal Health Check and Probes

Every agent now always receives an otelConfig with at least a `health_check` extension:

```yaml
extensions:
  health_check:
    endpoint: "0.0.0.0:13133"
service:
  extensions:
    - health_check
```

This means liveness and readiness probes are unconditional in the CR template — no feature-flag gating needed. Every agent has something listening on port 13133.

---

## What This Solves

| Problem | Before | After |
|---------|--------|-------|
| OTLP CI on wrong agents | Injected into all agents in the loop | Only injected into `targetAgent` match |
| Cluster scraper inconsistency | Vanilla Deployment, separate from CR pattern | CR in `agents` array, operator-managed |
| No health probes without OTLP | Probes gated behind `otelContainerInsights.enabled` | Probes always on, health check always present |
| Feature flags are global | No way to target specific agents | `targetAgent` routes features to named agents |
| Hardcoded defaultConfig | Must override entire JSON to toggle one feature | Dynamic construction from feature flags |
| Multi-agent safety | Second agent inherits everything | Second agent only gets features that target it |

---

## Scenario Walkthrough

**Default user (one agent, all features on):**
All three features target `cloudwatch-agent` → it gets CI + AppSignals in config, OTLP CI in otelConfig. Cluster-scraper gets its own otelConfig. Identical behavior to the original implementation.

**Multi-agent, Prometheus doesn't get anything:**
```yaml
agents:
  - name: cloudwatch-agent       # targeted by all 3 features
  - name: prometheus-agent       # targeted by nothing
    config: { ... }
```
`prometheus-agent` doesn't match any `targetAgent` → gets empty default config and health-check-only otelConfig. Clean.

**Split features across agents:**
```yaml
containerInsights:
  targetAgent: ci-agent
applicationSignals:
  targetAgent: appsignals-agent

agents:
  - name: ci-agent               # gets CI only
  - name: appsignals-agent       # gets AppSignals only
```

**Disable a feature entirely:**
```yaml
applicationSignals:
  enabled: false
```
No agent gets AppSignals config, regardless of `targetAgent`. The flag is the kill switch, the ref is the routing.

---

## Design Constraints and Callouts

### Why the Cluster-Scraper Gate Can't Move to Helpers

Helm's `define`/`include` can only return strings. To move agent-list gating into a helper, you'd need to serialize the entire resolved agents list through a `toJson`/`fromJson` round-trip. This is fragile with complex nested objects — edge cases around nil vs empty, numeric types, and multi-line YAML strings can cause hard-to-debug failures. One `if` check in the CR template is the pragmatic choice over a purity improvement that adds real risk.

### ⚠️ Behavior Change: Universal otelConfig

Previously, agents without an explicit `otelConfig` had no OTel collector running. Now every agent gets a minimal otelConfig with a `health_check` extension. This means the CW Agent binary will always start its OTel collector, even if there are no pipelines.

**This MUST be validated end-to-end** to ensure the agent binary handles an otelConfig with only a health_check extension and no pipelines/receivers/exporters. If the binary errors on this, the fallback is to gate probes and otelConfig behind a per-agent boolean — but this is less clean.

### hostNetwork and volumeMounts Are Still Global

The CR template hardcodes `hostNetwork: true` and a full set of host volume mounts (rootfs, docker/containerd sockets, etc.) for every agent — including Deployment-mode agents like the cluster-scraper that don't need them. This is a pre-existing issue (it affects any non-DaemonSet agent in the list today) and is out of scope for this change. A future enhancement should make these per-agent overridable.

### Windows Agents Are Separate Templates

The Windows agent CRs (`cloudwatch-agent-windows`, `cloudwatch-agent-windows-container-insights`) are hardcoded in their own templates, not part of the `agents` loop. They are unaffected by this proposal. Unifying them into the `agents` pattern is a separate effort.

---

## Migration

The rendered output for the default case (`containerInsights.enabled: true`, `applicationSignals.enabled: true`, `otelContainerInsights.enabled: true`, `agents: [{name: cloudwatch-agent}]`) is functionally identical to the original implementation, with two additions:

1. The main agent now always has an `otelConfig` field (previously only when otelCI was enabled or user provided one)
2. The main agent now always has liveness/readiness probes (previously only when otelCI was enabled)

Users who override `agent.config` are unaffected — the override path is unchanged. Users who override `agent.otelConfig` will have their config merged with the generated health-check base (or the full OTLP CI config if targeted), same as before.

The only breaking change is the removal of `agent.defaultConfig` from values.yaml. Users who referenced this field directly in custom templates or overrides will need to use `agent.config` instead, or rely on the dynamic construction.
