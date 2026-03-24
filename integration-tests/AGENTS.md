# Integration Tests

## Purpose
End-to-end validation of the Helm chart on real Kubernetes clusters. Tests deploy the chart via Terraform, then validate that expected Kubernetes resources (Deployments, DaemonSets, Services, Pods) are created correctly.

## Structure
- `terraform/common/` — Shared infrastructure (IAM roles, VPC, subnets, security groups). Used as a module by EKS and Minikube.
- `terraform/eks/` — Provisions an EKS cluster, node groups, and IAM roles for testing. Has a `windows/` variant for mixed Linux+Windows node groups.
- `terraform/minikube/` — Local Minikube-based test infrastructure with scenario-specific value overrides in `scenarios/`.
- `util/k8sclient.go` — Go wrapper around `k8s.io/client-go` for querying namespaces, pods, services, deployments, daemonsets, webhooks, CRs, and validating resource existence (ServiceAccounts, Roles, ClusterRoles, DaemonSets, Services).
- `validations/eks/` — Go test files validating resource counts and names on EKS. Uses build tags (`linuxonly`, `windowslinux`) to select test variants.
- `validations/minikube/` — Minikube-specific validation with per-scenario test cases.

## Running Tests
Tests require a live cluster. The typical flow:
1. `terraform apply` in the appropriate `terraform/` directory to create infrastructure
2. `go test` with build tags in the `validations/` directory
3. `terraform destroy` to clean up

## Patterns
- Build tags (`//go:build linuxonly || windowslinux`) control which resource counts are expected.
- Resource counts are split into separate files (`resource_counts_linuxonly.go`, `resource_counts_windowslinux.go`) with constants for expected deployments, pods, services, and daemonsets.
- The K8sClient uses `~/.kube/config` — tests assume kubeconfig is already configured for the target cluster.
- Minikube scenarios each have a Terraform directory (`terraform/minikube/scenarios/{name}/`) with `main.tf` + `values.yaml`, and a corresponding Go test file in `validations/minikube/scenarios/`. Scenarios include: default, appsignals-disabled, webhooks-disabled, otlp-disabled, otlp-custom-otel-config, and others.

## Pitfalls
- Don't run tests without a live cluster — there are no mocks.
- Minikube scenarios override values via local `values.yaml` files — check the scenario directory before assuming default chart values.
- EKS tests expect specific IAM roles (`cwa-e2e-iam-role`) and VPC resources to exist — these are shared infrastructure, not created by the test Terraform.
