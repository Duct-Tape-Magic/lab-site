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
