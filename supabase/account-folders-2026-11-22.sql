-- ============================================================
-- ACCOUNT FOLDERS (owner, 2026-11-22). Idempotent: safe to run again. Also the last section of schema.sql.
--
-- Admin-only filing for accounts, so long lists are quick to get through. A folder holds Google accounts and whole
-- classes (a class moves as one unit; its seats stay under it), and folders can sit inside folders.
-- Filing changes NOTHING about who can see or edit anything: no access rule reads these tables, and in the site's tick
-- lists a folder's checkbox is only a shortcut that ticks what is inside it at that moment.
-- ============================================================
create table if not exists public.account_folders (
  id         text primary key,                                                   -- 'af-<timestamp>'
  name       text not null,
  parent_id  text references public.account_folders(id) on delete set null,      -- null = top level
  sort_order int  not null default 0,
  created_at timestamptz not null default now()
);
create table if not exists public.account_folder_users (                         -- a Google account sits in at most one folder
  user_id   uuid primary key references auth.users(id) on delete cascade,
  folder_id text not null references public.account_folders(id) on delete cascade
);
create table if not exists public.account_folder_classes (                       -- a class sits in at most one folder
  class_id  text primary key references public.classes(id) on delete cascade,
  folder_id text not null references public.account_folders(id) on delete cascade
);
alter table public.account_folders        enable row level security;
alter table public.account_folder_users   enable row level security;
alter table public.account_folder_classes enable row level security;
-- Only admins read or write them (Supabase no longer grants new tables to the API roles by itself, so the grants are spelled out).
revoke all on public.account_folders, public.account_folder_users, public.account_folder_classes from anon, authenticated;
grant select, insert, update, delete on public.account_folders, public.account_folder_users, public.account_folder_classes to authenticated, service_role;
drop policy if exists "admin all account_folders" on public.account_folders;
create policy "admin all account_folders" on public.account_folders for all using (is_admin()) with check (is_admin());
drop policy if exists "admin all account_folder_users" on public.account_folder_users;
create policy "admin all account_folder_users" on public.account_folder_users for all using (is_admin()) with check (is_admin());
drop policy if exists "admin all account_folder_classes" on public.account_folder_classes;
create policy "admin all account_folder_classes" on public.account_folder_classes for all using (is_admin()) with check (is_admin());
