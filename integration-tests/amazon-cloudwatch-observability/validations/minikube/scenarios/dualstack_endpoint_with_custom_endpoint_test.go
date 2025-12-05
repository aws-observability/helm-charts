// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
)

func TestDualstackEndpointWithCustomEndpoint(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	// Validate namespace exists
	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	if !assert.NoError(t, err) {
		t.Fatal("Failed to get namespace, cannot continue test")
	}
	assert.Equal(t, minikube.Namespace, ns.Name)

	// Validate operator deployment exists
	exists, err := k8sClient.ValidateDeploymentExists(minikube.Namespace, "amazon-cloudwatch-observability-controller-manager")
	assert.NoError(t, err)
	assert.True(t, exists)

	t.Run("CustomEndpointNotOverwritten", func(t *testing.T) {
		validateCustomEndpointNotOverwritten(t, k8sClient)
	})

	t.Run("OtherConfigsStillGetDualstack", func(t *testing.T) {
		validateOtherConfigsStillGetDualstack(t, k8sClient)
	})

	t.Run("CloudWatchAgentStillHasDualstack", func(t *testing.T) {
		validateCloudWatchAgentDualstackEndpoint(t, k8sClient)
	})

	t.Run("FluentBitIPv6PreferenceStillSet", func(t *testing.T) {
		validateFluentBitIPv6PreferenceStillSet(t, k8sClient)
	})
}

func validateCustomEndpointNotOverwritten(t *testing.T, k8sClient *util.K8sClient) {
	configMap, err := k8sClient.GetConfigMap(minikube.Namespace, "fluent-bit-config")
	assert.NoError(t, err)

	appLogConf, exists := configMap.Data["application-log.conf"]
	assert.True(t, exists, "application-log.conf should exist")

	// Validate custom endpoint is preserved
	assert.Contains(t, appLogConf, "logs.custom-endpoint.example.com", "custom endpoint should be preserved")
	assert.NotContains(t, appLogConf, "logs.${AWS_REGION}.api.aws", "dualstack endpoint should not be added when custom endpoint exists")

	// Validate custom sts_endpoint is preserved
	assert.Contains(t, appLogConf, "sts.custom-endpoint.example.com", "custom sts_endpoint should be preserved")
	assert.NotContains(t, appLogConf, "sts.${AWS_REGION}.api.aws", "dualstack sts_endpoint should not be added when custom sts_endpoint exists")
}

func validateOtherConfigsStillGetDualstack(t *testing.T, k8sClient *util.K8sClient) {
	configMap, err := k8sClient.GetConfigMap(minikube.Namespace, "fluent-bit-config")
	assert.NoError(t, err)

	configsWithoutCustomEndpoint := []string{"dataplane-log.conf", "host-log.conf"}
	for _, configName := range configsWithoutCustomEndpoint {
		conf, exists := configMap.Data[configName]
		assert.True(t, exists, "%s should exist", configName)
		assert.Contains(t, conf, "logs.${AWS_REGION}.api.aws", "%s should contain dualstack logs endpoint since no custom endpoint is set", configName)
		assert.Contains(t, conf, "sts.${AWS_REGION}.api.aws", "%s should contain dualstack sts endpoint since no custom endpoint is set", configName)
	}
}

func validateFluentBitIPv6PreferenceStillSet(t *testing.T, k8sClient *util.K8sClient) {
	configMap, err := k8sClient.GetConfigMap(minikube.Namespace, "fluent-bit-config")
	assert.NoError(t, err)

	fluentBitConf, exists := configMap.Data["fluent-bit.conf"]
	assert.True(t, exists, "fluent-bit.conf should exist")
	assert.Contains(t, fluentBitConf, "net.dns.prefer_ipv6       true", "IPv6 preference should still be set even with custom endpoint")
}
