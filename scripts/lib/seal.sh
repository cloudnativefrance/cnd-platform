#!/usr/bin/env bash
# Shared helpers for component .bootstrap.sh scripts.
#
# Source it, don't execute it:
#   source "$(git rev-parse --show-toplevel)/scripts/lib/seal.sh"
#
# Why this exists: the seal-and-strip sequence was on its way to a third
# verbatim copy (communication/photos/.bootstrap.sh, plus one per new
# component). The duplicated part is not boilerplate — it is the Scaleway
# reseal keyed on exact secret key names, the CNPG basic-auth shape, and the
# `creationTimestamp: null` workaround for the kubeconform CI, which has
# already been fixed twice in this repo (27b235b, 6c61223). Three copies means
# the next kubeseal quirk has to be found and fixed three times.
#
# communication/photos/.bootstrap.sh predates this and still carries its own
# copies; back-porting it is a follow-up, deliberately not bundled with the
# component that motivated the extraction.

set -euo pipefail

SEAL_CTX="${SEAL_CTX:-k8s-cndfrance-prod}"

# require_bins <bin>...
# Fail fast on a missing tool rather than halfway through sealing.
require_bins() {
  local bin
  for bin in "$@"; do
    command -v "$bin" >/dev/null || { echo "ERROR: $bin not found on PATH" >&2; exit 1; }
  done
}

# require_context
# kubeseal does NOT accept kubectl's --context implicitly: it reads the
# CURRENT context to find the sealing certificate. Sealing against the wrong
# cluster yields files that pass kustomize, kubeconform and CI, and fail only
# after reconcile with "no key could decrypt secret" — by which point the
# plaintexts are usually deleted. So refuse to run on the wrong context.
require_context() {
  local current
  current="$(kubectl config current-context)"
  if [[ "${current}" != "${SEAL_CTX}" ]]; then
    echo "ERROR: current kubectl context is '${current}', expected '${SEAL_CTX}'." >&2
    echo "       kubeseal would seal against the wrong cluster. Run:" >&2
    echo "         kubectl config use-context ${SEAL_CTX}" >&2
    exit 1
  fi
}

# secure_file <path>
# Create (or truncate) a file that will hold plaintext, 0600 from the outset.
# A plain `> "$f"` creates it with the ambient umask — 0644 on most distros —
# and a later chmod leaves a window where any local user can read it.
secure_file() {
  local path="$1"
  install -m 600 /dev/null "${path}"
}

# strip_creation_timestamp <file>...
# kubectl create --dry-run=client emits `creationTimestamp: null` and kubeseal
# passes it into spec.template.metadata, where this repo's kubeconform CI
# rejects it (the CRD schema sets additionalProperties: false there).
#
# Strips ONLY the nested occurrence. The top-level metadata.creationTimestamp
# is harmless — ticketing/alfio, callforpapers/pretalx and
# website-staging/auth-sealedsecret.yaml all carry it on main with green CI —
# so removing it too would make new files differ cosmetically from every
# existing SealedSecret for no reason.
#
# This is now a convenience, not the sole defense: scripts/validate-manifests.sh
# asserts the same thing across the whole repo, so a file sealed by hand or by
# an older script is caught too. sed exits 0 when it matches nothing, which is
# why the gate has to exist independently.
strip_creation_timestamp() {
  local f
  for f in "$@"; do
    sed -i '/^      creationTimestamp: null$/d' "${f}"
  done
}

# seal_literals <namespace> <secret-name> <outfile> <key=value>...
seal_literals() {
  local ns="$1" name="$2" out="$3"; shift 3
  local args=()
  local kv
  for kv in "$@"; do args+=(--from-literal="${kv}"); done

  kubectl --context "${SEAL_CTX}" create secret generic "${name}" \
    --namespace "${ns}" "${args[@]}" \
    --dry-run=client -o yaml \
  | kubeseal --format yaml --namespace "${ns}" > "${out}"
  strip_creation_timestamp "${out}"
}

# seal_basic_auth <namespace> <secret-name> <outfile> <username> <password>
# CNPG expects kubernetes.io/basic-auth with username + password.
seal_basic_auth() {
  local ns="$1" name="$2" out="$3" user="$4" pass="$5"

  kubectl --context "${SEAL_CTX}" create secret generic "${name}" \
    --namespace "${ns}" \
    --type kubernetes.io/basic-auth \
    --from-literal=username="${user}" \
    --from-literal=password="${pass}" \
    --dry-run=client -o yaml \
  | kubeseal --format yaml --namespace "${ns}" > "${out}"
  strip_creation_timestamp "${out}"
}

# reseal_scw_secret <target-namespace> <outfile> [source-namespace]
# Copy the Scaleway object-storage credentials into a new namespace. Read once
# into one variable and extracted three times — not three kubectl calls.
reseal_scw_secret() {
  local ns="$1" out="$2" src="${3:-cnd-project}"
  local data id key region

  data="$(kubectl --context "${SEAL_CTX}" -n "${src}" get secret cnd-france-scw-secret -o json)"
  id="$(echo "${data}"     | jq -r '.data."access-key-id"     | @base64d')"
  key="$(echo "${data}"    | jq -r '.data."secret-access-key" | @base64d')"
  region="$(echo "${data}" | jq -r '.data."region"            | @base64d')"

  seal_literals "${ns}" cnd-france-scw-secret "${out}" \
    "access-key-id=${id}" "secret-access-key=${key}" "region=${region}"
}

# url_safe_password [bytes]
# Passwords generated here get interpolated into DATABASE_URL-style connection
# strings, where '/', '+' or '=' corrupt the URL and surface as a confusing
# auth failure rather than a parse error.
#
# hex, not base64: URL-safe *by construction*. The older idiom in
# communication/photos/.bootstrap.sh is `openssl rand -base64 24 | tr -d '\n=' |
# tr '/+' '_-'`, which generates the hazard and then patches it — and that
# patching is what all the surrounding documentation about URL-safety exists to
# manage. 32 bytes of hex is 128 bits of entropy in [0-9a-f].
url_safe_password() {
  openssl rand -hex "${1:-32}"
}

# assert_sealed_count <kustomize-dir> <expected>
# Render the kustomization and count SealedSecrets. Stronger than testing that
# files are non-empty: it also catches valid YAML of the wrong kind, a
# truncated write, or a file the kustomization does not list.
assert_sealed_count() {
  local dir="$1" expected="$2" actual
  actual="$(kustomize build "${dir}" | grep -c '^kind: SealedSecret' || true)"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "ERROR: ${dir} rendered ${actual} SealedSecrets, expected ${expected}" >&2
    exit 1
  fi
  echo "    OK: ${expected} SealedSecrets render cleanly"
}
