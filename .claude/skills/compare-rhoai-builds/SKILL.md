---
name: compare-rhoai-builds
description: Use when asking which RHOAI nightly build is where — comparing the catalog image pinned on main or clusters against a connected cluster, a newer build on quay, or a user-supplied tag/digest; also when deciding whether a new nightly could have fixed a docs/ ledger entry.
argument-hint: "[reference points to include/skip, e.g. 'skip clusters' or 'vs quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.6-ea.1-nightly']"
allowed-tools: Bash(oc *), Bash(git *), Bash(skopeo *), Bash(jq *), Bash(grep *), Bash(printf *), Bash(echo *), Bash(for *), Bash(cd *), Bash(mkdir *), Bash(sort *), Bash(head *), Bash(tail *), Bash(wc *), Bash(./pull-all.sh *), Read, Grep, Glob, WebFetch
---

# Compare RHOAI Builds

Answer "which build is where, and what changed between them" on demand. This is
**not** a scheduled job and keeps **no persistent state between runs** — every
run resolves its reference points fresh and compares them against each other.

## The model: reference points

A *reference point* is anything that resolves to a catalog image digest. Resolve
the ones that are relevant, skip the rest. Nothing here is required — a run with
two reference points is a valid run.

| # | Reference point | Where it comes from | Skip when |
|---|---|---|---|
| 1 | **`clusters` branch pin** | `git show origin/clusters:components/operators/rhoai-operator/base/catalogsource.yaml` | not asking about bu-nightly |
| 2 | **Connected cluster** | `oc get catalogsource` + catalog pod `imageID` | no cluster, or unreachable |
| 3 | **`main` branch pin** | `git show origin/main:.../catalogsource.yaml` | rarely — this is the baseline |
| 4 | **User-designated image** | `$ARGUMENTS` — a tag or a `@sha256:` digest | none given |
| 5 | **Newest build in main's version stream** | quay tag family scan (see below) | only comparing what's deployed |

Parse `$ARGUMENTS` for which to include or skip. With no arguments, resolve
1, 2, 3, and 5, and say which ones were skipped and why.

## Step 1 — Resolve each reference point to a digest

### Git-pinned (1 and 3)

```bash
git fetch origin --quiet
for br in main clusters; do
  printf '%-10s %s\n' "$br" \
    "$(git show "origin/${br}:components/operators/rhoai-operator/base/catalogsource.yaml" \
        | sed -nE 's/^[[:space:]]*image:[[:space:]]*//p')"
done
```

Two deliberate choices here, both explained in
[Environment gotchas](#environment-gotchas): the braces in `${br}:`, and `sed`
rather than `awk '{print $2}'`.

Also diff the channel when the pins differ — a tag change without the matching
channel change is a broken upgrade:
`git show origin/<br>:components/operators/rhoai-operator/base/patch-channel.yaml`

### Connected cluster (2)

`.spec.image` is what GitOps *asked for*; the catalog pod's `imageID` is what is
**actually running** — after a floating tag moves these disagree, and the pod is
the truth.

```bash
oc --request-timeout=20s get catalogsource rhoai-catalog-nightly -n openshift-marketplace -o jsonpath='{.spec.image}{"\n"}'
oc --request-timeout=20s get pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}'
oc --request-timeout=20s get subscription rhods-operator -n redhat-ods-operator \
  -o jsonpath='state={.status.state}  installed={.status.installedCSV}{"\n"}'
```

To reach a cluster that is not the current context without switching it, pass
`--context=` (list them with `oc config get-contexts`).

### Tag → digest, and build date (4, and any tag from 1/3)

```bash
skopeo inspect --no-tags --override-os linux --override-arch amd64 \
  docker://quay.io/rhoai/rhoai-fbc-fragment:<tag> \
  | jq -r '[.Labels["build-date"], .Digest[7:15], .Labels.version, .Labels.release] | @tsv'
```

`--override-os linux --override-arch amd64` is **mandatory** on an Apple Silicon
Mac — without it skopeo fails with *"no image found in image index for
architecture arm64, OS darwin"*.

### Newest build in the version stream (5)

Take the version from main's tag (`rhoai-3.5-nightly` → `3.5`) and resolve every
*floating or milestone* tag in that family, newest `build-date` wins:

```bash
for t in rhoai-3.5 rhoai-3.5-nightly rhoai-3.5-ea.1 rhoai-3.5-ea.2; do
  printf '%-22s %s\n' "$t" "$(skopeo inspect --no-tags --override-os linux --override-arch amd64 \
    docker://quay.io/rhoai/rhoai-fbc-fragment:$t 2>/dev/null \
    | jq -r '[.Labels["build-date"], .Digest[7:15]] | @tsv')"
done
```

`rhoai-<ver>` (released z-stream track) and `rhoai-<ver>-nightly` move
independently — **the released track is sometimes the newer of the two.** Report
both rather than assuming nightly leads.

Only run `skopeo list-tags` when you need to *discover* which milestones exist
(a new `-ea.N` appeared, or the version rolled). It returns **~216,000 tags** and
takes minutes — cache it to the scratchpad and filter, don't re-fetch:

```bash
skopeo list-tags --override-os linux --override-arch amd64 \
  docker://quay.io/rhoai/rhoai-fbc-fragment | jq -r '.Tags[]' > "$SCRATCH/fbc-tags.txt"
grep -E "^rhoai-3\.5" "$SCRATCH/fbc-tags.txt" | grep -vE -- "-[0-9a-f]{40}$|-linux-|\.git$"
```

The `-<40-hex>` tags are per-commit builds (~1300 per version) and the `-linux-*`
tags are per-arch manifests — filter both out; they are noise for this purpose.

## Step 2 — Compare at the catalog layer

Build one table: reference point | tag | digest8 | build-date | version/release.
Then state the relationships plainly:

- **Same digest** → identical build, nothing else to check.
- **Different digest, same `version` label** → a nightly rebuild of the same
  release. Expect the **CSV name to be identical** (`rhods-operator.3.5.0`) —
  that is `docs/issues/nightly-csv-name-static.md`, not a bug in your reading.
  OLM will not upgrade across it; `make restart-catalog` is what moves a cluster.
- **Different `version` label** → a real version bump; the upgrade path matters.
  Hand off to the **upgrade-rhoai-nightly** skill.

## Step 3 — Compare at the component layer (needs a cluster)

Catalog images cannot be decomposed locally — there is no `opm` or `crane` on
this machine, so component digests come from a **connected cluster** only. Skip
this step entirely when there isn't one, and say so.

Write to the scratchpad, not the repo. Do **not** diff the two raw lists against
each other — they are not the same universe. The env list carries version-string
vars (`0.24.0+cpu`) and duplicates, and the packagemanifest carries the bundle
and operator images the env list has no reason to hold. Normalise both to
`repo digest` pairs and join on the repo name:

```bash
norm() { grep -oE '[a-z0-9.:/-]+@sha256:[0-9a-f]{64}' | sed 's/@/ /' | sort -u; }

# What the catalog OFFERS
oc --request-timeout=30s get packagemanifest -l catalog=rhoai-catalog-nightly -n openshift-marketplace -o json \
 | jq -r '.items[]|select(.metadata.name=="rhods-operator").status.channels[]|select(.name=="stable-3.x")
          |.currentCSVDesc.relatedImages[]' | norm > "$SCRATCH/offered.pairs"

# What is DEPLOYED  (installed CSV name from the Subscription in Step 1)
oc --request-timeout=30s get csv "$CSV" -n redhat-ods-operator \
 -o jsonpath='{range .spec.install.spec.deployments[0].spec.template.spec.containers[0].env[*]}{.value}{"\n"}{end}' \
 | norm > "$SCRATCH/deployed.pairs"

join "$SCRATCH/offered.pairs" "$SCRATCH/deployed.pairs" | while read -r repo off dep; do
  [ "$off" != "$dep" ] && printf '%s\n  offered  %s\n  deployed %s\n' "$repo" "${off:7:8}" "${dep:7:8}"
done
```

Any output means the cluster runs an **older nightly than its own catalog
serves** — the exact symptom of the static-CSV-name issue, and the case
`make restart-catalog` exists to resolve. No output means the cluster is current
with its catalog, regardless of where the floating tag now points.

Two repos appear only on the offered side — `odh-operator-bundle` and
`odh-rhel9-operator`. That asymmetry is structural, not drift: the operator's own
image is not in its env list. Compare it separately, and expect all three to agree:

```bash
oc --request-timeout=20s get csv "$CSV" -n redhat-ods-operator \
  -o jsonpath='{.spec.install.spec.deployments[0].spec.template.spec.containers[0].image}{"\n"}'
oc --request-timeout=20s get pod -n redhat-ods-operator -l name=rhods-operator \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}' | sort -u
```

## Step 4 — Check the source repos

Only worth doing for components whose digest actually moved.

The upstream clones live outside this repo, one directory per GitHub org, with a
`pull-all.sh` in each. Locate them rather than assuming a path:

```bash
GH=~/git/github          # adjust if the clones live elsewhere
"$GH/opendatahub-io/pull-all.sh" -n -j 8 "$GH/opendatahub-io" "$GH/red-hat-data-services"
```

`-n` is a dry run (fetch, report, never merge) — use it first, drop it to
actually fast-forward. Repos are discovered by walking the tree, so new clones
dropped into either directory are picked up automatically.

Then, per repo that moved, list what landed after the **older** build-date —
`@{u}` is the upstream branch, so this works without merging anything:

```bash
git -C "$GH/<org>/<repo>" log --oneline --no-decorate HEAD..@{u} --since=<older-build-date>
```

Grep those subjects for the Jira keys already in the ledger.

Component → repo mapping (RHDS repos are the downstream mirrors; the fix has to
be on the **RHDS** side to reach a nightly):

| Component image env | Repo |
|---|---|
| `ODH_DASHBOARD_IMAGE` | `odh-dashboard` (both orgs) |
| `ODH_MAAS_API_IMAGE`, `ODH_MAAS_CONTROLLER_IMAGE` | `models-as-a-service` (both orgs) |
| `ODH_AI_GATEWAY_PAYLOAD_PROCESSING_IMAGE` | `opendatahub-io/ai-gateway-payload-processing` |
| `ODH_AI_GATEWAY_OPERATOR_IMAGE` | `opendatahub-io/ai-gateway-operator` |
| `ODH_OGX_*_IMAGE` | `opendatahub-io/ogx-k8s-operator` |
| the operator itself (`odh-rhel9-operator`) | `opendatahub-operator` / `rhods-operator` |
| `ODH_MODEL_CONTROLLER_IMAGE` | not cloned — clone on demand |

Kuadrant / RHCL / wasm-shim are **not in either org**. Their fixes arrive as an
`rhcl-operator` CSV bump, tracked through CONNLINK Jiras only.

## Step 5 — Which ledger entries could this have changed

A ledger entry is only worth re-verifying when a component it depends on moved.
Map the changed components, then run **that entry's own Detection command** —
do not re-derive the diagnosis.

| If this moved | Re-verify |
|---|---|
| operator (`odh-rhel9-operator`) | A13 / `observability-dashboard-unreachable` (PR #3923), A6 |
| `odh-dashboard`, `ODH_OGX_*` | `playground-maas-autowiring`, `ogx-upgrade-breaks-playgrounds` |
| `ODH_MAAS_*`, `ODH_AI_GATEWAY_OPERATOR` | A1, A2, E1 |
| `ODH_AI_GATEWAY_PAYLOAD_PROCESSING` | `maas-payload-h2-endstream-hang` |
| `ODH_MODEL_CONTROLLER` | A1 (the `maas-default-gateway-authn-ssl` filter leg) |
| `rhcl-operator` CSV version | both `telemetrypolicy-*` entries |
| nothing RHOAI-side | A11, `servicemonitors-bearertokenfile` — platform bugs, unaffected by a nightly |

**A moved digest is a reason to check, never evidence of a fix.** Removing a
workaround requires the Detection command going green on a live cluster running
that build — this repo's [mission](../../../CLAUDE.md) is to surface bugs, and a
prematurely removed workaround hides the regression of the bug it covered.

## Output

Report, in this order:

1. **Reference-point table** — point | tag | digest8 | build-date | version.
2. **Skipped points and why** (never silently omit one; "cluster unreachable" is
   a finding).
3. **Relationships** — who leads, by how long, whether a version boundary is crossed.
4. **Component diff** if a cluster was available; otherwise say it was not.
5. **Ledger entries worth re-verifying**, with the specific reason.
6. **Recommendation** — usually "no action", "bump `main`", or "hand to
   upgrade-rhoai-nightly". Do not act on it in this skill.

## Environment gotchas

Each of these cost a failed command when this skill was built:

| Symptom | Cause | Fix |
|---|---|---|
| `no such file or directory: oc --context=...` | The Bash tool runs **zsh**, which does not word-split unquoted variables | Don't stash a command in a var. Repeat it, or use a function |
| `unknown revision 'origin/mainomponents/...'` | zsh **modifiers**: `$br:components` parses as `$br` + the `:c` modifier, eating the `c` | Always brace before a colon: `"origin/${br}:components/..."` |
| An `awk` field reference silently vanishes (`awk '{print $2}'` runs as `awk '{print }'`) | The skill loader substitutes `$1`/`$2`/… in this file as **skill arguments** before you ever see it | Never put a bare positional in a snippet here. Use `sed`, `cut`, or `while read -r a b` |
| `command not found: timeout` | macOS has no `timeout` | `gtimeout`, or rely on the tool's own timeout |
| `no image found ... architecture arm64 ... OS darwin` | Apple Silicon default | `--override-os linux --override-arch amd64` |
| Quay REST API returns `401 Requires authentication` | `quay.io/api/v1` needs a token even for this repo | Use `skopeo`, which works anonymously |
| An `oc` command hangs for minutes | Sandbox cluster was reaped; TCP just times out | Always pass `--request-timeout=20s` |
| `jq: Cannot iterate over null` on a `skopeo`/`oc` pipe | The upstream command failed and printed a non-JSON error | Run it bare first and read the error |

## Common mistakes

- **Reading `.spec.image` as what the cluster runs.** Under a floating tag it is
  a *request*. The catalog pod's `imageID` is the truth.
- **Assuming `-nightly` is the newest build in the stream.** Check `rhoai-<ver>`
  too; it led on 2026-08-06.
- **Treating an identical CSV name as "no new build".** The name is static
  across nightlies by design-bug; compare digests, never names.
- **Running `skopeo list-tags` to resolve a known tag.** That is a 216k-tag
  fetch to answer what one `skopeo inspect` answers in a second.
- **Diffing the offered and deployed image lists directly.** Different universes;
  it manufactures ~30 lines of fake drift. Join on the repo name (Step 3).
- **Concluding a bug is fixed from a commit landing upstream.** The commit must
  be in the *nightly's* image, and the Detection command must go green.
