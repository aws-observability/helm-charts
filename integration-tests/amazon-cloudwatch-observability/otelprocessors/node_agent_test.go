// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package otelprocessors

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestNodeAgentProcessors runs processors from the node agent's config
// through the chart's CloudWatch Agent image and checks what they produce.
func TestNodeAgentProcessors(t *testing.T) {
	node := Render(t, "cloudwatch-agent", nil)

	workloads := []struct {
		metric   string
		resource map[string]string
		name     string
		kind     string
	}{
		{"deployment", map[string]string{"k8s.deployment.name": "web", "k8s.replicaset.name": "web-5d8f"}, "web", "Deployment"},
		{"statefulset", map[string]string{"k8s.statefulset.name": "db"}, "db", "StatefulSet"},
		{"daemonset", map[string]string{"k8s.daemonset.name": "agent"}, "agent", "DaemonSet"},
		{"job", map[string]string{"k8s.job.name": "migrate"}, "migrate", "Job"},
		{"cronjob", map[string]string{"k8s.cronjob.name": "nightly"}, "nightly", "CronJob"},
		{"replicaset", map[string]string{"k8s.replicaset.name": "bare-7c9d"}, "bare-7c9d", "ReplicaSet"},
		{"none", map[string]string{"k8s.pod.name": "standalone"}, "", ""},
	}
	var workloadInputs []Input
	for _, w := range workloads {
		workloadInputs = append(workloadInputs, Metrics(w.resource, nil, w.metric))
	}

	units := map[string]string{
		"container_cpu_usage_seconds_total": "s",
		"container_memory_usage_bytes":      "By",
		"container_network_bytes_total":     "By",
		"kube_pod_restarts_total":           "1",
		"node_cpu_ratio":                    "1",
		"node_hwmon_temp_celsius":           "Cel",
		"DCGM_FI_DEV_FB_USED":               "MiBy",
		"node_load1":                        "",
	}
	var unitNames []string
	for name := range units {
		unitNames = append(unitNames, name)
	}

	out := Run(t, node.Image, []Case{
		{
			Name:       "workload",
			Processors: node.Processors(t, "transform/cw_k8s_ci_v0_set_workload"),
			Inputs:     workloadInputs,
		},
		{
			Name:       "unit",
			Processors: node.Processors(t, "transform/cw_k8s_ci_v0_set_unit"),
			Inputs:     []Input{Metrics(nil, nil, unitNames...)},
		},
		{
			Name:       "cadvisor aggregates dropped",
			Processors: node.Processors(t, "filter/cw_k8s_ci_v0_cadvisor_empty"),
			Inputs: []Input{
				Metrics(nil, map[string]string{"container": "", "pod": ""}, "empty_container_empty_pod"),
				Metrics(nil, map[string]string{"container": ""}, "empty_container_no_pod"),
				Metrics(nil, map[string]string{"pod": ""}, "no_container_empty_pod"),
				Metrics(nil, nil, "no_container_no_pod"),
				Metrics(nil, map[string]string{"container": "", "pod": "web-1"}, "pod_only"),
				Metrics(nil, map[string]string{"container": "nginx", "pod": "web-1"}, "container"),
			},
		},
		{
			Name:       "default label removals",
			Processors: node.Processors(t, "awsattributelimit/cw_k8s_ci_v0"),
			Inputs: []Input{Metrics(map[string]string{
				"k8s.node.label.feature.node.kubernetes.io/cpu-model.vendor_id": "Intel",
				"k8s.node.label.topology.kubernetes.io/zone":                    "us-west-2a",
				"k8s.pod.label.pod-template-hash":                               "abc123",
				"k8s.node.label.app":                                            "web",
				"k8s.pod.label.team":                                            "payments",
			}, nil, "container_cpu_usage_seconds_total")},
		},
		{
			Name:       "log workload",
			Processors: node.Processors(t, "transform/cw_k8s_ci_v0_logs_set_workload"),
			Inputs: []Input{Logs(map[string]string{
				"k8s.deployment.name": "web",
				"k8s.replicaset.name": "web-5d8f",
			}, "hello")},
		},
	})

	got := map[string]Metric{}
	for _, m := range out["workload"].Metrics {
		got[m.Name] = m
	}
	for _, w := range workloads {
		if assert.Contains(t, got, w.metric) {
			assert.Equal(t, w.name, got[w.metric].Resource["k8s.workload.name"], "%s workload name", w.metric)
			assert.Equal(t, w.kind, got[w.metric].Resource["k8s.workload.type"], "%s workload type", w.metric)
		}
	}

	gotUnits := map[string]string{}
	for _, m := range out["unit"].Metrics {
		gotUnits[m.Name] = m.Unit
	}
	assert.Equal(t, units, gotUnits)

	assert.ElementsMatch(t, []string{"pod_only", "container"}, out["cadvisor aggregates dropped"].MetricNames())

	removals := out["default label removals"]
	if assert.Len(t, removals.Metrics, 1) {
		resource := removals.Metrics[0].Resource
		assert.NotContains(t, resource, "k8s.node.label.feature.node.kubernetes.io/cpu-model.vendor_id")
		assert.NotContains(t, resource, "k8s.node.label.topology.kubernetes.io/zone")
		assert.NotContains(t, resource, "k8s.pod.label.pod-template-hash")
		assert.Equal(t, "web", resource["k8s.node.label.app"])
		assert.Equal(t, "payments", resource["k8s.pod.label.team"])
	}

	logs := out["log workload"]
	if assert.Len(t, logs.Logs, 1) {
		assert.Equal(t, "hello", logs.Logs[0].Body)
		assert.Equal(t, "web", logs.Logs[0].Resource["k8s.workload.name"])
		assert.Equal(t, "Deployment", logs.Logs[0].Resource["k8s.workload.type"])
	}
}
