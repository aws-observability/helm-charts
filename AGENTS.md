# AWS Observability Helm Charts

## Purpose
Helm chart repo for deploying Amazon CloudWatch observability infrastructure on Kubernetes. Single chart (`amazon-cloudwatch-observability`) that installs the CloudWatch Agent Operator and its managed components for collecting metrics, logs, and traces.

## Architecture
The chart deploys an **operator pattern**: a controller-manager (Deployment) watches for `AmazonCloudWatchAgent` custom resources and reconciles DaemonSets/Deployments for the actual agents. Admission webhooks handle auto-instrumentation injection.

```
Operator (Deployment) → manages → AmazonCloudWatchAgent CRs → creates → Agent DaemonSets
                      → manages → Instrumentation CRs → injects → Auto-instrumentation sidecars
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

## Related Context
- Helm chart details: `charts/amazon-cloudwatch-observability/AGENTS.md`
- Integration tests: `integration-tests/AGENTS.md`
