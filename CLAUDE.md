# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

This is a GitOps repository for deploying RHOAI 3.2 Nightly on OpenShift clusters. It uses:
- **Scripts** for pre-GitOps cluster setup (GPU, pull secrets, ICSP)
- **ApplicationSets** for GitOps-managed components
- **gitops-catalog** remote references with local patches

## Development Workflows

### Default: Incremental Development (Interactive)

**This is the default workflow.** Stop after each phase to allow testing and review.

```
Phase 0: Pre-GitOps Setup
  make gpu           → Wait for user to verify GPU node
  make pull-secret   → Wait for user to verify
  make icsp          → Wait for user to verify nodes restart

Phase 1: Bootstrap GitOps
  make bootstrap     → Wait for user to verify ArgoCD

Phase 2: Add Components (one at a time)
  Add NFD operator   → commit, push → verify sync
  Add NFD instance   → commit, push → verify sync
  Add NVIDIA operator → commit, push → verify sync
  ... etc
```

**Key principle**: After each step, STOP and ask the user to verify before continuing.

### Autonomous Workflow

Use only when explicitly requested with "run autonomously" or "don't stop".

```bash
make all            # Runs everything without stopping
```

## Common Commands

```bash
# Pre-GitOps setup (run individually, verify each)
make gpu            # Create GPU MachineSet
make pull-secret    # Add quay.io/rhoai credentials
make icsp           # Create ImageContentSourcePolicy

# Bootstrap GitOps
make bootstrap      # Install GitOps operator + ArgoCD + root app

# Validation
make validate       # Check cluster state
make status         # Show ArgoCD application status

# Full autonomous run (only when requested)
make all
```

## Repository Structure

```
rhoai-nightly/
├── scripts/
│   ├── create-gpu-machineset.sh
│   ├── add-pull-secret.sh
│   ├── create-icsp.sh
│   └── bootstrap-gitops.sh
├── bootstrap/
│   ├── gitops-operator/
│   ├── argocd-instance/
│   └── root-app.yaml
├── applicationsets/
│   ├── operators.yaml
│   └── instances.yaml
├── components/
│   ├── operators/        # Added incrementally
│   └── instances/        # Added incrementally
└── Makefile
```

## Adding Components

Components are added incrementally via git commits:

```bash
# 1. Create component directory
mkdir -p components/operators/nfd

# 2. Add kustomization.yaml
cat > components/operators/nfd/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/redhat-cop/gitops-catalog/nfd/operator/overlays/stable?ref=main
EOF

# 3. Commit and push
git add . && git commit -m "Add NFD operator" && git push

# 4. Verify ArgoCD syncs
oc get applications -n openshift-gitops
```

## gitops-catalog Pattern

This repo uses remote references to [redhat-cop/gitops-catalog](https://github.com/redhat-cop/gitops-catalog):

```yaml
# Reference remote base
resources:
  - https://github.com/redhat-cop/gitops-catalog/nfd/operator/overlays/stable?ref=main

# Add local customizations via patches
patches:
  - target:
      kind: Subscription
    path: my-patch.yaml
```

## Security Guidelines

**CRITICAL: This is a public repository. Never commit secrets.**

### Before Every Commit

Run these checks before committing:

```bash
# Scan for potential secrets
grep -r -i "password=\|token=\|auth.*:" --include="*.sh" --include="*.yaml" .

# Check for base64 encoded strings (potential secrets)
grep -r -E "[A-Za-z0-9+/]{40,}={0,2}" --include="*.sh" --include="*.yaml" .

# Review staged changes
git diff --staged
```

### Secret Handling Rules

1. **Credentials**: Always use environment variables, never hardcode
   ```bash
   # CORRECT
   --auth-basic="${QUAY_USER}:${QUAY_TOKEN}"

   # WRONG - never do this
   --auth-basic="user:actualpassword123"
   ```

2. **Files to never commit**:
   - `.env` files
   - `*credentials*` files
   - `*secret*` files (except references like `pull-secret` name)
   - Any file with actual tokens, passwords, or API keys

3. **Safe patterns** (these are OK):
   - Secret *names* like `userDataSecret:`, `credentialsSecret:`
   - References like `oc get secret/pull-secret`
   - Environment variable references like `${QUAY_TOKEN}`

### If a Secret is Accidentally Committed

1. **Do NOT just delete it** - it remains in git history
2. Delete the entire repository on GitHub
3. Remove local `.git` directory: `rm -rf .git`
4. Reinitialize: `git init`
5. Rotate the exposed credential immediately

### Pre-commit Checklist

Before running `git commit`:
- [ ] No hardcoded passwords/tokens in scripts
- [ ] No API keys in YAML files
- [ ] No base64-encoded secrets
- [ ] Environment variables used for all credentials
- [ ] `git diff --staged` reviewed for sensitive data
