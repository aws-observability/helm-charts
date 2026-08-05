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

// TestDefaultOtel validates the config: "default:otel" value, which merges an OTLP receiver onto
// the default CW Agent config. Asserts on the rendered CR's JSON spec.config, like the other scenarios.
func TestDefaultOtel(t *testing.T) {
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

	t.Run("NodeAgentHasOtlpReceiver", func(t *testing.T) {
		validateNodeAgentOtlpReceiver(t, agentMap)
	})
	t.Run("NodeAgentDefaultConfigSurvives", func(t *testing.T) {
		validateNodeAgentDefaultConfigSurvives(t, agentMap)
	})
	t.Run("ClusterScraperHasNoOtlpReceiver", func(t *testing.T) {
		validateClusterScraperNoOtlpReceiver(t, agentMap)
	})

	t.Log("default:otel config scenario validation passed")
}

// configJSONOf parses a CR's spec.config (a JSON string) into a map, failing the test on any issue.
func configJSONOf(t *testing.T, agentMap map[string]unstructured.Unstructured, name string) map[string]interface{} {
	t.Helper()
	agent, exists := agentMap[name]
	if !assert.True(t, exists, "%s CR should exist", name) {
		return nil
	}
	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "%s spec should be a map", name) {
		return nil
	}
	configStr, ok := spec["config"].(string)
	if !assert.True(t, ok, "%s config should be a string", name) {
		return nil
	}
	var config map[string]interface{}
	if !assert.NoError(t, json.Unmarshal([]byte(configStr), &config), "%s config should be valid JSON", name) {
		return nil
	}
	return config
}

// otlpCollectBlockOf returns opentelemetry.collect.otlp from a parsed config, or nil if absent.
func otlpCollectBlockOf(config map[string]interface{}) map[string]interface{} {
	otel, ok := config["opentelemetry"].(map[string]interface{})
	if !ok {
		return nil
	}
	collect, ok := otel["collect"].(map[string]interface{})
	if !ok {
		return nil
	}
	otlp, _ := collect["otlp"].(map[string]interface{})
	return otlp
}

// validateNodeAgentOtlpReceiver checks the node agent's "default:otel" config carries the OTLP receiver.
func validateNodeAgentOtlpReceiver(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	config := configJSONOf(t, agentMap, "cloudwatch-agent")
	if config == nil {
		return
	}
	otlp := otlpCollectBlockOf(config)
	if !assert.NotNil(t, otlp, "node agent config should have opentelemetry.collect.otlp for default:otel") {
		return
	}
	// Endpoints are pinned to 0.0.0.0 so the receiver accepts traffic from other pods (the agent
	// default binds loopback only).
	assert.Equal(t, "0.0.0.0:4317", otlp["grpc_endpoint"], "otlp grpc_endpoint should be 0.0.0.0:4317")
	assert.Equal(t, "0.0.0.0:4318", otlp["http_endpoint"], "otlp http_endpoint should be 0.0.0.0:4318")
	assert.Equal(t, true, otlp["span_metrics_enabled"], "otlp span_metrics_enabled should be true")
}

// validateNodeAgentDefaultConfigSurvives checks the OTLP receiver was MERGED onto the default config,
// not substituted for it: the default Container Insights block (logs.metrics_collected.kubernetes)
// must remain alongside it.
func validateNodeAgentDefaultConfigSurvives(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	config := configJSONOf(t, agentMap, "cloudwatch-agent")
	if config == nil {
		return
	}
	logs, ok := config["logs"].(map[string]interface{})
	if !assert.True(t, ok, "node agent config should retain the default logs section") {
		return
	}
	metricsCollected, ok := logs["metrics_collected"].(map[string]interface{})
	if !assert.True(t, ok, "node agent config should retain logs.metrics_collected") {
		return
	}
	_, hasKubernetes := metricsCollected["kubernetes"]
	assert.True(t, hasKubernetes,
		"default Container Insights (logs.metrics_collected.kubernetes) should survive the OTLP merge")
}

// validateClusterScraperNoOtlpReceiver checks the cluster-scraper (config: "default", not
// "default:otel") does NOT get the OTLP receiver; it describes other workloads, not local ingest.
func validateClusterScraperNoOtlpReceiver(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	config := configJSONOf(t, agentMap, "cloudwatch-agent-cluster-scraper")
	if config == nil {
		return
	}
	assert.Nil(t, otlpCollectBlockOf(config),
		"cluster-scraper config should NOT have an OTLP receiver (config is plain default)")
}
