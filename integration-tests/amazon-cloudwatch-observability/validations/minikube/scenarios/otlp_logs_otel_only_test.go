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

// TestOTLPLogsOtelOnly covers state #7: otelContainerInsights.enabled=true,
// otelContainerInsights.logs.enabled=true, containerLogs.enabled=false.
//
// The fully-migrated production state — OTEL handles both metrics and logs,
// FluentBit is gone. Validates that OTEL log pipelines render and FluentBit
// is not deployed.
func TestOTLPLogsOtelOnly(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	require.NoError(t, err, "failed to create k8s client")

	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	require.NoError(t, err)
	require.Equal(t, minikube.Namespace, ns.Name)

	// FluentBit must not be deployed.
	exists, err := k8sClient.ValidateDaemonSetExists(minikube.Namespace, "fluent-bit")
	assert.NoError(t, err)
	assert.False(t, exists, "fluent-bit DaemonSet should not exist when containerLogs.enabled=false")

	// AmazonCloudWatchAgent CR for node-level agent.
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

	nodeAgent, exists := agentMap["cloudwatch-agent"]
	if !assert.True(t, exists, "cloudwatch-agent CR should exist") {
		return
	}

	spec, ok := nodeAgent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "spec should be a map") {
		return
	}

	config, ok := spec["config"].(string)
	if !assert.True(t, ok, "config should be a string") {
		return
	}

	// OTEL CI enabled (node role), logs on.
	minikube.AssertOtelContainerInsights(t, config, "node")
	// Hybrid: logs come from the chart otelConfig, not spec.config.
	otelConfig, ok := spec["otelConfig"].(string)
	if !assert.True(t, ok, "otelConfig should be a string") {
		return
	}
	minikube.AssertOtelCILogs(t, otelConfig, true)

	// CWA DaemonSet must carry the log mounts.
	assertHasLogMounts(t, k8sClient, "cloudwatch-agent")

	t.Log("OTLP OTEL-only (full migration) scenario validation passed")
}
