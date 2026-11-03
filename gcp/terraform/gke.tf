locals {
  # Real customer deployments (create_cluster=false) target an existing
  # cluster via the data source below: prefer its DNS-based control plane
  # endpoint over the raw IP, since DNS avoids depending on authorized-networks
  # IP allowlisting and is stable across endpoint IP changes. Falls back to the
  # IP endpoint for customer clusters that don't have this (relatively new)
  # GKE feature enabled, where dns_endpoint_config would otherwise be empty.
  #
  # The create_cluster=true branch (Marketplace's own validation plan only,
  # via module.gke) always uses the IP endpoint: the pinned
  # terraform-google-modules/kubernetes-engine/google version here has no
  # input to enable the DNS endpoint on the cluster it provisions, so
  # module.gke[0].endpoint_dns would error (empty dns_endpoint_config list).
  existing_dns_endpoints = var.create_cluster ? [] : flatten([
    for cpe in data.google_container_cluster.default[0].control_plane_endpoints_config : cpe.dns_endpoint_config[*].endpoint
  ])
  dns_endpoint   = length(local.existing_dns_endpoints) > 0 ? local.existing_dns_endpoints[0] : null
  ip_endpoint    = var.create_cluster ? module.gke[0].endpoint : data.google_container_cluster.default[0].endpoint
  endpoint       = "https://${coalesce(local.dns_endpoint, local.ip_endpoint)}"
  ca_certificate = var.create_cluster ? base64decode(module.gke[0].ca_certificate) : base64decode(data.google_container_cluster.default[0].master_auth[0].cluster_ca_certificate)
  # insecure and cluster_ca_certificate are mutually exclusive on the
  # kubernetes/helm providers, so this is only set when TLS verification is on.
  ca_certificate_if_verifying = var.skip_tls_verify ? null : local.ca_certificate
  host                        = local.endpoint
  cluster_name                = var.cluster_name
}

# Real customer deployments never set create_cluster, so this always resolves
# to their existing cluster. create_cluster=true exists only so Marketplace's
# own automated `terraform plan` validation (marketplace_test.tfvars) can spin
# up an ephemeral test cluster instead of depending on one already existing in
# Google's validation environment.
data "google_container_cluster" "default" {
  count    = var.create_cluster ? 0 : 1
  name     = var.cluster_name
  location = var.cluster_location
  project  = var.project_id
}

module "gke" {
  count   = var.create_cluster ? 1 : 0
  source  = "terraform-google-modules/kubernetes-engine/google"
  version = "38.0.0" # pinned: later versions require google >= 7.0, which conflicts with this module's other constraints

  project_id = var.project_id

  name     = var.cluster_name
  region   = var.cluster_location
  regional = length(split("-", var.cluster_location)) == 2
  zones    = length(split("-", var.cluster_location)) > 2 ? [var.cluster_location] : []

  # STABLE channel's default version rather than a pinned one: a pinned GKE
  # version stops being creatable once GKE retires it.
  release_channel = "STABLE"

  # Throwaway validation cluster; Marketplace must be able to tear it down.
  deletion_protection = false

  remove_default_node_pool = true
  initial_node_count       = 1

  network           = "default"
  subnetwork        = "default"
  ip_range_pods     = ""
  ip_range_services = ""

  issue_client_certificate = false

  node_pools = [{
    name         = "cpu-pool"
    machine_type = "n1-standard-4"
    autoscaling  = true
    min_count    = 1
    max_count    = 3
    disk_size_gb = 100
    disk_type    = "pd-standard"
  }]

  node_pools_oauth_scopes = {
    all = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}
