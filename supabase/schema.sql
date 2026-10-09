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
drop policy if exists "anyone logs events" on public.events;
create policy "anyone logs events" on public.events for insert
  with check (type in ('view','download','video_play','search','print','unlock')
              and coalesce(length(path), 0) <= 300);
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

-- ------------------------------------------------------------
-- Analytics aggregation (admin-guarded)
-- ------------------------------------------------------------
create or replace function public.stats_daily(n_days int default 30)
returns table(day date, views bigint, visitors bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query
    select e.ts::date, count(*) filter (where e.type = 'view'), count(distinct e.visitor_id)
    from events e
    where e.ts >= now() - make_interval(days => n_days)
    group by 1 order by 1;
end $$;

create or replace function public.stats_top_labs(n_days int default 30, lim int default 20)
returns table(lab_id text, views bigint, downloads bigint, visitors bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query
    select e.lab_id,
           count(*) filter (where e.type = 'view'),
           count(*) filter (where e.type = 'download'),
           count(distinct e.visitor_id)
    from events e
    where e.lab_id is not null and e.ts >= now() - make_interval(days => n_days)
    group by e.lab_id order by 2 desc limit lim;
end $$;

create or replace function public.stats_summary(n_days int default 30)
returns json
language plpgsql stable security definer set search_path = public as $$
declare result json;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  select json_build_object(
    'views',     count(*) filter (where e.type = 'view'),
    'downloads', count(*) filter (where e.type = 'download'),
    'unlocks',   count(*) filter (where e.type = 'unlock'),
    'visitors',  count(distinct e.visitor_id),
    'devices',   (select coalesce(json_object_agg(coalesce(d.device, 'unknown'), d.c), '{}'::json)
                  from (select device, count(*) c from events
                        where ts >= now() - make_interval(days => n_days) group by device) d)
  ) into result
  from events e where e.ts >= now() - make_interval(days => n_days);
  return result;
end $$;

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
drop policy if exists "student updates self" on public.students;
create policy "student updates self" on public.students for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- A student can delete their own account (cascades to students, lab_entries, group_members)
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if is_admin() then raise exception 'admin accounts cannot be deleted from the site'; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;


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

-- Per-lab daily views and unique visitors (Stats panel)
create or replace function public.stats_lab_daily(n_days int default 30)
returns table(lab_id text, day date, views bigint, visitors bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query
    select e.lab_id, e.ts::date, count(*) filter (where e.type = 'view'), count(distinct e.visitor_id)
    from events e
    where e.lab_id is not null and e.ts >= now() - make_interval(days => n_days)
    group by e.lab_id, e.ts::date order by e.lab_id, e.ts::date;
end $$;
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

-- Seats cannot delete themselves; their teacher manages them
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if is_admin() then raise exception 'admin accounts cannot be deleted from the site'; end if;
  if exists (select 1 from seats s where s.user_id = auth.uid()) then raise exception 'access code accounts are managed by the teacher'; end if;
  delete from auth.users where id = auth.uid();
end $$;

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
