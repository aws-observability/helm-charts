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
