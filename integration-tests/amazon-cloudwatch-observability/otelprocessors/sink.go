// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package otelprocessors

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"
)

// sinkHost is the host the exporters send to. The agent only accepts otlphttp
// endpoints under an AWS DNS suffix, so the tests use a name that does not
// exist in public DNS and map it to the sink with --add-host. If the mapping
// is missing, the export fails instead of leaving the host.
const sinkHost = "otel-processor-test.invalid-region.amazonaws.com"

// sink records the OTLP JSON requests the exporters send, keyed by the case
// path prefix of the request ("/case0/v1/metrics" is case "/case0").
type sink struct {
	ip   string
	port int

	mu      sync.Mutex
	outputs map[string]*Output
}

// startSink starts the sink on the Docker bridge gateway address, which
// containers reach as host-gateway.
func startSink(t *testing.T) *sink {
	t.Helper()
	gateway, err := exec.Command("docker", "network", "inspect", "bridge",
		"--format", "{{(index .IPAM.Config 0).Gateway}}").Output()
	require.NoError(t, err, "finding the Docker bridge gateway")
	ip := strings.TrimSpace(string(gateway))
	listener, err := net.Listen("tcp", net.JoinHostPort(ip, "0"))
	require.NoError(t, err)

	s := &sink{ip: ip, port: listener.Addr().(*net.TCPAddr).Port, outputs: map[string]*Output{}}
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		prefix, _, found := strings.Cut(strings.TrimPrefix(r.URL.Path, "/"), "/")
		var req otlpRequest
		if err := json.NewDecoder(r.Body).Decode(&req); !found || err != nil {
			t.Errorf("sink: bad request %s: %v", r.URL.Path, err)
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		s.mu.Lock()
		out, ok := s.outputs["/"+prefix]
		if !ok {
			out = &Output{}
			s.outputs["/"+prefix] = out
		}
		req.appendTo(out)
		s.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte("{}"))
	}))
	server.Listener = listener
	server.Start()
	t.Cleanup(server.Close)
	return s
}

func (s *sink) output(prefix string) Output {
	s.mu.Lock()
	defer s.mu.Unlock()
	if out, ok := s.outputs[prefix]; ok {
		return *out
	}
	return Output{}
}

// otlpRequest is the part of an OTLP JSON export request the tests read.
type otlpRequest struct {
	ResourceMetrics []struct {
		Resource     otlpResource `json:"resource"`
		ScopeMetrics []struct {
			Metrics []struct {
				Name                 string          `json:"name"`
				Unit                 string          `json:"unit"`
				Gauge                *otlpDataPoints `json:"gauge"`
				Sum                  *otlpDataPoints `json:"sum"`
				Histogram            *otlpDataPoints `json:"histogram"`
				ExponentialHistogram *otlpDataPoints `json:"exponentialHistogram"`
				Summary              *otlpDataPoints `json:"summary"`
			} `json:"metrics"`
		} `json:"scopeMetrics"`
	} `json:"resourceMetrics"`
	ResourceLogs []struct {
		Resource  otlpResource `json:"resource"`
		ScopeLogs []struct {
			LogRecords []struct {
				Body       map[string]interface{} `json:"body"`
				Attributes []otlpAttribute        `json:"attributes"`
			} `json:"logRecords"`
		} `json:"scopeLogs"`
	} `json:"resourceLogs"`
}

type otlpResource struct {
	Attributes []otlpAttribute `json:"attributes"`
}

type otlpDataPoints struct {
	DataPoints []struct {
		Attributes []otlpAttribute `json:"attributes"`
	} `json:"dataPoints"`
}

type otlpAttribute struct {
	Key   string                 `json:"key"`
	Value map[string]interface{} `json:"value"`
}

func (r otlpRequest) appendTo(out *Output) {
	for _, rm := range r.ResourceMetrics {
		resource := attributeMap(rm.Resource.Attributes)
		for _, sm := range rm.ScopeMetrics {
			for _, m := range sm.Metrics {
				metric := Metric{Name: m.Name, Unit: m.Unit, Resource: resource, Attributes: map[string]string{}}
				for _, points := range []*otlpDataPoints{m.Gauge, m.Sum, m.Histogram, m.ExponentialHistogram, m.Summary} {
					if points == nil {
						continue
					}
					for _, dp := range points.DataPoints {
						for k, v := range attributeMap(dp.Attributes) {
							metric.Attributes[k] = v
						}
					}
				}
				out.Metrics = append(out.Metrics, metric)
			}
		}
	}
	for _, rl := range r.ResourceLogs {
		resource := attributeMap(rl.Resource.Attributes)
		for _, sl := range rl.ScopeLogs {
			for _, lr := range sl.LogRecords {
				out.Logs = append(out.Logs, Log{
					Body:       anyValue(lr.Body),
					Resource:   resource,
					Attributes: attributeMap(lr.Attributes),
				})
			}
		}
	}
}

func attributeMap(attrs []otlpAttribute) map[string]string {
	out := map[string]string{}
	for _, a := range attrs {
		out[a.Key] = anyValue(a.Value)
	}
	return out
}

// anyValue formats an OTLP AnyValue such as {"stringValue": "x"} or {"intValue": "1"}.
func anyValue(v map[string]interface{}) string {
	for _, value := range v {
		return fmt.Sprint(value)
	}
	return ""
}
