// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
)

func TestDefault(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	// Validate namespace exists
	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

	// Validate operator deployment exists
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
