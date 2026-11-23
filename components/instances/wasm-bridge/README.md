# wasm-bridge

Delivers the Kuadrant wasm shim to the `maas-default-gateway` envoy via the
**istio-agent** instead of envoy's remote fetch, which fails deterministically
on the OCP5 sail envoy (`FAIL_RELOAD` → fail-closed 5xx on all `maas.apps`
traffic). Root cause and evidence:
[docs/issues/rhcl-wasm-fail-closed.md](../../docs/issues/rhcl-wasm-fail-closed.md).

Three pieces:

- `wasm-shim-server.yaml` — Deployment + Service (`openshift-operators`) whose
  initContainer copies `/wasm/plugin.wasm` from the **RHCL-paired** operator
  image and serves it over nginx (sha256 `fd5039db…`; the paired binary
  matters — do not substitute the upstream build).
- `wasmplugin.yaml` — `WasmPlugin/kuadrant-shim-bridge` (`openshift-ingress`,
  selector → `maas-default-gateway` pods) whose `pluginConfig` is the **frozen
  post-surgery** EnvoyFilter render: ~940 CEL expressions transformed to
  null-safe `in`-operator forms, endpoints remapped to istio-registry cluster
  names, store actions for removed services dropped. **Frozen for THIS rig** —
  the tenant/gateway names and the tier UUIDs baked into the CEL predicates
  are cluster-specific; re-freeze via the plan doc's "WasmPlugin config
  transform runbook" if the tenancy changes.
- `destinationrule-authorino-tls` — TLS SIMPLE to authorino on :50051 only
  (istiod strips `tls_context` from EnvoyFilter cluster patches; Limitador on
  :8081 is plaintext and needs no rule).

**Remove when** RHCL 1.5.1 ships (paired shim/authorino + the upstream wasm
fix) and the wasm shim loads in the sail envoy again — see the §E3 entry in
[docs/workarounds.md](../../docs/workarounds.md); the operator's EnvoyFilter
and AuthConfig render rights must then be restored too.
