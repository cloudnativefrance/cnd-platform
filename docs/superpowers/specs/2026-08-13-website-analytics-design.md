# Website analytics — design

Date: 2026-08-13
Component: `analytics` (namespace `cnd-analytics`, cluster `k8s-cndfrance-prod`)
Companion repo: `cloudnativefrance/website` (the tracker script tag)
Upstream: [Umami](https://umami.is) 3.3.0
Scope: audience measurement for the conference website. Event tracking, funnels and
campaign attribution are explicitly out of scope — see the end of this document.

## Goal

Answer "is the site getting traffic, to which pages, and from where" for
**`cloudnativedays.fr`**, self-hosted on the existing platform, without cookies and
without a consent banner.

Concretely: pageviews, top pages, referrers, and a visitors-per-day trend.

## Findings that shaped this design

- **The website has no analytics today.** Verified by grepping `~/Sources/cndfrance-website/src`
  for `plausible|umami|matomo|posthog|gtag|analytics`: every hit is Tailwind's
  `tracking-tight` utility class. `astro.config.mjs:33` declares exactly two integrations,
  `react()` and `sitemap()`, and the single `<script is:inline>` in
  `src/layouts/Layout.astro:80` is not a tracker. The only trace of intent is an archived
  planning line, `.planning.gsd-archive/milestones/v1.0-REQUIREMENTS.md:94` —
  "**V2-03**: Analytics dashboard integration (Plausible)".
- **The CNPG constraint eliminates most of the field.** Plausible Community Edition ships a
  whole `clickhouse/` configuration directory in its repo and requires ClickHouse alongside
  PostgreSQL; Matomo requires MySQL/MariaDB. Both would introduce a storage engine the
  cluster has no operator for — the same objection that decided Shlink over YOURLS in
  [the shortener design](2026-08-13-url-shortener-design.md). The candidates that run on
  plain PostgreSQL are **Umami** (Postgres-only as of v3) and **GoatCounter** (SQLite or
  Postgres). Umami was chosen for dashboard quality: the readers are the same non-technical
  comms team that uses the Shlink UI, and a dashboard nobody enjoys opening does not get
  opened.
- **The image tag was verified, not assumed.** Umami dropped its `mysql-`/`postgresql-`
  image split when v3 went Postgres-only, so the plain version tag is the Postgres image.
  Confirmed by digest equality on Docker Hub:
  `umamisoftware/umami:3.3.0` and `:postgresql-latest` are both
  `sha256:62ac5cff2e48beea540653fdfacf8e4477c0182226a4aebdc19813e773f8985a`.
- **Migrations run at startup.** `package.json` defines
  `start-docker: npm-run-all check-db update-tracker start-server`, and
  `scripts/check-db.js:76` calls `execSync('prisma migrate deploy')`. The same script
  queries `server_version_num`, so the documented PostgreSQL **v12.14+** floor is enforced
  at boot rather than failing obscurely later.
- **Umami authenticates itself.** It has built-in user accounts, so unlike the Shlink admin
  SPA this needs no ingress basic-auth gate.
- **`APP_SECRET` is required**, not optional: "a random string used to secure authentication
  tokens. Each installation should have a unique value."
- **Ad-blocking is a first-order concern for this audience, and Umami ships the mitigation.**
  `TRACKER_SCRIPT_NAME` (default `script.js`) and `COLLECT_API_ENDPOINT` (default
  `/api/send`) are supported env vars specifically for moving off the paths that filter
  lists match.
- **The tracker can scope itself to domains.** `data-domains` is "a comma-delimited list"
  matched against `window.location.hostname`. Without it, `website-staging` — which runs the
  same image from the same source at `staging.cloudnativedays.fr` — would silently pollute
  production statistics.
- **No external-dns.** DNS records are created manually, consistent with the website-staging,
  Ente and shortener specs.

## Architecture

```
  visitor ─▶ cloudnativedays.fr ──┐
                                  │ loads /cnd.js from the stats host,
                                  │ POSTs to /api/cnd
                                  ▼
            ┌─────────────────────────────────────┐
            │ stats.cloudnativedays.fr (Ingress)  │
            │   /cnd.js    tracker script         │
            │   /api/cnd   collection endpoint    │
            │   /          dashboard (own login)  │
            └──────────────┬──────────────────────┘
                    ┌──────▼──────┐     ┌──────────────────────┐
                    │   umami     │────▶│ cnpg-umami (2x)      │
                    │   3.3.0     │     │ pageviews, sessions  │
                    │   1 replica │     └──────────┬───────────┘
                    └─────────────┘                │ daily
                                     s3://cloudnativedaysfr/cnpg/umami
```

### Repository placement

A top-level domain directory, matching the repo's one-directory-per-domain taxonomy. It is
deliberately **not** folded into `website/`: that Flux Kustomization health-checks the
website Deployment, and an analytics outage must not be able to report the website as
unhealthy.

```
analytics/                                   ← manifests
namespaces/namespaces.yaml                   ← + cnd-analytics
clusters/k8s-cndfrance-prod/analytics.yaml   ← Flux Kustomization "cnd-analytics"
```

The Flux Kustomization mirrors `photos.yaml`: `path: ./analytics`, `prune: true`,
`interval: 2m0s`, `dependsOn: cnd-operators`, source `customer`, health checks on the
`umami` Deployment and the `cnpg-umami` Cluster.

### Manifests

| File | Contents |
|---|---|
| `kustomization.yaml` | `namespace: cnd-analytics` |
| `cnpg-cluster.yaml` | `cnpg-umami`: 2 instances, `initdb` database `umami` / owner `umami`, `node-local-retain` 10Gi, Scaleway `barmanObjectStore` → `s3://cloudnativedaysfr/cnpg/umami`, PodMonitor + relabelings |
| `cnpg-scheduled-backup.yaml` | daily at midnight |
| `umami-cnpg-secret.yaml` | SealedSecret, `kubernetes.io/basic-auth`: `username` / `password` |
| `umami-secret.yaml` | SealedSecret: `app-secret` |
| `cnd-france-scw-secret.yaml` | SealedSecret resealed into `cnd-analytics` |
| `deployment.yaml` | `umamisoftware/umami:3.3.0`, 1 replica |
| `service.yaml` | ClusterIP `umami`, port 3000 named `http` |
| `ingress.yaml` | `stats.cloudnativedays.fr`, letsencrypt, no basic auth |
| `.bootstrap.sh` | generates the DB password and `APP_SECRET`, reseals the Scaleway creds, writes all three SealedSecrets |

### Configuration

```yaml
# DB_PASSWORD must be declared BEFORE DATABASE_URL — Kubernetes expands $(VAR)
# against env vars defined earlier in the same container.
DB_PASSWORD:          from umami-cnpg-secret
DATABASE_URL:         postgresql://umami:$(DB_PASSWORD)@cnpg-umami-rw:5432/umami
APP_SECRET:           from umami-secret
DISABLE_TELEMETRY:    "1"
TRACKER_SCRIPT_NAME:  cnd.js
COLLECT_API_ENDPOINT: /api/cnd
```

Umami wants a single `DATABASE_URL`. Sealing the whole connection string would bake the
hostname into a secret and force a reseal on any topology change, so the password is sealed
alone and the URL is composed at pod start.

**This only works because the bootstrap generates URL-safe passwords** (`tr '/+' '_-'`, `=`
stripped), exactly as the shortener's script does. A raw base64 password containing `/`
would corrupt the URL and produce a confusing authentication failure rather than a parse
error.

### Probes and resources

Both probes hit `/api/heartbeat`, which does not touch the database — an analytics outage
should degrade quietly rather than restart-loop.

| Container | CPU req | Mem req | Mem limit |
|---|---|---|---|
| `umami` (Next.js, Node 18.18+) | 100m | 384Mi | 512Mi |
| `cnpg-umami` ×2 | 100m | 256Mi | 256Mi |

Roughly 900Mi and 300m requested, capping at 1Gi — on top of the shortener's ~800Mi. Both
components together stay well inside the envelope that made Baserow untenable (commit
`88a8b26`), but they should be sized together rather than each in isolation.

## The ad-blocker problem

**A cloud-native conference audience runs ad blockers at far above the general rate.**
uBlock Origin's default lists match both the tracker's script path and known analytics
hostnames. Deployed with defaults, the instance would undercount substantially and give no
signal that it was doing so.

`TRACKER_SCRIPT_NAME: cnd.js` and `COLLECT_API_ENDPOINT: /api/cnd` defeat path-based rules.
They do **not** defeat a rule targeting the `stats.` hostname, should one ever be listed.

**Decision: ship the neutral names now.** The complete fix is serving the script same-origin
from `cloudnativedays.fr`, which requires an `ExternalName` Service inside `cnd-website`
(an Ingress can only route to Services in its own namespace) plus a path rule on the
website ingress. That is real coupling between two Flux Kustomizations for a v1 whose
requirement is "audience basics", so it is recorded here as a documented escalation, to be
taken only if the numbers look implausible against a known-good reference such as ticket
sales.

**Stated limitation, to be repeated in the component README:** the undercount is
*systematic*, not random. Trends and relative comparisons between pages and referrers stay
meaningful; absolute visitor numbers are a floor, not a count. Nobody should quote them to a
sponsor as a measured audience size.

## Website change (companion repo)

One tag in `cloudnativefrance/website` → `src/layouts/Layout.astro`, in `<head>`:

```html
<script defer
        src="https://stats.cloudnativedays.fr/cnd.js"
        data-website-id="<uuid generated in the Umami UI>"
        data-domains="cloudnativedays.fr,www.cloudnativedays.fr"
        data-do-not-track="true"></script>
```

- `data-website-id` is generated in the Umami dashboard after first login. It is **public by
  design** — it ships in the HTML — and is therefore not a secret and not sealed.
- `data-domains` is what keeps `staging.cloudnativedays.fr` out of the production numbers.
  Both the apex and `www` are listed because the website ingress serves both.
- `data-do-not-track` honours the browser's DNT signal.

No component-level changes: the requirement is audience basics, so no `data-umami-event`
attributes anywhere.

## Privacy posture

Umami is cookieless and stores no personal data — a visitor is a server-side salted hash,
rotated. Nothing in this deployment writes a client-side identifier.

That property is what makes operating without a consent banner defensible for audience
measurement under CNIL guidance. **This document states a technical property; it is not
legal advice.** Two follow-ups belong to whoever owns the site's legal pages
(`src/layouts/LegalPageLayout.astro` exists in the website repo):

- Confirm the no-banner approach for this configuration.
- Add an analytics mention to the privacy page naming the tool, what is collected, and that
  it is self-hosted.

`DISABLE_TELEMETRY: "1"` stops the instance reporting its own usage upstream.

## Failure modes

| Failure | Behaviour | Mitigation |
|---|---|---|
| Postgres unavailable | Dashboard and collection fail | CNPG 2 instances, automatic failover |
| Analytics down entirely | **The website is unaffected** — the tag is `defer` and cross-origin | No coupling to the site's availability |
| Postgres older than 12.14 | Startup fails fast in `check-db.js` | Version floor enforced at boot, not silently |
| Rollout / node drain | Brief collection gap; pageviews in that window are lost | Accepted — analytics is not a system of record |
| Staging traffic recorded | Would inflate production numbers | `data-domains` excludes it |
| Ad blockers | Systematic undercount | Neutral script/endpoint names; documented escalation |

## Validation

```bash
./scripts/validate-manifests.sh    # kustomize render → polaris audit
```

`readOnlyRootFilesystem` stays `false` (Next.js writes a cache). The container sets
`allowPrivilegeEscalation: false`, resource requests and both probes, so it adds nothing to
the warning pile documented in `.polaris.yaml`.

## Acceptance criteria

Each verified by running the command and reading the output:

1. `curl -sSI https://stats.cloudnativedays.fr/` returns 200 and the login page loads.
2. `curl -sS https://stats.cloudnativedays.fr/cnd.js | head -c 100` returns JavaScript —
   proving `TRACKER_SCRIPT_NAME` took effect and that `/script.js` is *not* the live path.
3. First login succeeds with the default `admin` account, and the password is changed
   immediately and stored in the password manager.
4. After adding the website in the UI and deploying the script tag, a visit to
   `https://cloudnativedays.fr` appears in the dashboard within a minute.
5. **A visit to `https://staging.cloudnativedays.fr` does *not* appear.** This is the
   acceptance test for `data-domains`, and the one most likely to be silently wrong.
6. The browser devtools Network tab shows the collection POST going to `/api/cnd`, not
   `/api/send`.
7. A `Backup` object for `cnpg-umami` reaches `completed` after the first scheduled run.

## Out of scope

- **Event tracking on CTAs** (ticket button, CFP submit, sponsor deck). Requires
  `data-umami-event` attributes on individual components; additive later.
- **Campaign attribution / UTM reporting.** Umami records them, but wiring short links to
  carry UTM parameters is a shortener-side editorial decision.
- **Conversion funnels.** Checkout happens in Alf.io on a different domain, so any funnel
  would be truncated at the most interesting step.
- **Unifying with the shortener's statistics.** Shlink forwards visits to Matomo and nothing
  else; adopting Matomo to unify would reintroduce MySQL. The two dashboards stay separate,
  deliberately.
- **Same-origin script proxying.** Documented above as an escalation, not built now.
