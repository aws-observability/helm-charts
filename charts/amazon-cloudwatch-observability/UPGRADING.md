# Upgrading amazon-cloudwatch-observability

This guide lists the changes that can need action when you upgrade the chart. Each section
applies to an upgrade from any earlier chart version to that version, not only from the
previous release.

## Upgrading to 8.0.0

### Target Allocator selectors are Kubernetes label selectors

**Who is affected.** Anyone who creates or manages their own `AmazonCloudWatchAgent` resources
and sets `spec.targetAllocator.prometheusCR.serviceMonitorSelector` or
`spec.targetAllocator.prometheusCR.podMonitorSelector`. The resources that the chart itself
creates are not affected: chart versions before 8.0.0 do not set these fields.

**What changed.** The 8.0.0 `AmazonCloudWatchAgent` CRD types both fields as Kubernetes label
selectors (`matchLabels` and `matchExpressions`) instead of a flat map of labels.

**What happens if you don't act.** Once the 8.0.0 CRD is installed (by the
[CRD update Job](#crd-update-job) on `helm upgrade`, by the EKS add-on, or by Argo CD), the
API server no longer returns the flat-map labels. The selector reads back as `{}`, even though
nothing wrote to the resource. An empty label selector matches every object, so the target
allocator selects every ServiceMonitor or PodMonitor it can see instead of the ones you
selected. Applying your old manifest again does not bring the labels back:
`kubectl apply` rejects it with `strict decoding error: unknown field
"spec.targetAllocator.prometheusCR.serviceMonitorSelector.<label>"`, and with
`--validate=false` the labels are dropped and the selector stays empty.

**Find affected resources before you upgrade.** After the 8.0.0 CRD is installed, the old
labels can no longer be read. This prints `<namespace>/<name> <field> <labels>` for every
selector that is still a flat map:

```bash
kubectl get amazoncloudwatchagents.cloudwatch.aws.amazon.com -A -o json | jq -r '
  .items[]
  | (.metadata.namespace + "/" + .metadata.name) as $n
  | (.spec.targetAllocator.prometheusCR // {}) | to_entries[]
  | select((.key == "serviceMonitorSelector" or .key == "podMonitorSelector")
      and (.value | type == "object" and length > 0
           and (has("matchLabels") or has("matchExpressions") | not)))
  | "\($n) \(.key) \(.value | tojson)"'
```

**Migrate.** Move the labels under `matchLabels`:

```yaml
# Before 8.0.0
spec:
  targetAllocator:
    prometheusCR:
      enabled: true
      serviceMonitorSelector:
        team: payments
      podMonitorSelector:
        team: payments
```

```yaml
# 8.0.0 and later
spec:
  targetAllocator:
    prometheusCR:
      enabled: true
      serviceMonitorSelector:
        matchLabels:
          team: payments
      podMonitorSelector:
        matchLabels:
          team: payments
```

The CRD from before 8.0.0 rejects `matchLabels` (it accepts only string values), so apply the
new format after the 8.0.0 CRD is installed, that is, right after the upgrade. To keep the
target allocator from selecting every monitor until then, set `prometheusCR.enabled: false`
on the affected resources before you upgrade, and turn it back on together with the new
selectors.

### OTLP endpoint and profiles are on by default

- The node agent serves OTLP on host ports 4317 (gRPC) and 4318 (HTTP) on every node. Another
  collector that holds those ports leaves one of the two pods Pending, and a custom agent
  config or `otelConfig` receiver on the same ports stops the agent from starting. Set
  `otlp.enabled: false`, or change `otlp.grpc.port` and `otlp.http.port`.
- OTLP profiles (`otlp.profiles.enabled: true`) need agent image 1.300075.0 or later. If you
  pin an older `agent.image.tag`, set `otlp.profiles.enabled: false`.
- `agents[].config: "default:otel"` now builds the same config as `default`. Use
  `otlp.enabled` to turn the OTLP endpoint on or off.

See [OTLP endpoint](README.md#otlp-endpoint) in the chart README.

### CRD update Job

`helm install` and `helm upgrade` now run a pre-install and pre-upgrade hook Job
(`crds.upgradeJob`, on by default) that applies the chart's `crds/`. Before 8.0.0,
`helm upgrade` never updated the CRDs, so this Job is what moves a cluster from the CRDs of
its first install to the 8.0.0 CRDs.

- The Job pulls `registry.k8s.io/kubectl`. If your nodes pull through a mirror or have
  restricted egress, mirror the image and set `crds.upgradeJob.image.repositoryDomainMap.public`,
  `crds.upgradeJob.image.repository` and `crds.upgradeJob.image.tag`, or set
  `crds.upgradeJob.enabled: false`. Otherwise the Job can't start and the install or upgrade
  fails at the hook.
- The Job only updates the chart's CRDs that are already installed. A CRD that was added to
  the chart after your first install (for example `DcgmExporter` and `NeuronMonitor`, added in
  chart 1.5.2) is not created by `helm upgrade` or by the Job. Apply `crds/` to add it:

  ```bash
  helm pull aws-observability/amazon-cloudwatch-observability --version 8.0.0 --untar
  kubectl apply --server-side --force-conflicts -f amazon-cloudwatch-observability/crds/
  ```

- The EKS add-on and Argo CD apply `crds/` themselves and don't run the Job.

See [CRD updates on helm upgrade](README.md#crd-updates-on-helm-upgrade) in the chart README,
including its troubleshooting steps.
