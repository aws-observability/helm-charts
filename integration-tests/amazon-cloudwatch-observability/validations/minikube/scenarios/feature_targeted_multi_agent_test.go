// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func TestFeatureTargetedMultiAgent(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	if !assert.NoError(t, err) {
		t.Fatal("failed to create k8s client")
	}

	// Validate namespace exists
	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

	// Get all AmazonCloudWatchAgent CRs
	dynamicClient, err := k8sClient.GetDynamicClient()
	if !assert.NoError(t, err) {
		t.Fatal("failed to get dynamic client")
	}

	gvr := schema.GroupVersionResource{
		Group:    "cloudwatch.aws.amazon.com",
		Version:  "v1alpha1",
		Resource: "amazoncloudwatchagents",
	}

	agentList, err := dynamicClient.Resource(gvr).Namespace(minikube.Namespace).List(
		context.Background(), metav1.ListOptions{},
	)
	if !assert.NoError(t, err) {
		t.Fatal("failed to list AmazonCloudWatchAgent CRs")
	}

	// Build a map of CR name -> CR for easy lookup
	agentMap := make(map[string]unstructured.Unstructured)
	for _, agent := range agentList.Items {
		agentMap[agent.GetName()] = agent
	}

	// Verify all three CRs exist
	assert.GreaterOrEqual(t, len(agentMap), 3, "should have at least 3 agent CRs (cloudwatch-agent, prometheus-agent, cluster-scraper)")
	assert.Contains(t, agentMap, "cloudwatch-agent", "cloudwatch-agent CR should exist")
	assert.Contains(t, agentMap, "prometheus-agent", "prometheus-agent CR should exist")
	assert.Contains(t, agentMap, "cloudwatch-agent-cluster-scraper", "cluster-scraper CR should exist")

	t.Run("CloudWatchAgentFullConfig", func(t *testing.T) {
		validateCloudWatchAgentFullConfig(t, agentMap)
	})

	t.Run("PrometheusAgentMinimalConfig", func(t *testing.T) {
		validatePrometheusAgentMinimalConfig(t, agentMap)
	})

	t.Run("ClusterScraperClusterConfig", func(t *testing.T) {
		validateClusterScraperConfig(t, agentMap)
	})

	t.Log("Feature targeted multi-agent scenario validation passed")
}

// validateCloudWatchAgentFullConfig verifies cloudwatch-agent gets full config:
// Container Insights + Application Signals in CW Agent config, and node-level OTEL CI pipelines.
func validateCloudWatchAgentFullConfig(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["cloudwatch-agent"]
	if !assert.True(t, exists, "cloudwatch-agent CR should exist") {
		return
	}

	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return
	}

	// Verify hostNetwork is true (default for all agents)
	hostNetwork, ok := spec["hostNetwork"].(bool)
	assert.True(t, ok, "hostNetwork should be a bool")
	assert.True(t, hostNetwork, "cloudwatch-agent should have hostNetwork=true")

	// Validate CW Agent config contains CI and AppSignals
	configStr, ok := spec["config"].(string)
	if !assert.True(t, ok, "config should be a string") {
		return
	}

	var config map[string]interface{}
	err := json.Unmarshal([]byte(configStr), &config)
	if !assert.NoError(t, err, "config should be valid JSON") {
		return
	}

	// Should have logs.metrics_collected.kubernetes (Container Insights)
	logs, ok := config["logs"].(map[string]interface{})
	assert.True(t, ok, "config should have logs section")
	if ok {
		metricsCollected, ok := logs["metrics_collected"].(map[string]interface{})
		assert.True(t, ok, "logs should have metrics_collected section")
		if ok {
			_, hasKubernetes := metricsCollected["kubernetes"]
			assert.True(t, hasKubernetes, "cloudwatch-agent should have kubernetes (Container Insights) config")

			_, hasAppSignals := metricsCollected["application_signals"]
			assert.True(t, hasAppSignals, "cloudwatch-agent should have application_signals in logs.metrics_collected")
		}
	}

	// Should have traces.traces_collected.application_signals (AppSignals)
	traces, ok := config["traces"].(map[string]interface{})
	assert.True(t, ok, "config should have traces section")
	if ok {
		tracesCollected, ok := traces["traces_collected"].(map[string]interface{})
		assert.True(t, ok, "traces should have traces_collected section")
		if ok {
			_, hasAppSignals := tracesCollected["application_signals"]
			assert.True(t, hasAppSignals, "cloudwatch-agent should have application_signals in traces.traces_collected")
		}
	}

	// Validate OTEL config has node-level pipelines
	otelConfig, ok := spec["otelConfig"].(string)
	if !assert.True(t, ok, "otelConfig should be a string") {
		return
	}

	assert.True(t, strings.Contains(otelConfig, "kubeletstats"),
		"cloudwatch-agent otelConfig should contain kubeletstats receiver (node-level)")
	assert.True(t, strings.Contains(otelConfig, "cw_k8s_ci_v0_kubelet"),
		"cloudwatch-agent otelConfig should contain kubelet receiver (node-level)")
	assert.False(t, strings.Contains(otelConfig, "cw_k8s_ci_v0_apiserver"),
		"cloudwatch-agent otelConfig should NOT contain apiserver receiver (cluster-level)")
	assert.False(t, strings.Contains(otelConfig, "k8s_events"),
		"cloudwatch-agent otelConfig should NOT contain k8s_events receiver (cluster-level)")
}

// validatePrometheusAgentMinimalConfig verifies prometheus-agent gets minimal config:
// only region in CW Agent config (no CI, no AppSignals), and health-check-only OTEL config.
func validatePrometheusAgentMinimalConfig(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["prometheus-agent"]
	if !assert.True(t, exists, "prometheus-agent CR should exist") {
		return
	}

	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return
	}

	// Verify hostNetwork is false (explicitly overridden in values.yaml)
	hostNetwork, ok := spec["hostNetwork"].(bool)
	assert.True(t, ok, "hostNetwork should be a bool")
	assert.False(t, hostNetwork, "prometheus-agent should have hostNetwork=false (explicit override)")

	// Validate CW Agent config is minimal (only region, no CI or AppSignals)
	configStr, ok := spec["config"].(string)
	if !assert.True(t, ok, "config should be a string") {
		return
	}

	var config map[string]interface{}
	err := json.Unmarshal([]byte(configStr), &config)
	if !assert.NoError(t, err, "config should be valid JSON") {
		return
	}

	// Should have agent.region
	agentSection, ok := config["agent"].(map[string]interface{})
	assert.True(t, ok, "config should have agent section")
	if ok {
		_, hasRegion := agentSection["region"]
		assert.True(t, hasRegion, "prometheus-agent config should have agent.region")
	}

	// Should NOT have logs section (no CI, no AppSignals)
	_, hasLogs := config["logs"]
	assert.False(t, hasLogs, "prometheus-agent config should NOT have logs section")

	// Should NOT have traces section (no AppSignals)
	_, hasTraces := config["traces"]
	assert.False(t, hasTraces, "prometheus-agent config should NOT have traces section")

	// Validate OTEL config is absent or empty (not targeted by any OTEL CI feature)
	otelConfig, ok := spec["otelConfig"].(string)
	if ok {
		assert.False(t, strings.Contains(otelConfig, "kubeletstats"),
			"prometheus-agent otelConfig should NOT contain kubeletstats receiver")
		assert.False(t, strings.Contains(otelConfig, "cw_k8s_ci_v0_kubelet"),
			"prometheus-agent otelConfig should NOT contain kubelet receiver")
		assert.False(t, strings.Contains(otelConfig, "cw_k8s_ci_v0_apiserver"),
			"prometheus-agent otelConfig should NOT contain apiserver receiver")
		assert.False(t, strings.Contains(otelConfig, "cw_k8s_ci_v0_kube_state_metrics"),
			"prometheus-agent otelConfig should NOT contain kube_state_metrics receiver")
	}
	// otelConfig may be absent entirely when no OTEL CI features target this agent — that's valid
}

// validateClusterScraperConfig verifies cluster-scraper gets cluster-level OTEL config
// with apiserver and kube-state-metrics pipelines.
func validateClusterScraperConfig(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["cloudwatch-agent-cluster-scraper"]
	if !assert.True(t, exists, "cloudwatch-agent-cluster-scraper CR should exist") {
		return
	}

	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return
	}

	// Verify hostNetwork is true (default for all agents)
	hostNetwork, ok := spec["hostNetwork"].(bool)
	assert.True(t, ok, "hostNetwork should be a bool")
	assert.True(t, hostNetwork, "cluster-scraper should have hostNetwork=true")

	// Validate OTEL config has cluster-level pipelines
	otelConfig, ok := spec["otelConfig"].(string)
	if !assert.True(t, ok, "otelConfig should be a string") {
		return
	}

	assert.True(t, strings.Contains(otelConfig, "cw_k8s_ci_v0_apiserver"),
		"cluster-scraper otelConfig should contain apiserver receiver (cluster-level)")
	assert.True(t, strings.Contains(otelConfig, "cw_k8s_ci_v0_kube_state_metrics"),
		"cluster-scraper otelConfig should contain kube_state_metrics receiver (cluster-level)")
	assert.True(t, strings.Contains(otelConfig, "k8s_events"),
		"cluster-scraper otelConfig should contain k8s_events receiver")
	assert.False(t, strings.Contains(otelConfig, "kubeletstats"),
		"cluster-scraper otelConfig should NOT contain kubeletstats receiver (node-level)")
	assert.False(t, strings.Contains(otelConfig, "cw_k8s_ci_v0_kubelet"),
		"cluster-scraper otelConfig should NOT contain kubelet receiver (node-level)")
}
