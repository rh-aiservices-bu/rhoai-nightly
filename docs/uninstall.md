# Uninstall

Tear down what you installed. Remove optional features first (MaaS, observability,
Eval Hub), then RHOAI itself. Every destructive target supports a dry run.

If the cluster came from [demo.redhat.com](demo-env.md), the simplest cleanup is to
let it **auto-destroy** or delete it from **My Services** — no teardown needed.

## Order of teardown

Remove in the reverse order you installed:

1. Observability — `make observability-uninstall`
2. MaaS models — `make maas-model-delete MODEL=all`
3. MaaS platform — `make maas-uninstall`
4. Eval Hub — `make evalhub-uninstall`
5. RHOAI — `make undeploy` then `make clean`

Steps 1–4 are independent; skip any you didn't install.

## Preview first (dry run)

```bash
scripts/uninstall-maas.sh --dry-run   # maas targets don't forward flags; call the script
make undeploy DRY_RUN=true
make clean DRY_RUN=true
```

## MaaS and observability

```bash
make observability-uninstall      # reverse-flip instance-rhoai overlay; cascade tears down
make maas-model-delete MODEL=all  # remove all deployed models
make maas-uninstall               # cascade-delete Gateway, PostgreSQL, secrets
```

`make maas-uninstall` deletes the `instance-maas` ArgoCD Application (which
cascade-deletes its Helm resources), removes the PostgreSQL secrets and Authorino SSL
env vars, and cleans up stale DNS records.

## Eval Hub

```bash
make evalhub-uninstall            # delete instance-evalhub Application
```

The `resources-finalizer.argocd.argoproj.io` finalizer cascade-prunes EvalHub, MLflow,
DSPA, and the `evalhub-tenant` namespace + RBAC.

## RHOAI

```bash
make undeploy     # remove ArgoCD apps only (keeps the GitOps operator)
make clean        # undeploy + remove leftover operators/CSVs
```

- **`make undeploy`** deletes the ArgoCD Applications with cascade deletion — ArgoCD
  removes the managed resources before the apps disappear. The GitOps operator and
  ArgoCD instance stay.
- **`make clean`** runs `undeploy` first, then removes operators and CSVs that were
  pre-installed outside the ApplicationSets.

Both prompt for confirmation. To skip the prompt in automation:

```bash
make clean SKIP_CONFIRM=true
```

## With Claude Code

```
/uninstall-rhoai             # runs undeploy + clean with assessment + progress
/uninstall-rhoai --dry-run
/install-evalhub --uninstall # remove Eval Hub
```

See [Install with Claude](install-claude.md).

## Verify it's gone

```bash
oc get applications.argoproj.io -n openshift-gitops    # should be empty (or just what you kept)
oc get csv -A | grep -E 'rhoai|rhods|nvidia|nfd'       # no leftover CSVs after clean
oc get datascienceclusters -A                          # none
```

> Removing the GitOps operator/ArgoCD itself is intentionally **not** automated — if you
> want a completely bare cluster, uninstall the OpenShift GitOps operator from the
> OperatorHub UI after `make clean`, or just delete the demo.redhat.com cluster.
