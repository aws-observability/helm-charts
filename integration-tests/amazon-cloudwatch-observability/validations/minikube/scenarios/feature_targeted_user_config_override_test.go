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

func TestFeatureTargetedUserConfigOverride(t *testing.T) {
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

	t.Run("UserConfigPreserved", func(t *testing.T) {
		validateUserConfigPreserved(t, agentMap)
	})

	t.Run("DefaultConfigBypassed", func(t *testing.T) {
		validateDefaultConfigBypassed(t, agentMap)
	})

	t.Log("Feature targeted user config override scenario validation passed")
}

// validateUserConfigPreserved verifies that when a user provides an explicit config in the
// agents array, the user's custom config is preserved in the CR.
func validateUserConfigPreserved(t *testing.T, agentMap map[string]unstructured.Unstructured) {
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

	// Verify logs.metrics_collected.custom_metric exists (user's config preserved)
	logs, ok := config["logs"].(map[string]interface{})
	assert.True(t, ok, "config should have logs section from user config")
	if ok {
		metricsCollected, ok := logs["metrics_collected"].(map[string]interface{})
		assert.True(t, ok, "logs should have metrics_collected section from user config")
		if ok {
			_, hasCustomMetric := metricsCollected["custom_metric"]
			assert.True(t, hasCustomMetric, "logs.metrics_collected should contain custom_metric from user config")
		}
	}
}

// validateDefaultConfigBypassed verifies that when a user provides an explicit config,
// the build-default-config helper is bypassed and default features are not injected.
func validateDefaultConfigBypassed(t *testing.T, agentMap map[string]unstructured.Unstructured) {
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

	// Verify logs.metrics_collected does NOT contain kubernetes (build-default-config was bypassed)
	logs, hasLogs := config["logs"].(map[string]interface{})
	if hasLogs {
		metricsCollected, hasMC := logs["metrics_collected"].(map[string]interface{})
		if hasMC {
			_, hasKubernetes := metricsCollected["kubernetes"]
			assert.False(t, hasKubernetes, "logs.metrics_collected should NOT contain kubernetes when user provides explicit config")

			_, hasAppSignals := metricsCollected["application_signals"]
			assert.False(t, hasAppSignals, "logs.metrics_collected should NOT contain application_signals when user provides explicit config")
		}
	}
}
