// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
)

func TestWebhooksDisabled(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	whs, err := k8sClient.ListMutatingWebhookConfigurations()
	assert.NoError(t, err)

	for _, item := range whs.Items {
		assert.NotEqual(t, minikube.WebhookName, item.ObjectMeta.Name)
	}
}
