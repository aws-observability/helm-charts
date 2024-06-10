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

By default, the helm chart will enable [Container Insights](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ContainerInsights.html) enhanced observability and [CloudWatch Application Signals](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Application-Monitoring-Sections.html). This helps you to collect infrastructure metrics, application performance telemetry, and container logs from a Kubernetes cluster.

## Windows Support
CloudWatch DaemonSet on Windows is officially supported only for containerd runtime.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.

