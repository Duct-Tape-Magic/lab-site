-- ============================================================
-- DATA API GRANTS. From 2026-10-30 Supabase no longer grants the Data API roles access to NEW tables in "public"
-- automatically. Row-level security still decides who sees which rows; these grants only let the API reach the tables.
-- Idempotent and safe on the live project (existing tables already carry these). Run after schema.sql on a fresh project,
-- and add the same two lines for every table created from now on.
-- ============================================================
grant usage on schema public to anon, authenticated;
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('grant select, insert, update, delete on public.%I to anon, authenticated', t);
  end loop;
end $$;
grant usage, select on all sequences in schema public to anon, authenticated;
