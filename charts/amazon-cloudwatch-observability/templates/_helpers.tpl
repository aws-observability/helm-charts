{{/*
Expand the name of the chart.
*/}}
{{- define "amazon-cloudwatch-observability.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Name of k8s cluster
*/}}
{{- define "kubernetes-cluster.name" -}}
{{- if empty .Values.clusterName }}
{{- default "" (printf "k8s-cluster-%s" (sha256sum .Release.Name | trunc 7)) }}
{{- else }}
{{- default "" .Values.clusterName }}
{{- end }}
{{- end }}

{{/*
Helper function to modify cloudwatch-agent config
*/}}
{{- define "cloudwatch-agent.config-modifier" -}}
{{- $configCopy := deepCopy .Values.agent.config }}

{{- $agent := pluck "agent" $configCopy | first }}
{{- if and (empty $agent) (empty $agent.region) }}
{{- $agent := set $agent "region" .Values.region }}
{{- end }}

{{- $appSignals := pluck "app_signals" $configCopy.logs.metrics_collected | first }}
{{- if empty $appSignals.hosted_in }}
{{- $appSignals := set $appSignals "hosted_in" (include "kubernetes-cluster.name" .) }}
{{- end }}

{{- $containerInsights := pluck "kubernetes" $configCopy.logs.metrics_collected | first }}
{{- if empty $containerInsights.cluster_name }}
{{- $containerInsights := set $containerInsights "cluster_name" (include "kubernetes-cluster.name" .) }}
{{- end }}

{{- default ""  $configCopy | toJson | quote }}
{{- end }}

{{/*
Helper function to modify customer supplied agent config if ContainerInsights or ApplicationSignals is enabled
*/}}
{{- define "cloudwatch-agent.supplied-config" -}}
{{- if or (hasKey .Values.agent.config.logs "app_signals") (and (hasKey .Values.agent.config.logs "metrics_collected") (hasKey .Values.agent.config.logs.metrics_collected "kubernetes")) }}
{{- include "cloudwatch-agent.config-modifier" . }}
{{- else }}
{{- default "" .Values.agent.config | toJson | quote }}
{{- end }}
{{- end }}

{{/*
Helper function to modify default agent config
*/}}
{{- define "cloudwatch-agent.modify-default-config" -}}
{{- $configCopy := deepCopy .Values.agent.defaultConfig }}
{{- $agentRegion := dict "region" .Values.region }}
{{- $agent := set $configCopy "agent" $agentRegion }}
{{- $appSignals := pluck "app_signals" $configCopy.logs.metrics_collected | first }}
{{- $appSignals := set $appSignals "hosted_in" (include "kubernetes-cluster.name" .) }}
{{- $containerInsights := pluck "kubernetes" $configCopy.logs.metrics_collected | first }}
{{- $containerInsights := set $containerInsights "cluster_name" (include "kubernetes-cluster.name" .) }}
{{- default ""  $configCopy | toJson | quote }}
{{- end }}

{{/*
Name for cloudwatch-agent
*/}}
{{- define "cloudwatch-agent.name" -}}
{{- default "cloudwatch-agent" .Values.agent.name }}
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
{{- $imageDomain := "" -}}
{{- $imageDomain = index .Values.containerLogs.fluentBit.image.repositoryDomainMap .Values.region -}}
{{- if not $imageDomain -}}
{{- $imageDomain = .Values.containerLogs.fluentBit.image.repositoryDomainMap.public -}}
{{- end -}}
{{- printf "%s/%s:%s" $imageDomain .Values.containerLogs.fluentBit.image.repository .Values.containerLogs.fluentBit.image.tag -}}
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