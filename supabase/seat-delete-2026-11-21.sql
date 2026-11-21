-- Class code accounts (seats) may delete their own account. Run once in the Supabase SQL editor. Safe to run again.
begin;
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
commit;
notify pgrst, 'reload schema';
