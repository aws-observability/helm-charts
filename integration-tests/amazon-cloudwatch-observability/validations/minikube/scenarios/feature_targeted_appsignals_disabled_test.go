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

func TestFeatureTargetedAppSignalsDisabled(t *testing.T) {
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

	t.Run("AppSignalsNotInConfig", func(t *testing.T) {
		validateAppSignalsNotInConfig(t, agentMap)
	})

	t.Run("ContainerInsightsStillPresent", func(t *testing.T) {
		validateContainerInsightsStillPresent(t, agentMap)
	})

	t.Log("Feature targeted AppSignals disabled scenario validation passed")
}

// validateAppSignalsNotInConfig verifies that when applicationSignals.enabled is false,
// the cloudwatch-agent config JSON does not contain application_signals in
// logs.metrics_collected or in the traces section.
func validateAppSignalsNotInConfig(t *testing.T, agentMap map[string]unstructured.Unstructured) {
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

	// Verify logs.metrics_collected does NOT contain application_signals
	logs, hasLogs := config["logs"].(map[string]interface{})
	if hasLogs {
		metricsCollected, hasMC := logs["metrics_collected"].(map[string]interface{})
		if hasMC {
			_, hasAppSignals := metricsCollected["application_signals"]
			assert.False(t, hasAppSignals, "logs.metrics_collected should NOT contain application_signals when AppSignals is disabled")
		}
	}

	// Verify traces section does NOT exist or does not contain traces_collected.application_signals
	traces, hasTraces := config["traces"].(map[string]interface{})
	if hasTraces {
		tracesCollected, hasTC := traces["traces_collected"].(map[string]interface{})
		if hasTC {
			_, hasAppSignals := tracesCollected["application_signals"]
			assert.False(t, hasAppSignals, "traces.traces_collected should NOT contain application_signals when AppSignals is disabled")
		}
	}
}

// validateContainerInsightsStillPresent verifies that Container Insights config is still
// present in the cloudwatch-agent when only applicationSignals is disabled.
func validateContainerInsightsStillPresent(t *testing.T, agentMap map[string]unstructured.Unstructured) {
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

	// Should still have logs.metrics_collected.kubernetes (Container Insights)
	logs, ok := config["logs"].(map[string]interface{})
	assert.True(t, ok, "config should have logs section (Container Insights still enabled)")
	if ok {
		metricsCollected, ok := logs["metrics_collected"].(map[string]interface{})
		assert.True(t, ok, "logs should have metrics_collected section")
		if ok {
			_, hasKubernetes := metricsCollected["kubernetes"]
			assert.True(t, hasKubernetes, "logs.metrics_collected should still contain kubernetes when only AppSignals is disabled")
		}
	}
}
