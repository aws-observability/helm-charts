// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package otelprocessors

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"k8s.io/apimachinery/pkg/util/yaml"
)

const chartDir = "../../../charts/amazon-cloudwatch-observability"

// Processor is a named processor taken from a rendered OTEL config.
type Processor struct {
	Name   string
	Config map[string]interface{}
}

// Rendered is the OTEL config and image of one AmazonCloudWatchAgent from `helm template`.
type Rendered struct {
	Image      string
	OtelConfig map[string]interface{}
}

// Render runs `helm template` with OTEL Container Insights enabled plus the given
// values, and returns the named agent's OTEL config and image.
func Render(t *testing.T, agentName string, values map[string]interface{}) Rendered {
	t.Helper()
	valuesJSON, err := json.Marshal(values)
	require.NoError(t, err)
	valuesFile := filepath.Join(t.TempDir(), "values.json")
	require.NoError(t, os.WriteFile(valuesFile, valuesJSON, 0o600))

	out, err := exec.Command("helm", "template", chartDir,
		"--set", "region=us-west-2",
		"--set", "clusterName=test-cluster",
		"--set", "otelContainerInsights.enabled=true",
		"-f", valuesFile).CombinedOutput()
	require.NoError(t, err, "helm template failed:\n%s", out)

	decoder := yaml.NewYAMLOrJSONDecoder(bytes.NewReader(out), 4096)
	for {
		var doc struct {
			Kind     string `json:"kind"`
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
			Spec struct {
				Image      string `json:"image"`
				OtelConfig string `json:"otelConfig"`
			} `json:"spec"`
		}
		if err := decoder.Decode(&doc); err != nil {
			break
		}
		if doc.Kind != "AmazonCloudWatchAgent" || doc.Metadata.Name != agentName {
			continue
		}
		var cfg map[string]interface{}
		require.NoError(t, yaml.NewYAMLOrJSONDecoder(strings.NewReader(doc.Spec.OtelConfig), 4096).Decode(&cfg))
		return Rendered{Image: doc.Spec.Image, OtelConfig: cfg}
	}
	t.Fatalf("AmazonCloudWatchAgent %q not found in rendered chart", agentName)
	return Rendered{}
}

// Processors returns the named processors from the rendered OTEL config, in order.
func (r Rendered) Processors(t *testing.T, names ...string) []Processor {
	t.Helper()
	all, _ := r.OtelConfig["processors"].(map[string]interface{})
	var out []Processor
	for _, name := range names {
		cfg, ok := all[name]
		require.True(t, ok, "processor %q not in rendered config", name)
		cfgMap, _ := cfg.(map[string]interface{})
		out = append(out, Processor{Name: name, Config: cfgMap})
	}
	return out
}
