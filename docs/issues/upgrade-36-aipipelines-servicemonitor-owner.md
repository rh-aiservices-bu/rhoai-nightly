# 3.6 upgrade: AIPipelines can't adopt DSPO ServiceMonitor still owned by DataSciencePipelines

**Jira: NOT FILED** — filing target: RHOAIENG (rhods-operator AI Pipelines
module / DataSciencePipelines → AIPipelines migration). This file is the
ready-to-file draft.

Found 2026-10-16 on cluster-n56g8, in-place OLM upgrade
`rhods-operator.3.6.0-ea.2` → `rhods-operator.3.6.0` (catalog
`rhoai-3.6-nightly` 2026-10-15, operator `odh-rhel9-operator@sha256:e1a770e8…`).

## Symptom

DSC `AIPipelinesReady=False reason=ComponentsNotReady` ("AIPipelines is waiting
for configuration, DSPO, Argo, or monitoring readiness");
`AIPipelines/default-aipipelines`:

```
ProvisioningSucceeded=False MonitoringReconcileFailed: reconcile core ServiceMonitor:
ServiceMonitor "data-science-pipelines-operator-service-monitor" is controlled by
DataSciencePipelines "default-datasciencepipelines" with UID "604ab3c9-…"
```

The data-science-pipelines-operator itself did roll to the new image, so
pipelines likely still work; what fails is the new module's monitoring
reconcile — and therefore DSC `Ready`.

## Root cause

3.6.0 manages pipelines through the new `AIPipelines` module, but the
pre-upgrade `DataSciencePipelines/default-datasciencepipelines` component CR
(created 2026-09-25 by ea.2, still `Ready=True`, owner `DataScienceCluster`) is
neither removed nor stripped of its controller ownerReferences. The new module
refuses to take over the ServiceMonitor because another controller owns it.

Scope: EA2 → GA proven. A 3.5.x → 3.6.0 upgrade carries the same leftover
DataSciencePipelines CR, so it is **likely** affected — verify before filing.

## Detection

```bash
oc get servicemonitor data-science-pipelines-operator-service-monitor -n redhat-ods-applications \
  -o jsonpath='{range .metadata.ownerReferences[*]}{.kind}/{.name} controller={.controller}{"\n"}{end}'
oc get datasciencepipelines.components.platform.opendatahub.io
# Bug live: owner is DataSciencePipelines/default-datasciencepipelines and AIPipelines reports MonitoringReconcileFailed
```

## Expected

The upgrade migrates ownership (or deletes the obsolete DataSciencePipelines
CR) so AIPipelines can adopt its resources.

## Workaround

None carried.
