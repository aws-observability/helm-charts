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
{{- if not (has $key (list "namespaces")) }}
{{- fail (printf "otelContainerInsights.filters.%s has an unknown key %q (allowed: namespaces)" $signal $key) }}
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
