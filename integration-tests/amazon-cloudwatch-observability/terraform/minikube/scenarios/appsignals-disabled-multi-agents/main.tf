// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT

module "base" {
  source           = "../.."
  helm_values_file = "${path.module}/values.yaml"
  helm_dir         = var.helm_dir
}

variable "helm_dir" {
  type    = string
  default = "../../../../../../charts/amazon-cloudwatch-observability"
}

resource "null_resource" "validator" {
  depends_on = [module.base.helm_release]

  provisioner "local-exec" {
    command = "go test ${var.test_dir} -v -run=TestAppSignalsDisabledMultiAgents"
  }
}

variable "test_dir" {
  type    = string
  default = "../../../../validations/minikube/scenarios"
}
