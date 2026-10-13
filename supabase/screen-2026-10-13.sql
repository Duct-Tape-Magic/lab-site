-- Site-wide screen, 2026-10-13: three hardening changes. Idempotent.

-- 1. help_thread_who returns a student's name / seat label; it is only meant for the admin list and the email trigger
--    (both run as the function owner), never for direct calls with the publishable key.
revoke execute on function public.help_thread_who(bigint) from public, anon, authenticated;

-- 2. A new access code must sign out whoever still holds the old one (sessions are not invalidated by a password change).
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

-- Closing a class also ends its seats' live sessions.
create or replace function public.set_class_archived(p_class_id text, p_archived boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  update classes set archived = p_archived where id = p_class_id;
  update auth.users set banned_until = case when p_archived then 'infinity'::timestamptz else null end, updated_at = now()
    where id in (select s.user_id from seats s where s.class_id = p_class_id);
  if p_archived then delete from auth.sessions where user_id in (select s.user_id from seats s where s.class_id = p_class_id); end if;
end $$;

-- 3. Nothing on the site lets a student edit their profile row, and the policy would have let one rename themselves
--    (name and email) to look like another student in every admin view.
drop policy if exists "student updates self" on public.students;
