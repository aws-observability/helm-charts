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
}

func validateCustomEndpointNotOverwritten(t *testing.T, k8sClient *util.K8sClient) {
	configMap, err := k8sClient.GetConfigMap(minikube.Namespace, "fluent-bit-config")
	assert.NoError(t, err)

	appLogConf, exists := configMap.Data["application-log.conf"]
	assert.True(t, exists, "application-log.conf should exist")

	assert.Contains(t, appLogConf, "logs.custom-endpoint.example.com", "custom endpoint should be preserved")
	assert.NotContains(t, appLogConf, "logs.${AWS_REGION}.api.aws", "dualstack endpoint should not be added when custom endpoint exists")
}
