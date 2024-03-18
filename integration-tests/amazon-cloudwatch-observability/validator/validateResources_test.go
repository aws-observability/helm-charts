// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package validator

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"testing"

	"github.com/stretchr/testify/assert"

	arv1 "k8s.io/api/admissionregistration/v1"
	appsV1 "k8s.io/api/apps/v1"
	v1 "k8s.io/api/core/v1"
	rbacV1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

const (
	nameSpace        = "amazon-cloudwatch"
	addOnName        = "amazon-cloudwatch-observability"
	agentName        = "cloudwatch-agent"
	operatorName     = addOnName + "-controller-manager"
	fluentBitName    = "fluent-bit"
	dcgmExporterName = "dcgm-exporter"
	podNameRegex     = "(" + agentName + "|" + operatorName + "|" + fluentBitName + ")-*"
	serviceNameRegex = agentName + "(-headless|-monitoring)?|" + addOnName + "-webhook-service|" + dcgmExporterName + "-service"
)

func TestOperatorOnEKs(t *testing.T) {
	userHomeDir, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("error getting user home dir: %v\n", err)
	}
	kubeConfigPath := filepath.Join(userHomeDir, ".kube", "config")
	t.Logf("Using kubeconfig: %s\n", kubeConfigPath)

	kubeConfig, err := clientcmd.BuildConfigFromFlags("", kubeConfigPath)
	if err != nil {
		t.Fatalf("Error getting kubernetes config: %v\n", err)
	}

	clientSet, err := kubernetes.NewForConfig(kubeConfig)

	if err != nil {
		t.Fatalf("error getting kubernetes config: %v\n", err)
	}

	// Validating the "amazon-cloudwatch" namespace creation as part of EKS addon
	namespace, err := GetNameSpace(nameSpace, clientSet)
	assert.NoError(t, err)
	assert.Equal(t, nameSpace, namespace.Name)

	//Validating the number of pods and status
	pods, err := ListPods(nameSpace, clientSet)
	assert.NoError(t, err)
	assert.Len(t, pods.Items, 3)
	for _, pod := range pods.Items {
		fmt.Println("pod name: " + pod.Name + " namespace:" + pod.Namespace)
		assert.Contains(t, []v1.PodPhase{v1.PodRunning, v1.PodPending}, pod.Status.Phase)
		// matches
		// - cloudwatch-agent-*
		// - amazon-cloudwatch-observability-controller-manager-*
		// - fluent-bit-*
		if match, _ := regexp.MatchString(podNameRegex, pod.Name); !match {
			assert.Fail(t, "Cluster Pods are not created correctly")
		}
	}

	//Validating the services
	services, err := ListServices(nameSpace, clientSet)
	assert.NoError(t, err)
	assert.Len(t, services.Items, 5)
	for _, service := range services.Items {
		fmt.Println("service name: " + service.Name + " namespace:" + service.Namespace)
		// matches
		// - amazon-cloudwatch-observability-webhook-service
		// - cloudwatch-agent
		// - cloudwatch-agent-headless
		// - cloudwatch-agent-monitoring
		// - dcgm-exporter-service
		if match, _ := regexp.MatchString(serviceNameRegex, service.Name); !match {
			assert.Fail(t, "Cluster Service is not created correctly")
		}
	}

	//Validating the Deployment
	deployments, err := ListDeployments(nameSpace, clientSet)
	assert.NoError(t, err)
	for _, deployment := range deployments.Items {
		fmt.Println("deployment name: " + deployment.Name + " namespace:" + deployment.Namespace)
	}
	assert.Len(t, deployments.Items, 1)
	// matches
	// - amazon-cloudwatch-observability-controller-manager
	assert.Equal(t, addOnName+"-controller-manager", deployments.Items[0].Name)
	for _, deploymentCondition := range deployments.Items[0].Status.Conditions {
		fmt.Println("deployment condition type: " + deploymentCondition.Type)
	}
	assert.Equal(t, appsV1.DeploymentAvailable, deployments.Items[0].Status.Conditions[0].Type)

	//Validating the Daemon Sets
	daemonSets, err := ListDaemonSets(nameSpace, clientSet)
	assert.NoError(t, err)
	assert.Len(t, daemonSets.Items, 3)
	for _, daemonSet := range daemonSets.Items {
		fmt.Println("daemonSet name: " + daemonSet.Name + " namespace:" + daemonSet.Namespace)
		// matches
		// - cloudwatch-agent
		// - fluent-bit
		// - dcgm-exporter (this can be removed in the future)
		if match, _ := regexp.MatchString(agentName+"|fluent-bit|dcgm-exporter", daemonSet.Name); !match {
			assert.Fail(t, "DaemonSet is not created correctly")
		}
	}

	// Validating Service Accounts
	serviceAccounts, err := ListServiceAccounts(nameSpace, clientSet)
	assert.NoError(t, err)
	for _, sa := range serviceAccounts.Items {
		fmt.Println("serviceAccounts name: " + sa.Name + " namespace:" + sa.Namespace)
	}
	// searches
	// - amazon-cloudwatch-observability-controller-manager
	// - cloudwatch-agent
	// - dcgm-exporter-service-acct
	assert.True(t, validateServiceAccount(serviceAccounts, addOnName+"-controller-manager"))
	assert.True(t, validateServiceAccount(serviceAccounts, agentName))
	assert.True(t, validateServiceAccount(serviceAccounts, dcgmExporterName+"-service-acct"))

	//Validating ClusterRoles
	clusterRoles, err := ListClusterRoles(clientSet)
	assert.NoError(t, err)
	// searches
	// - amazon-cloudwatch-observability-manager-role
	// - cloudwatch-agent-role
	assert.True(t, validateClusterRoles(clusterRoles, addOnName+"-manager-role"))
	assert.True(t, validateClusterRoles(clusterRoles, agentName+"-role"))

	//Validating Roles
	roles, err := ListRoles(nameSpace, clientSet)
	assert.NoError(t, err)
	// searches
	// - dcgm-exporter-role
	assert.True(t, validateRoles(roles, dcgmExporterName+"-role"))

	//Validating ClusterRoleBinding
	clusterRoleBindings, err := ListClusterRoleBindings(clientSet)
	assert.NoError(t, err)
	// searches
	// - amazon-cloudwatch-observability-manager-rolebinding
	// - cloudwatch-agent-role-binding
	assert.True(t, validateClusterRoleBindings(clusterRoleBindings, addOnName+"-manager-rolebinding"))
	assert.True(t, validateClusterRoleBindings(clusterRoleBindings, agentName+"-role-binding"))

	//Validating RoleBinding
	roleBindings, err := ListRoleBindings(nameSpace, clientSet)
	assert.NoError(t, err)
	// searches
	// - dcgm-exporter-role-binding
	assert.True(t, validateRoleBindings(roleBindings, dcgmExporterName+"-role-binding"))

	//Validating MutatingWebhookConfiguration
	mutatingWebhookConfigurations, err := ListMutatingWebhookConfigurations(clientSet)
	assert.NoError(t, err)
	assert.Len(t, mutatingWebhookConfigurations.Items[0].Webhooks, 5)
	// searches
	// - amazon-cloudwatch-observability-mutating-webhook-configuration
	assert.Equal(t, addOnName+"-mutating-webhook-configuration", mutatingWebhookConfigurations.Items[0].Name)

	//Validating ValidatingWebhookConfiguration
	validatingWebhookConfigurations, err := ListValidatingWebhookConfigurations(clientSet)
	assert.NoError(t, err)
	assert.Len(t, validatingWebhookConfigurations.Items[0].Webhooks, 4)
	// searches
	// - amazon-cloudwatch-observability-validating-webhook-configuration
	assert.Equal(t, addOnName+"-validating-webhook-configuration", validatingWebhookConfigurations.Items[0].Name)
}

func validateServiceAccount(serviceAccounts *v1.ServiceAccountList, serviceAccountName string) bool {
	for _, serviceAccount := range serviceAccounts.Items {
		if serviceAccount.Name == serviceAccountName {
			return true
		}
	}
	return false
}

func validateClusterRoles(clusterRoles *rbacV1.ClusterRoleList, clusterRoleName string) bool {
	for _, clusterRole := range clusterRoles.Items {
		if clusterRole.Name == clusterRoleName {
			return true
		}
	}
	return false
}

func validateRoles(roles *rbacV1.RoleList, roleName string) bool {
	for _, role := range roles.Items {
		if role.Name == roleName {
			return true
		}
	}
	return false
}

func validateClusterRoleBindings(clusterRoleBindings *rbacV1.ClusterRoleBindingList, clusterRoleBindingName string) bool {
	for _, clusterRoleBinding := range clusterRoleBindings.Items {
		if clusterRoleBinding.Name == clusterRoleBindingName {
			return true
		}
	}
	return false
}

func validateRoleBindings(roleBindings *rbacV1.RoleBindingList, roleBindingName string) bool {
	for _, roleBinding := range roleBindings.Items {
		if roleBinding.Name == roleBindingName {
			return true
		}
	}
	return false
}

func ListPods(namespace string, client kubernetes.Interface) (*v1.PodList, error) {
	pods, err := client.CoreV1().Pods(namespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		err = fmt.Errorf("error getting pods: %v\n", err)
		return nil, err
	}
	return pods, nil
}

func GetNameSpace(namespace string, client kubernetes.Interface) (*v1.Namespace, error) {
	ns, err := client.CoreV1().Namespaces().Get(context.Background(), namespace, metav1.GetOptions{})
	if err != nil {
		err = fmt.Errorf("error getting namespace: %v\n", err)
		return nil, err
	}
	return ns, nil
}

func ListServices(namespace string, client kubernetes.Interface) (*v1.ServiceList, error) {
	namespaces, err := client.CoreV1().Services(namespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		err = fmt.Errorf("error getting Services: %v\n", err)
		return nil, err
	}
	return namespaces, nil
}

func ListDeployments(namespace string, client kubernetes.Interface) (*appsV1.DeploymentList, error) {
	deployments, err := client.AppsV1().Deployments(namespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		err = fmt.Errorf("error getting Deploymets: %v\n", err)
		return nil, err
	}
	return deployments, nil
}

func ListDaemonSets(namespace string, client kubernetes.Interface) (*appsV1.DaemonSetList, error) {
	daemonSets, err := client.AppsV1().DaemonSets(namespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		err = fmt.Errorf("error getting DaemonSets: %v\n", err)
		return nil, err
	}
	return daemonSets, nil
}

func ListServiceAccounts(namespace string, client kubernetes.Interface) (*v1.ServiceAccountList, error) {
	serviceAccounts, err := client.CoreV1().ServiceAccounts(namespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		err = fmt.Errorf("error getting ServiceAccounts: %v\n", err)
		return nil, err
	}
	return serviceAccounts, nil
}

func ListClusterRoles(client kubernetes.Interface) (*rbacV1.ClusterRoleList, error) {
	clusterRoles, err := client.RbacV1().ClusterRoles().List(context.Background(), metav1.ListOptions{})
	if err != nil {
		err = fmt.Errorf("error getting ClusterRoles: %v\n", err)
		return nil, err
	}
	return clusterRoles, nil
}

func ListRoles(namespace string, client kubernetes.Interface) (*rbacV1.RoleList, error) {
	roles, err := client.RbacV1().Roles(namespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		err = fmt.Errorf("error getting Roles: %v\n", err)
		return nil, err
	}
	return roles, nil
}

func ListClusterRoleBindings(client kubernetes.Interface) (*rbacV1.ClusterRoleBindingList, error) {
	clusterRoleBindings, err := client.RbacV1().ClusterRoleBindings().List(context.Background(), metav1.ListOptions{})
	if err != nil {
		err = fmt.Errorf("error getting ClusterRoleBindings: %v\n", err)
		return nil, err
	}
	return clusterRoleBindings, nil
}

func ListRoleBindings(namespace string, client kubernetes.Interface) (*rbacV1.RoleBindingList, error) {
	roleBindings, err := client.RbacV1().RoleBindings(namespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		err = fmt.Errorf("error getting RoleBindings: %v\n", err)
		return nil, err
	}
	return roleBindings, nil
}

func ListMutatingWebhookConfigurations(client kubernetes.Interface) (*arv1.MutatingWebhookConfigurationList, error) {
	mutatingWebhookConfigurations, err := client.AdmissionregistrationV1().MutatingWebhookConfigurations().List(context.Background(), metav1.ListOptions{})
	if err != nil {
		err = fmt.Errorf("error getting MutatingWebhookConfigurations: %v\n", err)
		return nil, err
	}
	return mutatingWebhookConfigurations, nil
}

func ListValidatingWebhookConfigurations(client kubernetes.Interface) (*arv1.ValidatingWebhookConfigurationList, error) {
	validatingWebhookConfigurations, err := client.AdmissionregistrationV1().ValidatingWebhookConfigurations().List(context.Background(), metav1.ListOptions{})
	if err != nil {
		err = fmt.Errorf("error getting ValidatingWebhookConfigurations: %v\n", err)
		return nil, err
	}
	return validatingWebhookConfigurations, nil
}
