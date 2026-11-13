{{/*
Expand the name of the chart.
*/}}
{{- define "amazon-cloudwatch-observability.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Whether the operator creates the ServiceMonitor/PodMonitor CRDs when they are missing
(operator flag --manage-prometheus-crds, plus the matching operator RBAC). True when
otelPrometheusMonitor.enabled. The chart itself never renders these CRDs.
Returns "true" or empty.
*/}}
{{- define "amazon-cloudwatch-observability.managePrometheusCRDs" -}}
{{- if dig "enabled" false (.Values.otelPrometheusMonitor | default dict) -}}
true
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
Resolve podLabels for a workload. Component value overrides root when defined
(explicit empty map `{}` counts as an override — same semantics as
`common.tolerations`).

Callers may pass a `reserved` list of label keys the workload's pod template
already emits as built-ins (e.g. selector labels). Those keys are stripped from
the returned user-provided labels so the rendered pod template contains no
duplicate keys and user input cannot override operator-managed selector labels.

Returns the map rendered as YAML content (no wrapping key).

Usage:
  {{- $labels := include "amazon-cloudwatch-observability.common.podLabels" (dict
       "component" .Values.manager
       "context"   .
       "reserved"  (list "app.kubernetes.io/name" "control-plane"))
       }}
  {{- with $labels }}{{ . | nindent 8 }}{{ end }}
*/}}
{{- define "amazon-cloudwatch-observability.common.podLabels" -}}
{{- $v := .context.Values.podLabels }}
{{- if .component }}
  {{- $componentPodLabels := dig "podLabels" nil .component }}
  {{- if ne nil $componentPodLabels }}
    {{- $v = $componentPodLabels }}
  {{- end }}
{{- end }}
{{- if and $v .reserved }}
  {{- $reserved := .reserved }}
  {{- $filtered := dict }}
  {{- range $k, $val := $v }}
    {{- if not (has $k $reserved) }}
      {{- $_ := set $filtered $k $val }}
    {{- end }}
  {{- end }}
  {{- $v = $filtered }}
{{- end }}
{{- with $v }}{{ toYaml . }}{{ end }}
{{- end }}

{{/*
Resolve podAnnotations for a workload. Component value overrides root when
defined (explicit empty map counts as an override).
*/}}
{{- define "amazon-cloudwatch-observability.common.podAnnotations" -}}
{{- $v := .context.Values.podAnnotations }}
{{- if .component }}
  {{- $componentPodAnnotations := dig "podAnnotations" nil .component }}
  {{- if ne nil $componentPodAnnotations }}
    {{- $v = $componentPodAnnotations }}
  {{- end }}
{{- end }}
{{- with $v }}{{ toYaml . }}{{ end }}
{{- end }}

{{/*
Resolve topologySpreadConstraints for a workload. Component value overrides
root when defined (explicit empty list counts as an override). Emits
`topologySpreadConstraints: [ ... ]` block or nothing.
Usage:
  {{- include "amazon-cloudwatch-observability.common.topologySpreadConstraints" (dict "component" .Values.manager "context" .) | nindent 6 }}
*/}}
{{- define "amazon-cloudwatch-observability.common.topologySpreadConstraints" -}}
{{- $v := .context.Values.topologySpreadConstraints }}
{{- if .component }}
  {{- $componentTsc := dig "topologySpreadConstraints" nil .component }}
  {{- if ne nil $componentTsc }}
    {{- $v = $componentTsc }}
  {{- end }}
{{- end }}
{{- with $v }}
topologySpreadConstraints:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Resolve priorityClassName for a workload. Returns the bare string (empty if unset).
Component value overrides root when defined (explicit empty string counts as an override).
Usage:
  {{- $pcn := include "amazon-cloudwatch-observability.common.priorityClassName" (dict "component" .Values.manager "context" .) }}
  {{- if $pcn }}priorityClassName: {{ $pcn | quote }}{{ end }}
*/}}
{{- define "amazon-cloudwatch-observability.common.priorityClassName" -}}
{{- $v := .context.Values.priorityClassName | default "" -}}
{{- if .component }}
  {{- $componentPcn := dig "priorityClassName" nil .component }}
  {{- if ne nil $componentPcn }}
    {{- $v = $componentPcn }}
  {{- end }}
{{- end }}
{{- $v -}}
{{- end }}

{{/*
Resolve podDisruptionBudget for a workload. Returns the effective PDB object
as YAML (parse with fromYaml). Component value overrides root when defined
(explicit empty dict counts as an override).
Usage:
  {{- $pdb := include "amazon-cloudwatch-observability.common.podDisruptionBudget" (dict "component" .Values.manager "context" .) | fromYaml }}
  {{- if $pdb.enabled }}...{{ end }}
*/}}
{{- define "amazon-cloudwatch-observability.common.podDisruptionBudget" -}}
{{- $v := .context.Values.podDisruptionBudget | default dict -}}
{{- if .component }}
  {{- $componentPdb := dig "podDisruptionBudget" nil .component }}
  {{- if ne nil $componentPdb }}
    {{- $v = $componentPdb }}
  {{- end }}
{{- end }}
{{- toYaml $v -}}
{{- end }}

{{/*
Render a PodDisruptionBudget resource. Callers pass:
  name       — PDB metadata.name
  namespace  — target namespace (usually .Release.Namespace)
  selector   — dict of matchLabels for spec.selector
  pdb        — the resolved PDB object (must have enabled: true; maxUnavailable and/or minAvailable)
  ctx        — the root context (.) for common labels
*/}}
{{- define "amazon-cloudwatch-observability.renderPodDisruptionBudget" -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .name }}
  namespace: {{ .namespace }}
  labels:
    {{- include "amazon-cloudwatch-observability.labels" .ctx | nindent 4 }}
spec:
  {{- if hasKey .pdb "minAvailable" }}
  minAvailable: {{ .pdb.minAvailable }}
  {{- else if hasKey .pdb "maxUnavailable" }}
  maxUnavailable: {{ .pdb.maxUnavailable }}
  {{- end }}
  selector:
    matchLabels:
      {{- toYaml .selector | nindent 6 }}
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
    {{- if and $agent.config (not (has ($agent.config | toString) (list "default" "default:otel"))) -}}
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
  - When otelContainerInsights.enabled is true and otelContainerInsights.targetAgent matches
    agentName, the node-level OTEL CI config
  - When otelContainerInsights.enabled is true and otelContainerInsights.clusterScraperAgent
    matches agentName, the cluster-level OTEL CI config
  - Otherwise, when otelPrometheusMonitor applies to agentName, the ServiceMonitor/PodMonitor
    pipeline alone (cloudwatch-agent.prometheus-monitor-config)
  - When otlp.enabled is true and agentName is the node agent (cloudwatch-agent.name), the OTLP
    endpoint config (otlp.config), merged with whichever of the configs above applies
  - Otherwise: {}
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
{{- if not (kindIs "bool" .Values.otelContainerInsights.enableDRACorrelation) }}
{{- fail "otelContainerInsights.enableDRACorrelation must be a boolean (true/false)" }}
{{- end }}
{{- include "otel-container-insights.validate-filters" . }}
{{- include "otlp.validate" . }}
{{- include "service-identity.validate" . }}
{{- include "cloudwatch-agent.validate-prometheus-monitor" . }}
{{- end -}}

{{/*
Validates otelPrometheusMonitor when it is enabled. Called from cloudwatch-agent.validate-flags.
  - targetAgent and clusterScraperAgent are set and differ.
  - With otelContainerInsights also enabled, both agent names match otelContainerInsights:
    each agent then runs the otelContainerInsights config, which already contains the
    ServiceMonitor/PodMonitor pipeline, so the two features cannot target different agents.
  - scrapeInterval is in "<N>s" format.
  - serviceMonitorSelector and podMonitorSelector are Kubernetes LabelSelectors.
*/}}
{{- define "cloudwatch-agent.validate-prometheus-monitor" -}}
{{- $pm := .Values.otelPrometheusMonitor | default dict -}}
{{- if dig "enabled" false $pm -}}
{{- $target := dig "targetAgent" "" $pm -}}
{{- $scraper := dig "clusterScraperAgent" "" $pm -}}
{{- if or (not (kindIs "string" $target)) (not $target) (not (kindIs "string" $scraper)) (not $scraper) -}}
{{- fail "otelPrometheusMonitor.targetAgent and otelPrometheusMonitor.clusterScraperAgent must be non-empty strings" -}}
{{- end -}}
{{- if eq $target $scraper -}}
{{- fail (printf "otelPrometheusMonitor.targetAgent and otelPrometheusMonitor.clusterScraperAgent must differ, both are %q" $target) -}}
{{- end -}}
{{- if .Values.otelContainerInsights.enabled -}}
{{- if or (ne $target .Values.otelContainerInsights.targetAgent) (ne $scraper .Values.otelContainerInsights.clusterScraperAgent) -}}
{{- fail (printf "with otelContainerInsights and otelPrometheusMonitor both enabled, otelPrometheusMonitor.targetAgent (%q) and clusterScraperAgent (%q) must match otelContainerInsights.targetAgent (%q) and clusterScraperAgent (%q)" $target $scraper .Values.otelContainerInsights.targetAgent .Values.otelContainerInsights.clusterScraperAgent) -}}
{{- end -}}
{{- end -}}
{{- $interval := dig "scrapeInterval" "" $pm | toString -}}
{{- if not (regexMatch "^[1-9][0-9]*s$" $interval) -}}
{{- fail (printf "otelPrometheusMonitor.scrapeInterval must be in \"<N>s\" format (e.g. \"30s\"), got: %s" $interval) -}}
{{- end -}}
{{- range $key := list "serviceMonitorSelector" "podMonitorSelector" -}}
{{- include "cloudwatch-agent.validate-label-selector" (dict "name" (printf "otelPrometheusMonitor.%s" $key) "selector" (get $pm $key)) -}}
{{- end -}}
{{- include "cloudwatch-agent.validate-agent-crd" . -}}
{{- end -}}
{{- end -}}

{{/*
Fails when otelPrometheusMonitor is enabled, crds.upgradeJob is disabled, and the
AmazonCloudWatchAgent CRD in the cluster is older than this chart's. Helm installs crds/ on
the first install only and never updates it, so a cluster upgraded with helm upgrade keeps
the CRD it was first installed with. With an older CRD the API server rejects
allocationStrategy per-node and label-selector monitor selectors, and drops scraperRole
without an error, so the cluster-scraper would scrape the per-node agent's monitors.
With crds.upgradeJob enabled the check is skipped: Helm renders the templates, lookup
included, before it runs the pre-upgrade hook, so the check would still see the old CRD
that the hook is about to update.
lookup returns nothing when there is no cluster to read (helm template, a client-side dry
run, tools that render offline); the check is then skipped too.
*/}}
{{- define "cloudwatch-agent.validate-agent-crd" -}}
{{- if not (dig "upgradeJob" "enabled" false (.Values.crds | default dict)) -}}
{{- $crd := lookup "apiextensions.k8s.io/v1" "CustomResourceDefinition" "" "amazoncloudwatchagents.cloudwatch.aws.amazon.com" -}}
{{- include "cloudwatch-agent.validate-agent-crd-schema" (dict "crd" $crd "Values" .Values "chartVersion" .Chart.Version) -}}
{{- end -}}
{{- end -}}

{{/*
The schema check of cloudwatch-agent.validate-agent-crd, on a CRD object (.crd, empty to skip),
so it can be tested without a cluster. Accepts a dict with "crd", "Values" and "chartVersion".
*/}}
{{- define "cloudwatch-agent.validate-agent-crd-schema" -}}
{{- $crd := .crd | default dict -}}
{{- if $crd -}}
{{- $schema := dict -}}
{{- range (dig "spec" "versions" list $crd) -}}
{{- if eq (get . "name") "v1alpha1" -}}
{{- $schema = . -}}
{{- end -}}
{{- end -}}
{{- $ta := dig "schema" "openAPIV3Schema" "properties" "spec" "properties" "targetAllocator" "properties" dict $schema -}}
{{- $pcr := dig "prometheusCR" "properties" dict $ta -}}
{{- $missing := list -}}
{{- if not (has "per-node" (dig "allocationStrategy" "enum" list $ta)) -}}
{{- $missing = append $missing "targetAllocator.allocationStrategy per-node" -}}
{{- end -}}
{{- if not (hasKey $pcr "scraperRole") -}}
{{- $missing = append $missing "targetAllocator.prometheusCR.scraperRole" -}}
{{- end -}}
{{- $pm := .Values.otelPrometheusMonitor | default dict -}}
{{- range $key := list "serviceMonitorSelector" "podMonitorSelector" -}}
{{- if and (get $pm $key) (not (hasKey (dig $key "properties" dict $pcr) "matchExpressions")) -}}
{{- $missing = append $missing (printf "targetAllocator.prometheusCR.%s as a label selector" $key) -}}
{{- end -}}
{{- end -}}
{{- if $missing -}}
{{- fail (printf "otelPrometheusMonitor needs the AmazonCloudWatchAgent CRD from this chart version, but the CRD in the cluster (amazoncloudwatchagents.cloudwatch.aws.amazon.com) lacks %s. helm upgrade does not update CRDs, so the cluster still has the CRD from its first install, and crds.upgradeJob, which updates them before each upgrade, is disabled. Set crds.upgradeJob.enabled=true, or apply this chart's CRDs and run the upgrade again: helm pull aws-observability/amazon-cloudwatch-observability --version %s --untar && kubectl apply --server-side --force-conflicts -f amazon-cloudwatch-observability/crds/" (join ", " $missing) .chartVersion) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Fails unless .selector is empty or a Kubernetes LabelSelector: only matchLabels (a map of
strings) and matchExpressions (a list of {key, operator, values}). operator is In, NotIn,
Exists or DoesNotExist; In and NotIn need values, Exists and DoesNotExist take none.
Accepts a dict with "name" (the values path, for messages) and "selector".
*/}}
{{- define "cloudwatch-agent.validate-label-selector" -}}
{{- $name := .name -}}
{{- $sel := .selector -}}
{{- if $sel -}}
{{- if not (kindIs "map" $sel) -}}
{{- fail (printf "%s must be a label selector (matchLabels and/or matchExpressions)" $name) -}}
{{- end -}}
{{- range $k, $_ := $sel -}}
{{- if not (has $k (list "matchLabels" "matchExpressions")) -}}
{{- fail (printf "%s: unknown key %q, only matchLabels and matchExpressions are allowed" $name $k) -}}
{{- end -}}
{{- end -}}
{{- with $sel.matchLabels -}}
{{- if not (kindIs "map" .) -}}
{{- fail (printf "%s.matchLabels must be a map of label names to values" $name) -}}
{{- end -}}
{{- range $k, $v := . -}}
{{- if not (kindIs "string" $v) -}}
{{- fail (printf "%s.matchLabels.%s must be a string (quote values such as \"true\")" $name $k) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- with $sel.matchExpressions -}}
{{- if not (kindIs "slice" .) -}}
{{- fail (printf "%s.matchExpressions must be a list" $name) -}}
{{- end -}}
{{- range $i, $e := . -}}
{{- if or (not (kindIs "map" $e)) (not (kindIs "string" (get $e "key"))) (not (get $e "key")) -}}
{{- fail (printf "%s.matchExpressions[%d] needs a key" $name $i) -}}
{{- end -}}
{{- $op := get $e "operator" | toString -}}
{{- if not (has $op (list "In" "NotIn" "Exists" "DoesNotExist")) -}}
{{- fail (printf "%s.matchExpressions[%d].operator must be In, NotIn, Exists or DoesNotExist, got %q" $name $i $op) -}}
{{- end -}}
{{- $values := get $e "values" -}}
{{- if and $values (not (kindIs "slice" $values)) -}}
{{- fail (printf "%s.matchExpressions[%d].values must be a list" $name $i) -}}
{{- end -}}
{{- if and (has $op (list "In" "NotIn")) (not $values) -}}
{{- fail (printf "%s.matchExpressions[%d]: operator %s needs values" $name $i $op) -}}
{{- end -}}
{{- if and (has $op (list "Exists" "DoesNotExist")) $values -}}
{{- fail (printf "%s.matchExpressions[%d]: operator %s takes no values" $name $i $op) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "cloudwatch-agent.build-default-otel-config" -}}
{{- $agentName := .agentName -}}
{{- $ctx := .context -}}
{{- include "cloudwatch-agent.validate-flags" $ctx -}}
{{- $ciOn := $ctx.Values.otelContainerInsights.enabled -}}
{{- $monitorOn := eq (include "cloudwatch-agent.prometheusMonitorEnabled" (dict "agentName" $agentName "context" $ctx)) "true" -}}
{{- $ci := "{}" -}}
{{- if and $ciOn (eq $ctx.Values.otelContainerInsights.targetAgent $agentName) -}}
{{- $ci = include "otel-container-insights.config" $ctx -}}
{{- else if and $ciOn (eq $ctx.Values.otelContainerInsights.clusterScraperAgent $agentName) -}}
{{- $ci = include "otel-container-insights-cluster-scraper.config" $ctx -}}
{{- else if $monitorOn -}}
{{- /* otelContainerInsights is off for this agent (validate-prometheus-monitor rules out
       different agent names when both are on): cut the ServiceMonitor/PodMonitor pipeline
       from the per-node or cluster-scraper template. */ -}}
{{- $full := "" -}}
{{- if eq (dig "targetAgent" "" $ctx.Values.otelPrometheusMonitor) $agentName -}}
{{- $full = include "otel-container-insights.config" $ctx -}}
{{- else -}}
{{- $full = include "otel-container-insights-cluster-scraper.config" $ctx -}}
{{- end -}}
{{- $ci = include "cloudwatch-agent.prometheus-monitor-config" (dict "config" $full) -}}
{{- end -}}
{{- if not (include "otlp.enabledFor" .) -}}
{{- $ci -}}
{{- else if eq (trimAll " \n\t" $ci) "{}" -}}
{{- include "otlp.config" $ctx -}}
{{- else -}}
{{- include "cloudwatch-agent.merge-otel-configs" (dict "Base" $ci "User" (include "otlp.config" $ctx)) -}}
{{- end -}}
{{- end -}}

{{/*
The OTEL config for ServiceMonitor/PodMonitor scraping alone, for an agent whose
otelContainerInsights config is off. It is cut from that agent's full otelContainerInsights
config, which defines the metrics/cw_k8s_ci_v0_prometheuscr pipeline whenever
otelPrometheusMonitor.enabled is true: the pipeline, the receivers, processors and
exporters it lists, the extensions those exporters authenticate with, and
service.telemetry. Taking the components from the same template keeps the definitions
identical whether or not otelContainerInsights is on, and no other otelContainerInsights
pipeline renders. Accepts a dict with "config" (the rendered full config, a string).
*/}}
{{- define "cloudwatch-agent.prometheus-monitor-config" -}}
{{- $pipelineName := "metrics/cw_k8s_ci_v0_prometheuscr" -}}
{{- $full := fromYaml .config -}}
{{- if hasKey $full "Error" -}}
{{- fail (printf "Failed to parse the otelContainerInsights config: %s" (index $full "Error")) -}}
{{- end -}}
{{- $pipeline := dig "service" "pipelines" $pipelineName dict $full -}}
{{- if not $pipeline -}}
{{- fail (printf "otelPrometheusMonitor: the otelContainerInsights config has no %s pipeline" $pipelineName) -}}
{{- end -}}
{{- $out := dict "receivers" dict "processors" dict "exporters" dict "extensions" dict -}}
{{- range $section := list "receivers" "processors" "exporters" -}}
{{- range $name := (get $pipeline $section | default list) -}}
{{- if not (hasKey (get $full $section | default dict) $name) -}}
{{- fail (printf "otelPrometheusMonitor: %s %s is not defined" $section $name) -}}
{{- end -}}
{{- $_ := set (get $out $section) $name (index (get $full $section) $name) -}}
{{- end -}}
{{- end -}}
{{- $extensions := list -}}
{{- range $name, $exporter := (get $out "exporters") -}}
{{- $auth := dig "auth" "authenticator" "" ($exporter | default dict) -}}
{{- if $auth -}}
{{- $_ := set (get $out "extensions") $auth (dig "extensions" $auth dict $full) -}}
{{- $extensions = append $extensions $auth -}}
{{- end -}}
{{- end -}}
{{- $service := dict "pipelines" (dict $pipelineName $pipeline) -}}
{{- if $extensions -}}
{{- $_ := set $service "extensions" ($extensions | uniq) -}}
{{- end -}}
{{- with (dig "service" "telemetry" nil $full) -}}
{{- $_ := set $service "telemetry" . -}}
{{- end -}}
{{- $_ := set $out "service" $service -}}
{{- if not (get $out "extensions") -}}
{{- $_ := unset $out "extensions" -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Returns "true" when ServiceMonitor/PodMonitor scraping applies to the given agent: when
otelPrometheusMonitor.enabled is true and the agent is either otelPrometheusMonitor.targetAgent
(per-node scraping of unrouted monitors) or otelPrometheusMonitor.clusterScraperAgent (central
scraping of monitors routed with cloudwatch.aws.amazon.com/scraper: cluster-scraper). It does
not depend on otelContainerInsights.
Accepts a dict with "agentName" (string) and "context" (root context $).
*/}}
{{- define "cloudwatch-agent.prometheusMonitorEnabled" -}}
{{- $ctx := .context -}}
{{- $agentName := .agentName -}}
{{- $pm := $ctx.Values.otelPrometheusMonitor | default dict -}}
{{- if and (dig "enabled" false $pm) (or (eq $agentName (dig "targetAgent" "" $pm)) (eq $agentName (dig "clusterScraperAgent" "" $pm))) -}}
true
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
Helper function to modify cloudwatch-agent YAML config. Returns the YAML text
unquoted, so that the caller can hash the same text that it writes.
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

{{- $configCopy | toYaml }}
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

{{/*
Render a Kubernetes IntOrString value (for example rollingUpdate.maxUnavailable).
The API accepts either a bare integer or a percentage string, so a plain number
must not be quoted: "1" is rejected with 'a valid percent string must be a
numeric string followed by an ending %'. Emit digits bare and quote anything
else, which keeps percentages valid while still preventing a configured value
from breaking out of its YAML scalar.
*/}}
{{- define "cloudwatch-agent.intOrStringValue" -}}
{{- $value := . | toString -}}
{{- if regexMatch "^[0-9]+$" $value -}}
{{- $value -}}
{{- else -}}
{{- $value | quote -}}
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
Validate a CloudWatch Agent name. The 36-character limit leaves room for the
longest generated resource suffix (-windows-container-insights) within the
Kubernetes 63-character DNS label limit.
*/}}
{{- define "cloudwatch-agent.validatedName" -}}
{{- $name := . | toString -}}
{{- if gt (len $name) 36 -}}
{{- fail "CloudWatch Agent names must be at most 36 characters" -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name) -}}
{{- fail "CloudWatch Agent names must be valid DNS-1123 labels" -}}
{{- end -}}
{{- $name -}}
{{- end }}

{{/*
Name for cloudwatch-agent
*/}}
{{/*
The name an agents entry (.agent) renders with: its own name, else agent.name,
else cloudwatch-agent, after merging it over agent. The agent CR template and
otlp.nodeAgentRendered both use this, so they agree on which agent is the node
agent.
*/}}
{{- define "cloudwatch-agent.resolvedName" -}}
{{- $agent := mergeOverwrite (deepCopy .context.Values.agent) .agent }}
{{- include "cloudwatch-agent.validatedName" ($agent.name | default (include "cloudwatch-agent.name" .context)) -}}
{{- end -}}

{{- define "cloudwatch-agent.name" -}}
{{- include "cloudwatch-agent.validatedName" (default "cloudwatch-agent" .Values.agent.name) -}}
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
Validate a Fluent Bit ConfigMap key and @INCLUDE file name.
*/}}
{{- define "fluent-bit.validatedConfigKey" -}}
{{- $key := . | toString -}}
{{- if gt (len $key) 253 -}}
{{- fail "Fluent Bit extraFiles keys must be at most 253 characters" -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" $key) -}}
{{- fail "Fluent Bit extraFiles keys may contain only alphanumeric characters, '.', '_' or '-'" -}}
{{- end -}}
{{- $key -}}
{{- end }}

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
  {{- if or (not $agentConfig) (has ($agentConfig | toString) (list "default" "default:otel")) -}}
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

{{/*
Legacy helpers kept for backward compatibility. Delegate to the common helpers,
sourcing from `manager` at the component level so root-level values are inherited.
*/}}
{{- define "amazon-cloudwatch-observability.podAnnotations" -}}
{{- include "amazon-cloudwatch-observability.common.podAnnotations" (dict "component" .Values.manager "context" .) }}
{{- end }}

{{- define "amazon-cloudwatch-observability.podLabels" -}}
{{- include "amazon-cloudwatch-observability.common.podLabels" (dict "component" .Values.manager "context" .) }}
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
{{/*
The crds.upgradeJob kubectl image: repositoryDomainMap[region] when set, else the public registry.
*/}}
{{- define "crd-upgrade-job.image" -}}
{{- $image := .Values.crds.upgradeJob.image -}}
{{- $domain := index $image.repositoryDomainMap .Values.region | default $image.repositoryDomainMap.public -}}
{{- printf "%s/%s:%s" $domain $image.repository $image.tag -}}
{{- end -}}

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
Merge two OTEL configs. The generated config (Base) takes precedence over the other config
(User) on name collision: Base is the OTEL CI config and User the OTLP endpoint config, or Base
is the generated config and User the user-supplied otelConfig. For map sections (extensions,
receivers, connectors, processors, exporters) both sets of entries are combined, with Base
entries winning on key collision. For service.extensions (a list) both lists are concatenated and deduped.
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
{{/* Merge top-level map sections: extensions, receivers, connectors, processors, exporters */}}
{{- $merged := deepCopy $base -}}
{{- range $section := list "extensions" "receivers" "connectors" "processors" "exporters" -}}
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
