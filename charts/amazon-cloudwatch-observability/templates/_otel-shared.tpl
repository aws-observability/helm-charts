{{/*
OTel processors that the Container Insights node agent config and the OTLP
endpoint config (otlp) both use. Each renders with the same name and the same
settings in both, so when both are on the merged config defines it once. They
enrich or limit telemetry of any signal, apply to metrics only, or sign and
send metrics to CloudWatch. The OTLP config defines its own logs and traces
signing extensions, logs provisioner and namespace filters, so that the
Container Insights logs components appear only when
otelContainerInsights.logs.enabled is true.
*/}}

{{/* Cloud and host attributes of the node, per k8sMode. */}}
{{- define "otel-shared.processor.resourcedetection" -}}
resourcedetection/cw_k8s_ci_v0:
  {{- if eq .Values.k8sMode "AKS" }}
  detectors: [aks, azure]
  aks:
    resource_attributes:
      cloud.platform: { enabled: true }
      cloud.provider: { enabled: true }
      k8s.cluster.name: { enabled: false }
  azure:
    resource_attributes:
      azure.resourcegroup.name: { enabled: true }
      azure.vm.name: { enabled: true }
      azure.vm.scaleset.name: { enabled: true }
      azure.vm.size: { enabled: true }
      cloud.account.id: { enabled: true }
      cloud.platform: { enabled: true }
      cloud.provider: { enabled: true }
      cloud.region: { enabled: true }
      host.id: { enabled: true }
      host.name: { enabled: true }
  {{- else if eq .Values.k8sMode "GKE" }}
  detectors: [gcp]
  gcp:
    resource_attributes:
      cloud.account.id: { enabled: true }
      cloud.availability_zone: { enabled: true }
      cloud.platform: { enabled: true }
      cloud.provider: { enabled: true }
      cloud.region: { enabled: true }
      host.id: { enabled: true }
      host.name: { enabled: true }
      k8s.cluster.name: { enabled: false }
  {{- else }}
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
  {{- end }}
{{- end -}}

{{/* Node labels, filtered by otelFilters.nodeLabels, for records that carry k8s.node.name. */}}
{{- define "otel-shared.processor.k8sattributesNode" -}}
k8sattributes/cw_k8s_ci_v0_node:
  auth_type: serviceAccount
  passthrough: false
  filter:
    node_from_env_var: K8S_NODE_NAME
  extract:
    metadata:
      - k8s.node.name
    labels:
      {{- include "otel-container-insights.k8sattributesLabels" (dict "Values" .Values "from" "node") | trim | nindent 6 }}
  pod_association:
    - sources:
        - from: resource_attribute
          name: k8s.node.name
{{- end -}}

{{/* The attribute limit, which also removes the otelFilters label removals from metrics. */}}
{{- define "otel-shared.processor.awsattributelimit" -}}
awsattributelimit/cw_k8s_ci_v0:
  max_total_attributes: 150
  {{- $labelRemovals := include "otel-container-insights.labelRemovals" (dict "Values" .Values) | fromJson }}
  {{- with $labelRemovals.prefixes }}
  unconditional_removal_prefixes:
    {{- range . }}
    - {{ . | quote }}
    {{- end }}
  {{- end }}
  {{- with $labelRemovals.keys }}
  unconditional_removal_keys:
    {{- range . }}
    - {{ . | quote }}
    {{- end }}
  {{- end }}
{{- end -}}


{{/* Signs the metrics exports to CloudWatch (service monitoring). */}}
{{- define "otel-shared.extension.sigv4authMetrics" -}}
sigv4auth/cw_k8s_ci_v0_metrics_dest:
  region: {{ .Values.region }}
  service: monitoring
{{- end -}}

{{/* Sends metrics to the CloudWatch OTLP metrics endpoint, or to otelContainerInsights.cloudwatchMetricsEndpoint when set. */}}
{{- define "otel-shared.exporter.otlphttpMetrics" -}}
otlphttp/cw_k8s_ci_v0_metrics_dest:
  endpoint: {{ if .Values.otelContainerInsights.cloudwatchMetricsEndpoint }}{{ .Values.otelContainerInsights.cloudwatchMetricsEndpoint | quote }}{{ else }}"https://monitoring.{{ .Values.region }}.amazonaws.com:443"{{ end }}
  tls:
    insecure: false
  auth:
    authenticator: sigv4auth/cw_k8s_ci_v0_metrics_dest
{{- end -}}
