-- ============================================================
-- Lab Site — database schema, security policies, storage, stats
-- Run this whole file once in the Supabase SQL editor of a NEW project.
-- Safe to re-run: every statement is idempotent (drop/create or "if not exists").
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------
create or replace function public.is_admin() returns boolean
language sql stable as $$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin'
$$;

create or replace function public.set_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

-- ------------------------------------------------------------
-- Tables
-- ------------------------------------------------------------
create table if not exists public.folders (
  id          text primary key,
  parent_id   text references public.folders(id) on delete cascade,
  name        text not null,
  slug        text not null unique,
  description text,
  sort_order  integer not null default 0,
  listed      boolean not null default true,
  access      text not null default 'inherit'
              check (access in ('inherit','public','password','accounts','admin')),
  cover_path  text,
  created_at  timestamptz not null default now()
);
alter table public.folders add column if not exists cover_path text;

create table if not exists public.labs (
  id                text primary key,
  folder_id         text references public.folders(id) on delete set null,
  title             text not null,
  slug              text not null unique,
  summary           text,
  cover_path        text,
  status            text not null default 'draft'
                    check (status in ('draft','published','scheduled')),
  publish_at        timestamptz,
  access            text not null default 'inherit'
                    check (access in ('inherit','public','password','accounts','admin')),
  tags              text[] not null default '{}',
  estimated_minutes integer,
  sort_order        integer not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

drop trigger if exists labs_updated_at on public.labs;
create trigger labs_updated_at before update on public.labs
  for each row execute function public.set_updated_at();

create table if not exists public.lab_content (
  lab_id  text primary key references public.labs(id) on delete cascade,
  media   text[] not null default '{}',
  content text,
  format  text not null default 'html'   -- 'html' (rich text editor) | 'labtags' (markdown + \commands, see docs/LAB-FORMAT.md)
);
alter table public.lab_content add column if not exists format text not null default 'html';

create table if not exists public.attachments (
  id         text primary key,
  lab_id     text not null references public.labs(id) on delete cascade,
  name       text not null,
  path       text not null,
  mime       text,
  size_bytes bigint not null default 0,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists attachments_lab_idx on public.attachments (lab_id);

create table if not exists public.lab_revisions (
  id       bigint generated always as identity primary key,
  lab_id   text not null references public.labs(id) on delete cascade,
  snapshot jsonb not null,
  note     text,
  saved_at timestamptz not null default now()
);
create index if not exists lab_revisions_lab_idx on public.lab_revisions (lab_id, saved_at desc);

create table if not exists public.item_passwords (
  item_id       text primary key,
  password_hash text not null,
  updated_at    timestamptz not null default now()
);

create table if not exists public.groups (
  id         text primary key,
  name       text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id text references public.groups(id) on delete cascade,
  user_id  uuid references auth.users(id) on delete cascade,
  primary key (group_id, user_id)
);

create table if not exists public.item_groups (
  item_id  text not null,
  group_id text references public.groups(id) on delete cascade,
  primary key (item_id, group_id)
);

create table if not exists public.students (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  full_name  text,
  created_at timestamptz not null default now()
);

create table if not exists public.unlock_attempts (
  item_id    text not null,
  client_key text not null,
  attempts   integer not null default 0,
  window_end timestamptz not null,
  primary key (item_id, client_key)
);

create table if not exists public.site_content (
  key   text primary key,
  value text
);

create table if not exists public.events (
  id         bigint generated always as identity primary key,
  ts         timestamptz not null default now(),
  type       text not null,
  lab_id     text,
  folder_id  text,
  path       text,
  visitor_id text,
  referrer   text,
  device     text
);
create index if not exists events_ts_idx on public.events (ts);
create index if not exists events_lab_ts_idx on public.events (lab_id, ts);

-- ------------------------------------------------------------
-- Access resolution (security definer: reads the tree regardless of RLS)
-- ------------------------------------------------------------
create or replace function public.resolve_access(p_lab_id text)
returns table(level text, governing_id text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_level  text;
  v_folder text;
  v_id     text;
  v_depth  int := 0;
begin
  select l.access, l.folder_id into v_level, v_folder from labs l where l.id = p_lab_id;
  if v_level is null then return; end if;
  if v_level <> 'inherit' then
    level := v_level; governing_id := p_lab_id; return next; return;
  end if;
  while v_folder is not null and v_depth < 20 loop
    select f.access, f.parent_id, f.id into v_level, v_folder, v_id from folders f where f.id = v_folder;
    if v_level is null then exit; end if;
    if v_level <> 'inherit' then
      level := v_level; governing_id := v_id; return next; return;
    end if;
    v_depth := v_depth + 1;
  end loop;
  level := 'public'; governing_id := null; return next;
end $$;

-- Same walk for a folder itself (used to hide admin-only folders from the catalogue)
create or replace function public.resolve_folder_access(p_folder_id text)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_level  text;
  v_parent text := p_folder_id;
  v_depth  int := 0;
begin
  while v_parent is not null and v_depth < 20 loop
    select f.access, f.parent_id into v_level, v_parent from folders f where f.id = v_parent;
    if v_level is null then return 'public'; end if;
    if v_level <> 'inherit' then return v_level; end if;
    v_depth := v_depth + 1;
  end loop;
  return 'public';
end $$;

create or replace function public.lab_is_live(p_status text, p_publish_at timestamptz)
returns boolean language sql immutable as $$
  select p_status = 'published'
      or (p_status = 'scheduled' and p_publish_at is not null and p_publish_at <= now())
$$;

create or replace function public.student_allowed(p_governing_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from item_groups ig
    join group_members gm on gm.group_id = ig.group_id
    where ig.item_id = p_governing_id and gm.user_id = auth.uid())
$$;

-- Admin sets or clears an item password (plaintext never stored)
create or replace function public.set_item_password(p_item_id text, p_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if p_password is null or p_password = '' then
    delete from item_passwords where item_id = p_item_id;
    return;
  end if;
  insert into item_passwords (item_id, password_hash)
  values (p_item_id, crypt(p_password, gen_salt('bf')))
  on conflict (item_id) do update
    set password_hash = excluded.password_hash, updated_at = now();
end $$;

-- ------------------------------------------------------------
-- Row-level security
-- ------------------------------------------------------------
alter table public.folders         enable row level security;
alter table public.labs            enable row level security;
alter table public.lab_content     enable row level security;
alter table public.attachments     enable row level security;
alter table public.lab_revisions   enable row level security;
alter table public.item_passwords  enable row level security;
alter table public.groups          enable row level security;
alter table public.group_members   enable row level security;
alter table public.item_groups     enable row level security;
alter table public.students        enable row level security;
alter table public.unlock_attempts enable row level security;
alter table public.site_content    enable row level security;
alter table public.events          enable row level security;

-- Catalogue reads (everyone): folders and live labs, except admin-only ones
drop policy if exists "read folders" on public.folders;
create policy "read folders" on public.folders for select
  using (is_admin() or resolve_folder_access(id) <> 'admin');

drop policy if exists "read lab catalogue" on public.labs;
create policy "read lab catalogue" on public.labs for select
  using (is_admin() or (lab_is_live(status, publish_at)
         and (select r.level from resolve_access(id) r) <> 'admin'));

-- Content and attachments: direct reads only for public labs (locked ones go through the gate function)
drop policy if exists "read public content" on public.lab_content;
create policy "read public content" on public.lab_content for select
  using (is_admin() or exists (
    select 1 from labs l where l.id = lab_content.lab_id
      and lab_is_live(l.status, l.publish_at)
      and (select r.level from resolve_access(l.id) r) = 'public'));

drop policy if exists "read public attachments" on public.attachments;
create policy "read public attachments" on public.attachments for select
  using (is_admin() or exists (
    select 1 from labs l where l.id = attachments.lab_id
      and lab_is_live(l.status, l.publish_at)
      and (select r.level from resolve_access(l.id) r) = 'public'));

drop policy if exists "read site_content" on public.site_content;
create policy "read site_content" on public.site_content for select using (true);

drop policy if exists "student reads self" on public.students;
create policy "student reads self" on public.students for select
  using (user_id = auth.uid() or is_admin());

drop policy if exists "student reads own groups" on public.group_members;
create policy "student reads own groups" on public.group_members for select
  using (user_id = auth.uid() or is_admin());

-- Admin writes everywhere
drop policy if exists "admin all folders" on public.folders;
create policy "admin all folders" on public.folders for all using (is_admin()) with check (is_admin());
drop policy if exists "admin all labs" on public.labs;
create policy "admin all labs" on public.labs for all using (is_admin()) with check (is_admin());
drop policy if exists "admin all lab_content" on public.lab_content;
create policy "admin all lab_content" on public.lab_content for all using (is_admin()) with check (is_admin());
drop policy if exists "admin all attachments" on public.attachments;
create policy "admin all attachments" on public.attachments for all using (is_admin()) with check (is_admin());
drop policy if exists "admin all revisions" on public.lab_revisions;
create policy "admin all revisions" on public.lab_revisions for all using (is_admin()) with check (is_admin());
drop policy if exists "admin all passwords" on public.item_passwords;
create policy "admin all passwords" on public.item_passwords for all using (is_admin()) with check (is_admin());
drop policy if exists "admin all groups" on public.groups;
create policy "admin all groups" on public.groups for all using (is_admin()) with check (is_admin());
drop policy if exists "admin all members" on public.group_members;
create policy "admin all members" on public.group_members for all using (is_admin()) with check (is_admin());
drop policy if exists "admin all item_groups" on public.item_groups;
create policy "admin all item_groups" on public.item_groups for all using (is_admin()) with check (is_admin());
drop policy if exists "admin all students" on public.students;
create policy "admin all students" on public.students for all using (is_admin()) with check (is_admin());
drop policy if exists "admin all site_content" on public.site_content;
create policy "admin all site_content" on public.site_content for all using (is_admin()) with check (is_admin());
-- unlock_attempts: no client policies; only the gate function (service key) touches it.

-- Analytics: anyone may log; only admins read or delete
-- (who may log events is set with the stats functions, in the Stats section at the end of this file)
drop policy if exists "admin reads events" on public.events;
create policy "admin reads events" on public.events for select using (is_admin());
drop policy if exists "admin deletes events" on public.events;
create policy "admin deletes events" on public.events for delete using (is_admin());

-- ------------------------------------------------------------
-- Storage buckets and policies
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('lab-files-public', 'lab-files-public', true, 52428800)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public, file_size_limit)
values ('lab-files-private', 'lab-files-private', false, 52428800)
on conflict (id) do nothing;

drop policy if exists "anyone reads public files" on storage.objects;
create policy "anyone reads public files" on storage.objects for select
  using (bucket_id = 'lab-files-public');
drop policy if exists "admin lists private files" on storage.objects;
create policy "admin lists private files" on storage.objects for select
  using (is_admin() and bucket_id = 'lab-files-private');
drop policy if exists "admin inserts files" on storage.objects;
create policy "admin inserts files" on storage.objects for insert
  with check (is_admin() and bucket_id in ('lab-files-public','lab-files-private'));
drop policy if exists "admin updates files" on storage.objects;
create policy "admin updates files" on storage.objects for update
  using (is_admin() and bucket_id in ('lab-files-public','lab-files-private'));
drop policy if exists "admin deletes files" on storage.objects;
create policy "admin deletes files" on storage.objects for delete
  using (is_admin() and bucket_id in ('lab-files-public','lab-files-private'));

-- (the stats functions are in the Stats section at the end of this file)

-- ------------------------------------------------------------
-- One-time step after creating the admin user in Authentication → Users:
--   update auth.users
--     set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
--   where email = 'YOUR-ADMIN-EMAIL';
-- Then sign out and back in on the site so the new role is in the session.
-- ------------------------------------------------------------
-- Student accounts (Google sign-in) and per-student lab entries
create table if not exists public.lab_entries (
  user_id    uuid not null references auth.users(id) on delete cascade,
  lab_id     text not null,
  data       jsonb not null default '{}',
  updated_at timestamptz not null default now(),
  primary key (user_id, lab_id)
);
alter table public.lab_entries enable row level security;
drop policy if exists "own entries" on public.lab_entries;
create policy "own entries" on public.lab_entries for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "admin reads entries" on public.lab_entries;
create policy "admin reads entries" on public.lab_entries for select using (is_admin());

-- Every new auth user gets a students row (name/email from Google); admins are skipped later via role
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.students (user_id, email, full_name)
  values (new.id, coalesce(new.email, ''), coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'))
  on conflict (user_id) do update set email = excluded.email, full_name = coalesce(excluded.full_name, students.full_name);
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Students may update their own display name
drop policy if exists "student updates self" on public.students;   -- removed 2026-10-13: nothing on the site needs it, and it allowed self-renaming

-- Any student may delete their own account, class code accounts (seats) included, without a teacher (owner, 2026-11-21; before that a seat
-- was refused). Deleting the auth user cascades to the seat row (so its access code stops working), class membership, lab entries, help
-- threads, Socratic 1 sessions and preferences. delete_my_account(true) only checks that the caller may delete and changes nothing: the page
-- calls it first, before it removes the student's photos from storage, so a refusal can never cost a student their photos.
drop function if exists public.delete_my_account();   -- the earlier form without the check argument
create or replace function public.delete_my_account(p_check boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if is_admin() then raise exception 'admin accounts cannot be deleted from the site'; end if;
  if p_check then return; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke execute on function public.delete_my_account(boolean) from public, anon;
grant execute on function public.delete_my_account(boolean) to authenticated;


-- Admin management: any admin may grant or revoke the admin role by email (used by the Admins panel)
create or replace function public.list_admins() returns table(email text, user_id uuid, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query select u.email::text, u.id, u.created_at from auth.users u
    where coalesce(u.raw_app_meta_data->>'role', '') = 'admin' order by u.created_at;
end $$;

create or replace function public.set_admin(p_email text, p_admin boolean) returns text
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_email text := lower(trim(p_email));
begin
  if not is_admin() then raise exception 'admin only'; end if;
  select id into v_id from auth.users where lower(email) = v_email;
  if v_id is null then return 'not_found'; end if;
  if v_id = auth.uid() and not p_admin then return 'cannot_remove_self'; end if;
  if p_admin then
    update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb where id = v_id;
  else
    update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) - 'role' where id = v_id;
  end if;
  return 'ok';
end $$;
revoke execute on function public.list_admins() from public, anon;
grant execute on function public.list_admins() to authenticated;
revoke execute on function public.set_admin(text, boolean) from public, anon;
grant execute on function public.set_admin(text, boolean) to authenticated;

-- ============================================================
-- Classes of access-code accounts (no email; passcode only)
-- ============================================================
create table if not exists public.classes (
  id         text primary key,
  name       text not null,
  prefix     text not null,
  archived   boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.seats (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  class_id   text not null references public.classes(id) on delete cascade,
  seat_no    integer not null,
  passcode   text not null unique,
  nickname   text,
  created_at timestamptz not null default now(),
  unique (class_id, seat_no)
);
alter table public.classes enable row level security;
alter table public.seats   enable row level security;
drop policy if exists "admin all classes" on public.classes;
create policy "admin all classes" on public.classes for all using (is_admin()) with check (is_admin());
drop policy if exists "seat reads own class" on public.classes;
create policy "seat reads own class" on public.classes for select
  using (exists (select 1 from public.seats s where s.class_id = classes.id and s.user_id = auth.uid()));
drop policy if exists "admin all seats" on public.seats;
create policy "admin all seats" on public.seats for all using (is_admin()) with check (is_admin());
drop policy if exists "seat reads self" on public.seats;
create policy "seat reads self" on public.seats for select using (user_id = auth.uid());

-- is_admin: also true for direct dashboard sessions (never for API roles), so functions can be exercised from the SQL editor
create or replace function public.is_admin() returns boolean
language sql stable as $$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin' or session_user = 'postgres'
$$;

-- Seat accounts are not listed as named students
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email like '%@seats.ohschemlabs.com' then return new; end if;
  insert into public.students (user_id, email, full_name)
  values (new.id, coalesce(new.email, ''), coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'))
  on conflict (user_id) do update set email = excluded.email, full_name = coalesce(excluded.full_name, students.full_name);
  return new;
end $$;

create or replace function public.seat_email(p_code text) returns text
language sql immutable as $$
  select lower(trim(both '-' from regexp_replace(upper(trim(p_code)), '[^A-Z0-9]+', '-', 'g'))) || '@seats.ohschemlabs.com'
$$;

create or replace function public.gen_passcode(p_prefix text) returns text
language plpgsql volatile as $$
declare
  words text[] := array['TIGER','MAPLE','RIVER','COMET','FALCON','CEDAR','EMBER','GLACIER','HARBOR','ISLAND','JASPER','KESTREL','LANTERN','METEOR','NEBULA','ORCHID','PEBBLE','QUARTZ','RAVEN','SUMMIT','THUNDER','VALLEY','WALNUT','ZEPHYR','AMBER','BEACON','CANYON','DELTA','EAGLE','FOREST','GARNET','HAZEL','IRIS','JUNIPER','KOALA','LAGOON','MARBLE','NECTAR','OTTER','PRISM','QUILL','ROCKET','SADDLE','TUNDRA','UMBER','VELVET','WILLOW','YARROW','ACORN','BADGER','CINDER','DUNE','ELM','FJORD','GRANITE','HERON','INLET','JADE','KELP','LOTUS','MESA','NORTH','OASIS','PINE','QUAIL','REEF','SPRUCE','TOPAZ','VORTEX','WREN','ASPEN','BISON','CORAL','DRIFT','ECHO','FERN','GROVE','HALO','IVORY','JETTY','KITE','LUNAR','MOSS','NOVA','ONYX','PLUM','RIDGE','SLATE','TRAIL','VISTA','WAVE','BERRY','CLOUD','DAWN','FLARE','GLOW','HAWK','LILAC','MINT','OPAL','PEARL','ROBIN','STORM','TIDE','VINE','WHEAT'];
begin
  return upper(regexp_replace(p_prefix, '[^A-Za-z0-9]+', '', 'g')) || '-' || words[1 + floor(random() * array_length(words, 1))::int] || '-' || lpad(floor(random() * 10000)::int::text, 4, '0');
end $$;

create or replace function public.create_class(p_name text, p_prefix text) returns text
language plpgsql security definer set search_path = public as $$
declare v_id text := 'c-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint::text;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'A class needs a name'; end if;
  insert into classes (id, name, prefix) values (v_id, trim(p_name), upper(regexp_replace(coalesce(p_prefix, 'C'), '[^A-Za-z0-9]+', '', 'g')));
  insert into groups (id, name) values (v_id, trim(p_name)) on conflict (id) do nothing;
  return v_id;
end $$;

create or replace function public.add_seats(p_class_id text, p_count int)
returns table(user_id uuid, seat_no int, passcode text)
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_prefix text; v_next int; v_code text; v_uid uuid; v_email text; i int;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  select c.prefix into v_prefix from classes c where c.id = p_class_id;
  if v_prefix is null then raise exception 'No such class'; end if;
  if p_count < 1 or p_count > 200 then raise exception 'Add between 1 and 200 seats at a time'; end if;
  for i in 1..p_count loop
    select coalesce(max(s.seat_no), 0) + 1 into v_next from seats s where s.class_id = p_class_id;
    loop
      v_code := gen_passcode(v_prefix);
      exit when not exists (select 1 from seats s where s.passcode = v_code);
    end loop;
    v_uid := gen_random_uuid(); v_email := seat_email(v_code);
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token, recovery_token, email_change, email_change_token_new, email_change_token_current, phone_change, phone_change_token, reauthentication_token, is_sso_user)
    values ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_email, crypt(v_code, gen_salt('bf', 10)), now(),
            jsonb_build_object('provider', 'email', 'providers', array['email'], 'role', 'seat'), jsonb_build_object('seat', true),
            now(), now(), '', '', '', '', '', '', '', '', false);
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v_uid, v_uid::text, jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true, 'phone_verified', false), 'email', now(), now(), now());
    insert into seats (user_id, class_id, seat_no, passcode) values (v_uid, p_class_id, v_next, v_code);
    insert into group_members (group_id, user_id) values (p_class_id, v_uid) on conflict do nothing;
    user_id := v_uid; seat_no := v_next; passcode := v_code; return next;
  end loop;
end $$;

create or replace function public.regenerate_seat(p_user uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_prefix text; v_code text; v_email text;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  select c.prefix into v_prefix from seats s join classes c on c.id = s.class_id where s.user_id = p_user;
  if v_prefix is null then raise exception 'No such seat'; end if;
  loop
    v_code := gen_passcode(v_prefix);
    exit when not exists (select 1 from seats s where s.passcode = v_code);
  end loop;
  v_email := seat_email(v_code);
  update auth.users set email = v_email, encrypted_password = crypt(v_code, gen_salt('bf', 10)), updated_at = now() where id = p_user;
  update auth.identities set identity_data = identity_data || jsonb_build_object('email', v_email), updated_at = now() where auth.identities.user_id = p_user and provider = 'email';
  update seats set passcode = v_code where user_id = p_user;
  delete from auth.sessions where user_id = p_user;   -- the old code stops working now, not at the next token refresh
  return v_code;
end $$;

create or replace function public.delete_seat(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  delete from auth.users where id = p_user and exists (select 1 from seats s where s.user_id = p_user);
end $$;

create or replace function public.delete_class(p_class_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  delete from auth.users where id in (select s.user_id from seats s where s.class_id = p_class_id);
  delete from classes where id = p_class_id;
  delete from groups where id = p_class_id;
end $$;

create or replace function public.set_class_archived(p_class_id text, p_archived boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  update classes set archived = p_archived where id = p_class_id;
  update auth.users set banned_until = case when p_archived then 'infinity'::timestamptz else null end, updated_at = now()
    where id in (select s.user_id from seats s where s.class_id = p_class_id);
  if p_archived then delete from auth.sessions where user_id in (select s.user_id from seats s where s.class_id = p_class_id); end if;
end $$;

create or replace function public.list_classes()
returns table(id text, name text, prefix text, archived boolean, created_at timestamptz, seat_count bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query select c.id, c.name, c.prefix, c.archived, c.created_at, (select count(*) from seats s where s.class_id = c.id)
    from classes c order by c.archived, c.created_at;
end $$;

create or replace function public.list_class_seats(p_class_id text)
returns table(user_id uuid, seat_no int, passcode text, nickname text, last_sign_in_at timestamptz, entries bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query select s.user_id, s.seat_no, s.passcode, s.nickname, u.last_sign_in_at,
      (select count(*) from lab_entries e where e.user_id = s.user_id)
    from seats s join auth.users u on u.id = s.user_id where s.class_id = p_class_id order by s.seat_no;
end $$;

create or replace function public.my_seat()
returns table(class_name text, seat_no int, nickname text, archived boolean)
language sql stable security definer set search_path = public as $$
  select c.name, s.seat_no, s.nickname, c.archived from seats s join classes c on c.id = s.class_id where s.user_id = auth.uid()
$$;

-- Seats may delete their own account since 2026-11-21: delete_my_account (defined once, above) no longer refuses them.

revoke execute on function public.gen_passcode(text) from public, anon;
revoke execute on function public.seat_email(text) from public, anon;
grant execute on function public.seat_email(text) to authenticated;
-- ============================================================
-- Account-locked access: classes (groups) and individual accounts per item
-- ============================================================
create table if not exists public.item_users (
  item_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (item_id, user_id)
);
alter table public.item_users enable row level security;
drop policy if exists "admin all item_users" on public.item_users;
create policy "admin all item_users" on public.item_users for all using (is_admin()) with check (is_admin());
drop policy if exists "student reads own item_users" on public.item_users;
create policy "student reads own item_users" on public.item_users for select using (user_id = auth.uid());
drop policy if exists "student reads item_groups" on public.item_groups;
create policy "student reads item_groups" on public.item_groups for select
  using (exists (select 1 from public.group_members gm where gm.group_id = item_groups.group_id and gm.user_id = auth.uid()));

create or replace function public.student_allowed(p_governing_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    exists (select 1 from item_groups ig join group_members gm on gm.group_id = ig.group_id
            where ig.item_id = p_governing_id and gm.user_id = auth.uid())
    or exists (select 1 from item_users iu where iu.item_id = p_governing_id and iu.user_id = auth.uid()))
$$;

create or replace function public.resolve_folder_governing(p_folder_id text)
returns table(level text, governing_id text)
language plpgsql stable security definer set search_path = public as $$
declare v_level text; v_parent text := p_folder_id; v_id text; v_depth int := 0;
begin
  while v_parent is not null and v_depth < 20 loop
    select f.access, f.parent_id, f.id into v_level, v_parent, v_id from folders f where f.id = v_parent;
    if v_level is null then exit; end if;
    if v_level <> 'inherit' then level := v_level; governing_id := v_id; return next; return; end if;
    v_depth := v_depth + 1;
  end loop;
  level := 'public'; governing_id := null; return next;
end $$;

create or replace function public.item_visible(p_level text, p_governing_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when is_admin() then true
    when p_level = 'admin' then false
    when p_level = 'accounts' then student_allowed(p_governing_id)
    else true end
$$;

drop policy if exists "read folders" on public.folders;
create policy "read folders" on public.folders for select
  using (is_admin() or (select item_visible(r.level, r.governing_id) from resolve_folder_governing(id) r));

drop policy if exists "read lab catalogue" on public.labs;
create policy "read lab catalogue" on public.labs for select
  using (is_admin() or (lab_is_live(status, publish_at) and (select item_visible(r.level, r.governing_id) from resolve_access(id) r)));

drop policy if exists "read public content" on public.lab_content;
create policy "read public content" on public.lab_content for select
  using (is_admin() or exists (
    select 1 from labs l where l.id = lab_content.lab_id and lab_is_live(l.status, l.publish_at)
      and (select r.level = 'public' or (r.level = 'accounts' and student_allowed(r.governing_id)) from resolve_access(l.id) r)));

drop policy if exists "read public attachments" on public.attachments;
create policy "read public attachments" on public.attachments for select
  using (is_admin() or exists (
    select 1 from labs l where l.id = attachments.lab_id and lab_is_live(l.status, l.publish_at)
      and (select r.level = 'public' or (r.level = 'accounts' and student_allowed(r.governing_id)) from resolve_access(l.id) r)));

-- Admin helper: everyone who can be put on an access list
create or replace function public.list_account_choices()
returns table(user_id uuid, label text, kind text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query
    select s.user_id, coalesce(nullif(s.full_name, ''), s.email) || case when s.full_name is not null and s.full_name <> '' then ' (' || s.email || ')' else '' end, 'google'::text
    from students s where coalesce(s.email, '') not like '%@seats.ohschemlabs.com'
      and coalesce((select u.raw_app_meta_data->>'role' from auth.users u where u.id = s.user_id), '') <> 'admin'
    order by 2;
end $$;


-- ============================================================
-- GET HELP: one private thread per student per lab, live in both directions,
-- with an instant email to the admins on every student message.
-- Idempotent. Run in the Supabase SQL editor (also appended to schema.sql).
-- ============================================================

alter table public.labs add column if not exists help_enabled boolean not null default false;

create table if not exists public.help_threads (
  id             bigint generated always as identity primary key,
  lab_id         text not null references public.labs(id) on delete cascade,
  user_id        uuid not null references auth.users(id) on delete cascade,   -- deleting the account wipes the thread
  status         text not null default 'open' check (status in ('open','resolved')),
  unread_admin   boolean not null default true,
  unread_student boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (lab_id, user_id)
);
create table if not exists public.help_messages (
  id         bigint generated always as identity primary key,
  thread_id  bigint not null references public.help_threads(id) on delete cascade,
  user_id    uuid references auth.users(id) on delete set null,
  role       text not null check (role in ('student','admin')),
  body       text not null check (char_length(body) between 1 and 4000),
  block      text,                                  -- where in the lab the student was stuck (free text)
  created_at timestamptz not null default now()
);
create index if not exists help_messages_thread_idx on public.help_messages (thread_id, created_at);
create index if not exists help_threads_lab_idx on public.help_threads (lab_id, updated_at desc);
alter table public.help_threads  replica identity full;   -- realtime UPDATE events carry the whole row, so filters work
alter table public.help_messages replica identity full;

alter table public.help_threads  enable row level security;
alter table public.help_messages enable row level security;

-- Students read their own thread and its messages; every write goes through the functions below.
drop policy if exists "student reads own thread" on public.help_threads;
create policy "student reads own thread" on public.help_threads for select using (user_id = auth.uid());
drop policy if exists "admin all threads" on public.help_threads;
create policy "admin all threads" on public.help_threads for all using (is_admin()) with check (is_admin());
drop policy if exists "student reads own messages" on public.help_messages;
create policy "student reads own messages" on public.help_messages for select
  using (exists (select 1 from public.help_threads t where t.id = thread_id and t.user_id = auth.uid()));
drop policy if exists "admin all messages" on public.help_messages;
create policy "admin all messages" on public.help_messages for all using (is_admin()) with check (is_admin());

-- Who a thread belongs to, as the admin sees it: "Period 3 · Seat 12 (nickname)" for seats, the name for Google accounts.
create or replace function public.help_thread_who(p_thread bigint) returns text
language sql stable security definer set search_path = public as $$
  select case
    when s.user_id is not null then c.name || ' · Seat ' || s.seat_no || coalesce(' (' || nullif(s.nickname, '') || ')', '')
    else coalesce(nullif(st.full_name, ''), 'Student')
  end
  from help_threads t
  left join seats s on s.user_id = t.user_id
  left join classes c on c.id = s.class_id
  left join students st on st.user_id = t.user_id
  where t.id = p_thread
$$;
revoke execute on function public.help_thread_who(bigint) from public, anon, authenticated;   -- admin list and email trigger only (they run as owner)

-- Student sends a question (creates the thread on first use). Reopens a resolved thread.
create or replace function public.help_post(p_lab_id text, p_body text, p_block text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_thread bigint; v_count int; v_body text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if is_admin() then raise exception 'admins reply from the Help panel'; end if;
  v_body := left(trim(coalesce(p_body, '')), 4000);
  if v_body = '' then raise exception 'empty message'; end if;
  if not exists (select 1 from labs where id = p_lab_id and help_enabled) then raise exception 'help is not enabled for this lab'; end if;
  select count(*) into v_count from help_messages m join help_threads t on t.id = m.thread_id
    where t.user_id = auth.uid() and m.role = 'student' and m.created_at > now() - interval '1 day';
  if v_count >= 40 then raise exception 'too many messages today; try again tomorrow'; end if;
  insert into help_threads (lab_id, user_id) values (p_lab_id, auth.uid())
    on conflict (lab_id, user_id) do update set status = 'open', unread_admin = true, updated_at = now()
    returning id into v_thread;
  insert into help_messages (thread_id, user_id, role, body, block)
    values (v_thread, auth.uid(), 'student', v_body, nullif(left(trim(coalesce(p_block, '')), 200), ''));
  return v_thread;
end $$;
revoke execute on function public.help_post(text, text, text) from public, anon;
grant execute on function public.help_post(text, text, text) to authenticated;

-- Admin replies.
create or replace function public.help_reply(p_thread bigint, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_body text;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  v_body := left(trim(coalesce(p_body, '')), 4000);
  if v_body = '' then raise exception 'empty message'; end if;
  insert into help_messages (thread_id, user_id, role, body) values (p_thread, auth.uid(), 'admin', v_body) returning id into v_id;
  update help_threads set unread_student = true, unread_admin = false, updated_at = now() where id = p_thread;
  return v_id;
end $$;
revoke execute on function public.help_reply(bigint, text) from public, anon;
grant execute on function public.help_reply(bigint, text) to authenticated;

create or replace function public.help_set_status(p_thread bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if p_status not in ('open', 'resolved') then raise exception 'bad status'; end if;
  update help_threads set status = p_status, unread_admin = false, updated_at = now() where id = p_thread;
end $$;
revoke execute on function public.help_set_status(bigint, text) from public, anon;
grant execute on function public.help_set_status(bigint, text) to authenticated;

-- Marks the thread read for whoever is calling (student clears unread_student, admin clears unread_admin).
create or replace function public.help_seen(p_thread bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if is_admin() then update help_threads set unread_admin = false where id = p_thread;
  else update help_threads set unread_student = false where id = p_thread and user_id = auth.uid(); end if;
end $$;
revoke execute on function public.help_seen(bigint) from public, anon;
grant execute on function public.help_seen(bigint) to authenticated;

-- Admin list: every thread with who it belongs to and its latest message.
create or replace function public.list_help_threads()
returns table(id bigint, lab_id text, user_id uuid, status text, unread_admin boolean, unread_student boolean, created_at timestamptz, updated_at timestamptz,
              who text, class_id text, last_body text, last_role text, last_block text, last_at timestamptz, messages bigint)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query
    select t.id, t.lab_id, t.user_id, t.status, t.unread_admin, t.unread_student, t.created_at, t.updated_at,
           help_thread_who(t.id), s.class_id,
           m.body, m.role, m.block, m.created_at,
           (select count(*) from help_messages x where x.thread_id = t.id)
    from help_threads t
    left join seats s on s.user_id = t.user_id
    left join lateral (select x.body, x.role, x.block, x.created_at from help_messages x where x.thread_id = t.id order by x.created_at desc limit 1) m on true
    order by t.updated_at desc;
end $$;
revoke execute on function public.list_help_threads() from public, anon;
grant execute on function public.list_help_threads() to authenticated;

-- Live updates: both tables in the realtime publication (RLS still applies to what each client receives).
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'help_messages') then
    alter publication supabase_realtime add table public.help_messages;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'help_threads') then
    alter publication supabase_realtime add table public.help_threads;
  end if;
end $$;

-- Instant email on every student message, sent through Resend from inside the database.
-- Needs: the pg_net extension, a Vault secret named resend_api_key, and the sending domain verified in Resend.
-- Recipients / sender / subject come from site_content (editable in Site text); defaults below.
create extension if not exists pg_net;
-- Per-lab choice of which admins get the email for a student's question (admin-only table; empty = no email).
create table if not exists public.help_notify (
  lab_id  text not null references public.labs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (lab_id, user_id)
);
alter table public.help_notify enable row level security;
drop policy if exists "admin all help_notify" on public.help_notify;
create policy "admin all help_notify" on public.help_notify for all using (is_admin()) with check (is_admin());

create or replace function public.help_notify() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_key text; v_from text; v_subject text; v_lab text; v_who text; v_text text; v_recipients jsonb;
begin
  if new.role <> 'student' then return new; end if;
  select jsonb_agg(u.email) into v_recipients
    from help_threads t join help_notify n on n.lab_id = t.lab_id join auth.users u on u.id = n.user_id
    where t.id = new.thread_id and u.email is not null;
  if v_recipients is null then return new; end if;   -- nobody ticked for this lab
  begin
    select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  exception when others then v_key := null; end;
  if coalesce(v_key, '') = '' then return new; end if;
  select coalesce((select value from site_content where key = 'helpEmailFrom'), 'OHS Chem Labs <help@ohschemlabs.com>') into v_from;
  select coalesce((select value from site_content where key = 'helpEmailSubject'), 'Help request: {lab}') into v_subject;
  select l.title into v_lab from help_threads t join labs l on l.id = t.lab_id where t.id = new.thread_id;
  v_who := coalesce(help_thread_who(new.thread_id), 'A student');
  v_subject := replace(replace(v_subject, '{lab}', coalesce(v_lab, 'Lab')), '{who}', v_who);
  v_text := v_who || ' asked for help on "' || coalesce(v_lab, 'a lab') || '".'
         || case when new.block is not null then E'\nWhere: ' || new.block else '' end
         || E'\n\n' || new.body
         || E'\n\nReply on the site: https://ohschemlabs.com/#/help/' || new.thread_id;
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json'),
    body := jsonb_build_object('from', v_from, 'to', v_recipients, 'subject', v_subject, 'text', v_text)
  );
  return new;
exception when others then
  raise warning 'help_notify failed: %', sqlerrm;
  return new;
end $$;
drop trigger if exists help_notify_tr on public.help_messages;
create trigger help_notify_tr after insert on public.help_messages for each row execute function public.help_notify();
-- Automatic first reply in a help thread (per-lab text, site default from site_content.helpAutoReply).
alter table public.labs add column if not exists help_auto_reply text;
alter table public.help_messages drop constraint if exists help_messages_role_check;
alter table public.help_messages add constraint help_messages_role_check check (role in ('student', 'admin', 'auto'));

create or replace function public.help_post(p_lab_id text, p_body text, p_block text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_thread bigint; v_count int; v_body text; v_existing record; v_auto text; v_send_auto boolean := false;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if is_admin() then raise exception 'admins reply from the Help panel'; end if;
  v_body := left(trim(coalesce(p_body, '')), 4000);
  if v_body = '' then raise exception 'empty message'; end if;
  if not exists (select 1 from labs where id = p_lab_id and help_enabled) then raise exception 'help is not enabled for this lab'; end if;
  select count(*) into v_count from help_messages m join help_threads t on t.id = m.thread_id
    where t.user_id = auth.uid() and m.role = 'student' and m.created_at > now() - interval '1 day';
  if v_count >= 40 then raise exception 'too many messages today; try again tomorrow'; end if;
  select id, status into v_existing from help_threads where lab_id = p_lab_id and user_id = auth.uid();
  v_send_auto := v_existing.id is null or v_existing.status = 'resolved';   -- first question, or a question after the thread was closed
  insert into help_threads (lab_id, user_id) values (p_lab_id, auth.uid())
    on conflict (lab_id, user_id) do update set status = 'open', unread_admin = true, updated_at = now()
    returning id into v_thread;
  insert into help_messages (thread_id, user_id, role, body, block)
    values (v_thread, auth.uid(), 'student', v_body, nullif(left(trim(coalesce(p_block, '')), 200), ''));
  if v_send_auto then
    select coalesce(nullif(trim(l.help_auto_reply), ''), (select value from site_content where key = 'helpAutoReply'),
                    'One of your TAs has been notified and will help you soon.')
      into v_auto from labs l where l.id = p_lab_id;
    if coalesce(v_auto, '') <> '' then
      insert into help_messages (thread_id, user_id, role, body) values (v_thread, null, 'auto', left(v_auto, 4000));
    end if;
  end if;
  return v_thread;
end $$;
-- Per-account preferences (today: the colour theme). Students and admins alike; one row per user.
create table if not exists public.user_prefs (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  theme      text,
  updated_at timestamptz not null default now()
);
alter table public.user_prefs enable row level security;
drop policy if exists "own prefs" on public.user_prefs;
create policy "own prefs" on public.user_prefs for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Optional write-up time estimate shown beside the procedure time.
alter table public.labs add column if not exists report_minutes integer;

-- Cover zoom (percent) on cards.
alter table public.labs add column if not exists cover_zoom integer not null default 100;
alter table public.folders add column if not exists cover_zoom integer not null default 100;
-- Student lab photos live in the private bucket under photos/<user_id>/<lab_id>/<photo_id>.jpg.
-- A signed-in student manages only their own folder; admins already have select/delete on the private bucket.
drop policy if exists "student manages own photos" on storage.objects;
create policy "student manages own photos" on storage.objects for all to authenticated
  using (bucket_id = 'lab-files-private' and (storage.foldername(name))[1] = 'photos' and (storage.foldername(name))[2] = auth.uid()::text)
  with check (bucket_id = 'lab-files-private' and (storage.foldername(name))[1] = 'photos' and (storage.foldername(name))[2] = auth.uid()::text);


-- ============================================================
-- EDITORS (owner, 2026-11-22). Replaces beta mode (2026-11-21). Idempotent: safe to run again. Also in schema.sql.
--
-- Every lab and every folder has a "who can edit" list of classes and accounts, kept by admins (item_edit_groups and
-- item_edit_users). There is no separate kind of user: an editor is an ordinary user (they see exactly what the access
-- settings let any user see, and never drafts) who is on such a list. Class-code accounts count, so a whole class can edit.
--   * on a lab's list: edit that lab's title, summary, tags, times, cover, photos, files and procedure;
--   * on a folder's list (it covers everything inside the folder, subfolders included): also create labs there (born
--     published, with the folder's access), move labs between folders they can edit, reorder them and delete them.
-- Being on a list never lets anyone SEE anything: the lab or folder must also be visible to them the ordinary way.
-- An editor can never change who sees a lab (access, status, publish date) or who edits it, never creates or edits
-- folders, and has no route to student data: every right below is a narrow function, and the tables themselves stay
-- admin-write-only. Nothing here widens what any role may READ.
-- ============================================================

alter table public.lab_revisions add column if not exists saved_by uuid default auth.uid();   -- who made the save this revision precedes

create table if not exists public.item_edit_groups (
  item_id  text not null,                                             -- a lab id or a folder id
  group_id text not null references public.groups(id) on delete cascade,
  primary key (item_id, group_id)
);
create table if not exists public.item_edit_users (
  item_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (item_id, user_id)
);
alter table public.item_edit_groups enable row level security;
alter table public.item_edit_users  enable row level security;
-- Only admins read or write the lists (Supabase no longer grants new tables to the API roles by itself, so the grants are
-- spelled out). Everyone else reaches them only through the functions below.
revoke all on public.item_edit_groups, public.item_edit_users from anon, authenticated;
grant select, insert, update, delete on public.item_edit_groups, public.item_edit_users to authenticated, service_role;
drop policy if exists "admin all item_edit_groups" on public.item_edit_groups;
create policy "admin all item_edit_groups" on public.item_edit_groups for all using (is_admin()) with check (is_admin());
drop policy if exists "admin all item_edit_users" on public.item_edit_users;
create policy "admin all item_edit_users" on public.item_edit_users for all using (is_admin()) with check (is_admin());

-- ---- Carry beta mode over, once: each beta user becomes an editor of each lab and folder that was marked beta editable.
do $carry$
begin
  if to_regclass('public.beta_users') is not null
     and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'labs' and column_name = 'beta_editable')
     and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'folders' and column_name = 'beta_editable') then
    execute $q$
      insert into public.item_edit_users (item_id, user_id)
      select i.id, b.user_id from public.beta_users b
        cross join (select id from public.labs where beta_editable union all select id from public.folders where beta_editable) i
      on conflict do nothing $q$;
  end if;
end $carry$;

-- ---- Beta mode is gone. (The beta_editable columns on labs and folders are left in place, unused, so that an admin page
-- opened before this change can still save. Drop them later: alter table public.labs drop column if exists beta_editable;
-- alter table public.folders drop column if exists beta_editable;)
drop policy if exists "beta adds lab files" on storage.objects;
drop policy if exists "beta deletes lab files" on storage.objects;
drop function if exists public.beta_can_add_file(text, text);
drop function if exists public.beta_lab_work_keys(text);
drop function if exists public.beta_remove_lab(text, boolean);
drop function if exists public.beta_set_lab_order(text, int);
drop function if exists public.beta_save_lab(jsonb, jsonb, jsonb);
drop function if exists public.beta_can_edit_lab(text);
drop function if exists public.beta_can_use_folder(text);
drop function if exists public.folder_in_beta(text);
drop function if exists public.list_beta_users();
drop function if exists public.set_beta(text, boolean);
drop function if exists public.is_beta();
drop function if exists public.beta_ok_media(text);
drop table if exists public.beta_users;

-- Is the caller on this one item's edit list, by account or through a class?
create or replace function public.edit_granted(p_item_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and p_item_id is not null and (
    exists (select 1 from item_edit_users iu where iu.item_id = p_item_id and iu.user_id = auth.uid())
    or exists (select 1 from item_edit_groups ig join group_members gm on gm.group_id = ig.group_id
               where ig.item_id = p_item_id and gm.user_id = auth.uid()))
$$;
revoke execute on function public.edit_granted(text) from public, anon, authenticated;

-- A folder's edit list covers everything inside it: is the caller on the list of this folder or of any folder above it?
create or replace function public.folder_edit_granted(p_folder_id text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_id text := p_folder_id; v_parent text; v_depth int := 0;
begin
  while v_id is not null and v_depth < 20 loop
    select f.parent_id into v_parent from folders f where f.id = v_id;
    if not found then return false; end if;
    if edit_granted(v_id) then return true; end if;
    v_id := v_parent; v_depth := v_depth + 1;
  end loop;
  return false;
end $$;
revoke execute on function public.folder_edit_granted(text) from public, anon, authenticated;

-- What an ORDINARY user may see. Deliberately not item_visible(): that one says yes to admins, and edit rights must never
-- lean on admin rights.
create or replace function public.plain_visible(p_level text, p_governing_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(p_level = 'public' or (p_level = 'accounts' and student_allowed(p_governing_id)), false)
$$;
revoke execute on function public.plain_visible(text, text) from public, anon, authenticated;

-- May the caller create labs in the folder, and move labs into or out of it?
create or replace function public.editor_can_use_folder(p_folder_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_folder_id is not null and folder_edit_granted(p_folder_id)
     and coalesce((select plain_visible(r.level, r.governing_id) from resolve_folder_governing(p_folder_id) r), false)
$$;

-- May the caller edit the lab? It must be live and visible to them as an ordinary user, and they must be on its own edit
-- list or on the list of a folder it sits in.
create or replace function public.editor_can_edit_lab(p_lab_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (
    select 1 from labs l where l.id = p_lab_id
      and lab_is_live(l.status, l.publish_at)
      and (edit_granted(l.id) or folder_edit_granted(l.folder_id))
      and coalesce((select plain_visible(r.level, r.governing_id) from resolve_access(l.id) r), false))
$$;

grant execute on function public.editor_can_use_folder(text), public.editor_can_edit_lab(text) to authenticated;   -- the storage rules below call them as the signed-in user

-- For the site's buttons: the folders the caller may add labs to and the labs they may edit. Empty for nearly everyone.
create or replace function public.my_edit_rights() returns table(kind text, item text)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not (
       exists (select 1 from item_edit_users iu where iu.user_id = auth.uid())
       or exists (select 1 from item_edit_groups ig join group_members gm on gm.group_id = ig.group_id where gm.user_id = auth.uid())) then
    return;
  end if;
  return query select 'folder'::text, f.id from folders f where editor_can_use_folder(f.id);
  return query select 'lab'::text, l.id from labs l where editor_can_edit_lab(l.id);
end $$;
revoke execute on function public.my_edit_rights() from public, anon;
grant execute on function public.my_edit_rights() to authenticated;

-- A media or cover entry as the site writes them: 'youtube:<id>', or '[img:]<path or URL>[|alt text]'. No quotes, angle
-- brackets, backslashes or control characters in the path; no control characters or backslashes in the alt text.
create or replace function public.editor_ok_media(p text) returns boolean
language sql immutable as $$
  select p is not null and length(p) <= 900 and (
    p ~ '^youtube:[A-Za-z0-9_-]{6,20}$'
    or (p !~ '^youtube:' and length(split_part(p, '|', 1)) <= 600 and split_part(p, '|', 1) ~ '^(img:)?[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$'   -- (Postgres caps a {n,m} count at 255, hence the separate length test)
        and substr(p, length(split_part(p, '|', 1)) + 2) !~ '[[:cntrl:]\\]'))
$$;

-- An editor's save: an existing lab the caller may edit, or a new lab inside a folder they may edit. Returns the lab's slug.
create or replace function public.editor_save_lab(p_lab jsonb, p_content jsonb, p_attachments jsonb default '[]'::jsonb)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id      text := p_lab->>'id';
  v_old     labs%rowtype;
  v_exists  boolean;
  v_folder  text := nullif(p_lab->>'folder_id', '');
  v_title   text := trim(coalesce(p_lab->>'title', ''));
  v_summary text := nullif(trim(coalesce(p_lab->>'summary', '')), '');
  v_slug    text;
  v_base    text;
  v_n       int := 1;
  v_format  text := coalesce(p_content->>'format', 'labtags');
  v_text    text := nullif(p_content->>'content', '');
  v_media   text[] := coalesce((select array_agg(x.v order by x.ord) from jsonb_array_elements_text(coalesce(p_content->'media', '[]'::jsonb)) with ordinality x(v, ord)), '{}');
  v_tags    text[] := coalesce((select array_agg(trim(x.v) order by x.ord) from jsonb_array_elements_text(coalesce(p_lab->'tags', '[]'::jsonb)) with ordinality x(v, ord) where trim(x.v) <> ''), '{}');
  v_cover   text := nullif(p_lab->>'cover_path', '');
  v_zoom    int := least(400, greatest(50, coalesce(nullif(p_lab->>'cover_zoom', '')::int, 100)));
  v_minutes int := nullif(p_lab->>'estimated_minutes', '')::int;
  v_report  int := nullif(p_lab->>'report_minutes', '')::int;
  v_order   int := coalesce(nullif(p_lab->>'sort_order', '')::int, 0);
  v_ids     text[] := '{}';
  a         jsonb;
  v_i       int := 0;
  v_aid     text; v_path text; v_name text;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if v_id is null or v_id !~ '^l-[A-Za-z0-9_-]{1,40}$' then raise exception 'bad lab id'; end if;
  if v_title = '' or length(v_title) > 200 then raise exception 'A lab needs a title of at most 200 characters.'; end if;
  if length(coalesce(v_summary, '')) > 1000 then raise exception 'The summary is too long.'; end if;
  if v_format not in ('html', 'labtags') then raise exception 'bad format'; end if;
  if length(coalesce(v_text, '')) > 2000000 then raise exception 'This lab is too large to save.'; end if;
  if coalesce(array_length(v_tags, 1), 0) > 40 or exists (select 1 from unnest(v_tags) t where length(t) > 60 or t ~ '[[:cntrl:]]') then raise exception 'bad tags'; end if;
  if v_cover is not null and not editor_ok_media(v_cover) then raise exception 'bad cover image'; end if;
  if coalesce(array_length(v_media, 1), 0) > 60 or exists (select 1 from unnest(v_media) x where not editor_ok_media(x)) then raise exception 'bad photo or video entry'; end if;
  if jsonb_typeof(coalesce(p_attachments, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_attachments, '[]'::jsonb)) > 40 then raise exception 'bad file list'; end if;

  select * into v_old from labs where id = v_id;
  v_exists := found;
  if v_exists then
    if not editor_can_edit_lab(v_id) then raise exception 'You cannot edit this lab.'; end if;
    if v_folder is distinct from v_old.folder_id and not (editor_can_use_folder(v_old.folder_id) and editor_can_use_folder(v_folder)) then
      raise exception 'A lab can only be moved between folders you can edit.';
    end if;
    insert into lab_revisions (lab_id, snapshot, note, saved_by) values (v_id, jsonb_build_object(
      'lab', to_jsonb(v_old),
      'content', (select to_jsonb(c) || jsonb_build_object('attachments', coalesce((select jsonb_agg(to_jsonb(t) order by t.sort_order) from attachments t where t.lab_id = v_id), '[]'::jsonb))
                  from lab_content c where c.lab_id = v_id)), 'before editor save', auth.uid());
    update labs set title = v_title, folder_id = v_folder, summary = v_summary, cover_path = v_cover, cover_zoom = v_zoom, tags = v_tags,
      estimated_minutes = v_minutes, report_minutes = v_report,
      sort_order = case when editor_can_use_folder(v_old.folder_id) then v_order else v_old.sort_order end   -- a lab they edit on its own list stays where it is
      where id = v_id;   -- never status, publish_at, access or slug
    v_slug := v_old.slug;
  else
    if v_id !~ '^l-[0-9]{10,16}$' then raise exception 'bad lab id'; end if;
    if not editor_can_use_folder(v_folder) then raise exception 'New labs can only be created inside a folder you can edit.'; end if;
    v_base := trim(both '-' from regexp_replace(lower(coalesce(nullif(p_lab->>'slug', ''), v_title)), '[^a-z0-9]+', '-', 'g'));
    if v_base = '' then v_base := 'lab'; end if;
    v_base := left(v_base, 80); v_slug := v_base;
    while exists (select 1 from labs where slug = v_slug) loop v_n := v_n + 1; v_slug := v_base || '-' || v_n; end loop;
    -- Born published with the folder's access: an editor never sees drafts and never chooses who sees a lab.
    insert into labs (id, folder_id, title, slug, summary, cover_path, cover_zoom, status, access, tags, estimated_minutes, report_minutes, sort_order)
      values (v_id, v_folder, v_title, v_slug, v_summary, v_cover, v_zoom, 'published', 'inherit', v_tags, v_minutes, v_report, v_order);
  end if;

  insert into lab_content (lab_id, media, content, format) values (v_id, v_media, v_text, v_format)
    on conflict (lab_id) do update set media = excluded.media, content = excluded.content, format = excluded.format;

  for a in select * from jsonb_array_elements(coalesce(p_attachments, '[]'::jsonb)) loop
    v_i := v_i + 1; v_aid := a->>'id'; v_path := a->>'path'; v_name := left(trim(coalesce(a->>'name', '')), 200);
    if v_aid is null or v_aid !~ '^[A-Za-z0-9_-]{1,60}$' then raise exception 'bad file id'; end if;
    if exists (select 1 from attachments t where t.id = v_aid and t.lab_id <> v_id) then raise exception 'bad file id'; end if;
    -- A new file must sit in this lab's own storage folder; a file already attached to this lab keeps the path it has.
    if not exists (select 1 from attachments t where t.id = v_aid and t.lab_id = v_id and t.path = v_path)
       and (v_path is null or v_path !~ ('^labs/' || v_id || '/[A-Za-z0-9._-]{1,200}$')) then raise exception 'bad file path'; end if;
    if v_name = '' then v_name := 'File'; end if;
    if v_name ~ '[[:cntrl:]]' or coalesce(a->>'mime', '') !~ '^[A-Za-z0-9.+/-]{0,100}$' then raise exception 'bad file'; end if;
    insert into attachments (id, lab_id, name, path, mime, size_bytes, sort_order)
      values (v_aid, v_id, v_name, v_path, nullif(a->>'mime', ''), greatest(0, coalesce(nullif(a->>'size_bytes', '')::bigint, 0)), v_i)
      on conflict (id) do update set name = excluded.name, mime = excluded.mime, size_bytes = excluded.size_bytes, sort_order = excluded.sort_order;
    v_ids := v_ids || v_aid;
  end loop;
  delete from attachments where lab_id = v_id and not (id = any(v_ids));
  return v_slug;
end $$;
revoke execute on function public.editor_save_lab(jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.editor_save_lab(jsonb, jsonb, jsonb) to authenticated;

-- Where a lab sits among its neighbours (the arrows on the cards). Only for labs inside a folder the caller may edit.
create or replace function public.editor_set_lab_order(p_lab_id text, p_order int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (editor_can_edit_lab(p_lab_id) and editor_can_use_folder((select folder_id from labs where id = p_lab_id))) then
    raise exception 'Only labs inside a folder you can edit can be reordered.';
  end if;
  update labs set sort_order = p_order where id = p_lab_id;
end $$;
revoke execute on function public.editor_set_lab_order(text, int) from public, anon;
grant execute on function public.editor_set_lab_order(text, int) to authenticated;

-- An editor deletes a lab inside a folder they may edit. This is a real deletion (owner, 2026-11-22: deleted labs need not
-- be restorable): the lab, its procedure, its revisions and its file list go. Refused when anyone ELSE has saved work,
-- a Get help thread or a Socratic 1 session in the lab; only an admin can delete such a lab. p_check = true only asks.
create or replace function public.editor_delete_lab(p_lab_id text, p_check boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (editor_can_edit_lab(p_lab_id) and editor_can_use_folder((select folder_id from labs where id = p_lab_id))) then
    raise exception 'Only labs inside a folder you can edit can be deleted.';
  end if;
  if exists (select 1 from lab_entries e where e.lab_id = p_lab_id and e.user_id <> auth.uid())
     or exists (select 1 from help_threads h where h.lab_id = p_lab_id and h.user_id <> auth.uid())
     or exists (select 1 from oral_sessions o where o.lab_id = p_lab_id and o.user_id <> auth.uid()) then
    raise exception 'Someone else has saved work in this lab, so only the site owner can delete it.';
  end if;
  if p_check then return; end if;
  delete from labs where id = p_lab_id;
end $$;
revoke execute on function public.editor_delete_lab(text, boolean) from public, anon;
grant execute on function public.editor_delete_lab(text, boolean) to authenticated;

-- For the editor's saved-work guard: WHICH of this lab's blanks hold saved work. Block ids only (the editor wrote them):
-- no values, no counts, no accounts.
create or replace function public.editor_lab_work_keys(p_lab_id text) returns table(key text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not editor_can_edit_lab(p_lab_id) then raise exception 'You cannot edit this lab.'; end if;
  return query select distinct k.key from lab_entries e cross join lateral jsonb_each(e.data) k
    where e.lab_id = p_lab_id and left(k.key, 1) <> '_' and k.value not in ('""'::jsonb, 'null'::jsonb, '0'::jsonb);
end $$;
revoke execute on function public.editor_lab_work_keys(text) from public, anon;
grant execute on function public.editor_lab_work_keys(text) to authenticated;

-- A deleted lab or folder takes its edit list with it.
create or replace function public.clear_edit_lists() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from item_edit_groups where item_id = old.id;
  delete from item_edit_users  where item_id = old.id;
  return old;
end $$;
revoke execute on function public.clear_edit_lists() from public, anon, authenticated;
drop trigger if exists labs_clear_edit_lists on public.labs;
create trigger labs_clear_edit_lists after delete on public.labs for each row execute function public.clear_edit_lists();
drop trigger if exists folders_clear_edit_lists on public.folders;
create trigger folders_clear_edit_lists after delete on public.folders for each row execute function public.clear_edit_lists();

-- Files. An editor may add files only under labs/<lab id>/ in the PUBLIC bucket, for a lab they may edit or one they are
-- about to create (the id is not taken and they have a folder to put it in), and may delete files only of a lab they may
-- edit. Nothing here touches the private bucket, where students' photos live.
create or replace function public.editor_can_add_file(p_bucket text, p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_bucket = 'lab-files-public' and auth.uid() is not null
     and p_name ~ '^labs/l-[A-Za-z0-9_-]{1,40}/[A-Za-z0-9._-]{1,200}$'
     and (editor_can_edit_lab(split_part(p_name, '/', 2))
          or (split_part(p_name, '/', 2) ~ '^l-[0-9]{10,16}$'
              and not exists (select 1 from labs l where l.id = split_part(p_name, '/', 2))
              and exists (select 1 from folders f where editor_can_use_folder(f.id))))
$$;
grant execute on function public.editor_can_add_file(text, text) to authenticated;
drop policy if exists "editors add lab files" on storage.objects;
create policy "editors add lab files" on storage.objects for insert to authenticated
  with check (editor_can_add_file(bucket_id, name));
drop policy if exists "editors delete lab files" on storage.objects;
create policy "editors delete lab files" on storage.objects for delete to authenticated
  using (bucket_id = 'lab-files-public' and name ~ '^labs/l-[A-Za-z0-9_-]{1,40}/' and editor_can_edit_lab(split_part(name, '/', 2)));

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


-- ============================================================
-- Moving a student's lab work from one account to another, lab by lab (owner, 2026-11-22)
--
-- The Users panel's "Move labs between accounts" tool. An admin picks two accounts and ticks labs; each ticked lab's saved
-- entries go from the first account to the second. If the second account already has work on that lab, the two copies
-- TRADE PLACES, so nothing is ever deleted and running the same move again puts everything back.
--
-- Rules this file keeps:
--   * admin only (is_admin()), and neither account may be an admin;
--   * all labs of one move succeed or none do (one function call = one transaction);
--   * a lab that changed since the admin's list was loaded is refused (the saved-at times must still match);
--   * every moved copy is stamped as saved now and carries "_moved": <move id> in its data. The site keeps the newest copy,
--     so a device still holding an older copy takes the moved one, and the changed "_moved" tells that device to put its
--     own photos for the lab aside (see ltBind in index.html);
--   * the lab's help thread and Socratic 1 sessions go with it, toward the second account only. A help thread stays where
--     it is when the second account already has one for that lab. No session is ended or changed otherwise.
--
-- Photos are files in the private bucket (photos/<user>/<lab>/<slot>.jpg) and cannot be moved from SQL. The page copies
-- them to merge-hold/<move id>/ first, calls move_lab_work, then puts them in their new places and sets photos_done.
-- A row with photos_done = false is a move whose photos still have to be finished from the hold (the tool offers it).
--
-- Safe to run more than once.
-- ============================================================

create table if not exists public.entry_moves (
  move_id        text not null,
  lab_id         text not null,
  moved_at       timestamptz not null default now(),
  moved_by       uuid,
  from_user      uuid not null,                 -- no foreign keys: the record outlives a removed account
  to_user        uuid not null,
  action         text not null check (action in ('moved', 'swapped')),
  from_saved_at  timestamptz,                   -- when each copy had last been saved, before the move stamped it
  to_saved_at    timestamptz,
  from_photos    text[] not null default '{}',  -- file names that were in photos/<from_user>/<lab>/ before the move
  to_photos      text[] not null default '{}',
  threads_moved  int not null default 0,
  sessions_moved int not null default 0,
  photos_done    boolean not null default false,
  primary key (move_id, lab_id)
);
alter table public.entry_moves enable row level security;
revoke all on public.entry_moves from anon, authenticated;
grant select, insert, update, delete on public.entry_moves to authenticated, service_role;
drop policy if exists "admin all entry_moves" on public.entry_moves;
create policy "admin all entry_moves" on public.entry_moves for all using (is_admin()) with check (is_admin());

-- p_labs: [{ "lab_id": "...", "from_saved_at": "<updated_at as read>", "to_saved_at": "<updated_at as read>" | null,
--            "from_photos": ["a.jpg", …], "to_photos": […] }, …]
create or replace function public.move_lab_work(p_move_id text, p_from uuid, p_to uuid, p_labs jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_now   timestamptz := clock_timestamp();
  v_stamp jsonb := jsonb_build_object('_moved', p_move_id);
  v_item  jsonb; v_lab text; v_action text;
  v_fd jsonb; v_fu timestamptz; v_td jsonb; v_tu timestamptz; v_has_t boolean;
  v_tid bigint; v_threads int; v_sessions int;
  v_fp text[]; v_tp text[];
  v_out jsonb := '[]'::jsonb;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if p_move_id is null or p_move_id !~ '^mv-[0-9]{10,16}$' then raise exception 'bad move id'; end if;
  if p_from is null or p_to is null or p_from = p_to then raise exception 'Pick two different accounts.'; end if;
  if (select count(*) from auth.users where id in (p_from, p_to)) <> 2 then raise exception 'One of the accounts no longer exists.'; end if;
  if exists (select 1 from auth.users where id in (p_from, p_to) and coalesce(raw_app_meta_data ->> 'role', '') = 'admin') then
    raise exception 'An admin account cannot be part of a move.';
  end if;
  if p_labs is null or jsonb_typeof(p_labs) <> 'array' or jsonb_array_length(p_labs) = 0 then raise exception 'No labs were chosen.'; end if;
  if exists (select 1 from entry_moves where move_id = p_move_id) then raise exception 'This move was already carried out.'; end if;

  for v_item in select * from jsonb_array_elements(p_labs) loop
    v_lab := v_item ->> 'lab_id';
    if v_lab is null or v_lab = '' then raise exception 'A chosen lab has no id.'; end if;

    select data, updated_at into v_fd, v_fu from lab_entries where user_id = p_from and lab_id = v_lab for update;
    if not found then raise exception 'The first account no longer has saved work on one of the chosen labs (%). Reload the list.', v_lab; end if;
    select data, updated_at into v_td, v_tu from lab_entries where user_id = p_to and lab_id = v_lab for update;
    v_has_t := found;

    -- the admin chose from a list; refuse if either copy was saved again (or appeared, or vanished) since that list was read
    if (v_item ->> 'from_saved_at') is null or (v_item ->> 'from_saved_at')::timestamptz <> v_fu
       or (v_has_t and ((v_item ->> 'to_saved_at') is null or (v_item ->> 'to_saved_at')::timestamptz <> v_tu))
       or (not v_has_t and (v_item ->> 'to_saved_at') is not null) then
      raise exception 'One of the chosen labs (%) was saved again after the list was loaded. Reload the list and choose again.', v_lab;
    end if;

    if not v_has_t then
      update lab_entries set user_id = p_to, updated_at = v_now, data = coalesce(data, '{}'::jsonb) || v_stamp
        where user_id = p_from and lab_id = v_lab;
      v_action := 'moved'; v_tu := null;
    else   -- trade places: each row takes the other's data (the key (user_id, lab_id) of both rows stays as it is)
      update lab_entries set data = coalesce(v_fd, '{}'::jsonb) || v_stamp, updated_at = v_now where user_id = p_to and lab_id = v_lab;
      update lab_entries set data = coalesce(v_td, '{}'::jsonb) || v_stamp, updated_at = v_now where user_id = p_from and lab_id = v_lab;
      v_action := 'swapped';
    end if;

    -- the lab's help thread, toward the second account only, and only when that account has none for this lab
    v_threads := 0;
    if not exists (select 1 from help_threads where lab_id = v_lab and user_id = p_to) then
      update help_threads set user_id = p_to where lab_id = v_lab and user_id = p_from returning id into v_tid;
      if found then
        update help_messages set user_id = p_to where thread_id = v_tid and user_id = p_from;
        v_threads := 1;
      end if;
    end if;
    -- the lab's Socratic 1 sessions, toward the second account only; nothing about a session changes but its owner
    update oral_sessions set user_id = p_to where user_id = p_from and lab_id = v_lab;
    get diagnostics v_sessions = row_count;

    v_fp := array(select jsonb_array_elements_text(case when jsonb_typeof(v_item -> 'from_photos') = 'array' then v_item -> 'from_photos' else '[]'::jsonb end));
    v_tp := array(select jsonb_array_elements_text(case when jsonb_typeof(v_item -> 'to_photos') = 'array' then v_item -> 'to_photos' else '[]'::jsonb end));
    insert into entry_moves (move_id, lab_id, moved_at, moved_by, from_user, to_user, action, from_saved_at, to_saved_at, from_photos, to_photos, threads_moved, sessions_moved, photos_done)
      values (p_move_id, v_lab, v_now, auth.uid(), p_from, p_to, v_action, v_fu, v_tu, v_fp, v_tp, v_threads, v_sessions,
              coalesce(array_length(v_fp, 1), 0) = 0 and coalesce(array_length(v_tp, 1), 0) = 0);
    v_out := v_out || jsonb_build_object('lab_id', v_lab, 'action', v_action, 'threads', v_threads, 'sessions', v_sessions);
  end loop;
  return v_out;
end $$;
revoke all on function public.move_lab_work(text, uuid, uuid, jsonb) from public, anon;
grant execute on function public.move_lab_work(text, uuid, uuid, jsonb) to authenticated;


-- ============================================================
-- Stats: how activity is counted (owner, 2026-11-22). Replaces the first stats functions.
--
--   * A day is a calendar day at the school, which is on Pacific time ("the days should flip over at midnight west coast
--     time, because ohs is west coast time"). stats_tz() is the one place that says so.
--   * "Last n days" is n whole calendar days ending today, and stats_daily returns EVERY one of them, with zeros.
--   * A lab view is one student opening one lab on one day, however many tabs or reloads it took.
--   * Only lab events of signed-in accounts are counted: view, download, print. Folder pages and searches are not
--     recorded any more, and old rows of those kinds are ignored here.
--   * Events can only be logged by a signed-in account, under its own id.
--
-- Safe to run more than once. supabase/stats-test.sql checks the counting with made-up events.
-- ============================================================

create or replace function public.stats_tz() returns text language sql immutable as $$ select 'America/Los_Angeles'::text $$;
create or replace function public.stats_today() returns date language sql stable as $$ select (now() at time zone public.stats_tz())::date $$;

-- The counted events of the last n school days, each with its school day. Internal: not callable through the API.
create or replace function public.stats_events(n_days int)
returns table(day date, type text, lab_id text, visitor_id text)
language sql stable security definer set search_path = public as $$
  select (e.ts at time zone stats_tz())::date, e.type, e.lab_id, e.visitor_id
  from events e
  where e.lab_id is not null and e.visitor_id is not null and e.type in ('view', 'download', 'print')
    and e.ts >= (stats_today() - (least(greatest(coalesce(n_days, 30), 1), 366) - 1))::timestamp at time zone stats_tz()
$$;
revoke all on function public.stats_events(int) from public, anon, authenticated;

-- One row for every day of the range, busy or not.
create or replace function public.stats_daily(n_days int default 30)
returns table(day date, views bigint, visitors bigint)
language plpgsql stable security definer set search_path = public as $$
declare n int := least(greatest(coalesce(n_days, 30), 1), 366);
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query
    with d as (select g::date as day from generate_series(stats_today() - (n - 1), stats_today(), interval '1 day') g),
         v as (select e.day, count(distinct (e.visitor_id, e.lab_id)) filter (where e.type = 'view') as views, count(distinct e.visitor_id) as visitors
               from stats_events(n) e group by e.day)
    select d.day, coalesce(v.views, 0), coalesce(v.visitors, 0) from d left join v on v.day = d.day order by d.day;
end $$;

create or replace function public.stats_summary(n_days int default 30)
returns json
language plpgsql stable security definer set search_path = public as $$
declare n int := least(greatest(coalesce(n_days, 30), 1), 366); result json;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  select json_build_object(
    'views',     count(distinct (e.day, e.visitor_id, e.lab_id)) filter (where e.type = 'view'),
    'visitors',  count(distinct e.visitor_id),
    'downloads', count(*) filter (where e.type = 'download'),
    'prints',    count(*) filter (where e.type = 'print'),
    'days',      n,
    'today',     stats_today(),
    'first_day', (select min((x.ts at time zone stats_tz())::date) from events x),   -- when recording began
    'removed',   (select count(*) from (select distinct s.visitor_id from stats_events(n) s) v     -- counted accounts that have since been removed
                  where not exists (select 1 from auth.users u where u.id::text = v.visitor_id))
  ) into result
  from stats_events(n) e;
  return result;
end $$;

-- The row type gains "prints", so the old function has to go first.
drop function if exists public.stats_top_labs(int, int);
create function public.stats_top_labs(n_days int default 30, lim int default 20)
returns table(lab_id text, views bigint, downloads bigint, visitors bigint, prints bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query
    select e.lab_id,
           count(distinct (e.day, e.visitor_id)) filter (where e.type = 'view'),
           count(*) filter (where e.type = 'download'),
           count(distinct e.visitor_id),
           count(*) filter (where e.type = 'print')
    from stats_events(n_days) e
    group by e.lab_id order by 2 desc, e.lab_id limit lim;
end $$;

create or replace function public.stats_lab_daily(n_days int default 30)
returns table(lab_id text, day date, views bigint, visitors bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query
    select e.lab_id, e.day, count(distinct e.visitor_id) filter (where e.type = 'view'), count(distinct e.visitor_id)
    from stats_events(n_days) e
    group by e.lab_id, e.day order by e.lab_id, e.day;
end $$;

revoke all on function public.stats_daily(int), public.stats_summary(int), public.stats_top_labs(int, int), public.stats_lab_daily(int) from public, anon;
grant execute on function public.stats_daily(int), public.stats_summary(int), public.stats_top_labs(int, int), public.stats_lab_daily(int) to authenticated;

-- Logging: a signed-in account, its own id, a lab event. (The page never sent anything else for a visitor without an account;
-- now the database would not take it either.)
drop policy if exists "anyone logs events" on public.events;
drop policy if exists "students log own events" on public.events;
create policy "students log own events" on public.events for insert to authenticated
  with check (type in ('view', 'download', 'print') and lab_id is not null
              and coalesce(length(path), 0) <= 300 and visitor_id = auth.uid()::text);
