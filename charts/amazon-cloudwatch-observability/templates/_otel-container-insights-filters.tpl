{{/*
Customer filters for the OTEL Container Insights pipelines
(otelContainerInsights.filters): validation, and the translation of the
filter values into OTel processors.
*/}}

{{/*
Validates otelContainerInsights.filters. Called from
cloudwatch-agent.validate-flags, so an invalid value fails the render before
any entry reaches a template.
*/}}
{{- define "otel-container-insights.validate-filters" -}}
{{- $filters := .Values.otelContainerInsights.filters }}
{{- if not (or (kindIs "invalid" $filters) (kindIs "map" $filters)) }}
{{- fail "otelContainerInsights.filters must be a map" }}
{{- end }}
{{- range $key, $_ := $filters }}
{{- if not (has $key (list "metrics" "logs")) }}
{{- fail (printf "otelContainerInsights.filters has an unknown key %q (allowed: metrics, logs)" $key) }}
{{- end }}
{{- end }}
{{- range $signal := list "metrics" "logs" }}
{{- $settings := index ($filters | default dict) $signal }}
{{- if not (or (kindIs "invalid" $settings) (kindIs "map" $settings)) }}
{{- fail (printf "otelContainerInsights.filters.%s must be a map" $signal) }}
{{- end }}
{{- range $key, $_ := $settings }}
{{- if not (has $key (list "namespaces" "nodeLabels" "podLabels")) }}
{{- fail (printf "otelContainerInsights.filters.%s has an unknown key %q (allowed: namespaces, nodeLabels, podLabels)" $signal $key) }}
{{- end }}
{{- end }}
{{- $namespaces := index ($settings | default dict) "namespaces" }}
{{- if not (or (kindIs "invalid" $namespaces) (kindIs "map" $namespaces)) }}
{{- fail (printf "otelContainerInsights.filters.%s.namespaces must be a map with include and exclude lists" $signal) }}
{{- end }}
{{- range $key, $_ := $namespaces }}
{{- if not (has $key (list "include" "exclude")) }}
{{- fail (printf "otelContainerInsights.filters.%s.namespaces has an unknown key %q (allowed: include, exclude)" $signal $key) }}
{{- end }}
{{- end }}
{{- range $list := list "include" "exclude" }}
{{- $entries := index ($namespaces | default dict) $list }}
{{- if not (or (kindIs "invalid" $entries) (kindIs "slice" $entries)) }}
{{- fail (printf "otelContainerInsights.filters.%s.namespaces.%s must be a list" $signal $list) }}
{{- end }}
{{- range $entries }}
{{- if not (and (kindIs "string" .) (regexMatch "^([a-z0-9][-a-z0-9]*\\*?|\\*)$" .)) }}
{{- fail (printf "otelContainerInsights.filters.%s.namespaces entries must be a namespace name, a prefix ending in *, or *, got: %v" $signal .) }}
{{- end }}
{{- if gt (len (trimSuffix "*" .)) 63 }}
{{- fail (printf "otelContainerInsights.filters.%s.namespaces entries must be at most 63 characters, got: %s" $signal .) }}
{{- end }}
{{- end }}
{{- end }}
{{- $exclude := index ($namespaces | default dict) "exclude" | default list }}
{{- range index ($namespaces | default dict) "include" | default list }}
{{- if has . $exclude }}
{{- fail (printf "otelContainerInsights.filters.%s.namespaces: %q is in both include and exclude" $signal .) }}
{{- end }}
{{- end }}
{{- range $kind := list "nodeLabels" "podLabels" }}
{{- $labels := index ($settings | default dict) $kind }}
{{- if not (or (kindIs "invalid" $labels) (kindIs "map" $labels)) }}
{{- fail (printf "otelContainerInsights.filters.%s.%s must be a map with include, exclude and recommendedExclusions" $signal $kind) }}
{{- end }}
{{- range $key, $_ := $labels }}
{{- if not (has $key (list "include" "exclude" "recommendedExclusions")) }}
{{- fail (printf "otelContainerInsights.filters.%s.%s has an unknown key %q (allowed: include, exclude, recommendedExclusions)" $signal $kind $key) }}
{{- end }}
{{- end }}
{{- $recommended := index ($labels | default dict) "recommendedExclusions" }}
{{- if not (or (kindIs "invalid" $recommended) (kindIs "bool" $recommended)) }}
{{- fail (printf "otelContainerInsights.filters.%s.%s.recommendedExclusions must be a boolean (true/false)" $signal $kind) }}
{{- end }}
{{- range $list := list "include" "exclude" }}
{{- $entries := index ($labels | default dict) $list }}
{{- if not (or (kindIs "invalid" $entries) (kindIs "slice" $entries)) }}
{{- fail (printf "otelContainerInsights.filters.%s.%s.%s must be a list" $signal $kind $list) }}
{{- end }}
{{- range $entries }}
{{- if not (and (kindIs "string" .) (regexMatch "^([A-Za-z0-9][-A-Za-z0-9_./]*\\*?|\\*)$" .)) }}
{{- fail (printf "otelContainerInsights.filters.%s.%s entries must be a label key, a prefix ending in *, or *, got: %v" $signal $kind .) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- /* Metrics and logs share one k8sattributes processor per label kind. */}}
{{- range $kind := list "nodeLabels" "podLabels" }}
{{- $metricsInclude := (include "otel-container-insights.labelSettings" (dict "Values" $.Values "signal" "metrics" "kind" $kind) | fromJson).include | sortAlpha }}
{{- $logsInclude := (include "otel-container-insights.labelSettings" (dict "Values" $.Values "signal" "logs" "kind" $kind) | fromJson).include | sortAlpha }}
{{- if ne (toJson $metricsInclude) (toJson $logsInclude) }}
{{- fail (printf "otelContainerInsights.filters.metrics.%s.include and otelContainerInsights.filters.logs.%s.include must contain the same labels, got %s and %s" $kind $kind (toJson $metricsInclude) (toJson $logsInclude)) }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
OTTL condition that is true when the OTTL path .path matches any of the filter
entries in .entries: "name" is an exact match, "prefix*" a prefix match and "*"
matches everything. Entries are validated in otel-container-insights.validate-filters,
so they contain no quotes or backslashes.
*/}}
{{- define "otel-container-insights.filterMatch" -}}
{{- $conditions := list }}
{{- range .entries }}
{{- if eq . "*" }}
{{- $conditions = append $conditions "true" }}
{{- else if hasSuffix "*" . }}
{{- $conditions = append $conditions (printf "IsMatch(%s, \"^%s\")" $.path (trimSuffix "*" . | regexQuoteMeta | replace "\\" "\\\\")) }}
{{- else }}
{{- $conditions = append $conditions (printf "%s == \"%s\"" $.path .) }}
{{- end }}
{{- end }}
{{- printf "(%s)" (join " or " $conditions) }}
{{- end -}}

{{/*
Conditions of the namespace filter for .signal ("metrics" or "logs"), as a
JSON list. A datapoint or log record is dropped when any condition is true.
Every condition requires resource k8s.namespace.name, so records without it
always pass through. An include list containing "*" includes every
namespace, so it adds no condition.
*/}}
{{- define "otel-container-insights.namespaceConditions" -}}
{{- $settings := index (.Values.otelContainerInsights.filters | default dict) .signal | default dict }}
{{- $namespaces := index $settings "namespaces" | default dict }}
{{- $include := index $namespaces "include" | default list }}
{{- $exclude := index $namespaces "exclude" | default list }}
{{- $path := "resource.attributes[\"k8s.namespace.name\"]" }}
{{- $conditions := list }}
{{- if and $include (not (has "*" $include)) }}
{{- $conditions = append $conditions (printf "%s != nil and not %s" $path (include "otel-container-insights.filterMatch" (dict "path" $path "entries" $include))) }}
{{- end }}
{{- if $exclude }}
{{- $conditions = append $conditions (printf "%s != nil and %s" $path (include "otel-container-insights.filterMatch" (dict "path" $path "entries" $exclude))) }}
{{- end }}
{{- toJson $conditions }}
{{- end -}}

{{/*
The namespace filter processor for .signal, or nothing when it has no
conditions. The metrics filter is added to every metrics pipeline whose
records carry a workload's k8s.namespace.name, and the logs filter to the
application logs pipeline, before k8sattributes.
*/}}
{{- define "otel-container-insights.namespaceFilter" -}}
{{- $conditions := include "otel-container-insights.namespaceConditions" . | fromJsonArray }}
{{- if $conditions }}
filter/cw_k8s_ci_v0_{{ .signal }}_namespaces:
  error_mode: ignore
  {{ .signal }}:
    {{ ternary "datapoint" "log_record" (eq .signal "metrics") }}:
      {{- range $conditions }}
      - '{{ . }}'
      {{- end }}
{{- end }}
{{- end -}}

{{/*
"true" when the metrics or logs namespace filter has conditions, so it is
defined and added to pipelines.
*/}}
{{- define "otel-container-insights.metricsNamespaceFilterEnabled" -}}
{{- if include "otel-container-insights.namespaceConditions" (dict "Values" .Values "signal" "metrics") | fromJsonArray }}true{{ end }}
{{- end -}}

{{- define "otel-container-insights.logsNamespaceFilterEnabled" -}}
{{- if include "otel-container-insights.namespaceConditions" (dict "Values" .Values "signal" "logs") | fromJsonArray }}true{{ end }}
{{- end -}}

{{/*
The node or pod (.kind: "nodeLabels" or "podLabels") label settings of .signal
("metrics" or "logs") with defaults applied, as JSON
{"include": [...], "exclude": [...], "recommendedExclusions": bool}.
- include is ["*"] when it is empty or contains "*", since both mean every
  label. Duplicate entries are removed.
- A missing or null recommendedExclusions is true for metrics and false for
  logs, the values.yaml defaults, so a null signal or label section renders
  like the defaults. Keep the two in sync.
*/}}
{{- define "otel-container-insights.labelSettings" -}}
{{- $settings := index (.Values.otelContainerInsights.filters | default dict) .signal | default dict }}
{{- $labels := index $settings .kind | default dict }}
{{- $include := index $labels "include" | default list | uniq }}
{{- if or (not $include) (has "*" $include) }}
{{- $include = list "*" }}
{{- end }}
{{- $recommended := index $labels "recommendedExclusions" }}
{{- if kindIs "invalid" $recommended }}
{{- $recommended = eq .signal "metrics" }}
{{- end }}
{{- dict "include" $include "exclude" (index $labels "exclude" | default list | uniq) "recommendedExclusions" $recommended | toJson }}
{{- end -}}

{{/*
k8sattributes label extraction rules for the node or pod (.from) labels. The
metrics include list is used: validation requires the logs list to match.
"*" extracts all labels; the $$$1 in tag_name is copied unchanged from the
extract-all rule this helper replaced, and renders as the literal text $$$1.
*/}}
{{- define "otel-container-insights.k8sattributesLabels" -}}
{{- $labels := include "otel-container-insights.labelSettings" (dict "Values" .Values "signal" "metrics" "kind" (printf "%sLabels" .from)) | fromJson }}
{{- range $labels.include }}
{{- if hasSuffix "*" . }}
- tag_name: "k8s.{{ $.from }}.label.$$$1"
  key_regex: "({{ trimSuffix "*" . | regexQuoteMeta | replace "\\" "\\\\" }}.*)"
  from: {{ $.from }}
{{- else }}
- tag_name: "k8s.{{ $.from }}.label.{{ . }}"
  key: {{ . | quote }}
  from: {{ $.from }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Label attributes removed for .signal ("metrics" or "logs"), as JSON
{"prefixes": [...], "keys": [...]}: the recommended exclusions when
recommendedExclusions is true, plus the exclude entries.
*/}}
{{- define "otel-container-insights.labelRemovals" -}}
{{- $node := include "otel-container-insights.labelSettings" (dict "Values" .Values "signal" .signal "kind" "nodeLabels") | fromJson }}
{{- $pod := include "otel-container-insights.labelSettings" (dict "Values" .Values "signal" .signal "kind" "podLabels") | fromJson }}
{{- $prefixes := list }}
{{- $keys := list }}
{{- if $node.recommendedExclusions }}
{{- $prefixes = concat $prefixes (list
  "k8s.node.label.feature.node.kubernetes.io/"
  "k8s.node.label.beta.kubernetes.io/"
  "k8s.node.label.failure-domain.beta.kubernetes.io/"
  "k8s.node.label.alpha.eksctl.io/") }}
{{- $keys = concat $keys (list
  "k8s.node.label.topology.kubernetes.io/region"
  "k8s.node.label.topology.kubernetes.io/zone"
  "k8s.node.label.topology.ebs.csi.aws.com/zone"
  "k8s.node.label.node.kubernetes.io/instance-type"
  "k8s.node.label.kubernetes.io/hostname"
  "k8s.node.label.helm.sh/chart"
  "k8s.node.label.release"
  "k8s.node.label.eks.amazonaws.com/nodegroup-image"
  "k8s.node.label.k8s.io/cloud-provider-aws"
  "k8s.node.label.eks.amazonaws.com/sourceLaunchTemplateId"
  "k8s.node.label.eks.amazonaws.com/sourceLaunchTemplateVersion") }}
{{- end }}
{{- range $node.exclude }}
{{- if hasSuffix "*" . }}
{{- $prefixes = append $prefixes (printf "k8s.node.label.%s" (trimSuffix "*" .)) }}
{{- else }}
{{- $keys = append $keys (printf "k8s.node.label.%s" .) }}
{{- end }}
{{- end }}
{{- if $pod.recommendedExclusions }}
{{- $keys = concat $keys (list
  "k8s.pod.label.pod-template-hash"
  "k8s.pod.label.controller-revision-hash") }}
{{- end }}
{{- range $pod.exclude }}
{{- if hasSuffix "*" . }}
{{- $prefixes = append $prefixes (printf "k8s.pod.label.%s" (trimSuffix "*" .)) }}
{{- else }}
{{- $keys = append $keys (printf "k8s.pod.label.%s" .) }}
{{- end }}
{{- end }}
{{- dict "prefixes" (uniq $prefixes) "keys" (uniq $keys) | toJson }}
{{- end -}}

{{/*
"true" when logs have label exclusions, so the logs label processor is defined
and added to the application and host logs pipelines.
*/}}
{{- define "otel-container-insights.logsLabelFilterEnabled" -}}
{{- $removals := include "otel-container-insights.labelRemovals" (dict "Values" .Values "signal" "logs") | fromJson }}
{{- if or $removals.prefixes $removals.keys }}true{{ end }}
{{- end -}}

{{/*
The transform processor that removes the logs label exclusions from the
resource attributes of log records.
*/}}
{{- define "otel-container-insights.logsLabelFilter" -}}
{{- $removals := include "otel-container-insights.labelRemovals" (dict "Values" .Values "signal" "logs") | fromJson }}
transform/cw_k8s_ci_v0_logs_labels:
  error_mode: ignore
  log_statements:
    - context: resource
      statements:
        {{- range $removals.prefixes }}
        - delete_matching_keys(attributes, "^{{ regexQuoteMeta . | replace "\\" "\\\\" }}")
        {{- end }}
        {{- range $removals.keys }}
        - delete_key(attributes, "{{ . }}")
        {{- end }}
{{- end -}}
