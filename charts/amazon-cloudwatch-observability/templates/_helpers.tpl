{{/*
Expand the name of the chart.
*/}}
{{- define "amazon-cloudwatch-observability.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "amazon-cloudwatch-observability.common.tolerations" -}}
{{- $tolerations := .context.Values.tolerations }}
{{- if .component }}
  {{- $componentTolerations := dig "tolerations" nil .component }}
  {{- if ne nil $componentTolerations }}
      {{- $tolerations = $componentTolerations }}
  {{- end }}
{{- end }}
{{- with $tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Helper function to determine monitorAllServices based on region
*/}}
{{- define "manager.monitorAllServices" -}}
{{- $region := .Values.region | required ".Values.region is required." -}}
{{- if regexMatch "ap-east-2|ap-southeast-6|cn-.*|.*-iso[a-z]*-.*" $region -}}
false
{{- else -}}
true
{{- end -}}
{{- end -}}

{{/*
Helper function to modify auto-monitor config based on agent configurations
*/}}
{{- define "manager.modify-auto-monitor-config" -}}
{{- $autoMonitorConfig := deepCopy .Values.manager.applicationSignals.autoMonitor -}}
{{- $hasAppSignals := false -}}
{{- range .Values.agents -}}
{{- $agent := merge . (deepCopy $.Values.agent) -}}
{{- $agentConfig := $agent.config | default $agent.defaultConfig -}}
{{- if and (hasKey $agentConfig "logs") (hasKey $agentConfig.logs "metrics_collected") (hasKey $agentConfig.logs.metrics_collected "application_signals") -}}
{{- $hasAppSignals = true -}}
{{- end -}}
{{- if and (hasKey $agentConfig "traces") (hasKey $agentConfig.traces "traces_collected") (hasKey $agentConfig.traces.traces_collected "application_signals") -}}
{{- $hasAppSignals = true -}}
{{- end -}}
{{- end -}}
{{- if not $hasAppSignals -}}
{{- $_ := set $autoMonitorConfig "monitorAllServices" false -}}
{{- else if not (hasKey $autoMonitorConfig "monitorAllServices") -}}
{{- $_ := set $autoMonitorConfig "monitorAllServices" (include "manager.monitorAllServices" . | trim | eq "true") -}}
{{- end -}}
{{- $autoMonitorConfig | toJson -}}
{{- end -}}

{{/*
Helper function to modify cloudwatch-agent config
*/}}
{{- define "cloudwatch-agent.config-modifier" -}}
{{- $configCopy := deepCopy .Config }}

{{- $agent := pluck "agent" $configCopy | first }}
{{- if and (empty $agent) (empty $agent.region) }}
{{- $agentRegion := dict "region" .Values.region }}
{{- $agent := set $configCopy "agent" $agentRegion }}
{{- end }}

{{- $appSignals := pluck "application_signals" $configCopy.logs.metrics_collected | first }}
{{- if and (hasKey $configCopy.logs.metrics_collected "application_signals") (empty $appSignals.hosted_in) }}
{{- $clusterName := .Values.clusterName | toString | required ".Values.clusterName is required." -}}
{{- $appSignals := set $appSignals "hosted_in" $clusterName }}
{{- end }}

{{- $containerInsights := pluck "kubernetes" $configCopy.logs.metrics_collected | first }}
{{- if and (hasKey $configCopy.logs.metrics_collected "kubernetes") (empty $containerInsights.cluster_name) }}
{{- $clusterName := .Values.clusterName | toString | required ".Values.clusterName is required." -}}
{{- $containerInsights := set $containerInsights "cluster_name" $clusterName }}
{{- end }}

{{- default ""  $configCopy | toJson | quote }}
{{- end }}

{{/*
Helper function to modify customer supplied agent config if ContainerInsights or ApplicationSignals is enabled
*/}}
{{- define "cloudwatch-agent.modify-config" -}}
{{- if and (hasKey .Config "logs") (or (and (hasKey .Config.logs "metrics_collected") (hasKey .Config.logs.metrics_collected "application_signals")) (and (hasKey .Config.logs "metrics_collected") (hasKey .Config.logs.metrics_collected "kubernetes"))) }}
{{- include "cloudwatch-agent.config-modifier" . }}
{{- else }}
{{- default "" .Config | toJson | quote }}
{{- end }}
{{- end }}

{{/*
Helper function to modify cloudwatch-agent YAML config
*/}}
{{- define "cloudwatch-agent.modify-otel-config" -}}
{{- $configCopy := deepCopy .OtelConfig }}
{{- if kindIs "string" $configCopy }}
  {{- $configCopy = fromYaml $configCopy }}
{{- end }}

{{- range $name, $component := $configCopy }}
{{- if and $component (kindIs "map" $component) }}
  {{- range $key, $value := $component }}
    {{- if eq $value nil }}
      {{- $_ := set $component $key dict }}
    {{- end -}}
  {{- end }}
{{- end }}
{{- end }}

{{- $configCopy | toYaml | quote }}
{{- end }}

{{- define "cloudwatch-agent.rolloutStrategyMaxUnavailable" -}}
{{- if eq .mode "daemonset" -}}
1
{{- else -}}
25%
{{- end -}}
{{- end -}}

{{- define "cloudwatch-agent.updateStrategy" -}}
{{- if eq .mode "deployment" -}}
deploymentUpdateStrategy
{{- else -}}
updateStrategy
{{- end -}}
{{- end -}}

{{- define "cloudwatch-agent.rolloutStrategyMaxSurge" -}}
{{- if eq .mode "daemonset" -}}
0
{{- else -}}
25%
{{- end -}}
{{- end -}}

{{/*
Name for cloudwatch-agent
*/}}
{{- define "cloudwatch-agent.name" -}}
{{- default "cloudwatch-agent" .Values.agent.name }}
{{- end }}

{{/*
Name for dcgm-exporter
*/}}
{{- define "dcgm-exporter.name" -}}
{{- default "dcgm-exporter" .Values.dcgmExporter.name }}
{{- end }}

{{/*
Name for neuron-monitor
*/}}
{{- define "neuron-monitor.name" -}}
{{- default "neuron-monitor" .Values.neuronMonitor.name }}
{{- end }}

{{/*
Get the current recommended cloudwatch agent image for a region
*/}}
{{- define "cloudwatch-agent.image" -}}
{{- $imageDomain := "" -}}
{{- $imageDomain = index .repositoryDomainMap .region -}}
{{- if not $imageDomain -}}
{{- $imageDomain = .repositoryDomainMap.public -}}
{{- end -}}
{{- printf "%s/%s:%s" $imageDomain .repository .tag -}}
{{- end -}}

{{/*
Get the current recommended cloudwatch agent operator image for a region
*/}}
{{- define "cloudwatch-agent-operator.image" -}}
{{- $region := .Values.region | required ".Values.region is required." -}}
{{- $imageDomain := "" -}}
{{- $imageDomain = index .Values.manager.image.repositoryDomainMap .Values.region -}}
{{- if not $imageDomain -}}
{{- $imageDomain = .Values.manager.image.repositoryDomainMap.public -}}
{{- end -}}
{{- printf "%s/%s:%s" $imageDomain .Values.manager.image.repository .Values.manager.image.tag -}}
{{- end -}}

{{/*
Get the current recommended target allocator image for a region
*/}}
{{- define "target-allocator.image" -}}
{{- $imageDomain := "" -}}
{{- $imageDomain = index .repositoryDomainMap .region -}}
{{- if not $imageDomain -}}
{{- $imageDomain = .repositoryDomainMap.public -}}
{{- end -}}
{{- printf "%s/%s:%s" $imageDomain .repository .tag -}}
{{- end -}}

{{/*
Get the current recommended fluent-bit image for a region
*/}}
{{- define "fluent-bit.image" -}}
{{- $region := .Values.region | required ".Values.region is required." -}}
{{- $imageDomain := "" -}}
{{- $imageDomain = index .Values.containerLogs.fluentBit.image.repositoryDomainMap .Values.region -}}
{{- if not $imageDomain -}}
{{- $imageDomain = .Values.containerLogs.fluentBit.image.repositoryDomainMap.public -}}
{{- end -}}
{{- printf "%s/%s:%s" $imageDomain .Values.containerLogs.fluentBit.image.repository .Values.containerLogs.fluentBit.image.tag -}}
{{- end -}}

{{/*
Get the current recommended fluent-bit Windows image for a region
*/}}
{{- define "fluent-bit-windows.image" -}}
{{- $region := .Values.region | required ".Values.region is required." -}}
{{- $imageDomain := "" -}}
{{- $imageDomain = index .Values.containerLogs.fluentBit.image.repositoryDomainMap .Values.region -}}
{{- if not $imageDomain -}}
{{- $imageDomain = .Values.containerLogs.fluentBit.image.repositoryDomainMap.public -}}
{{- end -}}
{{- printf "%s/%s:%s" $imageDomain .Values.containerLogs.fluentBit.image.repository .Values.containerLogs.fluentBit.image.tagWindows -}}
{{- end -}}

{{/*
Get the current recommended dcgm-exporter image for a region
*/}}
{{- define "dcgm-exporter.image" -}}
{{- $region := .Values.region | required ".Values.region is required." -}}
{{- $imageDomain := "" -}}
{{- $imageDomain = index .Values.dcgmExporter.image.repositoryDomainMap .Values.region -}}
{{- if not $imageDomain -}}
{{- $imageDomain = .Values.dcgmExporter.image.repositoryDomainMap.public -}}
{{- end -}}
{{- printf "%s/%s:%s" $imageDomain .Values.dcgmExporter.image.repository .Values.dcgmExporter.image.tag -}}
{{- end -}}

{{/*
Get the current recommended neuron-monitor image for a region
*/}}
{{- define "neuron-monitor.image" -}}
{{- $imageDomain := "" -}}
{{- $imageDomain = index .Values.neuronMonitor.image.repositoryDomainMap .Values.region -}}
{{- if not $imageDomain -}}
{{- $imageDomain = .Values.neuronMonitor.image.repositoryDomainMap.public -}}
{{- end -}}
{{- printf "%s/%s:%s" $imageDomain .Values.neuronMonitor.image.repository .Values.neuronMonitor.image.tag -}}
{{- end -}}

{{/*
Get the current recommended auto instrumentation java image
*/}}
{{- define "auto-instrumentation-java.image" -}}
{{- printf "%s/%s:%s" .Values.manager.autoInstrumentationImage.java.repositoryDomain .Values.manager.autoInstrumentationImage.java.repository .Values.manager.autoInstrumentationImage.java.tag -}}
{{- end -}}

{{/*
Get the current recommended auto instrumentation python image
*/}}
{{- define "auto-instrumentation-python.image" -}}
{{- printf "%s/%s:%s" .Values.manager.autoInstrumentationImage.python.repositoryDomain .Values.manager.autoInstrumentationImage.python.repository .Values.manager.autoInstrumentationImage.python.tag -}}
{{- end -}}

{{/*
Get the current recommended auto instrumentation dotnet image
*/}}
{{- define "auto-instrumentation-dotnet.image" -}}
{{- printf "%s/%s:%s" .Values.manager.autoInstrumentationImage.dotnet.repositoryDomain .Values.manager.autoInstrumentationImage.dotnet.repository .Values.manager.autoInstrumentationImage.dotnet.tag -}}
{{- end -}}

{{/*
Get the current recommended auto instrumentation nodejs image
*/}}
{{- define "auto-instrumentation-nodejs.image" -}}
{{- printf "%s/%s:%s" .Values.manager.autoInstrumentationImage.nodejs.repositoryDomain .Values.manager.autoInstrumentationImage.nodejs.repository .Values.manager.autoInstrumentationImage.nodejs.tag -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "amazon-cloudwatch-observability.labels" -}}
{{ include "amazon-cloudwatch-observability.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: "amazon-cloudwatch-agent-operator"
{{- end }}

{{/*
Selector labels
*/}}
{{- define "amazon-cloudwatch-observability.selectorLabels" -}}
app.kubernetes.io/name: {{ include "amazon-cloudwatch-observability.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "amazon-cloudwatch-observability.managerServiceAccountName" -}}
{{- if .Values.manager.serviceAccount.create }}
{{- default (printf "%s-controller-manager" (include "amazon-cloudwatch-observability.name" .)) .Values.manager.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.manager.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "cloudwatch-agent.serviceAccountName" -}}
{{- if .Values.agent.enabled }}
{{- default (include "cloudwatch-agent.name" .) .Values.agent.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.agent.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use for dcgm exporter
*/}}
{{- define "dcgm-exporter.serviceAccountName" -}}
{{- default "dcgm-exporter-service-acct" .Values.dcgmExporter.serviceAccount.name }}
{{- end }}

{{/*
Create the name of the service account to use for neuron monitor
*/}}
{{- define "neuron-monitor.serviceAccountName" -}}
{{- default "neuron-monitor-service-acct" .Values.neuronMonitor.serviceAccount.name }}
{{- end }}

{{- define "amazon-cloudwatch-observability.podAnnotations" -}}
{{- if .Values.manager.podAnnotations }}
{{- .Values.manager.podAnnotations | toYaml }}
{{- end }}
{{- end }}

{{- define "amazon-cloudwatch-observability.podLabels" -}}
{{- if .Values.manager.podLabels }}
{{- .Values.manager.podLabels | toYaml }}
{{- end }}
{{- end }}

{{/*
Define the default certificate secret name
*/}}
{{- define "amazon-cloudwatch-observability.certificateSecretName" -}}
{{- default (printf "%s-controller-manager-service-cert" (include "amazon-cloudwatch-observability.name" .)) .Values.admissionWebhooks.secretName }}
{{- end -}}

{{/*
Define the default service name
*/}}
{{- define "amazon-cloudwatch-observability.webhookServiceName" -}}
{{- default (printf "%s-webhook-service" (include "amazon-cloudwatch-observability.name" .)) .Values.manager.service.name }}
{{- end -}}

{{/*
Check if a specific admission webhook is enabled
*/}}
{{- define "amazon-cloudwatch-observability.isWebhookEnabled" -}}
{{- $ctx := index . 0 -}}
{{- $webhook := index . 1 -}}
{{- $webhookConfig := index $ctx.Values.admissionWebhooks $webhook -}}
{{- if hasKey $webhookConfig "create" -}}
{{- if $webhookConfig.create }}true{{- end -}}
{{- else -}}
{{- if $ctx.Values.admissionWebhooks.create }}true{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Check if any admission webhook is enabled
*/}}
{{- define "amazon-cloudwatch-observability.webhookEnabled" -}}
{{- $webhooks := list "agents" "instrumentations" "pods" "workloads" "namespaces" -}}
{{- range $webhook := $webhooks -}}
{{- if include "amazon-cloudwatch-observability.isWebhookEnabled" (list $ $webhook) -}}
true
{{- break -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Get namespaceSelector value for admission webhooks
*/}}
{{- define "amazon-cloudwatch-observability.namespaceSelector" -}}
{{- $ctx := index . 0 -}}
{{- $webhook := index . 1 -}}
{{- $webhookConfig := index $ctx.Values.admissionWebhooks $webhook -}}
{{- if and (hasKey $webhookConfig "namespaceSelector") (ne $webhookConfig.namespaceSelector nil) -}}
{{- $selector := $webhookConfig.namespaceSelector -}}
{{- if $selector -}}
{{- toYaml $selector | nindent 4 -}}
{{- else -}}
{}
{{- end -}}
{{- else -}}
{{- $selector := $ctx.Values.admissionWebhooks.namespaceSelector -}}
{{- if $selector -}}
{{- toYaml $selector | nindent 4 -}}
{{- else -}}
{}
{{- end -}}
{{- end -}}
{{- end -}}


