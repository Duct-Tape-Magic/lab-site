-- Self-undoing test of beta mode (supabase/beta-2026-11-21.sql). Run it in the Supabase SQL editor.
-- It is ONE statement: it builds made-up users, folders and labs, acts as each user through the same roles the site uses,
-- and always ends by raising "BETA TEST RESULT …", which rolls back everything it did (the made-up rows, and the temporary
-- is_admin() without the dashboard exception, which it needs so the dashboard session is not treated as an admin).
-- It reads no real student data: every row it touches is one it created. A result of "failures: none" is a pass.
do $test$
declare
  b uuid := gen_random_uuid();   -- beta user, member of the test group
  c uuid := gen_random_uuid();   -- beta user, not in the group
  s uuid := gen_random_uuid();   -- ordinary student in the group
  a uuid := gen_random_uuid();   -- admin
  fails text[] := '{}';
  n int; t text; ok boolean;
begin
  execute $f$ create or replace function public.is_admin() returns boolean language sql stable as $i$ select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin' $i$ $f$;

  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
    (b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'beta-test-b@test.invalid', '{}', '{}', now(), now()),
    (c, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'beta-test-c@test.invalid', '{}', '{}', now(), now()),
    (s, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'beta-test-s@test.invalid', '{}', '{}', now(), now()),
    (a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'beta-test-a@test.invalid', '{"role":"admin"}', '{}', now(), now());
  insert into beta_users (user_id) values (b), (c);
  insert into groups (id, name) values ('g-betatest', 'beta test group');
  insert into group_members (group_id, user_id) values ('g-betatest', b), ('g-betatest', s);
  insert into folders (id, parent_id, name, slug, access, beta_editable) values
    ('f-bt-beta', null, 'bt beta', 'bt-beta', 'accounts', true),
    ('f-bt-sub', 'f-bt-beta', 'bt sub', 'bt-sub', 'inherit', false),
    ('f-bt-normal', null, 'bt normal', 'bt-normal', 'public', false),
    ('f-bt-open', null, 'bt open beta', 'bt-open', 'public', true);
  insert into item_groups (item_id, group_id) values ('f-bt-beta', 'g-betatest');
  insert into labs (id, folder_id, title, slug, status, access, beta_editable) values
    ('l-9000000000001', 'f-bt-beta', 'in beta folder', 'bt-l1', 'published', 'inherit', false),
    ('l-9000000000002', 'f-bt-normal', 'switched on alone', 'bt-l2', 'published', 'inherit', true),
    ('l-9000000000003', 'f-bt-normal', 'not beta', 'bt-l3', 'published', 'inherit', false),
    ('l-9000000000004', 'f-bt-beta', 'draft in beta folder', 'bt-l4', 'draft', 'inherit', false),
    ('l-9000000000005', 'f-bt-beta', 'admin only in beta folder', 'bt-l5', 'published', 'admin', false),
    ('l-9000000000006', 'f-bt-beta', 'no entries', 'bt-l6', 'published', 'inherit', false);
  insert into lab_content (lab_id, content, format) select id, 'original', 'labtags' from labs where id like 'l-900000000000_';
  insert into attachments (id, lab_id, name, path) values ('a-bt-other', 'l-9000000000003', 'other', 'labs/l-9000000000003/x.pdf');
  insert into lab_entries (user_id, lab_id, data) values (s, 'l-9000000000001', '{"q1":"a secret answer","q2":"","_meta":1}');

  -- ===== as beta user B (in the group) =====
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', b::text, true);
  execute 'set local role authenticated';

  if not is_beta() then fails := fails || 'B is not beta'; end if;
  if not beta_can_edit_lab('l-9000000000001') then fails := fails || 'B cannot edit lab in beta folder'; end if;
  if not beta_can_edit_lab('l-9000000000002') then fails := fails || 'B cannot edit lone beta lab'; end if;
  if beta_can_edit_lab('l-9000000000003') then fails := fails || 'B can edit a non-beta lab'; end if;
  if beta_can_edit_lab('l-9000000000004') then fails := fails || 'B can edit a draft'; end if;
  if beta_can_edit_lab('l-9000000000005') then fails := fails || 'B can edit an admin-only lab'; end if;
  if not beta_can_use_folder('f-bt-beta') or not beta_can_use_folder('f-bt-sub') or not beta_can_use_folder('f-bt-open') then fails := fails || 'B cannot use a beta folder'; end if;
  if beta_can_use_folder('f-bt-normal') or beta_can_use_folder(null) then fails := fails || 'B can use a non-beta folder'; end if;

  -- no direct writes, no student data
  update labs set title = 'hacked' where id = 'l-9000000000001'; get diagnostics n = row_count;
  if n <> 0 then fails := fails || 'B updated labs directly'; end if;
  update folders set beta_editable = true where id = 'f-bt-normal'; get diagnostics n = row_count;
  if n <> 0 then fails := fails || 'B updated folders directly'; end if;
  begin insert into labs (id, title, slug) values ('l-9000000000099', 'x', 'bt-x'); fails := fails || 'B inserted into labs directly'; exception when others then null; end;
  select count(*) into n from lab_entries; if n <> 0 then fails := fails || format('B sees %s lab_entries rows', n); end if;
  select count(*) into n from students where user_id <> b; if n <> 0 then fails := fails || format('B sees %s other students', n); end if;
  select count(*) into n from seats; if n <> 0 then fails := fails || 'B sees seats'; end if;
  select count(*) into n from help_messages; if n <> 0 then fails := fails || 'B sees help messages'; end if;
  select count(*) into n from oral_messages; if n <> 0 then fails := fails || 'B sees Socratic 1 messages'; end if;
  select count(*) into n from events; if n <> 0 then fails := fails || 'B sees events'; end if;
  select count(*) into n from lab_revisions; if n <> 0 then fails := fails || 'B sees revisions'; end if;
  begin select count(*) into n from beta_users; fails := fails || 'B can read beta_users'; exception when others then null; end;
  begin perform set_beta('beta-test-s@test.invalid', true); fails := fails || 'B could add a beta user'; exception when others then null; end;
  begin perform * from list_beta_users(); fails := fails || 'B could list beta users'; exception when others then null; end;
  select count(*) into n from labs where id = 'l-9000000000004'; if n <> 0 then fails := fails || 'B sees a draft'; end if;

  -- saving an existing lab: only the allowed fields change
  t := beta_save_lab('{"id":"l-9000000000001","title":"renamed","folder_id":"f-bt-beta","status":"draft","access":"public","beta_editable":true,"slug":"stolen","sort_order":7,"tags":["a","b"]}'::jsonb,
                     '{"content":"new text","format":"labtags","media":["img:labs/l-9000000000001/a.webp|a photo","youtube:abcdefghijk"]}'::jsonb, '[]'::jsonb);
  execute 'reset role';
  select (title = 'renamed' and status = 'published' and access = 'inherit' and not beta_editable and slug = 'bt-l1' and sort_order = 7 and tags = array['a','b']) into ok from labs where id = 'l-9000000000001';
  if not coalesce(ok, false) or t <> 'bt-l1' then fails := fails || 'save changed a field it must not, or missed one it should'; end if;
  select (content = 'new text' and array_length(media, 1) = 2) into ok from lab_content where lab_id = 'l-9000000000001';
  if not coalesce(ok, false) then fails := fails || 'content not saved'; end if;
  select count(*) into n from lab_revisions where lab_id = 'l-9000000000001' and saved_by = b and snapshot->'content'->>'content' = 'original';
  if n <> 1 then fails := fails || 'no revision with the editor and the old content'; end if;
  execute 'set local role authenticated';

  -- moves
  begin perform beta_save_lab('{"id":"l-9000000000001","title":"x","folder_id":"f-bt-normal"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'moved a lab out to a non-beta folder'; exception when others then null; end;
  begin perform beta_save_lab('{"id":"l-9000000000001","title":"x","folder_id":""}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'moved a lab to the top level'; exception when others then null; end;
  begin perform beta_save_lab('{"id":"l-9000000000002","title":"x","folder_id":"f-bt-beta"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'moved a lone beta lab'; exception when others then null; end;
  perform beta_save_lab('{"id":"l-9000000000001","title":"renamed","folder_id":"f-bt-sub","sort_order":7}'::jsonb, '{"content":"new text","format":"labtags"}'::jsonb);
  perform beta_save_lab('{"id":"l-9000000000002","title":"lone renamed","folder_id":"f-bt-normal","sort_order":55}'::jsonb, '{"content":"lone","format":"html"}'::jsonb);
  execute 'reset role';
  select folder_id = 'f-bt-sub' into ok from labs where id = 'l-9000000000001'; if not coalesce(ok, false) then fails := fails || 'move between beta folders failed'; end if;
  select (title = 'lone renamed' and sort_order = 0) into ok from labs where id = 'l-9000000000002'; if not coalesce(ok, false) then fails := fails || 'lone beta lab: title not saved or order changed'; end if;
  execute 'set local role authenticated';

  -- labs that are not open
  begin perform beta_save_lab('{"id":"l-9000000000003","title":"x","folder_id":"f-bt-normal"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'saved a non-beta lab'; exception when others then null; end;
  begin perform beta_save_lab('{"id":"l-9000000000004","title":"x","folder_id":"f-bt-beta"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'saved a draft'; exception when others then null; end;
  begin perform beta_save_lab('{"id":"l-9000000000005","title":"x","folder_id":"f-bt-beta"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'saved an admin-only lab'; exception when others then null; end;

  -- new labs
  t := beta_save_lab('{"id":"l-9100000000001","title":"Brand New Lab!","folder_id":"f-bt-beta","slug":"bt-l3"}'::jsonb, '{"content":"hello","format":"labtags"}'::jsonb);
  begin perform beta_save_lab('{"id":"l-9100000000002","title":"x","folder_id":"f-bt-normal"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'created a lab outside a beta folder'; exception when others then null; end;
  begin perform beta_save_lab('{"id":"l-9100000000003","title":"x"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'created a lab at the top level'; exception when others then null; end;
  begin perform beta_save_lab('{"id":"x-1","title":"x","folder_id":"f-bt-beta"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'accepted a bad id'; exception when others then null; end;
  begin perform beta_save_lab('{"id":"l-9100000000004","title":"x","folder_id":"f-bt-beta","cover_path":"img:x'' onerror=''y"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'accepted a cover path with a quote'; exception when others then null; end;
  begin perform beta_save_lab('{"id":"l-9100000000005","title":"x","folder_id":"f-bt-beta"}'::jsonb, '{"content":"x","format":"labtags","media":["img:a\\b"]}'::jsonb); fails := fails || 'accepted a media path with a backslash'; exception when others then null; end;
  execute 'reset role';
  select (status = 'published' and access = 'inherit' and not beta_editable and folder_id = 'f-bt-beta' and slug = 'bt-l3-2') into ok from labs where id = 'l-9100000000001';
  if not coalesce(ok, false) or t <> 'bt-l3-2' then fails := fails || format('new lab wrong (slug %s)', t); end if;
  execute 'set local role authenticated';

  -- files attached to a lab
  begin perform beta_save_lab('{"id":"l-9000000000001","title":"renamed","folder_id":"f-bt-sub"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb, '[{"id":"a-bt-1","name":"f","path":"photos/someone/x.jpg"}]'::jsonb); fails := fails || 'attached a file outside the lab folder'; exception when others then null; end;
  begin perform beta_save_lab('{"id":"l-9000000000001","title":"renamed","folder_id":"f-bt-sub"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb, '[{"id":"a-bt-other","name":"f","path":"labs/l-9000000000001/x.pdf"}]'::jsonb); fails := fails || 'took over another lab''s file row'; exception when others then null; end;
  perform beta_save_lab('{"id":"l-9000000000001","title":"renamed","folder_id":"f-bt-sub"}'::jsonb, '{"content":"new text","format":"labtags"}'::jsonb, '[{"id":"a-bt-1","name":"handout.pdf","path":"labs/l-9000000000001/170-ab-handout.pdf","mime":"application/pdf","size_bytes":10}]'::jsonb);
  execute 'reset role';
  select count(*) into n from attachments where lab_id = 'l-9000000000001' and id = 'a-bt-1'; if n <> 1 then fails := fails || 'file not attached'; end if;
  select count(*) into n from attachments where id = 'a-bt-other' and lab_id = 'l-9000000000003'; if n <> 1 then fails := fails || 'other lab''s file row was touched'; end if;
  execute 'set local role authenticated';

  -- which blocks hold saved work: ids only
  select string_agg(k.key, ',' order by k.key) into t from beta_lab_work_keys('l-9000000000001') k;
  if t is distinct from 'q1' then fails := fails || format('work keys wrong: %s', t); end if;
  begin perform * from beta_lab_work_keys('l-9000000000003'); fails := fails || 'work keys given for a non-beta lab'; exception when others then null; end;

  -- order and remove
  begin perform beta_set_lab_order('l-9000000000002', 5); fails := fails || 'reordered a lone beta lab'; exception when others then null; end;
  perform beta_set_lab_order('l-9000000000001', 42);
  begin perform beta_remove_lab('l-9000000000001'); fails := fails || 'removed a lab that holds someone else''s work'; exception when others then null; end;
  begin perform beta_remove_lab('l-9000000000002'); fails := fails || 'removed a lone beta lab'; exception when others then null; end;
  perform beta_remove_lab('l-9000000000006', true);
  if not beta_can_edit_lab('l-9000000000006') then fails := fails || 'the check-only call removed the lab'; end if;
  perform beta_remove_lab('l-9000000000006');
  if beta_can_edit_lab('l-9000000000006') then fails := fails || 'a removed lab is still editable'; end if;
  execute 'reset role';
  select (status = 'draft') into ok from labs where id = 'l-9000000000006'; if not coalesce(ok, false) then fails := fails || 'remove did not make a draft'; end if;
  select count(*) into n from labs where id = 'l-9000000000006'; if n <> 1 then fails := fails || 'remove deleted the lab'; end if;
  select (sort_order = 42) into ok from labs where id = 'l-9000000000001'; if not coalesce(ok, false) then fails := fails || 'order not saved'; end if;
  select count(*) into n from lab_entries where lab_id = 'l-9000000000001' and user_id = s; if n <> 1 then fails := fails || 'the student entry was touched'; end if;
  execute 'set local role authenticated';

  -- files in storage
  if not beta_can_add_file('lab-files-public', 'labs/l-9000000000001/170-ab-x.webp') then fails := fails || 'cannot add a file to an editable lab'; end if;
  if not beta_can_add_file('lab-files-public', 'labs/l-9200000000001/170-ab-x.webp') then fails := fails || 'cannot add a file for a lab being created'; end if;
  if beta_can_add_file('lab-files-private', 'labs/l-9000000000001/170-ab-x.webp') then fails := fails || 'may write to the private bucket'; end if;
  if beta_can_add_file('lab-files-public', 'photos/' || s || '/l-1/x.jpg') or beta_can_add_file('lab-files-private', 'photos/' || s || '/l-1/x.jpg') then fails := fails || 'may write under photos/'; end if;
  if beta_can_add_file('lab-files-public', 'labs/l-9000000000003/x.webp') then fails := fails || 'may add a file to a non-beta lab'; end if;
  if beta_can_add_file('lab-files-public', 'labs/l-9000000000001/../x.webp') or beta_can_add_file('lab-files-public', 'folders/f-bt-beta/x.webp') or beta_can_add_file('lab-files-public', 'site/x.webp') then fails := fails || 'may add a file outside a lab folder'; end if;
  begin insert into storage.objects (bucket_id, name) values ('lab-files-private', 'photos/' || s || '/l-1/bt.jpg'); fails := fails || 'inserted into the private bucket'; exception when others then null; end;
  begin insert into storage.objects (bucket_id, name) values ('lab-files-public', 'labs/l-9000000000003/bt.webp'); fails := fails || 'inserted a file for a non-beta lab'; exception when others then null; end;
  select count(*) into n from storage.objects where bucket_id = 'lab-files-private'; if n <> 0 then fails := fails || format('B can list %s private files', n); end if;
  execute 'reset role';

  -- ===== as beta user C (not in the group) =====
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', c::text, true);
  execute 'set local role authenticated';
  if beta_can_edit_lab('l-9000000000001') or beta_can_use_folder('f-bt-beta') or beta_can_use_folder('f-bt-sub') then fails := fails || 'C can use a beta folder they cannot see'; end if;
  if not beta_can_use_folder('f-bt-open') or not beta_can_edit_lab('l-9000000000002') then fails := fails || 'C cannot use public beta items'; end if;
  begin perform beta_save_lab('{"id":"l-9000000000001","title":"x","folder_id":"f-bt-sub"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'C saved a lab they cannot see'; exception when others then null; end;
  begin perform beta_save_lab('{"id":"l-9100000000009","title":"x","folder_id":"f-bt-beta"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'C created a lab in a folder they cannot see'; exception when others then null; end;
  begin perform beta_save_lab('{"id":"l-9000000000001","title":"x","folder_id":"f-bt-open"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'C pulled a lab they cannot see into their folder'; exception when others then null; end;
  execute 'reset role';

  -- ===== as ordinary student S =====
  perform set_config('request.jwt.claims', json_build_object('sub', s, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', s::text, true);
  execute 'set local role authenticated';
  if is_beta() or beta_can_edit_lab('l-9000000000001') or beta_can_use_folder('f-bt-open') or beta_can_add_file('lab-files-public', 'labs/l-9000000000001/x.webp') then fails := fails || 'a non-beta student has beta rights'; end if;
  begin perform beta_save_lab('{"id":"l-9000000000001","title":"x","folder_id":"f-bt-sub"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'a non-beta student saved a lab'; exception when others then null; end;
  begin perform beta_remove_lab('l-9100000000001'); fails := fails || 'a non-beta student removed a lab'; exception when others then null; end;
  execute 'reset role';

  -- ===== signed out =====
  perform set_config('request.jwt.claims', '{"role":"anon"}', true); perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';
  if is_beta() or beta_can_edit_lab('l-9000000000002') then fails := fails || 'a signed-out visitor has beta rights'; end if;
  begin perform beta_save_lab('{"id":"l-9000000000002","title":"x","folder_id":"f-bt-normal"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'a signed-out visitor saved a lab'; exception when others then null; end;
  execute 'reset role';

  -- ===== as an admin: add and remove beta users; removal is immediate =====
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated', 'app_metadata', json_build_object('role', 'admin'))::text, true);
  perform set_config('request.jwt.claim.sub', a::text, true);
  execute 'set local role authenticated';
  if set_beta('Beta-Test-S@test.invalid', true) <> 'ok' or set_beta('nobody@test.invalid', true) <> 'not_found' then fails := fails || 'set_beta answers wrong'; end if;
  select count(*) into n from list_beta_users() l where l.email like 'beta-test-%@test.invalid'; if n <> 3 then fails := fails || format('list_beta_users shows %s test users, expected 3', n); end if;
  if set_beta('beta-test-b@test.invalid', false) <> 'ok' then fails := fails || 'could not remove B'; end if;
  update labs set beta_editable = true where id = 'l-9000000000003'; get diagnostics n = row_count; if n <> 1 then fails := fails || 'admin could not flip the switch'; end if;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', b::text, true);
  execute 'set local role authenticated';
  if is_beta() or beta_can_edit_lab('l-9000000000002') then fails := fails || 'B still has beta rights after removal'; end if;
  execute 'reset role';

  raise exception 'BETA TEST RESULT: failures: %', case when array_length(fails, 1) is null then 'none' else array_to_string(fails, ' | ') end;
end $test$;
