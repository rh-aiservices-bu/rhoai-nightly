# 3.6 upgrade: component Deployment selectors changed — Ray and TrustyAI operators never upgrade

**Jira: NOT FILED** — filing target: RHOAIENG (rhods-operator platform /
module deploy; affects the Ray and TrustyAI modules). This file is the
ready-to-file draft.

Found 2026-10-16 on cluster-n56g8, in-place OLM upgrade
`rhods-operator.3.6.0-ea.2` → `rhods-operator.3.6.0`. Reproduced on two
`rhoai-3.6-nightly` builds: operator `odh-rhel9-operator@sha256:e1a770e8…`
(catalog built 2026-10-15) and `@sha256:b14cd97f…` (built 2026-10-16 15:57Z).

## Symptom

DSC `RayReady=False` and `TrustyAIReady=False reason=DeployFailed`. The module
CRs report:

```
Ray/default-ray  ProvisioningSucceeded=False: ... Deployment.apps "kuberay-operator" is invalid:
  spec.selector: ... field is immutable
TrustyAI/default-trustyai  Ready=False DeployFailed: ... Deployment.apps
  "trustyai-service-operator-controller-manager" is invalid: spec.selector: ... field is immutable
```

Both Deployments keep running their **pre-upgrade** (3.6.0-ea.2) images —
they were created 2026-09-25 and never roll — while the cluster reports RHOAI
3.6.0. DSC stays `Ready=False`, which also blocks every settle-gate keyed on
DSC readiness (`make observability`, `make evalhub`).

## Root cause

The live Deployments (created by 3.6.0-ea.2) carry the platform-injected
component labels in `spec.selector.matchLabels`:

```
kuberay-operator:
  app.kubernetes.io/component: kuberay-operator
  app.kubernetes.io/name: kuberay
  app.kubernetes.io/part-of: ray            # injected
  app.opendatahub.io/ray: "true"            # injected
trustyai-service-operator-controller-manager:
  control-plane: trustyai-service-operator
  app.kubernetes.io/part-of: trustyai       # injected
  app.opendatahub.io/trustyai: "true"       # injected
```

The 3.6.0 module deploy no longer injects those two keys into the selector.
`spec.selector` is immutable, so every SSA patch is rejected. A sweep of all
`components.platform.opendatahub.io` / `modules.platform.opendatahub.io` CRs
on n56g8 found exactly these two Deployments failing this way (other modules
either kept the labels or recreated their Deployments).

Scope: proven for 3.6.0-ea.2 → 3.6.0. A 3.5.x → 3.6.0 upgrade is likely
affected the same way if 3.5 injected the same selector labels — **verify on a
3.5 cluster before filing**; that is the customer upgrade path.

## Detection

```bash
for d in kuberay-operator trustyai-service-operator-controller-manager; do
  echo "$d: $(oc get deploy $d -n redhat-ods-applications -o jsonpath='{.spec.selector.matchLabels}')"; done
for k in rays trustyais; do oc get $k.components.platform.opendatahub.io -o json | \
  jq -r '.items[].status.conditions[]? | select((.message//"")|test("field is immutable")) | .message' | head -1; done
# Bug live: either message contains "spec.selector ... field is immutable"
```

## Expected

The operator detects selector drift on Deployments it owns and recreates them
(delete + create, as kubectl/Helm-style upgrades do), or keeps selectors stable
across releases.

## Workaround

None carried. (Deleting the two Deployments would presumably let the operator
recreate them with the new selector — not applied, so the bug stays visible.)
