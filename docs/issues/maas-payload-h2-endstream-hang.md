# MaaS payload-processing (3.5.0-ea.2): HTTP/2 responses never close — every H2 client hangs

**Jira: NOT FILED — and none exists** (searched 2026-08-03: no RHOAIENG/RHAIENG
issue mentions END_STREAM or this hang). The fix reached 3.5.0 images via a
plain PR with no Jira trail:

- **Fix PR:** [opendatahub-io/ai-gateway-payload-processing#419](https://github.com/opendatahub-io/ai-gateway-payload-processing/pull/419)
  "fix: update framework to include SSE response body parser" — commit
  `a846538bfe73392cd48ef413c17116821987e6ac`, 2026-07-21 (go.mod bump to
  `llm-d-inference-payload-processor` commit `a8bbe6a6`).
- **First fixed image:** `odh-ai-gateway-payload-processing-rhel9@sha256:84cee292…`
  (built 2026-07-24/25), pinned by the `rhods-operator.3.5.0` bundle.
- **Every ea.2 image is broken** (`cb1b1816` Jul 13 → `347acb92` Jul 16;
  the ea.2 line froze 2026-07-18, three days before the fix). No fix exists or
  will ever exist within ea.2.

**Why this stays in the ledger despite being fixed in 3.5.0:** the
`redhat-operators` **released `beta` channel ships `3.5.0-ea.2` today** — real
EA customers get a build whose MaaS endpoint hangs every HTTP/2 client, and
there is no Jira, release note, or known-issue record they or support can
find. Filing gives support/QE a searchable record and a vehicle for the
"respin ea.2 or document it" decision. Delete this file once a Jira exists or
the beta channel moves past ea.2.

## Summary

On every RHOAI 3.5.0-ea.2 build, any request to a MaaS LLM route through
`maas-default-gateway` returns 200 and the complete response body, but the
connection is never terminated: HTTP/2 clients (curl, Node, Go, Java — anything
H2-native) block until their own read-timeout on every request, buffered AND
streaming. HTTP/1.1 clients complete normally (they finish at `content-length`
bytes), which hides the bug from Python `requests`/`httpx`/OpenAI-SDK users.

**Live re-confirmed 2026-08-03** on bu-nightly-2 (ea.2 pinned `6ef49d54`),
same request, same key: HTTP/1.1 → 200 in **0.33s**; HTTP/2 → 200 headers,
stream never closes, client killed at its 30s `--max-time`.

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

## Empirical bisect (2026-07-30)

Identical envoy (Service Mesh 3.4.0, istio-proxy digest `d518f3d1…`), identical
EnvoyFilter processing modes, identical plugins ConfigMap:
- ea.2 image `cb1b1816` (cluster bu-nightly-2): H2 200 but t=read-timeout, every request
- fixed image `84cee292` (clusters r8mf7 + fzgjg): H2 200 in 0.22–0.24s, clean close

Things verified NOT to fix it on ea.2: gateway pod restart, istiod restart,
payload-processing pod restart, deleting the payload-processing EnvoyFilter
(maas-controller recreates it), setting plugins ConfigMap `response: []` (the
RHOAIENG-79535 change — different symptom), moving to any other ea.2 image
(all carry framework rc.4), reinstalling MaaS.

## Detection

```bash
curl -sk --max-time 30 -X POST -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"<m>","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
  -o /dev/null -w "h2=%{http_code} t=%{time_total}s\n" "https://maas.<domain>/<ns>/<m>/v1/chat/completions"
# bug: h2=200 t==your --max-time.  fixed: t < 1s.  cross-check: --http1.1 is fast either way.
oc get deploy -n openshift-ingress payload-processing \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# cb1b1816… / 347acb92… (any ea.2 build) = affected; 84cee292… = fixed
```

## Remedy for an ea.2 cluster

Upgrade in place to 3.5.0: point the CatalogSource at a fragment containing
the 3.5.0 bundle (`rhoai-3.5` release tag or `rhoai-3.5-nightly`) and switch
the Subscription channel `beta` → `stable-3.x`; the 3.5.0 entry's
`skipRange: >=3.4.0 <3.5.0` covers ea.2 prereleases, so OLM upgrades without
uninstall. (Caveat while it lasts: 3.5.0 builds without
[models-as-a-service#1313](https://github.com/opendatahub-io/models-as-a-service/pull/1313)
carry the RHOAIENG-80043 dashboard-401 EnvoyFilter leak — gate the upgrade on
a build containing it.)

## Filing draft (RHOAIENG)

Summary, root cause, bisect, and detection as above. Suggested ask: confirm
whether ea.2 gets a respin with the framework bump (PR #419 / image
`84cee292`), or document that ea.2 MaaS is HTTP/2-broken in the EA release
notes with the in-place 3.5.0 upgrade as the remedy — today the released
`beta` channel serves this bug to EA customers with no discoverable record.

Related: RHOAIENG-79535 (adjacent response-plugin/SSE issue, Closed),
RHOAIENG-79619 (response-path perf, Closed), envoy upstream #44201 (same
symptom class in envoy ext_proc).
