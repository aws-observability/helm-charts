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

func TestFeatureTargetedOTLPDisabled(t *testing.T) {
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

	t.Run("ClusterScraperCRNotRendered", func(t *testing.T) {
		validateClusterScraperCRNotRendered(t, agentMap)
	})

	t.Run("CloudWatchAgentNoOtelConfig", func(t *testing.T) {
		validateCloudWatchAgentNoOtelConfig(t, agentMap)
	})

	t.Run("NodeExporterNotDeployed", func(t *testing.T) {
		validateNodeExporterNotDeployed(t, k8sClient)
	})

	t.Run("KubeStateMetricsNotDeployed", func(t *testing.T) {
		validateKubeStateMetricsNotDeployed(t, k8sClient)
	})

	t.Run("ContainerInsightsConfigStillPresent", func(t *testing.T) {
		validateCIConfigStillPresentWhenOTLPDisabled(t, agentMap)
	})

	t.Log("Feature targeted OTLP disabled scenario validation passed")
}

// validateClusterScraperCRNotRendered verifies the cluster-scraper CR is NOT rendered
// when otelContainerInsights.enabled is false (Requirement 3.2).
func validateClusterScraperCRNotRendered(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	_, exists := agentMap["cloudwatch-agent-cluster-scraper"]
	assert.False(t, exists, "cloudwatch-agent-cluster-scraper CR should NOT exist when otelContainerInsights is disabled")
}

// validateCloudWatchAgentNoOtelConfig verifies the cloudwatch-agent CR has no otelConfig
// field when otelContainerInsights is disabled — no node-level or cluster-level pipelines.
func validateCloudWatchAgentNoOtelConfig(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["cloudwatch-agent"]
	if !assert.True(t, exists, "cloudwatch-agent CR should exist") {
		return
	}

	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return
	}

	otelConfig, ok := spec["otelConfig"].(string)
	if ok {
		// If otelConfig is present, it should NOT contain any CI receivers
		assert.False(t, strings.Contains(otelConfig, "kubeletstats"),
			"cloudwatch-agent otelConfig should NOT contain kubeletstats receiver when OTLP disabled")
		assert.False(t, strings.Contains(otelConfig, "cadvisor"),
			"cloudwatch-agent otelConfig should NOT contain cadvisor receiver when OTLP disabled")
		assert.False(t, strings.Contains(otelConfig, "cw_k8s_ci_v0_apiserver"),
			"cloudwatch-agent otelConfig should NOT contain apiserver receiver when OTLP disabled")
		assert.False(t, strings.Contains(otelConfig, "cw_k8s_ci_v0_kube_state_metrics"),
			"cloudwatch-agent otelConfig should NOT contain kube_state_metrics receiver when OTLP disabled")
	}
	// otelConfig may be absent entirely when no OTEL CI features target this agent — that's valid
}

// validateNodeExporterNotDeployed verifies node-exporter resources are NOT present
// when otelContainerInsights is disabled (guarded by nodeExporter.enabled which defaults
// to following otelContainerInsights.enabled).
func validateNodeExporterNotDeployed(t *testing.T, k8sClient *util.K8sClient) {
	exists, err := k8sClient.ValidateDaemonSetExists(minikube.Namespace, "node-exporter")
	assert.NoError(t, err)
	assert.False(t, exists, "node-exporter daemonset should NOT exist when OTLP is disabled")
}

// validateKubeStateMetricsNotDeployed verifies kube-state-metrics resources are NOT present
// when otelContainerInsights is disabled (guarded by kubeStateMetrics.enabled which defaults
// to following otelContainerInsights.enabled).
func validateKubeStateMetricsNotDeployed(t *testing.T, k8sClient *util.K8sClient) {
	exists, err := k8sClient.ValidateDeploymentExists(minikube.Namespace, "kube-state-metrics")
	assert.NoError(t, err)
	assert.False(t, exists, "kube-state-metrics deployment should NOT exist when OTLP is disabled")
}

// validateCIConfigStillPresentWhenOTLPDisabled verifies that the CW Agent JSON config
// still contains logs.metrics_collected.kubernetes when otelContainerInsights is disabled
// but containerInsights is still enabled (default).
func validateCIConfigStillPresentWhenOTLPDisabled(t *testing.T, agentMap map[string]unstructured.Unstructured) {
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

	// Should have logs.metrics_collected.kubernetes (Container Insights still enabled by default)
	logs, ok := config["logs"].(map[string]interface{})
	assert.True(t, ok, "config should have logs section (Container Insights enabled by default)")
	if ok {
		metricsCollected, ok := logs["metrics_collected"].(map[string]interface{})
		assert.True(t, ok, "logs should have metrics_collected section")
		if ok {
			_, hasKubernetes := metricsCollected["kubernetes"]
			assert.True(t, hasKubernetes, "logs.metrics_collected should contain kubernetes when CI is enabled and OTLP is disabled")
		}
	}
}
