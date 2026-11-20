provider "google" {
  project = var.project_id
}

provider "google-beta" {
  project = var.project_id
}

data "google_client_config" "default" {}
