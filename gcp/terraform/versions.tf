terraform {
  # Infra Manager runs Terraform 1.5.7.
  required_version = ">= 1.5.7"

  required_providers {
    # < 7.0: terraform-google-modules/kubernetes-engine 38.0.0 requires google < 7.
    google = {
      source  = "hashicorp/google"
      version = ">= 6.42.0, < 7.0.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.42.0, < 7.0.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
  }
}
