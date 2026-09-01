# Runbook — Reset a user's Matrix devices without losing chat history

**Scope**: Matrix / ESS stack in `cnd-communication` (Synapse 1.150 + MAS 1.14 + Element Web 1.12.x).
**Use when**: a user reports "Unable to decrypt", endless "Verify this session" prompts, a red shield on
their own messages, or an unmanageable pile of old sessions.

---

## 0. The one rule

> **The server cannot decrypt anything and cannot recover a single message key.**

51 of our 57 rooms are end-to-end encrypted. Message keys live *only* in the clients and in the
user's **key backup**, which is itself encrypted with a **recovery key the server never sees**.

Therefore:

1. **Keys are preserved BEFORE sessions are killed.** Never the reverse — killing the last device that
   holds un-backed-up keys destroys that history permanently, for that user, on every future device.
2. **History "on any device" is only ever provided by key backup + recovery key.** There is no
   server-side alternative.
3. If the user has no working device *and* no recovery key, history in encrypted rooms **is already
   lost**. Say so explicitly and get their acknowledgement before proceeding (§1, Path B).

**Do not run this alongside**: a Synapse or MAS upgrade, or a CNPG failover.

---

## Prerequisites

```bash
export NS=cnd-communication
export USER_LOCAL=katia                                    # localpart, no @ and no domain
export USER_ID="@${USER_LOCAL}:matrix.cloudnativedays.fr"   # full MXID

# read-only DB access (any instance; reads are fine on a replica)
export PG=$(kubectl get pod -n $NS -l cnpg.io/cluster=cnpg-synapse -o name | head -1 | cut -d/ -f2)
psql() { kubectl exec -n $NS "$PG" -c postgres -- psql -U postgres -d synapse -c "$1"; }
```

---

## 1. Triage (read-only, safe)

### 1a. Real sessions vs. cross-signing pseudo-devices

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
| `last_seen` recent | live session | candidate **source of truth** for keys (§2) |
| `last_seen` months old | abandoned client | kill it |
| `last_seen` and `ip` both NULL | session provisioned but the client never came online | **kill it** — other members' clients still encrypt to it, which is a top cause of "unable to decrypt" |

### 1b. Cross-signing identity history

```bash
psql "select keytype, stream_id, left(keydata, 55) as keydata
      from e2e_cross_signing_keys where user_id='$USER_ID' order by keytype, stream_id;"
```

Synapse never deletes superseded cross-signing keys, so **the current identity is the row with the
highest `stream_id` per keytype** — extra rows are the history of past resets, not corruption in
themselves. One `master` row = the identity has never been reset. Several = it has, and any member
whose client is still pinned to an older `master` will see this user as unverified no matter how often
they re-verify. Only that symptom, reported by *other* people, justifies §4.

### 1c. Is the key backup usable?

```bash
psql "select v.version, v.deleted, count(k.session_id) as backed_up_keys
      from e2e_room_keys_versions v
      left join e2e_room_keys k on k.user_id=v.user_id and k.version=v.version
      where v.user_id='$USER_ID' group by 1,2 order by 1;"
```

Only the row with `deleted = 0` matters — keys under a deleted version are unreachable forever.
Compare `backed_up_keys` against the user's room count; a few hundred keys for someone in 20 rooms is
normal, single digits means the backup was never populated.

### 1d. Decision

| Condition | Path |
|---|---|
| At least one session is alive **and** the user can open Element on it | **A — safe reset** (§2 → §3 → §5) |
| No live session, but the user has their recovery key | **A'** — skip §2, go to §3, restore in §5 |
| No live session **and** no recovery key | **B — lossy reset**: history in encrypted rooms is gone. Get explicit acknowledgement in writing, then §3 → §5. The user re-joins with an empty backlog. |

---

## 2. Preserve the keys (user does this, on their healthy device)

Ask the user to do this **on the device from §1a with the most recent `last_seen`**, and to confirm
each step back to you before you touch anything.

1. Element → **Settings → Encryption**. (Labels below are verbatim from Element Web 1.12.13.)
2. **Key storage** section — the toggle **"Allow key storage"** must be ON.
   - Off → turn it on and let it upload; this is what puts the keys somewhere a future device can reach.
   - **"Your key storage is out of sync."** → click the offered fix button and wait for it to clear.
   - **"Failed to sync key storage. You need to reset your identity."** → the backup is unrecoverable
     from this device; treat the account as Path B / §4 and tell the user history will be lost.
3. **Recovery** section — click **"Set up recovery"** (or **"Change recovery key"** if recovery already
   exists but the key is lost). Element shows the key once, under *"Save your recovery key somewhere
   safe"*. The user **stores it in the team password manager right then** — not a sticky note, not a DM
   — and completes the *"Confirm your recovery key"* screen.
4. The user reads the first 4 characters back to you, so you both know a real key exists.

**Then verify server-side that the backup actually grew** — re-run §1c and check `backed_up_keys`
increased and is on a `deleted = 0` version:

```bash
psql "select version, deleted, (select count(*) from e2e_room_keys k
        where k.user_id=v.user_id and k.version=v.version) as keys
      from e2e_room_keys_versions v where v.user_id='$USER_ID' order by version;"
```

> **Gate:** do not continue to §3 until this number has stopped growing and the user confirms the
> recovery key is saved. This is the point of no return.

---

## 3. Reset the sessions

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

Self-service equivalent, if you would rather the user do it: they sign in at
**https://auth-matrix.cloudnativedays.fr/** and sign individual devices out from their own account
page — no admin needed, and it is the better option when only one bad session must go.

Verify the sessions are gone (signing-key rows must remain):

```bash
psql "select device_id, coalesce(display_name,'(no name)'), to_timestamp(last_seen/1000)
      from devices where user_id='$USER_ID'
        and coalesce(display_name,'') not like '%signing key';"
```

**Orphans only** — if a row survives with no matching MAS session, remove it via the admin API:

```bash
# admin token — issue it, use it, then kill it (see below). Copy the token from the command output.
kubectl exec -n $NS $MAS -c matrix-authentication-service -- \
  mas-cli manage issue-compatibility-token --yes-i-want-to-grant-synapse-admin-privileges admin
export ADMIN_TOKEN=<token from the output above>

kubectl exec -n $NS matrix-stack-synapse-main-0 -c synapse -- \
  curl -sS -X POST "http://localhost:8008/_synapse/admin/v2/users/$USER_ID/delete_devices" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d '{"devices":["DEVICEID1","DEVICEID2"]}'
```

---

## 4. Cross-signing reset — only if the identity itself is broken

Symptoms: §1b shows `master >= 2`, or other members see the user as "unverified" / with a red shield
even after the user re-verifies, or the user cannot verify a new session against any old one.

> **This is destructive in a way §3 is not.**
> - It mints a **new** cross-signing identity and a **new key backup version**. Keys still sitting only
>   in the *old* backup become unreachable. §2 must have completed, and the user must have restored
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

Within that window the user goes to **Settings → Encryption → Reset cryptographic identity** and
confirms. Then §5 immediately, and they re-verify each of their devices.

Afterwards, confirm a **new** identity was published — a fresh `master` row with a higher
`stream_id` than the one you saw in §1b:

```bash
psql "select keytype, stream_id, left(keydata, 55) from e2e_cross_signing_keys
      where user_id='$USER_ID' order by keytype, stream_id;"
```

---

## 5. Restore and verify

The user, on each device they want to keep:

1. Log in at **https://chat.cloudnativedays.fr** via Google.
2. At **"Verify this device"** choose the recovery-key option and paste the key from §2 at
   **"Enter recovery key"** — or verify by emoji against a device already restored. Either path
   unlocks key storage.
3. Settings → Encryption → **"Allow key storage"** is on, no "out of sync" banner, session verified.
4. Open the **oldest** encrypted room they care about and scroll back. Older messages may take a minute
   while keys stream down from key storage.
5. If you issued an admin token in §3/§4, retire it now:
   `kubectl exec -n $NS $MAS -c matrix-authentication-service -- mas-cli manage kill-sessions admin`
   (this also signs the `admin` account's own clients out — expected).

Server-side post-checks:

```bash
# expected sessions only, all recently seen
psql "select device_id, coalesce(display_name,'(no name)'), to_timestamp(last_seen/1000)
      from devices where user_id='$USER_ID'
        and coalesce(display_name,'') not like '%signing key' order by last_seen desc nulls last;"

# current identity = highest stream_id per keytype (older rows are expected leftovers)
psql "select keytype, max(stream_id) from e2e_cross_signing_keys
      where user_id='$USER_ID' group by 1;"

# one active backup version, key count non-zero
psql "select version, deleted, (select count(*) from e2e_room_keys k
        where k.user_id=v.user_id and k.version=v.version) as keys
      from e2e_room_keys_versions v where v.user_id='$USER_ID' order by version;"
```

Done when: only expected sessions, active backup populated, and the user confirms old
history renders on a **freshly logged-in** device — that last check is the only real proof.

---

## 6. Prevention

**Fleet-wide audit** — run periodically; the accounts at the top of this list are the next tickets:

```bash
psql "select d.user_id,
        count(*) filter (where coalesce(d.display_name,'') not like '%signing key') as sessions,
        count(*) filter (where d.last_seen is null
          and coalesce(d.display_name,'') not like '%signing key')                  as never_used,
        count(*) filter (where d.display_name = 'master signing key')               as identity_resets
      from devices d group by 1 having count(*) > 4 order by 2 desc;"
```

**Recovery-key hygiene** (the actual fix for "history on any device"):

- Onboarding checklist item: set up Recovery and store the recovery key in the team password manager
  on day one. Without it, every device reset is a coin flip.
- Never-used sessions are not harmless — they degrade decryption for *everyone* in the room. Prune them.
- A user resetting their own identity from the Element UI without doing §2 first is exactly how history
  gets lost. Point people at this runbook before they click "Reset".

**Open follow-up (not enabled by this runbook)**: Element Web supports `force_verification`, which
blocks an unverified session from being used at all. It makes the recovery-key setup unavoidable —
and it locks out anyone who has lost their key. Decide deliberately before adding it to
`communication/matrix/helmrelease.yaml`.

---

## Appendix — why the server cannot help

| Wish | Reality |
|---|---|
| "Just re-send the history to their new device from the DB" | Synapse holds ciphertext only. No plaintext, no keys. |
| "Admin-force-decrypt one room" | No such mechanism exists in Matrix, by design. |
| "Restore keys from the CNPG backup" | The backup restores the *encrypted* key backup blob. Useless without the user's recovery key. |
| "Delete devices via the Synapse admin API" | MAS owns device lifecycle here; kill the MAS session (§3) or it comes back. |
