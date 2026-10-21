#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins the shape of the vLLM engine config Info metric
# (otelContainerInsights.solutions.vllm.configInfo) and of the shared agent state
# storage (otelContainerInsights.stateStorage).
#
# The agent's signal_to_info_metric connector turns the vLLM engine startup log line
# into vllm_engine_config_info. What this script guards:
#
#   1. Off by default, and inert while off: an agent image without the connector
#      fails to start on an unknown component, so the default render must not change.
#      Opt-in: with BASE_REF set (for example BASE_REF=origin/main), every render with
#      both new flags off (or without effect) is also compared byte for byte, generated
#      certificates redacted, with the chart at that ref.
#   2. One switch: the metric renders only with otelContainerInsights.enabled,
#      solutions.enabled, solutions.vllm.enabled and configInfo.enabled.
#   3. Logs on: no new pipeline. The connector is a second exporter of
#      logs/cw_k8s_ci_v0_app and a second receiver of metrics/cw_k8s_ci_v0_vllm.
#      Opt-in: with LOGS_ON_REF set to the commit that shipped the metric with logs on
#      only (the change before this one), every logs-on render, and every logs-off
#      render with configInfo off, is compared byte for byte with the chart at that
#      ref. A failing render must fail with the same message.
#   4. Logs off: k8s_observer/cw_k8s_ci_v0_vllm watches the pods of the node, and
#      receiver_creator/cw_k8s_ci_v0_vllm_logs starts one filelog receiver for each
#      container that the vLLM scrape rule finds. logs/cw_k8s_ci_v0_vllm_info feeds the
#      connector. The receiver reads only the newest restart file of the container,
#      from the start, with no checkpoints. Apart from these components, the storage,
#      the Info metric processors and the state volume, the render is the logs-off
#      render with configInfo off. No /var/log mount, only the existing /var/log/pods one.
#   5. Identity: the connector keys on the namespace, pod and container of the record,
#      and also stores its k8s.pod.uid. Before k8sattributes, that stored UID is set
#      aside. Right after it, the Info metric is dropped when the live pod has no UID
#      (it is gone) or a UID other than the stored one (a pod replaced under the same
#      name), then the stored UID is removed. No scraped vllm:* or http_* series is
#      ever dropped. The metrics side is the same in both modes.
#   6. Storage: one file_storage extension, a writable hostPath on the node agent
#      DaemonSet only, and maxSurge 0. configInfo does not change log shipping: the
#      app-log receiver checkpoints only with stateStorage.enabled. With logs off and
#      configInfo off, the storage does not render, as no component uses it.
#   7. The connector's OTTL survives the three escaping layers (Helm text, YAML,
#      OTTL strings): each pattern is unescaped as OTTL would and run against sample
#      vLLM startup lines. Opt-in: with VLLM_RULE_FILE set to the connector's
#      testdata/vllm_rule.yaml in the amazon-cloudwatch-agent repository, the rendered
#      rules are also compared with the rules in that file.
#   8. In every render, every defined component is used and every used component is
#      defined.
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text.
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/vllm_config_info_shape.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"
BASE_REF="${BASE_REF:-}"
LOGS_ON_REF="${LOGS_ON_REF:-}"
VLLM_RULE_FILE="${VLLM_RULE_FILE:-}"
JOBS="$(nproc 2>/dev/null || echo 4)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

CI=otelContainerInsights
CONFIG_INFO="${CI}.solutions.vllm.configInfo"
COMMON=(--set region=us-west-2 --set clusterName=test-cluster)
OTEL=(--set "${CI}.enabled=true")
INFO=(--set "${CONFIG_INFO}.enabled=true")
LOGS_OFF=(--set "${CI}.logs.enabled=false")
STORAGE_ON=(--set "${CI}.stateStorage.enabled=true")
# Every new setting changed while both new flags stay off: must change nothing.
OFF_TUNED=(--set "${CI}.stateStorage.hostPath=/var/lib/elsewhere"
           --set "${CONFIG_INFO}.emitInterval=15s"
           --set "${CONFIG_INFO}.pollInterval=10s"
           --set "${CONFIG_INFO}.maxEntities=7"
           --set "${CONFIG_INFO}.maxStateBytes=70000"
           --set "${CONFIG_INFO}.maxValueLength=9")
# Each value out of its bounds: fails the render while the setting takes effect.
OUT_OF_BOUNDS=(--set "${CI}.stateStorage.hostPath=relative/dir"
               --set "${CONFIG_INFO}.emitInterval=0s"
               --set "${CONFIG_INFO}.pollInterval=500ms"
               --set "${CONFIG_INFO}.maxEntities=0"
               --set "${CONFIG_INFO}.maxStateBytes=1000"
               --set "${CONFIG_INFO}.maxValueLength=2000")
POLL_10S=(--set "${CONFIG_INFO}.pollInterval=10s")
MAX_SURGE_1=(--set agent.updateStrategy.rollingUpdate.maxUnavailable=0
             --set agent.updateStrategy.rollingUpdate.maxSurge=1)
AGENTS_SURGE_10=(--set 'agents[0].name=cloudwatch-agent'
                 --set 'agents[0].updateStrategy.type=RollingUpdate'
                 --set 'agents[0].updateStrategy.rollingUpdate.maxUnavailable=0'
                 --set 'agents[0].updateStrategy.rollingUpdate.maxSurge=10%'
                 --set 'agents[1].name=cloudwatch-agent-cluster-scraper'
                 --set 'agents[1].mode=deployment'
                 --set 'agents[1].config=default')

# render <chart> <name> [helm args...]: writes <name>.yaml, <name>.err and <name>.rc.
# Runs in the background, JOBS at a time. The renders are complete after wait.
QUEUED=0
render() {
    local chart="$1" name="$2"
    shift 2
    (
        rc=0
        "$HELM" template cw "$chart" --namespace amazon-cloudwatch "${COMMON[@]}" "$@" \
            > "${TMP_DIR}/${name}.yaml" 2> "${TMP_DIR}/${name}.err" || rc=$?
        echo "$rc" > "${TMP_DIR}/${name}.rc"
    ) &
    QUEUED=$((QUEUED + 1))
    if (( QUEUED % JOBS == 0 )); then
        wait
    fi
}

# extract_ref <ref> <dir>: the chart at a git ref, into dir. Prints ok or unresolved.
extract_ref() {
    local ref="$1" dir="$2" prefix top
    if prefix="$(git -C "$CHART_DIR" rev-parse --show-prefix 2>/dev/null)" &&
            top="$(git -C "$CHART_DIR" rev-parse --show-toplevel 2>/dev/null)" &&
            git -C "$top" rev-parse --verify --quiet "${ref}^{commit}" > /dev/null; then
        mkdir -p "$dir"
        # From the top level: run in a subdirectory, git archive keeps only that subdirectory.
        git -C "$top" archive --format=tar "${ref}:${prefix%/}" | tar -x -C "$dir"
        echo ok
    else
        echo unresolved
    fi
}

# The chart at BASE_REF and at LOGS_ON_REF, for the byte-identity checks.
BASE_STATUS="skipped: set BASE_REF (for example BASE_REF=origin/main) to compare"
if [[ -n "$BASE_REF" ]]; then
    BASE_STATUS="$(extract_ref "$BASE_REF" "${TMP_DIR}/base")"
fi
LOGS_ON_STATUS="skipped: set LOGS_ON_REF (the commit that shipped the metric with logs on only) to compare"
if [[ -n "$LOGS_ON_REF" ]]; then
    LOGS_ON_STATUS="$(extract_ref "$LOGS_ON_REF" "${TMP_DIR}/logs_on")"
fi

# same_as_logs_on <name> [helm args...]: renders <name>, and logs_on_<name> with the chart at
# LOGS_ON_REF. same_as_base also renders base_<name> with the chart at BASE_REF.
: > "${TMP_DIR}/logs_on_names"
: > "${TMP_DIR}/base_names"
same_as_logs_on() {
    local name="$1"
    shift
    echo "$name" >> "${TMP_DIR}/logs_on_names"
    render "$CHART_DIR" "$name" "$@"
    if [[ "$LOGS_ON_STATUS" == "ok" ]]; then
        render "${TMP_DIR}/logs_on" "logs_on_${name}" "$@"
    fi
}
same_as_base() {
    local name="$1"
    shift
    echo "$name" >> "${TMP_DIR}/base_names"
    same_as_logs_on "$name" "$@"
    if [[ "$BASE_STATUS" == "ok" ]]; then
        render "${TMP_DIR}/base" "base_${name}" "$@"
    fi
}

# Logs on, or the flags without effect.
same_as_base default
same_as_base logs_on "${OTEL[@]}"
same_as_base logs_on_tuned "${OTEL[@]}" "${OFF_TUNED[@]}"
same_as_base logs_on_surge "${OTEL[@]}" "${MAX_SURGE_1[@]}"
same_as_base vllm_off "${OTEL[@]}" --set "${CI}.solutions.vllm.enabled=false"
same_as_base info_vllm_off "${OTEL[@]}" "${INFO[@]}" --set "${CI}.solutions.vllm.enabled=false"
same_as_base solutions_off "${OTEL[@]}" --set "${CI}.solutions.enabled=false"
same_as_base info_solutions_off "${OTEL[@]}" "${INFO[@]}" --set "${CI}.solutions.enabled=false"
same_as_base info_otel_off "${INFO[@]}"
same_as_base info_otel_off_logs_off "${INFO[@]}" "${LOGS_OFF[@]}"
same_as_logs_on info_logs_on "${OTEL[@]}" "${INFO[@]}"
same_as_logs_on info_storage_logs_on "${OTEL[@]}" "${INFO[@]}" "${STORAGE_ON[@]}"
same_as_logs_on storage_only "${OTEL[@]}" "${STORAGE_ON[@]}"
same_as_logs_on emit_metric_resolution "${OTEL[@]}" "${INFO[@]}" --set "${CI}.metricResolution=20s"
same_as_logs_on emit_15s "${OTEL[@]}" "${INFO[@]}" --set "${CONFIG_INFO}.emitInterval=15s"
same_as_logs_on emit_1h "${OTEL[@]}" "${INFO[@]}" --set "${CONFIG_INFO}.emitInterval=1h"
same_as_logs_on emit_null "${OTEL[@]}" "${INFO[@]}" --set "${CONFIG_INFO}.emitInterval=null"
for bad in 15 0s 25h 1m30s abc; do
    same_as_logs_on "emit_bad_${bad}" "${OTEL[@]}" "${INFO[@]}" --set "${CONFIG_INFO}.emitInterval=${bad}"
done
# emitInterval empty: the metricResolution fallback is out of the connector's bounds.
same_as_logs_on emit_bad_resolution "${OTEL[@]}" "${INFO[@]}" --set "${CI}.metricResolution=90000s"
same_as_logs_on bad_max_state_bytes "${OTEL[@]}" "${INFO[@]}" --set "${CONFIG_INFO}.maxStateBytes=1000"
same_as_logs_on bad_max_value_length "${OTEL[@]}" "${INFO[@]}" --set "${CONFIG_INFO}.maxValueLength=2000"
same_as_logs_on bad_max_entities "${OTEL[@]}" "${INFO[@]}" --set "${CONFIG_INFO}.maxEntities=0"
same_as_logs_on bad_host_path "${OTEL[@]}" "${STORAGE_ON[@]}" --set "${CI}.stateStorage.hostPath=relative/dir"
same_as_logs_on bad_host_path_dot "${OTEL[@]}" "${STORAGE_ON[@]}" --set "${CI}.stateStorage.hostPath=/."
same_as_logs_on bad_host_path_dotdot "${OTEL[@]}" "${STORAGE_ON[@]}" --set "${CI}.stateStorage.hostPath=/var/.."
same_as_logs_on bad_host_path_inner "${OTEL[@]}" "${STORAGE_ON[@]}" --set "${CI}.stateStorage.hostPath=/var/./lib/x"
same_as_logs_on good_host_path_dots "${OTEL[@]}" "${STORAGE_ON[@]}" --set "${CI}.stateStorage.hostPath=/var/lib/.state..d"
same_as_logs_on surge_info "${OTEL[@]}" "${INFO[@]}" "${MAX_SURGE_1[@]}"
same_as_logs_on surge_storage "${OTEL[@]}" "${STORAGE_ON[@]}" "${MAX_SURGE_1[@]}"
same_as_logs_on surge_agents_entry "${OTEL[@]}" "${INFO[@]}" "${AGENTS_SURGE_10[@]}"
same_as_logs_on surge_on_delete "${OTEL[@]}" "${INFO[@]}" --set agent.updateStrategy.type=OnDelete
# pollInterval has no effect with logs on: a valid value renders as the logs-on chart does.
same_as_logs_on poll_set_10s_logs_on "${OTEL[@]}" "${INFO[@]}" "${POLL_10S[@]}"
same_as_logs_on poll_emit_5s_logs_on "${OTEL[@]}" "${INFO[@]}" --set "${CONFIG_INFO}.emitInterval=5s"
# A bad value still fails while configInfo is on (the logs-on chart has no pollInterval and renders it).
render "$CHART_DIR" poll_bad_500ms_logs_on "${OTEL[@]}" "${INFO[@]}" --set "${CONFIG_INFO}.pollInterval=500ms"
if [[ "$LOGS_ON_STATUS" == "ok" ]]; then
    render "${TMP_DIR}/logs_on" logs_on_poll_bad_500ms_logs_on "${OTEL[@]}" "${INFO[@]}" --set "${CONFIG_INFO}.pollInterval=500ms"
fi

# Logs off. logs_off_set <name> <renders|fails> <description> [helm args...] renders
# lo_<name>_info (configInfo on, which renders or fails as stated) and lo_<name>_plain
# (configInfo off, which must render as at LOGS_ON_REF and BASE_REF), both with logs off.
: > "${TMP_DIR}/logs_off_sets"
logs_off_set() {
    local name="$1" outcome="$2" desc="$3"
    shift 3
    printf '%s\t%s\t%s\n' "$name" "$outcome" "$desc" >> "${TMP_DIR}/logs_off_sets"
    render "$CHART_DIR" "lo_${name}_info" "${OTEL[@]}" "${LOGS_OFF[@]}" "${INFO[@]}" "$@"
    same_as_base "lo_${name}_plain" "${OTEL[@]}" "${LOGS_OFF[@]}" "$@"
}
logs_off_set defaults renders "the defaults"
logs_off_set tuned renders "emitInterval, pollInterval, caps and hostPath changed" "${OFF_TUNED[@]}"
logs_off_set storage renders "stateStorage on" "${STORAGE_ON[@]}"
logs_off_set storage_tuned renders "stateStorage on, emitInterval, pollInterval, caps and hostPath changed" \
    "${STORAGE_ON[@]}" "${OFF_TUNED[@]}"
logs_off_set metric_resolution renders "metricResolution 20s" --set "${CI}.metricResolution=20s"
logs_off_set on_delete renders "agent updateStrategy OnDelete" --set agent.updateStrategy.type=OnDelete
logs_off_set vllm_off renders "the vLLM solution off" --set "${CI}.solutions.vllm.enabled=false"
logs_off_set solutions_off renders "solutions.enabled false" --set "${CI}.solutions.enabled=false"
logs_off_set out_of_bounds fails "every new setting out of its bounds" "${OUT_OF_BOUNDS[@]}"
logs_off_set storage_out_of_bounds fails "stateStorage on, every new setting out of its bounds" \
    "${STORAGE_ON[@]}" "${OUT_OF_BOUNDS[@]}"
logs_off_set surge fails "agent maxSurge 1" "${MAX_SURGE_1[@]}"
logs_off_set storage_surge fails "stateStorage on, agent maxSurge 1" "${STORAGE_ON[@]}" "${MAX_SURGE_1[@]}"
logs_off_set agents_surge fails "agents[] entry maxSurge 10%" "${AGENTS_SURGE_10[@]}"
logs_off_set bad_poll fails "pollInterval 500ms" --set "${CONFIG_INFO}.pollInterval=500ms"

# Logs off, configInfo on: the poll interval and each bound on its own.
LO_INFO=("${OTEL[@]}" "${LOGS_OFF[@]}" "${INFO[@]}")
render "$CHART_DIR" poll_emit_1s "${LO_INFO[@]}" --set "${CONFIG_INFO}.emitInterval=1s"
render "$CHART_DIR" poll_null "${LO_INFO[@]}" --set "${CONFIG_INFO}.pollInterval=null"
render "$CHART_DIR" lo_emit_null "${LO_INFO[@]}" --set "${CONFIG_INFO}.emitInterval=null"
render "$CHART_DIR" poll_emit_5s "${LO_INFO[@]}" --set "${CONFIG_INFO}.emitInterval=5s"
render "$CHART_DIR" poll_emit_2m "${LO_INFO[@]}" --set "${CONFIG_INFO}.emitInterval=2m"
render "$CHART_DIR" poll_resolution_1s "${LO_INFO[@]}" --set "${CI}.metricResolution=1s"
render "$CHART_DIR" poll_set_10s "${LO_INFO[@]}" "${POLL_10S[@]}"
render "$CHART_DIR" poll_set_10s_emit_5s "${LO_INFO[@]}" "${POLL_10S[@]}" --set "${CONFIG_INFO}.emitInterval=5s"
render "$CHART_DIR" poll_set_1h "${LO_INFO[@]}" --set "${CONFIG_INFO}.pollInterval=1h"
for bad in 500ms 0s 25h 15 abc; do
    render "$CHART_DIR" "poll_bad_${bad}" "${LO_INFO[@]}" --set "${CONFIG_INFO}.pollInterval=${bad}"
done
render "$CHART_DIR" lo_bad_emit "${LO_INFO[@]}" --set "${CONFIG_INFO}.emitInterval=0s"
render "$CHART_DIR" lo_bad_max_state_bytes "${LO_INFO[@]}" --set "${CONFIG_INFO}.maxStateBytes=1000"
render "$CHART_DIR" lo_bad_max_value_length "${LO_INFO[@]}" --set "${CONFIG_INFO}.maxValueLength=2000"
render "$CHART_DIR" lo_bad_max_entities "${LO_INFO[@]}" --set "${CONFIG_INFO}.maxEntities=0"
render "$CHART_DIR" lo_bad_host_path "${LO_INFO[@]}" --set "${CI}.stateStorage.hostPath=relative/dir"
render "$CHART_DIR" lo_bad_host_path_dot "${LO_INFO[@]}" --set "${CI}.stateStorage.hostPath=/."
render "$CHART_DIR" lo_bad_host_path_dotdot "${LO_INFO[@]}" --set "${CI}.stateStorage.hostPath=/var/.."
render "$CHART_DIR" lo_bad_host_path_inner "${LO_INFO[@]}" --set "${CI}.stateStorage.hostPath=/var/./lib/x"
render "$CHART_DIR" lo_good_host_path_dots "${LO_INFO[@]}" --set "${CI}.stateStorage.hostPath=/var/lib/.state..d"
wait

python3 - "${TMP_DIR}" "${BASE_REF}" "${BASE_STATUS}" "${LOGS_ON_REF}" "${LOGS_ON_STATUS}" "${VLLM_RULE_FILE}" <<'PY'
import copy
import functools
import itertools
import json
import os
import re
import sys

import yaml

# The C loader when PyYAML has it: the checks parse each render several times.
LOADER = getattr(yaml, "CSafeLoader", yaml.SafeLoader)

TMP, BASE_REF, BASE_STATUS, LOGS_ON_REF, LOGS_ON_STATUS, RULE_FILE = sys.argv[1:7]

AGENT = "cloudwatch-agent"
SCRAPER = "cloudwatch-agent-cluster-scraper"
CONNECTOR = "signal_to_info_metric/cw_k8s_ci_v0_vllm"
STORAGE = "file_storage/cw_k8s_ci_v0_state"
OBSERVER = "k8s_observer/cw_k8s_ci_v0_vllm"
RC = "receiver_creator/cw_k8s_ci_v0_vllm_logs"
TEMPLATE = "filelog/vllm"
INFO_PIPELINE = "logs/cw_k8s_ci_v0_vllm_info"
HOST_PATH = "/var/lib/amazon-cloudwatch-agent/otel-state"
APP_RECEIVER = "filelog/cw_k8s_ci_v0_app"
APP_PIPELINE = "logs/cw_k8s_ci_v0_app"
APP_EXPORTER = "otlphttp/cw_k8s_ci_v0_app_logs_dest"
VLLM_PIPELINE = "metrics/cw_k8s_ci_v0_vllm"
VLLM_RECEIVER = "prometheus/cw_k8s_ci_v0_vllm"
KEEP = "filter/cw_k8s_ci_v0_vllm_keep"
POD = "k8sattributes/cw_k8s_ci_v0_pod"
UID_SET_ASIDE = "transform/cw_k8s_ci_v0_vllm_info_uid"
LIVE = "filter/cw_k8s_ci_v0_vllm_info_live"
CLEANUP = "transform/cw_k8s_ci_v0_vllm_info_cleanup"
PREFILTER = "filter/cw_k8s_ci_v0_vllm_info_prefilter"
INFO_PROCESSORS = (UID_SET_ASIDE, LIVE, CLEANUP)
# Everything that the Info metric or the storage adds to an otelConfig.
ADDED = (CONNECTOR, STORAGE, PREFILTER, OBSERVER, RC, INFO_PIPELINE) + INFO_PROCESSORS
INFO_METRIC = "vllm_engine_config_info"
# The private resource attribute that holds the stored UID between the transforms.
STORED_UID = "cwagent.info.pod.uid"
# The connector matches the startup line by plain substrings, no regex.
BODY_CONTAINS = ["Initializing an LLM engine (v", "Initializing a V0 LLM engine (v",
                 "Initializing a V1 LLM engine (v"]
# The connector's identity: the namespace, pod and container of the record.
IDENTITY = ["k8s.namespace.name", "k8s.pod.name", "k8s.container.name"]
# Copied to the emitted resource: the identity and the UID of the pod that logged the line.
INCLUDED = IDENTITY + ["k8s.pod.uid"]

# Logs-off mode. The vLLM scrape detection, and the receiver_creator rule that mirrors it.
SCRAPE_SOURCES = ["__meta_kubernetes_pod_label_serving_kserve_io_inferenceservice",
                  "__meta_kubernetes_pod_label_component", "__meta_kubernetes_pod_container_name",
                  "__meta_kubernetes_pod_container_image"]
SCRAPE_REGEX = ".+;predictor;kserve-container;.*|(?i)[^;]*;[^;]*;[^;]*;.*vllm.*"
RULE = ('type == "pod.container" && ((pod.labels["serving.kserve.io/inferenceservice"] != "" && '
        'pod.labels["component"] == "predictor" && container_name == "kserve-container") || '
        'container_image matches "(?i)vllm")')
OBSERVER_CONFIG = {"auth_type": "serviceAccount", "node": "${env:K8S_NODE_NAME}", "observe_pods": True,
                   "observe_nodes": False, "observe_services": False, "observe_ingresses": False}
CONTAINER_LOG_PARSER = {"id": "parse_container_log", "type": "container_log_parser"}
ORDERING = {"regex": r"/(?P<restart>[0-9]+)\.log\z", "top_n": 1,
            "sort_by": [{"regex_key": "restart", "sort_type": "numeric", "ascending": False}]}
TEMPLATE_CONFIG = {
    "include": ["/var/log/pods/`pod.namespace`_`pod.name`_`pod.uid`/`container_name`/*.log"],
    "ordering_criteria": ORDERING, "start_at": "beginning", "include_file_path": False,
    "include_file_name": False, "preserve_trailing_whitespaces": True, "poll_interval": "2s",
    "operators": [CONTAINER_LOG_PARSER]}

with open(os.path.join(TMP, "logs_off_sets")) as f:
    LOGS_OFF_SETS = [tuple(line.rstrip("\n").split("\t", 2)) for line in f if line.strip()]
with open(os.path.join(TMP, "logs_on_names")) as f:
    LOGS_ON_NAMES = [line.strip() for line in f if line.strip()]
with open(os.path.join(TMP, "base_names")) as f:
    BASE_NAMES = [line.strip() for line in f if line.strip()]
LO_RENDERING = [n for n, outcome, _ in LOGS_OFF_SETS if outcome == "renders"]
LO_FAILING = [n for n, outcome, _ in LOGS_OFF_SETS if outcome == "fails"]
LOGS_OFF = "lo_defaults_plain"
LOGS_OFF_TUNED = "lo_tuned_plain"
LO = "lo_defaults_info"
# Every render that must succeed, for the render guard and the component cross-checks.
MODES = ("default", "logs_on", "logs_on_tuned", "logs_on_surge", "info_logs_on",
         "info_storage_logs_on", "vllm_off", "info_vllm_off", "solutions_off",
         "info_solutions_off", "info_otel_off", "info_otel_off_logs_off", "storage_only",
         "emit_metric_resolution", "emit_15s", "emit_1h", "emit_null", "poll_null", "lo_emit_null",
         "surge_on_delete", "poll_set_10s_logs_on",
         "poll_emit_5s_logs_on", "poll_emit_1s", "poll_emit_5s", "poll_emit_2m", "poll_resolution_1s",
         "poll_set_10s", "poll_set_10s_emit_5s", "poll_set_1h") + \
    tuple(f"lo_{n}_plain" for n, _, _ in LOGS_OFF_SETS) + tuple(f"lo_{n}_info" for n in LO_RENDERING)

GREEN, RED, YELLOW, RESET = "\033[0;32m", "\033[0;31m", "\033[1;33m", "\033[0m"
passed = failed = 0


def check(desc, ok):
    global passed, failed
    if ok:
        print(f"  {GREEN}PASS{RESET}: {desc}")
        passed += 1
    else:
        print(f"  {RED}FAIL{RESET}: {desc}")
        failed += 1
    return ok


def skip(desc):
    print(f"  {YELLOW}SKIP{RESET}: {desc}")


def path(name):
    return os.path.join(TMP, name)


def rc(name):
    with open(path(name + ".rc")) as f:
        return int(f.read().strip())


def err(name):
    with open(path(name + ".err")) as f:
        return f.read()


def show_err(name):
    print("    " + err(name).strip().replace("\n", "\n    "))


@functools.lru_cache(maxsize=None)
def docs(name):
    """The parsed documents of a render, cached. No check changes them."""
    with open(path(name + ".yaml")) as f:
        return [d for d in yaml.load_all(f, Loader=LOADER) if d]


def agent_crs(name):
    return {d["metadata"]["name"]: d for d in docs(name) if d.get("kind") == "AmazonCloudWatchAgent"}


@functools.lru_cache(maxsize=None)
def otel_config(name, agent=AGENT):
    """The parsed otelConfig of an agent CR, cached. No check changes it."""
    cr = agent_crs(name).get(agent)
    return (yaml.load(cr["spec"].get("otelConfig") or "{}", Loader=LOADER) or {}) if cr else {}


def pipelines(cfg):
    return (cfg.get("service") or {}).get("pipelines") or {}


def pipeline(cfg, name):
    return pipelines(cfg).get(name) or {}


def section(cfg, kind):
    return cfg.get(kind) or {}


def service_extensions(cfg):
    return (cfg.get("service") or {}).get("extensions") or []


@functools.lru_cache(maxsize=None)
def redacted(name):
    """Rendered text with the randomly generated certificate material blanked."""
    with open(path(name + ".yaml")) as f:
        return re.sub(r"(?m)^(\s*(?:caBundle|ca\.crt|tls\.crt|tls\.key):).*$", r"\1 <redacted>", f.read())


def same_render(a, b):
    """Both render, and byte for byte the same (certificates redacted)."""
    return rc(a) == 0 and rc(b) == 0 and redacted(a) == redacted(b)


def same_outcome(a, b):
    """Both render byte for byte the same, or both fail with the same message."""
    if rc(a) == 0 or rc(b) == 0:
        return same_render(a, b)
    return err(a) == err(b)


def mounts(cr, name):
    return [m for m in cr["spec"].get("volumeMounts") or [] if m.get("name") == name]


def volumes(cr, name):
    return [v for v in cr["spec"].get("volumes") or [] if v.get("name") == name]


def undefined_components(cfg):
    """Components named in service or in watch_observers but not defined in their section."""
    missing = []
    for ext in service_extensions(cfg):
        if ext not in section(cfg, "extensions"):
            missing.append(ext)
    for p in pipelines(cfg).values():
        for r in p.get("receivers") or []:
            if r not in section(cfg, "receivers") and r not in section(cfg, "connectors"):
                missing.append(r)
        for x in p.get("processors") or []:
            if x not in section(cfg, "processors"):
                missing.append(x)
        for e in p.get("exporters") or []:
            if e not in section(cfg, "exporters") and e not in section(cfg, "connectors"):
                missing.append(e)
    # receiver_creator finds its observers among the started extensions.
    for r in section(cfg, "receivers").values():
        for o in (r or {}).get("watch_observers") or []:
            if o not in section(cfg, "extensions") or o not in service_extensions(cfg):
                missing.append(o)
    return missing


def unused_components(cfg):
    """Components defined but used by no pipeline (extensions: not in service.extensions;
    connectors: not used both as an exporter and as a receiver)."""
    used = {k: set() for k in ("receivers", "processors", "exporters")}
    for p in pipelines(cfg).values():
        for k in used:
            used[k] |= set(p.get(k) or [])
    unused = [c for k in used for c in section(cfg, k) if c not in used[k]]
    unused += [c for c in section(cfg, "connectors")
               if c not in used["exporters"] or c not in used["receivers"]]
    started = set(service_extensions(cfg))
    return unused + [e for e in section(cfg, "extensions") if e not in started]


def file_name_attributes(cfg, file_path):
    """The resource attributes APP_RECEIVER sets from file_path: its regex_parser on
    log.file.path into the resource, then a move of each capture group to a resource key."""
    rec = section(cfg, "receivers").get(APP_RECEIVER) or {}
    ops = rec.get("operators") or []
    parsers = [o for o in ops if o.get("type") == "regex_parser" and
               o.get("parse_from") == 'attributes["log.file.path"]' and o.get("parse_to") == "resource"]
    if rec.get("include_file_path") is not True or len(parsers) != 1:
        return {}
    m = re.match(parsers[0].get("regex") or "", file_path)
    if not m:
        return {}
    out = {}
    for o in ops:
        if o.get("type") != "move":
            continue
        src = re.fullmatch(r"resource\.(\w+)", o.get("from") or "")
        dst = re.fullmatch(r'resource\["([^"]+)"\]', o.get("to") or "")
        if src and dst and src.group(1) in m.groupdict():
            out[dst.group(1)] = m.group(src.group(1))
    return out


def mentions(cfg, component):
    """True if component is defined anywhere or used by any pipeline or service list."""
    if any(component in section(cfg, k) for k in ("receivers", "processors", "exporters", "connectors", "extensions")):
        return True
    if component in service_extensions(cfg) or component in pipelines(cfg):
        return True
    return any(component in (p.get(k) or []) for p in pipelines(cfg).values()
               for k in ("receivers", "processors", "exporters"))


def nothing_added(name):
    """No agent CR of the render has a connector, the storage, the observer, the
    receiver_creator, an Info metric processor or pipeline, or the state volume."""
    crs = agent_crs(name)
    return (bool(crs) and
            not any(mentions(otel_config(name, a), x) for a in crs for x in ADDED) and
            not any(volumes(cr, "otelstate") or mounts(cr, "otelstate") for cr in crs.values()))


def connector_users(cfg):
    as_exporter = [n for n, p in pipelines(cfg).items() if CONNECTOR in (p.get("exporters") or [])]
    as_receiver = [n for n, p in pipelines(cfg).items() if CONNECTOR in (p.get("receivers") or [])]
    return as_exporter, as_receiver


def strip_info(cfg):
    """An otelConfig without everything that the Info metric adds: what a configInfo-off
    render has."""
    c = copy.deepcopy(cfg)
    for k in (STORAGE, OBSERVER):
        section(c, "extensions").pop(k, None)
    section(c, "receivers").pop(RC, None)
    procs = section(c, "processors")
    for k in INFO_PROCESSORS:
        procs.pop(k, None)
    keep = ((procs.get(KEEP) or {}).get("metrics") or {}).get("metric") or []
    suffix = f' and name != "{INFO_METRIC}"'
    if keep and keep[0].endswith(suffix):
        keep[0] = keep[0][:-len(suffix)]
    section(c, "connectors").pop(CONNECTOR, None)
    if "connectors" in c and not c["connectors"]:
        del c["connectors"]
    svc = c.get("service") or {}
    svc["extensions"] = [e for e in svc.get("extensions") or [] if e not in (STORAGE, OBSERVER)]
    pl = svc.get("pipelines") or {}
    pl.pop(INFO_PIPELINE, None)
    if VLLM_PIPELINE in pl:
        v = pl[VLLM_PIPELINE]
        v["receivers"] = [r for r in v.get("receivers") or [] if r != CONNECTOR]
        v["processors"] = [p for p in v.get("processors") or [] if p not in INFO_PROCESSORS]
    return c


def without_state(spec):
    """A CR spec without the otelConfig and the otelstate volume and mount."""
    out = {k: v for k, v in spec.items() if k != "otelConfig"}
    for k in ("volumes", "volumeMounts"):
        out[k] = [x for x in spec.get(k) or [] if x.get("name") != "otelstate"]
    return out


@functools.lru_cache(maxsize=None)
def redacted_docs(name):
    return [d for d in yaml.load_all(redacted(name), Loader=LOADER) if d]


def only_info_added(info, plain):
    """info differs from plain only by the Info metric components in the node agent's
    otelConfig and by the otelstate volume and mount of the node agent."""
    a, b = redacted_docs(info), redacted_docs(plain)
    if len(a) != len(b):
        return False
    for x, y in zip(a, b):
        if x.get("kind") == "AmazonCloudWatchAgent" and (x.get("metadata") or {}).get("name") == AGENT:
            if without_state(x["spec"]) != without_state(y["spec"]):
                return False
            if strip_info(otel_config(info)) != otel_config(plain):
                return False
        elif x != y:
            return False
    return True


# --- OTTL, as far as the connector rule uses it ------------------------------------
OTTL_STRING = r'"((?:[^"\\]|\\.)*)"'
SHAPE = re.compile(r'^ExtractPatterns\(log\.body, ' + OTTL_STRING + r'\)\["v"\]$')


def ottl_unescape(s):
    """An OTTL string literal's value. Only \\\\ and \\" may appear: any other escape means
    a regex backslash was not doubled."""
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\":
            if i + 1 >= len(s) or s[i + 1] not in '\\"':
                raise ValueError(f"undoubled backslash at {i} in {s!r}")
            out.append(s[i + 1])
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def evaluate(attr, body):
    """An attribute's value for a log body, as the connector computes it: ExtractPatterns(log.body,
    "<re>")["v"]; no match (an evaluation error) gives default_value, or None."""
    m = SHAPE.match(attr.get("value") or "")
    if not m:
        raise ValueError(f"unexpected expression shape: {attr.get('value')}")
    hit = re.search(ottl_unescape(m.group(1)), body)
    if hit and hit.groupdict().get("v"):
        return hit.group("v")
    return attr.get("default_value")


# Sample engine startup lines: V1 (vLLM >= 0.10), V0 (0.8.x), and the line before the
# V0/V1 split (0.6.x), plus a speculative-decoding config.
V1_LINE = (
    "(EngineCore pid=211) INFO 10-15 12:41:46 [core.py:134] Initializing a V1 LLM engine "
    "(v0.31.1) with config: model='meta-llama/Llama-3.1-70B-Instruct', speculative_config=None, "
    "tokenizer='meta-llama/Llama-3.1-70B-Instruct', skip_tokenizer_init=False, tokenizer_mode=auto, "
    "revision=None, tokenizer_revision=None, trust_remote_code=False, dtype=torch.bfloat16, "
    "max_seq_len=131072, download_dir=None, load_format=auto, tensor_parallel_size=4, "
    "pipeline_parallel_size=2, data_parallel_size=1, decode_context_parallel_size=1, "
    "disable_custom_all_reduce=False, quantization=fp8, "
    "quantization_config={'activation_scheme': 'dynamic', 'quant_method': 'fp8'}, enforce_eager=False, "
    "kv_cache_dtype=fp8_e4m3, device_config=cuda, seed=0, "
    "served_model_name=llama-70b, enable_prefix_caching=True, enable_chunked_prefill=True, "
    "pooler_config=None, compilation_config={'mode': 3}, kernel_config=KernelConfig()"
)
V0_LINE = (
    "INFO 05-02 09:10:11 [llm_engine.py:241] Initializing a V0 LLM engine (v0.8.5) with config: "
    "model='Qwen/Qwen2.5-7B-Instruct', speculative_config=SpeculativeConfig(method='eagle', "
    "model='yuhuili/EAGLE-Qwen2-7B-Instruct', num_spec_tokens=3), tokenizer='Qwen/Qwen2.5-7B-Instruct', "
    "dtype=torch.float16, max_seq_len=32768, tensor_parallel_size=1, pipeline_parallel_size=1, "
    "quantization=awq, enforce_eager=True, kv_cache_dtype=auto, served_model_name=qwen-7b, "
    "enable_prefix_caching=False, use_async_output_proc=False, "
)
LEGACY_LINE = (
    "INFO 10-01 08:00:00 llm_engine.py:237] Initializing an LLM engine (v0.6.3) with config: "
    "model='mistralai/Mistral-7B-Instruct-v0.3', speculative_config=None, "
    "tokenizer='mistralai/Mistral-7B-Instruct-v0.3', dtype=torch.bfloat16, max_seq_len=32768, "
    "tensor_parallel_size=2, pipeline_parallel_size=1, quantization=None, enforce_eager=False, "
    "kv_cache_dtype=auto, served_model_name=mistralai/Mistral-7B-Instruct-v0.3, "
    "enable_prefix_caching=None, "
)
UNRELATED_LINE = "INFO 10-15 12:41:50 [api_server.py:1] Starting vLLM API server on http://0.0.0.0:8000"
EXPECTED = {
    "V1": (V1_LINE, {
        "vllm_version": "0.31.1", "model": "meta-llama/Llama-3.1-70B-Instruct", "vllm_engine": "V1",
        "served_model_name": "llama-70b", "dtype": "bfloat16", "max_seq_len": "131072",
        "tensor_parallel_size": "4", "pipeline_parallel_size": "2", "data_parallel_size": "1",
        "quantization": "fp8", "enforce_eager": "False", "kv_cache_dtype": "fp8_e4m3",
        "enable_prefix_caching": "True", "speculative_method": "None"}),
    "V0": (V0_LINE, {
        "vllm_version": "0.8.5", "model": "Qwen/Qwen2.5-7B-Instruct", "vllm_engine": "V0",
        "served_model_name": "qwen-7b", "dtype": "float16", "max_seq_len": "32768",
        "tensor_parallel_size": "1", "pipeline_parallel_size": "1", "data_parallel_size": None,
        "quantization": "awq", "enforce_eager": "True", "kv_cache_dtype": "auto",
        "enable_prefix_caching": "False", "speculative_method": "eagle"}),
    "pre-V0/V1": (LEGACY_LINE, {
        "vllm_version": "0.6.3", "model": "mistralai/Mistral-7B-Instruct-v0.3", "vllm_engine": "V0",
        "served_model_name": "mistralai/Mistral-7B-Instruct-v0.3", "dtype": "bfloat16",
        "max_seq_len": "32768", "tensor_parallel_size": "2", "pipeline_parallel_size": "1",
        "data_parallel_size": None, "quantization": "None", "enforce_eager": "False",
        "kv_cache_dtype": "auto", "enable_prefix_caching": "None", "speculative_method": "None"}),
}
REQUIRED = ["vllm_version", "model"]
DEFAULTED = {"vllm_engine": "V0"}
OPTIONAL = ["served_model_name", "dtype", "max_seq_len", "tensor_parallel_size",
            "pipeline_parallel_size", "data_parallel_size", "quantization", "enforce_eager",
            "kv_cache_dtype", "enable_prefix_caching", "speculative_method"]


# Guards: without these, the assertions below could pass on empty input.
print(f"\n{YELLOW}[renders]{RESET}")
for name in MODES:
    if not check(f"{name} renders", rc(name) == 0):
        show_err(name)
check("the node agent CR renders an otelConfig with configInfo on, logs on and off",
      bool(otel_config("info_logs_on")) and bool(otel_config(LO)))
check(f"{VLLM_PIPELINE} renders with configInfo on", bool(pipeline(otel_config("info_logs_on"), VLLM_PIPELINE)))
check(f"{len(LOGS_OFF_SETS)} logs-off value sets, {len(LO_FAILING)} of them failing with configInfo on",
      len(LO_RENDERING) >= 5 and len(LO_FAILING) >= 5)

# --- 1. Off by default, and inert while off ---------------------------------------
print(f"\n{YELLOW}[defaults: everything off]{RESET}")
if BASE_STATUS == "ok":
    for name in BASE_NAMES:
        if not check(f"{name} is byte-identical to {BASE_REF} (certificates redacted)",
                     same_render(name, f"base_{name}")):
            for n in (name, f"base_{name}"):
                if rc(n) != 0:
                    show_err(n)
elif BASE_REF:
    check(f"BASE_REF {BASE_REF} resolves in this checkout", False)
else:
    skip(f"byte identity with a base ref ({BASE_STATUS})")
for tuned, plain in (("logs_on_tuned", "logs_on"), (LOGS_OFF_TUNED, LOGS_OFF)):
    check(f"changing only the new settings, with both flags off, changes nothing ({plain})",
          same_render(tuned, plain))
check("maxSurge 1 renders while the storage is off", rc("logs_on_surge") == 0)
for name in ("default", "logs_on", LOGS_OFF, "info_vllm_off", "info_solutions_off", "info_otel_off",
             "info_otel_off_logs_off"):
    check(f"{name}: none of the Info metric components, no storage, no state volume", nothing_added(name))
check("configInfo without the vLLM solution renders as if it were off", same_render("info_vllm_off", "vllm_off"))
check("configInfo with solutions.enabled false renders as if it were off",
      same_render("info_solutions_off", "solutions_off"))
check("configInfo without OTEL Container Insights renders as the defaults, logs on or off",
      same_render("info_otel_off", "default") and same_render("info_otel_off_logs_off", "default"))
for set_name in ("vllm_off", "solutions_off"):
    check(f"logs off, {set_name}: configInfo on renders as configInfo off",
          same_render(f"lo_{set_name}_info", f"lo_{set_name}_plain"))

# --- 3. Logs on is unchanged -------------------------------------------------------
print(f"\n{YELLOW}[logs on and configInfo off: as at LOGS_ON_REF]{RESET}")
if LOGS_ON_STATUS == "ok":
    for name in LOGS_ON_NAMES:
        if not check(f"{name} is byte-identical to {LOGS_ON_REF}, or fails with the same message",
                     same_outcome(name, f"logs_on_{name}")):
            for n in (name, f"logs_on_{name}"):
                if rc(n) != 0:
                    show_err(n)
    check(f"logs on, pollInterval 500ms: fails here, and renders at {LOGS_ON_REF} as configInfo on (no pollInterval there)",
          rc("poll_bad_500ms_logs_on") != 0 and same_render("logs_on_poll_bad_500ms_logs_on", "logs_on_info_logs_on"))
elif LOGS_ON_REF:
    check(f"LOGS_ON_REF {LOGS_ON_REF} resolves in this checkout", False)
else:
    skip(f"byte identity with the logs-on-only chart ({LOGS_ON_STATUS})")

# --- configInfo on + logs on --------------------------------------------------------
print(f"\n{YELLOW}[configInfo on, logs on]{RESET}")
on = otel_config("info_logs_on")
off = otel_config("logs_on")
check("no new pipeline: same service.pipelines keys as the logs-on render",
      set(pipelines(on)) == set(pipelines(off)))
as_exporter, as_receiver = connector_users(on)
check(f"the connector is an exporter of {APP_PIPELINE} only", as_exporter == [APP_PIPELINE])
check(f"the connector is a receiver of {VLLM_PIPELINE} only", as_receiver == [VLLM_PIPELINE])
check(f"{APP_PIPELINE} still ships logs, then feeds the connector",
      pipeline(on, APP_PIPELINE).get("exporters") == [APP_EXPORTER, CONNECTOR])
check(f"{VLLM_PIPELINE} keeps its scrape receiver first",
      pipeline(on, VLLM_PIPELINE).get("receivers") == [VLLM_RECEIVER, CONNECTOR])
check(f"{APP_PIPELINE} receivers and processors are unchanged",
      pipeline(on, APP_PIPELINE).get("receivers") == pipeline(off, APP_PIPELINE).get("receivers") == [APP_RECEIVER] and
      pipeline(on, APP_PIPELINE).get("processors") == pipeline(off, APP_PIPELINE).get("processors"))
check(f"{APP_PIPELINE} runs {POD} before the connector, which adds the k8s.pod.uid the connector stores",
      POD in (pipeline(on, APP_PIPELINE).get("processors") or []))
check(f"no {PREFILTER}, and none of the logs-off components ({OBSERVER}, {RC}, {INFO_PIPELINE})",
      not any(mentions(on, x) for x in (PREFILTER, OBSERVER, RC, INFO_PIPELINE)))

connector = section(on, "connectors").get(CONNECTOR) or {}
rules = connector.get("rules") or [{}]
rule = rules[0]
check("the connector keeps its state in the storage extension", connector.get("storage") == STORAGE)
check("emit_interval defaults to metricResolution (30s)", connector.get("emit_interval") == "30s")
check("max_state_bytes and max_value_length come from values",
      connector.get("max_state_bytes") == 1048576 and connector.get("max_value_length") == 256)
check(f"one rule, {INFO_METRIC}, with max_entities 500",
      len(rules) == 1 and rule.get("name") == INFO_METRIC and rule.get("max_entities") == 500)
check(f"the rule is keyed on {IDENTITY} and copies those three and k8s.pod.uid to the resource",
      rule.get("identity") == IDENTITY and rule.get("include_resource_attributes") == INCLUDED)
check("no identity_output_prefix (the identity keys are plain resource attributes)",
      "identity_output_prefix" not in connector)
check("the startup line is matched by the three body_contains substrings, with no OTTL condition",
      rule.get("body_contains") == BODY_CONTAINS and "conditions" not in rule)
attrs = rule.get("attributes") or []
by_key = {a.get("key"): a for a in attrs}
check("the 14 facts, required first", [a.get("key") for a in attrs] == REQUIRED + list(DEFAULTED) + OPTIONAL)
check("vllm_version and model are required (no optional, no default_value)",
      all(not by_key[k].get("optional") and "default_value" not in by_key[k] for k in REQUIRED))
check("vllm_engine defaults to V0 and is not also optional (the connector rejects both)",
      all(by_key[k].get("default_value") == v and "optional" not in by_key[k] for k, v in DEFAULTED.items()))
check("every other fact is optional, with no default_value",
      all(by_key[k].get("optional") is True and "default_value" not in by_key[k] for k in OPTIONAL))

# The rule in the connector's testdata, which the connector's own tests run.
if RULE_FILE:
    try:
        with open(RULE_FILE) as f:
            want_rules = (yaml.safe_load(f) or {}).get("rules")
    except OSError as e:
        print(f"    {e}")
        want_rules = None
    if not check(f"the rendered rules equal the rules in {RULE_FILE} (both parsed)",
                 want_rules is not None and connector.get("rules") == want_rules):
        got_by_key = {a.get("key"): a for a in attrs}
        want_rule = (want_rules or [{}])[0]
        for k in sorted(set(rule) | set(want_rule)):
            if k != "attributes" and rule.get(k) != want_rule.get(k):
                print(f"    {k}: rendered {rule.get(k)!r}, file {want_rule.get(k)!r}")
        for a in want_rule.get("attributes") or []:
            if got_by_key.get(a.get("key")) != a:
                print(f"    attribute {a.get('key')}: rendered {got_by_key.get(a.get('key'))!r}, file {a!r}")
else:
    skip("rules equal the connector testdata (set VLLM_RULE_FILE to "
         "connector/signaltoinfometricconnector/testdata/vllm_rule.yaml of amazon-cloudwatch-agent)")

# 7. Escaping: run every pattern the way the collector would see it.
all_ottl = [a.get("value") or "" for a in attrs]
check("no OTTL string contains a $ (the collector's confmap would expand it)",
      all("$" not in s for s in all_ottl))
try:
    for s in all_ottl:
        for lit in re.findall(OTTL_STRING, s):
            re.compile(ottl_unescape(lit))
    escaping_ok = True
except (ValueError, re.error) as e:
    print(f"    {e}")
    escaping_ok = False
check("every regex backslash is doubled for OTTL and every string compiles as a regex", escaping_ok)
check('every attribute value is one ExtractPatterns(log.body, "...")["v"] (no Coalesce)',
      all(SHAPE.match(a.get("value") or "") for a in attrs))
for label, (line, expected) in EXPECTED.items():
    try:
        got = {a["key"]: evaluate(a, line) for a in attrs}
    except (ValueError, re.error) as e:
        print(f"    {e}")
        got = {}
    check(f"{label} startup line: contains exactly one body_contains substring",
          sum(b in line for b in BODY_CONTAINS) == 1)
    if not check(f"{label} startup line: all 14 facts extract as expected", got == expected):
        for k in expected:
            if got.get(k) != expected[k]:
                print(f"    {k}: got {got.get(k)!r}, want {expected[k]!r}")
check("an unrelated vLLM log line contains no body_contains substring",
      not any(b in UNRELATED_LINE for b in BODY_CONTAINS))

# Storage.
storage = section(on, "extensions").get(STORAGE) or {}
compaction = storage.get("compaction") or {}
check(f"{STORAGE} is in service.extensions", STORAGE in service_extensions(on))
check(f"{STORAGE} writes to {HOST_PATH} and creates it",
      storage.get("directory") == HOST_PATH and storage.get("create_directory") is True)
check(f"{STORAGE} compacts on start and on rebound, in the same directory",
      compaction.get("on_start") is True and compaction.get("on_rebound") is True and
      compaction.get("directory") == HOST_PATH)
check(f"{STORAGE} recreates a file it cannot open", storage.get("recreate") is True)
check(f"configInfo does not change log shipping: {APP_RECEIVER} (no checkpoints, start_at end) "
      f"and {APP_EXPORTER} are as in the logs-on render",
      section(on, "receivers").get(APP_RECEIVER) == section(off, "receivers").get(APP_RECEIVER) and
      "storage" not in (section(on, "receivers").get(APP_RECEIVER) or {"storage": 1}) and
      section(on, "exporters").get(APP_EXPORTER) == section(off, "exporters").get(APP_EXPORTER))
on_receiver = section(on, "receivers").get(APP_RECEIVER) or {}
check(f"{APP_RECEIVER} reads /var/log/containers and sets no k8s.pod.uid ({POD} adds it)",
      on_receiver.get("include") == ["/var/log/containers/*.log"] and
      not any("k8s.pod.uid" in (o.get("to") or "") for o in on_receiver.get("operators") or []))

# 5. Identity and liveness.
SAMPLE_PATH = "/var/log/containers/vllm-0_ml-serving_vllm-server-" + "0123456789abcdef" * 4 + ".log"
SAMPLE_IDENTITY = {"k8s.pod.name": "vllm-0", "k8s.namespace.name": "ml-serving",
                   "k8s.container.name": "vllm-server"}
got = file_name_attributes(on, SAMPLE_PATH)
if not check(f"{APP_RECEIVER} sets every identity key from the log file name",
             {k: got.get(k) for k in IDENTITY} == SAMPLE_IDENTITY):
    print(f"    got {got}")
chain = pipeline(on, VLLM_PIPELINE).get("processors") or []
pod_at = chain.index(POD) if POD in chain else -1
check(f"{UID_SET_ASIDE} runs right before {POD}, and {LIVE} then {CLEANUP} right after it",
      pod_at >= 1 and chain[pod_at - 1:pod_at + 3] == [UID_SET_ASIDE, POD, LIVE, CLEANUP])
check(f"{UID_SET_ASIDE} runs after {KEEP}", KEEP in chain and chain.index(KEEP) < pod_at - 1)
check(f"apart from {', '.join(INFO_PROCESSORS)}, {VLLM_PIPELINE} processors are unchanged",
      [p for p in chain if p not in INFO_PROCESSORS] == pipeline(off, VLLM_PIPELINE).get("processors"))
before_uid = chain[:max(pod_at - 1, 0)]
check(f"no processor before {UID_SET_ASIDE} names k8s.pod.uid, so none sets or changes it on the Info metric",
      bool(before_uid) and all(p in section(on, "processors") for p in before_uid) and
      not any("k8s.pod.uid" in json.dumps(section(on, "processors").get(p)) for p in before_uid))
uid_proc = section(on, "processors").get(UID_SET_ASIDE) or {}
check(f"{UID_SET_ASIDE} copies k8s.pod.uid to {STORED_UID} and deletes it, for {INFO_METRIC} only",
      uid_proc == {"error_mode": "ignore", "metric_statements": [{"context": "metric", "statements": [
          f'set(resource.attributes["{STORED_UID}"], resource.attributes["k8s.pod.uid"]) '
          f'where metric.name == "{INFO_METRIC}" and resource.attributes["k8s.pod.uid"] != nil',
          f'delete_key(resource.attributes, "k8s.pod.uid") where metric.name == "{INFO_METRIC}"']}]})
cleanup = section(on, "processors").get(CLEANUP) or {}
check(f"{CLEANUP} deletes {STORED_UID}, for {INFO_METRIC} only",
      cleanup == {"error_mode": "ignore", "metric_statements": [{"context": "metric", "statements": [
          f'delete_key(resource.attributes, "{STORED_UID}") where metric.name == "{INFO_METRIC}"']}]})
pod_proc = section(on, "processors").get(POD) or {}
associations = [[(s.get("from"), s.get("name")) for s in a.get("sources") or []]
                for a in pod_proc.get("pod_association") or []]
check(f"{POD} adds k8s.pod.uid, looked up by the k8s.pod.name and k8s.namespace.name that the "
      "Info metric carries (so the PromQL join on @resource.k8s.pod.uid holds)",
      "k8s.pod.uid" in ((pod_proc.get("extract") or {}).get("metadata") or []) and
      [("resource_attribute", "k8s.pod.name"), ("resource_attribute", "k8s.namespace.name")] in associations and
      {"k8s.pod.name", "k8s.namespace.name"} <= set(rule.get("include_resource_attributes") or []))
live = section(on, "processors").get(LIVE) or {}
live_conditions = ((live.get("metrics") or {}).get("datapoint")) or []
check(f"{LIVE} drops a {INFO_METRIC} data point with no live k8s.pod.uid, or with a stored "
      f"{STORED_UID} that is not the live k8s.pod.uid",
      live.get("error_mode") == "ignore" and set(live) == {"error_mode", "metrics"} and
      set(live.get("metrics") or {}) == {"datapoint"} and live_conditions == [
          f'metric.name == "{INFO_METRIC}" and resource.attributes["k8s.pod.uid"] == nil',
          f'metric.name == "{INFO_METRIC}" and resource.attributes["{STORED_UID}"] != nil and '
          f'resource.attributes["{STORED_UID}"] != resource.attributes["k8s.pod.uid"]'])
check(f"{LIVE} never drops a scraped series: each condition is an 'and' that names {INFO_METRIC}, "
      "which is not a vllm:* or http_* name",
      bool(live_conditions) and not re.match(r"^(vllm:|http_)", INFO_METRIC) and
      all(" or " not in c and f'metric.name == "{INFO_METRIC}"' in c.split(" and ") for c in live_conditions))
info_ottl = (live_conditions + [s for p in (uid_proc, cleanup) for g in p.get("metric_statements") or []
                                for s in g.get("statements") or []])
check("no OTTL of the Info metric processors contains a $ (the collector's confmap would expand it)",
      len(info_ottl) == 5 and all("$" not in s for s in info_ottl))

keep_on = ((section(on, "processors").get(KEEP) or {}).get("metrics") or {}).get("metric") or []
keep_off = ((section(off, "processors").get(KEEP) or {}).get("metrics") or {}).get("metric") or []
check(f"{KEEP} also passes {INFO_METRIC}, and otherwise drops what it drops today",
      bool(keep_off) and len(keep_on) == len(keep_off) and keep_on[1:] == keep_off[1:] and
      keep_on[0] == f'{keep_off[0]} and name != "{INFO_METRIC}"')

# 6. The state volume: writable, node agent DaemonSet only.
crs = agent_crs("info_logs_on")
node_cr = crs.get(AGENT) or {"spec": {}}
state_mounts, state_volumes = mounts(node_cr, "otelstate"), volumes(node_cr, "otelstate")
check(f"the {AGENT} DaemonSet mounts {HOST_PATH} writable",
      node_cr["spec"].get("mode") == "daemonset" and len(state_mounts) == 1 and
      state_mounts[0].get("mountPath") == HOST_PATH and not state_mounts[0].get("readOnly"))
check(f"the {AGENT} DaemonSet has a DirectoryOrCreate hostPath volume at {HOST_PATH}",
      len(state_volumes) == 1 and
      state_volumes[0].get("hostPath") == {"path": HOST_PATH, "type": "DirectoryOrCreate"})
check("no other agent CR (cluster-scraper, Windows) gets the state volume",
      len(crs) >= 3 and not any(mounts(cr, "otelstate") or volumes(cr, "otelstate")
                                for name, cr in crs.items() if name != AGENT))
check("the cluster-scraper has no connector or storage",
      not mentions(otel_config("info_logs_on", SCRAPER), CONNECTOR) and
      not mentions(otel_config("info_logs_on", SCRAPER), STORAGE))

# --- 4. configInfo on + logs off ----------------------------------------------------
print(f"\n{YELLOW}[configInfo on, logs off: only vLLM container logs]{RESET}")
for set_name, outcome, desc in LOGS_OFF_SETS:
    info, plain = f"lo_{set_name}_info", f"lo_{set_name}_plain"
    if outcome == "fails":
        continue
    if set_name in ("vllm_off", "solutions_off"):
        continue  # configInfo has no effect there: checked above
    if not check(f"logs off, {desc}: configInfo on adds only the Info metric components, the storage "
                 "and the state volume to the configInfo-off render", only_info_added(info, plain)):
        for n in (info, plain):
            if rc(n) != 0:
                show_err(n)
    check(f"logs off, {desc}: configInfo off adds nothing", nothing_added(plain))
lo = otel_config(LO)
lo_plain = otel_config(LOGS_OFF)
check(f"logs off: no {APP_RECEIVER}, {APP_PIPELINE}, {APP_EXPORTER} or other logs component",
      bool(lo) and APP_RECEIVER not in section(lo, "receivers") and APP_PIPELINE not in pipelines(lo) and
      APP_EXPORTER not in section(lo, "exporters") and "filelog/cw_k8s_ci_v0_node" not in section(lo, "receivers") and
      list(section(lo, "exporters")) == ["otlphttp/cw_k8s_ci_v0_metrics_dest"] and
      not any(e in section(lo, "extensions") for e in
              ("sigv4auth/cw_k8s_ci_v0_logs_dest", "awscloudwatchlogsprovisioner/cw_k8s_ci_v0_logs")))
check(f"logs off: {OBSERVER} watches only the pods of this node (service account, the downward-API "
      "node name, every other observe_* off)", section(lo, "extensions").get(OBSERVER) == OBSERVER_CONFIG)
check(f"logs off: service.extensions are the metrics auth, {STORAGE} and {OBSERVER}",
      service_extensions(lo) == ["sigv4auth/cw_k8s_ci_v0_metrics_dest", STORAGE, OBSERVER])
rc_cfg = section(lo, "receivers").get(RC) or {}
template = (rc_cfg.get("receivers") or {}).get(TEMPLATE) or {}
template_cfg = template.get("config") or {}
check(f"logs off: {RC} watches {OBSERVER} and has one template, {TEMPLATE}, with the receiver_creator "
      "default resource attributes",
      set(rc_cfg) == {"watch_observers", "receivers"} and rc_cfg.get("watch_observers") == [OBSERVER] and
      list(rc_cfg.get("receivers") or {}) == [TEMPLATE] and set(template) == {"rule", "config"})
check(f"logs off: the {TEMPLATE} rule is exactly the vLLM scrape rule for pod.container endpoints",
      template.get("rule") == RULE)
check(f"logs off: the {TEMPLATE} config (include, ordering_criteria, start_at, poll_interval, operators)",
      template_cfg == TEMPLATE_CONFIG)
check(f"logs off: {TEMPLATE} reads the kubelet log directory of the endpoint's container only",
      template_cfg.get("include") == ["/var/log/pods/`pod.namespace`_`pod.name`_`pod.uid`/`container_name`/*.log"])
check(f"logs off: {TEMPLATE} reads only the newest restart file (numeric sort, descending, top_n 1)",
      template_cfg.get("ordering_criteria") == ORDERING)
check(f"logs off: {TEMPLATE} reads from the start, with no storage, no encoding, no exclude",
      template_cfg.get("start_at") == "beginning" and
      not any(k in template_cfg for k in ("storage", "encoding", "exclude", "max_concurrent_files")))
check(f"logs off: {TEMPLATE} keeps trailing whitespace, so an empty CRI line parses",
      template_cfg.get("preserve_trailing_whitespaces") is True)
check(f"logs off: {TEMPLATE} parses no path (no regex parser, no file name or path attribute)",
      template_cfg.get("include_file_path") is False and template_cfg.get("include_file_name") is False and
      not any(o.get("type") == "regex_parser" or "regex" in o for o in template_cfg.get("operators") or []))
on_parsers = [o for o in on_receiver.get("operators") or [] if o.get("type") == "container_log_parser"]
check(f"logs off: {TEMPLATE} parses the container log format with the operator of {APP_RECEIVER}",
      template_cfg.get("operators") == on_parsers == [CONTAINER_LOG_PARSER])
rc_text = json.dumps(rc_cfg)
check(f"logs off: no $ in {RC} (the collector's confmap would expand it)", "$" not in rc_text)
check(f"logs off: {INFO_PIPELINE} is {RC} straight to the connector, with no processors",
      pipeline(lo, INFO_PIPELINE) == {"receivers": [RC], "exporters": [CONNECTOR]})
as_exporter, as_receiver = connector_users(lo)
check(f"logs off: the connector is the exporter of {INFO_PIPELINE} and a receiver of {VLLM_PIPELINE}",
      as_exporter == [INFO_PIPELINE] and as_receiver == [VLLM_PIPELINE])
check(f"logs off: pipelines are the configInfo-off ones plus {INFO_PIPELINE}",
      set(pipelines(lo)) == set(pipelines(lo_plain)) | {INFO_PIPELINE})
check("logs off: the connector (rule, storage, emit interval, caps) is the one of logs on",
      section(lo, "connectors").get(CONNECTOR) == section(on, "connectors").get(CONNECTOR))
check(f"logs off: {VLLM_PIPELINE} and the Info metric processors are the ones of logs on",
      pipeline(lo, VLLM_PIPELINE) == pipeline(on, VLLM_PIPELINE) and
      all(section(lo, "processors").get(p) == section(on, "processors").get(p) for p in INFO_PROCESSORS + (KEEP, POD)))
check(f"logs off: {STORAGE} is the one of logs on", section(lo, "extensions").get(STORAGE) == storage)

lo_crs = agent_crs(LO)
lo_node = lo_crs.get(AGENT) or {"spec": {}}
var_log_paths = sorted(set(re.findall(r"/var/log[^\s'\"`]*", json.dumps(lo))))
check("logs off: every path under /var/log in the otelConfig is under /var/log/pods",
      bool(var_log_paths) and all(p == "/var/log/pods" or p.startswith("/var/log/pods/") for p in var_log_paths))
check("logs off: /var/log/pods is mounted read-only on the node agent (the existing criologs volume)",
      [(m.get("mountPath"), m.get("readOnly")) for m in mounts(lo_node, "criologs")] == [("/var/log/pods", True)] and
      volumes(lo_node, "criologs") == [{"hostPath": {"path": "/var/log/pods"}, "name": "criologs"}] and
      sum(m.get("mountPath") == "/var/log/pods" for m in lo_node["spec"].get("volumeMounts") or []) == 1)
check("logs off: /var/log is not mounted on any agent",
      not any(mounts(cr, "varlog") or volumes(cr, "varlog") or
              any(m.get("mountPath") == "/var/log" for m in cr["spec"].get("volumeMounts") or [])
              for cr in lo_crs.values()))
check("logs off: the state volume is mounted writable on the node agent only",
      len(mounts(lo_node, "otelstate")) == 1 and not mounts(lo_node, "otelstate")[0].get("readOnly") and
      not any(mounts(cr, "otelstate") or volumes(cr, "otelstate") for n, cr in lo_crs.items() if n != AGENT))
check("logs off: the other agent CRs have none of the Info metric components",
      not any(mentions(otel_config(LO, a), x) for a in lo_crs if a != AGENT for x in ADDED))
node_env = {e.get("name"): e for e in lo_node["spec"].get("env") or []}
check(f"logs off: the node agent has K8S_NODE_NAME from spec.nodeName, for {OBSERVER}",
      node_env.get("K8S_NODE_NAME") == {"name": "K8S_NODE_NAME", "valueFrom": {"fieldRef": {"fieldPath": "spec.nodeName"}}})
role = next((d for d in docs(LO) if d.get("kind") == "ClusterRole" and d["metadata"]["name"] == f"{AGENT}-role"), {})
check(f"logs off: the agent ClusterRole lists and watches pods, for {OBSERVER}",
      any("" in (r.get("apiGroups") or []) and "pods" in (r.get("resources") or []) and
          {"list", "watch"} <= set(r.get("verbs") or []) for r in role.get("rules") or []))

# The rule mirrors the vLLM scrape detection. The rendered scrape step must be the one the
# rule was written for, and the two must agree on every case of a pod and container matrix.
scrape_steps = ((((section(lo, "receivers").get(VLLM_RECEIVER) or {}).get("config") or {})
                 .get("scrape_configs") or [{}])[0].get("relabel_configs") or [])[:2]
check("logs off: the vLLM scrape detection is the step the rule mirrors (labels, separator, regex)",
      len(scrape_steps) == 2 and scrape_steps[0].get("source_labels") == SCRAPE_SOURCES and
      scrape_steps[0].get("separator") == ";" and scrape_steps[0].get("regex") == SCRAPE_REGEX and
      scrape_steps[0].get("action") == "replace" and scrape_steps[1].get("action") == "keep")


def scrape_detects(isvc, comp, container, image):
    """The scrape detection: Prometheus anchors the regex. In RE2 the (?i) applies to the rest
    of its alternative, so in Python it becomes a scoped (?i:...) group. A missing label is ""."""
    regex = "^(?:" + SCRAPE_REGEX.replace("|(?i)", "|(?i:", 1) + "))$"
    return re.match(regex, ";".join([isvc or "", comp or "", container, image])) is not None


def rule_matches(isvc, comp, container, image):
    """The receiver_creator rule. A missing label is "" in the rule (pod.labels is a
    map[string]string), so None and "" give the same result."""
    return (((isvc or "") != "" and (comp or "") == "predictor" and container == "kserve-container") or
            re.search("(?i)vllm", image) is not None)


matrix = list(itertools.product(
    (None, "", "llama"), (None, "", "predictor", "Predictor", "transformer"),
    ("kserve-container", "queue-proxy", "vllm"),
    ("kserve/huggingfaceserver:v0.15.2", "vllm/vllm-openai:v0.10.1",
     "public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:v0.10.1", "registry.example.com/team/VLLM-serving:1.0",
     "public.ecr.aws/nginx/nginx:1.27")))
mismatch = [c for c in matrix if scrape_detects(*c) != rule_matches(*c)]
check(f"logs off: the rule and the scrape detection agree on {len(matrix)} pod and container cases",
      not mismatch and any(scrape_detects(*c) for c in matrix) and not all(scrape_detects(*c) for c in matrix))
for c in mismatch[:5]:
    print(f"    {c}: scrape {scrape_detects(*c)}, rule {rule_matches(*c)}")
for desc, case, want in (
        ("KServe predictor, any image", ("llama", "predictor", "kserve-container", "kserve/huggingfaceserver:v0.15.2"), True),
        ("vLLM image", (None, None, "vllm", "vllm/vllm-openai:v0.10.1"), True),
        ("CPU vLLM image", (None, None, "vllm", "public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:v0.10.1"), True),
        ("nginx", (None, None, "nginx", "public.ecr.aws/nginx/nginx:1.27"), False),
        ("KServe transformer", ("llama", "transformer", "kserve-container", "kserve/image-transformer:v0.15.2"), False),
        ("queue-proxy of a predictor", ("llama", "predictor", "queue-proxy", "gcr.io/knative-releases/queue:1"), False),
        ("pod with no labels", (None, None, "app", "busybox:1.36"), False)):
    check(f"logs off: {desc}: {'read' if want else 'not read'}",
          rule_matches(*case) == scrape_detects(*case) == want)

# --- stateStorage on, configInfo off -----------------------------------------------
print(f"\n{YELLOW}[stateStorage on, configInfo off]{RESET}")
so = otel_config("storage_only")
check(f"logs on: {STORAGE} is defined and in service.extensions",
      STORAGE in section(so, "extensions") and STORAGE in service_extensions(so))
check("logs on: no connector anywhere",
      not any(mentions(otel_config("storage_only", a), CONNECTOR) for a in agent_crs("storage_only")))
check("logs on: no Info metric processors, and the vLLM pipeline and keep filter are unchanged",
      not any(mentions(so, x) for x in (LIVE, CLEANUP, UID_SET_ASIDE, PREFILTER, OBSERVER, RC)) and
      pipeline(so, VLLM_PIPELINE) == pipeline(off, VLLM_PIPELINE) and
      section(so, "processors").get(KEEP) == section(off, "processors").get(KEEP))
check("logs on: same pipelines as the logs-on render", set(pipelines(so)) == set(pipelines(off)))
so_crs = agent_crs("storage_only")
check("logs on: the state volume is on the node agent only",
      len(mounts(so_crs.get(AGENT) or {"spec": {}}, "otelstate")) == 1 and
      not any(mounts(cr, "otelstate") for name, cr in so_crs.items() if name != AGENT))
# With logs off and configInfo off, no component uses the storage, so it does not render.
check("logs off: stateStorage on renders as stateStorage off (no extension, no hostPath)",
      same_render("lo_storage_plain", LOGS_OFF) and nothing_added("lo_storage_plain"))
check("logs off: stateStorage on with agent maxSurge 1 renders, as stateStorage off",
      same_render("lo_storage_surge_plain", "lo_surge_plain"))
check("logs off, configInfo on: stateStorage on changes nothing (the storage is on anyway)",
      same_render("lo_storage_info", LO) and same_render("lo_storage_tuned_info", "lo_tuned_info"))

# --- app-log checkpoints --------------------------------------------------------------
print(f"\n{YELLOW}[app-log checkpoints]{RESET}")
for name, want_storage, desc in (
        ("logs_on", None, "both flags off"),
        ("info_logs_on", None, "configInfo on, stateStorage off"),
        ("info_storage_logs_on", STORAGE, "configInfo on, stateStorage on"),
        ("storage_only", STORAGE, "stateStorage only")):
    cfg = otel_config(name)
    rec = section(cfg, "receivers").get(APP_RECEIVER)
    check(f"logs on, {desc}: {APP_RECEIVER} storage {want_storage or 'absent'}, start_at end",
          rec is not None and rec.get("storage") == want_storage and rec.get("start_at") == "end" and
          (want_storage is None or STORAGE in section(cfg, "extensions")))
check("configInfo on, stateStorage on: the receiver is the one of stateStorage only",
      section(otel_config("info_storage_logs_on"), "receivers").get(APP_RECEIVER) ==
      section(so, "receivers").get(APP_RECEIVER))
for name in ("info_logs_on", "info_storage_logs_on", LO, "lo_storage_info"):
    check(f"{name}: the connector keeps its state in {STORAGE}",
          (section(otel_config(name), "connectors").get(CONNECTOR) or {}).get("storage") == STORAGE)

# --- 8. every render: every defined component is used, every used one is defined -----
print(f"\n{YELLOW}[components defined and used]{RESET}")
for name in MODES:
    for agent in agent_crs(name):
        cfg = otel_config(name, agent)
        if cfg:
            missing = undefined_components(cfg)
            if not check(f"{name} / {agent}: every used component is defined", not missing):
                print(f"    undefined: {missing}")
            leftover = unused_components(cfg)
            if not check(f"{name} / {agent}: every defined component is used", not leftover):
                print(f"    unused: {leftover}")

# --- emitInterval and the other settings -------------------------------------------
print(f"\n{YELLOW}[emitInterval and limits]{RESET}")


def emit(name):
    return (section(otel_config(name), "connectors").get(CONNECTOR) or {}).get("emit_interval")


check("emitInterval empty follows metricResolution (20s)", emit("emit_metric_resolution") == "20s")
check('emitInterval "15s" is used as is', emit("emit_15s") == "15s")
check('emitInterval "1h" is used as is', emit("emit_1h") == "1h")
check("logs off: emitInterval empty follows metricResolution (20s), and caps come from values",
      emit("lo_metric_resolution_info") == "20s" and
      (section(otel_config("lo_tuned_info"), "connectors").get(CONNECTOR) or {}).get("max_state_bytes") == 70000)


def duration_error(setting, value):
    """The message of otel-container-insights.vllmInfoDuration, shared by emitInterval and pollInterval."""
    return (f'{setting} must be a duration in "<N>s", "<N>m" or "<N>h" format between 1s and 24h '
            f'(e.g. "60s", "5m", "1h"), got: {value}')


CONFIG_INFO = "otelContainerInsights.solutions.vllm.configInfo"
for name, setting, value, desc in (
        *((f"emit_bad_{bad}", f"{CONFIG_INFO}.emitInterval", bad, f'emitInterval "{bad}"')
          for bad in ("15", "0s", "25h", "1m30s", "abc")),
        ("emit_bad_resolution",
         "otelContainerInsights.metricResolution (used because solutions.vllm.configInfo.emitInterval is empty)",
         "90000s", 'emitInterval empty, metricResolution "90000s"'),
        ("lo_bad_emit", f"{CONFIG_INFO}.emitInterval", "0s", 'logs off, emitInterval "0s"')):
    if not check(f"{desc} fails the render with the duration message naming the setting",
                 rc(name) != 0 and duration_error(setting, value) in err(name)):
        show_err(name)
for prefix, mode in (("", "logs on"), ("lo_", "logs off")):
    for name, setting in (("bad_max_state_bytes", "maxStateBytes"), ("bad_max_value_length", "maxValueLength"),
                          ("bad_max_entities", "maxEntities")):
        check(f"{mode}: {setting} out of the connector's bounds fails the render",
              rc(prefix + name) != 0 and f"configInfo.{setting}" in err(prefix + name))
    check(f"{mode}: a relative stateStorage.hostPath fails the render",
          rc(prefix + "bad_host_path") != 0 and "stateStorage.hostPath" in err(prefix + "bad_host_path"))
    for name, value in (("bad_host_path_dot", "/."), ("bad_host_path_dotdot", "/var/.."),
                        ("bad_host_path_inner", "/var/./lib/x")):
        check(f"{mode}: a stateStorage.hostPath with a '.' or '..' segment ({value}) fails the render",
              rc(prefix + name) != 0 and "stateStorage.hostPath" in err(prefix + name))
    check(f"{mode}: a stateStorage.hostPath with dots inside a name (/var/lib/.state..d) renders",
          rc(prefix + "good_host_path_dots") == 0)
check("logs off, configInfo on: every new setting out of its bounds fails the render",
      rc("lo_out_of_bounds_info") != 0 and rc("lo_storage_out_of_bounds_info") != 0)
check("logs off, configInfo off: no new setting is checked, as none takes effect (out-of-bounds values render)",
      rc("lo_out_of_bounds_plain") == 0 and rc("lo_storage_out_of_bounds_plain") == 0 and
      rc("lo_bad_poll_plain") == 0)

# --- pollInterval ------------------------------------------------------------------------
print(f"\n{YELLOW}[pollInterval]{RESET}")


def poll(name):
    rcv = section(otel_config(name), "receivers").get(RC) or {}
    return ((((rcv.get("receivers") or {}).get(TEMPLATE) or {}).get("config")) or {}).get("poll_interval")


# The logs-off poll interval is configInfo.pollInterval as is. When that is empty, it is 2s,
# or the effective emit interval when that is shorter.
for name, want, desc in ((LO, "2s", "pollInterval empty, emitInterval 30s (the defaults)"),
                         ("poll_emit_1s", "1s", "emitInterval 1s"),
                         ("poll_emit_5s", "2s", "emitInterval 5s"),
                         ("poll_emit_2m", "2s", "emitInterval 2m"),
                         ("poll_resolution_1s", "1s", "emitInterval empty, metricResolution 1s"),
                         ("poll_set_10s", "10s", "pollInterval 10s"),
                         ("poll_set_10s_emit_5s", "10s", "pollInterval 10s, emitInterval 5s"),
                         ("poll_set_1h", "1h", "pollInterval 1h")):
    check(f"logs off, {desc}: {TEMPLATE} poll_interval {want}", poll(name) == want)
check("logs on: pollInterval 10s has no effect (the render is the configInfo-on, logs-on one)",
      rc("poll_set_10s_logs_on") == 0 and redacted("poll_set_10s_logs_on") == redacted("info_logs_on"))
check("logs on: emitInterval 5s does not add a poll interval anywhere",
      rc("poll_emit_5s_logs_on") == 0 and "poll_interval" not in json.dumps(otel_config("poll_emit_5s_logs_on")))
check("logs on: emitInterval null renders as emitInterval empty", same_render("emit_null", "info_logs_on"))
check("logs off: emitInterval null renders as emitInterval empty", same_render("lo_emit_null", LO))
check("logs off: pollInterval null renders as pollInterval empty", same_render("poll_null", LO))
for name, value, desc in (*((f"poll_bad_{bad}", bad, f'logs off, pollInterval "{bad}"')
                            for bad in ("500ms", "0s", "25h", "15", "abc")),
                          ("poll_bad_500ms_logs_on", "500ms", 'logs on, pollInterval "500ms"'),
                          ("lo_bad_poll_info", "500ms", 'logs off (value set), pollInterval "500ms"')):
    if not check(f"{desc} fails the render with the duration message naming the setting",
                 rc(name) != 0 and duration_error(f"{CONFIG_INFO}.pollInterval", value) in err(name)):
        show_err(name)

# --- maxSurge guard ------------------------------------------------------------------
print(f"\n{YELLOW}[maxSurge guard]{RESET}")
for name, desc in (("surge_info", "logs on, configInfo on, agent maxSurge 1"),
                   ("surge_storage", "logs on, stateStorage on, agent maxSurge 1"),
                   ("surge_agents_entry", "logs on, configInfo on, agents[] entry maxSurge 10%"),
                   ("lo_surge_info", "logs off, configInfo on, agent maxSurge 1"),
                   ("lo_storage_surge_info", "logs off, configInfo on, stateStorage on, agent maxSurge 1"),
                   ("lo_agents_surge_info", "logs off, configInfo on, agents[] entry maxSurge 10%")):
    check(f"{desc}: fails the render with a maxSurge message", rc(name) != 0 and "maxSurge 0" in err(name))
check("OnDelete has no surge and renders, logs on or off",
      rc("surge_on_delete") == 0 and rc("lo_on_delete_info") == 0)
check("the cluster-scraper Deployment's 25% maxSurge does not trip the guard",
      rc("info_logs_on") == 0 and rc(LO) == 0)
check("logs off, configInfo off: no storage, so maxSurge 1 or 10% renders, with or without stateStorage",
      all(rc(f"lo_{n}_plain") == 0 for n in ("surge", "storage_surge", "agents_surge")))

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
