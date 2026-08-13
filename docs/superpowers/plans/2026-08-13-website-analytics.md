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
- PostgreSQL: Umami's README states **12.14+**, but `scripts/check-db.js` only enforces `MIN_VERSION = '9.4.0'`. CNPG's default major version clears both, so do not pin an older one — and do not expect the boot check to catch a version between 9.4 and 12.14, because it will not.
- CNPG house pattern copied from `communication/photos/cnpg-cluster.yaml`: `instances: 2`, `storageClass: node-local-retain`, `size: 10Gi`, `endpointURL: https://s3.fr-par.scw.cloud`, `retentionPolicy: "90d"`, PodMonitor block with both relabelings. Backup path `s3://cloudnativedaysfr/cnpg/umami`.
- **`scripts/lib/seal.sh` is a prerequisite from PR #159** (see the Branch note). The bootstrap sources it rather than re-deriving the seal/reseal/strip sequence for a third time. Its `url_safe_password` uses `openssl rand -hex`, so the DB password interpolated into `DATABASE_URL` is URL-safe by construction — the hazard is removed rather than documented.
- `TRACKER_SCRIPT_NAME: cnd.js` and `COLLECT_API_ENDPOINT: /api/cnd` — never the defaults `script.js` / `/api/send`, which filter lists match.
- Container sets `allowPrivilegeEscalation: false`, `runAsNonRoot: true`, `runAsUser: 1001`, CPU and memory requests, a CPU limit, and both probes. The image's user is the *name* `nextjs`, not a UID, so `runAsNonRoot` alone would fail admission with "non-numeric user, cannot verify user is non-root" — hence the explicit `runAsUser` (the Dockerfile creates `nextjs` with `--uid 1001`). Polaris scores the manifest, not the image.
- `readOnlyRootFilesystem: false` — **not** merely because Next.js caches. The entrypoint runs `node scripts/update-tracker.js`, which rewrites `public/script.js` in place to bake in `COLLECT_API_ENDPOINT`. That write is what makes `/api/cnd` reach the browser at all; with a read-only root and no emptyDir over it, the write fails EROFS, `set -e` aborts before `node server.js`, and the pod crash-loops with no obvious cause.
- Probes hit `/api/heartbeat` — verified to return `{ok: true}` with no database access, so a DB outage does not restart-loop the pod.
- `creationTimestamp: null` inside a SealedSecret template is stripped by `seal.sh` and asserted repo-wide by `scripts/validate-manifests.sh` step 3 (both from PR #159). Only the nested form matters; the top-level one is on main and green.
- Commit messages and PR text in English; never add co-author or generated-by trailers.

## Prerequisites (human, before Task 1)

- [ ] **Branch.** Work on `feat/website-analytics` (PR #160). It **depends on PR #159**, which
  adds `scripts/lib/seal.sh` and the third gate step this plan relies on — merge #159 first, or
  copy those two files across. The branches also both append to `namespaces/namespaces.yaml`
  and to the README.md domain list; whichever merges second resolves both trivially.
- [ ] **Do NOT create the DNS record yet.** `stats.cloudnativedays.fr` → cluster ingress is created in Task 4 Step 7, *after* the seeded `admin`/`umami` password has been changed over a port-forward. Creating it up front would publish an admin panel on documented default credentials for however long it takes a human to reach the login page. There is no external-dns here, so the timing is entirely in your hands — which is what makes this free.
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
# into the new namespace, and writes 3 SealedSecret YAML files into analytics/.
# Plaintexts are stashed in a 0600 file you must move to your password manager
# and then delete.
#
# The seal/reseal/strip mechanics live in scripts/lib/seal.sh — see that file
# for why they are not inlined here.
#
# Manual prereqs (do these BEFORE running this script):
#   1. `kubectl config use-context k8s-cndfrance-prod` — the script refuses to
#      run on any other context, because kubeseal seals against the CURRENT
#      context regardless of what --context is passed to kubectl.
#   2. Do NOT create the stats.cloudnativedays.fr DNS record yet. It is created
#      in Task 4 Step 7, after the seeded admin password has been changed.

set -euo pipefail
trap 'echo "ERROR: bootstrap failed at line $LINENO" >&2' ERR

source "$(git rev-parse --show-toplevel)/scripts/lib/seal.sh"

NS="cnd-analytics"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_FILE="$HOME/.umami-bootstrap-secrets.txt"

echo "==> Bootstrapping Umami SealedSecrets in namespace ${NS}"

require_bins openssl kubeseal kubectl jq kustomize
require_context

# ---------- Generate plaintexts ----------
# url_safe_password uses `openssl rand -hex`, so the value is URL-safe by
# construction. This matters because it is interpolated into DATABASE_URL: a
# '/' or '+' would corrupt the URL and surface as a confusing auth failure
# rather than a parse error.
echo "==> Generating secrets"
PG_PASSWORD="$(url_safe_password)"
APP_SECRET="$(openssl rand -base64 32 | tr -d '\n')"   # not URL-interpolated

secure_file "${BACKUP_FILE}"
{
  echo "# Umami bootstrap secrets — generated $(date -Iseconds)"
  echo "# MOVE these to a password manager and DELETE this file."
  echo ""
  echo "POSTGRES_PASSWORD=${PG_PASSWORD}"
  echo "APP_SECRET=${APP_SECRET}"
} > "${BACKUP_FILE}"
echo "    Plaintexts written to ${BACKUP_FILE} (mode 600)."

# ---------- Seal ----------
echo "==> Resealing cnd-france-scw-secret for ${NS}"
reseal_scw_secret "${NS}" "${DIR}/cnd-france-scw-secret.yaml"

echo "==> Sealing umami-cnpg-secret"
seal_basic_auth "${NS}" umami-cnpg-secret "${DIR}/umami-cnpg-secret.yaml" \
  umami "${PG_PASSWORD}"

echo "==> Sealing umami-secret (APP_SECRET)"
seal_literals "${NS}" umami-secret "${DIR}/umami-secret.yaml" \
  "app-secret=${APP_SECRET}"

echo ""
echo "==> Plaintext backup at ${BACKUP_FILE} — MOVE to your password manager + DELETE."
```

- [ ] **Step 5: Run the bootstrap**

Run: `chmod +x analytics/.bootstrap.sh && ./analytics/.bootstrap.sh`

Expected: three `.yaml` files created in `analytics/`.

The URL-safe-password verification that used to be a separate step here is gone,
in both directions: `url_safe_password` generates hex, so an unsafe value is
impossible rather than merely checked for, and the check itself was broken —
`grep '^POSTGRES_PASSWORD=' … | grep -qE '[/+=]'` matches the `=` of the
`NAME=value` separator on every possible input, so it always reported FAIL.

- [ ] **Step 6: Move the plaintexts out**

Copy `~/.umami-bootstrap-secrets.txt` into the password manager, then delete the file.

- [ ] **Step 7: Commit**
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
      # 2x the request, not equal to it. Equal values make the pod Guaranteed
      # QoS with zero burst room, and the midnight ScheduledBackup runs
      # barman-cloud-backup with gzip compression and S3 upload buffers inside
      # this same pod — plus pg_basebackup whenever the replica resyncs. A hard
      # 256Mi OOMKills there, promoting the standby and forcing a full resync,
      # nightly. communication/photos uses 768Mi; this is the compromise with
      # the cluster capacity pressure recorded in 88a8b26.
      memory: "512Mi"
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

- [ ] **Step 3: Verify the two new files parse**

Assert on what this task produced, not on which missing file kustomize happens to
name first — that ordering is an upstream implementation detail, and Task 1 Step 3
already established the red state.

```bash
kubectl --context k8s-cndfrance-prod apply --dry-run=client \
  -f analytics/cnpg-cluster.yaml -f analytics/cnpg-scheduled-backup.yaml
```
Expected: both objects report `created (dry run)`. The full render stays red until
Task 3 adds the remaining resources.

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
  # Recreate, NOT RollingUpdate. With replicas:1, maxUnavailable:0 forbids
  # scaling the old pod down before the new one is Ready, so maxSurge:1 would
  # guarantee two pods overlap on every rollout — both running
  # `prisma migrate deploy` via check-db.js against the same database. Prisma's
  # advisory lock keeps the schema safe, but the second pod blocks on it while
  # its readiness probe counts down, and past the liveness delay gets killed
  # mid-migration. It also transiently doubles a 384Mi request on a cluster with
  # documented scheduling pressure — to buy zero-downtime that this design
  # explicitly does not want (see the Failure modes table: a collection gap on
  # rollout is Accepted).
  strategy:
    type: Recreate
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
            # A readiness failure never restarts anything, so a long initial
            # delay buys no safety — it only delays Ready. Startup runs
            # check-db (prisma migrate deploy) + update-tracker + start-server,
            # whose duration is not knowable in advance, which is exactly the
            # case a fixed delay handles badly. Poll early and often instead;
            # if first-boot migration ever proves slow, add a startupProbe
            # rather than growing these numbers.
            initialDelaySeconds: 5
            periodSeconds: 5
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
              # cpu limit set because .polaris.yaml scores cpuLimitsMissing.
              cpu: 500m
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            # The image's USER is the NAME `nextjs`, not a UID, so runAsNonRoot
            # alone fails admission: "container has runAsNonRoot and image has
            # non-numeric user (nextjs), cannot verify user is non-root".
            # The Dockerfile creates it with `adduser --system --uid 1001`.
            runAsNonRoot: true
            runAsUser: 1001
            # NOT just "Next.js caches". The entrypoint runs
            # `node scripts/update-tracker.js`, which rewrites public/script.js
            # in place to bake COLLECT_API_ENDPOINT into the served tracker —
            # it is what makes /api/cnd reach the browser. Under a read-only
            # root that write fails EROFS, `set -e` aborts before
            # `node server.js`, and the pod crash-loops for no visible reason.
            # .polaris.yaml scores this `warning` and says "fix rather than
            # exempt", so the reason has to be written down or someone will.
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

Run: `kustomize build analytics | grep '^kind:' | sort | uniq -c`

Expected, by kind rather than one magic number that any future addition breaks:

```
      1 kind: Cluster
      1 kind: Deployment
      1 kind: Ingress
      1 kind: ScheduledBackup
      3 kind: SealedSecret
      1 kind: Service
```

The SealedSecret line is the render-based assertion `communication/photos/.bootstrap.sh`
ends with: it catches a kubeseal run that wrote valid YAML of the wrong kind, a truncated
write, or a file the kustomization does not list — none of which a non-empty-file check sees.

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
    # Every object here lands in a namespace owned by the cnd-namespaces
    # Kustomization. photos.yaml omits this edge; without it a first reconcile
    # that wins the race fails with `namespaces "cnd-analytics" not found` and
    # stays NotReady until the next 2m pass.
    - name: cnd-namespaces
  sourceRef:
    kind: GitRepository
    name: customer
  # Without an explicit timeout Flux uses the interval (2m), shorter than a
  # first reconcile: two CNPG instances, PVCs, initdb, then Umami's startup
  # migrations. The health checks would report a timeout that reads as failure.
  timeout: 10m0s
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

- [ ] **Step 2: Validate the Flux Kustomization**

`./scripts/validate-manifests.sh` does **not** cover this file. It discovers work with
`find . -name kustomization.yaml`, and `clusters/k8s-cndfrance-prod/` holds bare Flux YAML
with no kustomization.yaml — so re-running it here would re-render the same kustomizations
as Task 3 Step 5 and prove nothing about the file just written. The kubeconform Dagger
module in CI is what actually schema-checks it.

```bash
kubectl --context k8s-cndfrance-prod apply --dry-run=client \
  -f clusters/k8s-cndfrance-prod/analytics.yaml
```
Expected: `kustomization.kustomize.toolkit.fluxcd.io/cnd-analytics created (dry run)`.

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

- [ ] **Step 4: Get the PR reviewed and merged**

Branch protection requires one approving review. Nothing below runs until the PR is merged
and Flux has reconciled — proceeding while it is open makes every `kubectl` call return
`NotFound`, which reads as a failure of the plan rather than of the sequencing.

- [ ] **Step 5: Verify reconciliation**

```bash
kubectl --context k8s-cndfrance-prod -n flux-system get kustomization cnd-analytics
kubectl --context k8s-cndfrance-prod -n cnd-analytics get pods
```
Expected: `READY=True`; pods `cnpg-umami-1`, `cnpg-umami-2`, `umami-*` all `Running`.

If Umami crash-loops, read `kubectl -n cnd-analytics logs deploy/umami`. Two likely causes:
`check-db.js` rejecting a PostgreSQL older than 9.4 (its actual floor — CNPG will not
produce one), or Prisma failing a migration against a version between 9.4 and Umami's
documented 12.14, which the boot check does *not* reject.

- [ ] **Step 6: First login and password change — over port-forward, before any DNS**

Umami seeds a **default `admin` / `umami` account** and has no env var to set the initial
password. The DNS record does not exist yet (Task 0 deliberately deferred it), so the
instance is not publicly reachable at this point. Close the window before it opens:

```bash
kubectl --context k8s-cndfrance-prod -n cnd-analytics port-forward svc/umami 3000:3000
```
Open `http://localhost:3000`, log in as `admin` / `umami`, change the password immediately,
and store it in the password manager.

- [ ] **Step 7: Create the DNS record**

Only now create the `stats.cloudnativedays.fr` A record pointing at the cluster ingress.
cert-manager has been retrying its ACME challenge since reconcile and will succeed within a
minute or two of the record existing; the Flux health checks target the Deployment and
Cluster, not the certificate, so nothing else was blocked by its absence.

- [ ] **Step 8: Acceptance — the app is up, the tracker path took effect, and the default login is dead**

```bash
curl -sSI https://stats.cloudnativedays.fr/ | head -3
curl -sS https://stats.cloudnativedays.fr/cnd.js | head -c 100
```
Expected: 200 on `/`; JavaScript from `/cnd.js`.

**Do not assert a 404 on `/script.js`.** `TRACKER_SCRIPT_NAME` adds an alias, it does not
remove the default: `docker/proxy.ts::customScriptName()` rewrites the configured name **to**
`TRACKER_PATH = '/script.js'`, and `public/script.js` is a static file in the image. Only
`TRACKER_SCRIPT_URL` (unset here) rewrites `/script.js` itself. An earlier draft of this plan
expected a 404 and called it the proof — it would have failed on a healthy deployment and
sent the operator debugging a working system. `/cnd.js` returning JavaScript *is* the proof.

Then confirm the seeded credential no longer works:
```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
  https://stats.cloudnativedays.fr/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"umami"}'
```
Expected: **401**. A 200 here means Step 5 was skipped and a public admin panel is live on
published credentials — stop and fix it before doing anything else.

- [ ] **Step 9: Add the website and capture the UUID**

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
- Consumes: the `data-website-id` UUID from Task 4 Step 9, and the `/cnd.js` path from Task 3.

- [ ] **Step 1: Confirm the tag is genuinely absent to begin with**

From `~/Sources/cndfrance-website`:

```bash
grep -rn "cnd.js" src/ | wc -l
```
Expected: `0`. A source grep, not a build — a cold `pnpm install` plus a full Astro build is
the slowest operation in this plan, and running it here would spend it proving something a
grep answers instantly. The builds that carry signal are in Step 5, where the *difference*
between two origins is the thing being measured.

Start the install now so it is warm by Step 5: `pnpm install --frozen-lockfile`.

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

Replace the placeholder with the UUID recorded in Task 4 Step 9. Do **not** add
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

- [ ] **Step 6: Add a CI guard for the gate**

Steps 4 and 5 verify the gate once, by hand, at merge time. The invariant they check is the
one this design calls most likely to be silently wrong — and nothing would re-check it after
a future `Layout.astro` refactor.

The repo already solves exactly this for the sibling invariant: `tests/build/noindex-guard.test.ts`
guards `indexable` — declared one line above `analyticsEnabled` in the same file — with a
source-shape spec, and its docstring states the split explicitly ("Source-shape guard rather
than a build assertion … The rendered output is verified once, manually, in the task's
steps"). `src/lib/__tests__/site-env.test.ts` only covers the pure predicate; the risk was
never in `isProductionOrigin`, it is in the wiring at the call site.

Create `tests/build/analytics-tracker-guard.test.ts`:

```ts
/**
 * Guards the production-only analytics tracker in Layout.astro.
 *
 * Source-shape guard rather than a build assertion, matching noindex-guard.test.ts
 * — a full `pnpm build` per case is too slow for CI. The rendered output is
 * verified once, manually, in the task's steps.
 */
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const LAYOUT_PATH = resolve(
  import.meta.dirname,
  "../../src/layouts/Layout.astro",
);

describe("Layout.astro analytics tracker", () => {
  const source = readFileSync(LAYOUT_PATH, "utf-8");

  it("derives the analytics flag from Astro.site, not a separate env flag", () => {
    expect(source).toMatch(
      /const\s+analyticsEnabled\s*=\s*isProductionOrigin\(\s*Astro\.site\?\.origin\s*\)/,
    );
  });

  it("renders the tracker only behind that flag", () => {
    const tag = source.slice(source.indexOf("cnd.js") - 400, source.indexOf("cnd.js"));
    expect(tag).toContain("analyticsEnabled &&");
  });

  it("does not scope the tracker with data-domains", () => {
    // The origin is the single source of truth; a hardcoded domain list would
    // be a second one. See src/lib/site-env.ts.
    expect(source).not.toContain("data-domains");
  });
});
```

- [ ] **Step 6b: Run the full suite**

```bash
pnpm test
```
Expected: PASS, including the new guard.

- [ ] **Step 6c: Add the analytics mention to the privacy page**

The spec assigns two legal follow-ups to "whoever owns the site's legal pages" — i.e. nobody,
and no checkbox. One of them is concrete and belongs in this PR: the privacy page must say
that the site self-hosts Umami, what it records (pageviews, referrers, no cookies, no IP, no
personal data), and that DNT is honoured. Shipping the tracker and its disclosure in the same
commit is the only way they cannot diverge.

Edit the relevant page under `src/pages/` that `LegalPageLayout.astro` renders (French and
English both — the site is bilingual and `i18n-parity.test.ts` will fail otherwise).

The other follow-up — confirming the no-banner posture for this configuration — stays a human
prerequisite and blocks Step 9 (production promotion), not this step.

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

- [ ] **Step 11: Confirm backups work — trigger one, don't wait for midnight**

This is the only check that proves the Scaleway credentials resealed in Task 1 actually
authenticate against `s3://cloudnativedaysfr/cnpg/umami`. Waiting for the schedule means up
to 24h of blind time, and a wrong key or path then costs another overnight cycle to
re-verify — after every other box has been ticked. It can be run as soon as Task 4 Step 5
shows the pods Running; it is listed here only to keep Task 5 contiguous.

```bash
kubectl --context k8s-cndfrance-prod cnpg backup cnpg-umami -n cnd-analytics
kubectl --context k8s-cndfrance-prod -n cnd-analytics get backups -w
```
Expected: phase reaches `completed` within a few minutes. If the `cnpg` plugin is not
installed, apply a one-off `Backup` CR referencing `cluster.name: cnpg-umami`.

Then confirm the *schedule* fires too, the morning after:

```bash
kubectl --context k8s-cndfrance-prod -n cnd-analytics get backups
```
Expected: a second, scheduled `Backup` with phase `completed`.

---

### Task 6: Document the component

**Do this before Task 4 Step 3 (`gh pr create`), not after.** Neither file depends on anything
in Tasks 4–5 — no UUID, no cluster state — so leaving it last forces a second PR and a second
review round-trip on the same repo for two text files. It would also land `analytics/README.md`,
which carries the systematic-undercount caveat the design insists must be repeated there, days
*after* the dashboard goes live and people start quoting numbers off it. The task is numbered 6
only because it reads better after the manifests.

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
emits no script at all. Guarded in CI by `tests/build/analytics-tracker-guard.test.ts`.

## Components

- **Umami 3.3.0** — 1 replica. `check-db.js` applies Prisma migrations and enforces the
  version floor at startup — though that floor is 9.4, not the 12.14 Umami documents.
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
