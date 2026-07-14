# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT
#
# Scenario: null-resource-limits
#
# `cpu: null` on map-typed keys must DELETE the default CPU limit — not fall
# back to the default and not render a CRD-invalid literal `cpu: null`.

render || return 0

# No literal null anywhere in the render — a literal `cpu: null` is rejected
# by the AmazonCloudWatchAgent CRD (quantity must be integer or string).
assert_not_contains "cpu: null" "no literal 'cpu: null' anywhere in the rendered output"

# ── cloudwatch-agent CR: default cpu limit (500m) removed, memory kept ────
agent_doc=$(extract_manifest AmazonCloudWatchAgent cloudwatch-agent)
if [[ -z "$agent_doc" ]]; then
    fail "cloudwatch-agent AmazonCloudWatchAgent CR not found in render"
else
    pass "cloudwatch-agent AmazonCloudWatchAgent CR found"
    assert_doc_not_contains "$agent_doc" "cpu: 500m" \
        "agent CR: default 500m cpu limit removed"
    assert_doc_contains "$agent_doc" "memory: 512Mi" \
        "agent CR: default memory limit preserved"
    assert_doc_contains "$agent_doc" "cpu: 250m" \
        "agent CR: default cpu request untouched"
fi

# ── fluent-bit DaemonSet: cpu limit removed, overridden values applied ────
fb_doc=$(extract_manifest DaemonSet fluent-bit)
if [[ -z "$fb_doc" ]]; then
    fail "fluent-bit DaemonSet not found in render"
else
    pass "fluent-bit DaemonSet found"
    assert_doc_not_contains "$fb_doc" "cpu: 500m" \
        "fluent-bit: default 500m cpu limit removed"
    assert_doc_contains "$fb_doc" "memory: 512Mi" \
        "fluent-bit: overridden memory limit applied"
    assert_doc_contains "$fb_doc" "cpu: 400m" \
        "fluent-bit: overridden cpu request applied"
fi

# ── TODO(PR #334): null inside agents[] array entries ─────────────────────
# Nulls inside `agents[]` entries do not go through Helm's values coalescing
# (arrays are replaced wholesale), so they currently render as literal
# `cpu: null` in the CR. Once aws-observability/helm-charts#334 merges,
# enable this to lock in the fixed behavior:
#
# render --set-json 'agents=[{"name":"cloudwatch-agent","resources":{"limits":{"cpu":null,"memory":"3Gi"},"requests":{"cpu":"250m","memory":"2Gi"}}}]'
# assert_not_contains "cpu: null" "agents[] entry cpu:null removes the limit (PR #334)"
# assert_contains "memory: 3Gi" "agents[] entry memory limit applied"
