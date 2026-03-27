# OCM Gateway NetworkPolicy Issue

## Problem

On OCM-managed OpenShift clusters (ROSA, OSD), RHOAI 3.x cannot fully deploy because the RHOAI operator's `GatewayConfig` tries to create a `kube-auth-proxy` NetworkPolicy in the `openshift-ingress` namespace. The OCM admission webhook `networkpolicies-validation.managed.openshift.io` blocks this, producing the error:

```
admission webhook "networkpolicies-validation.managed.openshift.io" denied the request:
User 'system:serviceaccount:redhat-ods-operator:redhat-ods-operator-controller-manager'
prevented from creating network policy that may impact default ingress, which is managed
by Red Hat.
```

This causes `GatewayConfig/default-gateway` to remain in `status.phase: Not Ready` with an empty `status.domain`. The DSC then fails to reconcile **Dashboard** and **ModelRegistry** because both require the gateway domain.

## Impact

- `DataScienceCluster` stays in `Not Ready` phase
- **All** RHOAI component pods are blocked from deploying (not just Dashboard/ModelRegistry)
- The gateway domain is a hard prerequisite for the DSC reconciliation loop

## Fix (Verified)

Disable NetworkPolicy creation on the GatewayConfig. The `GatewayConfig` CRD has a `spec.networkPolicy.ingress.enabled` field that controls whether the kube-auth-proxy NetworkPolicy is created in `openshift-ingress`. Setting it to `false` skips the NetworkPolicy entirely.

```bash
oc patch gatewayconfig default-gateway --type=merge \
  -p '{"spec":{"networkPolicy":{"ingress":{"enabled":false}}}}'
```

**Why this is safe on OCM-managed clusters**: The OCM admission webhook already protects the `openshift-ingress` namespace more strictly than a NetworkPolicy would. The CRD documentation says to set `Enabled=false` "when using alternative network security controls" — the OCM webhook *is* that alternative control.

**Why the patch persists**: The DSCI controller only creates the GatewayConfig if it doesn't already exist (`CreateGatewayConfig` in `dscinitialization_controller.go` returns immediately if the CR is found). It never reconciles the spec back to defaults. Source: [opendatahub-operator](https://github.com/opendatahub-io/opendatahub-operator/blob/main/internal/controller/dscinitialization/dscinitialization_controller.go).

**Result**: GatewayConfig transitions to `Ready` with `status.domain` populated. DSC reconciles successfully — Dashboard, ModelRegistry, and all other components deploy.

**Tested**: 2026-03-27 on bu-nightly-2 (ROSA, OCP 4.20.16, RHOAI 3.4.0-ea.2). Patch applied, GatewayConfig went Ready within seconds, DSC Ready within ~90 seconds.

### Post-install note

This patch must be applied **after** `rhoai-operator` installs and the GatewayConfig is created by DSCI, but it only needs to be done once per cluster. If RHOAI is fully uninstalled and reinstalled, the patch will need to be reapplied after the new GatewayConfig is created.

## Previous Workaround (No Longer Needed)

Previously, we disabled Dashboard and ModelRegistry to unblock the rest of RHOAI:

```bash
# 1. Disable auto-sync on instance-rhoai so ArgoCD doesn't revert the patch
oc patch application.argoproj.io/instance-rhoai -n openshift-gitops \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 2. Patch DSC to remove gateway-dependent components
oc patch datasciencecluster default-dsc --type=merge \
  -p '{"spec":{"components":{"dashboard":{"managementState":"Removed"},"modelregistry":{"managementState":"Removed"}}}}'
```

This is no longer necessary — the NetworkPolicy fix resolves the root cause.

## Environment Details

- **Cluster**: `bu-nightly-2.pmew.p1.openshiftapps.com` (ROSA/OCM-managed)
- **OCP**: 4.20.16
- **RHOAI**: 3.4.0-ea.2 nightly
- **Service Mesh**: 3.3.1
- **Blocking webhook**: `networkpolicies-validation.managed.openshift.io`
- **Blocking resource**: `NetworkPolicy/kube-auth-proxy` in `openshift-ingress`
- **Date discovered**: 2026-03-26

## Related Resources

- `GatewayConfig/default-gateway` — the CR that fails to reconcile
- `Gateway/data-science-gateway` in `openshift-ingress` — the Istio gateway (this part works)
- `Istio/openshift-gateway` in `openshift-ingress` — healthy, v1.26.2
- `DSCInitialization/default-dsci` — Ready (not affected)
- `DataScienceCluster/default-dsc` — Ready (after fix applied)
- **Date resolved**: 2026-03-27
