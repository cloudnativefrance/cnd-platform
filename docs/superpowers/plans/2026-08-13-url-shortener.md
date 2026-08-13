# Self-hosted URL shortener — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve branded short links at `s.cloudnativedays.fr` from a self-hosted Shlink instance, with a basic-auth-gated admin UI at `links.cloudnativedays.fr`, tracking clicks and referrers only.

**Architecture:** A new Flux Kustomization `cnd-shortener` reconciles `communication/shortener/` into namespace `cnd-shortener`. Shlink (1 replica) serves redirects and the REST API against a 2-instance CloudNativePG cluster backed up to Scaleway; shlink-web-client (a static SPA) serves the admin UI behind ingress-nginx basic auth. Placement mirrors `communication/photos`: under `communication/` for taxonomy, but reconciled independently so a broken shortener cannot block Matrix.

**Tech Stack:** Kustomize, Flux CD, CloudNativePG, Bitnami SealedSecrets, ingress-nginx, cert-manager, Shlink 5.1.5, shlink-web-client 4.8.1.

**Spec:** `docs/superpowers/specs/2026-08-13-url-shortener-design.md`

## How "tests" work in this repository

This is a GitOps manifest repo, not an application codebase — there is no unit-test
framework, so the TDD loop is adapted, not skipped:

| Classic TDD step | Here |
|---|---|
| Write failing test | Add the manifest; run the gate and observe the specific failure |
| Run test → red | `kustomize build communication/shortener` fails on the missing/invalid resource |
| Implement | Write the manifest content |
| Run test → green | `./scripts/validate-manifests.sh` exits 0 |
| Integration test | Post-deploy `curl` / `kubectl` assertions in Task 5 |

`./scripts/validate-manifests.sh` renders every kustomization into `.bundle/` and runs a
polaris audit that fails on `danger`. It needs `kustomize` and `polaris` on `PATH`.

**Do not claim a task is done without running its verification command and reading the
output.** Several steps below deliberately expect a *failure* first.

**Do not push before Task 5.** Tasks 1–3 leave `kustomize build` intentionally failing on
files that later tasks create, so the branch is only green from Task 4 Step 5 onward.
Commits stay local until Task 5 Step 3, which pushes and opens the PR in one go.

## Global Constraints

- Namespace: `cnd-shortener`. Flux Kustomization name: `cnd-shortener`.
- Redirect host: `s.cloudnativedays.fr`. Admin host: `links.cloudnativedays.fr`.
- Images, pinned exactly: `shlinkio/shlink:5.1.5`, `shlinkio/shlink-web-client:4.8.1`. Both verified present on Docker Hub. `.polaris.yaml` sets `tagNotSpecified: danger` — never use `:latest` or `:stable`.
- CNPG house pattern, copied verbatim from `communication/photos/cnpg-cluster.yaml`: `instances: 2`, `storageClass: node-local-retain`, `size: 10Gi`, `endpointURL: https://s3.fr-par.scw.cloud`, `retentionPolicy: "90d"`, PodMonitor block with the two metric relabelings.
- Backup destination: `s3://cloudnativedaysfr/cnpg/shlink`.
- Every container sets `allowPrivilegeEscalation: false`, `runAsNonRoot: true`, CPU **and** memory requests, a CPU limit, and both probes. Polaris scores the *manifest*, not the image, so "the image already runs as non-root" does not satisfy `runAsRootAllowed` — an earlier draft made exactly that mistake. The only warnings this component may add are the two `notReadOnlyRootFilesystem` ones, which are explained in the manifests.
- `readOnlyRootFilesystem: false` on both containers. The Shlink entrypoint does `mkdir -p data/cache data/locks data/log data/proxies data/temp-geolite` under `/etc/shlink`; the web client writes `servers.json` into its nginx root.
- `GEOLITE_LICENSE_KEY` is never set. The entrypoint passes `--skip-download-geolite` when it is empty; setting it would require a MaxMind account for a disabled feature.
- Secrets are Bitnami SealedSecrets. The bootstrap strips `creationTimestamp: null` from `spec.template.metadata` (kubeconform in CI rejects it there), and `scripts/validate-manifests.sh` asserts the same thing repo-wide — `sed` exits 0 when it matches nothing, so the gate is the real guarantee. Only the nested occurrence is stripped; the top-level one is harmless and present on several SealedSecrets already on main.
- Ingress: `ingressClassName: public`, `cert-manager.io/cluster-issuer: letsencrypt`.
- Commit messages and PR text in English; never add co-author or generated-by trailers.
- The bootstrap is **self-contained**, matching `communication/photos/.bootstrap.sh`, so this PR merges independently of PR #160. The duplication against the sibling bootstraps is a knowingly accepted cost of that independence; a fix made in one should be grepped for in the others.
- **`scripts/validate-manifests.sh` now has a third gate step** asserting no `creationTimestamp: null` inside a SealedSecret template, repo-wide. This repo shipped that exact failure to main twice (`27b235b`, `6c61223`) because the local gate had no opinion about it and only CI did.

## Prerequisites (human, before Task 1)

- [ ] **Branch.** Work on `feat/url-shortener` (PR #159). The sibling analytics branch (PR #160) is independent, but the two overlap in exactly two files — `namespaces/namespaces.yaml` and the README.md domain list, both of which each branch appends to. Whichever merges second resolves both trivially.
- [ ] Two DNS **A** records pointing at the cluster ingress IP — there is no external-dns in this cluster:
  - `s.cloudnativedays.fr`
  - `links.cloudnativedays.fr`
- [ ] `kubectl` context for `k8s-cndfrance-prod` works: `kubectl --context k8s-cndfrance-prod get ns`
- [ ] `kubeseal --version` works and the sealed-secrets controller is reachable
- [ ] `kustomize`, `polaris`, `openssl`, `jq` on `PATH`

---

### Task 1: Namespace, scaffold, and sealed secrets

**Files:**
- Modify: `namespaces/namespaces.yaml` (append one namespace)
- Create: `communication/shortener/kustomization.yaml`
- Create: `communication/shortener/.bootstrap.sh`
- Generated by the script: `communication/shortener/cnd-france-scw-secret.yaml`, `shlink-cnpg-secret.yaml`, `shlink-secret.yaml`, `web-client-auth-sealedsecret.yaml`

**Interfaces:**
- Produces: namespace `cnd-shortener`; SealedSecret `shlink-cnpg-secret` (keys `username`, `password`, type `kubernetes.io/basic-auth`); SealedSecret `shlink-secret` (key `initial-api-key`); SealedSecret `cnd-france-scw-secret` (keys `access-key-id`, `secret-access-key`, `region`); SealedSecret `shlink-admin-auth` (key `auth`). Tasks 2–4 reference these names and keys exactly.

- [ ] **Step 1: Add the namespace**

Append to `namespaces/namespaces.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: cnd-shortener
```

- [ ] **Step 2: Create the kustomization listing all twelve resources**

Create `communication/shortener/kustomization.yaml`. It lists files that do not exist yet — that is intentional; the next step proves the gate catches it.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cnd-shortener

resources:
  - cnd-france-scw-secret.yaml
  - shlink-cnpg-secret.yaml
  - shlink-secret.yaml
  - web-client-auth-sealedsecret.yaml
  - cnpg-cluster.yaml
  - cnpg-scheduled-backup.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - web-client-deployment.yaml
  - web-client-service.yaml
  - web-client-ingress.yaml
```

- [ ] **Step 3: Run the gate and confirm it fails**

Run: `kustomize build communication/shortener`

Expected: FAIL — `accumulating resources: accumulation err='accumulating resources from 'cnd-france-scw-secret.yaml': evalsymlink failure`. This confirms the kustomization is wired and the gate detects missing files.

- [ ] **Step 4: Write the bootstrap script**

Create `communication/shortener/.bootstrap.sh` and `chmod +x` it:

```bash
#!/usr/bin/env bash
# Bootstrap script for the self-hosted URL shortener (Shlink).
# Run from the repo root: ./communication/shortener/.bootstrap.sh
#
# Generates the DB password, the initial Shlink API key and the admin-UI
# basic-auth credential, reseals the Scaleway backup creds into the new
# namespace, and writes 4 SealedSecret YAML files into communication/shortener/.
# Plaintexts are stashed in a 0600 file you must move to your password manager
# and then delete.
#
# Structure follows communication/photos/.bootstrap.sh deliberately: each
# component's bootstrap is self-contained so its PR can merge independently of
# any other. The cost is real — the reseal block and the creationTimestamp
# workaround now exist in more than one place — and is accepted knowingly. If a
# kubeseal or kubeconform quirk is ever fixed here, grep the other
# .bootstrap.sh files for the same code.
#
# Manual prereqs (do these BEFORE running this script):
#   1. Two DNS A records pointing at the cluster ingress:
#        s.cloudnativedays.fr
#        links.cloudnativedays.fr
#   2. `kubectl config use-context k8s-cndfrance-prod`. kubeseal fetches the
#      sealing certificate from the CURRENT context regardless of what
#      --context is passed to kubectl, so sealing on the wrong context yields
#      files that pass kustomize, kubeconform and CI, and fail only after
#      reconcile with "no key could decrypt secret" — by which point the
#      plaintexts have usually been deleted.

set -euo pipefail
trap 'echo "ERROR: bootstrap failed at line $LINENO" >&2' ERR

CTX="k8s-cndfrance-prod"
NS="cnd-shortener"
SOURCE_NS="cnd-project"   # where the existing Scaleway secret lives
ADMIN_USER="cnd"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_FILE="$HOME/.shlink-bootstrap-secrets.txt"

echo "==> Bootstrapping Shlink SealedSecrets in namespace ${NS}"

for bin in openssl kubeseal kubectl jq kustomize; do
  command -v "$bin" >/dev/null || { echo "ERROR: $bin not found on PATH" >&2; exit 1; }
done

CURRENT_CTX="$(kubectl config current-context)"
if [[ "${CURRENT_CTX}" != "${CTX}" ]]; then
  echo "ERROR: current context is '${CURRENT_CTX}', expected '${CTX}'." >&2
  echo "       kubeseal would seal against the wrong cluster. Run:" >&2
  echo "         kubectl config use-context ${CTX}" >&2
  exit 1
fi

# Everything below writes plaintext at some point. 0600 from creation, rather
# than a chmod after a redirect has already created the file world-readable.
umask 077

# ---------- Generate plaintexts ----------
# hex, not base64: these values end up in URLs and htpasswd lines, where '/',
# '+' and '=' cause trouble. Hex is safe by construction, so there is no hazard
# to check for afterwards. 32 bytes = 128 bits.
echo "==> Generating secrets"
PG_PASSWORD="$(openssl rand -hex 32)"
ADMIN_PASSWORD="$(openssl rand -hex 12)"

# Shlink accepts any string as an API key; a UUID is the upstream convention.
if command -v uuidgen >/dev/null; then
  API_KEY="$(uuidgen)"
else
  API_KEY="$(cat /proc/sys/kernel/random/uuid)"
fi

# ingress-nginx reads an htpasswd file. nginx supports apr1, so we avoid a
# dependency on apache2-utils.
AUTH_LINE="${ADMIN_USER}:$(openssl passwd -apr1 -stdin <<< "${ADMIN_PASSWORD}")"

install -m 600 /dev/null "${BACKUP_FILE}"
{
  echo "# Shlink bootstrap secrets — generated $(date -Iseconds)"
  echo "# MOVE these to a password manager and DELETE this file."
  echo ""
  echo "POSTGRES_PASSWORD=${PG_PASSWORD}"
  echo "INITIAL_API_KEY=${API_KEY}"
  echo "ADMIN_UI_USER=${ADMIN_USER}"
  echo "ADMIN_UI_PASSWORD=${ADMIN_PASSWORD}"
} > "${BACKUP_FILE}"
echo "    Plaintexts written to ${BACKUP_FILE} (mode 600)."

# ---------- Reseal Scaleway creds ----------
# Read once, extract three times — not three kubectl calls.
echo "==> Reading Scaleway creds from namespace ${SOURCE_NS}"
SCW_DATA="$(kubectl --context "${CTX}" -n "${SOURCE_NS}" get secret cnd-france-scw-secret -o json)"
SCW_ACCESS_KEY_ID="$(echo "$SCW_DATA"     | jq -r '.data."access-key-id"     | @base64d')"
SCW_SECRET_ACCESS_KEY="$(echo "$SCW_DATA" | jq -r '.data."secret-access-key" | @base64d')"
SCW_REGION="$(echo "$SCW_DATA"            | jq -r '.data."region"            | @base64d')"

echo "==> Resealing cnd-france-scw-secret for ${NS}"
kubectl --context "${CTX}" create secret generic cnd-france-scw-secret \
  --namespace "${NS}" \
  --from-literal=access-key-id="${SCW_ACCESS_KEY_ID}" \
  --from-literal=secret-access-key="${SCW_SECRET_ACCESS_KEY}" \
  --from-literal=region="${SCW_REGION}" \
  --dry-run=client -o yaml \
| kubeseal --format yaml --namespace "${NS}" > "${DIR}/cnd-france-scw-secret.yaml"

# ---------- Database credentials ----------
# CNPG expects kubernetes.io/basic-auth with username + password.
echo "==> Sealing shlink-cnpg-secret"
kubectl --context "${CTX}" create secret generic shlink-cnpg-secret \
  --namespace "${NS}" \
  --type kubernetes.io/basic-auth \
  --from-literal=username=shlink \
  --from-literal=password="${PG_PASSWORD}" \
  --dry-run=client -o yaml \
| kubeseal --format yaml --namespace "${NS}" > "${DIR}/shlink-cnpg-secret.yaml"

# ---------- Shlink initial API key ----------
echo "==> Sealing shlink-secret (initial API key)"
kubectl --context "${CTX}" create secret generic shlink-secret \
  --namespace "${NS}" \
  --from-literal=initial-api-key="${API_KEY}" \
  --dry-run=client -o yaml \
| kubeseal --format yaml --namespace "${NS}" > "${DIR}/shlink-secret.yaml"

# ---------- Admin UI basic auth ----------
# ingress-nginx requires the data key to be named exactly `auth`.
echo "==> Sealing shlink-admin-auth (basic auth for the admin UI)"
kubectl --context "${CTX}" create secret generic shlink-admin-auth \
  --namespace "${NS}" \
  --from-literal=auth="${AUTH_LINE}" \
  --dry-run=client -o yaml \
| kubeseal --format yaml --namespace "${NS}" > "${DIR}/web-client-auth-sealedsecret.yaml"

# ---------- Strip the templated creationTimestamp ----------
# kubectl create --dry-run=client emits `creationTimestamp: null` and kubeseal
# passes it into spec.template.metadata, where the kubeconform Dagger module in
# CI rejects it (the CRD schema sets additionalProperties: false there). Shipped
# to main twice already: 27b235b, 6c61223.
#
# Only the 6-space form is stripped. The top-level metadata.creationTimestamp is
# harmless — ticketing/alfio, callforpapers/pretalx and website-staging all carry
# it on main with green CI — so removing it too would make these files differ
# cosmetically from every existing SealedSecret for no reason.
#
# sed exits 0 when it matches nothing, which is why scripts/validate-manifests.sh
# asserts the same thing repo-wide as a real gate.
for f in cnd-france-scw-secret.yaml shlink-cnpg-secret.yaml shlink-secret.yaml web-client-auth-sealedsecret.yaml; do
  sed -i '/^      creationTimestamp: null$/d' "${DIR}/${f}"
done

# ---------- Validate ----------
# Non-empty is too weak: a stderr dump or a truncated write also satisfies it.
# The render-based assertion needs every resource to exist, so it is deferred to
# Task 4 Step 4; here we assert each file parses as a SealedSecret.
echo "==> Verifying the four sealed files"
for f in cnd-france-scw-secret.yaml shlink-cnpg-secret.yaml shlink-secret.yaml web-client-auth-sealedsecret.yaml; do
  grep -q '^kind: SealedSecret$' "${DIR}/${f}" \
    || { echo "ERROR: ${DIR}/${f} is not a SealedSecret" >&2; exit 1; }
done
echo "    OK: 4 SealedSecrets written"

echo ""
echo "==> Plaintext backup at ${BACKUP_FILE} — MOVE to your password manager + DELETE."
echo "==> Admin UI login will be: ${ADMIN_USER} / (see backup file)"
```

- [ ] **Step 5: Run the bootstrap script**

Run: `chmod +x communication/shortener/.bootstrap.sh && ./communication/shortener/.bootstrap.sh`

Expected: four `.yaml` files created in `communication/shortener/`, and `~/.shlink-bootstrap-secrets.txt` written with mode 600.

- [ ] **Step 6: Verify exactly four SealedSecrets were produced**

A full `kustomize build` cannot run yet — the eight non-secret resources do not
exist until Task 4 — so assert on the sealed files directly. The render-based
assertion that `communication/photos/.bootstrap.sh` ends with is added at Task 4
Step 5, once the kustomization resolves.

```bash
# grep -c over a glob prints one `file:count` line per file and exits 1 when
# nothing matches, so this uses -l | wc -l instead.
test "$(grep -l '^kind: SealedSecret' communication/shortener/*.yaml | wc -l)" = 4 \
  && echo "OK: 4 SealedSecrets" || echo "FAIL: wrong SealedSecret count"
```
Expected: `OK: 4 SealedSecrets`.

The `creationTimestamp` check is no longer a per-step chore: `scripts/validate-manifests.sh`
now asserts it repo-wide (step 3 of the gate), so it is covered by every gate run
from Task 2 onward and by any file sealed outside this script.

- [ ] **Step 7: Move the plaintexts out**

Copy the contents of `~/.shlink-bootstrap-secrets.txt` into the password manager, then `rm ~/.shlink-bootstrap-secrets.txt`. Do not commit it — it is outside the repo, but confirm `git status` is clean of it.

- [ ] **Step 8: Commit**

`kustomize build` still fails at this point (the eight non-secret files are missing); that is expected and resolved by Task 4.

```bash
git add scripts/validate-manifests.sh \
        namespaces/namespaces.yaml \
        communication/shortener/kustomization.yaml \
        communication/shortener/.bootstrap.sh \
        communication/shortener/cnd-france-scw-secret.yaml \
        communication/shortener/shlink-cnpg-secret.yaml \
        communication/shortener/shlink-secret.yaml \
        communication/shortener/web-client-auth-sealedsecret.yaml
git commit -m "feat(shortener): namespace and sealed secrets for Shlink"
```

---

### Task 2: PostgreSQL via CloudNativePG

**Files:**
- Create: `communication/shortener/cnpg-cluster.yaml`
- Create: `communication/shortener/cnpg-scheduled-backup.yaml`

**Interfaces:**
- Consumes: `shlink-cnpg-secret` and `cnd-france-scw-secret` from Task 1.
- Produces: Service `cnpg-shlink-rw` on port 5432, database `shlink`, owner `shlink`. Task 3 connects with `DB_HOST: cnpg-shlink-rw`.

- [ ] **Step 1: Write the cluster manifest**

Create `communication/shortener/cnpg-cluster.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cnpg-shlink
spec:
  description: "PostgreSQL cluster for the Shlink URL shortener"
  instances: 2

  bootstrap:
    initdb:
      database: shlink
      owner: shlink
      secret:
        name: shlink-cnpg-secret

  superuserSecret:
    name: shlink-cnpg-secret

  storage:
    storageClass: node-local-retain
    size: 10Gi

  backup:
    barmanObjectStore:
      destinationPath: "s3://cloudnativedaysfr/cnpg/shlink"
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
      # 2x the request, not equal to it: an equal limit makes the pod
      # Guaranteed QoS with zero burst room, and the midnight ScheduledBackup
      # runs barman-cloud-backup with gzip + S3 buffers inside this same pod.
      # A hard 256Mi OOMKills there, failing over and forcing a full replica
      # resync — nightly. photos uses 768Mi; this is the compromise.
      memory: "512Mi"
```

- [ ] **Step 2: Write the scheduled backup**

Create `communication/shortener/cnpg-scheduled-backup.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: cnpg-shlink
spec:
  schedule: "0 0 0 * * *" # At midnight every day
  backupOwnerReference: self
  cluster:
    name: cnpg-shlink
```

- [ ] **Step 3: Verify the gate now fails on a different file**

Run: `kustomize build communication/shortener 2>&1 | tail -3`

Expected: FAIL, but the error now names `deployment.yaml` rather than `cnpg-cluster.yaml` — proving both new files parse and accumulate.

- [ ] **Step 4: Commit**

```bash
git add communication/shortener/cnpg-cluster.yaml \
        communication/shortener/cnpg-scheduled-backup.yaml
git commit -m "feat(shortener): CNPG cluster and scheduled backup for Shlink"
```

---

### Task 3: Shlink service

**Files:**
- Create: `communication/shortener/deployment.yaml`
- Create: `communication/shortener/service.yaml`
- Create: `communication/shortener/ingress.yaml`

**Interfaces:**
- Consumes: `cnpg-shlink-rw` (Task 2), `shlink-cnpg-secret`, `shlink-secret` (Task 1).
- Produces: Service `shlink` on port 8080, port name `http`. Task 4's SPA points at `https://s.cloudnativedays.fr`.

- [ ] **Step 1: Write the Deployment**

Create `communication/shortener/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shlink
  namespace: cnd-shortener
  labels:
    app.kubernetes.io/name: shlink
    app.kubernetes.io/component: url-shortener
    app.kubernetes.io/part-of: cnd-france
spec:
  replicas: 1
  revisionHistoryLimit: 3
  # Recreate, NOT RollingUpdate. With replicas:1, maxUnavailable:0 forbids
  # scaling the old pod down before the new one is Ready, so maxSurge:1 would
  # guarantee two Shlink pods run concurrently on every rollout — the exact
  # multi-instance state a single replica exists to avoid. The entrypoint runs
  # `shlink-installer init` (migrations) on every start and its locks live in
  # the pod-local data/locks dir, so the new pod would migrate the schema while
  # the old pod still serves traffic against the pre-migration one. Same
  # reasoning as communication/photos/museum.yaml.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: shlink
  template:
    metadata:
      labels:
        app.kubernetes.io/name: shlink
        app.kubernetes.io/component: url-shortener
        app.kubernetes.io/part-of: cnd-france
    spec:
      containers:
        - name: shlink
          # Shlink 4.0+ images already run as a non-root user.
          image: shlinkio/shlink:5.1.5
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: DEFAULT_DOMAIN
              value: s.cloudnativedays.fr
            - name: IS_HTTPS_ENABLED
              value: "true"
            - name: DB_DRIVER
              value: postgres
            - name: DB_HOST
              value: cnpg-shlink-rw
            - name: DB_PORT
              value: "5432"
            - name: DB_NAME
              value: shlink
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: shlink-cnpg-secret
                  key: username
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: shlink-cnpg-secret
                  key: password
            # Creates an admin-scoped API key on first boot only.
            - name: INITIAL_API_KEY
              valueFrom:
                secretKeyRef:
                  name: shlink-secret
                  key: initial-api-key
            # Privacy posture: a visit row keeps timestamp, short code and
            # referrer. No IP, no user agent, no location. GEOLITE_LICENSE_KEY
            # is deliberately unset — the entrypoint then passes
            # --skip-download-geolite, so no MaxMind account is needed.
            - name: DISABLE_IP_TRACKING
              value: "true"
            - name: DISABLE_UA_TRACKING
              value: "true"
            - name: DISABLE_REFERRER_TRACKING
              value: "false"
            - name: TRACK_ORPHAN_VISITS
              value: "false"
          # /rest/health returns 503 when Postgres is unreachable. That is
          # correct for readiness (stop routing traffic) but wrong for
          # liveness — it would restart-loop the pod through a CNPG failover.
          readinessProbe:
            httpGet:
              path: /rest/health
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 60
            periodSeconds: 30
            timeoutSeconds: 3
            failureThreshold: 3
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              # cpu limit set because .polaris.yaml scores cpuLimitsMissing;
              # website/deployment.yaml is the precedent.
              cpu: 500m
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            # The image already runs as UID 1001 (verified from its registry
            # config), so this is free — but polaris scores the manifest, not
            # the image, and without it runAsRootAllowed is reported.
            runAsNonRoot: true
            # The entrypoint creates data/cache, data/locks, data/log,
            # data/proxies and data/temp-geolite under /etc/shlink.
            readOnlyRootFilesystem: false
            capabilities:
              drop:
                - ALL
```

- [ ] **Step 2: Write the Service**

Create `communication/shortener/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: shlink
  namespace: cnd-shortener
  labels:
    app.kubernetes.io/name: shlink
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8080
      protocol: TCP
      targetPort: http
  selector:
    app.kubernetes.io/name: shlink
```

- [ ] **Step 3: Write the Ingress**

Create `communication/shortener/ingress.yaml`:

```yaml
---
# Every path on this host is short-code namespace: /<code> redirects, and
# /rest/* is the API. The admin UI therefore lives on its own host — mounting
# it here would permanently burn a slug.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shlink
  namespace: cnd-shortener
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: public
  rules:
    - host: s.cloudnativedays.fr
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: shlink
                port:
                  name: http
  tls:
    - hosts:
        - s.cloudnativedays.fr
      secretName: shlink-tls
```

- [ ] **Step 4: Verify the gate fails only on the web-client files**

Run: `kustomize build communication/shortener 2>&1 | tail -3`

Expected: FAIL naming `web-client-deployment.yaml`. Any other error means one of the three files above is malformed — fix before continuing.

- [ ] **Step 5: Commit**

```bash
git add communication/shortener/deployment.yaml \
        communication/shortener/service.yaml \
        communication/shortener/ingress.yaml
git commit -m "feat(shortener): Shlink deployment, service and ingress"
```

---

### Task 4: Admin UI behind basic auth

**Files:**
- Create: `communication/shortener/web-client-deployment.yaml`
- Create: `communication/shortener/web-client-service.yaml`
- Create: `communication/shortener/web-client-ingress.yaml`

**Interfaces:**
- Consumes: `shlink-secret` (`initial-api-key`) and `shlink-admin-auth` (`auth`) from Task 1.
- Produces: the first point at which `kustomize build communication/shortener` succeeds and `./scripts/validate-manifests.sh` can gate the whole component.

- [ ] **Step 1: Write the web client Deployment**

Create `communication/shortener/web-client-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shlink-web-client
  namespace: cnd-shortener
  labels:
    app.kubernetes.io/name: shlink-web-client
    app.kubernetes.io/component: admin-ui
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
      app.kubernetes.io/name: shlink-web-client
  template:
    metadata:
      labels:
        app.kubernetes.io/name: shlink-web-client
        app.kubernetes.io/component: admin-ui
        app.kubernetes.io/part-of: cnd-france
    spec:
      containers:
        - name: shlink-web-client
          image: shlinkio/shlink-web-client:4.8.1
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            # These are baked into a servers.json served to the browser, so the
            # API key IS visible to anyone who loads this page. Upstream:
            # "use this only when you self-host shlink-web-client, and you know
            # only trusted people will have access to it." The ingress basic
            # auth is what makes that true — it is not optional here.
            - name: SHLINK_SERVER_URL
              value: https://s.cloudnativedays.fr
            - name: SHLINK_SERVER_NAME
              value: CND France
            - name: SHLINK_SERVER_API_KEY
              valueFrom:
                secretKeyRef:
                  name: shlink-secret
                  key: initial-api-key
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
            periodSeconds: 30
            timeoutSeconds: 3
            failureThreshold: 3
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
          securityContext:
            allowPrivilegeEscalation: false
            # Image runs as UID 101 (verified from its registry config).
            runAsNonRoot: true
            # The entrypoint writes servers.json into the nginx document root.
            readOnlyRootFilesystem: false
            capabilities:
              drop:
                - ALL
              # No `add:` list. website-staging/deployment.yaml adds CHOWN,
              # SETGID and SETUID, but it pairs them with a pod-level
              # securityContext of runAsNonRoot:false + fsGroup:0 — i.e. it runs
              # as root, where added capabilities mean something. This image
              # runs as UID 101, so added capabilities are stripped from the
              # effective set at exec and would be pure decoration.
```

- [ ] **Step 2: Write the web client Service**

Create `communication/shortener/web-client-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: shlink-web-client
  namespace: cnd-shortener
  labels:
    app.kubernetes.io/name: shlink-web-client
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8080
      protocol: TCP
      targetPort: http
  selector:
    app.kubernetes.io/name: shlink-web-client
```

- [ ] **Step 3: Write the basic-auth Ingress**

Create `communication/shortener/web-client-ingress.yaml`:

```yaml
---
# Basic auth gate. The secret is sealed into web-client-auth-sealedsecret.yaml
# alongside this file; ingress-nginx requires its data key to be named exactly
# `auth`. This is the only control in front of an admin-scoped API key that the
# SPA serves to the browser — see web-client-deployment.yaml.
#
# cert-manager is unaffected: its HTTP-01 solver uses a separate, more-specific
# Ingress for /.well-known/acme-challenge/ which does not inherit these
# annotations.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shlink-web-client
  namespace: cnd-shortener
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: shlink-admin-auth
    nginx.ingress.kubernetes.io/auth-realm: "CND France — links"
spec:
  ingressClassName: public
  rules:
    - host: links.cloudnativedays.fr
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: shlink-web-client
                port:
                  name: http
  tls:
    - hosts:
        - links.cloudnativedays.fr
      secretName: shlink-web-client-tls
```

- [ ] **Step 4: Verify the render now succeeds**

Run:
```bash
kustomize build communication/shortener | grep '^kind:' | sort | uniq -c
```
Expected, by kind rather than a single magic number that any future addition breaks:

```
      2 kind: Deployment
      2 kind: Ingress
      2 kind: Service
      1 kind: Cluster
      1 kind: ScheduledBackup
      4 kind: SealedSecret
```

The SealedSecret line is the deferred half of Task 1 Step 6 — it is the assertion
`communication/photos/.bootstrap.sh` ends with, and it catches a kubeseal run that
wrote valid YAML of the wrong kind or a file the kustomization does not list.

- [ ] **Step 5: Run the full repository gate**

Run: `./scripts/validate-manifests.sh`

Expected: `==> All gates passed`, including the new step-3 SealedSecret hygiene check.
If polaris reports a `danger`, fix the manifest — do not add an exemption to
`.polaris.yaml`; the file's own rules of engagement say to fix rather than exempt.

Polaris will still report `notReadOnlyRootFilesystem` twice, which is expected and
explained in the manifests. It must **not** report `cpuLimitsMissing` or
`runAsRootAllowed` — both containers now set a cpu limit and `runAsNonRoot: true`.
If either appears, a securityContext or limits block was dropped.

- [ ] **Step 6: Commit**

```bash
git add communication/shortener/web-client-deployment.yaml \
        communication/shortener/web-client-service.yaml \
        communication/shortener/web-client-ingress.yaml
git commit -m "feat(shortener): admin UI behind ingress basic auth"
```

---

### Task 5: Go live and verify

**Files:**
- Create: `clusters/k8s-cndfrance-prod/shortener.yaml`

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: a reconciling `cnd-shortener` Flux Kustomization and a verified deployment.

This task is last on purpose: the Flux Kustomization's health checks reference objects that must already exist in git, or reconciliation reports failure on arrival.

- [ ] **Step 1: Write the Flux Kustomization**

Create `clusters/k8s-cndfrance-prod/shortener.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cnd-shortener
  namespace: flux-system
spec:
  prune: true
  interval: 2m0s
  path: ./communication/shortener
  dependsOn:
    - name: cnd-operators
    # photos.yaml omits this, but every object here lands in a namespace owned
    # by the cnd-namespaces Kustomization. Without the edge, a first reconcile
    # that wins the race fails with `namespaces "cnd-shortener" not found` and
    # stays NotReady until the next 2m pass.
    - name: cnd-namespaces
  sourceRef:
    kind: GitRepository
    name: customer
  # Without an explicit timeout Flux uses the interval (2m), which is shorter
  # than a first-time reconcile: two CNPG instances, their PVCs, initdb, then
  # Shlink's startup migrations. The health checks below would report a timeout
  # that reads as a real failure.
  timeout: 10m0s
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: shlink
      namespace: cnd-shortener
    - apiVersion: apps/v1
      kind: Deployment
      name: shlink-web-client
      namespace: cnd-shortener
    - apiVersion: postgresql.cnpg.io/v1
      kind: Cluster
      name: cnpg-shlink
      namespace: cnd-shortener
```

- [ ] **Step 2: Validate the Flux Kustomization**

`./scripts/validate-manifests.sh` does **not** cover this file: it discovers work
with `find . -name kustomization.yaml`, and `clusters/k8s-cndfrance-prod/` holds
bare Flux YAML with no kustomization.yaml. Re-running it here would re-render the
same 12 kustomizations as Task 4 Step 5 and prove nothing about the file just
written. The kubeconform Dagger module in CI is what actually schema-checks it.

Run a cheap local parse instead, then rely on CI:
```bash
kubectl --context k8s-cndfrance-prod apply --dry-run=client \
  -f clusters/k8s-cndfrance-prod/shortener.yaml
```
Expected: `kustomization.kustomize.toolkit.fluxcd.io/cnd-shortener created (dry run)`.

- [ ] **Step 3: Commit and open the PR**

```bash
git add clusters/k8s-cndfrance-prod/shortener.yaml
git commit -m "feat(shortener): reconcile the shortener with Flux"
git push -u origin feat/url-shortener
gh pr create --title "Self-hosted URL shortener at s.cloudnativedays.fr" \
  --body "Deploys Shlink 5.1.5 + shlink-web-client 4.8.1 on CNPG.

Short links at https://s.cloudnativedays.fr, admin UI at
https://links.cloudnativedays.fr behind basic auth.

Shlink over YOURLS because YOURLS is MySQL-only and this cluster
standardises on CloudNativePG. IP and user-agent tracking are disabled;
referrers are kept. No MaxMind account is needed.

Design: docs/superpowers/specs/2026-08-13-url-shortener-design.md
Plan: docs/superpowers/plans/2026-08-13-url-shortener.md"
```

- [ ] **Step 4: Get the PR reviewed and merged**

Branch protection requires one approving review. Nothing below this line can run
until the PR is merged and Flux has reconciled — do not proceed to Step 5 while
the PR is still open, or every `kubectl` call returns `NotFound` and reads as a
failure of the plan rather than of the sequencing.

- [ ] **Step 5: Wait for reconciliation**

Run:
```bash
kubectl --context k8s-cndfrance-prod -n flux-system get kustomization cnd-shortener
kubectl --context k8s-cndfrance-prod -n cnd-shortener get pods
```
Expected: Kustomization `READY=True`; pods `cnpg-shlink-1`, `cnpg-shlink-2`, `shlink-*`, `shlink-web-client-*` all `Running`.

If Shlink is `CrashLoopBackOff`, read `kubectl -n cnd-shortener logs deploy/shlink` — the most likely cause is the database not yet accepting connections, since `shlink-installer init` runs migrations at startup.

- [ ] **Step 5: Acceptance — health**

Run: `curl -sS https://s.cloudnativedays.fr/rest/health`

Expected: JSON containing `"status":"pass"`.

- [ ] **Step 6: Acceptance — create a link through the API**

Run, with `KEY` set to the `INITIAL_API_KEY` from the password manager:
```bash
curl -sS -X POST https://s.cloudnativedays.fr/rest/v3/short-urls \
  -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"longUrl":"https://cloudnativedays.fr","customSlug":"test"}' | jq -r '.shortUrl'
```
Expected: `https://s.cloudnativedays.fr/test`

- [ ] **Step 8: Acceptance — the redirect works, and records a visit**

**Must be a GET, not a HEAD.** Shlink refuses to track HEAD requests:
`module/Core/src/Visit/RequestTracker.php::shouldTrackRequest()` opens with
`if ($forwardedMethod === self::METHOD_HEAD) { return false; }`, and Mezzio's
`ImplicitHeadMiddleware` sets that attribute. `curl -I` would therefore return a
correct-looking 302 while writing no visit row, and Step 9 below would then find
an empty list — which reads deceptively like "no IP stored, privacy works".

Run, sending a referrer so Step 9 has something to assert on:
```bash
curl -sS -o /dev/null -D- -H 'Referer: https://example.com' \
  https://s.cloudnativedays.fr/test | head -5
```
Expected: `HTTP/2 302` with `location: https://cloudnativedays.fr`.

- [ ] **Step 9: Acceptance — the privacy configuration took effect**

This is the acceptance test for the design's central claim, not a nicety.

Run:
```bash
curl -sS -H "X-Api-Key: $KEY" \
  "https://s.cloudnativedays.fr/rest/v3/short-urls/test/visits" \
  | jq '.visits.data[0]'
```
Expected: **a non-null visit object** — if it is `null`, Step 8 was run as a HEAD
and nothing was tracked; re-run it as a GET before reading anything into this
result. The object must show `visitLocation: null`, an empty `userAgent`, no IP
address anywhere in the payload, and `referer: "https://example.com"` — the last
of which proves referrer tracking is still on rather than everything being off.

- [ ] **Step 9: Acceptance — the admin UI**

Open `https://links.cloudnativedays.fr` in a browser.

Expected: a basic-auth prompt; after authenticating with the `cnd` credential, the dashboard loads with the "CND France" server already selected and the `test` link listed.

- [ ] **Step 10: Create a separate API key for automation**

The initial key belongs to the SPA. Anything scripted gets its own, so either can be revoked independently:

```bash
kubectl --context k8s-cndfrance-prod -n cnd-shortener exec deploy/shlink -- \
  bin/cli api-key:generate --name=automation
```
Store the printed key in the password manager.

- [ ] **Step 11: Clean up the test link**

```bash
# -sS prints nothing for a 204 AND nothing for a 401/404, so without -w this
# step passes whether the delete worked or the key was wrong.
curl -sS -X DELETE -o /dev/null -w '%{http_code}\n' \
  https://s.cloudnativedays.fr/rest/v3/short-urls/test -H "X-Api-Key: $KEY"
curl -sS -o /dev/null -w '%{http_code}\n' https://s.cloudnativedays.fr/test
```
Expected: `204`, then `404`.

- [ ] **Step 12: Confirm backups work — now, not at midnight**

This is the only check that proves the Scaleway credentials resealed in Task 1
actually authenticate against `s3://cloudnativedaysfr/cnpg/shlink`. Waiting for
the scheduled run means up to 24h of blind time, and a wrong key or path then
costs a second overnight cycle to re-verify. Trigger one immediately:

```bash
kubectl --context k8s-cndfrance-prod cnpg backup cnpg-shlink -n cnd-shortener
kubectl --context k8s-cndfrance-prod -n cnd-shortener get backups -w
```
Expected: phase reaches `completed` within a few minutes. If the plugin is not
installed, apply a one-off `Backup` CR referencing `cluster.name: cnpg-shlink`.

Then, the morning after, confirm the *schedule* also fires:
```bash
kubectl --context k8s-cndfrance-prod -n cnd-shortener get backups
```
Expected: a second, scheduled `Backup` with phase `completed`.

---

### Task 6: Document the component

**Do this before Task 5 Step 3 (`gh pr create`), not after.** Neither file depends on
anything in Tasks 4–5 — no UUID, no cluster state — so leaving it until last forces a second
PR and a second review round-trip on the same repo for two text files, and lands the
operational caveats days after people start reading the dashboard. Both commits belong in
the same PR; the task is numbered 6 only because it reads better after the manifests.

**Files:**
- Create: `communication/shortener/README.md`
- Modify: `README.md` (repo root — add the shortener to the domain list)

- [ ] **Step 1: Write the component README**

Create `communication/shortener/README.md`:

```markdown
# URL shortener (Shlink)

Short links for Cloud Native Days France, self-hosted.

| Host | Serves | Auth |
|------|--------|------|
| `s.cloudnativedays.fr` | Redirects (`/<code>`) and the REST API (`/rest/*`) | API key on the API; redirects public |
| `links.cloudnativedays.fr` | shlink-web-client admin UI | ingress basic auth |

## Components

- **Shlink 5.1.5** — 1 replica. Runs `shlink-installer init` (migrations) on every start.
- **shlink-web-client 4.8.1** — static SPA. Its API key is served to the browser, so the
  basic-auth gate is a security control, not a convenience.
- **cnpg-shlink** — 2-instance CloudNativePG cluster, daily backup to
  `s3://cloudnativedaysfr/cnpg/shlink`, 90-day retention.

## Tracking

Clicks and referrers only. `DISABLE_IP_TRACKING` and `DISABLE_UA_TRACKING` are `true`, so a
visit row holds a timestamp, the short code and a referrer — no IP, no user agent, no
location. `GEOLITE_LICENSE_KEY` is deliberately unset: the entrypoint then passes
`--skip-download-geolite`, so no MaxMind account is required.

Re-enabling geolocation means a MaxMind account, a fifth sealed secret, and
`DISABLE_IP_TRACKING: "false"` — which changes the privacy posture and would want a notice.

## Creating links

Via the UI at `links.cloudnativedays.fr`, or the API:

```bash
curl -sS -X POST https://s.cloudnativedays.fr/rest/v3/short-urls \
  -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"longUrl":"https://cloudnativedays.fr/cfp","customSlug":"cfp"}'
```

Automation uses its own API key, not the one embedded in the SPA. New keys:

```bash
kubectl -n cnd-shortener exec deploy/shlink -- bin/cli api-key:generate --name=<name>
```

## Operational notes

- **Single replica** by design. Multi-instance Shlink needs `REDIS_SERVERS` for shared
  locks; given the cluster's resource budget that is not worth a few seconds of rollout
  downtime. Revisit if short links go onto printed material.
- **Readiness uses `/rest/health`, liveness uses a TCP check.** `/rest/health` returns 503
  when Postgres is unreachable; wiring that to liveness would restart-loop the pod through
  a CNPG failover.
- **Secrets** are regenerated by `.bootstrap.sh`. Rotating the admin-UI password should be
  accompanied by rotating the API key, since the two protect each other.
```

- [ ] **Step 2: Add the domain to the root README**

In `README.md`, insert immediately **after the `- 💬 **communication**:` line** (a
content anchor, not a line number — the sibling analytics plan edits the same
list, so absolute line numbers go stale the moment either branch merges):

```markdown
- 🔗 **communication/shortener**: Self-hosted URL shortener (Shlink) serving `s.cloudnativedays.fr`
```

Leave the stale Mattermost reference on that line alone — it is unrelated here.

- [ ] **Step 3: Commit**

```bash
git add communication/shortener/README.md README.md
git commit -m "docs(shortener): document the shortener component"
```

---

## Rollback

Deleting `clusters/k8s-cndfrance-prod/shortener.yaml` and pushing removes the Flux
Kustomization; `prune: true` then removes every object it owns, including the CNPG cluster.
The S3 backups are untouched by pruning and retain for 90 days.

Two things this does **not** do, both of which bite during an actual rollback:

- **The PVCs do not simply survive.** CNPG's PVCs carry ownerReferences to the `Cluster`, so
  the API server cascade-deletes them when the Cluster goes. With a Retain reclaim policy the
  *PVs* survive, but they land in `Released` with a stale `claimRef` that blocks re-binding
  until someone clears `spec.claimRef` on each one — and because the class is node-local,
  each PV is pinned to the node that provisioned it, so a re-created cluster may not even be
  schedulable there. Recovery is a manual procedure, not an automatic one.
- **Re-deploying onto the same S3 prefix fails.** A fresh cluster with the same name has a new
  system identifier and timeline, so CNPG's first-WAL-archive check rejects the non-empty
  `s3://cloudnativedaysfr/cnpg/shlink` prefix and continuous archiving never becomes healthy —
  leaving the restored shortener running with no backups and the Flux health check never
  Ready. On re-deploy, either purge the prefix or move to `…/cnpg/shlink-2`.

If the intent is to restore rather than to discard, use CNPG's `bootstrap.recovery` against
the existing barman store instead of re-running `initdb`.
