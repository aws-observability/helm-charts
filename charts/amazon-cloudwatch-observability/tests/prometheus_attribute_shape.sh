#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins six attribute invariants across the Prometheus-receiver pipelines of the
# OTEL Container Insights configs, for both agents:
#
#   1. Every pipeline with a prometheus/ receiver runs
#      transform/cw_k8s_ci_v0_drop_deprecated_semconv, which deletes the
#      receiver-injected net.host.name, net.host.port and http.scheme.
#   2. Nothing removes the current-spelling twins url.scheme, server.address or
#      server.port: no OTTL delete_key or delete_matching_keys, no resource-scope
#      keep_keys or keep_matching_keys, no awsattributelimit unconditional key or
#      prefix, and no attributes or resource processor delete action.
#   3. Any transform that copies a raw Prometheus label from resource scope back
#      down to datapoint scope removes the resource copy in a later resource block.
#   4. Every key a groupbyattrs processor promotes to resource scope, other than
#      k8s.*, is removed at resource scope by a later transform of the same
#      pipeline, after any copy-back of that key within that transform.
#   5. No awsattributelimit unconditional key or prefix covers a NEVER_DENY key or
#      prefix; unconditional removal does not consult the processor's protected keys.
#   6. The two agents' awsattributelimit/cw_k8s_ci_v0 denylists are identical,
#      apart from the entries in DENYLIST_ALLOWED_DIFFERENCES.
#
# The checks discover pipelines and transforms from the rendered config rather
# than naming them, so a newly added solution is covered without editing this
# file. Promote transforms are typically copied from an existing solution, and a
# copy repeats whatever the original did. An agent whose discovery finds no
# Prometheus pipeline, copy-back transform or groupbyattrs stage fails, and so
# does any metric OTTL statement the parser cannot model.
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text.
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/prometheus_attribute_shape.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

render() {
    local out="$1"; shift
    "$HELM" template "$CHART_DIR" \
        --set region=us-west-2 \
        --set clusterName=test-cluster \
        --set otelContainerInsights.enabled=true \
        "$@" > "$out"
}

# Defaults turn on every solution and both accelerator exporters, so the first
# render holds every Prometheus pipeline the chart can produce.
render "${TMP_DIR}/eks.yaml"
render "${TMP_DIR}/aks.yaml" --set k8sMode=AKS --set roleArn=arn:aws:iam::123456789012:role/test
render "${TMP_DIR}/no-solutions.yaml" \
    --set otelContainerInsights.solutions.enabled=false \
    --set dcgmExporter.enabled=false --set neuronMonitor.enabled=false

python3 - "${TMP_DIR}" <<'PY'
import json
import os
import re
import sys
from collections import namedtuple

import yaml

GREEN, RED, YELLOW, RESET = "\033[0;32m", "\033[0;31m", "\033[1;33m", "\033[0m"
passed = failed = 0

AGENTS = ("cloudwatch-agent", "cloudwatch-agent-cluster-scraper")
SEMCONV = "transform/cw_k8s_ci_v0_drop_deprecated_semconv"
DENYLIST = "awsattributelimit/cw_k8s_ci_v0"
DENYLIST_FIELDS = ("max_total_attributes", "unconditional_removal_keys", "unconditional_removal_prefixes")
DEPRECATED = ["net.host.name", "net.host.port", "http.scheme"]
CURRENT = ["url.scheme", "server.address", "server.port"]

# Kept in step with the never-denied list of the amazon-cloudwatch-agent-test repository (util/otelmetrics).
# Keyed by agent, "all" for both; an entry ending in * is a prefix.
NEVER_DENY = {
    "all": [
        # protectedResourceKeys and protectedPrefixes of the awsattributelimit processor;
        # unconditional removal runs before that protection, so a denylist entry would override it.
        "k8s.cluster.name", "k8s.node.name", "k8s.pod.name", "k8s.pod.uid", "k8s.namespace.name",
        "k8s.container.name", "k8s.deployment.name", "k8s.statefulset.name", "k8s.daemonset.name",
        "k8s.replicaset.name", "k8s.job.name", "k8s.cronjob.name", "k8s.workload.name",
        "k8s.workload.type", "neurondevice", "neuroncore", "efa.device", "aws.efa.eni.id",
        "volume_id", "instance_id", "k8s.pod.label.app.kubernetes.io/name",
        "k8s.pod.label.app.kubernetes.io/instance", "k8s.pod.label.app.kubernetes.io/component",
        "k8s.component.name", "cloud.*", "host.*", "hw.*",
        # Kept on purpose inside a label domain the denylist partly removes, so widening an entry to the domain fails.
        "k8s.node.label.kubernetes.io/os", "k8s.node.label.kubernetes.io/arch",
        "k8s.node.label.eks.amazonaws.com/nodegroup", "k8s.node.label.eks.amazonaws.com/capacityType",
        "k8s.node.label.karpenter.sh/nodepool", "k8s.node.label.karpenter.sh/capacity-type",
        "k8s.node.label.karpenter.k8s.aws/ec2nodeclass",
    ],
}

# Entries only one agent's DENYLIST may carry, as {agent: {field: {entry, ...}}}.
# Empty: both agents deny exactly the same attributes.
DENYLIST_ALLOWED_DIFFERENCES = {}

# OTTL string literal (pkg/ottl/grammar.go lexer), and an attributes path, optionally context-qualified and indexed.
STRING = re.compile(r'"(?:\\.|[^\\"])*"')
ATTR_PATH = re.compile(rf'(?:(resource|datapoint|scope)\s*\.\s*)?attributes(?:\s*\[\s*({STRING.pattern})\s*\])?')
KEY_LIST = re.compile(rf'\[\s*(?:{STRING.pattern}\s*(?:,\s*{STRING.pattern}\s*)*)?\]')
EDITOR_CALL = re.compile(r'\s*([a-z][a-z0-9_]*)\s*\(')
# Editors that remove map keys, and editors that never do; any other editor fails parsing.
REMOVERS = {"delete_key", "delete_matching_keys", "keep_keys", "keep_matching_keys"}
WRITERS = {"set", "append", "merge_maps", "replace_match", "replace_pattern", "replace_all_matches", "truncate_all"}

# A parsed statement: its context, the scope of the map it removes keys from (None if it removes
# none) with the key, pattern or kept keys it names, and the key it copies from resource to datapoint.
Stmt = namedtuple("Stmt", "text ctx editor target arg copied")


def check(desc, ok):
    global passed, failed
    if ok:
        print(f"  {GREEN}PASS{RESET}: {desc}")
        passed += 1
    else:
        print(f"  {RED}FAIL{RESET}: {desc}")
        failed += 1
    return ok


def detail(label, items):
    return f" ({label}: {'; '.join(items)})" if items else ""


def ptype(component_id):
    return component_id.split("/", 1)[0]


def otel_configs(path):
    """otelConfig of every AmazonCloudWatchAgent CR that has one, parsed."""
    out = {}
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if (doc or {}).get("kind") != "AmazonCloudWatchAgent":
                continue
            cfg = yaml.safe_load((doc.get("spec") or {}).get("otelConfig") or "{}") or {}
            if (cfg.get("service") or {}).get("pipelines"):
                out[doc["metadata"]["name"]] = cfg
    return out


def split_call(text):
    """Editor name, top-level arguments and trailing text of an OTTL editor invocation."""
    m = EDITOR_CALL.match(text)
    if not m:
        raise ValueError("not an editor invocation")
    args, depth, start, i = [], 0, m.end(), m.end()
    while i < len(text):
        c = text[i]
        if c == '"':
            s = STRING.match(text, i)
            if not s:
                raise ValueError("unterminated string")
            i = s.end()
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth:
                depth -= 1
            elif c == ")":
                args.append(text[start:i].strip())
                return m.group(1), args, text[i + 1:]
            else:
                raise ValueError(f"unbalanced {c}")
        elif c == "," and not depth:
            args.append(text[start:i].strip())
            start = i + 1
        i += 1
    raise ValueError("unbalanced parentheses")


def unquote(literal):
    """Value of an OTTL string literal; JSON escapes cover the Go escapes configs use, others fail parsing."""
    return json.loads(literal)


def attr_path(arg, ctx):
    """(scope, key) of an attributes path, key None for the whole map; None if arg is not one."""
    m = ATTR_PATH.fullmatch(arg)
    return m and (m.group(1) or ctx, m.group(2) and unquote(m.group(2)))


def parse(text, ctx):
    """Stmt for one OTTL statement; raises ValueError for anything the checks cannot model."""
    editor, args, rest = split_call(text)
    if not re.fullmatch(r"\s*(where\b.*)?", rest, re.S):
        raise ValueError(f"unexpected text after the call: {rest.strip()}")
    call = text[:len(text) - len(rest)].strip()
    target = attr_path(args[0], ctx) if args else None
    if editor in WRITERS:
        if editor == "set" and target and target[1] is None:
            raise ValueError("set replaces a whole attribute map")
        source = attr_path(args[1], ctx) if editor == "set" and len(args) == 2 else None
        copied = None
        if target and source and (target[0], source[0]) == ("datapoint", "resource") and target[1] == source[1]:
            copied = target[1]
        return Stmt(call, ctx, editor, None, None, copied)
    if editor not in REMOVERS:
        raise ValueError(f"{editor} is not modelled")
    if len(args) != 2 or not target or target[1] is not None:
        raise ValueError(f"{editor} expects an attribute map and one more argument")
    if editor == "keep_keys":
        if not KEY_LIST.fullmatch(args[1]):
            raise ValueError("keep_keys expects a list of string literals")
        return Stmt(call, ctx, editor, target[0], [unquote(s) for s in STRING.findall(args[1])], None)
    if not STRING.fullmatch(args[1]):
        raise ValueError(f"{editor} expects a string literal")
    arg = unquote(args[1])
    if editor != "delete_key":
        re.compile(arg)
    return Stmt(call, ctx, editor, target[0], arg, None)


def ottl_blocks(processors):
    """{processor: [(context, [Stmt, ...]), ...]} over every metric_statements group, plus parse errors."""
    parsed, errors = {}, []
    for pn, pv in sorted(processors.items()):
        groups = pv.get("metric_statements") if isinstance(pv, dict) else None
        if not groups:
            continue
        parsed[pn] = []
        for g in groups:
            ctx = g.get("context") if isinstance(g, dict) else None
            if not ctx:
                errors.append(f"{pn}: statement group without a context: {g}")
                continue
            stmts = []
            for s in g.get("statements") or []:
                try:
                    stmts.append(parse(s, ctx))
                except (ValueError, re.error) as e:
                    errors.append(f"{pn}: {e}: {s}")
            parsed[pn].append((ctx, stmts))
    return parsed, errors


def removes(st, key):
    if st.editor == "delete_key":
        return key == st.arg
    if st.editor == "delete_matching_keys":
        return re.search(st.arg, key) is not None
    if st.editor == "keep_keys":
        return key not in st.arg
    if st.editor == "keep_matching_keys":
        return re.search(st.arg, key) is None
    return False


def at_resource(st):
    """True if st runs once per resource and removes resource attributes."""
    return st.ctx == "resource" and st.target == "resource"


def removed_after_copy_back(blocks, key):
    """True if a resource-scope statement removes key in a group after any group copying key back."""
    last_copy = max((i for i, (_, ss) in enumerate(blocks) for st in ss if st.copied == key), default=-1)
    return any(at_resource(st) and removes(st, key) for _, ss in blocks[last_copy + 1:] for st in ss)


def current_key_removals(processors, ottl):
    """Every way a processor removes a CURRENT key."""
    out = set()
    for pn, blocks in ottl.items():
        for _, ss in blocks:
            for st in ss:
                # delete_* at any scope; keep_* only where it drops resource attributes.
                if st.target and (st.editor.startswith("delete_") or st.target == "resource"):
                    out |= {f"{pn}: {st.text} removes {k}" for k in CURRENT if removes(st, k)}
    for pn, pv in processors.items():
        pv = pv or {}
        if ptype(pn) == "awsattributelimit":
            out |= {f"{pn}: unconditional key {k}"
                    for k in pv.get("unconditional_removal_keys") or [] if k in CURRENT}
            out |= {f"{pn}: unconditional prefix {p} removes {k}"
                    for p in pv.get("unconditional_removal_prefixes") or [] for k in CURRENT if k.startswith(p)}
        elif ptype(pn) in ("attributes", "resource"):
            for a in (pv.get("actions") or []) + (pv.get("attributes") or []):
                if a.get("action") == "delete":
                    out |= {f"{pn}: delete action removes {k}" for k in CURRENT
                            if a.get("key") == k or (a.get("pattern") and re.search(a["pattern"], k))}
    return sorted(out)


def never_deny(agent):
    """(keys, prefixes) that no denylist of agent may remove."""
    entries = NEVER_DENY["all"] + NEVER_DENY.get(agent, [])
    return [e for e in entries if not e.endswith("*")], [e[:-1] for e in entries if e.endswith("*")]


def check_config(agent, cfg):
    processors = cfg.get("processors") or {}
    pipelines = (cfg.get("service") or {}).get("pipelines") or {}
    prom = {n: p for n, p in pipelines.items()
            if any(ptype(r) == "prometheus" for r in p.get("receivers") or [])}
    ottl, errors = ottl_blocks(processors)
    check(f"{agent}: discovers {len(prom)} Prometheus pipelines", len(prom) > 0)
    check(f"{agent}: every metric OTTL statement parses into a form these checks model" + detail("found", errors),
          not errors)

    # 1. the shared processor exists, deletes exactly the deprecated keys, and every
    #    Prometheus pipeline runs it.
    removals = [st for _, ss in ottl.get(SEMCONV, []) for st in ss if st.target]
    check(f"{agent}: {SEMCONV} deletes {', '.join(DEPRECATED)} at resource scope",
          all(at_resource(st) and st.editor == "delete_key" for st in removals)
          and sorted(st.arg for st in removals) == sorted(DEPRECATED))
    for name, p in sorted(prom.items()):
        check(f"{agent}: {name} runs {SEMCONV}", SEMCONV in (p.get("processors") or []))

    # 2. nothing removes a current-spelling attribute.
    offenders = current_key_removals(processors, ottl)
    check(f"{agent}: no processor removes {', '.join(CURRENT)}" + detail("found", offenders), not offenders)

    # 3. every copy-back is followed by a resource-scope removal of the same key.
    copy_back_transforms = 0
    for pn, blocks in sorted(ottl.items()):
        for i, (_, ss) in enumerate(blocks):
            copied = [st.copied for st in ss if st.copied]
            if not copied:
                continue
            copy_back_transforms += 1
            later = [st for _, ls in blocks[i + 1:] for st in ls if at_resource(st)]
            missing = [k for k in copied if not any(removes(st, k) for st in later)]
            check(f"{agent}: {pn} deletes the resource copy of every key it copies back"
                  + detail("missing", missing), not missing)
    check(f"{agent}: finds {copy_back_transforms} copy-back transforms", copy_back_transforms > 0)

    # 4. every raw key a groupbyattrs stage promotes is removed at resource scope later on.
    groupbyattrs_stages = 0
    for name, p in sorted(prom.items()):
        procs = p.get("processors") or []
        for i, gn in enumerate(procs):
            if ptype(gn) != "groupbyattrs":
                continue
            groupbyattrs_stages += 1
            raw = [k for k in (processors.get(gn) or {}).get("keys") or [] if not k.startswith("k8s.")]
            missing = [k for k in raw
                       if not any(removed_after_copy_back(ottl.get(later, []), k) for later in procs[i + 1:])]
            check(f"{agent}: {name} removes every raw key {gn} promotes at resource scope"
                  + detail("missing", missing), not missing)
    check(f"{agent}: finds {groupbyattrs_stages} groupbyattrs stages in Prometheus pipelines",
          groupbyattrs_stages > 0)

    # 5. no denylist entry covers a never-deny key or prefix.
    keys, prefixes = never_deny(agent)
    for pn, pv in sorted(processors.items()):
        if ptype(pn) != "awsattributelimit":
            continue
        deny_keys = (pv or {}).get("unconditional_removal_keys") or []
        deny_prefixes = (pv or {}).get("unconditional_removal_prefixes") or []
        hits = sorted({f"key {k}" for k in deny_keys if k in keys}
                      | {f"prefix {d} covers {k}" for d in deny_prefixes for k in keys if k.startswith(d)}
                      | {f"key {k} is under {p}" for k in deny_keys for p in prefixes if k.startswith(p)}
                      | {f"prefix {d} overlaps {p}" for d in deny_prefixes for p in prefixes
                         if p.startswith(d) or d.startswith(p)})
        check(f"{agent}: {pn} denies no never-deny key or prefix" + detail("found", hits), not hits)


def as_set(value):
    return set(value) if isinstance(value, list) else {value}


def check_denylists_match(configs):
    """6. both agents' DENYLIST copies are equal, apart from DENYLIST_ALLOWED_DIFFERENCES."""
    copies = {a: ((configs.get(a) or {}).get("processors") or {}).get(DENYLIST) for a in AGENTS}
    if not check(f"both agents define {DENYLIST}", all(copies.values())):
        return
    for field in DENYLIST_FIELDS:
        entries = {a: as_set(copies[a].get(field)) for a in AGENTS}
        diff = [f"only {a}: {e}"
                for a, b in (AGENTS, AGENTS[::-1])
                for e in sorted(entries[a] - entries[b]
                                - DENYLIST_ALLOWED_DIFFERENCES.get(a, {}).get(field, set()), key=str)]
        check(f"{DENYLIST} {field} is the same on both agents" + detail("differs", diff), not diff)


for render in ("eks", "aks", "no-solutions"):
    print(f"\n{YELLOW}[{render}]{RESET}")
    configs = otel_configs(os.path.join(sys.argv[1], f"{render}.yaml"))
    check("both agents render an otelConfig", set(AGENTS) <= set(configs))
    for agent, cfg in sorted(configs.items()):
        check_config(agent, cfg)
    check_denylists_match(configs)

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
