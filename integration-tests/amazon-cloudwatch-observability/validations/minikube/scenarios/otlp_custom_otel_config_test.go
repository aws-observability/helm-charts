// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestOTLPCustomOtelConfig(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	require.NoError(t, err, "failed to create k8s client")

	// Validate namespace exists
	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

	// Get the AmazonCloudWatchAgent CR via dynamic client
	dynamicClient, err := k8sClient.GetDynamicClient()
	require.NoError(t, err, "failed to get dynamic client")

	gvr := getAmazonCloudWatchAgentGVR()

	agent, err := dynamicClient.Resource(gvr).Namespace(minikube.Namespace).Get(
		context.Background(), "cloudwatch-agent", metav1.GetOptions{},
	)
	require.NoError(t, err, "failed to get cloudwatch-agent CR")
	if !assert.NotNil(t, agent, "cloudwatch-agent CR should exist") {
		t.Fatal("cloudwatch-agent CR is nil")
	}

	// Extract otelConfig from the CR spec
	spec, ok := agent.Object["spec"].(map[string]interface{})
	assert.True(t, ok, "spec should be a map")

	otelConfig, ok := spec["otelConfig"].(string)
	assert.True(t, ok, "otelConfig should be a string")
	assert.NotEmpty(t, otelConfig, "otelConfig should not be empty")

	t.Logf("otelConfig length: %d", len(otelConfig))

	// The CloudWatch Agent builds CI from spec.config, so the customer-supplied agent.otelConfig
	// passes through verbatim with no chart overwrite.

	// User-defined custom pipeline is preserved verbatim.
	assert.True(t, strings.Contains(otelConfig, "custom_test"),
		"otelConfig should contain the user-defined custom pipeline (custom_test prefix)")

	// The user's value on the sigv4auth/cw_k8s_ci_v0_metrics_dest key survives verbatim: chart CI
	// lives in spec.config, so there is no chart-generated otelConfig entry to overwrite it.
	assert.True(t, strings.Contains(otelConfig, "should-be-overwritten"),
		"otelConfig should preserve the user's sigv4auth service value verbatim (no chart CI overwrite)")

	// The chart-generated collision value must NOT appear — chart CI lands in spec.config, not otelConfig.
	assert.False(t, strings.Contains(otelConfig, "service: monitoring"),
		"otelConfig should NOT contain a chart-generated 'service: monitoring' (CI no longer merged into otelConfig)")

	// Chart-generated CI appears in spec.config as opentelemetry.collect.container_insights
	// (role=node), not in otelConfig.
	configStr, ok := spec["config"].(string)
	if assert.True(t, ok, "config should be a string") {
		var config map[string]interface{}
		if assert.NoError(t, json.Unmarshal([]byte(configStr), &config), "config should be valid JSON") {
			ci := containerInsightsOf(config)
			if assert.NotNil(t, ci, "cloudwatch-agent spec.config should carry opentelemetry.collect.container_insights") {
				assert.Equal(t, "node", ci["role"], "container_insights.role should be node")
			}
		}
	}

	t.Log("OTLP custom otel config passthrough scenario validation passed")
}
