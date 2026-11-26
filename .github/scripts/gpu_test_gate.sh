#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Usage: gpu_test_gate.sh <base-ref> [<head-ref>]
# Prints "true" when the change from base to head (default HEAD) touches a line inside the
# manager.image or dcgmExporter.image block of the chart's values.yaml, else "false". The GPU
# integration test costs a GPU node per run, so it runs only for the operator and DCGM Exporter
# images, the pair that broke in DCGM Exporter 4.9.0. If the diff cannot be read, prints "true".
set -uo pipefail

values=charts/amazon-cloudwatch-observability/values.yaml
base=$1
head=${2:-HEAD}

if ! diff=$(git diff -U0 "$base" "$head" -- "$values" 2>/dev/null); then
  echo true
  exit 0
fi

# changed_lines <old|new>: line numbers the diff changes on that side, from the @@ hunk headers.
changed_lines() {
  local side=$1
  sed -n 's/^@@ -\([0-9,]*\) +\([0-9,]*\) @@.*/\1 \2/p' <<<"$diff" | while read -r old new; do
    local range=$old
    [[ $side == new ]] && range=$new
    local start=${range%%,*} count=1
    [[ $range == *,* ]] && count=${range#*,}
    for ((i = 0; i < count; i++)); do echo $((start + i)); done
  done
}

# in_image_block <rev> <line numbers>: true if any line sits under manager.image or dcgmExporter.image.
in_image_block() {
  local rev=$1 lines=$2
  [[ -z $lines ]] && return 1
  git show "$rev:$values" 2>/dev/null | awk -v lines="$lines" '
    BEGIN { n = split(lines, l, "\n"); for (i = 1; i <= n; i++) want[l[i]] = 1 }
    /^[A-Za-z_][^:]*:/ { top = $1; sub(/:.*/, "", top); second = "" }
    /^  [A-Za-z_][^:]*:/ { second = $1; sub(/:.*/, "", second) }
    (NR in want) && (top == "manager" || top == "dcgmExporter") && second == "image" { hit = 1 }
    END { exit hit ? 0 : 1 }'
}

if in_image_block "$head" "$(changed_lines new)" || in_image_block "$base" "$(changed_lines old)"; then
  echo true
else
  echo false
fi
