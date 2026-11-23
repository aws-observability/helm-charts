// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"context"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"testing"
	"time"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

const (
	agentCertSecret         = "amazon-cloudwatch-observability-agent-cert"
	agentServerCertSecret   = "amazon-cloudwatch-observability-agent-server-cert"
	agentClientCertSecret   = "amazon-cloudwatch-observability-agent-client-cert"
	agentTAClientCertSecret = "amazon-cloudwatch-observability-agent-ta-client-cert"
	webhookCertSecret       = "amazon-cloudwatch-observability-controller-manager-service-cert"
)

var certificateGVR = schema.GroupVersionResource{Group: "cert-manager.io", Version: "v1", Resource: "certificates"}

// TestCertManagerEnabled installs the chart with agent.certManager.enabled=true and
// admissionWebhooks.certManager.enabled=true, after cert-manager itself.
//
// It checks the issued certificates the way their consumers use them, not only that
// they exist: each TLS client in the chart trusts the ca.crt of one Secret and dials one
// hostname, and the server presents tls.crt from another Secret. The pairs below are
// copied from the chart's scrape configs and volume mounts, so a change there must be
// reflected here. With agent.autoGenerateCert every certificate is signed by one CA,
// and cert-manager mode must give the same guarantee.
func TestCertManagerEnabled(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	require.NoError(t, err)

	t.Run("CertificatesReady", func(t *testing.T) {
		for _, name := range []string{
			agentCertSecret,
			agentServerCertSecret,
			agentClientCertSecret,
			agentTAClientCertSecret,
			"amazon-cloudwatch-observability-serving-cert",
		} {
			assert.NoError(t, waitForCertificateReady(k8sClient, name, 3*time.Minute), "Certificate %s", name)
		}
	})

	t.Run("OperatorWebhookTrusted", func(t *testing.T) {
		whs, err := k8sClient.ListMutatingWebhookConfigurations()
		require.NoError(t, err)
		var caBundle []byte
		for _, item := range whs.Items {
			if item.Name == minikube.WebhookName && len(item.Webhooks) > 0 {
				caBundle = item.Webhooks[0].ClientConfig.CABundle
			}
		}
		require.NotEmpty(t, caBundle, "cert-manager cainjector should set the webhook caBundle")
		roots := x509.NewCertPool()
		require.True(t, roots.AppendCertsFromPEM(caBundle))
		serving := secretCert(t, k8sClient, webhookCertSecret, "tls.crt")
		_, err = serving.Verify(x509.VerifyOptions{
			Roots:   roots,
			DNSName: "amazon-cloudwatch-observability-webhook-service." + minikube.Namespace + ".svc",
		})
		assert.NoError(t, err, "API server cannot verify the operator webhook serving certificate")
	})

	// Regression for helm-charts#381: one dnsNames entry per agent, rendered as valid YAML.
	t.Run("AgentCertificateTargetAllocatorNames", func(t *testing.T) {
		cert := secretCert(t, k8sClient, agentCertSecret, "tls.crt")
		for _, name := range []string{
			"cloudwatch-agent-target-allocator-service",
			"cloudwatch-agent-cluster-scraper-target-allocator-service",
		} {
			assert.Contains(t, cert.DNSNames, name)
		}
	})

	t.Run("ScrapeTargetsTrusted", func(t *testing.T) {
		ns := minikube.Namespace
		for _, tc := range []struct {
			consumer     string
			serverSecret string
			trustSecret  string
			hostname     string
		}{
			{"agent -> node-exporter", agentCertSecret, agentClientCertSecret, "node-exporter-service"},
			{"agent -> dcgm-exporter", agentCertSecret, agentClientCertSecret, "dcgm-exporter-service"},
			{"agent -> neuron-monitor", agentCertSecret, agentClientCertSecret, "neuron-monitor-service"},
			{"cluster scraper -> kube-state-metrics", agentCertSecret, agentCertSecret, "kube-state-metrics." + ns + ".svc"},
		} {
			t.Run(tc.consumer, func(t *testing.T) {
				server := secretCert(t, k8sClient, tc.serverSecret, "tls.crt")
				_, err := server.Verify(x509.VerifyOptions{
					Roots:     secretPool(t, k8sClient, tc.trustSecret),
					DNSName:   tc.hostname,
					KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
				})
				assert.NoError(t, err, "%s: %s tls.crt does not verify for %s against %s ca.crt",
					tc.consumer, tc.serverSecret, tc.hostname, tc.trustSecret)
			})
		}
	})

	// The agent, cluster scraper and target allocator authenticate each other with the
	// server, client and TA client certificates, so all of them must chain to one CA.
	t.Run("AgentCertificatesShareOneCA", func(t *testing.T) {
		secrets := []string{agentCertSecret, agentServerCertSecret, agentClientCertSecret, agentTAClientCertSecret}
		for _, leaf := range secrets {
			for _, trust := range secrets {
				t.Run(fmt.Sprintf("%s/%s", leaf, trust), func(t *testing.T) {
					_, err := secretCert(t, k8sClient, leaf, "tls.crt").Verify(x509.VerifyOptions{
						Roots:     secretPool(t, k8sClient, trust),
						KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
					})
					assert.NoError(t, err, "%s tls.crt does not chain to %s ca.crt", leaf, trust)
				})
			}
		}
	})
}

func waitForCertificateReady(k8sClient *util.K8sClient, name string, timeout time.Duration) error {
	dynamicClient, err := k8sClient.GetDynamicClient()
	if err != nil {
		return err
	}
	deadline := time.Now().Add(timeout)
	for {
		cert, err := dynamicClient.Resource(certificateGVR).Namespace(minikube.Namespace).Get(context.TODO(), name, metav1.GetOptions{})
		if err == nil && certificateReady(cert) {
			return nil
		}
		if time.Now().After(deadline) {
			if err != nil {
				return err
			}
			return fmt.Errorf("Certificate %s not Ready after %s", name, timeout)
		}
		time.Sleep(5 * time.Second)
	}
}

func certificateReady(cert *unstructured.Unstructured) bool {
	conditions, _, _ := unstructured.NestedSlice(cert.Object, "status", "conditions")
	for _, c := range conditions {
		m, ok := c.(map[string]interface{})
		if ok && m["type"] == "Ready" && m["status"] == "True" {
			return true
		}
	}
	return false
}

func secretData(t *testing.T, k8sClient *util.K8sClient, secret, key string) []byte {
	t.Helper()
	s, err := k8sClient.Clientset().CoreV1().Secrets(minikube.Namespace).Get(context.TODO(), secret, metav1.GetOptions{})
	require.NoError(t, err)
	require.NotEmpty(t, s.Data[key], "secret %s has no %s", secret, key)
	return s.Data[key]
}

func secretCert(t *testing.T, k8sClient *util.K8sClient, secret, key string) *x509.Certificate {
	t.Helper()
	block, _ := pem.Decode(secretData(t, k8sClient, secret, key))
	require.NotNil(t, block, "secret %s %s is not PEM", secret, key)
	cert, err := x509.ParseCertificate(block.Bytes)
	require.NoError(t, err)
	return cert
}

func secretPool(t *testing.T, k8sClient *util.K8sClient, secret string) *x509.CertPool {
	t.Helper()
	pool := x509.NewCertPool()
	require.True(t, pool.AppendCertsFromPEM(secretData(t, k8sClient, secret, "ca.crt")), "secret %s ca.crt is not PEM", secret)
	return pool
}
