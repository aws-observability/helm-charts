// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

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

# cert-manager is a prerequisite for scenarios that set agent.certManager or
# admissionWebhooks.certManager: the chart creates cert-manager Certificates and
# Issuers, so the CRDs and the cert-manager webhook must exist first.
resource "helm_release" "cert_manager" {
  count      = var.install_cert_manager ? 1 : 0
  depends_on = [null_resource.minikube_start]

  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  timeout          = 600
  wait             = true

  set {
    name  = "crds.enabled"
    value = "true"
  }
}

resource "helm_release" "cloudwatch_observability" {
  depends_on = [null_resource.minikube_start, helm_release.cert_manager]

  name             = "amazon-cloudwatch-observability"
  namespace        = "amazon-cloudwatch"
  create_namespace = true
  chart            = var.helm_dir
  timeout          = 600

  values = [file(var.helm_values_file)]
}

output "helm_release" {
  value = helm_release.cloudwatch_observability
}
