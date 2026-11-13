#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT
#
# Validates crds.upgradeJob, the pre-install/pre-upgrade hook that applies the chart's
# crds/ before Helm applies the release (templates/crd-upgrade-job.yaml):
#   - one ConfigMap per crds/ file, byte-identical to it, all mounted into the Job;
#   - RBAC limited to get and patch on the chart's CRDs by name, bound to the Job's
#     ServiceAccount;
#   - every object is a pre-install,pre-upgrade hook, deleted on success, with the
#     ConfigMaps and RBAC ordered before the Job;
#   - the Job runs kubectl apply --server-side on Linux nodes, as non-root;
#   - nothing renders with upgradeJob disabled, or without hooks (how the EKS add-on
#     renders the chart).
#
# Template-level test (helm template only). Run from the repo root:
#     bash charts/amazon-cloudwatch-observability/tests/crd_upgrade_job.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
N='\033[0m'
pass_count=0
fail_count=0
pass() { printf "${G}PASS${N} %s\n" "$1"; pass_count=$((pass_count+1)); }
fail() { printf "${R}FAIL${N} %s\n" "$1"; fail_count=$((fail_count+1)); }

render() {
    # shellcheck disable=SC2068
    helm template t "$CHART_DIR" --namespace amazon-cloudwatch \
        --set region=us-west-2 --set clusterName=test-cluster $@ 2>&1
}

# expect_py <desc> <python-check> <render-args...>
# The check gets `docs` (every rendered object), `hook` (the crd-upgrade objects by
# kind/name), `job` (the Job or None) and CHART (the chart directory). It prints "ok"
# or a failure reason.
expect_py() {
    local desc="$1" check="$2"; shift 2
    local out res
    out="$(render "$@")" || { fail "$desc (helm error) $(printf '%s' "$out" | head -c 300)"; return; }
    res="$(printf '%s\n' "$out" | CHECK="$check" CHART="$CHART_DIR" python3 -c '
import glob, os, sys, yaml
CHART = os.environ["CHART"]
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
hook = {"%s/%s" % (d["kind"], d["metadata"]["name"]): d for d in docs
        if (d["metadata"].get("labels") or {}).get("app.kubernetes.io/component") == "crd-upgrade"}
jobs = [d for d in hook.values() if d["kind"] == "Job"]
job = jobs[0] if jobs else None
def crd_files():
    out = {}
    for p in sorted(glob.glob(os.path.join(CHART, "crds", "*.yaml"))):
        out[os.path.basename(p)] = open(p).read()
    return out
try:
    exec(os.environ["CHECK"])
except Exception as e:
    print("error: %r" % (e,))
')" || true
    if [[ "$res" == "ok" ]]; then pass "$desc"; else fail "$desc: $res [$*]"; fi
}

printf "${Y}== hook objects ==${N}\n"
expect_py "default => ServiceAccount, ClusterRole, ClusterRoleBinding, Job and one ConfigMap per CRD" '
kinds = sorted(k.split("/")[0] for k in hook)
want = sorted(["ServiceAccount", "ClusterRole", "ClusterRoleBinding", "Job"] + ["ConfigMap"] * len(crd_files()))
assert kinds == want, kinds
print("ok")'
expect_py "every hook object is a pre-install,pre-upgrade hook deleted on success" '
for k, d in hook.items():
    a = d["metadata"]["annotations"]
    assert a["helm.sh/hook"] == "pre-install,pre-upgrade", (k, a)
    assert a["helm.sh/hook-delete-policy"] == "before-hook-creation,hook-succeeded", (k, a)
print("ok")'
expect_py "ConfigMaps and RBAC run before the Job (hook weights)" '
w = {k: int(d["metadata"]["annotations"]["helm.sh/hook-weight"]) for k, d in hook.items()}
jw = w.pop("Job/" + job["metadata"]["name"])
assert all(v < jw for v in w.values()), (w, jw)
print("ok")'
expect_py "no rollback hook (a rollback keeps the newer CRDs)" '
assert all("rollback" not in d["metadata"]["annotations"]["helm.sh/hook"] for d in hook.values())
print("ok")'

printf "\n${Y}== CRD content ==${N}\n"
expect_py "one ConfigMap per crds/ file, byte-identical to it" '
files = crd_files()
got = {}
for d in hook.values():
    if d["kind"] == "ConfigMap":
        assert len(d["data"]) == 1, d["metadata"]["name"]
        got.update(d["data"])
assert sorted(got) == sorted(files), (sorted(got), sorted(files))
for name, content in files.items():
    assert got[name] == content, "%s differs" % name
print("ok")'
expect_py "every ConfigMap fits the 1 MiB object limit" '
for d in hook.values():
    if d["kind"] == "ConfigMap":
        n = sum(len(v.encode()) for v in d["data"].values())
        assert n < 1000 * 1024, (d["metadata"]["name"], n)
print("ok")'
expect_py "the Job mounts every ConfigMap at /crds" '
cms = sorted(d["metadata"]["name"] for d in hook.values() if d["kind"] == "ConfigMap")
spec = job["spec"]["template"]["spec"]
vol = [v for v in spec["volumes"] if v["name"] == "crds"][0]
assert sorted(s["configMap"]["name"] for s in vol["projected"]["sources"]) == cms, vol
mounts = {m["name"]: m["mountPath"] for m in spec["containers"][0]["volumeMounts"]}
assert mounts["crds"] == "/crds", mounts
print("ok")'

printf "\n${Y}== RBAC ==${N}\n"
expect_py "ClusterRole: only get and patch, only on the chart CRDs by name" '
names = sorted(yaml.safe_load(c)["metadata"]["name"] for c in crd_files().values())
role = [d for d in hook.values() if d["kind"] == "ClusterRole"][0]
assert len(role["rules"]) == 1, role["rules"]
named = role["rules"][0]
assert named["apiGroups"] == ["apiextensions.k8s.io"] and named["resources"] == ["customresourcedefinitions"], named
assert sorted(named["resourceNames"]) == names, named["resourceNames"]
assert sorted(named["verbs"]) == ["get", "patch"], named["verbs"]
print("ok")'
expect_py "ClusterRoleBinding binds the ClusterRole to the Job ServiceAccount" '
sa = [d for d in hook.values() if d["kind"] == "ServiceAccount"][0]
crb = [d for d in hook.values() if d["kind"] == "ClusterRoleBinding"][0]
role = [d for d in hook.values() if d["kind"] == "ClusterRole"][0]
assert crb["roleRef"]["name"] == role["metadata"]["name"], crb["roleRef"]
assert crb["subjects"] == [{"kind": "ServiceAccount", "name": sa["metadata"]["name"], "namespace": "amazon-cloudwatch"}], crb["subjects"]
assert job["spec"]["template"]["spec"]["serviceAccountName"] == sa["metadata"]["name"]
print("ok")'

printf "\n${Y}== Job ==${N}\n"
expect_py "kubectl apply --server-side --force-conflicts of /crds" '
c = job["spec"]["template"]["spec"]["containers"][0]
assert c["args"] == ["apply", "--server-side", "--force-conflicts", "--field-manager=amazon-cloudwatch-observability-crds", "--filename=/crds"], c["args"]
assert c["image"] == "registry.k8s.io/kubectl:v1.35.10", c["image"]
print("ok")'
expect_py "Linux nodes, non-root, read-only root, no capabilities" '
spec = job["spec"]["template"]["spec"]
assert spec["nodeSelector"]["kubernetes.io/os"] == "linux", spec["nodeSelector"]
psc = spec["securityContext"]
assert psc["runAsNonRoot"] is True and psc["runAsUser"] == 65534, psc
sc = spec["containers"][0]["securityContext"]
assert sc["readOnlyRootFilesystem"] is True and sc["allowPrivilegeEscalation"] is False and sc["capabilities"]["drop"] == ["ALL"], sc
assert spec["restartPolicy"] == "OnFailure"
print("ok")'
expect_py "ROSA => no fixed UID (OpenShift assigns one)" '
psc = job["spec"]["template"]["spec"]["securityContext"]
assert psc["runAsNonRoot"] is True and "runAsUser" not in psc, psc
print("ok")' --set k8sMode=ROSA
expect_py "image domain from repositoryDomainMap for the region" '
assert job["spec"]["template"]["spec"]["containers"][0]["image"] == "123456789012.dkr.ecr.cn-north-1.amazonaws.com.cn/kubectl:v1.35.10"
print("ok")' --set region=cn-north-1 --set 'crds.upgradeJob.image.repositoryDomainMap.cn-north-1=123456789012.dkr.ecr.cn-north-1.amazonaws.com.cn'
expect_py "tolerations fall back to the top-level tolerations" '
assert job["spec"]["template"]["spec"]["tolerations"] == [{"key": "a", "operator": "Exists"}], job["spec"]["template"]["spec"].get("tolerations")
print("ok")' --set-json 'tolerations=[{"key":"a","operator":"Exists"}]'
expect_py "crds.upgradeJob.tolerations and nodeSelector apply to the Job" '
spec = job["spec"]["template"]["spec"]
assert spec["tolerations"] == [{"key": "b", "operator": "Exists"}], spec.get("tolerations")
assert spec["nodeSelector"] == {"kubernetes.io/os": "linux", "pool": "system"}, spec["nodeSelector"]
print("ok")' --set-json 'tolerations=[{"key":"a","operator":"Exists"}]' --set-json 'crds.upgradeJob.tolerations=[{"key":"b","operator":"Exists"}]' --set crds.upgradeJob.nodeSelector.pool=system

printf "\n${Y}== off ==${N}\n"
expect_py "crds.upgradeJob.enabled=false => no hook objects" '
assert not hook, sorted(hook)
print("ok")' --set crds.upgradeJob.enabled=false
expect_py "rendered without hooks (as the EKS add-on does) => no hook objects" '
assert not hook, sorted(hook)
print("ok")' --no-hooks
on="$(render --skip-crds | python3 -c 'import sys,yaml; print(sorted("%s/%s" % (d["kind"], d["metadata"]["name"]) for d in yaml.safe_load_all(sys.stdin) if d and (d["metadata"].get("labels") or {}).get("app.kubernetes.io/component") != "crd-upgrade"))')"
off="$(render --skip-crds --set crds.upgradeJob.enabled=false | python3 -c 'import sys,yaml; print(sorted("%s/%s" % (d["kind"], d["metadata"]["name"]) for d in yaml.safe_load_all(sys.stdin) if d))')"
if [[ "$on" == "$off" ]]; then pass "same non-hook objects with the Job on and off"; else fail "non-hook objects differ with the Job on and off"; fi

printf "\n${Y}== Summary ==${N}\n"
printf "passed: ${G}%s${N}, failed: ${R}%s${N}\n" "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
