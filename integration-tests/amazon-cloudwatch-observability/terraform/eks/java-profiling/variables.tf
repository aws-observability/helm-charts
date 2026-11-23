// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "k8s_version" {
  type    = string
  default = "1.33"
}

# eks addon and helm tests are similar
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
  default = "cwagent-helm-chart-integ"
}

variable "instance_type" {
  type    = string
  default = "t3a.medium"
}

# Image overrides; empty means the chart default.
variable "operator_image_domain" {
  type    = string
  default = ""
}

variable "operator_image_tag" {
  type    = string
  default = ""
}

variable "agent_image_domain" {
  type    = string
  default = ""
}

variable "agent_image_repository" {
  type    = string
  default = ""
}

variable "agent_image_tag" {
  type    = string
  default = ""
}

# The chart's OTLP HTTP port (otlp.http.port); the operator sends profiles there.
variable "otlp_http_port" {
  type    = string
  default = "4318"
}
