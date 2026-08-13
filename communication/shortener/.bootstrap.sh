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
