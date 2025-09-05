// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

//go:build linuxonly || windowslinux

package eks

import (
	"regexp"
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/stretchr/testify/assert"
	appsV1 "k8s.io/api/apps/v1"
	v1 "k8s.io/api/core/v1"
)

const (
	namespace            = "amazon-cloudwatch"
	addOnName            = "amazon-cloudwatch-observability"
	agentName            = "cloudwatch-agent"
	agentNameWindows     = "cloudwatch-agent-windows"
	operatorName         = addOnName + "-controller-manager"
	fluentBitName        = "fluent-bit"
	fluentBitNameWindows = "fluent-bit-windows"
	dcgmExporterName     = "dcgm-exporter"
	neuronMonitor        = "neuron-monitor"
	podNameRegex         = "(" + agentName + "|" + agentNameWindows + "|" + operatorName + "|" + fluentBitName + "|" + fluentBitNameWindows + ")-*"
	serviceNameRegex     = agentName + "(-headless|-monitoring)?|" + agentNameWindows + "(-headless|-monitoring)?|" + addOnName + "-webhook-service|" + dcgmExporterName + "-service|" + neuronMonitor + "-service"
	daemonSetNameRegex   = agentName + "|" + agentNameWindows + "|" + fluentBitName + "|" + fluentBitNameWindows + "|" + dcgmExporterName + "|" + neuronMonitor
)

const (
	deploymentCount = 1
	podCount        = podCountLinux + podCountWindows
	serviceCount    = serviceCountLinux + serviceCountWindows
	daemonSetCount  = daemonSetCountLinux + daemonSetCountWindows
)

func TestResourcesGenerated(t *testing.T) {

	k8sClient, err := util.NewK8sClient()
	if err != nil {
		assert.Fail(t, "failed to create k8s client", err)
	}

	// Validating namespace creation
	ns, err := k8sClient.GetNamespace(namespace)
	assert.NoError(t, err)
	assert.Equal(t, namespace, ns.Name)

	// Validating the number of pods and status
	pods, err := k8sClient.ListPods(namespace)
	assert.NoError(t, err)
	assert.Len(t, pods.Items, podCount)
	for _, pod := range pods.Items {
		t.Logf("pod: " + pod.Name + " namespace:" + pod.Namespace)
		assert.Contains(t, []v1.PodPhase{v1.PodRunning, v1.PodPending}, pod.Status.Phase)
		if match, _ := regexp.MatchString(podNameRegex, pod.Name); !match {
			assert.Fail(t, "pod is not created correctly")
		}
	}

	// Validating the services
	services, err := k8sClient.ListServices(namespace)
	assert.NoError(t, err)
	assert.Len(t, services.Items, serviceCount)
	for _, service := range services.Items {
		t.Logf("service: " + service.Name + " namespace:" + service.Namespace)
		if match, _ := regexp.MatchString(serviceNameRegex, service.Name); !match {
			assert.Fail(t, "service is not created correctly")
		}
	}

	// Validating the deployments
	deployments, err := k8sClient.ListDeployments(namespace)
	assert.NoError(t, err)
	for _, deployment := range deployments.Items {
		t.Logf("deployment: " + deployment.Name + " namespace:" + deployment.Namespace)
	}
	assert.Len(t, deployments.Items, deploymentCount)
	assert.Equal(t, addOnName+"-controller-manager", deployments.Items[0].Name)
	for _, deploymentCondition := range deployments.Items[0].Status.Conditions {
		t.Logf("deployment condition type: %v", deploymentCondition.Type)
	}
	assert.Equal(t, appsV1.DeploymentAvailable, deployments.Items[0].Status.Conditions[0].Type)

	// Validating the daemon sets
	daemonSets, err := k8sClient.ListDaemonSets(namespace)
	assert.NoError(t, err)
	assert.Len(t, daemonSets.Items, daemonSetCount)
	for _, daemonSet := range daemonSets.Items {
		t.Logf("daemonSet: " + daemonSet.Name + " namespace:" + daemonSet.Namespace)
		if match, _ := regexp.MatchString(daemonSetNameRegex, daemonSet.Name); !match {
			assert.Fail(t, "daemonset is not created correctly")
		}
	}

	// Validating Service Accounts
	serviceAccounts, err := k8sClient.ListServiceAccounts(namespace)
	assert.NoError(t, err)
	for _, sa := range serviceAccounts.Items {
		t.Logf("serviceAccount: " + sa.Name + " namespace:" + sa.Namespace)
	}
	assert.True(t, util.ValidateServiceAccount(serviceAccounts, addOnName+"-controller-manager"))
	assert.True(t, util.ValidateServiceAccount(serviceAccounts, agentName))
	assert.True(t, util.ValidateServiceAccount(serviceAccounts, dcgmExporterName+"-service-acct"))
	assert.True(t, util.ValidateServiceAccount(serviceAccounts, neuronMonitor+"-service-acct"))

	// Validating ClusterRoles
	clusterRoles, err := k8sClient.ListClusterRoles()
	assert.NoError(t, err)
	assert.True(t, util.ValidateClusterRoles(clusterRoles, addOnName+"-manager-role"))
	assert.True(t, util.ValidateClusterRoles(clusterRoles, agentName+"-role"))

	// Validating Roles
	roles, err := k8sClient.ListRoles(namespace)
	assert.NoError(t, err)
	assert.True(t, util.ValidateRoles(roles, dcgmExporterName+"-role"))
	assert.True(t, util.ValidateRoles(roles, neuronMonitor+"-role"))

	// Validating ClusterRoleBinding
	clusterRoleBindings, err := k8sClient.ListClusterRoleBindings()
	assert.NoError(t, err)
	assert.True(t, util.ValidateClusterRoleBindings(clusterRoleBindings, addOnName+"-manager-rolebinding"))
	assert.True(t, util.ValidateClusterRoleBindings(clusterRoleBindings, agentName+"-role-binding"))

	// Validating RoleBinding
	roleBindings, err := k8sClient.ListRoleBindings(namespace)
	assert.NoError(t, err)
	assert.True(t, util.ValidateRoleBindings(roleBindings, dcgmExporterName+"-role-binding"))
	assert.True(t, util.ValidateRoleBindings(roleBindings, neuronMonitor+"-role-binding"))

	// Validating MutatingWebhookConfiguration
	mutatingWebhookConfigurations, err := k8sClient.ListMutatingWebhookConfigurations()
	assert.NoError(t, err)
	assert.Len(t, mutatingWebhookConfigurations.Items[0].Webhooks, 5)
	assert.Equal(t, addOnName+"-mutating-webhook-configuration", mutatingWebhookConfigurations.Items[0].Name)

	// Validating ValidatingWebhookConfiguration
	validatingWebhookConfigurations, err := k8sClient.ListValidatingWebhookConfigurations()
	assert.NoError(t, err)
	assert.Len(t, validatingWebhookConfigurations.Items[0].Webhooks, 4)
	assert.Equal(t, addOnName+"-validating-webhook-configuration", validatingWebhookConfigurations.Items[0].Name)
}
