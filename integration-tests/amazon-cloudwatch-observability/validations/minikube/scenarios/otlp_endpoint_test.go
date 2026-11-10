// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	utilyaml "k8s.io/apimachinery/pkg/util/yaml"
)

const (
	otlpReceiver = "otlp/cw_k8s_otlp"
	// The operator creates the agent Service from the CR, after the Helm release is installed.
	servicePortsTimeout = 3 * time.Minute
)

// profiles/cw_k8s_otlp is opt-in (otlp.profiles.enabled), off in these scenarios.
var otlpPipelines = []string{"metrics/cw_k8s_otlp", "traces/cw_k8s_otlp", "logs/cw_k8s_otlp"}

// TestOTLPEndpointDefault validates the OTLP endpoint with the chart's default values: the node agent
// serves OTLP on 0.0.0.0:4317 and 0.0.0.0:4318 from its otelConfig, writes no OTLP receiver into
// its JSON config, the operator exposes both ports on the cloudwatch-agent Service, the agent pods
// run without restarting, and OTLP/HTTP metrics, traces and logs sent through the Service return 200.
func TestOTLPEndpointDefault(t *testing.T) {
	k8sClient, agentMap := agentCRs(t)

	t.Run("NodeAgentServesOTLP", func(t *testing.T) {
		validateOTLPReceiver(t, agentMap, "cloudwatch-agent", map[string]string{
			"grpc": "0.0.0.0:4317",
			"http": "0.0.0.0:4318",
		})
	})
	t.Run("NodeAgentJSONHasNoOTLPReceiver", func(t *testing.T) {
		config := configJSONOf(t, agentMap, "cloudwatch-agent")
		if config != nil {
			assert.Nil(t, otlpCollectBlockOf(config), "the node agent JSON config should not have opentelemetry.collect.otlp")
		}
	})
	t.Run("ServiceExposesOTLPPorts", func(t *testing.T) {
		validateServicePorts(t, k8sClient, "cloudwatch-agent", []int32{4317, 4318}, nil)
	})
	// The checks above read the CR and the Service, which the operator creates whether or not the
	// collector starts. These two cover the runtime path: the agent runs with the rendered config,
	// and the receiver accepts OTLP through the Service.
	t.Run("NodeAgentRuns", func(t *testing.T) {
		validateAgentPodsRunning(t, k8sClient, "cloudwatch-agent")
	})
	t.Run("OTLPPostThroughService", func(t *testing.T) {
		validateOTLPPostThroughService(t, k8sClient)
	})

	t.Log("OTLP endpoint default scenario validation passed")
}

// TestOTLPEndpointDisabled validates otlp.enabled=false: no OTLP receiver in any agent config, and no
// OTLP ports on the cloudwatch-agent Service.
func TestOTLPEndpointDisabled(t *testing.T) {
	k8sClient, agentMap := agentCRs(t)

	t.Run("NoOTLPReceiver", func(t *testing.T) {
		for name := range agentMap {
			if cfg := otelConfigMapOf(t, agentMap, name); cfg != nil {
				receivers, _ := cfg["receivers"].(map[string]interface{})
				_, has := receivers[otlpReceiver]
				assert.False(t, has, "%s otelConfig should not have %s when otlp.enabled is false", name, otlpReceiver)
			}
			if config := configJSONOf(t, agentMap, name); config != nil {
				assert.Nil(t, otlpCollectBlockOf(config), "%s JSON config should not have opentelemetry.collect.otlp", name)
			}
		}
	})
	t.Run("ServiceHasNoOTLPPorts", func(t *testing.T) {
		validateServicePorts(t, k8sClient, "cloudwatch-agent", nil, []int32{4317, 4318})
	})

	t.Log("OTLP endpoint disabled scenario validation passed")
}

// agentCRs checks that the operator is installed and returns the AmazonCloudWatchAgent CRs by name.
func agentCRs(t *testing.T) (*util.K8sClient, map[string]unstructured.Unstructured) {
	t.Helper()
	k8sClient, err := util.NewK8sClient()
	require.NoError(t, err, "failed to create k8s client")

	exists, err := k8sClient.ValidateDeploymentExists(minikube.Namespace, "amazon-cloudwatch-observability-controller-manager")
	require.NoError(t, err)
	require.True(t, exists, "operator deployment should exist")

	dynamicClient, err := k8sClient.GetDynamicClient()
	require.NoError(t, err, "failed to get dynamic client")
	gvr := schema.GroupVersionResource{
		Group:    "cloudwatch.aws.amazon.com",
		Version:  "v1alpha1",
		Resource: "amazoncloudwatchagents",
	}
	agentList, err := dynamicClient.Resource(gvr).Namespace(minikube.Namespace).List(context.Background(), metav1.ListOptions{})
	require.NoError(t, err, "failed to list AmazonCloudWatchAgent CRs")

	agentMap := make(map[string]unstructured.Unstructured)
	for _, agent := range agentList.Items {
		agentMap[agent.GetName()] = agent
	}
	return k8sClient, agentMap
}

// otelConfigMapOf parses a CR's spec.otelConfig (a YAML string) into a map. It returns nil when the
// CR has no otelConfig, and fails the test when the CR is missing or the YAML is invalid.
func otelConfigMapOf(t *testing.T, agentMap map[string]unstructured.Unstructured, name string) map[string]interface{} {
	t.Helper()
	agent, exists := agentMap[name]
	if !assert.True(t, exists, "%s CR should exist", name) {
		return nil
	}
	text, _, _ := unstructured.NestedString(agent.Object, "spec", "otelConfig")
	if text == "" {
		return nil
	}
	var cfg map[string]interface{}
	err := utilyaml.NewYAMLOrJSONDecoder(strings.NewReader(text), 4096).Decode(&cfg)
	if !assert.NoError(t, err, "%s otelConfig should be valid YAML", name) {
		return nil
	}
	return cfg
}

// validateOTLPReceiver checks that the agent's otelConfig has the OTLP receiver with exactly the
// given protocol endpoints, and the OTLP pipelines reading from it.
func validateOTLPReceiver(t *testing.T, agentMap map[string]unstructured.Unstructured, name string, endpoints map[string]string) {
	t.Helper()
	cfg := otelConfigMapOf(t, agentMap, name)
	if !assert.NotNil(t, cfg, "%s should have an otelConfig", name) {
		return
	}
	receiver, found, err := unstructured.NestedMap(cfg, "receivers", otlpReceiver, "protocols")
	if !assert.True(t, found && err == nil, "%s otelConfig should have %s", name, otlpReceiver) {
		return
	}
	assert.Len(t, receiver, len(endpoints), "%s receiver protocols", name)
	for protocol, endpoint := range endpoints {
		got, _, _ := unstructured.NestedString(receiver, protocol, "endpoint")
		assert.Equal(t, endpoint, got, "%s %s endpoint", name, protocol)
	}
	for _, p := range otlpPipelines {
		receivers, _, _ := unstructured.NestedStringSlice(cfg, "service", "pipelines", p, "receivers")
		assert.Contains(t, receivers, otlpReceiver, "%s pipeline %s should read from %s", name, p, otlpReceiver)
	}
}

// validateServicePorts waits for the operator to create the Service and checks that it exposes
// every port in want and none in notWant. The Service must exist: the node agent's Service also
// carries the Application Signals ports, so it exists with and without the OTLP endpoint.
func validateServicePorts(t *testing.T, k8sClient *util.K8sClient, name string, want, notWant []int32) {
	t.Helper()
	deadline := time.Now().Add(servicePortsTimeout)
	for {
		ports, found := servicePorts(t, k8sClient, name)
		missing := false
		for _, p := range want {
			if !ports[p] {
				missing = true
			}
		}
		if found && !missing {
			for _, p := range notWant {
				assert.False(t, ports[p], "Service %s should not expose port %d", name, p)
			}
			return
		}
		if time.Now().After(deadline) {
			assert.Fail(t, "Service ports not found", "Service %s (found=%t) has ports %v, want %v", name, found, ports, want)
			return
		}
		time.Sleep(5 * time.Second)
	}
}

func servicePorts(t *testing.T, k8sClient *util.K8sClient, name string) (map[int32]bool, bool) {
	services, err := k8sClient.ListServices(minikube.Namespace)
	require.NoError(t, err)
	for _, svc := range services.Items {
		if svc.Name != name {
			continue
		}
		ports := map[int32]bool{}
		for _, p := range svc.Spec.Ports {
			ports[p.Port] = true
		}
		return ports, true
	}
	return map[int32]bool{}, false
}

const (
	// The agent pods must stay Ready, with no restart, for this long after they first become
	// Ready. An agent that rejects its config exits within seconds of starting, so a crash loop
	// shows up as a restart inside the window even when the pod was briefly Ready.
	agentStableWindow   = time.Minute
	agentReadyTimeout   = 3 * time.Minute
	otlpSenderTimeout   = 3 * time.Minute
	otlpSenderImage     = "curlimages/curl:8.11.1"
	otlpSenderPodName   = "otlp-e2e-sender"
	otlpSenderNamespace = "default"
)

// validateAgentPodsRunning checks that every pod of the agent DaemonSet reaches Ready and then stays
// Ready without a container restart for agentStableWindow. The CR and Service checks above pass
// whether or not the collector starts; this is what fails when the agent rejects its config.
func validateAgentPodsRunning(t *testing.T, k8sClient *util.K8sClient, name string) {
	t.Helper()
	ctx := context.Background()
	pods := k8sClient.Clientset().CoreV1().Pods(minikube.Namespace)
	selector := metav1.ListOptions{LabelSelector: "app.kubernetes.io/name=" + name}

	restarts := func(p corev1.Pod) int32 {
		var n int32
		for _, cs := range p.Status.ContainerStatuses {
			n += cs.RestartCount
		}
		return n
	}
	ready := func(p corev1.Pod) bool {
		for _, c := range p.Status.Conditions {
			if c.Type == corev1.PodReady {
				return c.Status == corev1.ConditionTrue
			}
		}
		return false
	}
	describe := func(p corev1.Pod) string {
		var b strings.Builder
		for _, cs := range p.Status.ContainerStatuses {
			fmt.Fprintf(&b, "%s restarts=%d", cs.Name, cs.RestartCount)
			if term := cs.LastTerminationState.Terminated; term != nil {
				fmt.Fprintf(&b, " last exit %d (%s) %q", term.ExitCode, term.Reason, term.Message)
			}
			if wait := cs.State.Waiting; wait != nil {
				fmt.Fprintf(&b, " waiting %s", wait.Reason)
			}
			// CI keeps no agent logs, so put the end of the crashed container's log in the failure.
			if cs.RestartCount > 0 {
				tail := int64(40)
				raw, err := pods.GetLogs(p.Name, &corev1.PodLogOptions{Container: cs.Name, Previous: true, TailLines: &tail}).DoRaw(ctx)
				if err != nil {
					fmt.Fprintf(&b, "\n  (previous log unavailable: %v)", err)
				} else {
					fmt.Fprintf(&b, "\n  previous log (last %d lines):\n%s", tail, raw)
				}
			}
		}
		return b.String()
	}

	// Wait until every agent pod is Ready, and record the restart counts at that point.
	baseline := map[string]int32{}
	deadline := time.Now().Add(agentReadyTimeout)
	for {
		list, err := pods.List(ctx, selector)
		require.NoError(t, err, "list %s pods", name)
		allReady := len(list.Items) > 0
		for _, p := range list.Items {
			if !ready(p) {
				allReady = false
			}
		}
		if allReady {
			for _, p := range list.Items {
				baseline[p.Name] = restarts(p)
			}
			break
		}
		if time.Now().After(deadline) {
			var states []string
			for _, p := range list.Items {
				states = append(states, p.Name+": "+describe(p))
			}
			require.Failf(t, "agent pods not Ready", "%s pods did not all become Ready within %s: %v",
				name, agentReadyTimeout, states)
		}
		time.Sleep(5 * time.Second)
	}

	// Then they must stay Ready with no new restart.
	time.Sleep(agentStableWindow)
	list, err := pods.List(ctx, selector)
	require.NoError(t, err, "list %s pods", name)
	for _, p := range list.Items {
		before, known := baseline[p.Name]
		assert.True(t, known, "%s pod %s was replaced during the stability window", name, p.Name)
		assert.True(t, ready(p), "%s pod %s is no longer Ready: %s", name, p.Name, describe(p))
		assert.Equal(t, before, restarts(p), "%s pod %s restarted during the stability window: %s",
			name, p.Name, describe(p))
	}
}

// otlpSenderScript posts one minimal OTLP/HTTP JSON request per signal to the cloudwatch-agent Service
// and prints "<path> <status>" for each. It retries a path until it gets 200 or runs out of attempts,
// because the Service can take a moment to route to a freshly started agent. The export to CloudWatch
// fails without credentials on minikube, but the receiver answers once the pipeline has accepted the
// data, so a 200 shows the pipeline loaded and the port is reachable through the Service.
const otlpSenderScript = `
base="http://cloudwatch-agent.` + minikube.Namespace + `:4318"
res='"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otlp-e2e"}}]}'
post() {
  code=000
  for i in 1 2 3 4 5 6 7 8 9 10; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST -H 'Content-Type: application/json' --data "$2" "$base$1")
    [ "$code" = 200 ] && break
    sleep 3
  done
  echo "$1 $code"
}
post /v1/metrics '{"resourceMetrics":[{'"$res"',"scopeMetrics":[{"metrics":[{"name":"otlp_e2e_requests","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"asInt":"1","timeUnixNano":"1700000000000000000"}]}}]}]}]}'
post /v1/traces '{"resourceSpans":[{'"$res"',"scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"otlp-e2e","kind":2,"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000000100000000"}]}]}]}'
post /v1/logs '{"resourceLogs":[{'"$res"',"scopeLogs":[{"logRecords":[{"timeUnixNano":"1700000000000000000","body":{"stringValue":"otlp-e2e"}}]}]}]}'
`

// validateOTLPPostThroughService runs a short-lived curl pod in another namespace that sends metrics,
// traces and logs through the cloudwatch-agent Service, and checks that each request returns 200.
func validateOTLPPostThroughService(t *testing.T, k8sClient *util.K8sClient) {
	t.Helper()
	ctx := context.Background()
	pods := k8sClient.Clientset().CoreV1().Pods(otlpSenderNamespace)
	_ = pods.Delete(ctx, otlpSenderPodName, metav1.DeleteOptions{})
	waitForPodGone(ctx, t, k8sClient, otlpSenderNamespace, otlpSenderPodName)

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: otlpSenderPodName, Namespace: otlpSenderNamespace},
		Spec: corev1.PodSpec{
			RestartPolicy: corev1.RestartPolicyNever,
			Containers: []corev1.Container{{
				Name:    "sender",
				Image:   otlpSenderImage,
				Command: []string{"/bin/sh", "-c", otlpSenderScript},
			}},
		},
	}
	_, err := pods.Create(ctx, pod, metav1.CreateOptions{})
	require.NoError(t, err, "create the OTLP sender pod")
	t.Cleanup(func() { _ = pods.Delete(context.Background(), otlpSenderPodName, metav1.DeleteOptions{}) })

	deadline := time.Now().Add(otlpSenderTimeout)
	for {
		p, err := pods.Get(ctx, otlpSenderPodName, metav1.GetOptions{})
		require.NoError(t, err, "get the OTLP sender pod")
		if p.Status.Phase == corev1.PodSucceeded || p.Status.Phase == corev1.PodFailed {
			break
		}
		if time.Now().After(deadline) {
			require.Failf(t, "OTLP sender did not finish", "phase %s after %s", p.Status.Phase, otlpSenderTimeout)
		}
		time.Sleep(3 * time.Second)
	}

	raw, err := pods.GetLogs(otlpSenderPodName, &corev1.PodLogOptions{}).DoRaw(ctx)
	require.NoError(t, err, "read the OTLP sender logs")
	got := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		if f := strings.Fields(line); len(f) == 2 {
			got[f[0]] = f[1]
		}
	}
	for _, path := range []string{"/v1/metrics", "/v1/traces", "/v1/logs"} {
		assert.Equal(t, "200", got[path], "OTLP/HTTP POST %s through the cloudwatch-agent Service; sender output:\n%s", path, raw)
	}
}

// waitForPodGone waits until a deleted pod no longer exists, so a pod from an earlier run does not
// collide with the one about to be created.
func waitForPodGone(ctx context.Context, t *testing.T, k8sClient *util.K8sClient, namespace, name string) {
	t.Helper()
	pods := k8sClient.Clientset().CoreV1().Pods(namespace)
	for deadline := time.Now().Add(time.Minute); time.Now().Before(deadline); time.Sleep(2 * time.Second) {
		if _, err := pods.Get(ctx, name, metav1.GetOptions{}); apierrors.IsNotFound(err) {
			return
		}
	}
	require.Failf(t, "old pod still exists", "%s/%s was not deleted within a minute", namespace, name)
}
