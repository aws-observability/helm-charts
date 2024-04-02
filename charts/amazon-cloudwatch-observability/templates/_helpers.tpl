{{/*
Expand the name of the chart.
*/}}
{{- define "amazon-cloudwatch-observability.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Function to generate a random name and store it in .Release
*/}}
{{- define "generate_static_name_randomiser" -}}
{{- if not (index .Release "randomiser") -}}
{{- $_ := set .Release "randomiser" dict -}}
{{- end -}}
{{- $key := printf "%s_%s" .Release.Name "randomiser" -}}
{{- if not (index .Release.randomiser $key) -}}
{{- $_ := set .Release.randomiser $key (randAlphaNum 3) -}}
{{- end -}}
{{- index .Release.randomiser $key -}}
{{- end -}}

{{/*
Name of k8s cluster
*/}}
{{- define "kubernetes-cluster.name" -}}
{{- default (printf "k8s-cluster-%s-%s" (sha256sum .Release.Name | trunc 7) (include "generate_static_name_randomiser" .)) .Values.clusterName }}
{{- end }}

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

{{- $appSignals := pluck "app_signals" $configCopy.logs.metrics_collected | first }}
{{- if and (hasKey $configCopy.logs.metrics_collected "app_signals") (empty $appSignals.hosted_in) }}
{{- $appSignals := set $appSignals "hosted_in" (include "kubernetes-cluster.name" .) }}
{{- end }}

{{- $containerInsights := pluck "kubernetes" $configCopy.logs.metrics_collected | first }}
{{- if and (hasKey $configCopy.logs.metrics_collected "kubernetes") (empty $containerInsights.cluster_name) }}
{{- $containerInsights := set $containerInsights "cluster_name" (include "kubernetes-cluster.name" .) }}
{{- end }}

{{- default ""  $configCopy | toJson | quote }}
{{- end }}

{{/*
Helper function to modify customer supplied agent config if ContainerInsights or ApplicationSignals is enabled
*/}}
{{- define "cloudwatch-agent.modify-config" -}}
{{- if and (hasKey .Config "logs") (or (and (hasKey .Config.logs "metrics_collected") (hasKey .Config.logs.metrics_collected "app_signals")) (and (hasKey .Config.logs "metrics_collected") (hasKey .Config.logs.metrics_collected "kubernetes"))) }}
{{- include "cloudwatch-agent.config-modifier" . }}
{{- else }}
{{- default "" .Config | toJson | quote }}
{{- end }}
{{- end }}

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
Get the current recommended cloudwatch agent image for a region
*/}}
{{- define "cloudwatch-agent.image" -}}
{{- $imageDomain := "" -}}
{{- $imageDomain = index .Values.agent.image.repositoryDomainMap .Values.region -}}
{{- if not $imageDomain -}}
{{- $imageDomain = .Values.agent.image.repositoryDomainMap.public -}}
{{- end -}}
{{- printf "%s/%s:%s" $imageDomain .Values.agent.image.repository .Values.agent.image.tag -}}
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