// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

//go:build linuxonly
// +build linuxonly

package validator

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
	// - cloudwatch-agent-windows-container-insights
	// - cloudwatch-agent-windows-container-insights-headless
	// - cloudwatch-agent-windows-container-insights-monitoring
	serviceCountWindows = 6

	// DaemonSet count on Linux:
	// - cloudwatch-agent
	// - dcgm-exporter
	// - fluent-bit
	// - neuron-monitor
	daemonsetCountLinux = 4

	// DaemonSet count on Windows:
	// - cloudwatch-agent-windows
	// - cloudwatch-agent-windows-container-insights
	// - fluent-bit-windows
	daemonsetCountWindows = 3

	// Pods count on Linux and Windows
	podCountLinux   = 3
	podCountWindows = 0
)
