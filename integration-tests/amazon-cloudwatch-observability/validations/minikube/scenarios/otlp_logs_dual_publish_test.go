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

// TestOTLPLogsDualPublish covers state #8: otelContainerInsights.enabled=true,
// otelContainerInsights.logs=true, containerLogs.enabled=true.
//
// Both OTEL log pipelines and FluentBit are active simultaneously. This is the
// migration/validation state: customer keeps FluentBit running as a safety net
// while validating that OTEL log pipelines produce the expected output, then
// flips containerLogs.enabled=false once confident.
//
// Validates that both paths render: OTEL metrics + OTEL logs + FluentBit DS all
// present, CWA DaemonSet has the log mounts, FluentBit ConfigMap is functional.
func TestOTLPLogsDualPublish(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	if !assert.NoError(t, err) {
		t.Fatal("failed to create k8s client")
	}

	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

	// FluentBit DaemonSet must be present alongside OTEL logs.
	exists, err := k8sClient.ValidateDaemonSetExists(minikube.Namespace, "fluent-bit")
	assert.NoError(t, err)
	assert.True(t, exists, "fluent-bit DaemonSet should be deployed when containerLogs.enabled=true")

	// AmazonCloudWatchAgent CR for node-level agent.
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

	// OTEL metrics present (same as every logs=true scenario).
	assert.Contains(t, otelConfig, "otlphttp/cw_k8s_ci_v0_metrics_dest",
		"metrics exporter must be present")
	assert.Contains(t, otelConfig, "sigv4auth/cw_k8s_ci_v0_metrics_dest")

	// OTEL log pipelines present — the point of this scenario.
	logFragments := []string{
		"filelog/cw_k8s_ci_v0_app",
		"filelog/cw_k8s_ci_v0_node",
		"filelog/cw_k8s_ci_v0_dataplane_containers",
		"journald/cw_k8s_ci_v0_dataplane",
		"logs/cw_k8s_ci_v0_app",
		"logs/cw_k8s_ci_v0_node",
		"logs/cw_k8s_ci_v0_dataplane",
		"otlphttp/cw_k8s_ci_v0_app_logs_dest",
		"otlphttp/cw_k8s_ci_v0_node_logs_dest",
		"otlphttp/cw_k8s_ci_v0_dataplane_logs_dest",
		"sigv4auth/cw_k8s_ci_v0_logs_dest",
	}
	for _, fragment := range logFragments {
		assert.Contains(t, otelConfig, fragment,
			"otelConfig must contain %q when logs=true", fragment)
	}

	// CWA DaemonSet must carry the log mounts (inverse of assertNoLogMounts).
	assertHasLogMounts(t, k8sClient, "cloudwatch-agent")

	// FluentBit ConfigMap should be functional.
	fbCM, err := k8sClient.GetConfigMap(minikube.Namespace, "fluent-bit-config")
	if assert.NoError(t, err) && assert.NotNil(t, fbCM) {
		var found bool
		for _, v := range fbCM.Data {
			if strings.Contains(v, "/var/log/containers/") {
				found = true
				break
			}
		}
		assert.True(t, found, "fluent-bit ConfigMap should reference /var/log/containers/ paths")
	}

	t.Log("OTLP dual-publish scenario validation passed")
}

// assertHasLogMounts is the inverse of assertNoLogMounts: validates the CWA
// DaemonSet carries the expected log-related volume mounts when logs=true.
func assertHasLogMounts(t *testing.T, k8sClient *util.K8sClient, dsName string) {
	t.Helper()
	daemonSets, err := k8sClient.ListDaemonSets(minikube.Namespace)
	if !assert.NoError(t, err) {
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

	requiredVolumes := map[string]bool{
		"varlog":        false,
		"runlogjournal": false,
	}
	for _, vol := range ds.Spec.Template.Spec.Volumes {
		if _, ok := requiredVolumes[vol.Name]; ok {
			requiredVolumes[vol.Name] = true
		}
	}
	for name, found := range requiredVolumes {
		assert.True(t, found, "DaemonSet %q should have volume %q when logs=true", dsName, name)
	}
}
