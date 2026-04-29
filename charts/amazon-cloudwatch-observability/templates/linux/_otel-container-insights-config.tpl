{{- define "otel-container-insights.config" -}}
extensions:
  sigv4auth/cw_k8s_ci_v0_metrics_dest:
    region: {{ .Values.region }}
    service: monitoring

receivers:
{{- if .Values.nodeExporter.enabled }}
  prometheus/cw_k8s_ci_v0_node_exporter:
    config:
      scrape_configs:
        - job_name: node-exporter
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          scheme: https
          tls_config:
            ca_file: /etc/amazon-cloudwatch-observability-agent-client-cert/tls-ca.crt
            insecure_skip_verify: true
          static_configs:
            - targets:
                - ${env:HOST_IP}:9487
{{- end }}

  prometheus/cw_k8s_ci_v0_cadvisor:
    config:
      scrape_configs:
        - job_name: cadvisor
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          scheme: https
          tls_config:
            insecure_skip_verify: true
          bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          metrics_path: /metrics/cadvisor
          static_configs:
            - targets:
                - ${env:HOST_IP}:10250

  {{- if .Values.dcgmExporter.enabled }}
  prometheus/cw_k8s_ci_v0_dcgm:
    config:
      scrape_configs:
        - job_name: dcgm-exporter
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          scheme: https
          tls_config:
            ca_file: /etc/amazon-cloudwatch-observability-agent-client-cert/tls-ca.crt
          static_configs:
            - targets:
                - dcgm-exporter-service:9400
  {{- end }}

  {{- if .Values.neuronMonitor.enabled }}
  prometheus/cw_k8s_ci_v0_neuron:
    config:
      scrape_configs:
        - job_name: neuron-monitor
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          scheme: https
          tls_config:
            ca_file: /etc/amazon-cloudwatch-observability-agent-client-cert/tls-ca.crt
          static_configs:
            - targets:
                - neuron-monitor-service:8000
  {{- end }}

  awsefareceiver/cw_k8s_ci_v0:
    collection_interval: {{ .Values.otelContainerInsights.metricResolution }}

  prometheus/cw_k8s_ci_v0_ebs_csi_node:
    config:
      scrape_configs:
        - job_name: ebs-csi-node
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          kubernetes_sd_configs:
            - role: pod
              namespaces:
                names:
                  - kube-system
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_label_app]
              regex: ebs-csi-node
              action: keep
            - source_labels: [__meta_kubernetes_pod_node_name]
              regex: ${env:K8S_NODE_NAME}
              action: keep
            - source_labels: [__meta_kubernetes_pod_container_port_name]
              regex: metrics
              action: keep

  kubeletstats/cw_k8s_ci_v0:
    auth_type: serviceAccount
    collection_interval: {{ .Values.otelContainerInsights.metricResolution }}
    endpoint: "https://${env:HOST_IP}:10250"
    insecure_skip_verify: true
    metric_groups:
      - pod
      - container
      - node
    metrics:
      k8s.pod.cpu_limit_utilization:
        enabled: true
      k8s.pod.cpu_request_utilization:
        enabled: true
      k8s.pod.memory_limit_utilization:
        enabled: true
      k8s.pod.memory_request_utilization:
        enabled: true
      k8s.container.cpu_limit_utilization:
        enabled: true
      k8s.container.cpu_request_utilization:
        enabled: true
      k8s.container.memory_limit_utilization:
        enabled: true
      k8s.container.memory_request_utilization:
        enabled: true
      k8s.pod.cpu.usage:
        enabled: true
      container.cpu.usage:
        enabled: true
      k8s.node.cpu.usage:
        enabled: true
      k8s.pod.uptime:
        enabled: true
      container.uptime:
        enabled: true
      k8s.node.uptime:
        enabled: true

processors:
  filter/cw_k8s_ci_v0_scrape_metadata:
    error_mode: ignore
    metrics:
      metric:
        - IsMatch(name, "^(up|scrape_duration_seconds|scrape_samples_scraped|scrape_samples_post_metric_relabeling|scrape_series_added)$")

  transform/cw_k8s_ci_v0_set_unit:
    error_mode: ignore
    metric_statements:
      - context: metric
        statements:
          # Time
          - set(unit, "s") where IsMatch(name, ".*_seconds(_total)?$")
          - set(unit, "ms") where IsMatch(name, ".*_milliseconds(_total)?$")
          - set(unit, "us") where IsMatch(name, ".*_microseconds(_total)?$")
          - set(unit, "ns") where IsMatch(name, ".*_nanoseconds(_total)?$")
          # Bytes
          - set(unit, "By") where IsMatch(name, ".*_bytes(_total)?$")
          - set(unit, "KBy") where IsMatch(name, ".*_kilobytes(_total)?$")
          - set(unit, "MBy") where IsMatch(name, ".*_megabytes(_total)?$")
          - set(unit, "GBy") where IsMatch(name, ".*_gigabytes(_total)?$")
          - set(unit, "KiBy") where IsMatch(name, ".*_kibibytes(_total)?$")
          - set(unit, "MiBy") where IsMatch(name, ".*_mebibytes(_total)?$")
          - set(unit, "GiBy") where IsMatch(name, ".*_gibibytes(_total)?$")
          # Other
          - set(unit, "Cel") where IsMatch(name, ".*_celsius$")
          - set(unit, "Hz") where IsMatch(name, ".*_hertz$")
          - set(unit, "1") where IsMatch(name, ".*_ratio$")
          - set(unit, "%") where IsMatch(name, ".*_percent$")
          - set(unit, "V") where IsMatch(name, ".*_volts$")
          - set(unit, "W") where IsMatch(name, ".*_watts$")
          - set(unit, "J") where IsMatch(name, ".*_joules$")
          - set(unit, "A") where IsMatch(name, ".*_amperes$")
          - set(unit, "m") where IsMatch(name, ".*_meters(_total)?$")
          # Counters with only _total suffix (dimensionless count)
          - set(unit, "1") where unit == "" and IsMatch(name, ".*_total$")
          # DCGM explicit mappings (no suffix convention)
          - set(unit, "%") where name == "DCGM_FI_DEV_GPU_UTIL"
          - set(unit, "%") where name == "DCGM_FI_DEV_MEM_COPY_UTIL"
          - set(unit, "%") where name == "DCGM_FI_PROF_PIPE_TENSOR_ACTIVE"
          - set(unit, "MiBy") where name == "DCGM_FI_DEV_FB_USED"
          - set(unit, "MiBy") where name == "DCGM_FI_DEV_FB_FREE"
          - set(unit, "MiBy") where name == "DCGM_FI_DEV_FB_TOTAL"
          - set(unit, "Cel") where name == "DCGM_FI_DEV_GPU_TEMP"
          - set(unit, "W") where name == "DCGM_FI_DEV_POWER_USAGE"
          - set(unit, "MHz") where name == "DCGM_FI_DEV_SM_CLOCK"
          # Neuron explicit mappings
          - set(unit, "By") where IsMatch(name, "^neuroncore_memory_usage_.*")

  transform/cw_k8s_ci_v0_set_cluster_name:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.cluster.name"], "{{ .Values.clusterName }}")

{{- if .Values.nodeExporter.enabled }}
  transform/cw_k8s_ci_v0_set_scope_node_exporter:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.name, "github.com/prometheus/node_exporter")
          - set(scope.version, "{{ include "node-exporter.scopeVersion" . }}")
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "node-exporter")
{{- end }}

  transform/cw_k8s_ci_v0_set_scope_cadvisor:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.name, "github.com/google/cadvisor")
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "cadvisor")

  {{- if .Values.dcgmExporter.enabled }}
  transform/cw_k8s_ci_v0_set_scope_dcgm:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.name, "github.com/NVIDIA/dcgm-exporter")
          - set(scope.version, "{{ .Values.dcgmExporter.image.tag }}")
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "dcgm")
  {{- end }}

  {{- if .Values.neuronMonitor.enabled }}
  transform/cw_k8s_ci_v0_set_scope_neuron_monitor:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.name, "awsneuron")
          - set(scope.version, "{{ .Values.neuronMonitor.image.tag }}")
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "neuron-monitor")
  {{- end }}

  transform/cw_k8s_ci_v0_set_scope_efa:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "efa")

  transform/cw_k8s_ci_v0_set_scope_ebs_csi:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "ebs-csi")

  transform/cw_k8s_ci_v0_set_scope_kubeletstats:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "kubeletstats")

  transform/cw_k8s_ci_v0_set_node_name:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(attributes["node_name"], "${env:K8S_NODE_NAME}")

  transform/cw_k8s_ci_v0_promote_node_name:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.node.name"], attributes["node_name"]) where attributes["node_name"] != nil

  resourcedetection/cw_k8s_ci_v0:
    detectors: [eks, ec2]
    ec2:
      resource_attributes:
        host.id: { enabled: true }
        host.type: { enabled: true }
        host.name: { enabled: true }
        host.image.id: { enabled: true }
        cloud.provider: { enabled: true }
        cloud.platform: { enabled: true }
        cloud.region: { enabled: true }
        cloud.availability_zone: { enabled: true }
        cloud.account.id: { enabled: true }

  transform/cw_k8s_ci_v0_clear_schema_url:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(resource.schema_url, "")

  k8sattributes/cw_k8s_ci_v0_node:
    auth_type: serviceAccount
    passthrough: false
    extract:
      metadata:
        - k8s.node.name
      labels:
        - tag_name: "k8s.node.label.$$$1"
          key_regex: "(.*)"
          from: node
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.node.name

  k8sattributes/cw_k8s_ci_v0_pod:
    auth_type: serviceAccount
    passthrough: false
    extract:
      metadata:
        - k8s.pod.uid
        - k8s.node.name
        - k8s.deployment.name
        - k8s.statefulset.name
        - k8s.daemonset.name
        - k8s.replicaset.name
        - k8s.job.name
        - k8s.cronjob.name
      labels:
        - tag_name: "k8s.pod.label.$$$1"
          key_regex: "(.*)"
          from: pod
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.pod.name
          - from: resource_attribute
            name: k8s.namespace.name

  awsattributelimit/cw_k8s_ci_v0:
    max_total_attributes: 150
    unconditional_removal_prefixes:
      - "k8s.node.label.feature.node.kubernetes.io/"
      - "k8s.node.label.beta.kubernetes.io/"
      - "k8s.node.label.failure-domain.beta.kubernetes.io/"
      - "k8s.node.label.alpha.eksctl.io/"
    unconditional_removal_keys:
      - "k8s.node.label.topology.kubernetes.io/region"
      - "k8s.node.label.topology.kubernetes.io/zone"
      - "k8s.node.label.topology.ebs.csi.aws.com/zone"
      - "k8s.node.label.node.kubernetes.io/instance-type"
      - "k8s.node.label.kubernetes.io/hostname"
      - "k8s.node.label.helm.sh/chart"
      - "k8s.node.label.release"
      - "k8s.node.label.eks.amazonaws.com/nodegroup-image"
      - "k8s.node.label.k8s.io/cloud-provider-aws"
      - "k8s.node.label.eks.amazonaws.com/sourceLaunchTemplateId"
      - "k8s.node.label.eks.amazonaws.com/sourceLaunchTemplateVersion"
      - "k8s.pod.label.pod-template-hash"
      - "k8s.pod.label.controller-revision-hash"

  transform/cw_k8s_ci_v0_set_cloud_resource_id:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(resource.attributes["cloud.resource_id"], Concat(["arn:aws:eks:", resource.attributes["cloud.region"], ":", resource.attributes["cloud.account.id"], ":cluster/", resource.attributes["k8s.cluster.name"]], ""))
            where resource.attributes["cloud.region"] != nil and resource.attributes["cloud.account.id"] != nil and resource.attributes["k8s.cluster.name"] != nil

  metricstarttime/cw_k8s_ci_v0:

  transform/cw_k8s_ci_v0_set_workload:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.deployment.name"]) where resource.attributes["k8s.deployment.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "Deployment") where resource.attributes["k8s.deployment.name"] != nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.statefulset.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.statefulset.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "StatefulSet") where resource.attributes["k8s.statefulset.name"] != nil and resource.attributes["k8s.workload.type"] == nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.daemonset.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.daemonset.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "DaemonSet") where resource.attributes["k8s.daemonset.name"] != nil and resource.attributes["k8s.workload.type"] == nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.job.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.job.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "Job") where resource.attributes["k8s.job.name"] != nil and resource.attributes["k8s.workload.type"] == nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.cronjob.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.cronjob.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "CronJob") where resource.attributes["k8s.cronjob.name"] != nil and resource.attributes["k8s.workload.type"] == nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.replicaset.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.replicaset.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "ReplicaSet") where resource.attributes["k8s.replicaset.name"] != nil and resource.attributes["k8s.workload.type"] == nil

  batch/cw_k8s_ci_v0_metrics_dest:
    send_batch_size: 500
    send_batch_max_size: 500
    timeout: 10s

  filter/cw_k8s_ci_v0_cadvisor_empty:
    error_mode: ignore
    metrics:
      datapoint:
        - attributes["container"] == "" and attributes["pod"] == ""
        - attributes["container"] == "" and attributes["pod"] == nil
        - attributes["container"] == nil and attributes["pod"] == ""
        - attributes["container"] == nil and attributes["pod"] == nil

  filter/cw_k8s_ci_v0_cadvisor_pod:
    error_mode: ignore
    metrics:
      datapoint:
        - attributes["container"] == "POD"

  groupbyattrs/cw_k8s_ci_v0_cadvisor:
    keys:
      - container
      - pod
      - namespace

  transform/cw_k8s_ci_v0_cadvisor_promote:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(attributes["k8s.container.name"], attributes["container"]) where attributes["container"] != nil and attributes["container"] != ""
          - set(attributes["k8s.pod.name"], attributes["pod"]) where attributes["pod"] != nil
          - set(attributes["k8s.namespace.name"], attributes["namespace"]) where attributes["namespace"] != nil
      - context: datapoint
        statements:
          # Restore raw Prometheus names to datapoint scope (groupbyattrs removed them).
          - set(attributes["container"], resource.attributes["container"]) where resource.attributes["container"] != nil
          - set(attributes["pod"], resource.attributes["pod"]) where resource.attributes["pod"] != nil
          - set(attributes["namespace"], resource.attributes["namespace"]) where resource.attributes["namespace"] != nil

  {{- if .Values.dcgmExporter.enabled }}
  groupbyattrs/cw_k8s_ci_v0_dcgm:
    keys:
      - pod
      - namespace
      - container

  transform/cw_k8s_ci_v0_dcgm_promote:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(attributes["k8s.pod.name"], attributes["pod"]) where attributes["pod"] != nil
          - set(attributes["k8s.namespace.name"], attributes["namespace"]) where attributes["namespace"] != nil
          - set(attributes["k8s.container.name"], attributes["container"]) where attributes["container"] != nil
      - context: datapoint
        statements:
          # Restore raw Prometheus names to datapoint scope (groupbyattrs removed them).
          # Raw labels are still at resource scope (not deleted), so copy them back down.
          - set(attributes["pod"], resource.attributes["pod"]) where resource.attributes["pod"] != nil
          - set(attributes["namespace"], resource.attributes["namespace"]) where resource.attributes["namespace"] != nil
          - set(attributes["container"], resource.attributes["container"]) where resource.attributes["container"] != nil
          # Clean up leftover datapoint attributes not needed downstream.
          - delete_key(attributes, "Hostname") where attributes["Hostname"] != nil
          - delete_key(attributes, "pci_bus_id") where attributes["pci_bus_id"] != nil
  {{- end }}

  {{- if .Values.neuronMonitor.enabled }}
  filter/cw_k8s_ci_v0_neuron:
    error_mode: ignore
    metrics:
      metric:
        - IsMatch(name, "^(neuron|execution_|hardware_ecc_)") != true

  awsneuron/cw_k8s_ci_v0:

  groupbyattrs/cw_k8s_ci_v0_neuron:
    keys:
      - k8s.pod.name
      - k8s.namespace.name
      - k8s.container.name

  transform/cw_k8s_ci_v0_neuron_promote:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.pod.name"], attributes["k8s.pod.name"]) where attributes["k8s.pod.name"] != nil
          - set(resource.attributes["k8s.namespace.name"], attributes["k8s.namespace.name"]) where attributes["k8s.namespace.name"] != nil
          - set(resource.attributes["k8s.container.name"], attributes["k8s.container.name"]) where attributes["k8s.container.name"] != nil
          - set(resource.attributes["aws.neuron.runtime.tag"], attributes["runtime_tag"]) where attributes["runtime_tag"] != nil
          - delete_key(attributes, "k8s.pod.name") where attributes["k8s.pod.name"] != nil
          - delete_key(attributes, "k8s.namespace.name") where attributes["k8s.namespace.name"] != nil
          - delete_key(attributes, "k8s.container.name") where attributes["k8s.container.name"] != nil
          - delete_key(attributes, "runtime_tag") where attributes["runtime_tag"] != nil

  transform/cw_k8s_ci_v0_neuron_hw_attrs:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(attributes["aws.neuron.device"], attributes["neurondevice"]) where attributes["neurondevice"] != nil
          - set(attributes["aws.neuron.core"], attributes["neuroncore"]) where attributes["neuroncore"] != nil
          - delete_key(attributes, "neuroncore") where attributes["neuroncore"] != nil
          - delete_key(attributes, "neurondevice") where attributes["neurondevice"] != nil
          - delete_key(attributes, "instance_type") where attributes["instance_type"] != nil
  {{- end }}

  awsdevicepodcorrelation/cw_k8s_ci_v0:
    device_types:
      - name: neuron-by-core
        device_id_attribute: neuroncore
        resource_names:
          - aws.amazon.com/neuroncore
      - name: neuron-by-device
        device_id_attribute: neurondevice
        resource_names:
          - aws.amazon.com/neurondevice
          - aws.amazon.com/neuron
      - name: efa
        device_id_attribute: aws.efa.device
        resource_names:
          - vpc.amazonaws.com/efa

  transform/cw_k8s_ci_v0_efa_promote:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.pod.name"], attributes["k8s.pod.name"]) where attributes["k8s.pod.name"] != nil
          - set(resource.attributes["k8s.namespace.name"], attributes["k8s.namespace.name"]) where attributes["k8s.namespace.name"] != nil
          - set(resource.attributes["k8s.container.name"], attributes["k8s.container.name"]) where attributes["k8s.container.name"] != nil
          - delete_key(attributes, "k8s.pod.name") where attributes["k8s.pod.name"] != nil
          - delete_key(attributes, "k8s.namespace.name") where attributes["k8s.namespace.name"] != nil
          - delete_key(attributes, "k8s.container.name") where attributes["k8s.container.name"] != nil

  transform/cw_k8s_ci_v0_ebs_csi_promote:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["instance_id"], attributes["instance_id"]) where attributes["instance_id"] != nil
          - set(resource.attributes["volume_id"], attributes["volume_id"]) where attributes["volume_id"] != nil
          - delete_key(attributes, "instance_id") where attributes["instance_id"] != nil
          - delete_key(attributes, "volume_id") where attributes["volume_id"] != nil

exporters:
  otlphttp/cw_k8s_ci_v0_metrics_dest:
    endpoint: {{ if .Values.otelContainerInsights.cloudwatchMetricsEndpoint }}{{ .Values.otelContainerInsights.cloudwatchMetricsEndpoint | quote }}{{ else }}"https://monitoring.{{ .Values.region }}.amazonaws.com:443"{{ end }}
    tls:
      insecure: false
    auth:
      authenticator: sigv4auth/cw_k8s_ci_v0_metrics_dest

service:
  extensions:
    - sigv4auth/cw_k8s_ci_v0_metrics_dest
  pipelines:
{{- if .Values.nodeExporter.enabled }}
    metrics/cw_k8s_ci_v0_node_exporter:
      receivers: [prometheus/cw_k8s_ci_v0_node_exporter]
      processors:
        - filter/cw_k8s_ci_v0_scrape_metadata
        - transform/cw_k8s_ci_v0_set_unit
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cluster_name
        - transform/cw_k8s_ci_v0_set_node_name
        - transform/cw_k8s_ci_v0_promote_node_name
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_node
        - transform/cw_k8s_ci_v0_set_scope_node_exporter
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_workload
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest
{{- end }}

    metrics/cw_k8s_ci_v0_cadvisor:
      receivers: [prometheus/cw_k8s_ci_v0_cadvisor]
      processors:
        - filter/cw_k8s_ci_v0_scrape_metadata
        - transform/cw_k8s_ci_v0_set_unit
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cluster_name
        - filter/cw_k8s_ci_v0_cadvisor_empty
        - filter/cw_k8s_ci_v0_cadvisor_pod
        - groupbyattrs/cw_k8s_ci_v0_cadvisor
        - transform/cw_k8s_ci_v0_cadvisor_promote
        - transform/cw_k8s_ci_v0_set_node_name
        - transform/cw_k8s_ci_v0_promote_node_name
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_node
        - k8sattributes/cw_k8s_ci_v0_pod
        - transform/cw_k8s_ci_v0_set_scope_cadvisor
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_workload
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest

    {{- if .Values.dcgmExporter.enabled }}
    metrics/cw_k8s_ci_v0_dcgm:
      receivers: [prometheus/cw_k8s_ci_v0_dcgm]
      processors: [filter/cw_k8s_ci_v0_scrape_metadata, transform/cw_k8s_ci_v0_set_unit, metricstarttime/cw_k8s_ci_v0, transform/cw_k8s_ci_v0_set_cluster_name, groupbyattrs/cw_k8s_ci_v0_dcgm, transform/cw_k8s_ci_v0_dcgm_promote, k8sattributes/cw_k8s_ci_v0_pod, transform/cw_k8s_ci_v0_set_node_name, transform/cw_k8s_ci_v0_promote_node_name, k8sattributes/cw_k8s_ci_v0_node, resourcedetection/cw_k8s_ci_v0, transform/cw_k8s_ci_v0_set_scope_dcgm, transform/cw_k8s_ci_v0_clear_schema_url, transform/cw_k8s_ci_v0_set_cloud_resource_id, transform/cw_k8s_ci_v0_set_workload, awsattributelimit/cw_k8s_ci_v0, batch/cw_k8s_ci_v0_metrics_dest]
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest
    {{- end }}

    {{- if .Values.neuronMonitor.enabled }}
    metrics/cw_k8s_ci_v0_neuron:
      receivers: [prometheus/cw_k8s_ci_v0_neuron]
      processors:
        - filter/cw_k8s_ci_v0_scrape_metadata
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cluster_name
        - filter/cw_k8s_ci_v0_neuron
        - awsneuron/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_unit
        - awsdevicepodcorrelation/cw_k8s_ci_v0
        - groupbyattrs/cw_k8s_ci_v0_neuron
        - transform/cw_k8s_ci_v0_neuron_promote
        - transform/cw_k8s_ci_v0_neuron_hw_attrs
        - k8sattributes/cw_k8s_ci_v0_pod
        - transform/cw_k8s_ci_v0_set_node_name
        - transform/cw_k8s_ci_v0_promote_node_name
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_node
        - transform/cw_k8s_ci_v0_set_scope_neuron_monitor
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_workload
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest
    {{- end }}

    metrics/cw_k8s_ci_v0_efa:
      receivers: [awsefareceiver/cw_k8s_ci_v0]
      processors:
        - transform/cw_k8s_ci_v0_set_unit
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_scope_efa
        - transform/cw_k8s_ci_v0_set_cluster_name
        - awsdevicepodcorrelation/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_efa_promote
        - transform/cw_k8s_ci_v0_set_node_name
        - transform/cw_k8s_ci_v0_promote_node_name
        - k8sattributes/cw_k8s_ci_v0_pod
        - k8sattributes/cw_k8s_ci_v0_node
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - transform/cw_k8s_ci_v0_set_workload
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest

    metrics/cw_k8s_ci_v0_ebs_csi_node:
      receivers: [prometheus/cw_k8s_ci_v0_ebs_csi_node]
      processors:
        - filter/cw_k8s_ci_v0_scrape_metadata
        - transform/cw_k8s_ci_v0_set_unit
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cluster_name
        - transform/cw_k8s_ci_v0_ebs_csi_promote
        - transform/cw_k8s_ci_v0_set_node_name
        - transform/cw_k8s_ci_v0_promote_node_name
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_node
        - transform/cw_k8s_ci_v0_set_scope_ebs_csi
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_workload
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest

    metrics/cw_k8s_ci_v0_kubeletstats:
      receivers: [kubeletstats/cw_k8s_ci_v0]
      processors:
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_scope_kubeletstats
        - transform/cw_k8s_ci_v0_set_cluster_name
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_pod
        - k8sattributes/cw_k8s_ci_v0_node
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_workload
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest

{{- end -}}
