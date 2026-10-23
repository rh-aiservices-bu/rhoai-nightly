# 3.6 GA: RHOAI operator ServiceMonitors fail TLS under platform Prometheus (wrong serverName, over-broad selector)

**Jira: NOT FILED** — filing target: RHOAIENG (rhods-operator monitoring +
the affected component teams: trainer, model-registry, odh-model-controller,
ogx). This file is the ready-to-file draft.

Found 2026-10-16 on cluster-n56g8, RHOAI 3.6.0 (`rhoai-3.6-nightly`, operator
`odh-rhel9-operator@sha256:b14cd97f…`).

## Why this surfaced now

3.6.0 GA labels `redhat-ods-applications` with
`openshift.io/cluster-monitoring=true` on every DSCI reconcile, so the
component ServiceMonitors there are now scraped by **platform** Prometheus
(previously UWM rejected them outright — see
[servicemonitors-bearertokenfile.md](servicemonitors-bearertokenfile.md)).
Platform Prometheus loads them and then fails the scrapes.

## Symptom

`up{namespace="redhat-ods-applications"} == 0` for 7 services. Every
`lastError` is an x509 name mismatch, e.g. (from
`prometheus-k8s` `/api/v1/targets`):

```
kubeflow-trainer-controller-manager-metrics-monitor -> x509: certificate is valid for
  kubeflow-trainer-controller-manager.redhat-ods-applications.svc, not ...
model-registry-operator-controller-manager-metrics-monitor -> x509: ... not ...
odh-model-controller-metrics-monitor -> x509: ... not ...
ogx-k8s-operator-controller-manager-metrics-monitor (scraping feast/mcp-lifecycle/mlflow/
  ray-module/ogx services) -> x509: certificate is valid for localhost / mlflow-..., not
  ogx-k8s-operator-controller-manager-metrics-service...
```

RHOAI controller metrics for those components are silently missing.

## Root cause (two defects)

1. **Stale `tlsConfig.serverName`.** Several monitors keep the upstream
   namespace in `serverName` (e.g. `…opendatahub.svc`,
   `…odh-model-controller-system.svc`, `…ogx-k8s-operator-system.svc`), which
   kustomize does not rewrite when the manifests are deployed into
   `redhat-ods-applications`.
2. **Over-broad selector.** `ogx-k8s-operator-controller-manager-metrics-monitor`
   selects only `control-plane: controller-manager`, which matches the
   feast, mcp-lifecycle, mlflow and ray-module metrics Services too; those
   scrapes all fail TLS against ogx's serverName.

## Detection

```bash
T=$(oc whoami -t); P=$(oc get route prometheus-k8s -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $T" "https://$P/api/v1/targets?state=active" | jq -r \
  '.data.activeTargets[] | select(.labels.namespace=="redhat-ods-applications" and .health!="up")
   | "\(.scrapePool) \(.lastError[0:120])"' | sort -u
oc get servicemonitor ogx-k8s-operator-controller-manager-metrics-monitor -n redhat-ods-applications \
  -o jsonpath='{.spec.selector}'
```

## Expected

`serverName` matches `<service>.redhat-ods-applications.svc`, and each
monitor's selector matches only its own Service.

## Workaround

None carried (metrics-only; UX degradation).
