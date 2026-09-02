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

## Windows Support
CloudWatch DaemonSet on Windows is officially supported only for containerd runtime.

## EKS Add-on Standard Configuration

The following top-level values are the standard EKS add-on configuration keys. They are applied by default to all supported addon workloads and can be overridden per component (e.g. `manager.podLabels`, `containerLogs.fluentBit.podAnnotations`).

| Key                          | Type   | Default | Description                                                                                       |
| ---------------------------- | ------ | ------- | ------------------------------------------------------------------------------------------------- |
| `podLabels`                  | map    | `{}`    | Extra labels attached to addon pods.                                                              |
| `podAnnotations`             | map    | `{}`    | Extra annotations attached to addon pods.                                                         |
| `topologySpreadConstraints`  | list   | `[]`    | Topology spread constraints applied to addon pods.                                                |
| `priorityClassName`          | string | `""`    | Priority class name. Only applied to workloads that don't already declare a component-level value. |
| `podDisruptionBudget.enabled` | bool   | `false` | Opt-in creation of a `PodDisruptionBudget` for each supported workload.                           |
| `podDisruptionBudget.maxUnavailable` | int/string | `1` | `maxUnavailable` used when PDBs are created.                                             |
| `podDisruptionBudget.minAvailable`   | int/string | _unset_ | Alternative to `maxUnavailable` (mutually exclusive).                                     |

### Coverage

| Workload                     | podLabels | podAnnotations | topologySpreadConstraints | priorityClassName | podDisruptionBudget |
| ---------------------------- | :-------: | :------------: | :-----------------------: | :---------------: | :-----------------: |
| Operator (controller-manager) | ✓         | ✓              | ✓                         | ✓                 | ✓ (Kubernetes PDB)  |
| CloudWatch Agent (Linux/Windows) | ✗†     | ✓              | ✓                         | ✓                 | ✓ (via CR)          |
| Fluent Bit (Linux/Windows)   | ✓         | ✓              | ✓                         | ✓                 | ✓ (Kubernetes PDB)  |
| Node Exporter                | ✓         | ✓              | ✓                         | ✓                 | ✓ (Kubernetes PDB)  |
| Kube State Metrics           | ✓         | ✓              | ✓                         | ✓                 | ✓ (Kubernetes PDB)  |
| DCGM Exporter                | ✗†        | ✗†             | ✗†                        | ✗†                | ✗†                  |
| Neuron Monitor               | ✗†        | ✗†             | ✗†                        | ✗†                | ✗†                  |

† Not currently supported by the CloudWatch Agent Operator CRD. Support is planned in a follow-up.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.

