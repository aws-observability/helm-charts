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
	operatorName = "amazon-cloudwatch-observability-controller-manager"

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
		if deployments.Items[i].Name == operatorName {
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
