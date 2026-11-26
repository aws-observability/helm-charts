// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

package eks

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestDcgmVerdict needs no cluster and builds with any tags: without gpu a cluster with no
// dcgm-exporter pod skips, with gpu it fails.
func TestDcgmVerdict(t *testing.T) {
	assert.Equal(t, dcgmVerdictRun, dcgmVerdict(1))
	assert.Equal(t, dcgmVerdictRun, dcgmVerdict(3))
	noPod := dcgmVerdictSkip
	if expectGPU {
		noPod = dcgmVerdictFail
	}
	assert.Equal(t, noPod, dcgmVerdict(0))
}
