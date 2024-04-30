// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

//go:build windowslinux
// +build windowslinux

package validator

const (
	// Services count for CW agent on Linux and Windows
	serviceCountLinux   = 6
	serviceCountWindows = 3

	// DaemonSet count for CW agent on Linux and Windows
	daemonsetCountLinux   = 4
	daemonsetCountWindows = 2

	// Pods count for CW agent on Linux and Windows
	podCountLinux   = 3
	podCountWindows = 2
)
