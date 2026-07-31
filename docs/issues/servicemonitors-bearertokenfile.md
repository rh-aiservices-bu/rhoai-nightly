# Two operator ServiceMonitors rejected by UWM (`bearerTokenFile`) — controller metrics silently unscraped

**Jira: NOT FILED** for 3.5 (precedent fix pattern: [RHOAIENG-19954](https://redhat.atlassian.net/browse/RHOAIENG-19954), Kueue, rhoai-2.19). Filing draft below.


- **Symptom:** none user-visible — `make diagnose` is green and the Observability
  dashboard loads. But two components' metrics are silently never scraped.
- **Detection:**
  ```bash
  oc get events -n redhat-ods-applications --field-selector type=Warning,reason=InvalidConfiguration \
    -o jsonpath='{range .items[*]}{.involvedObject.name}: {.message}{"\n"}{end}'
  # controller-manager-metrics-monitor / odh-model-controller-metrics-monitor:
  #   rejected due to invalid configuration: endpoints[0]: it accesses file system
  #   via bearer token file which Prometheus specification prohibits
  ```
- **Root cause (3.5.0):** both ServiceMonitors set
  `endpoints[0].bearerTokenFile`. The prometheus-operator backing OpenShift
  user-workload monitoring prohibits filesystem token access for tenant workloads
  and rejects the whole object. The modern equivalent is
  `authorization.credentials` with a Secret reference.
- **Owners (cannot be fixed in-repo):** `DataScienceCluster/default-dsc` and
  `Kserve/default-kserve` — reconciled by the RHOAI operator, so a local patch is
  reverted, and there is no DSC field to override them.
- **Impact:** RHOAI controller-manager and odh-model-controller metrics are
  absent from UWM. MaaS/gateway/vLLM metrics are unaffected (those come from the
  Kuadrant monitors, `istio-gateway-metrics` and `kserve-llm-models`), so the
  Observability dashboard still populates — but panels fed by these two
  controllers stay empty. Easy to misread as "observability is broken".
- **Diagnosis note:** invisible to resource-existence checks — the objects exist
  and look correct; only Prometheus's rejection *event* reveals they are inert.
- **Fix:** none available — upstream must switch to `authorization.credentials`.

---

## Filing draft (RHOAIENG)

## Summary

On RHOAI 3.5.0 with user-workload monitoring, the RHOAI-operator-reconciled
ServiceMonitors `controller-manager-metrics-monitor` and
`odh-model-controller-metrics-monitor` set `endpoints[0].bearerTokenFile`.
The prometheus-operator behind UWM prohibits filesystem token access for
tenant workloads and **rejects the whole object**:

```
oc get events -n redhat-ods-applications --field-selector type=Warning,reason=InvalidConfiguration
# ...rejected due to invalid configuration: endpoints[0]: it accesses file system
# via bearer token file which Prometheus specification prohibits
```

Result: RHOAI controller-manager and odh-model-controller metrics are silently
absent from UWM. Nothing user-visible fails — dashboards load, health checks
pass — so the gap is easy to misread as "observability broken" when those
panels stay empty.

## Not fixable cluster-side

Both objects are owned/reconciled by the RHOAI operator (via
`DataScienceCluster` / `Kserve`), so local patches are reverted, and no DSC
field overrides them.

## Fix

Replace `bearerTokenFile` with the modern `authorization.credentials` Secret
reference, as was done for the identical Kueue case in RHOAIENG-19954
(Closed/Done, rhoai-2.19) — this is the same bug pattern recurring in two more
components.

## Steps to reproduce

1. OCP 4.20 with user-workload monitoring enabled
   (`cluster-monitoring-config` ConfigMap, `enableUserWorkload: true`).
2. Install RHOAI 3.5.0 nightly; create a default DataScienceCluster with
   kserve Managed. Wait for DSC Ready.
3. Run:
   ```bash
   oc get events -n redhat-ods-applications \
     --field-selector type=Warning,reason=InvalidConfiguration
   ```
   Both ServiceMonitors are rejected with the bearer-token-file message,
   recurring on every prometheus-operator sync.

## Detection

The InvalidConfiguration events above; or absence of
`controller_runtime_*` metrics for these controllers in UWM under load.
