#!/usr/bin/env bash
# Bootstrap script for self-hosted website analytics (Umami).
# Run from the repo root: ./analytics/.bootstrap.sh
#
# Generates the DB password and APP_SECRET, reseals the Scaleway backup creds
# into the new namespace, and writes 3 SealedSecret YAML files into analytics/.
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
#   1. `kubectl config use-context k8s-cndfrance-prod`. kubeseal fetches the
#      sealing certificate from the CURRENT context regardless of what
#      --context is passed to kubectl, so sealing on the wrong context yields
#      files that pass kustomize, kubeconform and CI, and fail only after
#      reconcile with "no key could decrypt secret".
#   2. Do NOT create the stats.cloudnativedays.fr DNS record yet — it is
#      created in Task 4 Step 7, after the seeded admin password is changed.

set -euo pipefail
trap 'echo "ERROR: bootstrap failed at line $LINENO" >&2' ERR

CTX="k8s-cndfrance-prod"
NS="cnd-analytics"
SOURCE_NS="cnd-project"   # where the existing Scaleway secret lives

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_FILE="$HOME/.umami-bootstrap-secrets.txt"

echo "==> Bootstrapping Umami SealedSecrets in namespace ${NS}"

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
# hex, not base64: the DB password is interpolated into DATABASE_URL, where a
# '/' or '+' corrupts the URL and surfaces as a confusing auth failure rather
# than a parse error. Hex is URL-safe by construction, so there is no hazard to
# check for afterwards. 32 bytes = 128 bits.
echo "==> Generating secrets"
PG_PASSWORD="$(openssl rand -hex 32)"
APP_SECRET="$(openssl rand -base64 32 | tr -d '\n')"   # never URL-interpolated

install -m 600 /dev/null "${BACKUP_FILE}"
{
  echo "# Umami bootstrap secrets — generated $(date -Iseconds)"
  echo "# MOVE these to a password manager and DELETE this file."
  echo ""
  echo "POSTGRES_PASSWORD=${PG_PASSWORD}"
  echo "APP_SECRET=${APP_SECRET}"
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
for f in cnd-france-scw-secret.yaml umami-cnpg-secret.yaml umami-secret.yaml; do
  sed -i '/^      creationTimestamp: null$/d' "${DIR}/${f}"
done

# ---------- Validate ----------
# Non-empty is too weak: a stderr dump or a truncated write also satisfies it.
# The render catches valid YAML of the wrong kind and files the kustomization
# does not list. It can only run once every resource exists, so it is deferred
# to Task 3 Step 4 — here we assert the files at least parse as SealedSecrets.
echo "==> Verifying the three sealed files"
for f in cnd-france-scw-secret.yaml umami-cnpg-secret.yaml umami-secret.yaml; do
  grep -q '^kind: SealedSecret$' "${DIR}/${f}" \
    || { echo "ERROR: ${DIR}/${f} is not a SealedSecret" >&2; exit 1; }
done
echo "    OK: 3 SealedSecrets written"

echo ""
echo "==> Plaintext backup at ${BACKUP_FILE} — MOVE to your password manager + DELETE."
