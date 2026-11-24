# maas-api `/v1/logs` read-proxy path can never authenticate — the datasource repoint bypasses the gateway trust boundary the route's identity model requires

**Status:** NOT FILED (draft below) — target **RHOAIENG**, with a mirror on
[github.com/opendatahub-io/models-as-a-service](https://github.com/opendatahub-io/models-as-a-service)
(the repoint ships in maas-controller / maas-api, so GitHub fix velocity
matters). No workaround for the bug itself is carried — none is viable within
the shipped design; the designed `usage-logs-loki` switch artifacts ARE carried
(imperative, documented — see **Workaround**). **Found:** 2026-11-23, OpenShift 5.0.1 + RHOAI
`rhods-operator.3.6.0` nightly (`rhoai-3.6-nightly`, catalog digest
`sha256:864736d5…`). All upstream citations from models-as-a-service @
`0697c1d`. This is the second-stage failure of the usage-logs path: the first
stage (orphaned SA-token Secret refs,
[maas-usage-logs-orphaned-satoken-secret.md](maas-usage-logs-orphaned-satoken-secret.md))
led us to activate the designed `usage-logs-loki` switch; the switched path
fails identically, for this reason.

## Symptom

After maas-controller repoints the usage-logs PersesDatasources at maas-api (see
Root cause), every panel of the MaaS **Usage** view of the Observability
dashboard errors:

```
{"error":"unauthorized","error_description":"trusted identity is invalid","exceptionCode":"AUTH_FAILURE"}
```

maas-api's access log carries the rejection on every datasource request:

```
level=WARN ... msg="identity extraction failed" error="invalid subject claim"
  identity_header_bytes=278
```

The maas-api Loki leg itself is correctly wired — startup logs
`maas-api Loki read proxy enabled` with `tokenInjected=true`, `caInjected=true`,
and the LokiStack `data-science-usage-logs-lokistack` is Ready. The failure is
purely on the /v1/logs auth path.

## Root cause

The a6adc1a usage-logs switch routes the perses server to an in-cluster URL that
the /v1/logs identity contract cannot service. The two halves are mutually
incompatible by design:

- **The repoint** (`self_deployment_controller.go`
  `patchPersesDatasourceMaaSAPILoki`, :877-911): when Secret `usage-logs-loki`
  exists in the infra ns, maas-controller patches both PersesDatasources' URL to
  `https://maas-api.redhat-ai-gateway-infra.svc.cluster.local:8443/v1/logs`
  (`?only_user=true` for the multi-tenancy datasource) plus the TLS CA. The
  datasources' `client.kubernetesAuth.enable: true` and `secret:` refs are
  untouched — and irrelevant, because the route never reads them.
- **The route's identity model** (cmd/main.go :360-364, :400-413): /v1/logs is
  guarded ONLY by `strictAuthMiddleware` (`ExtractVerifiedIdentityOptional`
  - `ExtractUserInfo`), which reads exclusively the `X-MaaS-Identity` envelope
    header (token/identity.go `ParseIdentityEnvelope`) or legacy
    X-MaaS-Username/Group. **The `Authorization` header is never examined** —
    TokenReview guards only /v1/tenants (main.go :384-387). The perses server's
    kubernetesAuth SA token therefore cannot authenticate this route at all.

The trust design intends `X-MaaS-Identity` to be minted by the maas Gateway's
Authorino (MaaSAuthPolicy `verifiedIdentityHeader` +
`managementIdentityRoutePredicate` for /v1/logs, maasauthpolicy_identity.go;
client-supplied copies are stripped). The in-cluster service URL bypasses the
gateway entirely — no gateway-minted envelope can ever appear on this path. What
actually arrives is whatever the perses HTTPProxy forwards: perses forwards
caller headers by default (perses internal/api/impl/proxy/http/http.go — no drop
list on these datasources), so the portal-bff's forwarded `x-maas-identity`
reaches maas-api. That envelope is minted by the portal-session AuthPolicy Rego
from a kube-auth-proxy token lacking a subject claim (the `TODO(MS-0007)` gap),
so it carries `sub: ""` — rejected with `invalid subject claim`. Byte-for-byte
reproduced: a hand-built envelope
`{"source":"oidc","claims":{iss,<real realm>,"sub":"", "aud":"maas-api","azp":"maas-consumer-portal",…empty optionals}}`
is exactly 278 bytes — matching every production rejection — and yields the
identical 401 + `error="invalid subject claim", identity_header_bytes=278`.

Even a well-formed envelope would not constitute a working design:

- the route accepts any syntactically-valid envelope WITHOUT cryptographic
  verification — the gateway is the assumed trust boundary, and the path
  bypasses it; forwarded or spoofed envelopes are the only possible inputs,
  which is itself evidence the path was never designed reachable;
- `authorize()` additionally requires `OrganizationID` (valid-UUID org_id),
  absent from session tokens — so no envelope a client could legitimately carry
  would pass either.

Aggravator: `rejectIdentity` hardcodes the 401 body ("trusted identity is
invalid", exceptionCode AUTH_FAILURE) regardless of cause, masking every failure
mode (missing header, malformed envelope, empty subject, failed org check) from
the dashboard user; only the WARN log carries the real reason. Secondary
aggravator: the MS-0007 empty-sub envelope (see
[maas-usage-logs-orphaned-satoken-secret.md](maas-usage-logs-orphaned-satoken-secret.md)
and the workarounds ledger) is what actually arrives today — but fixing it would
only change the rejection reason, not the outcome.

## Detection

```bash
# The datasource is repointed at the in-cluster maas-api URL (the switch is active)
oc get persesdatasource usage-logs-multi-tenancy -n redhat-ods-monitoring \
  -o jsonpath='{.spec.proxy.client.url}{"\n"}'
# https://maas-api.redhat-ai-gateway-infra.svc.cluster.local:8443/v1/logs?only_user=true

# The route that URL hits trusts only the X-MaaS-Identity envelope:
# strictAuthMiddleware at cmd/main.go:360-364; Authorization is never read.

# maas-api rejects every datasource request (note the byte length —
# every production rejection is the same 278-byte empty-sub envelope)
oc logs -n redhat-ai-gateway-infra deploy/maas-api \
  | grep "identity extraction failed"
# level=WARN ... error="invalid subject claim" identity_header_bytes=278

# Reproduce byte-for-byte: build an envelope with sub:"" and POST it; the
# response matches the dashboard error exactly
# {"error":"unauthorized","error_description":"trusted identity is invalid",
#  "exceptionCode":"AUTH_FAILURE"}  (401, 278 bytes)
```

## Workaround

NONE carried — none is viable within the shipped design. Routing the datasource
through the gateway requires a per-user Keycloak JWT that the perses server
cannot hold (it has no user session); fabricating envelopes would forge identity
attribution. REMOVE-WHEN: upstream routes the datasource through the
gateway-minted identity path or adds a service-to-service authn (TokenReview) to
/v1/logs.

Carried artifacts (imperative, documented): Secret `usage-logs-loki` (ns
`redhat-ai-gateway-infra`;
`LOKI_READ_ENDPOINT=https://data-science-usage-logs-lokistack-gateway-http.redhat-ods-monitoring.svc:8080/api/logs/v1/application`,
`LOKI_READ_TOKEN` = 1y token of SA
`redhat-ai-gateway-infra/usage-logs-loki-reader`, ClusterRoleBinding
`usage-logs-loki-reader` → ClusterRole `usage-tenancy-proxy`, `LOKI_READ_CA` =
the gateway CA bundle). These activate the designed switch; the maas-api Loki
leg is wired. They are kept because they are the designed mechanism and will be
correct once either upstream fix lands. REMOVE-WHEN: the MaaS Usage dashboard
renders data without the maas-api-Loki switch — i.e. when either upstream issue
is fixed (the orphaned secret references are dropped/minted, or the /v1/logs
identity contract is made serviceable).

## References

- [models-as-a-service commit a6adc1a](https://github.com/opendatahub-io/models-as-a-service/commit/a6adc1a)
  (2026-11-10) — the datasource repoint (`patchPersesDatasourceMaaSAPILoki`,
  self_deployment_controller.go :877-911)
- [RHAI-22640](https://issues.redhat.com/browse/RHAI-22640) — the maas-api Loki
  read proxy the repoint targets
- `cmd/main.go` :360-364, :384-387, :400-413 — `strictAuthMiddleware` on
  /v1/logs; TokenReview only on /v1/tenants
- `token/identity.go` — `ParseIdentityEnvelope` (the only identity input the
  route reads)
- `maasauthpolicy_identity.go` — gateway-minted `verifiedIdentityHeader` +
  `managementIdentityRoutePredicate` (the trust boundary the in-cluster URL
  bypasses)
- perses `internal/api/impl/proxy/http/http.go` — default header forwarding (no
  drop list on these datasources)
- [maas-usage-logs-orphaned-satoken-secret.md](maas-usage-logs-orphaned-satoken-secret.md)
  — the first-stage orphaned-secret failure that led to activating the switch;
  also documents the MS-0007 empty-sub envelope gap
- [maas-usage-dashboard-total-suffix.md](maas-usage-dashboard-total-suffix.md)
  — the PromQL→Loki architecture move that makes these Usage panels
  Loki-dependent at all
- The MS-0007 `TODO` in the rendered portal-session AuthPolicy Rego — the
  empty-sub envelope source

## Filing draft (RHOAIENG; mirror on models-as-a-service GitHub)

> **Title:** maas-api /v1/logs read-proxy cannot authenticate the repointed
> usage-logs PersesDatasources — the in-cluster URL bypasses the gateway trust
> boundary the route's identity contract requires
>
> **Component:** maas-controller usage-logs switch / maas-api /v1/logs route;
> environment: RHOAI `rhods-operator.3.6.0` nightly (`rhoai-3.6-nightly`,
> catalog digest `sha256:864736d5…`), OpenShift 5.0.1, models-as-a-service @
> `0697c1d`, DSCI `monitoring.usageLogs` on, LokiStack
> `data-science-usage-logs-lokistack` Ready
>
> Commit a6adc1a's `patchPersesDatasourceMaaSAPILoki`
> (self_deployment_controller.go:877-911) repoints the usage-logs
> PersesDatasources at
> `https://maas-api.redhat-ai-gateway-infra.svc.cluster.local:8443/v1/logs` when
> Secret `usage-logs-loki` exists. But the /v1/logs route is guarded only by
> `strictAuthMiddleware` (cmd/main.go:360-364), which reads exclusively the
> `X-MaaS-Identity` envelope header (token/identity.go) — the `Authorization`
> header is never examined (TokenReview guards only /v1/tenants,
> main.go:384-387). The envelope is meant to be minted by the maas Gateway's
> Authorino (maasauthpolicy_identity.go); the in-cluster service URL bypasses
> the gateway entirely, so no gateway-minted envelope can ever appear on this
> path — the only possible inputs are forwarded/spoofed envelopes, which is
> itself evidence the path was never designed reachable. In practice the perses
> HTTPProxy forwards the caller's headers, so maas-api receives the portal-bff's
> forwarded envelope (minted from a kube-auth-proxy token lacking a subject
> claim — the MS-0007 gap) with `sub: ""` and rejects it:
> `error="invalid subject claim", identity_header_bytes=278` on every request;
> every Usage dashboard panel 401s with the hardcoded body
> `{"error":"unauthorized", "error_description":"trusted identity is invalid", "exceptionCode":"AUTH_FAILURE"}`
> (rejectIdentity masks all failure causes; the real reason is only in the WARN
> log). Even a well-formed envelope would not fix the design: the route accepts
> any syntactically-valid envelope without cryptographic verification, and
> `authorize()` also requires an `OrganizationID` (valid-UUID org_id) that
> session tokens do not carry. The perses server has no legitimate way to obtain
> either a gateway-minted envelope or a user identity (its kubernetesAuth SA
> token is ignored by the route). The maas-api Loki leg itself is correctly
> wired (`maas-api Loki read proxy enabled`, tokenInjected=true,
> caInjected=true). Expected: route the datasource through the gateway-minted
> identity path, or add a service-to-service authn (TokenReview) to /v1/logs;
> also make rejectIdentity surface the actual rejection cause.
