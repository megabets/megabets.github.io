#!/usr/bin/env bash
# Mint or hash a malakabet invite code. Mirrors hashInvite() in index.html.
#   mint.sh           -> random memorable code (WC26-XXXXX), prints CODE + HASH
#   mint.sh WC26-FOO  -> hash the given code, prints CODE + HASH
set -euo pipefail
raw="${1:-}"
if [ -z "$raw" ]; then
  # Read a finite chunk (head exits cleanly), filter to an unambiguous charset
  # (no 0/O/1/I), then slice 5 chars in bash — avoids the pipefail+SIGPIPE that
  # `tr </dev/urandom | head` triggers.
  bytes=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789')
  raw="WC26-${bytes:0:5}"
fi
# normalize like hashInvite(): trim outer whitespace, then upper-case
code=$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]')
hash=$(printf '%s' "$code" | sha256sum | awk '{print $1}')
printf 'CODE=%s\nHASH=%s\n' "$code" "$hash"
