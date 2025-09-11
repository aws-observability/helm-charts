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
	// Default config has AppSignals enabled, so monitorAllServices should be true
	expectedConfig := map[string]interface{}{
		"monitorAllServices": true,
		"languages":          []interface{}{"java", "python", "dotnet", "nodejs"},
	}
	minikube.ValidateOperatorAutoMonitorConfig(t, expectedConfig)

	t.Log("Default scenario validation passed")
}
