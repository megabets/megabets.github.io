-- megabets — admin "see all bets" RPC. Additive; changes no existing policies.
-- Requires sql/01_lockdown_setup.sql (auth_admin) already run.
--
-- The public predictions SELECT is RLS-restricted to kicked-off matches
-- (sql/02), so the anon key can never read future bets. This security-definer
-- function bypasses that policy and returns EVERY player's bets — including
-- matches not yet kicked off — but auth_admin gates it to the organizer
-- (nickname 'trololoic'); anyone else gets HTTP 403. Mirrors preds_fetch,
-- with player_id added and the admin gate swapped in.

create or replace function public.preds_fetch_all(p_player uuid, p_auth text)
returns table (player_id uuid, match_id bigint, pred_home int, pred_away int)
language plpgsql security definer set search_path = public
as $$
begin
  perform auth_admin(p_player, p_auth);
  return query select pr.player_id, pr.match_id, pr.pred_home, pr.pred_away
    from predictions pr;
end; $$;
grant execute on function public.preds_fetch_all(uuid, text) to anon, authenticated;

notify pgrst, 'reload schema';
