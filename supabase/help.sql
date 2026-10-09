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
create or replace function public.help_notify() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_key text; v_to text; v_from text; v_subject text; v_lab text; v_who text; v_text text; v_recipients jsonb;
begin
  if new.role <> 'student' then return new; end if;
  begin
    select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  exception when others then v_key := null; end;
  if coalesce(v_key, '') = '' then return new; end if;
  select coalesce((select value from site_content where key = 'helpNotifyEmails'), 'whclark09@gmail.com') into v_to;
  select coalesce((select value from site_content where key = 'helpEmailFrom'), 'OHS Chem Labs <help@ohschemlabs.com>') into v_from;
  select coalesce((select value from site_content where key = 'helpEmailSubject'), 'Help request: {lab}') into v_subject;
  select l.title into v_lab from help_threads t join labs l on l.id = t.lab_id where t.id = new.thread_id;
  v_who := coalesce(help_thread_who(new.thread_id), 'A student');
  v_subject := replace(replace(v_subject, '{lab}', coalesce(v_lab, 'Lab')), '{who}', v_who);
  select jsonb_agg(trim(x)) into v_recipients from unnest(string_to_array(v_to, ',')) x where trim(x) <> '';
  if v_recipients is null then return new; end if;
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
  return new;   -- an email problem must never block the student's message
end $$;
drop trigger if exists help_notify_tr on public.help_messages;
create trigger help_notify_tr after insert on public.help_messages for each row execute function public.help_notify();
