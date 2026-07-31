# MaaS catalog advertises the bare gateway base as the model URL (3.5.0)

**Jira: NOT FILED** for the current variant (lineage: [RHOAIENG-76220](https://redhat.atlassian.net/browse/RHOAIENG-76220) Resolved covered the empty-catalog discovery variant; indirectly captured in [RHOAIENG-79529](https://redhat.atlassian.net/browse/RHOAIENG-79529)'s asks). Filing draft below.


- **Symptom:** `make maas-verify` reports **11 passed / 3 failed** — inference
  404, unauthenticated 404 (expected 401/403), and "No 429 responses". All three
  are the *same* bug: the test URL is wrong, so every request 404s before auth or
  rate limiting is reached. Reproduces on repeated runs; not timing.
- **Detection:**
  ```bash
  oc get maasmodelref <model> -n llm -o jsonpath='{.status.endpoint}{"\n"}'
  # https://maas.apps.<domain>/           <- bare base, WRONG
  curl -sk "$MAAS/maas-api/v1/models" -H "Authorization: Bearer $KEY" | jq '.data[0]|{id,url}'
  # url is the same bare base; expected https://maas.apps.<domain>/llm/<model>
  ```
- **Re-verified 2026-07-30** on r8mf7 (`rhods-operator.3.5.0`, payload
  `84cee292`): catalog `url` is still the bare base, and the model `id` format
  changed to `publishers/<ns>/models/<name>`.
- **Root cause (3.5.0 nightly, 2026-07-29):** maas-controller sets
  `MaaSModelRef.status.endpoint` to the BBR base (`/`) instead of the path-based
  `/<ns>/<model>`; maas-api echoes it as the catalog `url`. This is the
  pre-#1142 BBR-endpoint bug resurfacing in a *new* variant — the catalog is
  **populated** here (discovery worked), only the `url` field is wrong, so the
  empty-catalog guard in `verify-maas.sh` does not trigger.
- **The data plane is NOT broken.** Verified against the correct path:
  inference 200, no-auth 401, invalid token 403, and 5 rapid free-tier requests
  gave `200 200 429 429 429`. Auth and rate limiting both work.
- **Blast radius:** anything that trusts the catalog `url` builds a 404 — which
  is how this reaches the Gen AI playground (see D2c; the LlamaStack provider
  `base_url` is derived from it via `ensureVLLMCompatibleURL`).
- **Fix:** none available — maas-controller/maas-api behavior. Optional
  hardening: make `verify-maas.sh` fall back to `${HOST}/${NS}/${MODEL}` when
  `.data[0].url` has an empty path, and WARN naming this bug, so a genuine
  data-plane regression isn't masked by a metadata bug.
- **Remove when:** `MaaSModelRef.status.endpoint` reports the path-based URL.

## Steps to reproduce

1. RHOAI 3.5.0 nightly with MaaS enabled (DSC `modelsAsService: Managed`),
   Gateway `maas-default-gateway` in `openshift-ingress`.
2. Deploy any `LLMInferenceService` + `MaaSModelRef` (e.g. the kserve
   simulator model); wait for `MaaSModelRef` Ready.
3. `oc get maasmodelref <model> -n <ns> -o jsonpath='{.status.endpoint}'` →
   bare `https://maas.<domain>/` with no path.
4. Create an API key, `GET /maas-api/v1/models` → the model's `url` is the
   same bare base.
5. POST a chat completion to `<url>/v1/chat/completions` (as any client
   trusting the catalog would) → **404**. The same request against
   `https://maas.<domain>/<ns>/<model>/v1/chat/completions` → **200**.

Reproduced on three clusters (2026-07-29 nightly, 2026-07-30 and 2026-07-31
GA-track builds).

---

## Filing draft (RHOAIENG)

## Summary

On `rhods-operator.3.5.0` (verified 2026-07-29 nightly and 2026-07-31 GA-track,
two clusters), `GET /maas-api/v1/models` returns each model with

```json
{"id": "publishers/<ns>/models/<name>", "url": "https://maas.<domain>/", "ready": true}
```

`url` is the **bare gateway base** — not the per-model path
`https://maas.<domain>/<ns>/<name>`. Source: maas-controller sets
`MaaSModelRef.status.endpoint` to the BBR base (`/`); maas-api echoes it.

## Why this matters (verified blast radius)

Anything that composes a request URL from the catalog 404s before auth is even
consulted:

1. **Gen AI playground** (RHOAIENG-79529's defect #2): the dashboard BFF passes
   `maasModel.URL` verbatim through `ensureVLLMCompatibleURL` → `base_url:
   https://maas.<domain>/v1` → provider 404 on every chat. Dashboard source
   (verified on upstream main 2026-07-31, `token_k8s_client.go`) performs **no
   path derivation** and its own test fixtures expect `.../llm/<model>/v1` —
   i.e. the dashboard assumes the catalog URL is already path-based. The fix
   belongs here, on the maas side.
2. Any external API consumer/script doing catalog-driven discovery.
3. Verification tooling: naive smoke tests report inference/auth/rate-limit
   failures on a perfectly working deployment (404 for everything).

The data plane itself is fine — requests against the correct path URL give
200/401/403/429 exactly as configured.

## Lineage

This is the *surviving* variant of the BBR-endpoint family: RHOAIENG-76220
(Resolved) fixed the **discovery** side (empty catalog from the self-probe
recursion), but the **advertised URL** still regresses to the bare base.
On ea.2 builds the endpoint was path-based; 3.5.0 regressed it while also
changing the id format to `publishers/<ns>/models/<name>`.

## Detection

```bash
oc get maasmodelref <model> -n <ns> -o jsonpath='{.status.endpoint}{"\n"}'
# bug: https://maas.<domain>/         fixed: https://maas.<domain>/<ns>/<model>
```

## Expected

`status.endpoint` (and the catalog `url`) = the path-based per-model URL, as
models-as-a-service #1142 originally established for discovery.
