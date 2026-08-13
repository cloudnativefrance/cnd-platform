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

## Known deprecation — platform-wide

CNPG 1.26.0 warns on every apply that native `spec.backup.barmanObjectStore` support is
removed in **1.28.0**. This cluster uses it anyway, to match the seven other CNPG clusters in
this repo; migrating one alone would make the fleet less consistent. Plan the move to the
Barman Cloud Plugin as a single platform-wide task before the operator reaches 1.28.0.

## Privacy

Cookieless, no personal data, DNT honoured, telemetry disabled. That is what makes operating
without a consent banner defensible for audience measurement — confirm the approach with
whoever owns the site's legal pages, and keep the privacy page's analytics mention accurate.
