# Website Staging Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve a distinct build of the conference website at `https://staging.cloudnativedays.fr`, fed continuously from a dedicated `staging` branch, gated behind basic auth and excluded from search indexes.

**Architecture:** Two repositories. `cndfrance-website` gains a second image-tag channel (`staging-<sha>-<ts>`), an origin driven by `PUBLIC_SITE_URL` instead of a hardcoded constant, and a generated `robots.txt`. `cnd-platform` gains a `website-staging/` kustomization with its own Flux `ImagePolicy` and `ImageUpdateAutomation` writing to a separate path, plus an ingress-nginx basic-auth gate added *after* the TLS certificate has issued.

**Tech Stack:** Astro 5 (fully static, no adapter), Vitest 4, GitHub Actions + `docker/metadata-action@v5`, Flux CD v2.8 image automation, Kustomize, ingress-nginx, cert-manager, Bitnami SealedSecrets.

**Spec:** `docs/superpowers/specs/2026-07-25-website-staging-design.md`

## Global Constraints

- Production origin is exactly `https://cloudnativedays.fr`. It is both the default value and the production/non-production discriminator. Copy it verbatim; never write it twice in two places.
- Staging origin is exactly `https://staging.cloudnativedays.fr`.
- Production image tag pattern: `^main-[a-f0-9]+-(?P<ts>[0-9]+)$` — unchanged.
- Staging image tag pattern: `^staging-[a-f0-9]+-(?P<ts>[0-9]+)$`.
- The `latest` tag stays gated on `{{is_default_branch}}`. Never publish it from `staging`.
- The staging `ImageUpdateAutomation` MUST use `path: ./website-staging`. The existing one uses `./website`; reusing it would rewrite the production manifest.
- ingress-nginx requires the basic-auth secret data key to be named exactly `auth`.
- In the staging namespace the Deployment and Service keep the name `website`. Only objects living in `flux-system` are suffixed `cnd-website-staging`.
- Never commit an unsealed `Secret`. This repo uses Bitnami `SealedSecret` (21 already tracked).
- Repository metadata — commit messages, PR titles and PR descriptions — is written in English, per the user's global convention.
- Never commit to a default branch directly. Every task works on a feature branch.

## Repositories and branches

| Tasks | Repo | Path | Branch |
|---|---|---|---|
| 1–4 | `cndfrance-website` | `/home/smana/Sources/cndfrance-website` | `feat/staging-support` |
| 5 | `cndfrance-website` | — | merge to `main`, then cut `staging` |
| 6–7 | `cnd-platform` | `/home/smana/Sources/cnd-platform` | `feat/website-staging` |
| 8 | operator | — | cluster + DNS, no code |

Tasks 1–4 are behaviour-preserving for production: `PUBLIC_SITE_URL` defaults to the production origin and the generated `robots.txt` is byte-identical to the file it replaces. They can therefore land on `main` before staging exists.

## File Structure

**`cndfrance-website`**

| File | Responsibility |
|---|---|
| `astro.config.mjs` (modify, line 12) | Reads the build origin from the environment |
| `Dockerfile` (modify, build stage) | Threads `PUBLIC_SITE_URL` from build arg to build env |
| `src/lib/site-env.ts` (create) | **Single owner** of "which environment is this build for" — the production origin constant, the predicate, and the `robots.txt` body |
| `src/pages/robots.txt.ts` (create) | Thin Astro route; delegates to `site-env.ts` |
| `public/robots.txt` (delete) | Superseded — a static file here would shadow the route |
| `src/layouts/Layout.astro` (modify) | Emits `noindex` on non-production builds |
| `src/lib/__tests__/site-env.test.ts` (create) | Unit tests for the pure functions |
| `tests/build/astro-config-site.test.ts` (create) | Guards the config's env plumbing |
| `tests/build/noindex-guard.test.ts` (create) | Guards that `Layout.astro` keeps the conditional |
| `.github/workflows/build-image.yml` (modify) | Publishes the `staging-…` tag channel |

Tests live in two places by existing convention: pure-module unit tests under `src/lib/__tests__/`, source-shape guards under `tests/build/`. Follow it.

`src/lib/site-env.ts` exists so the production origin is defined once. Both consumers — the robots route and the layout's meta tag — derive from it, rather than each carrying its own copy of the string or a second `IS_STAGING` flag that could drift.

**`cnd-platform`**

| File | Responsibility |
|---|---|
| `namespaces/namespaces.yaml` (modify) | Adds the `cnd-website-staging` namespace |
| `website-staging/kustomization.yaml` (create) | Kustomize entry point |
| `website-staging/deployment.yaml` (create) | 1 replica, carries the imagepolicy marker |
| `website-staging/service.yaml` (create) | ClusterIP |
| `website-staging/ingress.yaml` (create) | Host + TLS. Basic auth is added in Task 8, not here |
| `flux/image-automation/website-staging.yaml` (create) | `ImagePolicy` + `ImageUpdateAutomation` |
| `flux/image-automation/kustomization.yaml` (modify) | Registers the new file |
| `clusters/k8s-cndfrance-prod/website-staging.yaml` (create) | Flux `Kustomization` + health check |

---

### Task 1: Drive the site origin from the environment

**Repo:** `cndfrance-website`, branch `feat/staging-support`

**Files:**
- Create: `tests/build/astro-config-site.test.ts`
- Modify: `astro.config.mjs:12`
- Modify: `Dockerfile` (build stage, after `WORKDIR /app`)

**Interfaces:**
- Produces: the environment variable `PUBLIC_SITE_URL`, read at Astro config load time. Task 2 and Task 3 consume its effect via `Astro.site`. Task 4 sets it as a Docker build arg.

- [ ] **Step 1: Create the branch**

```bash
cd /home/smana/Sources/cndfrance-website
git checkout main && git pull
git checkout -b feat/staging-support
```

- [ ] **Step 2: Write the failing test**

Create `tests/build/astro-config-site.test.ts`:

```ts
/**
 * Guards the build-origin plumbing.
 *
 * `site` feeds canonical URLs, hreflang alternates, OG image URLs and the
 * sitemap. It must default to production so that every existing build path
 * (local `pnpm build`, the `main` branch, workflow_dispatch) is unchanged,
 * and must be overridable so staging builds do not advertise production URLs.
 */
import { describe, it, expect, vi, afterEach } from "vitest";

const PROD_ORIGIN = "https://cloudnativedays.fr";
const STAGING_ORIGIN = "https://staging.cloudnativedays.fr";

async function loadConfig() {
  vi.resetModules();
  return (await import("../../astro.config.mjs")).default;
}

describe("astro.config.mjs site origin", () => {
  const original = process.env.PUBLIC_SITE_URL;

  afterEach(() => {
    if (original === undefined) delete process.env.PUBLIC_SITE_URL;
    else process.env.PUBLIC_SITE_URL = original;
  });

  it("defaults to the production origin when PUBLIC_SITE_URL is unset", async () => {
    delete process.env.PUBLIC_SITE_URL;
    const config = await loadConfig();
    expect(config.site).toBe(PROD_ORIGIN);
  });

  it("honours PUBLIC_SITE_URL when set", async () => {
    process.env.PUBLIC_SITE_URL = STAGING_ORIGIN;
    const config = await loadConfig();
    expect(config.site).toBe(STAGING_ORIGIN);
  });
});
```

- [ ] **Step 3: Run the test and confirm it fails**

Run: `pnpm vitest run tests/build/astro-config-site.test.ts`

Expected: 1 passed, 1 failed. The failure is the second test:
`AssertionError: expected 'https://cloudnativedays.fr' to be 'https://staging.cloudnativedays.fr'`

(The first test passes already — the current hardcoded value happens to be the production origin. That is the point: it must keep passing.)

- [ ] **Step 4: Make the change in `astro.config.mjs`**

Replace line 12:

```diff
-  site: "https://cloudnativedays.fr",
+  // Driven by PUBLIC_SITE_URL so staging builds advertise their own origin in
+  // canonical URLs, hreflang, OG image URLs and the sitemap. Defaults to
+  // production, so every existing build path is unchanged.
+  site: process.env.PUBLIC_SITE_URL ?? "https://cloudnativedays.fr",
```

- [ ] **Step 5: Run the test and confirm it passes**

Run: `pnpm vitest run tests/build/astro-config-site.test.ts`

Expected: `Tests  2 passed (2)`

- [ ] **Step 6: Thread the build arg through the Dockerfile**

In the build stage, immediately after `WORKDIR /app`:

```diff
 FROM node:22-alpine AS build
 WORKDIR /app
+# Origin this image is built for. Defaults to production so an argument-less
+# `docker build` keeps producing the production site. The staging CI job
+# overrides it via --build-arg.
+ARG PUBLIC_SITE_URL=https://cloudnativedays.fr
+ENV PUBLIC_SITE_URL=$PUBLIC_SITE_URL
 RUN corepack enable pnpm
```

- [ ] **Step 7: Verify the ARG precedes the build command**

If `ARG`/`ENV` were placed after `RUN pnpm run build`, the override would silently do nothing.

Run:

```bash
awk '/^ARG PUBLIC_SITE_URL/{a=NR} /^RUN pnpm run build/{b=NR} END{print (a && b && a < b) ? "OK" : "FAIL"}' Dockerfile
```

Expected: `OK`

- [ ] **Step 8: Run the full suite**

Run: `pnpm test`

Expected: 21 test files pass — the 20 that existed before this task, plus the new one.

- [ ] **Step 9: Commit**

```bash
git add astro.config.mjs Dockerfile tests/build/astro-config-site.test.ts
git commit -m "feat(build): drive the site origin from PUBLIC_SITE_URL

Astro's \`site\` was hardcoded to the production origin, so any non-production
build would emit production canonical URLs, hreflang alternates, OG image URLs
and sitemap entries. Read it from the environment instead, defaulting to
production so every existing build path is unchanged."
```

---

### Task 2: Generate `robots.txt` instead of shipping it

**Repo:** `cndfrance-website`, branch `feat/staging-support`

**Files:**
- Create: `src/lib/site-env.ts`
- Create: `src/lib/__tests__/site-env.test.ts`
- Create: `src/pages/robots.txt.ts`
- Delete: `public/robots.txt`

**Interfaces:**
- Consumes: `Astro.site`, whose value comes from Task 1.
- Produces:
  - `PROD_ORIGIN: string` — the literal `"https://cloudnativedays.fr"`.
  - `isProductionOrigin(origin: string | undefined): boolean` — used by Task 3.
  - `buildRobotsTxt(origin: string | undefined): string`.

**Note:** do not put test files under `src/pages/`. Astro's file-based routing turns *every* file there into a route, so `src/pages/__tests__/foo.test.ts` would ship as a public URL. That is why the logic lives in `src/lib/` and the route is a thin wrapper.

- [ ] **Step 1: Write the failing test**

Create `src/lib/__tests__/site-env.test.ts`:

```ts
/**
 * Unit tests for src/lib/site-env.ts.
 *
 * The production robots.txt body is asserted byte-for-byte against the content
 * of the public/robots.txt file this module replaces — production output must
 * not change.
 */
import { describe, it, expect } from "vitest";
import {
  PROD_ORIGIN,
  isProductionOrigin,
  buildRobotsTxt,
} from "@/lib/site-env";

const STAGING_ORIGIN = "https://staging.cloudnativedays.fr";
const DISALLOW_ALL = "User-agent: *\nDisallow: /\n";

describe("isProductionOrigin", () => {
  it("is true only for the exact production origin", () => {
    expect(isProductionOrigin(PROD_ORIGIN)).toBe(true);
    expect(isProductionOrigin(STAGING_ORIGIN)).toBe(false);
    expect(isProductionOrigin(undefined)).toBe(false);
    expect(isProductionOrigin("http://cloudnativedays.fr")).toBe(false);
  });
});

describe("buildRobotsTxt", () => {
  it("reproduces the previous public/robots.txt byte-for-byte in production", () => {
    expect(buildRobotsTxt(PROD_ORIGIN)).toBe(
      "User-agent: *\nAllow: /\nSitemap: https://cloudnativedays.fr/sitemap-index.xml\n",
    );
  });

  it("disallows everything outside production", () => {
    expect(buildRobotsTxt(STAGING_ORIGIN)).toBe(DISALLOW_ALL);
  });

  it("fails closed when the origin is unknown", () => {
    expect(buildRobotsTxt(undefined)).toBe(DISALLOW_ALL);
  });
});
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `pnpm vitest run src/lib/__tests__/site-env.test.ts`

Expected: FAIL — `Failed to resolve import "@/lib/site-env"`

- [ ] **Step 3: Write the module**

Create `src/lib/site-env.ts`:

```ts
/**
 * Which origin is this build for?
 *
 * `site` in astro.config.mjs is driven by PUBLIC_SITE_URL and defaults to
 * production. Everything that must differ between production and staging —
 * robots.txt today, the noindex meta tag next — derives from that single
 * origin rather than from a second environment flag that could drift out of
 * sync with it.
 *
 * Both helpers fail closed: an unknown origin is treated as non-production,
 * so a misconfigured build is un-indexable rather than a duplicate of the
 * production site.
 */

export const PROD_ORIGIN = "https://cloudnativedays.fr";

export function isProductionOrigin(origin: string | undefined): boolean {
  return origin === PROD_ORIGIN;
}

export function buildRobotsTxt(origin: string | undefined): string {
  if (!isProductionOrigin(origin)) {
    return "User-agent: *\nDisallow: /\n";
  }
  return `User-agent: *\nAllow: /\nSitemap: ${PROD_ORIGIN}/sitemap-index.xml\n`;
}
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `pnpm vitest run src/lib/__tests__/site-env.test.ts`

Expected: `Tests  4 passed (4)`

- [ ] **Step 5: Add the route and remove the static file**

Create `src/pages/robots.txt.ts`:

```ts
import type { APIRoute } from "astro";
import { buildRobotsTxt } from "@/lib/site-env";

export const GET: APIRoute = ({ site }) =>
  new Response(buildRobotsTxt(site?.origin), {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
```

Then:

```bash
git rm public/robots.txt
```

A file left in `public/` is copied to `dist/` verbatim and would shadow the route.

- [ ] **Step 6: Verify both build outputs**

Run:

```bash
pnpm build && cat dist/robots.txt
```

Expected, byte-for-byte:

```
User-agent: *
Allow: /
Sitemap: https://cloudnativedays.fr/sitemap-index.xml
```

Then:

```bash
PUBLIC_SITE_URL=https://staging.cloudnativedays.fr pnpm build && cat dist/robots.txt
```

Expected:

```
User-agent: *
Disallow: /
```

- [ ] **Step 7: Commit**

```bash
git add src/lib/site-env.ts src/lib/__tests__/site-env.test.ts src/pages/robots.txt.ts
git add -u public/robots.txt
git commit -m "feat(seo): generate robots.txt from the build origin

public/robots.txt shipped \`Allow: /\` plus a hardcoded production sitemap URL,
which would have made a staging deployment crawlable and duplicated the \`site\`
value in a second place. Generate it from the build origin instead, failing
closed to \`Disallow: /\` for any non-production origin.

Production output is unchanged, asserted byte-for-byte in the unit test."
```

---

### Task 3: Emit `noindex` on non-production builds

**Repo:** `cndfrance-website`, branch `feat/staging-support`

**Files:**
- Create: `tests/build/noindex-guard.test.ts`
- Modify: `src/layouts/Layout.astro` (frontmatter, and `<head>` near the canonical block at line 78)

**Interfaces:**
- Consumes: `isProductionOrigin` from `src/lib/site-env.ts` (Task 2).
- Produces: nothing consumed by later tasks.

Basic auth (Task 8) already returns 401 to crawlers. This is defence in depth: it keeps staging un-indexable if the auth is ever lifted for a demo.

- [ ] **Step 1: Write the failing guard**

Create `tests/build/noindex-guard.test.ts`:

```ts
/**
 * Guards the non-production noindex meta tag in Layout.astro.
 *
 * Source-shape guard rather than a build assertion, matching the other
 * tests/build/ specs — a full `pnpm build` per case is too slow for CI.
 * The rendered output is verified once, manually, in the task's steps.
 */
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const LAYOUT_PATH = resolve(
  import.meta.dirname,
  "../../src/layouts/Layout.astro",
);

describe("Layout.astro robots meta", () => {
  const source = readFileSync(LAYOUT_PATH, "utf-8");

  it("imports the production-origin predicate rather than inlining the URL", () => {
    expect(source).toContain("isProductionOrigin");
    expect(source).toContain("@/lib/site-env");
  });

  it("derives an indexable flag from Astro.site", () => {
    expect(source).toMatch(
      /const\s+indexable\s*=\s*isProductionOrigin\(\s*Astro\.site\?\.origin\s*\)/,
    );
  });

  it("emits noindex, nofollow only when not indexable", () => {
    expect(source).toMatch(
      /\{\s*!indexable\s*&&\s*\(?\s*<meta\s+name="robots"\s+content="noindex, nofollow"\s*\/>/,
    );
  });
});
```

- [ ] **Step 2: Run the guard and confirm it fails**

Run: `pnpm vitest run tests/build/noindex-guard.test.ts`

Expected: 3 failed — the first with
`expected '---\nimport { Font } from "astro:assets"…' to contain 'isProductionOrigin'`

- [ ] **Step 3: Edit `Layout.astro`**

In the frontmatter, next to the other `@/` imports (line 7 area):

```diff
 import { getLangFromUrl, useTranslations, getLocalePath } from "@/i18n/utils";
+import { isProductionOrigin } from "@/lib/site-env";
```

After the `ogImageAlt` assignment (line 61):

```diff
 const ogImageAlt = t("seo.og_image_alt");
+
+// Staging and any other non-production origin must never be indexed. Basic auth
+// already returns 401 to crawlers; this keeps the guarantee if auth is lifted.
+const indexable = isProductionOrigin(Astro.site?.origin);
```

In `<head>`, immediately before the `<!-- Canonical -->` comment (line 77):

```diff
+    {!indexable && <meta name="robots" content="noindex, nofollow" />}
+
     <!-- Canonical -->
     <link rel="canonical" href={canonicalUrl} />
```

- [ ] **Step 4: Run the guard and confirm it passes**

Run: `pnpm vitest run tests/build/noindex-guard.test.ts`

Expected: `Tests  3 passed (3)`

- [ ] **Step 5: Verify the rendered output once, in both modes**

Run:

```bash
PUBLIC_SITE_URL=https://staging.cloudnativedays.fr pnpm build
grep -c 'name="robots" content="noindex, nofollow"' dist/index.html
```

Expected: `1`

Run:

```bash
pnpm build
grep -c 'name="robots"' dist/index.html || echo "absent (expected)"
```

Expected, two lines — `grep -c` prints its count and *also* exits 1 when there is no match:

```
0
absent (expected)
```

- [ ] **Step 6: Run the full suite and commit**

```bash
pnpm test
git add src/layouts/Layout.astro tests/build/noindex-guard.test.ts
git commit -m "feat(seo): emit noindex on non-production builds

Defence in depth behind the staging basic-auth gate: if the auth is ever
lifted for a demo, the origin check still keeps the deployment out of search
indexes. Derived from the same production-origin predicate as robots.txt."
```

---

### Task 4: Open the `staging` image-tag channel

**Repo:** `cndfrance-website`, branch `feat/staging-support`

**Files:**
- Modify: `.github/workflows/build-image.yml` (trigger at lines 5-6, `tags:` block at lines 60-65, build step at line 68)

**Interfaces:**
- Consumes: the `PUBLIC_SITE_URL` build arg defined in Task 1.
- Produces: images tagged `staging-<7-hex-sha>-<unix-ts>` on every push to `staging`. Task 6's `ImagePolicy` matches this pattern; Task 6's Deployment needs one concrete tag from it.

`{{sha}}` in `docker/metadata-action` expands to the **7-character short SHA** — confirmed by the production tag currently deployed, `main-327411d-1782865059`. The regex `[a-f0-9]+` matches either length, so this holds regardless.

- [ ] **Step 1: Add `staging` to the push trigger**

```diff
 on:
   push:
-    branches: [main]
+    branches: [main, staging]
```

- [ ] **Step 2: Extend the tag rule to both channels**

```diff
           tags: |
             type=sha,prefix=
-            type=raw,value={{branch}}-{{sha}}-{{date 'X'}},enable={{is_default_branch}}
+            type=raw,value={{branch}}-{{sha}}-{{date 'X'}},enable=${{ github.ref_name == 'main' || github.ref_name == 'staging' }}
             type=raw,value=latest,enable={{is_default_branch}}
             type=semver,pattern={{version}}
```

One rule now feeds both channels; the two Flux ImagePolicies discriminate by prefix. `latest` stays gated on the default branch, preserving the original intent of the comment above this block.

Update that comment to say so:

```diff
           # Flux's ImagePolicy needs lexically sortable tags (filterTags →
           # numerical sort on the embedded timestamp). The
           # `<branch>-<sha>-<unix-ts>` pattern lets Flux pick the newest
-          # deploy without semver bumps; gating on is_default_branch keeps
-          # feature-branch dispatches from polluting the channel.
+          # deploy without semver bumps. Only `main` and `staging` get this
+          # tag — one channel per environment — so feature-branch dispatches
+          # still cannot pollute either. `latest` remains main-only.
```

- [ ] **Step 3: Pass the origin as a build arg**

```diff
       - name: Build and push
         id: build
         uses: docker/build-push-action@v6
         with:
           context: .
           push: ${{ env.IS_PUBLISH }}
+          build-args: |
+            PUBLIC_SITE_URL=${{ github.ref_name == 'staging' && 'https://staging.cloudnativedays.fr' || 'https://cloudnativedays.fr' }}
```

- [ ] **Step 4: Lint the workflow**

Run: `actionlint .github/workflows/build-image.yml`

Expected: no output, exit code 0.

- [ ] **Step 5: Assert the parsed result**

Run:

```bash
yq '.on.push.branches' .github/workflows/build-image.yml
```

Expected:

```yaml
- main
- staging
```

Run:

```bash
yq '.jobs.build.steps[] | select(.id == "build") | .with["build-args"]' .github/workflows/build-image.yml
```

Expected: a single line containing both `PUBLIC_SITE_URL=` and `staging.cloudnativedays.fr`.

- [ ] **Step 6: Commit and open the PR**

```bash
git add .github/workflows/build-image.yml
git commit -m "ci: publish a staging image channel

Adds a second sortable tag channel, \`staging-<sha>-<ts>\`, consumed by a
dedicated Flux ImagePolicy. \`latest\` stays gated on the default branch, so the
production channel is still not polluted by non-main builds.

The staging build also receives PUBLIC_SITE_URL so its canonical URLs, hreflang,
OG images and sitemap point at the staging origin rather than production."

git push -u origin feat/staging-support
gh pr create --base main \
  --title "Add staging build support" \
  --body "Prepares the website for a staging deployment at staging.cloudnativedays.fr.

- \`site\` is read from \`PUBLIC_SITE_URL\`, defaulting to production
- \`robots.txt\` is generated from the build origin and fails closed to \`Disallow: /\`
- non-production builds emit \`noindex, nofollow\`
- CI publishes a \`staging-<sha>-<ts>\` tag channel alongside \`main-<sha>-<ts>\`

Production output is unchanged: the default origin is production and the
generated robots.txt is asserted byte-for-byte against the file it replaces.

Design: \`cnd-platform/docs/superpowers/specs/2026-07-25-website-staging-design.md\`"
```

---

### Task 5: Merge and cut the `staging` branch

**Repo:** `cndfrance-website`

**Files:** none — branch and CI operations only.

**Interfaces:**
- Consumes: the merged PR from Task 4.
- Produces: the first `staging-<sha>-<ts>` image tag. Task 6 needs its exact value.

- [ ] **Step 1: Merge the PR after review**

```bash
gh pr merge --squash --delete-branch
```

- [ ] **Step 2: Confirm production is unaffected**

The merge triggers a `main` build. Wait for it, then check that the production robots.txt is unchanged:

```bash
gh run watch "$(gh run list --branch main --workflow build-image.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Expected: `✓ Build and Push Container Image`

- [ ] **Step 3: Cut the staging branch**

```bash
git checkout main && git pull
git checkout -b staging
git push -u origin staging
```

- [ ] **Step 4: Wait for the first staging image**

```bash
gh run watch "$(gh run list --branch staging --workflow build-image.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Expected: `✓ Build and Push Container Image`

- [ ] **Step 5: Capture the exact tag — Task 6 needs it**

```bash
RUN_ID=$(gh run list --branch staging --workflow build-image.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run view "$RUN_ID" --log \
  | grep -oE 'ghcr\.io/cloudnativefrance/website:staging-[a-f0-9]+-[0-9]+' \
  | head -1
```

Expected: one line, for example `ghcr.io/cloudnativefrance/website:staging-a1b2c3d-1785000000`.

Record it. If the command returns nothing, read the "Extract metadata" step's output in the run log directly — the tag list is printed there.

---

### Task 6: Namespace and staging manifests

**Repo:** `cnd-platform`, branch `feat/website-staging`

**Files:**
- Modify: `namespaces/namespaces.yaml` (append)
- Create: `website-staging/kustomization.yaml`
- Create: `website-staging/deployment.yaml`
- Create: `website-staging/service.yaml`
- Create: `website-staging/ingress.yaml`

**Interfaces:**
- Consumes: the image tag captured in Task 5, step 5.
- Produces: a Deployment named `website` in namespace `cnd-website-staging`, carrying the marker `# {"$imagepolicy": "flux-system:cnd-website-staging"}`, which Task 7's `ImageUpdateAutomation` rewrites.

The Ingress is created **without** basic-auth annotations. cert-manager must complete its HTTP-01 challenge first; the auth gate is added in Task 8. This ordering is the mitigation recorded in the spec's risk table.

- [ ] **Step 1: Create the branch**

```bash
cd /home/smana/Sources/cnd-platform
git checkout main && git pull
git checkout -b feat/website-staging
```

- [ ] **Step 2: Add the namespace**

Append to `namespaces/namespaces.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: cnd-website-staging
```

- [ ] **Step 3: Create `website-staging/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cnd-website-staging

resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

- [ ] **Step 4: Create `website-staging/deployment.yaml`**

Replace `staging-REPLACE-ME` with the tag captured in Task 5, step 5.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: website
  namespace: cnd-website-staging
  labels:
    app.kubernetes.io/name: website
    app.kubernetes.io/component: static-site
    app.kubernetes.io/part-of: cnd-france
spec:
  # One replica: staging validates content and layout, not availability.
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: website
  template:
    metadata:
      labels:
        app.kubernetes.io/name: website
        app.kubernetes.io/component: static-site
        app.kubernetes.io/part-of: cnd-france
    spec:
      securityContext:
        runAsNonRoot: false
        fsGroup: 0
      containers:
        - name: website
          image: ghcr.io/cloudnativefrance/website:staging-REPLACE-ME # {"$imagepolicy": "flux-system:cnd-website-staging"}
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
            periodSeconds: 30
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop:
                - ALL
              add:
                - CHOWN
                - SETGID
                - SETUID
                - NET_BIND_SERVICE
```

Resources, probes and securityContext are copied from `website/deployment.yaml` unchanged, so staging exercises the same runtime shape as production.

- [ ] **Step 5: Create `website-staging/service.yaml`**

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: website
  namespace: cnd-website-staging
  labels:
    app.kubernetes.io/name: website
    app.kubernetes.io/component: static-site
    app.kubernetes.io/part-of: cnd-france
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
  selector:
    app.kubernetes.io/name: website
```

- [ ] **Step 6: Create `website-staging/ingress.yaml`**

```yaml
---
# Basic auth is deliberately absent here. cert-manager must complete its
# HTTP-01 challenge before the gate goes up; the auth annotations are added in
# a follow-up commit once website-staging-tls is Ready.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: website
  namespace: cnd-website-staging
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
spec:
  ingressClassName: public
  rules:
    - host: staging.cloudnativedays.fr
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: website
                port:
                  name: http
  tls:
    - hosts:
        - staging.cloudnativedays.fr
      secretName: website-staging-tls
```

- [ ] **Step 7: Verify the kustomization renders**

Run:

```bash
kustomize build website-staging/ | grep '^kind:'
```

Expected:

```
kind: Service
kind: Deployment
kind: Ingress
```

- [ ] **Step 8: Verify every object lands in the staging namespace**

A missing `namespace:` would deploy staging on top of production.

Run:

```bash
kustomize build website-staging/ | yq -r 'select(.metadata) | .metadata.namespace' | sort -u
```

Expected: `cnd-website-staging` — one line, nothing else.

- [ ] **Step 9: Validate against the API schema**

Run:

```bash
kustomize build website-staging/ | kubectl apply --dry-run=client -f -
```

Expected: three `... created (dry run)` lines.

- [ ] **Step 10: Commit**

```bash
git add namespaces/namespaces.yaml website-staging/
git commit -m "feat(website): add the staging kustomization

A near-copy of ./website scoped to the cnd-website-staging namespace, with one
replica instead of two and the staging host. Resources, probes and
securityContext are carried over unchanged so staging exercises the same
runtime shape as production.

The Ingress ships without basic auth on purpose: cert-manager needs to complete
its HTTP-01 challenge before the gate goes up."
```

---

### Task 7: Flux image automation and cluster wiring

**Repo:** `cnd-platform`, branch `feat/website-staging`

**Files:**
- Create: `flux/image-automation/website-staging.yaml`
- Modify: `flux/image-automation/kustomization.yaml`
- Create: `clusters/k8s-cndfrance-prod/website-staging.yaml`

**Interfaces:**
- Consumes: the `ImageRepository` named `cnd-website` in `flux-system`, which already exists (`flux/image-automation/website.yaml`) and points at the same GHCR repository. It is reused, not duplicated.
- Produces: an `ImagePolicy` named `cnd-website-staging`, referenced by the marker written in Task 6, step 4.

- [ ] **Step 1: Create `flux/image-automation/website-staging.yaml`**

```yaml
---
# The ImageRepository cnd-website (see website.yaml) is reused as-is: staging
# pulls from the same GHCR repository, so a second scan would be wasted work.
# Only the policy and the write-back automation are specific to staging.
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: cnd-website-staging
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: cnd-website
  filterTags:
    pattern: '^staging-[a-f0-9]+-(?P<ts>[0-9]+)$'
    extract: '$ts'
  policy:
    numerical:
      order: asc
---
# A separate automation is mandatory. The production one targets ./website; if
# it were reused it would rewrite the production manifest with a staging tag.
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageUpdateAutomation
metadata:
  name: cnd-website-staging
  namespace: flux-system
spec:
  interval: 30m
  sourceRef:
    kind: GitRepository
    name: customer
  git:
    commit:
      author:
        email: fluxcdbot@cloudnativedays.fr
        name: fluxcdbot
      messageTemplate: |
        chore(website-staging): update image to {{range .Changed.Changes}}{{println .NewValue}}{{end}}
    push:
      branch: main
  update:
    path: ./website-staging
```

- [ ] **Step 2: Register the file**

`flux/image-automation/kustomization.yaml`:

```diff
 resources:
   - website.yaml
+  - website-staging.yaml
   - ente-web.yaml
```

- [ ] **Step 3: Create `clusters/k8s-cndfrance-prod/website-staging.yaml`**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
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

- [ ] **Step 4: Verify the image-automation kustomization renders**

Run:

```bash
kustomize build flux/image-automation/ | yq -r '[.kind, .metadata.name] | join(" ")'
```

Expected to include both existing and new objects, among them:

```
ImagePolicy cnd-website-staging
ImageUpdateAutomation cnd-website-staging
```

- [ ] **Step 5: Assert the two automations write to different paths**

This is the single most damaging mistake available in this task.

Run:

```bash
kustomize build flux/image-automation/ \
  | yq -r 'select(.kind == "ImageUpdateAutomation") | [.metadata.name, .spec.update.path] | join(" -> ")'
```

Expected: two distinct lines, including

```
cnd-website -> ./website
cnd-website-staging -> ./website-staging
```

- [ ] **Step 6: Validate the cluster Kustomization**

Run:

```bash
kubectl apply --dry-run=client -f clusters/k8s-cndfrance-prod/website-staging.yaml
```

Expected: `kustomization.kustomize.toolkit.fluxcd.io/cnd-website-staging created (dry run)`

- [ ] **Step 7: Commit and open the PR**

```bash
git add flux/image-automation/ clusters/k8s-cndfrance-prod/website-staging.yaml
git commit -m "feat(website): automate the staging image channel

Reuses the existing cnd-website ImageRepository — staging pulls from the same
GHCR repository — and adds a policy matching the staging-<sha>-<ts> tags plus a
separate ImageUpdateAutomation writing to ./website-staging.

The automation must be separate: the production one targets ./website and would
otherwise rewrite the production manifest with a staging tag."

git push -u origin feat/website-staging
gh pr create --base main \
  --title "Add the website staging environment" \
  --body "Deploys a second website instance at staging.cloudnativedays.fr, fed by the
\`staging\` branch of cloudnativefrance/cndfrance-website.

- new namespace \`cnd-website-staging\`
- \`website-staging/\` kustomization: 1 replica, staging host
- Flux ImagePolicy on \`staging-<sha>-<ts>\` plus a separate ImageUpdateAutomation on \`./website-staging\`

Requires the companion change in cndfrance-website (merged) and two manual
steps after merge: the DNS record and the basic-auth SealedSecret.

Design: \`docs/superpowers/specs/2026-07-25-website-staging-design.md\`"
```

---

### Task 8: DNS, certificate, and the basic-auth gate

**Repo:** `cnd-platform`, branch `feat/website-staging-auth` (cut after Task 7's PR merges)

**Files:**
- Create: `website-staging/auth-sealedsecret.yaml`
- Modify: `website-staging/ingress.yaml`

**Interfaces:**
- Consumes: the deployed Ingress from Task 6 and a resolving DNS record.
- Produces: a `SealedSecret` named `website-staging-auth` with data key `auth`.

This task requires cluster access and a DNS change. It is the operator's, not an agent's.

- [ ] **Step 1: Create the DNS record**

`staging.cloudnativedays.fr` → the same address `cloudnativedays.fr` resolves to.

Verify:

```bash
dig +short staging.cloudnativedays.fr
dig +short cloudnativedays.fr
```

Expected: identical output.

- [ ] **Step 2: Confirm Flux has reconciled both kustomizations**

```bash
flux get kustomizations cnd-website-staging
flux get images policy cnd-website-staging
```

Expected: `Ready: True` for the kustomization, and a `LatestImage` ending in a `staging-…` tag for the policy.

- [ ] **Step 3: Wait for the certificate**

```bash
kubectl -n cnd-website-staging get certificate website-staging-tls -w
```

Expected: `READY  True`. If it stays `False` for more than a few minutes:

```bash
kubectl -n cnd-website-staging describe certificate website-staging-tls
kubectl -n cnd-website-staging get challenges
```

- [ ] **Step 4: Confirm the site serves before locking it**

```bash
curl -sI https://staging.cloudnativedays.fr | head -1
curl -s https://staging.cloudnativedays.fr/robots.txt
```

Expected: `HTTP/2 200`, then:

```
User-agent: *
Disallow: /
```

If robots.txt shows `Allow: /`, the image was built without the `PUBLIC_SITE_URL` build arg — stop and fix Task 4 before continuing.

- [ ] **Step 5: Seal the basic-auth secret**

```bash
cd /home/smana/Sources/cnd-platform
git checkout main && git pull
git checkout -b feat/website-staging-auth

read -rsp 'staging password: ' STAGING_PW && echo
htpasswd -nbB cnd "$STAGING_PW" > /tmp/auth
unset STAGING_PW
kubectl create secret generic website-staging-auth \
  --from-file=auth=/tmp/auth \
  -n cnd-website-staging --dry-run=client -o yaml \
  | kubeseal --format yaml > website-staging/auth-sealedsecret.yaml
rm -f /tmp/auth
```

The data key must be exactly `auth`; ingress-nginx looks for no other name.

- [ ] **Step 6: Verify nothing unsealed leaked into the file**

```bash
yq -r '.kind' website-staging/auth-sealedsecret.yaml
grep -c 'stringData\|^data:' website-staging/auth-sealedsecret.yaml || echo "0 (expected)"
```

Expected: `SealedSecret`, then `0 (expected)`.

- [ ] **Step 7: Register the secret and raise the gate**

`website-staging/kustomization.yaml`:

```diff
 resources:
   - deployment.yaml
   - service.yaml
   - ingress.yaml
+  - auth-sealedsecret.yaml
```

`website-staging/ingress.yaml`:

```diff
-# Basic auth is deliberately absent here. cert-manager must complete its
-# HTTP-01 challenge before the gate goes up; the auth annotations are added in
-# a follow-up commit once website-staging-tls is Ready.
 apiVersion: networking.k8s.io/v1
 kind: Ingress
 metadata:
   name: website
   namespace: cnd-website-staging
   annotations:
     cert-manager.io/cluster-issuer: letsencrypt
+    nginx.ingress.kubernetes.io/auth-type: basic
+    nginx.ingress.kubernetes.io/auth-secret: website-staging-auth
+    nginx.ingress.kubernetes.io/auth-realm: "CND France — staging"
```

- [ ] **Step 8: Verify and commit**

```bash
kustomize build website-staging/ | kubectl apply --dry-run=client -f -
git add website-staging/
git commit -m "feat(website): gate staging behind basic auth

Added after the TLS certificate issued, so the ACME HTTP-01 challenge ran
against an unauthenticated ingress. The htpasswd credentials ship as a
SealedSecret, matching every other secret in this repo."
git push -u origin feat/website-staging-auth
gh pr create --base main --title "Gate the website staging environment behind basic auth" \
  --body "Follow-up to the staging environment PR. Adds the htpasswd SealedSecret and the
ingress-nginx basic-auth annotations, now that website-staging-tls has issued."
```

- [ ] **Step 9: Confirm the gate after Flux reconciles**

```bash
curl -sI https://staging.cloudnativedays.fr | head -1
curl -sI -u cnd:'<password>' https://staging.cloudnativedays.fr | head -1
```

Expected: `HTTP/2 401` then `HTTP/2 200`.

- [ ] **Step 10: Confirm production is untouched**

```bash
curl -s https://cloudnativedays.fr/robots.txt
kubectl -n cnd-website get deploy website -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Expected: the production robots.txt exactly as before, and an image tag still beginning with `main-`. A `staging-` tag here means the two ImageUpdateAutomations collided — revert and re-check Task 7, step 5.

---

## Done when

- `https://staging.cloudnativedays.fr` returns 401 without credentials and 200 with them.
- Its `/robots.txt` is `Disallow: /`; production's is unchanged.
- A push to `staging` reaches the deployed site without manual intervention.
- The production Deployment still runs a `main-…` tag.
