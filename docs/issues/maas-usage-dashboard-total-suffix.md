# MaaS Usage dashboard queries `*_total` metric names Limitador doesn't export

**Jira: NOT FILED** — filing target: RHOAIENG (maas-controller, which owns the
`dashboard-3-maas-usage-admin` PersesDashboard). This file is the
ready-to-file draft.

First seen 2026-09-25 (n56g8, 3.6.0-ea.2); still present 2026-10-16 on
RHOAI 3.6.0 (`rhoai-3.6-nightly`, operator `b14cd97f`) with RHCL 1.4.3.

## Symptom

The MaaS **Usage** view of the Observability dashboard renders empty panels
even with live MaaS traffic and rate limiting working.

## Root cause

`PersesDashboard/dashboard-3-maas-usage-admin` (redhat-ods-monitoring,
re-applied by maas-controller) references `authorized_hits_total`,
`authorized_calls_total` and `limited_calls_total` in 12 queries. Limitador
(RHCL 1.4.3) exports these counters **without** the `_total` suffix. Thanos on
n56g8, 2026-10-16:

| metric | series |
|---|---|
| `authorized_hits` / `authorized_calls` / `limited_calls` | 2 / 2 / 1 |
| `authorized_hits_total` / `authorized_calls_total` / `limited_calls_total` | 0 / 0 / 0 |

Before filing, check which Limitador version the `_total` names assumed (a
Prometheus client upgrade can add or drop the suffix), so the bug lands on the
right side.

## Detection

```bash
oc get persesdashboard dashboard-3-maas-usage-admin -n redhat-ods-monitoring -o json \
  | jq '[.. | strings | select(test("_calls_total|_hits_total"))] | length'   # > 0 = bug live
# and in Thanos: count(authorized_hits_total) is empty while count(authorized_hits) > 0
```

## Workaround

None carried (dashboard-only).
