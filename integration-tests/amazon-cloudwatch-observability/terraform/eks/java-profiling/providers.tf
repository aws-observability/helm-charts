// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

provider "aws" {
  region = var.region
}

provider "helm" {
  kubernetes = {
    config_path = "${var.kube_dir}/config"
  }
}
