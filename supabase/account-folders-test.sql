-- Self-undoing test of the account-folder tables (supabase/account-folders-2026-11-22.sql). Run it in the Supabase SQL editor.
-- ONE statement: made-up users, folders and a class; it always ends by raising "ACCOUNT FOLDERS TEST RESULT …", which rolls
-- everything back (including the temporary is_admin() without the dashboard exception). "failures: none" is a pass.
do $t$
declare u uuid := gen_random_uuid(); a uuid := gen_random_uuid(); fails text[] := '{}'; n int;
begin
  execute $f$ create or replace function public.is_admin() returns boolean language sql stable as $i$ select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin' $i$ $f$;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
    (u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'af-test-u@test.invalid', '{}', '{}', now(), now()),
    (a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'af-test-a@test.invalid', '{"role":"admin"}', '{}', now(), now());
  insert into account_folders (id, name) values ('af-test-1', 'test folder'), ('af-test-2', 'inner');
  update account_folders set parent_id = 'af-test-1' where id = 'af-test-2';
  insert into account_folder_users (user_id, folder_id) values (u, 'af-test-2');
  insert into classes (id, name, prefix) values ('c-af-test', 'af test class', 'AFT');
  insert into account_folder_classes (class_id, folder_id) values ('c-af-test', 'af-test-1');
  -- an ordinary signed-in user
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', u::text, true);
  execute 'set local role authenticated';
  select count(*) into n from account_folders; if n <> 0 then fails := fails || 'a user reads folders'; end if;
  select count(*) into n from account_folder_users; if n <> 0 then fails := fails || 'a user reads their own filing'; end if;
  select count(*) into n from account_folder_classes; if n <> 0 then fails := fails || 'a user reads class filing'; end if;
  begin insert into account_folders (id, name) values ('af-test-x', 'x'); fails := fails || 'a user added a folder'; exception when others then null; end;
  update account_folders set name = 'hacked'; get diagnostics n = row_count; if n <> 0 then fails := fails || 'a user renamed folders'; end if;
  delete from account_folder_users; get diagnostics n = row_count; if n <> 0 then fails := fails || 'a user removed filing'; end if;
  execute 'reset role';
  -- signed out
  perform set_config('request.jwt.claims', '{"role":"anon"}', true); perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';
  begin select count(*) into n from account_folders; fails := fails || 'a visitor can query folders'; exception when others then null; end;
  begin select count(*) into n from account_folder_users; fails := fails || 'a visitor can query filing'; exception when others then null; end;
  execute 'reset role';
  -- an admin
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated', 'app_metadata', json_build_object('role', 'admin'))::text, true);
  perform set_config('request.jwt.claim.sub', a::text, true);
  execute 'set local role authenticated';
  select count(*) into n from account_folders where id like 'af-test-%'; if n <> 2 then fails := fails || 'admin cannot read folders'; end if;
  insert into account_folder_users (user_id, folder_id) values (a, 'af-test-1');
  update account_folder_users set folder_id = 'af-test-2' where user_id = a; get diagnostics n = row_count; if n <> 1 then fails := fails || 'admin cannot move an account'; end if;
  delete from account_folders where id = 'af-test-1'; get diagnostics n = row_count; if n <> 1 then fails := fails || 'admin cannot delete a folder'; end if;
  execute 'reset role';
  select count(*) into n from account_folders where id = 'af-test-2' and parent_id is null; if n <> 1 then fails := fails || 'the inner folder did not move to the top level'; end if;
  select count(*) into n from account_folder_classes where class_id = 'c-af-test'; if n <> 0 then fails := fails || 'deleting a folder left its class filing'; end if;
  select count(*) into n from classes where id = 'c-af-test'; if n <> 1 then fails := fails || 'deleting a folder deleted a class'; end if;
  select count(*) into n from auth.users where id in (u, a); if n <> 2 then fails := fails || 'deleting a folder deleted an account'; end if;
  raise exception 'ACCOUNT FOLDERS TEST RESULT: failures: %', case when array_length(fails, 1) is null then 'none' else array_to_string(fails, ' | ') end;
end $t$;
