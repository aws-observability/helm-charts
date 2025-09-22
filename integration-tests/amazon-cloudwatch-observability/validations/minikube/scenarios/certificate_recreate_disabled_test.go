// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"bytes"
	"os"
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
)

const certificateRecreateDisabledPath = "/tmp/test-certificate-recreate-disabled.bin"

func TestCertificateRecreateDisabled_Save(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	data := retrieveCABundle(t, *k8sClient)
	assert.NotNil(t, data)

	err = os.WriteFile(certificateRecreateDisabledPath, data, 0644)
	assert.NoError(t, err)
}

func TestCertificateRecreateDisabled_Compare(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	actualData := retrieveCABundle(t, *k8sClient)
	assert.NotNil(t, actualData)

	savedData, err := os.ReadFile(certificateRecreateDisabledPath)
	assert.NoError(t, err)

	assert.False(t, bytes.Equal(actualData, savedData))
}

func retrieveCABundle(t *testing.T, k8sClient util.K8sClient) []byte {
	whs, err := k8sClient.ListMutatingWebhookConfigurations()
	assert.NoError(t, err)
	assert.NotEmpty(t, whs.Items)

	for _, item := range whs.Items {
		if item.ObjectMeta.Name != minikube.WebhookName {
			continue
		}
		assert.NotEmpty(t, item.Webhooks)
		assert.GreaterOrEqual(t, len(item.Webhooks), 1)

		// Grab the first CA bundle
		data := item.Webhooks[0].ClientConfig.CABundle
		return data
	}
	return nil
}
