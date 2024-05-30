// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "k8s_version" {
  type    = string
  default = "1.30"
}

# eks addon and helm tests are similar
variable "test_dir" {
  type    = string
  default = "../../validator"
}

variable "helm_dir" {
  type    = string
  default = "../../../../charts/amazon-cloudwatch-observability"
}

variable "kube_dir" {
  type    = string
  default = "~/.kube"
}

variable "cluster_name" {
  type    = string
  default = "cwagent-helm-chart-integ"
}
