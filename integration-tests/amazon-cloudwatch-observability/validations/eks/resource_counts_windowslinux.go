// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

//go:build windowslinux

package eks

const (
	// Services count on Linux:
	// - amazon-cloudwatch-observability-webhook-service
	// - cloudwatch-agent
	// - cloudwatch-agent-headless
	// - cloudwatch-agent-monitoring
	// - dcgm-exporter-service
	// - neuron-monitor-service
	serviceCountLinux = 6

	// Services count on Windows:
	// - cloudwatch-agent-windows
	// - cloudwatch-agent-windows-headless
	// - cloudwatch-agent-windows-monitoring
	// - cloudwatch-agent-windows-container-insights-monitoring
	serviceCountWindows = 4

	// DaemonSet count on Linux:
	// - cloudwatch-agent
	// - dcgm-exporter
	// - fluent-bit
	// - neuron-monitor
	daemonSetCountLinux = 4

	// DaemonSet count on Windows:
	// - cloudwatch-agent-windows
	// - cloudwatch-agent-windows-container-insights
	// - fluent-bit-windows
	daemonSetCountWindows = 3

	// Pods count on Linux and Windows
	podCountLinux   = 3
	podCountWindows = 3
)
