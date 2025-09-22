// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/stretchr/testify/assert"
)

func TestDeploymentRollingDisabled(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	ds, err := k8sClient.ListDeployments("amazon-cloudwatch")
	assert.NoError(t, err)

	found := false
	for _, d := range ds.Items {
		if d.GetName() != "amazon-cloudwatch-observability-controller-manager" {
			continue
		} else {
			found = true
		}

		_, exists := d.Spec.Template.Annotations["rollme"]
		assert.False(t, exists)
	}
	assert.True(t, found)
}
