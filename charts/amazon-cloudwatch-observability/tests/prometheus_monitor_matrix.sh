#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT
#
# Validates otelPrometheusMonitor (ServiceMonitor/PodMonitor scraping) wiring:
#   - one switch, independent of otelContainerInsights;
#   - the chart never renders the community SM/PM CRDs; the operator creates them
#     (--manage-prometheus-crds) with matching operator RBAC;
#   - both agents get a Target Allocator with prometheusCR discovery and read-only RBAC;
#   - with otelContainerInsights off, each agent's config holds only the SM/PM pipeline;
#   - with both on, no component is defined twice and the shared definitions match;
#   - the SM/PM series carry cloudwatch.solution k8s-otel-prometheus-monitors.
#
# This is a template-level test (helm template only); it does not deploy to a cluster.
# The operator's create-if-missing behavior is covered by the operator's pkg/crdmanager
# tests and by cluster testing.
#
# Run from the repo root:
#     bash charts/amazon-cloudwatch-observability/tests/prometheus_monitor_matrix.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
N='\033[0m'

pass_count=0
fail_count=0

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

MON='--set otelPrometheusMonitor.enabled=true'
CI='--set otelContainerInsights.enabled=true'
# The OTLP endpoint (otlp.enabled, on by default) adds its own pipelines to the node agent.
NO_OTLP='--set otlp.enabled=false'

SM_CRD='^[[:space:]]*name: servicemonitors\.monitoring\.coreos\.com$'
PM_CRD='^[[:space:]]*name: podmonitors\.monitoring\.coreos\.com$'
# Target Allocator ClusterRole rules (read-only CRD watch and SM/PM discovery).
TA_CRD_RBAC='resources: \["customresourcedefinitions"\]'
TA_SM_PM_RBAC='resources: \["podmonitors", "servicemonitors"\]'
# Operator ClusterRole rule (create-if-missing) and the flag that turns it on.
OP_CRD_RBAC='resources: \[ "customresourcedefinitions" \]'
OP_CRD_VERBS='verbs: \[ "create","get","list","watch" \]'
OP_FLAG='"--manage-prometheus-crds"'
# Target Allocator Secret access (otelPrometheusMonitor.readSecrets). The exact verbs are checked below.
TA_SECRETS_RBAC='resources: \["secrets"\]'

# render <args...> -> echoes the rendered manifests. --no-hooks leaves out the crds.upgradeJob
# hook, whose ConfigMaps hold the CRD files (tests/crd_upgrade_job.sh covers it).
render() {
    # shellcheck disable=SC2068
    helm template t "$CHART_DIR" --no-hooks \
        --kube-version 1.35.0 \
        --set region=us-west-2 \
        --set clusterName=test-cluster $@ 2>&1
}

pass() { printf "${G}PASS${N} %s\n" "$1"; pass_count=$((pass_count+1)); }
fail() { printf "${R}FAIL${N} %s\n" "$1"; fail_count=$((fail_count+1)); }

# expect_count <desc> <pattern> <expected-count> <render-args...>
expect_count() {
    local desc="$1" pattern="$2" want="$3"; shift 3
    local out got
    out="$(render "$@")" || { fail "$desc (helm error) $out"; return; }
    got="$(printf '%s\n' "$out" | grep -cE "$pattern" || true)"
    if [[ "$got" == "$want" ]]; then
        pass "$desc ($got == $want)"
    else
        fail "$desc (got $got, want $want) [$*]"
    fi
}

# expect_py <desc> <python-check> <render-args...>
# Runs a Python check over the rendered manifests. The check gets `agents`, a dict of
# AmazonCloudWatchAgent name -> {"spec": spec, "otel": parsed otelConfig or {}}, and
# `raw`, the agent name -> otelConfig string. It prints "ok" or a failure reason.
expect_py() {
    local desc="$1" check="$2"; shift 2
    local out res
    out="$(render "$@")" || { fail "$desc (helm error) $out"; return; }
    res="$(printf '%s\n' "$out" | CHECK="$check" python3 -c '
import os, sys, yaml

class UniqueKeyLoader(yaml.SafeLoader):
    pass

def no_duplicates(loader, node, deep=False):
    keys = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in keys:
            raise ValueError("duplicate key %r" % (key,))
        keys.add(key)
    return loader.construct_mapping(node, deep)

UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_duplicates)

agents, raw = {}, {}
for d in yaml.safe_load_all(sys.stdin):
    if not d or d.get("kind") != "AmazonCloudWatchAgent":
        continue
    oc = d["spec"].get("otelConfig") or ""
    raw[d["metadata"]["name"]] = oc
    agents[d["metadata"]["name"]] = {"spec": d["spec"], "otel": yaml.load(oc, Loader=UniqueKeyLoader) if oc else {}}

PIPE = "metrics/cw_k8s_ci_v0_prometheuscr"
SCOPE = "transform/cw_k8s_ci_v0_set_scope_prometheuscr"
NODE, SCRAPER = "cloudwatch-agent", "cloudwatch-agent-cluster-scraper"

def env(agent):
    return {e["name"] for e in agents[agent]["spec"].get("env") or []}

try:
    exec(os.environ["CHECK"])
except Exception as e:
    print("error: %s" % e)
')" || true
    if [[ "$res" == "ok" ]]; then
        pass "$desc"
    else
        fail "$desc: $res [$*]"
    fi
}

printf "${Y}== off by default ==${N}\n"
expect_count "default => no Target Allocator"        'targetAllocator:' 0
expect_count "default => no operator flag"           "$OP_FLAG" 0
expect_count "default => no operator CRD RBAC"       "$OP_CRD_RBAC" 0
expect_count "default => no TA CRD RBAC"             "$TA_CRD_RBAC" 0
expect_count "default => no cluster-scraper agent"   'name: cloudwatch-agent-cluster-scraper$' 0
expect_count "otelCI only => no Target Allocator"    'targetAllocator:' 0 $CI
expect_count "otelCI only => no operator flag"       "$OP_FLAG" 0 $CI
expect_count "otelCI only => no TA CRD RBAC"         "$TA_CRD_RBAC" 0 $CI
# The old otelContainerInsights.prometheusScrape key is gone and does nothing.
expect_count "removed prometheusScrape.enabled is ignored" 'targetAllocator:' 0 $CI --set otelContainerInsights.prometheusScrape.enabled=true

printf "\n${Y}== chart never renders the SM/PM CRDs ==${N}\n"
expect_count "monitor on => no ServiceMonitor CRD"          "$SM_CRD" 0 $MON
expect_count "monitor on => no PodMonitor CRD"              "$PM_CRD" 0 $MON
expect_count "monitor + otelCI => no CRD objects at all"    'kind: CustomResourceDefinition' 0 $MON $CI

printf "\n${Y}== operator --manage-prometheus-crds and RBAC follow otelPrometheusMonitor ==${N}\n"
for extra in "" "$CI"; do
    label="monitor on${extra:+ + otelCI}"
    expect_count "$label => operator flag"                        "$OP_FLAG" 1 $MON $extra
    expect_count "$label => operator CRD RBAC"                    "$OP_CRD_RBAC" 1 $MON $extra
    expect_count "$label => operator CRD verbs (no update/patch/delete)" "$OP_CRD_VERBS" 1 $MON $extra
    expect_count "$label => TA CRD watch RBAC"                    "$TA_CRD_RBAC" 1 $MON $extra
    expect_count "$label => TA SM/PM RBAC"                        "$TA_SM_PM_RBAC" 1 $MON $extra
    expect_count "$label => TA on both agents"                    'targetAllocator:' 2 $MON $extra
    expect_count "$label => prometheusCR on both agents"          'prometheusCR:' 2 $MON $extra
    expect_count "$label => per-node on the per-node agent"       'allocationStrategy: "per-node"' 1 $MON $extra
    expect_count "$label => consistent-hashing on the cluster-scraper" 'allocationStrategy: "consistent-hashing"' 1 $MON $extra
    expect_count "$label => scraperRole only on the cluster-scraper"   'scraperRole: cluster-scraper' 1 $MON $extra
    expect_count "$label => no monitor selectors"                 'onitorSelector:' 0 $MON $extra
done
# An agents[] entry without a name resolves to the default agent name (cloudwatch-agent),
# so its CR renders a Target Allocator; the shared TA ClusterRole and binding must render too.
UNNAMED="$tmp_dir/unnamed-agent.yaml"
printf 'agents:\n  - {}\n' > "$UNNAMED"
expect_count "unnamed agent => TA on the CR"              'targetAllocator:' 1 $MON -f "$UNNAMED"
ta_rbac="$(render $MON -f "$UNNAMED" | python3 -c '
import sys, yaml
kinds = sorted("%s/%s" % (d["kind"], d["metadata"]["name"]) for d in yaml.safe_load_all(sys.stdin)
               if d and d.get("kind") in ("ClusterRole", "ClusterRoleBinding") and "target-allocator" in d["metadata"]["name"])
print(" ".join(kinds))')"
if [[ "$ta_rbac" == "ClusterRole/cloudwatch-agent-target-allocator-role ClusterRoleBinding/cloudwatch-agent-target-allocator-rolebinding" ]]; then
    pass "unnamed agent => TA ClusterRole and ClusterRoleBinding render"
else
    fail "unnamed agent => TA ClusterRole and ClusterRoleBinding render: got [$ta_rbac]"
fi
expect_count "unnamed agent => TA SM/PM RBAC"             "$TA_SM_PM_RBAC" 1 $MON -f "$UNNAMED"
expect_count "unnamed agent + readSecrets => one Secrets rule" "$TA_SECRETS_RBAC" 1 $MON -f "$UNNAMED" --set otelPrometheusMonitor.readSecrets=true
# A Target Allocator enabled directly on an agent keeps consistent-hashing.
expect_count "direct TA => consistent-hashing" 'allocationStrategy: "consistent-hashing"' 1 \
    --set agent.prometheus.targetAllocator.enabled=true --set agent.prometheus.targetAllocator.prometheusCR.enabled=true

printf "\n${Y}== Target Allocator Secret access (readSecrets) ==${N}\n"
expect_count "default => no Secrets rule"                         "$TA_SECRETS_RBAC" 0
expect_count "monitor on, readSecrets default => no Secrets rule" "$TA_SECRETS_RBAC" 0 $MON
expect_count "monitor on, readSecrets=false => no Secrets rule"   "$TA_SECRETS_RBAC" 0 $MON --set otelPrometheusMonitor.readSecrets=false
expect_count "readSecrets=true without monitor => no Secrets rule" "$TA_SECRETS_RBAC" 0 --set otelPrometheusMonitor.readSecrets=true
expect_count "readSecrets=true with otelCI only => no Secrets rule" "$TA_SECRETS_RBAC" 0 $CI --set otelPrometheusMonitor.readSecrets=true
for extra in "" "$CI"; do
    label="monitor on + readSecrets${extra:+ + otelCI}"
    expect_count "$label => one Secrets rule"          "$TA_SECRETS_RBAC" 1 $MON --set otelPrometheusMonitor.readSecrets=true $extra
done
# Across the whole render, readSecrets adds Secret access to the Target Allocator role only.
secret_rules() {
    render "$@" | python3 -c '
import sys, yaml
out = []
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") in ("ClusterRole", "Role"):
        for r in d.get("rules") or []:
            if "secrets" in (r.get("resources") or []):
                out.append("%s:%s" % (d["metadata"]["name"], ",".join(sorted(r.get("verbs") or []))))
print(" ".join(sorted(out)))'
}
before="$(secret_rules $MON)"
after="$(secret_rules $MON --set otelPrometheusMonitor.readSecrets=true)"
added="$(comm -13 <(tr ' ' '\n' <<<"$before" | sort) <(tr ' ' '\n' <<<"$after" | sort) | tr '\n' ' ' | sed 's/ $//')"
if [[ "$added" == "cloudwatch-agent-target-allocator-role:get" ]]; then
    pass "readSecrets adds only get on Secrets to the Target Allocator role"
else
    fail "readSecrets adds only get on Secrets to the Target Allocator role: added [$added]"
fi
printf "\n${Y}== otelPrometheusMonitor without otelContainerInsights ==${N}\n"
# With the OTLP endpoint off, each agent runs the SM/PM pipeline alone.
expect_py "both agents render with only the SM/PM pipeline" '
for a in (NODE, SCRAPER):
    pipes = sorted(agents[a]["otel"]["service"]["pipelines"])
    assert pipes == [PIPE], "%s pipelines %s" % (a, pipes)
print("ok")' $MON $NO_OTLP
expect_py "no other otelCI components or env" '
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    p = o["service"]["pipelines"][PIPE]
    for section in ("receivers", "processors", "exporters"):
        assert sorted(o[section]) == sorted(p[section]), "%s %s not limited to the pipeline" % (a, section)
    assert "OTEL_CI_VERSION" not in env(a), "%s has OTEL_CI_VERSION" % a
    assert "POD_NAME" in env(a), "%s has no POD_NAME" % a
print("ok")' $MON $NO_OTLP
expect_py "service.extensions are exactly the exporters' authenticators" '
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    auths = sorted({e["auth"]["authenticator"] for e in o["exporters"].values() if "auth" in e})
    assert sorted(o["service"]["extensions"]) == auths, "%s extensions %s, want %s" % (a, o["service"]["extensions"], auths)
    assert sorted(o["extensions"]) == auths, "%s extension definitions %s" % (a, sorted(o["extensions"]))
print("ok")' $MON $NO_OTLP
expect_py "renders on AKS" '
for a in (NODE, SCRAPER):
    assert list(agents[a]["otel"]["service"]["pipelines"]) == [PIPE], a
print("ok")' $MON $NO_OTLP --set k8sMode=AKS --set roleArn=arn:aws:iam::111111111111:role/x
# With the OTLP endpoint on (the default), the node agent runs the SM/PM pipeline next to
# the OTLP pipelines, and the cluster-scraper still runs the SM/PM pipeline alone.
expect_py "OTLP on => node agent runs SM/PM and OTLP pipelines, cluster-scraper SM/PM only" '
node = sorted(agents[NODE]["otel"]["service"]["pipelines"])
assert PIPE in node, "node pipelines %s" % node
others = [p for p in node if p != PIPE]
assert others and all("cw_k8s_otlp" in p for p in others), "node pipelines %s" % node
assert not any(p.startswith(("metrics/cw_k8s_ci_v0_", "logs/cw_k8s_ci_v0_")) and p != PIPE for p in node), "otelCI pipelines on the node agent: %s" % node
assert sorted(agents[SCRAPER]["otel"]["service"]["pipelines"]) == [PIPE], agents[SCRAPER]["otel"]["service"]["pipelines"]
print("ok")' $MON
expect_py "OTLP on => SM/PM components unchanged and every authenticator listed once" '
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    p = o["service"]["pipelines"][PIPE]
    assert p["exporters"] == ["otlphttp/cw_k8s_ci_v0_prometheuscr"], "%s %s" % (a, p["exporters"])
    for section in ("receivers", "processors", "exporters"):
        for name in p[section]:
            assert name in o[section], "%s %s/%s not defined" % (a, section, name)
    ext = o["service"]["extensions"]
    assert len(ext) == len(set(ext)), "%s duplicate extensions %s" % (a, ext)
    for e in o["exporters"].values():
        if "auth" in e:
            assert e["auth"]["authenticator"] in ext, "%s missing %s" % (a, e["auth"]["authenticator"])
print("ok")' $MON

printf "\n${Y}== otelPrometheusMonitor with otelContainerInsights ==${N}\n"
expect_py "no component or key defined twice (otelConfig parses with unique keys)" '
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    assert PIPE in o["service"]["pipelines"], "%s has no %s" % (a, PIPE)
    assert len(o["service"]["pipelines"]) > 1, "%s lost its otelCI pipelines" % a
print("ok")' $MON $CI
expect_py "service.extensions has every authenticator, once" '
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    ext = o["service"]["extensions"]
    assert len(ext) == len(set(ext)), "%s duplicate extensions %s" % (a, ext)
    for e in o["exporters"].values():
        if "auth" in e:
            assert e["auth"]["authenticator"] in ext, "%s missing %s" % (a, e["auth"]["authenticator"])
print("ok")' $MON $CI

# The components the SM/PM pipeline uses must be the same with and without otelCI.
render $MON > "$tmp_dir/mon_only.yaml"
render $MON $CI > "$tmp_dir/mon_ci.yaml"
same="$(python3 - "$tmp_dir/mon_only.yaml" "$tmp_dir/mon_ci.yaml" <<'EOF'
import sys, yaml
def load(path):
    out = {}
    for d in yaml.safe_load_all(open(path)):
        if d and d.get("kind") == "AmazonCloudWatchAgent" and d["spec"].get("otelConfig"):
            out[d["metadata"]["name"]] = yaml.safe_load(d["spec"]["otelConfig"])
    return out
a, b = load(sys.argv[1]), load(sys.argv[2])
bad = []
for agent, o in a.items():
    for section in ("receivers", "processors", "exporters", "extensions"):
        for name, comp in (o.get(section) or {}).items():
            if b[agent][section].get(name) != comp:
                bad.append("%s %s/%s" % (agent, section, name))
print("ok" if not bad else "differ: " + ", ".join(bad))
EOF
)"
if [[ "$same" == "ok" ]]; then pass "SM/PM components identical with and without otelCI"; else fail "SM/PM components identical with and without otelCI: $same"; fi

printf "\n${Y}== cloudwatch.solution and cloudwatch.pipeline ==${N}\n"
for extra in "" "$CI"; do
    expect_py "SM/PM pipelines set k8s-otel-prometheus-monitors / prometheus-monitors${extra:+ (with otelCI)}" '
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    assert SCOPE in o["service"]["pipelines"][PIPE]["processors"], "%s pipeline lacks %s" % (a, SCOPE)
    stmts = " ".join(s for ms in o["processors"][SCOPE]["metric_statements"] for s in ms["statements"])
    assert "\"cloudwatch.solution\"], \"k8s-otel-prometheus-monitors\"" in stmts, "%s solution: %s" % (a, stmts)
    assert "\"cloudwatch.pipeline\"], \"prometheus-monitors\"" in stmts, "%s pipeline: %s" % (a, stmts)
print("ok")' $MON $extra
done
expect_py "otelCI pipelines keep k8s-otel-container-insights" '
for a in (NODE, SCRAPER):
    for name, comp in agents[a]["otel"]["processors"].items():
        if name == SCOPE or not name.startswith("transform/cw_k8s_ci_v0_set_scope"):
            continue
        stmts = " ".join(s for ms in comp.get("metric_statements", []) + comp.get("log_statements", []) for s in ms["statements"])
        assert "k8s-otel-prometheus-monitors" not in stmts, "%s %s uses the monitors solution" % (a, name)
print("ok")' $MON $CI

printf "\n${Y}== units set on both SM/PM pipelines ==${N}\n"
# The per-node and cluster-scraper pipelines normalize units the same way, so a
# monitor's units do not depend on which agent scrapes it.
for extra in "" "$CI"; do
    expect_py "set_unit on both SM/PM pipelines${extra:+ (with otelCI)}" '
for a in (NODE, SCRAPER):
    assert "transform/cw_k8s_ci_v0_set_unit" in agents[a]["otel"]["service"]["pipelines"][PIPE]["processors"], a
print("ok")' $MON $extra
done

printf "\n${Y}== up is kept for ServiceMonitor/PodMonitor targets ==${N}\n"
# The SM/PM pipelines use their own filter: it drops the scrape metadata series but keeps
# up, so up == 0 shows a failing target. Container Insights pipelines keep dropping up.
for extra in "" "$CI"; do
    expect_py "SM/PM pipelines keep up and drop the scrape metadata${extra:+ (with otelCI)}" '
import re
F = "filter/cw_k8s_ci_v0_prometheuscr_scrape_metadata"
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    procs = o["service"]["pipelines"][PIPE]["processors"]
    assert F in procs, "%s pipeline lacks %s: %s" % (a, F, procs)
    assert "filter/cw_k8s_ci_v0_scrape_metadata" not in procs, "%s pipeline still drops up" % a
    pats = [re.search(r"IsMatch\(name, \"(.*)\"\)", m).group(1) for m in o["processors"][F]["metrics"]["metric"]]
    dropped = lambda n: any(re.search(p, n) for p in pats)
    assert not dropped("up"), "%s drops up" % a
    for n in ("scrape_duration_seconds", "scrape_samples_scraped", "scrape_samples_post_metric_relabeling", "scrape_series_added"):
        assert dropped(n), "%s keeps %s" % (a, n)
print("ok")' $MON $extra
done
expect_py "otelCI pipelines still drop up" '
import re
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    users = [p for p, v in o["service"]["pipelines"].items() if "filter/cw_k8s_ci_v0_scrape_metadata" in v.get("processors", [])]
    assert users and PIPE not in users, "%s: %s" % (a, users)
    pats = [re.search(r"IsMatch\(name, \"(.*)\"\)", m).group(1) for m in o["processors"]["filter/cw_k8s_ci_v0_scrape_metadata"]["metrics"]["metric"]]
    assert any(re.search(p, "up") for p in pats), "%s otelCI filter keeps up" % a
print("ok")' $MON $CI

printf "\n${Y}== otelPrometheusMonitor has its own agent names and scrapeInterval ==${N}\n"
# receiver_ta <agent> -> the prometheuscr receiver target_allocator block
TA_CHECK='
def ta(a):
    return agents[a]["otel"]["receivers"]["prometheus/cw_k8s_ci_v0_prometheuscr"]["target_allocator"]
def cr(a):
    return agents[a]["spec"]["targetAllocator"]["prometheusCR"]
'
for extra in "" "$CI"; do
    expect_py "scrapeInterval drives the TA poll and prometheusCR.scrapeInterval${extra:+ (with otelCI)}" "$TA_CHECK"'
for a in (NODE, SCRAPER):
    assert ta(a)["interval"] == "60s", "%s receiver interval %s" % (a, ta(a)["interval"])
    assert cr(a)["scrapeInterval"] == "60s", "%s prometheusCR %s" % (a, cr(a)["scrapeInterval"])
print("ok")' $MON $extra --set otelPrometheusMonitor.scrapeInterval=60s
done
expect_py "otelContainerInsights.metricResolution does not change the SM/PM interval" "$TA_CHECK"'
for a in (NODE, SCRAPER):
    assert ta(a)["interval"] == "30s" and cr(a)["scrapeInterval"] == "30s", (a, ta(a)["interval"], cr(a)["scrapeInterval"])
print("ok")' $MON $CI --set otelContainerInsights.metricResolution=15s
# Monitor-only with agent names of its own: the otelContainerInsights agent names do not apply.
OWN_AGENTS="$tmp_dir/own-agents.yaml"
cat > "$OWN_AGENTS" <<'EOF'
otelPrometheusMonitor:
  targetAgent: pm-node
  clusterScraperAgent: pm-central
agents:
  - name: pm-node
  - name: pm-central
    mode: deployment
    replicas: 1
  - name: cloudwatch-agent-cluster-scraper
    mode: deployment
    replicas: 1
EOF
expect_py "own agent names => SM/PM on pm-node and pm-central only" "$TA_CHECK"'
linux = {a for a in agents if not a.startswith("cloudwatch-agent-windows")}
assert linux == {"pm-node", "pm-central"}, "rendered agents: %s" % sorted(agents)
assert ta("pm-node")["endpoint"] == "https://pm-node-target-allocator-service:80", ta("pm-node")["endpoint"]
assert ta("pm-central")["endpoint"] == "https://pm-central-target-allocator-service:80", ta("pm-central")["endpoint"]
assert agents["pm-node"]["spec"]["targetAllocator"]["allocationStrategy"] == "per-node"
assert agents["pm-central"]["spec"]["targetAllocator"]["allocationStrategy"] == "consistent-hashing"
assert "scraperRole" not in cr("pm-node") and cr("pm-central").get("scraperRole") == "cluster-scraper"
for a in ("pm-node", "pm-central"):
    assert list(agents[a]["otel"]["service"]["pipelines"]) == [PIPE], (a, list(agents[a]["otel"]["service"]["pipelines"]))
print("ok")' $MON -f "$OWN_AGENTS"
expect_count "own agent names => TA SM/PM RBAC" "$TA_SM_PM_RBAC" 1 $MON -f "$OWN_AGENTS"

printf "\n${Y}== SM/PM series always use the regional endpoint ==${N}\n"
for extra in "" "$CI"; do
    expect_py "cloudwatchMetricsEndpoint does not apply to SM/PM${extra:+ (with otelCI)}" '
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    ex = o["service"]["pipelines"][PIPE]["exporters"]
    assert ex == ["otlphttp/cw_k8s_ci_v0_prometheuscr"], "%s exporters %s" % (a, ex)
    ep = o["exporters"]["otlphttp/cw_k8s_ci_v0_prometheuscr"]["endpoint"]
    assert ep == "https://monitoring.us-west-2.amazonaws.com:443", "%s endpoint %s" % (a, ep)
    # With otelCI on, its metrics exporter keeps the override.
    ci = {NODE: "otlphttp/cw_k8s_ci_v0_metrics_dest", SCRAPER: "otlphttp/cw_k8s_ci_v0_cwotel"}[a]
    if ci in o["exporters"]:
        assert o["exporters"][ci]["endpoint"] == "https://example.invalid:443", "%s %s %s" % (a, ci, o["exporters"][ci]["endpoint"])
print("ok")' $MON $extra --set otelContainerInsights.cloudwatchMetricsEndpoint=https://example.invalid:443
done

printf "\n${Y}== otelPrometheusMonitor validation ==${N}\n"
# expect_render_fails <desc> <error-regex> <render-args...>
expect_render_fails() {
    local desc="$1" want="$2"; shift 2
    local out
    if out="$(render "$@")"; then
        fail "$desc (render succeeded) [$*]"
    elif printf '%s\n' "$out" | grep -qE "$want"; then
        pass "$desc"
    else
        fail "$desc (wrong error: $(printf '%s' "$out" | head -c 300)) [$*]"
    fi
}
# Both features on: each agent runs the otelContainerInsights config, which holds the SM/PM
# pipeline, so they must target the same agents.
expect_render_fails "both on + different targetAgent => render fails" \
    'must match otelContainerInsights.targetAgent' $MON $CI --set otelPrometheusMonitor.targetAgent=pm-node
expect_render_fails "both on + different clusterScraperAgent => render fails" \
    'must match otelContainerInsights.targetAgent' $MON $CI --set otelPrometheusMonitor.clusterScraperAgent=pm-central
expect_count "monitor off + different agent names => renders" 'kind: AmazonCloudWatchAgent' 4 $CI \
    --set otelPrometheusMonitor.targetAgent=pm-node --set otelPrometheusMonitor.clusterScraperAgent=pm-central
expect_render_fails "targetAgent == clusterScraperAgent => render fails" \
    'must differ' $MON --set otelPrometheusMonitor.clusterScraperAgent=cloudwatch-agent
expect_render_fails "empty targetAgent => render fails" \
    'must be non-empty strings' $MON --set otelPrometheusMonitor.targetAgent=
for bad in 30 30m 0s 1.5s; do
    expect_render_fails "scrapeInterval=$bad => render fails" 'scrapeInterval must be in' $MON --set otelPrometheusMonitor.scrapeInterval=$bad
done

printf "\n${Y}== serviceMonitorSelector / podMonitorSelector ==${N}\n"
expect_count "selectors {} => no monitor selectors" 'onitorSelector:' 0 $MON \
    --set-json 'otelPrometheusMonitor.serviceMonitorSelector={}' --set-json 'otelPrometheusMonitor.podMonitorSelector={}'
SEL_LABELS='{"matchLabels":{"cloudwatch":"true"}}'
SEL_EXPR='{"matchExpressions":[{"key":"team","operator":"In","values":["payments","checkout"]},{"key":"legacy","operator":"DoesNotExist"}]}'
export SEL_LABELS SEL_EXPR
for extra in "" "$CI"; do
    expect_py "matchLabels and matchExpressions on both agents${extra:+ (with otelCI)}" '
import json
for a in (NODE, SCRAPER):
    c = agents[a]["spec"]["targetAllocator"]["prometheusCR"]
    assert c.get("serviceMonitorSelector") == json.loads(os.environ["SEL_LABELS"]), "%s sm %s" % (a, c.get("serviceMonitorSelector"))
    assert c.get("podMonitorSelector") == json.loads(os.environ["SEL_EXPR"]), "%s pm %s" % (a, c.get("podMonitorSelector"))
print("ok")' $MON $extra --set-json "otelPrometheusMonitor.serviceMonitorSelector=$SEL_LABELS" --set-json "otelPrometheusMonitor.podMonitorSelector=$SEL_EXPR"
done
expect_count "selectors without the monitor => not rendered" 'onitorSelector:' 0 \
    --set-json "otelPrometheusMonitor.serviceMonitorSelector=$SEL_LABELS"
expect_render_fails "selector with an unknown key => render fails" 'unknown key "labels"' $MON \
    --set-json 'otelPrometheusMonitor.serviceMonitorSelector={"labels":{"a":"b"}}'
expect_render_fails "selector as a flat label map => render fails" 'unknown key "cloudwatch"' $MON \
    --set-json 'otelPrometheusMonitor.podMonitorSelector={"cloudwatch":"true"}'
expect_render_fails "matchLabels with a non-string value => render fails" 'must be a string' $MON \
    --set-json 'otelPrometheusMonitor.serviceMonitorSelector={"matchLabels":{"cloudwatch":true}}'
expect_render_fails "matchExpressions with a bad operator => render fails" 'operator must be In, NotIn, Exists or DoesNotExist' $MON \
    --set-json 'otelPrometheusMonitor.podMonitorSelector={"matchExpressions":[{"key":"a","operator":"Equals","values":["b"]}]}'
expect_render_fails "In without values => render fails" 'operator In needs values' $MON \
    --set-json 'otelPrometheusMonitor.podMonitorSelector={"matchExpressions":[{"key":"a","operator":"In"}]}'
expect_render_fails "Exists with values => render fails" 'operator Exists takes no values' $MON \
    --set-json 'otelPrometheusMonitor.serviceMonitorSelector={"matchExpressions":[{"key":"a","operator":"Exists","values":["b"]}]}'
expect_render_fails "matchExpressions entry without a key => render fails" 'needs a key' $MON \
    --set-json 'otelPrometheusMonitor.serviceMonitorSelector={"matchExpressions":[{"operator":"Exists"}]}'

printf "\n${Y}== service identity on both SM/PM pipelines ==${N}\n"
# The SM/PM pipelines use the Container Insights pod k8sattributes and the chart-wide
# service identity processor (_service-identity.tpl), so a monitor's series get the same
# service.* as the pod's Container Insights metrics and OTLP data.
ID_CHECK='
POD = "k8sattributes/cw_k8s_ci_v0_pod"
ID = "transform/cw_k8s_ci_v0_service_identity"
def id_statements(o):
    return [s for g in o["processors"][ID]["metric_statements"] for s in g["statements"]]
def pod_label_tags(o):
    return [l["tag_name"] for l in o["processors"][POD]["extract"].get("labels") or []]
'
for extra in "$NO_OTLP" "" "$CI"; do
    label="${extra:+ ($extra)}"
    expect_py "k8sattributes, then resourcedetection, then service identity on both pipelines$label" "$ID_CHECK"'
for a in (NODE, SCRAPER):
    procs = agents[a]["otel"]["service"]["pipelines"][PIPE]["processors"]
    for name in (POD, ID):
        assert name in procs, "%s pipeline lacks %s: %s" % (a, name, procs)
    i = procs.index
    assert i(POD) < i("resourcedetection/cw_k8s_ci_v0") < i(ID) < i("awsattributelimit/cw_k8s_ci_v0"), "%s order %s" % (a, procs)
print("ok")' $MON $extra
    expect_py "identity processor is the receiverDefault chain, same on both agents$label" "$ID_CHECK"'
n, s = agents[NODE]["otel"], agents[SCRAPER]["otel"]
assert n["processors"][ID] == s["processors"][ID], "the agents differ"
st = id_statements(n)
assert any(x.startswith("delete_key(resource.attributes, \"service.name\") where resource.attributes[\"service.name\"] != nil") for x in st), "job name not treated as unset"
assert any("_tmp.service_identity.receiver.service.instance.id" in x for x in st), "target not set aside"
assert any("k8s.pod.label.serving.kserve.io/inferenceservice" in x for x in st), "no KServe input"
assert any("k8s.deployment.name" in x for x in st), "no workload chain"
print("ok")' $MON $extra
    expect_py "pod k8sattributes: this node only on the per-node agent, cluster-wide on the scraper$label" "$ID_CHECK"'
for a in (NODE, SCRAPER):
    k = agents[a]["otel"]["processors"][POD]
    assert k["pod_association"] == [{"sources": [{"from": "resource_attribute", "name": "k8s.pod.name"}, {"from": "resource_attribute", "name": "k8s.namespace.name"}]}], "%s %s" % (a, k["pod_association"])
    ann = sorted(x["key"] for x in k["extract"]["annotations"])
    assert ann == ["resource.opentelemetry.io/service.instance.id", "resource.opentelemetry.io/service.name", "resource.opentelemetry.io/service.namespace", "resource.opentelemetry.io/service.version"], "%s annotations %s" % (a, ann)
assert agents[NODE]["otel"]["processors"][POD].get("filter") == {"node_from_env_var": "K8S_NODE_NAME"}, agents[NODE]["otel"]["processors"][POD].get("filter")
assert "filter" not in agents[SCRAPER]["otel"]["processors"][POD], agents[SCRAPER]["otel"]["processors"][POD].get("filter")
print("ok")' $MON $extra
done
for extra in "$NO_OTLP" "$CI"; do
    expect_py "otelServiceIdentity.useAppLabels adds the app labels to the chain on both agents${extra:+ ($extra)}" "$ID_CHECK"'
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    tags = pod_label_tags(o)
    for l in ("instance", "name", "version"):
        assert "_tmp.service_identity.label.app.kubernetes.io/" + l in tags, "%s extract lacks %s: %s" % (a, l, tags)
    assert any("_tmp.service_identity.label.app.kubernetes.io/instance" in x for x in id_statements(o)), "%s chain ignores app labels" % a
print("ok")' $MON $extra --set otelServiceIdentity.useAppLabels=true
    expect_py "no app labels in the chain by default${extra:+ ($extra)}" "$ID_CHECK"'
for a in (NODE, SCRAPER):
    o = agents[a]["otel"]
    assert not [t for t in pod_label_tags(o) if t.startswith("_tmp.service_identity.label.")], a
    assert not any("_tmp.service_identity.label." in x for x in id_statements(o)), a
print("ok")' $MON $extra
done
expect_py "cluster-scraper defines the identity processor without kube-state-metrics" "$ID_CHECK"'
o = agents[SCRAPER]["otel"]
assert ID in o["processors"] and ID in o["service"]["pipelines"][PIPE]["processors"]
print("ok")' $MON $NO_OTLP --set kubeStateMetrics.enabled=false
# The pod k8sattributes extracts pod labels, so an otelFilters exception that turns on the
# metrics label processor for Container Insights also applies it to the SM/PM pipelines.
for extra in "$NO_OTLP" "$CI"; do
    expect_py "otelFilters label exceptions apply to the SM/PM pipelines${extra:+ ($extra)}" '
for a in (NODE, SCRAPER):
    procs = agents[a]["otel"]["service"]["pipelines"][PIPE]["processors"]
    assert "transform/cw_k8s_ci_v0_metrics_labels" in procs, "%s %s" % (a, procs)
print("ok")' $MON $extra --set-json 'otelFilters.nodeLabels.include=["beta.kubernetes.io/arch"]'
done

printf "\n${Y}== installed AmazonCloudWatchAgent CRD check (helm upgrade keeps old CRDs) ==${N}\n"
# cloudwatch-agent.validate-agent-crd reads the installed CRD with lookup when
# crds.upgradeJob is disabled. lookup is empty without a cluster, so these cases call its
# schema check on CRD files through a probe
# template in a copy of the chart: the bundled CRD, and copies with the parts an older
# chart's CRD lacks removed.
CRD_PROBE="$tmp_dir/crd-probe"
mkdir -p "$CRD_PROBE"
cp -r "$CHART_DIR" "$CRD_PROBE/chart"
mkdir -p "$CRD_PROBE/chart/probe"
cat > "$CRD_PROBE/chart/templates/zz-crd-probe.yaml" <<'EOT'
{{- $crd := dict }}
{{- with .Values.probeCRD }}{{ $crd = $.Files.Get (printf "probe/%s.yaml" .) | fromYaml }}{{ end }}
{{- include "cloudwatch-agent.validate-agent-crd-schema" (dict "crd" $crd "Values" .Values "chartVersion" .Chart.Version) }}
# crd-check: ok
EOT
python3 - "$CHART_DIR/crds/cloudwatch.aws.amazon.com_amazoncloudwatchagents.yaml" "$CRD_PROBE/chart/probe" <<'EOF'
import copy, sys, yaml
base = yaml.safe_load(open(sys.argv[1]))
out = sys.argv[2]
def ta(d):
    v = [x for x in d["spec"]["versions"] if x["name"] == "v1alpha1"][0]
    return v["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["targetAllocator"]["properties"]
def no_per_node(d):
    ta(d)["allocationStrategy"]["enum"] = ["consistent-hashing"]
def no_scraper_role(d):
    del ta(d)["prometheusCR"]["properties"]["scraperRole"]
def flat_selectors(d):
    for k in ("serviceMonitorSelector", "podMonitorSelector"):
        ta(d)["prometheusCR"]["properties"][k] = {"type": "object", "additionalProperties": {"type": "string"}}
cases = {"current": [], "no-per-node": [no_per_node], "no-scraper-role": [no_scraper_role],
         "flat-selectors": [flat_selectors], "old": [no_per_node, no_scraper_role, flat_selectors]}
for name, edits in cases.items():
    d = copy.deepcopy(base)
    for e in edits:
        e(d)
    yaml.safe_dump(d, open("%s/%s.yaml" % (out, name), "w"))
EOF
# crd_probe <probeCRD or ""> <args...> -> the probe's output, or the render error
crd_probe() {
    local crd="$1"; shift
    # shellcheck disable=SC2068
    helm template t "$CRD_PROBE/chart" --set region=us-west-2 --set clusterName=test-cluster \
        ${crd:+--set probeCRD=$crd} --show-only templates/zz-crd-probe.yaml $@ 2>&1
}
expect_crd_ok() {
    local desc="$1"; shift
    local out
    out="$(crd_probe "$@")"
    if printf '%s\n' "$out" | grep -q '^# crd-check: ok$'; then pass "$desc"; else fail "$desc: $(printf '%s' "$out" | head -c 300)"; fi
}
expect_crd_fail() {
    local desc="$1" want="$2"; shift 2
    local out
    if out="$(crd_probe "$@")"; then fail "$desc (render succeeded)"
    elif printf '%s\n' "$out" | grep -qF -- "$want"; then pass "$desc"
    else fail "$desc (wrong error: $(printf '%s' "$out" | head -c 300))"; fi
}
SEL='otelPrometheusMonitor.serviceMonitorSelector={"matchLabels":{"cloudwatch":"true"}}'
expect_crd_ok   "no CRD to read (helm template, offline render) => check skipped" "" $MON
expect_crd_ok   "this chart's CRD => passes" current $MON
expect_crd_ok   "this chart's CRD with a selector => passes" current $MON --set-json "$SEL"
expect_crd_fail "CRD without per-node => fails" "lacks targetAllocator.allocationStrategy per-node." no-per-node $MON
expect_crd_fail "CRD without scraperRole => fails" "lacks targetAllocator.prometheusCR.scraperRole." no-scraper-role $MON
expect_crd_ok   "flat-map selectors, no selector set => passes" flat-selectors $MON
expect_crd_fail "flat-map selectors with serviceMonitorSelector set => fails" "lacks targetAllocator.prometheusCR.serviceMonitorSelector as a label selector." flat-selectors $MON --set-json "$SEL"
expect_crd_fail "older chart's CRD => names everything it lacks" \
    "lacks targetAllocator.allocationStrategy per-node, targetAllocator.prometheusCR.scraperRole." old $MON
expect_crd_fail "older chart's CRD => tells the user how to apply the CRDs" \
    "kubectl apply --server-side --force-conflicts -f amazon-cloudwatch-observability/crds/" old $MON
expect_crd_fail "older chart's CRD => pulls this chart version" \
    "--version $(awk '/^version:/{print $2}' "$CHART_DIR/Chart.yaml") --untar" old $MON

printf "\n${Y}== Summary ==${N}\n"
printf "passed: ${G}%s${N}, failed: ${R}%s${N}\n" "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
