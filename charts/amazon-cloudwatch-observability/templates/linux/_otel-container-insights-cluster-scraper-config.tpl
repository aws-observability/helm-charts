{{- define "otel-container-insights-cluster-scraper.config" -}}
extensions:
  sigv4auth/cw_k8s_ci_v0_cwotel:
    region: {{ .Values.region }}
    service: monitoring

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
                - {{ include "kube-state-metrics.name" . }}.{{ .Release.Namespace }}.svc:8443
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
          - delete_key(attributes, "host.id")
          - delete_key(attributes, "host.name")
          - delete_key(attributes, "host.type")
          - delete_key(attributes, "host.image.id")

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

  # Rename raw Prometheus label names (now in resource scope from groupbyattrs)
  # to OTel semantic convention names.
  transform/cw_k8s_ci_v0_ksm_promote:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(attributes["k8s.pod.name"], attributes["pod"]) where attributes["pod"] != nil
          - delete_key(attributes, "pod") where attributes["pod"] != nil
          - set(attributes["k8s.namespace.name"], attributes["namespace"]) where attributes["namespace"] != nil
          - delete_key(attributes, "namespace") where attributes["namespace"] != nil
          - set(attributes["k8s.node.name"], attributes["node"]) where attributes["node"] != nil
          - delete_key(attributes, "node") where attributes["node"] != nil
          - set(attributes["k8s.pod.uid"], attributes["uid"]) where attributes["uid"] != nil
          - delete_key(attributes, "uid") where attributes["uid"] != nil
          - set(attributes["k8s.container.name"], attributes["container"]) where attributes["container"] != nil
          - delete_key(attributes, "container") where attributes["container"] != nil
          - set(attributes["k8s.workload.name"], attributes["owner_name"]) where attributes["owner_name"] != nil
          - set(attributes["k8s.workload.type"], attributes["owner_kind"]) where attributes["owner_kind"] != nil
          - delete_key(attributes, "owner_name") where attributes["owner_name"] != nil
          - delete_key(attributes, "owner_kind") where attributes["owner_kind"] != nil
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
    detectors: [ec2, eks]
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

  transform/cw_k8s_ci_v0_clear_schema_url:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(resource.schema_url, "")

  awsattributelimit/cw_k8s_ci_v0:
    max_total_attributes: 150

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
  pipelines:
    metrics/cw_k8s_ci_v0_apiserver:
      receivers: [prometheus/cw_k8s_ci_v0_apiserver]
      processors:
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
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_cwotel
      exporters:
        - otlphttp/cw_k8s_ci_v0_cwotel
{{- end }}
{{- end -}}

