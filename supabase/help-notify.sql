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
