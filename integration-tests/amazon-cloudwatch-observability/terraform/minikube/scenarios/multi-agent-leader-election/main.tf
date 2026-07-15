// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT

module "base" {
  source           = "../.."
  helm_values_file = "${path.module}/values.yaml"
  helm_dir         = var.helm_dir
}

// For the purposes of this test scenario, the leader agent's values pin it
// to nodes labeled workload-tier=system (an arbitrary label chosen to
// exercise nodeAffinity propagation — not a requirement of the feature).
// Label the minikube node(s) accordingly so the leader deployment can
// schedule.
resource "null_resource" "label_nodes" {
  depends_on = [module.base.helm_release]

  provisioner "local-exec" {
    command = "kubectl label nodes --all workload-tier=system --overwrite"
  }
}

resource "null_resource" "validator" {
  depends_on = [null_resource.label_nodes]

  provisioner "local-exec" {
    command = "go test ${var.test_dir} -v -run=TestMultiAgentLeaderElection"
  }
}

variable "test_dir" {
  type    = string
  default = "../../../../validations/minikube/scenarios"
}

variable "helm_dir" {
  type    = string
  default = "../../../../../../charts/amazon-cloudwatch-observability"
}
