---
name: diagnose-rhoai
description: Diagnose the state of an OpenShift cluster for RHOAI installation. Runs full health check, preflight, and config validation as appropriate based on install state, then independently hunts for symptoms the scripted checks don't cover.
argument-hint: "[--verbose]"
allowed-tools: Bash(make *), Bash(oc *), Bash(scripts/*), Bash(curl *), Bash(jq *), Bash(grep *), Bash(date *), Read, Grep, AskUserQuestion
---

# Diagnose RHOAI Cluster

Perform a comprehensive health check of the connected OpenShift cluster.

## The rule that matters most

**`scripts/diagnose.sh` reporting 0 failures is NOT sufficient evidence that the
cluster is healthy. Never conclude "fully operational" from its exit code alone.**

This is not hypothetical. On 2026-07-29 a full install finished with
`make diagnose` reporting *"35 passed, 0 failures — Cluster is fully operational"*
while the RHOAI dashboard was returning **503** and its gateway pod had been
**OOMKilled 13 times**. The script simply had no check that looked there. Six
distinct real problems were found that day (now `docs/known-issues.md` §A9, §A10,
§D2a–c, §E1); **none** of them was found by the script.

The script is a regression suite for problems we already know about. It cannot
find the next one. On a nightly build, the next one is the normal case — so
Step 3 below (the independent sweep) is mandatory, not conditional.

## Scope

Look at whole-cluster health, but **focus on what this repo installs**: the
`redhat-ods-*`, `redhat-ai-gateway-infra`, `kuadrant-system`, `llm`,
`models-as-a-service`, `nvidia-gpu-operator`, `openshift-nfd`,
`openshift-gitops`, `external-secrets`, `nfs-provisioner`, `evalhub-tenant`,
`openshift-ingress` namespaces and the operators in `openshift-operators`.
Platform-owned breakage elsewhere is worth *reporting* but is not ours to fix —
say so explicitly rather than burying our signal in it.

## Instructions

### Step 1: Run the diagnostic script

```bash
make diagnose
```

If `--verbose` was passed in `$ARGUMENTS`, run `scripts/diagnose.sh --verbose`.

Note `make diagnose` exits 1 on failures and 2 on warnings. If you pipe it
(`| tee`), the pipeline returns **tee's** status, not the script's — use
`${PIPESTATUS[0]}` or `set -o pipefail`, or you will report a failing run as
successful. (This exact masking hid a `make maas-model` failure on 2026-07-29.)

### Step 2: Determine install state

- **Bare**: GitOps not installed, RHOAI not installed
- **Partially installed**: GitOps up but RHOAI not Ready, or RHOAI up without MaaS
- **Fully installed**: RHOAI and MaaS both installed

**If bare or partially installed**, also run:

```bash
make preflight
make validate-config
```

### Step 3: Independent sweep — ALWAYS run this

Run these regardless of what the script reported. They are cheap, read-only, and
each one has caught a real outage that the script missed. Anything surprising
here becomes an investigation, not a footnote.

**3a. Does the user-facing thing actually work?**
Resource existence is not function. Probe the endpoints a human would use:

```bash
# Dashboard — expect 200/302/303. 503/502/000 = data plane down.
DASH=$(oc get route -A -o jsonpath='{range .items[?(@.spec.to.name=="data-science-gateway-data-science-gateway-class")]}{.spec.host}{"\n"}{end}' | head -1)
curl -sk -o /dev/null -w "dashboard=%{http_code}\n" --max-time 15 "https://${DASH}/"

# MaaS — expect 200 (or 401 unauthenticated)
oc get route -A --no-headers | awk '$3 ~ /^maas\./ {print $3; exit}'
curl -sk -o /dev/null -w "maas=%{http_code}\n" --max-time 15 "https://<maas-host>/maas-api/health"
```

**3b. Is anything crash-looping, OOMKilled, or restarting right now?**

```bash
oc get pods -A --no-headers | grep -Ev "Running|Completed|Succeeded"
oc get pods -A -o json | jq -r '.items[] | . as $p | (.status.containerStatuses//[])[]
  | select(.lastState.terminated.reason=="OOMKilled")
  | "\($p.metadata.namespace)/\($p.metadata.name) \(.name) restarts=\(.restartCount)"'
```

OOMKilled is the most common failure mode in this stack (two separate
`docs/known-issues.md` entries exist for it) and it is **invisible in the STATUS
column** once the container restarts successfully. Check it explicitly.

**3c. Do the CR conditions agree with reality?**

```bash
oc get dsc default-dsc -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
oc get authpolicy,telemetrypolicy -A -o json | jq -r '.items[]
  | "\(.kind) \(.metadata.namespace)/\(.metadata.name): \((.status.conditions//[])[]|select(.type=="Accepted")|.status)"'
oc get csv -A --no-headers | grep -v Succeeded
oc get applications.argoproj.io -n openshift-gitops --no-headers | awk '$2!="Synced"||$3!="Healthy"'
```

**3d. What changed recently?** Warnings in the last hour often name the problem
outright:

```bash
oc get events -A --sort-by=.lastTimestamp --field-selector type=Warning | tail -25
```

**3e. Read the logs of anything that looks unhappy** — don't infer from status
alone. The gateway OOM on 2026-07-29 was only explained by its envoy logs
(a wasm fetch retry loop ~1/s); status showed nothing but `CrashLoopBackOff`.

### Step 4: Triage against known problems

Before debugging from scratch, check whether it is already known:

`docs/known-issues.md` is the canonical index of **both** the workarounds this
repo carries and the things that are known-broken with no fix. Most entries have
a **Detection** command — run it rather than re-deriving the diagnosis:

- **A–C** — we work around it. If one regresses, the workaround stopped working.
- **D** — genuinely broken upstream, no fix. Nothing to repair; don't burn an
  afternoon on it. (§D2a explains why `make maas-verify` reports 11/3 on a
  perfectly working MaaS.)
- **E** — install-time hazards with a one-command remedy. **§E1 (operators
  caching a startup dependency probe) is the single most common install failure
  in this stack** — check it early whenever a condition names a resource that
  demonstrably exists.
- **F** — defects in this repo's own scripts.

### Step 5: Recognise these failure patterns

Learned the hard way; all cost significant time when unrecognised:

**Stale cached dependency probe.** An operator probes for a dependency once at
startup, caches the answer, and never re-checks. Symptom: a `Ready=False` /
`Accepted=False` whose message names a dependency that demonstrably *does* exist.
Seen with the RHOAI operator (trustyai waiting on an `InferenceServices` CRD that
existed) and Kuadrant (`AuthPolicy` reporting "Gateway API provider is not
installed" with istiod running).
→ Remedy is **always** `oc delete pod` on the operator, **never**
`oc rollout restart`: OLM owns these Deployments and reverts the restart
annotation, so `rollout restart` silently no-ops while `rollout status` cheerfully
reports success. Confirm by checking the ReplicaSet hash and pod AGE actually
changed.

**A workaround existing ≠ the workaround working.** Verify the *effect*, not the
presence of the manifest. The dashboard wasm-strip EnvoyFilter was present and
correctly targeted, yet ineffective because istio orders EnvoyFilters by
(priority, creationTimestamp, name) and Kuadrant's filter was created later.
→ Check the outcome (pod restart count, actual behaviour), not the object.

**A fix isn't tested until the affected pod restarts.** A pod parked in
CrashLoopBackOff backoff can sit for minutes running pre-fix config. I briefly
declared the priority fix "wrong" because of this. Delete the pod, then judge.

**Cascading failures hide behind the first one.** Fixing feast revealed trustyai;
fixing the AuthPolicy revealed the catalog-URL bug. After any fix, re-check the
whole condition list rather than assuming you are done.

**Structural green, functional red.** Every MaaS pod Running + gateway Programmed
+ health 200, yet API-key creation returned 500 because zero AuthConfigs existed.
Deployment-shaped checks cannot see this.

### Step 6: Summarise

- **INFO** = not installed yet (expected)
- **WARN** = needs attention, not blocking
- **FAIL** = broken, must be fixed

State plainly what you verified *functionally* versus what you only checked
structurally, and name anything you could not verify. If the script passed but
your sweep found something, say so directly — that is a gap in the script, and
worth adding a check for.

Recommend `make` targets rather than Claude skills, since the user may be in a
plain terminal.
