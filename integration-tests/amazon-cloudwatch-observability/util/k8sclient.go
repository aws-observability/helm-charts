package util

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"k8s.io/client-go/tools/clientcmd"

	arv1 "k8s.io/api/admissionregistration/v1"
	appsV1 "k8s.io/api/apps/v1"
	v1 "k8s.io/api/core/v1"
	rbacV1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

type K8sClient struct {
	client kubernetes.Interface
}

func NewK8sClient() (*K8sClient, error) {

	userHomeDir, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}

	kubeConfigPath := filepath.Join(userHomeDir, ".kube", "config")

	kubeConfig, err := clientcmd.BuildConfigFromFlags("", kubeConfigPath)
	if err != nil {
		return nil, err
	}

	client, err := kubernetes.NewForConfig(kubeConfig)
	if err != nil {
		return nil, err
	}

	return &K8sClient{client: client}, nil
}

func (k *K8sClient) GetNamespace(namespace string) (*v1.Namespace, error) {
	ns, err := k.client.CoreV1().Namespaces().Get(context.Background(), namespace, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting namespace: %v", err)
	}
	return ns, nil
}

func (k *K8sClient) ListPods(namespace string) (*v1.PodList, error) {
	pods, err := k.client.CoreV1().Pods(namespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting pods: %v", err)
	}
	return pods, nil
}

func (k *K8sClient) ListServices(namespace string) (*v1.ServiceList, error) {
	services, err := k.client.CoreV1().Services(namespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting Services: %v", err)
	}
	return services, nil
}

func (k *K8sClient) ListDeployments(namespace string) (*appsV1.DeploymentList, error) {
	deployments, err := k.client.AppsV1().Deployments(namespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting Deployments: %v", err)
	}
	return deployments, nil
}

func (k *K8sClient) ListDaemonSets(namespace string) (*appsV1.DaemonSetList, error) {
	daemonSets, err := k.client.AppsV1().DaemonSets(namespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting DaemonSets: %v", err)
	}
	return daemonSets, nil
}

func (k *K8sClient) ListServiceAccounts(namespace string) (*v1.ServiceAccountList, error) {
	serviceAccounts, err := k.client.CoreV1().ServiceAccounts(namespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting ServiceAccounts: %v", err)
	}
	return serviceAccounts, nil
}

func (k *K8sClient) ListClusterRoles() (*rbacV1.ClusterRoleList, error) {
	clusterRoles, err := k.client.RbacV1().ClusterRoles().List(context.Background(), metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting ClusterRoles: %v", err)
	}
	return clusterRoles, nil
}

func (k *K8sClient) ListRoles(namespace string) (*rbacV1.RoleList, error) {
	roles, err := k.client.RbacV1().Roles(namespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting Roles: %v", err)
	}
	return roles, nil
}

func (k *K8sClient) ListClusterRoleBindings() (*rbacV1.ClusterRoleBindingList, error) {
	clusterRoleBindings, err := k.client.RbacV1().ClusterRoleBindings().List(context.Background(), metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting ClusterRoleBindings: %v", err)
	}
	return clusterRoleBindings, nil
}

func (k *K8sClient) ListRoleBindings(namespace string) (*rbacV1.RoleBindingList, error) {
	roleBindings, err := k.client.RbacV1().RoleBindings(namespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting RoleBindings: %v", err)
	}
	return roleBindings, nil
}

func (k *K8sClient) ListMutatingWebhookConfigurations() (*arv1.MutatingWebhookConfigurationList, error) {
	mutatingWebhookConfigurations, err := k.client.AdmissionregistrationV1().MutatingWebhookConfigurations().List(context.Background(), metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting MutatingWebhookConfigurations: %v", err)
	}
	return mutatingWebhookConfigurations, nil
}

func (k *K8sClient) ListValidatingWebhookConfigurations() (*arv1.ValidatingWebhookConfigurationList, error) {
	validatingWebhookConfigurations, err := k.client.AdmissionregistrationV1().ValidatingWebhookConfigurations().List(context.Background(), metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting ValidatingWebhookConfigurations: %v", err)
	}
	return validatingWebhookConfigurations, nil
}

func (k *K8sClient) ValidateServiceAccountExists(namespace, serviceAccountName string) (bool, error) {
	serviceAccounts, err := k.ListServiceAccounts(namespace)
	if err != nil {
		return false, err
	}
	for _, serviceAccount := range serviceAccounts.Items {
		if serviceAccount.Name == serviceAccountName {
			return true, nil
		}
	}
	return false, nil
}

func (k *K8sClient) ValidateClusterRoleExists(clusterRoleName string) (bool, error) {
	clusterRoles, err := k.ListClusterRoles()
	if err != nil {
		return false, err
	}
	for _, clusterRole := range clusterRoles.Items {
		if clusterRole.Name == clusterRoleName {
			return true, nil
		}
	}
	return false, nil
}

func (k *K8sClient) ValidateRoleExists(namespace, roleName string) (bool, error) {
	roles, err := k.ListRoles(namespace)
	if err != nil {
		return false, err
	}
	for _, role := range roles.Items {
		if role.Name == roleName {
			return true, nil
		}
	}
	return false, nil
}

func (k *K8sClient) ValidateClusterRoleBindingExists(clusterRoleBindingName string) (bool, error) {
	clusterRoleBindings, err := k.ListClusterRoleBindings()
	if err != nil {
		return false, err
	}
	for _, clusterRoleBinding := range clusterRoleBindings.Items {
		if clusterRoleBinding.Name == clusterRoleBindingName {
			return true, nil
		}
	}
	return false, nil
}

func (k *K8sClient) ValidateRoleBindingExists(namespace, roleBindingName string) (bool, error) {
	roleBindings, err := k.ListRoleBindings(namespace)
	if err != nil {
		return false, err
	}
	for _, roleBinding := range roleBindings.Items {
		if roleBinding.Name == roleBindingName {
			return true, nil
		}
	}
	return false, nil
}

func (k *K8sClient) ValidateDeploymentExists(namespace, deploymentName string) (bool, error) {
	deployments, err := k.ListDeployments(namespace)
	if err != nil {
		return false, err
	}
	for _, deployment := range deployments.Items {
		if deployment.Name == deploymentName {
			return true, nil
		}
	}
	return false, nil
}
