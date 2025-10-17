// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
)

func TestDeploymentRollingDisabled(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	ds, err := k8sClient.ListDeployments(minikube.Namespace)
	assert.NoError(t, err)

	found := false
	for _, d := range ds.Items {
		if d.GetName() != minikube.OperatorName {
			continue
		} else {
			found = true
		}

		_, exists := d.Spec.Template.Annotations["rollme"]
		assert.False(t, exists)
	}
	assert.True(t, found)
}
