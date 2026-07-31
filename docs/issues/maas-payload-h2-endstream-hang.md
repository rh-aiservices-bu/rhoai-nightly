# MaaS payload-processing (3.5.0-ea.2): HTTP/2 responses never close — every H2 client hangs

**Jira: NOT FILED** — fixed upstream with no Jira trail (framework `a8bbe6a6` via ODH `a846538`; first fixed image `84cee292` in `rhods-operator.3.5.0`). Filing draft below.

- **MaaS inference responses never close over HTTP/2 — every H2 client hangs
  until its read-timeout (3.5.0-ea.2 line only; FIXED in nightly/GA builds
  ≥ 2026-07-24).** Debugged on bu-nightly-2 (ea.2) vs r8mf7 (3.5.0), 2026-07-30.
  - **Symptom:** any LLM-route request through the MaaS gateway returns 200 and
    the **full, valid response body**, but the connection is never terminated —
    the client blocks until its own timeout. Affects buffered *and* streaming
    (SSE) responses, every model, both subscription tiers. **HTTP/1.1 is
    unaffected** (client completes at `content-length` bytes), which is why
    Python clients (`requests`/`httpx`/OpenAI SDK — HTTP/1.1 by default) never
    see it while curl, Node, Go, and other H2-native clients always do.
  - **Detection:**
    ```bash
    curl -sk --max-time 30 -X POST -H "Authorization: Bearer $KEY" \
      -H "Content-Type: application/json" \
      -d '{"model":"<m>","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
      -o /dev/null -w "h2=%{http_code} t=%{time_total}s\n" "$MAAS/<ns>/<m>/v1/chat/completions"
    # bug: h2=200 t=30.0s (exactly your --max-time).  fixed: t < 1s.
    # cross-check: add --http1.1 -> completes fast even on affected builds
    oc get deploy -n openshift-ingress payload-processing \
      -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
    # cb1b1816... / 347acb92... (any ea.2 build) = affected; 84cee292... = fixed
    ```
  - **Root cause:** the `payload-processing` ext_proc (IPP) runs with
    `response_body_mode: FULL_DUPLEX_STREAMED` + `response_trailer_mode: SEND`;
    in that mode envoy signals end-of-response via a ResponseTrailers message,
    not via `end_of_stream` on a body chunk. The IPP framework
    (`llm-d-inference-payload-processor` `v0.1.0-rc.4`, in every ea.2 image)
    only **echoes** the incoming chunk's EoS flag (`pkg/handlers/response.go`)
    and answers trailers with an inert empty reply — so it never emits
    `end_of_stream=true`, envoy never sends H2 END_STREAM, and the stream stays
    open. (The request path hard-codes EoS `true` on the last chunk, which is
    why requests work.) Fix vehicle: ai-gateway-payload-processing `a846538`
    (2026-07-21) bumps the framework to commit `a8bbe6a6`; the first image
    carrying it is `84cee292` (built 2026-07-24/25) — pinned by the
    `rhods-operator.3.5.0` bundle. Verified empirically: identical envoy
    (SM 3.4.0) + identical EnvoyFilter, `cb1b1816` hangs, `84cee292` closes in
    0.25s.
  - **Things that do NOT fix it** (all tested): restarting the gateway pod,
    istiod, or the payload-processing pods; deleting the `payload-processing`
    EnvoyFilter (maas-controller recreates it in ~20 min); setting the plugins
    ConfigMap `response: []` (upstream #1284 / RHOAIENG-79535 — addresses a
    different response-path symptom); moving to any other ea.2 image (all are
    framework rc.4). Reinstalling MaaS redeploys the same image.
  - **Remedy for a cluster pinned to the ea.2 fragment:** upgrade in place to
    3.5.0 — point the CatalogSource at a fragment containing the 3.5.0 bundle
    (`rhoai-3.5-nightly` floating or `rhoai-3.5` release) and switch the
    Subscription channel `beta` → `stable-3.5`; the 3.5.0 entry's
    `skipRange: >=3.4.0 <3.5.0` covers ea.2 prereleases, so OLM upgrades
    without uninstall. No fix exists within the ea.2 line (frozen 2026-07-18,
    three days before the framework bump).
  - **Not applicable to main** — main's `stable-3.x` channel already resolves
    `rhods-operator.3.5.0` with the fixed image.

---

## Filing draft (RHOAIENG)

**Why file when it's already fixed:** the fix reached 3.5.0 GA images with no Jira
trail (upstream framework commit, no tracked bug). Filing gives (a) a record for
support/QE triaging "MaaS hangs" reports on ea.2 clusters, (b) a vehicle for any
ea.2 respin/backport decision, (c) searchability for the failure signature.

## Summary

On every RHOAI 3.5.0-ea.2 build, any request to a MaaS LLM route through
`maas-default-gateway` returns 200 and the complete response body, but the
connection is never terminated: HTTP/2 clients (curl, Node, Go, Java — anything
H2-native) block until their own read-timeout on every request, buffered AND
streaming. HTTP/1.1 clients complete normally (they finish at `content-length`
bytes), which hides the bug from Python `requests`/`httpx`/OpenAI-SDK users.

## Root cause (source-verified)

The `payload-processing` ext_proc runs with `response_body_mode:
FULL_DUPLEX_STREAMED` + `response_trailer_mode: SEND`. In that mode envoy
signals end-of-response via a (synthesized) ResponseTrailers message — the EoS
flag is never set on body chunks. The IPP framework in every ea.2 image
(`llm-d-inference-payload-processor v0.1.0-rc.4`) only **echoes** the incoming
chunk's EoS flag (`pkg/handlers/response.go` — `buildStreamedChunkResponse`
sets `EndOfStream: endOfStream` verbatim) and answers trailers with an inert
empty `TrailersResponse{}`. It therefore never emits `end_of_stream=true`,
envoy never sends H2 END_STREAM downstream, and the stream stays open. The
request path works because it hard-codes `EndOfStream: true` on the last chunk
(`pkg/common/envoy/chunking.go`, `setEos=true`).

## Fix lineage

- Fix vehicle: opendatahub-io/ai-gateway-payload-processing commit `a846538`
  (2026-07-21, PR #419) — bumps the framework to `llm-d-inference-payload-processor`
  commit `a8bbe6a6` (pseudo-version v0.1.0-rc.4.0.20260721200012-a8bbe6a6a75a).
- First fixed image: `odh-ai-gateway-payload-processing-rhel9@sha256:84cee292…`
  (built 2026-07-24/25), pinned by the `rhods-operator.3.5.0` bundle.
- All ea.2 images are broken: `cb1b1816` (Jul 13) through `347acb92` (Jul 16);
  the ea.2 branches froze 2026-07-18, three days before the fix.

## Empirical bisect (2026-07-30)

Identical envoy (Service Mesh 3.4.0, istio-proxy digest `d518f3d1…`), identical
EnvoyFilter processing modes, identical plugins ConfigMap:
- ea.2 image `cb1b1816` (cluster bu-nightly-2): H2 200 but t=read-timeout, every request
- GA image `84cee292` (clusters r8mf7 + fzgjg): H2 200 in 0.22–0.24s, clean close

Things verified NOT to fix it on ea.2: gateway pod restart, istiod restart,
payload-processing pod restart, deleting the payload-processing EnvoyFilter,
setting plugins ConfigMap `response: []` (the RHOAIENG-79535 change), moving to
any other ea.2 image, reinstalling MaaS.

## Detection

```bash
curl -sk --max-time 30 -X POST -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"<m>","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
  -o /dev/null -w "h2=%{http_code} t=%{time_total}s\n" "https://maas.<domain>/<ns>/<m>/v1/chat/completions"
# bug: h2=200 t==your --max-time.  fixed: t < 1s.  cross-check: --http1.1 is fast either way.
```

## Suggested ask

Confirm whether ea.2 gets a respin with the framework bump, or document that
ea.2 MaaS is H2-broken and the remedy is upgrading to 3.5.0 (skipRange
`>=3.4.0 <3.5.0` covers ea.2 prereleases — in-place upgrade works).

Related: RHOAIENG-79535 (adjacent response-plugin/SSE issue, Closed),
RHOAIENG-79619 (response-path perf, Closed), envoy upstream #44201 (same
symptom class in envoy ext_proc).
