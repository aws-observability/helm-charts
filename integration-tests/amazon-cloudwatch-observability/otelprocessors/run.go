// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

// Package otelprocessors tests the processors in the chart's rendered OTEL
// Container Insights config by running them in the chart's CloudWatch Agent
// image, using Docker. Each case gets its own pipeline: an OTLP receiver, the
// processors under test and an otlphttp exporter that sends to a sink in the
// test process. Tests send OTLP JSON and assert on what reaches the sink. No
// cluster or AWS credentials are needed.
package otelprocessors

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// containerName is unique per test process, so concurrent runs on one host do
// not remove each other's container.
var containerName = fmt.Sprintf("otel-processor-test-%d", os.Getpid())

// Case is one pipeline: the processors under test and the requests to send through them.
type Case struct {
	Name       string
	Processors []Processor
	Inputs     []Input
}

// Metric is one exported metric. Attributes are the attributes of its data points.
type Metric struct {
	Name       string
	Unit       string
	Resource   map[string]string
	Attributes map[string]string
}

// Log is one exported log record.
type Log struct {
	Body       string
	Resource   map[string]string
	Attributes map[string]string
}

// Output is everything one case exported.
type Output struct {
	Metrics []Metric
	Logs    []Log
}

// MetricNames returns the names of the exported metrics.
func (o Output) MetricNames() []string {
	var out []string
	for _, m := range o.Metrics {
		out = append(out, m.Name)
	}
	return out
}

// LogBodies returns the bodies of the exported log records.
func (o Output) LogBodies() []string {
	var out []string
	for _, l := range o.Logs {
		out = append(out, l.Body)
	}
	return out
}

// Run starts one collector in the given image with a pipeline per case, sends
// each case's inputs and returns each case's output, keyed by case name. It
// fails if the collector does not start, an export fails or the collector
// logs an error.
//
// The pipelines have no batch processor and the exporters have no sending
// queue, so a case's data reaches the sink before its OTLP request returns.
func Run(t *testing.T, image string, cases []Case) map[string]Output {
	t.Helper()
	sink := startSink(t)
	ports := make([]int, len(cases))
	receivers := map[string]interface{}{}
	processors := map[string]interface{}{}
	exporters := map[string]interface{}{}
	pipelines := map[string]interface{}{}
	for i, c := range cases {
		require.NotEmpty(t, c.Inputs, "case %q has no inputs", c.Name)
		ports[i] = freePort(t)
		receiver := fmt.Sprintf("otlp/case%d", i)
		receivers[receiver] = map[string]interface{}{"protocols": map[string]interface{}{
			"http": map[string]interface{}{"endpoint": fmt.Sprintf("0.0.0.0:%d", ports[i])},
		}}
		var names []string
		for _, p := range c.Processors {
			name := caseComponentName(p.Name, i)
			processors[name] = p.Config
			names = append(names, name)
		}
		exporter := fmt.Sprintf("otlphttp/case%d", i)
		exporters[exporter] = map[string]interface{}{
			"endpoint":         fmt.Sprintf("http://%s:%d/case%d", sinkHost, sink.port, i),
			"encoding":         "json",
			"compression":      "none",
			"retry_on_failure": map[string]interface{}{"enabled": false},
			"sending_queue":    map[string]interface{}{"enabled": false},
		}
		pipelines[fmt.Sprintf("%s/case%d", c.Inputs[0].signal, i)] = map[string]interface{}{
			"receivers":  []string{receiver},
			"processors": names,
			"exporters":  []string{exporter},
		}
	}
	config := map[string]interface{}{
		"receivers": receivers,
		"exporters": exporters,
		"service": map[string]interface{}{
			"telemetry": map[string]interface{}{"metrics": map[string]interface{}{"level": "none"}},
			"pipelines": pipelines,
		},
	}
	if len(processors) > 0 {
		config["processors"] = processors
	}
	startCollector(t, image, config, ports, sink.ip)

	outputs := map[string]Output{}
	for i, c := range cases {
		for _, in := range c.Inputs {
			require.Equal(t, c.Inputs[0].signal, in.signal, "case %q mixes metrics and logs", c.Name)
			send(t, ports[i], in)
		}
		outputs[c.Name] = sink.output(fmt.Sprintf("/case%d", i))
	}
	for _, line := range strings.Split(containerLogs(t), "\n") {
		require.NotContains(t, line, " E! ", "collector logged an error")
	}
	return outputs
}

// caseComponentName makes a component ID unique per case: "filter/x" becomes "filter/case0_x".
func caseComponentName(name string, i int) string {
	typ, suffix, found := strings.Cut(name, "/")
	if !found {
		return fmt.Sprintf("%s/case%d", typ, i)
	}
	return fmt.Sprintf("%s/case%d_%s", typ, i, suffix)
}

func startCollector(t *testing.T, image string, config map[string]interface{}, ports []int, sinkIP string) {
	t.Helper()
	dir := t.TempDir()
	configJSON, err := json.MarshalIndent(config, "", "  ")
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "otel.yaml"), configJSON, 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "agent.toml"), []byte("[agent]\n  omit_hostname = true\n"), 0o644))

	_ = exec.Command("docker", "rm", "-f", containerName).Run()
	t.Cleanup(func() { _ = exec.Command("docker", "rm", "-f", containerName).Run() })
	args := []string{"run", "-d", "--name", containerName,
		"--add-host", sinkHost + ":" + sinkIP,
		"-v", dir + ":/etc/otel-processor-test:ro"}
	for _, port := range ports {
		args = append(args, "-p", fmt.Sprintf("127.0.0.1:%d:%d", port, port))
	}
	args = append(args, "--entrypoint", "/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent",
		image, "-config", "/etc/otel-processor-test/agent.toml", "-otelconfig", "/etc/otel-processor-test/otel.yaml")
	out, err := exec.Command("docker", args...).CombinedOutput()
	require.NoError(t, err, "docker run failed:\n%s", out)

	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		logs := containerLogs(t)
		if strings.Contains(logs, "Everything is ready") {
			return
		}
		running, _ := exec.Command("docker", "inspect", "-f", "{{.State.Running}}", containerName).Output()
		if strings.TrimSpace(string(running)) == "false" {
			t.Fatalf("collector exited during startup:\n%s\nconfig:\n%s", logs, configJSON)
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("collector did not start within 60s:\n%s", containerLogs(t))
}

func containerLogs(t *testing.T) string {
	t.Helper()
	out, err := exec.Command("docker", "logs", containerName).CombinedOutput()
	require.NoError(t, err, "docker logs failed:\n%s", out)
	return string(out)
}

func send(t *testing.T, port int, in Input) {
	t.Helper()
	body, err := json.Marshal(in.body)
	require.NoError(t, err)
	resp, err := http.Post(fmt.Sprintf("http://127.0.0.1:%d/v1/%s", port, in.signal), "application/json", bytes.NewReader(body))
	require.NoError(t, err)
	respBody, _ := io.ReadAll(resp.Body)
	require.NoError(t, resp.Body.Close())
	require.Equal(t, http.StatusOK, resp.StatusCode, "OTLP request failed: %s", respBody)
}

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}
