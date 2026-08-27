# Self-hosted Plane (Community Edition)

**Date:** 2026-08-25
**Status:** Approved, implementation in progress

## Goal

Replace the project-management slot vacated when OpenProject was removed in
`77d1c8d` ("remove OpenProject and reduce resources post-event"), with Plane
Community Edition serving `plane.cloudnativedays.fr` for the organizing team.

## Edition and licensing

Plane CE is AGPL-3.0, deployed from the official `plane-ce` chart
(`https://helm.plane.so/`, chart **1.6.3**, appVersion v1.4.1). It is a *separate
codebase* from the Commercial edition, at feature parity with the Free tier of
Plane Cloud, and receives features later than Commercial.

Not available in CE, and not worked around here:

- SSO / SAML / OIDC / LDAP
- Workflows and approval gates
- Epics, initiatives, teamspaces
- Work item types and custom properties
- GitHub / GitLab / Slack integrations
- Org-wide wiki
- Audit trails

CE does provide unlimited projects, work items, cycles, modules and pages,
intake, dashboards, estimates, REST API and webhooks, with no user cap — which
covers what OpenProject was doing for the event. Moving to Commercial later is
a license key, not a reinstall or a data migration.

## Architecture

One HelmRelease in `cnd-project`, alongside baserow.

```
                    plane.cloudnativedays.fr
                              |
              +---------------+----------------+
     Ingress: plane                  Ingress: plane-godmode
     / -> plane-web:3000               /god-mode -> plane-admin:3000
     /api,/auth -> plane-api:8000      + nginx basic-auth
     /live/ -> plane-live:3000
     /spaces -> plane-space:3000
                              |
         +------------+-------+--------+--------------+
      plane-api   plane-worker   plane-beatworker  plane-live
         |            |                |               |
    +----+------------+----------------+---------------+----+
    | cnpg-plane-rw   plane-redis   plane-rabbitmq   Scaleway |
    | (CNPG, 2 inst)  (chart)       (chart)          S3 fr-par|
    +--------------------------------------------------------+
```

### Backing services

| Service | Choice | Why |
|---|---|---|
| Postgres | CNPG `cnpg-plane`, 2 instances, backed up to S3 | House pattern; this is the data that cannot be recreated |
| Cache | Chart-bundled Valkey (`redis.local_setup: true`) | Saves ~250Mi over a dedicated Valkey release; contents are disposable |
| Broker | Chart-bundled RabbitMQ | Hard Plane dependency; no RabbitMQ operator in this cluster; official upstream image, no Bitnami licensing trap |
| Object store | Scaleway S3, dedicated `cnd-plane` bucket | House pattern; removes a stateful workload; CORS is bucket-scoped so it does not belong on the shared backup bucket |

The accepted cost of the bundled Valkey: no auth (the chart emits a bare
`redis://plane-redis:6379/`) and no metrics. This repo has no NetworkPolicies,
so any pod in the cluster could reach it. Bounded and accepted for a cache
holding sessions and Celery state on a single-tenant cluster.

## Chart limitations and how each is handled

| Limitation | Handling |
|---|---|
| Bundled Redis and RabbitMQ render with **no `resources` block** and no values knob — BestEffort QoS, first evicted under memory pressure | postRenderer patches inject requests/limits |
| The **migrator Job** also renders with no `resources` — BestEffort, so it can be evicted part-way through a Django migration | Same postRenderer patch injects requests/limits |
| Migrator Job has no `ttlSecondsAfterFinished`; one per Helm revision, accumulates | Same patch, targeted by `kind: Job` because the name carries `.Release.Revision` |
| **1.6.3 hardcodes `WEB_URL` to `http://<appHost>`** regardless of any `ssl.*` value. Behind a force-ssl-redirect Ingress that breaks auth redirects and every generated link | postRenderer patch rewrites `WEB_URL` on the `plane-app-vars` ConfigMap. Chart 1.7.0 adds `ssl.externalTermination`, which makes this patch removable |
| Migrator Job has `backoffLimit: 3` and no wait-for-database | Two-PR rollout: CNPG first, verified Ready, then the HelmRelease |
| Every pod template carries `timestamp: {{ now }}` | `driftDetection: mode: warn` initially, rather than the repo-default `enabled` |
| No `securityContext` anywhere in the chart | Deliberately **not** patched in the initial rollout — forcing `runAsNonRoot`/`readOnlyRootFilesystem` onto seven unexercised images invites a day-one crashloop. Follow-up once observable |
| `/god-mode` exposed publicly at a predictable path with no gate | Separate Ingress with nginx basic-auth |
| Chart Ingress applies annotations to the whole object, so `/god-mode` cannot be gated from it; two Ingresses claiming the same host+path make ingress-nginx pick the older one | `ingress.enabled: false`, routes hand-written per the chart README's route table |
| No SMTP settings in the chart at all | Configured post-deploy in `/god-mode`, stored in the DB. Brevo relay, as pretalx and baserow use |
| `SECRET_KEY` not rotatable without corrupting encrypted data | Generated once by `.bootstrap.sh`, sealed, recorded in the password manager |
| Images come from the vendor registry `artifacts.plane.so`, no `stable` tag | `planeVersion` pinned explicitly |
| Chart's git `master` reports version 1.7.0, but only up to **1.6.3 is published** at helm.plane.so | Pinned to 1.6.3; pinning 1.7.0 fails with "chart not found" |
| Only `api` has a readinessProbe; no liveness probes | Accepted; a readiness probe is added to RabbitMQ via postRenderer |

## Secrets

Five chart `external_secrets.*` hooks plus the basic-auth credential, all
SealedSecrets written by `project/plane/.bootstrap.sh`. Using the hooks is
mandatory, not stylistic: without them the chart builds `DATABASE_URL` and
`AMQP_URL` from `values`, putting both passwords in Git as plaintext.

| SealedSecret | Keys |
|---|---|
| `plane-cnpg-secret` | `username`, `password` |
| `plane-app-secret` | `SECRET_KEY`, `LIVE_SERVER_SECRET_KEY`, `DATABASE_URL`, `REDIS_URL`, `AMQP_URL` |
| `plane-live-secret` | `LIVE_SERVER_SECRET_KEY`, `REDIS_URL` |
| `plane-docstore-secret` | `USE_MINIO=0`, `AWS_*`, `AWS_S3_BUCKET_NAME`, `AWS_S3_ENDPOINT_URL`, `FILE_SIZE_LIMIT` |
| `plane-rabbitmq-secret` | `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS` |
| `plane-godmode-auth` | `auth` (apr1 htpasswd line) |

Connection strings mirror the chart's own generated format verbatim, so they
cannot drift from what the bundled services expect.

Two consequences accepted explicitly:

- The Postgres password is duplicated between `plane-cnpg-secret` and the DSN
  inside `plane-app-secret`. Rotating it means resealing both in lockstep.
- `LIVE_SERVER_SECRET_KEY` appears in two secrets and must be byte-identical.
  A mismatch breaks collaborative editing with no useful error in either pod.

`cnd-france-scw-secret` is **not** resealed: Plane shares `cnd-project` with
baserow, so the existing secret applies. It moves from `project/baserow/` up to
`project/` because two apps now depend on it.

## Sizing

Provisional — the cluster headroom check was not completed before
implementation.

| Workload | CPU req | Mem req | Mem limit |
|---|---|---|---|
| api | 300m | 512Mi | 1Gi |
| worker | 200m | 384Mi | 768Mi |
| beatworker | 50m | 192Mi | 384Mi |
| web | 150m | 384Mi | 768Mi |
| space / admin / live | 100m each | 256Mi each | 512Mi each |
| redis (patched) | 50m | 128Mi | 256Mi |
| rabbitmq (patched) | 100m | 256Mi | 512Mi |
| migrator Job (patched, transient) | 200m | 384Mi | 768Mi |
| cnpg-plane x2 | 200m each | 512Mi each | 1Gi each |
| **Total** | **~1.55** | **~3.6 GiB** | **~7 GiB** |

For comparison, the OpenProject slot this replaces held ~2.5 GiB requested
(1 GiB app + 2x768Mi CNPG). Plane is roughly 1.1 GiB larger. This cluster has a
documented history of memory pressure — `88a8b26` blocked baserow outright for
lack of resources, and there are ~6 OOMKill-fix commits across pretalx, baserow
and its Valkey — so this is the risk most likely to decide whether the rollout
succeeds.

CNPG gets 512Mi request / 1Gi limit rather than baserow's equal 768/768,
following the reasoning already recorded in `analytics/cnpg-cluster.yaml`.

CPU limits are set on every app pod because the chart templates always render
one (`cpu: {{ .Values.X.cpuLimit | default "500m" }}`); they cannot be omitted
the way the rest of this repo omits them.

## Rollout

**PR 1** — HelmRepository, `project/kustomization.yaml`, the
`cnd-france-scw-secret` move, CNPG cluster + ScheduledBackup, six SealedSecrets,
this document. Verify the cluster reports Ready and the first backup lands in
S3 before proceeding.

**PR 2** — HelmRelease and both Ingress objects.

Out-of-band before PR 1, documented in `.bootstrap.sh`: create the `cnd-plane`
bucket, apply its CORS rule, create the DNS record.

Post-deploy manual steps: `/god-mode` -> create the instance admin -> configure
Brevo (`smtp-relay.brevo.com:587`, TLS, sender `plane@cloudnativedays.fr`) ->
send a test invite -> create the first workspace.

## Pre-merge verification (already done)

Rendered locally with `helm template plane plane-ce --version 1.6.3` and the
postRenderer replayed through `kustomize build`, i.e. what Flux itself does:

- All four postRenderer patches apply cleanly against real chart output
- Every Deployment, StatefulSet **and the migrator Job** carries a memory
  request — nothing renders BestEffort
- `WEB_URL` comes out `https://plane.cloudnativedays.fr`
- Job carries `ttlSecondsAfterFinished: 3600`
- All seven Services get a real ClusterIP (none headless)
- No `Secret` objects are rendered at all — the `external_secrets.*` hooks are
  in effect, so no credential reaches Git
- App-tier requests total 2.56 GiB, matching the estimate in this document
- `./scripts/validate-manifests.sh` passes (polaris 10.2.1, the CI-pinned
  version)

## Verification (post-deploy)

- HelmRelease Ready; migrator Job Complete
- No pod reports `BestEffort`:
  `kubectl -n cnd-project get pods -o json | jq '.items[]|{name:.metadata.name,qos:.status.qosClass}'`
- CNPG cluster healthy; first ScheduledBackup present in S3
- `curl -sI https://plane.cloudnativedays.fr/god-mode` returns 401
- A real file upload through the UI — proves S3 credentials *and* bucket CORS
- A Page open in two browsers — proves the websocket route and that
  `LIVE_SERVER_SECRET_KEY` matches

## Known failure modes

- Migrator backoff exhausted before Postgres is Ready: delete the Job and
  reconcile. Mitigated by the two-PR sequencing.
- Missing bucket CORS: uploads fail silently, visible only in the browser
  console.
- `LIVE_SERVER_SECRET_KEY` mismatch: live editing broken, no useful log line.
- nginx `proxy-read-timeout` at its 60s default: websocket sessions drop
  mid-edit. Set to 3600 on the app Ingress.

## Rejected alternatives

**Dedicated Valkey HelmRelease** (the baserow/pretalx pattern, with auth and
metrics): ~250Mi more on a capacity-constrained cluster, and RabbitMQ still
needs the postRenderer regardless, so it does not remove the mechanism it would
have justified.

**Single-instance CNPG**: fits inside the freed OpenProject slot, but breaks
the pattern uniform across all six CNPG clusters here and turns every Postgres
restart or node drain into Plane downtime.

**Chart-managed Ingress**: cannot gate `/god-mode` separately, since chart
annotations apply to the whole object.

**Reusing the shared `cloudnativedaysfr` bucket**: defensible, since backups
need signed requests and CORS alone does not expose them, but a browser-origin
CORS policy does not belong on the bucket holding every CNPG backup.
