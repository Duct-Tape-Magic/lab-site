-- Self-undoing test of the stats counting (supabase/stats-2026-11-22.sql). Run it in the Supabase SQL editor.
-- It is ONE statement: it reads the totals, adds made-up events for made-up accounts and made-up lab ids at chosen school-time
-- moments, reads the totals again and checks that every number moved by exactly the known amount. It always ends by raising
-- "STATS TEST RESULT …", which rolls back everything it did. It reads no student work. "failures: none" is a pass.
do $test$
declare
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); a uuid := gen_random_uuid();
  gone text := gen_random_uuid()::text;   -- an account id that does not exist (a removed account)
  la text := 'l-7000000000001'; lb text := 'l-7000000000002';
  t0 date := stats_today();
  fails text[] := '{}';
  s0 json; s1 json; s30a json; s30b json; n int; x text;
  d0 jsonb; d1 jsonb;
begin
  execute $f$ create or replace function public.is_admin() returns boolean language sql stable as $i$ select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin' $i$ $f$;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
    (u1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'stats-test-1@test.invalid', '{}', '{}', now(), now()),
    (u2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'stats-test-2@test.invalid', '{}', '{}', now(), now()),
    (a,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'stats-test-a@test.invalid', '{"role":"admin"}', '{}', now(), now());

  -- ===== a student cannot read stats; nobody can call the internal function through the API =====
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated', 'app_metadata', json_build_object())::text, true);
  perform set_config('request.jwt.claim.sub', u1::text, true);
  execute 'set local role authenticated';
  begin perform stats_summary(7); fails := fails || 'a student read stats_summary'; exception when others then null; end;
  begin perform count(*) from stats_daily(7); fails := fails || 'a student read stats_daily'; exception when others then null; end;
  begin perform count(*) from stats_top_labs(7, 10); fails := fails || 'a student read stats_top_labs'; exception when others then null; end;
  begin perform count(*) from stats_lab_daily(7); fails := fails || 'a student read stats_lab_daily'; exception when others then null; end;
  begin perform count(*) from stats_events(7); fails := fails || 'a student called stats_events'; exception when others then null; end;

  -- ===== logging: own id, a lab event, signed in =====
  begin insert into events (type, lab_id, visitor_id, path) values ('view', la, u1::text, '#/lab/x'); exception when others then fails := fails || format('a student could not log a lab view: %s', sqlerrm); end;
  begin insert into events (type, lab_id, visitor_id) values ('view', la, u2::text); fails := fails || 'a student logged under another id'; exception when others then null; end;
  begin insert into events (type, lab_id, visitor_id) values ('view', la, null); fails := fails || 'an event without an account was accepted'; exception when others then null; end;
  begin insert into events (type, lab_id, visitor_id) values ('search', la, u1::text); fails := fails || 'a search event was accepted'; exception when others then null; end;
  begin insert into events (type, lab_id, visitor_id) values ('view', null, u1::text); fails := fails || 'a folder view was accepted'; exception when others then null; end;
  begin insert into events (type, lab_id, visitor_id, path) values ('view', la, u1::text, repeat('x', 301)); fails := fails || 'an over-long path was accepted'; exception when others then null; end;
  select count(*) into n from events; if n <> 0 then fails := fails || 'a student can read events'; end if;
  execute 'reset role';
  execute 'set local role anon';
  begin insert into events (type, lab_id, visitor_id) values ('view', la, u1::text); fails := fails || 'a visitor without an account logged an event'; exception when others then null; end;
  begin perform stats_summary(7); fails := fails || 'a visitor read stats'; exception when others then null; end;
  execute 'reset role';
  delete from events where lab_id = la and visitor_id = u1::text;   -- the one accepted row; the known set below starts clean

  -- ===== the totals before =====
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated', 'app_metadata', json_build_object('role', 'admin'))::text, true);
  perform set_config('request.jwt.claim.sub', a::text, true);
  execute 'set local role authenticated';
  s0 := stats_summary(7); s30a := stats_summary(30);
  select jsonb_object_agg(d.day, jsonb_build_array(d.views, d.visitors)) into d0 from stats_daily(7) d;
  execute 'reset role';

  -- ===== the known events =====
  insert into events (ts, type, lab_id, visitor_id) values
    ((t0::timestamp + time '00:00:01') at time zone stats_tz(), 'view', la, u1::text),
    ((t0::timestamp + time '00:00:02') at time zone stats_tz(), 'view', la, u1::text),          -- the same student, lab and day: still one view
    ((t0::timestamp + time '00:00:03') at time zone stats_tz(), 'view', la, u2::text),
    ((t0::timestamp + time '00:00:04') at time zone stats_tz(), 'view', lb, u1::text),
    (((t0 - 1)::timestamp + time '23:59:59') at time zone stats_tz(), 'view', la, u1::text),    -- one second before midnight at school: yesterday
    (((t0 - 2)::timestamp + time '12:00:00') at time zone stats_tz(), 'view', la, gone),        -- an account that has since been removed
    ((t0::timestamp + time '00:00:05') at time zone stats_tz(), 'download', la, u1::text),
    ((t0::timestamp + time '00:00:06') at time zone stats_tz(), 'download', la, u1::text),
    (((t0 - 1)::timestamp + time '10:00:00') at time zone stats_tz(), 'print', lb, u2::text),
    ((t0::timestamp + time '00:00:07') at time zone stats_tz(), 'view', null, u1::text),        -- an old folder view: ignored
    ((t0::timestamp + time '00:00:08') at time zone stats_tz(), 'search', null, u1::text),      -- an old search: ignored
    ((t0::timestamp + time '00:00:09') at time zone stats_tz(), 'view', la, null),              -- no account: ignored
    ((t0::timestamp + time '00:00:10') at time zone stats_tz(), 'unlock', la, u1::text),        -- an old kind: ignored
    (((t0 - 6)::timestamp + time '00:00:00') at time zone stats_tz(), 'view', la, u2::text),    -- the first second of a 7-day range
    (((t0 - 7)::timestamp + time '23:59:59') at time zone stats_tz(), 'view', lb, u2::text);    -- the last second before it

  -- ===== the totals after =====
  execute 'set local role authenticated';
  s1 := stats_summary(7); s30b := stats_summary(30);
  select jsonb_object_agg(d.day, jsonb_build_array(d.views, d.visitors)) into d1 from stats_daily(7) d;

  if (s1 ->> 'views')::int - (s0 ->> 'views')::int <> 6 then fails := fails || format('7-day views moved by %s, expected 6', (s1 ->> 'views')::int - (s0 ->> 'views')::int); end if;
  if (s1 ->> 'visitors')::int - (s0 ->> 'visitors')::int <> 3 then fails := fails || format('7-day students moved by %s, expected 3', (s1 ->> 'visitors')::int - (s0 ->> 'visitors')::int); end if;
  if (s1 ->> 'downloads')::int - (s0 ->> 'downloads')::int <> 2 then fails := fails || 'downloads wrong'; end if;
  if (s1 ->> 'prints')::int - (s0 ->> 'prints')::int <> 1 then fails := fails || 'prints wrong'; end if;
  if (s1 ->> 'removed')::int - (s0 ->> 'removed')::int <> 1 then fails := fails || 'removed accounts wrong'; end if;
  if (s30b ->> 'views')::int - (s30a ->> 'views')::int <> 7 then fails := fails || format('30-day views moved by %s, expected 7', (s30b ->> 'views')::int - (s30a ->> 'views')::int); end if;
  if (s1 ->> 'today')::date <> t0 or (s1 ->> 'days')::int <> 7 or (s1 ->> 'first_day') is null then fails := fails || 'summary dates wrong'; end if;

  -- every day of the range is there, in order, ending today
  select count(*), string_agg(d.day::text, ',' order by d.day) into n, x from stats_daily(7) d;
  if n <> 7 or x is distinct from (select string_agg(g::date::text, ',' order by g) from generate_series(t0 - 6, t0, interval '1 day') g) then fails := fails || format('stats_daily(7) days: %s', x); end if;
  select count(*) into n from stats_daily(90); if n <> 90 then fails := fails || format('stats_daily(90) has %s rows', n); end if;
  select count(*) into n from stats_daily(1);  if n <> 1 then fails := fails || format('stats_daily(1) has %s rows', n); end if;
  -- per day: [views, students] moved by exactly this much
  select string_agg(format('%s:%s/%s', t0 - k.day::date, (d1 -> k.day ->> 0)::int - (d0 -> k.day ->> 0)::int, (d1 -> k.day ->> 1)::int - (d0 -> k.day ->> 1)::int), ' ' order by k.day desc)
    into x from (select jsonb_object_keys(d1) as day) k;
  if x is distinct from '0:3/2 1:1/2 2:1/1 3:0/0 4:0/0 5:0/0 6:1/1' then fails := fails || format('per-day changes (days ago:views/students): %s', x); end if;

  -- per lab (the made-up lab ids have no other events)
  select string_agg(format('%s v%s d%s s%s p%s', right(t.lab_id, 1), t.views, t.downloads, t.visitors, t.prints), ' | ' order by t.lab_id) into x from stats_top_labs(7, 1000) t where t.lab_id in (la, lb);
  if x is distinct from '1 v5 d2 s3 p0 | 2 v1 d0 s2 p1' then fails := fails || format('per-lab 7 days: %s', x); end if;
  select string_agg(format('%s v%s', right(t.lab_id, 1), t.views), ' | ' order by t.lab_id) into x from stats_top_labs(30, 1000) t where t.lab_id in (la, lb);
  if x is distinct from '1 v5 | 2 v2' then fails := fails || format('per-lab 30 days: %s', x); end if;
  select string_agg(format('%s@%s v%s s%s', right(l.lab_id, 1), t0 - l.day, l.views, l.visitors), ' | ' order by l.lab_id, l.day desc) into x from stats_lab_daily(7) l where l.lab_id in (la, lb);
  if x is distinct from '1@0 v2 s2 | 1@1 v1 s1 | 1@2 v1 s1 | 1@6 v1 s1 | 2@0 v1 s1 | 2@1 v0 s1' then fails := fails || format('per-lab per-day: %s', x); end if;
  execute 'reset role';

  raise exception 'STATS TEST RESULT: failures: %', case when array_length(fails, 1) is null then 'none' else array_to_string(fails, ' | ') end;
end $test$;
