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

const certificateRecreateEnabledPath = "/tmp/test-certificate-recreate-disabled.bin"

func TestCertificateRecreateEnabled_Save(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	data := retrieveCABundle(t, *k8sClient)
	assert.NotNil(t, data)

	err = os.WriteFile(certificateRecreateDisabledPath, data, 0644)
}

func TestCertificateRecreateEnabled_Compare(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	actualData := retrieveCABundle(t, *k8sClient)
	assert.NotNil(t, actualData)

	savedData, err := os.ReadFile(certificateRecreateEnabledPath)
	assert.NoError(t, err)

	assert.True(t, bytes.Equal(actualData, savedData))
}
