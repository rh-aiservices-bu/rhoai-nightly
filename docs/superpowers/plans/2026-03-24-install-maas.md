# Install MaaS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add MaaS (Models as a Service) support via a script, GitOps manifests, and a Claude Code skill.

**Architecture:** GitOps manifests provide the declarative base (postgres, gateway, DSC changes). An imperative script handles cluster-specific setup (secret generation, gateway domain detection, Authorino SSL env vars). A skill wraps the script with monitoring.

**Tech Stack:** Bash, Kustomize, OpenShift CLI (`oc`), ArgoCD, Gateway API

**Spec:** `docs/superpowers/specs/2026-03-24-install-maas-design.md`

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `scripts/install-maas.sh` | Imperative MaaS installer (postgres, gateway, authorino SSL, validation) |
| `components/instances/maas-instance/base/kustomization.yaml` | Kustomize entrypoint for generic postgres resources |
| `components/instances/maas-instance/base/postgres-deployment.yaml` | PostgreSQL 15 Deployment |
| `components/instances/maas-instance/base/postgres-service.yaml` | PostgreSQL ClusterIP Service |
| `components/instances/maas-instance/base/postgres-pvc.yaml` | 1Gi PVC for postgres data |
| `components/instances/maas-instance/overlays/rhoaibu-cluster-nightly/kustomization.yaml` | bu-nightly overlay adding gateway |
| `components/instances/maas-instance/overlays/rhoaibu-cluster-nightly/maas-gateway.yaml` | Gateway with hardcoded bu-nightly domain |
| `.claude/skills/install-maas/SKILL.md` | Claude Code skill definition |

### Modified Files

| File | Change |
|------|--------|
| `components/instances/rhoai-instance/base/datasciencecluster.yaml` | `rawDeploymentServiceConfig: Headed`, add `modelsAsService.managementState: Managed` |
| `components/argocd/apps/cluster-oper-instances-appset.yaml` | Add `instance-maas` entry |
| `Makefile` | Add `maas` target |
| `.claude/settings.local.json` | Add `Skill(install-maas)` to allow list |

---

## Task 1: Create feature branch

**Files:** None (git only)

- [ ] **Step 1: Create and push feature branch**

```bash
git checkout -b feature/install-maas
git push -u origin feature/install-maas
```

- [ ] **Step 2: Verify branch**

```bash
git branch --show-current
```

Expected: `feature/install-maas`

---

## Task 2: GitOps - Update DSC for MaaS

**Files:**
- Modify: `components/instances/rhoai-instance/base/datasciencecluster.yaml:17-21`

- [ ] **Step 1: Update DSC**

Change `rawDeploymentServiceConfig` from `Headless` to `Headed` and add `modelsAsService` block under `kserve`:

```yaml
    kserve:
      managementState: Managed
      nim:
        managementState: Managed
      rawDeploymentServiceConfig: Headed
      modelsAsService:
        managementState: Managed
```

Note: preserve all other fields (`wva`, etc.) that may exist in the actual file.

- [ ] **Step 2: Validate kustomize builds**

```bash
oc kustomize components/instances/rhoai-instance/base/
```

Expected: YAML output with the updated DSC, no errors.

- [ ] **Step 3: Commit**

```bash
git add components/instances/rhoai-instance/base/datasciencecluster.yaml
git commit -m "Enable MaaS in DSC: Headed + modelsAsService Managed"
```

---

## Task 3: GitOps - Create maas-instance base (postgres)

**Files:**
- Create: `components/instances/maas-instance/base/kustomization.yaml`
- Create: `components/instances/maas-instance/base/postgres-deployment.yaml`
- Create: `components/instances/maas-instance/base/postgres-service.yaml`
- Create: `components/instances/maas-instance/base/postgres-pvc.yaml`

- [ ] **Step 1: Create directory**

```bash
mkdir -p components/instances/maas-instance/base
```

- [ ] **Step 2: Create kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

commonAnnotations:
  argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true

resources:
  - postgres-deployment.yaml
  - postgres-service.yaml
  - postgres-pvc.yaml
```

- [ ] **Step 3: Create postgres-deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  labels:
    app: postgres
    app.kubernetes.io/name: maas
    app.kubernetes.io/component: database
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
        app.kubernetes.io/name: maas
        app.kubernetes.io/component: database
    spec:
      containers:
        - name: postgres
          image: postgres:15-alpine
          ports:
            - containerPort: 5432
          envFrom:
            - secretRef:
                name: postgres-secret
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: postgres-storage
              mountPath: /var/lib/postgresql/data
          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          securityContext:
            allowPrivilegeEscalation: false
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - pg_isready -U $POSTGRES_USER -d $POSTGRES_DB
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - pg_isready -U $POSTGRES_USER -d $POSTGRES_DB
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: postgres-storage
          persistentVolumeClaim:
            claimName: postgres-pvc
```

- [ ] **Step 4: Create postgres-service.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  labels:
    app: postgres
    app.kubernetes.io/name: maas
    app.kubernetes.io/component: database
spec:
  ports:
    - port: 5432
      targetPort: 5432
      protocol: TCP
      name: postgres
  selector:
    app: postgres
  type: ClusterIP
```

- [ ] **Step 5: Create postgres-pvc.yaml**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  labels:
    app: postgres
    app.kubernetes.io/name: maas
    app.kubernetes.io/component: database
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

- [ ] **Step 6: Validate kustomize builds**

```bash
oc kustomize components/instances/maas-instance/base/
```

Expected: Combined YAML with Deployment, Service, PVC. No errors.

- [ ] **Step 7: Commit**

```bash
git add components/instances/maas-instance/
git commit -m "Add maas-instance base: PostgreSQL deployment, service, PVC"
```

---

## Task 4: GitOps - Create bu-nightly overlay (gateway)

**Files:**
- Create: `components/instances/maas-instance/overlays/rhoaibu-cluster-nightly/kustomization.yaml`
- Create: `components/instances/maas-instance/overlays/rhoaibu-cluster-nightly/maas-gateway.yaml`

The bu-nightly cluster domain is obtained from the current cluster config. For the permanent GitOps config, we need the actual bu-nightly cluster domain (not the test cluster). Since we're testing on a different cluster, use the test cluster domain for now and update when merging to main.

- [ ] **Step 1: Create overlay directory**

```bash
mkdir -p components/instances/maas-instance/overlays/rhoaibu-cluster-nightly
```

- [ ] **Step 2: Detect test cluster domain and cert name**

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
CERT_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
[ -z "$CERT_NAME" ] && CERT_NAME="router-certs-default"
echo "Domain: $CLUSTER_DOMAIN"
echo "Cert: $CERT_NAME"
```

- [ ] **Step 3: Create maas-gateway.yaml**

Use the detected domain and cert name. Example (values will vary per cluster):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: maas-default-gateway
  namespace: openshift-ingress
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
  labels:
    app.kubernetes.io/name: maas
    app.kubernetes.io/component: gateway
spec:
  gatewayClassName: openshift-default
  listeners:
    - name: http
      hostname: "maas.<CLUSTER_DOMAIN>"
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      hostname: "maas.<CLUSTER_DOMAIN>"
      port: 443
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: All
      tls:
        certificateRefs:
          - group: ""
            kind: Secret
            name: <CERT_NAME>
        mode: Terminate
```

Replace `<CLUSTER_DOMAIN>` and `<CERT_NAME>` with the actual detected values.

- [ ] **Step 4: Create kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base
  - maas-gateway.yaml
```

- [ ] **Step 5: Validate kustomize builds**

```bash
oc kustomize components/instances/maas-instance/overlays/rhoaibu-cluster-nightly/
```

Expected: Combined YAML with postgres resources + gateway. No errors.

- [ ] **Step 6: Commit**

```bash
git add components/instances/maas-instance/overlays/
git commit -m "Add maas-instance bu-nightly overlay with Gateway"
```

---

## Task 5: GitOps - Update ApplicationSet and Makefile

**Files:**
- Modify: `components/argocd/apps/cluster-oper-instances-appset.yaml`
- Modify: `Makefile`

- [ ] **Step 1: Add maas-instance to ApplicationSet**

Add this entry to the `elements` list in `cluster-oper-instances-appset.yaml`, after the `instance-nfs` entry:

```yaml
          - cluster: local
            values:
              name: instance-maas
              path: components/instances/maas-instance/overlays/rhoaibu-cluster-nightly
              namespace: openshift-gitops
```

- [ ] **Step 2: Add maas target to Makefile**

Add after the `dedicate-masters` target (before the `demos` target):

```makefile
# Install MaaS (Models as a Service)
maas:
	@scripts/install-maas.sh
```

Also add `maas` to the `.PHONY` list at the top.

Add a help entry in the `help` target (after the "Demos" section):

```
	@echo "MaaS (Models as a Service):"
	@echo "  make maas         - Install MaaS (PostgreSQL, Gateway, Authorino TLS)"
	@echo ""
```

- [ ] **Step 3: Commit**

```bash
git add components/argocd/apps/cluster-oper-instances-appset.yaml Makefile
git commit -m "Add maas-instance to ApplicationSet and Makefile target"
```

---

## Task 6: Create install-maas.sh script

**Files:**
- Create: `scripts/install-maas.sh`

This is the largest task. The script follows the same conventions as `scripts/deploy-apps.sh`: `set -euo pipefail`, color logging functions, argument parsing, dry-run support, idempotent checks.

- [ ] **Step 1: Create the script**

Create `scripts/install-maas.sh` with these sections:

**Header and logging** (match `deploy-apps.sh` pattern):
- Shebang, description, usage
- `set -euo pipefail`
- `SCRIPT_DIR` / `REPO_ROOT`
- Color constants and `log_info`, `log_warn`, `log_step`, `log_error` functions
- `DRY_RUN` flag, argument parsing (`--dry-run`, `-h`/`--help`)

**Phase 1 - Preflight:**
- `log_step "Phase 1: Preflight checks"`
- Verify `oc` connection: `oc whoami --show-server`
- Check RHOAI CSV: `oc get csv -n redhat-ods-operator --no-headers | grep rhods`
- Check DSC exists: `oc get datasciencecluster default-dsc`
- Check DSC has modelsAsService Managed: `oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}'` — warn if not `Managed`
- Check Authorino: `oc get authorino authorino -n kuadrant-system`
- Detect `CLUSTER_DOMAIN`: `oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'`
- Detect `CERT_NAME`: from ingresscontroller, fallback `router-certs-default`
- Set `NAMESPACE=redhat-ods-applications`
- Log all detected values

**Phase 2 - Deploy PostgreSQL:**
- `log_step "Phase 2: Deploy PostgreSQL"`
- Check if postgres deployment exists: `oc get deployment postgres -n $NAMESPACE`. If exists, `log_info "PostgreSQL already deployed, skipping"` and skip.
- Generate password: `POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)`
- Create `postgres-secret`:
  ```bash
  oc create secret generic postgres-secret \
    -n "$NAMESPACE" \
    --from-literal=POSTGRES_USER=maas \
    --from-literal=POSTGRES_DB=maas \
    --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
  ```
- Create `maas-db-config`:
  ```bash
  oc create secret generic maas-db-config \
    -n "$NAMESPACE" \
    --from-literal=DB_CONNECTION_URL="postgresql://maas:${POSTGRES_PASSWORD}@postgres.${NAMESPACE}.svc:5432/maas?sslmode=disable"
  ```
- Apply kustomize base: `oc apply -k "$REPO_ROOT/components/instances/maas-instance/base/" -n "$NAMESPACE"`
- Wait for deployment: `oc rollout status deployment/postgres -n "$NAMESPACE" --timeout=120s`

**Phase 3 - Create Gateway:**
- `log_step "Phase 3: Create MaaS Gateway"`
- Check if gateway exists: `oc get gateway maas-default-gateway -n openshift-ingress`. If exists, skip.
- Generate and apply Gateway YAML via heredoc using `$CLUSTER_DOMAIN` and `$CERT_NAME`
- Wait for Gateway Programmed: `oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=120s`

**Phase 4 - Configure Authorino SSL:**
- `log_step "Phase 4: Configure Authorino SSL env vars"`
- Check if env vars already set: `oc get deployment authorino -n kuadrant-system -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'` — if contains `SSL_CERT_FILE`, skip.
- Set env vars:
  ```bash
  oc -n kuadrant-system set env deployment/authorino \
    SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
  ```

**Phase 5 - Validate:**
- `log_step "Phase 5: Validate MaaS deployment"`
- Wait for maas-api deployment: poll with timeout 300s for `oc get deployment maas-api -n $NAMESPACE`
- Once found: `oc rollout status deployment/maas-api -n "$NAMESPACE" --timeout=180s`
- Check Gateway: `oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'`
- Test health endpoint: `curl -sk -o /dev/null -w '%{http_code}' "https://maas.${CLUSTER_DOMAIN}/maas-api/health"` — expect 401 (auth working)
- Print summary: MaaS URL, component statuses

**Dry-run handling:** Wrap all mutating commands (`oc create`, `oc apply`, `oc set env`, `oc wait`) in a helper:
```bash
run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/install-maas.sh
```

- [ ] **Step 3: Test dry-run locally**

```bash
scripts/install-maas.sh --dry-run
```

Expected: All phases print `[DRY RUN]` messages, no resources created.

- [ ] **Step 4: Commit**

```bash
git add scripts/install-maas.sh
git commit -m "Add install-maas.sh script for MaaS setup"
```

---

## Task 7: Push branch and point ArgoCD at feature branch

**Files:** None (git + cluster operations)

- [ ] **Step 1: Push all commits**

```bash
git push origin feature/install-maas
```

- [ ] **Step 2: Point ArgoCD apps at the feature branch**

The ApplicationSet uses `create-only`, so we need to patch existing apps individually. For the DSC change to take effect, patch `instance-rhoai`:

```bash
oc patch application.argoproj.io/instance-rhoai -n openshift-gitops --type=merge \
  -p '{"spec":{"source":{"targetRevision":"feature/install-maas"}}}'
```

Then apply the updated ApplicationSet so the new `instance-maas` app is created with the feature branch:

```bash
oc apply -f components/argocd/apps/cluster-oper-instances-appset.yaml
```

- [ ] **Step 3: Sync rhoai instance to pick up DSC changes**

```bash
make sync-app APP=instance-rhoai
```

- [ ] **Step 4: Verify DSC updated on cluster**

```bash
oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}'
```

Expected: `Managed`

```bash
oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.rawDeploymentServiceConfig}'
```

Expected: `Headed`

---

## Task 8: Test install-maas.sh on the cluster

**Files:** None (testing)

- [ ] **Step 1: Create postgres secrets manually first**

The ArgoCD maas-instance app will try to deploy postgres but will fail without the secret. Create it before running the script to test the "secrets already exist" path, OR let the script create it.

For testing the script end-to-end, ensure no MaaS resources exist yet:

```bash
oc get deployment postgres -n redhat-ods-applications 2>/dev/null && echo "EXISTS" || echo "CLEAN"
oc get gateway maas-default-gateway -n openshift-ingress 2>/dev/null && echo "EXISTS" || echo "CLEAN"
oc get secret postgres-secret -n redhat-ods-applications 2>/dev/null && echo "EXISTS" || echo "CLEAN"
```

- [ ] **Step 2: Run the script**

```bash
make maas
```

Watch for each phase to complete successfully.

- [ ] **Step 3: Validate deployment**

```bash
oc get deployment postgres -n redhat-ods-applications
oc get deployment maas-api -n redhat-ods-applications
oc get gateway maas-default-gateway -n openshift-ingress
oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'
```

Expected: postgres Running, maas-api Running (may take a few minutes), Gateway Programmed=True.

- [ ] **Step 4: Test MaaS API endpoint**

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
curl -sk -o /dev/null -w '%{http_code}' "https://maas.${CLUSTER_DOMAIN}/maas-api/health"
```

Expected: `401` (auth is working, rejecting unauthenticated requests)

- [ ] **Step 5: Test idempotency — re-run the script**

```bash
make maas
```

Expected: All phases skip with "already exists" messages. No errors.

---

## Task 9: Create install-maas skill

**Files:**
- Create: `.claude/skills/install-maas/SKILL.md`
- Modify: `.claude/settings.local.json`

- [ ] **Step 1: Create skill directory**

```bash
mkdir -p .claude/skills/install-maas
```

- [ ] **Step 2: Create SKILL.md**

Follow the pattern from `uninstall-rhoai/SKILL.md`. The skill calls `make maas` with background execution and monitoring. Content should include:

- Frontmatter: name, description, argument-hint, allowed-tools (matching existing pattern)
- Execution model: log directory, background execution, monitoring rules
- Preflight: cluster checks (RHOAI CSV, DSC, Authorino, existing MaaS)
- Run: `make maas 2>&1 | tee $LOGDIR/install-maas.log` in background
- Monitor: postgres deployment, gateway, maas-api deployment
- Final report: MaaS URL, component statuses, log location

- [ ] **Step 3: Add skill to settings.local.json**

Add `"Skill(install-maas)"` to the `permissions.allow` array in `.claude/settings.local.json`.

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/install-maas/SKILL.md .claude/settings.local.json
git commit -m "Add install-maas skill"
```

- [ ] **Step 5: Push**

```bash
git push origin feature/install-maas
```

---

## Task 10: Cleanup and PR preparation

**Files:** None

- [ ] **Step 1: Update overlay with bu-nightly domain**

If the test cluster domain differs from bu-nightly, update the gateway YAML in the overlay to use the actual bu-nightly domain before merging. This may be done in a follow-up commit on the PR.

- [ ] **Step 2: Reset ArgoCD to main (on test cluster)**

```bash
oc patch application.argoproj.io/instance-rhoai -n openshift-gitops --type=merge \
  -p '{"spec":{"source":{"targetRevision":"main"}}}'
```

- [ ] **Step 3: Create PR**

```bash
gh pr create --title "Add MaaS installation support" --body "$(cat <<'EOF'
## Summary
- Add `scripts/install-maas.sh` for imperative MaaS installation
- Add `maas-instance` GitOps component (PostgreSQL + Gateway)
- Update DSC with `Headed` + `modelsAsService: Managed`
- Add `install-maas` Claude Code skill
- Add `make maas` Makefile target

## Design
See `docs/superpowers/specs/2026-03-24-install-maas-design.md`

## Test plan
- [ ] Dry-run passes: `scripts/install-maas.sh --dry-run`
- [ ] Full install on test cluster: `make maas`
- [ ] Idempotent re-run succeeds
- [ ] maas-api deployment comes up healthy
- [ ] Health endpoint returns 401
- [ ] GitOps sync works (DSC changes applied via ArgoCD)
EOF
)"
```
