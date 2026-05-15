# Self-hosted Ente Photo Platform — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a self-hosted Ente Photos instance on the CND platform cluster, replacing the current dependency on hosted `albums.ente.io` for the website's 2026 gallery link.

**Architecture:** Raw Kustomize manifests under a new `photos/` top-level dir in `cnd-platform`, deploying Museum (Ente's Go backend) + a CloudNativePG cluster + three nginx-served SPA frontends (photos, albums, accounts). All wrapped in one Flux Kustomization. Image build pipeline for the three SPAs lives in the existing `cndfrance-website` repo under `dockerfiles/ente-web/`, pinned to an upstream `ente-io/ente` commit SHA.

**Tech Stack:** Kubernetes + Flux CD + CloudNativePG + nginx-unprivileged + Scaleway S3 + SealedSecrets + GitHub Actions + Docker.

**Reference spec:** `docs/superpowers/specs/2026-05-15-self-hosted-ente-photos-design.md` — read it first.

**Two repos in scope:**
- `cndfrance-website` (path: `/home/smana/Sources/cndfrance-website`) — image build pipeline
- `cnd-platform` (path: `/home/smana/Sources/cnd-platform`) — manifests + Flux wiring + the cutover PR

---

## File Structure

### In `cndfrance-website/` (Phase A)

| Path | Action | Responsibility |
|---|---|---|
| `dockerfiles/ente-web/Dockerfile.photos` | Create | Build the `photos` SPA from upstream Ente and bake the museum endpoint at build time |
| `dockerfiles/ente-web/Dockerfile.albums` | Create | Same, for the public-albums viewer SPA |
| `dockerfiles/ente-web/Dockerfile.accounts` | Create | Same, for the accounts/OTP-login SPA |
| `dockerfiles/ente-web/nginx.conf` | Create | Shared nginx config: rootless, SPA `try_files`, security headers |
| `ente-web.pin` | Create | Single-line file holding the pinned `ente-io/ente` commit SHA — source of truth for upstream version |
| `.github/workflows/build-ente-web.yml` | Create | Matrix-builds the 3 images and pushes to GHCR with tag `main-<sha>-<unix>` |

### In `cnd-platform/` (Phase C)

| Path | Action | Responsibility |
|---|---|---|
| `namespaces/namespaces.yaml` | Modify | Add `cnd-photos` namespace |
| `clusters/k8s-cndfrance-prod/photos.yaml` | Create | Flux Kustomization `cnd-photos`, depends on `cnd-operators` |
| `photos/kustomization.yaml` | Create | List of all resources, namespace `cnd-photos` |
| `photos/cnpg-cluster.yaml` | Create | CNPG `Cluster` `cnpg-ente`, 2 instances, 10Gi |
| `photos/cnpg-scheduled-backup.yaml` | Create | Daily CNPG backup → `s3://cloudnativedaysfr/cnpg/ente` |
| `photos/cnpg-secret.yaml` | Create | SealedSecret `ente-cnpg-secret` (postgres password) |
| `photos/cnd-france-scw-secret.yaml` | Create | SealedSecret with Scaleway creds, resealed for `cnd-photos` ns |
| `photos/brevo-smtp-secret.yaml` | Create | SealedSecret with Brevo SMTP password, resealed for `cnd-photos` ns |
| `photos/museum-secret.yaml` | Create | SealedSecret `museum-secret` (encryption + hash + JWT) |
| `photos/museum-config.yaml` | Create | ConfigMap holding `museum.yaml` |
| `photos/museum.yaml` | Create | Museum Deployment + Service + Ingress |
| `photos/web-photos.yaml` | Create | photos-web Deployment + Service + Ingress |
| `photos/web-albums.yaml` | Create | albums-web Deployment + Service + Ingress |
| `photos/web-accounts.yaml` | Create | accounts-web Deployment + Service + Ingress |
| `flux/image-automation/ente-web.yaml` | Create | 3× ImageRepository/ImagePolicy/ImageUpdateAutomation |
| `flux/image-automation/kustomization.yaml` | Modify | Reference the new file |

### In `cndfrance-website/` (Phase D — cutover)

| Path | Action | Responsibility |
|---|---|---|
| `src/lib/editions-data.ts` | Modify | Swap `EDITION_2026.galleryUrl` from `albums.ente.io` to `albums.cloudnativedays.fr` |

---

## Conventions used throughout this plan

- All shell commands are listed with the working directory shown as a `cd` prefix or noted before the snippet.
- `cnd-platform` uses **SealedSecrets** (kind: `bitnami.com/v1alpha1`). The `kubeseal` CLI must be available locally and configured against this cluster's controller. See [bitnami-labs/sealed-secrets](https://github.com/bitnami-labs/sealed-secrets).
- `cnd-platform` commit message style is conventional commits, scope = component name (e.g. `feat(photos): …`, `fix(photos): …`). One logical change per commit.
- `cndfrance-website` commit message style is conventional commits per `CONTRIBUTING.md`. For this work the scope is `ente-web` (not a website phase).
- No `Co-Authored-By:` lines on any commit.
- "Verify" steps **must pass** before the next task starts.
- After each task, push the branch and confirm CI is green where applicable.

---

## Phase A — Image build pipeline in `cndfrance-website`

This phase must complete and **first GHCR images must be pushed** before Phase C, otherwise pods will land in `ImagePullBackOff`.

### Task A1: Create branch + add nginx.conf + pin file

**Files:**
- Create: `cndfrance-website/dockerfiles/ente-web/nginx.conf`
- Create: `cndfrance-website/ente-web.pin`

- [ ] **Step 1: Create a feature branch in cndfrance-website**

```bash
cd /home/smana/Sources/cndfrance-website
git checkout main
git pull --ff-only
git checkout -b feat/ente-web-build
```

- [ ] **Step 2: Create the shared nginx.conf**

This mirrors `cndfrance-website/nginx/nginx.conf` (rootless, listens 8080, SPA-friendly), trimmed of the website-specific redirects.

```bash
mkdir -p dockerfiles/ente-web
```

Create `dockerfiles/ente-web/nginx.conf`:

```nginx
worker_processes auto;

# nginx-unprivileged runs as uid 101 and cannot write to /run.
pid /tmp/nginx.pid;

events {
  worker_connections 1024;
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  sendfile on;

  server {
    listen 8080;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    # Gzip text + JSON + JS
    gzip on;
    gzip_min_length 1000;
    gzip_proxied expired no-cache no-store private auth;
    gzip_types text/plain text/css application/json application/javascript
               application/x-javascript text/xml application/xml
               application/xml+rss text/javascript image/svg+xml;

    # Cache static assets aggressively
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
      expires 1y;
      add_header Cache-Control "public, immutable";
    }

    # SPA fallback — public-album URLs use a query+hash like
    # /?t=<TOKEN>#<KEY>, so serving /index.html for any non-asset path is
    # exactly what we want.
    location / {
      try_files $uri $uri/index.html /index.html;
    }

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
  }
}
```

- [ ] **Step 3: Create the upstream pin file**

```bash
# Pick a recent commit from main of https://github.com/ente-io/ente.
# Choose one that has a passing CI run — check the GitHub Actions tab.
# Example value below is illustrative; pick a current SHA at impl time.
echo "REPLACE_WITH_RECENT_ENTE_SHA" > ente-web.pin
```

The `ente-web.pin` file must contain **exactly one line**: a full 40-char `ente-io/ente` commit SHA, with a trailing newline. This is the source of truth for which upstream version is built into our images.

- [ ] **Step 4: Verify the files exist and look right**

```bash
ls -la dockerfiles/ente-web/nginx.conf ente-web.pin
cat ente-web.pin
```

Expected: `nginx.conf` exists, `ente-web.pin` contains exactly one SHA-looking string.

- [ ] **Step 5: Commit**

```bash
git add dockerfiles/ente-web/nginx.conf ente-web.pin
git commit -m "feat(ente-web): nginx config and upstream pin file

Shared SPA-friendly nginx config and a single-source-of-truth pin file
holding the ente-io/ente commit SHA the images are built against."
```

---

### Task A2: Add the 3 Dockerfiles

**Files:**
- Create: `cndfrance-website/dockerfiles/ente-web/Dockerfile.photos`
- Create: `cndfrance-website/dockerfiles/ente-web/Dockerfile.albums`
- Create: `cndfrance-website/dockerfiles/ente-web/Dockerfile.accounts`

All three Dockerfiles share the same structure. They differ only in:
- which `yarn build:<app>` script is run
- which `web/apps/<app>/out` directory is copied

**Important note on env-var names:** The Ente web monorepo's exact `NEXT_PUBLIC_*` variable names have changed over time. At the SHA pinned during initial implementation (`4e97df9e…`), the supported variables are documented in `web/apps/photos/.env` and `web/apps/albums/.env`:

- `NEXT_PUBLIC_ENTE_ENDPOINT` — museum API URL
- `NEXT_PUBLIC_ENTE_ALBUMS_ENDPOINT` — public-albums viewer URL
- `NEXT_PUBLIC_ENTE_PHOTOS_ENDPOINT` — photos SPA URL (used by albums to hand off join/login flows back to photos)

**`NEXT_PUBLIC_ENTE_ACCOUNTS_URL` is explicitly disallowed** at this SHA — `web/packages/base/next.config.base.js` hard-exits the build if it's set, with a message instructing to use `apps.accounts` in the museum configuration instead (which Task C6's `museum-config.yaml` already does). If at a future pinned SHA the env-var names have shifted again, re-run the pre-flight check below.

**Pre-flight check at any new SHA:**

```bash
ENTE_SHA="$(cat ente-web.pin)"
curl -fsSL "https://raw.githubusercontent.com/ente-io/ente/${ENTE_SHA}/web/package.json" \
  | jq -r '.scripts | to_entries[] | select(.key | startswith("build")) | "\(.key): \(.value)"'
# And check each app's .env for endpoint variable names:
for app in photos albums accounts; do
  curl -fsSL "https://raw.githubusercontent.com/ente-io/ente/${ENTE_SHA}/web/apps/${app}/.env"
done
```

- [ ] **Step 1: Create `Dockerfile.photos`**

```dockerfile
# Stage 1: Build the Ente photos SPA from a pinned upstream commit.
FROM node:22-alpine AS build

ARG ENTE_SHA
ARG MUSEUM_ENDPOINT=https://api.photos.cloudnativedays.fr
ARG ALBUMS_ENDPOINT=https://albums.cloudnativedays.fr
ARG PHOTOS_ENDPOINT=https://photos.cloudnativedays.fr

RUN apk add --no-cache git python3 make g++

WORKDIR /src
# Shallow-clone then fetch the exact pinned SHA so the cache is reusable
# across runs that share an upstream version.
RUN git init && git remote add origin https://github.com/ente-io/ente.git \
    && git fetch --depth=1 origin "${ENTE_SHA}" \
    && git checkout FETCH_HEAD

RUN corepack enable && corepack prepare yarn@1.22.22 --activate

WORKDIR /src/web
RUN yarn install --frozen-lockfile

# Endpoint env vars baked at build time. NEXT_PUBLIC_ENTE_ACCOUNTS_URL is
# intentionally NOT set — it triggers a hard-exit in next.config.base.js
# at this SHA. The accounts URL is configured server-side in museum.yaml
# via apps.accounts (see Task C6).
ENV NEXT_PUBLIC_ENTE_ENDPOINT=${MUSEUM_ENDPOINT}
ENV NEXT_PUBLIC_ENTE_ALBUMS_ENDPOINT=${ALBUMS_ENDPOINT}
ENV NEXT_PUBLIC_ENTE_PHOTOS_ENDPOINT=${PHOTOS_ENDPOINT}

RUN yarn build:photos

# Stage 2: Serve the static export via nginx-unprivileged.
FROM nginxinc/nginx-unprivileged:1.27-alpine AS runtime
COPY dockerfiles/ente-web/nginx.conf /etc/nginx/nginx.conf
COPY --from=build /src/web/apps/photos/out /usr/share/nginx/html
```

- [ ] **Step 2: Create `Dockerfile.albums`** — identical except `yarn build:albums` and copying `web/apps/albums/out`.

Copy `Dockerfile.photos` to `Dockerfile.albums`, then change the **last two non-FROM lines** of stage 1:

```dockerfile
RUN yarn build:albums
```

And the copy in stage 2:

```dockerfile
COPY --from=build /src/web/apps/albums/out /usr/share/nginx/html
```

Every other line is byte-identical.

- [ ] **Step 3: Create `Dockerfile.accounts`** — identical except `yarn build:accounts` and copying `web/apps/accounts/out`.

Same change pattern.

- [ ] **Step 4: Sanity-check locally**

Pick the pinned SHA (e.g. `<SHA>` from `ente-web.pin`) and try building `Dockerfile.photos` end-to-end on your laptop:

```bash
cd /home/smana/Sources/cndfrance-website
docker build \
  --build-arg ENTE_SHA="$(cat ente-web.pin)" \
  -f dockerfiles/ente-web/Dockerfile.photos \
  -t ente-web-photos:local .
```

Expected: image builds, no errors. If `yarn build:photos` fails because the script name has changed upstream, fix the Dockerfile and the pin to a more recent SHA. Investigate before retrying with `--no-cache`.

- [ ] **Step 5: Smoke-test the image**

```bash
docker run --rm -d --name ente-web-photos-test -p 8080:8080 ente-web-photos:local
sleep 2
curl -sf http://localhost:8080/ | head -20
docker rm -f ente-web-photos-test
```

Expected: an HTML page comes back, no curl errors.

- [ ] **Step 6: Commit**

```bash
git add dockerfiles/ente-web/Dockerfile.photos \
        dockerfiles/ente-web/Dockerfile.albums \
        dockerfiles/ente-web/Dockerfile.accounts
git commit -m "feat(ente-web): Dockerfiles for photos/albums/accounts SPAs

Two-stage builds: yarn build against a pinned ente-io/ente commit with
museum endpoint env vars baked in, served via nginx-unprivileged."
```

---

### Task A3: Add the GitHub Actions workflow

**Files:**
- Create: `cndfrance-website/.github/workflows/build-ente-web.yml`

- [ ] **Step 1: Create the workflow file**

```yaml
# Builds the 3 Ente web SPA images (photos, albums, accounts) and pushes
# them to GHCR. Consumed by Flux image-automation in cnd-platform.
name: Build and Push Ente Web Images

on:
  push:
    branches: [main]
    paths:
      - 'dockerfiles/ente-web/**'
      - 'ente-web.pin'
      - '.github/workflows/build-ente-web.yml'
  pull_request:
    branches: [main]
    paths:
      - 'dockerfiles/ente-web/**'
      - 'ente-web.pin'
      - '.github/workflows/build-ente-web.yml'
  workflow_dispatch:

env:
  REGISTRY: ghcr.io
  IMAGE_OWNER: ${{ github.repository_owner }}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    strategy:
      fail-fast: false
      matrix:
        app: [photos, albums, accounts]
    env:
      IS_PUBLISH: ${{ github.event_name != 'pull_request' }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Read pinned Ente SHA
        id: pin
        run: echo "sha=$(tr -d '[:space:]' < ente-web.pin)" >> "$GITHUB_OUTPUT"

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        if: env.IS_PUBLISH == 'true'
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_OWNER }}/ente-web-${{ matrix.app }}
          tags: |
            type=sha,prefix=
            type=raw,value={{branch}}-{{sha}}-{{date 'X'}},enable={{is_default_branch}}
            type=raw,value=latest,enable={{is_default_branch}}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          file: dockerfiles/ente-web/Dockerfile.${{ matrix.app }}
          push: ${{ env.IS_PUBLISH }}
          build-args: |
            ENTE_SHA=${{ steps.pin.outputs.sha }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha,scope=ente-web-${{ matrix.app }}
          cache-to: type=gha,mode=max,scope=ente-web-${{ matrix.app }}
          platforms: linux/amd64
```

Notes on this workflow:

- Tag pattern `<branch>-<sha>-<unix-ts>` matches what Flux image-automation expects (see `cnd-platform/flux/image-automation/website.yaml` for the existing precedent). The unix timestamp is what Flux's `ImagePolicy` sorts on.
- Matrix builds all 3 apps in parallel.
- Buildx GHA cache is scoped per-app so independent layer caches don't trample each other.
- No Trivy scan in this initial workflow (we can add it later — Phase C focuses on getting Ente up; security scanning of upstream-derived images is a separate concern).

- [ ] **Step 2: Lint the workflow**

```bash
cd /home/smana/Sources/cndfrance-website
# actionlint is the standard linter for GitHub Actions YAML.
# If you don't have it: `go install github.com/rhysd/actionlint/cmd/actionlint@latest`
actionlint .github/workflows/build-ente-web.yml
```

Expected: no errors. If actionlint isn't installed locally, the GH Actions UI will surface syntax issues on push — the linter just catches them faster.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build-ente-web.yml
git commit -m "ci(ente-web): build and push the 3 SPA images to GHCR

Matrix build for photos/albums/accounts, tagged main-<sha>-<unix> to
match Flux image-automation's sortable tag convention."
```

---

### Task A4: Open PR, merge, verify GHCR images

- [ ] **Step 1: Push the branch**

```bash
cd /home/smana/Sources/cndfrance-website
git push -u origin feat/ente-web-build
```

- [ ] **Step 2: Open a PR via gh CLI**

```bash
gh pr create \
  --title "feat(ente-web): build pipeline for self-hosted Ente web SPAs" \
  --body "$(cat <<'EOF'
## Summary

Adds Docker build artifacts + GH Actions workflow to produce three Ente web
SPA images (photos, albums, accounts) for the self-hosted Ente deployment
landing in `cnd-platform`. See
`cnd-platform/docs/superpowers/specs/2026-05-15-self-hosted-ente-photos-design.md`
for the full design.

- `dockerfiles/ente-web/{Dockerfile.photos,Dockerfile.albums,Dockerfile.accounts}` — 2-stage builds (node:22 build → nginx-unprivileged serve)
- `dockerfiles/ente-web/nginx.conf` — shared SPA-friendly config
- `ente-web.pin` — single line, the ente-io/ente commit SHA all 3 images are built against
- `.github/workflows/build-ente-web.yml` — matrix build, tag pattern `main-<sha>-<unix>` matching Flux image-automation

## Test plan

- [ ] CI workflow runs and pushes 3 images to GHCR
- [ ] `ghcr.io/cloudnativefrance/ente-web-photos:main-<sha>-<unix>` exists
- [ ] `ghcr.io/cloudnativefrance/ente-web-albums:main-<sha>-<unix>` exists
- [ ] `ghcr.io/cloudnativefrance/ente-web-accounts:main-<sha>-<unix>` exists
EOF
)"
```

- [ ] **Step 3: Watch CI**

```bash
gh pr checks --watch
```

Expected: 3 matrix jobs all pass. If any fail, inspect logs (`gh run view <run-id> --log-failed`), fix in the same PR, push again.

- [ ] **Step 4: Merge**

After CI is green and a maintainer reviews (this is shared infra — get a second pair of eyes):

```bash
gh pr merge --squash --delete-branch
```

- [ ] **Step 5: Confirm published images**

After main builds, pull the digests:

```bash
# Replace <unix> with the actual timestamp shown in the GH Actions main run
for app in photos albums accounts; do
  gh api -H "Accept: application/vnd.github+json" \
    "/orgs/cloudnativefrance/packages/container/ente-web-${app}/versions" \
    --jq '.[0:3] | .[] | .metadata.container.tags'
done
```

Expected: each command lists tags including a `main-<sha>-<unix>` entry. Confirm those exact tag strings — you'll need them for verification in Phase C, though Flux image-automation will discover the latest automatically.

---

## Phase B — Manual prerequisites (out-of-cluster)

These are not git operations; they must complete before Phase C deploys, but they don't change files in the repos. Track them as a checklist.

### Task B1: Perform the one-time external setup

- [ ] **Scaleway bucket** — create `cnd-ente-photos` in `fr-par`. No lifecycle rule.

  ```bash
  # If you use the Scaleway CLI:
  scw object bucket create name=cnd-ente-photos region=fr-par
  ```

  Verify with: `scw object bucket get name=cnd-ente-photos region=fr-par`

- [ ] **Workspace alias** — reuse existing `communication@cloudnativedays.fr` (no new mailbox to create). Verify by sending a test email from a Gmail account; replies/bounces from Brevo will land in the existing inbox.

- [ ] **DNS** — add 4 A records (or CNAMEs to the cluster ingress hostname), all pointing at the same target as `br.cloudnativedays.fr`:
  - `api.photos.cloudnativedays.fr`
  - `photos.cloudnativedays.fr`
  - `albums.cloudnativedays.fr`
  - `accounts.cloudnativedays.fr`

  Verify:

  ```bash
  for h in api.photos photos albums accounts; do
    dig +short "${h}.cloudnativedays.fr"
  done
  dig +short br.cloudnativedays.fr
  ```

  Expected: the 4 lookups return the same address(es) as `br.cloudnativedays.fr`.

- [ ] **Generate the 4 secret plaintexts** locally and stash them in your password manager. Do **not** commit them, do not paste in chat. Save the seal output to `cnd-platform`, not the plaintext.

  ```bash
  # Museum config secrets
  echo "key.encryption=$(openssl rand -base64 32)"
  echo "key.hash=$(openssl rand -base64 64)"
  echo "jwt.secret=$(openssl rand -base64 32)"
  # CNPG postgres password (24 chars, no special-char headaches)
  echo "postgres.password=$(openssl rand -base64 24)"
  ```

  Save all 4 lines into your password manager under a vault entry titled
  e.g. "cnd-platform / ente / museum-secret + cnpg-secret". Losing
  `key.encryption` or `key.hash` means total irrecoverable user-data loss
  — back up the plaintexts somewhere durable (1Password vault export,
  encrypted offline copy, etc.).

- [ ] Confirm `kubeseal` is available and can reach the cluster's controller:

  ```bash
  kubeseal --version
  # Find the controller — it's deployed as a single pod, name often
  # `sealed-secrets-controller`, namespace varies (commonly kube-system or
  # sealed-secrets).
  kubectl --context k8s-cndfrance-prod get pods --all-namespaces \
    -l name=sealed-secrets-controller
  ```

  Expected: a kubeseal version is printed; one controller pod is running.
  Note the namespace it lives in — if `kubeseal` auto-detection fails in
  Tasks C3/C4/C5, you'll need to pass `--controller-namespace <ns>`.

---

## Phase C — Cluster manifests in `cnd-platform`

All work in this phase happens in `/home/smana/Sources/cnd-platform`.

### Task C1: Create branch + add namespace

**Files:**
- Modify: `cnd-platform/namespaces/namespaces.yaml`

- [ ] **Step 1: Branch**

```bash
cd /home/smana/Sources/cnd-platform
git checkout main
git pull --ff-only
git checkout -b feat/photos-ente
```

- [ ] **Step 2: Add the new namespace at the end of `namespaces/namespaces.yaml`**

Append:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: cnd-photos
```

- [ ] **Step 3: Validate**

```bash
kubectl apply --dry-run=client -f namespaces/namespaces.yaml
```

Expected: no errors, output includes `namespace/cnd-photos unchanged` (or `created` if cluster doesn't have it yet — but dry-run on client side doesn't check the cluster, so just confirm the yaml parses).

- [ ] **Step 4: Commit**

```bash
git add namespaces/namespaces.yaml
git commit -m "feat(photos): add cnd-photos namespace

Holds the self-hosted Ente deployment (Museum, CNPG, web SPAs)."
```

---

### Task C2: Create photos/kustomization.yaml skeleton + CNPG cluster + scheduled backup

**Files:**
- Create: `cnd-platform/photos/kustomization.yaml`
- Create: `cnd-platform/photos/cnpg-cluster.yaml`
- Create: `cnd-platform/photos/cnpg-scheduled-backup.yaml`

- [ ] **Step 1: Create the directory and the kustomization skeleton**

```bash
mkdir -p photos
```

Create `photos/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cnd-photos

resources:
  - cnpg-cluster.yaml
  - cnpg-scheduled-backup.yaml
```

(We'll append more resources to this list as tasks add files. Keeping this minimal at first lets each task validate `kustomize build` cleanly.)

- [ ] **Step 2: Create `photos/cnpg-cluster.yaml`**

Mirrors `project/baserow/cnpg-cluster.yaml`, with `ente`-specific names and the existing `cnd-france-scw-secret` (which we'll reseal for `cnd-photos` ns in Task C5):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cnpg-ente
spec:
  description: "PostgreSQL cluster for self-hosted Ente Museum"
  instances: 2

  bootstrap:
    initdb:
      database: ente_db
      owner: ente
      secret:
        name: ente-cnpg-secret

  superuserSecret:
    name: ente-cnpg-secret

  storage:
    storageClass: node-local-retain
    size: 10Gi

  backup:
    barmanObjectStore:
      destinationPath: "s3://cloudnativedaysfr/cnpg/ente"
      endpointURL: "https://s3.fr-par.scw.cloud"
      s3Credentials:
        accessKeyId:
          name: cnd-france-scw-secret
          key: access-key-id
        secretAccessKey:
          name: cnd-france-scw-secret
          key: secret-access-key
        region:
          name: cnd-france-scw-secret
          key: region
      wal:
        compression: gzip
      data:
        compression: gzip
    retentionPolicy: "90d"

  monitoring:
    customQueriesConfigMap:
      - key: queries
        name: cnpg-default-monitoring
    disableDefaultQueries: false
    enablePodMonitor: true
    podMonitorMetricRelabelings:
      - action: replace
        sourceLabels:
          - cluster
        targetLabel: cnpg_cluster
      - action: labeldrop
        regex: cluster

  resources:
    requests:
      memory: "768Mi"
      cpu: 200m
    limits:
      memory: "768Mi"
```

- [ ] **Step 3: Create `photos/cnpg-scheduled-backup.yaml`**

Mirrors the Baserow version:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: cnpg-ente
spec:
  schedule: "0 0 0 * * *"
  backupOwnerReference: self
  cluster:
    name: cnpg-ente
```

- [ ] **Step 4: Validate**

```bash
kustomize build photos/ | kubectl apply --dry-run=client -f -
```

Expected: errors complaining about missing `cnd-france-scw-secret` are **not** a real failure — that secret is added in Task C5. The kustomize build itself must succeed (yaml parses, no `kustomization.yaml` syntax errors). What you want to see is `cluster.postgresql.cnpg.io/cnpg-ente created` (dry-run) and similar for the ScheduledBackup. If kustomize errors out, the YAML is wrong — fix before continuing.

- [ ] **Step 5: Commit**

```bash
git add photos/kustomization.yaml photos/cnpg-cluster.yaml photos/cnpg-scheduled-backup.yaml
git commit -m "feat(photos): CNPG cluster cnpg-ente and scheduled backup

2-instance postgres on node-local-retain, 10Gi, daily backup to
s3://cloudnativedaysfr/cnpg/ente."
```

---

### Task C3: Seal the postgres password into `ente-cnpg-secret`

**Files:**
- Create: `cnd-platform/photos/cnpg-secret.yaml`
- Modify: `cnd-platform/photos/kustomization.yaml` (append entry)

- [ ] **Step 1: Generate the sealed secret**

Use the postgres password you stashed in Phase B (`postgres.password`). The
CNPG operator expects `username` + `password` fields in the secret.

Replace `<POSTGRES_PASSWORD>` below with the plaintext from your password manager:

`kubeseal` auto-detects the controller (no `--controller-namespace` flag needed unless your kubeconfig context can't reach it):

```bash
cat <<'EOF' | kubeseal --format yaml --namespace cnd-photos > photos/cnpg-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: ente-cnpg-secret
  namespace: cnd-photos
type: kubernetes.io/basic-auth
stringData:
  username: ente
  password: <POSTGRES_PASSWORD>
EOF
```

`kubeseal` produces a `SealedSecret` containing the encrypted ciphertext. Inspect the output file — it must contain `kind: SealedSecret`, an `encryptedData` map with both `username` and `password`, and `metadata.namespace: cnd-photos`.

- [ ] **Step 2: Append to kustomization.yaml**

Edit `photos/kustomization.yaml`, add the new file to `resources:`:

```yaml
resources:
  - cnpg-cluster.yaml
  - cnpg-scheduled-backup.yaml
  - cnpg-secret.yaml
```

- [ ] **Step 3: Validate**

```bash
kustomize build photos/ | grep -A2 "kind: SealedSecret"
```

Expected: the SealedSecret block is present, namespace is `cnd-photos`.

- [ ] **Step 4: Commit**

```bash
git add photos/cnpg-secret.yaml photos/kustomization.yaml
git commit -m "feat(photos): seal ente-cnpg-secret for CNPG bootstrap

Postgres credentials for the CNPG cluster cnpg-ente."
```

---

### Task C4: Reseal `cnd-france-scw-secret` and `brevo-smtp` for `cnd-photos` ns

**Files:**
- Create: `cnd-platform/photos/cnd-france-scw-secret.yaml`
- Create: `cnd-platform/photos/brevo-smtp-secret.yaml`
- Modify: `cnd-platform/photos/kustomization.yaml`

- [ ] **Step 1: Get the plaintexts from an existing namespace**

You need the **plaintext** values, not the SealedSecret ciphertext (which is sealed per-namespace and isn't reusable across namespaces).

```bash
# Scaleway creds (we read from cnd-project where Baserow uses them)
kubectl --context k8s-cndfrance-prod -n cnd-project get secret cnd-france-scw-secret \
  -o jsonpath='{.data}' | jq 'with_entries(.value |= @base64d)'

# Brevo SMTP creds (also from cnd-project)
kubectl --context k8s-cndfrance-prod -n cnd-project get secret brevo-smtp \
  -o jsonpath='{.data}' | jq 'with_entries(.value |= @base64d)'
```

Expected: prints JSON like `{"access-key-id":"SCWXXX","secret-access-key":"…","region":"fr-par"}` and `{"password":"…"}`.

Note the values **temporarily** — they will be re-sealed and the plaintext discarded.

- [ ] **Step 2: Seal `cnd-france-scw-secret` for `cnd-photos`**

Replace `<ACCESS_KEY_ID>`, `<SECRET_ACCESS_KEY>` below with the values read above:

```bash
cat <<'EOF' | kubeseal --format yaml --namespace cnd-photos > photos/cnd-france-scw-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cnd-france-scw-secret
  namespace: cnd-photos
type: Opaque
stringData:
  access-key-id: <ACCESS_KEY_ID>
  secret-access-key: <SECRET_ACCESS_KEY>
  region: fr-par
EOF
```

- [ ] **Step 3: Seal `brevo-smtp` for `cnd-photos`**

Replace `<BREVO_PASSWORD>` with the value read above:

```bash
cat <<'EOF' | kubeseal --format yaml --namespace cnd-photos > photos/brevo-smtp-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: brevo-smtp
  namespace: cnd-photos
type: Opaque
stringData:
  password: <BREVO_PASSWORD>
EOF
```

- [ ] **Step 4: Append both to kustomization.yaml**

```yaml
resources:
  - cnpg-cluster.yaml
  - cnpg-scheduled-backup.yaml
  - cnpg-secret.yaml
  - cnd-france-scw-secret.yaml
  - brevo-smtp-secret.yaml
```

- [ ] **Step 5: Validate**

```bash
kustomize build photos/ | grep -B1 "name: cnd-france-scw-secret\|name: brevo-smtp"
```

Expected: both SealedSecrets render with `namespace: cnd-photos`.

- [ ] **Step 6: Commit**

```bash
git add photos/cnd-france-scw-secret.yaml photos/brevo-smtp-secret.yaml photos/kustomization.yaml
git commit -m "feat(photos): reseal Scaleway and Brevo SMTP creds for cnd-photos

Same upstream credentials as cnd-project, sealed for the new namespace
so Museum can talk to S3 and Brevo from cnd-photos."
```

---

### Task C5: Seal `museum-secret` (encryption + hash + JWT)

**Files:**
- Create: `cnd-platform/photos/museum-secret.yaml`
- Modify: `cnd-platform/photos/kustomization.yaml`

- [ ] **Step 1: Seal museum-secret**

Replace `<KEY_ENCRYPTION>`, `<KEY_HASH>`, `<JWT_SECRET>` with the
plaintexts you generated in Phase B (`openssl rand -base64` outputs).

```bash
cat <<'EOF' | kubeseal --format yaml --namespace cnd-photos > photos/museum-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: museum-secret
  namespace: cnd-photos
type: Opaque
stringData:
  key-encryption: <KEY_ENCRYPTION>
  key-hash: <KEY_HASH>
  jwt-secret: <JWT_SECRET>
EOF
```

Why hyphens instead of dots in the secret keys: Kubernetes secret keys must
match `[-._a-zA-Z0-9]+` — dots are allowed but hyphens read more naturally
and we map them via `env:` definitions in the Museum Deployment (Task C7),
not via `envFrom`.

- [ ] **Step 2: Append to kustomization.yaml**

```yaml
resources:
  - cnpg-cluster.yaml
  - cnpg-scheduled-backup.yaml
  - cnpg-secret.yaml
  - cnd-france-scw-secret.yaml
  - brevo-smtp-secret.yaml
  - museum-secret.yaml
```

- [ ] **Step 3: Commit**

```bash
git add photos/museum-secret.yaml photos/kustomization.yaml
git commit -m "feat(photos): seal museum-secret (encryption + hash + JWT)

Three random keys generated once via openssl rand -base64 {32,64,32}.
Loss is unrecoverable; plaintexts archived in password manager."
```

---

### Task C6: Create `museum-config` ConfigMap

**Files:**
- Create: `cnd-platform/photos/museum-config.yaml`
- Modify: `cnd-platform/photos/kustomization.yaml`

- [ ] **Step 1: Create `photos/museum-config.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: museum-config
  namespace: cnd-photos
data:
  museum.yaml: |
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
      username: 8f026a001@smtp-brevo.com
      email: communication@cloudnativedays.fr
      # password ← env

    apps:
      public-albums: https://albums.cloudnativedays.fr
      accounts:      https://accounts.cloudnativedays.fr

    webauthn:
      rpid: photos.cloudnativedays.fr
      rporigins:
        - https://photos.cloudnativedays.fr

    internal:
      admins: []   # bootstrap admin user_id set after first signup (Phase D)
```

**Schema verification step (required before first deploy):**

At the pinned `ente-io/ente` SHA, fetch `server/configurations/local.yaml`
(or whatever the canonical example config is named at that SHA — historically
it's lived at `server/configurations/local.yaml` and earlier at
`museum/configurations/local.yaml`) and diff the structure against the
ConfigMap above. Adjust key names if any have shifted. The shape (one
section per concern, env overrides for secrets) is stable; only exact
field names may have drifted.

```bash
ENTE_SHA="$(cat /home/smana/Sources/cndfrance-website/ente-web.pin)"
curl -fsSL "https://raw.githubusercontent.com/ente-io/ente/${ENTE_SHA}/server/configurations/local.yaml" \
  | tee /tmp/upstream-museum-config.yaml
diff /tmp/upstream-museum-config.yaml <(yq '.data."museum.yaml"' photos/museum-config.yaml)
```

If the upstream uses different key names, edit `museum-config.yaml`
accordingly and re-run the diff. The Deployment (Task C7) maps env vars to
the matching upstream keys.

- [ ] **Step 2: Append to kustomization.yaml**

```yaml
resources:
  - cnpg-cluster.yaml
  - cnpg-scheduled-backup.yaml
  - cnpg-secret.yaml
  - cnd-france-scw-secret.yaml
  - brevo-smtp-secret.yaml
  - museum-secret.yaml
  - museum-config.yaml
```

- [ ] **Step 3: Validate**

```bash
kustomize build photos/ | grep -A50 "kind: ConfigMap"
```

Expected: the ConfigMap renders with the embedded museum.yaml content intact.

- [ ] **Step 4: Commit**

```bash
git add photos/museum-config.yaml photos/kustomization.yaml
git commit -m "feat(photos): museum.yaml ConfigMap

Non-secret config: db host, S3 endpoint, SMTP, app URLs, webauthn.
Schema verified against the pinned ente-io/ente SHA before deploy."
```

---

### Task C7: Create Museum Deployment + Service + Ingress

**Files:**
- Create: `cnd-platform/photos/museum.yaml`
- Modify: `cnd-platform/photos/kustomization.yaml`

- [ ] **Step 1: Create `photos/museum.yaml`**

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: museum
  namespace: cnd-photos
  labels:
    app.kubernetes.io/name: museum
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: ente
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: Recreate    # Museum singleton — avoid two pods racing on the same DB during upgrades
  selector:
    matchLabels:
      app.kubernetes.io/name: museum
  template:
    metadata:
      labels:
        app.kubernetes.io/name: museum
        app.kubernetes.io/component: api
        app.kubernetes.io/part-of: ente
    spec:
      containers:
        - name: museum
          # Pin a specific upstream tag; bump when upgrading. Verify the
          # tag exists at https://github.com/ente-io/ente/pkgs/container/museum
          image: ghcr.io/ente-io/museum:latest
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          # Museum reads /museum.yaml by default at startup.
          volumeMounts:
            - name: config
              mountPath: /museum.yaml
              subPath: museum.yaml
          env:
            - name: ENTE_DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ente-cnpg-secret
                  key: password
            # Museum's env-var override convention maps nested keys with
            # uppercase + underscores. The exact spelling for the
            # hyphenated storage entry name `scw-fr-par` is upstream-
            # version-dependent — verify at the pinned SHA. If hyphens are
            # not supported, rename the storage entry to `scwfrpar` in both
            # museum-config.yaml and these env names.
            - name: ENTE_S3_SCW-FR-PAR_KEY
              valueFrom:
                secretKeyRef:
                  name: cnd-france-scw-secret
                  key: access-key-id
            - name: ENTE_S3_SCW-FR-PAR_SECRET
              valueFrom:
                secretKeyRef:
                  name: cnd-france-scw-secret
                  key: secret-access-key
            - name: ENTE_SMTP_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: brevo-smtp
                  key: password
            - name: ENTE_KEY_ENCRYPTION
              valueFrom:
                secretKeyRef:
                  name: museum-secret
                  key: key-encryption
            - name: ENTE_KEY_HASH
              valueFrom:
                secretKeyRef:
                  name: museum-secret
                  key: key-hash
            - name: ENTE_JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: museum-secret
                  key: jwt-secret
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /ping
              port: http
            initialDelaySeconds: 30
            periodSeconds: 30
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ping
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
      volumes:
        - name: config
          configMap:
            name: museum-config
            items:
              - key: museum.yaml
                path: museum.yaml
---
apiVersion: v1
kind: Service
metadata:
  name: museum
  namespace: cnd-photos
  labels:
    app.kubernetes.io/name: museum
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
  selector:
    app.kubernetes.io/name: museum
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: museum
  namespace: cnd-photos
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    # Photo uploads can be large; keep parity with Baserow's body-size cap.
    nginx.ingress.kubernetes.io/proxy-body-size: "100M"
    nginx.ingress.kubernetes.io/client-body-buffer-size: "100M"
spec:
  ingressClassName: public
  rules:
    - host: api.photos.cloudnativedays.fr
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: museum
                port:
                  name: http
  tls:
    - hosts:
        - api.photos.cloudnativedays.fr
      secretName: museum-tls
```

**Notes:**
- `Recreate` rather than `RollingUpdate` because Museum holds an in-process lock table; running two pods briefly during a rolling update is asking for trouble. Single-replica downtime is fine for this use case.
- `/ping` is Museum's health endpoint. Verify against the pinned SHA — if it's been renamed, adjust.
- `ENTE_S3_SCW-FR-PAR_*` env names are upstream-version-dependent (see Task C6 schema verification step). If hyphens are not supported, rename the storage entry to `scwfrpar` in `museum-config.yaml`'s `s3.hot_storage.primary` and `s3.scw-fr-par:` → `s3.scwfrpar:`, and use `ENTE_S3_SCWFRPAR_*` here.

- [ ] **Step 2: Append to kustomization.yaml**

```yaml
resources:
  - cnpg-cluster.yaml
  - cnpg-scheduled-backup.yaml
  - cnpg-secret.yaml
  - cnd-france-scw-secret.yaml
  - brevo-smtp-secret.yaml
  - museum-secret.yaml
  - museum-config.yaml
  - museum.yaml
```

- [ ] **Step 3: Validate**

```bash
kustomize build photos/ | kubectl apply --dry-run=client -f -
```

Expected: `deployment.apps/museum created (dry run)`, `service/museum created (dry run)`, `ingress.networking.k8s.io/museum created (dry run)`. No errors.

- [ ] **Step 4: Commit**

```bash
git add photos/museum.yaml photos/kustomization.yaml
git commit -m "feat(photos): Museum Deployment, Service, Ingress

Singleton Go API server, env-var secret overlays, /ping liveness probe,
ingress at api.photos.cloudnativedays.fr with 100M body limit."
```

---

### Task C8: Create the photos-web Deployment + Service + Ingress

**Files:**
- Create: `cnd-platform/photos/web-photos.yaml`
- Modify: `cnd-platform/photos/kustomization.yaml`

- [ ] **Step 1: Create `photos/web-photos.yaml`**

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-photos
  namespace: cnd-photos
  labels:
    app.kubernetes.io/name: web-photos
    app.kubernetes.io/component: frontend
    app.kubernetes.io/part-of: ente
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: web-photos
  template:
    metadata:
      labels:
        app.kubernetes.io/name: web-photos
        app.kubernetes.io/component: frontend
        app.kubernetes.io/part-of: ente
    spec:
      containers:
        - name: web-photos
          # Placeholder tag — Flux image-automation will swap this for the
          # latest GHCR push. The `# {"$imagepolicy": ...}` marker is what
          # Flux looks for.
          image: ghcr.io/cloudnativefrance/ente-web-photos:latest # {"$imagepolicy": "flux-system:cnd-ente-web-photos"}
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
            periodSeconds: 30
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop:
                - ALL
---
apiVersion: v1
kind: Service
metadata:
  name: web-photos
  namespace: cnd-photos
  labels:
    app.kubernetes.io/name: web-photos
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
  selector:
    app.kubernetes.io/name: web-photos
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-photos
  namespace: cnd-photos
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
spec:
  ingressClassName: public
  rules:
    - host: photos.cloudnativedays.fr
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web-photos
                port:
                  name: http
  tls:
    - hosts:
        - photos.cloudnativedays.fr
      secretName: web-photos-tls
```

- [ ] **Step 2: Append to kustomization.yaml**

```yaml
  - web-photos.yaml
```

- [ ] **Step 3: Validate**

```bash
kustomize build photos/ | kubectl apply --dry-run=client -f -
```

Expected: all resources render, no errors.

- [ ] **Step 4: Commit**

```bash
git add photos/web-photos.yaml photos/kustomization.yaml
git commit -m "feat(photos): web-photos Deployment, Service, Ingress

Organizer-facing photos SPA on photos.cloudnativedays.fr. Image tag
managed by Flux image-automation (\$imagepolicy marker)."
```

---

### Task C9: Create the albums-web Deployment + Service + Ingress

**Files:**
- Create: `cnd-platform/photos/web-albums.yaml`
- Modify: `cnd-platform/photos/kustomization.yaml`

- [ ] **Step 1: Create `photos/web-albums.yaml`**

Copy `photos/web-photos.yaml` to `photos/web-albums.yaml` and replace, throughout the file:

| Old | New |
|---|---|
| `web-photos` | `web-albums` |
| `photos.cloudnativedays.fr` | `albums.cloudnativedays.fr` |
| `ente-web-photos` (image and image policy ref) | `ente-web-albums` |
| `web-photos-tls` | `web-albums-tls` |

Specifically the image line becomes:

```yaml
          image: ghcr.io/cloudnativefrance/ente-web-albums:latest # {"$imagepolicy": "flux-system:cnd-ente-web-albums"}
```

Every other line is identical (resources, probes, securityContext, etc.).

- [ ] **Step 2: Append to kustomization.yaml**

```yaml
  - web-albums.yaml
```

- [ ] **Step 3: Validate**

```bash
kustomize build photos/ | grep "host: albums"
```

Expected: `- host: albums.cloudnativedays.fr` appears.

- [ ] **Step 4: Commit**

```bash
git add photos/web-albums.yaml photos/kustomization.yaml
git commit -m "feat(photos): web-albums Deployment, Service, Ingress

Public-facing shared-album viewer on albums.cloudnativedays.fr.
The URL embedded by cndfrance-website's EDITION_2026.galleryUrl."
```

---

### Task C10: Create the accounts-web Deployment + Service + Ingress

**Files:**
- Create: `cnd-platform/photos/web-accounts.yaml`
- Modify: `cnd-platform/photos/kustomization.yaml`

- [ ] **Step 1: Create `photos/web-accounts.yaml`**

Same copy-and-rename pattern as Task C9. Substitutions:

| Old | New |
|---|---|
| `web-photos` | `web-accounts` |
| `photos.cloudnativedays.fr` | `accounts.cloudnativedays.fr` |
| `ente-web-photos` (image + policy) | `ente-web-accounts` |
| `web-photos-tls` | `web-accounts-tls` |

Image line:

```yaml
          image: ghcr.io/cloudnativefrance/ente-web-accounts:latest # {"$imagepolicy": "flux-system:cnd-ente-web-accounts"}
```

- [ ] **Step 2: Append to kustomization.yaml**

```yaml
  - web-accounts.yaml
```

- [ ] **Step 3: Validate**

```bash
kustomize build photos/ | grep "host: accounts"
```

Expected: `- host: accounts.cloudnativedays.fr` appears.

- [ ] **Step 4: Commit**

```bash
git add photos/web-accounts.yaml photos/kustomization.yaml
git commit -m "feat(photos): web-accounts Deployment, Service, Ingress

OTP-login SPA on accounts.cloudnativedays.fr. Required by photos and
albums SPAs to complete email-OTP authentication flows."
```

---

### Task C11: Wire the Flux Kustomization for `cnd-photos`

**Files:**
- Create: `cnd-platform/clusters/k8s-cndfrance-prod/photos.yaml`

- [ ] **Step 1: Create the Flux Kustomization**

Mirrors `clusters/k8s-cndfrance-prod/project.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1beta2
kind: Kustomization
metadata:
  name: cnd-photos
  namespace: flux-system
spec:
  prune: true
  interval: 2m0s
  path: ./photos
  dependsOn:
    - name: cnd-operators
  sourceRef:
    kind: GitRepository
    name: customer
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: museum
      namespace: cnd-photos
    - apiVersion: postgresql.cnpg.io/v1
      kind: Cluster
      name: cnpg-ente
      namespace: cnd-photos
```

- [ ] **Step 2: Validate**

```bash
kubectl apply --dry-run=client -f clusters/k8s-cndfrance-prod/photos.yaml
```

Expected: `kustomization.kustomize.toolkit.fluxcd.io/cnd-photos created (dry run)`.

- [ ] **Step 3: Commit**

```bash
git add clusters/k8s-cndfrance-prod/photos.yaml
git commit -m "feat(photos): Flux Kustomization cnd-photos

Reconciles ./photos every 2 minutes, after cnd-operators is ready.
Health-gated on Museum Deployment and CNPG cluster."
```

---

### Task C12: Add Flux image-automation for the 3 web images

**Files:**
- Create: `cnd-platform/flux/image-automation/ente-web.yaml`
- Modify: `cnd-platform/flux/image-automation/kustomization.yaml`

- [ ] **Step 1: Create `flux/image-automation/ente-web.yaml`**

Mirrors the website entry — three triples (ImageRepository + ImagePolicy + ImageUpdateAutomation), one per app, all writing back to `./photos`.

```yaml
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: cnd-ente-web-photos
  namespace: flux-system
spec:
  image: ghcr.io/cloudnativefrance/ente-web-photos
  interval: 30m
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: cnd-ente-web-photos
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: cnd-ente-web-photos
  filterTags:
    pattern: '^main-[a-f0-9]+-(?P<ts>[0-9]+)$'
    extract: '$ts'
  policy:
    numerical:
      order: asc
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: cnd-ente-web-albums
  namespace: flux-system
spec:
  image: ghcr.io/cloudnativefrance/ente-web-albums
  interval: 30m
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: cnd-ente-web-albums
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: cnd-ente-web-albums
  filterTags:
    pattern: '^main-[a-f0-9]+-(?P<ts>[0-9]+)$'
    extract: '$ts'
  policy:
    numerical:
      order: asc
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: cnd-ente-web-accounts
  namespace: flux-system
spec:
  image: ghcr.io/cloudnativefrance/ente-web-accounts
  interval: 30m
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: cnd-ente-web-accounts
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: cnd-ente-web-accounts
  filterTags:
    pattern: '^main-[a-f0-9]+-(?P<ts>[0-9]+)$'
    extract: '$ts'
  policy:
    numerical:
      order: asc
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageUpdateAutomation
metadata:
  name: cnd-ente-web
  namespace: flux-system
spec:
  interval: 30m
  sourceRef:
    kind: GitRepository
    name: customer
  git:
    commit:
      author:
        email: fluxcdbot@cloudnativedays.fr
        name: fluxcdbot
      messageTemplate: |
        chore(photos): update image to {{range .Updated.Images}}{{println .}}{{end}}
    push:
      branch: main
  update:
    path: ./photos
```

One `ImageUpdateAutomation` covers all three apps because they share the
same source repo, target path, and tag pattern. Flux scans the photos
directory for `$imagepolicy` markers and updates each one against the
matching ImagePolicy.

- [ ] **Step 2: Append to `flux/image-automation/kustomization.yaml`**

The current file is:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - website.yaml
```

Make it:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - website.yaml
  - ente-web.yaml
```

- [ ] **Step 3: Validate**

```bash
kustomize build flux/image-automation/ | grep "name: cnd-ente-web"
```

Expected: 4 entries (3 ImageRepositories + 3 ImagePolicies + 1 ImageUpdateAutomation = 7 references to a `cnd-ente-web*` name).

- [ ] **Step 4: Commit**

```bash
git add flux/image-automation/ente-web.yaml flux/image-automation/kustomization.yaml
git commit -m "feat(photos): Flux image-automation for 3 Ente web images

Watches GHCR for main-<sha>-<unix> tags on ente-web-{photos,albums,accounts},
auto-PRs bumps into photos/web-*.yaml."
```

---

### Task C13: Push branch, open PR, watch reconciliation

- [ ] **Step 1: Push**

```bash
cd /home/smana/Sources/cnd-platform
git push -u origin feat/photos-ente
```

- [ ] **Step 2: Open PR**

```bash
gh pr create \
  --title "feat(photos): self-hosted Ente photo platform" \
  --body "$(cat <<'EOF'
## Summary

Adds a self-hosted Ente Photos deployment under a new `photos/` top-level
directory. See
`docs/superpowers/specs/2026-05-15-self-hosted-ente-photos-design.md`
for the full design and
`docs/superpowers/plans/2026-05-15-self-hosted-ente-photos.md` for the
plan.

- New namespace `cnd-photos` + Flux Kustomization wiring
- CNPG cluster `cnpg-ente` (2 instances, 10Gi, daily backup to S3)
- Museum Deployment + ConfigMap + 4 SealedSecrets
- 3 web SPA Deployments (photos / albums / accounts) with Flux image-automation
- Web image build pipeline lives in cndfrance-website (already merged)

## Test plan

- [ ] Phase B prereqs done (Scaleway bucket, DNS, mailbox, secrets generated)
- [ ] Phase A images pushed and discoverable in GHCR
- [ ] After merge: `flux get kustomization cnd-photos` reports `Ready`
- [ ] `kubectl -n cnd-photos get pods` shows museum + 2 cnpg + 3 web pods all `Running`
- [ ] All 4 ingresses get certificates (`kubectl -n cnd-photos get certificate` → all `Ready`)
- [ ] `curl -fsI https://api.photos.cloudnativedays.fr/ping` returns 200
- [ ] Web UIs load without errors at photos./albums./accounts.cloudnativedays.fr
EOF
)"
```

- [ ] **Step 3: Have a maintainer review**

Shared infra — get a second pair of eyes before merging. After approval:

```bash
gh pr merge --squash --delete-branch
```

- [ ] **Step 4: Watch Flux reconcile**

```bash
flux --context k8s-cndfrance-prod get kustomization cnd-photos --watch
```

Wait until `READY=True`. If it errors:
- `flux logs --kind=Kustomization --name=cnd-photos --tail=200`
- Most likely failure modes: SealedSecret can't decrypt (wrong controller-namespace at seal time), or museum image pulled but exits because config has a bad key. Diagnose, fix, push a follow-up.

- [ ] **Step 5: Confirm all pods + certs are healthy**

```bash
kubectl --context k8s-cndfrance-prod -n cnd-photos get pods,certs,ingress
```

Expected: 1 museum pod Running, 2 cnpg-ente pods Running, 3 web-* pods Running, 4 certificates Ready, 4 ingresses with addresses.

- [ ] **Step 6: Smoke-test the API endpoint**

```bash
curl -fsI https://api.photos.cloudnativedays.fr/ping
```

Expected: HTTP 200 (or whatever Museum's `/ping` returns — verify the
endpoint exists at the pinned SHA in Task C7 notes).

---

## Phase D — Post-deploy and cutover

### Task D1: Bootstrap the admin account

- [ ] **Step 1: Sign up via the web UI**

Open `https://photos.cloudnativedays.fr` in a browser. Click sign-up,
enter your email. OTP email should arrive in your Workspace inbox via
Brevo (check spam if it doesn't appear within a minute).

If the OTP email never arrives:
```bash
kubectl --context k8s-cndfrance-prod -n cnd-photos logs deploy/museum --tail=200 | grep -i smtp
```

Look for SMTP connection errors, auth failures, or "from address rejected"
messages. Fix the relevant secret/config and re-trigger.

- [ ] **Step 2: Read your user_id**

```bash
kubectl --context k8s-cndfrance-prod -n cnd-photos exec -ti cnpg-ente-1 -- \
  psql -U postgres -d ente_db -c "SELECT user_id, email FROM users;"
```

Note the integer `user_id` for your email.

- [ ] **Step 3: Promote yourself to admin**

Edit `photos/museum-config.yaml` — change `internal.admins: []` to
`internal.admins: [<your-user-id>]` (e.g. `[1]` if you were the first
signup). Commit the change on a quick branch:

```bash
cd /home/smana/Sources/cnd-platform
git checkout -b chore/photos-bootstrap-admin
# Edit photos/museum-config.yaml in-place
git add photos/museum-config.yaml
git commit -m "chore(photos): bootstrap admin user_id <N>

First signup ($USER_EMAIL) is now an admin; further promotions go
through Museum's admin CLI instead of ConfigMap edits."
git push -u origin chore/photos-bootstrap-admin
gh pr create --title "chore(photos): bootstrap admin user_id" --body "Promotes the first signup to admin per design §post-deploy step 9."
```

- [ ] **Step 4: After merge, restart museum to pick up the new ConfigMap**

```bash
kubectl --context k8s-cndfrance-prod -n cnd-photos rollout restart deploy/museum
kubectl --context k8s-cndfrance-prod -n cnd-photos rollout status deploy/museum
```

Expected: rollout completes in <1 minute.

---

### Task D2: Verify desktop upload end-to-end

- [ ] **Step 1: Point the Ente Desktop app at the self-hosted museum**

Open Ente Desktop → Settings → Developer Settings → Custom server endpoint:

```
https://api.photos.cloudnativedays.fr
```

Sign in with the email account you bootstrapped in D1.

- [ ] **Step 2: Upload one test photo**

Pick any small JPG/PNG. Upload via the desktop app.

- [ ] **Step 3: Verify it landed in S3 and is queryable from the web UI**

```bash
# Check S3 — Ente blobs land at the bucket root with UUID-style names.
scw object bucket get name=cnd-ente-photos region=fr-par
# Or via aws-cli configured against Scaleway:
aws --endpoint-url https://s3.fr-par.scw.cloud s3 ls s3://cnd-ente-photos/ | head
```

Expected: at least one object exists. Then load
`https://photos.cloudnativedays.fr`, sign in, the test photo is visible.

- [ ] **Step 4: Verify Museum logs are clean**

```bash
kubectl --context k8s-cndfrance-prod -n cnd-photos logs deploy/museum --tail=50
```

Expected: no error stack traces, no "failed to upload" messages.

---

### Task D3: Migrate the 2026 photo collection

- [ ] **Step 1: From the cloud Ente account, export the existing 2026 photos**

Use Ente Desktop's export feature (Settings → Export) to download originals
of all 2026 photos to a local folder. This step preserves originals; the
re-upload re-encrypts them against the new museum's keys.

- [ ] **Step 2: Re-upload to the self-hosted instance**

In Ente Desktop, signed into the self-hosted instance, create a new album
"CND France 2026" (or similar). Upload the exported folder.

- [ ] **Step 3: Create a public share link**

In the photos web UI, open the album → Share → "Allow public links" → copy
the link. Format:

```
https://albums.cloudnativedays.fr/?t=<TOKEN>#<KEY>
```

Note this URL — Task D4 will swap it into the website.

---

### Task D4: Update `cndfrance-website` `EDITION_2026.galleryUrl`

**Files:**
- Modify: `cndfrance-website/src/lib/editions-data.ts`

- [ ] **Step 1: Branch in cndfrance-website**

```bash
cd /home/smana/Sources/cndfrance-website
git checkout main
git pull --ff-only
git checkout -b chore/photos-cutover-2026-gallery
```

- [ ] **Step 2: Edit `src/lib/editions-data.ts` lines 51-52**

Replace:

```ts
  galleryUrl:
    "https://albums.ente.io/?t=QRX4L3WBSD#5jsodRK1mQbqS83qJMd2sVBZr9oW4Bzgm9DuVP6MowY5",
```

With the new self-hosted URL from D3:

```ts
  galleryUrl:
    "https://albums.cloudnativedays.fr/?t=<TOKEN>#<KEY>",
```

(Substitute the actual token + key from your D3 share link.)

- [ ] **Step 3: Run the standard pre-PR checks**

```bash
pnpm test
pnpm astro check
pnpm build
```

Expected: all three green. If `pnpm test` has known non-blocking failures
(see `docs/testing.md` in the website repo), confirm the failures are
unrelated to your change.

- [ ] **Step 4: Commit and PR**

```bash
git add src/lib/editions-data.ts
git commit -m "chore(photos): point EDITION_2026.galleryUrl at self-hosted Ente

Cuts over from albums.ente.io to albums.cloudnativedays.fr now that the
self-hosted instance is up and the 2026 photo collection has been
re-uploaded. See cnd-platform docs/superpowers/specs/2026-05-15-…."
git push -u origin chore/photos-cutover-2026-gallery
gh pr create \
  --title "chore(photos): cut over EDITION_2026 gallery to self-hosted Ente" \
  --body "Final step of the self-hosted Ente migration. Swaps the gallery link from albums.ente.io to albums.cloudnativedays.fr — content has already been re-uploaded to the new museum."
```

- [ ] **Step 5: After merge, verify the live site**

After CI builds and Flux image-automation deploys the new website image:

```bash
curl -fsSL https://2027.cloudnativedays.fr/2023 | grep -i "albums.cloudnativedays"
```

Wait — that's the 2023 page. The 2026 gallery is linked from the
homepage / 2026 section. Spot-check whichever page renders
`EDITION_2026.galleryUrl`:

```bash
curl -fsSL "https://2027.cloudnativedays.fr/" | grep -A2 "Galerie\|Gallery"
```

Expected: the link points at `albums.cloudnativedays.fr`, not
`albums.ente.io`. Click through in a browser; the public album loads.

---

## Verification checklist (end-to-end)

After all phases are merged and reconciled:

- [ ] `flux get kustomization cnd-photos` → `Ready: True`
- [ ] `kubectl -n cnd-photos get pods` → all `Running`, 0 restarts after 30 minutes
- [ ] 4 certificates `Ready`
- [ ] OTP sign-up flow works (verified in D1)
- [ ] Photo upload works (verified in D2)
- [ ] Public share link viewer works on `albums.cloudnativedays.fr` (verified in D3)
- [ ] Website 2026 gallery link points at self-hosted (verified in D4)
- [ ] CNPG scheduled backup ran at least once (`kubectl -n cnd-photos get backups`)
- [ ] No unexpected Museum errors in the last 24h of logs

If any item fails, file an issue or PR against the relevant repo before
considering the deploy complete.

---

## Deferred (not in this plan)

These were explicitly scoped out in the design doc and are not implemented
here. Track separately:

- S3 blob backup beyond Scaleway native durability
- PodMonitor + Grafana dashboard for Museum
- Per-user storage quotas
- Resource right-sizing after a week of traffic
- Baserow SMTP migration to Workspace-native (if desired)
