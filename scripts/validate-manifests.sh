#!/usr/bin/env bash
# Single entry point for Kubernetes manifest validation.
#
# Runs the same steps locally and in CI, so "it validates" is a claim backed by
# a command anyone — human or agent — can reproduce:
#   1. render every kustomization into a bundle
#   2. gate the bundle with polaris (workload best practices)
#
# Schema validation is NOT here: it is already covered in CI by the kubeconform
# Dagger module, which resolves CRD schemas from the catalog and therefore
# validates the Flux and SealedSecret objects a bare kubeconform would skip.
#
# HelmReleases are deliberately not rendered. Every chart in this repo is
# third-party (bitnami valkey, ess-helm, baserow), so polaris findings against
# them are noise we cannot act on from values. Adding helm rendering later is
# additive: render into the same BUNDLE_DIR before the audit step.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

for bin in kustomize polaris; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: $bin not found on PATH." >&2
    exit 1
  fi
done

BUNDLE_DIR="${BUNDLE_DIR:-.bundle}"

echo "==> [1/3] Rendering kustomizations into ${BUNDLE_DIR}/"
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}"

rendered=0
# Only top-level kustomizations: anything under a chart's own templates/ is
# rendered by helm at apply time, not by us.
while IFS= read -r kfile; do
  dir="$(dirname "$kfile")"
  name="${dir#./}"
  name="${name//\//-}"
  if kustomize build "$dir" > "${BUNDLE_DIR}/${name}.yaml" 2>/dev/null; then
    rendered=$((rendered + 1))
  else
    echo "error: kustomize build failed for ${dir}" >&2
    exit 1
  fi
done < <(find . -name kustomization.yaml -not -path "*/templates/*" -not -path "./.bundle/*" | sort)

echo "    rendered ${rendered} kustomization(s)"

echo "==> [2/3] polaris audit (workload best practices)"
polaris audit \
  --audit-path "${BUNDLE_DIR}" \
  --config .polaris.yaml \
  --set-exit-code-on-danger \
  --only-show-failed-tests

echo "==> [3/3] SealedSecret template hygiene"
# `creationTimestamp: null` inside spec.template.metadata is rejected by the
# kubeconform Dagger module in CI (the SealedSecret CRD schema sets
# additionalProperties: false there). kubectl create --dry-run=client emits it
# and kubeseal passes it straight through, so every bootstrap script strips it
# afterwards with sed — and sed exits 0 when it matches nothing.
#
# This repo has already shipped that failure to main twice (27b235b, 6c61223).
# Both times it was caught by CI after a push, because the local gate had no
# opinion about it. Asserting it here makes the local gate agree with CI.
#
# Only the nested occurrence matters: several SealedSecrets on main carry the
# top-level `metadata.creationTimestamp: null` (ticketing/alfio, callforpapers/
# pretalx, website-staging) and CI is green on them, so this must not match at
# the 2-space depth.
if grep -rn '^      creationTimestamp: null$' --include='*.yaml' \
     --exclude-dir=.bundle --exclude-dir=.git . ; then
  echo "" >&2
  echo "error: 'creationTimestamp: null' found inside a SealedSecret template." >&2
  echo "       kubeconform rejects it in CI. Remove the lines listed above." >&2
  exit 1
fi
echo "    OK: no templated creationTimestamp"

echo "==> All gates passed"
