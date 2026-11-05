#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Validates otelFilters by rendering `helm template` and checking the exact
# processors and pipeline placement in the generated OTEL configs. Also checks
# the cloudwatch-agent/otel-config-sha256 pod annotation, which restarts an
# agent when its final otelConfig changes. This test renders locally and never
# connects to a cluster.
#
# Requires python3 with PyYAML.
#
# Run from the repo root:
#     bash charts/amazon-cloudwatch-observability/tests/otel_ci_filters.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for readable output.
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
N='\033[0m'

pass_count=0
fail_count=0

# ──────────────────────────────────────────────────────────────────────────
# render — run helm template with the given filters into $RENDERED.
#
# Arguments:
#   $1   otelFilters as JSON
#   $2+  extra helm arguments (optional)
# Returns helm's exit code; output (or the error) is in $RENDERED.
# ──────────────────────────────────────────────────────────────────────────
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT

render() {
    local filters="$1"
    shift
    helm template "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        --set otelContainerInsights.enabled=true \
        --set-json "otelFilters=$filters" "$@" >"$RENDERED" 2>&1
}

# ──────────────────────────────────────────────────────────────────────────
# check_case — render and run python assertions on the parsed OTEL configs.
#
# Arguments:
#   $1   description shown in output
#   $2   otelFilters as JSON
#   $3   python assertions (see below)
#   $4+  extra helm arguments (optional)
#
# The assertions run with:
#   cfg[agent]                     OTEL config of each AmazonCloudWatchAgent
#   processor(agent, name)         a processor's config, or None
#   pipeline(agent, name)          a pipeline's processor list
#   pipelines_with(agent, name)    names of the pipelines that use a processor
#   NS                             the OTTL namespace path
# and fail with the message of the first failed assert.
# ──────────────────────────────────────────────────────────────────────────
check_case() {
    local desc="$1" filters="$2" assertions="$3"
    shift 3

    printf "\n${Y}[Case]${N} %s\n" "$desc"

    if ! render "$filters" "$@"; then
        echo -e "  ${R}FAIL${N}: helm template failed unexpectedly"
        tail -5 "$RENDERED" | sed 's/^/    /'
        fail_count=$((fail_count + 1))
        return
    fi

    local result
    if result=$(python3 - "$RENDERED" "$assertions" <<'PY' 2>&1
import sys, yaml

with open(sys.argv[1]) as f:
    docs = [d for d in yaml.safe_load_all(f) if d]
cfg = {}
for d in docs:
    if d.get("kind") == "AmazonCloudWatchAgent" and d["spec"].get("otelConfig"):
        cfg[d["metadata"]["name"]] = yaml.safe_load(d["spec"]["otelConfig"])

def processor(agent, name):
    return cfg[agent].get("processors", {}).get(name)

def pipeline(agent, name):
    return cfg[agent]["service"]["pipelines"][name]["processors"]

def pipelines_with(agent, name):
    return sorted(p for p, v in cfg[agent]["service"]["pipelines"].items()
                  if name in v.get("processors", []))

NS = 'resource.attributes["k8s.namespace.name"]'
exec(sys.argv[2])
PY
    ); then
        echo -e "  ${G}PASS${N}"
        pass_count=$((pass_count + 1))
    else
        echo -e "  ${R}FAIL${N}: $(tail -1 <<< "$result")"
        fail_count=$((fail_count + 1))
    fi
}

# ──────────────────────────────────────────────────────────────────────────
# check_fails — render and expect helm template to fail with a message.
#
# Arguments:
#   $1   description shown in output
#   $2   otelFilters as JSON
#   $3   fragment that MUST be in the error message
#   $4+  extra helm arguments (optional)
# ──────────────────────────────────────────────────────────────────────────
check_fails() {
    local desc="$1" filters="$2" message="$3"
    shift 3

    printf "\n${Y}[Case]${N} %s\n" "$desc"

    if render "$filters" "$@"; then
        echo -e "  ${R}FAIL${N}: expected helm template to fail, but it succeeded"
        fail_count=$((fail_count + 1))
    elif ! grep -qF -- "$message" "$RENDERED"; then
        echo -e "  ${R}FAIL${N}: error does not contain: $message"
        tail -3 "$RENDERED" | sed 's/^/    /'
        fail_count=$((fail_count + 1))
    else
        echo -e "  ${G}PASS${N}"
        pass_count=$((pass_count + 1))
    fi
}

# ──────────────────────────────────────────────────────────────────────────
# check_renders — run python assertions that render the chart themselves,
# for cases that compare several renders.
#
# Arguments:
#   $1  description shown in output
#   $2  python assertions (see below)
#
# The assertions run with:
#   render(*args)   renders the chart with Container Insights on, plus the
#                   extra helm arguments, and returns a dict per
#                   AmazonCloudWatchAgent: otelConfig (text or None),
#                   annotations (spec.podAnnotations or {}), hash (the
#                   otel-config-sha256 annotation or None) and keys (how often
#                   the raw document has a podAnnotations key).
#   sha256(text)    hex SHA-256 of a string
#   HASH            the annotation key
# ──────────────────────────────────────────────────────────────────────────
check_renders() {
    local desc="$1" assertions="$2"

    printf "\n${Y}[Case]${N} %s\n" "$desc"

    local result
    if result=$(python3 - "$CHART_DIR" "$assertions" <<'PY' 2>&1
import hashlib, re, subprocess, sys, yaml

CHART = sys.argv[1]
HASH = "cloudwatch-agent/otel-config-sha256"

def sha256(text):
    return hashlib.sha256(text.encode()).hexdigest()

def render(*args):
    out = subprocess.run(
        ["helm", "template", CHART, "--set", "region=us-west-2",
         "--set", "clusterName=test-cluster",
         "--set", "otelContainerInsights.enabled=true", *args],
        check=True, capture_output=True, text=True).stdout
    agents = {}
    for raw in re.split(r"^---\s*$", out, flags=re.M):
        d = yaml.safe_load(raw)
        if not d or d.get("kind") != "AmazonCloudWatchAgent":
            continue
        annotations = d["spec"].get("podAnnotations") or {}
        agents[d["metadata"]["name"]] = {
            "otelConfig": d["spec"].get("otelConfig"),
            "annotations": annotations,
            "hash": annotations.get(HASH),
            "keys": len(re.findall(r"^\s*podAnnotations:", raw, flags=re.M)),
        }
    return agents

exec(sys.argv[2])
PY
    ); then
        echo -e "  ${G}PASS${N}"
        pass_count=$((pass_count + 1))
    else
        echo -e "  ${R}FAIL${N}: $(tail -1 <<< "$result")"
        fail_count=$((fail_count + 1))
    fi
}

NODE="cloudwatch-agent"
SCRAPER="cloudwatch-agent-cluster-scraper"
METRICS_NS="filter/cw_k8s_ci_v0_metrics_namespaces"
LOGS_NS="filter/cw_k8s_ci_v0_logs_namespaces"
DEVICE_NS="transform/cw_k8s_ci_v0_device_namespaces"

# 63 and 64 characters: the longest valid namespace and one too long.
NS63="$(printf 'a%.0s' {1..63})"
NS64="${NS63}a"

# Entry kinds for the include x exclude matrix. Include and exclude never share
# an entry: validation rejects that.
declare -A NS_KINDS_INCLUDE=(
    [none]='[]' [exact]='["prod"]' [prefix]='["team-*"]' [star]='["*"]' [mixed]='["prod","team-*"]')
declare -A NS_KINDS_EXCLUDE=(
    [none]='[]' [exact]='["kube-system"]' [prefix]='["kube-*"]' [star]='["*"]' [mixed]='["kube-system","team-legacy-*"]')

echo "=== OTEL CI filters ==="
echo "Chart: $CHART_DIR"

# ── Namespaces ──────────────────────────────────────────────────────────

# Expected processor blocks for a list of datapoint/log_record conditions.
NS_BLOCKS="
def metrics_ns(*conditions):
    return {'error_mode': 'ignore', 'metrics': {'datapoint': list(conditions)}}
def logs_ns(*conditions):
    return {'error_mode': 'ignore', 'logs': {'log_record': list(conditions)}}
def ns_processor(name):
    # The metrics filter is defined in both agents and must be the same in each.
    agents = ['$SCRAPER', '$NODE'] if name == '$METRICS_NS' else ['$NODE']
    got = [processor(agent, name) for agent in agents]
    assert all(g == got[0] for g in got), got
    return got[0]
RNS = 'attributes[\"k8s.namespace.name\"]'
def device_ns(*conditions):
    # The device transform matches like the filter. Its resource group reads
    # the namespace with the resource path. The datapoint group runs first.
    return {'error_mode': 'ignore', 'metric_statements': [
        {'context': 'datapoint', 'conditions': list(conditions),
         'statements': ['delete_key(attributes, \"pod\")', 'delete_key(attributes, \"namespace\")',
                        'delete_key(attributes, \"container\")']},
        {'context': 'resource', 'conditions': [c.replace(NS, RNS) for c in conditions],
         'statements': ['delete_key(attributes, \"k8s.pod.name\")', 'delete_key(attributes, \"k8s.container.name\")',
                        'delete_key(attributes, \"k8s.namespace.name\")']}]}
def ns_filters(*conditions):
    # One list sets the metrics and the logs filter and the device transform,
    # with the same conditions.
    assert ns_processor('$METRICS_NS') == metrics_ns(*conditions), ns_processor('$METRICS_NS')
    assert ns_processor('$LOGS_NS') == logs_ns(*conditions), ns_processor('$LOGS_NS')
    assert processor('$NODE', '$DEVICE_NS') == device_ns(*conditions), processor('$NODE', '$DEVICE_NS')
    assert processor('$SCRAPER', '$DEVICE_NS') is None
def ns_match(entries):
    parts = []
    for e in entries:
        if e == '*':
            parts.append('true')
        elif e.endswith('*'):
            parts.append('IsMatch(' + NS + ', \"^' + e[:-1] + '\")')
        else:
            parts.append(NS + ' == \"' + e + '\"')
    return '(' + ' or '.join(parts) + ')'
def no_ns_filters():
    for agent in cfg:
        assert processor(agent, '$METRICS_NS') is None, agent
        assert processor(agent, '$LOGS_NS') is None, agent
        assert not pipelines_with(agent, '$METRICS_NS'), agent
        assert not pipelines_with(agent, '$LOGS_NS'), agent
        assert processor(agent, '$DEVICE_NS') is None, agent
        assert not pipelines_with(agent, '$DEVICE_NS'), agent
"

for value in '{}' '{"namespaces":{}}' '{"namespaces":{"include":[],"exclude":[]}}' \
    '{"namespaces":{"include":null,"exclude":null}}' '{"namespaces":null}'; do
    check_case "No namespace filter processors for $value" "$value" "$NS_BLOCKS
no_ns_filters()"
done

check_case "Namespaces — a duplicate exclude entry renders once" \
    '{"namespaces":{"exclude":["a","a"]}}' "$NS_BLOCKS
ns_filters(NS + ' != nil and (' + NS + ' == \"a\")')"

check_case "Namespaces — a duplicate include entry renders once" \
    '{"namespaces":{"include":["a","b*","a","b*"],"exclude":["c","c"]}}' "$NS_BLOCKS
ns_filters(NS + ' != nil and not (' + NS + ' == \"a\" or IsMatch(' + NS + ', \"^b\"))',
           NS + ' != nil and (' + NS + ' == \"c\")')"

check_case "Namespaces — * among other include entries adds no include condition" \
    '{"namespaces":{"include":["a","*"],"exclude":["b"]}}' "$NS_BLOCKS
ns_filters(NS + ' != nil and (' + NS + ' == \"b\")')"

# Every pairing of include and exclude kinds, each on its own and together.
# ns_match is the expected translation: "*" is true, "x*" an anchored
# IsMatch, anything else ==. An include containing "*" adds no condition.
for include in none exact prefix star mixed; do
    for exclude in none exact prefix star mixed; do
        # none/none is the default (above); * in both lists is rejected (below).
        [[ "$include" == none && "$exclude" == none ]] && continue
        [[ "$include" == star && "$exclude" == star ]] && continue
        check_case "Namespaces — include $include, exclude $exclude" \
            "{\"namespaces\":{\"include\":${NS_KINDS_INCLUDE[$include]},\"exclude\":${NS_KINDS_EXCLUDE[$exclude]}}}" "$NS_BLOCKS
include, exclude = ${NS_KINDS_INCLUDE[$include]}, ${NS_KINDS_EXCLUDE[$exclude]}
conditions = []
if include and '*' not in include:
    conditions.append(NS + ' != nil and not ' + ns_match(include))
if exclude:
    conditions.append(NS + ' != nil and ' + ns_match(exclude))
if conditions:
    ns_filters(*conditions)
else:
    no_ns_filters()"
    done
done

check_case "Namespaces — 63-character names and prefixes" \
    "{\"namespaces\":{\"include\":[\"$NS63\",\"$NS63*\"]}}" "$NS_BLOCKS
ns_filters(NS + ' != nil and not (' + NS + ' == \"$NS63\" or IsMatch(' + NS + ', \"^$NS63\"))')"

# Every pipeline that emits resource k8s.namespace.name for a workload gets
# the namespace filter, or, for the device pipelines (DCGM, Neuron, EFA), the
# device transform, which keeps the datapoints and removes the pod. The set is derived from the rendered config, so a new
# pipeline that carries a namespace fails here until it is filtered (or added
# to the controller exceptions: Karpenter, KEDA and the KServe and Knative
# control planes, which only report their own namespace). The kubeletstats
# receiver sets the attribute itself; elsewhere a receiver or processor names
# it before k8sattributes. The filter must run after the last processor before
# k8sattributes that names the attribute, or it sees no namespace.
check_case "Namespaces — every pipeline that emits k8s.namespace.name is filtered (device pipelines: transformed) after it is set and before k8sattributes, except the controller pipelines" \
    '{"namespaces":{"exclude":["kube-system"]}}' "$NS_BLOCKS
import json
CONTROLLER_PIPELINES = {'metrics/cw_k8s_ci_v0_karpenter', 'metrics/cw_k8s_ci_v0_keda',
                        'metrics/cw_k8s_ci_v0_kserve_controlplane', 'metrics/cw_k8s_ci_v0_knative_controlplane'}
rendered = {n for a in cfg for n in cfg[a]['service']['pipelines']}
DEVICE_PIPELINES = {'metrics/cw_k8s_ci_v0_dcgm', 'metrics/cw_k8s_ci_v0_neuron', 'metrics/cw_k8s_ci_v0_efa'}
NS_STEPS = ('$METRICS_NS', '$LOGS_NS', '$DEVICE_NS')
assert CONTROLLER_PIPELINES | DEVICE_PIPELINES | {'metrics/cw_k8s_ci_v0_vllm', 'metrics/cw_k8s_ci_v0_knative_dataplane'} <= rendered, rendered
assert pipelines_with('$NODE', '$DEVICE_NS') == sorted(DEVICE_PIPELINES), pipelines_with('$NODE', '$DEVICE_NS')
for agent in cfg:
    c = cfg[agent]
    for name, p in c['service']['pipelines'].items():
        procs = p['processors']
        first_k8s = next((i for i, x in enumerate(procs) if x.startswith('k8sattributes/')), len(procs))
        sources = [c['receivers'][r] for r in p['receivers']] + [
            c['processors'][x] for x in procs[:first_k8s] if not x.startswith('filter/') and x not in NS_STEPS]
        emits = (any(r.startswith('kubeletstats/') for r in p['receivers'])
                 or any('k8s.namespace.name' in json.dumps(s) for s in sources))
        want = '$DEVICE_NS' if name in DEVICE_PIPELINES else '$METRICS_NS' if name.startswith('metrics/') else '$LOGS_NS'
        filtered = want in procs
        expected = emits and name not in CONTROLLER_PIPELINES
        # A pipeline has at most its own namespace step, never another one.
        assert [x for x in procs if x in NS_STEPS and x != want] == [], (agent, name, procs)
        assert filtered == expected, (agent, name, 'emits' if emits else 'no namespace', 'filtered' if filtered else 'not filtered')
        if filtered:
            # Before k8sattributes, and only once.
            assert procs.count(want) == 1 and procs.index(want) < first_k8s, (agent, name, procs)
            # After every processor that names the attribute. A receiver
            # that sets it counts as position -1.
            setters = [i for i, x in enumerate(procs[:first_k8s])
                       if not x.startswith('filter/') and x not in NS_STEPS and 'k8s.namespace.name' in json.dumps(c['processors'][x])]
            assert procs.index(want) > max(setters, default=-1), (agent, name, procs)
" --set dcgmExporter.enabled=true --set neuronMonitor.enabled=true \
    --set otelContainerInsights.solutions.vllm.enabled=true \
    --set otelContainerInsights.solutions.kserve.controlPlane.enabled=true \
    --set otelContainerInsights.solutions.knative.dataPlane.enabled=true \
    --set otelContainerInsights.solutions.knative.controlPlane.enabled=true

# EFA: the receiver emits one resource per node, and awsdevicepodcorrelation
# sets the pod of each card on its datapoints. groupbyattrs moves the pod to
# its own resource before the device transform, so the transform judges each
# card by its own pod. No processor copies a datapoint namespace onto the
# shared node resource.
check_case "Namespaces — EFA cards are grouped by pod before the device transform" \
    '{"namespaces":{"exclude":["team-b"]}}' "$NS_BLOCKS
import json
procs = pipeline('$NODE', 'metrics/cw_k8s_ci_v0_efa')
grp = 'groupbyattrs/cw_k8s_ci_v0_efa'
assert processor('$NODE', grp) == {'keys': ['k8s.pod.name', 'k8s.namespace.name', 'k8s.container.name']}, processor('$NODE', grp)
assert procs.index('awsdevicepodcorrelation/cw_k8s_ci_v0') < procs.index(grp) < procs.index('$DEVICE_NS') < procs.index('k8sattributes/cw_k8s_ci_v0_pod'), procs
# groupbyattrs is the only processor before the transform that names the namespace.
before = procs[:procs.index('$DEVICE_NS')]
assert [x for x in before if 'k8s.namespace.name' in json.dumps(processor('$NODE', x))] == [grp], before"

check_case "Namespaces with OTEL logs disabled — metrics filter only" \
    '{"namespaces":{"exclude":["kube-system"]}}' "$NS_BLOCKS
assert ns_processor('$METRICS_NS') == metrics_ns(NS + ' != nil and (' + NS + ' == \"kube-system\")')
assert processor('$NODE', '$LOGS_NS') is None
assert not pipelines_with('$NODE', '$LOGS_NS')
assert processor('$NODE', '$DEVICE_NS') == device_ns(NS + ' != nil and (' + NS + ' == \"kube-system\")')" --set otelContainerInsights.logs.enabled=false

message="otelFilters.namespaces entries must be"
long="otelFilters.namespaces entries must be at most 63 characters"
for case in "include|uppercase|[\"Prod\"]|$message" \
            "exclude|* not at the end|[\"a*b\"]|$message" \
            "include|leading -|[\"-a\"]|$message" \
            "exclude|trailing - on an exact name|[\"a-\"]|$message" \
            "exclude|dot|[\"a.b*\"]|$message" \
            "include|quote|[\"a\\\"b\"]|$message" \
            "exclude|empty string|[\"\"]|$message" \
            "include|not a string|[123]|$message" \
            "exclude|64-character name|[\"$NS64\"]|$long" \
            "include|64-character prefix|[\"$NS64*\"]|$long" \
            "exclude|a string, not a list|\"prod\"|otelFilters.namespaces.exclude must be a list"; do
    IFS='|' read -r list what value expect <<< "$case"
    check_fails "Invalid namespaces.$list — $what" \
        "{\"namespaces\":{\"$list\":$value}}" "$expect"
done
check_fails "Invalid namespaces — unknown key" \
    '{"namespaces":{"excludes":["kube-system"]}}' 'otelFilters.namespaces has an unknown key "excludes"'
check_fails "Invalid namespaces — not a map" \
    '{"namespaces":["kube-system"]}' "otelFilters.namespaces must be a map"
check_fails "Invalid namespaces — exact entry in include and exclude" \
    '{"namespaces":{"include":["a","b"],"exclude":["b"]}}' 'otelFilters.namespaces: "b" is in both include and exclude'
check_fails "Invalid namespaces — * in include and exclude" \
    '{"namespaces":{"include":["*"],"exclude":["*"]}}' 'otelFilters.namespaces: "*" is in both include and exclude'

check_fails "Invalid otelFilters — unknown key" '{"namespace":{}}' 'otelFilters has an unknown key "namespace"'
check_fails "Invalid otelFilters — a signal key" '{"metrics":{}}' 'otelFilters has an unknown key "metrics"'
check_fails "Invalid otelFilters — not a map" '[]' "otelFilters must be a map"

OLD_KEY="otelContainerInsights.filters is not supported. Set the filters in the top-level otelFilters block"
check_fails "otelContainerInsights.filters — fails with a pointer to otelFilters" \
    '{}' "$OLD_KEY" --set-json 'otelContainerInsights.filters={"metrics":{"namespaces":{"exclude":["kube-system"]}}}'
check_fails "otelContainerInsights.filters — an empty map also fails" \
    '{}' "$OLD_KEY" --set-json 'otelContainerInsights.filters={}'
check_fails "otelContainerInsights.filters — fails with Container Insights off" \
    '{}' "$OLD_KEY" --set otelContainerInsights.enabled=false --set-json 'otelContainerInsights.filters={}'

# ── The otelConfig hash ─────────────────────────────────────────────────
# The operator restarts the agent pods only for a pod template change, and its
# own hash does not cover spec.otelConfig. The chart puts the hash of each
# agent's final otelConfig in that agent's podAnnotations.

check_renders "Hash — each agent with an otelConfig gets the SHA-256 of its final otelConfig" "
agents = render()
assert set(agents) >= {'$NODE', '$SCRAPER'}, sorted(agents)
for name, a in agents.items():
    if a['otelConfig']:
        assert a['hash'] == sha256(a['otelConfig']), (name, a['hash'])
    else:
        assert a['hash'] is None and HASH not in a['annotations'], (name, a['annotations'])
assert agents['$NODE']['hash'] and agents['$SCRAPER']['hash']
assert agents['$NODE']['hash'] != agents['$SCRAPER']['hash']"

check_renders "Hash — the same values give the same hash" "
first, second = render('--set-json', 'otelFilters={\"namespaces\":{\"exclude\":[\"kube-system\"]}}'), \
                render('--set-json', 'otelFilters={\"namespaces\":{\"exclude\":[\"kube-system\"]}}')
for name in ('$NODE', '$SCRAPER'):
    assert first[name]['hash'] and first[name]['hash'] == second[name]['hash'], name"

check_renders "Hash — a changed namespace list gives a new hash on both agents" "
default = render()
one = render('--set-json', 'otelFilters={\"namespaces\":{\"exclude\":[\"kube-system\"]}}')
two = render('--set-json', 'otelFilters={\"namespaces\":{\"exclude\":[\"kube-system\",\"test-*\"]}}')
for name in ('$NODE', '$SCRAPER'):
    hashes = {default[name]['hash'], one[name]['hash'], two[name]['hash']}
    assert len(hashes) == 3, (name, hashes)
    for r in (default, one, two):
        assert r[name]['hash'] == sha256(r[name]['otelConfig']), name"

check_renders "Hash — a changed agents[].otelConfig gives a new hash on that agent only" "
def agents_value(processors):
    import json
    return 'agents=' + json.dumps([
        {'name': '$NODE', 'otelConfig': {'processors': processors}},
        {'name': '$SCRAPER', 'mode': 'deployment', 'replicas': 1}])
default = render('--set-json', agents_value({}))
one = render('--set-json', agents_value({'batch/customer': {'timeout': '5s'}}))
two = render('--set-json', agents_value({'batch/customer': {'timeout': '10s'}}))
assert 'batch/customer' in yaml.safe_load(one['$NODE']['otelConfig'])['processors']
assert len({default['$NODE']['hash'], one['$NODE']['hash'], two['$NODE']['hash']}) == 3
for r in (default, one, two):
    assert r['$NODE']['hash'] == sha256(r['$NODE']['otelConfig'])
assert default['$SCRAPER']['hash'] == one['$SCRAPER']['hash'] == two['$SCRAPER']['hash']"

check_renders "Hash — an agents[].otelConfig with Container Insights off gets a hash" "
import json
agents = render('--set', 'otelContainerInsights.enabled=false', '--set-json', 'agents=' + json.dumps([
    {'name': '$NODE', 'otelConfig': {'processors': {'batch/customer': {}}}}]))
assert agents['$NODE']['otelConfig'], agents['$NODE']
assert agents['$NODE']['hash'] == sha256(agents['$NODE']['otelConfig'])"

check_renders "Hash — no otelConfig, no hash" "
agents = render('--set', 'otelContainerInsights.enabled=false')
assert agents, agents
for name, a in agents.items():
    assert a['otelConfig'] is None, name
    assert a['annotations'] == {} and a['keys'] == 0, (name, a['annotations'], a['keys'])"

check_renders "Hash — the customer's podAnnotations stay, in one podAnnotations key" "
import json
root = render('--set-json', 'podAnnotations={\"team\":\"obs\",\"example.com/owner\":\"me\"}')
for name in ('$NODE', '$SCRAPER'):
    a = root[name]
    assert a['annotations'] == {'team': 'obs', 'example.com/owner': 'me', HASH: a['hash']}, (name, a['annotations'])
    assert a['hash'] == sha256(a['otelConfig']) and a['keys'] == 1, (name, a['keys'])
own = render('--set-json', 'podAnnotations={\"team\":\"obs\"}', '--set-json', 'agents=' + json.dumps([
    {'name': '$NODE', 'podAnnotations': {'agent': 'node'}},
    {'name': '$SCRAPER', 'mode': 'deployment', 'replicas': 1}]))
assert own['$NODE']['annotations'] == {'agent': 'node', HASH: own['$NODE']['hash']}, own['$NODE']['annotations']
assert own['$SCRAPER']['annotations'] == {'team': 'obs', HASH: own['$SCRAPER']['hash']}, own['$SCRAPER']['annotations']
for name, a in own.items():
    assert a['keys'] == 1, (name, a['keys'])
off = render('--set', 'otelContainerInsights.enabled=false', '--set-json', 'podAnnotations={\"team\":\"obs\"}')
for name, a in off.items():
    assert a['annotations'] == {'team': 'obs'} and a['keys'] == 1, (name, a['annotations'], a['keys'])"

# "Error" is a valid annotation name. fromYaml also uses that key for a parse
# error, so the map check must not read it.
check_renders "Hash — a customer annotation named Error stays" "
root = render('--set-json', 'podAnnotations={\"Error\":\"x\",\"team\":\"obs\"}')
for name in ('$NODE', '$SCRAPER'):
    a = root[name]
    assert a['annotations'] == {'Error': 'x', 'team': 'obs', HASH: a['hash']}, (name, a['annotations'])
own = render('--set-json', 'agents=[{\"name\":\"$NODE\",\"podAnnotations\":{\"Error\":\"y\"}}]')
assert own['$NODE']['annotations'] == {'Error': 'y', HASH: own['$NODE']['hash']}, own['$NODE']['annotations']"

# podAnnotations that are not a map fail the render, as the API server would.
check_fails "Hash — agents[].podAnnotations that is a list fails" '{}' \
    "podAnnotations of agent $NODE must be a map of annotation names to values" \
    --set-json "agents=[{\"name\":\"$NODE\",\"podAnnotations\":[\"foo\"]}]"
check_fails "Hash — agents[].podAnnotations that is not a map fails" '{}' \
    "podAnnotations of agent $NODE must be a map of annotation names to values" \
    --set-json "agents=[{\"name\":\"$NODE\",\"podAnnotations\":\"foo\"}]"
check_fails "Hash — root podAnnotations that is not a map fails" '{}' \
    "podAnnotations of agent $NODE must be a map of annotation names to values" \
    --set podAnnotations=foo

# ── Labels ──────────────────────────────────────────────────────────────
# otelFilters.podLabels and otelFilters.nodeLabels: one list per kind, shared
# by metrics and logs. Include sets the shared k8sattributes rules. Exclude,
# the recommended exclusions and the chart's labels that the include list
# leaves out form one removal list: awsattributelimit for metrics, and the
# logs label transform for the application and host logs. A named include
# entry (not "*") keeps a recommended exclusion. A recommended prefix with a
# named entry inside it is removed by OTTL statements instead: the metrics
# label transform before awsattributelimit, and the start of the logs label
# transform.

LOGS_LABELS="transform/cw_k8s_ci_v0_logs_labels"
METRICS_LABELS="transform/cw_k8s_ci_v0_metrics_labels"

# Expected processor blocks. The recommended exclusions are the
# awsattributelimit removal lists before label filters were added, plus
# the Karpenter, EKS Auto Mode and pod-label additions from #383.
LABEL_BLOCKS="
RECOMMENDED_PREFIXES = [
    'k8s.node.label.feature.node.kubernetes.io/',
    'k8s.node.label.beta.kubernetes.io/',
    'k8s.node.label.failure-domain.beta.kubernetes.io/',
    'k8s.node.label.alpha.eksctl.io/',
    'k8s.node.label.karpenter.k8s.aws/instance-cpu',
    'k8s.node.label.karpenter.k8s.aws/instance-gpu-',
    'k8s.node.label.karpenter.k8s.aws/instance-accelerator-',
    'k8s.node.label.eks.amazonaws.com/instance-',
]
RECOMMENDED_NODE_KEYS = [
    'k8s.node.label.topology.kubernetes.io/region',
    'k8s.node.label.topology.kubernetes.io/zone',
    'k8s.node.label.topology.ebs.csi.aws.com/zone',
    'k8s.node.label.node.kubernetes.io/instance-type',
    'k8s.node.label.kubernetes.io/hostname',
    'k8s.node.label.helm.sh/chart',
    'k8s.node.label.release',
    'k8s.node.label.eks.amazonaws.com/nodegroup-image',
    'k8s.node.label.k8s.io/cloud-provider-aws',
    'k8s.node.label.eks.amazonaws.com/sourceLaunchTemplateId',
    'k8s.node.label.eks.amazonaws.com/sourceLaunchTemplateVersion',
    'k8s.node.label.karpenter.sh/do-not-sync-taints',
    'k8s.node.label.karpenter.sh/initialized',
    'k8s.node.label.karpenter.sh/registered',
    'k8s.node.label.karpenter.k8s.aws/instance-category',
    'k8s.node.label.karpenter.k8s.aws/instance-family',
    'k8s.node.label.karpenter.k8s.aws/instance-generation',
    'k8s.node.label.karpenter.k8s.aws/instance-size',
    'k8s.node.label.karpenter.k8s.aws/instance-memory',
    'k8s.node.label.karpenter.k8s.aws/instance-hypervisor',
    'k8s.node.label.karpenter.k8s.aws/instance-local-nvme',
    'k8s.node.label.karpenter.k8s.aws/instance-ebs-bandwidth',
    'k8s.node.label.karpenter.k8s.aws/instance-network-bandwidth',
    'k8s.node.label.karpenter.k8s.aws/instance-encryption-in-transit-supported',
    'k8s.node.label.karpenter.k8s.aws/instance-capability-flex',
]
RECOMMENDED_POD_KEYS = [
    'k8s.pod.label.pod-template-hash',
    'k8s.pod.label.controller-revision-hash',
    'k8s.pod.label.pod-template-generation',
    'k8s.pod.label.topology.kubernetes.io/region',
    'k8s.pod.label.topology.kubernetes.io/zone',
]
RECOMMENDED_KEYS = RECOMMENDED_NODE_KEYS + RECOMMENDED_POD_KEYS
# Labels that the chart's own processors read: extracted even when an include
# list leaves them out, then removed again.
CHART_LABELS = {'node': ['topology.kubernetes.io/zone'],
                'pod': ['topology.kubernetes.io/region', 'topology.kubernetes.io/zone',
                        'serving.kserve.io/inferenceservice', 'component']}
CHART_NODE_KEYS = ['k8s.node.label.' + k for k in CHART_LABELS['node']]
CHART_POD_KEYS = ['k8s.pod.label.' + k for k in CHART_LABELS['pod']]

def chart_rules(source):
    return [{'tag_name': 'k8s.' + source + '.label.' + k, 'key': k, 'from': source} for k in CHART_LABELS[source]]

def merged(*lists):
    # The removal lists are de-duplicated, keeping the first occurrence.
    out = []
    for k in (k for l in lists for k in l):
        if k not in out:
            out.append(k)
    return out

def attribute_limit(prefixes, keys):
    block = {'max_total_attributes': 150}
    if prefixes:
        block['unconditional_removal_prefixes'] = prefixes
    if keys:
        block['unconditional_removal_keys'] = keys
    return block

def all_labels(source):
    return [{'tag_name': 'k8s.' + source + '.label.\$\$\$1', 'key_regex': '(.*)', 'from': source}]

def assert_labels(source, rules):
    for agent in ('$NODE', '$SCRAPER'):
        got = processor(agent, 'k8sattributes/cw_k8s_ci_v0_' + source)['extract']['labels']
        assert got == rules, (agent, got)

def logs_labels(*statements):
    return {'error_mode': 'ignore',
            'log_statements': [{'context': 'resource', 'statements': list(statements)}]}

def quote(text):
    # regexQuoteMeta, then the OTTL string escape of each backslash.
    return ''.join('\\\\\\\\' + c if c in '\\\\.+*?()|[]{}^\$' else c for c in text)

def delete_prefix(prefix):
    return 'delete_matching_keys(attributes, \"^' + quote(prefix) + '\")'

def delete_key(key):
    return 'delete_key(attributes, \"' + key + '\")'

def no_logs_labels():
    for agent in cfg:
        assert processor(agent, '$LOGS_LABELS') is None, agent
        assert not pipelines_with(agent, '$LOGS_LABELS'), agent

def node(key):
    return 'k8s.node.label.' + key

def pod(key):
    return 'k8s.pod.label.' + key

def without(items, *drop):
    return [i for i in items if i not in drop]

def exception_statements(exceptions):
    # exceptions: (prefix, keep entries) pairs. A keep entry ending in * is a
    # prefix, any other entry an exact key.
    if not exceptions:
        return []
    keep = [quote(e[:-1]) if e.endswith('*') else quote(e) + '\$' for _, entries in exceptions for e in entries]
    return (['set(cache[\"kept_labels\"], attributes)',
             'keep_matching_keys(cache[\"kept_labels\"], \"^(' + '|'.join(keep) + ')\")']
            + [delete_prefix(p) for p, _ in exceptions]
            + ['merge_maps(attributes, cache[\"kept_labels\"], \"upsert\")'])

def metrics_labels(exceptions):
    return {'error_mode': 'ignore',
            'metric_statements': [{'context': 'resource', 'statements': exception_statements(exceptions)}]}

def assert_metrics_labels(exceptions):
    # The metrics label transform runs directly before awsattributelimit in
    # every metrics pipeline of both agents, and only when there are exceptions.
    for agent in ('$NODE', '$SCRAPER'):
        if not exceptions:
            assert processor(agent, '$METRICS_LABELS') is None, agent
            assert not pipelines_with(agent, '$METRICS_LABELS'), agent
            continue
        got = processor(agent, '$METRICS_LABELS')
        assert got == metrics_labels(exceptions), (agent, got)
        for name, value in cfg[agent]['service']['pipelines'].items():
            if name.startswith('metrics/'):
                procs = value['processors']
                limit = procs.index('awsattributelimit/cw_k8s_ci_v0')
                assert procs[limit - 1] == '$METRICS_LABELS' and procs.count('$METRICS_LABELS') == 1, (agent, name, procs)

def assert_removals(prefixes, keys, exceptions=()):
    # Metrics and logs get the same removal list: awsattributelimit and the
    # metrics label transform on both agents, and the logs label transform on
    # the DaemonSet agent.
    for agent in ('$NODE', '$SCRAPER'):
        got = processor(agent, 'awsattributelimit/cw_k8s_ci_v0')
        assert got == attribute_limit(prefixes, keys), (agent, got)
    assert_metrics_labels(exceptions)
    if prefixes or keys or exceptions:
        got = processor('$NODE', '$LOGS_LABELS')
        assert got == logs_labels(*exception_statements(exceptions), *[delete_prefix(p) for p in prefixes], *[delete_key(k) for k in keys]), got
        assert pipelines_with('$NODE', '$LOGS_LABELS') == ['logs/cw_k8s_ci_v0_app', 'logs/cw_k8s_ci_v0_node']
        assert processor('$SCRAPER', '$LOGS_LABELS') is None
    else:
        no_logs_labels()
"

for value in '{}' 'null' '{"nodeLabels":{},"podLabels":{}}' \
    '{"nodeLabels":{"include":null,"exclude":null},"podLabels":{"include":[],"exclude":[]}}' \
    '{"nodeLabels":null,"podLabels":null}' \
    '{"nodeLabels":{"recommendedExclusions":null},"podLabels":{"recommendedExclusions":null}}' \
    '{"nodeLabels":{"recommendedExclusions":true},"podLabels":{"recommendedExclusions":true}}'; do
    check_case "No label filters for $value — all labels, recommended exclusions on metrics and logs" "$value" "$LABEL_BLOCKS
assert_labels('node', all_labels('node'))
assert_labels('pod', all_labels('pod'))
assert_removals(RECOMMENDED_PREFIXES, RECOMMENDED_KEYS)"
done

for source in node pod; do
    kind="${source}Labels"

    check_case "$kind include exact" \
        "{\"$kind\":{\"include\":[\"app\"]}}" "$LABEL_BLOCKS
assert_labels('$source', [{'tag_name': 'k8s.$source.label.app', 'key': 'app', 'from': '$source'}] + chart_rules('$source'))"

    check_case "$kind include prefix" \
        "{\"$kind\":{\"include\":[\"team*\"]}}" "$LABEL_BLOCKS
assert_labels('$source', [{'tag_name': 'k8s.$source.label.\$\$\$1', 'key_regex': '(team.*)', 'from': '$source'}] + chart_rules('$source'))"

    check_case "$kind include prefix with dots and a slash is escaped" \
        "{\"$kind\":{\"include\":[\"app.kubernetes.io/*\"]}}" "$LABEL_BLOCKS
assert_labels('$source', [{'tag_name': 'k8s.$source.label.\$\$\$1', 'key_regex': '(app\\\\.kubernetes\\\\.io/.*)', 'from': '$source'}] + chart_rules('$source'))"

    check_case "$kind include *" \
        "{\"$kind\":{\"include\":[\"*\"]}}" "$LABEL_BLOCKS
assert_labels('$source', all_labels('$source'))"

    check_case "$kind include several entries, in order and listed once" \
        "{\"$kind\":{\"include\":[\"app\",\"team*\",\"app\"]}}" "$LABEL_BLOCKS
exact = {'tag_name': 'k8s.$source.label.app', 'key': 'app', 'from': '$source'}
prefix = {'tag_name': 'k8s.$source.label.\$\$\$1', 'key_regex': '(team.*)', 'from': '$source'}
assert_labels('$source', [exact, prefix] + chart_rules('$source'))"

    check_case "$kind include * among other entries extracts all labels once" \
        "{\"$kind\":{\"include\":[\"app\",\"*\"]}}" "$LABEL_BLOCKS
assert_labels('$source', all_labels('$source'))"

    check_case "$kind include * listed twice extracts all labels once" \
        "{\"$kind\":{\"include\":[\"*\",\"*\"]}}" "$LABEL_BLOCKS
assert_labels('$source', all_labels('$source'))"

    check_case "$kind include keys with uppercase, underscore and hyphen" \
        "{\"$kind\":{\"include\":[\"Team_X\",\"my-label*\"]}}" "$LABEL_BLOCKS
assert_labels('$source', [{'tag_name': 'k8s.$source.label.Team_X', 'key': 'Team_X', 'from': '$source'},
                          {'tag_name': 'k8s.$source.label.\$\$\$1', 'key_regex': '(my-label.*)', 'from': '$source'}] + chart_rules('$source'))"
done

# Label keys are an optional DNS subdomain prefix (at most 253 characters) and
# "/", then a name (at most 63 characters).
LABEL_NAME_63="$(printf 'n%.0s' {1..63})"
LABEL_NAME_64="${LABEL_NAME_63}n"
LABEL_PREFIX_253="$(printf 'a%.0s' {1..61}).$(printf 'b%.0s' {1..63}).$(printf 'c%.0s' {1..63}).$(printf 'd%.0s' {1..63})"

check_case "Label include keys with a DNS prefix, the longest name and the longest prefix" \
    "{\"nodeLabels\":{\"include\":[\"example.com/team\",\"$LABEL_NAME_63\",\"$LABEL_PREFIX_253/a\",\"app-*\"]}}" "$LABEL_BLOCKS
assert_labels('node', [{'tag_name': 'k8s.node.label.example.com/team', 'key': 'example.com/team', 'from': 'node'},
                       {'tag_name': 'k8s.node.label.$LABEL_NAME_63', 'key': '$LABEL_NAME_63', 'from': 'node'},
                       {'tag_name': 'k8s.node.label.$LABEL_PREFIX_253/a', 'key': '$LABEL_PREFIX_253/a', 'from': 'node'},
                       {'tag_name': 'k8s.node.label.\$\$\$1', 'key_regex': '(app-.*)', 'from': 'node'}] + chart_rules('node'))"

check_case "Node and pod label include are independent" \
    '{"nodeLabels":{"include":["a"]},"podLabels":{"include":["b"]}}' "$LABEL_BLOCKS
assert_labels('node', [{'tag_name': 'k8s.node.label.a', 'key': 'a', 'from': 'node'}] + chart_rules('node'))
assert_labels('pod', [{'tag_name': 'k8s.pod.label.b', 'key': 'b', 'from': 'pod'}] + chart_rules('pod'))"

check_case "Label exclude exact and prefix are added to the recommended exclusions, for metrics and logs" \
    '{"nodeLabels":{"exclude":["team-x","example.com/*"]},"podLabels":{"exclude":["app","tier*"]}}' "$LABEL_BLOCKS
assert_removals(
    RECOMMENDED_PREFIXES + ['k8s.node.label.example.com/', 'k8s.pod.label.tier'],
    RECOMMENDED_NODE_KEYS + ['k8s.node.label.team-x'] + RECOMMENDED_POD_KEYS + ['k8s.pod.label.app'])"

check_case "Label exclude exact and prefix with recommended exclusions off, for metrics and logs" \
    '{"nodeLabels":{"exclude":["team-x","example.com/*"],"recommendedExclusions":false},"podLabels":{"exclude":["app","tier*"],"recommendedExclusions":false}}' "$LABEL_BLOCKS
assert_removals(['k8s.node.label.example.com/', 'k8s.pod.label.tier'], ['k8s.node.label.team-x', 'k8s.pod.label.app'])"

# exclude: ["*"] removes every label of a kind. The chart's labels are still
# extracted for its own processors, and removed after use.
check_case "Label exclude * removes every label of that kind, from metrics and logs" \
    '{"nodeLabels":{"exclude":["*"]},"podLabels":{"exclude":["*"]}}' "$LABEL_BLOCKS
assert_labels('node', all_labels('node'))
assert_labels('pod', all_labels('pod'))
assert_removals(RECOMMENDED_PREFIXES + ['k8s.node.label.', 'k8s.pod.label.'], RECOMMENDED_KEYS)"

check_case "Label exclude * with recommended exclusions off — only the prefixes of the kinds" \
    '{"nodeLabels":{"exclude":["*"],"recommendedExclusions":false},"podLabels":{"exclude":["*"],"recommendedExclusions":false}}' "$LABEL_BLOCKS
assert_removals(['k8s.node.label.', 'k8s.pod.label.'], [])"

check_case "Label exclude * for pods only — node labels keep the recommended exclusions" \
    '{"podLabels":{"exclude":["*"]}}' "$LABEL_BLOCKS
assert_removals(RECOMMENDED_PREFIXES + ['k8s.pod.label.'], RECOMMENDED_KEYS)"

check_case "Label exclude * with an include list — the include and the chart's labels are extracted, then all removed" \
    '{"podLabels":{"include":["app"],"exclude":["*"]}}' "$LABEL_BLOCKS
assert_labels('pod', [{'tag_name': 'k8s.pod.label.app', 'key': 'app', 'from': 'pod'}] + chart_rules('pod'))
assert_removals(RECOMMENDED_PREFIXES + ['k8s.pod.label.'], merged(RECOMMENDED_KEYS, CHART_POD_KEYS))"

check_case "Label exclude duplicates and recommended entries are listed once" \
    '{"nodeLabels":{"exclude":["release","x","x"]},"podLabels":{"exclude":["pod-template-hash","y","y"]}}' "$LABEL_BLOCKS
assert_removals(RECOMMENDED_PREFIXES,
    RECOMMENDED_NODE_KEYS + ['k8s.node.label.x'] + RECOMMENDED_POD_KEYS + ['k8s.pod.label.y'])"

check_case "Node recommended exclusions off" \
    '{"nodeLabels":{"recommendedExclusions":false}}' "$LABEL_BLOCKS
assert_removals([], RECOMMENDED_POD_KEYS)"

check_case "Pod recommended exclusions off" \
    '{"podLabels":{"recommendedExclusions":false}}' "$LABEL_BLOCKS
assert_removals(RECOMMENDED_PREFIXES, RECOMMENDED_NODE_KEYS)"

check_case "Recommended exclusions off — no removal lists and no logs label processor" \
    '{"nodeLabels":{"recommendedExclusions":false},"podLabels":{"recommendedExclusions":false}}' "$LABEL_BLOCKS
assert_removals([], [])"

# Label filters are not placed per pipeline: include changes the shared
# k8sattributes processors and exclude the shared awsattributelimit. So every
# metrics pipeline that adds labels must also remove them, including the
# optional solution and controller pipelines.
check_case "Label exclude is placed where awsattributelimit is today, in every metrics pipeline that adds labels" \
    '{"nodeLabels":{"exclude":["x"]}}' "$LABEL_BLOCKS
for agent in ('$NODE', '$SCRAPER'):
    pipelines = cfg[agent]['service']['pipelines']
    metrics = sorted(p for p in pipelines if p.startswith('metrics/'))
    assert pipelines_with(agent, 'awsattributelimit/cw_k8s_ci_v0') == metrics, agent
    for name in metrics:
        procs = pipelines[name]['processors']
        enrich = [i for i, p in enumerate(procs) if p.startswith('k8sattributes/')]
        if enrich:
            assert max(enrich) < procs.index('awsattributelimit/cw_k8s_ci_v0'), (agent, name)
assert {'metrics/cw_k8s_ci_v0_vllm', 'metrics/cw_k8s_ci_v0_knative_dataplane'} <= set(cfg['$NODE']['service']['pipelines'])
assert {'metrics/cw_k8s_ci_v0_kserve_controlplane', 'metrics/cw_k8s_ci_v0_knative_controlplane'} <= set(cfg['$SCRAPER']['service']['pipelines'])
assert_removals(RECOMMENDED_PREFIXES, RECOMMENDED_NODE_KEYS + ['k8s.node.label.x'] + RECOMMENDED_POD_KEYS)" --set dcgmExporter.enabled=true --set neuronMonitor.enabled=true \
    --set otelContainerInsights.solutions.vllm.enabled=true \
    --set otelContainerInsights.solutions.kserve.controlPlane.enabled=true \
    --set otelContainerInsights.solutions.knative.dataPlane.enabled=true \
    --set otelContainerInsights.solutions.knative.controlPlane.enabled=true

check_case "Logs label processor with default values — in the application and host logs pipelines, before batch" \
    '{}' "$LABEL_BLOCKS
assert pipelines_with('$NODE', '$LOGS_LABELS') == ['logs/cw_k8s_ci_v0_app', 'logs/cw_k8s_ci_v0_node']
app = pipeline('$NODE', 'logs/cw_k8s_ci_v0_app')
assert app[-3:] == ['transform/cw_k8s_ci_v0_logs_set_workload', '$LOGS_LABELS', 'batch/cw_k8s_ci_v0_logs_dest'], app
host = pipeline('$NODE', 'logs/cw_k8s_ci_v0_node')
assert host[-3:] == ['transform/cw_k8s_ci_v0_logs_clear_schema_url', '$LOGS_LABELS', 'batch/cw_k8s_ci_v0_logs_dest'], host
assert processor('$SCRAPER', '$LOGS_LABELS') is None"

check_case "Label exclude with OTEL logs disabled — metrics only, no logs label processor" \
    '{"podLabels":{"exclude":["x"]}}' "$LABEL_BLOCKS
assert attribute_limit(RECOMMENDED_PREFIXES, RECOMMENDED_KEYS + ['k8s.pod.label.x']) == processor('$NODE', 'awsattributelimit/cw_k8s_ci_v0')
no_logs_labels()" --set otelContainerInsights.logs.enabled=false

# Include and exclude together: include picks what k8sattributes extracts,
# exclude removes from it (awsattributelimit for metrics, transform for logs).
check_case "Labels include * with exclude exact and prefix" \
    '{"nodeLabels":{"include":["*"],"exclude":["team-x","example.com/*"]},"podLabels":{"include":["*"],"exclude":["app-secret"]}}' "$LABEL_BLOCKS
assert_labels('node', all_labels('node'))
assert_labels('pod', all_labels('pod'))
assert_removals(
    RECOMMENDED_PREFIXES + ['k8s.node.label.example.com/'],
    RECOMMENDED_NODE_KEYS + ['k8s.node.label.team-x'] + RECOMMENDED_POD_KEYS + ['k8s.pod.label.app-secret'])"

check_case "Labels include prefix with exclude exact and prefix inside it" \
    '{"podLabels":{"include":["app*"],"exclude":["app-secret","app.k8s/*"]}}' "$LABEL_BLOCKS
assert_labels('node', all_labels('node'))
assert_labels('pod', [{'tag_name': 'k8s.pod.label.\$\$\$1', 'key_regex': '(app.*)', 'from': 'pod'}] + chart_rules('pod'))
assert_removals(
    RECOMMENDED_PREFIXES + ['k8s.pod.label.app.k8s/'],
    merged(RECOMMENDED_KEYS, ['k8s.pod.label.app-secret'], CHART_POD_KEYS))"

check_case "Labels include exact with exclude and recommended exclusions off" \
    '{"nodeLabels":{"include":["team","zone"],"exclude":["zone"],"recommendedExclusions":false},"podLabels":{"recommendedExclusions":false}}' "$LABEL_BLOCKS
assert_labels('node', [{'tag_name': 'k8s.node.label.team', 'key': 'team', 'from': 'node'},
                       {'tag_name': 'k8s.node.label.zone', 'key': 'zone', 'from': 'node'}] + chart_rules('node'))
assert_removals([], ['k8s.node.label.zone'] + CHART_NODE_KEYS)"

# Named include entries and the built-in list. For each label, exclude wins
# over a named include entry (an exact key or a prefix, not "*"), and a named
# entry wins over the recommended exclusions. "*" and an empty include list
# name nothing, so the recommended exclusions still apply.
for value in '{"nodeLabels":{"include":["*"]},"podLabels":{"include":["*"]}}' \
    '{"nodeLabels":{"include":["*","*"]},"podLabels":{"include":[]}}'; do
    check_case "Named — include $value names nothing, so the full built-in list stays" "$value" "$LABEL_BLOCKS
assert_labels('node', all_labels('node'))
assert_labels('pod', all_labels('pod'))
assert_removals(RECOMMENDED_PREFIXES, RECOMMENDED_KEYS)"
done

check_case "Named — exact keys on the built-in list are kept on metrics and logs, with and without *" \
    '{"nodeLabels":{"include":["*","release","kubernetes.io/hostname"]},"podLabels":{"include":["pod-template-hash"]}}' "$LABEL_BLOCKS
assert_labels('node', all_labels('node'))
assert_labels('pod', [{'tag_name': 'k8s.pod.label.pod-template-hash', 'key': 'pod-template-hash', 'from': 'pod'}] + chart_rules('pod'))
assert_removals(RECOMMENDED_PREFIXES,
    merged(without(RECOMMENDED_KEYS, node('release'), node('kubernetes.io/hostname'), pod('pod-template-hash')), CHART_POD_KEYS))"

check_case "Named — a prefix keeps the built-in keys that start with it" \
    '{"nodeLabels":{"include":["*","karpenter.sh/*"]}}' "$LABEL_BLOCKS
assert_removals(RECOMMENDED_PREFIXES,
    without(RECOMMENDED_KEYS, node('karpenter.sh/do-not-sync-taints'), node('karpenter.sh/initialized'), node('karpenter.sh/registered')))"

check_case "Named — a prefix equal to or shorter than a built-in prefix drops that prefix" \
    '{"nodeLabels":{"include":["*","feature.node.kubernetes.io/*","karpenter.k8s.aws/*"]}}' "$LABEL_BLOCKS
assert_removals(
    without(RECOMMENDED_PREFIXES, node('feature.node.kubernetes.io/'), node('karpenter.k8s.aws/instance-cpu'),
            node('karpenter.k8s.aws/instance-gpu-'), node('karpenter.k8s.aws/instance-accelerator-')),
    [k for k in RECOMMENDED_KEYS if not k.startswith(node('karpenter.k8s.aws/'))])"

GPU_NAME_STATEMENTS=$(cat <<'PY'
expected = [
    'set(cache["kept_labels"], attributes)',
    r'keep_matching_keys(cache["kept_labels"], "^(k8s\\.node\\.label\\.karpenter\\.k8s\\.aws/instance-gpu-name$)")',
    r'delete_matching_keys(attributes, "^k8s\\.node\\.label\\.karpenter\\.k8s\\.aws/instance-gpu-")',
    'merge_maps(attributes, cache["kept_labels"], "upsert")',
]
for agent in cfg:
    got = processor(agent, 'transform/cw_k8s_ci_v0_metrics_labels')['metric_statements'][0]['statements']
    assert got == expected, (agent, got)
logs = processor('cloudwatch-agent', 'transform/cw_k8s_ci_v0_logs_labels')['log_statements'][0]['statements']
assert logs[:4] == expected, logs[:4]
PY
)

check_case "Named — * plus a key inside a built-in prefix renders the keep and merge statements on metrics and logs" \
    '{"nodeLabels":{"include":["*","karpenter.k8s.aws/instance-gpu-name"]}}' "$LABEL_BLOCKS
assert_labels('node', all_labels('node'))
GPU = node('karpenter.k8s.aws/instance-gpu-')
assert_removals(without(RECOMMENDED_PREFIXES, GPU), RECOMMENDED_KEYS, [(GPU, [node('karpenter.k8s.aws/instance-gpu-name')])])
$GPU_NAME_STATEMENTS"

check_case "Named — a key inside a built-in prefix without * also renders the statements" \
    '{"nodeLabels":{"include":["karpenter.k8s.aws/instance-gpu-name"]}}' "$LABEL_BLOCKS
assert_labels('node', [{'tag_name': 'k8s.node.label.karpenter.k8s.aws/instance-gpu-name', 'key': 'karpenter.k8s.aws/instance-gpu-name', 'from': 'node'}] + chart_rules('node'))
GPU = node('karpenter.k8s.aws/instance-gpu-')
assert_removals(without(RECOMMENDED_PREFIXES, GPU), RECOMMENDED_KEYS, [(GPU, [node('karpenter.k8s.aws/instance-gpu-name')])])"

check_case "Named — a longer prefix and exact keys inside three built-in prefixes, in one copy and merge" \
    '{"nodeLabels":{"include":["*","karpenter.k8s.aws/instance-accelerator-name","karpenter.k8s.aws/instance-gpu-n*","karpenter.k8s.aws/instance-cpu"]}}' "$LABEL_BLOCKS
CPU = node('karpenter.k8s.aws/instance-cpu')
GPU = node('karpenter.k8s.aws/instance-gpu-')
ACC = node('karpenter.k8s.aws/instance-accelerator-')
assert_removals(without(RECOMMENDED_PREFIXES, CPU, GPU, ACC), RECOMMENDED_KEYS,
    [(CPU, [CPU]), (GPU, [node('karpenter.k8s.aws/instance-gpu-n*')]), (ACC, [node('karpenter.k8s.aws/instance-accelerator-name')])])
keep = processor('$NODE', '$METRICS_LABELS')['metric_statements'][0]['statements'][1]
for part in ('instance-cpu\$|', 'instance-gpu-n|', 'instance-accelerator-name\$)'):
    assert part in keep, (part, keep)"

check_case "Named — exclude still wins: an exact key, and a key inside a built-in prefix" \
    '{"nodeLabels":{"include":["*","release","karpenter.k8s.aws/instance-gpu-name"],"exclude":["release","karpenter.k8s.aws/instance-gpu-name"]}}' "$LABEL_BLOCKS
GPU = node('karpenter.k8s.aws/instance-gpu-')
assert_removals(without(RECOMMENDED_PREFIXES, GPU),
    without(RECOMMENDED_NODE_KEYS, node('release')) + [node('release'), node('karpenter.k8s.aws/instance-gpu-name')] + RECOMMENDED_POD_KEYS,
    [(GPU, [node('karpenter.k8s.aws/instance-gpu-name')])])
logs = processor('$NODE', '$LOGS_LABELS')['log_statements'][0]['statements']
assert logs.index(delete_key(node('karpenter.k8s.aws/instance-gpu-name'))) > logs.index('merge_maps(attributes, cache[\"kept_labels\"], \"upsert\")'), logs"

check_case "Named — a prefix include with an exclude inside it removes the excluded key" \
    '{"podLabels":{"include":["app*","pod-template-hash"],"exclude":["app-secret"]}}' "$LABEL_BLOCKS
assert_removals(RECOMMENDED_PREFIXES,
    merged(without(RECOMMENDED_KEYS, pod('pod-template-hash')), [pod('app-secret')], CHART_POD_KEYS))"

check_case "Named — entries of one kind do not keep labels of the other kind" \
    '{"podLabels":{"include":["*","release","karpenter.k8s.aws/instance-gpu-name"]}}' "$LABEL_BLOCKS
assert_removals(RECOMMENDED_PREFIXES, RECOMMENDED_KEYS)"

check_case "Named — with recommended exclusions off, no metrics label transform" \
    '{"nodeLabels":{"include":["*","karpenter.k8s.aws/instance-gpu-name"],"recommendedExclusions":false}}' "$LABEL_BLOCKS
assert_removals([], RECOMMENDED_POD_KEYS)"

check_case "Named — a key inside a built-in prefix with OTEL logs disabled — the metrics label transform only" \
    '{"nodeLabels":{"include":["*","karpenter.k8s.aws/instance-gpu-name"]}}' "$LABEL_BLOCKS
GPU = node('karpenter.k8s.aws/instance-gpu-')
assert_metrics_labels([(GPU, [node('karpenter.k8s.aws/instance-gpu-name')])])
assert processor('$NODE', 'awsattributelimit/cw_k8s_ci_v0') == attribute_limit(without(RECOMMENDED_PREFIXES, GPU), RECOMMENDED_KEYS)
no_logs_labels()" --set otelContainerInsights.logs.enabled=false

check_renders "Hash — a named include entry inside a built-in prefix gives a new hash on both agents" "
default = render()
named = render('--set-json', 'otelFilters={\"nodeLabels\":{\"include\":[\"*\",\"karpenter.k8s.aws/instance-gpu-name\"]}}')
for name in ('$NODE', '$SCRAPER'):
    assert default[name]['hash'] != named[name]['hash'], name"

# The chart reads some pod labels itself (vLLM service.name, Knative service
# type). A pod include list that leaves them out must not break those.
check_case "Pod labels include without the chart's labels — still extracted, then removed from metrics and logs" \
    '{"podLabels":{"include":["app"]}}' "$LABEL_BLOCKS
assert_labels('node', all_labels('node'))
assert_labels('pod', [{'tag_name': 'k8s.pod.label.app', 'key': 'app', 'from': 'pod'}] + chart_rules('pod'))
assert_removals(RECOMMENDED_PREFIXES, merged(RECOMMENDED_KEYS, CHART_POD_KEYS))"

check_case "Pod labels include without the chart's labels, recommended exclusions off — only the chart's labels are removed" \
    '{"podLabels":{"include":["app"],"recommendedExclusions":false},"nodeLabels":{"recommendedExclusions":false}}' "$LABEL_BLOCKS
assert_removals([], CHART_POD_KEYS)"

check_case "Pod labels include covering the chart's labels, by prefix and exactly — extracted once, and the named topology labels are kept" \
    '{"podLabels":{"include":["serving.kserve.io/*","component","topology.kubernetes.io/*"]}}' "$LABEL_BLOCKS
assert_labels('pod', [{'tag_name': 'k8s.pod.label.\$\$\$1', 'key_regex': '(serving\\\\.kserve\\\\.io/.*)', 'from': 'pod'},
                      {'tag_name': 'k8s.pod.label.component', 'key': 'component', 'from': 'pod'},
                      {'tag_name': 'k8s.pod.label.\$\$\$1', 'key_regex': '(topology\\\\.kubernetes\\\\.io/.*)', 'from': 'pod'}])
assert_removals(RECOMMENDED_PREFIXES, without(RECOMMENDED_KEYS, pod('topology.kubernetes.io/region'), pod('topology.kubernetes.io/zone')))"

check_case "Pod labels exclude of a chart label — still extracted, read, then removed" \
    '{"podLabels":{"include":["app"],"exclude":["component"]}}' "$LABEL_BLOCKS
assert_labels('pod', [{'tag_name': 'k8s.pod.label.app', 'key': 'app', 'from': 'pod'}] + chart_rules('pod'))
assert_removals(RECOMMENDED_PREFIXES, merged(RECOMMENDED_KEYS, ['k8s.pod.label.component'], CHART_POD_KEYS))"

check_case "The chart's labels are exactly the labels its processors read, after pod enrichment and before awsattributelimit" \
    '{"podLabels":{"include":["app"]}}' "$LABEL_BLOCKS
import re
read = set()
for agent in cfg:
    for name in cfg[agent]['service']['pipelines']:
        procs = pipeline(agent, name)
        for p in procs:
            if p.startswith(('k8sattributes/', 'awsattributelimit/')) or p == '$LOGS_LABELS':
                continue
            found = set(re.findall(r'attributes\\[\"(k8s\\.(?:node|pod)\\.label\\.[^\"]+)\"\\]', yaml.safe_dump(processor(agent, p), width=10000)))
            if found:
                enrich = [i for i, q in enumerate(procs) if q.startswith('k8sattributes/')]
                assert enrich and max(enrich) < procs.index(p) < procs.index('awsattributelimit/cw_k8s_ci_v0'), (agent, name, p)
            read |= found
assert read == set(CHART_NODE_KEYS + CHART_POD_KEYS), sorted(read)" --set dcgmExporter.enabled=true --set neuronMonitor.enabled=true \
    --set otelContainerInsights.solutions.vllm.enabled=true \
    --set otelContainerInsights.solutions.kserve.controlPlane.enabled=true \
    --set otelContainerInsights.solutions.knative.dataPlane.enabled=true \
    --set otelContainerInsights.solutions.knative.controlPlane.enabled=true

check_case "Labels include with OTEL logs disabled" \
    '{"nodeLabels":{"include":["team"]},"podLabels":{"include":["app"]}}' "$LABEL_BLOCKS
assert_labels('node', [{'tag_name': 'k8s.node.label.team', 'key': 'team', 'from': 'node'}] + chart_rules('node'))
assert_labels('pod', [{'tag_name': 'k8s.pod.label.app', 'key': 'app', 'from': 'pod'}] + chart_rules('pod'))
no_logs_labels()" --set otelContainerInsights.logs.enabled=false

check_renders "Hash — a changed label exclude list gives a new hash on both agents" "
default = render()
one = render('--set-json', 'otelFilters={\"podLabels\":{\"exclude\":[\"app\"]}}')
two = render('--set-json', 'otelFilters={\"podLabels\":{\"exclude\":[\"app\",\"team\"]}}')
for name in ('$NODE', '$SCRAPER'):
    hashes = {default[name]['hash'], one[name]['hash'], two[name]['hash']}
    assert len(hashes) == 3, (name, hashes)"

check_fails "Invalid otelFilters — unknown key, with the allowed keys" \
    '{"labels":{}}' 'otelFilters has an unknown key "labels" (allowed: namespaces, nodeLabels, podLabels)'
check_fails "otelContainerInsights.filters with label lists — fails with a pointer to otelFilters" \
    '{}' "$OLD_KEY" --set-json 'otelContainerInsights.filters={"metrics":{"podLabels":{"exclude":["app"]}}}'

for kind in nodeLabels podLabels; do
    check_fails "Invalid — $kind.recommendedExclusions is not a boolean" \
        "{\"$kind\":{\"recommendedExclusions\":\"yes\"}}" \
        "otelFilters.$kind.recommendedExclusions must be a boolean"
    check_fails "Invalid — $kind.recommendedExclusions is a number" \
        "{\"$kind\":{\"recommendedExclusions\":1}}" \
        "otelFilters.$kind.recommendedExclusions must be a boolean"
    message="otelFilters.$kind entries must be"
    for entry in '"a b"' '"a*b"' '"-a"' '"a\"b"' '""' 'true' 'null' '"app-"' '"app."' '"a/b/c"' '"x//"' '"/x"' '"Example.com/x"'; do
        check_fails "Invalid $kind.exclude entry $entry" \
            "{\"$kind\":{\"exclude\":[$entry]}}" "$message"
    done
    check_fails "Invalid $kind.exclude entry — a 64-character name" \
        "{\"$kind\":{\"exclude\":[\"example.com/$LABEL_NAME_64\"]}}" \
        "otelFilters.$kind entries must have a name of at most 63 characters"
    check_fails "Invalid $kind.exclude entry — a 254-character prefix" \
        "{\"$kind\":{\"exclude\":[\"${LABEL_PREFIX_253}x/a*\"]}}" \
        "otelFilters.$kind entries must have a name of at most 63 characters and a prefix of at most 253"
    check_fails "Invalid $kind.include entry \"a b\"" \
        "{\"$kind\":{\"include\":[\"a b\"]}}" "$message"
    check_fails "Invalid $kind.include entry null" \
        "{\"$kind\":{\"include\":[\"app\",null]}}" "$message"
    check_fails "Invalid $kind — not a map" \
        "{\"$kind\":[\"app\"]}" "otelFilters.$kind must be a map"
    check_fails "Invalid $kind — unknown key" \
        "{\"$kind\":{\"excludes\":[\"app\"]}}" \
        "otelFilters.$kind has an unknown key \"excludes\""
    check_fails "Invalid $kind — a signal key" \
        "{\"$kind\":{\"metrics\":{\"exclude\":[\"app\"]}}}" \
        "otelFilters.$kind has an unknown key \"metrics\""
    for list in include exclude; do
        check_fails "Invalid $kind.$list — a string, not a list" \
            "{\"$kind\":{\"$list\":\"app\"}}" \
            "otelFilters.$kind.$list must be a list"
    done
done

# ──────────────────────────────────────────────────────────────────────────
# Summary.
# ──────────────────────────────────────────────────────────────────────────
total=$((pass_count + fail_count))
echo ""
echo "=== Summary ==="
if [[ $fail_count -eq 0 ]]; then
    echo -e "${G}All $total cases passed.${N}"
    exit 0
else
    echo -e "${R}$fail_count of $total cases failed.${N}"
    exit 1
fi
