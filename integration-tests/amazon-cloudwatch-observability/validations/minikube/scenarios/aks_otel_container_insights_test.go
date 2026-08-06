// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"context"
	"regexp"
	"strings"
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// clusterName matches clusterName in the scenario's values.yaml. The AKS cloud.resource_id
// derivation templates it into the replace_pattern regex, so the test asserts against it.
const clusterName = "minikube"

// TestAKSOtelContainerInsights validates that installing with k8sMode=AKS renders the
// AKS-specific OTEL Container Insights configuration onto the AmazonCloudWatchAgent CRs.
//
// This asserts on the rendered CRs rather than on running agents: AKS-mode agent pods do not
// become healthy on minikube (no Azure IMDS / workload identity), but the CRs are applied by the
// helm release regardless, so the AKS-specific config they carry is verifiable here.
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

	t.Run("NodeAgentAKSConfig", func(t *testing.T) {
		validateAKSOtelConfig(t, agentMap, "cloudwatch-agent")
	})
	t.Run("ClusterScraperAKSConfig", func(t *testing.T) {
		validateAKSOtelConfig(t, agentMap, "cloudwatch-agent-cluster-scraper")
	})
	t.Run("ServiceAttributes", func(t *testing.T) {
		validateAKSServiceAttributes(t, agentMap)
	})
	t.Run("HostAttributes", func(t *testing.T) {
		validateAKSHostAttributes(t, agentMap)
	})
	t.Run("OTELConfigRouting", func(t *testing.T) {
		validateOTELConfigRoutingAKS(t, agentMap)
	})
	t.Run("WebhookEnforcerDisabled", func(t *testing.T) {
		validateAKSWebhookEnforcerDisabled(t, k8sClient)
	})
	t.Run("ApiserverTLSServerName", func(t *testing.T) {
		validateAKSApiserverTLSServerName(t, agentMap)
	})

	t.Log("AKS OTEL Container Insights scenario validation passed")
}

// otelConfigOf returns the CR's spec.otelConfig, failing the test if it is missing.
func otelConfigOf(t *testing.T, agentMap map[string]unstructured.Unstructured, name string) string {
	t.Helper()
	agent, exists := agentMap[name]
	if !assert.True(t, exists, "%s CR should exist", name) {
		return ""
	}
	spec, ok := agent.Object["spec"].(map[string]interface{})
	if !assert.True(t, ok, "%s spec should be a map", name) {
		return ""
	}
	otelConfig, ok := spec["otelConfig"].(string)
	if !assert.True(t, ok, "%s otelConfig should be a string", name) {
		return ""
	}
	assert.NotEmpty(t, otelConfig, "%s otelConfig should not be empty", name)
	return otelConfig
}

// validateAKSOtelConfig checks that a CR's otelConfig uses the AKS resource detectors and the
// Azure cloud.resource_id derivation, and that no EKS/EC2-specific constructs remain.
func validateAKSOtelConfig(t *testing.T, agentMap map[string]unstructured.Unstructured, name string) {
	otelConfig := otelConfigOf(t, agentMap, name)
	if otelConfig == "" {
		return
	}

	// AKS resource detectors, not EKS/EC2. Match the list entries ("- aks") so an unrelated
	// "azure"-prefixed attribute cannot satisfy the check.
	assert.True(t, strings.Contains(otelConfig, "- aks"),
		"%s otelConfig should use the aks resource detector", name)
	assert.True(t, strings.Contains(otelConfig, "- azure"),
		"%s otelConfig should use the azure resource detector", name)
	assert.False(t, strings.Contains(otelConfig, "- eks"),
		"%s otelConfig should NOT use the eks resource detector on AKS", name)
	assert.False(t, strings.Contains(otelConfig, "- ec2"),
		"%s otelConfig should NOT use the ec2 resource detector on AKS", name)

	assert.True(t, strings.Contains(otelConfig, "Microsoft.ContainerService/managedClusters"),
		"%s cloud.resource_id should be an Azure managedClusters id", name)
	assert.False(t, strings.Contains(otelConfig, "arn:aws:eks:"),
		"%s cloud.resource_id should NOT be an EKS ARN on AKS", name)

	assert.True(t, strings.Contains(otelConfig, "_tmp.azure.resourcegroup.name"),
		"%s should derive the cluster resource group via a scratch attribute", name)
	assert.True(t, strings.Contains(otelConfig, `"^MC_(.+)_`+clusterName+`_[^_]+$"`),
		"%s replace_pattern regex should anchor on the cluster name", name)
	// $$$1 survives Helm ($ passthrough) then confmap ($$->$) to reach OTTL as $1; a bare $1 is eaten
	// as an env-var reference and crashes the agent. Asserted apart from the regex: Helm wraps the
	// long line between the two replace_pattern args.
	assert.True(t, strings.Contains(otelConfig, `"$$$1"`),
		"%s replace_pattern should use the $$$1 backreference", name)
	assert.True(t, strings.Contains(otelConfig, `delete_key`) &&
		strings.Contains(otelConfig, `_tmp.azure.resourcegroup.name`),
		"%s should delete_key the scratch attribute so it does not leak", name)
}

// validateOTELConfigRoutingAKS verifies the AKS overlay did not disturb the node/cluster pipeline split.
func validateOTELConfigRoutingAKS(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	node := otelConfigOf(t, agentMap, "cloudwatch-agent")
	if node != "" {
		assert.True(t, strings.Contains(node, "kubeletstats"),
			"node agent otelConfig should contain the kubeletstats receiver (node-level)")
		assert.False(t, strings.Contains(node, "cw_k8s_ci_v0_apiserver"),
			"node agent otelConfig should NOT contain the apiserver receiver (cluster-level)")
	}
	scraper := otelConfigOf(t, agentMap, "cloudwatch-agent-cluster-scraper")
	if scraper != "" {
		assert.True(t, strings.Contains(scraper, "cw_k8s_ci_v0_apiserver"),
			"cluster-scraper otelConfig should contain the apiserver receiver (cluster-level)")
		assert.False(t, strings.Contains(scraper, "kubeletstats"),
			"cluster-scraper otelConfig should NOT contain the kubeletstats receiver (node-level)")
	}
}

// validateAKSApiserverTLSServerName checks the apiserver scrape verifies TLS against a DNS SAN. On
// AKS, endpoints SD dials the managed control-plane IP, which is absent from the serving cert's SANs,
// so without server_name every scrape fails TLS and no apiserver metrics reach CloudWatch.
func validateAKSApiserverTLSServerName(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	scraper := otelConfigOf(t, agentMap, "cloudwatch-agent-cluster-scraper")
	if scraper == "" {
		return
	}
	assert.True(t, strings.Contains(scraper, "server_name: kubernetes.default.svc"),
		"cluster-scraper otelConfig should set server_name for the apiserver TLS scrape on AKS")
}

// validateAKSServiceAttributes checks the AKS-gated service.*/deployment.environment.name are on the
// node agent but NOT the cluster-scraper (scraper metrics describe other workloads, not its own).
func validateAKSServiceAttributes(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	serviceAttrs := []string{"service.name", "service.namespace", "deployment.environment.name"}

	node := otelConfigOf(t, agentMap, "cloudwatch-agent")
	if node != "" {
		for _, a := range serviceAttrs {
			assert.True(t, strings.Contains(node, a),
				"node agent otelConfig should set %s on AKS", a)
		}
	}

	scraper := otelConfigOf(t, agentMap, "cloudwatch-agent-cluster-scraper")
	if scraper != "" {
		for _, a := range serviceAttrs {
			assert.False(t, strings.Contains(scraper, a),
				"cluster-scraper otelConfig should NOT set %s (scraper metrics describe other workloads)", a)
		}
	}
}

// validateAKSHostAttributes checks host/VM identity attributes are enabled on the node agent but
// disabled on the cluster-scraper (a Deployment whose own host is not the node it scrapes).
func validateAKSHostAttributes(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	hostAttrs := []string{"host.id", "host.name", "azure.vm.name", "azure.vm.scaleset.name", "azure.vm.size"}

	assertEnabled := func(who, otelConfig string, want bool) {
		if otelConfig == "" {
			return
		}
		for _, a := range hostAttrs {
			re := regexp.MustCompile(regexp.QuoteMeta(a) + `:\s*enabled: (true|false)`)
			m := re.FindStringSubmatch(otelConfig)
			if !assert.NotNil(t, m, "%s otelConfig should set enabled for %s", who, a) {
				continue
			}
			assert.Equal(t, want, m[1] == "true",
				"%s otelConfig should have %s enabled=%t", who, a, want)
		}
	}

	assertEnabled("node agent", otelConfigOf(t, agentMap, "cloudwatch-agent"), true)
	assertEnabled("cluster-scraper", otelConfigOf(t, agentMap, "cloudwatch-agent-cluster-scraper"), false)
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
