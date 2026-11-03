variable "project_id" {
  type        = string
  description = "GCP project id"
}

# Marketplace UI deployments require this variable. Cloud Marketplace uses it
# to name the customer's deployment on their deployment page, and it doubles
# as the Helm release name below to avoid resource collisions across multiple
# deployments in one project.
variable "goog_cm_deployment_name" {
  type        = string
  description = "The name of the deployment, provided by Cloud Marketplace to avoid resource name collisions across deployments."
}

# Helm

variable "helm_release_name" {
  type    = string
  default = ""
}

variable "namespace" {
  type        = string
  default     = "amazon-cloudwatch"
  description = "Kubernetes namespace to install the chart into. Created automatically if it doesn't already exist."
}

variable "helm_chart_repo" {
  type    = string
  default = "oci://us-docker.pkg.dev/crestdata-public/gcloud-marketplace-repo"
}

variable "helm_chart_name" {
  type    = string
  default = "amazon-cloudwatch-observability"
}

variable "helm_chart_version" {
  type    = string
  default = "6.7.0"
}

# GKE — real customer deployments always install onto their existing cluster.
# create_cluster exists only for Marketplace's own automated validation plan
# (marketplace_test.tfvars), which needs to spin up an ephemeral test cluster;
# it must never be set for an actual customer deployment.

variable "cluster_name" {
  type        = string
  description = "Name of the GKE cluster to install the chart onto (existing cluster by default)."
}

variable "cluster_location" {
  type        = string
  description = "Location (zone or region) of the GKE cluster."
}

variable "create_cluster" {
  type        = bool
  default     = false
  description = "Marketplace validation only. Must stay false for real customer deployments, which always target their existing cluster."
}

variable "skip_tls_verify" {
  type        = bool
  default     = true
  description = "Local/ad-hoc testing only. Must stay false for Marketplace validation and real customer deployments — disables TLS certificate verification on the kubernetes/helm provider connections to the cluster."
}

# Overrides for the amazon-cloudwatch-observability chart, as JSON or YAML,
# merged over the chart's own values.yaml (like the EKS add-on's
# "Configuration values"). k8sMode and the image fields are
# always overridden by the `set` blocks in helm.tf. The Marketplace form
# pre-fills this from metadata.yaml's defaultValue.
variable "helm_values_yaml" {
  type        = string
  description = "Chart value overrides as JSON or YAML, merged over the chart's defaults. Must set clusterName, region and roleArn."

  validation {
    condition     = can(yamldecode(var.helm_values_yaml)) # JSON is valid YAML
    error_message = "helm_values_yaml must be valid JSON or YAML."
  }

  # Catches the REPLACE_WITH_* placeholders left from the form's default.
  validation {
    condition = alltrue([
      for k in ["clusterName", "roleArn"] :
      !strcontains(try(tostring(yamldecode(var.helm_values_yaml)[k]), ""), "REPLACE_WITH")
    ])
    error_message = "Replace the REPLACE_WITH_* placeholders in clusterName and roleArn with real values."
  }
}

# Container image overrides. Marketplace's "Click to Deploy" flow does not
# inject these (confirmed: it applies the raw module as-is, same as
# helm_chart_repo/name/version above) — they default to this package's own
# mirrored images in gcloud-marketplace-repo.

variable "fluent_bit_image_registry" {
  type    = string
  default = "us-docker.pkg.dev/crestdata-public/gcloud-marketplace-repo"
}
variable "fluent_bit_image_repo" {
  type    = string
  default = "aws-for-fluent-bit"
}
variable "fluent_bit_image_tag" {
  type    = string
  default = "6.7"
}

variable "cloudwatch_agent_operator_image_registry" {
  type    = string
  default = "us-docker.pkg.dev/crestdata-public/gcloud-marketplace-repo"
}
variable "cloudwatch_agent_operator_image_repo" {
  type    = string
  default = "cloudwatch-agent-operator"
}
variable "cloudwatch_agent_operator_image_tag" {
  type    = string
  default = "6.7"
}

variable "auto_instrumentation_java_image_registry" {
  type    = string
  default = "us-docker.pkg.dev/crestdata-public/gcloud-marketplace-repo"
}
variable "auto_instrumentation_java_image_repo" {
  type    = string
  default = "adot-autoinstrumentation-java"
}
variable "auto_instrumentation_java_image_tag" {
  type    = string
  default = "6.7"
}

variable "auto_instrumentation_python_image_registry" {
  type    = string
  default = "us-docker.pkg.dev/crestdata-public/gcloud-marketplace-repo"
}
variable "auto_instrumentation_python_image_repo" {
  type    = string
  default = "adot-autoinstrumentation-python"
}
variable "auto_instrumentation_python_image_tag" {
  type    = string
  default = "6.7"
}

variable "auto_instrumentation_dotnet_image_registry" {
  type    = string
  default = "us-docker.pkg.dev/crestdata-public/gcloud-marketplace-repo"
}
variable "auto_instrumentation_dotnet_image_repo" {
  type    = string
  default = "adot-autoinstrumentation-dotnet"
}
variable "auto_instrumentation_dotnet_image_tag" {
  type    = string
  default = "6.7"
}

variable "auto_instrumentation_nodejs_image_registry" {
  type    = string
  default = "us-docker.pkg.dev/crestdata-public/gcloud-marketplace-repo"
}
variable "auto_instrumentation_nodejs_image_repo" {
  type    = string
  default = "adot-autoinstrumentation-node"
}
variable "auto_instrumentation_nodejs_image_tag" {
  type    = string
  default = "6.7"
}

variable "cloudwatch_agent_image_registry" {
  type    = string
  default = "us-docker.pkg.dev/crestdata-public/gcloud-marketplace-repo"
}
variable "cloudwatch_agent_image_repo" {
  type    = string
  default = "cloudwatch-agent"
}
variable "cloudwatch_agent_image_tag" {
  type    = string
  default = "6.7"
}

variable "target_allocator_image_registry" {
  type    = string
  default = "us-docker.pkg.dev/crestdata-public/gcloud-marketplace-repo"
}
variable "target_allocator_image_repo" {
  type    = string
  default = "cloudwatch-agent-target-allocator"
}
variable "target_allocator_image_tag" {
  type    = string
  default = "6.7"
}

variable "dcgm_exporter_image_registry" {
  type    = string
  default = "us-docker.pkg.dev/crestdata-public/gcloud-marketplace-repo"
}
variable "dcgm_exporter_image_repo" {
  type    = string
  default = "dcgm-exporter"
}
variable "dcgm_exporter_image_tag" {
  type    = string
  default = "6.7"
}

variable "neuron_monitor_image_registry" {
  type    = string
  default = "us-docker.pkg.dev/crestdata-public/gcloud-marketplace-repo"
}
variable "neuron_monitor_image_repo" {
  type    = string
  default = "neuron-monitor"
}
variable "neuron_monitor_image_tag" {
  type    = string
  default = "6.7"
}

variable "kube_state_metrics_image_registry" {
  type    = string
  default = "us-docker.pkg.dev/crestdata-public/gcloud-marketplace-repo"
}
variable "kube_state_metrics_image_repo" {
  type    = string
  default = "kube-state-metrics"
}
variable "kube_state_metrics_image_tag" {
  type    = string
  default = "6.7"
}

variable "node_exporter_image_registry" {
  type    = string
  default = "us-docker.pkg.dev/crestdata-public/gcloud-marketplace-repo"
}
variable "node_exporter_image_repo" {
  type    = string
  default = "node-exporter"
}
variable "node_exporter_image_tag" {
  type    = string
  default = "6.7"
}
