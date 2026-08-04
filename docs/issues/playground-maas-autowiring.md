# Gen AI playground + MaaS: UI chat works; static config ships a fake token (direct API use 401s)

**Jira: [RHOAIENG-79529](https://redhat.atlassian.net/browse/RHOAIENG-79529)**
(New, unassigned). Originally filed as three defects; live testing has
narrowed it to **one**: the generated static `api_token` is the literal
`fake`. The full fix is
[RHOAIENG-38993](https://redhat.atlassian.net/browse/RHOAIENG-38993)
(`280db9dc5` / [PR #8364](https://github.com/opendatahub-io/odh-dashboard/pull/8364)
— removes the static-token machinery, mints an ephemeral MaaS key per
request), in Review with fixVersion **3.6 EA1 only**; no rhoai-3.5
cherry-pick exists. Prepared Jira comment at the end of this file.

## Current state (live-verified 2026-08-04, tm9xb, released-track 3.5 FBC `f4183f7e`)

| Path | Result |
|---|---|
| **Playground UI chat with a MaaS model** | **WORKS out of the box** — playground created via dashboard, chat answered (a little slow on first message) |
| Direct API call to the playground's llama-stack endpoint (`POST :8321/v1/chat/completions`, static config only) | **401** — the static `api_token` is `fake` |
| Startup model refresh in the pod log | `list_provider_model_ids() failed error=Error code: 401` + `Model refresh skipped` — cosmetic (models are statically registered) |

Why UI chat works despite the fake static token: the model entry is
statically registered in the generated config (no dynamic listing needed),
and the dashboard BFF applies a **per-request runtime credential override**
for providers with the `maas-` prefix, so UI-originated requests never use
the static token. Both halves verified: OGXServer env shows
`VLLM_API_TOKEN_1=fake` while UI chat succeeds; an in-pod curl using only
the static config gets 401.

The generated `base_url` (`https://maas.<domain>/v1`) and `model_id`
(`publishers/llm/models/<model>`, no `provider_model_id`) are **correct** —
they are the gateway's body-based-routing contract, independently verified
by direct curl (200 with a real key).

**History:** on earlier 3.5 builds (ea.2 r8mf7 2026-07-29; GA-track fzgjg
2026-07-31) UI chat failed outright ("Server error" / 404) and required the
full Workaround B. Some combination of the newer dashboard module commits in
the current build made the runtime override effective for the UI path.

## Remaining defect

Anything that talks to the playground's llama-stack endpoint **without going
through the dashboard UI** — automation, notebooks, agents pointed at the
OGX route, `Update playground configuration` regenerations — authenticates
with the fake token and fails. Plus permanent 401 noise at startup.

## Steps to reproduce (the remaining defect)

1. RHOAI 3.5 with MaaS; create a Gen AI Studio playground selecting a MaaS
   model. UI chat works.
2. `oc get ogxserver -n <project> -o yaml | grep -A1 VLLM_API_TOKEN` →
   value is the literal `fake`;
   `oc get cm llama-stack-config -n <project> -o jsonpath='{.data.config\.yaml}'`
   → `api_token: ${env.VLLM_API_TOKEN_1:=fake}`.
3. In-pod direct call:
   ```bash
   POD=$(oc get pods -n <project> --no-headers | grep lsd | awk '{print $1}')
   oc exec -n <project> $POD -- curl -s -o /dev/null -w "%{http_code}\n" \
     -X POST http://localhost:8321/v1/chat/completions -H 'Content-Type: application/json' \
     -d '{"model":"maas-vllm-inference-1/publishers/llm/models/<model>","messages":[{"role":"user","content":"say OK"}],"max_tokens":5}'
   # → 401
   ```
4. Pod log shows the startup 401 + "Model refresh skipped".

## Root cause

`packages/gen-ai/bff/internal/integrations/kubernetes/token_k8s_client.go`
(odh-dashboard, rhoai-3.5): the static credential lookup resolves a model's
token by finding an InferenceService in the user's own namespace and reading
its SA token — a MaaS model matches nothing, so the env builder falls
through to the `Value: "fake"` sentinel. The runtime override covers the UI
path only. RHOAIENG-38993 on `main` deletes this machinery entirely.

## Workaround — minimal (token only)

Only needed if something must call the playground's llama-stack endpoint
directly (UI users need nothing):

```bash
NS=<project>; LSD=lsd-genai-playground; MODEL=<model>
MAAS=https://maas.apps.<cluster-domain>
KEY=$(curl -sk -X POST "$MAAS/maas-api/v1/api-keys" \
      -H "Authorization: Bearer $(oc whoami -t)" -H 'Content-Type: application/json' \
      -d "{\"name\":\"playground\",\"subscription\":\"${MODEL}-free\"}" | jq -r .key)
IDX=$(oc get ogxserver $LSD -n $NS -o json \
      | jq -r 'paths(objects) as $p | select(getpath($p).name? == "VLLM_API_TOKEN_1") | ($p|join("."))' \
      | awk -F. '{print $NF}')
oc patch ogxserver $LSD -n $NS --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/workload/overrides/env/$IDX/value\",\"value\":\"$KEY\"}]"
oc delete pod -n $NS -l app=ogx     # env read at startup
```

Do NOT rewrite `base_url` or add `provider_model_id` (the old Workaround B)
— the generated values are correct under the BBR contract; the path-based
rewrite is what *made* `provider_model_id` necessary. The config is
operator-owned and regenerates on playground recreate.

## Prepared comment for RHOAIENG-79529

Re-tested 2026-08-04 on the current 3.5.0 released-track build (FBC
`f4183f7e`, dashboard modules from the 2026-08-01+ sync): **UI playground
chat with a MaaS model now works out of the box** — the per-request runtime
credential override for `maas-`prefixed providers is effective, and the
generated `base_url`/`model_id` pair is valid under the gateway's
body-based-routing contract (verified by direct curl). The issue narrows to
one remaining defect: the static config still ships
`api_token: ${env.VLLM_API_TOKEN_1:=fake}` (OGXServer env literally `fake`),
so (a) any direct/programmatic call to the playground's llama-stack endpoint
returns 401, and (b) every pod start logs
`list_provider_model_ids() failed error=Error code: 401`.

RHOAIENG-38993 (`280db9dc5` / #8364) removes the static-token machinery
entirely and would close this. Requests: (1) link this issue to
RHOAIENG-38993 ("is fixed by"); (2) cherry-pick it to `rhoai-3.5` or add a
3.5.x fixVersion — as of 2026-08-04 it targets 3.6 EA1 only and no
downstream backport PR exists.
