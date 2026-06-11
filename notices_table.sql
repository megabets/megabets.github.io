-- megabets: one-time setup for admin → single-user popup messages.
-- Run this once in the Supabase SQL editor (Dashboard → SQL Editor → New query → Run).
-- NOT publicly reachable: the anon key has no grants and no policies here.
-- Recipients read their own popups via rpc/notices_fetch; the organizer
-- manages them via rpc/notices_list / notices_send / notices_delete
-- (all defined in sql/01_lockdown_setup.sql, credential-checked server-side).

create table if not exists public.notices (
  id         bigint generated always as identity primary key,
  to_nick    text        not null,                 -- recipient nickname, stored lowercased
  body       text        not null,
  created_at timestamptz not null default now()
);

alter table public.notices enable row level security;
revoke all on table public.notices from anon, authenticated;

-- Drop-and-recreate so re-running this file is safe on a pre-lockdown project
-- (these were the old open policies; the lockdown has no policies at all).
drop policy if exists notices_select on public.notices;
drop policy if exists notices_insert on public.notices;
drop policy if exists notices_delete on public.notices;
