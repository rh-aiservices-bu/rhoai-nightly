# Gen AI playground auto-wiring of MaaS models is broken in three places

**Jira: [RHOAIENG-79529](https://redhat.atlassian.net/browse/RHOAIENG-79529)** (New, unassigned, customer-facing) — matches all three defects and documents our workaround B as its workaround. Defect 1 fixed on odh-dashboard main by [RHOAIENG-38993](https://redhat.atlassian.net/browse/RHOAIENG-38993) (`280db9dc5`), NOT cherry-picked to rhoai-3.5. Related: RHOAIENG-69083, RHOAIENG-38779. Prepared Jira comment at the end of this file.


**There is a supported workaround — see "Workaround A" below.** What has no
declarative fix is the *auto-wired* MaaS path; you can sidestep it entirely.

> **Re-verified 2026-07-31 on `rhods-operator.3.5.0` GA (clean install,
> cluster-fzgjg): all three defects still present** — generated config had
> `api_token: fake`, `base_url: https://maas.<domain>/v1` (bare base + `/v1`,
> derived from D2a's catalog URL), and the LLM model entry lacked
> `provider_model_id` while the embedding entry had one. First playground
> message → "Server error" / `[server_error] Error code: 404`. Two build-level
> deltas: the model picker DOES list the MaaS model (gate satisfied by
> `AIGatewayReady` — no `ModelsAsServiceReady` condition exists on this DSC),
> and the Subscription tier dropdown is populated. Workaround B (patch
> `llama-stack-config` base_url + `provider_model_id`, set a real key in the
> OGXServer `VLLM_API_TOKEN_1`, restart the pod) verified working: 951ms
> round-trip through the playground.

The playground registers a MaaS model as a LlamaStack provider by generating a
`run.yaml` into ConfigMap `llama-stack-config` (owned by
`OGXServer/lsd-genai-playground`) plus env vars on the OGXServer CR. **Three
separate fields are wrong**, and each one masks the next — expect to "fix it" and
find it still broken twice more:

| # | Field | Generated value | Result |
|---|---|---|---|
| 1 | `api_token` (via `VLLM_API_TOKEN_<N>`) | `fake` | 401 listing models → **0 models registered** |
| 2 | `base_url` | `https://maas.apps.<domain>/v1` | `/v1/models` 200 (!) but `/v1/chat/completions` **404** |
| 3 | `provider_model_id` | *absent* | LlamaStack sends the catalog path; vLLM serves `gpt-oss-20b` → **404** |

Symptoms in order, as you fix each:

1. Playground shows *"You need at least one model"*; LlamaStack logs
   `list_provider_model_ids() failed error=Error code: 401` +
   `Model refresh skipped provider_id=maas-vllm-inference-<N>`.
2. Model **appears** in the picker, chat returns **"Server error"**; LlamaStack logs
   `Provider SDK error during response generation exc=Error code: 404`.
   Defect 2 is especially deceptive: the bare base *does* serve `/v1/models`
   (that is maas-api's catalog endpoint), so discovery succeeds and the config
   looks correct.
3. Chat still fails; vLLM replies
   `The model 'publishers/llm/models/gpt-oss-20b' does not exist`.

**Root causes** (`packages/gen-ai/bff/internal/integrations/kubernetes/token_k8s_client.go`):

- **#1** — the credential lookup (~line 1519) resolves a model's token by finding an
  `InferenceService`/`LLMInferenceService` **in the user's own project namespace**
  and reading its ServiceAccount token secret. A MaaS model is in `llm`, is not
  SA-token authenticated, and is not at a plain in-cluster URL — so the lookup
  fails, and the env builder (~line 1596) falls to `else → Value: "fake"`.
  `"fake"` is a deliberate sentinel for *"no credential configured"* (see also
  `external_models.go:157`, `lsd_responses_handler.go:1301`) — harmless for an
  unauthenticated in-cluster vLLM, fatal for a gateway that checks keys.
  Note the irony: installing a MaaS model **requires** the user token (~line 1802,
  `"user auth token is required to install MaaS models"`) and threads it into
  `generateLlamaStackConfig`, which uses it only to *list* models via the MaaS BFF.
  The token is present and then dropped.
- **#2** — `endpointURL := ensureVLLMCompatibleURL(maasModel.URL)` takes the catalog's
  `url` (the bare gateway base, see **§D2a**) and appends `/v1`. Fixing D2a upstream
  fixes this one for free.
- **#3** — the generator emits `provider_model_id` for the sentence-transformers
  embedding model in the very same file, but omits it for MaaS models. An
  oversight, not a design choice.

---

## Prepared comment for RHOAIENG-79529

Reproduced on `rhods-operator.3.5.0` (GA-track nightly, clean install
2026-07-30, cluster-fzgjg) — all three defects persist past EA. Generated
`llama-stack-config` for a MaaS model (`gpt-oss-20b`):

```yaml
config:
  api_token: ${env.VLLM_API_TOKEN_1:=fake}          # OGXServer env: VLLM_API_TOKEN_1=fake
  base_url: https://maas.<domain>/v1                # bare gateway base + /v1 -> 404
models:
- provider_id: maas-vllm-inference-1
  model_id: publishers/llm/models/gpt-oss-20b       # new catalog id format
  model_type: llm                                    # NO provider_model_id
  # (the sentence-transformers embedding entry in the same file DOES set provider_model_id)
```

First playground message → "Server error", pod log:
`Provider SDK error during response generation ... Error code: 404`.

Two build-level improvements vs EA worth noting: the model picker now lists the
MaaS model (the `ModelsAsServiceReady` gate was relaxed to `AIGatewayReady`,
odh-dashboard `3e5b156a0`), and the Subscription tier dropdown populates.

Source-level status as of 2026-07-31:

- **Defect 1 (fake token): fixed on odh-dashboard main** by RHOAIENG-38993 /
  `280db9dc5` (static VLLM_API_TOKEN_N machinery removed; ephemeral MaaS key
  minted per request as provider_data). **Not on rhoai-3.5** — that branch still
  ships the fake env plus the runtime override gated on a `maas-` provider-id
  prefix; live 3.5.0 behavior still shows the fake token in effect.
- **Defect 2 (base_url): not a dashboard bug.** The BFF passes the catalog
  `url` verbatim (`token_k8s_client.go`, `ensureVLLMCompatibleURL`) and its
  test fixtures expect `.../llm/<model>/v1` — the catalog itself advertises the
  bare gateway base on 3.5.0 (`MaaSModelRef.status.endpoint` = `/`; maas-api
  echoes it). Root cause is maas-controller-side (surviving variant of the
  RHOAIENG-76220 BBR-endpoint family). Fixing the catalog URL fixes this defect
  with zero dashboard changes.
- **Defect 3 (provider_model_id): unfixed everywhere.** MaaS LLM entries go
  through `NewLLMModel` (`llamastack_config.go`) which never sets
  `ProviderModelID`, while `NewEmbeddingModel` does; the id-resolution helper
  on main already honors `provider_model_id` when present, so the fix is
  plumbing the served-model name into the MaaS entry.

Workaround B from the description confirmed working on 3.5.0 (951ms round-trip
after: mint key → patch OGXServer VLLM_API_TOKEN_1 → fix base_url to
`https://maas.<domain>/<ns>/<model>/v1` → add `provider_model_id: <served-name>`
→ restart lsd pod). Also confirmed: the config regenerates on playground
recreate, so the workaround is per-playground and fragile.
