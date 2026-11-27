// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

//go:build linuxonly || windowslinux

package eks

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const (
	// A GPU node pulls a large image and the exporter starts the DCGM host engine, so allow
	// longer than the minikube agent check (otlp_endpoint_test.go: 3 min Ready, 1 min stable).
	dcgmReadyTimeout = 5 * time.Minute
	dcgmStableWindow = 2 * time.Minute
	dcgmMetricsPort  = "9400"
	dcgmMetricPrefix = "DCGM_FI_"
)

// TestDcgmExporterHealthy checks that every dcgm-exporter pod becomes Ready, stays Ready with no
// container restart for dcgmStableWindow, and serves at least one DCGM_FI_ series on :9400/metrics.
// The operator adds no probe to the container and the DcgmExporter CR status has no health field,
// so pod status and the metrics endpoint are the only health signal. DCGM Exporter 4.9.0 under
// operator 3.8.1 crash-looped on a missing /etc/dcgm-exporter/config.yaml; this test fails on that.
//
// On a CPU-only cluster the DaemonSet wants 0 pods and the test skips. Built with the gpu tag
// (terraform/eks/gpu) it fails instead, so a GPU node that never gets a pod is caught too.
func TestDcgmExporterHealthy(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	require.NoError(t, err, "create k8s client")
	ctx := context.Background()

	// The operator creates the DaemonSet after the Helm release, and its status starts at 0, so on
	// a GPU cluster wait for the DaemonSet controller to count the GPU node before judging it.
	var ds *appsv1.DaemonSet
	deadline := time.Now().Add(dcgmReadyTimeout)
	for {
		ds, err = k8sClient.Clientset().AppsV1().DaemonSets(namespace).Get(ctx, dcgmExporterName, metav1.GetOptions{})
		if !expectGPU || (err == nil && ds.Status.DesiredNumberScheduled > 0) || time.Now().After(deadline) {
			break
		}
		time.Sleep(5 * time.Second)
	}
	require.NoError(t, err, "get DaemonSet %s", dcgmExporterName)
	desired := ds.Status.DesiredNumberScheduled
	switch dcgmVerdict(desired) {
	case dcgmVerdictFail:
		require.FailNow(t, "no dcgm-exporter pod scheduled",
			"DaemonSet %s still wants 0 pods after %s on a GPU cluster; check the node instance type and the chart's dcgmExporter affinity",
			dcgmExporterName, dcgmReadyTimeout)
	case dcgmVerdictSkip:
		t.Skipf("DaemonSet %s wants 0 pods: no NVIDIA GPU node in this cluster", dcgmExporterName)
	}
	t.Logf("DaemonSet %s wants %d pod(s)", dcgmExporterName, desired)

	// Use the DaemonSet's own selector, so no pod label is guessed.
	selector := metav1.ListOptions{LabelSelector: metav1.FormatLabelSelector(ds.Spec.Selector)}
	pods := waitDcgmPodsHealthy(t, k8sClient, selector, int(desired))

	// The chart serves :9400 over TLS with the agent's self-signed cert and no client auth. The API
	// server's pod proxy speaks https to the pod without verifying that cert.
	for _, p := range pods {
		raw, err := k8sClient.Clientset().CoreV1().Pods(namespace).
			ProxyGet("https", p.Name, dcgmMetricsPort, "/metrics", nil).DoRaw(ctx)
		require.NoError(t, err, "GET https://%s:%s/metrics through the API server proxy", p.Name, dcgmMetricsPort)
		n := countDcgmMetricLines(raw)
		t.Logf("pod %s serves %d %s* series", p.Name, n, dcgmMetricPrefix)
		assert.Positive(t, n, "pod %s /metrics has no %s* series", p.Name, dcgmMetricPrefix)
	}
}

// waitDcgmPodsHealthy waits until want dcgm-exporter pods are all healthy, then holds for
// dcgmStableWindow and checks they are still the same pods and still healthy. It returns the pods.
//
// shortcut: this follows validateAgentPodsRunning (validations/minikube/scenarios/otlp_endpoint_test.go),
// which lives in package scenarios and cannot be imported here. Move both into util/ if a third copy appears.
func waitDcgmPodsHealthy(t *testing.T, k8sClient *util.K8sClient, selector metav1.ListOptions, want int) []corev1.Pod {
	t.Helper()
	ctx := context.Background()
	podsAPI := k8sClient.Clientset().CoreV1().Pods(namespace)
	describe := func(list []corev1.Pod) []string {
		var out []string
		for _, p := range list {
			out = append(out, describeDcgmPod(ctx, k8sClient, p))
		}
		return out
	}

	var list []corev1.Pod
	deadline := time.Now().Add(dcgmReadyTimeout)
	for {
		got, err := podsAPI.List(ctx, selector)
		require.NoError(t, err, "list %s pods", dcgmExporterName)
		list = got.Items
		healthy := len(list) == want
		for _, p := range list {
			if !dcgmPodHealthy(p) {
				healthy = false
			}
		}
		if healthy {
			break
		}
		if time.Now().After(deadline) {
			require.Failf(t, "dcgm-exporter pods not healthy",
				"want %d Ready %s pod(s) with 0 restarts within %s, got %d: %v",
				want, dcgmExporterName, dcgmReadyTimeout, len(list), describe(list))
		}
		time.Sleep(5 * time.Second)
	}

	names := map[string]bool{}
	for _, p := range list {
		names[p.Name] = true
	}
	t.Logf("%d %s pod(s) Ready with 0 restarts; holding %s", len(list), dcgmExporterName, dcgmStableWindow)
	time.Sleep(dcgmStableWindow)

	got, err := podsAPI.List(ctx, selector)
	require.NoError(t, err, "list %s pods", dcgmExporterName)
	for _, p := range got.Items {
		assert.True(t, names[p.Name], "%s pod %s was replaced during the stability window", dcgmExporterName, p.Name)
		assert.True(t, dcgmPodHealthy(p), "%s pod %s is not healthy after %s: %s",
			dcgmExporterName, p.Name, dcgmStableWindow, describeDcgmPod(ctx, k8sClient, p))
	}
	require.Len(t, got.Items, want, "%s pod count changed during the stability window", dcgmExporterName)
	return got.Items
}

// dcgmPodHealthy is true when the pod is Ready and no container has restarted or is waiting.
// Any restart fails, not only one after Ready: a crash-looping pod restarts before it is ever Ready.
func dcgmPodHealthy(p corev1.Pod) bool {
	ready := false
	for _, c := range p.Status.Conditions {
		if c.Type == corev1.PodReady {
			ready = c.Status == corev1.ConditionTrue
		}
	}
	if !ready || len(p.Status.ContainerStatuses) == 0 {
		return false
	}
	for _, cs := range p.Status.ContainerStatuses {
		if cs.RestartCount > 0 || cs.State.Waiting != nil {
			return false
		}
	}
	return true
}

// describeDcgmPod gives the restart count, last exit, waiting reason and, after a restart, the
// end of the previous container log, because CI keeps no pod logs.
func describeDcgmPod(ctx context.Context, k8sClient *util.K8sClient, p corev1.Pod) string {
	var b strings.Builder
	b.WriteString(p.Name + ":")
	for _, cs := range p.Status.ContainerStatuses {
		fmt.Fprintf(&b, " %s restarts=%d", cs.Name, cs.RestartCount)
		if term := cs.LastTerminationState.Terminated; term != nil {
			fmt.Fprintf(&b, " last exit %d (%s) %q", term.ExitCode, term.Reason, term.Message)
		}
		if wait := cs.State.Waiting; wait != nil {
			fmt.Fprintf(&b, " waiting %s %q", wait.Reason, wait.Message)
		}
		if cs.RestartCount > 0 {
			tail := int64(40)
			raw, err := k8sClient.Clientset().CoreV1().Pods(namespace).
				GetLogs(p.Name, &corev1.PodLogOptions{Container: cs.Name, Previous: true, TailLines: &tail}).DoRaw(ctx)
			if err != nil {
				fmt.Fprintf(&b, "\n  (previous log unavailable: %v)", err)
			} else {
				fmt.Fprintf(&b, "\n  previous log (last %d lines):\n%s", tail, raw)
			}
		}
	}
	return b.String()
}

// countDcgmMetricLines counts Prometheus sample lines (not # HELP or # TYPE) whose name starts
// with DCGM_FI_.
func countDcgmMetricLines(body []byte) int {
	n := 0
	s := bufio.NewScanner(bytes.NewReader(body))
	s.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for s.Scan() {
		if strings.HasPrefix(s.Text(), dcgmMetricPrefix) {
			n++
		}
	}
	return n
}
