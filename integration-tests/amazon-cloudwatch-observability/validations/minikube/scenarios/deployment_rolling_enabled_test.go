// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"bytes"
	"os"
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/stretchr/testify/assert"
)

const deploymentRollingEnabledPath = "/tmp/test-deployment-rolling-enabled.bin"

func TestDeploymentRollingEnabled_Save(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	data := retrieveRollMe(t, *k8sClient)
	assert.NotNil(t, data)

	err = os.WriteFile(deploymentRollingEnabledPath, data, 0644)
	assert.NoError(t, err)
}

func TestDeploymentRollingEnabled_Compare(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	actualData := retrieveRollMe(t, *k8sClient)
	assert.NotNil(t, actualData)

	savedData, err := os.ReadFile(deploymentRollingEnabledPath)
	assert.NoError(t, err)

	assert.False(t, bytes.Equal(actualData, savedData))
}

func retrieveRollMe(t *testing.T, k8sClient util.K8sClient) []byte {
	ds, err := k8sClient.ListDeployments("amazon-cloudwatch")
	assert.NoError(t, err)

	for _, d := range ds.Items {
		if d.GetName() != "amazon-cloudwatch-observability-controller-manager" {
			continue
		}

		value := d.Spec.Template.Annotations["rollme"]
		return []byte(value)
	}
	return nil
}
