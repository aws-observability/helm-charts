// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	v1 "k8s.io/api/admissionregistration/v1"
)

func TestWebhooksPartiallyEnabled(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	whs, err := k8sClient.ListMutatingWebhookConfigurations()
	assert.NoError(t, err)
	assert.NotEmpty(t, whs.Items)

	foundWebhookConfiguration := false
	for _, item := range whs.Items {
		if item.ObjectMeta.Name == minikube.WebhookName {
			foundWebhookConfiguration = true
		} else {
			continue
		}
		assert.NotEmpty(t, item.Webhooks)

		for _, wh := range item.Webhooks {
			// Only the pod webhook is configured
			switch path := *wh.ClientConfig.Service.Path; path {
			case minikube.WebhookPathMutatePod:
				assert.Equal(t, v1.Ignore, *wh.FailurePolicy)
			default:
				assert.Fail(t, "unexpected webhook found: %s", path)
			}
		}
	}

	assert.True(t, foundWebhookConfiguration)
}
