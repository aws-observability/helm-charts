// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT

provider "aws" {
  region = var.region
}

provider "helm" {
  kubernetes {
    config_path = "${var.kube_dir}/config"
  }
}