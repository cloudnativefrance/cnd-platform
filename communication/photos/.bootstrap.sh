#!/usr/bin/env bash
# Bootstrap script for the self-hosted Ente photo platform.
# Run from the repo root: ./communication/photos/.bootstrap.sh
#
# Generates random secrets, reseals existing creds for the new namespace,
# writes the 4 SealedSecret YAML files into photos/, and stashes the
# generated plaintexts to a backup file you must move to your password
# manager and then delete.
#
# Manual prereqs (do these BEFORE running this script):
#   1. Create Scaleway bucket cnd-ente-photos in fr-par.
#   2. (Nothing — communication@cloudnativedays.fr alias is reused for OTP.)
#   3. Add 4 DNS A records pointing at the cluster ingress:
#        api.photos.cloudnativedays.fr
#        photos.cloudnativedays.fr
#        albums.cloudnativedays.fr
#        accounts.cloudnativedays.fr
#   4. Confirm `kubectl --context k8s-cndfrance-prod` works and `kubeseal`
#      can find the controller (`kubeseal --version` works, controller pod
#      exists in the cluster — namespace usually kube-system).

set -euo pipefail

CTX="k8s-cndfrance-prod"
NS="cnd-photos"
SOURCE_NS="cnd-project"   # where the existing Scaleway + Brevo secrets live

PHOTOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_FILE="$HOME/.ente-photos-bootstrap-secrets.txt"

echo "==> Bootstrapping Ente SealedSecrets in namespace ${NS}"
echo "    Working dir: ${PHOTOS_DIR}"
echo "    Plaintext backup: ${BACKUP_FILE}"

# Sanity checks
command -v openssl >/dev/null || { echo "openssl not found"; exit 1; }
command -v kubeseal >/dev/null || { echo "kubeseal not found"; exit 1; }
command -v kubectl  >/dev/null || { echo "kubectl  not found"; exit 1; }

# ---------- Generate plaintexts ----------
echo "==> Generating random secrets"
PG_PASSWORD="$(openssl rand -base64 24 | tr -d '\n=' | tr '/+' '_-')"
KEY_ENCRYPTION="$(openssl rand -base64 32)"
KEY_HASH="$(openssl rand -base64 64 | tr -d '\n')"
JWT_SECRET="$(openssl rand -base64 32)"

# ---------- Snapshot the plaintexts to a backup file the user MUST move ----------
{
  echo "# Ente photos bootstrap secrets — generated $(date -Iseconds)"
  echo "# MOVE these to a password manager and DELETE this file."
  echo ""
  echo "POSTGRES_PASSWORD=${PG_PASSWORD}"
  echo "KEY_ENCRYPTION=${KEY_ENCRYPTION}"
  echo "KEY_HASH=${KEY_HASH}"
  echo "JWT_SECRET=${JWT_SECRET}"
} > "${BACKUP_FILE}"
chmod 600 "${BACKUP_FILE}"
echo "    Plaintexts written to ${BACKUP_FILE} (mode 600)."

# ---------- Read existing Scaleway + Brevo creds from cnd-project ns ----------
echo "==> Reading Scaleway + Brevo plaintexts from namespace ${SOURCE_NS}"
SCW_DATA=$(kubectl --context "${CTX}" -n "${SOURCE_NS}" get secret cnd-france-scw-secret -o json)
SCW_ACCESS_KEY_ID=$(echo "$SCW_DATA"     | jq -r '.data."access-key-id"     | @base64d')
SCW_SECRET_ACCESS_KEY=$(echo "$SCW_DATA" | jq -r '.data."secret-access-key" | @base64d')
SCW_REGION=$(echo "$SCW_DATA"            | jq -r '.data."region"            | @base64d')

BREVO_DATA=$(kubectl --context "${CTX}" -n "${SOURCE_NS}" get secret brevo-smtp -o json)
BREVO_PASSWORD=$(echo "$BREVO_DATA" | jq -r '.data."password" | @base64d')

# ---------- Task C3: ente-cnpg-secret ----------
echo "==> Sealing ente-cnpg-secret (Postgres credentials)"
kubectl --context "${CTX}" create secret generic ente-cnpg-secret \
  --namespace "${NS}" \
  --type kubernetes.io/basic-auth \
  --from-literal=username=ente \
  --from-literal=password="${PG_PASSWORD}" \
  --dry-run=client -o yaml \
| kubeseal --format yaml --namespace "${NS}" > "${PHOTOS_DIR}/cnpg-secret.yaml"

# ---------- Task C4: cnd-france-scw-secret + brevo-smtp ----------
echo "==> Resealing cnd-france-scw-secret for ${NS}"
kubectl --context "${CTX}" create secret generic cnd-france-scw-secret \
  --namespace "${NS}" \
  --from-literal=access-key-id="${SCW_ACCESS_KEY_ID}" \
  --from-literal=secret-access-key="${SCW_SECRET_ACCESS_KEY}" \
  --from-literal=region="${SCW_REGION}" \
  --dry-run=client -o yaml \
| kubeseal --format yaml --namespace "${NS}" > "${PHOTOS_DIR}/cnd-france-scw-secret.yaml"

echo "==> Resealing brevo-smtp for ${NS}"
kubectl --context "${CTX}" create secret generic brevo-smtp \
  --namespace "${NS}" \
  --from-literal=password="${BREVO_PASSWORD}" \
  --dry-run=client -o yaml \
| kubeseal --format yaml --namespace "${NS}" > "${PHOTOS_DIR}/brevo-smtp-secret.yaml"

# ---------- Task C5: museum-secret ----------
echo "==> Sealing museum-secret (encryption + hash + JWT)"
kubectl --context "${CTX}" create secret generic museum-secret \
  --namespace "${NS}" \
  --from-literal=key-encryption="${KEY_ENCRYPTION}" \
  --from-literal=key-hash="${KEY_HASH}" \
  --from-literal=jwt-secret="${JWT_SECRET}" \
  --dry-run=client -o yaml \
| kubeseal --format yaml --namespace "${NS}" > "${PHOTOS_DIR}/museum-secret.yaml"

# ---------- Validate ----------
echo "==> Verifying"
ls -la "${PHOTOS_DIR}"/*-secret*.yaml "${PHOTOS_DIR}"/cnpg-secret.yaml "${PHOTOS_DIR}"/cnd-france-scw-secret.yaml "${PHOTOS_DIR}"/brevo-smtp-secret.yaml 2>/dev/null
echo ""
echo "==> kustomize build photos/ should now succeed:"
( cd "$(dirname "${PHOTOS_DIR}")" && kustomize build photos/ | grep -c "^kind: SealedSecret" ) || true

echo ""
echo "==> Plaintext backup at ${BACKUP_FILE} — MOVE to your password manager + DELETE the file."
echo "==> Add and commit the 4 SealedSecret files:"
echo "       git add photos/cnpg-secret.yaml \\"
echo "               photos/cnd-france-scw-secret.yaml \\"
echo "               photos/brevo-smtp-secret.yaml \\"
echo "               photos/museum-secret.yaml"
echo "       git commit -m 'feat(photos): seal cluster + S3 + SMTP + museum secrets'"
