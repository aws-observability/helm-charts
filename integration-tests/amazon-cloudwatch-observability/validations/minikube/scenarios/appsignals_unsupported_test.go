// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
)

func TestAppSignalsUnsupported(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	// Validate operator deployment exists
	exists, err := k8sClient.ValidateDeploymentExists(minikube.Namespace, "amazon-cloudwatch-observability-controller-manager")
	assert.NoError(t, err)
	assert.True(t, exists)

	// Validate auto-monitor-config has monitorAllServices: false
	// for ap-east-2 (unsupported region) even with AppSignals enabled
	expectedConfig := map[string]interface{}{
		"monitorAllServices": false,
		"languages":          []interface{}{"java", "python", "dotnet", "nodejs"},
	}
	minikube.ValidateOperatorAutoMonitorConfig(t, expectedConfig)

	t.Log("AppSignals unsupported region validation passed")
}
