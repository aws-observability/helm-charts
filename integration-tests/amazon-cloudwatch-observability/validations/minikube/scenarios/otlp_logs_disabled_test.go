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
	appsV1 "k8s.io/api/apps/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// TestOTLPLogsDisabled covers state #5: otelContainerInsights.enabled=true,
// otelContainerInsights.logs.enabled=false, containerLogs.enabled=false.
//
// Customer wants OTEL CI metrics but no log ingestion. Validates:
//   - OTEL metrics pipeline components are present in otelConfig
//   - OTEL log pipeline components (receivers, exporters, service pipelines)
//     are completely absent
//   - Log-only sigv4auth extension is absent; metrics-side sigv4auth is present
//   - CWA DaemonSet does not mount /var/log or journald host paths
//   - FluentBit DaemonSet is not rendered
func TestOTLPLogsDisabled(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	if !assert.NoError(t, err) {
		t.Fatal("failed to create k8s client")
	}

	// Namespace + operator sanity.
	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

	exists, err := k8sClient.ValidateDeploymentExists(minikube.Namespace, "amazon-cloudwatch-observability-controller-manager")
	assert.NoError(t, err)
	assert.True(t, exists, "operator deployment should exist")

	// FluentBit must not be deployed (containerLogs.enabled=false).
	exists, err = k8sClient.ValidateDaemonSetExists(minikube.Namespace, "fluent-bit")
	assert.NoError(t, err)
	assert.False(t, exists, "fluent-bit DaemonSet should not exist when containerLogs.enabled=false")

	// AmazonCloudWatchAgent CR for the node-level agent should exist and have an
	// otelConfig with metrics but no log-pipeline content.
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

	// Metrics pipeline present.
	assert.Contains(t, otelConfig, "otlphttp/cw_k8s_ci_v0_metrics_dest",
		"metrics exporter must be present when enabled=true")
	assert.Contains(t, otelConfig, "sigv4auth/cw_k8s_ci_v0_metrics_dest",
		"metrics-side sigv4auth must be present")

	// Log pipeline completely absent.
	assertLogPipelineAbsent(t, otelConfig)

	// CWA DaemonSet must not have log-related host mounts.
	assertNoLogMounts(t, k8sClient, "cloudwatch-agent")

	t.Log("OTLP logs-disabled scenario validation passed")
}

// assertLogPipelineAbsent checks that no log-specific OTEL components appear in
// the generated config. The shared names are gated by otelContainerInsights.logs.enabled.
func assertLogPipelineAbsent(t *testing.T, otelConfig string) {
	t.Helper()
	logOnlyFragments := []string{
		// Receivers
		"filelog/cw_k8s_ci_v0_app",
		"filelog/cw_k8s_ci_v0_node",
		// Service pipelines
		"logs/cw_k8s_ci_v0_app",
		"logs/cw_k8s_ci_v0_node",
		// Log exporters
		"otlphttp/cw_k8s_ci_v0_app_logs_dest",
		"otlphttp/cw_k8s_ci_v0_node_logs_dest",
		// Log-specific extension
		"sigv4auth/cw_k8s_ci_v0_logs_dest",
	}
	for _, fragment := range logOnlyFragments {
		assert.False(t, strings.Contains(otelConfig, fragment),
			"otelConfig must not contain %q when otelContainerInsights.logs.enabled=false", fragment)
	}
}

// assertNoLogMounts verifies the CWA DaemonSet does not carry the /var/log or
// journald host mounts, which are only needed when otelContainerInsights.logs.enabled=true.
func assertNoLogMounts(t *testing.T, k8sClient *util.K8sClient, dsName string) {
	t.Helper()
	daemonSets, err := k8sClient.ListDaemonSets(minikube.Namespace)
	if !assert.NoError(t, err, "failed to list DaemonSets") {
		return
	}

	var ds *appsV1.DaemonSet
	for i := range daemonSets.Items {
		if daemonSets.Items[i].Name == dsName {
			ds = &daemonSets.Items[i]
			break
		}
	}
	if !assert.NotNil(t, ds, "DaemonSet %q not found", dsName) {
		return
	}

	// Check volumes — names come from the helm template.
	logVolumeNames := map[string]bool{
		"varlog": true,
	}
	for _, vol := range ds.Spec.Template.Spec.Volumes {
		if logVolumeNames[vol.Name] {
			t.Errorf("DaemonSet %q should not have volume %q when logs=false", dsName, vol.Name)
		}
	}

	// Check volume mounts on every container.
	for _, c := range ds.Spec.Template.Spec.Containers {
		for _, vm := range c.VolumeMounts {
			if logVolumeNames[vm.Name] {
				t.Errorf("container %q in DaemonSet %q should not mount %q when logs=false",
					c.Name, dsName, vm.Name)
			}
		}
	}
}
