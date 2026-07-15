# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT
#
# Scenario: fluentbit-advanced-config
#
# Deep fluent-bit customization must survive rendering: custom SERVICE
# settings, custom parsers, net-new extraFiles (auto-@INCLUDEd), overridden
# default conf files, and DaemonSet-level overrides (resources with cpu:null,
# priorityClassName, tolerations, updateStrategy).

render || return 0

# ── ConfigMap: custom service + parsers + files ───────────────────────────
cm_doc=$(extract_manifest ConfigMap fluent-bit-config)
if [[ -z "$cm_doc" ]]; then
    fail "fluent-bit-config ConfigMap not found"
else
    pass "fluent-bit-config ConfigMap found"
    # Custom SERVICE settings render verbatim.
    assert_doc_contains "$cm_doc" "scheduler.base            15" "custom SERVICE scheduler.base rendered"
    assert_doc_contains "$cm_doc" "scheduler.cap             300" "custom SERVICE scheduler.cap rendered"
    # Every extraFiles entry is auto-@INCLUDEd and present as a data key.
    assert_doc_contains "$cm_doc" "@INCLUDE custom-routing.conf" "net-new extraFile is @INCLUDEd"
    assert_doc_contains "$cm_doc" "custom-routing.conf: |" "net-new extraFile present in ConfigMap data"
    assert_doc_contains "$cm_doc" "@INCLUDE application-log.conf" "overridden default file still @INCLUDEd"
    assert_doc_contains "$cm_doc" "# disabled by override" "default conf file content replaced by override"
    # Custom parsers land in parsers.conf.
    assert_doc_contains "$cm_doc" "Name                custom_syslog" "customParsers rendered into parsers.conf"
    # Real-world routing constructs survive verbatim.
    assert_doc_contains "$cm_doc" "Emitter_Storage.type filesystem" "rewrite_tag emitter config preserved"
    assert_doc_contains "$cm_doc" "log_retention_days  3653" "log retention setting preserved"
    assert_doc_contains "$cm_doc" "Add                 cluster_id test-cluster-id" "modify filter enrichment preserved"
    # The default application-log pipeline must be gone (overridden away).
    assert_doc_not_contains "$cm_doc" "Kube_Tag_Prefix" "default application-log kubernetes filter removed by override"
fi

# ── DaemonSet: workload-level overrides ───────────────────────────────────
fb_doc=$(extract_manifest DaemonSet fluent-bit)
if [[ -z "$fb_doc" ]]; then
    fail "fluent-bit DaemonSet not found"
else
    pass "fluent-bit DaemonSet found"
    assert_doc_not_contains "$fb_doc" "cpu: null" "cpu:null did not leak as literal null"
    assert_doc_not_contains "$fb_doc" "cpu: 500m" "default cpu limit removed via cpu:null"
    assert_doc_contains "$fb_doc" "memory: 500Mi" "overridden memory limit applied"
    assert_doc_contains "$fb_doc" "cpu: 400m" "overridden cpu request applied"
    assert_doc_contains "$fb_doc" "priorityClassName: system-node-critical" "priorityClassName propagated"
    assert_doc_contains "$fb_doc" "operator: Exists" "blanket toleration propagated"
    assert_doc_contains "$fb_doc" "maxUnavailable: 5%" "updateStrategy rollingUpdate propagated"
fi
