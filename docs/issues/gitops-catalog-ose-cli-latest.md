# gitops-catalog Jobs pull `openshift4/ose-cli` untagged — registry.redhat.io now refuses `:latest`

**Upstream: NOT FILED** — filing target: GitHub issue (or PR) on
[redhat-cop/gitops-catalog](https://github.com/redhat-cop/gitops-catalog).
Not an RHOAI product bug; it is in the upstream catalog this repo consumes
for the NVIDIA GPU operator. This file is the ready-to-file draft.
Searched 2026-09-25: no issue or PR in redhat-cop/gitops-catalog mentions
`ose-cli`.

Found 2026-09-25 on cluster-n56g8 (OCP 4.20.36) during `make sync` of a
fresh install. Not seen on the 2026-08-14 bq4x2 install, so the registry-side
change landed between those dates.

## Symptom

`nvidia-operator` ArgoCD Application stays `Synced / Progressing` forever;
`make sync` times out on it (300s) and moves on. The only non-healthy
resource is `Job/job-gpu-console-plugin`, whose pod is `ImagePullBackOff`:

```
Failed to pull image "registry.redhat.io/openshift4/ose-cli": ...
reading manifest latest in registry.redhat.io/openshift4/ose-cli: unsupported:
This repository does not use the "latest" tag to track the most recent image
and must be pulled with an explicit version or image reference.
```

Impact: cosmetic only. The GPU operator CSV installs (`Succeeded`),
`instance-nvidia` (ClusterPolicy) goes Healthy, GPUs work. What is lost is
the Job's one task — adding `console-plugin-nvidia-gpu` to
`console.operator/cluster .spec.plugins` — so the NVIDIA GPU dashboard
plugin is never enabled in the console. The app's permanent `Progressing`
also shows up as noise in `make status` / `make diagnose`.

**No workaround carried** (repo mission: UX-only degradation → document and
file, don't paper over).

## Root cause

`registry.redhat.io/openshift4/ose-cli` is the RHEL8-era CLI image; its last
minor tag is `v4.15` (still rebuilt — `v4.15` created 2026-09-11). Its
`latest` tag is listed but the registry now refuses to serve it (see Red Hat
article 4301321). The current image is `openshift4/ose-cli-rhel9`
(`v4.16`…`v4.22`), which **does** still serve `:latest`
(`sha256:679f03aa…` on 2026-09-25).

gitops-catalog references the old image with no tag in ~10 places, unchanged
since the 2024-05-02 "Gpu Refactor (#298)":

```
gpu-operator-certified/operator/components/console-plugin/console-plugin-job.yaml       <- used by overlays/stable (this repo)
gpu-operator-certified/operator/components/console-plugin-helm/console-plugin-job.yaml
gpu-operator-certified/instance/components/aws-gpu-machineset/job.yaml
installplan-approver/base/installplan-approver-job.yaml
openshift-ai/instance/components/wait-for-servicemesh/wait-for-servicemesh-job.yaml
openshift-data-foundation-operator/config-helpers/node-labeler/base/node-label-job.yaml
openshift-data-foundation-operator/operator/base/enable-console-plugin-job.yaml
openshift-gitops-operator/operator/components/enable-console-plugin/console-plugin-job.yaml
openshift-pipelines-operator/components/enable-console-plugin/console-plugin-job.yaml
advanced-cluster-management/instance/observability/02-install-observability.yaml
```

Within this repo only `components/operators/nvidia-operator` renders it
(checked by `oc kustomize` over every operator/instance path).

## Detection

```bash
# Still broken if this prints the untagged old image:
oc kustomize components/operators/nvidia-operator | grep 'openshift4/ose-cli'
# On a cluster:
oc get pods -n nvidia-gpu-operator -l job-name=job-gpu-console-plugin
oc get console.operator cluster -o jsonpath='{.spec.plugins}'   # lacks console-plugin-nvidia-gpu
```

Fixed when the first command shows `ose-cli-rhel9` (or a pinned tag) and the
Job completes.

## Filing draft (GitHub issue, redhat-cop/gitops-catalog)

**Title:** Jobs using `registry.redhat.io/openshift4/ose-cli` (untagged) fail
with ImagePullBackOff — registry no longer serves `:latest`

**Body:**

> Several components reference `registry.redhat.io/openshift4/ose-cli` with no
> tag. registry.redhat.io now refuses to serve `latest` for that repository:
>
> ```
> reading manifest latest in registry.redhat.io/openshift4/ose-cli: unsupported:
> This repository does not use the "latest" tag to track the most recent image
> and must be pulled with an explicit version or image reference.
> ```
>
> Seen on OCP 4.20.36 with `gpu-operator-certified/operator/overlays/stable`:
> `job-gpu-console-plugin` sits in ImagePullBackOff, the console plugin is
> never enabled, and the ArgoCD app stays Progressing.
>
> `openshift4/ose-cli` stops at v4.15; the current image is
> `registry.redhat.io/openshift4/ose-cli-rhel9` (v4.16+), which still serves
> `:latest`. Suggested fix: replace `openshift4/ose-cli` with
> `openshift4/ose-cli-rhel9` in all Job manifests (list: `grep -rn
> 'openshift4/ose-cli' .`), optionally pinning a minor tag.
