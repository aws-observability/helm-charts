// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

//go:build linuxonly || windowslinux

package eks

import (
	"testing"

	"github.com/stretchr/testify/assert"
	corev1 "k8s.io/api/core/v1"
)

// These tests need no cluster. They cover the checks TestDcgmExporterHealthy applies to each pod.

func dcgmTestPod(ready bool, restarts int32, waiting string) corev1.Pod {
	status := corev1.ConditionFalse
	if ready {
		status = corev1.ConditionTrue
	}
	cs := corev1.ContainerStatus{Name: dcgmExporterName, RestartCount: restarts}
	if waiting != "" {
		cs.State.Waiting = &corev1.ContainerStateWaiting{Reason: waiting}
	}
	return corev1.Pod{Status: corev1.PodStatus{
		Conditions:        []corev1.PodCondition{{Type: corev1.PodReady, Status: status}},
		ContainerStatuses: []corev1.ContainerStatus{cs},
	}}
}

func TestDcgmPodHealthy(t *testing.T) {
	assert.True(t, dcgmPodHealthy(dcgmTestPod(true, 0, "")), "Ready, no restart")
	assert.False(t, dcgmPodHealthy(dcgmTestPod(false, 0, "")), "not Ready")
	assert.False(t, dcgmPodHealthy(dcgmTestPod(true, 1, "")), "Ready but restarted once")
	assert.False(t, dcgmPodHealthy(dcgmTestPod(false, 3, "CrashLoopBackOff")), "crash loop")
	assert.False(t, dcgmPodHealthy(dcgmTestPod(true, 0, "ContainerCreating")), "container waiting")
	assert.False(t, dcgmPodHealthy(corev1.Pod{}), "no status yet")
}

func TestCountDcgmMetricLines(t *testing.T) {
	body := []byte(`# HELP DCGM_FI_DEV_GPU_UTIL GPU utilization (in %).
# TYPE DCGM_FI_DEV_GPU_UTIL gauge
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-1"} 0
DCGM_FI_DEV_FB_USED{gpu="0",UUID="GPU-1"} 0
go_goroutines 12
`)
	assert.Equal(t, 2, countDcgmMetricLines(body))
	assert.Equal(t, 0, countDcgmMetricLines([]byte("# HELP DCGM_FI_DEV_GPU_UTIL x\ngo_goroutines 12\n")))
	assert.Equal(t, 0, countDcgmMetricLines(nil))
}
