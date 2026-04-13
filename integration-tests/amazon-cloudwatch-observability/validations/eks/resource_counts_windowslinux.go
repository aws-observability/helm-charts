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
	// - kube-state-metrics
	// - cloudwatch-agent-cluster-scraper-monitoring
	serviceCountLinux = 8

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
	// - node-exporter
	daemonSetCountLinux = 5

	// DaemonSet count on Windows:
	// - cloudwatch-agent-windows
	// - cloudwatch-agent-windows-container-insights
	// - fluent-bit-windows
	daemonSetCountWindows = 3

	// Pods count on Linux and Windows
	// podCountLinux includes 2 OTLP deployment pods (kube-state-metrics, cloudwatch-agent-cluster-scraper)
	// + 1 node-exporter daemonset pod
	podCountLinux   = 6
	podCountWindows = 3
)
