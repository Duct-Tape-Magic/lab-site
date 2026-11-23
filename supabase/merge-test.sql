-- Self-undoing test of moving lab work between accounts (supabase/merge-2026-11-22.sql). Run it in the Supabase SQL editor.
-- It is ONE statement: it builds made-up users, labs, entries, a help thread and Socratic 1 sessions, acts as a student and as
-- an admin through the same roles the site uses, and always ends by raising "MERGE TEST RESULT …", which rolls back everything
-- it did (the made-up rows, and the temporary is_admin() without the dashboard exception). It reads no real student data:
-- every row it touches is one it created. "failures: none" is a pass.
do $test$
declare
  f uuid := gen_random_uuid();   -- the account work is moved from
  t uuid := gen_random_uuid();   -- the account work is moved to
  o uuid := gen_random_uuid();   -- another student, never part of a move
  a uuid := gen_random_uuid();   -- admin
  fails text[] := '{}';
  n int; x text; j jsonb; d jsonb; d2 jsonb;
  f1 timestamptz; f2 timestamptz; t2 timestamptz; f3 timestamptz; before timestamptz;
  tid bigint;
begin
  execute $f$ create or replace function public.is_admin() returns boolean language sql stable as $i$ select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin' $i$ $f$;

  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
    (f, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'merge-test-f@test.invalid', '{}', '{}', now(), now()),
    (t, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'merge-test-t@test.invalid', '{}', '{}', now(), now()),
    (o, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'merge-test-o@test.invalid', '{}', '{}', now(), now()),
    (a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'merge-test-a@test.invalid', '{"role":"admin"}', '{}', now(), now());
  insert into folders (id, parent_id, name, slug, access) values ('f-mt', null, 'merge test', 'merge-test', 'public');
  insert into labs (id, folder_id, title, slug, status, access) values
    ('l-8000000000001', 'f-mt', 'only on the first account', 'mt-l1', 'published', 'inherit'),
    ('l-8000000000002', 'f-mt', 'on both accounts', 'mt-l2', 'published', 'inherit'),
    ('l-8000000000003', 'f-mt', 'on the first account, not chosen', 'mt-l3', 'published', 'inherit'),
    ('l-8000000000004', 'f-mt', 'only on the second account', 'mt-l4', 'published', 'inherit');
  insert into lab_entries (user_id, lab_id, data, updated_at) values
    (f, 'l-8000000000001', '{"q1":"F lab 1"}', now() - interval '9 days'),
    (f, 'l-8000000000002', '{"q1":"F lab 2"}', now() - interval '8 days'),
    (t, 'l-8000000000002', '{"q1":"T lab 2","_moved":"mv-1111111111"}', now() - interval '2 days'),
    (f, 'l-8000000000003', '{"q1":"F lab 3"}', now() - interval '7 days'),
    (t, 'l-8000000000004', '{"q1":"T lab 4"}', now() - interval '1 day'),
    (o, 'l-8000000000001', '{"q1":"O lab 1"}', now() - interval '3 days');
  select updated_at into f1 from lab_entries where user_id = f and lab_id = 'l-8000000000001';
  select updated_at into f2 from lab_entries where user_id = f and lab_id = 'l-8000000000002';
  select updated_at into t2 from lab_entries where user_id = t and lab_id = 'l-8000000000002';
  select updated_at into f3 from lab_entries where user_id = f and lab_id = 'l-8000000000003';
  insert into help_threads (lab_id, user_id) values ('l-8000000000001', f) returning id into tid;
  insert into help_messages (thread_id, user_id, role, body) values (tid, f, 'student', 'made-up question'), (tid, a, 'admin', 'made-up reply');
  insert into help_threads (lab_id, user_id) values ('l-8000000000002', f), ('l-8000000000002', t), ('l-8000000000001', o);
  insert into oral_banks (id, title) values ('b-mt-bank', 'merge test bank');
  insert into oral_sessions (id, user_id, bank_id, lab_id) values
    ('s-mt-f1', f, 'b-mt-bank', 'l-8000000000001'), ('s-mt-f3', f, 'b-mt-bank', 'l-8000000000003'),
    ('s-mt-t2', t, 'b-mt-bank', 'l-8000000000002'), ('s-mt-o1', o, 'b-mt-bank', 'l-8000000000001');

  -- ===== as a student: no moving, no reading the record =====
  perform set_config('request.jwt.claims', json_build_object('sub', f, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', f::text, true);
  execute 'set local role authenticated';
  begin
    perform move_lab_work('mv-9000000001', f, t, jsonb_build_array(jsonb_build_object('lab_id', 'l-8000000000001', 'from_saved_at', f1)));
    fails := fails || 'a student could move work';
  exception when others then if sqlerrm not like '%admin only%' then fails := fails || format('student refusal was: %s', sqlerrm); end if; end;
  begin insert into entry_moves (move_id, lab_id, from_user, to_user, action) values ('mv-9000000002', 'x', f, t, 'moved'); fails := fails || 'a student wrote entry_moves';
  exception when others then null; end;
  execute 'reset role';
  execute 'set local role anon';
  begin
    perform move_lab_work('mv-9000000003', f, t, jsonb_build_array(jsonb_build_object('lab_id', 'l-8000000000001', 'from_saved_at', f1)));
    fails := fails || 'a visitor could move work';
  exception when others then null; end;
  execute 'reset role';
  select count(*) into n from lab_entries where user_id = f and lab_id like 'l-800000000000_'; if n <> 3 then fails := fails || 'entries changed by a refused call'; end if;

  -- ===== as the admin =====
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated', 'app_metadata', json_build_object('role', 'admin'))::text, true);
  perform set_config('request.jwt.claim.sub', a::text, true);
  execute 'set local role authenticated';

  -- refusals, each leaving everything as it was
  begin perform move_lab_work('mv-9000000010', f, f, jsonb_build_array(jsonb_build_object('lab_id', 'l-8000000000001', 'from_saved_at', f1))); fails := fails || 'same account twice accepted';
  exception when others then null; end;
  begin perform move_lab_work('mv-9000000011', f, a, jsonb_build_array(jsonb_build_object('lab_id', 'l-8000000000001', 'from_saved_at', f1))); fails := fails || 'an admin account accepted as target';
  exception when others then null; end;
  begin perform move_lab_work('mv-9000000012', f, gen_random_uuid(), jsonb_build_array(jsonb_build_object('lab_id', 'l-8000000000001', 'from_saved_at', f1))); fails := fails || 'a missing account accepted';
  exception when others then null; end;
  begin perform move_lab_work('mv-9000000013', f, t, '[]'::jsonb); fails := fails || 'an empty list accepted';
  exception when others then null; end;
  begin perform move_lab_work('bad id', f, t, jsonb_build_array(jsonb_build_object('lab_id', 'l-8000000000001', 'from_saved_at', f1))); fails := fails || 'a bad move id accepted';
  exception when others then null; end;
  begin   -- stale: the first copy's time does not match
    perform move_lab_work('mv-9000000014', f, t, jsonb_build_array(jsonb_build_object('lab_id', 'l-8000000000001', 'from_saved_at', f1 - interval '1 second')));
    fails := fails || 'a stale first copy accepted';
  exception when others then if sqlerrm not like '%saved again%' then fails := fails || format('stale refusal was: %s', sqlerrm); end if; end;
  begin   -- stale: the list said the second account had nothing for lab 2
    perform move_lab_work('mv-9000000015', f, t, jsonb_build_array(jsonb_build_object('lab_id', 'l-8000000000002', 'from_saved_at', f2, 'to_saved_at', null)));
    fails := fails || 'a copy that appeared on the second account was overwritten';
  exception when others then null; end;
  begin   -- all or nothing: one good lab and one the first account has no work on
    perform move_lab_work('mv-9000000016', f, t, jsonb_build_array(
      jsonb_build_object('lab_id', 'l-8000000000001', 'from_saved_at', f1),
      jsonb_build_object('lab_id', 'l-8000000000004', 'from_saved_at', f1)));
    fails := fails || 'a lab the first account has no work on was accepted';
  exception when others then null; end;
  execute 'reset role';
  select count(*) into n from lab_entries where user_id = f and lab_id like 'l-800000000000_'; if n <> 3 then fails := fails || 'a refused move changed the first account'; end if;
  select count(*) into n from lab_entries where user_id = t and lab_id like 'l-800000000000_'; if n <> 2 then fails := fails || 'a refused move changed the second account'; end if;
  select count(*) into n from entry_moves where move_id like 'mv-90000000__'; if n <> 0 then fails := fails || 'a refused move left a record'; end if;
  execute 'set local role authenticated';

  -- the real move: lab 1 (only on the first account, with photos listed) and lab 2 (on both)
  before := clock_timestamp();
  j := move_lab_work('mv-9000000020', f, t, jsonb_build_array(
    jsonb_build_object('lab_id', 'l-8000000000001', 'from_saved_at', f1, 'to_saved_at', null, 'from_photos', jsonb_build_array('p1.jpg', 'p1.2.jpg')),
    jsonb_build_object('lab_id', 'l-8000000000002', 'from_saved_at', f2, 'to_saved_at', t2)));
  if j is distinct from '[{"lab_id":"l-8000000000001","action":"moved","threads":1,"sessions":1},{"lab_id":"l-8000000000002","action":"swapped","threads":0,"sessions":0}]'::jsonb then fails := fails || format('result wrong: %s', j); end if;
  select count(*) into n from entry_moves where move_id = 'mv-9000000020'; if n <> 2 then fails := fails || 'the admin cannot read the record'; end if;
  begin perform move_lab_work('mv-9000000020', f, t, jsonb_build_array(jsonb_build_object('lab_id', 'l-8000000000003', 'from_saved_at', f3))); fails := fails || 'the same move id ran twice';
  exception when others then null; end;
  execute 'reset role';

  -- lab 1: moved
  select count(*) into n from lab_entries where user_id = f and lab_id = 'l-8000000000001'; if n <> 0 then fails := fails || 'lab 1 still on the first account'; end if;
  select data into d from lab_entries where user_id = t and lab_id = 'l-8000000000001';
  if d is distinct from '{"q1":"F lab 1","_moved":"mv-9000000020"}'::jsonb then fails := fails || format('lab 1 on the second account: %s', d); end if;
  select count(*) into n from lab_entries where user_id = t and lab_id = 'l-8000000000001' and updated_at >= before; if n <> 1 then fails := fails || 'lab 1 was not stamped as saved now'; end if;
  -- lab 2: traded places, both stamped
  select data into d from lab_entries where user_id = t and lab_id = 'l-8000000000002';
  select data into d2 from lab_entries where user_id = f and lab_id = 'l-8000000000002';
  if d is distinct from '{"q1":"F lab 2","_moved":"mv-9000000020"}'::jsonb then fails := fails || format('lab 2 on the second account: %s', d); end if;
  if d2 is distinct from '{"q1":"T lab 2","_moved":"mv-9000000020"}'::jsonb then fails := fails || format('lab 2 on the first account: %s', d2); end if;
  select count(*) into n from lab_entries where lab_id = 'l-8000000000002' and user_id in (f, t) and updated_at >= before; if n <> 2 then fails := fails || 'lab 2 copies were not both stamped'; end if;
  -- everything not chosen is as it was
  select count(*) into n from lab_entries where (user_id, lab_id, data) in ((f, 'l-8000000000003', '{"q1":"F lab 3"}'::jsonb), (t, 'l-8000000000004', '{"q1":"T lab 4"}'::jsonb), (o, 'l-8000000000001', '{"q1":"O lab 1"}'::jsonb)) and updated_at < before;
  if n <> 3 then fails := fails || 'a lab that was not chosen changed'; end if;
  select count(*) into n from lab_entries where lab_id like 'l-800000000000_'; if n <> 6 then fails := fails || format('%s entry rows, expected 6 (nothing may be lost)', n); end if;
  -- help threads: lab 1 went along with its student message; lab 2 (both had one) and the other student's stayed
  select count(*) into n from help_threads where id = tid and user_id = t; if n <> 1 then fails := fails || 'lab 1 help thread did not move'; end if;
  select count(*) into n from help_messages where thread_id = tid and ((role = 'student' and user_id = t) or (role = 'admin' and user_id = a)); if n <> 2 then fails := fails || 'lab 1 help messages wrong'; end if;
  select count(*) into n from help_threads where lab_id = 'l-8000000000002' and user_id in (f, t); if n <> 2 then fails := fails || 'lab 2 help threads changed'; end if;
  select count(*) into n from help_threads where lab_id = 'l-8000000000001' and user_id = o; if n <> 1 then fails := fails || 'the other student''s help thread changed'; end if;
  -- Socratic 1 sessions: only the first account's sessions for a moved lab change owner
  select string_agg(id || '=' || case user_id when f then 'f' when t then 't' when o then 'o' else '?' end, ',' order by id) into x from oral_sessions where id like 's-mt-%';
  if x is distinct from 's-mt-f1=t,s-mt-f3=f,s-mt-o1=o,s-mt-t2=t' then fails := fails || format('sessions wrong: %s', x); end if;
  select count(*) into n from oral_sessions where id like 's-mt-%' and ended_at is not null; if n <> 0 then fails := fails || 'a session was ended'; end if;
  -- the record
  select count(*) into n from entry_moves where move_id = 'mv-9000000020' and moved_by = a and from_user = f and to_user = t
    and ((lab_id = 'l-8000000000001' and action = 'moved' and from_saved_at = f1 and to_saved_at is null and from_photos = array['p1.jpg', 'p1.2.jpg'] and to_photos = '{}' and not photos_done and threads_moved = 1 and sessions_moved = 1)
      or (lab_id = 'l-8000000000002' and action = 'swapped' and from_saved_at = f2 and to_saved_at = t2 and photos_done and threads_moved = 0 and sessions_moved = 0));
  if n <> 2 then fails := fails || 'the record of the move is wrong'; end if;

  -- a student still cannot read the record, and anon cannot touch the table
  perform set_config('request.jwt.claims', json_build_object('sub', f, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', f::text, true);
  execute 'set local role authenticated';
  select count(*) into n from entry_moves; if n <> 0 then fails := fails || 'a student can read entry_moves'; end if;
  update entry_moves set photos_done = true where move_id = 'mv-9000000020'; get diagnostics n = row_count; if n <> 0 then fails := fails || 'a student updated entry_moves'; end if;
  execute 'reset role';
  execute 'set local role anon';
  begin select count(*) into n from entry_moves; fails := fails || 'a visitor can read entry_moves'; exception when others then null; end;
  execute 'reset role';

  -- the same swap again puts lab 2 back (the way to undo)
  select updated_at into f2 from lab_entries where user_id = f and lab_id = 'l-8000000000002';
  select updated_at into t2 from lab_entries where user_id = t and lab_id = 'l-8000000000002';
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated', 'app_metadata', json_build_object('role', 'admin'))::text, true);
  perform set_config('request.jwt.claim.sub', a::text, true);
  execute 'set local role authenticated';
  perform move_lab_work('mv-9000000021', f, t, jsonb_build_array(jsonb_build_object('lab_id', 'l-8000000000002', 'from_saved_at', f2, 'to_saved_at', t2)));
  update entry_moves set photos_done = true where move_id = 'mv-9000000020' and lab_id = 'l-8000000000001'; get diagnostics n = row_count; if n <> 1 then fails := fails || 'the admin cannot mark photos done'; end if;
  execute 'reset role';
  select data into d from lab_entries where user_id = t and lab_id = 'l-8000000000002';
  select data into d2 from lab_entries where user_id = f and lab_id = 'l-8000000000002';
  if d is distinct from '{"q1":"T lab 2","_moved":"mv-9000000021"}'::jsonb or d2 is distinct from '{"q1":"F lab 2","_moved":"mv-9000000021"}'::jsonb then fails := fails || format('undo wrong: %s / %s', d, d2); end if;

  raise exception 'MERGE TEST RESULT: failures: %', case when array_length(fails, 1) is null then 'none' else array_to_string(fails, ' | ') end;
end $test$;
