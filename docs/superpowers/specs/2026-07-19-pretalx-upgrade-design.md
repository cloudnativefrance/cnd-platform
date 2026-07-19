# Pretalx upgrade runbook — v2025.1.0 → v2026.2.1

Date: 2026-07-19
Component: `callforpapers/pretalx` (namespace `cnd-callforpapers`, cluster `k8s-cndfrance-prod`)
Scope: pretalx only. Valkey v6 deferred (see "Deferred / blocked").

## Goal

Move pretalx from **v2025.1.0** to the latest **v2026.2.1**, and in the process
**drop the custom `smana/pretalx` fork** in favour of pure upstream
`pretalx/standalone:v2026.2.1`.

## Findings that shaped this plan

- **The custom image is one cosmetic template.** `smana/pretalx:v2025.1.0-cndfr-1`
  differs from upstream `pretalx/standalone:v2025.1.0` in exactly one file:
  `src/pretalx/common/templates/common/forms/field.html` — it renders each field's
  help text *above* the input instead of below (commit `243e7bd`). No plugins, no
  logic, no schema changes. Verified by diffing the two file trees inside pod
  `pretalx-0` (web container = custom, worker container = upstream).
- **Behaviour is preserved on drop.** Upstream `pretalx/standalone:v2026.2.1` is
  `ENTRYPOINT ["pretalx"]` / `CMD ["all"]` — identical to the current web container
  (PID1 = `supervisord … all`). The image entrypoint defaults `AUTOMIGRATE=yes` and
  `AUTOREBUILD=yes`, so the new pod runs `python -m pretalx migrate --noinput` and
  `rebuild` on boot before serving. No manual migration step required (but we watch
  the logs to confirm).
- **DB prerequisites already met.** v2026.1.0 requires PostgreSQL 16+ and Python
  3.12+. The CNPG cluster runs **PG 17.5**; Python 3.12 ships inside the image.
- **Irreversible migration.** v2026.1.0 permanently removes soft-deleted proposals
  and the activity-log `legacy_data` field during migration. Covered by the
  pre-upgrade base backup.
- **The `-cndfr` help-text tweak is dropped** (decision: cosmetic, not worth the
  per-upgrade maintenance). If help-below turns out to be a problem, re-add it
  *without* an image by mounting a reordered `field.html` (rebased on the
  v2026.2.1 upstream template) as a ConfigMap volume — the same pattern already
  used for `pretalx.cfg` and `nginx.conf`. Recipe kept in scratch.

## Pre-flight (done)

- On-demand base backup taken: **`cnpg-pretalx-preupgrade-20260719`**
  (backupId `20260719T073349`, completed, barmanObjectStore → Scaleway S3).
- Backup subsystem verified healthy: `ContinuousArchiving=True`,
  `LastBackupSucceeded=True`, nightly ScheduledBackup green, recoverability window
  back to 2026-04-20 (90d retention).
- Note (not blocking): CNPG backs up the **database only**. The `pretalx-public`
  PVC (media uploads, `.secret`) is on `node-local-retain` and is **not** backed
  up. This in-place image bump does not touch the PVCs, so media/`.secret` persist.

## Open-PR disposition

| PR | Action |
|----|--------|
| #144 actions/checkout v7 | Merge first (CI only) |
| #113 dagger-for-github v8 | Merge first (CI only) |
| #89 pretalx worker → v2025.2.3 | Close — superseded |
| #73 valkey chart → 3.0.31 | Close — superseded |
| #114 pretalx worker → v2026.2.1 | Superseded by this PR (worker-only, unsafe alone) |
| #112 nginx 1.29 → 1.31-alpine | Folded into this PR |
| #143 valkey chart → 6.2.0 | **Defer** — blocked (see below) |
| #111 / #106 / #105 | Out of scope (matrix / mattermost / baserow) |

## Change (branch `chore/pretalx_update_202607`)

`callforpapers/pretalx/statefulset.yaml`:

| Container | From | To |
|-----------|------|----|
| `pretalx` (web) | `smana/pretalx:v2025.1.0-cndfr-1` | `pretalx/standalone:v2026.2.1` |
| `pretalx-worker` | `pretalx/standalone:v2025.1.0` | `pretalx/standalone:v2026.2.1` |
| `nginx-statics` | `nginx:1.29-alpine` | `nginx:1.31-alpine` |

## Execution

1. Merge #144 and #113; close #89 and #73.
2. Commit the statefulset change, push, open PR; confirm CI (Kubernetes validation) green.
3. **Checkpoint** — get explicit go before merging to main.
4. Merge to main → `flux reconcile kustomization cnd-callforpapers --with-source`.
5. StatefulSet `pretalx` rolls (single replica, RWO PVCs → brief downtime). New pod
   auto-migrates + rebuilds. `kubectl logs -f pretalx-0 -c pretalx` to watch migrations.

## Verification

- `kubectl get pod pretalx-0` → `3/3 Running`.
- `kubectl exec pretalx-0 -c pretalx -- python -m pretalx --version` → `v2026.2.1`.
- CNPG cluster still `Healthy`, no failed migration in logs.
- `curl -sI -H 'Host: cfp.cloudnativedays.fr' …` → HTTP 200; CfP page + a form render.
- Celery worker container healthy.
- Take a post-upgrade on-demand backup.

## Rollback

- Fast path: `git revert` the PR → Flux restores `smana/pretalx:v2025.1.0-cndfr-1`
  and the old worker/nginx tags. (Forward DB migrations are **not** auto-reversed by
  downgrading the image.)
- If the DB must be rolled back after migrating: restore from base backup
  `20260719T073349` via CNPG recovery bootstrap into a new cluster, then repoint.

## Deferred / blocked

- **Valkey v6 (PR #143) is blocked.** Cluster Kyverno ClusterPolicy
  `move-to-bitnamilegacy` rewrites `docker.io/bitnami/*` → `docker.io/bitnamilegacy/*`.
  `bitnamilegacy/valkey` is a frozen snapshot capped at **8.1.3**; chart 6.2.0 wants
  appVersion **9.1.0** → `ImagePullBackOff`. Going past 8.1.3 is a "get-off-Bitnami"
  migration (subscribe to Bitnami Secure Images, switch to `valkey/valkey` upstream
  image, or exempt valkey from the policy), tracked separately — not a version bump.
- Baserow valkey, matrix-stack (#111), mattermost-operator (#106), baserow OOM (#105).
