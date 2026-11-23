-- ============================================================
-- Stats: how activity is counted (owner, 2026-11-22). Replaces the first stats functions.
--
--   * A day is a calendar day at the school, which is on Pacific time ("the days should flip over at midnight west coast
--     time, because ohs is west coast time"). stats_tz() is the one place that says so.
--   * "Last n days" is n whole calendar days ending today, and stats_daily returns EVERY one of them, with zeros.
--   * A lab view is one student opening one lab on one day, however many tabs or reloads it took.
--   * Only lab events of signed-in accounts are counted: view, download, print. Folder pages and searches are not
--     recorded any more, and old rows of those kinds are ignored here.
--   * Events can only be logged by a signed-in account, under its own id.
--
-- Safe to run more than once. supabase/stats-test.sql checks the counting with made-up events.
-- ============================================================

create or replace function public.stats_tz() returns text language sql immutable as $$ select 'America/Los_Angeles'::text $$;
create or replace function public.stats_today() returns date language sql stable as $$ select (now() at time zone public.stats_tz())::date $$;

-- The counted events of the last n school days, each with its school day. Internal: not callable through the API.
create or replace function public.stats_events(n_days int)
returns table(day date, type text, lab_id text, visitor_id text)
language sql stable security definer set search_path = public as $$
  select (e.ts at time zone stats_tz())::date, e.type, e.lab_id, e.visitor_id
  from events e
  where e.lab_id is not null and e.visitor_id is not null and e.type in ('view', 'download', 'print')
    and e.ts >= (stats_today() - (least(greatest(coalesce(n_days, 30), 1), 366) - 1))::timestamp at time zone stats_tz()
$$;
revoke all on function public.stats_events(int) from public, anon, authenticated;

-- One row for every day of the range, busy or not.
create or replace function public.stats_daily(n_days int default 30)
returns table(day date, views bigint, visitors bigint)
language plpgsql stable security definer set search_path = public as $$
declare n int := least(greatest(coalesce(n_days, 30), 1), 366);
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query
    with d as (select g::date as day from generate_series(stats_today() - (n - 1), stats_today(), interval '1 day') g),
         v as (select e.day, count(distinct (e.visitor_id, e.lab_id)) filter (where e.type = 'view') as views, count(distinct e.visitor_id) as visitors
               from stats_events(n) e group by e.day)
    select d.day, coalesce(v.views, 0), coalesce(v.visitors, 0) from d left join v on v.day = d.day order by d.day;
end $$;

create or replace function public.stats_summary(n_days int default 30)
returns json
language plpgsql stable security definer set search_path = public as $$
declare n int := least(greatest(coalesce(n_days, 30), 1), 366); result json;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  select json_build_object(
    'views',     count(distinct (e.day, e.visitor_id, e.lab_id)) filter (where e.type = 'view'),
    'visitors',  count(distinct e.visitor_id),
    'downloads', count(*) filter (where e.type = 'download'),
    'prints',    count(*) filter (where e.type = 'print'),
    'days',      n,
    'today',     stats_today(),
    'first_day', (select min((x.ts at time zone stats_tz())::date) from events x),   -- when recording began
    'removed',   (select count(*) from (select distinct s.visitor_id from stats_events(n) s) v     -- counted accounts that have since been removed
                  where not exists (select 1 from auth.users u where u.id::text = v.visitor_id))
  ) into result
  from stats_events(n) e;
  return result;
end $$;

-- The row type gains "prints", so the old function has to go first.
drop function if exists public.stats_top_labs(int, int);
create function public.stats_top_labs(n_days int default 30, lim int default 20)
returns table(lab_id text, views bigint, downloads bigint, visitors bigint, prints bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query
    select e.lab_id,
           count(distinct (e.day, e.visitor_id)) filter (where e.type = 'view'),
           count(*) filter (where e.type = 'download'),
           count(distinct e.visitor_id),
           count(*) filter (where e.type = 'print')
    from stats_events(n_days) e
    group by e.lab_id order by 2 desc, e.lab_id limit lim;
end $$;

create or replace function public.stats_lab_daily(n_days int default 30)
returns table(lab_id text, day date, views bigint, visitors bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query
    select e.lab_id, e.day, count(distinct e.visitor_id) filter (where e.type = 'view'), count(distinct e.visitor_id)
    from stats_events(n_days) e
    group by e.lab_id, e.day order by e.lab_id, e.day;
end $$;

revoke all on function public.stats_daily(int), public.stats_summary(int), public.stats_top_labs(int, int), public.stats_lab_daily(int) from public, anon;
grant execute on function public.stats_daily(int), public.stats_summary(int), public.stats_top_labs(int, int), public.stats_lab_daily(int) to authenticated;

-- Logging: a signed-in account, its own id, a lab event. (The page never sent anything else for a visitor without an account;
-- now the database would not take it either.)
drop policy if exists "anyone logs events" on public.events;
drop policy if exists "students log own events" on public.events;
create policy "students log own events" on public.events for insert to authenticated
  with check (type in ('view', 'download', 'print') and lab_id is not null
              and coalesce(length(path), 0) <= 300 and visitor_id = auth.uid()::text);
