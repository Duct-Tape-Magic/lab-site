-- Per-account preferences (today: the colour theme). Students and admins alike; one row per user.
create table if not exists public.user_prefs (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  theme      text,
  updated_at timestamptz not null default now()
);
alter table public.user_prefs enable row level security;
drop policy if exists "own prefs" on public.user_prefs;
create policy "own prefs" on public.user_prefs for all using (user_id = auth.uid()) with check (user_id = auth.uid());
