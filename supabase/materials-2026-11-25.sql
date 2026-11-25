-- ============================================================
-- MATERIALS LISTS (owner, 2026-11-25). Idempotent: safe to run again. Also the last section of schema.sql.
--
-- The admin Materials panel. A list is a name and a set of ticked labs; the "materials" Edge Function reads those labs'
-- Materials sections and stores the cumulative list here (one entry per distinct item, each with the labs and wording it
-- came from). Lab files only: nothing in this table comes from student work.
-- Admins read and write the name and the ticked labs from the page; the function (service role) writes the rest.
-- ============================================================
create table if not exists public.materials_lists (
  id          text primary key,                    -- 'ml-<timestamp>'
  title       text not null,
  lab_ids     text[] not null default '{}',        -- the ticked labs (no foreign key: a deleted lab is skipped when the list is built)
  items       jsonb not null default '[]',         -- [{ name, category, sources: [{ lab_id, text, group }], unmerged? }]
  report      jsonb not null default '{}',         -- { read: [{ lab_id, lines }], missing: [lab_id], empty: [lab_id], gone: [lab_id], lines, unmerged }
  source_hash text,                                -- fingerprint of the material lines the list was built from; unchanged = not rebuilt
  model       text,
  cost        numeric not null default 0,          -- $ of the last build
  built_at    timestamptz,
  created_at  timestamptz not null default now()
);
alter table public.materials_lists enable row level security;
-- Only admins read or write it (Supabase no longer grants new tables to the API roles by itself, so the grants are spelled out).
revoke all on public.materials_lists from anon, authenticated;
grant select, insert, update, delete on public.materials_lists to authenticated, service_role;
drop policy if exists "admin all materials_lists" on public.materials_lists;
create policy "admin all materials_lists" on public.materials_lists for all using (is_admin()) with check (is_admin());
