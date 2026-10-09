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
