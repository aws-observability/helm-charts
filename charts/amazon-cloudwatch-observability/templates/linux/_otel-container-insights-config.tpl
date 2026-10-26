{{- define "otel-container-insights.config" -}}
{{- /* The vLLM config Info metric: signal_to_info_metric/cw_k8s_ci_v0_vllm. */ -}}
{{- $configInfo := eq (include "otel-container-insights.configInfoEnabled" .) "true" -}}
{{- /* Logs-off mode of the Info metric: k8s_observer/cw_k8s_ci_v0_vllm watches the pods of the
node, receiver_creator/cw_k8s_ci_v0_vllm_logs reads only the logs of vLLM containers, and
logs/cw_k8s_ci_v0_vllm_info feeds the connector. With logs on, the connector is a second
exporter of logs/cw_k8s_ci_v0_app instead. */ -}}
{{- $infoLogsOff := and $configInfo (not .Values.otelContainerInsights.logs.enabled) -}}
{{- /* configInfo.pollInterval takes effect only in logs-off mode, but a bad value fails
whenever configInfo is on. */ -}}
{{- if $configInfo -}}
  {{- $_ := include "otel-container-insights.vllmInfoPollInterval" . -}}
{{- end -}}
{{- /* file_storage/cw_k8s_ci_v0_state. */ -}}
{{- $stateStorage := eq (include "otel-container-insights.stateStorageEnabled" .) "true" -}}
{{- /* File checkpoints of filelog/cw_k8s_ci_v0_app in file_storage/cw_k8s_ci_v0_state: only with
an explicit stateStorage.enabled, so that configInfo does not change log shipping. The receiver
renders only with logs on, so the checkpoints do too. */ -}}
{{- $appLogCheckpoints := and $stateStorage .Values.otelContainerInsights.stateStorage.enabled -}}
{{- /* Ray logs: k8s_observer/cw_k8s_ci_v0_ray, receiver_creator/cw_k8s_ci_v0_ray_logs and
logs/cw_k8s_ci_v0_ray. They need logs on, so they never render together with the vLLM logs-off
mode, and the two pod watches never run at the same time. */ -}}
{{- $rayLogs := eq (include "otel-container-insights.rayLogsEnabled" .) "true" -}}
extensions:
  sigv4auth/cw_k8s_ci_v0_metrics_dest:
    region: {{ .Values.region }}
    service: monitoring
{{- if .Values.otelContainerInsights.logs.enabled }}
  sigv4auth/cw_k8s_ci_v0_logs_dest:
    region: {{ .Values.region }}
    service: logs
  awscloudwatchlogsprovisioner/cw_k8s_ci_v0_logs:
    region: {{ .Values.region }}
    additional_auth: sigv4auth/cw_k8s_ci_v0_logs_dest
{{- end }}
{{- if $stateStorage }}
  {{- $stateDir := include "otel-container-insights.stateStorageHostPath" . }}
  # Agent state that must survive a restart: the vLLM config Info metric's facts and,
  # when turned on, the app-log receiver's file checkpoints. One bbolt file per
  # component, in the hostPath the targetAgent DaemonSet mounts read-write at the same path.
  file_storage/cw_k8s_ci_v0_state:
    directory: {{ $stateDir | quote }}
    create_directory: true
    compaction:
      on_start: true
      on_rebound: true
      directory: {{ $stateDir | quote }}
    # A file that bbolt cannot open (corrupted by a node crash) is renamed aside
    # and recreated empty, rather than keeping the agent from starting.
    recreate: true
{{- end }}
{{- if $infoLogsOff }}
  # Logs-off mode of the vLLM config Info metric: one watch on the pods of this node,
  # so that receiver_creator/cw_k8s_ci_v0_vllm_logs starts a log reader for each vLLM
  # container. The other kinds of objects are not watched.
  k8s_observer/cw_k8s_ci_v0_vllm:
    auth_type: serviceAccount
    node: ${env:K8S_NODE_NAME}
    observe_pods: true
    observe_nodes: false
    observe_services: false
    observe_ingresses: false
{{- end }}
{{- if $rayLogs }}
  # Ray logs: one watch on the pods of this node, so that
  # receiver_creator/cw_k8s_ci_v0_ray_logs starts the log readers of each Ray pod.
  # The other kinds of objects are not watched.
  k8s_observer/cw_k8s_ci_v0_ray:
    auth_type: serviceAccount
    node: ${env:K8S_NODE_NAME}
    observe_pods: true
    observe_nodes: false
    observe_services: false
    observe_ingresses: false
{{- end }}

receivers:
{{- if .Values.nodeExporter.enabled }}
  prometheus/cw_k8s_ci_v0_node_exporter:
    config:
      scrape_configs:
        - job_name: node-exporter
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          scheme: https
          tls_config:
            ca_file: /etc/amazon-cloudwatch-observability-agent-client-cert/tls-ca.crt
          static_configs:
            - targets:
                - {{ include "node-exporter.name" . }}-service:9487
{{- end }}

  prometheus/cw_k8s_ci_v0_cadvisor:
    config:
      scrape_configs:
        - job_name: cadvisor
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          scheme: https
          tls_config:
            insecure_skip_verify: true
          bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          metrics_path: /metrics/cadvisor
          static_configs:
            - targets:
                - ${env:HOST_IP}:10250

  {{- if .Values.dcgmExporter.enabled }}
  prometheus/cw_k8s_ci_v0_dcgm:
    config:
      scrape_configs:
        - job_name: dcgm-exporter
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          scheme: https
          tls_config:
            ca_file: /etc/amazon-cloudwatch-observability-agent-client-cert/tls-ca.crt
          static_configs:
            - targets:
                - dcgm-exporter-service:9400
  {{- end }}

  {{- if .Values.neuronMonitor.enabled }}
  prometheus/cw_k8s_ci_v0_neuron:
    config:
      scrape_configs:
        - job_name: neuron-monitor
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          scheme: https
          tls_config:
            ca_file: /etc/amazon-cloudwatch-observability-agent-client-cert/tls-ca.crt
          static_configs:
            - targets:
                - neuron-monitor-service:8000
  {{- end }}

  awsefareceiver/cw_k8s_ci_v0:
    collection_interval: {{ .Values.otelContainerInsights.metricResolution }}

  prometheus/cw_k8s_ci_v0_ebs_csi_node:
    config:
      scrape_configs:
        - job_name: ebs-csi-node
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          kubernetes_sd_configs:
            - role: pod
              namespaces:
                names:
                  - kube-system
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_label_app]
              regex: ebs-csi-node
              action: keep
            - source_labels: [__meta_kubernetes_pod_node_name]
              regex: ${env:K8S_NODE_NAME}
              action: keep
            - source_labels: [__meta_kubernetes_pod_container_port_name]
              regex: metrics
              action: keep

  {{- if and .Values.otelContainerInsights.solutions.enabled .Values.otelContainerInsights.solutions.knative.dataPlane.enabled }}
  # Knative request metrics from the queue-proxy's user-metric port. Keyed on the
  # revision label, so plain Knative Services are covered too. The port serves
  # nothing until request-metrics-protocol is set on Serving >= 1.19.
  prometheus/cw_k8s_ci_v0_knative_dataplane:
    config:
      scrape_configs:
        - job_name: knative-dataplane
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          metrics_path: /metrics
          # Watch only this node's revision pods; both filters run in the API server,
          # so no agent holds pods from other nodes or non-Knative pods.
          kubernetes_sd_configs:
            - role: pod
              {{- if .Values.otelContainerInsights.solutions.knative.dataPlane.namespace }}
              namespaces:
                names:
                  - {{ .Values.otelContainerInsights.solutions.knative.dataPlane.namespace }}
              {{- end }}
              selectors:
                - role: pod
                  field: spec.nodeName=${env:K8S_NODE_NAME}
                  label: serving.knative.dev/revision
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_container_port_name]
              regex: http-usermetric
              action: keep
            - source_labels: [__meta_kubernetes_pod_name]
              target_label: pod
              action: replace
            - source_labels: [__meta_kubernetes_namespace]
              target_label: namespace
              action: replace
  {{- end }}

  prometheus/cw_k8s_ci_v0_lis_csi_node:
    config:
      scrape_configs:
        - job_name: lis-csi-node
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          kubernetes_sd_configs:
            - role: pod
              namespaces:
                names:
                  - kube-system
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_label_app]
              regex: ec2-instance-store-plugin
              action: keep
            - source_labels: [__meta_kubernetes_pod_node_name]
              regex: ${env:K8S_NODE_NAME}
              action: keep
            - source_labels: [__meta_kubernetes_pod_container_port_name]
              regex: metrics
              action: keep

  {{- if and .Values.otelContainerInsights.solutions.enabled .Values.otelContainerInsights.solutions.vllm.enabled }}
  # vLLM model-server metrics, scraped per node like the ebs-csi-node job.
  prometheus/cw_k8s_ci_v0_vllm:
    config:
      scrape_configs:
        - job_name: vllm
          scrape_interval: {{ .Values.otelContainerInsights.metricResolution }}
          scrape_timeout: {{ include "otel-container-insights.scrapeTimeout" . }}
          metrics_path: /metrics
          # Watch only this node's pods: the vLLM match below is on the image, which
          # the API server cannot filter on, so an unscoped watch would hold every
          # pod in the cluster on every agent.
          kubernetes_sd_configs:
            - role: pod
              selectors:
                - role: pod
                  field: spec.nodeName=${env:K8S_NODE_NAME}
          relabel_configs:
            # Found without configuration: the model container of a KServe predictor,
            # or any container running a vLLM image. KServe names the container of
            # every InferenceService component kserve-container, so the predictor is
            # picked by its component label; transformers and explainers are not model
            # servers. Keyed on the container name rather than the port name: the port
            # is unnamed in RawDeployment mode, where Knative never renames it.
            - source_labels: [__meta_kubernetes_pod_label_serving_kserve_io_inferenceservice, __meta_kubernetes_pod_label_component, __meta_kubernetes_pod_container_name, __meta_kubernetes_pod_container_image]
              separator: ";"
              regex: '.+;predictor;kserve-container;.*|(?i)[^;]*;[^;]*;[^;]*;.*vllm.*'
              target_label: __tmp_vllm_detected
              replacement: "true"
              action: replace
            # receiver_creator/cw_k8s_ci_v0_vllm_logs (configInfo with logs off) has the
            # same rule. A change to one of them needs the same change in the other.
            # Only those: the chart reads no scrape labels or annotations of its own
            # from customer pods.
            - source_labels: [__tmp_vllm_detected]
              regex: "true"
              action: keep
            - source_labels: [__meta_kubernetes_pod_container_init]
              regex: "true"
              action: drop
            - source_labels: [__meta_kubernetes_pod_phase]
              regex: Running
              action: keep
            # role: pod gives a declared port's target its address already. A container
            # declaring none gets the server's default: 8080 for KServe, else
            # vllm serve's 8000. Joined via `separator` rather than a `$1` in
            # `replacement`, which would have to survive the collector's $$-unescaping.
            - source_labels: [__meta_kubernetes_pod_container_port_number, __meta_kubernetes_pod_label_serving_kserve_io_inferenceservice]
              separator: ";"
              regex: ";.+"
              target_label: __tmp_port
              replacement: "8080"
              action: replace
            - source_labels: [__meta_kubernetes_pod_container_port_number, __meta_kubernetes_pod_label_serving_kserve_io_inferenceservice]
              separator: ";"
              regex: ";"
              target_label: __tmp_port
              replacement: "8000"
              action: replace
            # A KServe serving runtime can state its metrics port and path in its
            # prometheus.kserve.io/* annotations, which KServe copies onto the pod.
            # They win over the defaults and collapse a multi-port container to one
            # target. These rules use the default replacement ($1), which is not part
            # of the rendered config.
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_kserve_io_port]
              regex: "([0-9]+)"
              target_label: __tmp_port
              action: replace
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_kserve_io_path]
              regex: "(/.*)"
              target_label: __metrics_path__
              action: replace
            - source_labels: [__meta_kubernetes_pod_ip, __tmp_port]
              separator: ":"
              regex: "(.+:[0-9]+)"
              target_label: __address__
              action: replace
            # Promoted to resource scope downstream, so k8sattributes can resolve the
            # owning Deployment rather than the ReplicaSet.
            - source_labels: [__meta_kubernetes_pod_name]
              target_label: pod
              action: replace
            - source_labels: [__meta_kubernetes_namespace]
              target_label: namespace
              action: replace
  {{- end }}

  kubeletstats/cw_k8s_ci_v0:
    auth_type: serviceAccount
    collection_interval: {{ .Values.otelContainerInsights.metricResolution }}
    endpoint: "https://${env:HOST_IP}:10250"
    insecure_skip_verify: true
    metric_groups:
      - pod
      - container
      - node
    metrics:
      k8s.pod.cpu_limit_utilization:
        enabled: true
      k8s.pod.cpu_request_utilization:
        enabled: true
      k8s.pod.memory_limit_utilization:
        enabled: true
      k8s.pod.memory_request_utilization:
        enabled: true
      k8s.container.cpu_limit_utilization:
        enabled: true
      k8s.container.cpu_request_utilization:
        enabled: true
      k8s.container.memory_limit_utilization:
        enabled: true
      k8s.container.memory_request_utilization:
        enabled: true
      k8s.pod.cpu.usage:
        enabled: true
      container.cpu.usage:
        enabled: true
      k8s.node.cpu.usage:
        enabled: true
      k8s.pod.uptime:
        enabled: true
      container.uptime:
        enabled: true
      k8s.node.uptime:
        enabled: true

{{- if .Values.otelContainerInsights.logs.enabled }}
  # ── CI Logs receivers ──
  filelog/cw_k8s_ci_v0_app:
    include:
      - /var/log/containers/*.log
    exclude:
      - /var/log/containers/cloudwatch-agent*
      - /var/log/containers/fluent-bit*
      # aws-node and kube-proxy are dataplane components — excluded to match
      # FluentBit's existing Exclude_Path behavior.
      - /var/log/containers/aws-node*
      - /var/log/containers/kube-proxy*
    {{- if $appLogCheckpoints }}
    # File checkpoints persist in file_storage/cw_k8s_ci_v0_state, so a restarted
    # agent resumes each file where it stopped, including lines written while it was
    # down. Only with otelContainerInsights.stateStorage.enabled (configInfo alone
    # does not change log shipping).
    storage: file_storage/cw_k8s_ci_v0_state
    {{- else }}
    # No checkpoint persistence — logs during agent downtime are lost.
    # otelContainerInsights.stateStorage.enabled persists the checkpoints.
    {{- end }}
    start_at: end
    include_file_path: true
    include_file_name: false
    max_concurrent_files: 100
    operators:
      - type: regex_parser
        id: extract_metadata_from_filepath
        regex: '^.*\/(?P<pod>[^_]+)_(?P<namespace>[^_]+)_(?P<container>.+)-[a-f0-9]{64}\.log$'
        parse_from: attributes["log.file.path"]
        parse_to: resource
      - type: move
        from: resource.pod
        to: resource["k8s.pod.name"]
      - type: move
        from: resource.namespace
        to: resource["k8s.namespace.name"]
      - type: move
        from: resource.container
        to: resource["k8s.container.name"]
      - id: parse_container_log
        type: container_log_parser

  filelog/cw_k8s_ci_v0_node:
    include:
      - /var/log/messages
      - /var/log/dmesg
      - /var/log/secure
    # No checkpoint persistence — logs during agent downtime are lost.
    # Filestorage support is tracked in a follow-up PR.
    start_at: end
    include_file_path: true
    include_file_name: false
    max_concurrent_files: 100

{{- end }}

{{- if $infoLogsOff }}

  # ── vLLM config Info metric, logs-off mode ──
  # For each container that the rule matches, receiver_creator starts one filelog
  # receiver, and it stops that receiver when the container stops. The rule is the
  # vLLM scrape rule of prometheus/cw_k8s_ci_v0_vllm: the kserve-container of a KServe
  # predictor pod, or a container whose image name contains vllm (any case). A change
  # to one of them needs the same change in the other. A pod without a label gets an
  # empty string for it, so the rule works for every pod. Like the scrape job, the pod
  # watch skips init containers and pods that are not running. It also skips a
  # container that is not running, until it runs.
  # receiver_creator sets k8s.namespace.name, k8s.pod.name, k8s.pod.uid and
  # k8s.container.name from the pod watch, so the records need no file name parse.
  # It also sets container.id and container.image.name, which the connector does not use.
  receiver_creator/cw_k8s_ci_v0_vllm_logs:
    watch_observers: [k8s_observer/cw_k8s_ci_v0_vllm]
    receivers:
      filelog/vllm:
        rule: 'type == "pod.container" && ((pod.labels["serving.kserve.io/inferenceservice"] != "" && pod.labels["component"] == "predictor" && container_name == "kserve-container") || container_image matches "(?i)vllm")'
        config:
          # The kubelet log directory of the container. The values in backticks come
          # from the pod watch. A static pod has no files here: its directory has the
          # UID of the kubelet's own pod, not the UID of the mirror pod in the API.
          include:
            - '/var/log/pods/`pod.namespace`_`pod.name`_`pod.uid`/`container_name`/*.log'
          # After a container restart, kubelet keeps the log of the previous container,
          # <n>.log, next to the current <n+1>.log. Only the file with the highest
          # restart count is read, so an older startup line never replaces newer facts.
          # A file name without a number is not read.
          ordering_criteria:
            regex: '/(?P<restart>[0-9]+)\.log\z'
            top_n: 1
            sort_by:
              - regex_key: restart
                sort_type: numeric
                ascending: false
          # No checkpoints: a new receiver reads the current file from the start. No
          # log is shipped in this mode, so only the connector reads the records.
          start_at: beginning
          include_file_path: false
          include_file_name: false
          # Keep the trailing space of an empty line, "<time> stdout F ".
          # container_log_parser needs it, and logs an error for each empty line without it.
          preserve_trailing_whitespaces: true
          poll_interval: {{ include "otel-container-insights.vllmInfoLogsOffPollInterval" . }}
          operators:
            - id: parse_container_log
              type: container_log_parser
{{- end }}

{{- if $rayLogs }}

  # ── Ray logs ──
  # Ray writes its logs to files under /tmp/ray in the pod, not to stdout. When /tmp/ray
  # is an emptyDir (the KubeRay log-persistence pattern), the files are on the node,
  # under the pod's volume directory, and the agent reads them through its read-only
  # /rootfs mount. Files in the container's own filesystem are not read.
  # The rule is the Ray scrape rule: every pod that KubeRay labels ray.io/is-ray-node=yes.
  # For each such pod, receiver_creator starts the three receivers below, and it stops
  # them when the pod stops. It sets k8s.namespace.name, k8s.pod.name and k8s.pod.uid
  # from the pod watch, so the records need no file name parse.
  # The pod watch does not report volume names, so the path matches every emptyDir of
  # the pod. Only a Ray session directory has the files. session_[0-9]* skips
  # session_latest, a symlink to an absolute path inside the container.
  # The Ray text timestamps carry no time zone (the Ray images set TZ), so they are
  # not parsed. As for the host logs, a record's time is the time the agent reads it.
  receiver_creator/cw_k8s_ci_v0_ray_logs:
    watch_observers: [k8s_observer/cw_k8s_ci_v0_ray]
    receivers:
      # Ray Serve: the controller, proxy and replica logs, text or JSON
      # (logging_config.encoding: JSON). transform/cw_k8s_ci_v0_ray_logs_parse
      # reads the JSON fields.
      filelog/ray_serve:
        rule: 'type == "pod" && labels["ray.io/is-ray-node"] == "yes"'
        config:
          include:
            - '/rootfs/var/lib/kubelet/pods/`uid`/volumes/kubernetes.io~empty-dir/*/session_[0-9]*/logs/serve/*.log'
          {{- include "otel-container-insights.rayLogsReaderConfig" (dict "checkpoints" $appLogCheckpoints) | nindent 10 }}
          operators:
            # A record starts with a JSON object or with Serve's text format
            # ("INFO 2026-01-02 03:04:05,678 ..."). Other lines, such as the lines of
            # a text traceback, belong to the record before them.
            - type: recombine
              combine_field: body
              combine_with: "\n"
              source_identifier: attributes["log.file.name"]
              is_first_entry: body matches "^(\\{|(DEBUG|INFO|WARNING|ERROR|CRITICAL) \\d{4}-\\d{2}-\\d{2} )"
      # The stdout and stderr of each Ray worker process (worker-*.out, worker-*.err,
      # in old/ after the worker exits) and of each job driver: the application's own
      # output, prints and tracebacks.
      filelog/ray_workers:
        rule: 'type == "pod" && labels["ray.io/is-ray-node"] == "yes"'
        config:
          include:
            - '/rootfs/var/lib/kubelet/pods/`uid`/volumes/kubernetes.io~empty-dir/*/session_[0-9]*/logs/worker-*.out'
            - '/rootfs/var/lib/kubelet/pods/`uid`/volumes/kubernetes.io~empty-dir/*/session_[0-9]*/logs/worker-*.err'
            - '/rootfs/var/lib/kubelet/pods/`uid`/volumes/kubernetes.io~empty-dir/*/session_[0-9]*/logs/old/worker-*.out'
            - '/rootfs/var/lib/kubelet/pods/`uid`/volumes/kubernetes.io~empty-dir/*/session_[0-9]*/logs/old/worker-*.err'
            - '/rootfs/var/lib/kubelet/pods/`uid`/volumes/kubernetes.io~empty-dir/*/session_[0-9]*/logs/job-driver-*.log'
          {{- include "otel-container-insights.rayLogsReaderConfig" (dict "checkpoints" $appLogCheckpoints) | nindent 10 }}
          operators:
            # A Python traceback joins the record before it: its indented lines, its
            # "Traceback" and chaining lines, and its final exception line. Also after
            # the "(EngineCore pid=7165) " prefix that vLLM puts on the output of its
            # subprocesses, and after vLLM's log header ("ERROR 01-02 03:04:05 [x.py:1] "),
            # which vLLM writes on every line of a traceback it logs.
            - type: recombine
              combine_field: body
              combine_with: "\n"
              source_identifier: attributes["log.file.name"]
              is_first_entry: not (body matches "^(\\([\\w.-]+ pid=\\d+\\) )?((DEBUG|INFO|WARNING|ERROR|CRITICAL) \\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2} \\[[^\\]]+\\] )?(\\s|Traceback \\(most recent call last\\):|During handling of the above exception|The above exception was the direct cause|[A-Za-z_][\\w.]*(Error|Exception|Exit|Interrupt|Warning)(:|$))")
            # Three kinds of copies are dropped, so that each line is sent once:
            # - Ray Serve writes each of its records to its serve/ file and, by default
            #   (RAY_SERVE_LOG_TO_STDERR=1), again to the stderr of the actor, in Serve's
            #   text format. filelog/ray_serve reads the serve/ copy, so the stderr copy
            #   is dropped here, with its traceback.
            # - Ray copies the output of each worker to the drivers of its job, with the
            #   colored "(RayWorkerProc pid=7303) " prefix. A process inside a Ray
            #   worker can be a driver too (vLLM's engine with the Ray executor), so the
            #   copies land in that worker's stderr. The worker's own file has the line.
            # - Ray's :job_id:, :task_name: and :actor_name: marker lines: Ray's log
            #   monitor reads them, and they carry no message.
            # A line in any other format is kept.
            - type: filter
              expr: body matches "^(DEBUG|INFO|WARNING|ERROR|CRITICAL) \\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2},\\d{3} \\S+ \\S+ " or body matches "\\x1b\\[[0-9;]*m\\([^()]* pid=\\d+(, ip=[0-9.]+)?\\)\\x1b\\[0?m" or body matches "^:(job_id|task_name|actor_name):"
      # Ray's own processes: the raylet on every Ray pod, the GCS server, autoscaler
      # monitor and runtime environment agent, and the exit record of each Ray process.
      # The Python core logs of each worker (python-core-worker-*.log), the dashboard
      # logs, the event files and the profiler output are not read.
      filelog/ray_system:
        rule: 'type == "pod" && labels["ray.io/is-ray-node"] == "yes"'
        config:
          include:
            - '/rootfs/var/lib/kubelet/pods/`uid`/volumes/kubernetes.io~empty-dir/*/session_[0-9]*/logs/raylet.out'
            - '/rootfs/var/lib/kubelet/pods/`uid`/volumes/kubernetes.io~empty-dir/*/session_[0-9]*/logs/raylet.err'
            - '/rootfs/var/lib/kubelet/pods/`uid`/volumes/kubernetes.io~empty-dir/*/session_[0-9]*/logs/gcs_server.out'
            - '/rootfs/var/lib/kubelet/pods/`uid`/volumes/kubernetes.io~empty-dir/*/session_[0-9]*/logs/gcs_server.err'
            - '/rootfs/var/lib/kubelet/pods/`uid`/volumes/kubernetes.io~empty-dir/*/session_[0-9]*/logs/monitor.log'
            - '/rootfs/var/lib/kubelet/pods/`uid`/volumes/kubernetes.io~empty-dir/*/session_[0-9]*/logs/runtime_env_agent.log'
            - '/rootfs/var/lib/kubelet/pods/`uid`/volumes/kubernetes.io~empty-dir/*/session_[0-9]*/logs/ray_process_exit.log'
          {{- include "otel-container-insights.rayLogsReaderConfig" (dict "checkpoints" $appLogCheckpoints) | nindent 10 }}
          operators:
            # A record starts with a timestamp: "[2026-01-02 03:04:05,678 I ...]" from
            # the C++ processes, "2026-01-02 03:04:05,678<TAB>INFO ..." from the Python
            # ones. Other lines, such as a periodic stats dump, belong to the record
            # before them.
            - type: recombine
              combine_field: body
              combine_with: "\n"
              source_identifier: attributes["log.file.name"]
              is_first_entry: body matches "^\\[?\\d{4}-\\d{2}-\\d{2} "
            # The raylet and the GCS server write a stats dump every few seconds, at
            # INFO. From these two, only WARNING and above is kept: worker and node
            # failures, out-of-memory kills.
            - type: filter
              expr: attributes["log.file.name"] in ["raylet.out", "gcs_server.out"] and body matches "^\\[\\d{4}-\\d{2}-\\d{2} [0-9:,.]+ [DI] "
{{- end }}

processors:
  # node-exporter's own per-collector scrape timing/status, same category as the five
  # scrape_* names. node_textfile_scrape_error stays: kubernetes-mixin alerts on it.
  filter/cw_k8s_ci_v0_scrape_metadata:
    error_mode: ignore
    metrics:
      metric:
        - IsMatch(name, "^(up|scrape_duration_seconds|scrape_samples_scraped|scrape_samples_post_metric_relabeling|scrape_series_added|node_scrape_collector_duration_seconds|node_scrape_collector_success)$")

  # Drop receiver-injected deprecated semconv attributes; their current-spelling
  # twins (server.address, server.port, url.scheme) carry the same values and stay.
  transform/cw_k8s_ci_v0_drop_deprecated_semconv:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - delete_key(attributes, "net.host.name") where attributes["net.host.name"] != nil
          - delete_key(attributes, "net.host.port") where attributes["net.host.port"] != nil
          - delete_key(attributes, "http.scheme") where attributes["http.scheme"] != nil

  transform/cw_k8s_ci_v0_set_unit:
    error_mode: ignore
    metric_statements:
      - context: metric
        statements:
          # Time
          - set(unit, "s") where IsMatch(name, ".*_seconds(_total)?$")
          - set(unit, "ms") where IsMatch(name, ".*_milliseconds(_total)?$")
          - set(unit, "us") where IsMatch(name, ".*_microseconds(_total)?$")
          - set(unit, "ns") where IsMatch(name, ".*_nanoseconds(_total)?$")
          # Bytes
          - set(unit, "By") where IsMatch(name, ".*_bytes(_total)?$")
          - set(unit, "KBy") where IsMatch(name, ".*_kilobytes(_total)?$")
          - set(unit, "MBy") where IsMatch(name, ".*_megabytes(_total)?$")
          - set(unit, "GBy") where IsMatch(name, ".*_gigabytes(_total)?$")
          - set(unit, "KiBy") where IsMatch(name, ".*_kibibytes(_total)?$")
          - set(unit, "MiBy") where IsMatch(name, ".*_mebibytes(_total)?$")
          - set(unit, "GiBy") where IsMatch(name, ".*_gibibytes(_total)?$")
          # Other
          - set(unit, "Cel") where IsMatch(name, ".*_celsius$")
          - set(unit, "Hz") where IsMatch(name, ".*_hertz$")
          - set(unit, "1") where IsMatch(name, ".*_ratio$")
          - set(unit, "%") where IsMatch(name, ".*_percent$")
          - set(unit, "V") where IsMatch(name, ".*_volts$")
          - set(unit, "W") where IsMatch(name, ".*_watts$")
          - set(unit, "J") where IsMatch(name, ".*_joules$")
          - set(unit, "A") where IsMatch(name, ".*_amperes$")
          - set(unit, "m") where IsMatch(name, ".*_meters(_total)?$")
          # Counters with only _total suffix (dimensionless count)
          - set(unit, "1") where unit == "" and IsMatch(name, ".*_total$")
          # DCGM explicit mappings (no suffix convention)
          - set(unit, "%") where name == "DCGM_FI_DEV_GPU_UTIL"
          - set(unit, "%") where name == "DCGM_FI_DEV_MEM_COPY_UTIL"
          - set(unit, "%") where name == "DCGM_FI_PROF_PIPE_TENSOR_ACTIVE"
          - set(unit, "MiBy") where name == "DCGM_FI_DEV_FB_USED"
          - set(unit, "MiBy") where name == "DCGM_FI_DEV_FB_FREE"
          - set(unit, "MiBy") where name == "DCGM_FI_DEV_FB_TOTAL"
          - set(unit, "Cel") where name == "DCGM_FI_DEV_GPU_TEMP"
          - set(unit, "W") where name == "DCGM_FI_DEV_POWER_USAGE"
          - set(unit, "MHz") where name == "DCGM_FI_DEV_SM_CLOCK"
          # Neuron explicit mappings
          - set(unit, "By") where IsMatch(name, "^neuroncore_memory_usage_.*")

  transform/cw_k8s_ci_v0_set_cluster_name:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.cluster.name"], "{{ .Values.clusterName }}")

{{- if .Values.nodeExporter.enabled }}
  transform/cw_k8s_ci_v0_set_scope_node_exporter:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.name, "github.com/prometheus/node_exporter")
          - set(scope.version, "{{ include "node-exporter.scopeVersion" . }}")
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "node-exporter")
{{- end }}

  transform/cw_k8s_ci_v0_set_scope_cadvisor:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.name, "github.com/google/cadvisor")
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "cadvisor")

  {{- if .Values.dcgmExporter.enabled }}
  transform/cw_k8s_ci_v0_set_scope_dcgm:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.name, "github.com/NVIDIA/dcgm-exporter")
          - set(scope.version, "{{ .Values.dcgmExporter.image.tag }}")
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "dcgm")
  {{- end }}

  {{- if .Values.neuronMonitor.enabled }}
  transform/cw_k8s_ci_v0_set_scope_neuron_monitor:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.name, "awsneuron")
          - set(scope.version, "{{ .Values.neuronMonitor.image.tag }}")
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "neuron-monitor")
  {{- end }}

  transform/cw_k8s_ci_v0_set_scope_efa:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "efa")

  transform/cw_k8s_ci_v0_set_scope_ebs_csi:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "ebs-csi")

  {{- if and .Values.otelContainerInsights.solutions.enabled .Values.otelContainerInsights.solutions.vllm.enabled }}
  transform/cw_k8s_ci_v0_set_scope_vllm:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.name, "github.com/vllm-project/vllm")
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "vllm")

  # Lift the scraped pod identity to resource scope, where k8sattributes'
  # pod_association looks for it. Same shape as the DCGM promote.
  transform/cw_k8s_ci_v0_vllm_promote:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.pod.name"], attributes["pod"]) where attributes["pod"] != nil
          - set(resource.attributes["k8s.namespace.name"], attributes["namespace"]) where attributes["namespace"] != nil
          # vLLM only ever serves inference, including when it generates rollouts
          # for a training loop.
          - set(resource.attributes["aws.service.type"], "ai_inference")

  # transform/cw_k8s_ci_v0_set_workload only assigns service.name on AKS and GKE, so
  # on EKS it stays the Prometheus receiver's default -- the scrape job name.
  #
  # Ordered lowest-precedence first, each overwriting unconditionally: a guard on
  # `service.name == nil` would never fire, because the receiver always sets it.
  # Effective precedence is InferenceService, then workload (resolved by
  # set_workload, which runs earlier), then pod. The InferenceService name is
  # KServe's own pod label, as extracted by k8sattributes.
  transform/cw_k8s_ci_v0_vllm_service_name:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(attributes["service.name"], attributes["k8s.pod.name"]) where attributes["k8s.pod.name"] != nil
          - set(attributes["service.name"], attributes["k8s.workload.name"]) where attributes["k8s.workload.name"] != nil
          - set(attributes["service.name"], attributes["k8s.pod.label.serving.kserve.io/inferenceservice"]) where attributes["k8s.pod.label.serving.kserve.io/inferenceservice"] != nil
          - set(attributes["service.namespace"], attributes["k8s.namespace.name"]) where attributes["k8s.namespace.name"] != nil

  # Keep the engine's own series and the instrumentator's http_* (the only
  # HTTP-status telemetry vLLM emits); drop the Python client registry's python_*
  # and process_*. The *_created creation timestamps are constant per scrape, and
  # the receiver has already consumed them to set start timestamps. Summaries
  # (http_request_size_bytes, http_response_size_bytes) are rejected by the
  # CloudWatch OTLP endpoint, so drop them here rather than per batch there.
  filter/cw_k8s_ci_v0_vllm_keep:
    error_mode: ignore
    metrics:
      metric:
        {{- if $configInfo }}
        # Also keep the config Info metric from signal_to_info_metric/cw_k8s_ci_v0_vllm.
        - 'not IsMatch(name, "^(vllm:|http_).*") and name != "vllm_engine_config_info"'
        {{- else }}
        - 'not IsMatch(name, "^(vllm:|http_).*")'
        {{- end }}
        - 'IsMatch(name, ".*_created$")'
        - 'type == METRIC_DATA_TYPE_SUMMARY'
  {{- if $configInfo }}

  # The config Info metric is keyed on the namespace, pod and container of the log
  # record: from the log file name with logs on, from the pod watch with logs off. Its
  # resource also carries the k8s.pod.uid of the pod that logged the startup line,
  # when the record had one.
  # This sets that stored UID aside, so that k8sattributes/cw_k8s_ci_v0_pod (which
  # never overwrites an attribute) adds the UID of the live pod with that name.
  # No processor before this one sets or changes k8s.pod.uid on the Info metric.
  # Each statement names the Info metric, whose resource holds no other metric.
  transform/cw_k8s_ci_v0_vllm_info_uid:
    error_mode: ignore
    metric_statements:
      - context: metric
        statements:
          - set(resource.attributes["cwagent.info.pod.uid"], resource.attributes["k8s.pod.uid"]) where metric.name == "vllm_engine_config_info" and resource.attributes["k8s.pod.uid"] != nil
          - delete_key(resource.attributes, "k8s.pod.uid") where metric.name == "vllm_engine_config_info"

  # Right after k8sattributes/cw_k8s_ci_v0_pod has looked up the pod with that name in
  # that namespace on this node. An Info data point is stale, and dropped, when:
  # - there is no live k8s.pod.uid: no such pod (k8sattributes keeps a deleted pod for
  #   its 120 s grace period), or
  # - the stored UID is set and is not the live one: a pod replaced under the same
  #   name (a StatefulSet pod) that has not logged its own startup line yet.
  # While the pod cache syncs at agent start, a live pod can be missing too: the
  # connector keeps the facts, and a later emit passes. Each condition names the Info
  # metric, so a scraped vllm:* or http_* series is never dropped, with or without a UID.
  filter/cw_k8s_ci_v0_vllm_info_live:
    error_mode: ignore
    metrics:
      datapoint:
        - 'metric.name == "vllm_engine_config_info" and resource.attributes["k8s.pod.uid"] == nil'
        - 'metric.name == "vllm_engine_config_info" and resource.attributes["cwagent.info.pod.uid"] != nil and resource.attributes["cwagent.info.pod.uid"] != resource.attributes["k8s.pod.uid"]'

  # The stored UID is private to the check above and is not sent.
  transform/cw_k8s_ci_v0_vllm_info_cleanup:
    error_mode: ignore
    metric_statements:
      - context: metric
        statements:
          - delete_key(resource.attributes, "cwagent.info.pod.uid") where metric.name == "vllm_engine_config_info"
  {{- end }}
  {{- end }}

  transform/cw_k8s_ci_v0_set_scope_lis_csi:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "lis-csi")

  {{- if and .Values.otelContainerInsights.solutions.enabled .Values.otelContainerInsights.solutions.knative.dataPlane.enabled }}
  transform/cw_k8s_ci_v0_set_scope_knative_dataplane:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.name, "knative.dev/serving")
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "knative-dataplane")

  # Lifts the scraped pod identity to resource scope, where k8sattributes'
  # pod_association looks for it, so the revision's Deployment is resolved.
  transform/cw_k8s_ci_v0_knative_dataplane_promote:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.pod.name"], attributes["pod"]) where attributes["pod"] != nil
          - set(resource.attributes["k8s.namespace.name"], attributes["namespace"]) where attributes["namespace"] != nil

  # The predictor revision of a KServe InferenceService runs the model, like the
  # vLLM pipeline, so it is ai_inference. Transformer and explainer revisions
  # carry the same InferenceService label but don't run the model, and plain
  # Knative Services are any workload, so they get no aws.service.type. Reads
  # KServe's own pod labels, as extracted by k8sattributes.
  transform/cw_k8s_ci_v0_knative_dataplane_service_type:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(attributes["aws.service.type"], "ai_inference") where attributes["k8s.pod.label.serving.kserve.io/inferenceservice"] != nil and attributes["k8s.pod.label.component"] == "predictor"

  # Two name sets, because Serving 1.19 moved observability to the OpenTelemetry
  # SDK and renamed every metric: revision_* before it, kn_serving_* from it on.
  filter/cw_k8s_ci_v0_knative_dataplane_keep:
    error_mode: ignore
    metrics:
      metric:
        - 'not IsMatch(name, "^(revision_.*request.*|kn_serving_.*)")'
  {{- end }}

  transform/cw_k8s_ci_v0_set_scope_kubeletstats:
    error_mode: ignore
    metric_statements:
      - context: scope
        statements:
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "kubeletstats")

  transform/cw_k8s_ci_v0_set_node_name:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(attributes["node_name"], "${env:K8S_NODE_NAME}")

  transform/cw_k8s_ci_v0_promote_node_name:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.node.name"], attributes["node_name"]) where attributes["node_name"] != nil

  resourcedetection/cw_k8s_ci_v0:
    {{- if eq .Values.k8sMode "AKS" }}
    detectors: [aks, azure]
    aks:
      resource_attributes:
        cloud.platform: { enabled: true }
        cloud.provider: { enabled: true }
        k8s.cluster.name: { enabled: false }
    azure:
      resource_attributes:
        azure.resourcegroup.name: { enabled: true }
        azure.vm.name: { enabled: true }
        azure.vm.scaleset.name: { enabled: true }
        azure.vm.size: { enabled: true }
        cloud.account.id: { enabled: true }
        cloud.platform: { enabled: true }
        cloud.provider: { enabled: true }
        cloud.region: { enabled: true }
        host.id: { enabled: true }
        host.name: { enabled: true }
    {{- else if eq .Values.k8sMode "GKE" }}
    detectors: [gcp]
    gcp:
      resource_attributes:
        cloud.account.id: { enabled: true }
        cloud.availability_zone: { enabled: true }
        cloud.platform: { enabled: true }
        cloud.provider: { enabled: true }
        cloud.region: { enabled: true }
        host.id: { enabled: true }
        host.name: { enabled: true }
        k8s.cluster.name: { enabled: false }
    {{- else }}
    detectors: [eks, ec2]
    ec2:
      resource_attributes:
        host.id: { enabled: true }
        host.type: { enabled: true }
        host.name: { enabled: true }
        host.image.id: { enabled: true }
        cloud.provider: { enabled: true }
        cloud.platform: { enabled: true }
        cloud.region: { enabled: true }
        cloud.availability_zone: { enabled: true }
        cloud.account.id: { enabled: true }
    {{- end }}

  transform/cw_k8s_ci_v0_clear_schema_url:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(resource.schema_url, "")

  k8sattributes/cw_k8s_ci_v0_node:
    auth_type: serviceAccount
    passthrough: false
    filter:
      node_from_env_var: K8S_NODE_NAME
    extract:
      metadata:
        - k8s.node.name
      labels:
        - tag_name: "k8s.node.label.$$$1"
          key_regex: "(.*)"
          from: node
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.node.name

  k8sattributes/cw_k8s_ci_v0_pod:
    auth_type: serviceAccount
    passthrough: false
    filter:
      node_from_env_var: K8S_NODE_NAME
    extract:
      metadata:
        - k8s.pod.uid
        - k8s.node.name
        - k8s.deployment.name
        - k8s.statefulset.name
        - k8s.daemonset.name
        - k8s.replicaset.name
        - k8s.job.name
        - k8s.cronjob.name
      labels:
        - tag_name: "k8s.pod.label.$$$1"
          key_regex: "(.*)"
          from: pod
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.pod.name
          - from: resource_attribute
            name: k8s.namespace.name

  awsattributelimit/cw_k8s_ci_v0:
    max_total_attributes: 150
    unconditional_removal_prefixes:
      - "k8s.node.label.feature.node.kubernetes.io/"
      - "k8s.node.label.beta.kubernetes.io/"
      - "k8s.node.label.failure-domain.beta.kubernetes.io/"
      - "k8s.node.label.alpha.eksctl.io/"
      # Not the whole karpenter.k8s.aws/instance- prefix: instance-tenancy is a launch property, so it is kept.
      - "k8s.node.label.karpenter.k8s.aws/instance-cpu"
      - "k8s.node.label.karpenter.k8s.aws/instance-gpu-"
      - "k8s.node.label.karpenter.k8s.aws/instance-accelerator-"
      - "k8s.node.label.eks.amazonaws.com/instance-"
    unconditional_removal_keys:
      - "k8s.node.label.topology.kubernetes.io/region"
      - "k8s.node.label.topology.kubernetes.io/zone"
      - "k8s.node.label.topology.ebs.csi.aws.com/zone"
      - "k8s.node.label.node.kubernetes.io/instance-type"
      - "k8s.node.label.kubernetes.io/hostname"
      - "k8s.node.label.helm.sh/chart"
      - "k8s.node.label.release"
      - "k8s.node.label.eks.amazonaws.com/nodegroup-image"
      - "k8s.node.label.k8s.io/cloud-provider-aws"
      - "k8s.node.label.eks.amazonaws.com/sourceLaunchTemplateId"
      - "k8s.node.label.eks.amazonaws.com/sourceLaunchTemplateVersion"
      - "k8s.pod.label.pod-template-hash"
      - "k8s.pod.label.controller-revision-hash"
      - "k8s.pod.label.pod-template-generation"
      - "k8s.pod.label.topology.kubernetes.io/region"
      - "k8s.pod.label.topology.kubernetes.io/zone"
      - "k8s.node.label.karpenter.sh/do-not-sync-taints"
      - "k8s.node.label.karpenter.sh/initialized"
      - "k8s.node.label.karpenter.sh/registered"
      - "k8s.node.label.karpenter.k8s.aws/instance-category"
      - "k8s.node.label.karpenter.k8s.aws/instance-family"
      - "k8s.node.label.karpenter.k8s.aws/instance-generation"
      - "k8s.node.label.karpenter.k8s.aws/instance-size"
      - "k8s.node.label.karpenter.k8s.aws/instance-memory"
      - "k8s.node.label.karpenter.k8s.aws/instance-hypervisor"
      - "k8s.node.label.karpenter.k8s.aws/instance-local-nvme"
      - "k8s.node.label.karpenter.k8s.aws/instance-ebs-bandwidth"
      - "k8s.node.label.karpenter.k8s.aws/instance-network-bandwidth"
      - "k8s.node.label.karpenter.k8s.aws/instance-encryption-in-transit-supported"
      - "k8s.node.label.karpenter.k8s.aws/instance-capability-flex"

  transform/cw_k8s_ci_v0_set_cloud_resource_id:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          {{- if eq .Values.k8sMode "AKS" }}
          {{/* azure.resourcegroup.name is the node's group, not the cluster's: AKS nodes live in an
               auto-generated MC_<clusterResourceGroup>_<cluster>_<region> group. */}}
          - set(resource.attributes["_tmp.azure.resourcegroup.name"], resource.attributes["azure.resourcegroup.name"])
            where resource.attributes["azure.resourcegroup.name"] != nil
          - replace_pattern(resource.attributes["_tmp.azure.resourcegroup.name"], "^MC_(.+)_{{ .Values.clusterName }}_[^_]+$", "$$$1")
          - set(resource.attributes["cloud.resource_id"], Concat(["/subscriptions/", resource.attributes["cloud.account.id"], "/resourceGroups/", resource.attributes["_tmp.azure.resourcegroup.name"], "/providers/Microsoft.ContainerService/managedClusters/", resource.attributes["k8s.cluster.name"]], ""))
            where resource.attributes["cloud.account.id"] != nil and resource.attributes["_tmp.azure.resourcegroup.name"] != nil and resource.attributes["k8s.cluster.name"] != nil
          - delete_key(resource.attributes, "_tmp.azure.resourcegroup.name")
          {{- else if eq .Values.k8sMode "GKE" }}
          {{/* GKE full resource name: zones/<zone> (zonal) or locations/<region> (regional). */}}
          - set(resource.attributes["cloud.resource_id"], Concat(["//container.googleapis.com/projects/", resource.attributes["cloud.account.id"], "/zones/", resource.attributes["cloud.availability_zone"], "/clusters/", resource.attributes["k8s.cluster.name"]], ""))
            where resource.attributes["cloud.account.id"] != nil and resource.attributes["cloud.availability_zone"] != nil and resource.attributes["k8s.cluster.name"] != nil
          - set(resource.attributes["cloud.resource_id"], Concat(["//container.googleapis.com/projects/", resource.attributes["cloud.account.id"], "/locations/", resource.attributes["cloud.region"], "/clusters/", resource.attributes["k8s.cluster.name"]], ""))
            where resource.attributes["cloud.resource_id"] == nil and resource.attributes["cloud.account.id"] != nil and resource.attributes["cloud.region"] != nil and resource.attributes["k8s.cluster.name"] != nil
          {{- else }}
          - set(resource.attributes["cloud.resource_id"], Concat(["arn:aws:eks:", resource.attributes["cloud.region"], ":", resource.attributes["cloud.account.id"], ":cluster/", resource.attributes["k8s.cluster.name"]], ""))
            where resource.attributes["cloud.region"] != nil and resource.attributes["cloud.account.id"] != nil and resource.attributes["k8s.cluster.name"] != nil
          {{- end }}

  metricstarttime/cw_k8s_ci_v0:

  transform/cw_k8s_ci_v0_set_workload:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.deployment.name"]) where resource.attributes["k8s.deployment.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "Deployment") where resource.attributes["k8s.deployment.name"] != nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.statefulset.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.statefulset.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "StatefulSet") where resource.attributes["k8s.statefulset.name"] != nil and resource.attributes["k8s.workload.type"] == nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.daemonset.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.daemonset.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "DaemonSet") where resource.attributes["k8s.daemonset.name"] != nil and resource.attributes["k8s.workload.type"] == nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.job.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.job.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "Job") where resource.attributes["k8s.job.name"] != nil and resource.attributes["k8s.workload.type"] == nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.cronjob.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.cronjob.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "CronJob") where resource.attributes["k8s.cronjob.name"] != nil and resource.attributes["k8s.workload.type"] == nil
          - set(resource.attributes["k8s.workload.name"], resource.attributes["k8s.replicaset.name"]) where resource.attributes["k8s.workload.name"] == nil and resource.attributes["k8s.replicaset.name"] != nil
          - set(resource.attributes["k8s.workload.type"], "ReplicaSet") where resource.attributes["k8s.replicaset.name"] != nil and resource.attributes["k8s.workload.type"] == nil
          {{- if or (eq .Values.k8sMode "AKS") (eq .Values.k8sMode "GKE") }}
          - set(resource.attributes["service.name"], resource.attributes["k8s.workload.name"]) where resource.attributes["service.name"] == nil and resource.attributes["k8s.workload.name"] != nil
          - set(resource.attributes["service.namespace"], resource.attributes["k8s.namespace.name"]) where resource.attributes["service.namespace"] == nil and resource.attributes["k8s.namespace.name"] != nil
          - set(resource.attributes["deployment.environment.name"], Concat([resource.attributes["cloud.platform"], Concat([resource.attributes["k8s.cluster.name"], resource.attributes["k8s.namespace.name"]], "/")], ":")) where resource.attributes["deployment.environment.name"] == nil and resource.attributes["cloud.platform"] != nil and resource.attributes["k8s.cluster.name"] != nil and resource.attributes["k8s.namespace.name"] != nil
          {{- end }}

  batch/cw_k8s_ci_v0_metrics_dest:
    send_batch_size: 500
    send_batch_max_size: 500
    timeout: 10s

  filter/cw_k8s_ci_v0_cadvisor_empty:
    error_mode: ignore
    metrics:
      datapoint:
        - attributes["container"] == "" and attributes["pod"] == ""
        - attributes["container"] == "" and attributes["pod"] == nil
        - attributes["container"] == nil and attributes["pod"] == ""
        - attributes["container"] == nil and attributes["pod"] == nil

  filter/cw_k8s_ci_v0_cadvisor_pod:
    error_mode: ignore
    metrics:
      datapoint:
        - attributes["container"] == "POD"

  # Drop the pod cgroup slice and pause/sandbox duplicates of each container_* family.
  # container_network_* is sandbox-only so must stay; `container` arrives absent, not "".
  filter/cw_k8s_ci_v0_cadvisor_rollup:
    error_mode: ignore
    metrics:
      datapoint:
        - (attributes["container"] == nil or attributes["container"] == "")
            and attributes["pod"] != nil and attributes["pod"] != ""
            and IsMatch(metric.name, "^container_network_") != true

  groupbyattrs/cw_k8s_ci_v0_cadvisor:
    keys:
      - container
      - pod
      - namespace

  transform/cw_k8s_ci_v0_cadvisor_promote:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(attributes["k8s.container.name"], attributes["container"]) where attributes["container"] != nil and attributes["container"] != ""
          - set(attributes["k8s.pod.name"], attributes["pod"]) where attributes["pod"] != nil
          - set(attributes["k8s.namespace.name"], attributes["namespace"]) where attributes["namespace"] != nil
      - context: datapoint
        statements:
          # Restore raw Prometheus names to datapoint scope (groupbyattrs removed them).
          - set(attributes["container"], resource.attributes["container"]) where resource.attributes["container"] != nil
          - set(attributes["pod"], resource.attributes["pod"]) where resource.attributes["pod"] != nil
          - set(attributes["namespace"], resource.attributes["namespace"]) where resource.attributes["namespace"] != nil
      # Drop the resource-level raw copies; the datapoint block above already copied
      # them down. Must run after it — statement groups execute in declaration order.
      - context: resource
        statements:
          - delete_key(attributes, "container") where attributes["container"] != nil
          - delete_key(attributes, "pod") where attributes["pod"] != nil
          - delete_key(attributes, "namespace") where attributes["namespace"] != nil

  {{- if .Values.dcgmExporter.enabled }}
  groupbyattrs/cw_k8s_ci_v0_dcgm:
    keys:
      - pod
      - namespace
      - container

  transform/cw_k8s_ci_v0_dcgm_promote:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(attributes["k8s.pod.name"], attributes["pod"]) where attributes["pod"] != nil
          - set(attributes["k8s.namespace.name"], attributes["namespace"]) where attributes["namespace"] != nil
          - set(attributes["k8s.container.name"], attributes["container"]) where attributes["container"] != nil
      - context: datapoint
        statements:
          # Restore raw Prometheus names to datapoint scope (groupbyattrs removed them).
          # The resource-scope copies are deleted after this copy-back.
          - set(attributes["pod"], resource.attributes["pod"]) where resource.attributes["pod"] != nil
          - set(attributes["namespace"], resource.attributes["namespace"]) where resource.attributes["namespace"] != nil
          - set(attributes["container"], resource.attributes["container"]) where resource.attributes["container"] != nil
          # Clean up leftover datapoint attributes not needed downstream.
          - delete_key(attributes, "Hostname") where attributes["Hostname"] != nil
          - delete_key(attributes, "pci_bus_id") where attributes["pci_bus_id"] != nil
      # Drop the resource-level raw copies; the datapoint block above already copied
      # them down. Must run after it — statement groups execute in declaration order.
      - context: resource
        statements:
          - delete_key(attributes, "pod") where attributes["pod"] != nil
          - delete_key(attributes, "namespace") where attributes["namespace"] != nil
          - delete_key(attributes, "container") where attributes["container"] != nil
  {{- end }}

  {{- if .Values.neuronMonitor.enabled }}
  filter/cw_k8s_ci_v0_neuron:
    error_mode: ignore
    metrics:
      metric:
        - IsMatch(name, "^(neuron|execution_|hardware_ecc_)") != true

  awsneuron/cw_k8s_ci_v0:

  groupbyattrs/cw_k8s_ci_v0_neuron:
    keys:
      - k8s.pod.name
      - k8s.namespace.name
      - k8s.container.name
      - runtime_tag

  transform/cw_k8s_ci_v0_neuron_promote:
    error_mode: ignore
    metric_statements:
      - context: resource
        statements:
          - set(attributes["aws.neuron.runtime.tag"], attributes["runtime_tag"]) where attributes["runtime_tag"] != nil
          - delete_key(attributes, "runtime_tag") where attributes["runtime_tag"] != nil

  transform/cw_k8s_ci_v0_neuron_hw_attrs:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(attributes["aws.neuron.device"], attributes["neurondevice"]) where attributes["neurondevice"] != nil
          - set(attributes["aws.neuron.core"], attributes["neuroncore"]) where attributes["neuroncore"] != nil
          - delete_key(attributes, "neuroncore") where attributes["neuroncore"] != nil
          - delete_key(attributes, "neurondevice") where attributes["neurondevice"] != nil
          - delete_key(attributes, "instance_type") where attributes["instance_type"] != nil
  {{- end }}

  awsdevicepodcorrelation/cw_k8s_ci_v0:
    device_types:
      - name: neuron-by-core
        device_id_attribute: neuroncore
        resource_names:
          - aws.amazon.com/neuroncore
      - name: neuron-by-device
        device_id_attribute: neurondevice
        resource_names:
          - aws.amazon.com/neurondevice
          - aws.amazon.com/neuron
      - name: efa
        device_id_attribute: aws.efa.device
        resource_names:
          - vpc.amazonaws.com/efa

  transform/cw_k8s_ci_v0_efa_promote:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["k8s.pod.name"], attributes["k8s.pod.name"]) where attributes["k8s.pod.name"] != nil
          - set(resource.attributes["k8s.namespace.name"], attributes["k8s.namespace.name"]) where attributes["k8s.namespace.name"] != nil
          - set(resource.attributes["k8s.container.name"], attributes["k8s.container.name"]) where attributes["k8s.container.name"] != nil
          - delete_key(attributes, "k8s.pod.name") where attributes["k8s.pod.name"] != nil
          - delete_key(attributes, "k8s.namespace.name") where attributes["k8s.namespace.name"] != nil
          - delete_key(attributes, "k8s.container.name") where attributes["k8s.container.name"] != nil

  transform/cw_k8s_ci_v0_ebs_csi_promote:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["instance_id"], attributes["instance_id"]) where attributes["instance_id"] != nil
          - set(resource.attributes["volume_id"], attributes["volume_id"]) where attributes["volume_id"] != nil
          - delete_key(attributes, "instance_id") where attributes["instance_id"] != nil
          - delete_key(attributes, "volume_id") where attributes["volume_id"] != nil

  transform/cw_k8s_ci_v0_lis_csi_promote:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["instance_id"], attributes["instance_id"]) where attributes["instance_id"] != nil
          - set(resource.attributes["volume_id"], attributes["volume_id"]) where attributes["volume_id"] != nil
          - delete_key(attributes, "instance_id") where attributes["instance_id"] != nil
          - delete_key(attributes, "volume_id") where attributes["volume_id"] != nil

{{- if .Values.otelContainerInsights.logs.enabled }}
  # ── CI Logs processors ──
  transform/cw_k8s_ci_v0_logs_set_workload:
    error_mode: ignore
    log_statements:
      - context: resource
        statements:
          # Derive k8s.workload.name and k8s.workload.type — matches metrics'
          # transform/cw_k8s_ci_v0_set_workload exactly so metrics and logs use
          # the same workload identity for the same pod.
          - set(attributes["k8s.workload.name"], attributes["k8s.deployment.name"]) where attributes["k8s.deployment.name"] != nil
          - set(attributes["k8s.workload.type"], "Deployment") where attributes["k8s.deployment.name"] != nil
          - set(attributes["k8s.workload.name"], attributes["k8s.statefulset.name"]) where attributes["k8s.workload.name"] == nil and attributes["k8s.statefulset.name"] != nil
          - set(attributes["k8s.workload.type"], "StatefulSet") where attributes["k8s.statefulset.name"] != nil and attributes["k8s.workload.type"] == nil
          - set(attributes["k8s.workload.name"], attributes["k8s.daemonset.name"]) where attributes["k8s.workload.name"] == nil and attributes["k8s.daemonset.name"] != nil
          - set(attributes["k8s.workload.type"], "DaemonSet") where attributes["k8s.daemonset.name"] != nil and attributes["k8s.workload.type"] == nil
          - set(attributes["k8s.workload.name"], attributes["k8s.job.name"]) where attributes["k8s.workload.name"] == nil and attributes["k8s.job.name"] != nil
          - set(attributes["k8s.workload.type"], "Job") where attributes["k8s.job.name"] != nil and attributes["k8s.workload.type"] == nil
          - set(attributes["k8s.workload.name"], attributes["k8s.cronjob.name"]) where attributes["k8s.workload.name"] == nil and attributes["k8s.cronjob.name"] != nil
          - set(attributes["k8s.workload.type"], "CronJob") where attributes["k8s.cronjob.name"] != nil and attributes["k8s.workload.type"] == nil
          - set(attributes["k8s.workload.name"], attributes["k8s.replicaset.name"]) where attributes["k8s.workload.name"] == nil and attributes["k8s.replicaset.name"] != nil
          - set(attributes["k8s.workload.type"], "ReplicaSet") where attributes["k8s.replicaset.name"] != nil and attributes["k8s.workload.type"] == nil
          # Derive service.name from k8s.workload.name (OTEL logs semconv).
          # Logs need service.name; metrics use k8s.workload.name directly, except on
          # AKS — see transform/cw_k8s_ci_v0_set_workload.
          - set(attributes["service.name"], attributes["k8s.workload.name"]) where attributes["service.name"] == nil and attributes["k8s.workload.name"] != nil
          {{- if or (eq .Values.k8sMode "AKS") (eq .Values.k8sMode "GKE") }}
          - set(attributes["service.namespace"], attributes["k8s.namespace.name"]) where attributes["service.namespace"] == nil and attributes["k8s.namespace.name"] != nil
          - set(attributes["deployment.environment.name"], Concat([attributes["cloud.platform"], Concat([attributes["k8s.cluster.name"], attributes["k8s.namespace.name"]], "/")], ":")) where attributes["deployment.environment.name"] == nil and attributes["cloud.platform"] != nil and attributes["k8s.cluster.name"] != nil and attributes["k8s.namespace.name"] != nil
          {{- end }}

  transform/cw_k8s_ci_v0_logs_set_cluster_and_node:
    error_mode: ignore
    log_statements:
      - context: resource
        statements:
          - set(attributes["k8s.cluster.name"], "{{ .Values.clusterName }}")
          - set(attributes["k8s.node.name"], "${env:K8S_NODE_NAME}")

  transform/cw_k8s_ci_v0_logs_set_cloud_resource_id:
    error_mode: ignore
    log_statements:
      - context: resource
        statements:
          {{- if eq .Values.k8sMode "AKS" }}
          {{/* Node group -> cluster group, as in transform/cw_k8s_ci_v0_set_cloud_resource_id. */}}
          - set(attributes["_tmp.azure.resourcegroup.name"], attributes["azure.resourcegroup.name"])
            where attributes["azure.resourcegroup.name"] != nil
          - replace_pattern(attributes["_tmp.azure.resourcegroup.name"], "^MC_(.+)_{{ .Values.clusterName }}_[^_]+$", "$$$1")
          - set(attributes["cloud.resource_id"], Concat(["/subscriptions/", attributes["cloud.account.id"], "/resourceGroups/", attributes["_tmp.azure.resourcegroup.name"], "/providers/Microsoft.ContainerService/managedClusters/", attributes["k8s.cluster.name"]], ""))
            where attributes["cloud.account.id"] != nil and attributes["_tmp.azure.resourcegroup.name"] != nil and attributes["k8s.cluster.name"] != nil
          - delete_key(attributes, "_tmp.azure.resourcegroup.name")
          {{- else if eq .Values.k8sMode "GKE" }}
          {{/* GKE full resource name: zones/<zone> (zonal) or locations/<region> (regional). */}}
          - set(attributes["cloud.resource_id"], Concat(["//container.googleapis.com/projects/", attributes["cloud.account.id"], "/zones/", attributes["cloud.availability_zone"], "/clusters/", attributes["k8s.cluster.name"]], ""))
            where attributes["cloud.account.id"] != nil and attributes["cloud.availability_zone"] != nil and attributes["k8s.cluster.name"] != nil
          - set(attributes["cloud.resource_id"], Concat(["//container.googleapis.com/projects/", attributes["cloud.account.id"], "/locations/", attributes["cloud.region"], "/clusters/", attributes["k8s.cluster.name"]], ""))
            where attributes["cloud.resource_id"] == nil and attributes["cloud.account.id"] != nil and attributes["cloud.region"] != nil and attributes["k8s.cluster.name"] != nil
          {{- else }}
          - set(attributes["cloud.resource_id"], Concat(["arn:aws:eks:", attributes["cloud.region"], ":", attributes["cloud.account.id"], ":cluster/", attributes["k8s.cluster.name"]], ""))
            where attributes["cloud.region"] != nil and attributes["cloud.account.id"] != nil and attributes["k8s.cluster.name"] != nil
          {{- end }}

  transform/cw_k8s_ci_v0_logs_clear_schema_url:
    error_mode: ignore
    log_statements:
      - context: resource
        statements:
          - set(resource.schema_url, "")

  # Scope transforms — tag each logs pipeline with cloudwatch.source/solution/pipeline
  # for backend attribution. Matches the metrics pipeline's transform/set_scope_*
  # processors so logs are attributed identically to metrics.
  # scope.name is intentionally not set — the metrics pipeline sets it only for
  # pipelines with a well-known source library (e.g., github.com/google/cadvisor).
  # filelog receivers don't have an equivalent upstream library, so scope.name is
  # omitted (matches metrics' set_scope_efa / set_scope_ebs_csi /
  # set_scope_kubeletstats which also omit scope.name).
  transform/cw_k8s_ci_v0_logs_set_scope_app:
    error_mode: ignore
    log_statements:
      - context: scope
        statements:
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "application-logs")

  transform/cw_k8s_ci_v0_logs_set_scope_host:
    error_mode: ignore
    log_statements:
      - context: scope
        statements:
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "host-logs")

{{- if $rayLogs }}

  # Ray logs: the fields of a Ray Serve JSON record (logging_config.encoding: JSON)
  # become attributes, so that a record joins its trace through request_id. The body
  # stays the line as written. The level of a text record is read from its prefix in
  # the Serve, Python and C++ formats of Ray and in vLLM's format, also after vLLM's
  # "(EngineCore pid=7165) " subprocess prefix.
  transform/cw_k8s_ci_v0_ray_logs_parse:
    error_mode: ignore
    log_statements:
      - context: log
        statements:
          - merge_maps(cache, ParseJSON(body), "upsert") where IsString(body) and IsMatch(body, "^\\{")
          - set(attributes["request_id"], cache["request_id"]) where IsString(cache["request_id"])
          - set(attributes["application"], cache["application"]) where IsString(cache["application"])
          - set(attributes["deployment"], cache["deployment"]) where IsString(cache["deployment"])
          - set(attributes["replica"], cache["replica"]) where IsString(cache["replica"])
          - set(attributes["route"], cache["route"]) where IsString(cache["route"])
          - set(severity_text, cache["levelname"]) where IsString(cache["levelname"])
          - merge_maps(cache, ExtractPatterns(body, "^(?P<level>DEBUG|INFO|WARNING|ERROR|CRITICAL) \\d{4}-\\d{2}-\\d{2} "), "upsert") where cache["levelname"] == nil and IsString(body)
          - merge_maps(cache, ExtractPatterns(body, "^(?:\\([\\w.-]+ pid=\\d+\\) )*\\d{4}-\\d{2}-\\d{2} [0-9:,.]+\\t(?P<level>DEBUG|INFO|WARNING|ERROR|CRITICAL) "), "upsert") where cache["levelname"] == nil and cache["level"] == nil and IsString(body)
          - merge_maps(cache, ExtractPatterns(body, "^(?:\\([\\w.-]+ pid=\\d+\\) )*(?P<level>DEBUG|INFO|WARNING|ERROR|CRITICAL) \\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2} \\["), "upsert") where cache["levelname"] == nil and cache["level"] == nil and IsString(body)
          - merge_maps(cache, ExtractPatterns(body, "^\\[\\d{4}-\\d{2}-\\d{2} [0-9:,.]+ (?P<level>[DIWEF]) "), "upsert") where cache["levelname"] == nil and cache["level"] == nil and IsString(body)
          - set(severity_text, cache["level"]) where IsString(cache["level"]) and Len(cache["level"]) > 1
          - set(severity_text, "DEBUG") where cache["level"] == "D"
          - set(severity_text, "INFO") where cache["level"] == "I"
          - set(severity_text, "WARNING") where cache["level"] == "W"
          - set(severity_text, "ERROR") where cache["level"] == "E"
          - set(severity_text, "FATAL") where cache["level"] == "F"
          - set(severity_number, SEVERITY_NUMBER_DEBUG) where severity_text == "DEBUG"
          - set(severity_number, SEVERITY_NUMBER_INFO) where severity_text == "INFO"
          - set(severity_number, SEVERITY_NUMBER_WARN) where severity_text == "WARNING"
          - set(severity_number, SEVERITY_NUMBER_ERROR) where severity_text == "ERROR"
          - set(severity_number, SEVERITY_NUMBER_FATAL) where severity_text == "CRITICAL" or severity_text == "FATAL"

  # Same rule as transform/cw_k8s_ci_v0_ray_service_name of the Ray metrics:
  # service.name is the workload name, else the pod name. KubeRay pods are owned by a
  # RayCluster, which is not a workload kind, so it is the pod name. The
  # app.kubernetes.io/name label is not used: KubeRay sets it to "kuberay" on every
  # Ray pod.
  transform/cw_k8s_ci_v0_ray_logs_service_name:
    error_mode: ignore
    log_statements:
      - context: resource
        statements:
          - set(attributes["service.name"], attributes["k8s.pod.name"]) where attributes["service.name"] == nil and attributes["k8s.pod.name"] != nil

  transform/cw_k8s_ci_v0_logs_set_scope_ray:
    error_mode: ignore
    log_statements:
      - context: scope
        statements:
          - set(scope.schema_url, "")
          - set(attributes["cloudwatch.source"], "cloudwatch-agent")
          - set(attributes["cloudwatch.solution"], "k8s-otel-container-insights")
          - set(attributes["cloudwatch.pipeline"], "ray-logs")
{{- end }}

  batch/cw_k8s_ci_v0_logs_dest:
    send_batch_size: 500
    send_batch_max_size: 500
    timeout: 5s
{{- end }}

exporters:
  otlphttp/cw_k8s_ci_v0_metrics_dest:
    endpoint: {{ if .Values.otelContainerInsights.cloudwatchMetricsEndpoint }}{{ .Values.otelContainerInsights.cloudwatchMetricsEndpoint | quote }}{{ else }}"https://monitoring.{{ .Values.region }}.amazonaws.com:443"{{ end }}
    tls:
      insecure: false
    auth:
      authenticator: sigv4auth/cw_k8s_ci_v0_metrics_dest

{{- if .Values.otelContainerInsights.logs.enabled }}
  otlphttp/cw_k8s_ci_v0_app_logs_dest:
    endpoint: {{ if .Values.otelContainerInsights.cloudwatchLogsEndpoint }}{{ .Values.otelContainerInsights.cloudwatchLogsEndpoint | quote }}{{ else if hasKey .Values.adcEndpointOverrides .Values.region }}"https://logs.{{ .Values.region }}.{{ index .Values.adcEndpointOverrides .Values.region }}:443"{{ else }}"https://logs.{{ .Values.region }}.amazonaws.com:443"{{ end }}
    # compression: none matches FluentBit's current behavior (the aws-for-fluent-bit
    # cloudwatch_logs plugin does not compress by default), so customers migrating
    # from FluentBit see no bandwidth bill change. Enabling compression: gzip is
    # available as an opt-in bandwidth optimization (~5–10× reduction for typical
    # container logs) at the cost of +25% agent CPU — customers who raise the CPU
    # limit accordingly can improve on FluentBit's bandwidth cost. See OTELify CI
    # Logs Pipeline Optimizations doc for details.
    compression: none
    headers:
      x-aws-log-group: "/aws/otel/containerinsights/{{ .Values.clusterName }}/application"
      x-aws-log-stream: "${env:K8S_NODE_NAME}-application"
    sending_queue:
      queue_size: 500
      num_consumers: 10
    tls:
      insecure: false
    auth:
      authenticator: awscloudwatchlogsprovisioner/cw_k8s_ci_v0_logs

  otlphttp/cw_k8s_ci_v0_node_logs_dest:
    endpoint: {{ if .Values.otelContainerInsights.cloudwatchLogsEndpoint }}{{ .Values.otelContainerInsights.cloudwatchLogsEndpoint | quote }}{{ else if hasKey .Values.adcEndpointOverrides .Values.region }}"https://logs.{{ .Values.region }}.{{ index .Values.adcEndpointOverrides .Values.region }}:443"{{ else }}"https://logs.{{ .Values.region }}.amazonaws.com:443"{{ end }}
    # See app_logs_dest comment for compression tradeoff rationale.
    compression: none
    headers:
      x-aws-log-group: "/aws/otel/containerinsights/{{ .Values.clusterName }}/host"
      x-aws-log-stream: "${env:K8S_NODE_NAME}-host"
    sending_queue:
      queue_size: 500
      num_consumers: 10
    tls:
      insecure: false
    auth:
      authenticator: awscloudwatchlogsprovisioner/cw_k8s_ci_v0_logs

{{- end }}

{{- if $configInfo }}

connectors:
  # vLLM engine configuration as an Info metric: one vllm_engine_config_info series
  # (gauge, value 1) per vLLM container, parsed from the engine startup log line. A
  # second receiver of metrics/cw_k8s_ci_v0_vllm. With logs on, it is a second
  # exporter of logs/cw_k8s_ci_v0_app, so it adds no pipeline. With logs off, it is
  # the exporter of logs/cw_k8s_ci_v0_vllm_info. The latest facts per container are
  # kept in file_storage/cw_k8s_ci_v0_state and re-sent every emit_interval, so they
  # outlive both the log line and an agent restart.
  #
  # The rule is the same as connector/signaltoinfometricconnector/testdata/vllm_rule.yaml
  # in the amazon-cloudwatch-agent repository. A change to one of them needs the same
  # change in the other.
  #
  # Escaping: these OTTL strings are YAML single-quoted (or block) scalars, so YAML
  # keeps every backslash; OTTL then turns each \\ into the one backslash the regex
  # needs. No pattern may contain a $, which the collector's confmap would expand.
  # A pattern that does not match is an evaluation error: the fact is then omitted
  # (optional), replaced (default_value), or the line is not used (required).
  signal_to_info_metric/cw_k8s_ci_v0_vllm:
    storage: file_storage/cw_k8s_ci_v0_state
    emit_interval: {{ include "otel-container-insights.vllmInfoEmitInterval" . }}
    max_state_bytes: {{ include "otel-container-insights.vllmInfoInt" (dict "name" "maxStateBytes" "value" .Values.otelContainerInsights.solutions.vllm.configInfo.maxStateBytes "min" 65536 "max" 67108864) }}
    max_value_length: {{ include "otel-container-insights.vllmInfoInt" (dict "name" "maxValueLength" "value" .Values.otelContainerInsights.solutions.vllm.configInfo.maxValueLength "min" 1 "max" 1024) }}
    rules:
      - name: vllm_engine_config_info
        description: vLLM engine configuration parsed from the engine startup log line. The value is always 1.
        # Plain substring match, no regex: the startup line of every vLLM version,
        # from before the V0/V1 split ("an LLM engine") to the V1 engine.
        body_contains:
          - "Initializing an LLM engine (v"
          - "Initializing a V0 LLM engine (v"
          - "Initializing a V1 LLM engine (v"
        # With logs on, the identity comes from the log file name,
        # /var/log/containers/<pod>_<namespace>_<container>-<id>.log, which kubelet
        # creates and filelog/cw_k8s_ci_v0_app parses, so every record has it and it
        # does not wait for the k8sattributes pod cache. With logs off,
        # receiver_creator/cw_k8s_ci_v0_vllm_logs sets it from the pod watch. One
        # series per container. The connector requires every identity key in
        # include_resource_attributes.
        #
        # k8s.pod.uid is the UID of the pod that logged the startup line. With logs on,
        # it comes from k8sattributes/cw_k8s_ci_v0_pod of logs/cw_k8s_ci_v0_app. With
        # logs off, it comes from the pod watch. A record without it stores no UID. A
        # changed included value counts as changed facts, so a new pod's startup line
        # replaces the stored UID.
        # filter/cw_k8s_ci_v0_vllm_info_live drops the series while the stored UID is
        # not the UID of the live pod with that name: a pod replaced under the same name
        # (a StatefulSet pod) has no series until its own startup line arrives. It also
        # drops the series of a deleted pod.
        identity: [k8s.namespace.name, k8s.pod.name, k8s.container.name]
        include_resource_attributes: [k8s.namespace.name, k8s.pod.name, k8s.container.name, k8s.pod.uid]
        max_entities: {{ include "otel-container-insights.vllmInfoInt" (dict "name" "maxEntities" "value" .Values.otelContainerInsights.solutions.vllm.configInfo.maxEntities "min" 1 "max" 100000) }}
        # A line that yields no vllm_version or model is not used. Every other fact is
        # optional, because older vLLM versions do not log all of them.
        attributes:
          - key: vllm_version
            value: 'ExtractPatterns(log.body, "Initializing an? (?:V[01] )?LLM engine \\(v(?P<v>[^)]+)\\) with config: ")["v"]'
          # Block scalar: the pattern contains single quotes.
          - key: model
            value: |-
              ExtractPatterns(log.body, "with config: model='(?P<v>[^']*)'")["v"]
          # Lines from before the V0/V1 split read "Initializing an LLM engine": V0.
          # (The connector rejects optional together with default_value.)
          - key: vllm_engine
            value: 'ExtractPatterns(log.body, "Initializing a (?P<v>V[01]) LLM engine")["v"]'
            default_value: V0
          - key: served_model_name
            value: 'ExtractPatterns(log.body, ", served_model_name=(?P<v>[^,]+),")["v"]'
            optional: true
          - key: dtype
            value: 'ExtractPatterns(log.body, ", dtype=(?:torch\\.)?(?P<v>[A-Za-z0-9_]+),")["v"]'
            optional: true
          - key: max_seq_len
            value: 'ExtractPatterns(log.body, ", max_seq_len=(?P<v>\\d+),")["v"]'
            optional: true
          - key: tensor_parallel_size
            value: 'ExtractPatterns(log.body, ", tensor_parallel_size=(?P<v>\\d+),")["v"]'
            optional: true
          - key: pipeline_parallel_size
            value: 'ExtractPatterns(log.body, ", pipeline_parallel_size=(?P<v>\\d+),")["v"]'
            optional: true
          - key: data_parallel_size
            value: 'ExtractPatterns(log.body, ", data_parallel_size=(?P<v>\\d+),")["v"]'
            optional: true
          - key: quantization
            value: 'ExtractPatterns(log.body, ", quantization=(?P<v>[A-Za-z0-9_.\\-]+),")["v"]'
            optional: true
          - key: enforce_eager
            value: 'ExtractPatterns(log.body, ", enforce_eager=(?P<v>True|False),")["v"]'
            optional: true
          - key: kv_cache_dtype
            value: 'ExtractPatterns(log.body, ", kv_cache_dtype=(?P<v>[A-Za-z0-9_]+),")["v"]'
            optional: true
          - key: enable_prefix_caching
            value: 'ExtractPatterns(log.body, ", enable_prefix_caching=(?P<v>True|False|None),")["v"]'
            optional: true
          # The method name, or "None" when the engine runs without speculative decoding.
          # Block scalar: the pattern contains single quotes.
          - key: speculative_method
            value: |-
              ExtractPatterns(log.body, "speculative_config=(?:SpeculativeConfig\\(method=')?(?P<v>None|[^',)]+)")["v"]
            optional: true
{{- end }}

service:
  # Pin internal self-telemetry off. Without this the collector falls back to its
  # built-in default (metrics level Normal + a Prometheus reader on localhost:8888),
  # which collides with the co-scheduled cluster-scraper on the node's :8888.
  telemetry:
    metrics:
      level: none
  extensions:
    - sigv4auth/cw_k8s_ci_v0_metrics_dest
{{- if .Values.otelContainerInsights.logs.enabled }}
    - sigv4auth/cw_k8s_ci_v0_logs_dest
    - awscloudwatchlogsprovisioner/cw_k8s_ci_v0_logs
{{- end }}
{{- if $stateStorage }}
    - file_storage/cw_k8s_ci_v0_state
{{- end }}
{{- if $infoLogsOff }}
    - k8s_observer/cw_k8s_ci_v0_vllm
{{- end }}
{{- if $rayLogs }}
    - k8s_observer/cw_k8s_ci_v0_ray
{{- end }}
  pipelines:
{{- if .Values.nodeExporter.enabled }}
    metrics/cw_k8s_ci_v0_node_exporter:
      receivers: [prometheus/cw_k8s_ci_v0_node_exporter]
      processors:
        - filter/cw_k8s_ci_v0_scrape_metadata
        - transform/cw_k8s_ci_v0_drop_deprecated_semconv
        - transform/cw_k8s_ci_v0_set_unit
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cluster_name
        - transform/cw_k8s_ci_v0_set_node_name
        - transform/cw_k8s_ci_v0_promote_node_name
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_node
        - transform/cw_k8s_ci_v0_set_scope_node_exporter
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_workload
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest
{{- end }}

    metrics/cw_k8s_ci_v0_cadvisor:
      receivers: [prometheus/cw_k8s_ci_v0_cadvisor]
      processors:
        - filter/cw_k8s_ci_v0_scrape_metadata
        - transform/cw_k8s_ci_v0_drop_deprecated_semconv
        - transform/cw_k8s_ci_v0_set_unit
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cluster_name
        - filter/cw_k8s_ci_v0_cadvisor_empty
        - filter/cw_k8s_ci_v0_cadvisor_pod
        - filter/cw_k8s_ci_v0_cadvisor_rollup
        - groupbyattrs/cw_k8s_ci_v0_cadvisor
        - transform/cw_k8s_ci_v0_cadvisor_promote
        - transform/cw_k8s_ci_v0_set_node_name
        - transform/cw_k8s_ci_v0_promote_node_name
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_node
        - k8sattributes/cw_k8s_ci_v0_pod
        - transform/cw_k8s_ci_v0_set_scope_cadvisor
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_workload
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest

    {{- if .Values.dcgmExporter.enabled }}
    metrics/cw_k8s_ci_v0_dcgm:
      receivers: [prometheus/cw_k8s_ci_v0_dcgm]
      processors: [filter/cw_k8s_ci_v0_scrape_metadata, transform/cw_k8s_ci_v0_drop_deprecated_semconv, transform/cw_k8s_ci_v0_set_unit, metricstarttime/cw_k8s_ci_v0, transform/cw_k8s_ci_v0_set_cluster_name, groupbyattrs/cw_k8s_ci_v0_dcgm, transform/cw_k8s_ci_v0_dcgm_promote, k8sattributes/cw_k8s_ci_v0_pod, transform/cw_k8s_ci_v0_set_node_name, transform/cw_k8s_ci_v0_promote_node_name, k8sattributes/cw_k8s_ci_v0_node, resourcedetection/cw_k8s_ci_v0, transform/cw_k8s_ci_v0_set_scope_dcgm, transform/cw_k8s_ci_v0_clear_schema_url, transform/cw_k8s_ci_v0_set_cloud_resource_id, transform/cw_k8s_ci_v0_set_workload, awsattributelimit/cw_k8s_ci_v0, batch/cw_k8s_ci_v0_metrics_dest]
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest
    {{- end }}

    {{- if .Values.neuronMonitor.enabled }}
    metrics/cw_k8s_ci_v0_neuron:
      receivers: [prometheus/cw_k8s_ci_v0_neuron]
      processors:
        - filter/cw_k8s_ci_v0_scrape_metadata
        - transform/cw_k8s_ci_v0_drop_deprecated_semconv
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cluster_name
        - filter/cw_k8s_ci_v0_neuron
        - awsneuron/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_unit
        - awsdevicepodcorrelation/cw_k8s_ci_v0
        - groupbyattrs/cw_k8s_ci_v0_neuron
        - transform/cw_k8s_ci_v0_neuron_promote
        - transform/cw_k8s_ci_v0_neuron_hw_attrs
        - k8sattributes/cw_k8s_ci_v0_pod
        - transform/cw_k8s_ci_v0_set_node_name
        - transform/cw_k8s_ci_v0_promote_node_name
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_node
        - transform/cw_k8s_ci_v0_set_scope_neuron_monitor
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_workload
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest
    {{- end }}

    metrics/cw_k8s_ci_v0_efa:
      receivers: [awsefareceiver/cw_k8s_ci_v0]
      processors:
        - transform/cw_k8s_ci_v0_set_unit
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_scope_efa
        - transform/cw_k8s_ci_v0_set_cluster_name
        - awsdevicepodcorrelation/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_efa_promote
        - transform/cw_k8s_ci_v0_set_node_name
        - transform/cw_k8s_ci_v0_promote_node_name
        - k8sattributes/cw_k8s_ci_v0_pod
        - k8sattributes/cw_k8s_ci_v0_node
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - transform/cw_k8s_ci_v0_set_workload
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest

    metrics/cw_k8s_ci_v0_ebs_csi_node:
      receivers: [prometheus/cw_k8s_ci_v0_ebs_csi_node]
      processors:
        - filter/cw_k8s_ci_v0_scrape_metadata
        - transform/cw_k8s_ci_v0_drop_deprecated_semconv
        - transform/cw_k8s_ci_v0_set_unit
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cluster_name
        - transform/cw_k8s_ci_v0_ebs_csi_promote
        - transform/cw_k8s_ci_v0_set_node_name
        - transform/cw_k8s_ci_v0_promote_node_name
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_node
        - transform/cw_k8s_ci_v0_set_scope_ebs_csi
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_workload
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest

{{- if and .Values.otelContainerInsights.solutions.enabled .Values.otelContainerInsights.solutions.vllm.enabled }}
    metrics/cw_k8s_ci_v0_vllm:
      {{- if $configInfo }}
      receivers: [prometheus/cw_k8s_ci_v0_vllm, signal_to_info_metric/cw_k8s_ci_v0_vllm]
      {{- else }}
      receivers: [prometheus/cw_k8s_ci_v0_vllm]
      {{- end }}
      processors:
        - filter/cw_k8s_ci_v0_scrape_metadata
        - filter/cw_k8s_ci_v0_vllm_keep
        - transform/cw_k8s_ci_v0_drop_deprecated_semconv
        - transform/cw_k8s_ci_v0_set_unit
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cluster_name
        - transform/cw_k8s_ci_v0_vllm_promote
        {{- if $configInfo }}
        # Sets the Info metric's stored pod UID aside, so k8sattributes adds the live one.
        - transform/cw_k8s_ci_v0_vllm_info_uid
        {{- end }}
        - k8sattributes/cw_k8s_ci_v0_pod
        {{- if $configInfo }}
        # Right after k8sattributes adds the live pod's k8s.pod.uid: drop stale Info
        # data points, then remove the stored UID.
        - filter/cw_k8s_ci_v0_vllm_info_live
        - transform/cw_k8s_ci_v0_vllm_info_cleanup
        {{- end }}
        - transform/cw_k8s_ci_v0_set_node_name
        - transform/cw_k8s_ci_v0_promote_node_name
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_node
        - transform/cw_k8s_ci_v0_set_scope_vllm
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_workload
        - transform/cw_k8s_ci_v0_vllm_service_name
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest
{{- end }}

    metrics/cw_k8s_ci_v0_lis_csi_node:
      receivers: [prometheus/cw_k8s_ci_v0_lis_csi_node]
      processors:
        - filter/cw_k8s_ci_v0_scrape_metadata
        - transform/cw_k8s_ci_v0_drop_deprecated_semconv
        - transform/cw_k8s_ci_v0_set_unit
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cluster_name
        - transform/cw_k8s_ci_v0_lis_csi_promote
        - transform/cw_k8s_ci_v0_set_node_name
        - transform/cw_k8s_ci_v0_promote_node_name
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_node
        - transform/cw_k8s_ci_v0_set_scope_lis_csi
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_workload
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest

{{- if and .Values.otelContainerInsights.solutions.enabled .Values.otelContainerInsights.solutions.knative.dataPlane.enabled }}
    metrics/cw_k8s_ci_v0_knative_dataplane:
      receivers: [prometheus/cw_k8s_ci_v0_knative_dataplane]
      processors:
        - filter/cw_k8s_ci_v0_scrape_metadata
        - filter/cw_k8s_ci_v0_knative_dataplane_keep
        - transform/cw_k8s_ci_v0_drop_deprecated_semconv
        - transform/cw_k8s_ci_v0_set_unit
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cluster_name
        - transform/cw_k8s_ci_v0_knative_dataplane_promote
        - k8sattributes/cw_k8s_ci_v0_pod
        - transform/cw_k8s_ci_v0_set_node_name
        - transform/cw_k8s_ci_v0_promote_node_name
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_node
        - transform/cw_k8s_ci_v0_set_scope_knative_dataplane
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_workload
        - transform/cw_k8s_ci_v0_knative_dataplane_service_type
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest
{{- end }}

    metrics/cw_k8s_ci_v0_kubeletstats:
      receivers: [kubeletstats/cw_k8s_ci_v0]
      processors:
        - metricstarttime/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_scope_kubeletstats
        - transform/cw_k8s_ci_v0_set_cluster_name
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_pod
        - k8sattributes/cw_k8s_ci_v0_node
        - transform/cw_k8s_ci_v0_clear_schema_url
        - transform/cw_k8s_ci_v0_set_workload
        - awsattributelimit/cw_k8s_ci_v0
        - batch/cw_k8s_ci_v0_metrics_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_metrics_dest

{{- if .Values.otelContainerInsights.logs.enabled }}
    # ── CI Logs pipelines ──
    logs/cw_k8s_ci_v0_app:
      receivers: [filelog/cw_k8s_ci_v0_app]
      processors:
        - transform/cw_k8s_ci_v0_logs_set_cluster_and_node
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_logs_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_node
        - k8sattributes/cw_k8s_ci_v0_pod
        - transform/cw_k8s_ci_v0_logs_set_scope_app
        - transform/cw_k8s_ci_v0_logs_clear_schema_url
        - transform/cw_k8s_ci_v0_logs_set_workload
        - batch/cw_k8s_ci_v0_logs_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_app_logs_dest
        {{- if $configInfo }}
        # The vLLM config Info metric connector, a second exporter. It keys on the
        # k8s.namespace.name, k8s.pod.name and k8s.container.name that the receiver
        # parses from the log file name, and stores the k8s.pod.uid that
        # k8sattributes/cw_k8s_ci_v0_pod of this chain adds.
        - signal_to_info_metric/cw_k8s_ci_v0_vllm
        {{- end }}

    # ── CI Logs: Host pipeline ──
    # Intentionally omits k8sattributes/pod and set_workload — host logs
    # (/var/log/messages, /var/log/dmesg, /var/log/secure) come from the node OS
    # and have no pod/workload context to enrich from. k8sattributes/node adds
    # node-level labels; cluster + cloud attributes apply as with other pipelines.
    # service.name is intentionally not set — host logs are node-level, not
    # service-level. Customers query host logs by k8s.node.name + log group.
    logs/cw_k8s_ci_v0_node:
      receivers: [filelog/cw_k8s_ci_v0_node]
      processors:
        - transform/cw_k8s_ci_v0_logs_set_cluster_and_node
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_logs_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_node
        - transform/cw_k8s_ci_v0_logs_set_scope_host
        - transform/cw_k8s_ci_v0_logs_clear_schema_url
        - batch/cw_k8s_ci_v0_logs_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_node_logs_dest
{{- end }}

{{- if $rayLogs }}

    # ── Ray logs ──
    # The Ray log files of the Ray pods of this node, into the application log group,
    # with the pod and workload attributes of the application logs.
    logs/cw_k8s_ci_v0_ray:
      receivers: [receiver_creator/cw_k8s_ci_v0_ray_logs]
      processors:
        - transform/cw_k8s_ci_v0_logs_set_cluster_and_node
        - resourcedetection/cw_k8s_ci_v0
        - transform/cw_k8s_ci_v0_logs_set_cloud_resource_id
        - k8sattributes/cw_k8s_ci_v0_node
        - k8sattributes/cw_k8s_ci_v0_pod
        - transform/cw_k8s_ci_v0_ray_logs_parse
        - transform/cw_k8s_ci_v0_logs_set_scope_ray
        - transform/cw_k8s_ci_v0_logs_clear_schema_url
        - transform/cw_k8s_ci_v0_logs_set_workload
        - transform/cw_k8s_ci_v0_ray_logs_service_name
        - batch/cw_k8s_ci_v0_logs_dest
      exporters:
        - otlphttp/cw_k8s_ci_v0_app_logs_dest
{{- end }}

{{- if $infoLogsOff }}

    # ── vLLM config Info metric, logs-off mode ──
    # Ships no logs. Every record of a vLLM container goes straight to the connector,
    # with no processors. The connector checks each body for the startup line.
    logs/cw_k8s_ci_v0_vllm_info:
      receivers: [receiver_creator/cw_k8s_ci_v0_vllm_logs]
      exporters: [signal_to_info_metric/cw_k8s_ci_v0_vllm]
{{- end }}

{{- end -}}
