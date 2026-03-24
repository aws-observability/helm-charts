# ROSA (Red Hat OpenShift on AWS) Templates

## Purpose
OpenShift-specific resources. Only rendered when `k8sMode: ROSA`.

## Components
- `cloudwatch-agent-scc.yaml` — SecurityContextConstraints granting the agent privileged access, hostDir volumes, hostNetwork, SYS_ADMIN capability. Scoped to the agent's ServiceAccount.
- `cloudwatch-agent-scc-clusterrole.yaml` — ClusterRole allowing `use` of the SCC.
- `cloudwatch-agent-ssc-clusterrolebinding.yaml` — Binds the ClusterRole to the agent ServiceAccount.

## Guard
All templates gated by: `{{ if and .Values.agent.enabled (eq .Values.k8sMode "ROSA") }}`

## Pitfalls
- The SCC grants broad privileges (privileged containers, hostNetwork, SYS_ADMIN). Don't widen the `users` list beyond the agent ServiceAccount.
- Note the typo in the filename: `ssc-clusterrolebinding` (should be `scc`). Don't rename — it would break existing deployments.
