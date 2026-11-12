{{/*
The OTLP endpoint (otlp): an OTLP receiver on the node agent, and one pipeline
per signal that enriches the telemetry like Container Insights enriches the
same pod, applies otelFilters, and exports to the CloudWatch OTLP endpoints.

The pipeline is written here in OTel YAML rather than produced by the agent
from its JSON config, so the chart controls the enrichment and the filters.
Processors shared with the Container Insights node config come from
_otel-shared.tpl and keep their Container Insights names, so a cluster with
both on defines them once. Components only the OTLP pipelines use have
cw_k8s_otlp in their name.
*/}}

{{/*
"true" when the OTLP endpoint renders into the otelConfig of the agent named
.agentName: otlp.enabled is true and the agent is the chart's node agent.
*/}}
{{- define "otlp.enabledFor" -}}
{{- if and .context.Values.otlp.enabled (eq .agentName (include "cloudwatch-agent.name" .context)) }}true{{ end }}
{{- end -}}

{{/*
"true" when an entry of agents renders as the chart's node agent, the agent
named cloudwatch-agent.name that serves the OTLP endpoint. Uses the same name
resolution as the agent CR template (cloudwatch-agent.resolvedName).
*/}}
{{- define "otlp.nodeAgentRendered" -}}
{{- $want := include "cloudwatch-agent.name" . }}
{{- $found := false }}
{{- range .Values.agents }}
{{- if eq (include "cloudwatch-agent.resolvedName" (dict "agent" . "context" $)) $want }}
{{- $found = true }}
{{- end }}
{{- end }}
{{- if $found }}true{{ end }}
{{- end -}}

{{/*
The maximum OTLP/HTTP request body the endpoint accepts, in bytes. The
receiver sets it explicitly (max_request_body_size); it is the collector's
confighttp default, 20 MiB. Charts and senders that need the limit, such as
the profiling integration, read it from here instead of restating it.
*/}}
{{- define "otlp.httpMaxRequestBodyBytes" -}}
20971520
{{- end -}}

{{/*
The OTLP/HTTP base URL of the chart's endpoint, for in-cluster senders the chart
configures itself: http://<node agent>.<release namespace>:<otlp.http.port>,
through the node agent's Service. A sender appends the signal path (for example
/v1development/profiles). Empty when the endpoint does not serve OTLP/HTTP:
otlp.enabled or otlp.http.enabled is false, or no agent renders as the node
agent. A caller that needs the endpoint should fail the render when this is
empty.
*/}}
{{- define "otlp.httpEndpointURL" -}}
{{- $otlp := .Values.otlp }}
{{- if and $otlp.enabled $otlp.http.enabled (include "otlp.nodeAgentRendered" .) }}
{{- printf "http://%s.%s:%d" (include "cloudwatch-agent.name" .) .Release.Namespace (int64 $otlp.http.port) }}
{{- end }}
{{- end -}}

{{/*
Ports the agent already listens on, which the OTLP receiver must not take:
X-Ray (2000), the agent server (4311), the cluster scraper's entity endpoint
(4314), Application Signals (4315, 4316), StatsD (8125), collectd (25826)
and EMF (25888).
*/}}
{{- define "otlp.reservedPorts" -}}
{{- list 2000 4311 4314 4315 4316 8125 25826 25888 | toJson }}
{{- end -}}

{{/*
Validates the otlp block. Types and port ranges are checked whether or not the
endpoint is enabled, so a bad value does not wait for the day it is turned on.
The checks that compare the two protocols run only when otlp.enabled is true.
*/}}
{{- define "otlp.validate" -}}
{{- $otlp := .Values.otlp }}
{{- if not (kindIs "map" $otlp) }}
{{- fail "otlp must be a map with enabled, grpc, http, spanMetrics and profiles" }}
{{- end }}
{{- range $key, $_ := $otlp }}
{{- if not (has $key (list "enabled" "grpc" "http" "spanMetrics" "profiles")) }}
{{- fail (printf "otlp has an unknown key %q (allowed: enabled, grpc, http, spanMetrics, profiles)" $key) }}
{{- end }}
{{- end }}
{{- if not (kindIs "bool" $otlp.enabled) }}
{{- fail "otlp.enabled must be a boolean (true/false)" }}
{{- end }}
{{- $reserved := include "otlp.reservedPorts" . | fromJsonArray }}
{{- $ports := dict }}
{{- range $protocol := list "grpc" "http" }}
{{- $settings := index $otlp $protocol }}
{{- if not (kindIs "map" $settings) }}
{{- fail (printf "otlp.%s must be a map with enabled and port" $protocol) }}
{{- end }}
{{- range $key, $_ := $settings }}
{{- if not (has $key (list "enabled" "port")) }}
{{- fail (printf "otlp.%s has an unknown key %q (allowed: enabled, port)" $protocol $key) }}
{{- end }}
{{- end }}
{{- if not (kindIs "bool" $settings.enabled) }}
{{- fail (printf "otlp.%s.enabled must be a boolean (true/false)" $protocol) }}
{{- end }}
{{- $port := $settings.port }}
{{- if not (and (or (kindIs "int" $port) (kindIs "int64" $port) (kindIs "float64" $port)) (eq (float64 $port) (float64 (int64 $port))) (ge (int64 $port) 1) (le (int64 $port) 65535)) }}
{{- fail (printf "otlp.%s.port must be an integer from 1 to 65535, got: %v" $protocol $port) }}
{{- end }}
{{- if $settings.enabled }}
{{- $_ := set $ports $protocol (int64 $port) }}
{{- end }}
{{- end }}
{{- $spanMetrics := $otlp.spanMetrics }}
{{- if not (kindIs "map" $spanMetrics) }}
{{- fail "otlp.spanMetrics must be a map with enabled" }}
{{- end }}
{{- range $key, $_ := $spanMetrics }}
{{- if ne $key "enabled" }}
{{- fail (printf "otlp.spanMetrics has an unknown key %q (allowed: enabled)" $key) }}
{{- end }}
{{- end }}
{{- if not (kindIs "bool" $spanMetrics.enabled) }}
{{- fail "otlp.spanMetrics.enabled must be a boolean (true/false)" }}
{{- end }}
{{- $profiles := $otlp.profiles }}
{{- if not (kindIs "map" $profiles) }}
{{- fail "otlp.profiles must be a map with enabled" }}
{{- end }}
{{- range $key, $_ := $profiles }}
{{- if ne $key "enabled" }}
{{- fail (printf "otlp.profiles has an unknown key %q (allowed: enabled)" $key) }}
{{- end }}
{{- end }}
{{- if not (kindIs "bool" $profiles.enabled) }}
{{- fail "otlp.profiles.enabled must be a boolean (true/false)" }}
{{- end }}
{{- if $otlp.enabled }}
{{- if not $ports }}
{{- fail "otlp.grpc.enabled and otlp.http.enabled are both false. Enable one of them, or set otlp.enabled to false" }}
{{- end }}
{{- if and (hasKey $ports "grpc") (hasKey $ports "http") (eq $ports.grpc $ports.http) }}
{{- fail (printf "otlp.grpc.port and otlp.http.port must differ, both are %d" $ports.grpc) }}
{{- end }}
{{- range $protocol, $port := $ports }}
{{- if has (float64 $port) $reserved }}
{{- fail (printf "otlp.%s.port %d is already used by the CloudWatch agent (reserved: 2000, 4311, 4314, 4315, 4316, 8125, 25826, 25888)" $protocol $port) }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Endpoint of the CloudWatch OTLP API for .service ("monitoring", "logs" or
"xray"), with the chart's overrides: .override when set, then the region's
adcEndpointOverrides domain for logs and traces, as for the Container
Insights logs exporters. Metrics use the same endpoint as the Container
Insights metrics exporter.
*/}}
{{- define "otlp.endpoint" -}}
{{- $values := .context.Values }}
{{- if .override }}
{{- .override | quote }}
{{- else if and (ne .service "monitoring") (hasKey $values.adcEndpointOverrides $values.region) }}
{{- printf "https://%s.%s.%s:443" .service $values.region (index $values.adcEndpointOverrides $values.region) | quote }}
{{- else }}
{{- printf "https://%s.%s.amazonaws.com:443" .service $values.region | quote }}
{{- end }}
{{- end -}}

{{/*
Renders .statements (a list of OTTL statements in the resource context) once
per signal, as the statement groups of a transform processor.
*/}}
{{- define "otlp.resourceStatements" -}}
{{- range $group := list "metric_statements" "log_statements" "trace_statements" "profile_statements" }}
{{ $group }}:
  - context: resource
    statements:
      {{- range $.statements }}
      - {{ . | squote }}
      {{- end }}
{{- end }}
{{- end -}}

{{/*
OTTL statements that enrich OTLP telemetry like Container Insights enriches
the same pod: the cluster name, the pod's topology, cloud.resource_id and
k8s.workload.*. cloud.resource_id and a Deployment's k8s.workload.* overwrite
what the sender set, as in Container Insights.
*/}}
{{- define "otlp.enrichStatements" -}}
{{- $r := "resource.attributes" }}
{{- $statements := list
  (printf "set(%s[\"k8s.cluster.name\"], \"%s\")" $r .Values.clusterName)
  (printf "set(%s[\"cloud.region\"], %s[\"k8s.pod.label.topology.kubernetes.io/region\"]) where %s[\"cloud.region\"] == nil and %s[\"k8s.pod.label.topology.kubernetes.io/region\"] != nil" $r $r $r $r) }}
{{- if eq .Values.k8sMode "AKS" }}
{{- $statements = concat $statements (list
  (printf "set(%s[\"_tmp.azure.resourcegroup.name\"], %s[\"azure.resourcegroup.name\"]) where %s[\"azure.resourcegroup.name\"] != nil" $r $r $r)
  (printf "replace_pattern(%s[\"_tmp.azure.resourcegroup.name\"], \"^MC_(.+)_%s_[^_]+$\", \"$$$1\")" $r .Values.clusterName)
  (printf "set(%s[\"cloud.resource_id\"], Concat([\"/subscriptions/\", %s[\"cloud.account.id\"], \"/resourceGroups/\", %s[\"_tmp.azure.resourcegroup.name\"], \"/providers/Microsoft.ContainerService/managedClusters/\", %s[\"k8s.cluster.name\"]], \"\")) where %s[\"cloud.account.id\"] != nil and %s[\"_tmp.azure.resourcegroup.name\"] != nil and %s[\"k8s.cluster.name\"] != nil" $r $r $r $r $r $r $r)
  (printf "delete_key(%s, \"_tmp.azure.resourcegroup.name\")" $r)) }}
{{- else if eq .Values.k8sMode "GKE" }}
{{- $statements = concat $statements (list
  (printf "set(%s[\"cloud.resource_id\"], Concat([\"//container.googleapis.com/projects/\", %s[\"cloud.account.id\"], \"/zones/\", %s[\"cloud.availability_zone\"], \"/clusters/\", %s[\"k8s.cluster.name\"]], \"\")) where %s[\"cloud.account.id\"] != nil and %s[\"cloud.availability_zone\"] != nil and %s[\"k8s.cluster.name\"] != nil" $r $r $r $r $r $r $r)
  (printf "set(%s[\"cloud.resource_id\"], Concat([\"//container.googleapis.com/projects/\", %s[\"cloud.account.id\"], \"/locations/\", %s[\"cloud.region\"], \"/clusters/\", %s[\"k8s.cluster.name\"]], \"\")) where %s[\"cloud.resource_id\"] == nil and %s[\"cloud.account.id\"] != nil and %s[\"cloud.region\"] != nil and %s[\"k8s.cluster.name\"] != nil" $r $r $r $r $r $r $r $r)) }}
{{- else }}
{{- $statements = append $statements
  (printf "set(%s[\"cloud.resource_id\"], Concat([\"arn:aws:eks:\", %s[\"cloud.region\"], \":\", %s[\"cloud.account.id\"], \":cluster/\", %s[\"k8s.cluster.name\"]], \"\")) where %s[\"cloud.region\"] != nil and %s[\"cloud.account.id\"] != nil and %s[\"k8s.cluster.name\"] != nil" $r $r $r $r $r $r $r) }}
{{- end }}
{{- /* The pod's zone replaces the detected one only after cloud.resource_id is built, as in the
     Container Insights pipelines: on GKE the resource ID uses the detected zone, which the gcp detector
     sets only for a zonal cluster, so a regional cluster's ID stays locations/<region>. */}}
{{- $statements = append $statements
  (printf "set(%s[\"cloud.availability_zone\"], %s[\"k8s.pod.label.topology.kubernetes.io/zone\"]) where %s[\"k8s.pod.label.topology.kubernetes.io/zone\"] != nil and not IsMatch(%s[\"k8s.pod.label.topology.kubernetes.io/zone\"], \"^[0-9]+$\")" $r $r $r $r) }}
{{- $statements = concat $statements (list
  (printf "set(%s[\"k8s.workload.name\"], %s[\"k8s.deployment.name\"]) where %s[\"k8s.deployment.name\"] != nil" $r $r $r)
  (printf "set(%s[\"k8s.workload.type\"], \"Deployment\") where %s[\"k8s.deployment.name\"] != nil" $r $r)) }}
{{- range $kind := list (list "statefulset" "StatefulSet") (list "daemonset" "DaemonSet") (list "job" "Job") (list "cronjob" "CronJob") (list "replicaset" "ReplicaSet") }}
{{- $attr := printf "%s[\"k8s.%s.name\"]" $r (first $kind) }}
{{- $statements = concat $statements (list
  (printf "set(%s[\"k8s.workload.name\"], %s) where %s[\"k8s.workload.name\"] == nil and %s != nil" $r $attr $r $attr)
  (printf "set(%s[\"k8s.workload.type\"], \"%s\") where %s != nil and %s[\"k8s.workload.type\"] == nil" $r (last $kind) $attr $r)) }}
{{- end }}
{{- toJson $statements }}
{{- end -}}

{{/*
OTTL statements, in a resource context, that remove the otelFilters label
removals from logs and traces. Metrics use the Container Insights processors
instead (awsattributelimit and, for exceptions, the metrics label transform).
*/}}
{{- define "otlp.labelStatements" -}}
{{- $removals := include "otel-container-insights.labelRemovals" (dict "Values" .Values) | fromJson }}
{{- $statements := list }}
{{- with include "otel-container-insights.labelExceptionStatements" $removals | trim }}
{{- range splitList "\n" . }}
{{- $statements = append $statements (trimPrefix "- " .) }}
{{- end }}
{{- end }}
{{- range $removals.prefixes }}
{{- $statements = append $statements (printf "delete_matching_keys(attributes, \"^%s\")" (regexQuoteMeta . | replace "\\" "\\\\")) }}
{{- end }}
{{- range $removals.keys }}
{{- $statements = append $statements (printf "delete_key(attributes, \"%s\")" .) }}
{{- end }}
{{- toJson $statements }}
{{- end -}}

{{/*
The pod metadata, annotations and labels that the OTLP k8sattributes
processors extract: the Container Insights pod labels, and the annotations
and labels that the service identity processor (_service-identity.tpl) reads.
*/}}
{{- define "otlp.podExtract" -}}
extract:
  metadata:
    - k8s.namespace.name
    - k8s.pod.name
    - k8s.pod.uid
    - k8s.pod.start_time
    - k8s.container.name
    - k8s.node.name
    - k8s.deployment.name
    - k8s.replicaset.name
    - k8s.statefulset.name
    - k8s.daemonset.name
    - k8s.job.name
    - k8s.cronjob.name
  annotations:
    {{- include "service-identity.extractAnnotations" . | nindent 4 }}
  labels:
    {{- include "otel-container-insights.k8sattributesLabels" (dict "Values" .Values "from" "pod") | trim | nindent 4 }}
    {{- with include "service-identity.extractLabels" . | trim }}
    {{- . | nindent 4 }}
    {{- end }}
{{- end -}}

{{/*
The node agent's OTLP endpoint config, as OTel YAML.
*/}}
{{- define "otlp.config" -}}
{{- $otlp := .Values.otlp }}
{{- $spanMetrics := $otlp.spanMetrics.enabled }}
{{- $profiles := $otlp.profiles.enabled }}
{{- $metricsNamespaces := include "otel-container-insights.metricsNamespaceFilterEnabled" . }}
{{- $metricsLabels := include "otel-container-insights.metricsLabelFilterEnabled" . }}
{{- $metricNames := include "otel-container-insights.metricNamesFilterEnabled" . }}
{{- $labelStatements := include "otlp.labelStatements" . | fromJsonArray }}
extensions:
  {{- include "otel-shared.extension.sigv4authMetrics" . | nindent 2 }}
  sigv4auth/cw_k8s_otlp_logs_dest:
    region: {{ .Values.region }}
    service: logs
  # Creates the log group and stream of each export before it is sent.
  awscloudwatchlogsprovisioner/cw_k8s_otlp_logs:
    region: {{ .Values.region }}
    additional_auth: sigv4auth/cw_k8s_otlp_logs_dest
  sigv4auth/cw_k8s_otlp_traces_dest:
    region: {{ .Values.region }}
    service: xray
  # Sets the log group and stream of each export from the request context,
  # which attributestocontext/cw_k8s_otlp_logs fills from the resource.
  headers_setter/cw_k8s_otlp_logs:
    additional_auth: awscloudwatchlogsprovisioner/cw_k8s_otlp_logs
    headers:
      - action: upsert
        key: x-aws-log-group
        from_context: aws.log.group.name
      - action: upsert
        key: x-aws-log-stream
        from_context: aws.log.stream.name

receivers:
  # Binds all interfaces so that other pods can send through the
  # cloudwatch-agent Service. Plaintext, without client authentication.
  otlp/cw_k8s_otlp:
    protocols:
      {{- if $otlp.grpc.enabled }}
      grpc:
        endpoint: "0.0.0.0:{{ int64 $otlp.grpc.port }}"
      {{- end }}
      {{- if $otlp.http.enabled }}
      http:
        endpoint: "0.0.0.0:{{ int64 $otlp.http.port }}"
        max_request_body_size: {{ include "otlp.httpMaxRequestBodyBytes" . }}
      {{- end }}

{{- if $spanMetrics }}

connectors:
  # Request rate, error and duration metrics from the traces, with the
  # dimensions of the agent's span_metrics_enabled setting. Each series carries
  # the pod's resource attributes, so a pod that stops sending spans (a rolling
  # deploy, a finished Job) would otherwise keep its series in the cache and be
  # re-exported every flush. metrics_expiration drops a series 5 minutes after
  # its last span (the connector's default, 0, never expires it).
  spanmetrics/cw_k8s_otlp:
    namespace: traces.span.metrics
    metrics_flush_interval: 30s
    metrics_expiration: 5m
    add_resource_attributes: true
    dimensions:
      - name: http.response.status_code
      - name: http.request.method
      - name: http.route
      - name: http.status_code
      - name: http.method
      - name: rpc.grpc.status_code
      - name: rpc.response.status_code
      - name: error.type
{{- end }}

processors:
  # The sender's pod: by the pod attributes the sender set, then by the
  # connection's source IP, which is how an application that sets no pod
  # attributes is found. No k8s.pod.ip source, as in the agent's profiles
  # pipeline (amazon-cloudwatch-agent #2393): it matches by IP without the
  # hostNetwork exclusion of the connection source, so a hostNetwork sender
  # that sets it would get another hostNetwork pod's attributes.
  k8sattributes/cw_k8s_otlp_pod:
    auth_type: serviceAccount
    passthrough: false
    filter:
      node_from_env_var: K8S_NODE_NAME
    {{- include "otlp.podExtract" . | nindent 4 }}
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.pod.uid
      - sources:
          - from: resource_attribute
            name: k8s.pod.name
          - from: resource_attribute
            name: k8s.namespace.name
      - sources:
          - from: connection

  {{- if $profiles }}
  # Profiles, as the agent's profiles pipeline does: by container.id, which the
  # eBPF profiler sets for the process it profiled, then by the connection's
  # source IP. No pod IP source: a hostNetwork sender would match another
  # hostNetwork pod on the node.
  k8sattributes/cw_k8s_otlp_profiles:
    auth_type: serviceAccount
    passthrough: false
    filter:
      node_from_env_var: K8S_NODE_NAME
    {{- include "otlp.podExtract" . | nindent 4 }}
    pod_association:
      - sources:
          - from: resource_attribute
            name: container.id
      - sources:
          - from: connection
  {{- end }}

  {{- include "otel-shared.processor.k8sattributesNode" . | nindent 2 }}

  {{- include "otel-shared.processor.resourcedetection" . | nindent 2 }}

  transform/cw_k8s_otlp_enrich:
    error_mode: ignore
    {{- include "otlp.resourceStatements" (dict "statements" (include "otlp.enrichStatements" . | fromJsonArray)) | trim | nindent 4 }}

  {{- include "service-identity.processor" . | nindent 2 }}

  {{- if $labelStatements }}

  transform/cw_k8s_otlp_labels:
    error_mode: ignore
    log_statements:
      - context: resource
        statements:
          {{- range $labelStatements }}
          - {{ . | squote }}
          {{- end }}
    trace_statements:
      - context: resource
        statements:
          {{- range $labelStatements }}
          - {{ . | squote }}
          {{- end }}
    profile_statements:
      - context: resource
        statements:
          {{- range $labelStatements }}
          - {{ . | squote }}
          {{- end }}
  {{- end }}

  {{- if $metricsLabels }}

  {{- include "otel-container-insights.metricsLabelFilter" . | nindent 2 }}
  {{- end }}

  {{- if $metricsNamespaces }}

  {{- range $signal := concat (list "metrics" "logs" "traces") (ternary (list "profiles") (list) $profiles) }}
  {{- include "otel-container-insights.namespaceFilter" (dict "Values" $.Values "signal" $signal "name" (printf "filter/cw_k8s_otlp_%s_namespaces" $signal)) | nindent 2 }}
  {{- end }}
  {{- end }}

  {{- if $metricNames }}

  {{- include "otel-container-insights.metricNamesFilter" . | nindent 2 }}
  {{- end }}

  transform/cw_k8s_otlp_scope:
    error_mode: ignore
    {{- range $group := list "metric_statements" "log_statements" "trace_statements" "profile_statements" }}
    {{ $group }}:
      - context: scope
        statements:
          - set(scope.attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(scope.attributes["cloudwatch.solution"], "otel-otlp")
    {{- end }}

  # The log group and stream, as for the agent's default:otel config: a
  # sender's aws.log.group.name and aws.log.stream.name win, then
  # /aws/cwagent/<cluster>/<aws.log.source> (otlp unless the sender set it).
  transform/cw_k8s_otlp_logs_routing:
    error_mode: ignore
    log_statements:
      - context: resource
        statements:
          - set(resource.attributes["aws.log.source"], "otlp") where resource.attributes["aws.log.source"] == nil
          - set(resource.attributes["aws.log.group.name"], Concat(["/aws/cwagent", resource.attributes["k8s.cluster.name"], resource.attributes["aws.log.source"]], "/")) where resource.attributes["aws.log.group.name"] == nil and resource.attributes["k8s.cluster.name"] != nil
          - set(resource.attributes["aws.log.stream.name"], Concat([resource.attributes["k8s.namespace.name"], resource.attributes["service.namespace"], resource.attributes["service.name"]], "/")) where resource.attributes["aws.log.stream.name"] == nil and resource.attributes["k8s.namespace.name"] != nil and resource.attributes["service.namespace"] != nil and resource.attributes["service.name"] != nil and not IsMatch(resource.attributes["service.name"], "^unknown_service")
          - set(resource.attributes["aws.log.stream.name"], Concat([resource.attributes["k8s.namespace.name"], resource.attributes["service.name"]], "/")) where resource.attributes["aws.log.stream.name"] == nil and resource.attributes["k8s.namespace.name"] != nil and resource.attributes["service.name"] != nil and not IsMatch(resource.attributes["service.name"], "^unknown_service")
          - set(resource.attributes["aws.log.stream.name"], resource.attributes["k8s.namespace.name"]) where resource.attributes["aws.log.stream.name"] == nil and resource.attributes["k8s.namespace.name"] != nil
          - set(resource.attributes["aws.log.stream.name"], "default") where resource.attributes["aws.log.stream.name"] == nil

  attributestocontext/cw_k8s_otlp_logs:
    actions:
      - key: aws.log.group.name
        from_resource_attribute: aws.log.group.name
      - key: aws.log.stream.name
        from_resource_attribute: aws.log.stream.name

  transform/cw_k8s_otlp_logs_cleanup:
    error_mode: ignore
    log_statements:
      - context: resource
        statements:
          - delete_key(resource.attributes, "aws.log.group.name")
          - delete_key(resource.attributes, "aws.log.stream.name")
          - delete_key(resource.attributes, "aws.log.source")

  {{- include "otel-shared.processor.awsattributelimit" . | nindent 2 }}

  batch/cw_k8s_otlp_metrics:
    send_batch_size: 1000
    send_batch_max_size: 1000
    timeout: 10s

  batch/cw_k8s_otlp_traces:
    send_batch_size: 10000
    send_batch_max_size: 10000
    timeout: 30s

  # One batch per log group and stream, which the exporter sends as headers.
  batch/cw_k8s_otlp_logs:
    send_batch_size: 10000
    send_batch_max_size: 10000
    timeout: 30s
    metadata_keys:
      - aws.log.group.name
      - aws.log.stream.name
    metadata_cardinality_limit: 1000

exporters:
  {{- include "otel-shared.exporter.otlphttpMetrics" . | nindent 2 }}

  otlphttp/cw_k8s_otlp_traces:
    endpoint: {{ include "otlp.endpoint" (dict "context" . "service" "xray") }}
    tls:
      insecure: false
    auth:
      authenticator: sigv4auth/cw_k8s_otlp_traces_dest

  {{- if $profiles }}
  # Profiles, as the agent's profiles pipeline sends them: to the CloudWatch
  # development profiles API, with a bounded send queue to limit the memory a
  # backlog can hold.
  otlphttp/cw_k8s_otlp_profiles:
    profiles_endpoint: {{ printf "%s/v1development/profiles" (.Values.otelContainerInsights.cloudwatchMetricsEndpoint | default (printf "https://monitoring.%s.amazonaws.com" .Values.region) | trimSuffix "/" | trimSuffix ":443") | quote }}
    tls:
      insecure: false
    auth:
      authenticator: sigv4auth/cw_k8s_ci_v0_metrics_dest
    sending_queue:
      queue_size: 100
  {{- end }}

  otlphttp/cw_k8s_otlp_logs:
    endpoint: {{ include "otlp.endpoint" (dict "context" . "service" "logs" "override" .Values.otelContainerInsights.cloudwatchLogsEndpoint) }}
    tls:
      insecure: false
    auth:
      authenticator: headers_setter/cw_k8s_otlp_logs

service:
  # Internal self-telemetry off, as in the Container Insights config, so the
  # collector opens no Prometheus reader on :8888.
  telemetry:
    metrics:
      level: none
  extensions:
    - sigv4auth/cw_k8s_ci_v0_metrics_dest
    - sigv4auth/cw_k8s_otlp_logs_dest
    - awscloudwatchlogsprovisioner/cw_k8s_otlp_logs
    - sigv4auth/cw_k8s_otlp_traces_dest
    - headers_setter/cw_k8s_otlp_logs
  pipelines:
    metrics/cw_k8s_otlp:
      receivers:
        - otlp/cw_k8s_otlp
        {{- if $spanMetrics }}
        - spanmetrics/cw_k8s_otlp
        {{- end }}
      processors:
        - k8sattributes/cw_k8s_otlp_pod
        - k8sattributes/cw_k8s_ci_v0_node
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_otlp_enrich
        - transform/cw_k8s_service_identity
        {{- if $metricsLabels }}
        - transform/cw_k8s_ci_v0_metrics_labels
        {{- end }}
        {{- if $metricsNamespaces }}
        - filter/cw_k8s_otlp_metrics_namespaces
        {{- end }}
        - transform/cw_k8s_otlp_scope
        - awsattributelimit/cw_k8s_ci_v0
        {{- if $metricNames }}
        - filter/cw_k8s_ci_v0_metric_names
        {{- end }}
        - batch/cw_k8s_otlp_metrics
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest
    traces/cw_k8s_otlp:
      receivers:
        - otlp/cw_k8s_otlp
      processors:
        - k8sattributes/cw_k8s_otlp_pod
        - k8sattributes/cw_k8s_ci_v0_node
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_otlp_enrich
        - transform/cw_k8s_service_identity
        {{- if $labelStatements }}
        - transform/cw_k8s_otlp_labels
        {{- end }}
        {{- if $metricsNamespaces }}
        - filter/cw_k8s_otlp_traces_namespaces
        {{- end }}
        - transform/cw_k8s_otlp_scope
        - batch/cw_k8s_otlp_traces
      exporters:
        - otlphttp/cw_k8s_otlp_traces
        {{- if $spanMetrics }}
        - spanmetrics/cw_k8s_otlp
        {{- end }}
    logs/cw_k8s_otlp:
      receivers:
        - otlp/cw_k8s_otlp
      processors:
        - k8sattributes/cw_k8s_otlp_pod
        - k8sattributes/cw_k8s_ci_v0_node
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_otlp_enrich
        - transform/cw_k8s_service_identity
        {{- if $labelStatements }}
        - transform/cw_k8s_otlp_labels
        {{- end }}
        {{- if $metricsNamespaces }}
        - filter/cw_k8s_otlp_logs_namespaces
        {{- end }}
        - transform/cw_k8s_otlp_scope
        - transform/cw_k8s_otlp_logs_routing
        - attributestocontext/cw_k8s_otlp_logs
        - transform/cw_k8s_otlp_logs_cleanup
        - batch/cw_k8s_otlp_logs
      exporters:
        - otlphttp/cw_k8s_otlp_logs
    {{- if $profiles }}
    # Profiles need an agent with the service.profilesSupport feature gate on,
    # which the agent turns on at startup from v1.300075.0, so the pipeline is
    # opt-in (otlp.profiles.enabled) until the chart's default image has it.
    profiles/cw_k8s_otlp:
      receivers:
        - otlp/cw_k8s_otlp
      processors:
        - k8sattributes/cw_k8s_otlp_profiles
        - k8sattributes/cw_k8s_ci_v0_node
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_otlp_enrich
        - transform/cw_k8s_service_identity
        {{- if $labelStatements }}
        - transform/cw_k8s_otlp_labels
        {{- end }}
        {{- if $metricsNamespaces }}
        - filter/cw_k8s_otlp_profiles_namespaces
        {{- end }}
        - transform/cw_k8s_otlp_scope
      exporters:
        - otlphttp/cw_k8s_otlp_profiles
    {{- end }}
{{- end -}}
