#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Validates otelContainerInsights.filters by rendering `helm template` and
# checking the exact processors and pipeline placement in the generated OTEL
# configs. This test renders locally and never connects to a cluster.
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
#   $1  otelContainerInsights.filters as JSON
#   $2  extra helm arguments (optional)
# Returns helm's exit code; output (or the error) is in $RENDERED.
# ──────────────────────────────────────────────────────────────────────────
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT

render() {
    local filters="$1" extra_args="${2:-}"
    helm template "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        --set otelContainerInsights.enabled=true \
        --set-json "otelContainerInsights.filters=$filters" $extra_args >"$RENDERED" 2>&1
}

# ──────────────────────────────────────────────────────────────────────────
# check_case — render and run python assertions on the parsed OTEL configs.
#
# Arguments:
#   $1  description shown in output
#   $2  otelContainerInsights.filters as JSON
#   $3  python assertions (see below)
#   $4  extra helm arguments (optional)
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
    local desc="$1" filters="$2" assertions="$3" extra_args="${4:-}"

    printf "\n${Y}[Case]${N} %s\n" "$desc"

    if ! render "$filters" "$extra_args"; then
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
#   $1  description shown in output
#   $2  otelContainerInsights.filters as JSON
#   $3  fragment that MUST be in the error message
# ──────────────────────────────────────────────────────────────────────────
check_fails() {
    local desc="$1" filters="$2" message="$3"

    printf "\n${Y}[Case]${N} %s\n" "$desc"

    if render "$filters"; then
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

NODE="cloudwatch-agent"
SCRAPER="cloudwatch-agent-cluster-scraper"
METRICS_NS="filter/cw_k8s_ci_v0_metrics_namespaces"
LOGS_NS="filter/cw_k8s_ci_v0_logs_namespaces"

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
"

for value in '{}' '{"metrics":{},"logs":{}}' \
    '{"metrics":{"namespaces":{}},"logs":{"namespaces":{}}}' \
    '{"metrics":{"namespaces":{"include":[],"exclude":[]}},"logs":{"namespaces":{"include":[],"exclude":[]}}}' \
    '{"metrics":{"namespaces":{"include":null,"exclude":null}},"logs":{"namespaces":{"include":null,"exclude":null}}}' \
    '{"metrics":{"namespaces":null},"logs":{"namespaces":null}}' \
    '{"metrics":null,"logs":null}'; do
    check_case "No namespace filter processors for $value" "$value" "$NS_BLOCKS
no_ns_filters()"
done

for signal in metrics logs; do
    if [[ "$signal" == "metrics" ]]; then
        name="$METRICS_NS" block="metrics_ns"
    else
        name="$LOGS_NS" block="logs_ns"
    fi

    check_case "$signal namespaces — duplicates render as given" \
        "{\"$signal\":{\"namespaces\":{\"exclude\":[\"a\",\"a\"]}}}" "$NS_BLOCKS
assert ns_processor('$name') == $block(
    NS + ' != nil and (' + NS + ' == \"a\" or ' + NS + ' == \"a\")')"


    check_case "$signal namespaces — * among other include entries adds no include condition" \
        "{\"$signal\":{\"namespaces\":{\"include\":[\"a\",\"*\"],\"exclude\":[\"b\"]}}}" "$NS_BLOCKS
assert ns_processor('$name') == $block(NS + ' != nil and (' + NS + ' == \"b\")')"

    # Every pairing of include and exclude kinds, each on its own and together.
    # ns_match is the expected translation: "*" is true, "x*" an anchored
    # IsMatch, anything else ==. An include containing "*" adds no condition.
    for include in none exact prefix star mixed; do
        for exclude in none exact prefix star mixed; do
            # none/none is the default (above); * in both lists is rejected (below).
            [[ "$include" == none && "$exclude" == none ]] && continue
            [[ "$include" == star && "$exclude" == star ]] && continue
            check_case "$signal namespaces — include $include, exclude $exclude" \
                "{\"$signal\":{\"namespaces\":{\"include\":${NS_KINDS_INCLUDE[$include]},\"exclude\":${NS_KINDS_EXCLUDE[$exclude]}}}}" "$NS_BLOCKS
include, exclude = ${NS_KINDS_INCLUDE[$include]}, ${NS_KINDS_EXCLUDE[$exclude]}
conditions = []
if include and '*' not in include:
    conditions.append(NS + ' != nil and not ' + ns_match(include))
if exclude:
    conditions.append(NS + ' != nil and ' + ns_match(exclude))
if conditions:
    assert ns_processor('$name') == $block(*conditions)
else:
    no_ns_filters()"
        done
    done

    check_case "$signal namespaces — 63-character names and prefixes" \
        "{\"$signal\":{\"namespaces\":{\"include\":[\"$NS63\",\"$NS63*\"]}}}" "$NS_BLOCKS
assert ns_processor('$name') == $block(
    NS + ' != nil and not (' + NS + ' == \"$NS63\" or IsMatch(' + NS + ', \"^$NS63\"))')"


done

# Every pipeline that emits resource k8s.namespace.name for a workload gets
# the namespace filter. The set is derived from the rendered config, so a new
# pipeline that carries a namespace fails here until it is filtered (or added
# to the controller exceptions). The kubeletstats receiver sets the attribute
# itself; elsewhere a receiver or processor names it before k8sattributes.
check_case "Namespaces — every pipeline that emits k8s.namespace.name is filtered before k8sattributes, except Karpenter and KEDA" \
    '{"metrics":{"namespaces":{"exclude":["kube-system"]}},"logs":{"namespaces":{"exclude":["kube-system"]}}}' "$NS_BLOCKS
import json
CONTROLLER_PIPELINES = {'metrics/cw_k8s_ci_v0_karpenter', 'metrics/cw_k8s_ci_v0_keda'}
for agent in cfg:
    c = cfg[agent]
    for name, p in c['service']['pipelines'].items():
        procs = p['processors']
        first_k8s = next((i for i, x in enumerate(procs) if x.startswith('k8sattributes/')), len(procs))
        sources = [c['receivers'][r] for r in p['receivers']] + [
            c['processors'][x] for x in procs[:first_k8s] if not x.startswith('filter/')]
        emits = (any(r.startswith('kubeletstats/') for r in p['receivers'])
                 or any('k8s.namespace.name' in json.dumps(s) for s in sources))
        want = '$METRICS_NS' if name.startswith('metrics/') else '$LOGS_NS'
        filtered = want in procs
        expected = emits and name not in CONTROLLER_PIPELINES
        assert filtered == expected, (agent, name, 'emits' if emits else 'no namespace', 'filtered' if filtered else 'not filtered')
        if filtered:
            # Before k8sattributes, and only once.
            assert procs.count(want) == 1 and procs.index(want) < first_k8s, (agent, name, procs)
" "--set dcgmExporter.enabled=true --set neuronMonitor.enabled=true"

check_case "Metrics and logs namespaces together are independent" \
    '{"metrics":{"namespaces":{"include":["a"]}},"logs":{"namespaces":{"include":["b"]}}}' "$NS_BLOCKS
assert processor('$SCRAPER', '$METRICS_NS') == metrics_ns(NS + ' != nil and not (' + NS + ' == \"a\")')
assert processor('$NODE', '$LOGS_NS') == logs_ns(NS + ' != nil and not (' + NS + ' == \"b\")')"

check_case "Logs namespaces with OTEL logs disabled — no namespace filter" \
    '{"logs":{"namespaces":{"exclude":["kube-system"]}}}' "$NS_BLOCKS
no_ns_filters()" "--set otelContainerInsights.logs.enabled=false"

for signal in metrics logs; do
    # Both lists go through the same checks, so each error is tested on one.
    message="otelContainerInsights.filters.$signal.namespaces entries must be"
    long="otelContainerInsights.filters.$signal.namespaces entries must be at most 63 characters"
    for case in "include|uppercase|[\"Prod\"]|$message" \
                "exclude|* not at the end|[\"a*b\"]|$message" \
                "include|leading -|[\"-a\"]|$message" \
                "exclude|dot|[\"a.b*\"]|$message" \
                "include|quote|[\"a\\\"b\"]|$message" \
                "exclude|empty string|[\"\"]|$message" \
                "include|not a string|[123]|$message" \
                "exclude|64-character name|[\"$NS64\"]|$long" \
                "include|64-character prefix|[\"$NS64*\"]|$long" \
                "exclude|a string, not a list|\"prod\"|otelContainerInsights.filters.$signal.namespaces.exclude must be a list"; do
        IFS='|' read -r list what value expect <<< "$case"
        check_fails "Invalid $signal.namespaces.$list — $what" \
            "{\"$signal\":{\"namespaces\":{\"$list\":$value}}}" "$expect"
    done
    check_fails "Invalid $signal.namespaces — unknown key" \
        "{\"$signal\":{\"namespaces\":{\"excludes\":[\"kube-system\"]}}}" "otelContainerInsights.filters.$signal.namespaces has an unknown key \"excludes\""
    check_fails "Invalid $signal.namespaces — not a map" \
        "{\"$signal\":{\"namespaces\":[\"kube-system\"]}}" "otelContainerInsights.filters.$signal.namespaces must be a map"
    check_fails "Invalid $signal — unknown key" \
        "{\"$signal\":{\"namespace\":{\"exclude\":[\"kube-system\"]}}}" "otelContainerInsights.filters.$signal has an unknown key \"namespace\""
    check_fails "Invalid $signal — not a map" \
        "{\"$signal\":[]}" "otelContainerInsights.filters.$signal must be a map"
    check_fails "Invalid $signal.namespaces — exact entry in include and exclude" \
        "{\"$signal\":{\"namespaces\":{\"include\":[\"a\",\"b\"],\"exclude\":[\"b\"]}}}" "otelContainerInsights.filters.$signal.namespaces: \"b\" is in both include and exclude"
    check_fails "Invalid $signal.namespaces — * in include and exclude" \
        "{\"$signal\":{\"namespaces\":{\"include\":[\"*\"],\"exclude\":[\"*\"]}}}" "otelContainerInsights.filters.$signal.namespaces: \"*\" is in both include and exclude"

done

check_fails "Invalid filters — unknown key" '{"traces":{}}' 'otelContainerInsights.filters has an unknown key "traces"'
check_fails "Invalid filters — not a map" '[]' "otelContainerInsights.filters must be a map"

# ── Labels ──────────────────────────────────────────────────────────────

LOGS_LABELS="transform/cw_k8s_ci_v0_logs_labels"

# Expected processor blocks. The recommended exclusions are the
# awsattributelimit removal lists before label filters were added.
LABEL_BLOCKS="
RECOMMENDED_PREFIXES = [
    'k8s.node.label.feature.node.kubernetes.io/',
    'k8s.node.label.beta.kubernetes.io/',
    'k8s.node.label.failure-domain.beta.kubernetes.io/',
    'k8s.node.label.alpha.eksctl.io/',
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
]
RECOMMENDED_POD_KEYS = [
    'k8s.pod.label.pod-template-hash',
    'k8s.pod.label.controller-revision-hash',
]
RECOMMENDED_KEYS = RECOMMENDED_NODE_KEYS + RECOMMENDED_POD_KEYS

def attribute_limit(prefixes, keys):
    block = {'max_total_attributes': 150}
    if prefixes:
        block['unconditional_removal_prefixes'] = prefixes
    if keys:
        block['unconditional_removal_keys'] = keys
    return block

def assert_attribute_limit(prefixes, keys):
    for agent in ('$NODE', '$SCRAPER'):
        got = processor(agent, 'awsattributelimit/cw_k8s_ci_v0')
        assert got == attribute_limit(prefixes, keys), (agent, got)

def all_labels(source):
    return [{'tag_name': 'k8s.' + source + '.label.\$\$\$1', 'key_regex': '(.*)', 'from': source}]

def assert_labels(source, rules):
    for agent in ('$NODE', '$SCRAPER'):
        got = processor(agent, 'k8sattributes/cw_k8s_ci_v0_' + source)['extract']['labels']
        assert got == rules, (agent, got)

def logs_labels(*statements):
    return {'error_mode': 'ignore',
            'log_statements': [{'context': 'resource', 'statements': list(statements)}]}

def delete_prefix(prefix):
    quoted = ''.join('\\\\\\\\' + c if c in '\\\\.+*?()|[]{}^\$' else c for c in prefix)
    return 'delete_matching_keys(attributes, \"^' + quoted + '\")'

def delete_key(key):
    return 'delete_key(attributes, \"' + key + '\")'

def no_logs_labels():
    for agent in cfg:
        assert processor(agent, '$LOGS_LABELS') is None, agent
        assert not pipelines_with(agent, '$LOGS_LABELS'), agent
"

for value in '{}' '{"metrics":{"nodeLabels":{},"podLabels":{}},"logs":{"nodeLabels":{},"podLabels":{}}}' \
    '{"metrics":{"nodeLabels":{"include":null,"exclude":null},"podLabels":{"include":[],"exclude":[]}},"logs":{"nodeLabels":{"include":null,"exclude":null},"podLabels":{"include":[],"exclude":[]}}}' \
    '{"metrics":null,"logs":null}' '{"metrics":null}' '{"logs":null}' \
    '{"metrics":{"nodeLabels":null,"podLabels":null},"logs":{"nodeLabels":null,"podLabels":null}}' \
    '{"metrics":{"nodeLabels":{"recommendedExclusions":null},"podLabels":{"recommendedExclusions":null}},"logs":{"nodeLabels":{"recommendedExclusions":null},"podLabels":{"recommendedExclusions":null}}}'; do
    check_case "No label filters for $value — all labels, recommended exclusions on metrics only" "$value" "$LABEL_BLOCKS
assert_labels('node', all_labels('node'))
assert_labels('pod', all_labels('pod'))
assert_attribute_limit(RECOMMENDED_PREFIXES, RECOMMENDED_KEYS)
no_logs_labels()"
done

for source in node pod; do
    kind="${source}Labels"

    check_case "$kind include exact" \
        "{\"metrics\":{\"$kind\":{\"include\":[\"app\"]}},\"logs\":{\"$kind\":{\"include\":[\"app\"]}}}" "$LABEL_BLOCKS
assert_labels('$source', [{'tag_name': 'k8s.$source.label.app', 'key': 'app', 'from': '$source'}])"

    check_case "$kind include prefix" \
        "{\"metrics\":{\"$kind\":{\"include\":[\"team*\"]}},\"logs\":{\"$kind\":{\"include\":[\"team*\"]}}}" "$LABEL_BLOCKS
assert_labels('$source', [{'tag_name': 'k8s.$source.label.\$\$\$1', 'key_regex': '(team.*)', 'from': '$source'}])"

    check_case "$kind include prefix with dots and a slash is escaped" \
        "{\"metrics\":{\"$kind\":{\"include\":[\"app.kubernetes.io/*\"]}},\"logs\":{\"$kind\":{\"include\":[\"app.kubernetes.io/*\"]}}}" "$LABEL_BLOCKS
assert_labels('$source', [{'tag_name': 'k8s.$source.label.\$\$\$1', 'key_regex': '(app\\\\.kubernetes\\\\.io/.*)', 'from': '$source'}])"

    check_case "$kind include *" \
        "{\"metrics\":{\"$kind\":{\"include\":[\"*\"]}},\"logs\":{\"$kind\":{\"include\":[\"*\"]}}}" "$LABEL_BLOCKS
assert_labels('$source', all_labels('$source'))"

    check_case "$kind include several entries, in order and listed once, logs in another order" \
        "{\"metrics\":{\"$kind\":{\"include\":[\"app\",\"team*\",\"app\"]}},\"logs\":{\"$kind\":{\"include\":[\"team*\",\"app\"]}}}" "$LABEL_BLOCKS
exact = {'tag_name': 'k8s.$source.label.app', 'key': 'app', 'from': '$source'}
prefix = {'tag_name': 'k8s.$source.label.\$\$\$1', 'key_regex': '(team.*)', 'from': '$source'}
assert_labels('$source', [exact, prefix])"

    check_case "$kind include * among other entries extracts all labels once" \
        "{\"metrics\":{\"$kind\":{\"include\":[\"app\",\"*\"]}},\"logs\":{\"$kind\":{\"include\":[\"*\"]}}}" "$LABEL_BLOCKS
assert_labels('$source', all_labels('$source'))"

    check_case "$kind include empty, *, and * listed twice are the same list" \
        "{\"metrics\":{\"$kind\":{\"include\":[\"*\",\"*\"]}},\"logs\":{\"$kind\":{\"include\":[]}}}" "$LABEL_BLOCKS
assert_labels('$source', all_labels('$source'))"

    check_case "$kind include keys with uppercase, underscore and hyphen" \
        "{\"metrics\":{\"$kind\":{\"include\":[\"Team_X\",\"my-label*\"]}},\"logs\":{\"$kind\":{\"include\":[\"Team_X\",\"my-label*\"]}}}" "$LABEL_BLOCKS
assert_labels('$source', [{'tag_name': 'k8s.$source.label.Team_X', 'key': 'Team_X', 'from': '$source'},
                          {'tag_name': 'k8s.$source.label.\$\$\$1', 'key_regex': '(my-label.*)', 'from': '$source'}])"
done

check_case "Node and pod label include are independent" \
    '{"metrics":{"nodeLabels":{"include":["a"]},"podLabels":{"include":["b"]}},"logs":{"nodeLabels":{"include":["a"]},"podLabels":{"include":["b"]}}}' "$LABEL_BLOCKS
assert_labels('node', [{'tag_name': 'k8s.node.label.a', 'key': 'a', 'from': 'node'}])
assert_labels('pod', [{'tag_name': 'k8s.pod.label.b', 'key': 'b', 'from': 'pod'}])"

check_case "Metrics label exclude exact and prefix are added to the recommended exclusions" \
    '{"metrics":{"nodeLabels":{"exclude":["team-x","example.com/*"]},"podLabels":{"exclude":["app","tier*"]}}}' "$LABEL_BLOCKS
assert_attribute_limit(
    RECOMMENDED_PREFIXES + ['k8s.node.label.example.com/', 'k8s.pod.label.tier'],
    RECOMMENDED_NODE_KEYS + ['k8s.node.label.team-x'] + RECOMMENDED_POD_KEYS + ['k8s.pod.label.app'])
no_logs_labels()"

check_case "Metrics label exclude * removes every label of that kind" \
    '{"metrics":{"nodeLabels":{"exclude":["*"],"recommendedExclusions":false},"podLabels":{"exclude":["*"],"recommendedExclusions":false}}}' "$LABEL_BLOCKS
assert_attribute_limit(['k8s.node.label.', 'k8s.pod.label.'], [])"

check_case "Metrics label exclude duplicates and recommended entries are listed once" \
    '{"metrics":{"nodeLabels":{"exclude":["release","x","x"]},"podLabels":{"exclude":["pod-template-hash"]}}}' "$LABEL_BLOCKS
assert_attribute_limit(RECOMMENDED_PREFIXES,
    RECOMMENDED_NODE_KEYS + ['k8s.node.label.x'] + RECOMMENDED_POD_KEYS)"

check_case "Metrics node recommended exclusions off" \
    '{"metrics":{"nodeLabels":{"recommendedExclusions":false}}}' "$LABEL_BLOCKS
assert_attribute_limit([], RECOMMENDED_POD_KEYS)"

check_case "Metrics pod recommended exclusions off" \
    '{"metrics":{"podLabels":{"recommendedExclusions":false}}}' "$LABEL_BLOCKS
assert_attribute_limit(RECOMMENDED_PREFIXES, RECOMMENDED_NODE_KEYS)"

check_case "Metrics recommended exclusions off — no removal lists" \
    '{"metrics":{"nodeLabels":{"recommendedExclusions":false},"podLabels":{"recommendedExclusions":false}}}' "$LABEL_BLOCKS
assert_attribute_limit([], [])"

check_case "Metrics label exclude is placed where awsattributelimit is today" \
    '{"metrics":{"nodeLabels":{"exclude":["x"]}}}' "$LABEL_BLOCKS
for agent in ('$NODE', '$SCRAPER'):
    metrics = sorted(p for p in cfg[agent]['service']['pipelines'] if p.startswith('metrics/'))
    assert pipelines_with(agent, 'awsattributelimit/cw_k8s_ci_v0') == metrics, agent
no_logs_labels()"

check_case "Logs label exclude exact and prefix" \
    '{"logs":{"nodeLabels":{"exclude":["team-x","example.com/*"]},"podLabels":{"exclude":["app","tier*"]}}}' "$LABEL_BLOCKS
assert processor('$NODE', '$LOGS_LABELS') == logs_labels(
    delete_prefix('k8s.node.label.example.com/'),
    delete_prefix('k8s.pod.label.tier'),
    delete_key('k8s.node.label.team-x'),
    delete_key('k8s.pod.label.app'))
assert_attribute_limit(RECOMMENDED_PREFIXES, RECOMMENDED_KEYS)"

check_case "Logs label exclude * removes every label of that kind" \
    '{"logs":{"nodeLabels":{"exclude":["*"]},"podLabels":{"exclude":["*"]}}}' "$LABEL_BLOCKS
assert processor('$NODE', '$LOGS_LABELS') == logs_labels(
    delete_prefix('k8s.node.label.'), delete_prefix('k8s.pod.label.'))"

check_case "Logs label exclude duplicates are listed once" \
    '{"logs":{"podLabels":{"exclude":["x","x"]}}}' "$LABEL_BLOCKS
assert processor('$NODE', '$LOGS_LABELS') == logs_labels(delete_key('k8s.pod.label.x'))"

check_case "Logs recommended exclusions on" \
    '{"logs":{"nodeLabels":{"recommendedExclusions":true},"podLabels":{"recommendedExclusions":true}}}' "$LABEL_BLOCKS
assert processor('$NODE', '$LOGS_LABELS') == logs_labels(
    *[delete_prefix(p) for p in RECOMMENDED_PREFIXES], *[delete_key(k) for k in RECOMMENDED_KEYS])"

check_case "Logs pod recommended exclusions on, node off" \
    '{"logs":{"podLabels":{"recommendedExclusions":true}}}' "$LABEL_BLOCKS
assert processor('$NODE', '$LOGS_LABELS') == logs_labels(*[delete_key(k) for k in RECOMMENDED_POD_KEYS])"

check_case "Logs label exclude — in the application and host logs pipelines, before batch" \
    '{"logs":{"nodeLabels":{"exclude":["x"]}}}' "$LABEL_BLOCKS
assert pipelines_with('$NODE', '$LOGS_LABELS') == ['logs/cw_k8s_ci_v0_app', 'logs/cw_k8s_ci_v0_node']
app = pipeline('$NODE', 'logs/cw_k8s_ci_v0_app')
assert app[-3:] == ['transform/cw_k8s_ci_v0_logs_set_workload', '$LOGS_LABELS', 'batch/cw_k8s_ci_v0_logs_dest'], app
host = pipeline('$NODE', 'logs/cw_k8s_ci_v0_node')
assert host[-3:] == ['transform/cw_k8s_ci_v0_logs_clear_schema_url', '$LOGS_LABELS', 'batch/cw_k8s_ci_v0_logs_dest'], host
assert processor('$SCRAPER', '$LOGS_LABELS') is None"

check_case "Logs label exclude * with recommended exclusions on" \
    '{"logs":{"nodeLabels":{"exclude":["*"],"recommendedExclusions":true}}}' "$LABEL_BLOCKS
assert processor('$NODE', '$LOGS_LABELS') == logs_labels(
    *[delete_prefix(p) for p in RECOMMENDED_PREFIXES + ['k8s.node.label.']],
    *[delete_key(k) for k in RECOMMENDED_NODE_KEYS])"

check_case "Logs label exclude with OTEL logs disabled — no logs label processor" \
    '{"logs":{"podLabels":{"exclude":["x"]}}}' "$LABEL_BLOCKS
no_logs_labels()" "--set otelContainerInsights.logs.enabled=false"

# Include and exclude together: include picks what k8sattributes extracts,
# exclude removes from it (awsattributelimit for metrics, transform for logs).
check_case "Labels include * with exclude exact and prefix — metrics and logs" \
    '{"metrics":{"nodeLabels":{"include":["*"],"exclude":["team-x","example.com/*"]},"podLabels":{"include":["*"],"exclude":["app-secret"]}},"logs":{"nodeLabels":{"include":["*"],"exclude":["team-x","example.com/*"]},"podLabels":{"include":["*"],"exclude":["app-secret"]}}}' "$LABEL_BLOCKS
assert_labels('node', all_labels('node'))
assert_labels('pod', all_labels('pod'))
assert_attribute_limit(
    RECOMMENDED_PREFIXES + ['k8s.node.label.example.com/'],
    RECOMMENDED_NODE_KEYS + ['k8s.node.label.team-x'] + RECOMMENDED_POD_KEYS + ['k8s.pod.label.app-secret'])
assert processor('$NODE', '$LOGS_LABELS') == logs_labels(
    delete_prefix('k8s.node.label.example.com/'),
    delete_key('k8s.node.label.team-x'),
    delete_key('k8s.pod.label.app-secret'))"

check_case "Labels include prefix with exclude exact and prefix inside it — metrics and logs" \
    '{"metrics":{"podLabels":{"include":["app*"],"exclude":["app-secret","app.k8s/*"]}},"logs":{"podLabels":{"include":["app*"],"exclude":["app-secret","app.k8s/*"]}}}' "$LABEL_BLOCKS
assert_labels('node', all_labels('node'))
assert_labels('pod', [{'tag_name': 'k8s.pod.label.\$\$\$1', 'key_regex': '(app.*)', 'from': 'pod'}])
assert_attribute_limit(
    RECOMMENDED_PREFIXES + ['k8s.pod.label.app.k8s/'],
    RECOMMENDED_KEYS + ['k8s.pod.label.app-secret'])
assert processor('$NODE', '$LOGS_LABELS') == logs_labels(
    delete_prefix('k8s.pod.label.app.k8s/'),
    delete_key('k8s.pod.label.app-secret'))"

check_case "Labels include exact with exclude and recommended exclusions off — metrics" \
    '{"metrics":{"nodeLabels":{"include":["team","zone"],"exclude":["zone"],"recommendedExclusions":false},"podLabels":{"recommendedExclusions":false}},"logs":{"nodeLabels":{"include":["zone","team"]}}}' "$LABEL_BLOCKS
assert_labels('node', [{'tag_name': 'k8s.node.label.team', 'key': 'team', 'from': 'node'},
                       {'tag_name': 'k8s.node.label.zone', 'key': 'zone', 'from': 'node'}])
assert_attribute_limit([], ['k8s.node.label.zone'])
no_logs_labels()"

for kind in nodeLabels podLabels; do
    check_fails "Invalid — metrics $kind include without the logs list" \
        "{\"metrics\":{\"$kind\":{\"include\":[\"app\"]}}}" \
        "otelContainerInsights.filters.metrics.$kind.include and otelContainerInsights.filters.logs.$kind.include must contain the same labels"
    check_fails "Invalid — logs $kind include without the metrics list" \
        "{\"logs\":{\"$kind\":{\"include\":[\"app\"]}}}" \
        "otelContainerInsights.filters.metrics.$kind.include and otelContainerInsights.filters.logs.$kind.include must contain the same labels"
    check_fails "Invalid — $kind include lists differ" \
        "{\"metrics\":{\"$kind\":{\"include\":[\"a\"]}},\"logs\":{\"$kind\":{\"include\":[\"b\"]}}}" \
        'must contain the same labels, got ["a"] and ["b"]'
    for signal in metrics logs; do
        check_fails "Invalid — $signal.$kind.recommendedExclusions is not a boolean" \
            "{\"$signal\":{\"$kind\":{\"recommendedExclusions\":\"yes\"}}}" \
            "otelContainerInsights.filters.$signal.$kind.recommendedExclusions must be a boolean"
        message="otelContainerInsights.filters.$signal.$kind entries must be"
        for entry in '"a b"' '"a*b"' '"-a"' '"a\"b"' '""' 'true'; do
            check_fails "Invalid $signal.$kind.exclude entry $entry" \
                "{\"$signal\":{\"$kind\":{\"exclude\":[$entry]}}}" "$message"
        done
        check_fails "Invalid $signal.$kind.include entry \"a b\"" \
            "{\"$signal\":{\"$kind\":{\"include\":[\"a b\"]}}}" "$message"
        check_fails "Invalid — $signal.$kind.recommendedExclusions is a number" \
            "{\"$signal\":{\"$kind\":{\"recommendedExclusions\":1}}}" \
            "otelContainerInsights.filters.$signal.$kind.recommendedExclusions must be a boolean"
        check_fails "Invalid $signal.$kind — not a map" \
            "{\"$signal\":{\"$kind\":[\"app\"]}}" "otelContainerInsights.filters.$signal.$kind must be a map"
        check_fails "Invalid $signal.$kind — unknown key" \
            "{\"$signal\":{\"$kind\":{\"excludes\":[\"app\"]}}}" \
            "otelContainerInsights.filters.$signal.$kind has an unknown key \"excludes\""
        for list in include exclude; do
            check_fails "Invalid $signal.$kind.$list — a string, not a list" \
                "{\"$signal\":{\"$kind\":{\"$list\":\"app\"}}}" \
                "otelContainerInsights.filters.$signal.$kind.$list must be a list"
        done
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
