# Self-hosted URL shortener — design

Date: 2026-08-13
Component: `shortener` (namespace `cnd-shortener`, cluster `k8s-cndfrance-prod`)
Upstream: [Shlink](https://shlink.io) 5.1.5 + [shlink-web-client](https://github.com/shlinkio/shlink-web-client) 4.8.1
Scope: the shortener service itself. Which links get created, and the editorial
convention for slugs, are the comms team's call and are not specced here.

## Goal

Serve branded short links under **`s.cloudnativedays.fr`**, self-hosted on the existing
platform, with:

- a **web UI** the comms team can use without touching git or curl,
- a **REST API** so the website build and scripts can mint links programmatically,
- **click counts and referrers per link** — and deliberately nothing more.

## Findings that shaped this design

- **YOURLS is MySQL/MariaDB-only.** The cluster standardises on CloudNativePG: six
  `Cluster` objects across `ticketing/alfio`, `callforpapers/pretalx`, `project/baserow`,
  `communication/photos` and two in `communication/matrix`, all `instances: 2`,
  `storageClass: node-local-retain`, `size: 10Gi`, backed up to Scaleway. Adopting YOURLS
  means introducing a database engine with no operator and a hand-rolled backup story.
  Shlink accepts `DB_DRIVER=postgres` and drops onto the existing pattern unchanged. This
  single fact decides the YOURLS-vs-Shlink question.
- **No infrastructure source can produce per-link stats.** `nginx_ingress_controller_requests`
  labels by `ingress`, `host` and the ingress *path rule* — not the request URI — so
  ingress-nginx metrics cannot distinguish `/kubecon26` from `/cfp`. Shlink exposes no
  Prometheus or OpenTelemetry endpoint either: zero code hits for `prometheus` in
  `shlinkio/shlink`, and nothing in the CHANGELOG through 5.1.5. Its Matomo integration
  works but requires deploying Matomo, which is more infrastructure than the shortener.
  **Shlink's own visit table is therefore the stats backend**, and it costs nothing extra
  because the app needs that database regardless.
- **`GEOLITE_LICENSE_KEY` is not actually mandatory.** `install-docker-image` lists it
  among three required variables, but `docker/docker-entrypoint.sh` appends
  `--skip-download-geolite` when the key is empty. With IP tracking disabled the key is
  unnecessary — **no MaxMind account is needed**.
- **Migrations run on every container start.** The entrypoint invokes
  `php vendor/bin/shlink-installer init`, and multi-instance deployments are documented as
  needing `REDIS_SERVERS` for shared locks. A single replica sidesteps both concerns.
- **`/rest/health` is database-coupled.** `module/Rest/src/Action/HealthAction.php` declares
  `ROUTE_PATH = '/health'` (mounted under `/rest`) and returns 503 when the entity manager
  cannot connect. Used as a *liveness* probe it would restart-loop the pod through a CNPG
  failover.
- **shlink-web-client is a static SPA.** `SHLINK_SERVER_API_KEY` is materialised into a
  `servers.json` served to the browser. Upstream states: *"use this only when you self-host
  shlink-web-client, and you know only trusted people will have access to it."*
- **The basic-auth pattern already exists here.** `website-staging/ingress.yaml` carries the
  `nginx.ingress.kubernetes.io/auth-type: basic` annotation set, with the SealedSecret
  alongside it and the constraint that the data key must be named exactly `auth`.
- **Cluster resources are tight.** Commit `88a8b26` removed Baserow with
  "do not have enough resources in the cluster". This design budgets ~1.1Gi total and adds
  no Valkey.
- **No external-dns.** DNS records are created manually, as recorded in the
  website-staging and Ente specs. Two A records are a manual prerequisite here too.
- **Shlink 4.0+ runs as a non-root user** by default, so no `-non-root` tag suffix is
  required. Both images use numeric users — Shlink 1001, the web client 101, read from their
  registry configs — which is what lets `runAsNonRoot: true` be set without also pinning
  `runAsUser`. It must still be set explicitly: polaris scores the manifest, not the image,
  so relying on the image's default is what makes `runAsRootAllowed` fire.

## Architecture

Two hostnames, deliberately separate — every path under the redirect host is short-code
namespace, so an admin UI mounted there would permanently burn a slug.

| Host | Serves | Auth |
|---|---|---|
| `s.cloudnativedays.fr` | Shlink: `/<code>` redirects, `/rest/*` API | API key on `/rest/*`; redirects public |
| `links.cloudnativedays.fr` | shlink-web-client SPA | ingress basic auth |

```
                    ┌─────────────────────────────────────────┐
  visitor ─────────▶│ s.cloudnativedays.fr        (Ingress)   │
                    │   /kubecon26  → 302 → target            │
  CI / scripts ────▶│   /rest/*     → REST API (X-Api-Key)    │
                    └──────────────┬──────────────────────────┘
                                   │
                            ┌──────▼──────┐      ┌────────────────────┐
                            │  shlink     │─────▶│ cnpg-shlink (2x)   │
                            │  5.1.5      │      │ short URLs, visits │
                            │  1 replica  │      └─────────┬──────────┘
                            └──────▲──────┘                │ daily
                                   │ REST over HTTPS        ▼
  comms ──▶ links.cloudnativedays.fr ──┐   s3://cloudnativedaysfr/cnpg/shlink
            (basic auth) │             │
                    ┌────▼─────────────┴──┐
                    │ shlink-web-client    │  static SPA, nginx :8080
                    │ 4.8.1                │  API key injected at startup
                    └──────────────────────┘
```

### Repository placement

Follows the `communication/photos` precedent: the directory sits under `communication/`
for taxonomy, but reconciliation is owned by a separate Flux Kustomization with its own
namespace, so a broken shortener cannot block Matrix.

```
communication/shortener/                       ← manifests (below)
namespaces/namespaces.yaml                     ← + cnd-shortener
clusters/k8s-cndfrance-prod/shortener.yaml     ← Flux Kustomization "cnd-shortener"
communication/kustomization.yaml               ← unchanged; stays scoped to matrix
```

`clusters/k8s-cndfrance-prod/shortener.yaml` mirrors `photos.yaml`: `path: ./communication/shortener`,
`prune: true`, `interval: 2m0s`, `dependsOn: cnd-operators`, source `customer`, with
health checks on the `shlink` Deployment and the `cnpg-shlink` Cluster.

### Manifests

| File | Contents |
|---|---|
| `kustomization.yaml` | `namespace: cnd-shortener`, lists the resources below |
| `cnpg-cluster.yaml` | `cnpg-shlink`: 2 instances, `bootstrap.initdb` database `shlink` / owner `shlink`, `node-local-retain` 10Gi, Scaleway `barmanObjectStore` → `s3://cloudnativedaysfr/cnpg/shlink`, PodMonitor + relabelings — structurally identical to `communication/photos/cnpg-cluster.yaml` |
| `cnpg-scheduled-backup.yaml` | `0 0 0 * * *`, `backupOwnerReference: self` |
| `shlink-cnpg-secret.yaml` | SealedSecret, `kubernetes.io/basic-auth`: DB `username` / `password` |
| `shlink-secret.yaml` | SealedSecret: `initial-api-key` |
| `cnd-france-scw-secret.yaml` | SealedSecret resealed into `cnd-shortener` for CNPG backups |
| `deployment.yaml` | `shlinkio/shlink:5.1.5`, 1 replica |
| `service.yaml` | ClusterIP `shlink`, port 8080 named `http` |
| `ingress.yaml` | `s.cloudnativedays.fr`, letsencrypt, `force-ssl-redirect` |
| `web-client-deployment.yaml` | `shlinkio/shlink-web-client:4.8.1`, 1 replica |
| `web-client-service.yaml` | ClusterIP `shlink-web-client`, port 8080 |
| `web-client-ingress.yaml` | `links.cloudnativedays.fr`, letsencrypt, basic auth |
| `web-client-auth-sealedsecret.yaml` | htpasswd; data key **must** be named `auth` |
| `.bootstrap.sh` | generates + seals the four secrets (see below) |

### Shlink configuration

```yaml
DEFAULT_DOMAIN: s.cloudnativedays.fr
IS_HTTPS_ENABLED: "true"

DB_DRIVER: postgres
DB_HOST: cnpg-shlink-rw
DB_PORT: "5432"
DB_NAME: shlink
DB_USER / DB_PASSWORD:  from shlink-cnpg-secret
INITIAL_API_KEY:        from shlink-secret

DISABLE_IP_TRACKING: "true"          # no IP stored; geolocation off; no MaxMind account
DISABLE_UA_TRACKING: "true"          # no device / browser rows
DISABLE_REFERRER_TRACKING: "false"   # the one signal we want
TRACK_ORPHAN_VISITS: "false"         # don't record hits on non-existent codes
```

`GEOLITE_LICENSE_KEY` is intentionally left unset.

**Resulting data footprint.** A visit row holds a timestamp, the short code, and a referrer
string. No IP address, no user agent, no location. This is the deliberate answer to
"which channel drove traffic" without accumulating personal data.

### Probes and resources

Readiness uses `/rest/health`; liveness uses a TCP socket check on port 8080, so a CNPG
failover degrades readiness (traffic stops being routed) without triggering restarts.

| Container | CPU req | CPU limit | Mem req | Mem limit |
|---|---|---|---|---|
| `shlink` (PHP + RoadRunner) | 100m | 500m | 256Mi | 512Mi |
| `shlink-web-client` (nginx, static) | 10m | 100m | 32Mi | 64Mi |
| `cnpg-shlink` ×2 | 100m | — | 256Mi | 512Mi |

Roughly 800Mi and 310m requested, capping at 1.6Gi. The Shlink figures are an estimate for a
RoadRunner worker pool at this traffic level; revisit after a week of real usage rather
than guessing harder now.

Two deliberate choices in that table:

- **CPU limits are set** because `.polaris.yaml` scores `cpuLimitsMissing`, and
  `website/deployment.yaml` is the in-repo precedent. Without them the component adds
  warnings it claims not to.
- **The CNPG memory limit is 2× its request**, not equal to it. Equal values make the pod
  Guaranteed QoS with no burst room, and the midnight `ScheduledBackup` runs
  `barman-cloud-backup` with gzip compression and S3 upload buffers inside that same pod —
  plus `pg_basebackup` whenever the replica resyncs. The first spike past a hard 256Mi is an
  immediate OOMKill, then a failover, then a full resync, nightly. `communication/photos`
  sizes the same shape at 768Mi; 512Mi is the compromise between that and this cluster's
  documented capacity pressure (`88a8b26`).

## Secrets and bootstrap

`communication/shortener/.bootstrap.sh`, modelled on `communication/photos/.bootstrap.sh`:

1. Generate the DB password, `INITIAL_API_KEY`, and an htpasswd entry for the admin UI.
2. Reseal `cnd-france-scw-secret` from `cnd-project` into `cnd-shortener`.
3. `kubeseal` four SealedSecrets into `communication/shortener/`.
4. Strip `creationTimestamp: null` — kubeconform rejects it (same fix as commit `27b235b`,
   and again in `6c61223`).
5. Write plaintexts to `~/.shlink-bootstrap-secrets.txt` (mode 600) for the operator to
   move into the password manager and delete.

Manual prerequisites the script cannot perform:

- DNS A records for `s.cloudnativedays.fr` and `links.cloudnativedays.fr` → cluster ingress.
- A working `kubectl` context for `k8s-cndfrance-prod` and a reachable `kubeseal` controller.

### API key handling

The SPA serves its API key to the browser. Basic auth is not a convenience here — it is the
only control in front of an admin-scoped key. Two rules follow:

- The htpasswd credential is shared-secret-grade. Rotating it should be accompanied by
  rotating the API key.
- **Automation gets its own API key**, created through the UI after bootstrap. The initial
  key stays with the SPA. A leak of either is then independently revocable via
  `bin/cli api-key:disable`.

## Failure modes

| Failure | Behaviour | Mitigation |
|---|---|---|
| Postgres unavailable | Redirects 503; readiness fails, liveness holds | CNPG 2 instances, automatic failover |
| Rollout / node drain | Seconds of redirect downtime (single replica) | Accepted trade-off; `strategy: Recreate` is what makes it seconds rather than a race |
| Migration on start | `shlink-installer init` runs every boot, idempotent | `strategy: Recreate` — see below |
| Unknown short code | Shlink returns 404 | `TRACK_ORPHAN_VISITS: "false"` keeps the visits table clean |
| API key lost | No admin access | `kubectl exec` → `bin/cli api-key:generate` |
| Admin UI credential leak | Attacker can mint/delete links | Rotate htpasswd + API key; redirects themselves are unaffected |

### Accepted trade-offs

- **Single replica, with `strategy: Recreate`.** Multi-replica Shlink needs Valkey for shared
  locks. Given the cluster's resource history (`88a8b26`) and the traffic profile, a Valkey
  deployment is not worth a few seconds of rollout downtime. Revisit if short links go onto
  printed material where an outage is costlier.

  The strategy is load-bearing, not incidental. `replicas: 1` alone does **not** mean one pod:
  with the default RollingUpdate plus `maxUnavailable: 0`, Kubernetes must start the new pod
  before terminating the old one, so every rollout runs two Shlink pods concurrently — each
  executing `shlink-installer init` against the same database, with locks in a pod-local
  `data/locks` directory. That is precisely the concurrent-migration race a single replica is
  chosen to avoid, and it would have been reintroduced by the very field meant to prevent
  downtime. `communication/photos/museum.yaml` reached the same conclusion for the same
  reason.
- **No geolocation.** Chosen, not a limitation. Re-enabling means a MaxMind account,
  `GEOLITE_LICENSE_KEY` as a fifth secret, and `DISABLE_IP_TRACKING: "false"` — which
  changes the privacy story and would want a notice.

## Validation

Manifest gate — the repository's existing single entry point, unchanged:

```bash
./scripts/validate-manifests.sh    # kustomize render → polaris audit
```

Expected polaris outcome, measured by rendering these manifests and running the gate rather
than assumed: **two `notReadOnlyRootFilesystem` warnings and nothing else.**
`readOnlyRootFilesystem` stays `false` because the entrypoint does
`mkdir -p data/cache data/locks data/log data/proxies data/temp-geolite` under `/etc/shlink`,
and the web client writes `servers.json` into its nginx root — the config scores that
`warning`, not `danger`.

An earlier draft of this document claimed the component added *no* warnings. That was wrong:
polaris scores the manifest, not the image, so `cpuLimitsMissing` and `runAsRootAllowed` were
each reported twice even though both images already run as non-root (UID 1001 and 101,
verified from their registry configs). Both are now set explicitly, which is what makes the
claim above true.

## Acceptance criteria

Post-deploy, each verified by running the command and reading the output:

1. `curl -sS https://s.cloudnativedays.fr/rest/health` → `{"status":"pass"}`.
2. Creating a link through the REST API succeeds:
   ```bash
   curl -sS -X POST https://s.cloudnativedays.fr/rest/v3/short-urls \
     -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
     -d '{"longUrl":"https://cloudnativedays.fr","customSlug":"test"}'
   ```
3. A **GET** of `https://s.cloudnativedays.fr/test` returns `302` with
   `Location: https://cloudnativedays.fr`. It must not be a HEAD: `RequestTracker.php`
   returns `false` from `shouldTrackRequest()` when the forwarded method is HEAD, so
   `curl -I` would return a correct-looking 302 while recording no visit — and criterion 5
   would then read an empty list as proof that privacy works.
4. `https://links.cloudnativedays.fr` prompts for basic auth, and after authenticating shows
   the CND France server already configured, with the `test` link listed.
5. **The privacy configuration demonstrably took effect**: the visit recorded in criterion 3
   exists (non-null), carries the referrer that request sent, and shows no IP address and no
   location. This is the acceptance test for the design's central claim, not a nicety — and
   a null visit means criterion 3 was run wrong, not that the privacy config is working.
6. A `Backup` object for `cnpg-shlink` reaches `completed` — triggered on demand right after
   rollout, not left until midnight, since it is the only proof the resealed Scaleway
   credentials authenticate against the backup path.

## Out of scope

- Migrating any existing short links — there are none.
- QR code generation workflows. Shlink provides the endpoint; how the comms team uses it is
  editorial.
- A shorter apex domain (e.g. `cndays.fr`). Shlink supports multiple domains natively, so
  this stays an additive change if the idea is revisited.
- Website analytics. Related, but a separate decision with a separate spec.
