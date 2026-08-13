# Website analytics — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Self-hosted Umami at `stats.cloudnativedays.fr` reporting pageviews, top pages, referrers and a visitor trend for `cloudnativedays.fr` — cookieless, no consent banner, and invisible to staging.

**Architecture:** A new Flux Kustomization `cnd-analytics` reconciles `analytics/` into namespace `cnd-analytics`. Umami 3.3.0 (1 replica) runs against a 2-instance CloudNativePG cluster backed up to Scaleway. The tracker script tag is added to the companion website repo, gated at build time on the production origin.

**Tech Stack:** Kustomize, Flux CD, CloudNativePG, Bitnami SealedSecrets, ingress-nginx, cert-manager, Umami 3.3.0. Website side: Astro, pnpm, vitest.

**Spec:** `docs/superpowers/specs/2026-08-13-website-analytics-design.md`

**This plan spans two repositories.** Tasks 1–4 and 6 are in `cnd-platform`. Task 5 is in
`cloudnativefrance/website` (`~/Sources/cndfrance-website`) and cannot start until Task 4
produces a `data-website-id`.

## How "tests" work here

Same adaptation as the shortener plan: for manifests the red/green loop is
`kustomize build` failing on a named file, then `./scripts/validate-manifests.sh` exiting 0.
Task 5 is different — the website repo has a real vitest suite and a real build, so that
task uses genuine before/after assertions on built output.

**Do not claim a task is done without running its verification command and reading the
output.** Several steps deliberately expect a failure first.

**Do not push before Task 4.** Tasks 1–3 leave `kustomize build` intentionally failing on
files later tasks create.

## Global Constraints

- Namespace: `cnd-analytics`. Flux Kustomization name: `cnd-analytics`. Directory: top-level `analytics/`.
- Host: `stats.cloudnativedays.fr`. No basic auth — Umami has its own accounts.
- Image, pinned: `umamisoftware/umami:3.3.0`. Verified identical by digest to `postgresql-latest` (`sha256:62ac5cff2e48beea540653fdfacf8e4477c0182226a4aebdc19813e773f8985a`); v3 is Postgres-only, so there is no separate `postgresql-` tag to chase. `.polaris.yaml` sets `tagNotSpecified: danger` — never `:latest`.
- PostgreSQL **12.14+** is a hard floor, enforced at boot by `scripts/check-db.js`. CNPG's default major version satisfies it; do not pin an older one.
- CNPG house pattern copied from `communication/photos/cnpg-cluster.yaml`: `instances: 2`, `storageClass: node-local-retain`, `size: 10Gi`, `endpointURL: https://s3.fr-par.scw.cloud`, `retentionPolicy: "90d"`, PodMonitor block with both relabelings. Backup path `s3://cloudnativedaysfr/cnpg/umami`.
- The DB password **must be URL-safe** — it is interpolated into `DATABASE_URL`. The bootstrap script strips `=` and maps `/+` to `_-`. A `/` in the password corrupts the URL and surfaces as a confusing auth failure, not a parse error.
- `TRACKER_SCRIPT_NAME: cnd.js` and `COLLECT_API_ENDPOINT: /api/cnd` — never the defaults `script.js` / `/api/send`, which filter lists match.
- Container sets `allowPrivilegeEscalation: false`, resource requests, both probes. `readOnlyRootFilesystem: false` (Next.js writes a cache).
- Probes hit `/api/heartbeat` — verified to return `{ok: true}` with no database access, so a DB outage does not restart-loop the pod.
- Strip `creationTimestamp: null` after sealing (commits `27b235b`, `6c61223`).
- Commit messages and PR text in English; never add co-author or generated-by trailers.

## Prerequisites (human, before Task 1)

- [ ] **Branch.** Work on `feat/website-analytics`, which already branches from `main` and carries this spec and plan. It is independent of the shortener branch (PR #159) and can ship before or after it — the two components share no files. The only overlap is `namespaces/namespaces.yaml`, which both append to; whichever merges second may need a trivial conflict resolution there.
- [ ] One DNS **A** record for `stats.cloudnativedays.fr` → cluster ingress IP. No external-dns in this cluster.
- [ ] `kubectl --context k8s-cndfrance-prod get ns` works
- [ ] `kubeseal --version` works and the controller is reachable
- [ ] `kustomize`, `polaris`, `openssl`, `jq` on `PATH`

---

### Task 1: Namespace, scaffold, and sealed secrets

**Files:**
- Modify: `namespaces/namespaces.yaml`
- Create: `analytics/kustomization.yaml`, `analytics/.bootstrap.sh`
- Generated: `analytics/cnd-france-scw-secret.yaml`, `analytics/umami-cnpg-secret.yaml`, `analytics/umami-secret.yaml`

**Interfaces:**
- Produces: namespace `cnd-analytics`; SealedSecret `umami-cnpg-secret` (keys `username`, `password`, type `kubernetes.io/basic-auth`); SealedSecret `umami-secret` (key `app-secret`); SealedSecret `cnd-france-scw-secret` (keys `access-key-id`, `secret-access-key`, `region`). Tasks 2–3 reference these names and keys exactly.

- [ ] **Step 1: Add the namespace**

Append to `namespaces/namespaces.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: cnd-analytics
```

- [ ] **Step 2: Create the kustomization**

Create `analytics/kustomization.yaml`. It lists files that do not exist yet — intentional.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cnd-analytics

resources:
  - cnd-france-scw-secret.yaml
  - umami-cnpg-secret.yaml
  - umami-secret.yaml
  - cnpg-cluster.yaml
  - cnpg-scheduled-backup.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

- [ ] **Step 3: Run the gate and confirm it fails**

Run: `kustomize build analytics`

Expected: FAIL — `accumulating resources from 'cnd-france-scw-secret.yaml': evalsymlink failure`.

- [ ] **Step 4: Write the bootstrap script**

Create `analytics/.bootstrap.sh`:

```bash
#!/usr/bin/env bash
# Bootstrap script for self-hosted website analytics (Umami).
# Run from the repo root: ./analytics/.bootstrap.sh
#
# Generates the DB password and APP_SECRET, reseals the Scaleway backup creds
# into the new namespace, writes 3 SealedSecret YAML files into analytics/,
# and stashes the plaintexts to a backup file you must move to your password
# manager and then delete.
#
# Manual prereqs (do these BEFORE running this script):
#   1. DNS A record stats.cloudnativedays.fr -> cluster ingress.
#   2. Confirm `kubectl --context k8s-cndfrance-prod` works and `kubeseal`
#      can reach the controller.

set -euo pipefail
trap 'echo "ERROR: bootstrap failed at line $LINENO" >&2' ERR

CTX="k8s-cndfrance-prod"
NS="cnd-analytics"
SOURCE_NS="cnd-project"   # where the existing Scaleway secret lives

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_FILE="$HOME/.umami-bootstrap-secrets.txt"

echo "==> Bootstrapping Umami SealedSecrets in namespace ${NS}"

for bin in openssl kubeseal kubectl jq; do
  command -v "$bin" >/dev/null || { echo "$bin not found"; exit 1; }
done

# ---------- Generate plaintexts ----------
# The DB password is interpolated into DATABASE_URL via Kubernetes $(VAR)
# expansion, so it MUST be URL-safe: strip '=' padding and map '/+' to '_-'.
# A '/' here would corrupt the connection URL.
echo "==> Generating secrets"
PG_PASSWORD="$(openssl rand -base64 24 | tr -d '\n=' | tr '/+' '_-')"
APP_SECRET="$(openssl rand -base64 32 | tr -d '\n')"

{
  echo "# Umami bootstrap secrets — generated $(date -Iseconds)"
  echo "# MOVE these to a password manager and DELETE this file."
  echo ""
  echo "POSTGRES_PASSWORD=${PG_PASSWORD}"
  echo "APP_SECRET=${APP_SECRET}"
} > "${BACKUP_FILE}"
chmod 600 "${BACKUP_FILE}"
echo "    Plaintexts written to ${BACKUP_FILE} (mode 600)."

# ---------- Reseal Scaleway creds ----------
echo "==> Reading Scaleway creds from namespace ${SOURCE_NS}"
SCW_DATA=$(kubectl --context "${CTX}" -n "${SOURCE_NS}" get secret cnd-france-scw-secret -o json)
SCW_ACCESS_KEY_ID=$(echo "$SCW_DATA"     | jq -r '.data."access-key-id"     | @base64d')
SCW_SECRET_ACCESS_KEY=$(echo "$SCW_DATA" | jq -r '.data."secret-access-key" | @base64d')
SCW_REGION=$(echo "$SCW_DATA"            | jq -r '.data."region"            | @base64d')

echo "==> Resealing cnd-france-scw-secret for ${NS}"
kubectl --context "${CTX}" create secret generic cnd-france-scw-secret \
  --namespace "${NS}" \
  --from-literal=access-key-id="${SCW_ACCESS_KEY_ID}" \
  --from-literal=secret-access-key="${SCW_SECRET_ACCESS_KEY}" \
  --from-literal=region="${SCW_REGION}" \
  --dry-run=client -o yaml \
| kubeseal --format yaml --namespace "${NS}" > "${DIR}/cnd-france-scw-secret.yaml"

# ---------- Database credentials ----------
echo "==> Sealing umami-cnpg-secret"
kubectl --context "${CTX}" create secret generic umami-cnpg-secret \
  --namespace "${NS}" \
  --type kubernetes.io/basic-auth \
  --from-literal=username=umami \
  --from-literal=password="${PG_PASSWORD}" \
  --dry-run=client -o yaml \
| kubeseal --format yaml --namespace "${NS}" > "${DIR}/umami-cnpg-secret.yaml"

# ---------- Application secret ----------
echo "==> Sealing umami-secret (APP_SECRET)"
kubectl --context "${CTX}" create secret generic umami-secret \
  --namespace "${NS}" \
  --from-literal=app-secret="${APP_SECRET}" \
  --dry-run=client -o yaml \
| kubeseal --format yaml --namespace "${NS}" > "${DIR}/umami-secret.yaml"

# ---------- Strip stale 'creationTimestamp: null' ----------
for f in cnd-france-scw-secret.yaml umami-cnpg-secret.yaml umami-secret.yaml; do
  sed -i '/^  creationTimestamp: null$/d; /^      creationTimestamp: null$/d' "${DIR}/${f}"
done

echo "==> Verifying secret files exist"
for f in cnd-france-scw-secret.yaml umami-cnpg-secret.yaml umami-secret.yaml; do
  [[ -s "${DIR}/${f}" ]] || { echo "ERROR: missing or empty ${DIR}/${f}"; exit 1; }
done

echo ""
echo "==> Plaintext backup at ${BACKUP_FILE} — MOVE to your password manager + DELETE."
```

- [ ] **Step 5: Run the bootstrap**

Run: `chmod +x analytics/.bootstrap.sh && ./analytics/.bootstrap.sh`

Expected: three `.yaml` files created in `analytics/`.

- [ ] **Step 6: Verify the password is URL-safe**

This is the failure mode most likely to waste an hour later, so check it explicitly:

```bash
grep '^POSTGRES_PASSWORD=' ~/.umami-bootstrap-secrets.txt | grep -qE '[/+=]' \
  && echo "FAIL: password contains a URL-unsafe character" \
  || echo "OK: password is URL-safe"
```
Expected: `OK: password is URL-safe`.

- [ ] **Step 7: Move the plaintexts out**

Copy `~/.umami-bootstrap-secrets.txt` into the password manager, then delete the file.

- [ ] **Step 8: Commit**

```bash
git add namespaces/namespaces.yaml analytics/kustomization.yaml analytics/.bootstrap.sh \
        analytics/cnd-france-scw-secret.yaml analytics/umami-cnpg-secret.yaml \
        analytics/umami-secret.yaml
git commit -m "feat(analytics): namespace and sealed secrets for Umami"
```

---

### Task 2: PostgreSQL via CloudNativePG

**Files:**
- Create: `analytics/cnpg-cluster.yaml`, `analytics/cnpg-scheduled-backup.yaml`

**Interfaces:**
- Consumes: `umami-cnpg-secret`, `cnd-france-scw-secret` from Task 1.
- Produces: Service `cnpg-umami-rw` on 5432, database `umami`, owner `umami`.

- [ ] **Step 1: Write the cluster**

Create `analytics/cnpg-cluster.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cnpg-umami
spec:
  description: "PostgreSQL cluster for Umami website analytics"
  instances: 2

  bootstrap:
    initdb:
      database: umami
      owner: umami
      secret:
        name: umami-cnpg-secret

  superuserSecret:
    name: umami-cnpg-secret

  storage:
    storageClass: node-local-retain
    size: 10Gi

  backup:
    barmanObjectStore:
      destinationPath: "s3://cloudnativedaysfr/cnpg/umami"
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
      memory: "256Mi"
      cpu: 100m
    limits:
      memory: "256Mi"
```

- [ ] **Step 2: Write the scheduled backup**

Create `analytics/cnpg-scheduled-backup.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: cnpg-umami
spec:
  schedule: "0 0 0 * * *" # At midnight every day
  backupOwnerReference: self
  cluster:
    name: cnpg-umami
```

- [ ] **Step 3: Verify the gate fails on a later file**

Run: `kustomize build analytics 2>&1 | tail -3`

Expected: FAIL naming `deployment.yaml`, not `cnpg-cluster.yaml`.

- [ ] **Step 4: Commit**

```bash
git add analytics/cnpg-cluster.yaml analytics/cnpg-scheduled-backup.yaml
git commit -m "feat(analytics): CNPG cluster and scheduled backup for Umami"
```

---

### Task 3: Umami

**Files:**
- Create: `analytics/deployment.yaml`, `analytics/service.yaml`, `analytics/ingress.yaml`

**Interfaces:**
- Consumes: `cnpg-umami-rw` (Task 2), `umami-cnpg-secret`, `umami-secret` (Task 1).
- Produces: Service `umami` on port 3000 named `http`; the tracker at `/cnd.js` and collection at `/api/cnd` on `stats.cloudnativedays.fr`. Task 5's script tag depends on both paths.

- [ ] **Step 1: Write the Deployment**

Create `analytics/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: umami
  namespace: cnd-analytics
  labels:
    app.kubernetes.io/name: umami
    app.kubernetes.io/component: analytics
    app.kubernetes.io/part-of: cnd-france
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
      app.kubernetes.io/name: umami
  template:
    metadata:
      labels:
        app.kubernetes.io/name: umami
        app.kubernetes.io/component: analytics
        app.kubernetes.io/part-of: cnd-france
    spec:
      containers:
        - name: umami
          # v3 is PostgreSQL-only, so the plain version tag IS the postgres
          # image — verified by digest equality with :postgresql-latest.
          image: umamisoftware/umami:3.3.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 3000
              protocol: TCP
          env:
            # DB_PASSWORD MUST come before DATABASE_URL: Kubernetes expands
            # $(VAR) only against env vars defined earlier in this list.
            # Sealing the password alone (rather than the whole URL) keeps the
            # DB hostname out of the secret.
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: umami-cnpg-secret
                  key: password
            - name: DATABASE_URL
              value: postgresql://umami:$(DB_PASSWORD)@cnpg-umami-rw:5432/umami
            - name: APP_SECRET
              valueFrom:
                secretKeyRef:
                  name: umami-secret
                  key: app-secret
            - name: DISABLE_TELEMETRY
              value: "1"
            # Off the default paths that ad-blocker filter lists match. A
            # cloud-native audience blocks at well above the general rate, so
            # the defaults would undercount badly and silently.
            - name: TRACKER_SCRIPT_NAME
              value: cnd.js
            - name: COLLECT_API_ENDPOINT
              value: /api/cnd
          # /api/heartbeat returns {ok:true} without touching the database, so
          # a Postgres outage degrades quietly instead of restart-looping.
          readinessProbe:
            httpGet:
              path: /api/heartbeat
              port: http
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /api/heartbeat
              port: http
            initialDelaySeconds: 60
            periodSeconds: 30
            timeoutSeconds: 3
            failureThreshold: 3
          resources:
            requests:
              cpu: 100m
              memory: 384Mi
            limits:
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            # Next.js writes a build/runtime cache.
            readOnlyRootFilesystem: false
            capabilities:
              drop:
                - ALL
```

- [ ] **Step 2: Write the Service**

Create `analytics/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: umami
  namespace: cnd-analytics
  labels:
    app.kubernetes.io/name: umami
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 3000
      protocol: TCP
      targetPort: http
  selector:
    app.kubernetes.io/name: umami
```

- [ ] **Step 3: Write the Ingress**

Create `analytics/ingress.yaml`:

```yaml
---
# No basic-auth annotations here, unlike website-staging and the shortener's
# admin UI: Umami ships its own user accounts. The tracker script and the
# collection endpoint must also stay publicly reachable for the website to
# report at all.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: umami
  namespace: cnd-analytics
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: public
  rules:
    - host: stats.cloudnativedays.fr
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: umami
                port:
                  name: http
  tls:
    - hosts:
        - stats.cloudnativedays.fr
      secretName: umami-tls
```

- [ ] **Step 4: Verify the render succeeds**

Run: `kustomize build analytics | grep -c "^kind:"`

Expected: `8` — three SealedSecrets, Cluster, ScheduledBackup, Deployment, Service, Ingress.

- [ ] **Step 5: Run the full repository gate**

Run: `./scripts/validate-manifests.sh`

Expected: `==> All gates passed`. On a polaris `danger`, fix the manifest — `.polaris.yaml`'s own rules of engagement say fix rather than exempt.

- [ ] **Step 6: Commit**

```bash
git add analytics/deployment.yaml analytics/service.yaml analytics/ingress.yaml
git commit -m "feat(analytics): Umami deployment, service and ingress"
```

---

### Task 4: Go live and get the website ID

**Files:**
- Create: `clusters/k8s-cndfrance-prod/analytics.yaml`

**Interfaces:**
- Produces: a reconciling `cnd-analytics` Kustomization and the `data-website-id` UUID that Task 5 needs. Task 5 is blocked until this task completes.

- [ ] **Step 1: Write the Flux Kustomization**

Create `clusters/k8s-cndfrance-prod/analytics.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cnd-analytics
  namespace: flux-system
spec:
  prune: true
  interval: 2m0s
  path: ./analytics
  dependsOn:
    - name: cnd-operators
  sourceRef:
    kind: GitRepository
    name: customer
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: umami
      namespace: cnd-analytics
    - apiVersion: postgresql.cnpg.io/v1
      kind: Cluster
      name: cnpg-umami
      namespace: cnd-analytics
```

- [ ] **Step 2: Run the gate**

Run: `./scripts/validate-manifests.sh`

Expected: `==> All gates passed`.

- [ ] **Step 3: Commit, push, open the PR**

```bash
git add clusters/k8s-cndfrance-prod/analytics.yaml
git commit -m "feat(analytics): reconcile Umami with Flux"
git push -u origin feat/website-analytics
gh pr create --title "Self-hosted website analytics at stats.cloudnativedays.fr" \
  --body "Deploys Umami 3.3.0 on CNPG.

Audience basics only: pageviews, top pages, referrers, visitor trend.
Cookieless, no consent banner. Tracker script and collection endpoint use
non-default paths because this audience blocks analytics at well above the
general rate.

The website-side script tag is a follow-up PR in cloudnativefrance/website,
gated at build time on the production origin so staging emits no tag.

Design: docs/superpowers/specs/2026-08-13-website-analytics-design.md
Plan: docs/superpowers/plans/2026-08-13-website-analytics.md"
```

- [ ] **Step 4: Verify reconciliation after merge**

```bash
kubectl --context k8s-cndfrance-prod -n flux-system get kustomization cnd-analytics
kubectl --context k8s-cndfrance-prod -n cnd-analytics get pods
```
Expected: `READY=True`; pods `cnpg-umami-1`, `cnpg-umami-2`, `umami-*` all `Running`.

If Umami crash-loops, read `kubectl -n cnd-analytics logs deploy/umami`. Two likely causes:
`check-db.js` rejecting a PostgreSQL older than 12.14, or a malformed `DATABASE_URL` from a
non-URL-safe password (Task 1 Step 6 exists to prevent the second).

- [ ] **Step 5: Acceptance — the app is up and the tracker path took effect**

```bash
curl -sSI https://stats.cloudnativedays.fr/ | head -3
curl -sS https://stats.cloudnativedays.fr/cnd.js | head -c 100
curl -sSI https://stats.cloudnativedays.fr/script.js | head -1
```
Expected: 200 on `/`; JavaScript from `/cnd.js`; **404 on `/script.js`** — that last one is
what proves `TRACKER_SCRIPT_NAME` is actually in effect rather than merely set.

- [ ] **Step 6: First login and password change**

Open `https://stats.cloudnativedays.fr`, log in with the default `admin` account, change the
password immediately, and store it in the password manager.

- [ ] **Step 7: Add the website and capture the UUID**

In the Umami UI: Settings → Websites → Add website, name `Cloud Native Days France`, domain
`cloudnativedays.fr`. Copy the generated **website ID** (a UUID).

Record it here before starting Task 5 — it is public, not a secret:

```
data-website-id = ________________________________
```

---

### Task 5: Tracker script tag (companion repo)

**Repository:** `cloudnativefrance/website` — `~/Sources/cndfrance-website`. **Not** cnd-platform.

**Files:**
- Modify: `src/layouts/Layout.astro`

**Interfaces:**
- Consumes: the `data-website-id` UUID from Task 4 Step 7, and the `/cnd.js` path from Task 3.

- [ ] **Step 1: Confirm the "test" detects absence before the change**

From `~/Sources/cndfrance-website`, build with the production origin and count occurrences:

```bash
pnpm install --frozen-lockfile
pnpm build && grep -rl "cnd.js" dist/ | wc -l
```
Expected: `0`. This proves the check works and the tag genuinely is not there yet.

- [ ] **Step 2: Add the gating const**

In `src/layouts/Layout.astro`, immediately after the existing `indexable` line (currently
line 74), add:

```ts
// Analytics ships only from the production origin, for the same reason as
// `indexable`: a staging build must never write to production statistics.
// Fails closed — an unknown origin yields no analytics.
const analyticsEnabled = isProductionOrigin(Astro.site?.origin);
```

`isProductionOrigin` is already imported at line 9; do not add a second import.

- [ ] **Step 3: Add the gated script tag**

In the same file, inside `<head>`, after the existing theme `<script is:inline>` block:

```astro
{analyticsEnabled && (
  <script
    defer
    src="https://stats.cloudnativedays.fr/cnd.js"
    data-website-id="PASTE-UUID-FROM-TASK-4-STEP-7"
    data-do-not-track="true"
  />
)}
```

Replace the placeholder with the UUID recorded in Task 4 Step 7. Do **not** add
`data-domains` — the origin is the single source of truth, per `src/lib/site-env.ts`.

- [ ] **Step 4: Verify the production build now includes it**

```bash
pnpm build && grep -rl "cnd.js" dist/ | wc -l
```
Expected: a non-zero count (one per generated page).

- [ ] **Step 5: Verify the staging build does NOT include it**

This is the check most likely to be silently wrong:

```bash
PUBLIC_SITE_URL=https://staging.cloudnativedays.fr pnpm build && grep -rl "cnd.js" dist/ | wc -l
```
Expected: `0`. If this prints anything else, the gate is not working — stop and fix it before
shipping, because the alternative is discovering it as inflated numbers weeks later.

- [ ] **Step 6: Run the existing test suite**

```bash
pnpm test
```
Expected: PASS. `src/lib/__tests__/site-env.test.ts` already covers `isProductionOrigin`; no
new unit test is needed because the change adds no new logic, only a new consumer.

- [ ] **Step 7: Commit and ship to staging**

Staging deploys automatically from the `staging` branch; production is an explicit promotion.

```bash
git checkout -b feat/analytics-tracker
git add src/layouts/Layout.astro
git commit -m "feat(analytics): add the Umami tracker, gated on the production origin"
git push -u origin feat/analytics-tracker
```

Merge into `staging` following the repo's usual flow. The website CI publishes
`staging-<sha>-<ts>`, and `flux/image-automation/website-staging.yaml` picks it up within
30m.

- [ ] **Step 8: Acceptance — staging serves no tracker**

Once the staging image has rolled out:

```bash
curl -sS -u "$STAGING_AUTH" https://staging.cloudnativedays.fr | grep -c "cnd.js"
```
Expected: `0`. (`$STAGING_AUTH` is the `user:password` basic-auth credential for
`website-staging`.)

- [ ] **Step 9: Promote to production**

Open a PR from `feat/analytics-tracker` to `main` and merge it. The website CI then publishes
`main-<sha>-<ts>`; `flux/image-automation/website.yaml` writes the image bump to the
`promote/website` branch rather than to `main`, so **production ships only when you merge
that promotion PR**. Delete `promote/website` after merging — Flux recreates it cleanly on
its next run.

- [ ] **Step 10: Acceptance — production reports**

```bash
curl -sS https://cloudnativedays.fr | grep -c "cnd.js"
```
Expected: `1`.

Then visit `https://cloudnativedays.fr` in a browser and confirm, within a minute:
- the Umami dashboard shows the pageview;
- devtools → Network shows the collection POST going to `/api/cnd`, **not** `/api/send`.

- [ ] **Step 11: Confirm the first backup**

Back in cnd-platform, after the first midnight run:

```bash
kubectl --context k8s-cndfrance-prod -n cnd-analytics get backups
```
Expected: a `Backup` for `cnpg-umami` with phase `completed`.

---

### Task 6: Document the component

**Files:**
- Create: `analytics/README.md`
- Modify: `README.md` (repo root)

- [ ] **Step 1: Write the component README**

Create `analytics/README.md`:

```markdown
# Website analytics (Umami)

Audience measurement for `cloudnativedays.fr`, self-hosted at
`stats.cloudnativedays.fr`.

## What it measures

Pageviews, top pages, referrers, visitors per day. Nothing else — no events, no funnels,
no campaign reporting. Umami is cookieless and stores no personal data; a visitor is a
server-side salted hash.

## Reading the numbers honestly

Tracker script and collection endpoint are served from non-default paths (`/cnd.js`,
`/api/cnd`) because filter lists match the defaults, and this audience blocks analytics at
well above the general rate. That blunts path-based blocking; it does not defeat blocking by
hostname.

**The undercount is systematic, not random.** Trends over time and comparisons between pages
or referrers are meaningful. Absolute visitor numbers are a floor, not a measured audience
size — do not quote them to sponsors as one.

If numbers ever look implausible against a known-good reference such as ticket sales, the
escalation is serving the script same-origin from `cloudnativedays.fr`, which needs an
`ExternalName` Service in `cnd-website` plus a path rule on the website ingress. Deliberately
not built: it couples two Flux Kustomizations.

## Staging

The tracker tag is gated at build time on the production origin
(`isProductionOrigin(Astro.site?.origin)` in the website repo's `Layout.astro`), so staging
emits no script at all. The origin is the single source of truth — do not add a
`data-domains` attribute as a second one.

## Components

- **Umami 3.3.0** — 1 replica. `check-db.js` applies Prisma migrations and enforces the
  PostgreSQL 12.14+ floor at startup.
- **cnpg-umami** — 2-instance CloudNativePG cluster, daily backup to
  `s3://cloudnativedaysfr/cnpg/umami`, 90-day retention.

`DATABASE_URL` is composed at pod start from a sealed password via Kubernetes `$(VAR)`
expansion, so the DB hostname stays out of the secret. **The password must be URL-safe** —
`.bootstrap.sh` guarantees this; a `/` in it corrupts the URL.

## Privacy

Cookieless, no personal data, DNT honoured, telemetry disabled. That is what makes operating
without a consent banner defensible for audience measurement — confirm the approach with
whoever owns the site's legal pages, and keep the privacy page's analytics mention accurate.
```

- [ ] **Step 2: Add the domain to the root README**

In `README.md`, insert after the `- **operators**:` line:

```markdown
- 📊 **analytics**: Self-hosted website analytics (Umami) serving `stats.cloudnativedays.fr`
```

- [ ] **Step 3: Commit**

```bash
git add analytics/README.md README.md
git commit -m "docs(analytics): document the analytics component"
```

---

## Rollback

Deleting `clusters/k8s-cndfrance-prod/analytics.yaml` removes the Flux Kustomization and,
via `prune: true`, every object it owns. PVCs use `node-local-retain`, so data survives, and
S3 backups are untouched.

The website side rolls back independently: revert the `Layout.astro` commit and promote. The
site never depends on analytics being reachable — the tag is `defer` and cross-origin, so a
dead stats host costs nothing but the missing data.
