# Makefile for RHOAI 3.2 Nightly GitOps
#
# Default workflow: Run targets individually and verify each step
# Autonomous workflow: make all

# Load .env file if it exists
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

.PHONY: help check gpu cpu pull-secret icsp setup bootstrap status validate all clean configure-repo

# Default target
help:
	@echo "RHOAI 3.2 Nightly GitOps"
	@echo ""
	@echo "Pre-GitOps Setup (run individually, verify each):"
	@echo "  make gpu          - Create GPU MachineSet (g5.2xlarge)"
	@echo "  make cpu          - Create CPU worker MachineSet (m5.4xlarge)"
	@echo "  make pull-secret  - Add quay.io/rhoai credentials"
	@echo "  make icsp         - Create ImageContentSourcePolicy"
	@echo "  make setup        - Run all pre-GitOps setup (gpu + pull-secret + icsp)"
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
	@chmod +x scripts/create-gpu-machineset.sh
	@scripts/create-gpu-machineset.sh

# Pre-GitOps: CPU Worker MachineSet
cpu:
	@chmod +x scripts/create-cpu-machineset.sh
	@scripts/create-cpu-machineset.sh

# Pre-GitOps: Pull Secret
pull-secret:
	@chmod +x scripts/add-pull-secret.sh
	@scripts/add-pull-secret.sh

# Pre-GitOps: ICSP
icsp:
	@chmod +x scripts/create-icsp.sh
	@scripts/create-icsp.sh

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
	@chmod +x scripts/status.sh
	@scripts/status.sh

# Full validation
validate:
	@chmod +x scripts/validate.sh
	@scripts/validate.sh

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

# Configure repo URLs for forks
configure-repo:
	@chmod +x scripts/configure-repo.sh
	@scripts/configure-repo.sh
