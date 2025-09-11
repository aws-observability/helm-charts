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

func TestWebhooksConfigured(t *testing.T) {
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
			// Instrumentation is not configured in this test hence the omission of it
			switch path := *wh.ClientConfig.Service.Path; path {
			case minikube.WebhookPathMutateAmazonCloudWatchAgent:
				assert.Equal(t, v1.Ignore, wh.FailurePolicy)
				assert.Empty(t, wh.NamespaceSelector.MatchExpressions)
			case minikube.WebhookPathMutatePod, minikube.WebhookPathMutateWorkload, minikube.WebhookPathMutateNamespace:
				assert.Equal(t, v1.Fail, wh.FailurePolicy)
				assert.Len(t, wh.NamespaceSelector.MatchExpressions, 1)
				assert.Equal(t, "NotIn", wh.NamespaceSelector.MatchExpressions[0].Key)
				assert.Equal(t, "kubernetes.io/metadata.name", wh.NamespaceSelector.MatchExpressions[0].Operator)
				assert.ElementsMatch(t, []string{"kube-system", "amazon-cloudwatch"}, wh.NamespaceSelector.MatchExpressions[0].Values)
			default:
				assert.Fail(t, "unexpected webhook found: %s", path)
			}
		}
	}

	assert.True(t, foundWebhookConfiguration)
}
