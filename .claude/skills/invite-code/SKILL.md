---
name: invite-code
description: Mint, list, or revoke malakabet invite codes. Generates a memorable code, hashes it (SHA-256, the same normalization as hashInvite in index.html), and edits the INVITE_HASHES array — so you never run sha256sum by hand. Use when the user says "new invite code", "make an invite", "another code", "add invite codes", or "revoke/remove an invite code".
---

# Minting malakabet invite codes

Invite codes gate first-time registration. `index.html` stores only the SHA-256
of each code in `const INVITE_HASHES = [ ... ]`. This skill edits that array.

## Mint a new code (default)
1. Run the helper (optionally pass a specific code as `$1`):
   `bash .claude/skills/invite-code/mint.sh`           # random code
   `bash .claude/skills/invite-code/mint.sh WC26-FOO`  # specific code
   It prints `CODE=...` and `HASH=...`.
2. In `index.html`, add a new line inside the `INVITE_HASHES = [ ... ]` array:
   `  "<HASH>", // minted <today's date YYYY-MM-DD>`
   NEVER put the plaintext CODE in the comment — it's a public file.
3. Tell the user the plaintext **CODE** to hand out, and remind them to
   `git commit` + push so GitHub Pages serves it. Do not commit unless asked.

## Mint several
Repeat the steps N times, collecting each CODE; report them as a list.

## Revoke a code
1. `bash .claude/skills/invite-code/mint.sh <THE-CODE>` to recover its HASH.
2. Remove the line whose hash matches from `INVITE_HASHES` in `index.html`.
3. Confirm which one was removed (by date label, never the plaintext).

## Notes
- The helper normalizes exactly like `hashInvite()`: trim surrounding
  whitespace, upper-case, then SHA-256. So codes are case-insensitive.
- Always keep at least one hash in the array, or nobody can register.
