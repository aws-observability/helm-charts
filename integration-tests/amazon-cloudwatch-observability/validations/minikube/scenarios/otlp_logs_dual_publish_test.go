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
	appsV1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// TestOTLPLogsDualPublish covers state #8: otelContainerInsights.enabled=true,
// otelContainerInsights.logs.enabled=true, containerLogs.enabled=true.
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
	require.NoError(t, err, "failed to create k8s client")

	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	require.NoError(t, err)
	require.Equal(t, minikube.Namespace, ns.Name)

	// FluentBit DaemonSet must be present alongside OTEL logs.
	exists, err := k8sClient.ValidateDaemonSetExists(minikube.Namespace, "fluent-bit")
	assert.NoError(t, err)
	assert.True(t, exists, "fluent-bit DaemonSet should be deployed when containerLogs.enabled=true")

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
		"logs/cw_k8s_ci_v0_app",
		"logs/cw_k8s_ci_v0_node",
		"otlphttp/cw_k8s_ci_v0_app_logs_dest",
		"otlphttp/cw_k8s_ci_v0_node_logs_dest",
		"sigv4auth/cw_k8s_ci_v0_logs_dest",
	}
	for _, fragment := range logFragments {
		assert.Contains(t, otelConfig, fragment,
			"otelConfig must contain %q when logs=true", fragment)
	}

	// file_storage checkpoint extension must be configured.
	assertCheckpointConfigPresent(t, otelConfig)

	// CWA DaemonSet must carry the log mounts (inverse of assertNoLogMounts).
	assertHasLogMounts(t, k8sClient, "cloudwatch-agent")

	// CWA DaemonSet must have the checkpoint volume (writable hostPath).
	assertHasCheckpointVolume(t, k8sClient, "cloudwatch-agent")

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
		"varlog": false,
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

// assertCheckpointConfigPresent validates that the file_storage extension and
// storage wiring are present in the otelConfig when logs are enabled.
func assertCheckpointConfigPresent(t *testing.T, otelConfig string) {
	t.Helper()
	assert.Contains(t, otelConfig, "file_storage/cw_k8s_ci_v0_logs_checkpoint",
		"file_storage extension must be declared in otelConfig")
	assert.Equal(t, 4, strings.Count(otelConfig, "storage: file_storage/cw_k8s_ci_v0_logs_checkpoint"),
		"expected 4 storage references: 2 filelog receivers + 2 exporter sending_queues")
}

// assertHasCheckpointVolume validates the CWA DaemonSet has the writable
// otel-logs-checkpoints hostPath volume and mount.
func assertHasCheckpointVolume(t *testing.T, k8sClient *util.K8sClient, dsName string) {
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

	var foundVolume bool
	for _, vol := range ds.Spec.Template.Spec.Volumes {
		if vol.Name == "otel-logs-checkpoints" {
			foundVolume = true
			if assert.NotNil(t, vol.HostPath, "otel-logs-checkpoints volume must be hostPath") {
				assert.Equal(t, "/var/lib/cwagent/otel-logs-checkpoints", vol.HostPath.Path)
				assert.NotNil(t, vol.HostPath.Type)
				assert.Equal(t, corev1.HostPathDirectoryOrCreate, *vol.HostPath.Type)
			}
			break
		}
	}
	assert.True(t, foundVolume, "DaemonSet %q must have otel-logs-checkpoints volume", dsName)

	var foundMount bool
	for _, c := range ds.Spec.Template.Spec.Containers {
		for _, vm := range c.VolumeMounts {
			if vm.Name == "otel-logs-checkpoints" {
				foundMount = true
				assert.Equal(t, "/var/lib/cwagent/otel-logs-checkpoints", vm.MountPath)
				assert.False(t, vm.ReadOnly, "otel-logs-checkpoints mount must be writable")
			}
		}
	}
	assert.True(t, foundMount, "DaemonSet %q must mount otel-logs-checkpoints", dsName)
}
