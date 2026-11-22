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
