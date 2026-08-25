#!/usr/bin/env bash
# Bootstrap script for self-hosted Plane (Community Edition).
# Run from the repo root: ./project/plane/.bootstrap.sh
#
# Generates the Postgres password, the RabbitMQ password, Plane's SECRET_KEY
# and LIVE_SERVER_SECRET_KEY, and the /god-mode basic-auth credential; reads
# the existing Scaleway creds to build the doc-store secret; and writes 6
# SealedSecret YAML files into project/plane/. Plaintexts are stashed in a 0600
# file you must move to your password manager and then delete.
#
# Structure follows analytics/.bootstrap.sh deliberately: each component's
# bootstrap is self-contained so its PR can merge independently of any other.
# The cost is real — the creationTimestamp workaround now exists in more than
# one place — and is accepted knowingly. If a kubeseal or kubeconform quirk is
# ever fixed here, grep the other .bootstrap.sh files for the same code.
#
# Unlike the other bootstraps in this repo there is NO reseal block:
# plane lives in cnd-project, the same namespace as baserow, so the existing
# cnd-france-scw-secret already applies. It is read here only to build the
# doc-store secret, which needs the same credentials under Plane's own key
# names (AWS_ACCESS_KEY_ID rather than access-key-id).
#
# Manual prereqs (do these BEFORE running this script):
#   1. `kubectl config use-context k8s-cndfrance-prod`. kubeseal fetches the
#      sealing certificate from the CURRENT context regardless of what
#      --context is passed to kubectl, so sealing on the wrong context yields
#      files that pass kustomize, kubeconform and CI, and fail only after
#      reconcile with "no key could decrypt secret".
#   2. Create the Scaleway object-storage bucket `cnd-plane` in fr-par.
#      A dedicated bucket, not the shared cloudnativedaysfr one: the CORS rule
#      below is bucket-scoped, and it does not belong on the bucket holding
#      every CNPG backup for the platform.
#   3. Apply this CORS rule to that bucket — without it, browser uploads fail
#      silently, visible only in the browser console:
#        aws s3api put-bucket-cors --bucket cnd-plane \
#          --endpoint-url https://s3.fr-par.scw.cloud \
#          --cors-configuration '{"CORSRules":[{
#             "AllowedOrigins":["https://plane.cloudnativedays.fr"],
#             "AllowedMethods":["GET","PUT","POST","HEAD"],
#             "AllowedHeaders":["*"],
#             "ExposeHeaders":["ETag"],
#             "MaxAgeSeconds":3000}]}'
#   4. A DNS A record for plane.cloudnativedays.fr pointing at the cluster
#      ingress. Create it before the HelmRelease PR merges, so cert-manager can
#      complete the HTTP-01 challenge on first reconcile.

set -euo pipefail
trap 'echo "ERROR: bootstrap failed at line $LINENO" >&2' ERR

CTX="k8s-cndfrance-prod"
NS="cnd-project"
BUCKET="cnd-plane"
GODMODE_USER="cnd"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_FILE="$HOME/.plane-bootstrap-secrets.txt"

echo "==> Bootstrapping Plane SealedSecrets in namespace ${NS}"

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
# hex, not base64: PG_PASSWORD and RABBITMQ_PASSWORD are interpolated into
# DATABASE_URL and AMQP_URL, where a '/' or '+' corrupts the URL and surfaces
# as a confusing auth failure rather than a parse error. The god-mode password
# ends up in an htpasswd line, where '=' causes trouble. Hex is safe by
# construction, so there is no hazard to check for afterwards.
#
# SECRET_KEY is NOT rotatable. Plane uses it to encrypt data at rest, and the
# chart README is explicit that changing it after data exists corrupts what is
# already encrypted. Generated once, here, and never again.
echo "==> Generating secrets"
PG_PASSWORD="$(openssl rand -hex 32)"
RABBITMQ_PASSWORD="$(openssl rand -hex 32)"
SECRET_KEY="$(openssl rand -hex 32)"
LIVE_SERVER_SECRET_KEY="$(openssl rand -hex 32)"
GODMODE_PASSWORD="$(openssl rand -hex 12)"

# ingress-nginx reads an htpasswd file. nginx supports apr1, so we avoid a
# dependency on apache2-utils.
GODMODE_AUTH_LINE="${GODMODE_USER}:$(openssl passwd -apr1 -stdin <<< "${GODMODE_PASSWORD}")"

# Mirror the chart's own generated connection-string format verbatim
# (templates/config-secrets/app-env.yaml). Deviating here — a missing trailing
# slash on AMQP_URL, say — breaks against the very services the chart deploys.
DATABASE_URL="postgresql://plane:${PG_PASSWORD}@cnpg-plane-rw.${NS}.svc.cluster.local:5432/plane"
REDIS_URL="redis://plane-redis.${NS}.svc.cluster.local:6379/"
AMQP_URL="amqp://plane:${RABBITMQ_PASSWORD}@plane-rabbitmq.${NS}.svc.cluster.local:5672/"

install -m 600 /dev/null "${BACKUP_FILE}"
{
  echo "# Plane bootstrap secrets — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# MOVE these to a password manager and DELETE this file."
  echo "#"
  echo "# SECRET_KEY especially: it is not rotatable without corrupting"
  echo "# already-encrypted data, and it is not recoverable from the cluster."
  echo ""
  echo "POSTGRES_PASSWORD=${PG_PASSWORD}"
  echo "RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}"
  echo "SECRET_KEY=${SECRET_KEY}"
  echo "LIVE_SERVER_SECRET_KEY=${LIVE_SERVER_SECRET_KEY}"
  echo "GODMODE_USER=${GODMODE_USER}"
  echo "GODMODE_PASSWORD=${GODMODE_PASSWORD}"
} > "${BACKUP_FILE}"
echo "    Plaintexts written to ${BACKUP_FILE} (mode 600)."

# ---------- Read the shared Scaleway creds ----------
# Same namespace as baserow, so no reseal — read once, extract twice.
echo "==> Reading Scaleway creds from ${NS}/cnd-france-scw-secret"
SCW_DATA="$(kubectl --context "${CTX}" -n "${NS}" get secret cnd-france-scw-secret -o json)"
SCW_ACCESS_KEY_ID="$(echo "$SCW_DATA"     | jq -r '.data."access-key-id"     | @base64d')"
SCW_SECRET_ACCESS_KEY="$(echo "$SCW_DATA" | jq -r '.data."secret-access-key" | @base64d')"
SCW_REGION="$(echo "$SCW_DATA"            | jq -r '.data."region"            | @base64d')"

# Derived, not hardcoded: AWS_REGION on the doc-store secret comes from the same
# secret, so a hardcoded host could disagree with it and sign requests for one
# region against another's endpoint. communication/photos/.bootstrap.sh does the
# same.
S3_ENDPOINT="https://s3.${SCW_REGION}.scw.cloud"

# ---------- Seal helper ----------
# kubectl create --dry-run=client emits `creationTimestamp: null` and kubeseal
# passes it into spec.template.metadata, where the kubeconform Dagger module in
# CI rejects it (the CRD schema sets additionalProperties: false there). Shipped
# to main twice already: 27b235b, 6c61223.
#
# Stripped inside the pipeline rather than with `sed -i` over the finished file:
# plain filter sed has no GNU-vs-BSD `-i` divergence, leaves no .bak behind, and
# the file is never on disk in a shape CI would reject. Same helper as the three
# sibling bootstraps.
#
# Only the 6-space form is stripped. The top-level metadata.creationTimestamp is
# harmless — ticketing/alfio, callforpapers/pretalx and website-staging all carry
# it on main with green CI — so removing it too would make these files differ
# cosmetically from every existing SealedSecret for no reason.
seal() {
  kubeseal --format yaml --namespace "${NS}" \
    | sed '/^      creationTimestamp: null$/d' > "${DIR}/$1"
}

# ---------- Database credentials ----------
# CNPG expects kubernetes.io/basic-auth with username + password.
echo "==> Sealing plane-cnpg-secret"
kubectl --context "${CTX}" create secret generic plane-cnpg-secret \
  --namespace "${NS}" \
  --type kubernetes.io/basic-auth \
  --from-literal=username=plane \
  --from-literal=password="${PG_PASSWORD}" \
  --dry-run=client -o yaml \
| seal plane-cnpg-secret.yaml

# ---------- Application env ----------
# Feeding external_secrets.app_env_existingSecret is not stylistic: without it
# the chart builds DATABASE_URL and AMQP_URL from values.yaml, which would put
# both passwords in Git as plaintext.
echo "==> Sealing plane-app-secret"
kubectl --context "${CTX}" create secret generic plane-app-secret \
  --namespace "${NS}" \
  --from-literal=SECRET_KEY="${SECRET_KEY}" \
  --from-literal=LIVE_SERVER_SECRET_KEY="${LIVE_SERVER_SECRET_KEY}" \
  --from-literal=DATABASE_URL="${DATABASE_URL}" \
  --from-literal=REDIS_URL="${REDIS_URL}" \
  --from-literal=AMQP_URL="${AMQP_URL}" \
  --dry-run=client -o yaml \
| seal plane-app-secret.yaml

# ---------- Live server env ----------
# LIVE_SERVER_SECRET_KEY is the shared secret between api and live and MUST be
# byte-identical to the one in plane-app-secret above. A mismatch breaks
# collaborative editing with no useful error in either pod's logs.
echo "==> Sealing plane-live-secret"
kubectl --context "${CTX}" create secret generic plane-live-secret \
  --namespace "${NS}" \
  --from-literal=LIVE_SERVER_SECRET_KEY="${LIVE_SERVER_SECRET_KEY}" \
  --from-literal=REDIS_URL="${REDIS_URL}" \
  --dry-run=client -o yaml \
| seal plane-live-secret.yaml

# ---------- Doc store (Scaleway S3, not MinIO) ----------
# USE_MINIO=0 switches Plane to plain S3. FILE_SIZE_LIMIT is in bytes and must
# stay in step with the proxy-body-size annotation in ingress.yaml (20 MiB).
echo "==> Sealing plane-docstore-secret"
kubectl --context "${CTX}" create secret generic plane-docstore-secret \
  --namespace "${NS}" \
  --from-literal=USE_MINIO="0" \
  --from-literal=AWS_ACCESS_KEY_ID="${SCW_ACCESS_KEY_ID}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${SCW_SECRET_ACCESS_KEY}" \
  --from-literal=AWS_REGION="${SCW_REGION}" \
  --from-literal=AWS_S3_BUCKET_NAME="${BUCKET}" \
  --from-literal=AWS_S3_ENDPOINT_URL="${S3_ENDPOINT}" \
  --from-literal=FILE_SIZE_LIMIT="20971520" \
  --dry-run=client -o yaml \
| seal plane-docstore-secret.yaml

# ---------- RabbitMQ ----------
# The user/password here must match what AMQP_URL above was built from: this
# secret is what the RabbitMQ StatefulSet boots with.
echo "==> Sealing plane-rabbitmq-secret"
kubectl --context "${CTX}" create secret generic plane-rabbitmq-secret \
  --namespace "${NS}" \
  --from-literal=RABBITMQ_DEFAULT_USER="plane" \
  --from-literal=RABBITMQ_DEFAULT_PASS="${RABBITMQ_PASSWORD}" \
  --dry-run=client -o yaml \
| seal plane-rabbitmq-secret.yaml

# ---------- /god-mode basic auth ----------
# The chart exposes the instance admin panel on the app host with no auth gate.
# ingress-godmode.yaml puts nginx basic-auth in front of it, reading this.
echo "==> Sealing plane-godmode-auth"
kubectl --context "${CTX}" create secret generic plane-godmode-auth \
  --namespace "${NS}" \
  --from-literal=auth="${GODMODE_AUTH_LINE}" \
  --dry-run=client -o yaml \
| seal plane-godmode-auth-secret.yaml

SEALED_FILES=(
  plane-cnpg-secret.yaml
  plane-app-secret.yaml
  plane-live-secret.yaml
  plane-docstore-secret.yaml
  plane-rabbitmq-secret.yaml
  plane-godmode-auth-secret.yaml
)

# ---------- Validate ----------
# Non-empty is too weak: a stderr dump or a truncated write also satisfies it.
echo "==> Verifying the sealed files"
for f in "${SEALED_FILES[@]}"; do
  grep -q '^kind: SealedSecret$' "${DIR}/${f}" \
    || { echo "ERROR: ${DIR}/${f} is not a SealedSecret" >&2; exit 1; }
done
echo "    OK: ${#SEALED_FILES[@]} SealedSecrets written"

# The kustomization lists all six by name, so this catches a missing or
# misnamed file that the per-file check above cannot see.
echo "==> Rendering project/plane to confirm the kustomization is complete"
kustomize build "${DIR}" > /dev/null
echo "    OK: kustomize build succeeded"

echo ""
echo "==> Plaintext backup at ${BACKUP_FILE} — MOVE to your password manager + DELETE."
echo "==> /god-mode login: ${GODMODE_USER} / (see backup file)"
