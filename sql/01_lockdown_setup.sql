-- megabets lockdown — STEP 1 of 2 (additive; safe to run while the old app is live).
-- Run this whole file in Supabase → SQL Editor → New query → Run.
--
-- Credential model: the app has no Supabase Auth. pin_hash — SHA-256("nick:pin")
-- computed in the browser by hashPin() — doubles as a bearer credential, stored
-- in localStorage as me.auth and passed to every RPC as (p_player, p_auth).
-- It is a low-entropy, non-rotatable secret — deterrent-grade by design — but
-- strictly better than the old model where pin_hash was readable by anyone
-- holding the anon key and every table was writable with it.
--
-- This file only ADDS tables and functions; nothing loses access yet. Run
-- sql/02_lockdown_enforce.sql to revoke the old open access, AFTER the new
-- index.html is deployed and verified.

create extension if not exists pgcrypto with schema extensions;

-- ── Tables (no policies + revoked grants → invisible to the anon key; only
--    the SECURITY DEFINER functions below can touch them) ────────────────────

-- Invite codes. Only the SHA-256 of upper(trim(code)) is stored — the same
-- normalization the invite-code skill's mint.sh uses. revoked_at null = active.
-- register_player() checks codes server-side; they no longer ship in index.html.
create table if not exists public.invites (
  hash       text primary key,
  label      text,                         -- e.g. 'minted 2026-06-08' — never the plaintext
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);
alter table public.invites enable row level security;
revoke all on table public.invites from anon, authenticated;

-- Seed with the codes previously hardcoded in index.html's INVITE_HASHES.
insert into public.invites (hash, label) values
  ('d287bc1ddabd7061431059e42910395864df27239c8d6d1416fa59f34bf73eef', 'minted 2026-06-08'),
  ('ebe7a7fb1cd6740ed29486e32b05a39a5551ae9ff1cf3b5d07120ee9e5d2c92e', 'minted 2026-06-08'),
  ('12a7cff00a2d4279deddb037a9b9614e3277ea4af7d8003c1f218ae1a2c48001', 'WC2026 — minted 2026-06-09')
on conflict do nothing;

-- Brute-force throttle. A 4–6 digit PIN is only ~1M hash candidates, so
-- unthrottled online guessing (via login_player OR any credential-checked RPC)
-- would crack one in hours. Keys: 'login:<nick>', 'auth:<player uuid>', 'invite'.
-- If a friend gets griefed into a lockout, delete their row here in the editor.
create table if not exists public.login_attempts (
  key          text primary key,
  fails        int not null default 0,
  locked_until timestamptz
);
alter table public.login_attempts enable row level security;
revoke all on table public.login_attempts from anon, authenticated;

-- ── Internal helpers (NOT callable via the API — execute revoked) ───────────

create or replace function public.throttle_check(p_key text)
returns void
language plpgsql security definer set search_path = public
as $$
declare t timestamptz;
begin
  select locked_until into t from login_attempts where key = p_key;
  if t is not null and t > now() then
    raise exception 'too many attempts — try again in a few minutes' using errcode = 'PT429';
  end if;
end; $$;
revoke execute on function public.throttle_check(text) from public, anon, authenticated;

create or replace function public.throttle_fail(p_key text, p_max int, p_lock interval)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  insert into login_attempts as la (key, fails) values (p_key, 1)
  on conflict (key) do update set
    fails        = case when la.fails + 1 >= p_max then 0 else la.fails + 1 end,
    locked_until = case when la.fails + 1 >= p_max then now() + p_lock else la.locked_until end;
end; $$;
revoke execute on function public.throttle_fail(text, int, interval) from public, anon, authenticated;

create or replace function public.throttle_clear(p_key text)
returns void
language sql security definer set search_path = public
as $$
  delete from login_attempts where key = p_key;
$$;
revoke execute on function public.throttle_clear(text) from public, anon, authenticated;

-- Credential check shared by every player-facing RPC. Returns the caller's
-- canonical nickname or raises 401 (PostgREST maps errcode PTxxx → HTTP xxx).
create or replace function public.auth_player(p_player uuid, p_auth text)
returns text
language plpgsql security definer set search_path = public
as $$
declare nick text; tkey text := 'auth:' || p_player;
begin
  perform throttle_check(tkey);
  select p.nickname into nick from players p
   where p.id = p_player and p.pin_hash is not null and p.pin_hash = p_auth;
  if nick is null then
    perform throttle_fail(tkey, 8, interval '15 minutes');
    raise exception 'invalid credentials' using errcode = 'PT401';
  end if;
  perform throttle_clear(tkey);
  return nick;
end; $$;
revoke execute on function public.auth_player(uuid, text) from public, anon, authenticated;

-- Admin gate: same credential check, then nickname must be the organizer.
create or replace function public.auth_admin(p_player uuid, p_auth text)
returns text
language plpgsql security definer set search_path = public
as $$
declare nick text;
begin
  nick := auth_player(p_player, p_auth);
  if lower(nick) <> 'trololoic' then
    raise exception 'not allowed' using errcode = 'PT403';
  end if;
  return nick;
end; $$;
revoke execute on function public.auth_admin(uuid, text) from public, anon, authenticated;

-- ── Login + registration ────────────────────────────────────────────────────

-- Server-side login: returns a status instead of leaking pin_hash.
--   ok        → credentials match, log straight in
--   wrong_pin → claimed nickname, wrong PIN
--   unclaimed → legacy player without a PIN yet (claim flow)
--   new       → nickname not taken (registration flow)
create or replace function public.login_player(p_nickname text, p_pin_hash text)
returns table (status text, id uuid, nickname text)
language plpgsql security definer set search_path = public
as $$
declare pl players; tkey text := 'login:' || lower(p_nickname);  -- NB: OUT cols shadow table cols; qualify refs as p.*
begin
  perform throttle_check(tkey);
  select p.* into pl from players p where p.nickname = p_nickname;
  if not found then
    return query select 'new'::text, null::uuid, null::text;
  elsif pl.pin_hash is null then
    return query select 'unclaimed'::text, pl.id, pl.nickname;
  elsif pl.pin_hash = p_pin_hash then
    perform throttle_clear(tkey);
    return query select 'ok'::text, pl.id, pl.nickname;
  else
    perform throttle_fail(tkey, 8, interval '15 minutes');
    perform pg_sleep(0.3);  -- mild extra online brute-force friction
    return query select 'wrong_pin'::text, null::uuid, null::text;
  end if;
end; $$;
revoke execute on function public.login_player(text, text) from public;
grant execute on function public.login_player(text, text) to anon, authenticated;

-- Registration / legacy claim: the invite code is verified HERE, server-side
-- (the plaintext code is sent over TLS; only its hash is compared). Handles
-- both a brand-new nickname and claiming a pre-seeded PIN-less one. Direct
-- INSERT/UPDATE on players is revoked in sql/02.
create or replace function public.register_player(p_nickname text, p_pin_hash text, p_invite text)
returns table (id uuid, nickname text)
language plpgsql security definer set search_path = public, extensions
as $$
declare pl players; ihash text; nick text := trim(p_nickname);
begin
  if length(nick) < 2 then
    raise exception 'pick at least 2 characters' using errcode = 'PT400';
  end if;
  perform throttle_check('invite');
  ihash := encode(digest(upper(trim(p_invite)), 'sha256'), 'hex');
  if not exists (select 1 from invites i where i.hash = ihash and i.revoked_at is null) then
    perform throttle_fail('invite', 20, interval '10 minutes');
    raise exception 'invalid invite code' using errcode = 'PT403';
  end if;
  select p.* into pl from players p where p.nickname = nick;
  if pl.id is not null and pl.pin_hash is not null then
    raise exception 'nickname taken' using errcode = 'PT409';
  end if;
  if pl.id is not null then
    -- one-time claim — same guarantee the old "claim pin" policy gave:
    -- a set PIN can never be overwritten through the public API
    update players p set pin_hash = p_pin_hash where p.id = pl.id and p.pin_hash is null;
    return query select pl.id, pl.nickname;
  else
    return query insert into players (nickname, pin_hash)
      values (nick, p_pin_hash) returning players.id, players.nickname;
  end if;
end; $$;
revoke execute on function public.register_player(text, text, text) from public;
grant execute on function public.register_player(text, text, text) to anon, authenticated;

-- ── Predictions ─────────────────────────────────────────────────────────────
-- Public SELECT on the table only exposes kicked-off matches (policy in
-- sql/02), which is all the standings need. Your own bets — including future
-- ones — come through preds_fetch.

create or replace function public.preds_fetch(p_player uuid, p_auth text)
returns table (match_id bigint, pred_home int, pred_away int)
language plpgsql security definer set search_path = public
as $$
begin
  perform auth_player(p_player, p_auth);
  return query select pr.match_id, pr.pred_home, pr.pred_away
    from predictions pr where pr.player_id = p_player;
end; $$;

-- Upsert bets for the CALLER only; matches that already kicked off are
-- silently skipped (server-enforced bet lock — the old model trusted the
-- browser for this). Returns rows written.
-- p_preds: [{"match_id":123,"pred_home":1,"pred_away":0}, ...]
create or replace function public.preds_save(p_player uuid, p_auth text, p_preds jsonb)
returns int
language plpgsql security definer set search_path = public
as $$
declare r jsonb; n int := 0;
begin
  perform auth_player(p_player, p_auth);
  for r in select * from jsonb_array_elements(p_preds) loop
    if exists (select 1 from matches m
                where m.id = (r->>'match_id')::bigint and m.kickoff > now()) then
      insert into predictions (player_id, match_id, pred_home, pred_away)
      values (p_player, (r->>'match_id')::bigint,
              least(greatest((r->>'pred_home')::int, 0), 30),
              least(greatest((r->>'pred_away')::int, 0), 30))
      on conflict (player_id, match_id) do update
        set pred_home = excluded.pred_home,
            pred_away = excluded.pred_away,
            submitted_at = now();
      n := n + 1;
    end if;
  end loop;
  return n;
end; $$;

revoke execute on function public.preds_fetch(uuid, text) from public;
revoke execute on function public.preds_save(uuid, text, jsonb) from public;
grant execute on function public.preds_fetch(uuid, text)        to anon, authenticated;
grant execute on function public.preds_save(uuid, text, jsonb)  to anon, authenticated;

-- ── Chat ────────────────────────────────────────────────────────────────────
-- Chat is login-only in BOTH directions: reads and writes go through these
-- RPCs; the anon key gets no direct grants on messages (sql/02).

-- Chat read: full load (newest 200, ascending) or incremental (> p_since).
create or replace function public.chat_fetch(p_player uuid, p_auth text, p_since timestamptz default null)
returns setof public.messages
language plpgsql security definer set search_path = public
as $$
begin
  perform auth_player(p_player, p_auth);
  if p_since is null then
    return query select * from (
      select * from messages order by created_at desc limit 200
    ) latest order by created_at asc;
  else
    return query select * from messages where created_at > p_since order by created_at asc;
  end if;
end; $$;

-- Chat post: nickname is server-derived from the players row, so a forged
-- body can no longer spoof another player's name. The 420-char check
-- constraint and the trim_messages() retention trigger still apply (the
-- trigger now runs as the function owner, which bypasses RLS — fine, since
-- direct anon inserts are revoked).
create or replace function public.chat_post(p_player uuid, p_auth text, p_text text)
returns void
language plpgsql security definer set search_path = public
as $$
declare nick text; t text := nullif(trim(p_text), '');
begin
  nick := auth_player(p_player, p_auth);
  if t is null then raise exception 'empty message' using errcode = 'PT400'; end if;
  insert into messages (player_id, nickname, text) values (p_player, nick, t);
end; $$;

-- Chat delete: admin only, enforced server-side.
create or replace function public.chat_delete(p_player uuid, p_auth text, p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform auth_admin(p_player, p_auth);
  delete from messages where id = p_id;
end; $$;

revoke execute on function public.chat_fetch(uuid, text, timestamptz) from public;
revoke execute on function public.chat_post(uuid, text, text) from public;
revoke execute on function public.chat_delete(uuid, text, uuid) from public;
grant execute on function public.chat_fetch(uuid, text, timestamptz) to anon, authenticated;
grant execute on function public.chat_post(uuid, text, text)         to anon, authenticated;
grant execute on function public.chat_delete(uuid, text, uuid)       to anon, authenticated;

-- ── Payments (admin only, both directions) ──────────────────────────────────

create or replace function public.payments_fetch(p_player uuid, p_auth text)
returns table (player_id uuid, paid boolean)
language plpgsql security definer set search_path = public
as $$
begin
  perform auth_admin(p_player, p_auth);
  return query select pay.player_id, pay.paid from payments pay;
end; $$;

-- p_rows: [{"player_id":"<uuid>","paid":true}, ...]
create or replace function public.payments_save(p_player uuid, p_auth text, p_rows jsonb)
returns void
language plpgsql security definer set search_path = public
as $$
declare r jsonb;
begin
  perform auth_admin(p_player, p_auth);
  for r in select * from jsonb_array_elements(p_rows) loop
    insert into payments (player_id, paid, updated_at)
    values ((r->>'player_id')::uuid, (r->>'paid')::boolean, now())
    on conflict (player_id) do update
      set paid = excluded.paid, updated_at = now();
  end loop;
end; $$;

revoke execute on function public.payments_fetch(uuid, text) from public;
revoke execute on function public.payments_save(uuid, text, jsonb) from public;
grant execute on function public.payments_fetch(uuid, text)       to anon, authenticated;
grant execute on function public.payments_save(uuid, text, jsonb) to anon, authenticated;

-- ── Notices (popups): recipient-only read, admin-only manage ────────────────

-- The caller's own popups (boot check).
create or replace function public.notices_fetch(p_player uuid, p_auth text)
returns setof public.notices
language plpgsql security definer set search_path = public
as $$
declare nick text;
begin
  nick := auth_player(p_player, p_auth);
  return query select * from notices
    where to_nick = lower(nick) order by created_at asc;
end; $$;

-- Admin: all active popups, or one user's (manage panel / "/alerts").
create or replace function public.notices_list(p_player uuid, p_auth text, p_to_nick text default null)
returns setof public.notices
language plpgsql security definer set search_path = public
as $$
begin
  perform auth_admin(p_player, p_auth);
  return query select * from notices
    where p_to_nick is null or to_nick = lower(trim(p_to_nick))
    order by created_at desc;
end; $$;

create or replace function public.notices_send(p_player uuid, p_auth text, p_to_nick text, p_body text)
returns void
language plpgsql security definer set search_path = public
as $$
declare b text := nullif(trim(p_body), '');
begin
  perform auth_admin(p_player, p_auth);
  if b is null then raise exception 'empty message' using errcode = 'PT400'; end if;
  insert into notices (to_nick, body) values (lower(trim(p_to_nick)), b);
end; $$;

create or replace function public.notices_delete(p_player uuid, p_auth text, p_id bigint)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform auth_admin(p_player, p_auth);
  delete from notices where id = p_id;
end; $$;

revoke execute on function public.notices_fetch(uuid, text) from public;
revoke execute on function public.notices_list(uuid, text, text) from public;
revoke execute on function public.notices_send(uuid, text, text, text) from public;
revoke execute on function public.notices_delete(uuid, text, bigint) from public;
grant execute on function public.notices_fetch(uuid, text)             to anon, authenticated;
grant execute on function public.notices_list(uuid, text, text)        to anon, authenticated;
grant execute on function public.notices_send(uuid, text, text, text)  to anon, authenticated;
grant execute on function public.notices_delete(uuid, text, bigint)    to anon, authenticated;

-- Make PostgREST pick up the new functions immediately.
notify pgrst, 'reload schema';
