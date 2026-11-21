-- ============================================================
-- BETA MODE (owner, 2026-11-21). Idempotent: safe to run again. Also appended to schema.sql.
--
-- A beta user is an ordinary user (they see exactly what the access settings let any user see, and never drafts) who may
-- also EDIT the labs and folders the owner has marked "beta editable", when they can see them:
--   * a lab marked beta editable, or a lab inside a beta-editable folder: edit its title, summary, tags, times, cover,
--     photos, files and procedure;
--   * inside a beta-editable folder (the switch covers everything inside it): also create labs (born published, with the
--     folder's access), move labs between beta folders they can use, reorder them and remove them.
-- A beta user can never change who sees a lab (access, status, publish date), never flips a beta switch, never creates or
-- edits folders, and has no route to student data: every right below is a narrow function, and the tables themselves stay
-- admin-write-only. Nothing here widens what any role may READ.
-- ============================================================

alter table public.folders       add column if not exists beta_editable boolean not null default false;
alter table public.labs          add column if not exists beta_editable boolean not null default false;
alter table public.lab_revisions add column if not exists saved_by uuid default auth.uid();   -- who made the save this revision precedes

-- Who is in beta. Reached only through the functions below (no API grants, RLS on with no policies), and checked on every
-- call, so removing someone takes effect at once (the admin role, by contrast, lives in the login token).
create table if not exists public.beta_users (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.beta_users enable row level security;
revoke all on public.beta_users from anon, authenticated;

create or replace function public.is_beta() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from beta_users b where b.user_id = auth.uid())
$$;

-- A folder is "in beta" when it, or any folder above it, has the switch on.
create or replace function public.folder_in_beta(p_folder_id text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_parent text := p_folder_id; v_beta boolean; v_depth int := 0;
begin
  while v_parent is not null and v_depth < 20 loop
    select f.beta_editable, f.parent_id into v_beta, v_parent from folders f where f.id = v_parent;
    if not found then return false; end if;
    if v_beta then return true; end if;
    v_depth := v_depth + 1;
  end loop;
  return false;
end $$;
revoke execute on function public.folder_in_beta(text) from public, anon, authenticated;

-- What an ORDINARY user may see. Deliberately not item_visible(): that one says yes to admins, and beta rights must never
-- lean on admin rights.
create or replace function public.plain_visible(p_level text, p_governing_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(p_level = 'public' or (p_level = 'accounts' and student_allowed(p_governing_id)), false)
$$;
revoke execute on function public.plain_visible(text, text) from public, anon, authenticated;

-- May this beta user create labs in the folder, and move labs into or out of it?
create or replace function public.beta_can_use_folder(p_folder_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_folder_id is not null and is_beta() and folder_in_beta(p_folder_id)
     and coalesce((select plain_visible(r.level, r.governing_id) from resolve_folder_governing(p_folder_id) r), false)
$$;

-- May this beta user edit the lab? It must be live and visible to them as an ordinary user, and beta editable itself or by its folder.
create or replace function public.beta_can_edit_lab(p_lab_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select is_beta() and exists (
    select 1 from labs l where l.id = p_lab_id
      and lab_is_live(l.status, l.publish_at)
      and (l.beta_editable or folder_in_beta(l.folder_id))
      and coalesce((select plain_visible(r.level, r.governing_id) from resolve_access(l.id) r), false))
$$;

-- A media or cover entry as the site writes them: 'youtube:<id>', or '[img:]<path or URL>[|alt text]'. No quotes, angle
-- brackets, backslashes or control characters in the path; no control characters or backslashes in the alt text.
create or replace function public.beta_ok_media(p text) returns boolean
language sql immutable as $$
  select p is not null and length(p) <= 900 and (
    p ~ '^youtube:[A-Za-z0-9_-]{6,20}$'
    or (p !~ '^youtube:' and split_part(p, '|', 1) ~ '^(img:)?[A-Za-z0-9._~:/?#@!$&()*+,;=%-]{1,500}$'
        and substr(p, length(split_part(p, '|', 1)) + 2) !~ '[[:cntrl:]\\]'))
$$;

-- Save a lab in beta mode: an existing lab the caller may edit, or a new lab inside a beta folder. Returns the lab's slug.
create or replace function public.beta_save_lab(p_lab jsonb, p_content jsonb, p_attachments jsonb default '[]'::jsonb)
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
  if not is_beta() then raise exception 'Beta mode only.'; end if;
  if v_id is null or v_id !~ '^l-[A-Za-z0-9_-]{1,40}$' then raise exception 'bad lab id'; end if;
  if v_title = '' or length(v_title) > 200 then raise exception 'A lab needs a title of at most 200 characters.'; end if;
  if length(coalesce(v_summary, '')) > 1000 then raise exception 'The summary is too long.'; end if;
  if v_format not in ('html', 'labtags') then raise exception 'bad format'; end if;
  if length(coalesce(v_text, '')) > 2000000 then raise exception 'This lab is too large to save.'; end if;
  if coalesce(array_length(v_tags, 1), 0) > 40 or exists (select 1 from unnest(v_tags) t where length(t) > 60 or t ~ '[[:cntrl:]]') then raise exception 'bad tags'; end if;
  if v_cover is not null and not beta_ok_media(v_cover) then raise exception 'bad cover image'; end if;
  if coalesce(array_length(v_media, 1), 0) > 60 or exists (select 1 from unnest(v_media) x where not beta_ok_media(x)) then raise exception 'bad photo or video entry'; end if;
  if jsonb_typeof(coalesce(p_attachments, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_attachments, '[]'::jsonb)) > 40 then raise exception 'bad file list'; end if;

  select * into v_old from labs where id = v_id;
  v_exists := found;
  if v_exists then
    if not beta_can_edit_lab(v_id) then raise exception 'This lab is not open for beta editing.'; end if;
    if v_folder is distinct from v_old.folder_id and not (beta_can_use_folder(v_old.folder_id) and beta_can_use_folder(v_folder)) then
      raise exception 'A lab can only be moved between beta folders.';
    end if;
    insert into lab_revisions (lab_id, snapshot, note, saved_by) values (v_id, jsonb_build_object(
      'lab', to_jsonb(v_old),
      'content', (select to_jsonb(c) || jsonb_build_object('attachments', coalesce((select jsonb_agg(to_jsonb(t) order by t.sort_order) from attachments t where t.lab_id = v_id), '[]'::jsonb))
                  from lab_content c where c.lab_id = v_id)), 'before beta save', auth.uid());
    update labs set title = v_title, folder_id = v_folder, summary = v_summary, cover_path = v_cover, cover_zoom = v_zoom, tags = v_tags,
      estimated_minutes = v_minutes, report_minutes = v_report,
      sort_order = case when beta_can_use_folder(v_old.folder_id) then v_order else v_old.sort_order end   -- a lab that is beta editable on its own stays where it is
      where id = v_id;   -- never status, publish_at, access, slug or the beta switch
    v_slug := v_old.slug;
  else
    if v_id !~ '^l-[0-9]{10,16}$' then raise exception 'bad lab id'; end if;
    if not beta_can_use_folder(v_folder) then raise exception 'New labs can only be created inside a beta folder.'; end if;
    v_base := trim(both '-' from regexp_replace(lower(coalesce(nullif(p_lab->>'slug', ''), v_title)), '[^a-z0-9]+', '-', 'g'));
    if v_base = '' then v_base := 'lab'; end if;
    v_base := left(v_base, 80); v_slug := v_base;
    while exists (select 1 from labs where slug = v_slug) loop v_n := v_n + 1; v_slug := v_base || '-' || v_n; end loop;
    -- Born published with the folder's access: a beta user never sees drafts and never chooses who sees a lab.
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
revoke execute on function public.beta_save_lab(jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.beta_save_lab(jsonb, jsonb, jsonb) to authenticated;

-- Where a lab sits among its neighbours (the arrows on the cards). Only for labs inside a beta folder.
create or replace function public.beta_set_lab_order(p_lab_id text, p_order int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (beta_can_edit_lab(p_lab_id) and beta_can_use_folder((select folder_id from labs where id = p_lab_id))) then
    raise exception 'Only labs inside a beta folder can be reordered in beta mode.';
  end if;
  update labs set sort_order = p_order where id = p_lab_id;
end $$;
revoke execute on function public.beta_set_lab_order(text, int) from public, anon;
grant execute on function public.beta_set_lab_order(text, int) to authenticated;

-- "Remove" in beta mode does not delete: the lab becomes a draft that only admins see, so the owner can put it back.
-- Refused when anyone else has saved work in the lab (removing it would hide their work). p_check = true only asks.
create or replace function public.beta_remove_lab(p_lab_id text, p_check boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (beta_can_edit_lab(p_lab_id) and beta_can_use_folder((select folder_id from labs where id = p_lab_id))) then
    raise exception 'Only labs inside a beta folder can be removed in beta mode.';
  end if;
  if exists (select 1 from lab_entries e where e.lab_id = p_lab_id and e.user_id <> auth.uid()) then
    raise exception 'Someone has saved work in this lab, so it cannot be removed in beta mode. Ask the site owner.';
  end if;
  if p_check then return; end if;
  insert into lab_revisions (lab_id, snapshot, note, saved_by)
    values (p_lab_id, jsonb_build_object('lab', (select to_jsonb(l) from labs l where l.id = p_lab_id)), 'removed in beta mode (made a draft)', auth.uid());
  update labs set status = 'draft', publish_at = null where id = p_lab_id;
end $$;
revoke execute on function public.beta_remove_lab(text, boolean) from public, anon;
grant execute on function public.beta_remove_lab(text, boolean) to authenticated;

-- For the editor's saved-work guard: WHICH of this lab's blanks hold saved work. Block ids only (the editor wrote them):
-- no values, no counts, no accounts.
create or replace function public.beta_lab_work_keys(p_lab_id text) returns table(key text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not beta_can_edit_lab(p_lab_id) then raise exception 'This lab is not open for beta editing.'; end if;
  return query select distinct k.key from lab_entries e cross join lateral jsonb_each(e.data) k
    where e.lab_id = p_lab_id and left(k.key, 1) <> '_' and k.value not in ('""'::jsonb, 'null'::jsonb, '0'::jsonb);
end $$;
revoke execute on function public.beta_lab_work_keys(text) from public, anon;
grant execute on function public.beta_lab_work_keys(text) to authenticated;

-- Admins: who is in beta, and adding or removing someone by the email of their Google account.
create or replace function public.list_beta_users() returns table(email text, user_id uuid, added_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query select u.email::text, b.user_id, b.added_at from beta_users b join auth.users u on u.id = b.user_id order by b.added_at;
end $$;
create or replace function public.set_beta(p_email text, p_beta boolean) returns text
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_email text := lower(trim(p_email));
begin
  if not is_admin() then raise exception 'admin only'; end if;
  select id into v_id from auth.users where lower(email) = v_email and email not like '%@seats.ohschemlabs.com';
  if v_id is null then return 'not_found'; end if;
  if p_beta then insert into beta_users (user_id) values (v_id) on conflict (user_id) do nothing;
  else delete from beta_users where user_id = v_id; end if;
  return 'ok';
end $$;
revoke execute on function public.list_beta_users() from public, anon;
grant execute on function public.list_beta_users() to authenticated;
revoke execute on function public.set_beta(text, boolean) from public, anon;
grant execute on function public.set_beta(text, boolean) to authenticated;

-- Files. A beta user may add files only under labs/<lab id>/ in the PUBLIC bucket, for a lab they may edit or one they are
-- about to create (the id is not taken and they have a beta folder to put it in), and may delete files only of a lab they
-- may edit. Nothing here touches the private bucket, where students' photos live.
create or replace function public.beta_can_add_file(p_bucket text, p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_bucket = 'lab-files-public' and is_beta()
     and p_name ~ '^labs/l-[A-Za-z0-9_-]{1,40}/[A-Za-z0-9._-]{1,200}$'
     and (beta_can_edit_lab(split_part(p_name, '/', 2))
          or (split_part(p_name, '/', 2) ~ '^l-[0-9]{10,16}$'
              and not exists (select 1 from labs l where l.id = split_part(p_name, '/', 2))
              and exists (select 1 from folders f where beta_can_use_folder(f.id))))
$$;
drop policy if exists "beta adds lab files" on storage.objects;
create policy "beta adds lab files" on storage.objects for insert to authenticated
  with check (beta_can_add_file(bucket_id, name));
drop policy if exists "beta deletes lab files" on storage.objects;
create policy "beta deletes lab files" on storage.objects for delete to authenticated
  using (bucket_id = 'lab-files-public' and name ~ '^labs/l-[A-Za-z0-9_-]{1,40}/' and beta_can_edit_lab(split_part(name, '/', 2)));
