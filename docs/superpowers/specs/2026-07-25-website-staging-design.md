# Website staging environment — design

Date: 2026-07-25
Component: `website-staging` (namespace `cnd-website-staging`, cluster `k8s-cndfrance-prod`)
Companion repo: `cloudnativefrance/website` (CI, Astro config, robots)
Scope: staging environment only. The UI changes it exists to validate are specced separately.

## Goal

Serve a distinct build of the conference website at **`staging.cloudnativedays.fr`**, fed
continuously from a dedicated `staging` branch, so batches of UI work can be reviewed in a
real deployment before they reach `main` / production.

## Findings that shaped this design

- **The CI deliberately excludes non-default branches.** `build-image.yml:63` gates the
  sortable tag on `{{is_default_branch}}`, with the comment "gating on is_default_branch
  keeps feature-branch dispatches from polluting the channel". A branch push therefore
  publishes only a bare `<sha>` tag, and `flux/image-automation/website.yaml` states that
  "Flux ImagePolicy cannot order bare git SHAs". A second, prefixed tag channel is required —
  not a relaxation of the existing gate.
- **`site` is hardcoded** in `astro.config.mjs:12` (`https://cloudnativedays.fr`). It feeds
  canonical URLs, `hreflang` alternates, OG image URLs and the `@astrojs/sitemap` output.
  Left as-is, every one of those would point at production from a staging build.
- **`public/robots.txt` ships `Allow: /`** plus a hardcoded production sitemap URL. A
  crawlable staging host would create duplicate content and put a staging domain in Google.
- **The ingress controller is ingress-nginx.** Confirmed by `nginx.ingress.kubernetes.io/*`
  annotations in `callforpapers/pretalx/ingress.yaml:6`, `ticketing/alfio/ingress.yaml:9`
  and `communication/photos/museum.yaml:150`, and stated in
  `docs/superpowers/specs/2026-05-15-self-hosted-ente-photos-design.md:90`. The basic-auth
  annotations are therefore available.
- **Secrets are Bitnami SealedSecrets** — 21 already tracked in this repo. The htpasswd
  secret follows the same pattern; no new tooling.
- **The existing `ImageRepository cnd-website` is reusable.** Staging pulls from the same
  GHCR repository, so only a new `ImagePolicy` is needed. The `ImageUpdateAutomation`,
  however, must be separate: the existing one targets `path: ./website` and would rewrite
  the production manifest if reused.
- **No external-dns in the cluster.** DNS records are created manually today; staging
  follows the same operating model.

## Deployment flow

```
cndfrance-website : push to `staging`
   │  .github/workflows/build-image.yml
   │  build-arg PUBLIC_SITE_URL=https://staging.cloudnativedays.fr
   ▼
ghcr.io/cloudnativefrance/website:staging-<sha>-<unix-ts>
   │
   ▼  Flux ImagePolicy  cnd-website-staging   ^staging-[a-f0-9]+-(?P<ts>[0-9]+)$
   │
   ▼  ImageUpdateAutomation cnd-website-staging → commit to cnd-platform/website-staging/
   │
   ▼  Flux Kustomization cnd-website-staging → ./website-staging (ns cnd-website-staging)
   Deployment(1) · Service · Ingress(basic auth + letsencrypt)
   ▼
https://staging.cloudnativedays.fr
```

Production is untouched: the `main-…` tag channel, the `latest` tag, the `cnd-website`
ImagePolicy and the `./website` path all keep their current behaviour.

## Changes in `cndfrance-website`

### 1. Open the `staging` image channel

`.github/workflows/build-image.yml`:

```diff
 on:
   push:
-    branches: [main]
+    branches: [main, staging]
```

```diff
       tags: |
         type=sha,prefix=
-        type=raw,value={{branch}}-{{sha}}-{{date 'X'}},enable={{is_default_branch}}
+        type=raw,value={{branch}}-{{sha}}-{{date 'X'}},enable=${{ github.ref_name == 'main' || github.ref_name == 'staging' }}
         type=raw,value=latest,enable={{is_default_branch}}
         type=semver,pattern={{version}}
```

One rule now produces both channels (`main-…` and `staging-…`); the two Flux ImagePolicies
discriminate by prefix. `latest` stays gated on the default branch, so the production
channel is still not polluted — the original intent of the gate is preserved.

Pass the site origin as a build arg on the same step:

```diff
       - name: Build and push
         with:
           context: .
+          build-args: |
+            PUBLIC_SITE_URL=${{ github.ref_name == 'staging' && 'https://staging.cloudnativedays.fr' || 'https://cloudnativedays.fr' }}
```

### 2. Make `site` configurable

`astro.config.mjs`:

```diff
-  site: "https://cloudnativedays.fr",
+  site: process.env.PUBLIC_SITE_URL ?? "https://cloudnativedays.fr",
```

`Dockerfile`, in the build stage before `pnpm run build`:

```diff
 FROM node:22-alpine AS build
 WORKDIR /app
+ARG PUBLIC_SITE_URL=https://cloudnativedays.fr
+ENV PUBLIC_SITE_URL=$PUBLIC_SITE_URL
```

The default keeps every existing build path (local `pnpm build`, `main`, `workflow_dispatch`)
producing exactly what it produces today. This fixes canonical, `hreflang`, OG and sitemap in
one change.

### 3. Generate `robots.txt` instead of shipping it

Delete `public/robots.txt` (a static file in `public/` would otherwise shadow the route) and
add `src/pages/robots.txt.ts`:

```ts
import type { APIRoute } from "astro";

const PROD_ORIGIN = "https://cloudnativedays.fr";

export const GET: APIRoute = ({ site }) => {
  const origin = site?.origin ?? PROD_ORIGIN;
  const body =
    origin === PROD_ORIGIN
      ? `User-agent: *\nAllow: /\nSitemap: ${origin}/sitemap-index.xml\n`
      : `User-agent: *\nDisallow: /\n`;
  return new Response(body, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
};
```

This also removes the hardcoded sitemap URL, which was a latent duplicate of `site`.

Add a matching guard in `src/layouts/Layout.astro`, next to the existing canonical/OG block:

```astro
{Astro.site?.origin !== "https://cloudnativedays.fr" && (
  <meta name="robots" content="noindex, nofollow" />
)}
```

Basic auth already returns 401 to crawlers, so this is defence in depth — it keeps staging
unindexable if the auth is ever removed.

## Changes in `cnd-platform`

```
website-staging/
├── kustomization.yaml         namespace: cnd-website-staging
├── deployment.yaml            1 replica; # {"$imagepolicy": "flux-system:cnd-website-staging"}
├── service.yaml
├── ingress.yaml               staging.cloudnativedays.fr · basic auth · letsencrypt
└── auth-sealedsecret.yaml     SealedSecret website-staging-auth (key: auth)
clusters/k8s-cndfrance-prod/website-staging.yaml   Flux Kustomization, path ./website-staging
flux/image-automation/website-staging.yaml         ImagePolicy + ImageUpdateAutomation
namespaces/namespaces.yaml                         + cnd-website-staging
```

`ingress.yaml` above shows the target state. It ships in two commits: the
Kustomization/Deployment/Service/Ingress land first without the `auth-*`
annotations, and a follow-up commit adds them once the basic-auth secret is
sealed — see Operator prerequisites below.

`website-staging/` is a near-copy of `website/`, differing only in namespace, replica count
(1 instead of 2), host, and the imagepolicy marker. Resource requests/limits, probes and
securityContext are carried over unchanged so staging exercises the same runtime shape as
production.

The Deployment and Service keep the name **`website`** — the namespace is what separates them
from production, matching how every other component in this repo is scoped. Only the
cluster-scoped and `flux-system` objects are suffixed (`cnd-website-staging`), because those
share a namespace with their production counterparts.

### Flux Kustomization

`clusters/k8s-cndfrance-prod/website-staging.yaml`, mirroring `website.yaml`:

```yaml
kind: Kustomization
metadata:
  name: cnd-website-staging
  namespace: flux-system
spec:
  prune: true
  interval: 2m0s
  path: ./website-staging
  sourceRef:
    kind: GitRepository
    name: customer
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: website
      namespace: cnd-website-staging
```

### Ingress

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: website-staging-auth
    nginx.ingress.kubernetes.io/auth-realm: "CND France — staging"
spec:
  ingressClassName: public
  rules:
    - host: staging.cloudnativedays.fr
```

### Image automation

```yaml
kind: ImagePolicy
metadata:
  name: cnd-website-staging
spec:
  imageRepositoryRef:
    name: cnd-website          # reuse — same GHCR repository
  filterTags:
    pattern: '^staging-[a-f0-9]+-(?P<ts>[0-9]+)$'
    extract: '$ts'
  policy:
    numerical: { order: asc }
---
kind: ImageUpdateAutomation
metadata:
  name: cnd-website-staging
spec:
  update:
    path: ./website-staging     # MUST differ from ./website
```

## Operator prerequisites

Two steps require cluster or DNS access and are performed by the operator, in
this order:

1. **Seal the basic-auth secret and land the auth annotations**, after the
   namespace exists:

   ```sh
   htpasswd -nbB cnd '<password>' > /tmp/auth
   kubectl create secret generic website-staging-auth \
     --from-file=auth=/tmp/auth \
     -n cnd-website-staging --dry-run=client -o yaml \
   | kubeseal --format yaml > website-staging/auth-sealedsecret.yaml
   rm /tmp/auth
   ```

   ingress-nginx requires the secret key to be named `auth`. `kubeseal` binds
   a SealedSecret to a namespace/name string, not to any live cluster object,
   so this — and the PR that adds the `auth-*` annotations to the Ingress —
   can happen before DNS exists. That closes what would otherwise be a
   publicly-reachable, unauthenticated window between the DNS record going
   live and the auth gate landing.
2. **DNS** — `staging.cloudnativedays.fr` → the ingress IP (same target as
   `cloudnativedays.fr`), created only after the auth gate above has
   reconciled. cert-manager's HTTP-01 solver still issues the certificate
   normally: it uses a separate, more-specific Ingress for
   `/.well-known/acme-challenge/` that does not inherit the `auth-*`
   annotations.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Basic auth blocks the ACME HTTP-01 challenge | cert-manager creates a *separate* solver Ingress for `/.well-known/acme-challenge/`, which does not inherit our annotations. If the certificate nevertheless fails to issue, deploy the Ingress without the auth annotations, wait for `website-staging-tls` to be `Ready`, then add them back. |
| Two `ImageUpdateAutomation`s pushing to `cnd-platform` `main` race | They target disjoint paths and Flux retries on push rejection. Confirm both reconcile after the first staging build. |
| `staging` branch drifts far from `main` | Staging is a merge target, not a long-lived fork: rebase or merge `main` into `staging` before each validation batch. |
| Bare `<sha>` tags now pushed for staging builds too | Harmless — no ImagePolicy matches that pattern. It also makes a manual pin possible if automation needs to be bypassed. |
| GHCR image count grows faster | Acceptable at this cadence; revisit with a retention policy if it becomes a cost or clutter issue. |

## Non-goals

- **external-dns.** Rejected: it would add an operator with DNS-provider credentials and
  RBAC for a single record. DNS stays manual, as it already is for every other host.
- **A separate cluster or namespace-per-PR.** One long-lived staging namespace covers the
  stated need (validate a batch before merging).
- **Promotion tooling.** Promotion is `git merge staging → main`; production automation
  already handles the rest.

## Decisions log

| Decision | Rationale |
|---|---|
| Dedicated `staging` branch, continuous | Batches accumulate on one branch and deploy without a manual trigger; `git merge` is the promotion gesture. Rejected alternatives: `workflow_dispatch` per branch (manual every iteration), pinned tag in the manifest (a `cnd-platform` commit per iteration). |
| Basic auth in addition to noindex | Staging may show unannounced content (schedule, speakers, pricing). 401 also makes indexing impossible, so the two protections reinforce each other. |
| DNS created manually | No external-dns in the cluster; matches how every existing host is provisioned. |
| Reuse `ImageRepository`, duplicate `ImageUpdateAutomation` | Same GHCR repo means one scan; separate write paths keep staging from touching `./website`. |
| `PUBLIC_SITE_URL` with a production default | Every existing build path keeps its current output with no CI change beyond the staging branch. |
