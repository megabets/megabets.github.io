-- World Cup 2026 Friends League — Supabase schema
-- Fresh install: run this file, then notices_table.sql, then
-- sql/01_lockdown_setup.sql (invites, throttle, all RPC functions).
-- The policies/grants below already match the locked-down end state, so
-- sql/02_lockdown_enforce.sql is only needed when MIGRATING a project that
-- still has the old open policies (deploy order documented in that file).

-- ── Tables ───────────────────────────────────────────────
create table players (
  id uuid primary key default gen_random_uuid(),
  nickname text unique not null,
  pin_hash text,                   -- SHA-256(nickname:pin); null = not yet claimed
  created_at timestamptz default now()
);

create table matches (
  id bigint primary key,           -- football-data.org match id
  stage text not null,             -- 'MD1','MD2','MD3','R32','R16','QF','SF','3RD','FINAL'
  home_team text not null,
  away_team text not null,
  kickoff timestamptz not null,
  home_score int,                  -- null until played
  away_score int,
  status text default 'SCHEDULED'
);

create table predictions (
  id uuid primary key default gen_random_uuid(),
  player_id uuid references players(id) on delete cascade,
  match_id bigint references matches(id) on delete cascade,
  pred_home int not null,
  pred_away int not null,
  submitted_at timestamptz default now(),
  unique (player_id, match_id)
);

-- Easter-egg / manual point awards (e.g. the "whose hips" secret). One row per
-- (player, kind); the point VALUE lives client-side, so a spammed insert can at
-- most add one extra fixed bonus per player — see BONUS_PTS in index.html.
create table bonuses (
  id uuid primary key default gen_random_uuid(),
  player_id uuid references players(id) on delete cascade,
  kind text not null,              -- e.g. 'shakira'
  created_at timestamptz default now(),
  unique (player_id, kind)
);

-- Who has paid the buy-in. Admin-only in BOTH directions, enforced
-- server-side: access goes through payments_fetch / payments_save
-- (sql/01_lockdown_setup.sql), which verify the organizer's credential.
create table payments (
  player_id uuid primary key references players(id) on delete cascade,
  paid boolean not null default false,
  updated_at timestamptz default now()
);

-- Group chat. `nickname` is denormalized so the poll doesn't join on players.
-- NOT publicly reachable: the anon key has no direct grants on this table.
-- All reads/writes go through the chat_fetch / chat_post / chat_delete RPCs
-- (sql/01_lockdown_setup.sql), which verify the caller's (player_id, pin_hash)
-- server-side. Deleting is admin-only ('trololoic'), enforced in chat_delete.
create table messages (
  id uuid primary key default gen_random_uuid(),
  player_id uuid references players(id) on delete cascade,
  nickname text not null,
  text text not null check (char_length(text) <= 420),  -- mirror the UI cap
  created_at timestamptz default now()
);
create index messages_created_idx on messages (created_at);

-- Retention: keep only the newest 500 messages so the table can't grow unbounded
-- (caps storage even against an insert flood). Runs once per insert statement.
create or replace function trim_messages() returns trigger
language plpgsql as $$
begin
  delete from messages where id in (
    select id from messages order by created_at desc offset 500
  );
  return null;
end;
$$;
create trigger trim_messages_after_insert
  after insert on messages
  for each statement execute function trim_messages();

-- ── Row Level Security ───────────────────────────────────
-- The anon key is read-only, and only for genuinely public data. EVERY write
-- — and every private read (own future bets, payments, popups, chat) — goes
-- through the SECURITY DEFINER RPCs in sql/01_lockdown_setup.sql, which verify
-- the caller's (player_id, pin_hash) credential server-side.
alter table players enable row level security;
alter table matches enable row level security;
alter table predictions enable row level security;
alter table bonuses enable row level security;
alter table payments enable row level security;
alter table messages enable row level security;

-- Public reads (friends league): who plays, the fixtures, claimed bonuses.
create policy "read players"     on players     for select using (true);
create policy "read matches"     on matches     for select using (true);
create policy "read bonuses"     on bonuses     for select using (true);

-- Others' bets stay hidden until the match kicks off (no peeking via dev
-- tools); this is also exactly the set of rows that can score, so the
-- standings query needs nothing else. Own future bets: rpc/preds_fetch.
create policy "read kicked-off predictions" on predictions for select
  using (exists (select 1 from matches m
                  where m.id = match_id and m.kickoff <= now()));

-- pin_hash is hidden via COLUMN-level grants (the row policy above stays —
-- policies gate rows, grants gate columns; both apply). PIN verification
-- happens server-side in login_player(); the browser never reads pin_hash,
-- so a 4–6 digit PIN can't be brute-forced offline against a dumped hash.
-- ⚠ Consequence: `players?select=*` (or an insert without `?select=col,...`
-- under the default Prefer: return=representation) fails with 42501 —
-- always list columns explicitly when touching players from the client.
revoke select, insert, update, delete on table players from anon, authenticated;
grant select (id, nickname, created_at) on table players to anon, authenticated;

-- Direct writes are revoked everywhere — these tables have NO insert/update/
-- delete policies on purpose. The RPC layer (sql/01) is the only write path:
--   players      → register_player (invite-code-checked, one-time PIN claim)
--   predictions  → preds_save      (own bets only, kicked-off matches refused)
--   messages     → chat_post / chat_delete (no grants at all: chat is login-only)
--   payments     → payments_save   (admin only; reads admin-only too)
--   notices      → notices_send / notices_delete (admin), notices_fetch (recipient)
revoke insert, update, delete on table predictions from anon, authenticated;
revoke all on table messages from anon, authenticated;
revoke all on table payments from anon, authenticated;

-- ── Admin write model (SERVICE-KEY ONLY) ─────────────────
-- Matches are written ONLY by GitHub Actions using the SERVICE key, which
-- bypasses RLS. So `matches` has NO public write policy — intentionally.
--   • scheduled scores  → .github/workflows/fetch-scores.yml (seed_matches.py)
--   • manual overrides  → .github/workflows/set-result.yml  (set_result.py)
-- The service_role key lives only in GitHub Actions secrets — never in the
-- browser or this repo. The public anon key therefore CANNOT write scores.
--
-- Do NOT add a public update policy like the one below: on a public site it
-- would let anyone holding the (public) anon key tamper with match scores.
--   create policy "update matches" on matches for update using (true);  -- ⚠ insecure, leave off

-- ── Migrating an EXISTING pre-lockdown project ───────────
-- Don't re-run this file. Instead run, in order (details + rollback inside):
--   1. sql/01_lockdown_setup.sql   (additive: invites, throttle, RPC functions)
--   2. deploy the matching index.html
--   3. sql/02_lockdown_enforce.sql (revokes the old open policies/grants)
-- The pre-lockdown per-feature migration blocks that used to live at the
-- bottom of this file (PINs, bonuses, payments, messages) are superseded —
-- see git history if you ever need them.
