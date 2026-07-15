// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// TestMultiAgentLeaderElection validates the node/leader Container Insights
// split generalized from a real-world production pattern: a daemonset agent
// (CWAGENT_ROLE=NODE) plus a deployment agent (CWAGENT_ROLE=LEADER)
// with per-agent env, resources (default CPU limit removed via null),
// scheduling controls, and rollout tuning.
func TestMultiAgentLeaderElection(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	require.NoError(t, err, "failed to create k8s client")

	ns, err := k8sClient.GetNamespace(minikube.Namespace)
	assert.NoError(t, err)
	assert.Equal(t, minikube.Namespace, ns.Name)

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

	assert.Contains(t, agentMap, "cloudwatch-agent", "node agent CR should exist")
	assert.Contains(t, agentMap, "cloudwatch-agent-ci-leader", "leader agent CR should exist")

	t.Run("NodeAgentSpec", func(t *testing.T) {
		validateNodeAgentSpec(t, agentMap)
	})

	t.Run("LeaderAgentSpec", func(t *testing.T) {
		validateLeaderAgentSpec(t, agentMap)
	})

	t.Run("LeaderPodScheduled", func(t *testing.T) {
		validateLeaderPodRunning(t, k8sClient)
	})
}

func validateNodeAgentSpec(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["cloudwatch-agent"]
	if !assert.True(t, exists, "cloudwatch-agent CR should exist") {
		return
	}
	spec, ok := agent.Object["spec"].(map[string]interface{})
	require.True(t, ok, "spec should be a map")

	mode, _ := spec["mode"].(string)
	assert.Equal(t, "daemonset", mode, "node agent should be a daemonset")

	assertEnvValue(t, spec, "CWAGENT_ROLE", "NODE")
	assertResources(t, spec, "768Mi", "100m")
	assertSchedulingControls(t, spec)

	// updateStrategy rollingUpdate maxUnavailable propagated.
	updateStrategy, _ := spec["updateStrategy"].(map[string]interface{})
	if assert.NotNil(t, updateStrategy, "updateStrategy should be present") {
		rollingUpdate, _ := updateStrategy["rollingUpdate"].(map[string]interface{})
		if assert.NotNil(t, rollingUpdate, "rollingUpdate should be present") {
			assert.Equal(t, "5%", rollingUpdate["maxUnavailable"], "maxUnavailable override should propagate")
		}
	}

	assertEnhancedContainerInsights(t, spec)
}

func validateLeaderAgentSpec(t *testing.T, agentMap map[string]unstructured.Unstructured) {
	agent, exists := agentMap["cloudwatch-agent-ci-leader"]
	if !assert.True(t, exists, "cloudwatch-agent-ci-leader CR should exist") {
		return
	}
	spec, ok := agent.Object["spec"].(map[string]interface{})
	require.True(t, ok, "spec should be a map")

	mode, _ := spec["mode"].(string)
	assert.Equal(t, "deployment", mode, "leader agent should be a deployment")

	replicas, _ := spec["replicas"].(int64)
	assert.EqualValues(t, 1, replicas, "leader should have 1 replica")

	assertEnvValue(t, spec, "CWAGENT_ROLE", "LEADER")
	assertResources(t, spec, "512Mi", "50m")
	assertSchedulingControls(t, spec)

	// Custom nodeAffinity propagated (generic workload-tier label).
	affinityJSON, err := json.Marshal(spec["affinity"])
	require.NoError(t, err)
	assert.Contains(t, string(affinityJSON), "workload-tier",
		"leader nodeAffinity should require the workload-tier label")

	assertEnhancedContainerInsights(t, spec)
}

// assertEnvValue verifies spec.env contains the given name/value pair.
func assertEnvValue(t *testing.T, spec map[string]interface{}, name, value string) {
	env, _ := spec["env"].([]interface{})
	for _, e := range env {
		entry, _ := e.(map[string]interface{})
		if entry["name"] == name {
			assert.Equal(t, value, entry["value"], "env var %s should be %s", name, value)
			return
		}
	}
	assert.Failf(t, "env var not found", "env var %s should be present in spec.env", name)
}

// assertResources verifies the CPU limit was removed (cpu: null inside the
// agents[] entry — requires the null-handling fix from PR #334) while the
// per-agent memory limit and CPU request propagated.
func assertResources(t *testing.T, spec map[string]interface{}, memLimit, cpuRequest string) {
	resources, _ := spec["resources"].(map[string]interface{})
	if !assert.NotNil(t, resources, "resources should be present") {
		return
	}

	limits, _ := resources["limits"].(map[string]interface{})
	if assert.NotNil(t, limits, "limits should be present") {
		_, hasCPU := limits["cpu"]
		assert.False(t, hasCPU, "cpu limit should be removed (cpu: null in values)")
		assert.Equal(t, memLimit, limits["memory"], "memory limit override should propagate")
	}

	requests, _ := resources["requests"].(map[string]interface{})
	if assert.NotNil(t, requests, "requests should be present") {
		assert.Equal(t, cpuRequest, requests["cpu"], "cpu request override should propagate")
	}
}

// assertSchedulingControls verifies priorityClassName and the blanket
// toleration propagated into the CR spec.
func assertSchedulingControls(t *testing.T, spec map[string]interface{}) {
	assert.Equal(t, "system-node-critical", spec["priorityClassName"],
		"priorityClassName should propagate")

	tolerations, _ := spec["tolerations"].([]interface{})
	found := false
	for _, tol := range tolerations {
		entry, _ := tol.(map[string]interface{})
		if entry["operator"] == "Exists" {
			found = true
			break
		}
	}
	assert.True(t, found, "blanket Exists toleration should propagate")
}

// assertEnhancedContainerInsights verifies the per-agent config override
// merged into the rendered agent config.
func assertEnhancedContainerInsights(t *testing.T, spec map[string]interface{}) {
	configStr, _ := spec["config"].(string)
	if !assert.NotEmpty(t, configStr, "config should be present") {
		return
	}
	assert.Contains(t, configStr, "enhanced_container_insights",
		"per-agent enhanced_container_insights config should merge into rendered config")
}

// validateLeaderPodRunning polls until the leader deployment's pod is
// Running, proving the workload-tier affinity is satisfiable after the
// scenario labels the node. Operator reconciliation is async, so retry.
func validateLeaderPodRunning(t *testing.T, k8sClient *util.K8sClient) {
	deadline := time.Now().Add(3 * time.Minute)
	var lastState string

	for time.Now().Before(deadline) {
		pods, err := k8sClient.ListPods(minikube.Namespace)
		if err == nil {
			for _, pod := range pods.Items {
				if strings.HasPrefix(pod.Name, "cloudwatch-agent-ci-leader") {
					lastState = string(pod.Status.Phase)
					if pod.Status.Phase == corev1.PodRunning {
						t.Logf("leader pod %s is Running", pod.Name)
						return
					}
				}
			}
		}
		time.Sleep(10 * time.Second)
	}

	assert.Failf(t, "leader pod not running",
		"cloudwatch-agent-ci-leader pod did not reach Running within timeout (last state: %q)", lastState)
}
