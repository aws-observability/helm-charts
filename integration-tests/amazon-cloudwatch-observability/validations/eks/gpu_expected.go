// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

//go:build gpu

package eks

// expectGPU is true when the test cluster has an NVIDIA GPU node (terraform/eks/gpu), so
// TestDcgmExporterHealthy fails instead of skipping when no dcgm-exporter pod is scheduled.
const expectGPU = true
