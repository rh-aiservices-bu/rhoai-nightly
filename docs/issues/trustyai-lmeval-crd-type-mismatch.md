# 3.6.0 nightly: TrustyAI module CRD types `lmeval.permit*` as boolean — DSC provisioning fails

**Upstream: FIXED, not filed** — fixed on red-hat-data-services/rhods-operator
`rhoai-3.6` by `4f8c88949` (2026-10-15 20:53Z, "Updating the operator repo with
latest images and manifests"), which put the string/`deny` CRD back. Delete
this file once a `rhoai-3.6-nightly` built after that commit is verified.

Found 2026-10-16 on cluster-n56g8 during the in-place upgrade
`rhods-operator.3.6.0-ea.2` → `rhods-operator.3.6.0` (catalog
`rhoai-3.6-nightly` built 2026-10-15 15:34Z, digest `d385d052`; operator
`odh-rhel9-operator@sha256:e1a770e8…`).

## Symptom

`DataScienceCluster/default-dsc` → `Ready=False`, `ProvisioningSucceeded=Error`:

```
failure deploying resource /default-trustyai: apply failed ... Kind=TrustyAI:
  .spec.eval.lmeval.permitCodeExecution: expected boolean, got &{deny}
  .spec.eval.lmeval.permitOnline: expected boolean, got &{deny}
```

The existing `TrustyAI/default-trustyai` (gen 1) keeps running, so TrustyAI
itself still works; what breaks is DSC readiness — and with it every
settle-gate that checks `DSC Ready=True` (`make observability`,
`make evalhub`) and `make diagnose`.

## Root cause

Two copies of one API disagree inside the same operator image:

- DSC v2 and v3 schemas (and the Go type `PermitCodeExecution string` in
  `api/components/v1alpha1/trustyai_types.go`): `type: string`,
  `enum: [allow, deny]`, `default: deny`.
- The TrustyAI module CRD the operator SSA-applies from
  `/opt/manifests/trustyai/crd/bases/components.platform.opendatahub.io_trustyais.yaml`:
  `type: boolean`, `default: false`.

The operator copies the DSC string verbatim into the TrustyAI CR, so the apply
fails. Because the DSC **default** is `deny`, any DSC with TrustyAI `Managed`
hits it — not just ones that set the fields explicitly.

History of that prefetched CRD on `rhoai-3.6`: boolean at `278e661db`
(09-23) and `e33638eac` (10-06); string again at `4f8c88949` (10-15 20:53Z).
The 3.6.0-ea.2 nightly (built 09-18) predates the regression.

## Detection

```bash
oc get crd trustyais.components.platform.opendatahub.io -o json | jq -c \
  '.spec.versions[]|select(.storage)|.schema.openAPIV3Schema.properties.spec.properties.eval.properties.lmeval.properties.permitCodeExecution|{type,default}'
# Broken: {"type":"boolean","default":false}   Fixed: {"type":"string","default":"deny"}
oc get dsc default-dsc -o jsonpath='{.status.conditions[?(@.type=="ProvisioningSucceeded")].message}'
```

## Workaround

None carried (UX/readiness only; `deny` is the correct API value and the
default, so there is nothing valid to change in the DSC). Wait for the next
nightly.
