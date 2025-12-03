// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func TestDualstackEndpointEnabled(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	// Validate namespace exists
	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	if !assert.NoError(t, err) {
		t.Fatal("Failed to get namespace, cannot continue test")
	}
	assert.Equal(t, minikube.Namespace, ns.Name)

	// Validate operator deployment exists
	exists, err := k8sClient.ValidateDeploymentExists(minikube.Namespace, "amazon-cloudwatch-observability-controller-manager")
	assert.NoError(t, err)
	assert.True(t, exists)

	t.Run("CloudWatchAgentDualstackEndpoint", func(t *testing.T) {
		validateCloudWatchAgentDualstackEndpoint(t, k8sClient)
	})

	t.Run("FluentBitDualstackEndpoints", func(t *testing.T) {
		validateFluentBitDualstackEndpoints(t, k8sClient)
	})

	t.Run("FluentBitIPv6Preference", func(t *testing.T) {
		validateFluentBitIPv6Preference(t, k8sClient)
	})
}

func validateCloudWatchAgentDualstackEndpoint(t *testing.T, k8sClient *util.K8sClient) {
	dynamicClient, err := k8sClient.GetDynamicClient()
	assert.NoError(t, err)

	agentList, err := dynamicClient.Resource(getAmazonCloudWatchAgentGVR()).
		Namespace(minikube.Namespace).
		List(context.Background(), metav1.ListOptions{})
	assert.NoError(t, err)
	assert.NotEmpty(t, agentList.Items, "No CloudWatch Agent resources found")

	foundDualstackConfig := false
	for _, agent := range agentList.Items {
		spec, found := agent.Object["spec"].(map[string]any)
		if !found {
			continue
		}

		configStr, found := spec["config"].(string)
		if !found {
			continue
		}

		var config map[string]any
		if err := json.Unmarshal([]byte(configStr), &config); err != nil {
			continue
		}

		if agentConfig, ok := config["agent"].(map[string]any); ok {
			if useDualstack, ok := agentConfig["use_dualstack_endpoint"].(bool); ok && useDualstack {
				foundDualstackConfig = true
				break
			}
		}
	}

	assert.True(t, foundDualstackConfig, "use_dualstack_endpoint should be true in CloudWatch Agent config")
}

func validateFluentBitDualstackEndpoints(t *testing.T, k8sClient *util.K8sClient) {
	configMap, err := k8sClient.GetConfigMap(minikube.Namespace, "fluent-bit-config")
	assert.NoError(t, err)

	// Validate dualstack endpoints in all log configuration files
	logConfigs := []string{"application-log.conf", "dataplane-log.conf", "host-log.conf"}
	for _, configName := range logConfigs {
		conf, exists := configMap.Data[configName]
		assert.True(t, exists, "%s should exist", configName)
		assert.Contains(t, conf, "logs.${AWS_REGION}.api.aws", "%s should contain dualstack logs endpoint", configName)
		assert.Contains(t, conf, "sts.${AWS_REGION}.api.aws", "%s should contain dualstack sts endpoint", configName)
		// Verify standard endpoints are NOT present when dualstack is enabled
		assert.NotContains(t, conf, "logs.${AWS_REGION}.amazonaws.com", "%s should not contain standard logs endpoint when dualstack is enabled", configName)
	}
}

func validateFluentBitIPv6Preference(t *testing.T, k8sClient *util.K8sClient) {
	configMap, err := k8sClient.GetConfigMap(minikube.Namespace, "fluent-bit-config")
	assert.NoError(t, err)

	fluentBitConf, exists := configMap.Data["fluent-bit.conf"]
	assert.True(t, exists, "fluent-bit.conf should exist")
	assert.Contains(t, fluentBitConf, "net.dns.prefer_ipv6       true")
}

func getAmazonCloudWatchAgentGVR() schema.GroupVersionResource {
	return schema.GroupVersionResource{
		Group:    "cloudwatch.aws.amazon.com",
		Version:  "v1alpha1",
		Resource: "amazoncloudwatchagents",
	}
}
