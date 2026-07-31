# Gateway-API LoadBalancer ELB black-holes ~50% of external traffic (no cross-zone, empty AZ)

**Status:** NOT FILED (draft below) — target **OCPBUGS** (cluster-ingress-operator /
Gateway API on AWS), with a secondary note to opendatahub-io/models-as-a-service
(their LoadBalancer pattern docs inherit the same defect).
**Found:** 2026-07-31, fresh RHOAI 3.5.0 nightly install on cluster-tm9xb
(OCP 4.20.30, AWS us-east-2, single-AZ cluster — all 5 nodes in us-east-2c).
**Workaround in this repo:** `components/instances/maas-instance/chart/templates/maas-gateway-options.yaml`
(`service` key adds the cross-zone annotation). **Temporary** — remove when the
gateway controller provisions LBs that serve from every enrolled AZ by default.

## Symptom

External requests to the MaaS gateway hostname hang until client timeout on
roughly half of connection attempts. `curl` shows TCP connect succeeding, then
TLS `Client hello` with no response:

```
* Connected to maas.apps.<domain> (3.131.150.190) port 443
* (304) (OUT), TLS handshake, Client hello (1):
* SSL connection timeout        ← HTTP 000 after --max-time
```

The hostname resolves to two A records (both belonging to the gateway's
classic ELB). One IP serves normally (200 in ~0.12s); the other black-holed
TLS consistently for 30+ minutes. Which one a client gets is DNS round-robin —
so API consumers see intermittent 50% hangs, which is the worst kind of
failure to debug from outside.

## Root cause

The `openshift.io/gateway-controller/v1` GatewayClass controller
(cluster-ingress-operator + OSSM/Istio gateway deployer) creates the
Gateway's Service (`<gateway>-<class>`, `type: LoadBalancer`) with **no AWS
annotations**. The Kubernetes AWS cloud provider therefore builds a **classic
ELB with cross-zone load balancing disabled** (the AWS default). The ELB
enrolled an availability zone that contains **no cluster instances**; with
cross-zone off, that AZ's LB node has no backends and its IP is a TLS black
hole. Single-AZ clusters (common for dev/sandbox) are maximally exposed.

The OpenShift router's LoadBalancer does not exhibit this on the same
cluster — only the Gateway-API-provisioned Service.

## Detection

```bash
H=maas.apps.<cluster-domain>
for IP in $(dig +short $H); do
  curl -sk --connect-timeout 5 --max-time 8 --resolve "$H:443:$IP" \
    "https://$H/maas-api/health" -o /dev/null -w "$IP -> %{http_code}\n"
done
# any IP -> 000 while another -> 200 = this bug
```

## Fix / workaround

Live-verified on tm9xb: annotating the Service flipped the dead IP to
HTTP 200 **immediately** (first probe after the cloud controller applied it):

```bash
oc annotate svc maas-default-gateway-openshift-default -n openshift-ingress \
  "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled=true"
```

Durable form (this repo): the Gateway already carries
`spec.infrastructure.parametersRef` → ConfigMap `maas-default-gateway-options`;
the controller merges the ConfigMap's `service` key into the generated
Service. We add `metadata.annotations` only (no `spec.type`), keeping the
LoadBalancer. Upstream models-as-a-service uses the same ConfigMap `service`
mechanism for its service-ca annotation, so this is the supported knob.

## Remove when

The Detection loop shows every ELB IP serving without the annotation
(i.e., the gateway controller either enables cross-zone, restricts LB AZ
enrollment to AZs with instances, or moves to NLB with sane defaults).

## Steps to reproduce

1. AWS OCP 4.20 cluster whose nodes all sit in **one** availability zone
   (typical dev/sandbox install).
2. Create a GatewayClass with
   `controllerName: openshift.io/gateway-controller/v1` and a Gateway using it
   with an HTTPS listener (any hostname under `*.apps`).
3. Wait for the Gateway's generated `Service` (`<gateway>-<class>`,
   `type: LoadBalancer`) to get its classic ELB.
4. `dig +short <listener-hostname>` — two A records.
5. Probe each: `curl -sk --resolve "<host>:443:<ip>" https://<host>/ -o
   /dev/null -w "%{http_code}\n" --max-time 8` — one IP answers, the other
   times out in TLS (`000`). Persists indefinitely.
6. Confirm the mechanism: set
   `service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"`
   on the Service — the dead IP starts serving within ~1 min.

## Filing draft (OCPBUGS)

> **Title:** Gateway API LoadBalancer Service on AWS provisions classic ELB
> with cross-zone disabled — enrolled AZ without instances black-holes ~50%
> of external traffic
>
> **Component:** Networking / router (Gateway API), cluster-ingress-operator
>
> **Version:** OCP 4.20.30, OSSM 3.4.0 (servicemeshoperator3.v3.4.0)
>
> On a single-AZ AWS cluster (all nodes us-east-2c), creating a Gateway with
> `gatewayClassName: openshift-default` produces a `type: LoadBalancer`
> Service with no cloud annotations. The resulting classic ELB comes up with
> two enrolled AZs and cross-zone load balancing disabled; the AZ with no
> instances yields a DNS A record whose TLS handshakes time out. External
> clients hang on ~50% of connections (DNS round-robin). The default router
> LB on the same cluster is not affected. Reproduced persistently for 30+
> minutes on a fresh install; adding
> `service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"`
> to the Service fixed it immediately. Expected: the gateway controller
> provisions LBs that serve from every AZ it enrolls (enable cross-zone,
> restrict AZ enrollment, or default to NLB).
