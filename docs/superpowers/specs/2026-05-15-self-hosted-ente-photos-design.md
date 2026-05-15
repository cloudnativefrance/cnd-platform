# Self-hosted Ente for CND photos — design

**Status:** Approved, ready for implementation plan
**Date:** 2026-05-15
**Owner:** smana

## Why

The CND France website currently links its 2026 edition gallery at
`src/lib/editions-data.ts:51-52` to a public album on `albums.ente.io` — the
hosted Ente cloud. The goal is to migrate that gallery (and future editions)
onto a self-hosted Ente instance running on this cluster, so photo storage
follows the same self-hosted / GitOps posture as the rest of the platform
(Baserow, Matrix, Mattermost, Pretalx).

The website integration shape is preserved: the public-facing URL stays
`https://albums.<host>/?t=<TOKEN>#<KEY>`, only `<host>` swaps from
`ente.io` to `cloudnativedays.fr`.

## Scope

**In scope:**

- A new top-level `photos/` directory in this repo deploying Museum (Ente's Go
  backend) + a CloudNativePG cluster + three Ente web frontends (photos,
  albums, accounts) — all wrapped in a new Flux Kustomization.
- A new Scaleway bucket `cnd-ente-photos` for encrypted blob storage.
- Reuse of existing infra: Brevo SMTP (for OTP email transport), the existing
  Scaleway access key (works across buckets), nginx ingress + cert-manager,
  Flux + image automation, SealedSecrets.
- Image build pipeline for the 3 web frontends, living inside the existing
  `cndfrance-website` repo under `dockerfiles/ente-web/`, pinned to a
  specific upstream `ente-io/ente` commit SHA.
- One-time cutover PR to `cndfrance-website` swapping
  `EDITION_2026.galleryUrl` to the self-hosted URL.

**Out of scope (deferred):**

- S3 blob backup beyond Scaleway's native durability (cross-region replication,
  out-of-provider sync).
- PodMonitor / Grafana dashboard for Museum.
- Per-user storage quotas.
- Resource right-sizing after observing real traffic.
- Migration of Baserow off Brevo onto Workspace SMTP.

## Audience & usage model

- **Organizers** (~5–10 accounts): create accounts via email OTP, upload photos
  through the Ente desktop or mobile app pointed at the self-hosted museum.
- **Attendees**: never sign up. They view photos exclusively through public
  shared-album links rendered by `albums.cloudnativedays.fr`. Those links are
  embedded in the `cndfrance-website` marketing site.
- **Email volume:** tens of OTP emails per month — Brevo's free tier is
  enormously over-provisioned for this.

## Architecture

```
                                      ┌───────────────────────────────┐
External:                             │ Scaleway S3 (fr-par)          │
                                      │ s3://cnd-ente-photos          │
                                      │ (encrypted blobs, root-level) │
                                      └──────────────▲────────────────┘
                                                     │
                              ┌──── api.photos.cloudnativedays.fr ────┐
                              │                                       │
                       ┌──────┴─────┐    metadata    ┌────────────────┴──┐
                       │  Museum    │◀──────────────▶│ CNPG cnpg-ente    │
                       │  (Go)      │                │ 2 instances, 10Gi │
                       └──────▲─────┘                └───────────────────┘
                              │ build-time endpoint baked in
        ┌─────────────────────┼──────────────────────┐
        │                     │                      │
   ┌────┴────────┐     ┌──────┴───────┐      ┌───────┴────────┐
   │ albums.*    │     │ photos.*     │      │ accounts.*     │
   │ (PUBLIC —   │     │ (organizer   │      │ (OTP login     │
   │  embedded   │     │  upload UI)  │      │  flow)         │
   │  by         │     └──────────────┘      └────────────────┘
   │  cndfrance- │
   │  website)   │
   └─────────────┘

All four hostnames terminate at the existing nginx ingress + cert-manager
(letsencrypt) — class `public`. SMTP egress goes to smtp-relay.brevo.com.
```

### Component summary

| Component       | Image                                                     | Replicas | Resources (req → lim)                    | Persistence                |
|-----------------|-----------------------------------------------------------|----------|------------------------------------------|----------------------------|
| Museum          | `ghcr.io/ente-io/museum:<pinned-tag>`                     | 1        | 200m / 256Mi → — / 512Mi                 | none (state in PG + S3)    |
| CNPG cnpg-ente  | upstream cloudnative-pg                                   | 2        | 200m / 768Mi → — / 768Mi                 | 10Gi / `node-local-retain` |
| ente-web-photos | `ghcr.io/cloudnativefrance/ente-web-photos:<bumped>`      | 1        | 50m / 64Mi → — / 128Mi                   | none (nginx + static)      |
| ente-web-albums | `ghcr.io/cloudnativefrance/ente-web-albums:<bumped>`      | 1        | 50m / 64Mi → — / 128Mi                   | none                       |
| ente-web-accts  | `ghcr.io/cloudnativefrance/ente-web-accounts:<bumped>`    | 1        | 50m / 64Mi → — / 128Mi                   | none                       |

Sizing rationale: Museum echoes Baserow's backend memory profile; webs are
plain nginx + small SPA bundles, minimal footprint. Revisit after a week.

## Repository layout

New top-level `photos/` directory. New entries also touch
`namespaces/namespaces.yaml`, `clusters/k8s-cndfrance-prod/`, and
`flux/image-automation/`.

```
cnd-platform/
├── namespaces/
│   └── namespaces.yaml                  ← add Namespace cnd-photos
├── clusters/k8s-cndfrance-prod/
│   └── photos.yaml                      ← NEW — Flux Kustomization cnd-photos
├── flux/image-automation/
│   └── ente-web.yaml                    ← NEW — 3× ImageRepository/Policy/UpdateAutomation
└── photos/                              ← NEW
    ├── kustomization.yaml
    │
    ├── cnpg-cluster.yaml                ← Cluster cnpg-ente (2 inst, 10Gi)
    ├── cnpg-scheduled-backup.yaml       ← daily → s3://cloudnativedaysfr/cnpg/ente
    ├── cnpg-secret.yaml                 ← SealedSecret ente-cnpg-secret
    │
    ├── cnd-france-scw-secret.yaml       ← SealedSecret (resealed for cnd-photos ns)
    ├── brevo-smtp-secret.yaml           ← SealedSecret (resealed for cnd-photos ns)
    ├── museum-secret.yaml               ← SealedSecret museum-secret
    │
    ├── museum-config.yaml               ← ConfigMap containing museum.yaml
    ├── museum.yaml                      ← Deployment + Service + Ingress
    ├── web-photos.yaml                  ← Deployment + Service + Ingress
    ├── web-albums.yaml                  ← Deployment + Service + Ingress
    └── web-accounts.yaml                ← Deployment + Service + Ingress
```

Naming choices locked in: top-level dir named `photos/` (by purpose, matching
`communication/` / `ticketing/`), files grouped 1-per-component
(Deployment+Service+Ingress in one file).

## Museum configuration

Museum reads a YAML config file (`museum.yaml`) with non-secret values, and
overlays secrets via env vars using the upstream convention
`ENTE_<NESTED_KEY>` (e.g. `ENTE_DB_PASSWORD` → `db.password`).

### ConfigMap `museum-config` (museum.yaml)

```yaml
db:
  host: cnpg-ente-rw
  port: 5432
  name: ente_db
  user: ente
  # password ← env ENTE_DB_PASSWORD

s3:
  are_local_buckets: false
  use_path_style_urls: true
  hot_storage:
    primary: scw-fr-par
  scw-fr-par:
    endpoint: s3.fr-par.scw.cloud
    region: fr-par
    bucket: cnd-ente-photos
    # key/secret ← env

smtp:
  host: smtp-relay.brevo.com
  port: 587
  username: 8f026a001@smtp-brevo.com   # same Brevo account as Baserow
  email: communication@cloudnativedays.fr  # existing Workspace alias
  # password ← env

apps:
  public-albums: https://albums.cloudnativedays.fr
  accounts:      https://accounts.photos.cloudnativedays.fr

webauthn:
  rpid: photos.cloudnativedays.fr
  rporigins:
    - https://photos.cloudnativedays.fr

internal:
  admins: [1]   # bootstrap admin user_id, set after first signup (see Cutover §step 9)
```

**Note on schema drift:** Museum's config schema evolves with upstream. Exact
key names (especially `hot_storage.primary` and env-var binding semantics)
must be verified against `museum/configurations/local.yaml` at the pinned
`ente-io/ente` SHA before implementation. If keys have renamed, the design
shape is unchanged — only field names update.

### Secrets

All sealed using `kubeseal --namespace cnd-photos`. Five distinct sealed
secrets:

| SealedSecret             | Keys                                                    | Source                                     |
|--------------------------|---------------------------------------------------------|--------------------------------------------|
| `ente-cnpg-secret`       | `password`, `username`                                  | Random 32-char password, generated once    |
| `cnd-france-scw-secret`  | `access-key-id`, `secret-access-key`, `region`          | Existing Scaleway key, resealed for new ns |
| `brevo-smtp`             | `password`                                              | Existing Brevo SMTP password, resealed     |
| `museum-secret`          | `key.encryption`, `key.hash`, `jwt.secret`              | `openssl rand -base64 {32,64,32}` once     |

Museum pod mounts:

- `museum-config` ConfigMap → `/museum.yaml`
- `envFrom` / `env`:
  - `ente-cnpg-secret` → `ENTE_DB_PASSWORD`
  - `cnd-france-scw-secret` → S3 key/secret for the `scw-fr-par` storage entry
  - `brevo-smtp` → `ENTE_SMTP_PASSWORD`
  - `museum-secret` → encryption key, hash key, JWT secret

**Env-var naming note:** Museum uses an uppercase env-var override convention
roughly mapping `key.encryption` → `ENTE_KEY_ENCRYPTION`. The exact transform
for nested keys containing hyphens (e.g. `scw-fr-par`) is upstream-version
dependent — some versions accept hyphenated keys via a `--` separator, others
require renaming the storage entry to an underscore-friendly name. The exact
env var spellings (and whether to rename `scw-fr-par` to e.g. `scwfrpar` in
config) are confirmed against the pinned `ente-io/ente` SHA at implementation
time.

## Frontends — build pipeline

The three web apps (`photos`, `albums`, `accounts`) are SPAs from
`ente-io/ente/web/apps/*`. They bake the museum endpoint at build time via
`NEXT_PUBLIC_ENTE_ENDPOINT` (and per-app endpoint vars); there is no runtime
config option. So each environment-specific deployment needs its own image
trio.

### Repo: `cndfrance-website` (existing)

```
cndfrance-website/
├── Dockerfile                          # existing — marketing site
├── dockerfiles/
│   └── ente-web/                       # NEW
│       ├── Dockerfile.photos
│       ├── Dockerfile.albums
│       ├── Dockerfile.accounts
│       └── nginx.conf
├── ente-web.pin                        # NEW — single line: ente-io/ente commit SHA
└── .github/workflows/
    ├── build-image.yml                 # existing
    └── build-ente-web.yml              # NEW
```

### Each Dockerfile

Two stages:

1. **Build** (`node:22-alpine`): `git clone --depth=1 --branch=<sha from
   ente-web.pin> https://github.com/ente-io/ente`, install pnpm, `cd web`,
   `pnpm install`, set the relevant `NEXT_PUBLIC_*` endpoint env vars,
   `pnpm build:<app>`.
2. **Serve** (`nginx:alpine`): copy `out/` into `/usr/share/nginx/html`, ship a
   minimal SPA-friendly nginx.conf (try_files → /index.html).

### CI workflow `build-ente-web.yml`

- Triggers: push to main when `ente-web.pin` or `dockerfiles/ente-web/**` changes; plus `workflow_dispatch`.
- Builds all 3 images in a matrix.
- Tags as `main-<short-sha>-<unix>` (matching the existing website tag format,
  e.g. `ghcr.io/cloudnativefrance/website:main-836e181-1778229415`).
- Pushes to `ghcr.io/cloudnativefrance/ente-web-{photos,albums,accounts}`.

### Flux image automation

Three new `ImageRepository` + `ImagePolicy` + `ImageUpdateAutomation` entries
in `flux/image-automation/ente-web.yaml`. Same pattern as the existing
website automation: Flux watches GHCR for new tags matching the
`main-*-<unix>` format, picks the latest by unix timestamp, opens a PR
bumping the image tag in the corresponding `photos/web-*.yaml`.

## Operational prerequisites

Performed once, in order, outside the Flux loop:

1. **Scaleway** — create bucket `cnd-ente-photos` in `fr-par`. No lifecycle
   rule (blob deletion is Museum's GC responsibility, not S3's). Same access
   key as today applies.
2. **Google Workspace** — reuse existing alias `communication@cloudnativedays.fr` as the OTP From address (no new mailbox needed). If you'd rather scope a dedicated mailbox per app later, swap it in via `smtp.email` and re-deploy.

    Historical / superseded:
    Original design proposed creating `photos@cloudnativedays.fr` as a user, alias,
   or group with delegate. Confirm Brevo SPF/DKIM records still cover
   `cloudnativedays.fr` (they do, since `baserow@cloudnativedays.fr` sends
   today).
3. **DNS** — 4 A records at the existing DNS provider, all pointing at the
   same ingress IP as `br.cloudnativedays.fr`:
   - `api.photos.cloudnativedays.fr`
   - `photos.cloudnativedays.fr`
   - `albums.cloudnativedays.fr`
   - `accounts.photos.cloudnativedays.fr`
4. **Generate secret values** and seal them:
   ```bash
   openssl rand -base64 32   # key.encryption
   openssl rand -base64 64   # key.hash
   openssl rand -base64 32   # jwt.secret
   openssl rand -base64 24   # postgres password
   ```
   Seal all 4 + the resealed Scaleway/Brevo creds for `cnd-photos` ns.
5. **`cndfrance-website` PR** — add `dockerfiles/ente-web/`, `ente-web.pin`,
   `.github/workflows/build-ente-web.yml`. Merge → first GHCR images pushed.
   **Must complete before the cnd-platform PR**, otherwise pods land in
   `ImagePullBackOff`.

## Deploy

6. **`cnd-platform` PR** adds:
   - `namespaces/namespaces.yaml` → `cnd-photos` ns
   - `clusters/k8s-cndfrance-prod/photos.yaml` → Flux Kustomization, depends
     on `cnd-operators`, 2m interval
   - Full `photos/` dir
   - `flux/image-automation/ente-web.yaml`

   Merge → Flux applies. Museum + CNPG come up; web pods come up once their
   images are pulled.

## Post-deploy (one-time)

7. Sign up your own account via `photos.cloudnativedays.fr` → OTP email
   arrives via Brevo.
8. Read the resulting `user_id` from CNPG:
   ```bash
   kubectl -n cnd-photos exec -ti cnpg-ente-1 -- \
     psql -U postgres -d ente_db -c "SELECT user_id, email FROM users;"
   ```
9. Edit `museum-config` ConfigMap → `internal.admins: [<your-user-id>]`,
   restart museum deployment.
10. Promote additional organizers via Museum's admin CLI (no more ConfigMap
    edits beyond step 9).

## Migration cutover

11. From Ente Desktop on your laptop, switch the server endpoint in developer
    settings to `https://api.photos.cloudnativedays.fr`. Sign in with your
    organizer account. Re-upload the existing 2026 photo collection.
12. Create a new shared album, copy the public link. Format:
    `https://albums.cloudnativedays.fr/?t=<TOKEN>#<KEY>`.
13. PR to `cndfrance-website` swapping `EDITION_2026.galleryUrl` in
    `src/lib/editions-data.ts:51-52`. Merge → website rebuild → link live.

## Deferred / non-goals

Tracked here so they are not forgotten but explicitly out of scope for the
initial deploy:

- **Blob backup:** Scaleway provides 11×9s durability. Ente blobs are e2e
  encrypted but irreplaceable user data. Options to revisit: cross-region
  replication, daily blob sync to a second provider, or relying solely on
  Scaleway's durability + occasional manual export.
- **Observability:** Museum exposes Prometheus metrics. Add `PodMonitor` and a
  Grafana dashboard once core deploy is stable.
- **User storage quotas:** Museum supports `internal.user_storage` overrides.
  Not needed for ~10 organizer accounts but worth adding if open signup ever
  enabled.
- **Resource right-sizing:** Sizing in this doc is an educated starting point
  mirroring Baserow. Revisit after one week of real traffic.
- **Baserow SMTP migration:** If Workspace-native SMTP is desirable for
  Baserow too (dropping Brevo entirely), do that as a follow-up after Ente
  proves the pattern in a low-stakes app.

## Risks & mitigations

| Risk                                                        | Mitigation                                                                                                       |
|-------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------|
| Museum config schema drift between upstream releases        | Pin exact `ente-io/ente` SHA in `ente-web.pin` and re-verify config keys against that SHA at implementation time |
| Web frontend / Museum API version skew                      | Pin everything to the same SHA; bump in one coordinated PR                                                       |
| ImagePullBackOff on initial deploy if images are not pushed | Sequence: cndfrance-website PR merges and CI completes BEFORE cnd-platform PR merges                             |
| OTP emails land in spam                                     | Brevo + existing SPF/DKIM cover `cloudnativedays.fr`; verify by sending a test OTP to a Gmail address            |
| Lost museum encryption/hash/jwt keys                        | Generated once via openssl, sealed once; loss = total data unrecoverability. Keep an offline secure backup of the plaintext values at generation time, document where |
| Bucket misconfiguration (e.g. wrong region) breaks uploads  | Caught during post-deploy step 7 (signup + first upload test) before any real photos are migrated                |

## Decisions log

This section records design choices made during brainstorming with the
rationale. Useful when revisiting in 12 months.

- **Audience model:** Organizers upload, attendees view via public shared-album
  links. → Simplest footprint, no open signup, no per-user storage concerns.
- **Approach C (raw Kustomize manifests):** No maintained community Helm chart
  for Ente exists as of 2026-05; the proven community pattern is Kustomize +
  CNPG (developer-friendly.blog, Feb 2025). Matches this repo's existing
  `website/` precedent.
- **All 3 web frontends in-cluster on nginx pods:** Single TLS story, no
  separate static-hosting pipeline, single repo for both image build and
  deploy manifests.
- **Image build inside cndfrance-website repo:** Shared Node 22 / pnpm
  toolchain, fewer repos to maintain. Slight conflation of "marketing site"
  with "photo app frontends" accepted as a deliberate trade-off.
- **Pin to specific upstream SHA (manual bumps):** Reproducible, controls when
  upstream changes are adopted, important because museum/web compatibility
  matters and upstream tags are inconsistent for web apps.
- **Separate Scaleway bucket (`cnd-ente-photos`):** Ente doesn't natively
  prefix blobs; mixing with the shared bucket would scatter UUIDs at root
  level alongside Baserow and CNPG data. Same cost.
- **Hostname layout `photos.* / albums.* / accounts.* / api.photos.*`:**
  Follows the existing `br.* / br-backend.*` style.
- **SMTP via Brevo with `communication@cloudnativedays.fr` From address:** Brevo
  stays the transport (already wired, zero extra setup); Workspace mailbox
  owns the From identity so replies/bounces land in a real human-readable
  inbox.
- **Top-level dir `photos/`, files grouped 1-per-component:** Matches the
  naming style of `communication/` / `ticketing/`; grouped files keep file
  count manageable (~8 vs ~16).
