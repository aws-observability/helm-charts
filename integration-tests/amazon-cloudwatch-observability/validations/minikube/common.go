// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package minikube

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/stretchr/testify/assert"
	appsV1 "k8s.io/api/apps/v1"
)

const (
	Namespace    = "amazon-cloudwatch"
	OperatorName = "amazon-cloudwatch-observability-controller-manager"

	WebhookName                              = "amazon-cloudwatch-observability-mutating-webhook-configuration"
	WebhookPathMutateInstrumentation         = "/mutate-cloudwatch-aws-amazon-com-v1alpha1-instrumentation"
	WebhookPathMutateAmazonCloudWatchAgent   = "/mutate-cloudwatch-aws-amazon-com-v1alpha1-amazoncloudwatchagent"
	WebhookPathMutatePod                     = "/mutate-v1-pod"
	WebhookPathMutateNamespace               = "/mutate-v1-namespace"
	WebhookPathMutateWorkload                = "/mutate-v1-workload"
	WebhookPathValidateInstrumentation       = "/validate-cloudwatch-aws-amazon-com-v1alpha1-instrumentation"
	WebhookPathValidateAmazonCloudWatchAgent = "/validate-cloudwatch-aws-amazon-com-v1alpha1-amazoncloudwatchagent"
)

func ValidateOperatorAutoMonitorConfig(t *testing.T, expectedConfig map[string]interface{}) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	deployments, err := k8sClient.ListDeployments(Namespace)
	assert.NoError(t, err)

	// Find the operator deployment by name
	var deployment *appsV1.Deployment
	for i := range deployments.Items {
		if deployments.Items[i].Name == OperatorName {
			deployment = &deployments.Items[i]
			break
		}
	}
	assert.NotNil(t, deployment, "operator deployment not found")

	// Find the auto-monitor-config argument
	var autoMonitorArg string
	for _, container := range deployment.Spec.Template.Spec.Containers {
		for _, arg := range container.Args {
			if strings.HasPrefix(arg, "--auto-monitor-config=") {
				autoMonitorArg = strings.TrimPrefix(arg, "--auto-monitor-config=")
				break
			}
		}
	}

	assert.NotEmpty(t, autoMonitorArg, "auto-monitor-config argument not found")

	// Parse the JSON config
	var config map[string]interface{}
	err = json.Unmarshal([]byte(autoMonitorArg), &config)
	assert.NoError(t, err)

	// Validate config matches expected values
	for key, expectedValue := range expectedConfig {
		actualValue, exists := config[key]
		assert.True(t, exists, "key %s not found in config", key)
		assert.Equal(t, expectedValue, actualValue, "mismatch for key %s", key)
	}

	t.Logf("auto-monitor-config: %s", autoMonitorArg)
}

// GetOperatorAutoInstrumentationConfig returns the parsed --auto-instrumentation-config argument
// from the operator deployment, keyed by language.
func GetOperatorAutoInstrumentationConfig(t *testing.T) map[string]interface{} {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	deployments, err := k8sClient.ListDeployments(Namespace)
	assert.NoError(t, err)

	// Find the operator deployment by name
	var deployment *appsV1.Deployment
	for i := range deployments.Items {
		if deployments.Items[i].Name == OperatorName {
			deployment = &deployments.Items[i]
			break
		}
	}
	assert.NotNil(t, deployment, "operator deployment not found")

	// Find the auto-instrumentation-config argument
	var autoInstrumentationArg string
	for _, container := range deployment.Spec.Template.Spec.Containers {
		for _, arg := range container.Args {
			if strings.HasPrefix(arg, "--auto-instrumentation-config=") {
				autoInstrumentationArg = strings.TrimPrefix(arg, "--auto-instrumentation-config=")
				break
			}
		}
	}

	assert.NotEmpty(t, autoInstrumentationArg, "auto-instrumentation-config argument not found")

	// Parse the JSON config
	var config map[string]interface{}
	err = json.Unmarshal([]byte(autoInstrumentationArg), &config)
	assert.NoError(t, err)

	t.Logf("auto-instrumentation-config: %s", autoInstrumentationArg)
	return config
}

// OTEL CI assertions — CI is delivered via spec.config JSON (operator generates
// the pipeline), so tests assert on spec.config, not spec.otelConfig.

// otelCIMarker matches the V2 container_insights block.
const otelCIMarker = `"container_insights":{`

// AssertOtelContainerInsights asserts OTEL CI is enabled with the given role (node|cluster).
func AssertOtelContainerInsights(t *testing.T, config, role string) {
	assert.Contains(t, config, otelCIMarker,
		"config must enable opentelemetry.collect.container_insights")
	assert.Contains(t, config, `"role":"`+role+`"`,
		"container_insights role must be %q", role)
}

// AssertOtelCILogsEnabled asserts the container_insights logs toggle.
func AssertOtelCILogsEnabled(t *testing.T, config string, enabled bool) {
	if enabled {
		assert.Contains(t, config, `"logs":{"enabled":true}`,
			"container_insights logs must be enabled")
	} else {
		assert.Contains(t, config, `"logs":{"enabled":false}`,
			"container_insights logs must be disabled")
	}
}

// AssertOtelCILogs asserts presence/absence of the CI logs pipeline in the chart-provided
// otelConfig. In the hybrid model, metrics come from spec.config (JSON) and logs from
// spec.otelConfig, so log collection is verified here rather than via spec.config.
func AssertOtelCILogs(t *testing.T, otelConfig string, present bool) {
	if present {
		assert.Contains(t, otelConfig, "cw_k8s_ci_v0_app_logs_dest",
			"CI logs pipeline must be present in otelConfig")
	} else {
		assert.NotContains(t, otelConfig, "cw_k8s_ci_v0_app_logs_dest",
			"CI logs pipeline must not be present in otelConfig")
	}
}

// AssertNoOtelContainerInsights asserts OTEL CI is not configured.
func AssertNoOtelContainerInsights(t *testing.T, config string) {
	assert.NotContains(t, config, otelCIMarker,
		"config must not enable opentelemetry.collect.container_insights")
}
