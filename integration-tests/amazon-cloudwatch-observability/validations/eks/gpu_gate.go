// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package eks

const (
	dcgmVerdictRun  = "run"
	dcgmVerdictSkip = "skip"
	dcgmVerdictFail = "fail"
)

// dcgmVerdict says what TestDcgmExporterHealthy does when the dcgm-exporter DaemonSet wants
// desired pods: run the checks when it wants at least one, otherwise skip on a cluster with no
// GPU node, or fail when built with the gpu tag (expectGPU), where a GPU node must get a pod.
func dcgmVerdict(desired int32) string {
	switch {
	case desired > 0:
		return dcgmVerdictRun
	case expectGPU:
		return dcgmVerdictFail
	default:
		return dcgmVerdictSkip
	}
}
