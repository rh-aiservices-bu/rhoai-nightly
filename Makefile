# Makefile for RHOAI 3.x Nightly GitOps
#
# Default workflow: Run targets individually and verify each step
# Autonomous workflow: make all

# Load .env file if it exists
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

.PHONY: help check gpu cpu icsp setup infra secrets gitops deploy bootstrap status validate all clean undeploy configure-repo scale refresh restart-catalog sync sync-app sync-disable sync-enable refresh-apps dedicate-masters demos demos-delete

# Default target - run everything
.DEFAULT_GOAL := all

help:
	@echo "RHOAI 3.x Nightly GitOps"
	@echo ""
	@echo "Autonomous (recommended for clean clusters):"
	@echo "  make all          - Full setup: infra → secrets → gitops → deploy → sync"
	@echo ""
	@echo "Phase 1: Infrastructure"
	@echo "  make infra        - Run icsp, cpu, gpu (no pull-secret, handled by secrets)"
	@echo "  make icsp         - Create ICSP (configure registry mirror)"
	@echo "  make gpu          - Create GPU MachineSet (waits for node Ready)"
	@echo "  make cpu          - Create CPU MachineSet m6a.4xlarge (waits for node Ready)"
	@echo "  make dedicate-masters - Remove worker role from masters (optional)"
	@echo ""
	@echo "Phase 2: Secrets"
	@echo "  make secrets      - Setup pull-secret (auto-detects mode)"
	@echo "                      Mode A: QUAY_USER/QUAY_TOKEN set → manual credentials"
	@echo "                      Mode B: Bootstrap repo access → External Secrets"
	@echo ""
	@echo "Phase 3: GitOps"
	@echo "  make gitops       - Install GitOps operator + ArgoCD (waits for ready)"
	@echo ""
	@echo "Phase 4-5: Deploy and Sync"
	@echo "  make deploy       - Deploy root app (creates apps with sync DISABLED)"
	@echo "  make sync         - Sync all apps one-by-one in dependency order"
	@echo "  make sync-app APP=<name> - Sync a single app (e.g., APP=nfd)"
	@echo ""
	@echo "Shortcuts:"
	@echo "  make setup        - Run infra + secrets (pre-GitOps setup)"
	@echo "  make bootstrap    - Run gitops + deploy"
	@echo ""
	@echo "Validation:"
	@echo "  make check        - Verify cluster connection"
	@echo "  make status       - Show ArgoCD application status"
	@echo "  make validate     - Full cluster validation"
	@echo "  make refresh      - Refresh all apps from git (hard refresh, no sync)"
	@echo "  make restart-catalog - Restart catalog pod and operator (force image pull)"
	@echo ""
	@echo "ArgoCD Sync Control:"
	@echo "  make sync-disable - Disable auto-sync on all apps (for manual changes)"
	@echo "  make sync-enable  - Re-enable auto-sync on all apps"
	@echo "  make refresh-apps - Refresh and sync all apps (one-time, keeps current sync setting)"
	@echo ""
	@echo "Demos (optional):"
	@echo "  make demos        - Deploy demos ApplicationSet (ai-bu-shared namespace, etc.)"
	@echo "  make demos-delete - Remove demos ApplicationSet and apps"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean        - Full cleanup (runs undeploy + removes leftover operators)"
	@echo "  make undeploy     - Remove ArgoCD apps only (keeps GitOps operator)"
	@echo ""
	@echo "Scaling:"
	@echo "  make scale NAME=<machineset> REPLICAS=<N|+N|-N>"
	@echo "                      Scale a MachineSet (e.g., REPLICAS=2 or REPLICAS=+1)"
	@echo ""
	@echo "Configuration (for forks):"
	@echo "  make configure-repo - Update repo URLs in applicationsets"
	@echo "                        Set GITOPS_REPO_URL and GITOPS_BRANCH in .env"
	@echo ""

# Verify cluster connection
check:
	@echo "Checking cluster connection..."
	@oc whoami --show-server
	@oc get nodes

# Pre-GitOps: GPU MachineSet
gpu:
	@scripts/create-gpu-machineset.sh

# Pre-GitOps: CPU Worker MachineSet
cpu:
	@scripts/create-cpu-machineset.sh

# Pre-GitOps: ICSP (configure registry mirror)
icsp:
	@scripts/create-icsp.sh

# Infrastructure setup (icsp, workers - no pull-secret, handled by secrets target)
# Each script waits for its resources to be ready before returning
# CPU before GPU - cheaper instances provision faster
infra: icsp cpu gpu
	@echo ""
	@echo "Infrastructure setup complete!"

# Secrets - auto-detects mode (manual credentials or External Secrets)
secrets:
	@scripts/setup-secrets.sh

# All pre-GitOps setup (infra + secrets)
setup: infra secrets
	@echo ""
	@echo "Pre-GitOps setup complete!"

# Install GitOps operator and ArgoCD
gitops:
	@scripts/install-gitops.sh

# Deploy root application (triggers all GitOps syncs)
deploy:
	@scripts/deploy-apps.sh

# Bootstrap GitOps (install + deploy)
bootstrap: gitops deploy

# Show ArgoCD status
status:
	@scripts/status.sh

# Full validation
validate:
	@scripts/validate.sh

# Full autonomous run
# Workflow: setup (infra + secrets) → bootstrap (gitops + deploy) → sync
all: setup bootstrap sync
	@echo ""
	@echo "Full setup complete!"
	@echo "RHOAI 3.x nightly is now deploying."

# Remove ArgoCD apps with cascade deletion (keeps GitOps operator)
# ArgoCD deletes managed resources before removing the app
# Usage: make undeploy [DRY_RUN=true] [SKIP_CONFIRM=true]
undeploy:
	@scripts/undeploy.sh $(if $(DRY_RUN),--dry-run) $(if $(SKIP_CONFIRM),-y)

# Full cleanup including pre-installed operators
# Chains: undeploy -> clean
# Usage: make clean [DRY_RUN=true] [SKIP_CONFIRM=true]
clean: undeploy
	@scripts/clean.sh $(if $(DRY_RUN),--dry-run) $(if $(SKIP_CONFIRM),-y)

# Configure repo URLs for forks
configure-repo:
	@scripts/configure-repo.sh

# Scale a MachineSet
scale:
	@scripts/scale-machineset.sh --name "$(NAME)" --replicas "$(REPLICAS)"

# GitOps refresh - pull latest from git without triggering sync
# Use this to update ArgoCD's view of git state
refresh:
	@echo "Refreshing all apps from git (hard refresh)..."
	@oc get applications.argoproj.io -n openshift-gitops -o name | \
	  xargs -I {} oc annotate {} -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
	@echo "All apps refreshed from git."
	@echo "Apps will show OutOfSync if git differs from cluster."
	@echo "Run 'make sync' to apply changes, or 'make status' to check."

# Restart catalog and operator pods to force image pull
# Use after updating catalog image and syncing from git
restart-catalog:
	@echo "Restarting RHOAI catalog and operator pods..."
	@echo "Restarting catalog pod..."
	@oc delete pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly 2>/dev/null || true
	@echo "Waiting for catalog pod to restart..."
	@sleep 5
	@oc wait --for=condition=Ready pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly --timeout=120s 2>/dev/null || true
	@echo "Restarting RHOAI operator..."
	@oc delete pod -n redhat-ods-operator -l name=rhods-operator 2>/dev/null || true
	@echo ""
	@echo "Pods restarted. Operator will reconcile with latest images."
	@echo "Monitor with: oc get pods -n redhat-ods-operator -w"

# Sync all apps one-by-one in dependency order (RECOMMENDED)
sync:
	@scripts/sync-apps.sh

# Sync a single app and trigger immediate sync
sync-app:
	@echo "Enabling sync for $(APP)..."
	@oc patch application.argoproj.io/$(APP) -n openshift-gitops --type=merge \
	  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
	@echo "Triggering sync..."
	@oc annotate application.argoproj.io/$(APP) -n openshift-gitops \
	  argocd.argoproj.io/refresh=normal --overwrite
	@echo "Sync enabled and triggered for $(APP)"

# Disable auto-sync on all ArgoCD applications
sync-disable:
	@echo "Disabling auto-sync on all ArgoCD applications..."
	@oc get applications.argoproj.io -n openshift-gitops -o name | xargs -I {} oc patch {} -n openshift-gitops --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
	@echo "Auto-sync disabled. You can now make manual changes."
	@echo "Re-enable with: make sync-enable"

# Re-enable auto-sync on all ArgoCD applications
sync-enable:
	@echo "Re-enabling auto-sync on all ArgoCD applications..."
	@oc get applications.argoproj.io -n openshift-gitops -o name | xargs -I {} oc patch {} -n openshift-gitops --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
	@echo "Auto-sync re-enabled."

# Refresh from git AND sync all apps (one-time, does not change auto-sync setting)
# Use when auto-sync is disabled and you want to apply latest from git
refresh-apps:
	@echo "Refreshing all apps from git..."
	@oc get applications.argoproj.io -n openshift-gitops -o name | \
	  xargs -I {} oc annotate {} -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
	@echo "Triggering sync on all apps..."
	@oc get applications.argoproj.io -n openshift-gitops -o name | \
	  xargs -I {} oc patch {} -n openshift-gitops --type=merge \
	    -p '{"operation":{"initiatedBy":{"username":"make"},"sync":{"prune":true}}}'
	@echo "All apps refreshed and syncing."

# Remove worker role from master nodes (run after workers are Ready)
dedicate-masters:
	@echo "Checking for Ready worker nodes..."
	@WORKERS=$$(oc get nodes -l node-role.kubernetes.io/worker,!node-role.kubernetes.io/master --no-headers 2>/dev/null | grep -c " Ready" || echo 0); \
	if [ "$$WORKERS" -eq 0 ]; then \
		echo "ERROR: No dedicated worker nodes are Ready. Create workers first with 'make gpu' or 'make cpu'"; \
		exit 1; \
	fi; \
	echo "Found $$WORKERS Ready worker node(s)"
	@echo "Removing worker role from master nodes..."
	@oc label nodes -l node-role.kubernetes.io/master node-role.kubernetes.io/worker- 2>/dev/null || true
	@echo "Master nodes are now dedicated (no longer schedulable for regular workloads)"
	@oc get nodes

# Deploy demos ApplicationSet (optional)
demos:
	@echo "Deploying demos ApplicationSet..."
	@oc apply -f components/argocd/apps/cluster-demos-appset.yaml
	@echo "Demos ApplicationSet deployed. Syncing demo apps..."
	@sleep 3
	@oc get applications.argoproj.io -n openshift-gitops -l app.kubernetes.io/instance=cluster-demos-applicationset 2>/dev/null || \
	  oc get applications.argoproj.io -n openshift-gitops | grep demo || echo "Waiting for apps to be created..."

# Remove demos ApplicationSet and its apps
demos-delete:
	@echo "Removing demos ApplicationSet..."
	@oc delete applicationset cluster-demos-applicationset -n openshift-gitops --cascade=foreground 2>/dev/null || true
	@echo "Demos removed."
