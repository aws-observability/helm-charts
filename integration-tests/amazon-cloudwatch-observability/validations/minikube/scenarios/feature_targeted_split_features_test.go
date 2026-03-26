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

func TestFeatureTargetedSplitFeatures(t *testing.T) {
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
	assert.GreaterOrEqual(t, len(agentMap), 3, "should have at least 3 agent CRs (ci-agent, appsignals-agent, cluster-scraper)")
	assert.Contains(t, agentMap, "ci-agent", "ci-agent CR should exist")
	assert.Contains(t, agentMap, "appsignals-agent", "appsignals-agent CR should exist")
	assert.Contains(t, agentMap, "cloudwatch-agent-cluster-scraper", "cluster-scraper CR should exist")

	t.Run("CIAgentConfig", func(t *testing.T) {
		validateCIAgentConfig(t, agentMap)
	})

	t.Run("AppSignalsAgentConfig", func(t *testing.T) {
		validateAppSignalsAgentConfig(t, agentMap)
	})

	t.Run("SplitFeaturesClusterScraperConfig", func(t *testing.T) {
		validateSplitFeaturesClusterScraperConfig(t, agentMap)
	})

	t.Log("Feature targeted split features scenario validation passed")
}

// validateCIAgentConfig verifies ci-agent gets Container Insights config and node-level OTEL
// pipelines, but does NOT get Application Signals config (targeted to appsignals-agent).
func validateCIAgentConfig(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["ci-agent"]
	if !assert.True(t, exists, "ci-agent CR should exist") {
		return
	}

	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return
	}

	// Validate CW Agent config
	configStr, ok := spec["config"].(string)
	if !assert.True(t, ok, "config should be a string") {
		return
	}

	var config map[string]interface{}
	err := json.Unmarshal([]byte(configStr), &config)
	if !assert.NoError(t, err, "config should be valid JSON") {
		return
	}

	// Should have logs.metrics_collected.kubernetes (Container Insights targeted here)
	logs, ok := config["logs"].(map[string]interface{})
	assert.True(t, ok, "ci-agent config should have logs section")
	if ok {
		metricsCollected, ok := logs["metrics_collected"].(map[string]interface{})
		assert.True(t, ok, "logs should have metrics_collected section")
		if ok {
			_, hasKubernetes := metricsCollected["kubernetes"]
			assert.True(t, hasKubernetes, "ci-agent should have kubernetes (Container Insights) config")

			// Should NOT have application_signals (targeted to appsignals-agent)
			_, hasAppSignals := metricsCollected["application_signals"]
			assert.False(t, hasAppSignals, "ci-agent should NOT have application_signals in logs.metrics_collected")
		}
	}

	// Should NOT have traces section (AppSignals targeted elsewhere)
	_, hasTraces := config["traces"]
	assert.False(t, hasTraces, "ci-agent config should NOT have traces section")

	// Validate OTEL config has node-level pipelines (otelContainerInsights targeted here)
	otelConfig, ok := spec["otelConfig"].(string)
	if !assert.True(t, ok, "otelConfig should be a string") {
		return
	}

	assert.True(t, strings.Contains(otelConfig, "kubeletstats"),
		"ci-agent otelConfig should contain kubeletstats receiver (node-level OTEL CI targeted here)")
	assert.True(t, strings.Contains(otelConfig, "health_check"),
		"ci-agent otelConfig should contain health_check extension")
	assert.False(t, strings.Contains(otelConfig, "otel_container_insights_apiserver"),
		"ci-agent otelConfig should NOT contain apiserver receiver (cluster-level)")
}

// validateAppSignalsAgentConfig verifies appsignals-agent gets Application Signals config
// but does NOT get Container Insights config (targeted to ci-agent), and has health-check-only
// OTEL config (otelContainerInsights not targeted here).
func validateAppSignalsAgentConfig(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["appsignals-agent"]
	if !assert.True(t, exists, "appsignals-agent CR should exist") {
		return
	}

	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return
	}

	// Validate CW Agent config
	configStr, ok := spec["config"].(string)
	if !assert.True(t, ok, "config should be a string") {
		return
	}

	var config map[string]interface{}
	err := json.Unmarshal([]byte(configStr), &config)
	if !assert.NoError(t, err, "config should be valid JSON") {
		return
	}

	// Should have logs.metrics_collected.application_signals (AppSignals targeted here)
	logs, ok := config["logs"].(map[string]interface{})
	assert.True(t, ok, "appsignals-agent config should have logs section")
	if ok {
		metricsCollected, ok := logs["metrics_collected"].(map[string]interface{})
		assert.True(t, ok, "logs should have metrics_collected section")
		if ok {
			_, hasAppSignals := metricsCollected["application_signals"]
			assert.True(t, hasAppSignals, "appsignals-agent should have application_signals in logs.metrics_collected")

			// Should NOT have kubernetes (Container Insights targeted to ci-agent)
			_, hasKubernetes := metricsCollected["kubernetes"]
			assert.False(t, hasKubernetes, "appsignals-agent should NOT have kubernetes (Container Insights) config")
		}
	}

	// Should have traces.traces_collected.application_signals (AppSignals targeted here)
	traces, ok := config["traces"].(map[string]interface{})
	assert.True(t, ok, "appsignals-agent config should have traces section")
	if ok {
		tracesCollected, ok := traces["traces_collected"].(map[string]interface{})
		assert.True(t, ok, "traces should have traces_collected section")
		if ok {
			_, hasAppSignals := tracesCollected["application_signals"]
			assert.True(t, hasAppSignals, "appsignals-agent should have application_signals in traces.traces_collected")
		}
	}

	// Validate OTEL config is health-check-only (otelContainerInsights not targeted here)
	otelConfig, ok := spec["otelConfig"].(string)
	if !assert.True(t, ok, "otelConfig should be a string") {
		return
	}

	assert.True(t, strings.Contains(otelConfig, "health_check"),
		"appsignals-agent otelConfig should contain health_check extension")
	assert.False(t, strings.Contains(otelConfig, "kubeletstats"),
		"appsignals-agent otelConfig should NOT contain kubeletstats receiver")
	assert.False(t, strings.Contains(otelConfig, "otel_container_insights_apiserver"),
		"appsignals-agent otelConfig should NOT contain apiserver receiver")
	assert.False(t, strings.Contains(otelConfig, "otel_container_insights_kube_state_metrics"),
		"appsignals-agent otelConfig should NOT contain kube_state_metrics receiver")
}

// validateSplitFeaturesClusterScraperConfig verifies cluster-scraper gets minimal CW Agent
// config (just region) and cluster-level OTEL pipelines (apiserver, kube-state-metrics).
func validateSplitFeaturesClusterScraperConfig(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["cloudwatch-agent-cluster-scraper"]
	if !assert.True(t, exists, "cloudwatch-agent-cluster-scraper CR should exist") {
		return
	}

	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return
	}

	// Validate CW Agent config is minimal (just region)
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
	assert.True(t, ok, "cluster-scraper config should have agent section")
	if ok {
		_, hasRegion := agentSection["region"]
		assert.True(t, hasRegion, "cluster-scraper config should have agent.region")
	}

	// Should NOT have logs section (no features targeted here)
	_, hasLogs := config["logs"]
	assert.False(t, hasLogs, "cluster-scraper config should NOT have logs section")

	// Should NOT have traces section (no features targeted here)
	_, hasTraces := config["traces"]
	assert.False(t, hasTraces, "cluster-scraper config should NOT have traces section")

	// Validate OTEL config has cluster-level pipelines
	otelConfig, ok := spec["otelConfig"].(string)
	if !assert.True(t, ok, "otelConfig should be a string") {
		return
	}

	assert.True(t, strings.Contains(otelConfig, "otel_container_insights_apiserver"),
		"cluster-scraper otelConfig should contain apiserver receiver (cluster-level)")
	assert.True(t, strings.Contains(otelConfig, "otel_container_insights_kube_state_metrics"),
		"cluster-scraper otelConfig should contain kube_state_metrics receiver (cluster-level)")
	assert.True(t, strings.Contains(otelConfig, "health_check"),
		"cluster-scraper otelConfig should contain health_check extension")
	assert.False(t, strings.Contains(otelConfig, "kubeletstats"),
		"cluster-scraper otelConfig should NOT contain kubeletstats receiver (node-level)")
}
