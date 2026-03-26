// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"testing"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
)

func TestOTLPDisabled(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	assert.NoError(t, err)

	// Validate namespace exists
	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

	// Validate operator deployment still exists
	exists, err := k8sClient.ValidateDeploymentExists(minikube.Namespace, "amazon-cloudwatch-observability-controller-manager")
	assert.NoError(t, err)
	assert.True(t, exists)

	// Validate OTLP resources are NOT present
	exists, err = k8sClient.ValidateDeploymentExists(minikube.Namespace, "cwagent-kube-state-metrics")
	assert.NoError(t, err)
	assert.False(t, exists, "cwagent-kube-state-metrics deployment should not exist when OTLP is disabled")

	// Cluster-scraper is now an AmazonCloudWatchAgent CR (not a standalone Deployment).
	// When OTLP is disabled, the CR is not rendered, so the operator doesn't create a Deployment.
	exists, err = k8sClient.ValidateDeploymentExists(minikube.Namespace, "cloudwatch-agent-cluster-scraper")
	assert.NoError(t, err)
	assert.False(t, exists, "cloudwatch-agent-cluster-scraper should not exist when OTLP is disabled")

	exists, err = k8sClient.ValidateDaemonSetExists(minikube.Namespace, "node-exporter")
	assert.NoError(t, err)
	assert.False(t, exists, "node-exporter daemonset should not exist when OTLP is disabled")

	t.Log("OTLP disabled scenario validation passed")
}
