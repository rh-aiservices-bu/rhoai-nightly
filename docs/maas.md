# MaaS (Models as a Service)

MaaS provides API-key management, subscriptions, and rate limiting for LLM inference
services on RHOAI. It uses a hybrid GitOps + imperative approach: a Helm chart for the
cluster-specific Gateway and PostgreSQL, plus `install-maas.sh` for the bits that can't
be declarative (generated secrets, Authorino SSL env vars).

`make all` installs the MaaS **platform** automatically. Models and observability are
separate, deliberate steps.

## What gets deployed

| Component | Managed by | Description |
|-----------|------------|-------------|
| PostgreSQL | Helm chart (ArgoCD) | API-key storage. 20Gi PVC — size/`storageClassName` configurable via Helm values `postgres.persistence.size` / `postgres.persistence.storageClassName` (empty = cluster default). |
| Gateway + GatewayClass | Helm chart (ArgoCD) | LoadBalancer gateway for MaaS traffic. |
| PostgreSQL secrets | `install-maas.sh` | Generated password, DB connection URL. |
| Authorino SSL | `install-maas.sh` | Env vars for TLS trust. |
| maas-api, maas-controller | RHOAI operator | Deployed automatically when the DSC has `modelsAsService: Managed`. |
| UWM | `make uwm` (part of `make infra`) | Prerequisite for scraping MaaS metrics. |
| TelemetryPolicy + Istio Telemetry | `instance-maas-observability` (ArgoCD) | Per-subscription/model/user metric labels. Added by `make observability`. |
| Observability cascade (Kuadrant, ServiceMonitors, Perses/Tempo/OTel) | `make observability` (separate, settle-gated) | Lights up the RHOAI Observability dashboard. |

## Install the platform

```bash
make maas
```

Auto-detects the cluster domain and TLS cert name, creates the PostgreSQL secrets,
deploys the Helm chart via ArgoCD (Gateway, GatewayClass, PostgreSQL + 20Gi PVC), and
configures Authorino. ELB DNS propagation can take **2–5 minutes** after install.

> `make maas` does **not** install observability. The observability cascade (Perses,
> Tempo, OTel, MonitoringStack) puts significant memory pressure on the control plane,
> so it's a separate step with its own settle-gate. Run `make observability` once the
> cluster is healthy.

From Claude Code: `/install-maas` (see [Install with Claude](install-claude.md)).

## Deploy models

```bash
make maas-model                         # auto-detect by cluster GPU VRAM:
                                        #   no GPU           -> simulator
                                        #   GPU VRAM >= 40Gi -> gpt-oss-20b
                                        #   otherwise        -> granite-tiny-gpu
make maas-model MODEL=simulator         # CPU-only mock
make maas-model MODEL=gpt-oss-20b       # GPU
make maas-model MODEL=granite-tiny-gpu  # GPU
make maas-model MODEL=all               # all of the above
```

Available models:

| Model | Hardware | Notes |
|-------|----------|-------|
| **simulator** | CPU only | ~256Mi RAM, instant startup, mock responses |
| **gpt-oss-20b** | 1 GPU | OpenAI gpt-oss-20b on vLLM CUDA, 60Gi RAM, 5–15 min startup |
| **granite-tiny-gpu** | 1 GPU | RedHatAI Granite 4.0-h-tiny FP8 on vLLM CUDA, 24Gi RAM |

Each model gets two subscription tiers (all authenticated users):

- **Free** — 100 tokens/min
- **Premium** — 100000 tokens/min

Set defaults in `.env`:

```bash
MAAS_MODELS=gpt-oss-20b granite-tiny-gpu
```

## Manage models

```bash
make maas-model-status                   # show all deployed models
make maas-model-delete MODEL=simulator   # delete one
make maas-model-delete MODEL=all         # delete all
```

## Verify

```bash
make maas-verify
```

Full end-to-end test: deploys a temporary simulator model, creates an API key, tests
inference, checks auth enforcement and rate limiting (429s), then cleans up. It does
**not** touch persistently deployed models.

## Observability

Installed separately from the platform:

```bash
make observability             # settle-gate -> flip instance-rhoai overlay
                               #   -> wait for Perses/Tempo/OTel
make observability-uninstall   # reverse-flip; monitoring cascade tears down
```

The **settle-gate** refuses to run if any master is ≥75% memory, the DSC/DSCI aren't
`Ready`, there are non-terminal pods in core namespaces, or etcd is `Degraded`. This
prevents the cascade from tipping a stressed control plane into OOM.

> **Control-plane sizing.** The monitoring cascade is memory-heavy on the masters.
> Use **`m6a.2xlarge`** (or larger) control-plane nodes — smaller types fail the
> settle-gate. On demo.redhat.com this must be chosen at order time (masters can't be
> resized later) — see [Provision a cluster](demo-env.md#1-order-an-aws-openshift-environment).

Observability lights up the RHOAI 3.x **Observability dashboard** (request rate,
success rate, GPU/CPU/memory, per-subscription usage). The nav item is set by
`components/instances/rhoai-instance/base/odh-dashboard-config.yaml`
(`observabilityDashboard: true`) and is visible only to dashboard admins
(cluster-admin); non-admins won't see it.

## Uninstall

```bash
make maas-uninstall            # cascade-delete Gateway, PostgreSQL, secrets
```

See [Uninstall](uninstall.md) for the full order (observability and models first).

## Dry run

The `make maas` / `make maas-uninstall` targets don't forward flags, so call the
scripts directly to preview without applying:

```bash
scripts/install-maas.sh --dry-run     # preview install
scripts/uninstall-maas.sh --dry-run   # preview uninstall
```

## Debugging

```bash
# Platform
oc get application.argoproj.io/instance-maas -n openshift-gitops
oc get gateway maas-default-gateway -n openshift-ingress
oc get deployment maas-api maas-controller -n redhat-ods-applications

# Models
oc get llminferenceservice -n llm
oc get maassubscription -n models-as-a-service

# Health endpoint (200 = healthy, 401 = auth working)
curl -sk https://maas.<cluster-domain>/maas-api/health
```

`make diagnose` includes a MaaS section (and an Observability section) covering all of
the above.
