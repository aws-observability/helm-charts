// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
)

// TestDefault validates the out-of-box default install behavior.
//
// Default corresponds to state 2 in the CI flag state matrix (see values.yaml):
//   containerInsights.enabled       = true  (default)
//   containerLogs.enabled           = true  (default)
//   otelContainerInsights.enabled   = false (default — OTEL is opt-in)
//   otelContainerInsights.logs      = false (default — OTEL logs are opt-in)
//
// Result: legacy ECI metrics via CloudWatch Agent + FluentBit logs. No OTEL
// Container Insights resources (cluster-scraper, kube-state-metrics, node-exporter).
// This matches v6.x behavior — customers upgrading see no change unless they
// explicitly opt into OTEL.
func TestDefault(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	// Validate namespace exists
	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

	// Validate operator deployment exists (always present regardless of CI flags)
	exists, err := k8sClient.ValidateDeploymentExists(minikube.Namespace, "amazon-cloudwatch-observability-controller-manager")
	assert.NoError(t, err)
	assert.True(t, exists)

	// Validate auto-monitor-config uses default values
	// Default config has AppSignals enabled and us-west-2 is a supported region, so monitorAllServices should be true
	expectedConfig := map[string]interface{}{
		"monitorAllServices": true,
		"languages":          []interface{}{"java", "python", "dotnet", "nodejs"},
	}
	minikube.ValidateOperatorAutoMonitorConfig(t, expectedConfig)

	t.Run("LegacyCIResourcesExist", func(t *testing.T) {
		// CloudWatch Agent DaemonSet exists for legacy ECI metrics
		// (created via AmazonCloudWatchAgent CR named "cloudwatch-agent")
		exists, err := k8sClient.ValidateDaemonSetExists(minikube.Namespace, "cloudwatch-agent")
		assert.NoError(t, err)
		assert.True(t, exists, "cloudwatch-agent DaemonSet should exist (legacy ECI metrics)")

		// FluentBit DaemonSet exists for legacy log pipeline
		exists, err = k8sClient.ValidateDaemonSetExists(minikube.Namespace, "fluent-bit")
		assert.NoError(t, err)
		assert.True(t, exists, "fluent-bit DaemonSet should exist (legacy log pipeline)")
	})

	t.Run("OTELCIResourcesAbsent", func(t *testing.T) {
		// OTEL CI is opt-in — no OTEL-specific resources should exist by default

		exists, err := k8sClient.ValidateDeploymentExists(minikube.Namespace, "kube-state-metrics")
		assert.NoError(t, err)
		assert.False(t, exists, "kube-state-metrics deployment should NOT exist when otelContainerInsights.enabled=false")

		exists, err = k8sClient.ValidateDeploymentExists(minikube.Namespace, "cloudwatch-agent-cluster-scraper")
		assert.NoError(t, err)
		assert.False(t, exists, "cloudwatch-agent-cluster-scraper deployment should NOT exist when otelContainerInsights.enabled=false")

		exists, err = k8sClient.ValidateDaemonSetExists(minikube.Namespace, "node-exporter")
		assert.NoError(t, err)
		assert.False(t, exists, "node-exporter daemonset should NOT exist when otelContainerInsights.enabled=false")

		exists, err = k8sClient.ValidateServiceExists(minikube.Namespace, "kube-state-metrics")
		assert.NoError(t, err)
		assert.False(t, exists, "kube-state-metrics service should NOT exist when otelContainerInsights.enabled=false")
	})

	t.Run("DualstackEndpointsNotPresent", func(t *testing.T) {
		validateDualstackEndpointsNotPresent(t, k8sClient)
	})

	t.Log("Default scenario validation passed")
}

// validateDualstackEndpointsNotPresent ensures dualstack endpoints are NOT added when useDualstackEndpoint is false (default)
func validateDualstackEndpointsNotPresent(t *testing.T, k8sClient *util.K8sClient) {
	configMap, err := k8sClient.GetConfigMap(minikube.Namespace, "fluent-bit-config")
	assert.NoError(t, err)

	logConfigs := []string{"application-log.conf", "dataplane-log.conf", "host-log.conf"}
	for _, configName := range logConfigs {
		conf, exists := configMap.Data[configName]
		assert.True(t, exists, "%s should exist", configName)
		assert.NotContains(t, conf, "logs.${AWS_REGION}.api.aws", "%s should not contain dualstack logs endpoint when dualstack is disabled", configName)
		assert.NotContains(t, conf, "sts.${AWS_REGION}.api.aws", "%s should not contain dualstack sts endpoint when dualstack is disabled", configName)
	}

	fluentBitConf, exists := configMap.Data["fluent-bit.conf"]
	assert.True(t, exists, "fluent-bit.conf should exist")
	assert.NotContains(t, fluentBitConf, "net.dns.prefer_ipv6       true", "IPv6 preference should not be set when dualstack is disabled")
}
