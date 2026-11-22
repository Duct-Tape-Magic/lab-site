-- Self-undoing test of the edit lists (supabase/editors-2026-11-22.sql). Run it in the Supabase SQL editor.
-- It is ONE statement: it builds made-up users, a made-up class, folders and labs, acts as each user through the same roles
-- the site uses, and always ends by raising "EDITORS TEST RESULT …", which rolls back everything it did (the made-up rows,
-- and the temporary is_admin() without the dashboard exception, which it needs so the dashboard session is not treated as
-- an admin). It reads no real student data: every row it touches is one it created. "failures: none" is a pass.
do $test$
declare
  b uuid := gen_random_uuid();   -- on edit lists by account, and allowed to see the restricted folder
  c uuid := gen_random_uuid();   -- on edit lists by account, but NOT allowed to see the restricted folder
  k uuid := gen_random_uuid();   -- member of a class that is on the folder's edit list (and allowed to see it)
  s uuid := gen_random_uuid();   -- ordinary student who can see the folder, on no edit list
  a uuid := gen_random_uuid();   -- admin
  fails text[] := '{}';
  n int; t text; ok boolean;
begin
  execute $f$ create or replace function public.is_admin() returns boolean language sql stable as $i$ select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin' $i$ $f$;

  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
    (b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'edit-test-b@test.invalid', '{}', '{}', now(), now()),
    (c, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'edit-test-c@test.invalid', '{}', '{}', now(), now()),
    (k, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'edit-test-k@test.invalid', '{}', '{}', now(), now()),
    (s, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'edit-test-s@test.invalid', '{}', '{}', now(), now()),
    (a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'edit-test-a@test.invalid', '{"role":"admin"}', '{}', now(), now());
  insert into groups (id, name) values ('g-et-view', 'edit test viewers'), ('g-et-class', 'edit test class');
  insert into group_members (group_id, user_id) values ('g-et-view', b), ('g-et-view', s), ('g-et-view', k), ('g-et-class', k);
  insert into folders (id, parent_id, name, slug, access) values
    ('f-et-edit', null, 'et edit', 'et-edit', 'accounts'),
    ('f-et-sub', 'f-et-edit', 'et sub', 'et-sub', 'inherit'),
    ('f-et-normal', null, 'et normal', 'et-normal', 'public'),
    ('f-et-open', null, 'et open', 'et-open', 'public');
  insert into item_groups (item_id, group_id) values ('f-et-edit', 'g-et-view');
  insert into labs (id, folder_id, title, slug, status, access) values
    ('l-9000000000001', 'f-et-edit', 'in edit folder', 'et-l1', 'published', 'inherit'),
    ('l-9000000000002', 'f-et-normal', 'on its own list', 'et-l2', 'published', 'inherit'),
    ('l-9000000000003', 'f-et-normal', 'nobody edits', 'et-l3', 'published', 'inherit'),
    ('l-9000000000004', 'f-et-edit', 'draft in edit folder', 'et-l4', 'draft', 'inherit'),
    ('l-9000000000005', 'f-et-edit', 'admin only in edit folder', 'et-l5', 'published', 'admin'),
    ('l-9000000000006', 'f-et-edit', 'no work from others', 'et-l6', 'published', 'inherit'),
    ('l-9000000000007', 'f-et-edit', 'help thread from a student', 'et-l7', 'published', 'inherit'),
    ('l-9000000000008', 'f-et-edit', 'Socratic 1 session from a student', 'et-l8', 'published', 'inherit');
  insert into lab_content (lab_id, content, format) select id, 'original', 'labtags' from labs where id like 'l-900000000000_';
  -- the edit lists: the folder by account (b), by class (k's class); the open folder (b, c); one lab on its own (b, c)
  insert into item_edit_users (item_id, user_id) values ('f-et-edit', b), ('f-et-edit', c), ('f-et-open', b), ('f-et-open', c), ('l-9000000000002', b), ('l-9000000000002', c), ('l-9000000000006', c);
  insert into item_edit_groups (item_id, group_id) values ('f-et-edit', 'g-et-class');
  insert into attachments (id, lab_id, name, path) values ('a-et-other', 'l-9000000000003', 'other', 'labs/l-9000000000003/x.pdf');
  insert into lab_entries (user_id, lab_id, data) values (s, 'l-9000000000001', '{"q1":"a secret answer","q2":"","_meta":1}'), (b, 'l-9000000000006', '{"q1":"the editor''s own"}');
  insert into help_threads (lab_id, user_id) values ('l-9000000000007', s);
  insert into oral_banks (id, title) values ('b-et-bank', 'edit test bank');
  insert into oral_sessions (id, user_id, bank_id, lab_id) values ('s-et-1', s, 'b-et-bank', 'l-9000000000008');

  -- beta mode must be gone
  if to_regclass('public.beta_users') is not null then fails := fails || 'beta_users still exists'; end if;
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and (p.proname like 'beta\_%' or p.proname in ('is_beta', 'set_beta', 'list_beta_users', 'folder_in_beta'));
  if n <> 0 then fails := fails || format('%s beta functions remain', n); end if;
  select count(*) into n from pg_policies where policyname like 'beta %'; if n <> 0 then fails := fails || 'beta storage policies remain'; end if;

  -- ===== as B (on the lists by account, can see the folder) =====
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', b::text, true);
  execute 'set local role authenticated';

  if not editor_can_edit_lab('l-9000000000001') then fails := fails || 'B cannot edit lab in edit folder'; end if;
  if not editor_can_edit_lab('l-9000000000002') then fails := fails || 'B cannot edit lab on its own list'; end if;
  if editor_can_edit_lab('l-9000000000003') then fails := fails || 'B can edit a lab with no list'; end if;
  if editor_can_edit_lab('l-9000000000004') then fails := fails || 'B can edit a draft'; end if;
  if editor_can_edit_lab('l-9000000000005') then fails := fails || 'B can edit an admin-only lab'; end if;
  if not editor_can_use_folder('f-et-edit') or not editor_can_use_folder('f-et-sub') or not editor_can_use_folder('f-et-open') then fails := fails || 'B cannot use a folder they edit'; end if;
  if editor_can_use_folder('f-et-normal') or editor_can_use_folder(null) or editor_can_use_folder('f-nope') then fails := fails || 'B can use a folder with no list'; end if;
  select string_agg(r.kind || ':' || r.item, ',' order by r.kind, r.item) into t from my_edit_rights() r where r.item like '%-et-%' or r.item like 'l-900000000000_';
  if t is distinct from 'folder:f-et-edit,folder:f-et-open,folder:f-et-sub,lab:l-9000000000001,lab:l-9000000000002,lab:l-9000000000006,lab:l-9000000000007,lab:l-9000000000008' then fails := fails || format('B rights list wrong: %s', t); end if;
  begin perform edit_granted('f-et-edit'); fails := fails || 'B may call edit_granted directly'; exception when others then null; end;

  -- no direct writes, no student data, no view of the lists
  update labs set title = 'hacked' where id = 'l-9000000000001'; get diagnostics n = row_count;
  if n <> 0 then fails := fails || 'B updated labs directly'; end if;
  update folders set access = 'public' where id = 'f-et-edit'; get diagnostics n = row_count;
  if n <> 0 then fails := fails || 'B updated folders directly'; end if;
  begin insert into labs (id, title, slug) values ('l-9000000000099', 'x', 'et-x'); fails := fails || 'B inserted into labs directly'; exception when others then null; end;
  delete from labs where id = 'l-9000000000006'; get diagnostics n = row_count; if n <> 0 then fails := fails || 'B deleted a lab directly'; end if;
  select count(*) into n from lab_entries where user_id <> b; if n <> 0 then fails := fails || format('B sees %s lab_entries rows of others', n); end if;
  select count(*) into n from students where user_id <> b; if n <> 0 then fails := fails || format('B sees %s other students', n); end if;
  select count(*) into n from seats; if n <> 0 then fails := fails || 'B sees seats'; end if;
  select count(*) into n from help_messages; if n <> 0 then fails := fails || 'B sees help messages'; end if;
  select count(*) into n from help_threads where user_id <> b; if n <> 0 then fails := fails || 'B sees help threads of others'; end if;
  select count(*) into n from oral_messages; if n <> 0 then fails := fails || 'B sees Socratic 1 messages'; end if;
  select count(*) into n from oral_sessions where user_id <> b; if n <> 0 then fails := fails || 'B sees Socratic 1 sessions of others'; end if;
  select count(*) into n from events; if n <> 0 then fails := fails || 'B sees events'; end if;
  select count(*) into n from lab_revisions; if n <> 0 then fails := fails || 'B sees revisions'; end if;
  select count(*) into n from item_edit_users; if n <> 0 then fails := fails || 'B can read the edit lists (accounts)'; end if;
  select count(*) into n from item_edit_groups; if n <> 0 then fails := fails || 'B can read the edit lists (classes)'; end if;
  begin insert into item_edit_users (item_id, user_id) values ('l-9000000000003', b); fails := fails || 'B put themselves on an edit list'; exception when others then null; end;
  begin insert into item_edit_groups (item_id, group_id) values ('f-et-normal', 'g-et-view'); fails := fails || 'B put a class on an edit list'; exception when others then null; end;
  delete from item_edit_users where user_id = c; get diagnostics n = row_count; if n <> 0 then fails := fails || 'B removed someone from an edit list'; end if;
  select count(*) into n from labs where id = 'l-9000000000004'; if n <> 0 then fails := fails || 'B sees a draft'; end if;

  -- saving an existing lab: only the allowed fields change
  t := editor_save_lab('{"id":"l-9000000000001","title":"renamed","folder_id":"f-et-edit","status":"draft","access":"public","slug":"stolen","sort_order":7,"tags":["a","b"]}'::jsonb,
                       '{"content":"new text","format":"labtags","media":["img:labs/l-9000000000001/a.webp|a photo","youtube:abcdefghijk"]}'::jsonb, '[]'::jsonb);
  execute 'reset role';
  select (title = 'renamed' and status = 'published' and access = 'inherit' and slug = 'et-l1' and sort_order = 7 and tags = array['a','b']) into ok from labs where id = 'l-9000000000001';
  if not coalesce(ok, false) or t <> 'et-l1' then fails := fails || 'save changed a field it must not, or missed one it should'; end if;
  select (content = 'new text' and array_length(media, 1) = 2) into ok from lab_content where lab_id = 'l-9000000000001';
  if not coalesce(ok, false) then fails := fails || 'content not saved'; end if;
  select count(*) into n from lab_revisions where lab_id = 'l-9000000000001' and saved_by = b and snapshot->'content'->>'content' = 'original';
  if n <> 1 then fails := fails || 'no revision with the editor and the old content'; end if;
  execute 'set local role authenticated';

  -- moves
  begin perform editor_save_lab('{"id":"l-9000000000001","title":"x","folder_id":"f-et-normal"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'moved a lab out to a folder with no list'; exception when others then null; end;
  begin perform editor_save_lab('{"id":"l-9000000000001","title":"x","folder_id":""}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'moved a lab to the top level'; exception when others then null; end;
  begin perform editor_save_lab('{"id":"l-9000000000002","title":"x","folder_id":"f-et-edit"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'moved a lab edited on its own list'; exception when others then null; end;
  perform editor_save_lab('{"id":"l-9000000000001","title":"renamed","folder_id":"f-et-sub","sort_order":7}'::jsonb, '{"content":"new text","format":"labtags"}'::jsonb);
  perform editor_save_lab('{"id":"l-9000000000002","title":"lone renamed","folder_id":"f-et-normal","sort_order":55}'::jsonb, '{"content":"lone","format":"html"}'::jsonb);
  execute 'reset role';
  select folder_id = 'f-et-sub' into ok from labs where id = 'l-9000000000001'; if not coalesce(ok, false) then fails := fails || 'move between edit folders failed'; end if;
  select (title = 'lone renamed' and sort_order = 0) into ok from labs where id = 'l-9000000000002'; if not coalesce(ok, false) then fails := fails || 'lab on its own list: title not saved or order changed'; end if;
  execute 'set local role authenticated';

  -- labs that are not open to B
  begin perform editor_save_lab('{"id":"l-9000000000003","title":"x","folder_id":"f-et-normal"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'saved a lab with no list'; exception when others then null; end;
  begin perform editor_save_lab('{"id":"l-9000000000004","title":"x","folder_id":"f-et-edit"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'saved a draft'; exception when others then null; end;
  begin perform editor_save_lab('{"id":"l-9000000000005","title":"x","folder_id":"f-et-edit"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'saved an admin-only lab'; exception when others then null; end;

  -- new labs
  t := editor_save_lab('{"id":"l-9100000000001","title":"Brand New Lab!","folder_id":"f-et-edit","slug":"et-l3"}'::jsonb, '{"content":"hello","format":"labtags"}'::jsonb);
  begin perform editor_save_lab('{"id":"l-9100000000002","title":"x","folder_id":"f-et-normal"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'created a lab outside an edit folder'; exception when others then null; end;
  begin perform editor_save_lab('{"id":"l-9100000000003","title":"x"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'created a lab at the top level'; exception when others then null; end;
  begin perform editor_save_lab('{"id":"x-1","title":"x","folder_id":"f-et-edit"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'accepted a bad id'; exception when others then null; end;
  begin perform editor_save_lab('{"id":"l-9100000000004","title":"x","folder_id":"f-et-edit","cover_path":"img:x'' onerror=''y"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'accepted a cover path with a quote'; exception when others then null; end;
  begin perform editor_save_lab('{"id":"l-9100000000005","title":"x","folder_id":"f-et-edit"}'::jsonb, '{"content":"x","format":"labtags","media":["img:a\\b"]}'::jsonb); fails := fails || 'accepted a media path with a backslash'; exception when others then null; end;
  if not editor_can_edit_lab('l-9100000000001') then fails := fails || 'B cannot edit the lab they just created'; end if;
  execute 'reset role';
  select (status = 'published' and access = 'inherit' and folder_id = 'f-et-edit' and slug = 'et-l3-2') into ok from labs where id = 'l-9100000000001';
  if not coalesce(ok, false) or t <> 'et-l3-2' then fails := fails || format('new lab wrong (slug %s)', t); end if;
  execute 'set local role authenticated';

  -- files attached to a lab
  begin perform editor_save_lab('{"id":"l-9000000000001","title":"renamed","folder_id":"f-et-sub"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb, '[{"id":"a-et-1","name":"f","path":"photos/someone/x.jpg"}]'::jsonb); fails := fails || 'attached a file outside the lab folder'; exception when others then null; end;
  begin perform editor_save_lab('{"id":"l-9000000000001","title":"renamed","folder_id":"f-et-sub"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb, '[{"id":"a-et-other","name":"f","path":"labs/l-9000000000001/x.pdf"}]'::jsonb); fails := fails || 'took over another lab''s file row'; exception when others then null; end;
  perform editor_save_lab('{"id":"l-9000000000001","title":"renamed","folder_id":"f-et-sub"}'::jsonb, '{"content":"new text","format":"labtags"}'::jsonb, '[{"id":"a-et-1","name":"handout.pdf","path":"labs/l-9000000000001/170-ab-handout.pdf","mime":"application/pdf","size_bytes":10}]'::jsonb);
  execute 'reset role';
  select count(*) into n from attachments where lab_id = 'l-9000000000001' and id = 'a-et-1'; if n <> 1 then fails := fails || 'file not attached'; end if;
  select count(*) into n from attachments where id = 'a-et-other' and lab_id = 'l-9000000000003'; if n <> 1 then fails := fails || 'other lab''s file row was touched'; end if;
  execute 'set local role authenticated';

  -- which blocks hold saved work: ids only
  select string_agg(w.key, ',' order by w.key) into t from editor_lab_work_keys('l-9000000000001') w;
  if t is distinct from 'q1' then fails := fails || format('work keys wrong: %s', t); end if;
  begin perform * from editor_lab_work_keys('l-9000000000003'); fails := fails || 'work keys given for a lab B cannot edit'; exception when others then null; end;

  -- order and delete
  begin perform editor_set_lab_order('l-9000000000002', 5); fails := fails || 'reordered a lab edited on its own list'; exception when others then null; end;
  perform editor_set_lab_order('l-9000000000001', 42);
  begin perform editor_delete_lab('l-9000000000001'); fails := fails || 'deleted a lab that holds someone else''s entries'; exception when others then null; end;
  begin perform editor_delete_lab('l-9000000000007'); fails := fails || 'deleted a lab that holds someone else''s help thread'; exception when others then null; end;
  begin perform editor_delete_lab('l-9000000000008'); fails := fails || 'deleted a lab that holds someone else''s Socratic 1 session'; exception when others then null; end;
  begin perform editor_delete_lab('l-9000000000002'); fails := fails || 'deleted a lab edited on its own list'; exception when others then null; end;
  begin perform editor_delete_lab('l-9000000000003'); fails := fails || 'deleted a lab B cannot edit'; exception when others then null; end;
  perform editor_delete_lab('l-9000000000006', true);
  if not editor_can_edit_lab('l-9000000000006') then fails := fails || 'the check-only call deleted the lab'; end if;
  perform editor_delete_lab('l-9000000000006');   -- holds only B's own entry
  execute 'reset role';
  select count(*) into n from labs where id = 'l-9000000000006'; if n <> 0 then fails := fails || 'delete left the lab'; end if;
  select count(*) into n from lab_content where lab_id = 'l-9000000000006'; if n <> 0 then fails := fails || 'delete left the lab content'; end if;
  select count(*) into n from item_edit_users where item_id = 'l-9000000000006'; if n <> 0 then fails := fails || 'delete left the lab''s edit list'; end if;
  select count(*) into n from labs where id in ('l-9000000000001', 'l-9000000000002', 'l-9000000000003', 'l-9000000000007', 'l-9000000000008'); if n <> 5 then fails := fails || 'a refused delete removed a lab'; end if;
  select (sort_order = 42) into ok from labs where id = 'l-9000000000001'; if not coalesce(ok, false) then fails := fails || 'order not saved'; end if;
  select count(*) into n from lab_entries where lab_id = 'l-9000000000001' and user_id = s; if n <> 1 then fails := fails || 'the student entry was touched'; end if;
  select count(*) into n from help_threads where lab_id = 'l-9000000000007' and user_id = s; if n <> 1 then fails := fails || 'the student help thread was touched'; end if;
  select count(*) into n from oral_sessions where id = 's-et-1'; if n <> 1 then fails := fails || 'the student Socratic 1 session was touched'; end if;
  execute 'set local role authenticated';

  -- files in storage
  if not editor_can_add_file('lab-files-public', 'labs/l-9000000000001/170-ab-x.webp') then fails := fails || 'cannot add a file to an editable lab'; end if;
  if not editor_can_add_file('lab-files-public', 'labs/l-9200000000001/170-ab-x.webp') then fails := fails || 'cannot add a file for a lab being created'; end if;
  if editor_can_add_file('lab-files-private', 'labs/l-9000000000001/170-ab-x.webp') then fails := fails || 'may write to the private bucket'; end if;
  if editor_can_add_file('lab-files-public', 'photos/' || s || '/l-1/x.jpg') or editor_can_add_file('lab-files-private', 'photos/' || s || '/l-1/x.jpg') then fails := fails || 'may write under photos/'; end if;
  if editor_can_add_file('lab-files-public', 'labs/l-9000000000003/x.webp') then fails := fails || 'may add a file to a lab B cannot edit'; end if;
  if editor_can_add_file('lab-files-public', 'labs/l-9000000000001/../x.webp') or editor_can_add_file('lab-files-public', 'folders/f-et-edit/x.webp') or editor_can_add_file('lab-files-public', 'site/x.webp') then fails := fails || 'may add a file outside a lab folder'; end if;
  begin insert into storage.objects (bucket_id, name) values ('lab-files-private', 'photos/' || s || '/l-1/et.jpg'); fails := fails || 'inserted into the private bucket'; exception when others then null; end;
  begin insert into storage.objects (bucket_id, name) values ('lab-files-public', 'labs/l-9000000000003/et.webp'); fails := fails || 'inserted a file for a lab B cannot edit'; exception when others then null; end;
  select count(*) into n from storage.objects where bucket_id = 'lab-files-private'; if n <> 0 then fails := fails || format('B can list %s private files', n); end if;
  execute 'reset role';

  -- ===== as C (on the lists, but cannot see the restricted folder) =====
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', c::text, true);
  execute 'set local role authenticated';
  if editor_can_edit_lab('l-9000000000001') or editor_can_use_folder('f-et-edit') or editor_can_use_folder('f-et-sub') then fails := fails || 'C can edit in a folder they cannot see'; end if;
  if not editor_can_use_folder('f-et-open') or not editor_can_edit_lab('l-9000000000002') then fails := fails || 'C cannot edit the public items they are listed on'; end if;
  select count(*) into n from labs where id = 'l-9000000000001'; if n <> 0 then fails := fails || 'being on an edit list let C SEE a restricted lab'; end if;
  select count(*) into n from folders where id = 'f-et-edit'; if n <> 0 then fails := fails || 'being on an edit list let C SEE a restricted folder'; end if;
  select string_agg(r.kind || ':' || r.item, ',' order by r.kind, r.item) into t from my_edit_rights() r where r.item like '%-et-%' or r.item like 'l-9_00000000000_';
  if t is distinct from 'folder:f-et-open,lab:l-9000000000002' then fails := fails || format('C rights list wrong: %s', t); end if;
  begin perform editor_save_lab('{"id":"l-9000000000001","title":"x","folder_id":"f-et-sub"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'C saved a lab they cannot see'; exception when others then null; end;
  begin perform editor_save_lab('{"id":"l-9100000000009","title":"x","folder_id":"f-et-edit"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'C created a lab in a folder they cannot see'; exception when others then null; end;
  begin perform editor_save_lab('{"id":"l-9000000000001","title":"x","folder_id":"f-et-open"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'C pulled a lab they cannot see into their folder'; exception when others then null; end;
  begin perform editor_delete_lab('l-9000000000007'); fails := fails || 'C deleted a lab they cannot see'; exception when others then null; end;
  execute 'reset role';

  -- ===== as K (a class member; the class is on the folder's list) =====
  perform set_config('request.jwt.claims', json_build_object('sub', k, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', k::text, true);
  execute 'set local role authenticated';
  if not editor_can_use_folder('f-et-edit') or not editor_can_use_folder('f-et-sub') or not editor_can_edit_lab('l-9000000000001') then fails := fails || 'a class on the edit list does not let its member edit'; end if;
  if editor_can_edit_lab('l-9000000000002') or editor_can_use_folder('f-et-open') or editor_can_edit_lab('l-9000000000003') then fails := fails || 'K can edit things their class is not listed on'; end if;
  perform editor_save_lab('{"id":"l-9100000000007","title":"made by a class member","folder_id":"f-et-sub"}'::jsonb, '{"content":"k","format":"labtags"}'::jsonb);
  select count(*) into n from lab_entries where user_id <> k; if n <> 0 then fails := fails || 'K sees entries of others'; end if;
  execute 'reset role';
  select count(*) into n from labs where id = 'l-9100000000007' and folder_id = 'f-et-sub' and status = 'published' and access = 'inherit'; if n <> 1 then fails := fails || 'the class member''s new lab is wrong'; end if;

  -- ===== as ordinary student S =====
  perform set_config('request.jwt.claims', json_build_object('sub', s, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', s::text, true);
  execute 'set local role authenticated';
  if editor_can_edit_lab('l-9000000000001') or editor_can_use_folder('f-et-open') or editor_can_use_folder('f-et-edit') or editor_can_add_file('lab-files-public', 'labs/l-9000000000001/x.webp') then fails := fails || 'a student on no list has edit rights'; end if;
  select count(*) into n from my_edit_rights(); if n <> 0 then fails := fails || 'a student on no list is given rights'; end if;
  begin perform editor_save_lab('{"id":"l-9000000000001","title":"x","folder_id":"f-et-sub"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'a student on no list saved a lab'; exception when others then null; end;
  begin perform editor_save_lab('{"id":"l-9100000000008","title":"x","folder_id":"f-et-edit"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'a student on no list created a lab'; exception when others then null; end;
  begin perform editor_delete_lab('l-9100000000001'); fails := fails || 'a student on no list deleted a lab'; exception when others then null; end;
  begin perform editor_set_lab_order('l-9000000000001', 1); fails := fails || 'a student on no list reordered a lab'; exception when others then null; end;
  execute 'reset role';

  -- ===== signed out =====
  perform set_config('request.jwt.claims', '{"role":"anon"}', true); perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';
  if editor_can_edit_lab('l-9000000000002') or editor_can_use_folder('f-et-open') then fails := fails || 'a signed-out visitor has edit rights'; end if;
  begin perform editor_save_lab('{"id":"l-9000000000002","title":"x","folder_id":"f-et-normal"}'::jsonb, '{"content":"x","format":"labtags"}'::jsonb); fails := fails || 'a signed-out visitor saved a lab'; exception when others then null; end;
  begin perform * from my_edit_rights(); fails := fails || 'a signed-out visitor may ask for edit rights'; exception when others then null; end;
  begin select count(*) into n from item_edit_users; fails := fails || 'a signed-out visitor can query the edit lists'; exception when others then null; end;
  execute 'reset role';

  -- ===== as an admin: keeps the lists; taking someone off is immediate =====
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated', 'app_metadata', json_build_object('role', 'admin'))::text, true);
  perform set_config('request.jwt.claim.sub', a::text, true);
  execute 'set local role authenticated';
  select count(*) into n from item_edit_users where item_id = 'f-et-edit'; if n <> 2 then fails := fails || format('admin reads %s accounts on the folder list, expected 2', n); end if;
  select count(*) into n from item_edit_groups where item_id = 'f-et-edit'; if n <> 1 then fails := fails || 'admin cannot read the classes on the folder list'; end if;
  insert into item_edit_users (item_id, user_id) values ('l-9000000000003', s);
  delete from item_edit_users where user_id = b; get diagnostics n = row_count; if n <> 3 then fails := fails || format('admin removed %s of B''s rows, expected 3', n); end if;
  delete from folders where id = 'f-et-open'; get diagnostics n = row_count; if n <> 1 then fails := fails || 'admin could not delete a folder'; end if;
  execute 'reset role';
  delete from group_members where group_id = 'g-et-class' and user_id = k;   -- K leaves the class
  select count(*) into n from item_edit_users where item_id = 'f-et-open'; if n <> 0 then fails := fails || 'a deleted folder kept its edit list'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', b::text, true);
  execute 'set local role authenticated';
  if editor_can_edit_lab('l-9000000000002') or editor_can_edit_lab('l-9000000000001') or editor_can_use_folder('f-et-edit') then fails := fails || 'B still has edit rights after being taken off the lists'; end if;
  select count(*) into n from my_edit_rights(); if n <> 0 then fails := fails || 'B is still given rights after being taken off the lists'; end if;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', k, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', k::text, true);
  execute 'set local role authenticated';
  if editor_can_edit_lab('l-9000000000001') or editor_can_use_folder('f-et-edit') then fails := fails || 'K still has edit rights after leaving the class'; end if;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', s, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', s::text, true);
  execute 'set local role authenticated';
  if not editor_can_edit_lab('l-9000000000003') then fails := fails || 'a student the admin listed on one lab cannot edit it'; end if;
  if editor_can_edit_lab('l-9000000000002') then fails := fails || 'that student can edit another lab'; end if;
  execute 'reset role';

  raise exception 'EDITORS TEST RESULT: failures: %', case when array_length(fails, 1) is null then 'none' else array_to_string(fails, ' | ') end;
end $test$;
