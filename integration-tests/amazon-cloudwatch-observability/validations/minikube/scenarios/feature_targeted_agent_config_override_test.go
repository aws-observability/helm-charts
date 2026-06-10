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
	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// TestFeatureTargetedAgentConfigOverride verifies that when agent.config (singular)
// is set, the cloudwatch-agent daemonset uses it but the cluster-scraper deployment
// gets build-default-config output instead (no config bleed-through).
func TestFeatureTargetedAgentConfigOverride(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	require.NoError(t, err, "failed to create k8s client")

	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

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

	t.Run("DaemonsetUsesAgentConfig", func(t *testing.T) {
		agent, exists := agentMap["cloudwatch-agent"]
		if !assert.True(t, exists, "cloudwatch-agent CR should exist") {
			return
		}
		config := extractAgentCRConfig(t, agent)
		if config == nil {
			return
		}

		// agent.config has logs.metrics_collected.kubernetes — verify it's present
		logs, ok := config["logs"].(map[string]interface{})
		assert.True(t, ok, "cloudwatch-agent config should have logs section")
		if ok {
			mc, ok := logs["metrics_collected"].(map[string]interface{})
			assert.True(t, ok, "logs should have metrics_collected")
			if ok {
				_, hasK8s := mc["kubernetes"]
				assert.True(t, hasK8s, "cloudwatch-agent should have kubernetes in metrics_collected from agent.config")
			}
		}
	})

	t.Run("ClusterScraperGetsDefaultConfig", func(t *testing.T) {
		agent, exists := agentMap["cloudwatch-agent-cluster-scraper"]
		if !assert.True(t, exists, "cloudwatch-agent-cluster-scraper CR should exist") {
			return
		}
		config := extractAgentCRConfig(t, agent)
		if config == nil {
			return
		}

		// cluster-scraper should get build-default-config: only {"agent":{"region":"..."}}
		_, hasLogs := config["logs"]
		assert.False(t, hasLogs, "cluster-scraper should NOT have logs section (config bleed-through)")

		_, hasTraces := config["traces"]
		assert.False(t, hasTraces, "cluster-scraper should NOT have traces section (config bleed-through)")

		agentSection, hasAgent := config["agent"].(map[string]interface{})
		assert.True(t, hasAgent, "cluster-scraper should have agent section with region")
		if hasAgent {
			_, hasRegion := agentSection["region"]
			assert.True(t, hasRegion, "cluster-scraper agent section should have region")
		}
	})
}

func extractAgentCRConfig(t *testing.T, cr unstructured.Unstructured) map[string]interface{} {
	spec, ok := cr.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return nil
	}
	configStr, ok := spec["config"].(string)
	if !assert.True(t, ok, "config should be a string") {
		return nil
	}
	var config map[string]interface{}
	err := json.Unmarshal([]byte(configStr), &config)
	require.NoError(t, err, "config should be valid JSON")
	return config
}
