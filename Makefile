# Makefile for RHOAI 3.2 Nightly GitOps
#
# Default workflow: Run targets individually and verify each step
# Autonomous workflow: make all

# Load .env file if it exists
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

.PHONY: help check gpu pull-secret icsp setup bootstrap status validate all clean

# Default target
help:
	@echo "RHOAI 3.2 Nightly GitOps"
	@echo ""
	@echo "Pre-GitOps Setup (run individually, verify each):"
	@echo "  make gpu          - Create GPU MachineSet (g5.2xlarge)"
	@echo "  make pull-secret  - Add quay.io/rhoai credentials"
	@echo "  make icsp         - Create ImageContentSourcePolicy"
	@echo "  make setup        - Run all pre-GitOps setup"
	@echo ""
	@echo "Credentials: Copy .env.example to .env and fill in values"
	@echo "             Or: QUAY_USER=x QUAY_TOKEN=y make pull-secret"
	@echo ""
	@echo "Bootstrap GitOps:"
	@echo "  make bootstrap    - Install GitOps operator + ArgoCD"
	@echo ""
	@echo "Validation:"
	@echo "  make check        - Verify cluster connection"
	@echo "  make status       - Show ArgoCD application status"
	@echo "  make validate     - Full cluster validation"
	@echo ""
	@echo "Autonomous:"
	@echo "  make all          - Run everything (setup + bootstrap)"
	@echo ""

# Verify cluster connection
check:
	@echo "Checking cluster connection..."
	@oc whoami --show-server
	@oc get nodes

# Pre-GitOps: GPU MachineSet
gpu:
	@chmod +x scripts/create-gpu-machineset.sh
	@scripts/create-gpu-machineset.sh
	@echo ""
	@echo "Verify GPU MachineSet:"
	@echo "  oc get machineset -n openshift-machine-api | grep gpu"
	@echo "  oc get machines -n openshift-machine-api | grep gpu"

# Pre-GitOps: Pull Secret (requires QUAY_USER and QUAY_TOKEN from .env or environment)
pull-secret:
ifndef QUAY_USER
	$(error QUAY_USER is not set. Create .env from .env.example or set env vars)
endif
ifndef QUAY_TOKEN
	$(error QUAY_TOKEN is not set. Create .env from .env.example or set env vars)
endif
	@chmod +x scripts/add-pull-secret.sh
	@scripts/add-pull-secret.sh

# Pre-GitOps: ICSP
icsp:
	@chmod +x scripts/create-icsp.sh
	@scripts/create-icsp.sh
	@echo ""
	@echo "Monitor node rollout:"
	@echo "  oc get nodes -w"
	@echo "  oc get mcp"

# All pre-GitOps setup
setup: gpu pull-secret icsp
	@echo ""
	@echo "Pre-GitOps setup complete!"

# Bootstrap GitOps
bootstrap:
	@chmod +x scripts/bootstrap-gitops.sh
	@scripts/bootstrap-gitops.sh

# Show ArgoCD status
status:
	@echo "ArgoCD Applications:"
	@oc get applications -n openshift-gitops 2>/dev/null || echo "ArgoCD not installed"
	@echo ""
	@echo "ApplicationSets:"
	@oc get applicationsets -n openshift-gitops 2>/dev/null || echo "No ApplicationSets"

# Full validation
validate:
	@echo "=== Cluster Info ==="
	@oc whoami --show-server
	@echo ""
	@echo "=== Nodes ==="
	@oc get nodes
	@echo ""
	@echo "=== GPU Nodes ==="
	@oc get nodes -l node-role.kubernetes.io/gpu 2>/dev/null || echo "No GPU nodes"
	@echo ""
	@echo "=== GitOps Operator ==="
	@oc get csv -n openshift-gitops-operator 2>/dev/null | grep gitops || echo "Not installed"
	@echo ""
	@echo "=== ArgoCD Applications ==="
	@oc get applications -n openshift-gitops 2>/dev/null || echo "ArgoCD not ready"
	@echo ""
	@echo "=== RHOAI Operator ==="
	@oc get csv -n redhat-ods-operator 2>/dev/null | grep rhods || echo "Not installed"
	@echo ""
	@echo "=== DataScienceCluster ==="
	@oc get datasciencecluster 2>/dev/null || echo "Not created"

# Full autonomous run
all: setup bootstrap
	@echo ""
	@echo "Full setup complete!"
	@echo "Next: Add components incrementally via git commits"

# Clean up (dangerous!)
clean:
	@echo "This will delete all ArgoCD applications and applicationsets!"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ]
	@oc delete applications --all -n openshift-gitops 2>/dev/null || true
	@oc delete applicationsets --all -n openshift-gitops 2>/dev/null || true
