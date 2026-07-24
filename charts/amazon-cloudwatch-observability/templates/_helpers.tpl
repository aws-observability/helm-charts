{{/*
Expand the name of the chart.
*/}}
{{- define "amazon-cloudwatch-observability.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Whether to bundle the community ServiceMonitor/PodMonitor CRDs. Honours
.Values.otelContainerInsights.prometheusScrape.crds.install:
  "always" => true; "never" => empty;
  "auto" (default) => true only when otelContainerInsights.enabled AND
  otelContainerInsights.prometheusScrape.enabled are both true.
Returns the string "true" when CRDs should be rendered, empty otherwise.
*/}}
{{- define "amazon-cloudwatch-observability.prometheusCRDsEnabled" -}}
{{- $install := (dig "prometheusScrape" "crds" "install" "auto" .Values.otelContainerInsights) -}}
{{- /* Back-compat: honor the legacy top-level prometheusCRDs.install if set (deprecated). */ -}}
{{- if hasKey .Values "prometheusCRDs" -}}
{{- $install = (dig "install" $install .Values.prometheusCRDs) -}}
{{- end -}}
{{- $scrapeEnabled := (dig "prometheusScrape" "enabled" true .Values.otelContainerInsights) -}}
{{- if eq $install "always" -}}
true
{{- else if eq $install "never" -}}
{{- else if eq $install "auto" -}}
{{- if and .Values.otelContainerInsights.enabled $scrapeEnabled -}}
true
{{- end -}}
{{- else -}}
{{- fail (printf "prometheusCRDs.install must be one of \"auto\", \"always\", or \"never\", got: %s" $install) -}}
{{- end -}}
{{- end -}}

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
Helper function to determine whether Service Events is supported in the region.
Returns false for regions where Service Events should be disabled.
Note: Service Events only runs when Application Signals is enabled, so unsupported/iso regions
(where AppSignals is off) are already covered. The regions listed below are still matched
explicitly as a safeguard, so that Service Events stays disabled there even if Application
Signals becomes available while Service Events does not.
*/}}
{{- define "manager.serviceEventsSupported" -}}
{{- $region := .Values.region | required ".Values.region is required." -}}
{{- if regexMatch "me-central-1|me-south-1|il-central-1|cn-.*|.*-iso[a-z]*-.*|us-gov-.*|eusc-.*" $region -}}
false
{{- else -}}
true
{{- end -}}
{{- end -}}

{{/*
Builds the per-language --auto-instrumentation-config payload, merging autoInstrumentationResources
with autoInstrumentationConfiguration for each language. In regions where Service Events is
unsupported (see manager.serviceEventsSupported), service_events.enabled defaults to "false" unless
the user has explicitly set it.
*/}}
{{- define "manager.modify-auto-instrumentation-config" -}}
{{- $serviceEventsSupported := include "manager.serviceEventsSupported" . | trim | eq "true" -}}
{{- $config := dict -}}
{{- range $lang := list "java" "python" "dotnet" "nodejs" -}}
{{- $langConfig := merge (deepCopy (index $.Values.manager.autoInstrumentationResources $lang)) (deepCopy (index $.Values.manager.autoInstrumentationConfiguration $lang | default dict)) -}}
{{/* service_events is supported for java, python, nodejs only (no dotnet SDK) */}}
{{- if and (not $serviceEventsSupported) (ne $lang "dotnet") -}}
{{- $serviceEvents := deepCopy (index $langConfig "service_events" | default dict) -}}
{{- if not (hasKey $serviceEvents "enabled") -}}
{{- $_ := set $serviceEvents "enabled" "false" -}}
{{- end -}}
{{- $_ := set $langConfig "service_events" $serviceEvents -}}
{{- end -}}
{{- $_ := set $config $lang $langConfig -}}
{{- end -}}
{{- $config | toJson -}}
{{- end -}}

{{/*
Helper function to modify auto-monitor config based on agent configurations
*/}}
{{- define "manager.modify-auto-monitor-config" -}}
{{- $autoMonitorConfig := deepCopy .Values.manager.applicationSignals.autoMonitor -}}
{{- $hasAppSignals := false -}}
{{- range .Values.agents -}}
  {{- $agent := mergeOverwrite (deepCopy $.Values.agent) . -}}
  {{- if and $.Values.applicationSignals.enabled (eq $.Values.applicationSignals.targetAgent $agent.name) -}}
    {{- if and $agent.config (ne ($agent.config | toString) "default") -}}
      {{- $agentConfig := $agent.config -}}
      {{- if or (and (hasKey $agentConfig "logs") (hasKey $agentConfig.logs "metrics_collected") (hasKey $agentConfig.logs.metrics_collected "application_signals")) (and (hasKey $agentConfig "traces") (hasKey $agentConfig.traces "traces_collected") (hasKey $agentConfig.traces.traces_collected "application_signals")) -}}
        {{- $hasAppSignals = true -}}
      {{- end -}}
    {{- else -}}
      {{- $hasAppSignals = true -}}
    {{- end -}}
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
Build the default CW Agent JSON config for a given agent based on which feature flags target it.
Accepts a dict with "agentName" (string) and "context" (root context $).
Returns a dict (not JSON) — caller is responsible for serialization.

Logic:
  - Always includes agent.region
  - Includes logs.metrics_collected.application_signals + traces.traces_collected.application_signals
    when applicationSignals.enabled AND applicationSignals.targetAgent matches agentName
  - Includes logs.metrics_collected.kubernetes when containerInsights.enabled AND
    containerInsights.targetAgent matches agentName
  - Returns minimal {"agent":{"region":"<region>"}} when no feature targets the agent
*/}}
{{- define "cloudwatch-agent.build-default-config" -}}
{{- $agentName := .agentName -}}
{{- $ctx := .context -}}
{{- $region := $ctx.Values.region | required ".Values.region is required." -}}
{{- $config := dict "agent" (dict "region" $region) -}}
{{- $needsLogs := false -}}
{{- $metricsCollected := dict -}}
{{/* Application Signals: add logs.metrics_collected.application_signals + traces.traces_collected.application_signals */}}
{{- if and $ctx.Values.applicationSignals.enabled (eq $ctx.Values.applicationSignals.targetAgent $agentName) -}}
  {{- $needsLogs = true -}}
  {{- $_ := set $metricsCollected "application_signals" dict -}}
  {{- $_ := set $config "traces" (dict "traces_collected" (dict "application_signals" dict)) -}}
{{- end -}}
{{/* Container Insights: add logs.metrics_collected.kubernetes */}}
{{- if and $ctx.Values.containerInsights.enabled (eq $ctx.Values.containerInsights.targetAgent $agentName) -}}
  {{- $needsLogs = true -}}
  {{- $_ := set $metricsCollected "kubernetes" (dict "enhanced_container_insights" true) -}}
{{- end -}}
{{- if $needsLogs -}}
  {{- $_ := set $config "logs" (dict "metrics_collected" $metricsCollected) -}}
{{- end -}}
{{- $config | toJson -}}
{{- end -}}

{{/*
Build the default OTEL YAML config for a given agent based on which feature flags target it.
Accepts a dict with "agentName" (string) and "context" (root context $).
Returns OTEL YAML string.

Logic:
  - When otelContainerInsights.enabled is false, return empty config ({})
  - When otelContainerInsights.targetAgent matches agentName, return node-level OTEL CI config
  - When otelContainerInsights.clusterScraperAgent matches agentName, return cluster-level OTEL CI config
  - Default: return empty config ({})
*/}}
{{- define "cloudwatch-agent.validate-flags" -}}
{{- /*
  Flag validation and type checking for the CI flag state matrix.
  Four flags control CI behavior:
    - containerInsights.enabled (ECI)       — legacy Container Insights metrics
    - containerLogs.enabled (FB)            — FluentBit log pipeline
    - otelContainerInsights.enabled         — OTEL Container Insights (metrics)
    - otelContainerInsights.logs.enabled    — OTEL log pipelines

  All flag combinations are valid. Notable behaviors:
    - otelCI.logs.enabled=true without otelCI.enabled=true is a no-op
      (logs config is only rendered when the parent OTEL CI pipeline is active)
    - otelCI.enabled=true + containerLogs.enabled=true = dual-publish
      (both OTEL and FluentBit log pipelines run simultaneously)
*/ -}}
{{- if not (kindIs "bool" .Values.containerInsights.enabled) }}
{{- fail "containerInsights.enabled must be a boolean (true/false)" }}
{{- end }}
{{- if not (kindIs "bool" .Values.containerLogs.enabled) }}
{{- fail "containerLogs.enabled must be a boolean (true/false)" }}
{{- end }}
{{- if not (kindIs "bool" .Values.otelContainerInsights.enabled) }}
{{- fail "otelContainerInsights.enabled must be a boolean (true/false)" }}
{{- end }}
{{- if not (kindIs "bool" .Values.otelContainerInsights.logs.enabled) }}
{{- fail "otelContainerInsights.logs.enabled must be a boolean (true/false)" }}
{{- end }}
{{- end -}}

{{- define "cloudwatch-agent.build-default-otel-config" -}}
{{- $agentName := .agentName -}}
{{- $ctx := .context -}}
{{- include "cloudwatch-agent.validate-flags" $ctx -}}
{{- if not $ctx.Values.otelContainerInsights.enabled -}}
{}
{{- else if eq $ctx.Values.otelContainerInsights.targetAgent $agentName -}}
{{- include "otel-container-insights.config" $ctx -}}
{{- else if eq $ctx.Values.otelContainerInsights.clusterScraperAgent $agentName -}}
{{- include "otel-container-insights-cluster-scraper.config" $ctx -}}
{{- else -}}
{}
{{- end -}}
{{- end -}}

{{/*
Returns "true" when otelContainerInsights-driven ServiceMonitor/PodMonitor scraping
applies to the given agent. True when otelContainerInsights is enabled, the agent is
the configured targetAgent, and at least one of serviceMonitor/podMonitor is enabled.
Accepts a dict with "agentName" (string) and "context" (root context $).
*/}}
{{- define "cloudwatch-agent.otelCIScrapeEnabled" -}}
{{- $ctx := .context -}}
{{- $agentName := .agentName -}}
{{- if and $ctx.Values.otelContainerInsights.enabled (eq $agentName $ctx.Values.otelContainerInsights.targetAgent) (dig "prometheusScrape" "enabled" true $ctx.Values.otelContainerInsights) -}}
true
{{- end -}}
{{- end -}}

{{/*
Whether ServiceMonitor / PodMonitor discovery is enabled. Honors the legacy
otelContainerInsights.serviceMonitor.enabled / .podMonitor.enabled if set
(deprecated), otherwise otelContainerInsights.prometheusScrape.<monitor>.enabled
(default true). Return "true" when enabled, empty otherwise.
*/}}
{{- define "cloudwatch-agent.serviceMonitorEnabled" -}}
{{- $v := dig "prometheusScrape" "serviceMonitor" "enabled" true .Values.otelContainerInsights -}}
{{- if hasKey .Values.otelContainerInsights "serviceMonitor" -}}
{{- $v = dig "serviceMonitor" "enabled" $v .Values.otelContainerInsights -}}
{{- end -}}
{{- if $v -}}true{{- end -}}
{{- end -}}

{{- define "cloudwatch-agent.podMonitorEnabled" -}}
{{- $v := dig "prometheusScrape" "podMonitor" "enabled" true .Values.otelContainerInsights -}}
{{- if hasKey .Values.otelContainerInsights "podMonitor" -}}
{{- $v = dig "podMonitor" "enabled" $v .Values.otelContainerInsights -}}
{{- end -}}
{{- if $v -}}true{{- end -}}
{{- end -}}

{{/*
Reject a contradictory scraping config. prometheusScrape.enabled=true with BOTH
ServiceMonitor and PodMonitor discovery disabled would render an idle Target Allocator
(and bundle CRDs) that discovers nothing. Fail loudly rather than ship a no-op path.
Invoked from an always-rendered template so it runs regardless of which agents render.
*/}}
{{- define "cloudwatch-agent.validatePrometheusScrape" -}}
{{- if and .Values.otelContainerInsights.enabled (dig "prometheusScrape" "enabled" true .Values.otelContainerInsights) -}}
{{- if and (ne (include "cloudwatch-agent.serviceMonitorEnabled" .) "true") (ne (include "cloudwatch-agent.podMonitorEnabled" .) "true") -}}
{{- fail "otelContainerInsights.prometheusScrape.enabled=true requires at least one of prometheusScrape.serviceMonitor.enabled or prometheusScrape.podMonitor.enabled to be true; enable one, or set prometheusScrape.enabled=false" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Helper function to modify cloudwatch-agent config
*/}}
{{- define "cloudwatch-agent.config-modifier" -}}
{{- $configCopy := deepCopy .Config }}

{{- $agent := pluck "agent" $configCopy | first }}
{{- if or (empty $agent) (empty $agent.region) }}
{{- $agentRegion := dict "region" .Values.region }}
{{- $agent := set $configCopy "agent" $agentRegion }}
{{- end }}

{{- if .Values.useDualstackEndpoint }}
{{- if not (hasKey $configCopy "agent") }}
{{- $_ := set $configCopy "agent" dict }}
{{- end }}
{{- $_ := set $configCopy.agent "use_dualstack_endpoint" true }}
{{- end }}

{{- if and (hasKey $configCopy "logs") (hasKey $configCopy.logs "metrics_collected") }}
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
  {{- if hasKey $configCopy "Error" }}
    {{- fail (printf "Failed to parse otelConfig: %s" (index $configCopy "Error")) }}
  {{- end }}
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

{{/*
Compute scrape_timeout: use metricResolution if it's less than 10s, otherwise 10s.
Validates metricResolution is in "<N>s" format.
*/}}
{{- define "otel-container-insights.scrapeTimeout" -}}
{{- $raw := .Values.otelContainerInsights.metricResolution -}}
{{- if not (hasSuffix "s" $raw) -}}
  {{- fail (printf "otelContainerInsights.metricResolution must be in \"<N>s\" format (e.g. \"30s\"), got: %s" $raw) -}}
{{- end -}}
{{- $seconds := trimSuffix "s" $raw -}}
{{- if not (regexMatch "^[0-9]+$" $seconds) -}}
  {{- fail (printf "otelContainerInsights.metricResolution must be in \"<N>s\" format (e.g. \"30s\"), got: %s" $raw) -}}
{{- end -}}
{{- if lt ($seconds | int) 10 -}}
{{- $raw }}
{{- else -}}
10s
{{- end -}}
{{- end -}}

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
Helper function to add dualstack endpoints to fluent-bit OUTPUT sections
Uses regex to handle variable whitespace in the region line
*/}}
{{- define "fluent-bit.add-dualstack-endpoints" -}}
{{- $config := .config -}}
{{- if and .Values.useDualstackEndpoint (not (contains "endpoint" $config)) -}}
{{- $config = mustRegexReplaceAll "(region\\s+\\$\\{AWS_REGION\\})" $config "$1\n  endpoint            logs.$${AWS_REGION}.api.aws\n  sts_endpoint        sts.$${AWS_REGION}.api.aws" -}}
{{- end -}}
{{- $config -}}
{{- end -}}

{{/*
Helper function to add IPv6 preference to fluent-bit SERVICE section
Inserts net.dns.prefer_ipv6 right after [SERVICE] or [ SERVICE ] header
*/}}
{{- define "fluent-bit.add-ipv6-preference" -}}
{{- $config := .config -}}
{{- $indent := .indent | default "  " -}}
{{- if and .useDualstackEndpoint (not (contains "net.dns.prefer_ipv6" $config)) -}}
{{- $config = mustRegexReplaceAll "(\\[\\s*SERVICE\\s*\\])" $config (printf "$1\n%snet.dns.prefer_ipv6       true" $indent) -}}
{{- end -}}
{{- $config -}}
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
Set DCGM_EXPORTER_INTERVAL environment variable for dcgmExporter if accelerated_compute_gpu_metrics_collection_interval is set and less than 60
*/}}
{{- define "dcgm-exporter.env" -}}
{{- $intervalFound := false -}}
{{- $intervalValue := 0 -}}
{{- range .Values.agents -}}
  {{- $agent := mergeOverwrite (deepCopy $.Values.agent) . -}}
  {{- $agentConfig := $agent.config -}}
  {{- if or (not $agentConfig) (eq ($agentConfig | toString) "default") -}}
    {{- $agentConfig = dict -}}
  {{- end -}}
  {{- if and (hasKey $agentConfig "logs") (hasKey $agentConfig.logs "metrics_collected") (hasKey $agentConfig.logs.metrics_collected "kubernetes") (hasKey $agentConfig.logs.metrics_collected.kubernetes "accelerated_compute_gpu_metrics_collection_interval") -}}
    {{- $intervalFound = true -}}
    {{- $intervalValue = $agentConfig.logs.metrics_collected.kubernetes.accelerated_compute_gpu_metrics_collection_interval -}}
  {{- end -}}
{{- end -}}
{{- if and $intervalFound (lt ($intervalValue | int) 60) -}}
- name: DCGM_EXPORTER_INTERVAL
  value: "1000"
{{- end -}}
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

{{/*
Returns auto-generated certificate and CA for admission webhooks.
*/}}
{{- define "amazon-cloudwatch-observability.webhookCert" -}}
{{- $tlsCrt := "" }}
{{- $tlsKey := "" }}
{{- $caCrt := "" }}
{{- if .Values.admissionWebhooks.autoGenerateCert.enabled }}
{{- $existingCert := ( lookup "v1" "Secret" .Release.Namespace (include "amazon-cloudwatch-observability.certificateSecretName" .) ) }}
{{- if and (not .Values.admissionWebhooks.autoGenerateCert.recreate) $existingCert }}
{{- $tlsCrt = index $existingCert "data" "tls.crt" }}
{{- $tlsKey = index $existingCert "data" "tls.key" }}
{{- $caCrt = index $existingCert "data" "ca.crt" }}
{{- if not $caCrt }}
{{- $existingWebhook := ( lookup "admissionregistration.k8s.io/v1" "MutatingWebhookConfiguration" "" (printf "%s-mutating-webhook-configuration" (include "amazon-cloudwatch-observability.name" .)) ) }}
{{- $caCrt = (first $existingWebhook.webhooks).clientConfig.caBundle }}
{{- end }}
{{- else }}
{{- $altNames := list ( printf "%s-webhook-service.%s" (include "amazon-cloudwatch-observability.name" .) .Release.Namespace ) ( printf "%s-webhook-service.%s.svc" (include "amazon-cloudwatch-observability.name" .) .Release.Namespace ) ( printf "%s-webhook-service.%s.svc.cluster.local" (include "amazon-cloudwatch-observability.name" .) .Release.Namespace ) -}}
{{- $ca := genCA ( printf "%s-ca" (include "amazon-cloudwatch-observability.name" .) ) ( .Values.admissionWebhooks.autoGenerateCert.expiryDays | int ) -}}
{{- $cert := genSignedCert (include "amazon-cloudwatch-observability.name" .) nil $altNames ( .Values.admissionWebhooks.autoGenerateCert.expiryDays | int ) $ca -}}
{{- $tlsCrt = b64enc $cert.Cert }}
{{- $tlsKey = b64enc $cert.Key }}
{{- $caCrt = b64enc $ca.Cert }}
{{- end }}
{{- $result := dict "Cert" $tlsCrt "Key" $tlsKey "Ca" $caCrt }}
{{- $result | toYaml }}
{{- end }}
{{- end }}

{{/*
Name for node-exporter
*/}}
{{- define "node-exporter.name" -}}
{{- default "node-exporter" .Values.nodeExporter.name }}
{{- end }}

{{/*
Create the name of the service account to use for node exporter
*/}}
{{- define "node-exporter.serviceAccountName" -}}
{{- default "node-exporter-service-acct" .Values.nodeExporter.serviceAccount.name }}
{{- end }}

{{/*
Get the node-exporter scope version (image tag) for the configured region.
Uses restrictedTag for regions with a repositoryDomainMap entry, public tag otherwise.
*/}}
{{- define "node-exporter.scopeVersion" -}}
{{- if and (hasKey .Values.nodeExporter.image.repositoryDomainMap .Values.region) (index .Values.nodeExporter.image.repositoryDomainMap .Values.region) -}}
{{- .Values.nodeExporter.image.restrictedTag -}}
{{- else -}}
{{- .Values.nodeExporter.image.tag -}}
{{- end -}}
{{- end -}}

{{/*
Get the node-exporter image for the configured region using repositoryDomainMap
*/}}
{{- define "node-exporter.image" -}}
{{- if and (hasKey .Values.nodeExporter.image.repositoryDomainMap .Values.region) (index .Values.nodeExporter.image.repositoryDomainMap .Values.region) -}}
{{- $imageDomain := index .Values.nodeExporter.image.repositoryDomainMap .Values.region -}}
{{- printf "%s/%s:%s" $imageDomain .Values.nodeExporter.image.restrictedRepository .Values.nodeExporter.image.restrictedTag -}}
{{- else -}}
{{- $imageDomain := .Values.nodeExporter.image.repositoryDomainMap.public -}}
{{- printf "%s/%s:%s" $imageDomain .Values.nodeExporter.image.repository .Values.nodeExporter.image.tag -}}
{{- end -}}
{{- end -}}

{{/*
Name for kube-state-metrics
*/}}
{{- define "kube-state-metrics.name" -}}
{{- default "kube-state-metrics" .Values.kubeStateMetrics.name }}
{{- end }}

{{/*
Create the name of the service account to use for kube-state-metrics
*/}}
{{- define "kube-state-metrics.serviceAccountName" -}}
{{- default "kube-state-metrics-service-acct" .Values.kubeStateMetrics.serviceAccount.name }}
{{- end }}

{{/*
Get the kube-state-metrics scope version (image tag) for the configured region.
Uses restrictedTag for regions with a repositoryDomainMap entry, public tag otherwise.
*/}}
{{- define "kube-state-metrics.scopeVersion" -}}
{{- if and (hasKey .Values.kubeStateMetrics.image.repositoryDomainMap .Values.region) (index .Values.kubeStateMetrics.image.repositoryDomainMap .Values.region) -}}
{{- .Values.kubeStateMetrics.image.restrictedTag -}}
{{- else -}}
{{- .Values.kubeStateMetrics.image.tag -}}
{{- end -}}
{{- end -}}

{{/*
Get the kube-state-metrics image for the configured region using repositoryDomainMap
*/}}
{{- define "kube-state-metrics.image" -}}
{{- if and (hasKey .Values.kubeStateMetrics.image.repositoryDomainMap .Values.region) (index .Values.kubeStateMetrics.image.repositoryDomainMap .Values.region) -}}
{{- $imageDomain := index .Values.kubeStateMetrics.image.repositoryDomainMap .Values.region -}}
{{- printf "%s/%s:%s" $imageDomain .Values.kubeStateMetrics.image.restrictedRepository .Values.kubeStateMetrics.image.restrictedTag -}}
{{- else -}}
{{- $imageDomain := .Values.kubeStateMetrics.image.repositoryDomainMap.public -}}
{{- printf "%s/%s:%s" $imageDomain .Values.kubeStateMetrics.image.repository .Values.kubeStateMetrics.image.tag -}}
{{- end -}}
{{- end -}}

{{/*
Merge two OTEL configs. The generated OTLP CI config (Base) takes precedence over the
user-supplied otelConfig (User) on name collision. For map sections (extensions, receivers,
processors, exporters) both sets of entries are combined, with generated entries winning on
key collision. For service.extensions (a list) both lists are concatenated and deduped.
For service.pipelines (a map) both pipeline maps are combined, with generated pipelines
winning on key collision.
*/}}
{{- define "cloudwatch-agent.merge-otel-configs" -}}
{{- $base := .Base -}}
{{- $user := .User -}}
{{- if kindIs "string" $base }}
  {{- $base = fromYaml $base }}
  {{- if hasKey $base "Error" }}
    {{- fail (printf "Failed to parse generated otelConfig: %s" (index $base "Error")) }}
  {{- end }}
{{- end }}
{{- if kindIs "string" $user }}
  {{- $user = fromYaml $user }}
  {{- if hasKey $user "Error" }}
    {{- fail (printf "Failed to parse user-supplied otelConfig: %s" (index $user "Error")) }}
  {{- end }}
{{- end }}
{{/* Merge top-level map sections: extensions, receivers, processors, exporters */}}
{{- $merged := deepCopy $base -}}
{{- range $section := list "extensions" "receivers" "processors" "exporters" -}}
  {{- if and (hasKey $user $section) (hasKey $merged $section) -}}
    {{- $_ := set $merged $section (mustMergeOverwrite (index $user $section) (index $merged $section)) -}}
  {{- else if hasKey $user $section -}}
    {{- $_ := set $merged $section (index $user $section) -}}
  {{- end -}}
{{- end -}}
{{/* Merge service section */}}
{{- if and (hasKey $user "service") (hasKey $merged "service") -}}
  {{/* Concatenate service.extensions lists */}}
  {{- if and (hasKey $user.service "extensions") (hasKey $merged.service "extensions") -}}
    {{- $mergedExts := concat $merged.service.extensions $user.service.extensions | uniq -}}
    {{- $_ := set $merged.service "extensions" $mergedExts -}}
  {{- else if hasKey $user.service "extensions" -}}
    {{- $_ := set $merged.service "extensions" $user.service.extensions -}}
  {{- end -}}
  {{/* Merge service.pipelines maps */}}
  {{- if and (hasKey $user.service "pipelines") (hasKey $merged.service "pipelines") -}}
    {{- $_ := set $merged.service "pipelines" (mustMergeOverwrite $user.service.pipelines $merged.service.pipelines) -}}
  {{- else if hasKey $user.service "pipelines" -}}
    {{- $_ := set $merged.service "pipelines" $user.service.pipelines -}}
  {{- end -}}
{{- else if hasKey $user "service" -}}
  {{- $_ := set $merged "service" $user.service -}}
{{- end -}}
{{- $merged | toYaml -}}
{{- end -}}

{{/* Recursively drop nil leaves so a user-supplied `cpu: null` removes the limit instead of emitting literal null. mergeOverwrite keeps nil values from the default, so prune after merge. */}}
{{- define "cloudwatch-agent.pruneNulls" -}}
{{- $in := . -}}
{{- $out := dict -}}
{{- range $k, $v := $in -}}
  {{- if kindIs "map" $v -}}
    {{- $nested := include "cloudwatch-agent.pruneNulls" $v | fromYaml -}}
    {{- if $nested -}}
      {{- $_ := set $out $k $nested -}}
    {{- end -}}
  {{- else if not (kindIs "invalid" $v) -}}
    {{- $_ := set $out $k $v -}}
  {{- end -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end -}}
