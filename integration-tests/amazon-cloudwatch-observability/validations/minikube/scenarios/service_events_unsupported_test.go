// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
)

func TestServiceEventsUnsupported(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	// Validate operator deployment exists
	exists, err := k8sClient.ValidateDeploymentExists(minikube.Namespace, minikube.OperatorName)
	assert.NoError(t, err)
	assert.True(t, exists)

	// In an unsupported region (us-west-1), the chart injects service_events.enabled: "false"
	// for the Service Events languages (java, python, nodejs) and leaves dotnet untouched
	// (no Service Events SDK).
	config := minikube.GetOperatorAutoInstrumentationConfig(t)

	for _, lang := range []string{"java", "python", "nodejs"} {
		langConfig, ok := config[lang].(map[string]interface{})
		assert.True(t, ok, "language %s not found in auto-instrumentation-config", lang)

		serviceEvents, ok := langConfig["service_events"].(map[string]interface{})
		assert.True(t, ok, "service_events not found for %s", lang)
		assert.Equal(t, "false", serviceEvents["enabled"], "service_events.enabled should be false for %s in unsupported region", lang)
	}

	// dotnet has no Service Events SDK, so it should never carry service_events config.
	dotnetConfig, ok := config["dotnet"].(map[string]interface{})
	assert.True(t, ok, "dotnet not found in auto-instrumentation-config")
	_, hasServiceEvents := dotnetConfig["service_events"]
	assert.False(t, hasServiceEvents, "dotnet should not have service_events config")

	t.Log("Service Events unsupported region validation passed")
}
