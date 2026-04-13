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
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func TestFeatureTargetedDefault(t *testing.T) {
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

	t.Run("ClusterScraperCRExists", func(t *testing.T) {
		validateClusterScraperCRExists(t, agentMap)
	})

	t.Run("OTELConfigRouting", func(t *testing.T) {
		validateOTELConfigRouting(t, agentMap)
	})

	t.Log("Feature targeted default scenario validation passed")
}

// validateClusterScraperCRExists verifies the cluster-scraper is an AmazonCloudWatchAgent CR
// with mode=deployment (managed by the operator, not a standalone Deployment).
func validateClusterScraperCRExists(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["cloudwatch-agent-cluster-scraper"]
	assert.True(t, exists, "cloudwatch-agent-cluster-scraper CR should exist")
	if !exists {
		return
	}

	spec, ok := agent.Object["spec"].(map[string]interface{})
	assert.True(t, ok, "spec should be a map")

	// Verify mode is deployment
	mode, ok := spec["mode"].(string)
	assert.True(t, ok, "mode should be a string")
	assert.Equal(t, "deployment", mode, "cluster-scraper CR should have mode=deployment")

	// Verify replicas is 1
	replicas, ok := spec["replicas"].(int64)
	assert.True(t, ok, "replicas should be an int64")
	assert.Equal(t, int64(1), replicas, "cluster-scraper CR should have replicas=1")

	// Verify hostNetwork is true (explicitly set in values.yaml for cluster-scraper)
	hostNetwork, ok := spec["hostNetwork"].(bool)
	assert.True(t, ok, "hostNetwork should be a bool")
	assert.True(t, hostNetwork, "cluster-scraper CR should have hostNetwork=true")
}

// validateOTELConfigRouting verifies that OTEL configs are correctly routed:
// - cloudwatch-agent gets node-level pipelines (cadvisor, kubeletstats, node-exporter receivers)
// - cloudwatch-agent-cluster-scraper gets cluster-level pipelines (apiserver, kube-state-metrics receivers)
func validateOTELConfigRouting(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	// Validate cloudwatch-agent has node-level OTEL config
	t.Run("CloudWatchAgentNodeLevel", func(t *testing.T) {
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

		// Node-level config should contain node-exporter, cadvisor, kubeletstats receivers
		assert.True(t, strings.Contains(otelConfig, "kubeletstats"),
			"cloudwatch-agent otelConfig should contain kubeletstats receiver (node-level)")

		// Node-level config should NOT contain cluster-level receivers
		assert.False(t, strings.Contains(otelConfig, "cw_k8s_ci_v0_apiserver"),
			"cloudwatch-agent otelConfig should NOT contain apiserver receiver (cluster-level)")
		assert.False(t, strings.Contains(otelConfig, "cw_k8s_ci_v0_kube_state_metrics"),
			"cloudwatch-agent otelConfig should NOT contain kube_state_metrics receiver (cluster-level)")
	})

	// Validate cluster-scraper has cluster-level OTEL config
	t.Run("ClusterScraperClusterLevel", func(t *testing.T) {
		agent, exists := agentMap["cloudwatch-agent-cluster-scraper"]
		if !assert.True(t, exists, "cloudwatch-agent-cluster-scraper CR should exist") {
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

		// Cluster-level config should contain apiserver and kube-state-metrics receivers
		assert.True(t, strings.Contains(otelConfig, "cw_k8s_ci_v0_apiserver"),
			"cluster-scraper otelConfig should contain apiserver receiver (cluster-level)")
		assert.True(t, strings.Contains(otelConfig, "cw_k8s_ci_v0_kube_state_metrics"),
			"cluster-scraper otelConfig should contain kube_state_metrics receiver (cluster-level)")

		// Cluster-level config should NOT contain node-level receivers
		assert.False(t, strings.Contains(otelConfig, "kubeletstats"),
			"cluster-scraper otelConfig should NOT contain kubeletstats receiver (node-level)")
	})
}
