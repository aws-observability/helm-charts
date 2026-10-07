// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package otelprocessors

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestOTLPRequestAppendTo(t *testing.T) {
	var req otlpRequest
	require.NoError(t, json.Unmarshal([]byte(`{
  "resourceMetrics": [{
    "resource": {"attributes": [{"key": "k8s.namespace.name", "value": {"stringValue": "a"}}]},
    "scopeMetrics": [{"metrics": [
      {"name": "m1", "unit": "s", "gauge": {"dataPoints": [{"attributes": [{"key": "dp", "value": {"stringValue": "x"}}], "asDouble": 1}]}},
      {"name": "m2", "sum": {"dataPoints": [{"attributes": [{"key": "n", "value": {"intValue": "3"}}], "asInt": "1"}]}}
    ]}]
  }],
  "resourceLogs": [{
    "resource": {"attributes": [{"key": "k8s.namespace.name", "value": {"stringValue": "b"}}]},
    "scopeLogs": [{"logRecords": [
      {"body": {"stringValue": "hello"}, "attributes": [{"key": "k", "value": {"stringValue": "v"}}]}
    ]}]
  }]
}`), &req))

	var out Output
	req.appendTo(&out)

	assert.Equal(t, []string{"m1", "m2"}, out.MetricNames())
	assert.Equal(t, "s", out.Metrics[0].Unit)
	assert.Equal(t, map[string]string{"k8s.namespace.name": "a"}, out.Metrics[0].Resource)
	assert.Equal(t, map[string]string{"dp": "x"}, out.Metrics[0].Attributes)
	assert.Equal(t, map[string]string{"n": "3"}, out.Metrics[1].Attributes)
	assert.Equal(t, []string{"hello"}, out.LogBodies())
	assert.Equal(t, map[string]string{"k8s.namespace.name": "b"}, out.Logs[0].Resource)
	assert.Equal(t, map[string]string{"k": "v"}, out.Logs[0].Attributes)
}
