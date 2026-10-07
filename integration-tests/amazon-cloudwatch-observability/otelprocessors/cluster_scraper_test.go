// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package otelprocessors

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestClusterScraperProcessors runs processors from the cluster scraper's
// config through the chart's CloudWatch Agent image.
func TestClusterScraperProcessors(t *testing.T) {
	scraper := Render(t, "cloudwatch-agent-cluster-scraper", nil)

	out := Run(t, scraper.Image, []Case{
		{
			Name:       "keda runtime metrics dropped",
			Processors: scraper.Processors(t, "filter/cw_k8s_ci_v0_keda_drop_non_keda"),
			Inputs: []Input{Metrics(nil, nil,
				"keda_scaler_active", "keda_scaled_object_errors_total",
				"go_goroutines", "process_cpu_seconds_total", "rest_client_requests_total",
				"workqueue_depth", "apiserver_request_total", "goroutines_total")},
		},
	})

	assert.ElementsMatch(t,
		[]string{"keda_scaler_active", "keda_scaled_object_errors_total", "goroutines_total"},
		out["keda runtime metrics dropped"].MetricNames())
}
