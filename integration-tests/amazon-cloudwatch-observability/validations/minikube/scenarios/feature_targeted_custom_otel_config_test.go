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

	t.Run("CustomOtelConfigPassthrough", func(t *testing.T) {
		validateCustomOtelConfigPassthrough(t, agentMap)
	})

	t.Run("UserNonCollidingKeysPreserved", func(t *testing.T) {
		validateUserNonCollidingKeysPreserved(t, agentMap)
	})

	t.Run("ContainerInsightsInSpecConfig", func(t *testing.T) {
		validateContainerInsightsInSpecConfig(t, agentMap)
	})

	t.Log("Feature targeted custom otel config scenario validation passed")
}

// validateCustomOtelConfigPassthrough verifies the customer-supplied agent.otelConfig passes through
// verbatim: the CloudWatch Agent builds CI from spec.config, so the user's sigv4auth region
// (us-fake-99) survives and no chart-generated region (us-west-2) is merged into otelConfig.
func validateCustomOtelConfigPassthrough(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["cloudwatch-agent"]
	if !assert.True(t, exists, "cloudwatch-agent CR should exist") {
		return
	}

	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return
	}

	otelConfig, ok := spec["otelConfig"].(string)
	if !assert.True(t, ok, "otelConfig should be a string (customer passthrough present)") {
		return
	}
	assert.NotEmpty(t, otelConfig, "otelConfig should not be empty")

	// The user's colliding-key region survives verbatim — no chart CI overwrites it anymore.
	assert.True(t, strings.Contains(otelConfig, "us-fake-99"),
		"otelConfig should preserve the user's sigv4auth region us-fake-99 verbatim")

	// The chart-generated region is not merged into otelConfig (chart CI lives in spec.config).
	assert.False(t, strings.Contains(otelConfig, "us-west-2"),
		"otelConfig should NOT contain a chart-generated region us-west-2 (CI no longer merged into otelConfig)")
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

// validateContainerInsightsInSpecConfig verifies chart-generated CI lands in spec.config as
// opentelemetry.collect.container_insights (node role=node + cluster_name; cluster-scraper
// role=cluster + solutions). The node agent also carries the customer otelConfig passthrough, so its
// container_insights block is asserted directly rather than via the otelConfig-absent asserter.
func validateContainerInsightsInSpecConfig(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	config := configJSONOf(t, agentMap, "cloudwatch-agent")
	if config != nil {
		ci := containerInsightsOf(config)
		if assert.NotNil(t, ci, "cloudwatch-agent spec.config should carry opentelemetry.collect.container_insights") {
			assert.Equal(t, "node", ci["role"], "cloudwatch-agent container_insights.role should be node")
			assert.Equal(t, clusterName, otelClusterNameOf(config),
				"cloudwatch-agent opentelemetry.cluster_name should be %q", clusterName)
		}
	}

	// The cluster-scraper carries no customer otelConfig, so the full asserter applies.
	assertClusterScraperContainerInsights(t, agentMap, "cloudwatch-agent-cluster-scraper")
}
