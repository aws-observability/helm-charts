// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"context"
	"strings"
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestOTLPCustomOtelConfig(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	if !assert.NoError(t, err) {
		t.Fatal("failed to create k8s client")
	}

	// Validate namespace exists
	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

	// Get the AmazonCloudWatchAgent CR via dynamic client
	dynamicClient, err := k8sClient.GetDynamicClient()
	if !assert.NoError(t, err) {
		t.Fatal("failed to get dynamic client")
	}

	gvr := getAmazonCloudWatchAgentGVR()

	agent, err := dynamicClient.Resource(gvr).Namespace(minikube.Namespace).Get(
		context.Background(), "cloudwatch-agent", metav1.GetOptions{},
	)
	if !assert.NoError(t, err) {
		t.Fatal("failed to get cloudwatch-agent CR")
	}
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

	// Verify generated OTLP CI pipelines are present
	assert.True(t, strings.Contains(otelConfig, "cw_k8s_ci_v0"),
		"merged otelConfig should contain generated OTLP CI pipelines (cw_k8s_ci_v0 prefix)")

	// Verify user-defined custom pipeline is preserved
	assert.True(t, strings.Contains(otelConfig, "custom_test"),
		"merged otelConfig should contain user-defined custom pipeline (custom_test prefix)")

	// Verify generated config takes precedence on name collision
	// The user provided sigv4auth/cw_k8s_ci_v0_metrics_dest with service: "should-be-overwritten"
	// The generated config has service: monitoring — generated should win
	assert.True(t, strings.Contains(otelConfig, "service: monitoring"),
		"merged otelConfig should contain generated value 'service: monitoring' for sigv4auth")
	assert.False(t, strings.Contains(otelConfig, "should-be-overwritten"),
		"merged otelConfig should NOT contain user's conflicting value 'should-be-overwritten'")

	t.Log("OTLP custom otel config merge scenario validation passed")
}
