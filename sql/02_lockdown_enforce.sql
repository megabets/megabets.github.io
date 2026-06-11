-- megabets lockdown — STEP 2 of 2 (ENFORCE — run ONLY after the new RPC-based
-- index.html is deployed on GitHub Pages and verified working, otherwise the
-- live old frontend breaks). Requires sql/01_lockdown_setup.sql already run.
--
-- This removes the open anon-key access: direct writes everywhere, pin_hash
-- reads, future-bet reads, chat reads, payments/notices access. The
-- service_role key (GitHub Actions score writers) is untouched — it bypasses
-- RLS and nothing is revoked from it.
--
-- Also confirm `messages` is NOT in the supabase_realtime publication
-- (Dashboard → Database → Publications) — belt and braces; with no grants
-- Realtime would return nothing anyway.

-- players: hide pin_hash via COLUMN-level grant (the "read players" row policy
-- stays — policies gate rows, grants gate columns; both apply). Direct
-- insert/update die; registration goes through register_player().
-- ⚠ Consequence: `players?select=*` (or an insert without `?select=col,...`
-- under the default Prefer: return=representation) now fails with 42501 —
-- always list columns explicitly when touching players from the client.
revoke select, insert, update, delete on table public.players from anon, authenticated;
grant select (id, nickname, created_at) on table public.players to anon, authenticated;
drop policy if exists "insert players" on public.players;
drop policy if exists "claim pin"      on public.players;

-- predictions: others' bets visible only after kickoff; writes via preds_save
-- only. Your own future bets come through preds_fetch. The standings query
-- (select all predictions) keeps working — only kicked-off matches can score.
revoke insert, update, delete on table public.predictions from anon, authenticated;
drop policy if exists "read predictions" on public.predictions;
drop policy if exists "insert preds"     on public.predictions;
drop policy if exists "update preds"     on public.predictions;
drop policy if exists "read kicked-off predictions" on public.predictions;  -- re-run safety
create policy "read kicked-off predictions" on public.predictions for select
  using (exists (select 1 from public.matches m
                  where m.id = match_id and m.kickoff <= now()));

-- messages (chat): NO public grants and NO policies — on purpose. The anon
-- key cannot touch the table directly; chat is login-only in both directions
-- via chat_fetch / chat_post / chat_delete.
revoke all on table public.messages from anon, authenticated;
drop policy if exists "read messages"   on public.messages;
drop policy if exists "insert messages" on public.messages;
drop policy if exists "delete messages" on public.messages;

-- payments: admin-RPC only (payments_fetch / payments_save)
revoke all on table public.payments from anon, authenticated;
drop policy if exists "read payments"   on public.payments;
drop policy if exists "insert payments" on public.payments;
drop policy if exists "update payments" on public.payments;

-- notices: RPC only (notices_fetch for the recipient, notices_* for the admin)
revoke all on table public.notices from anon, authenticated;
drop policy if exists notices_select on public.notices;
drop policy if exists notices_insert on public.notices;
drop policy if exists notices_delete on public.notices;

-- bonuses: feature unused by the app — close the open insert. Wrapped because
-- the table never made it to production ("if exists" on drop policy does NOT
-- cover a missing TABLE, only a missing policy — it errors with 42P01).
do $$ begin
  if to_regclass('public.bonuses') is not null then
    drop policy if exists "insert bonuses" on public.bonuses;
  end if;
end $$;

notify pgrst, 'reload schema';

-- ── EMERGENCY ROLLBACK ──────────────────────────────────────────────────────
-- Paste-and-run to restore the pre-lockdown open access (the old frontend
-- works again immediately). Leaves the sql/01 RPCs in place — they're harmless.
--
-- grant select, insert, update, delete on table public.players     to anon, authenticated;
-- grant insert, update, delete         on table public.predictions to anon, authenticated;
-- grant select, insert, update, delete on table public.messages    to anon, authenticated;
-- grant select, insert, update, delete on table public.payments    to anon, authenticated;
-- grant select, insert, update, delete on table public.notices     to anon, authenticated;
-- create policy "insert players"   on public.players     for insert with check (true);
-- create policy "claim pin"        on public.players     for update using (pin_hash is null) with check (true);
-- drop policy if exists "read kicked-off predictions" on public.predictions;
-- create policy "read predictions" on public.predictions for select using (true);
-- create policy "insert preds"     on public.predictions for insert with check (true);
-- create policy "update preds"     on public.predictions for update using (true);
-- create policy "read messages"    on public.messages    for select using (true);
-- create policy "insert messages"  on public.messages    for insert with check (true);
-- create policy "delete messages"  on public.messages    for delete using (true);
-- create policy "read payments"    on public.payments    for select using (true);
-- create policy "insert payments"  on public.payments    for insert with check (true);
-- create policy "update payments"  on public.payments    for update using (true);
-- create policy notices_select     on public.notices     for select using (true);
-- create policy notices_insert     on public.notices     for insert with check (true);
-- create policy notices_delete     on public.notices     for delete using (true);
-- notify pgrst, 'reload schema';
