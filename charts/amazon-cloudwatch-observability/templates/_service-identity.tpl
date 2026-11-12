{{/*
Service identity (service.name, service.namespace, service.version,
service.instance.id, deployment.environment.name) for every chart pipeline
that sets it.

The chain follows the OpenTelemetry semantic conventions for Kubernetes
("how service.name should be calculated" and "how service.instance.id should
be calculated", https://opentelemetry.io/docs/specs/semconv/non-normative/k8s-attributes/)
and design rule DR-0001 in the CloudWatch agent design registry:

1. the value the sender set, except a service.name starting with
   unknown_service (the SDK default), which counts as not set;
2. the resource.opentelemetry.io/service.* pod annotations, always;
3. the app.kubernetes.io/instance and app.kubernetes.io/name pod labels (and
   app.kubernetes.io/version for service.version), only with
   otelServiceIdentity.useAppLabels, because the convention asks for an
   opt-in: all pods of one Helm release usually share
   app.kubernetes.io/instance;
4. the workload chain: Deployment, ReplicaSet, StatefulSet, DaemonSet,
   CronJob, Job, pod, container;
5. the sender's unknown_service value, when nothing else is found.

This file is the only place the chain is written. A pipeline that needs
service identity includes service-identity.processor and extracts the
annotations and labels with service-identity.extractAnnotations and
service-identity.extractLabels, so that the setting means the same for every
signal and a change to the chain is reviewed once. A second copy of the chain
is a DR-0001 review finding.

The extracted annotations and labels are held in _tmp.service_identity.*
resource attributes, which the processor removes at the end.

service-identity.processor and service-identity.statements take either the
root context (the OTLP endpoint) or a dict with:

- Values: the chart values (required);
- name: the processor name (default transform/cw_k8s_service_identity);
- groups: the statement groups (default metric_statements, log_statements,
  trace_statements, profile_statements);
- inputs: names of further service.name inputs, from
  service-identity.namedInputs, used after the annotation and before the app
  labels (default none);
- receiverDefault: true when the pipeline's receiver sets service.name and
  service.instance.id itself, as the Prometheus receiver does with the scrape
  job name and target address. Both then count as not set. The receiver's
  service.name, held in _tmp.service_identity.unknown_service, is used only
  when nothing else is found. The receiver's service.instance.id is restored
  only where service.name ended up as that job name, because the target
  identifies the scraped job and nothing else. Elsewhere service.instance.id
  is the annotation or <namespace>.<pod>.<container>, or is not set, as the
  OpenTelemetry convention asks when the instance is not known (default
  false).
*/}}

{{/*
The named service.name inputs a caller can add to the chain, as JSON
{name: resource attribute}. kserveInferenceService is KServe's own
serving.kserve.io/inferenceservice pod label, as the Container Insights pod
k8sattributes extracts it (otel-container-insights.chartLabels).
*/}}
{{- define "service-identity.namedInputs" -}}
{{- dict "kserveInferenceService" "k8s.pod.label.serving.kserve.io/inferenceservice" | toJson }}
{{- end -}}

{{/* The parameters of service-identity.processor, with defaults, as JSON. */}}
{{- define "service-identity.params" -}}
{{- $p := dict "name" "transform/cw_k8s_service_identity" "groups" (list "metric_statements" "log_statements" "trace_statements" "profile_statements") "inputs" (list) "receiverDefault" false }}
{{- $_ := set $p "useAppLabels" .Values.otelServiceIdentity.useAppLabels }}
{{- /* The root context (it has .Release) takes the defaults. */}}
{{- if not (hasKey . "Release") }}
{{- range $key := list "name" "groups" "inputs" "receiverDefault" }}
{{- if hasKey $ $key }}
{{- $_ := set $p $key (index $ $key) }}
{{- end }}
{{- end }}
{{- end }}
{{- $named := include "service-identity.namedInputs" . | fromJson }}
{{- range $p.inputs }}
{{- if not (hasKey $named .) }}
{{- fail (printf "service-identity: unknown input %q" .) }}
{{- end }}
{{- end }}
{{- toJson $p }}
{{- end -}}

{{/* Validates otelServiceIdentity. */}}
{{- define "service-identity.validate" -}}
{{- $identity := .Values.otelServiceIdentity }}
{{- if not (kindIs "map" $identity) }}
{{- fail "otelServiceIdentity must be a map with useAppLabels" }}
{{- end }}
{{- range $key, $_ := $identity }}
{{- if ne $key "useAppLabels" }}
{{- fail (printf "otelServiceIdentity has an unknown key %q (allowed: useAppLabels)" $key) }}
{{- end }}
{{- end }}
{{- if not (kindIs "bool" $identity.useAppLabels) }}
{{- fail "otelServiceIdentity.useAppLabels must be a boolean (true/false)" }}
{{- end }}
{{- end -}}

{{/* k8sattributes extract.annotations entries for the service.* pod annotations. */}}
{{- define "service-identity.extractAnnotations" -}}
{{- range list "service.name" "service.namespace" "service.version" "service.instance.id" }}
- tag_name: "_tmp.service_identity.annotation.{{ . }}"
  key: "resource.opentelemetry.io/{{ . }}"
  from: pod
{{- end }}
{{- end -}}

{{/* k8sattributes extract.labels entries for the app.kubernetes.io labels; empty unless otelServiceIdentity.useAppLabels. */}}
{{- define "service-identity.extractLabels" -}}
{{- if .Values.otelServiceIdentity.useAppLabels }}
{{- range list "instance" "name" "version" }}
- tag_name: "_tmp.service_identity.label.app.kubernetes.io/{{ . }}"
  key: "app.kubernetes.io/{{ . }}"
  from: pod
{{- end }}
{{- end }}
{{- end -}}

{{/* The OTTL statements of the chain, in a resource context, as a JSON list. */}}
{{- define "service-identity.statements" -}}
{{- $p := include "service-identity.params" . | fromJson }}
{{- $r := "resource.attributes" }}
{{- $tmp := "_tmp.service_identity." }}
{{- $useAppLabels := $p.useAppLabels }}
{{- /* The sender's default: unknown_service*, or with receiverDefault any value the receiver set. */}}
{{- $isDefault := printf "IsMatch(%s[\"service.name\"], \"^unknown_service\")" $r }}
{{- if $p.receiverDefault }}
{{- $isDefault = printf "%s[\"service.name\"] != nil" $r }}
{{- end }}
{{- $statements := list
  (printf "set(%s[\"%sunknown_service\"], %s[\"service.name\"]) where %s" $r $tmp $r $isDefault)
  (printf "delete_key(%s, \"service.name\") where %s" $r $isDefault) }}
{{- $sources := list (printf "%s[\"%sannotation.service.name\"]" $r $tmp) }}
{{- $named := include "service-identity.namedInputs" . | fromJson }}
{{- range $p.inputs }}
{{- $sources = append $sources (printf "%s[\"%s\"]" $r (index $named .)) }}
{{- end }}
{{- if $useAppLabels }}
{{- $sources = concat $sources (list
  (printf "%s[\"%slabel.app.kubernetes.io/instance\"]" $r $tmp)
  (printf "%s[\"%slabel.app.kubernetes.io/name\"]" $r $tmp)) }}
{{- end }}
{{- range list "deployment" "replicaset" "statefulset" "daemonset" "cronjob" "job" "pod" "container" }}
{{- $sources = append $sources (printf "%s[\"k8s.%s.name\"]" $r .) }}
{{- end }}
{{- $sources = append $sources (printf "%s[\"%sunknown_service\"]" $r $tmp) }}
{{- range $sources }}
{{- $statements = append $statements (printf "set(%s[\"service.name\"], %s) where %s[\"service.name\"] == nil and %s != nil" $r . $r .) }}
{{- end }}
{{- $fallbacks := dict "service.namespace" (list (printf "%s[\"k8s.namespace.name\"]" $r)) "service.version" (list) }}
{{- if $useAppLabels }}
{{- $_ := set $fallbacks "service.version" (list (printf "%s[\"%slabel.app.kubernetes.io/version\"]" $r $tmp)) }}
{{- end }}
{{- range $key, $fallback := $fallbacks }}
{{- range prepend $fallback (printf "%s[\"%sannotation.%s\"]" $r $tmp $key) }}
{{- $statements = append $statements (printf "set(%s[\"%s\"], %s) where %s[\"%s\"] == nil and %s != nil" $r $key . $r $key .) }}
{{- end }}
{{- end }}
{{- if $p.receiverDefault }}
{{- $statements = concat $statements (list
  (printf "set(%s[\"%sreceiver.service.instance.id\"], %s[\"service.instance.id\"]) where %s[\"service.instance.id\"] != nil" $r $tmp $r $r)
  (printf "delete_key(%s, \"service.instance.id\")" $r)) }}
{{- end }}
{{- $statements = concat $statements (list
  (printf "set(%s[\"service.instance.id\"], %s[\"%sannotation.service.instance.id\"]) where %s[\"service.instance.id\"] == nil and %s[\"%sannotation.service.instance.id\"] != nil" $r $r $tmp $r $r $tmp)
  (printf "set(%s[\"service.instance.id\"], Concat([%s[\"k8s.namespace.name\"], %s[\"k8s.pod.name\"], %s[\"k8s.container.name\"]], \".\")) where %s[\"service.instance.id\"] == nil and %s[\"k8s.namespace.name\"] != nil and %s[\"k8s.pod.name\"] != nil and %s[\"k8s.container.name\"] != nil" $r $r $r $r $r $r $r $r)) }}
{{- if $p.receiverDefault }}
{{- /* After every service.name statement, including the restore of the job name. */}}
{{- $statements = append $statements (printf "set(%s[\"service.instance.id\"], %s[\"%sreceiver.service.instance.id\"]) where %s[\"service.instance.id\"] == nil and %s[\"service.name\"] == %s[\"%sunknown_service\"] and %s[\"%sreceiver.service.instance.id\"] != nil" $r $r $tmp $r $r $r $tmp $r $tmp) }}
{{- end }}
{{- $statements = concat $statements (list
  (printf "set(%s[\"deployment.environment.name\"], Concat([%s[\"cloud.platform\"], Concat([%s[\"k8s.cluster.name\"], %s[\"k8s.namespace.name\"]], \"/\")], \":\")) where %s[\"deployment.environment.name\"] == nil and %s[\"cloud.platform\"] != nil and %s[\"k8s.cluster.name\"] != nil and %s[\"k8s.namespace.name\"] != nil" $r $r $r $r $r $r $r $r)
  (printf "delete_matching_keys(%s, \"^_tmp\\\\.service_identity\\\\.\")" $r)) }}
{{- toJson $statements }}
{{- end -}}

{{/*
A metrics transform processor named .name that only removes the
_tmp.service_identity.* inputs, for a pipeline that shares a k8sattributes
processor with the chain but does not apply it.
*/}}
{{- define "service-identity.dropInputs" -}}
{{ .name }}:
  error_mode: ignore
  metric_statements:
    - context: resource
      statements:
        - 'delete_matching_keys(resource.attributes, "^_tmp\\.service_identity\\.")'
{{- end -}}

{{/* The transform processor that applies the chain, by default to metrics, logs, traces and profiles. */}}
{{- define "service-identity.processor" -}}
{{- $p := include "service-identity.params" . | fromJson }}
{{- $statements := include "service-identity.statements" . | fromJsonArray }}
{{ $p.name }}:
  error_mode: ignore
  {{- range $group := $p.groups }}
  {{ $group }}:
    - context: resource
      statements:
        {{- range $statements }}
        - {{ . | squote }}
        {{- end }}
  {{- end }}
{{- end -}}
