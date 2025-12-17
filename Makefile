# Makefile for RHOAI 3.2 Nightly GitOps
#
# Default workflow: Run targets individually and verify each step
# Autonomous workflow: make all

# Load .env file if it exists
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

.PHONY: help check gpu cpu pull-secret icsp setup gitops deploy bootstrap status validate all clean undeploy configure-repo scale refresh sync sync-app sync-disable sync-enable refresh-apps dedicate-masters demos demos-delete

# Default target - run everything
.DEFAULT_GOAL := all

help:
	@echo "RHOAI 3.2 Nightly GitOps"
	@echo ""
	@echo "Pre-GitOps Setup (each step waits for completion):"
	@echo "  make pull-secret  - Add quay.io/rhoai credentials"
	@echo "  make icsp         - Create ICSP (waits for MCP update ~10-15 min)"
	@echo "  make gpu          - Create GPU MachineSet (waits for node Ready)"
	@echo "  make cpu          - Create CPU MachineSet m6a.4xlarge (waits for node Ready)"
	@echo "  make setup        - Run all above (except dedicate-masters)"
	@echo "  make dedicate-masters - Remove worker role from masters (optional)"
	@echo ""
	@echo "Credentials: Copy .env.example to .env and fill in values"
	@echo "             Or: QUAY_USER=x QUAY_TOKEN=y make pull-secret"
	@echo ""
	@echo "Bootstrap GitOps:"
	@echo "  make gitops       - Install GitOps operator + ArgoCD (waits for ready)"
	@echo "  make deploy       - Deploy root app (creates apps with sync DISABLED)"
	@echo "  make bootstrap    - Run gitops + deploy"
	@echo "  make sync         - Sync all apps one-by-one in dependency order (RECOMMENDED)"
	@echo "  make sync-app APP=<name> - Sync a single app (e.g., APP=nfd)"
	@echo ""
	@echo "Validation:"
	@echo "  make check        - Verify cluster connection"
	@echo "  make status       - Show ArgoCD application status"
	@echo "  make validate     - Full cluster validation"
	@echo "  make refresh      - Force pull latest nightly images"
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
	@echo "  make undeploy     - Remove ArgoCD apps with cascade deletion (keeps GitOps)"
	@echo "  make clean        - Full cleanup including pre-installed operators"
	@echo ""
	@echo "Autonomous:"
	@echo "  make all          - Run everything (setup + bootstrap)"
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

# Pre-GitOps: Pull Secret
pull-secret:
	@scripts/add-pull-secret.sh

# Pre-GitOps: ICSP (triggers node restart, waits for MCP update)
icsp:
	@scripts/create-icsp.sh

# All pre-GitOps setup (pull-secret, icsp, workers)
# Each script waits for its resources to be ready before returning
# CPU before GPU - cheaper instances provision faster
setup: pull-secret icsp cpu gpu
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
all: setup bootstrap sync
	@echo ""
	@echo "Full setup complete!"
	@echo "RHOAI 3.2 nightly is now deploying."

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

# Force refresh of nightly images
refresh:
	@echo "Refreshing RHOAI nightly images..."
	@echo "Restarting catalog pod..."
	@oc delete pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly 2>/dev/null || true
	@echo "Waiting for catalog pod to restart..."
	@sleep 5
	@oc wait --for=condition=Ready pod -n openshift-marketplace -l olm.catalogSource=rhoai-catalog-nightly --timeout=120s 2>/dev/null || true
	@echo "Restarting RHOAI operator..."
	@oc delete pod -n redhat-ods-operator -l name=rhods-operator 2>/dev/null || true
	@echo ""
	@echo "Refresh initiated! Operator will reconcile with latest images."
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
	@oc annotate application/$(APP) -n openshift-gitops \
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

# Refresh and sync all apps (one-time sync, does not change auto-sync setting)
# Use when auto-sync is disabled and you want to pull latest from git
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
