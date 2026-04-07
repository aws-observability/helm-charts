// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const agentName = "cloudwatch-agent"

func TestConfigMapPermissionScoping(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	require.NoError(t, err)

	t.Run("ClusterRoleHasOnlyGetForConfigMaps", func(t *testing.T) {
		clusterRole, err := k8sClient.GetClusterRole(agentName + "-role")
		require.NoError(t, err)

		for _, rule := range clusterRole.Rules {
			for _, resource := range rule.Resources {
				if resource == "configmaps" {
					assert.Equal(t, []string{"get"}, rule.Verbs,
						"ClusterRole should only have get verb for configmaps")
				}
			}
		}
	})

	t.Run("NamespaceScopedRoleExists", func(t *testing.T) {
		role, err := k8sClient.GetRole(minikube.Namespace, agentName+"-role")
		require.NoError(t, err)
		require.Len(t, role.Rules, 1, "Role should have exactly one rule")

		assert.Equal(t, []string{""}, role.Rules[0].APIGroups)
		assert.Equal(t, []string{"configmaps"}, role.Rules[0].Resources)
		assert.Equal(t, []string{"create", "update"}, role.Rules[0].Verbs)
		assert.Empty(t, role.Rules[0].ResourceNames)
	})

	t.Run("NamespaceScopedRoleBindingExists", func(t *testing.T) {
		roleBindings, err := k8sClient.ListRoleBindings(minikube.Namespace)
		require.NoError(t, err)

		var found bool
		for _, rb := range roleBindings.Items {
			if rb.Name != agentName+"-role-binding" {
				continue
			}
			found = true
			assert.Equal(t, "Role", rb.RoleRef.Kind)
			assert.Equal(t, agentName+"-role", rb.RoleRef.Name)
			require.Len(t, rb.Subjects, 1)
			assert.Equal(t, "ServiceAccount", rb.Subjects[0].Kind)
			assert.Equal(t, agentName, rb.Subjects[0].Name)
			assert.Equal(t, minikube.Namespace, rb.Subjects[0].Namespace)
		}
		assert.True(t, found, "RoleBinding %s-role-binding not found in namespace %s", agentName, minikube.Namespace)
	})

	t.Log("ConfigMap permission scoping validation passed")
}
