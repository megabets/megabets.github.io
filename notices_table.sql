-- megabets: one-time setup for admin → single-user popup messages.
-- Run this once in the Supabase SQL editor (Dashboard → SQL Editor → New query → Run).
-- Policies mirror the open anon-key access the app already uses for the `messages` table.

create table if not exists public.notices (
  id         bigint generated always as identity primary key,
  to_nick    text        not null,                 -- recipient nickname, stored lowercased
  body       text        not null,
  created_at timestamptz not null default now()
);

alter table public.notices enable row level security;

-- Drop-and-recreate so re-running this file is safe.
drop policy if exists notices_select on public.notices;
drop policy if exists notices_insert on public.notices;
drop policy if exists notices_delete on public.notices;

create policy notices_select on public.notices for select using (true);
create policy notices_insert on public.notices for insert with check (true);
create policy notices_delete on public.notices for delete using (true);
