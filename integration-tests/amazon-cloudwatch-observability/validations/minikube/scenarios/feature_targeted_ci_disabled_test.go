// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func TestFeatureTargetedCIDisabled(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	if !assert.NoError(t, err) {
		t.Fatal("failed to create k8s client")
	}

	// Validate namespace exists
	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

	// Validate operator deployment exists
	exists, err := k8sClient.ValidateDeploymentExists(minikube.Namespace, "amazon-cloudwatch-observability-controller-manager")
	assert.NoError(t, err)
	assert.True(t, exists, "operator deployment should exist")

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

	t.Run("KubernetesMetricsNotInConfig", func(t *testing.T) {
		validateKubernetesMetricsNotInConfig(t, agentMap)
	})

	t.Run("AppSignalsStillPresent", func(t *testing.T) {
		validateAppSignalsStillPresent(t, agentMap)
	})

	t.Log("Feature targeted CI disabled scenario validation passed")
}

// validateKubernetesMetricsNotInConfig verifies that when containerInsights.enabled is false,
// the cloudwatch-agent config JSON does not contain kubernetes in logs.metrics_collected.
func validateKubernetesMetricsNotInConfig(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["cloudwatch-agent"]
	if !assert.True(t, exists, "cloudwatch-agent CR should exist") {
		return
	}

	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return
	}

	configStr, ok := spec["config"].(string)
	if !assert.True(t, ok, "config should be a string") {
		return
	}

	var config map[string]interface{}
	err := json.Unmarshal([]byte(configStr), &config)
	if !assert.NoError(t, err, "config should be valid JSON") {
		return
	}

	// Verify logs.metrics_collected does NOT contain kubernetes
	logs, hasLogs := config["logs"].(map[string]interface{})
	if hasLogs {
		metricsCollected, hasMC := logs["metrics_collected"].(map[string]interface{})
		if hasMC {
			_, hasKubernetes := metricsCollected["kubernetes"]
			assert.False(t, hasKubernetes, "logs.metrics_collected should NOT contain kubernetes when Container Insights is disabled")
		}
	}
}

// validateAppSignalsStillPresent verifies that Application Signals config is still
// present in the cloudwatch-agent when only containerInsights is disabled.
func validateAppSignalsStillPresent(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["cloudwatch-agent"]
	if !assert.True(t, exists, "cloudwatch-agent CR should exist") {
		return
	}

	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return
	}

	configStr, ok := spec["config"].(string)
	if !assert.True(t, ok, "config should be a string") {
		return
	}

	var config map[string]interface{}
	err := json.Unmarshal([]byte(configStr), &config)
	if !assert.NoError(t, err, "config should be valid JSON") {
		return
	}

	// Should still have logs.metrics_collected.application_signals (AppSignals still enabled)
	logs, ok := config["logs"].(map[string]interface{})
	assert.True(t, ok, "config should have logs section (AppSignals still enabled)")
	if ok {
		metricsCollected, ok := logs["metrics_collected"].(map[string]interface{})
		assert.True(t, ok, "logs should have metrics_collected section")
		if ok {
			_, hasAppSignals := metricsCollected["application_signals"]
			assert.True(t, hasAppSignals, "logs.metrics_collected should still contain application_signals when only CI is disabled")
		}
	}

	// Should still have traces.traces_collected.application_signals
	traces, ok := config["traces"].(map[string]interface{})
	assert.True(t, ok, "config should have traces section (AppSignals still enabled)")
	if ok {
		tracesCollected, ok := traces["traces_collected"].(map[string]interface{})
		assert.True(t, ok, "traces should have traces_collected section")
		if ok {
			_, hasAppSignals := tracesCollected["application_signals"]
			assert.True(t, hasAppSignals, "traces.traces_collected should still contain application_signals when only CI is disabled")
		}
	}
}
