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

// TestOTLPHybridMetricsFluentBit covers state #6: otelContainerInsights.enabled=true,
// otelContainerInsights.logs=false, containerLogs.enabled=true.
//
// Customer wants OTEL CI metrics but keeps FluentBit for log collection (typically
// because they have custom FluentBit configs they haven't ported to OTEL).
// Validates that both worlds coexist: OTEL metrics pipelines deployed, OTEL log
// pipelines absent, FluentBit DaemonSet deployed.
func TestOTLPHybridMetricsFluentBit(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	if !assert.NoError(t, err) {
		t.Fatal("failed to create k8s client")
	}

	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

	exists, err := k8sClient.ValidateDeploymentExists(minikube.Namespace, "amazon-cloudwatch-observability-controller-manager")
	assert.NoError(t, err)
	assert.True(t, exists, "operator deployment should exist")

	// FluentBit should be deployed.
	exists, err = k8sClient.ValidateDaemonSetExists(minikube.Namespace, "fluent-bit")
	assert.NoError(t, err)
	assert.True(t, exists, "fluent-bit DaemonSet should be deployed when containerLogs.enabled=true")

	// AmazonCloudWatchAgent CR should carry OTEL metrics config but no log pipelines.
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

	otelConfig, ok := spec["otelConfig"].(string)
	if !assert.True(t, ok, "otelConfig should be a string") {
		return
	}

	// OTEL metrics present.
	assert.Contains(t, otelConfig, "otlphttp/cw_k8s_ci_v0_metrics_dest",
		"metrics exporter must be present")
	assert.Contains(t, otelConfig, "sigv4auth/cw_k8s_ci_v0_metrics_dest",
		"metrics-side sigv4auth must be present")

	// OTEL log pipeline absent (same assertions as the logs-disabled scenario —
	// the logs sub-flag is the only thing controlling this, and it's false here).
	assertLogPipelineAbsent(t, otelConfig)

	// CWA DaemonSet must not have log-related host mounts.
	assertNoLogMounts(t, k8sClient, "cloudwatch-agent")

	// FluentBit ConfigMap must exist and contain log-tail configs (sanity check
	// that the legacy log path is actually functional, not just a DS without config).
	fbCM, err := k8sClient.GetConfigMap(minikube.Namespace, "fluent-bit-config")
	if assert.NoError(t, err) && assert.NotNil(t, fbCM) {
		// The FB ConfigMap contains multiple keyed configs; at least one should
		// reference the application log path FluentBit tails by default.
		var found bool
		for _, v := range fbCM.Data {
			if strings.Contains(v, "/var/log/containers/") {
				found = true
				break
			}
		}
		assert.True(t, found, "fluent-bit ConfigMap should reference /var/log/containers/ paths")
	}

	t.Log("OTLP hybrid (metrics + FluentBit) scenario validation passed")
}
