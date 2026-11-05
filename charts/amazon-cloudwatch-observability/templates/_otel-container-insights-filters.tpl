{{/*
Customer filters for the OTEL Container Insights pipelines (otelFilters):
validation, and the translation of the filter values into OTel processors.
*/}}

{{/*
Validates otelFilters. Called from cloudwatch-agent.validate-flags, so an
invalid value fails the render before any entry reaches a template.
*/}}
{{- define "otel-container-insights.validate-filters" -}}
{{- if hasKey .Values.otelContainerInsights "filters" }}
{{- fail "otelContainerInsights.filters is not supported. Set the filters in the top-level otelFilters block, for example otelFilters.namespaces" }}
{{- end }}
{{- $filters := .Values.otelFilters }}
{{- if not (or (kindIs "invalid" $filters) (kindIs "map" $filters)) }}
{{- fail "otelFilters must be a map" }}
{{- end }}
{{- range $key, $_ := $filters }}
{{- if not (has $key (list "namespaces")) }}
{{- fail (printf "otelFilters has an unknown key %q (allowed: namespaces)" $key) }}
{{- end }}
{{- end }}
{{- $namespaces := index ($filters | default dict) "namespaces" }}
{{- if not (or (kindIs "invalid" $namespaces) (kindIs "map" $namespaces)) }}
{{- fail "otelFilters.namespaces must be a map with include and exclude lists" }}
{{- end }}
{{- range $key, $_ := $namespaces }}
{{- if not (has $key (list "include" "exclude")) }}
{{- fail (printf "otelFilters.namespaces has an unknown key %q (allowed: include, exclude)" $key) }}
{{- end }}
{{- end }}
{{- range $list := list "include" "exclude" }}
{{- $entries := index ($namespaces | default dict) $list }}
{{- if not (or (kindIs "invalid" $entries) (kindIs "slice" $entries)) }}
{{- fail (printf "otelFilters.namespaces.%s must be a list" $list) }}
{{- end }}
{{- range $entries }}
{{- if not (and (kindIs "string" .) (regexMatch "^([a-z0-9]([-a-z0-9]*[a-z0-9])?|[a-z0-9][-a-z0-9]*\\*|\\*)$" .)) }}
{{- fail (printf "otelFilters.namespaces entries must be a namespace name, a prefix ending in *, or *, got: %v" .) }}
{{- end }}
{{- if gt (len (trimSuffix "*" .)) 63 }}
{{- fail (printf "otelFilters.namespaces entries must be at most 63 characters, got: %s" .) }}
{{- end }}
{{- end }}
{{- end }}
{{- $exclude := index ($namespaces | default dict) "exclude" | default list }}
{{- range index ($namespaces | default dict) "include" | default list }}
{{- if has . $exclude }}
{{- fail (printf "otelFilters.namespaces: %q is in both include and exclude" .) }}
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
Conditions of the namespace filter, as a JSON list, for the OTTL path .path of
the record's k8s.namespace.name. A condition is true when the namespace is
filtered out. Every condition requires the namespace, so records without it
never match. An include list containing "*" includes every namespace, so it
adds no condition. A duplicate entry renders once.
*/}}
{{- define "otel-container-insights.namespaceConditionsFor" -}}
{{- $namespaces := index (.Values.otelFilters | default dict) "namespaces" | default dict }}
{{- $include := index $namespaces "include" | default list | uniq }}
{{- $exclude := index $namespaces "exclude" | default list | uniq }}
{{- $path := .path }}
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
Conditions of the namespace filter for a datapoint or log record, which reads
the namespace from its resource. The metrics and the logs filter both use them.
*/}}
{{- define "otel-container-insights.namespaceConditions" -}}
{{- include "otel-container-insights.namespaceConditionsFor" (dict "Values" .Values "path" "resource.attributes[\"k8s.namespace.name\"]") }}
{{- end -}}

{{/*
The namespace filter processor for .signal ("metrics" or "logs"), or nothing
when it has no conditions. The signal picks the processor name and the record
type. The metrics filter is added to every pod and container metrics pipeline,
and the logs filter to the application logs pipeline, before k8sattributes.
The device pipelines (DCGM, Neuron, EFA) use deviceNamespaces instead.
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
The namespace transform of the device pipelines (DCGM, Neuron, EFA), or nothing
when the namespace filter has no conditions. A device belongs to a pod only for
a while, so its metrics are never dropped. When the namespace of the device's
pod is filtered out, the transform removes the pod attributes, and the device
then has its node attributes only, like an unused device. It runs after the
pod grouping, so each resource holds one pod, and before k8sattributes, which
then finds no pod for the resource. The datapoint group runs first, because
it reads the namespace that the resource group deletes. The DCGM datapoints
carry raw pod, namespace and container copies, which it also deletes.
*/}}
{{- define "otel-container-insights.deviceNamespaces" -}}
{{- $datapoint := include "otel-container-insights.namespaceConditions" . | fromJsonArray }}
{{- $resource := include "otel-container-insights.namespaceConditionsFor" (dict "Values" .Values "path" "attributes[\"k8s.namespace.name\"]") | fromJsonArray }}
{{- if $datapoint }}
transform/cw_k8s_ci_v0_device_namespaces:
  error_mode: ignore
  metric_statements:
    - context: datapoint
      conditions:
        {{- range $datapoint }}
        - '{{ . }}'
        {{- end }}
      statements:
        - delete_key(attributes, "pod")
        - delete_key(attributes, "namespace")
        - delete_key(attributes, "container")
    - context: resource
      conditions:
        {{- range $resource }}
        - '{{ . }}'
        {{- end }}
      statements:
        - delete_key(attributes, "k8s.pod.name")
        - delete_key(attributes, "k8s.container.name")
        - delete_key(attributes, "k8s.namespace.name")
{{- end }}
{{- end -}}

{{/*
"true" when the namespace filter has conditions, so the metrics or the logs
filter is defined and added to pipelines. Both read otelFilters.namespaces.
*/}}
{{- define "otel-container-insights.metricsNamespaceFilterEnabled" -}}
{{- if include "otel-container-insights.namespaceConditions" . | fromJsonArray }}true{{ end }}
{{- end -}}

{{- define "otel-container-insights.logsNamespaceFilterEnabled" -}}
{{- include "otel-container-insights.metricsNamespaceFilterEnabled" . }}
{{- end -}}
