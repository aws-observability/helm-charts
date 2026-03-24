# Windows Templates

## Purpose
Windows-specific deployment templates. Deploys separate CloudWatch Agent and Fluent Bit DaemonSets targeting `kubernetes.io/os: windows` nodes.

## Components

### CloudWatch Agent Windows (`cloudwatch-agent-windows-daemonset.yaml`)
Creates an `AmazonCloudWatchAgent` CR named `{agent-name}-windows` for Application Signals (traces + metrics). Runs as `NT AUTHORITY\System`. Hardcoded config — does not use `agent.config` override, only applies `cloudwatch-agent.modify-config` to a fixed JSON payload.

### CloudWatch Agent Windows Container Insights (`cloudwatch-agent-windows-container-insights-daemonset.yaml`)
Separate CR named `{agent-name}-windows-container-insights` for Container Insights metrics. Runs as a HostProcess container (`hostProcess: true`) with `hostNetwork: true`. Also uses a hardcoded config focused on `kubernetes.enhanced_container_insights`.

### Fluent Bit Windows (`fluent-bit-windows-configmap.yaml`, `fluent-bit-windows-daemonset.yaml`)
Windows log collection. Uses Windows-specific paths (`C:\var\log\containers\`), Windows Event Log inputs (`winlog`), and the `docker` parser instead of `cri`. Config lives in `containerLogs.fluentBit.configWindows`.

## Key Differences from Linux
- Two separate agent CRs instead of one (Application Signals + Container Insights split)
- Hardcoded agent configs — not driven by `agents` list or `agent.config`
- HostProcess containers for Container Insights (required for Windows node-level metrics)
- Fluent Bit uses `configWindows` section, not `config`
- No DCGM, Neuron, OTEL, or kube-state-metrics on Windows

## Pitfalls
- Windows agent configs are hardcoded in the templates — changing `agent.defaultConfig` won't affect Windows agents.
- The Container Insights Windows agent requires HostProcess — this needs Windows Server 2022+ and containerd.
- Don't add Linux-only components (DCGM, Neuron, node-exporter) to Windows templates.
