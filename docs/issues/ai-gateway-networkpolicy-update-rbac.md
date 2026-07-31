# ai-gateway-manager-role lacks `update` on networkpolicies — DSC stuck AIGatewayReady=False while MaaS works

**Jira: NOT FILED** — filing target: RHOAIENG, component MaaS/ai-gateway-operator. This file is the ready-to-file draft.

## Summary

On rhoai-3.5 nightlies (first seen 2026-07-22, models-as-a-service commit
`fba7cbf4`), `DataScienceCluster` sticks at `AIGatewayReady=False` (→
`Ready=False`) even though the entire MaaS data plane (gateway, catalog,
inference, auth) works. Operator log:

```
failed to remove owner references from object ...maas-controller-allow-monitoring...
networkpolicies ... is forbidden: User "system:serviceaccount:...:ai-gateway-operator"
cannot update resource "networkpolicies" ...
```

## Root cause

The operator-shipped `ai-gateway-manager-role` ClusterRole grants
`create/delete/get/list/patch/watch` on `networkpolicies` but **not `update`**.
The ModelsAsService controller calls `Update()` to strip owner references from
pre-existing NetworkPolicies and is denied — reconcile fails permanently,
condition never goes True.

## Detection

```bash
oc auth can-i update networkpolicies -n redhat-ods-applications \
  --as=system:serviceaccount:redhat-ods-applications:ai-gateway-operator
# no
```

## Fix

Add `update` to the networkpolicies rule in the CSV's ai-gateway-manager-role.

## Workaround (ours, verified)

Supplementary ClusterRole/Binding adding only the `update` verb, bound to the
`ai-gateway-operator` SA (additive; does not fight the operator).
