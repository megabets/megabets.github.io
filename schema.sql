-- World Cup 2026 Friends League — Supabase schema
-- Run this in Supabase -> SQL Editor (New query) once, on a fresh project.

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

-- Who has paid the buy-in. Kept in its own table (not a column on players) so the
-- public anon key can toggle `paid` without an "update players" policy that would
-- also expose pin_hash. Hidden behind a 5-tap footer gesture; only the organizer
-- (nickname 'trololoic') edits it in the UI — a client-side deterrent, like PINs.
create table payments (
  player_id uuid primary key references players(id) on delete cascade,
  paid boolean not null default false,
  updated_at timestamptz default now()
);

-- Group chat. `nickname` is denormalized so the poll doesn't join on players.
-- Anyone can post or delete (open RLS); the UI gates deleting to 'trololoic'
-- — a client-side deterrent, like the PIN and Paid-column gates.
create table messages (
  id uuid primary key default gen_random_uuid(),
  player_id uuid references players(id) on delete cascade,
  nickname text not null,
  text text not null,
  created_at timestamptz default now()
);
create index messages_created_idx on messages (created_at);

-- ── Row Level Security ───────────────────────────────────
alter table players enable row level security;
alter table matches enable row level security;
alter table predictions enable row level security;
alter table bonuses enable row level security;
alter table payments enable row level security;
alter table messages enable row level security;

-- Everyone can read (public league)
create policy "read players"     on players     for select using (true);
create policy "read matches"     on matches     for select using (true);
create policy "read predictions" on predictions for select using (true);
create policy "read bonuses"     on bonuses     for select using (true);
create policy "read payments"    on payments    for select using (true);
create policy "read messages"    on messages    for select using (true);

-- Anyone can create a player and submit/update their own predictions
create policy "insert players"   on players     for insert with check (true);
create policy "insert preds"     on predictions for insert with check (true);
create policy "update preds"     on predictions for update using (true);
-- Anyone can claim a bonus; unique(player_id,kind) caps it at one per kind.
create policy "insert bonuses"   on bonuses     for insert with check (true);
-- Anyone can upsert a payment row; the UI gates editing to 'trololoic'.
create policy "insert payments"  on payments    for insert with check (true);
create policy "update payments"  on payments    for update using (true);
-- Anyone can post or delete a message; the UI gates deleting to 'trololoic'.
create policy "insert messages"  on messages    for insert with check (true);
create policy "delete messages"  on messages    for delete using (true);

-- A player's PIN may be set only while it is unclaimed (pin_hash is null).
-- Once set, the anon key can no longer change it — so a nickname can't be
-- re-PINned by someone else. (Client-side deterrent: the PIN is checked in the
-- browser; this policy just keeps a claimed PIN from being overwritten.)
create policy "claim pin"        on players     for update using (pin_hash is null) with check (true);

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

-- ── Migration: add PINs to an EXISTING project ───────────
-- The block above is the fresh-install schema. If your project already has the
-- players table, run THIS in the Supabase SQL Editor instead (idempotent):
--   alter table players add column if not exists pin_hash text;
--   create policy "claim pin" on players for update using (pin_hash is null) with check (true);
-- Existing PIN-less players keep pin_hash = null and claim a PIN on next login.

-- ── Migration: add bonuses to an EXISTING project ────────
-- Idempotent — run in the Supabase SQL Editor if `bonuses` doesn't exist yet:
--   create table if not exists bonuses (
--     id uuid primary key default gen_random_uuid(),
--     player_id uuid references players(id) on delete cascade,
--     kind text not null,
--     created_at timestamptz default now(),
--     unique (player_id, kind)
--   );
--   alter table bonuses enable row level security;
--   drop policy if exists "read bonuses"   on bonuses;
--   drop policy if exists "insert bonuses" on bonuses;
--   create policy "read bonuses"   on bonuses for select using (true);
--   create policy "insert bonuses" on bonuses for insert with check (true);

-- ── Migration: add payments to an EXISTING project ───────
-- Idempotent — run in the Supabase SQL Editor if `payments` doesn't exist yet:
--   create table if not exists payments (
--     player_id uuid primary key references players(id) on delete cascade,
--     paid boolean not null default false,
--     updated_at timestamptz default now()
--   );
--   alter table payments enable row level security;
--   drop policy if exists "read payments"   on payments;
--   drop policy if exists "insert payments" on payments;
--   drop policy if exists "update payments" on payments;
--   create policy "read payments"   on payments for select using (true);
--   create policy "insert payments" on payments for insert with check (true);
--   create policy "update payments" on payments for update using (true);

-- ── Migration: add messages (chat) to an EXISTING project ─
-- Idempotent — run in the Supabase SQL Editor if `messages` doesn't exist yet:
--   create table if not exists messages (
--     id uuid primary key default gen_random_uuid(),
--     player_id uuid references players(id) on delete cascade,
--     nickname text not null,
--     text text not null,
--     created_at timestamptz default now()
--   );
--   create index if not exists messages_created_idx on messages (created_at);
--   alter table messages enable row level security;
--   drop policy if exists "read messages"   on messages;
--   drop policy if exists "insert messages" on messages;
--   drop policy if exists "delete messages" on messages;
--   create policy "read messages"   on messages for select using (true);
--   create policy "insert messages" on messages for insert with check (true);
--   create policy "delete messages" on messages for delete using (true);
