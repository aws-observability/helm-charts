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
{{- if not (has $key (list "namespaces" "metricNames" "nodeLabels" "podLabels")) }}
{{- fail (printf "otelFilters has an unknown key %q (allowed: namespaces, metricNames, nodeLabels, podLabels)" $key) }}
{{- end }}
{{- end }}
{{- include "otel-container-insights.validate-include-exclude" (dict
      "value" (index ($filters | default dict) "namespaces")
      "path" "otelFilters.namespaces"
      "what" "a namespace name"
      "regex" "^([a-z0-9]([-a-z0-9]*[a-z0-9])?|[a-z0-9][-a-z0-9]*\\*|\\*)$"
      "maxLength" 63) }}
{{- include "otel-container-insights.validate-include-exclude" (dict
      "value" (index ($filters | default dict) "metricNames")
      "path" "otelFilters.metricNames"
      "what" "a metric name"
      "regex" "^([A-Za-z0-9_:.]+\\*?|\\*)$") }}
{{- range $kind := list "nodeLabels" "podLabels" }}
{{- $labels := index ($filters | default dict) $kind }}
{{- if not (or (kindIs "invalid" $labels) (kindIs "map" $labels)) }}
{{- fail (printf "otelFilters.%s must be a map with include, exclude and recommendedExclusions" $kind) }}
{{- end }}
{{- range $key, $_ := $labels }}
{{- if not (has $key (list "include" "exclude" "recommendedExclusions")) }}
{{- fail (printf "otelFilters.%s has an unknown key %q (allowed: include, exclude, recommendedExclusions)" $kind $key) }}
{{- end }}
{{- end }}
{{- $recommended := index ($labels | default dict) "recommendedExclusions" }}
{{- if not (or (kindIs "invalid" $recommended) (kindIs "bool" $recommended)) }}
{{- fail (printf "otelFilters.%s.recommendedExclusions must be a boolean (true/false)" $kind) }}
{{- end }}
{{- range $list := list "include" "exclude" }}
{{- $entries := index ($labels | default dict) $list }}
{{- if not (or (kindIs "invalid" $entries) (kindIs "slice" $entries)) }}
{{- fail (printf "otelFilters.%s.%s must be a list" $kind $list) }}
{{- end }}
{{- /* A label key is an optional DNS subdomain prefix and "/", then a name; a "*" entry may stop anywhere in it. */}}
{{- $domain := "[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*" }}
{{- $exact := printf "^(%s/)?[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$" $domain }}
{{- $prefix := printf "^((%s/)?[A-Za-z0-9][-A-Za-z0-9_.]*|%s/)\\*$" $domain $domain }}
{{- range $entries }}
{{- if not (and (kindIs "string" .) (or (eq . "*") (regexMatch $exact .) (regexMatch $prefix .))) }}
{{- fail (printf "otelFilters.%s entries must be a label key, a prefix ending in *, or *, got: %v" $kind .) }}
{{- end }}
{{- $parts := splitList "/" (trimSuffix "*" .) }}
{{- if or (gt (len (last $parts)) 63) (and (eq (len $parts) 2) (gt (len (first $parts)) 253)) }}
{{- fail (printf "otelFilters.%s entries must have a name of at most 63 characters and a prefix of at most 253, got: %s" $kind .) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Validates an include/exclude filter at .path: .value must be unset or a map
with only include and exclude keys, each unset or a list of strings matching
.regex (described as .what in the error), and no entry in both lists. With
.maxLength, an entry without its trailing * may be at most that many characters.
*/}}
{{- define "otel-container-insights.validate-include-exclude" -}}
{{- $value := .value }}
{{- if not (or (kindIs "invalid" $value) (kindIs "map" $value)) }}
{{- fail (printf "%s must be a map with include and exclude lists" .path) }}
{{- end }}
{{- range $key, $_ := $value | default dict }}
{{- if not (has $key (list "include" "exclude")) }}
{{- fail (printf "%s has an unknown key %q (allowed: include, exclude)" $.path $key) }}
{{- end }}
{{- end }}
{{- range $list := list "include" "exclude" }}
{{- $entries := index ($value | default dict) $list }}
{{- if not (or (kindIs "invalid" $entries) (kindIs "slice" $entries)) }}
{{- fail (printf "%s.%s must be a list" $.path $list) }}
{{- end }}
{{- range $entries }}
{{- if not (and (kindIs "string" .) (regexMatch $.regex .)) }}
{{- fail (printf "%s entries must be %s, a prefix ending in *, or *, got: %v" $.path $.what .) }}
{{- end }}
{{- if and $.maxLength (gt (len (trimSuffix "*" .)) (int $.maxLength)) }}
{{- fail (printf "%s entries must be at most %d characters, got: %s" $.path (int $.maxLength) .) }}
{{- end }}
{{- end }}
{{- end }}
{{- $exclude := index ($value | default dict) "exclude" | default list }}
{{- range index ($value | default dict) "include" | default list }}
{{- if has . $exclude }}
{{- fail (printf "%s: %q is in both include and exclude" $.path .) }}
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

{{/*
JSON list of OTTL metric conditions for otelFilters.metricNames, which applies
to the Container Insights metrics only. A metric matching any condition is
dropped. An include list containing "*" includes everything, so it adds no
condition. A duplicate entry renders once.
*/}}
{{- define "otel-container-insights.metricNamesConditions" -}}
{{- $metricNames := index (.Values.otelFilters | default dict) "metricNames" | default dict }}
{{- $include := index $metricNames "include" | default list | uniq }}
{{- $exclude := index $metricNames "exclude" | default list | uniq }}
{{- $conditions := list }}
{{- if and $include (not (has "*" $include)) }}
{{- $conditions = append $conditions (printf "not %s" (include "otel-container-insights.filterMatch" (dict "path" "name" "entries" $include))) }}
{{- end }}
{{- if $exclude }}
{{- $conditions = append $conditions (include "otel-container-insights.filterMatch" (dict "path" "name" "entries" $exclude)) }}
{{- end }}
{{- toJson $conditions }}
{{- end -}}

{{/*
Filter processor that drops metrics by name. Runs last before batch in every
Container Insights metrics pipeline, so it matches the names that are exported.
Renders nothing when no condition applies.
*/}}
{{- define "otel-container-insights.metricNamesFilter" -}}
{{- $conditions := include "otel-container-insights.metricNamesConditions" . | fromJsonArray }}
{{- if $conditions }}
filter/cw_k8s_ci_v0_metric_names:
  error_mode: ignore
  metrics:
    metric:
      {{- range $conditions }}
      - '{{ . }}'
      {{- end }}
{{- end }}
{{- end -}}

{{/*
"true" when the metric name filter processor is defined and added to pipelines.
*/}}
{{- define "otel-container-insights.metricNamesFilterEnabled" -}}
{{- if include "otel-container-insights.metricNamesConditions" . | fromJsonArray }}true{{ end }}
{{- end -}}

{{- define "otel-container-insights.logsNamespaceFilterEnabled" -}}
{{- include "otel-container-insights.metricsNamespaceFilterEnabled" . }}
{{- end -}}

{{/*
The node or pod (.kind: "nodeLabels" or "podLabels") label settings in
otelFilters with defaults applied, as JSON
{"include": [...], "named": [...], "exclude": [...], "recommendedExclusions": bool}.
Metrics and logs share these settings.
- include is ["*"] when it is empty or contains "*", since both mean every
  label. Duplicate entries are removed.
- named is the include entries other than "*", also when include contains
  "*". A named entry keeps a label that is on the built-in list.
- A missing or null recommendedExclusions is true, the values.yaml default,
  so a null otelFilters or label section renders like the defaults. Keep the
  two in sync.
*/}}
{{- define "otel-container-insights.labelSettings" -}}
{{- $labels := index (.Values.otelFilters | default dict) .kind | default dict }}
{{- $include := index $labels "include" | default list | uniq }}
{{- $named := without $include "*" }}
{{- if or (not $include) (has "*" $include) }}
{{- $include = list "*" }}
{{- end }}
{{- $recommended := index $labels "recommendedExclusions" }}
{{- if kindIs "invalid" $recommended }}
{{- $recommended = true }}
{{- end }}
{{- dict "include" $include "named" $named "exclude" (index $labels "exclude" | default list | uniq) "recommendedExclusions" $recommended | toJson }}
{{- end -}}

{{/*
Labels that the chart's own processors read, as JSON {"node": [...], "pod": [...]}:
the topology labels set cloud.region and cloud.availability_zone, and the KServe
InferenceService and component pod labels set the vLLM service.name and the
Knative ai_inference service type. An include list that leaves one out still
extracts it, and it is removed after those processors run.
*/}}
{{- define "otel-container-insights.chartLabels" -}}
{{- dict "node" (list "topology.kubernetes.io/zone") "pod" (list "topology.kubernetes.io/region" "topology.kubernetes.io/zone" "serving.kserve.io/inferenceservice" "component") | toJson }}
{{- end -}}

{{/*
Non-empty when the include list .include, as returned by labelSettings,
covers the label key .key.
*/}}
{{- define "otel-container-insights.labelIncluded" -}}
{{- range .include }}
{{- if or (eq . "*") (eq . $.key) (and (hasSuffix "*" .) (hasPrefix (trimSuffix "*" .) $.key)) }}true{{ end }}
{{- end }}
{{- end -}}

{{/*
k8sattributes label extraction rules for the node or pod (.from) labels, from
the include list that metrics and logs share. "*" extracts all labels; the
$$$1 in tag_name is copied unchanged from the extract-all rule this helper
replaced, and renders as the literal text $$$1.
*/}}
{{- define "otel-container-insights.k8sattributesLabels" -}}
{{- $labels := include "otel-container-insights.labelSettings" (dict "Values" .Values "kind" (printf "%sLabels" .from)) | fromJson }}
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
{{- range index (include "otel-container-insights.chartLabels" . | fromJson) .from }}
{{- if not (include "otel-container-insights.labelIncluded" (dict "include" $labels.include "key" .)) }}
- tag_name: "k8s.{{ $.from }}.label.{{ . }}"
  key: {{ . | quote }}
  from: {{ $.from }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
The built-in list of high-cardinality labels that recommendedExclusions
removes, as JSON {"node": {"prefixes": [...], "keys": [...]}, "pod": {...}}.
The entries are label keys. A prefix entry matches every key that starts with it.
*/}}
{{- define "otel-container-insights.recommendedExclusions" -}}
{{- /* Not the whole karpenter.k8s.aws/instance- prefix: instance-tenancy is a launch property, so it is kept. */}}
{{- dict
  "node" (dict
    "prefixes" (list
      "feature.node.kubernetes.io/"
      "beta.kubernetes.io/"
      "failure-domain.beta.kubernetes.io/"
      "alpha.eksctl.io/"
      "karpenter.k8s.aws/instance-cpu"
      "karpenter.k8s.aws/instance-gpu-"
      "karpenter.k8s.aws/instance-accelerator-"
      "eks.amazonaws.com/instance-")
    "keys" (list
      "topology.kubernetes.io/region"
      "topology.kubernetes.io/zone"
      "topology.ebs.csi.aws.com/zone"
      "node.kubernetes.io/instance-type"
      "kubernetes.io/hostname"
      "helm.sh/chart"
      "release"
      "eks.amazonaws.com/nodegroup-image"
      "k8s.io/cloud-provider-aws"
      "eks.amazonaws.com/sourceLaunchTemplateId"
      "eks.amazonaws.com/sourceLaunchTemplateVersion"
      "karpenter.sh/do-not-sync-taints"
      "karpenter.sh/initialized"
      "karpenter.sh/registered"
      "karpenter.k8s.aws/instance-category"
      "karpenter.k8s.aws/instance-family"
      "karpenter.k8s.aws/instance-generation"
      "karpenter.k8s.aws/instance-size"
      "karpenter.k8s.aws/instance-memory"
      "karpenter.k8s.aws/instance-hypervisor"
      "karpenter.k8s.aws/instance-local-nvme"
      "karpenter.k8s.aws/instance-ebs-bandwidth"
      "karpenter.k8s.aws/instance-network-bandwidth"
      "karpenter.k8s.aws/instance-encryption-in-transit-supported"
      "karpenter.k8s.aws/instance-capability-flex"))
  "pod" (dict
    "prefixes" (list)
    "keys" (list
      "pod-template-hash"
      "controller-revision-hash"
      "pod-template-generation"
      "topology.kubernetes.io/region"
      "topology.kubernetes.io/zone"))
  | toJson }}
{{- end -}}

{{/*
Label attributes removed from metrics and logs, as JSON
{"prefixes": [...], "keys": [...], "exceptions": [{"prefix": "...", "keep": [...]}]}.
For each label, exclude wins over a named include entry, and a named include
entry wins over the built-in list. So the lists hold:
- The built-in list, when recommendedExclusions is true, less the labels that
  a named include entry covers. A built-in key is left out when a named entry
  is the same key or a prefix of it. A built-in prefix is left out when a
  named prefix is a prefix of it. A built-in prefix with named entries inside
  it (a key or a longer prefix) moves to exceptions, with those entries in
  keep, because awsattributelimit cannot remove a prefix except some keys.
- The exclude entries.
- The chart's labels that the include list leaves out.
A keep entry is an attribute key, or an attribute key prefix followed by *.
*/}}
{{- define "otel-container-insights.labelRemovals" -}}
{{- $recommended := include "otel-container-insights.recommendedExclusions" . | fromJson }}
{{- $prefixes := list }}
{{- $keys := list }}
{{- $exceptions := list }}
{{- $settings := dict }}
{{- range $kind := list "node" "pod" }}
{{- $labels := include "otel-container-insights.labelSettings" (dict "Values" $.Values "kind" (printf "%sLabels" $kind)) | fromJson }}
{{- $_ := set $settings $kind $labels }}
{{- $attribute := printf "k8s.%s.label." $kind }}
{{- if $labels.recommendedExclusions }}
{{- $builtin := index $recommended $kind }}
{{- range $prefix := $builtin.prefixes }}
{{- $covered := false }}
{{- $keep := list }}
{{- range $labels.named }}
{{- if and (hasSuffix "*" .) (hasPrefix (trimSuffix "*" .) $prefix) }}
{{- $covered = true }}
{{- else if hasPrefix $prefix (trimSuffix "*" .) }}
{{- $keep = append $keep (printf "%s%s" $attribute .) }}
{{- end }}
{{- end }}
{{- if $covered }}
{{- else if $keep }}
{{- $exceptions = append $exceptions (dict "prefix" (printf "%s%s" $attribute $prefix) "keep" $keep) }}
{{- else }}
{{- $prefixes = append $prefixes (printf "%s%s" $attribute $prefix) }}
{{- end }}
{{- end }}
{{- range $builtin.keys }}
{{- if not (include "otel-container-insights.labelIncluded" (dict "include" $labels.named "key" .)) }}
{{- $keys = append $keys (printf "%s%s" $attribute .) }}
{{- end }}
{{- end }}
{{- end }}
{{- range $labels.exclude }}
{{- if hasSuffix "*" . }}
{{- $prefixes = append $prefixes (printf "%s%s" $attribute (trimSuffix "*" .)) }}
{{- else }}
{{- $keys = append $keys (printf "%s%s" $attribute .) }}
{{- end }}
{{- end }}
{{- end }}
{{- $chartLabels := include "otel-container-insights.chartLabels" . | fromJson }}
{{- range $kind := list "node" "pod" }}
{{- range index $chartLabels $kind }}
{{- if not (include "otel-container-insights.labelIncluded" (dict "include" (index $settings $kind).include "key" .)) }}
{{- $keys = append $keys (printf "k8s.%s.label.%s" $kind .) }}
{{- end }}
{{- end }}
{{- end }}
{{- dict "prefixes" (uniq $prefixes) "keys" (uniq $keys) "exceptions" $exceptions | toJson }}
{{- end -}}

{{/*
OTTL statements, in a resource context, that remove the attributes under each
prefix in .exceptions (from labelRemovals) except the keep entries: copy the
attributes to the cache, keep only the keep entries in the copy, delete the
prefixes from the attributes, and merge the copy back. Renders nothing when
there are no exceptions.
*/}}
{{- define "otel-container-insights.labelExceptionStatements" -}}
{{- if .exceptions }}
{{- $keep := list }}
{{- range .exceptions }}
{{- range .keep }}
{{- $quoted := trimSuffix "*" . | regexQuoteMeta | replace "\\" "\\\\" }}
{{- $keep = append $keep (ternary $quoted (printf "%s$" $quoted) (hasSuffix "*" .)) }}
{{- end }}
{{- end }}
- set(cache["kept_labels"], attributes)
- keep_matching_keys(cache["kept_labels"], "^({{ join "|" $keep }})")
{{- range .exceptions }}
- delete_matching_keys(attributes, "^{{ regexQuoteMeta .prefix | replace "\\" "\\\\" }}")
{{- end }}
- merge_maps(attributes, cache["kept_labels"], "upsert")
{{- end }}
{{- end -}}

{{/*
"true" when labelRemovals has exceptions, so the metrics label processor is
defined and added before awsattributelimit/cw_k8s_ci_v0 in every metrics
pipeline of both agents.
*/}}
{{- define "otel-container-insights.metricsLabelFilterEnabled" -}}
{{- $removals := include "otel-container-insights.labelRemovals" (dict "Values" .Values) | fromJson }}
{{- if $removals.exceptions }}true{{ end }}
{{- end -}}

{{/*
The transform processor that removes the exception prefixes of labelRemovals
from the resource attributes of metrics, except the keep entries.
awsattributelimit/cw_k8s_ci_v0 removes the other labels.
*/}}
{{- define "otel-container-insights.metricsLabelFilter" -}}
{{- $removals := include "otel-container-insights.labelRemovals" (dict "Values" .Values) | fromJson }}
transform/cw_k8s_ci_v0_metrics_labels:
  error_mode: ignore
  metric_statements:
    - context: resource
      statements:
        {{- include "otel-container-insights.labelExceptionStatements" $removals | trim | nindent 8 }}
{{- end -}}

{{/*
"true" when there are label removals, so the logs label processor is defined
and added to the application and host logs pipelines.
*/}}
{{- define "otel-container-insights.logsLabelFilterEnabled" -}}
{{- $removals := include "otel-container-insights.labelRemovals" (dict "Values" .Values) | fromJson }}
{{- if or $removals.prefixes $removals.keys $removals.exceptions }}true{{ end }}
{{- end -}}

{{/*
The transform processor that deletes the labelRemovals attributes from the
resource attributes of log records. The exception statements run first, so
the exclude entries still remove a kept entry.
*/}}
{{- define "otel-container-insights.logsLabelFilter" -}}
{{- $removals := include "otel-container-insights.labelRemovals" (dict "Values" .Values) | fromJson }}
transform/cw_k8s_ci_v0_logs_labels:
  error_mode: ignore
  log_statements:
    - context: resource
      statements:
        {{- with include "otel-container-insights.labelExceptionStatements" $removals | trim }}
        {{- . | nindent 8 }}
        {{- end }}
        {{- range $removals.prefixes }}
        - delete_matching_keys(attributes, "^{{ regexQuoteMeta . | replace "\\" "\\\\" }}")
        {{- end }}
        {{- range $removals.keys }}
        - delete_key(attributes, "{{ . }}")
        {{- end }}
{{- end -}}
