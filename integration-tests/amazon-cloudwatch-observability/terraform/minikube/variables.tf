// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT

variable "k8s_version" {
  type    = string
  default = "v1.33.0"
}

variable "helm_dir" {
  type    = string
  default = "../../../../charts/amazon-cloudwatch-observability"
}

variable "helm_values_file" {
  type        = string
  description = "Path to helm values file for the specific scenario"
}
