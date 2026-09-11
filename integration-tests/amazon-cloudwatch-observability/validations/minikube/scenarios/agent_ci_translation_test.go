// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"context"
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// ---------------------------------------------------------------------------
// Shared readers/asserters for the OTel Container Insights surface. The chart emits an
// opentelemetry.collect.container_insights JSON block in spec.config and the CloudWatch Agent
// builds the CI collector pipelines at runtime.
// ---------------------------------------------------------------------------

// containerInsightsOf returns opentelemetry.collect.container_insights from a parsed spec.config,
// or nil if absent. Mirrors otlpCollectBlockOf in default_otel_test.go for the CI block.
func containerInsightsOf(config map[string]interface{}) map[string]interface{} {
	otel, ok := config["opentelemetry"].(map[string]interface{})
	if !ok {
		return nil
	}
	collect, ok := otel["collect"].(map[string]interface{})
	if !ok {
		return nil
	}
	ci, _ := collect["container_insights"].(map[string]interface{})
	return ci
}

// otelClusterNameOf returns opentelemetry.cluster_name (a sibling of collect), or "" if absent.
func otelClusterNameOf(config map[string]interface{}) string {
	otel, ok := config["opentelemetry"].(map[string]interface{})
	if !ok {
		return ""
	}
	name, _ := otel["cluster_name"].(string)
	return name
}

// assertContainerInsightsLogsEnabled asserts container_insights.logs.enabled equals want.
func assertContainerInsightsLogsEnabled(t *testing.T, ci map[string]interface{}, name string, want bool) {
	t.Helper()
	logs, ok := ci["logs"].(map[string]interface{})
	if !assert.True(t, ok, "%s container_insights should have a logs object", name) {
		return
	}
	assert.Equal(t, want, logs["enabled"],
		"%s container_insights.logs.enabled should be %t", name, want)
}

// assertOtelConfigAbsent asserts the CR carries no chart-generated spec.otelConfig: chart CI lives
// entirely in spec.config, so spec.otelConfig only appears with customer agent.otelConfig passthrough
// (covered separately by the custom-otel-config scenarios).
func assertOtelConfigAbsent(t *testing.T, agentMap map[string]unstructured.Unstructured, name string) {
	t.Helper()
	agent, exists := agentMap[name]
	if !assert.True(t, exists, "%s CR should exist", name) {
		return
	}
	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "%s spec should be a map", name) {
		return
	}
	_, hasOtelConfig := spec["otelConfig"]
	assert.False(t, hasOtelConfig,
		"%s should carry no spec.otelConfig after migration (chart CI now lives in spec.config)", name)
}

// assertNodeContainerInsights asserts the node CI agent's surface: spec.config carries
// opentelemetry.collect.container_insights with role=node, opentelemetry.cluster_name matches the
// scenario cluster name, logs.enabled matches wantLogsEnabled, and no chart-generated otelConfig.
func assertNodeContainerInsights(t *testing.T, agentMap map[string]unstructured.Unstructured, name string, wantLogsEnabled bool) {
	t.Helper()
	config := configJSONOf(t, agentMap, name)
	if config == nil {
		return
	}
	ci := containerInsightsOf(config)
	if !assert.NotNil(t, ci, "%s spec.config should have opentelemetry.collect.container_insights", name) {
		return
	}
	assert.Equal(t, "node", ci["role"], "%s container_insights.role should be node", name)
	assert.Equal(t, clusterName, otelClusterNameOf(config),
		"%s opentelemetry.cluster_name should be %q", name, clusterName)
	assertContainerInsightsLogsEnabled(t, ci, name, wantLogsEnabled)
	assertOtelConfigAbsent(t, agentMap, name)
}

// assertClusterScraperContainerInsights asserts the cluster-scraper agent's surface:
// spec.config carries opentelemetry.collect.container_insights with role=cluster, a solutions
// object, opentelemetry.cluster_name matches, NO logs key (logs are node-only; the filelog
// pipeline runs only on the node daemonset), and no chart otelConfig.
func assertClusterScraperContainerInsights(t *testing.T, agentMap map[string]unstructured.Unstructured, name string) {
	t.Helper()
	config := configJSONOf(t, agentMap, name)
	if config == nil {
		return
	}
	ci := containerInsightsOf(config)
	if !assert.NotNil(t, ci, "%s spec.config should have opentelemetry.collect.container_insights", name) {
		return
	}
	assert.Equal(t, "cluster", ci["role"], "%s container_insights.role should be cluster", name)
	assert.Equal(t, clusterName, otelClusterNameOf(config),
		"%s opentelemetry.cluster_name should be %q", name, clusterName)
	_, hasSolutions := ci["solutions"].(map[string]interface{})
	assert.True(t, hasSolutions,
		"%s cluster-role container_insights should include a solutions object", name)
	_, hasLogs := ci["logs"]
	assert.False(t, hasLogs,
		"%s cluster-role container_insights should NOT include a logs key (logs are node-only)", name)
	assertOtelConfigAbsent(t, agentMap, name)
}

// TestAgentCITranslation gives dedicated end-to-end coverage of the OTel Container Insights surface
// the CloudWatch Agent translates from spec.config at runtime: the node agent (role=node, with
// logs.enabled) and the cluster-scraper (role=cluster + solutions, no logs key) both carry
// container_insights and no chart-generated otelConfig, so a regression that drops or reshapes the
// block is caught.
func TestAgentCITranslation(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	require.NoError(t, err, "failed to create k8s client")

	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

	exists, err := k8sClient.ValidateDeploymentExists(minikube.Namespace, "amazon-cloudwatch-observability-controller-manager")
	assert.NoError(t, err)
	assert.True(t, exists, "operator deployment should exist")

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

	agentMap := make(map[string]unstructured.Unstructured)
	for _, agent := range agentList.Items {
		agentMap[agent.GetName()] = agent
	}

	t.Run("NodeAgentRuntimeContainerInsights", func(t *testing.T) {
		assertNodeContainerInsights(t, agentMap, "cloudwatch-agent", true)
	})
	t.Run("ClusterScraperRuntimeContainerInsights", func(t *testing.T) {
		assertClusterScraperContainerInsights(t, agentMap, "cloudwatch-agent-cluster-scraper")
	})

	t.Log("OTel CI runtime-config (spec.config container_insights) scenario validation passed")
}
