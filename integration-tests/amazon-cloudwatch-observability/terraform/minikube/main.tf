// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

resource "null_resource" "minikube_start" {
  provisioner "local-exec" {
    command = <<-EOT
      minikube start --driver=docker --kubernetes-version=${var.k8s_version}
      minikube status
    EOT
  }
  
  provisioner "local-exec" {
    when    = destroy
    command = "minikube delete"
  }
}

resource "helm_release" "cloudwatch_observability" {
  depends_on = [null_resource.minikube_start]

  name             = "amazon-cloudwatch-observability"
  namespace        = "amazon-cloudwatch"
  create_namespace = true
  chart            = var.helm_dir

  values = [file(var.helm_values_file)]
}

output "helm_release" {
  value = helm_release.cloudwatch_observability
}
