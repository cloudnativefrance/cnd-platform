# Runbook — Matrix devices, verification and chat history

**Scope**: Matrix / ESS stack in `cnd-communication` (Synapse 1.150 + MAS 1.14 + Element Web 1.12.x),
served at https://chat.cloudnativedays.fr.

This runbook has two parts:

- **[Part A](#part-a--check-your-own-setup) — check your own setup.** 5 minutes, any team member, no
  admin rights, nothing to install. **This is the link to send to the team.**
- **[Part B](#part-b--admin--reset-a-users-devices) — admin: reset a user's devices** without losing
  their history. Requires cluster access.

---

# Part A — Check your own setup

Do this once, and again whenever you start using a new laptop or phone. It takes five minutes and it
is what stands between you and losing years of chat history.

> ### ⛔ One button you must never press on your own
>
> **Settings → Encryption → "Reset cryptographic identity"**.
>
> It sounds like the fix for every encryption problem. It is not — it **permanently destroys your
> ability to read your old messages** unless an admin has prepared for it first. If you think you need
> it, stop and ask in the team channel. Everything in Part A is safe; that button is not part of it.

Open https://chat.cloudnativedays.fr, click your avatar in the top-left, then **Settings**.

## A1. Is this session verified? (1 min)

Go to **Sessions**. Look at **Current session**.

| What you see | What it means | What to do |
|---|---|---|
| **Verified session** | This device is trusted and can read your history. | Nothing. Go to A2. |
| **Unverified session** | Matrix does not trust this device yet. Old messages stay locked and other people see warnings on your messages. | Verify it now: use another device where you are already signed in and verified (emoji check), or click the recovery-key option and enter your recovery key. |
| Unverified, and you have **no other device and no recovery key** | You cannot get back in on your own. | **Stop here** and ask an admin. Do not press "Reset cryptographic identity" — an admin can sometimes save your history, that button cannot. |

## A2. Is key storage on? (1 min)

Go to **Settings → Encryption**, section **Key storage**.

| What you see | What to do |
|---|---|
| **"Allow key storage"** is ON, no warning | Good. Go to A3. |
| **"Allow key storage"** is OFF | Turn it on. This is what lets a *future* device read *today's* messages. Wait until it finishes uploading — it can take a few minutes. |
| **"Your key storage is out of sync."** | Click the button it offers and wait for the message to disappear. |
| **"Failed to sync key storage. You need to reset your identity."** | **Stop** and ask an admin. Do not follow that suggestion yourself. |

## A3. Do you have a recovery key you can actually use? (2 min)

Still in **Settings → Encryption**, section **Recovery**.

Your recovery key is the *only* thing that gets your history onto a device you do not own yet — a new
laptop, a replacement phone, a browser profile you had to wipe. The server cannot do it for you.

1. If you see **"Set up recovery"** — you have never had a key. Click it.
   > ⚠️ **This is the trap that catches people.** Seeing "Set up recovery" means you have **no**
   > recovery key *even if A2 told you your keys are backed up*. Both can be true at once: your keys
   > are safely on the server, inside a box that nothing on earth can open from a new device. If you
   > see this button, you are one wiped browser profile away from losing your history.
2. If you see **"Change recovery key"** — you already have one. **If you cannot find it in your
   password manager right now, click "Change recovery key" and make a new one.** This is safe: it
   re-protects the keys you already have. (It is *not* "Reset cryptographic identity".)
3. Element shows the key **once**, under *"Save your recovery key somewhere safe"*. Put it in the team
   password manager **before clicking away** — not in a note, not in a DM to yourself.
4. Complete the *"Confirm your recovery key"* screen, which asks you to type it back.

## A4. Prove the key works (2 min)

Everyone skips this one. An untested recovery key is a guess, not a backup.

1. Open a **private / incognito window** and go to https://chat.cloudnativedays.fr.
2. Sign in with Google as usual.
3. When asked to verify, choose the recovery-key option and paste your key at **"Enter recovery key"**.
4. Open an old conversation and check you can read messages from *before today*.
5. **Sign that test session out** — Settings → Sessions → find it under "Other sessions" → **Sign out**.
   If you leave it, it becomes an abandoned session that breaks decryption for other people (A5).

If step 3 or 4 fails, your key is wrong or your key storage is incomplete. Ask an admin *before*
changing anything else.

## A5. Clean up your old sessions (1 min)

**Settings → Sessions → Other sessions.** Every device you have ever signed in with is listed.

Sign out anything you no longer use — an old laptop, a phone you replaced, a browser you tried once.
This is not just tidiness: other people's apps keep encrypting messages to those dead sessions, and
that is one of the main reasons someone sees "unable to decrypt". Use **Show details** if you are not
sure what a session is; the last-activity date is usually enough to recognise it.

You can also do this outside Element, at https://auth-matrix.cloudnativedays.fr/.

## Two habits that prevent all of this

1. **Keep two verified sessions** — for example desktop *and* phone. Then losing one device is a
   non-event: the other one verifies your replacement, and you never depend on finding the key.
2. **Sign a session out the day you stop using it**, not months later.

## Self-check card

Copy this into your reply when someone asks you to run the check:

```
[ ] A1  Sessions → Current session says "Verified session"
[ ] A2  Encryption → "Allow key storage" is ON, no warning
[ ] A3  Recovery key is in the team password manager
[ ] A4  Signed in with it in a private window, read an old message, signed that session out
[ ] A5  No sessions left under "Other sessions" that I don't recognise
```

---

# Part B — Admin — reset a user's devices

**Use when**: a user reports "Unable to decrypt", endless "Verify this session" prompts, a red shield
on their own messages, or has an unmanageable pile of old sessions — and Part A did not resolve it.

## B0. The one rule

> **The server cannot decrypt anything and cannot recover a single message key.**

51 of our 57 rooms are end-to-end encrypted. Message keys live *only* in the clients and in the
user's **key storage**, which is itself encrypted with a **recovery key the server never sees**.

Therefore:

1. **Keys are preserved BEFORE sessions are killed.** Never the reverse — killing the last device that
   holds un-backed-up keys destroys that history permanently, for that user, on every future device.
2. **History "on any device" is only ever provided by key storage + recovery key.** There is no
   server-side alternative.
3. If the user has no working device *and* no recovery key, history in encrypted rooms **is already
   lost**. Say so explicitly and get their acknowledgement before proceeding (B1, Path B).

**Do not run this alongside**: a Synapse or MAS upgrade, or a CNPG failover.

## Prerequisites

```bash
export NS=cnd-communication
export USER_LOCAL=katia                                    # localpart, no @ and no domain
export USER_ID="@${USER_LOCAL}:matrix.cloudnativedays.fr"   # full MXID

# read-only DB access (any instance; reads are fine on a replica)
export PG=$(kubectl get pod -n $NS -l cnpg.io/cluster=cnpg-synapse -o name | head -1 | cut -d/ -f2)
psql() { kubectl exec -n $NS "$PG" -c postgres -- psql -U postgres -d synapse -c "$1"; }
```

## B1. Triage (read-only, safe)

### B1a. Real sessions vs. cross-signing pseudo-devices

Synapse stores cross-signing keys as rows in `devices`. They are **not** sessions — never count them,
never delete them by hand. They are the rows whose `display_name` ends in `signing key`.

```bash
psql "select device_id, coalesce(display_name,'(no name)') as name,
        to_timestamp(last_seen/1000) as last_seen, ip
      from devices
      where user_id='$USER_ID' and coalesce(display_name,'') not like '%signing key'
      order by last_seen desc nulls last;"
```

Read the result like this:

| Pattern | Meaning | Action |
|---|---|---|
| `last_seen` recent | live session | candidate **source of truth** for keys (B2) |
| `last_seen` months old | abandoned client | kill it |
| `last_seen` and `ip` both NULL | session provisioned but the client never came online | **kill it** — other members' clients still encrypt to it, which is a top cause of "unable to decrypt" |

### B1b. Which sessions are actually verified?

A session the user can log into is not necessarily one that can *read* anything. A device is trusted
only if it carries a signature from the user's **current** self-signing key — and that signature lives
in one of two places, so both must be checked.

```bash
psql "with ssk as (
        select distinct on (user_id) user_id,
               split_part((select k from jsonb_object_keys((keydata::jsonb)->'keys') k limit 1),':',2) as ssk
        from e2e_cross_signing_keys where keytype='self_signing'
        order by user_id, stream_id desc)
      select d.device_id, to_timestamp(d.last_seen/1000) as last_seen,
             (coalesce(dk.key_json like '%'||s.ssk||'%', false)
              or exists (select 1 from e2e_cross_signing_signatures g
                         where g.target_user_id=d.user_id and g.target_device_id=d.device_id
                           and g.key_id='ed25519:'||s.ssk)) as verified
      from devices d
      left join e2e_device_keys_json dk on dk.user_id=d.user_id and dk.device_id=d.device_id
      left join ssk s on s.user_id=d.user_id
      where d.user_id='$USER_ID' and coalesce(d.display_name,'') not like '%signing key'
      order by d.last_seen desc nulls last;"
```

`verified = f` on the session the user is currently using **is the single most common cause of "I
can't connect"** — Element parks them behind "Verify this device" with no readable rooms, which users
report as a login problem. It is not one: check the MAS session state (B1e) before touching anything.

### B1c. Cross-signing identity history

```bash
psql "select keytype, stream_id, left(keydata, 55) as keydata
      from e2e_cross_signing_keys where user_id='$USER_ID' order by keytype, stream_id;"
```

Synapse never deletes superseded cross-signing keys, so **the current identity is the row with the
highest `stream_id` per keytype** — extra rows are the history of past resets, not corruption in
themselves. One `master` row = the identity has never been reset. Several = it has, and any member
whose client is still pinned to an older `master` will see this user as unverified no matter how often
they re-verify. Only that symptom, reported by *other* people, justifies B4.

### B1d. Is the key storage usable?

```bash
psql "select v.version, v.deleted, count(k.session_id) as backed_up_keys
      from e2e_room_keys_versions v
      left join e2e_room_keys k on k.user_id=v.user_id and k.version=v.version
      where v.user_id='$USER_ID' group by 1,2 order by 1;"
```

Only the row with `deleted = 0` matters — keys under a deleted version are unreachable forever.
Compare `backed_up_keys` against the user's room count; a few hundred keys for someone in 20 rooms is
normal, single digits means key storage was never populated.

**A populated backup is NOT proof that anything can be recovered.** The key that decrypts it lives in
the user's secret storage (4S), and Element lets a user enable key storage while skipping the recovery
setup. The result looks healthy from every angle except this one:

```bash
psql "select account_data_type from account_data
      where user_id='$USER_ID'
        and account_data_type in ('m.secret_storage.default_key','m.megolm_backup.v1');"
```

| Result | Meaning |
|---|---|
| both rows present | A recovery key exists. The backup is openable from a new device. |
| **no rows** | **No recovery key was ever created.** The backup can only be opened by a device that already holds the key locally. If those devices are gone, so is the history — regardless of how many keys `backed_up_keys` reports. |

If this returns nothing, jump straight to B1f Path B and tell the user there is nothing to look for in
their password manager. Do not send them hunting for a key that was never generated.

### B1e. Is it really a login problem? (check before assuming)

```bash
MASPG=$(kubectl get pod -n $NS -l cnpg.io/cluster=cnpg-mas -o name | head -1 | cut -d/ -f2)
M() { kubectl exec -n $NS "$MASPG" -c postgres -- psql -U postgres -d mas -c "$1"; }

# account state: locked_at / deactivated_at must be empty
M "select username, created_at, locked_at, deactivated_at from users where username='$USER_LOCAL';"

# live sessions: finished_at empty = still valid; check last_active_at
M "select s.created_at, s.finished_at, s.last_active_at, s.last_active_ip,
     (select x from unnest(s.scope_list) x where x like '%device:%') as device
   from oauth2_sessions s
   where s.user_id=(select user_id from users where username='$USER_LOCAL')
   order by s.created_at desc limit 10;"

# Google link present?
M "select p.human_name, l.subject, l.created_at from upstream_oauth_links l
   join upstream_oauth_providers p using (upstream_oauth_provider_id)
   where l.user_id=(select user_id from users where username='$USER_LOCAL');"
```

Also rule out rate limiting — `rc_login` is deliberately strict in our config:

```bash
kubectl logs -n $NS matrix-stack-synapse-main-0 -c synapse --since=6h | grep -c "M_LIMIT_EXCEEDED"
kubectl logs -n $NS matrix-stack-synapse-main-0 -c synapse --since=6h | grep "$USER_LOCAL" | tail -20
```

If MAS shows a live session and Synapse shows HTTP 200s, the user *is* connected and the problem is
verification (B1b), not authentication. Point them at Part A before doing anything destructive.

### B1f. Decision

| Condition | Path |
|---|---|
| A **verified** session is alive and the user can open Element on it | **A — safe reset** (B2 → B3 → B5) |
| No verified session, but the user has their recovery key | **A'** — skip B2, go to B3, restore in B5 |
| No verified session **and** no recovery key | **B — lossy reset**: history in encrypted rooms is gone. Get explicit acknowledgement in writing, then B3 → B5. The user re-joins with an empty backlog. |

## B2. Preserve the keys (user does this, on their healthy device)

Have the user run **A2 and A3** on the device from B1b with `verified = t` and the most recent
`last_seen`, and confirm each step back to you before you touch anything. Then have them read the
first 4 characters of the recovery key back to you, so you both know a real key exists.

**Verify server-side that key storage actually grew** — re-run B1d and check `backed_up_keys`
increased and sits on a `deleted = 0` version:

```bash
psql "select version, deleted, (select count(*) from e2e_room_keys k
        where k.user_id=v.user_id and k.version=v.version) as keys
      from e2e_room_keys_versions v where v.user_id='$USER_ID' order by version;"
```

> **Gate:** do not continue to B3 until this number has stopped growing and the user confirms the
> recovery key is saved. This is the point of no return.

## B3. Reset the sessions

Devices here are **MAS sessions** — MAS owns their lifecycle and pushes create/delete/sync down to
Synapse (`/_synapse/mas/*`). So reset through MAS. Deleting a device straight from the Synapse admin
API while its MAS session is still alive can simply be re-synced back.

```bash
export MAS=deploy/matrix-stack-matrix-authentication-service

# 1) dry run — review what would be killed
kubectl exec -n $NS $MAS -c matrix-authentication-service -- \
  mas-cli manage kill-sessions --dry-run "$USER_LOCAL"

# 2) for real (this signs the user out everywhere, including the browser session)
kubectl exec -n $NS $MAS -c matrix-authentication-service -- \
  mas-cli manage kill-sessions "$USER_LOCAL"
```

Prefer the self-service route when only one or two bad sessions must go: the user signs them out
themselves (Part A, A5) and keeps their working session — no re-verification churn for anyone.

Verify the sessions are gone (signing-key rows must remain):

```bash
psql "select device_id, coalesce(display_name,'(no name)'), to_timestamp(last_seen/1000)
      from devices where user_id='$USER_ID'
        and coalesce(display_name,'') not like '%signing key';"
```

**Orphans only** — if a row survives with no matching MAS session, remove it via the admin API:

```bash
# admin token — issue it, use it, then kill it (see B5). Copy the token from the command output.
kubectl exec -n $NS $MAS -c matrix-authentication-service -- \
  mas-cli manage issue-compatibility-token --yes-i-want-to-grant-synapse-admin-privileges admin
export ADMIN_TOKEN=<token from the output above>

kubectl exec -n $NS matrix-stack-synapse-main-0 -c synapse -- \
  curl -sS -X POST "http://localhost:8008/_synapse/admin/v2/users/$USER_ID/delete_devices" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d '{"devices":["DEVICEID1","DEVICEID2"]}'
```

## B4. Cross-signing reset — only if the identity itself is broken

Symptoms: other members see the user as unverified / with a red shield even after the user re-verifies,
or the user cannot verify a new session against any old one and has no recovery key.

> **This is destructive in a way B3 is not.**
> - It mints a **new** cross-signing identity and a **new key storage version**. Keys still sitting only
>   in the *old* version become unreachable. B2 must have completed, and the user must have restored
>   and re-uploaded their keys, before doing this.
> - Every other member's client must re-verify this user. Expect a wave of "identity changed" warnings
>   in every shared room. Announce it in the team channel first.

Normally Element performs this reset behind an interactive auth prompt, which our MAS/Google-OIDC
setup cannot present. Open a 10-minute window instead:

```bash
kubectl exec -n $NS matrix-stack-synapse-main-0 -c synapse -- \
  curl -sS -X POST \
    "http://localhost:8008/_synapse/admin/v1/users/$USER_ID/_allow_cross_signing_replacement_without_uia" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -d '{}'
# -> {"updatable_without_uia_before_ms": <epoch ms>}   ≈ now + 10 min
```

Within that window the user goes to **Settings → Encryption → "Reset cryptographic identity"** and
confirms — this is the *only* circumstance in which anyone touches that button. Then B5 immediately,
and they re-verify each of their devices.

Afterwards, confirm a **new** identity was published — a fresh `master` row with a higher `stream_id`
than the one you saw in B1c:

```bash
psql "select keytype, stream_id, left(keydata, 55) from e2e_cross_signing_keys
      where user_id='$USER_ID' order by keytype, stream_id;"
```

## B5. Restore and verify

The user, on each device they want to keep, runs **A1 → A4** of Part A: log in, verify with the
recovery key (or by emoji against a device already restored), confirm key storage is on, and read an
old message. Older messages may take a minute while keys stream down from key storage.

If you issued an admin token in B3/B4, retire it now:

```bash
kubectl exec -n $NS $MAS -c matrix-authentication-service -- mas-cli manage kill-sessions admin
# this also signs the admin account's own clients out — expected
```

Server-side post-checks:

```bash
# expected sessions only, all recently seen — and re-run B1b: the kept sessions must show verified = t
psql "select device_id, coalesce(display_name,'(no name)'), to_timestamp(last_seen/1000)
      from devices where user_id='$USER_ID'
        and coalesce(display_name,'') not like '%signing key' order by last_seen desc nulls last;"

# current identity = highest stream_id per keytype (older rows are expected leftovers)
psql "select keytype, max(stream_id) from e2e_cross_signing_keys
      where user_id='$USER_ID' group by 1;"

# one active version, key count non-zero
psql "select version, deleted, (select count(*) from e2e_room_keys k
        where k.user_id=v.user_id and k.version=v.version) as keys
      from e2e_room_keys_versions v where v.user_id='$USER_ID' order by version;"
```

Done when: only expected sessions, all verified, active key storage populated, and the user confirms
old history renders on a **freshly logged-in** device — that last check is the only real proof.

## B6. Prevention

**Fleet audit** — this is the query that matters. `live_verified = 1` means that person's entire
history depends on one browser profile; `live_verified = 0` means they are locked out right now.

```bash
kubectl exec -i -n $NS "$PG" -c postgres -- psql -U postgres -d synapse <<'SQL'
with ssk as (
  select distinct on (user_id) user_id,
         split_part((select k from jsonb_object_keys((keydata::jsonb)->'keys') k limit 1),':',2) as ssk
  from e2e_cross_signing_keys where keytype='self_signing'
  order by user_id, stream_id desc),
dev as (
  select d.user_id, d.last_seen,
         (coalesce(dk.key_json like '%'||s.ssk||'%', false)
          or exists (select 1 from e2e_cross_signing_signatures g
                     where g.target_user_id=d.user_id and g.target_device_id=d.device_id
                       and g.key_id='ed25519:'||s.ssk)) as verified
  from devices d
  left join e2e_device_keys_json dk on dk.user_id=d.user_id and dk.device_id=d.device_id
  left join ssk s on s.user_id=d.user_id
  where coalesce(d.display_name,'') not like '%signing key'),
bk as (
  select v.user_id, (select count(*) from e2e_room_keys k
                     where k.user_id=v.user_id and k.version=v.version) as keys
  from e2e_room_keys_versions v where v.deleted=0),
rec as (   -- users who actually have a recovery key (secret storage configured)
  select distinct user_id from account_data
  where account_data_type='m.secret_storage.default_key')
select split_part(d.user_id,':',1) as "user",
       bool_or(r.user_id is not null)                                                  as has_recovery,
       count(*) filter (where d.last_seen > (extract(epoch from now())-30*86400)*1000) as live_30d,
       count(*) filter (where d.verified
                          and d.last_seen > (extract(epoch from now())-30*86400)*1000) as live_verified,
       count(*) filter (where d.last_seen is null)                                     as ghosts,
       coalesce(max(bk.keys),0)                                                        as backed_up_keys
from dev d left join bk on bk.user_id=d.user_id left join rec r on r.user_id=d.user_id
group by 1 order by has_recovery asc, live_verified asc, backed_up_keys desc;
SQL
```

Act on it like this:

| Column | Threshold | Action |
|---|---|---|
| `has_recovery` | `f` | **Highest priority.** No recovery key exists — losing their browser profile loses their history, with no recourse. Send them Part A, A3. A non-zero `backed_up_keys` does not help them. |
| `live_verified` | `0` | User is locked out of their own history right now. Open a ticket, run B1. |
| `live_verified` | `1` | Single point of failure. Nudge them to add a second device (Part A, "two habits"). |
| `ghosts` | `> 0` | Sessions that never came online, degrading decryption for everyone in shared rooms. Ask the owner to sign them out (A5). |
| `backed_up_keys` | `0` with live devices | Key storage never populated. Send Part A, A2. |

**Recovery-key hygiene** — the actual fix for "history on any device":

- Onboarding checklist item: run **Part A** on day one, key in the team password manager.
- Never-used sessions are not harmless — prune them.
- A user pressing "Reset cryptographic identity" on their own, without B2 first, is exactly how history
  gets lost. That is why Part A leads with the warning; point people there before they improvise.

**Open follow-up (not enabled by this runbook)**: Element Web supports `force_verification`, which
blocks an unverified session from being used at all. It makes Part A unavoidable — and it locks out
anyone who has lost their key, so enable it only once the fleet audit shows no `live_verified = 0`.
Decide deliberately before adding it to `communication/matrix/helmrelease.yaml`.

## Appendix — why the server cannot help

| Wish | Reality |
|---|---|
| "Just re-send the history to their new device from the DB" | Synapse holds ciphertext only. No plaintext, no keys. |
| "Admin-force-decrypt one room" | No such mechanism exists in Matrix, by design. |
| "Restore keys from the CNPG backup" | The backup restores the *encrypted* key storage blob. Useless without the user's recovery key. |
| "Delete devices via the Synapse admin API" | MAS owns device lifecycle here; kill the MAS session (B3) or it comes back. |
