# 3.6: deprecated `kserve.modelsAsService: Managed` is silently ignored — MaaS never deploys

**Jira: NOT FILED** — filing target: RHOAIENG (opendatahub-operator /
AI Gateway module). This file is the ready-to-file draft.

Found 2026-09-25 on cluster-n56g8, fresh install of `rhoai-3.6-ea.2-nightly`
(operator `rhods-operator.3.6.0-ea.2`, image
`odh-rhel9-operator@sha256:38fd3af0…`). Code references are
opendatahub-operator `main` @ `2d8eadbd` (2026-09-25).

## Symptom

A DataScienceCluster that enables MaaS the 3.5 way
(`spec.components.kserve.modelsAsService.managementState: Managed`) gets **no
MaaS** on 3.6: `ModelsAsAServiceReady=False reason=Removed`, no `maas.*` CRDs,
no maas-controller. DSC is otherwise `Ready=True`, so nothing looks broken.

Every write is answered with this webhook warning, which is false:

```
spec.components.kserve.modelsAsService is deprecated; use
spec.components.aigateway.modelsAsAService instead. Clear to Removed after
migration (re-enabling is blocked). The field remains respected at least through 3.6.
```

The CRD field description says the same ("Existing Managed values are still
respected by the operator").

## Root cause

The fallback exists but can never fire:

1. `api/components/v1alpha1/modelsasservice_types.go` — the shared
   `DSCModelsAsServiceSpec.ManagementState` carries
   `+kubebuilder:default=Removed`.
2. `DSCAIGateway` is a non-pointer struct (`json:"aigateway,omitempty"`;
   omitempty does not omit structs), so the operator's first write of the DSC
   materializes `aigateway.modelsAsAService: {}`, and API-server defaulting
   turns that into `managementState: Removed`. Observed via managedFields: ArgoCD
   created the DSC at 15:03:02 with only the kserve field; manager `manager`
   (the operator) owned `f:aigateway.f:modelsAsAService.f:managementState` from
   an Update at 15:03:03.
3. `internal/controller/modules/aigateway/handler.go` only consults the
   deprecated field when the new one is empty (`IsEnabled`:
   `if dsc.AIGateway.ModelsAsAService.ManagementState != ""`; `BuildModuleCR`:
   `if commonSpec.ModelsAsAService.ManagementState == ""`). After step 2 it is
   never empty → the explicit `Removed` wins → MaaS off.

## Scope

- **Fresh installs** that use the documented-as-supported deprecated field:
  proven here.
- **3.5 → 3.6 upgrades — likely, not yet verified.** A 3.5 DSC has only
  `kserve.modelsAsService: Managed`; the first operator write after the CRD
  upgrade should default `aigateway.modelsAsAService` to `Removed` the same way,
  which would **tear down a running MaaS** on upgrade. This is the higher-impact
  case and should be confirmed on an upgrade before filing.

## Detection

```bash
oc get dsc default-dsc -o jsonpath='{.spec.components.kserve.modelsAsService.managementState} {.spec.components.aigateway.modelsAsAService.managementState} {.status.conditions[?(@.type=="ModelsAsAServiceReady")].reason}{"\n"}'
# Bug live:  "Managed Removed Removed"
# Fixed:     "Managed <Managed or empty> <not Removed>"
```

## What this repo does

Not a workaround — we migrated to the current API:
`components/instances/rhoai-instance/base/datasciencecluster.yaml` sets
`aigateway.{managementState,modelsAsAService.managementState}: Removed` and
`kserve.modelsAsService: Removed`; `overlays/maas` flips the two `aigateway`
states to `Managed`. Verified on n56g8: MaaS CRDs + maas-controller +
ai-gateway-controller came up within ~1 min. Nothing to remove when the
upstream fix lands.

## Expected

Either honour the deprecated field as promised (e.g. make
`AIGateway`/`ModelsAsAService` pointers or drop the `Removed` default so
"unset" stays distinguishable, or migrate `kserve.modelsAsService` into
`aigateway.modelsAsAService` in the defaulting webhook before the default
applies), or stop claiming it is respected and fail loudly (webhook
rejection / DSC condition) when only the deprecated field is `Managed`.

## Filing draft (RHOAIENG)

**Title:** DSC `kserve.modelsAsService: Managed` ignored on 3.6 — CRD default
`aigateway.modelsAsAService=Removed` defeats the deprecation fallback

**Body:** Symptom, root cause (3 steps), detection, and the upgrade concern
from this file. Component: opendatahub-operator, AI Gateway module. Affects
3.6.0-ea.2.
