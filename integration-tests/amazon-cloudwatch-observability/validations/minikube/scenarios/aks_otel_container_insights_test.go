// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"context"
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// clusterName matches clusterName in the scenario's values.yaml and is the value the chart writes
// into opentelemetry.cluster_name in spec.config. Shared by the container_insights asserters.
const clusterName = "minikube"

// TestAKSOtelContainerInsights validates that installing with k8sMode=AKS renders the
// AmazonCloudWatchAgent CRs with the expected OTel Container Insights surface.
//
// The CloudWatch Agent builds the AKS CI pipelines at runtime from the
// opentelemetry.collect.container_insights block in spec.config, so here we assert that block is
// emitted with correct roles, no chart-generated otelConfig, and the AKS webhook-enforcer annotation.
//
// This asserts on the rendered CRs rather than on running agents: AKS-mode agent pods do not
// become healthy on minikube (no Azure IMDS / workload identity), but the CRs are applied by the
// helm release regardless, so the config they carry is verifiable here.
func TestAKSOtelContainerInsights(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	require.NoError(t, err, "failed to create k8s client")

	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

	exists, err := k8sClient.ValidateDeploymentExists(minikube.Namespace, "amazon-cloudwatch-observability-controller-manager")
	assert.NoError(t, err)
	assert.True(t, exists, "operator deployment should exist")

	dynamicClient, err := k8sClient.GetDynamicClient()
	require.NoError(t, err, "failed to get dynamic client")

	gvr := schema.GroupVersionResource{
		Group:    "cloudwatch.aws.amazon.com",
		Version:  "v1alpha1",
		Resource: "amazoncloudwatchagents",
	}
	agentList, err := dynamicClient.Resource(gvr).Namespace(minikube.Namespace).List(
		context.Background(), metav1.ListOptions{},
	)
	require.NoError(t, err, "failed to list AmazonCloudWatchAgent CRs")

	agentMap := make(map[string]unstructured.Unstructured)
	for _, agent := range agentList.Items {
		agentMap[agent.GetName()] = agent
	}

	// otelContainerInsights.logs.enabled=true in this scenario's values.
	t.Run("NodeAgentContainerInsights", func(t *testing.T) {
		assertNodeContainerInsights(t, agentMap, "cloudwatch-agent", true)
	})
	t.Run("ClusterScraperContainerInsights", func(t *testing.T) {
		assertClusterScraperContainerInsights(t, agentMap, "cloudwatch-agent-cluster-scraper")
	})
	t.Run("WebhookEnforcerDisabled", func(t *testing.T) {
		validateAKSWebhookEnforcerDisabled(t, k8sClient)
	})

	t.Log("AKS OTEL Container Insights scenario validation passed")
}

// validateAKSWebhookEnforcerDisabled checks the webhook configurations carry the
// admissions.enforcer/disabled annotation on AKS. Without it, the AKS admissionsenforcer rewrites each
// webhook's namespaceSelector and takes server-side-apply ownership of the field, which makes the next
// helm upgrade fail with an apply conflict.
func validateAKSWebhookEnforcerDisabled(t *testing.T, k8sClient *util.K8sClient) {
	const enforcerDisabled = "admissions.enforcer/disabled"

	mwc, err := k8sClient.ListMutatingWebhookConfigurations()
	require.NoError(t, err, "failed to list MutatingWebhookConfigurations")
	assertEnforcerDisabled := func(name string, annotations map[string]string) {
		assert.Equal(t, "true", annotations[enforcerDisabled],
			"%s should set %s on AKS", name, enforcerDisabled)
	}

	foundMutating := false
	for _, wh := range mwc.Items {
		if wh.Name == minikube.WebhookName {
			foundMutating = true
			assertEnforcerDisabled(wh.Name, wh.Annotations)
		}
	}
	assert.True(t, foundMutating, "mutating webhook configuration %s should exist", minikube.WebhookName)

	vwc, err := k8sClient.ListValidatingWebhookConfigurations()
	require.NoError(t, err, "failed to list ValidatingWebhookConfigurations")
	validatingName := "amazon-cloudwatch-observability-validating-webhook-configuration"
	foundValidating := false
	for _, wh := range vwc.Items {
		if wh.Name == validatingName {
			foundValidating = true
			assertEnforcerDisabled(wh.Name, wh.Annotations)
		}
	}
	assert.True(t, foundValidating, "validating webhook configuration %s should exist", validatingName)
}
