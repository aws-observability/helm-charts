// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"context"
	"strings"
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func TestFeatureTargetedCustomOtelConfig(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	require.NoError(t, err, "failed to create k8s client")

	// Validate namespace exists
	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

	// Get all AmazonCloudWatchAgent CRs
	dynamicClient, err := k8sClient.GetDynamicClient()
	require.NoError(t, err, "failed to get dynamic client")

	gvr := schema.GroupVersionResource{
		Group:    "cloudwatch.aws.amazon.com",
		Version:  "v1alpha1",
		Resource: "amazoncloudwatchagents",
	}

	agentList, err := dynamicClient.Resource(gvr).Namespace(minikube.Namespace).List(
		context.Background(), metav1.ListOptions{},
	)
	require.NoError(t, err, "failed to list AmazonCloudWatchAgent CRs")

	// Build a map of CR name -> CR for easy lookup
	agentMap := make(map[string]unstructured.Unstructured)
	for _, agent := range agentList.Items {
		agentMap[agent.GetName()] = agent
	}

	t.Run("GeneratedConfigWinsOnCollision", func(t *testing.T) {
		validateGeneratedConfigWinsOnCollision(t, agentMap)
	})

	t.Run("UserNonCollidingKeysPreserved", func(t *testing.T) {
		validateUserNonCollidingKeysPreserved(t, agentMap)
	})

	t.Run("GeneratedPipelinesPresent", func(t *testing.T) {
		validateGeneratedPipelinesPresent(t, agentMap)
	})

	t.Log("Feature targeted custom otel config scenario validation passed")
}

// validateGeneratedConfigWinsOnCollision verifies that when the user supplies an otelConfig
// with a colliding sigv4auth/cw_k8s_ci_v0_metrics_dest extension (region "us-fake-99"), the
// generated config's region ("us-west-2") wins (Requirement 4.4, 12.1).
func validateGeneratedConfigWinsOnCollision(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["cloudwatch-agent"]
	if !assert.True(t, exists, "cloudwatch-agent CR should exist") {
		return
	}

	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return
	}

	otelConfig, ok := spec["otelConfig"].(string)
	if !assert.True(t, ok, "otelConfig should be a string") {
		return
	}
	assert.NotEmpty(t, otelConfig, "otelConfig should not be empty")

	// The generated sigv4auth region (us-west-2) should be present
	assert.True(t, strings.Contains(otelConfig, "us-west-2"),
		"merged otelConfig should contain generated sigv4auth region us-west-2")

	// The user's colliding region (us-fake-99) should NOT be present
	assert.False(t, strings.Contains(otelConfig, "us-fake-99"),
		"merged otelConfig should NOT contain user's colliding sigv4auth region us-fake-99")
}

// validateUserNonCollidingKeysPreserved verifies that user-supplied keys that do not collide
// with generated keys are preserved in the merged output (Requirement 4.4, 12.1).
func validateUserNonCollidingKeysPreserved(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["cloudwatch-agent"]
	if !assert.True(t, exists, "cloudwatch-agent CR should exist") {
		return
	}

	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return
	}

	otelConfig, ok := spec["otelConfig"].(string)
	if !assert.True(t, ok, "otelConfig should be a string") {
		return
	}

	// User's custom receiver should be preserved
	assert.True(t, strings.Contains(otelConfig, "custom_user_scraper"),
		"merged otelConfig should contain user's custom receiver (custom_user_scraper)")

	// User's custom processor should be preserved
	assert.True(t, strings.Contains(otelConfig, "custom_user"),
		"merged otelConfig should contain user's custom processor (custom_user)")

	// User's custom exporter should be preserved
	assert.True(t, strings.Contains(otelConfig, "custom_user_dest"),
		"merged otelConfig should contain user's custom exporter (custom_user_dest)")

	// User's custom pipeline should be preserved
	assert.True(t, strings.Contains(otelConfig, "custom_user_pipeline"),
		"merged otelConfig should contain user's custom pipeline (custom_user_pipeline)")
}

// validateGeneratedPipelinesPresent verifies that the generated OTLP Container Insights
// pipelines are present in the merged output, confirming they were not lost during merge.
func validateGeneratedPipelinesPresent(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["cloudwatch-agent"]
	if !assert.True(t, exists, "cloudwatch-agent CR should exist") {
		return
	}

	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return
	}

	otelConfig, ok := spec["otelConfig"].(string)
	if !assert.True(t, ok, "otelConfig should be a string") {
		return
	}

	// Generated OTLP CI pipelines should be present (cw_k8s_ci_v0 prefix for node-level)
	assert.True(t, strings.Contains(otelConfig, "cw_k8s_ci_v0"),
		"merged otelConfig should contain generated OTLP CI pipelines (cw_k8s_ci_v0 prefix)")

	// Generated kubeletstats receiver should be present (node-level)
	assert.True(t, strings.Contains(otelConfig, "kubeletstats"),
		"merged otelConfig should contain generated kubeletstats receiver")

	// Generated sigv4auth extension should be present
	assert.True(t, strings.Contains(otelConfig, "sigv4auth"),
		"merged otelConfig should contain generated sigv4auth extension")
}
