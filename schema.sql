-- World Cup 2026 Friends League — Supabase schema
-- Run this in Supabase -> SQL Editor (New query) once, on a fresh project.

-- ── Tables ───────────────────────────────────────────────
create table players (
  id uuid primary key default gen_random_uuid(),
  nickname text unique not null,
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

-- ── Row Level Security ───────────────────────────────────
alter table players enable row level security;
alter table matches enable row level security;
alter table predictions enable row level security;

-- Everyone can read (public league)
create policy "read players"     on players     for select using (true);
create policy "read matches"     on matches     for select using (true);
create policy "read predictions" on predictions for select using (true);

-- Anyone can create a player and submit/update their own predictions
create policy "insert players"   on players     for insert with check (true);
create policy "insert preds"     on predictions for insert with check (true);
create policy "update preds"     on predictions for update using (true);

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
