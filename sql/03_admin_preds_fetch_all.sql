-- megabets — admin "see all bets" RPC. Additive; changes no existing policies.
-- Requires sql/01_lockdown_setup.sql (auth_admin) already run.
--
-- The public predictions SELECT is RLS-restricted to kicked-off matches
-- (sql/02), so the anon key can never read future bets. This security-definer
-- function bypasses that policy and returns EVERY player's bets — including
-- matches not yet kicked off — but auth_admin gates it to the organizer
-- (nickname 'trololoic'); anyone else gets HTTP 403.
--
-- Returns a SINGLE jsonb array (one row) rather than a row set. PostgREST's
-- "Max rows" cap counts rows, so a set-returning version is silently truncated
-- once total predictions exceed the cap (default 1000) — which with 34 players
-- betting future rounds it does, dropping bets arbitrarily from the admin view.
-- One row holding the whole array is never capped. The frontend parses the
-- array directly (the REST body for a scalar RPC is the value itself).

drop function if exists public.preds_fetch_all(uuid, text);
create function public.preds_fetch_all(p_player uuid, p_auth text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  perform auth_admin(p_player, p_auth);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'player_id', pr.player_id, 'match_id', pr.match_id,
             'pred_home', pr.pred_home, 'pred_away', pr.pred_away)
             order by pr.match_id, pr.player_id)
    from predictions pr), '[]'::jsonb);
end; $$;
grant execute on function public.preds_fetch_all(uuid, text) to anon, authenticated;

notify pgrst, 'reload schema';
