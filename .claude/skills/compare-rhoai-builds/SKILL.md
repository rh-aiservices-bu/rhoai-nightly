---
name: compare-rhoai-builds
description: Use when asking which RHOAI nightly build is where — comparing the catalog image pinned on main or clusters against a connected cluster, a newer build on quay, or a user-supplied tag/digest; also when deciding whether a new nightly could have fixed a docs/ ledger entry.
argument-hint: "[what to compare, e.g. 'offline only' or 'vs rhoai-3.6-ea.1-nightly' or 'also check the repos']"
allowed-tools: Bash(make compare*), Bash(scripts/compare-builds.sh*), Bash(./scripts/compare-builds.sh*), Bash(oc get *), Bash(oc whoami *), Bash(oc config get-contexts*), Bash(oc config current-context), Bash(git fetch *), Bash(skopeo inspect *), Read, Grep, Glob
---

# Compare RHOAI Builds

`scripts/compare-builds.sh` does the mechanical work. This skill is for choosing
what to compare and interpreting the answer — the parts that need judgment.

Run it, read the table, then decide what (if anything) it means. **The script
reports; it never changes a cluster or a pin.**

## Run it

```bash
make compare                                    # main + clusters + current cluster + quay family
make compare ARGS="--no-cluster"                # offline: git pins and quay only
make compare ARGS="--repos"                     # also list upstream commits since the build
make compare ARGS="--fixes"                     # which ledger Jira keys have commits on the build branch
make compare ARGS="--against :rhoai-3.5"        # what another catalog build contains that ours doesn't
make compare ARGS="--image :rhoai-3.6-ea.1-nightly"
make compare ARGS="--cluster <oc-context> --cluster current"
```

`scripts/compare-builds.sh --help` lists every option. Exit codes: **0** = all
actionable points agree, **2** = drift, **1** = usage error or nothing resolved.

Map the request to flags rather than asking:

| The user wants | Flags |
|---|---|
| "is there a new nightly?" | default, or `--no-cluster` if no cluster is up |
| "is this cluster current?" | `--cluster current` (component diff runs automatically) |
| "is prod behind?" | `--branch clusters --cluster <bu-nightly context>` |
| "what about 3.6?" | `--image :rhoai-3.6-ea.1-nightly` |
| "what changed upstream?" | add `--repos` |
| "has anything in the ledger been fixed?" | add `--fixes` |
| "what's in build X that we don't have?" | `--against <ref>` (e.g. `:rhoai-3.5`) |
| "did a new milestone appear?" | add `--list-tags` (slow — only for discovery) |

## `--fixes` — where it looks and how it degrades

The fix hunt searches the **`red-hat-data-services` branch named after the tag
family** (`rhoai-3.5-nightly` → branch `rhoai-3.5` — the branch that builds the
nightly) for commits citing the Jira keys in `docs/`, split into **in-build**
vs **PENDING** by the catalog image's build date. It is portable by design:

- **Local clones** are found by origin-remote URL, never by path
  (`RHOAI_SRC_ROOTS` overrides the search roots, colon-separated) — full
  history, but purely an optimisation.
- **No clones** → `gh` if authenticated, else the **anonymous GitHub API**
  (public repos; ~1 request/repo, 60/hr limit, `--since` window only,
  default 90d).
- **Jira** enrichment needs `JIRA_TOKEN` or `JIRA_EMAIL`+`JIRA_API_TOKEN`
  (there is no anonymous Jira read); it is skipped with a printed notice
  otherwise — statuses recorded in the ledger remain the fallback.

Every run prints a `sources:` line and scopes its no-hit claim to what was
actually searched. Relay both to the user — a "no hits" from a 90-day window is
a different statement than one from full history. A cited key is evidence a fix
*exists*, never that the bug is gone; the entry's Detection command on a live
cluster is still the only settle.

## `--against` — what a different catalog build contains

Diffs the baseline (the `main` pin's resolved build) against any other catalog
image at two layers, **without a cluster and without opm**: it skopeo-copies
both FBC images (~300MB each, deleted after read; needs `yq`), reads
`configs/*/catalog.yaml` out of the layers, and compares the **channel-head
bundle's** `relatedImages`. Then, for moved components that map to a
`red-hat-data-services` source repo, it lists the release-branch commits
between the two build dates — the source-level "what's in theirs".

Reading the result: Konflux `chore(deps)` bumps are mechanical noise; the
signal is named `fix:`/Jira-keyed commits and CVE respins. The commit window is
an approximation (component images are built per-commit and released
asynchronously); the digest columns are the ground truth. And if the against
build is the released `rhoai-<ver>` track, adopting it is a **track change** —
surface it as a decision.

## Reference points

Each is optional and independently skippable. A point that cannot be resolved is
**reported as unresolved, never dropped** — "the cluster did not answer" is a
finding, so repeat it to the user rather than quietly narrowing the comparison.

| Point | Means |
|---|---|
| `branch:main` | what a fresh install of this repo would get |
| `branch:clusters` | what bu-nightly is pinned to |
| `cluster:<name>` | what is **actually running** — the catalog pod's digest, not the requested tag |
| `image` | whatever was named explicitly |
| `stream:*` | context only: what else exists in the version family |

Only branch/cluster/image points count as drift. `stream:` rows are historical
milestones and always differ — the script already excludes them from the verdict.

## Reading the result

**Same digest everywhere** → nothing to do.

**Different digest, same `version` label** → a nightly rebuild of one release.
The CSV name will be *identical* (`rhods-operator.3.5.0`); that is
`docs/issues/nightly-csv-name-static.md`, not a misreading. OLM will not upgrade
across it — `scripts/restart-catalog.sh` is what moves a cluster.

**Different `version` label** → a real version bump. Hand to the
**upgrade-rhoai-nightly** skill; do not bump the pin here.

**Component drift reported** → the cluster runs an older nightly than its own
catalog serves. Same remedy: `restart-catalog.sh` on that cluster.

**"A newer build exists in this family"** → check *which track*. `rhoai-<ver>` is
the released z-stream and `rhoai-<ver>-nightly` is the nightly; they move
independently and the released track has led before. Moving between them is a
**track change**, not a fresher build — surface it as a decision, never do it.

## Which ledger entries this touches

Only worth re-verifying an entry when a component it depends on actually moved.
Use `--repos` to see what landed upstream, then run **that entry's own Detection
command** from `docs/workarounds.md` / `docs/issues/` — do not re-derive the
diagnosis.

| If this moved | Re-verify |
|---|---|
| the operator (`odh-rhel9-operator`) | A13 / `observability-dashboard-unreachable`, A6 |
| `odh-dashboard`, `ODH_OGX_*` | `playground-maas-autowiring`, `ogx-upgrade-breaks-playgrounds` |
| `ODH_MAAS_*`, `ODH_AI_GATEWAY_OPERATOR` | A1, A2, E1 |
| `ODH_AI_GATEWAY_PAYLOAD_PROCESSING` | `maas-payload-h2-endstream-hang` |
| `ODH_MODEL_CONTROLLER` | A1 (the `maas-default-gateway-authn-ssl` filter leg) |
| `rhcl-operator` CSV version | both `telemetrypolicy-*` entries |
| nothing RHOAI-side | A11, `servicemonitors-bearertokenfile` — platform bugs, a nightly cannot affect them |

Component → source repo, for `--repos` output. RHDS is the downstream mirror, so
a fix only reaches a nightly once it is on the **RHDS** side:

| Component | Repo |
|---|---|
| `ODH_DASHBOARD_IMAGE` | `odh-dashboard` (both orgs) |
| `ODH_MAAS_API_IMAGE`, `ODH_MAAS_CONTROLLER_IMAGE` | `models-as-a-service` (both orgs) |
| `ODH_AI_GATEWAY_PAYLOAD_PROCESSING_IMAGE` | `opendatahub-io/ai-gateway-payload-processing` |
| `ODH_AI_GATEWAY_OPERATOR_IMAGE` | `opendatahub-io/ai-gateway-operator` |
| `ODH_OGX_*_IMAGE` | `opendatahub-io/ogx-k8s-operator` |
| the operator | `opendatahub-operator` / `rhods-operator` |

Kuadrant, RHCL and wasm-shim are in **neither** org — their fixes arrive as an
`rhcl-operator` CSV bump and are tracked through CONNLINK Jiras only.

**A moved digest is a reason to check, never evidence of a fix.** Removing a
workaround requires that entry's Detection command going green on a live cluster
running the build. This repo's [mission](../../../CLAUDE.md) is to surface bugs
upstream, and a prematurely removed workaround hides the regression of the very
bug it covered.

## Common mistakes

- **Acting on the report.** This skill compares and recommends. Bumping a pin,
  restarting a catalog, or editing the ledger are separate, deliberate steps.
- **Reading `.spec.image` as what a cluster runs.** Under a floating tag it is
  only a request. The script already uses the catalog pod's digest; don't
  "correct" it back.
- **Counting `stream:` rows as drift.** They are historical by construction.
- **Treating an identical CSV name as "no new build".** The name is static
  across nightlies; compare digests.
- **Concluding a bug is fixed because the commit landed upstream.** It has to be
  in the nightly's image, and the Detection command has to go green.
- **Reaching for `--list-tags` to resolve a known tag.** That is a ~216k-tag
  registry walk to answer what a single inspect answers in a second.

## If you must run commands by hand

Prefer the script — it exists so these details stay out of prose. When you do
drop to raw commands, the traps that cost real time while building it:

| Symptom | Cause |
|---|---|
| an `awk` field vanishes (`awk '{print $2}'` runs as `awk '{print }'`) | **this file's** `$1`/`$2` are substituted as skill arguments before you see them — use `sed`/`cut`/`while read` in any snippet written here |
| `unknown revision 'origin/mainomponents/...'` | zsh modifiers: `$br:components` parses as `$br` + `:c`. Brace it: `"origin/${br}:components/..."` |
| `no such file or directory: oc --context=...` | zsh does not word-split an unquoted command stashed in a variable |
| `no image found ... architecture arm64 ... OS darwin` | skopeo on Apple Silicon needs `--override-os linux --override-arch amd64` |
| `401 Requires authentication` from `quay.io/api/v1` | the REST API needs a token; `skopeo` reads this repo anonymously |
| an `oc` call hangs for minutes | unreachable API — always pass `--request-timeout=20s` |
| `jq: Cannot iterate over null` | the upstream command failed and emitted a non-JSON error; run it bare and read it |
