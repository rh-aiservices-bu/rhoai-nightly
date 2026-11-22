# RHCL `kuadrant-wasm-shim` fails to load in the OCP5 sail envoy — AuthPolicy enforcement is fail-closed, all `maas.apps` traffic 5xx

**Status:** NOT FILED (draft below) — target **CONNLINK** (RHCL /
Connectivity Link; MaaS-class issues flow to CONNLINK), with a mirror on
[Kuadrant/kuadrant-operator](https://github.com/Kuadrant/kuadrant-operator)
GitHub for fix velocity. **OCPBUGS only if the sail envoy build is proven at
fault** — the initial trigger is not isolated to a component build; the
persistence mechanism is localized to the sail control plane's cached
translation (Root cause, 2026-11-22 findings) and the 1.5.1 fix content is
confirmed locally (Churn-fix confirmation), pending RHCL 1.5.1 (2026-11-24).
**Found:** 2026-11-19, cluster `nightly.rhai-tmm.dev` (OpenShift 5.0.1, RHOAI
`rhods-operator.3.6.0` nightly, RHCL 1.5.0), immediately after the
workarounds.md §E1 pod-bounce remedy (RHOAIENG-67925) re-enabled AuthPolicy
enforcement on the MaaS gateway.
**Workaround in this repo:** none that restores traffic — enforcement
(fail-closed) is kept as the current honest state (workarounds.md **E1**);
the unenforced rollback is not cleanly reachable and is a security hole. A
recovery sequence for a wedged gateway exists (churn-trigger fix + istiod
bounce — see **Recovery** below); the expected full unblock is RHCL 1.5.1's
paired components on 2026-11-24.
Not a mitigation for this defect: Prevention for the bootstrap race that
triggered the §E1 remedy — `components/operators/connectivity-link/` wave-orders
the `openshift-default` GatewayClass (wave 0) ahead of the RHCL Subscription
(wave 1). The OOM-churn trigger is mitigated for the kuadrant-operator only:
an SSA resource patch in the connectivity-link component plus an imperative
CSV-template patch on the live cluster raise that Deployment's memory limit
(remove-when: RHCL 1.5.1 ships the churn
fix, [kuadrant/kuadrant-operator#2398](https://github.com/Kuadrant/kuadrant-operator/pull/2398),
per RHOAIENG-103592). The rhcl-operator-generated mcp-gateway-controller
carries no workaround: its 256Mi limit is hardcoded in the kuadrant-operator's
embedded chart with no knob, and the chart's ~20s re-render loop outpaces any
declarative re-assert — the occasional idle OOMKill is accepted, and
parameterizing the chart's controller resources is the upstream ask (see the
workarounds.md second-leg Prevention entry). The wasm wedge post-churn is NOT
mitigated by these measures — it is a separate upstream defect, still
fail-closed without a wasm fix.

## Symptom

After the §E1 remedy (deleting the Kuadrant operator pod) restores
`Accepted=True` on the gateway AuthPolicies, every request to the MaaS gateway
hostname returns **5xx** — both MaaS inference (`GET /maas-api/v1/models`,
chat completions) and the consumer-portal API
(`GET /maas-portal/maas/api/v1/whoami`); `GET /maas-api/health` stays 200
except in the 503 phase below. Status-code timeline (2026-11-19 UTC):
RCA window ~22:2x–22:5x — models **500**, health **200**; ~23:1x, after the
envoy pods restarted and the `maas-consumer-portal-extproc-bypass`
EnvoyFilter appeared — **503 on both**; re-probe 23:48 — models **500**,
health **200** again. The AuthPolicies report Accepted/Enforced throughout,
so the failure is invisible from the policy API.

Security exposure in the pre-remedy state: while the §E1 cached dependency
probe left every AuthPolicy unenforced on the gateway, anonymous
`GET /maas-api/v1/models` returned **200** — the MaaS API was fully exposed.
The remedy trades that exposure for the fail-closed 5xx above.

## Root cause

Envoy-internal remote wasm fetch failure. The Kuadrant-generated EnvoyFilter
on the gateway loads `kuadrant-wasm-shim` as a remote wasm plugin —
`vm_config.code.remote` →
`kuadrant-operator-wasm.openshift-operators.svc:8082/plugin.wasm` — with
`failure_policy: FAIL_RELOAD`. The sail envoy (run by the ingress operator;
Gateway API controller `openshift.io/gateway-controller/v1`, no
servicemeshoperator3 on OCP 4.20.32+/OCP5) fails the fetch **inside envoy**:

- the wasm server is verified serving the plugin (HTTP 200, 5.4MB);
- a curl pod carrying the envoy workload's identical labels fetches it fine;
- freshly started envoy pods fail the fetch instantly (~0.5s).

So the network path is good and the failure is envoy-internal — a signature
matching no known issue. `FAIL_RELOAD` makes the failed load fail-closed: the
filter chain rejects everything it governs, which is the 5xx above.

**Persistence mechanism (2026-11-22 testing):** the wedge outlives every
remedy aimed at the envoy side. After a churn episode the module fails to
load on EVERY envoy — fresh or old, any config, any operator version — while
the serving side verifies healthy end-to-end: the envoy wasm-fetch cluster
counters show `rq_success:2 rq_error:0`, an envoy-situ curl pod fetches
200/5.4–5.6MB, `config_dump` confirms the clusters are plaintext (mTLS ruled
out), the endpoints are correct, and the operator pod itself serves the shim
on :8082. A fresh envoy fails its first load in <50ms: `createWasm: failed
to load (in progress)` followed by `(cached)` — the module never
instantiates. An `istiod-openshift-gateway` pod bounce heals the load
immediately (the module's own logging appears); the per-envoy poison lives
in the sail control plane's cached translation, inherited by every fresh
envoy. Consequence: wedged-gateway recovery = fix the churn trigger + bounce
istiod; the §E1 operator pod-bounce alone was never sufficient (see
**Recovery**).

**Not the NetworkPolicy class of
[kuadrant-operator#2234](https://github.com/Kuadrant/kuadrant-operator/issues/2234)**
(deny-all NetworkPolicy in `kuadrant-system` blocking the wasm fetch, fixed by
[#2244](https://github.com/Kuadrant/kuadrant-operator/pull/2244), merged
2026-09-16 on main): that root cause is ruled out by the NetworkPolicy allow
proof in the evidence bundle below.

## Churn-fix confirmation (2026-11-22)

Upstream kuadrant-operator v1.6.0 plus PR
[#2398](https://github.com/Kuadrant/kuadrant-operator/pull/2398)'s four
determinism commits (built locally as
`quay.io/jharmison/kuadrant-operator:v1.6.0-2398`) rendered the gateway's
wasm EnvoyFilter deterministically — 0 rewrites over 90s. RHCL 1.5.1's
planned fix content works as claimed.

Test caveat: the run was an operator-only swap (upstream shim + RHCL
authorino). RHCL 1.5.1 ships wasm-shim 0.15.0 PAIRED with authorino 0.28.0,
and the pair matters: the swapped state showed per-request shim→authorino
gRPC failures (`gRPC status code is not OK`) that the matched pairing does
not show.

### Testing technique — a modified operator image under OLM

OLM continuously enforces the CSV bundle spec on operator Deployments: env,
resource, and image patches revert in seconds (generation churn ~1 per 2.5
minutes; OLM itself is CVO-managed and cannot be paused). The only stable way
to test a modified operator image is to patch the CSV's embedded deployment
template — OLM then enforces the patched spec; revert by patching the CSV
back:

```bash
oc patch csv <csv-name> -n <namespace> --type=json -p='[{"op":"replace",
  "path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/image",
  "value":"<image>"}]'
```

## Recovery

Wedged-gateway recovery sequence:

1. Remove or fix the churn trigger.
2. Bounce `istiod-openshift-gateway`.
3. Verify the wasm loads — envoy logs `wasm log kuadrant-wasm-shim …`.
4. Verify traffic.

RHCL 1.5.1 (paired wasm-shim 0.15.0 + authorino 0.28.0) + istiod bounce is
the expected full unblock on 2026-11-24; test tracker CONNLINK-2003 was
still New as of 2026-11-22, so the date is at risk.

## Detection

```bash
# Envoy logs: wasm fetch failure (wasm.cc:319) and load-task failure ("Task failed")
DEP=$(oc get deploy -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=maas-default-gateway \
  -o jsonpath='{.items[0].metadata.name}')
oc logs -n openshift-ingress deploy/$DEP -c istio-proxy | grep -iE "wasm|Task failed"

# The Kuadrant-generated EnvoyFilter: remote wasm code + fail-closed policy
oc get envoyfilter -n openshift-ingress -o yaml | grep -B2 -A8 "vm_config"

# Traffic: policy-governed paths 5xx, /health 200 (503 on both ~23:1x UTC
# 2026-11-19, after envoy pod restarts)
curl -sk https://maas.apps.<cluster-domain>/maas-api/v1/models \
  -o /dev/null -w "models: %{http_code}\n"    # 5xx (500 in the ~22:2x–22:5x RCA window)
curl -sk https://maas.apps.<cluster-domain>/maas-api/health \
  -o /dev/null -w "health: %{http_code}\n"    # 200

# Policies report Accepted despite the dead shim
oc get authpolicies.kuadrant.io -A
```

## Evidence bundle

- **Envoy logs:** two distinct strings, in different failure phases. During
  the 2026-11-19 22:5x window envoy logged BOTH — the fetch-failure warning
  `wasm.cc:319 Wasm remote code fetch is unstable and may cause a crash`
  (repeating on every fetch attempt) and the load-task error `wasm log
  kuadrant-wasm-shim … : Task failed: "0"` (context.cc:1160); a later tail
  (23:48Z) showed only the remote-fetch warning. Plus fail-closed 5xx;
  fresh envoy pods fail instantly (~0.5s), deterministically.
- **Wasm server verified:** `kuadrant-operator-wasm.openshift-operators.svc:8082/plugin.wasm`
  serves HTTP 200 with the 5.4MB plugin.
- **curl-vs-fresh-envoy side-by-side:** the same URL at the same moment —
  curl 200/5.4MB, fresh envoy fetch failure.
- **Generated EnvoyFilter YAML:** `vm_config.code.remote` pointing at the wasm
  URL with `failure_policy: FAIL_RELOAD` (fail-closed).
- **NetworkPolicy allow proof:** a curl pod with labels identical to the envoy
  workload reaches the wasm server — the network path is good, ruling out the
  #2234 class.
- **Gateway/provider details:** Gateway `maas-default-gateway` (ns
  `openshift-ingress`), Gateway API controller
  `openshift.io/gateway-controller/v1` (ingress-operator embedded sail library;
  no servicemeshoperator3), RHCL 1.5.0, OpenShift 5.0.1, RHOAI
  `rhods-operator.3.6.0` nightly.
- **Triage context — support caveat:** RHCL 1.4/1.5 release notes name OSSM
  3.4 as the only supported Gateway API provider; the ingress-operator sail
  combination is undocumented/unsupported territory, which explains the lack
  of test coverage. RHCL 1.4.0 was deprecated for the same class of
  integration incompatibility.
- **Consumer-side knobs are not a rescue:** `AUTH_SERVICE_FAILURE_MODE`
  (default deny — the fail-closed 5xx) and `AUTH_SERVICE_TIMEOUT` (+ the
  rate-limit twins) are env vars on the kuadrant-operator Deployment,
  operator-wide, and apply only post-load (CONNLINK-1956, support case
  07801313 — itself a RHOAI MaaS + RHCL case). No documented non-wasm
  enforcement path exists (no ambient/extproc alternative found).
- **Upstream fix status:** RHCL 1.5.1 is staged (CONNLINK-2004 + regression
  tickets, 2026-11-11); its fix content is confirmed locally (see Churn-fix
  confirmation, 2026-11-22), pending publication — test tracker
  CONNLINK-2003 was still New as of 2026-11-22.

## Related, unconfirmed — blocked behind this defect

Session-flow tokens carry `azp=maas-consumer-portal` while the gateway's
`maas-gateway-auth` policy demands `azp==maas-api` (the AITenant OIDC
clientId; single-client `azp` enforcement is RHOAIENG-103680), and the
rendered policy's own `TODO(MS-0007)` admits no ID-token pass-through. If
real, even a fixed wasm shim leaves the `maas.apps` portal session flow
rejected at maas-api. **Unverifiable until this defect resolves — treat as
unconfirmed, not a claim.**

## References

- [kuadrant-operator#2234](https://github.com/Kuadrant/kuadrant-operator/issues/2234)
  — same failure signature (wasm pull failure → FAIL_RELOAD → all traffic
  blocked), but NetworkPolicy-caused and fixed by
  [#2244](https://github.com/Kuadrant/kuadrant-operator/pull/2244); **not our
  root cause**
- CONNLINK-1595, CONNLINK-1878, CONNLINK-1956, CONNLINK-595
- CONNLINK-2003 (1.5.1 test tracker; New as of 2026-11-22), CONNLINK-2004
  (1.5.1 staging)
- CONNLINK-2030 (MaaS issues flow to CONNLINK)
- [RHOAIENG-67925](https://redhat.atlassian.net/browse/RHOAIENG-67925) (the §E1
  cached dependency probe) — its pod-bounce remedy is what surfaces this
  state; CONNLINK-595 is its precedent cousin on the RHCL side (same
  cached-probe pattern, fixed in RHCL 1.2)

## Filing draft (CONNLINK; mirror on Kuadrant/kuadrant-operator)

> **Title:** `kuadrant-wasm-shim` remote fetch fails envoy-internally on the
> OpenShift ingress-operator sail envoy — `FAIL_RELOAD` fail-closes all
> policy-governed gateway traffic (HTTP 5xx)
>
> **Component:** RHCL (Connectivity Link) / Kuadrant wasm shim; environment:
> RHCL 1.5.0 on OpenShift 5.0.1, Gateway API controller
> `openshift.io/gateway-controller/v1` (ingress-operator embedded sail, no
> servicemeshoperator3)
>
> On OpenShift 5.0.1, the Kuadrant-generated EnvoyFilter on our gateway loads
> `kuadrant-wasm-shim` as a remote wasm plugin (`vm_config.code.remote` →
> `kuadrant-operator-wasm.openshift-operators.svc:8082/plugin.wasm`) with
> `failure_policy: FAIL_RELOAD`. The envoy fetch of the plugin fails
> internally within ~0.5s on every envoy start, while the same URL returns
> HTTP 200 (5.4MB) to a curl pod carrying the envoy workload's labels — the
> network path and NetworkPolicy allow the traffic, so this is not the #2234
> deny-all NetworkPolicy class (fixed by #2244). With FAIL_RELOAD, the failed
> load fail-closes the filter chain: every request governed by a Kuadrant
> AuthPolicy on the gateway returns 5xx (on `maas-default-gateway`: all
> `maas.apps` traffic — MaaS inference and portal API — 5xx, while
> unauthenticated `/maas-api/health` stays 200; 2026-11-19 UTC: 500 in the
> ~22:2x–22:5x window, 503 on both paths ~23:1x after envoy pod restarts,
> 500/200 again at 23:48). The AuthPolicies report
> Accepted/Enforced throughout, so the outage is silent from the policy API.
> Envoy logs show the fetch failure (repeating `wasm.cc:319 Wasm remote code
> fetch is unstable and may cause a crash` warnings) and, on the failing
> loads, the task failure (`wasm log kuadrant-wasm-shim … : Task failed:
> "0"`, context.cc:1160).
> Expected: the envoy fetches the plugin from the in-cluster wasm server and
> the filter chain loads; or the failure surfaces in a policy-visible way
> instead of silently failing closed on all traffic.
