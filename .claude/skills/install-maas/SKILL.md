---
name: install-maas
description: Install MaaS (Models as a Service) on a connected RHOAI cluster. Runs scripts/install-maas.sh with preflight checks, progress monitoring, and known-issue reporting.
argument-hint: "[--dry-run] [--force]"
allowed-tools: Bash(make *), Bash(oc *), Bash(mkdir *), Bash(tail *), Bash(echo *), Bash(ls *), Bash(LOGDIR=*), Bash(for *), Bash(date *), Bash(curl *), AskUserQuestion
---

# Install MaaS on Connected RHOAI Cluster

Install Models as a Service (MaaS) on a cluster that already has RHOAI deployed. This wraps `make maas` (which runs `scripts/install-maas.sh`) with preflight validation, progress monitoring, and known-issue reporting.

MaaS enables serving LLM models via a managed API with rate limiting and API key authentication.

## Prerequisites

- RHOAI operator installed with DataScienceCluster created
- DSC must have `modelsAsService.managementState: Managed` and `rawDeploymentServiceConfig: Headed`
- Authorino deployed in `kuadrant-system` namespace (installed by RHOAI operator)

## Arguments

Parse `$ARGUMENTS` for optional flags:
- `--dry-run` — preview what would be created without applying (passes `--dry-run` to script)
- `--force` — skip preflight checks and run install regardless

## Execution Model

### Log Directory

At the start of the install, create a timestamped log directory under `.tmp/logs/` (already gitignored):
```
LOGDIR=.tmp/logs/install-maas-$(date +%Y%m%d-%H%M%S)
mkdir -p $LOGDIR
```

### Rules for running commands:

1. **Run make maas in the background with log capture:**
   ```
   make maas 2>&1 | tee $LOGDIR/install-maas.log
   ```
   Use Bash `run_in_background: true` so Claude can continue monitoring.

2. **Monitor background task** by checking the log file with `tail -30 $LOGDIR/install-maas.log`. Check every 15-30 seconds.

3. **While the background task is running**, run monitoring commands in parallel:
   - `oc get deployment postgres -n redhat-ods-applications --no-headers 2>/dev/null || echo "PostgreSQL not yet deployed"`
   - `oc get gateway maas-default-gateway -n openshift-ingress --no-headers 2>/dev/null || echo "Gateway not yet created"`
   - `oc get gatewayclass openshift-default --no-headers 2>/dev/null || echo "GatewayClass not yet created"`
   - `oc get deployment maas-api -n redhat-ods-applications --no-headers 2>/dev/null || echo "maas-api not yet deployed"`
   - `oc get deployment maas-controller -n redhat-ods-applications --no-headers 2>/dev/null || echo "maas-controller not yet deployed"`

4. **Report progress to the user** after each monitoring check.

5. **Use timeout: 600000** (10 minutes) for any foreground commands.

6. **On failure**, tell the user the log file path so they can review the full output.

## Instructions

You MUST run this from the repository root.

### Phase 0: Preflight — Cluster Assessment

Unless `--force` was passed, verify the cluster is ready for MaaS. Run ALL of these checks in parallel:

```
oc whoami --show-server
oc get clusterversion -o jsonpath='{.items[0].status.desired.version}'
oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods || echo "No RHOAI CSV"
oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null || echo "No DSC or no modelsAsService"
oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.rawDeploymentServiceConfig}' 2>/dev/null || echo "No rawDeploymentServiceConfig"
oc get authorino authorino -n kuadrant-system --no-headers 2>/dev/null || echo "No Authorino"
oc get deployment postgres -n redhat-ods-applications --no-headers 2>/dev/null || echo "No PostgreSQL"
oc get gateway maas-default-gateway -n openshift-ingress --no-headers 2>/dev/null || echo "No Gateway"
oc get deployment maas-api -n redhat-ods-applications --no-headers 2>/dev/null || echo "No maas-api"
oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null
```

Based on the results, report to the user:
- Cluster URL, OCP version, RHOAI version
- DSC modelsAsService state and rawDeploymentServiceConfig
- Authorino status
- Whether MaaS appears already installed (PostgreSQL, Gateway, maas-api exist)
- Any blockers (missing RHOAI, missing Authorino, DSC not configured)

**Blockers that should STOP the install:**
- No RHOAI operator CSV
- No DataScienceCluster
- modelsAsService not set to Managed
- No Authorino in kuadrant-system

**If MaaS appears already installed** (PostgreSQL + Gateway + maas-api all exist), ask the user if they want to proceed. The script is idempotent so re-running is safe.

### Phase 1: Run Install

Run `make maas` in the background. The script handles five internal phases:
1. Preflight checks (cluster connection, RHOAI, DSC, Authorino)
2. Deploy PostgreSQL (secrets + deployment + PVC)
3. Create GatewayClass + Gateway
4. Configure Authorino SSL env vars
5. Validate (wait for maas-api, check health endpoint)

Monitor progress and report as each phase completes.

### Phase 2: Post-Install Validation

After the script completes, run additional validation:

```
oc get deployment postgres -n redhat-ods-applications
oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'
oc get deployment maas-api -n redhat-ods-applications --no-headers 2>/dev/null
oc get deployment maas-controller -n redhat-ods-applications --no-headers 2>/dev/null
oc get authpolicy -A -o wide --no-headers 2>/dev/null
```

Check the cluster domain and test the health endpoint:
```
DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
curl -sk -o /dev/null -w '%{http_code}' "https://maas.${DOMAIN}/maas-api/health"
```

### Phase 3: Known Issues Check

Check for the known AuthPolicy namespace bug (present in RHOAI 3.4.0-ea.2 and likely other builds):

```
oc get authpolicy gateway-default-auth -n redhat-ods-applications -o jsonpath='{.status.conditions[0]}' 2>/dev/null
```

If the AuthPolicy exists in `redhat-ods-applications` with `Accepted=False`, report the known upstream bug:

> **Known Issue: AuthPolicy namespace bug**
> The `gateway-default-auth` AuthPolicy is deployed to `redhat-ods-applications` instead of `openshift-ingress`. This is an upstream RHOAI operator bug — a name mismatch between the operator constant (`gateway-auth-policy`) and the manifest name (`gateway-default-auth`) prevents the namespace-fixing code from finding the resource.
>
> **Impact:** External requests through the MaaS gateway return HTTP 500/503. The maas-api itself is healthy internally.
>
> **Workaround:** Copy the AuthPolicy to the correct namespace:
> ```
> oc get authpolicy gateway-default-auth -n redhat-ods-applications -o yaml | \
>   sed 's/namespace: redhat-ods-applications/namespace: openshift-ingress/' | \
>   grep -v 'ownerReferences\|resourceVersion\|uid\|creationTimestamp' | \
>   oc apply -f -
> ```
>
> See `.tmp/maas-authpolicy-bug.md` for full details.

### Final Report

Summarize the installation result:
- Cluster URL and domain
- RHOAI version
- PostgreSQL: deployed / already existed
- GatewayClass: created / already existed
- Gateway: Programmed status
- Authorino SSL: configured / already configured
- maas-api: deployment status
- maas-controller: deployment status
- Health endpoint: HTTP status code
- MaaS API URL: `https://maas.<domain>`
- Any known issues detected (AuthPolicy bug, etc.)
- Log file location

## Uninstall

To remove MaaS resources created by this script, run:
```
make maas-uninstall
```

This removes PostgreSQL, Gateway, GatewayClass, Authorino SSL env vars, and associated secrets. It does NOT modify the DataScienceCluster or operator-managed resources.
