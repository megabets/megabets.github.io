---
name: invite-code
description: Mint, list, or revoke malakabet invite codes. Generates a memorable code, hashes it (SHA-256, the same normalization register_player uses server-side), and produces the paste-ready SQL for the Supabase `invites` table — so you never run sha256sum by hand. Use when the user says "new invite code", "make an invite", "another code", "add invite codes", or "revoke/remove an invite code".
---

# Minting malakabet invite codes

Invite codes gate first-time registration. Since the lockdown they live in the
Supabase `invites` table (hash + label only, never the plaintext) and are
verified server-side by `rpc/register_player` — nothing ships in index.html,
so no git commit or Pages deploy is needed: a code works the moment the SQL
runs in the Supabase SQL editor.

## Mint a new code (default)
1. Run the helper (optionally pass a specific code as `$1`):
   `bash .claude/skills/invite-code/mint.sh`           # random code
   `bash .claude/skills/invite-code/mint.sh WC26-FOO`  # specific code
   It prints `CODE=...` and `HASH=...`.
2. Give the user a paste-ready statement for the Supabase SQL editor:
   ```sql
   insert into invites (hash, label)
   values ('<HASH>', 'minted <today YYYY-MM-DD>')
   on conflict do nothing;
   ```
   NEVER put the plaintext CODE in the label — admins may screen-share the table.
3. Tell the user the plaintext **CODE** to hand out.

## Mint several
Repeat step 1 N times, then emit ONE insert with multiple value rows;
report the plaintext codes as a list.

## Revoke a code
1. `bash .claude/skills/invite-code/mint.sh <THE-CODE>` to recover its HASH
   (or have the user pick by label via the List query below).
2. ```sql
   update invites set revoked_at = now() where hash = '<HASH>';
   ```
   (Soft revoke — keeps the row for the record. `delete` works too.)

## List active codes
```sql
select label, created_at, revoked_at from invites order by created_at;
```

## Notes
- The helper normalizes exactly like `register_player()`: trim surrounding
  whitespace, upper-case, then SHA-256. So codes are case-insensitive.
- Keep at least one unrevoked row in `invites`, or nobody can register.
- Invalid-code attempts are throttled server-side (20 fails → 10-min lock,
  shared key 'invite' in `login_attempts`).
