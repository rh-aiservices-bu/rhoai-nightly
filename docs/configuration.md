# Configuration

Everything you can configure through `.env`: pull-secret credentials, node sizing,
MaaS models, and which repo/branch ArgoCD syncs from.

> This page covers `.env`-driven configuration only. Changing the RHOAI version,
> hard-forking the repo, or adding components means editing tracked files — see
> [CLAUDE.md](../CLAUDE.md), or use the `/upgrade-rhoai-nightly` skill for version bumps.

## Pull-secret credentials

RHOAI nightly images live in `quay.io/rhoai`, which requires credentials. **You must
have one of the two modes below before you can install** — without registry
credentials the operators can't pull their images. `make secrets` (and `make all`)
auto-detects which mode to use.

- **Mode A — Manual:** you have personal `quay.io/rhoai` pull access.
- **Mode B — External Secrets:** you don't have quay access, but you have read access
  to the private bootstrap repo, which supplies the credentials from AWS. The repo is
  private, so if you're not already a member you'll need to **request read access** to
  [rh-aiservices-bu-bootstrap](https://github.com/rh-aiservices-bu/rh-aiservices-bu-bootstrap)
  (open an issue or ask a `rh-aiservices-bu` maintainer).

### Mode A — Manual credentials

Set your personal quay.io credentials in `.env`:

```bash
cp .env.example .env
# then edit .env:
QUAY_USER=your-username
QUAY_TOKEN=your-token
```

`make secrets` patches the cluster pull-secret directly. Idempotent — safe to re-run.

### Mode B — External Secrets (automatic)

If you have git access to the private
[bootstrap repo](https://github.com/rh-aiservices-bu/rh-aiservices-bu-bootstrap),
leave `QUAY_USER`/`QUAY_TOKEN` **empty**. `make secrets` then:

1. Installs the External Secrets Operator,
2. Creates a ClusterSecretStore for AWS Secrets Manager,
3. Applies an ExternalSecret that syncs the pull-secret from AWS.

The External Secrets Operator is then **adopted by ArgoCD during the sync phase**, so
it shows up as a managed application afterward — that's expected, not a stray install.

The pull-secret uses `creationPolicy: Merge`, so it survives ExternalSecret deletion —
you can switch modes without losing credentials.

Verify:

```bash
oc get externalsecret pull-secret -n openshift-config
oc get secret pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq '.auths | keys'
```

Switch from External Secrets to manual: set `QUAY_USER`/`QUAY_TOKEN` in `.env`, then
`make secrets` (it detects the credentials, deletes the ExternalSecret, and uses
manual mode).

## The `.env` file

Copy `.env.example` to `.env` and uncomment what you need. `.env` is gitignored — never
commit it. The Makefile sources it automatically.

| Variable | Default | Purpose |
|----------|---------|---------|
| `QUAY_USER` / `QUAY_TOKEN` | empty | Manual pull-secret credentials (Mode A) |
| `BOOTSTRAP_REPO` / `BOOTSTRAP_BRANCH` | bootstrap repo / `dev` | External Secrets source (Mode B), for forks |
| `GPU_INSTANCE_TYPE` | `g6e.2xlarge` | GPU MachineSet instance type |
| `GPU_AZ` | auto | GPU availability zone (set if your AZ lacks capacity) |
| `GPU_MIN` / `GPU_MAX` | `1` / `3` | GPU autoscaler bounds |
| `CPU_INSTANCE_TYPE` | `m6a.4xlarge` | CPU worker MachineSet instance type |
| `CPU_VOLUME_SIZE` | `120` | CPU worker root volume (GB) |
| `CPU_MIN` / `CPU_MAX` | `1` / `3` | CPU autoscaler bounds |
| `MAAS_MODELS` | `auto` | Models to deploy (`auto`, `simulator`, `gpt-oss-20b`, `granite-tiny-gpu`, `all`, or a space-separated list) |
| `GITOPS_REPO_URL` / `GITOPS_BRANCH` | this repo / `main` | Repo + branch ArgoCD syncs from (see below) |

Validate your `.env` against the live cluster:

```bash
make validate-config
```

## Repository and branch selection

`make deploy` tells ArgoCD which repo + branch to sync from, via `GITOPS_REPO_URL` /
`GITOPS_BRANCH`. Two `.env`-friendly ways, by durability. (To bake the change into
tracked YAML for a permanent fork, see `make configure-repo` in [CLAUDE.md](../CLAUDE.md).)

### 1. Ephemeral — inline env var (recommended for PR/test runs)

No file edits, no commits. `scripts/deploy-apps.sh` reads `GITOPS_BRANCH` at runtime and
patches the ApplicationSets plus every child Application on the cluster:

```bash
git push origin my-feature-branch
GITOPS_BRANCH=my-feature-branch make deploy
GITOPS_BRANCH=my-feature-branch make sync
```

Works for later git-fetching ops too, e.g. `GITOPS_BRANCH=my-feature-branch make refresh-apps`.

### 2. Persistent — `.env` override

Put it in `.env` and every subsequent `make` picks it up:

```bash
cat >> .env <<EOF
GITOPS_BRANCH=my-feature-branch
GITOPS_REPO_URL=https://github.com/my-fork/rhoai-nightly
EOF
make deploy
```

For a permanent fork (committing the repo/branch change into tracked YAML via
`make configure-repo`), and for changing the RHOAI version or adding components, see
[CLAUDE.md](../CLAUDE.md) — those go beyond `.env`.
