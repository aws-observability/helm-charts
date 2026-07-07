{{- define "otel-container-insights-cluster-scraper.config" -}}
extensions:
  sigv4auth/cw_k8s_ci_v0_cwotel:
    region: {{ .Values.region }}
    service: monitoring
  nodemetadatacache/cw_k8s_ci_v0:
    namespace: {{ .Release.Namespace }}

receivers:
  prometheus/cw_k8s_ci_v0_apiserver:
    config:
      scrape_configs:
        - job_name: kubernetes-apiserver
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          scheme: https
          tls_config:
            ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
            insecure_skip_verify: false
          bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          kubernetes_sd_configs:
            - role: endpoints
              namespaces:
                names:
                  - default
          relabel_configs:
            - source_labels: [__meta_kubernetes_service_name]
              action: keep
              regex: kubernetes
            - source_labels: [__meta_kubernetes_endpoint_port_name]
              action: keep
              regex: https
            - target_label: __metrics_path__
              replacement: /metrics

{{- if .Values.kubeStateMetrics.enabled }}
  prometheus/cw_k8s_ci_v0_kube_state_metrics:
    config:
      scrape_configs:
        - job_name: kube-state-metrics
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          scheme: https
          tls_config:
            ca_file: /etc/amazon-cloudwatch-observability-agent-cert/tls-ca.crt
          static_configs:
            - targets:
                - {{ include "kube-state-metrics.name" . }}.{{ .Release.Namespace }}.svc:{{ .Values.kubeStateMetrics.service.port }}
{{- end }}

{{- if .Values.otelContainerInsights.integrations.karpenter.enabled }}
  prometheus/cw_k8s_ci_v0_karpenter:
    config:
      scrape_configs:
        - job_name: karpenter
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          metrics_path: /metrics
          kubernetes_sd_configs:
            - role: pod
              namespaces:
                names:
                  - {{ .Values.otelContainerInsights.integrations.karpenter.namespace }}
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
              regex: karpenter
              action: keep
            - source_labels: [__meta_kubernetes_pod_container_port_name]
              regex: http-metrics
              action: keep
            - source_labels: [__meta_kubernetes_pod_name]
              target_label: pod
            - source_labels: [__meta_kubernetes_namespace]
              target_label: namespace
            - source_labels: [__meta_kubernetes_pod_node_name]
              target_label: node
{{- end }}

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
          # ── Suffix-based ──
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
          # ── Counters with only _total suffix (dimensionless count) ──
          - set(unit, "1") where unit == "" and IsMatch(name, ".*_total$")

  metricstarttime/cw_k8s_ci_v0:

  transform/cw_k8s_ci_v0_apiserver_extract_version:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.apiserver.version"], attributes["git_version"]) where attributes["git_version"] != nil and attributes["git_version"] != ""

  filter/cw_k8s_ci_v0_apiserver_build_info:
    error_mode: ignore
    metrics:
      metric:
        - name == "kubernetes_build_info"

  transform/cw_k8s_ci_v0_set_scope_apiserver:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.version, resource.attributes["k8s.apiserver.version"]) where resource.attributes["k8s.apiserver.version"] != nil
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "apiserver")

  transform/cw_k8s_ci_v0_apiserver_cleanup_version:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - delete_key(attributes, "k8s.apiserver.version") where attributes["k8s.apiserver.version"] != nil

{{- if .Values.kubeStateMetrics.enabled }}
  transform/cw_k8s_ci_v0_set_scope_kube_state_metrics:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.name, "github.com/kubernetes/kube-state-metrics")
          - set(scope.version, "{{ include "kube-state-metrics.scopeVersion" . }}")
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "kube-state-metrics")
{{- end }}

{{- if .Values.otelContainerInsights.integrations.karpenter.enabled }}
  transform/cw_k8s_ci_v0_set_scope_karpenter:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.name, "github.com/aws/karpenter")
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "karpenter")

  # Promote scraped pod/namespace/node labels to OTel K8s resource attributes.
  # This allows the shared k8sattributes processor to enrich with deployment/workload info.
  groupbyattrs/cw_k8s_ci_v0_karpenter:
    keys:
      - pod
      - namespace
      - node

  transform/cw_k8s_ci_v0_karpenter_promote:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(attributes["k8s.pod.name"], attributes["pod"]) where attributes["pod"] != nil
          - set(attributes["k8s.namespace.name"], attributes["namespace"]) where attributes["namespace"] != nil
          - set(attributes["k8s.node.name"], attributes["node"]) where attributes["node"] != nil
          # Remove deprecated/unwanted attributes auto-injected by the Prometheus receiver.
          - delete_key(attributes, "net.host.name") where attributes["net.host.name"] != nil
          - delete_key(attributes, "net.host.port") where attributes["net.host.port"] != nil
          - delete_key(attributes, "url.scheme") where attributes["url.scheme"] != nil
      - context: datapoint
        statements:
          - set(attributes["pod"], resource.attributes["pod"]) where resource.attributes["pod"] != nil
          - set(attributes["namespace"], resource.attributes["namespace"]) where resource.attributes["namespace"] != nil
          - set(attributes["node"], resource.attributes["node"]) where resource.attributes["node"] != nil

  # Karpenter-specific resource detection: only cloud-level attributes (region, account).
  # No host/AZ attributes — those would incorrectly reflect the scraper's node, not Karpenter's.
  resourcedetection/cw_k8s_ci_v0_karpenter:
    detectors: [eks, ec2]
    ec2:
      resource_attributes:
        host.id: { enabled: false }
        host.type: { enabled: false }
        host.name: { enabled: false }
        host.image.id: { enabled: false }
        cloud.provider: { enabled: true }
        cloud.platform: { enabled: true }
        cloud.region: { enabled: true }
        cloud.availability_zone: { enabled: false }
        cloud.account.id: { enabled: true }
{{- end }}

  transform/cw_k8s_ci_v0_set_cluster_name:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.cluster.name"], "{{ .Values.clusterName }}")

{{- if .Values.kubeStateMetrics.enabled }}
  transform/cw_k8s_ci_v0_ksm_clean_resource:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          # Remove scraper pod's own K8s identity so only KSM-promoted values remain.
          - delete_key(attributes, "k8s.pod.name")
          - delete_key(attributes, "k8s.pod.uid")
          - delete_key(attributes, "k8s.namespace.name")
          - delete_key(attributes, "k8s.node.name")
          - delete_key(attributes, "k8s.container.name")
          - delete_key(attributes, "k8s.deployment.name")
          - delete_key(attributes, "k8s.replicaset.name")
          - delete_key(attributes, "k8s.workload.name")
          - delete_key(attributes, "k8s.workload.type")

  # Split the single Prometheus scrape resource into per-pod resources.
  # groupbyattrs moves datapoint labels to resource scope, creating one resource
  # per unique (pod, namespace, uid, node) combination.
  groupbyattrs/cw_k8s_ci_v0_ksm:
    keys:
      - pod
      - namespace
      - uid
      - node
      - container
      - owner_name
      - owner_kind
      - deployment
      - daemonset
      - statefulset
      - replicaset
      - job_name
      - cronjob

  # Rename raw Prometheus label names (now in resource scope from groupbyattrs)
  # to OTel semantic convention names. Raw labels stay at resource scope and are
  # copied back to datapoint scope for dashboard compatibility.
  transform/cw_k8s_ci_v0_ksm_promote:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(attributes["k8s.pod.name"], attributes["pod"]) where attributes["pod"] != nil
          - set(attributes["k8s.namespace.name"], attributes["namespace"]) where attributes["namespace"] != nil
          - set(attributes["k8s.node.name"], attributes["node"]) where attributes["node"] != nil
          - set(attributes["k8s.pod.uid"], attributes["uid"]) where attributes["uid"] != nil
          - set(attributes["k8s.container.name"], attributes["container"]) where attributes["container"] != nil
          # Workload identity from owner references (kube_pod_owner metric)
          - set(attributes["k8s.workload.name"], attributes["owner_name"]) where attributes["owner_name"] != nil
          - set(attributes["k8s.workload.type"], attributes["owner_kind"]) where attributes["owner_kind"] != nil
          # K8s object names from object-level metrics (deployment, daemonset, etc.)
          - set(attributes["k8s.deployment.name"], attributes["deployment"]) where attributes["deployment"] != nil
          - set(attributes["k8s.daemonset.name"], attributes["daemonset"]) where attributes["daemonset"] != nil
          - set(attributes["k8s.statefulset.name"], attributes["statefulset"]) where attributes["statefulset"] != nil
          - set(attributes["k8s.job.name"], attributes["job_name"]) where attributes["job_name"] != nil
          - set(attributes["k8s.cronjob.name"], attributes["cronjob"]) where attributes["cronjob"] != nil
          - set(attributes["k8s.replicaset.name"], attributes["replicaset"]) where attributes["replicaset"] != nil
      - context: datapoint
        statements:
          # Restore raw Prometheus names to datapoint scope (groupbyattrs removed them).
          - set(attributes["pod"], resource.attributes["pod"]) where resource.attributes["pod"] != nil
          - set(attributes["namespace"], resource.attributes["namespace"]) where resource.attributes["namespace"] != nil
          - set(attributes["node"], resource.attributes["node"]) where resource.attributes["node"] != nil
          - set(attributes["uid"], resource.attributes["uid"]) where resource.attributes["uid"] != nil
          - set(attributes["container"], resource.attributes["container"]) where resource.attributes["container"] != nil
          - set(attributes["deployment"], resource.attributes["deployment"]) where resource.attributes["deployment"] != nil
          - set(attributes["daemonset"], resource.attributes["daemonset"]) where resource.attributes["daemonset"] != nil
          - set(attributes["statefulset"], resource.attributes["statefulset"]) where resource.attributes["statefulset"] != nil
          - set(attributes["replicaset"], resource.attributes["replicaset"]) where resource.attributes["replicaset"] != nil
          - set(attributes["job_name"], resource.attributes["job_name"]) where resource.attributes["job_name"] != nil
          - set(attributes["cronjob"], resource.attributes["cronjob"]) where resource.attributes["cronjob"] != nil
          - set(attributes["owner_name"], resource.attributes["owner_name"]) where resource.attributes["owner_name"] != nil
          - set(attributes["owner_kind"], resource.attributes["owner_kind"]) where resource.attributes["owner_kind"] != nil

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
        # $$$1 is Helm escaping: $$$ → $$ (Helm) → $ (OTel env resolver) → literal $1 backreference
        - tag_name: "k8s.pod.label.$$$1"
          key_regex: "(.*)"
          from: pod
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.pod.name
          - from: resource_attribute
            name: k8s.namespace.name

  transform/cw_k8s_ci_v0_set_workload:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.deployment.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.deployment.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "Deployment") where resource.attributes["k8s.workload.type"] == nil and resource.attributes["k8s.deployment.name"] != nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.statefulset.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.statefulset.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "StatefulSet") where resource.attributes["k8s.workload.type"] == nil and resource.attributes["k8s.statefulset.name"] != nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.daemonset.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.daemonset.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "DaemonSet") where resource.attributes["k8s.workload.type"] == nil and resource.attributes["k8s.daemonset.name"] != nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.job.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.job.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "Job") where resource.attributes["k8s.workload.type"] == nil and resource.attributes["k8s.job.name"] != nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.cronjob.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.cronjob.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "CronJob") where resource.attributes["k8s.workload.type"] == nil and resource.attributes["k8s.cronjob.name"] != nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.replicaset.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.replicaset.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "ReplicaSet") where resource.attributes["k8s.workload.type"] == nil and resource.attributes["k8s.replicaset.name"] != nil

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
{{- end }}

  transform/cw_k8s_ci_v0_set_component:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(attributes["component"], "apiserver")

  transform/cw_k8s_ci_v0_promote_component:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.component.name"], attributes["component"])

  resourcedetection/cw_k8s_ci_v0:
    detectors: [eks, ec2]
    ec2:
      resource_attributes:
        host.id: { enabled: false }
        host.type: { enabled: false }
        host.name: { enabled: false }
        host.image.id: { enabled: false }
        cloud.provider: { enabled: true }
        cloud.platform: { enabled: true }
        cloud.region: { enabled: true }
        cloud.availability_zone: { enabled: true }
        cloud.account.id: { enabled: true }

  nodemetadataenricher/cw_k8s_ci_v0: {}

  transform/cw_k8s_ci_v0_clear_schema_url:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(resource.schema_url, "")

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

  batch/cw_k8s_ci_v0_cwotel:
    send_batch_size: 500
    send_batch_max_size: 500
    timeout: 10s

exporters:
  otlphttp/cw_k8s_ci_v0_cwotel:
    endpoint: {{ if .Values.otelContainerInsights.cloudwatchMetricsEndpoint }}{{ .Values.otelContainerInsights.cloudwatchMetricsEndpoint | quote }}{{ else }}"https://monitoring.{{ .Values.region }}.amazonaws.com:443"{{ end }}
    tls:
      insecure: false
    auth:
      authenticator: sigv4auth/cw_k8s_ci_v0_cwotel

service:
  extensions:
    - sigv4auth/cw_k8s_ci_v0_cwotel
    - nodemetadatacache/cw_k8s_ci_v0
  pipelines:
    metrics/cw_k8s_ci_v0_apiserver:
      receivers: [prometheus/cw_k8s_ci_v0_apiserver]
      processors:
        - filter/cw_k8s_ci_v0_scrape_metadata
        - transform/cw_k8s_ci_v0_set_unit
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_apiserver_extract_version
        - filter/cw_k8s_ci_v0_apiserver_build_info
        - transform/cw_k8s_ci_v0_set_scope_apiserver
        - transform/cw_k8s_ci_v0_apiserver_cleanup_version
        - transform/cw_k8s_ci_v0_set_cluster_name
        - transform/cw_k8s_ci_v0_set_component
        - transform/cw_k8s_ci_v0_promote_component
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_cwotel
      exporters:
        - otlphttp/cw_k8s_ci_v0_cwotel
{{- if .Values.kubeStateMetrics.enabled }}
    metrics/cw_k8s_ci_v0_kube_state_metrics:
      receivers: [prometheus/cw_k8s_ci_v0_kube_state_metrics]
      processors:
        - filter/cw_k8s_ci_v0_scrape_metadata
        - transform/cw_k8s_ci_v0_set_unit
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_scope_kube_state_metrics
        - transform/cw_k8s_ci_v0_set_cluster_name
        - transform/cw_k8s_ci_v0_ksm_clean_resource
        - groupbyattrs/cw_k8s_ci_v0_ksm
        - transform/cw_k8s_ci_v0_ksm_promote
        - k8sattributes/cw_k8s_ci_v0_pod
        - k8sattributes/cw_k8s_ci_v0_node
        - transform/cw_k8s_ci_v0_set_workload
        - resourcedetection/cw_k8s_ci_v0
        - nodemetadataenricher/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_cwotel
      exporters:
        - otlphttp/cw_k8s_ci_v0_cwotel
{{- end }}
{{- if .Values.otelContainerInsights.integrations.karpenter.enabled }}
    metrics/cw_k8s_ci_v0_karpenter:
      receivers: [prometheus/cw_k8s_ci_v0_karpenter]
      processors:
        - filter/cw_k8s_ci_v0_scrape_metadata
        - transform/cw_k8s_ci_v0_set_unit
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_scope_karpenter
        - transform/cw_k8s_ci_v0_set_cluster_name
        - groupbyattrs/cw_k8s_ci_v0_karpenter
        - transform/cw_k8s_ci_v0_karpenter_promote
        - k8sattributes/cw_k8s_ci_v0_pod
        - transform/cw_k8s_ci_v0_set_workload
        - resourcedetection/cw_k8s_ci_v0_karpenter
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_cwotel
      exporters:
        - otlphttp/cw_k8s_ci_v0_cwotel
{{- end }}
{{- end -}}

