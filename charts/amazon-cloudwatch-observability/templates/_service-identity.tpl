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
*/}}

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
{{- $r := "resource.attributes" }}
{{- $tmp := "_tmp.service_identity." }}
{{- $useAppLabels := .Values.otelServiceIdentity.useAppLabels }}
{{- $statements := list
  (printf "set(%s[\"%sunknown_service\"], %s[\"service.name\"]) where IsMatch(%s[\"service.name\"], \"^unknown_service\")" $r $tmp $r $r)
  (printf "delete_key(%s, \"service.name\") where IsMatch(%s[\"service.name\"], \"^unknown_service\")" $r $r) }}
{{- $sources := list (printf "%s[\"%sannotation.service.name\"]" $r $tmp) }}
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
{{- $statements = concat $statements (list
  (printf "set(%s[\"service.instance.id\"], %s[\"%sannotation.service.instance.id\"]) where %s[\"service.instance.id\"] == nil and %s[\"%sannotation.service.instance.id\"] != nil" $r $r $tmp $r $r $tmp)
  (printf "set(%s[\"service.instance.id\"], Concat([%s[\"k8s.namespace.name\"], %s[\"k8s.pod.name\"], %s[\"k8s.container.name\"]], \".\")) where %s[\"service.instance.id\"] == nil and %s[\"k8s.namespace.name\"] != nil and %s[\"k8s.pod.name\"] != nil and %s[\"k8s.container.name\"] != nil" $r $r $r $r $r $r $r $r)
  (printf "set(%s[\"deployment.environment.name\"], Concat([%s[\"cloud.platform\"], Concat([%s[\"k8s.cluster.name\"], %s[\"k8s.namespace.name\"]], \"/\")], \":\")) where %s[\"deployment.environment.name\"] == nil and %s[\"cloud.platform\"] != nil and %s[\"k8s.cluster.name\"] != nil and %s[\"k8s.namespace.name\"] != nil" $r $r $r $r $r $r $r $r)
  (printf "delete_matching_keys(%s, \"^_tmp\\\\.service_identity\\\\.\")" $r)) }}
{{- toJson $statements }}
{{- end -}}

{{/* The transform processor that applies the chain to metrics, logs, traces and profiles. */}}
{{- define "service-identity.processor" -}}
{{- $statements := include "service-identity.statements" . | fromJsonArray }}
transform/cw_k8s_service_identity:
  error_mode: ignore
  {{- range $group := list "metric_statements" "log_statements" "trace_statements" "profile_statements" }}
  {{ $group }}:
    - context: resource
      statements:
        {{- range $statements }}
        - {{ . | squote }}
        {{- end }}
  {{- end }}
{{- end -}}
