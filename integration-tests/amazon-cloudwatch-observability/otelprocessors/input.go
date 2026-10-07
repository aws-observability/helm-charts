// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package otelprocessors

import (
	"fmt"
	"time"
)

// Input is one OTLP JSON request.
type Input struct {
	signal string
	body   map[string]interface{}
}

// Metrics builds a request with one resource and one gauge per name. The
// datapoint attributes are set on every gauge.
func Metrics(resource map[string]string, datapoint map[string]string, names ...string) Input {
	var metrics []interface{}
	for _, name := range names {
		metrics = append(metrics, map[string]interface{}{
			"name": name,
			"gauge": map[string]interface{}{"dataPoints": []interface{}{map[string]interface{}{
				"asDouble":     1,
				"timeUnixNano": fmt.Sprint(time.Now().UnixNano()),
				"attributes":   attributes(datapoint),
			}}},
		})
	}
	return Input{signal: "metrics", body: map[string]interface{}{"resourceMetrics": []interface{}{map[string]interface{}{
		"resource":     map[string]interface{}{"attributes": attributes(resource)},
		"scopeMetrics": []interface{}{map[string]interface{}{"metrics": metrics}},
	}}}}
}

// Logs builds a request with one resource and one log record per body.
func Logs(resource map[string]string, bodies ...string) Input {
	var records []interface{}
	for _, body := range bodies {
		records = append(records, map[string]interface{}{
			"body":         map[string]interface{}{"stringValue": body},
			"timeUnixNano": fmt.Sprint(time.Now().UnixNano()),
		})
	}
	return Input{signal: "logs", body: map[string]interface{}{"resourceLogs": []interface{}{map[string]interface{}{
		"resource":  map[string]interface{}{"attributes": attributes(resource)},
		"scopeLogs": []interface{}{map[string]interface{}{"logRecords": records}},
	}}}}
}

func attributes(m map[string]string) []interface{} {
	var out []interface{}
	for k, v := range m {
		out = append(out, map[string]interface{}{"key": k, "value": map[string]interface{}{"stringValue": v}})
	}
	return out
}
