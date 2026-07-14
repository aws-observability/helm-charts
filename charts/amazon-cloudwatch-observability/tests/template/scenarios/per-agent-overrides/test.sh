# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT
#
# Scenario: per-agent-overrides
#
# Every supported per-agent override in an agents[] entry must propagate
# into that agent's AmazonCloudWatchAgent CR, merged over the shared
# top-level `agent` defaults: env vars, resources, scheduling controls
# (priorityClassName, tolerations, affinity), rollout tuning
# (updateStrategy), workload mode/replicas, and per-agent config.

render || return 0

# ── node agent (daemonset) ────────────────────────────────────────────────
node_doc=$(extract_manifest AmazonCloudWatchAgent cloudwatch-agent)
if [[ -z "$node_doc" ]]; then
    fail "cloudwatch-agent CR not found"
else
    pass "cloudwatch-agent CR found"
    assert_doc_contains "$node_doc" "mode: daemonset" "node agent: default daemonset mode"
    assert_doc_contains "$node_doc" "value: CI_NODE" "node agent: CWAGENT_ROLE env var propagated"
    assert_doc_contains "$node_doc" "memory: 3Gi" "node agent: overridden memory limit applied"
    assert_doc_contains "$node_doc" "cpu: 500m" "node agent: default cpu limit preserved by merge"
    assert_doc_contains "$node_doc" "memory: 2Gi" "node agent: overridden memory request applied"
    assert_doc_contains "$node_doc" "priorityClassName: system-node-critical" "node agent: priorityClassName propagated"
    assert_doc_contains "$node_doc" "operator: Exists" "node agent: blanket toleration propagated"
    assert_doc_contains "$node_doc" "maxUnavailable: 5%" "node agent: updateStrategy rollingUpdate propagated"
    assert_doc_contains "$node_doc" "enhanced_container_insights" "node agent: per-agent config merged into rendered config"
fi

# ── leader agent (deployment) ─────────────────────────────────────────────
leader_doc=$(extract_manifest AmazonCloudWatchAgent cloudwatch-agent-leader)
if [[ -z "$leader_doc" ]]; then
    fail "cloudwatch-agent-leader CR not found"
else
    pass "cloudwatch-agent-leader CR found"
    assert_doc_contains "$leader_doc" "mode: deployment" "leader: deployment mode override applied"
    assert_doc_contains "$leader_doc" "replicas: 2" "leader: replicas override applied"
    assert_doc_contains "$leader_doc" "value: CI_LEADER" "leader: CWAGENT_ROLE env var propagated"
    assert_doc_contains "$leader_doc" "memory: 2Gi" "leader: overridden memory limit applied"
    assert_doc_contains "$leader_doc" "cpu: 50m" "leader: overridden cpu request applied"
    assert_doc_contains "$leader_doc" "key: workload-tier" "leader: custom nodeAffinity propagated"
    assert_doc_contains "$leader_doc" "priorityClassName: system-node-critical" "leader: priorityClassName propagated"
    assert_doc_contains "$leader_doc" "enhanced_container_insights" "leader: per-agent config merged into rendered config"
fi

# The two agents must not bleed into each other: exactly one CI_NODE and one
# CI_LEADER in the whole render, and the node agent must not carry the
# leader's custom affinity.
assert_line_count "value: CI_NODE" 1 "exactly one agent carries CI_NODE"
assert_line_count "value: CI_LEADER" 1 "exactly one agent carries CI_LEADER"
if [[ -n "$node_doc" ]]; then
    assert_doc_not_contains "$node_doc" "workload-tier" "node agent: leader's affinity did not leak across agents"
fi
