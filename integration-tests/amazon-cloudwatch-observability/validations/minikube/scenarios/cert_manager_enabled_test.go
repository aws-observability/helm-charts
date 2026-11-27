// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package scenarios

import (
	"context"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/util"
	"github.com/aws-observability/helm-charts/integration-tests/amazon-cloudwatch-observability/validations/minikube"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

const (
	agentCASecret           = "amazon-cloudwatch-observability-agent-ca"
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
			agentCASecret,
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

	t.Run("ScrapeTargetsTrusted", func(t *testing.T) { checkScrapeTargetsTrusted(t, k8sClient) })

	// The chart creates the agent Secrets empty and cert-manager fills them. Nothing restarts the
	// pods here, so this checks that a plain install serves the issued certificate.
	t.Run("TLSConnectionsWithoutRestart", func(t *testing.T) { checkTLSConnections(t, k8sClient, 0) })

	// The agent, cluster scraper and target allocator authenticate each other with the
	// server, client and TA client certificates, so all of them must chain to one CA.
	t.Run("AgentCertificatesShareOneCA", func(t *testing.T) { checkAgentCertificatesShareOneCA(t, k8sClient) })
}

// TestCertManagerRotation renews the CA, then one leaf certificate, and checks that every TLS
// client still trusts its peer. cert-manager 1.18 and later rotate the private key on renewal by
// default, so a CA renewed with a new key would leave leaves renewed at different times chained to
// different keys. The chart sets the CA's rotationPolicy to Never to prevent that.
func TestCertManagerRotation(t *testing.T) {
	k8sClient, err := util.NewK8sClient()
	require.NoError(t, err)

	caKey := secretCert(t, k8sClient, agentCASecret, "tls.crt").PublicKey
	require.NoError(t, renewCertificate(k8sClient, agentCASecret, 3*time.Minute))
	assert.Equal(t, caKey, secretCert(t, k8sClient, agentCASecret, "tls.crt").PublicKey,
		"the renewed CA has a new private key")

	// A leaf renewed after the CA, while the other leaves keep certificates signed before it.
	require.NoError(t, renewCertificate(k8sClient, agentCertSecret, 3*time.Minute))

	t.Run("ScrapeTargetsTrusted", func(t *testing.T) { checkScrapeTargetsTrusted(t, k8sClient) })
	t.Run("AgentCertificatesShareOneCA", func(t *testing.T) { checkAgentCertificatesShareOneCA(t, k8sClient) })
	// The kubelet updates mounted Secrets within about a minute; the servers must then serve the
	// renewed certificate without a restart.
	t.Run("TLSConnectionsServeRenewedCertificate", func(t *testing.T) { checkTLSConnections(t, k8sClient, 3*time.Minute) })
}

// tlsTarget is a server that presents agentCertSecret, and the Secret whose ca.crt its client
// trusts, as the chart wires them.
type tlsTarget struct{ addr, trustSecret string }

var tlsTargets = []tlsTarget{
	{"node-exporter-service:9487", agentClientCertSecret},
	{"kube-state-metrics." + minikube.Namespace + ".svc:8443", agentCertSecret},
}

// checkTLSConnections connects to each target from a pod that mounts the trust Secret, as the
// agent does, and checks that the TLS handshake verifies and that the server presents the
// certificate currently in agentCertSecret. It retries for up to wait, for a renewal to reach the
// mounted Secrets.
func checkTLSConnections(t *testing.T, k8sClient *util.K8sClient, wait time.Duration) {
	want := strings.ToLower(secretCert(t, k8sClient, agentCertSecret, "tls.crt").SerialNumber.Text(16))
	deadline := time.Now().Add(wait)
	for {
		results, err := runTLSProbe(k8sClient)
		require.NoError(t, err)
		ok := true
		for _, target := range tlsTargets {
			if results[target.addr] != "200 "+want {
				ok = false
			}
		}
		if ok || time.Now().After(deadline) {
			for _, target := range tlsTargets {
				assert.Equal(t, "200 "+want, results[target.addr],
					"%s: want HTTP 200 and the serial of %s, verified against %s ca.crt", target.addr, agentCertSecret, target.trustSecret)
			}
			return
		}
		time.Sleep(15 * time.Second)
	}
}

// runTLSProbe runs a curl pod against tlsTargets and returns "<http code> <served serial>" per target.
func runTLSProbe(k8sClient *util.K8sClient) (map[string]string, error) {
	pods := k8sClient.Clientset().CoreV1().Pods(minikube.Namespace)
	const name = "cert-manager-tls-probe"
	_ = pods.Delete(context.TODO(), name, metav1.DeleteOptions{})
	for i := 0; i < 30; i++ {
		if _, err := pods.Get(context.TODO(), name, metav1.GetOptions{}); err != nil {
			break
		}
		time.Sleep(2 * time.Second)
	}
	var script strings.Builder
	var mounts []corev1.VolumeMount
	var volumes []corev1.Volume
	seen := map[string]bool{}
	for _, target := range tlsTargets {
		fmt.Fprintf(&script, "out=$(curl -sS -o /dev/null --cacert /trust/%[2]s/ca.crt -w '%%{http_code} %%{certs}' https://%[1]s/metrics 2>&1); "+
			"echo \"%[1]s $(echo \"$out\" | head -1 | cut -d' ' -f1) $(echo \"$out\" | grep -m1 'Serial Number' | sed 's/.*://; s/[ :]//g')\"\n",
			target.addr, target.trustSecret)
		if !seen[target.trustSecret] {
			seen[target.trustSecret] = true
			mounts = append(mounts, corev1.VolumeMount{Name: fmt.Sprintf("trust%d", len(volumes)), MountPath: "/trust/" + target.trustSecret})
			volumes = append(volumes, corev1.Volume{Name: fmt.Sprintf("trust%d", len(volumes)),
				VolumeSource: corev1.VolumeSource{Secret: &corev1.SecretVolumeSource{SecretName: target.trustSecret}}})
		}
	}
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: corev1.PodSpec{
			RestartPolicy: corev1.RestartPolicyNever,
			Containers: []corev1.Container{{
				Name: "curl", Image: "curlimages/curl:8.8.0",
				Command: []string{"sh", "-c", script.String()}, VolumeMounts: mounts,
			}},
			Volumes: volumes,
		},
	}
	if _, err := pods.Create(context.TODO(), pod, metav1.CreateOptions{}); err != nil {
		return nil, err
	}
	defer func() { _ = pods.Delete(context.TODO(), name, metav1.DeleteOptions{}) }()
	deadline := time.Now().Add(3 * time.Minute)
	for {
		p, err := pods.Get(context.TODO(), name, metav1.GetOptions{})
		if err == nil && (p.Status.Phase == corev1.PodSucceeded || p.Status.Phase == corev1.PodFailed) {
			break
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("TLS probe pod did not finish in 3m")
		}
		time.Sleep(3 * time.Second)
	}
	raw, err := pods.GetLogs(name, &corev1.PodLogOptions{}).Do(context.TODO()).Raw()
	if err != nil {
		return nil, err
	}
	results := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		f := strings.Fields(line)
		if len(f) >= 2 {
			serial := ""
			if len(f) >= 3 {
				if n, ok := new(big.Int).SetString(f[2], 16); ok {
					serial = n.Text(16)
				}
			}
			results[f[0]] = f[1] + " " + serial
		}
	}
	return results, nil
}

func checkScrapeTargetsTrusted(t *testing.T, k8sClient *util.K8sClient) {
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
}

func checkAgentCertificatesShareOneCA(t *testing.T, k8sClient *util.K8sClient) {
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
}

// renewCertificate triggers re-issuance the way cmctl renew does, by setting the Issuing condition,
// and waits for the next revision to be Ready.
func renewCertificate(k8sClient *util.K8sClient, name string, timeout time.Duration) error {
	dynamicClient, err := k8sClient.GetDynamicClient()
	if err != nil {
		return err
	}
	certs := dynamicClient.Resource(certificateGVR).Namespace(minikube.Namespace)
	cert, err := certs.Get(context.TODO(), name, metav1.GetOptions{})
	if err != nil {
		return err
	}
	revision, _, _ := unstructured.NestedInt64(cert.Object, "status", "revision")
	conditions, _, _ := unstructured.NestedSlice(cert.Object, "status", "conditions")
	conditions = append(conditions, map[string]interface{}{
		"type":               "Issuing",
		"status":             "True",
		"reason":             "ManuallyTriggered",
		"message":            "Certificate re-issuance manually triggered",
		"lastTransitionTime": time.Now().UTC().Format(time.RFC3339),
	})
	if err := unstructured.SetNestedSlice(cert.Object, conditions, "status", "conditions"); err != nil {
		return err
	}
	if _, err := certs.UpdateStatus(context.TODO(), cert, metav1.UpdateOptions{}); err != nil {
		return err
	}
	deadline := time.Now().Add(timeout)
	for {
		cert, err = certs.Get(context.TODO(), name, metav1.GetOptions{})
		if err == nil {
			r, _, _ := unstructured.NestedInt64(cert.Object, "status", "revision")
			if r > revision && certificateReady(cert) {
				return nil
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("Certificate %s not reissued after %s", name, timeout)
		}
		time.Sleep(5 * time.Second)
	}
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
