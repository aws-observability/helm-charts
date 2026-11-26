// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

variable "region" {
  type    = string
  default = "us-west-2"
}

# Keep in step with ../variables.tf.
variable "k8s_version" {
  type    = string
  default = "1.33"
}

variable "test_dir" {
  type    = string
  default = "../../../validations/eks"
}

variable "helm_dir" {
  type    = string
  default = "../../../../../charts/amazon-cloudwatch-observability"
}

variable "kube_dir" {
  type    = string
  default = "~/.kube"
}

variable "cluster_name" {
  type    = string
  default = "cwagent-helm-chart-integ-gpu"
}

# Must be in the chart's dcgmExporter node affinity (values.yaml, node.kubernetes.io/instance-type).
variable "instance_type" {
  type    = string
  default = "g4dn.xlarge"
}

variable "nvidia_device_plugin_version" {
  type    = string
  default = "0.20.2"
}

# Operator image tag override; empty means the chart default.
variable "operator_image_tag" {
  type    = string
  default = ""
}
