// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

//go:build !gpu

package eks

// expectGPU is false on the CPU-only clusters, where TestDcgmExporterHealthy skips when the
// dcgm-exporter DaemonSet wants no pod.
const expectGPU = false
