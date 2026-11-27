#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Tests for gpu_test_gate.sh: it must print true only when a change touches the manager or
# dcgmExporter image block of the chart's values.yaml. Builds throwaway git repos; no network.
set -euo pipefail

gate="$(cd "$(dirname "$0")" && pwd)/gpu_test_gate.sh"
values=charts/amazon-cloudwatch-observability/values.yaml
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0

base_values() {
  cat <<'EOF'
## Operator
manager:
  name:
  image:
    repository: cloudwatch-agent-operator
    tag: 3.8.1
    repositoryDomainMap:
      public: public.ecr.aws/cloudwatch-agent
  resources:
    limits:
      cpu: 200m
agent:
  image:
    tag: 1.0.0
dcgmExporter:
  enabled: true
  image:
    repository: dcgm-exporter
    tag: 4.7.0-4.9.0-distroless
  resources:
    limits:
      cpu: 100m
neuronMonitor:
  image:
    tag: 1.0.0
EOF
}

# check <name> <want> <sed expression applied to values.yaml | other-file>
check() {
  local name=$1 want=$2 edit=$3 repo="$work/$1"
  mkdir -p "$repo/$(dirname "$values")"
  git -C "$repo" init -q
  base_values >"$repo/$values"
  echo readme >"$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m base
  if [[ $edit == other-file ]]; then
    echo changed >"$repo/README.md"
  else
    sed -i "$edit" "$repo/$values"
  fi
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m change
  local got
  got=$(cd "$repo" && bash "$gate" HEAD~1 HEAD)
  if [[ $got == "$want" ]]; then
    echo "PASS $name"
  else
    echo "FAIL $name: want $want, got $got"
    fails=$((fails + 1))
  fi
}

check manager-tag true 's/tag: 3.8.1/tag: 3.9.0/'
check manager-domain true 's#public: public.ecr.aws/cloudwatch-agent#public: example.com/cwa#'
check dcgm-tag true 's/tag: 4.7.0-4.9.0-distroless/tag: 4.6.0-4.8.3-distroless/'
check dcgm-repo-line-deleted true '/repository: dcgm-exporter/d'
check manager-resources false 's/cpu: 200m/cpu: 300m/'
check dcgm-enabled false 's/enabled: true/enabled: false/'
check dcgm-resources false 's/cpu: 100m/cpu: 150m/'
check agent-tag false '0,/tag: 1.0.0/s//tag: 2.0.0/'
# shellcheck disable=SC2016 # $ is sed's last-line address, not a shell variable.
check neuron-tag false '$s/tag: 1.0.0/tag: 2.0.0/'
check other-file false other-file

if ((fails > 0)); then
  echo "$fails gpu_test_gate check(s) failed"
  exit 1
fi
echo "All gpu_test_gate checks passed"
