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

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks_windows_cluster_ca.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}