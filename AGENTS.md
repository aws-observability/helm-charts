# AWS Observability Helm Charts

## Purpose
Helm chart repo for deploying Amazon CloudWatch observability infrastructure on Kubernetes. Single chart (`amazon-cloudwatch-observability`) that installs the CloudWatch Agent Operator and its managed components for collecting metrics, logs, and traces.

## Architecture
The chart deploys an **operator pattern**: a controller-manager (Deployment) watches for `AmazonCloudWatchAgent` custom resources and reconciles DaemonSets/Deployments for the actual agents. Admission webhooks handle auto-instrumentation injection.

Each observability feature (`containerInsights`, `applicationSignals`, `otelContainerInsights`) declares a `targetAgent` field that routes its configuration to a specific agent in the `agents` array. Two dynamic helpers — `build-default-config` and `build-default-otel-config` — construct per-agent CW Agent JSON and OTEL YAML configs based on which features target that agent.

```
Operator (Deployment) → manages → AmazonCloudWatchAgent CRs → creates → Agent DaemonSets/Deployments
                      → manages → Instrumentation CRs → injects → Auto-instrumentation sidecars

Feature flags (targetAgent routing):
  containerInsights.targetAgent      → build-default-config   → CW Agent JSON for matched agent
  applicationSignals.targetAgent     → build-default-config   → CW Agent JSON for matched agent
  otelContainerInsights.targetAgent  → build-default-otel-config → node-level OTEL config for matched agent
  otelContainerInsights.clusterScraperAgent → build-default-otel-config → cluster-level OTEL config for matched agent
```

## Repo Layout
- `charts/amazon-cloudwatch-observability/` — the Helm chart (templates, values, CRDs)
- `integration-tests/` — Terraform-based integration tests (EKS, Minikube)
- `go.mod` / Go files — test utilities and validation code
- `Makefile` — build, lint, format, secret-scanning targets

## Key Constraints
- `region` and `clusterName` are **required** values — templates will fail without them.
- CRDs in `crds/` are **generated from the operator source** — do not hand-edit them.
- Image references use **region-aware ECR domain mapping** (public, China, GovCloud, ADC). Every image helper in `_helpers.tpl` follows this pattern.
- The chart supports three Kubernetes modes: `EKS`, `ROSA`, `K8S` (set via `k8sMode`).
- Multi-platform: Linux (primary), Windows (separate DaemonSets), ROSA (OpenShift SCC).
- **Feature-targeted routing**: each feature flag section (`containerInsights`, `applicationSignals`, `otelContainerInsights`) has a `targetAgent` field that determines which agent in the `agents` array receives that feature's config. Agents not targeted by a feature get minimal config.
- **Cluster-scraper is a CR entry**: the cluster-scraper (`cloudwatch-agent-cluster-scraper`) is an entry in the `agents` array with `mode: deployment`, managed by the operator like all other agents. It is not a standalone Deployment.
- **Dynamic config construction**: agent configs are built at render time by `build-default-config` (CW Agent JSON) and `build-default-otel-config` (OTEL YAML) based on `targetAgent` matching. There is no static `defaultConfig`.
- **Universal health check**: every agent receives a `health_check` OTEL extension (endpoint `0.0.0.0:13133`) and liveness/readiness probes regardless of `otelContainerInsights.enabled`.

## Build & Validate
```bash
make all                    # deps, tidy, check_secrets, fmt, lint, helm-lint
make helm-lint              # helm lint with required values
make check_secrets          # scan for leaked AWS credentials
```
Helm lint requires: `helm lint ./charts/amazon-cloudwatch-observability --set region=test-region --set clusterName=test-cluster`

## Anti-Patterns
- Never hardcode ECR image domains — always use the `repositoryDomainMap` pattern in `_helpers.tpl`.
- Never add AWS credentials to any file — `make check_secrets` will catch this.
- Don't modify CRD files directly — they're generated artifacts.
- Don't assume a single agent — the `agents` list in values.yaml supports multiple independent `AmazonCloudWatchAgent` CRs.
- Don't hardcode agent configs — use `build-default-config` and `build-default-otel-config` helpers to dynamically construct per-agent configs based on `targetAgent` routing.
- Don't assume the cluster-scraper is a standalone Deployment — it is an `AmazonCloudWatchAgent` CR entry in the `agents` array, managed by the operator.

## Related Context
- Helm chart details: `charts/amazon-cloudwatch-observability/AGENTS.md`
- Integration tests: `integration-tests/AGENTS.md`
