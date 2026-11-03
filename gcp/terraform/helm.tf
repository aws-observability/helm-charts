provider "helm" {
  alias = "app"
  kubernetes {
    host                   = local.host
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = local.ca_certificate_if_verifying
    insecure               = var.skip_tls_verify
  }
}

locals {
  helm_release_name = var.helm_release_name != "" ? var.helm_release_name : var.goog_cm_deployment_name
}

resource "helm_release" "primary" {
  provider = helm.app

  name = local.helm_release_name
  # Helm creates the namespace rather than a kubernetes_namespace resource: the
  # kubernetes provider can't plan against a cluster whose endpoint is still
  # unknown (create_cluster=true in Marketplace's validation plan) and fails
  # with "default cluster has no server defined"; the helm provider can.
  namespace        = var.namespace
  create_namespace = true

  repository = var.helm_chart_repo
  chart      = var.helm_chart_name
  version    = var.helm_chart_version

  # A first install takes ~3 minutes; atomic rolls back (or uninstalls) on
  # failure instead of leaving a half-installed release.
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true

  values = var.helm_values_yaml == "" ? [] : [var.helm_values_yaml]

  # `set` takes precedence over `values`, so these can't be overridden from
  # the pasted YAML.
  set {
    name  = "k8sMode"
    value = "GKE"
  }

  # Image overrides, populated by Marketplace from schema.yaml's images block.
  # Each image is split into registry / repo / tag to match this chart's
  # existing values.yaml structure (repositoryDomainMap.public + repository + tag).
  set {
    name  = "containerLogs.fluentBit.image.repositoryDomainMap.public"
    value = var.fluent_bit_image_registry
  }
  set {
    name  = "containerLogs.fluentBit.image.repository"
    value = var.fluent_bit_image_repo
  }
  set {
    name  = "containerLogs.fluentBit.image.tag"
    value = var.fluent_bit_image_tag
  }

  set {
    name  = "manager.image.repositoryDomainMap.public"
    value = var.cloudwatch_agent_operator_image_registry
  }
  set {
    name  = "manager.image.repository"
    value = var.cloudwatch_agent_operator_image_repo
  }
  set {
    name  = "manager.image.tag"
    value = var.cloudwatch_agent_operator_image_tag
  }

  set {
    name  = "manager.autoInstrumentationImage.java.repositoryDomain"
    value = var.auto_instrumentation_java_image_registry
  }
  set {
    name  = "manager.autoInstrumentationImage.java.repository"
    value = var.auto_instrumentation_java_image_repo
  }
  set {
    name  = "manager.autoInstrumentationImage.java.tag"
    value = var.auto_instrumentation_java_image_tag
  }

  set {
    name  = "manager.autoInstrumentationImage.python.repositoryDomain"
    value = var.auto_instrumentation_python_image_registry
  }
  set {
    name  = "manager.autoInstrumentationImage.python.repository"
    value = var.auto_instrumentation_python_image_repo
  }
  set {
    name  = "manager.autoInstrumentationImage.python.tag"
    value = var.auto_instrumentation_python_image_tag
  }

  set {
    name  = "manager.autoInstrumentationImage.dotnet.repositoryDomain"
    value = var.auto_instrumentation_dotnet_image_registry
  }
  set {
    name  = "manager.autoInstrumentationImage.dotnet.repository"
    value = var.auto_instrumentation_dotnet_image_repo
  }
  set {
    name  = "manager.autoInstrumentationImage.dotnet.tag"
    value = var.auto_instrumentation_dotnet_image_tag
  }

  set {
    name  = "manager.autoInstrumentationImage.nodejs.repositoryDomain"
    value = var.auto_instrumentation_nodejs_image_registry
  }
  set {
    name  = "manager.autoInstrumentationImage.nodejs.repository"
    value = var.auto_instrumentation_nodejs_image_repo
  }
  set {
    name  = "manager.autoInstrumentationImage.nodejs.tag"
    value = var.auto_instrumentation_nodejs_image_tag
  }

  set {
    name  = "agent.image.repositoryDomainMap.public"
    value = var.cloudwatch_agent_image_registry
  }
  set {
    name  = "agent.image.repository"
    value = var.cloudwatch_agent_image_repo
  }
  set {
    name  = "agent.image.tag"
    value = var.cloudwatch_agent_image_tag
  }

  set {
    name  = "agent.prometheus.targetAllocator.image.repositoryDomainMap.public"
    value = var.target_allocator_image_registry
  }
  set {
    name  = "agent.prometheus.targetAllocator.image.repository"
    value = var.target_allocator_image_repo
  }
  set {
    name  = "agent.prometheus.targetAllocator.image.tag"
    value = var.target_allocator_image_tag
  }

  set {
    name  = "dcgmExporter.image.repositoryDomainMap.public"
    value = var.dcgm_exporter_image_registry
  }
  set {
    name  = "dcgmExporter.image.repository"
    value = var.dcgm_exporter_image_repo
  }
  set {
    name  = "dcgmExporter.image.tag"
    value = var.dcgm_exporter_image_tag
  }

  set {
    name  = "neuronMonitor.image.repositoryDomainMap.public"
    value = var.neuron_monitor_image_registry
  }
  set {
    name  = "neuronMonitor.image.repository"
    value = var.neuron_monitor_image_repo
  }
  set {
    name  = "neuronMonitor.image.tag"
    value = var.neuron_monitor_image_tag
  }

  set {
    name  = "kubeStateMetrics.image.repositoryDomainMap.public"
    value = var.kube_state_metrics_image_registry
  }
  set {
    name  = "kubeStateMetrics.image.repository"
    value = var.kube_state_metrics_image_repo
  }
  set {
    name  = "kubeStateMetrics.image.tag"
    value = var.kube_state_metrics_image_tag
  }

  set {
    name  = "nodeExporter.image.repositoryDomainMap.public"
    value = var.node_exporter_image_registry
  }
  set {
    name  = "nodeExporter.image.repository"
    value = var.node_exporter_image_repo
  }
  set {
    name  = "nodeExporter.image.tag"
    value = var.node_exporter_image_tag
  }
}
