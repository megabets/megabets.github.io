-- megabets — "Podium" bet: predict the tournament winner / finalist / 3rd / 4th.
-- Additive; changes no existing policies. Run the whole file in Supabase → SQL
-- Editor. Requires sql/01_lockdown_setup.sql (auth_player, auth_admin) already run.
--
-- One tournament-wide bet per player, scored on EXACT final placement:
--   winner = 5 pts, finalist (runner-up) = 3, 3rd = 2, 4th = 2.
-- Picks lock at the hard-coded deadline below (anticipated end of the Round of 32);
-- the lock is server-enforced in podium_save, the analogue of the kickoff > now()
-- guard in preds_save. The same timestamp gates the public read policy so nobody
-- sees anyone else's picks until the bet is closed — mirrors the kicked-off-only
-- SELECT policy on predictions (sql/02).

-- ── Tables ───────────────────────────────────────────────────────────────────

-- One row per player; nullable picks so a partial save is fine.
create table if not exists public.podium_bets (
  player_id    uuid primary key references public.players(id) on delete cascade,
  winner       text,
  finalist     text,
  third        text,
  fourth       text,
  submitted_at timestamptz not null default now()
);
alter table public.podium_bets enable row level security;
-- Public SELECT exposed ONLY after the lock, so future picks stay hidden. Your own
-- picks come through podium_fetch before then.
drop policy if exists podium_read_after_lock on public.podium_bets;
create policy podium_read_after_lock on public.podium_bets for select
  using (now() > timestamptz '2026-07-04 23:59:00+00');
grant select on public.podium_bets to anon, authenticated;

-- Single-row actual result, admin-written, world-readable.
create table if not exists public.podium_result (
  id         int primary key default 1 check (id = 1),
  winner     text,
  finalist   text,
  third      text,
  fourth     text,
  updated_at timestamptz not null default now()
);
alter table public.podium_result enable row level security;
drop policy if exists podium_result_read on public.podium_result;
create policy podium_result_read on public.podium_result for select using (true);
grant select on public.podium_result to anon, authenticated;

-- ── RPCs ─────────────────────────────────────────────────────────────────────

-- Caller's own picks (the read policy hides them until lock, like preds_fetch).
create or replace function public.podium_fetch(p_player uuid, p_auth text)
returns table (winner text, finalist text, third text, fourth text)
language plpgsql security definer set search_path = public
as $$
begin
  perform auth_player(p_player, p_auth);
  return query select b.winner, b.finalist, b.third, b.fourth
    from podium_bets b where b.player_id = p_player;
end; $$;

-- Upsert the CALLER's picks; rejected once the bet has locked (server-enforced).
create or replace function public.podium_save(
  p_player uuid, p_auth text,
  p_winner text, p_finalist text, p_third text, p_fourth text)
returns int
language plpgsql security definer set search_path = public
as $$
begin
  perform auth_player(p_player, p_auth);
  if now() > timestamptz '2026-07-04 23:59:00+00' then
    raise exception 'podium bet is locked' using errcode = 'PT403';
  end if;
  insert into podium_bets (player_id, winner, finalist, third, fourth)
    values (p_player, p_winner, p_finalist, p_third, p_fourth)
  on conflict (player_id) do update
    set winner = excluded.winner, finalist = excluded.finalist,
        third = excluded.third, fourth = excluded.fourth,
        submitted_at = now();
  return 1;
end; $$;

-- Admin-only: set the actual podium (single id=1 row).
create or replace function public.podium_result_set(
  p_player uuid, p_auth text,
  p_winner text, p_finalist text, p_third text, p_fourth text)
returns int
language plpgsql security definer set search_path = public
as $$
begin
  perform auth_admin(p_player, p_auth);
  insert into podium_result (id, winner, finalist, third, fourth, updated_at)
    values (1, p_winner, p_finalist, p_third, p_fourth, now())
  on conflict (id) do update
    set winner = excluded.winner, finalist = excluded.finalist,
        third = excluded.third, fourth = excluded.fourth,
        updated_at = now();
  return 1;
end; $$;

revoke execute on function public.podium_fetch(uuid, text) from public;
revoke execute on function public.podium_save(uuid, text, text, text, text, text) from public;
revoke execute on function public.podium_result_set(uuid, text, text, text, text, text) from public;
grant execute on function public.podium_fetch(uuid, text)                              to anon, authenticated;
grant execute on function public.podium_save(uuid, text, text, text, text, text)       to anon, authenticated;
grant execute on function public.podium_result_set(uuid, text, text, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';
