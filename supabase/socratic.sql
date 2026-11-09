-- Socratic tutor widget (docs/SOCRATIC.md). Run once in the SQL editor, as the project owner.
-- Banks and settings are admin-only; students never read a bank (solutions stay server-side).
-- Sessions, messages, reports and usage are written only by the `socratic` Edge Function (service role);
-- a student reads their own sessions and messages, an admin reads everything. Nothing here is ever deleted
-- by the site; account deletion cascades like every other per-user table.

create table if not exists public.oral_banks (
  id            text primary key,                 -- 'b-<timestamp>'
  title         text not null,
  source        text not null default '',          -- the bank file (docs/socratic/sample-bank.txt shows the format)
  problem_count int  not null default 0,
  hidden        boolean not null default false,    -- hidden banks stay out of the Builder picker; labs using them keep working
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create table if not exists public.oral_settings (  -- system_prompt, reminder, model, effort, caps (JSON)
  key   text primary key,
  value text
);
create table if not exists public.oral_sessions (
  id                text primary key,              -- 's-<timestamp>-<rand>'
  user_id           uuid not null references auth.users(id) on delete cascade,
  bank_id           text not null references public.oral_banks(id),
  lab_id            text,
  model             text,
  effort            text,
  started_at        timestamptz not null default now(),
  ended_at          timestamptz,
  target_difficulty int  not null default 2,
  served            jsonb not null default '{}'::jsonb,   -- pid -> { status, difficulty, studentTurns, flag }
  current_pid       text,
  bank_total        int,                         -- problems in the bank when the session started (for the report line)
  previous_summary  text,
  summary           text,
  turns             int  not null default 0,
  cost              numeric not null default 0,
  concepts          jsonb                          -- { total, credited[], needs_work[], untouched[], all_done } written by the function after every turn
);
alter table public.oral_sessions add column if not exists concepts jsonb;   -- added 2026-11-09 (credit by topic)

create table if not exists public.oral_messages (
  id          bigserial primary key,
  session_id  text not null references public.oral_sessions(id) on delete cascade,
  role        text not null,                       -- 'user' | 'assistant'
  blocks      jsonb not null,                      -- API content blocks for user turns; [{type:'text', text: raw}] for assistant turns
  raw         text,                                -- assistant: the full reply including the hidden state line
  text        text,                                -- assistant: what the student sees
  state       jsonb,                               -- parsed hidden state line
  usage       jsonb,
  cost        numeric,
  hidden      boolean not null default false,      -- system-generated user turns (session start, session end)
  created_at  timestamptz not null default now()
);
create table if not exists public.oral_reports (
  id          bigserial primary key,
  session_id  text not null references public.oral_sessions(id) on delete cascade,
  message_id  bigint,
  pid         text,
  note        text,
  created_at  timestamptz not null default now()
);
create table if not exists public.oral_usage (
  user_id       uuid not null references auth.users(id) on delete cascade,
  day           date not null,
  turns         int not null default 0,
  input_tokens  bigint not null default 0,
  output_tokens bigint not null default 0,
  cost          numeric not null default 0,
  primary key (user_id, day)
);
create index if not exists oral_sessions_user_bank on public.oral_sessions (user_id, bank_id, started_at desc);
create index if not exists oral_messages_session on public.oral_messages (session_id, id);

-- Data API grants (Supabase stopped granting these automatically on 2026-10-30); RLS below is the real boundary.
grant select, insert, update, delete on public.oral_banks, public.oral_settings, public.oral_sessions, public.oral_messages, public.oral_reports, public.oral_usage to anon, authenticated;
grant usage, select on all sequences in schema public to anon, authenticated;

alter table public.oral_banks    enable row level security;
alter table public.oral_settings enable row level security;
alter table public.oral_sessions enable row level security;
alter table public.oral_messages enable row level security;
alter table public.oral_reports  enable row level security;
alter table public.oral_usage    enable row level security;

drop policy if exists "admin banks"    on public.oral_banks;
create policy "admin banks"    on public.oral_banks    for all using (is_admin()) with check (is_admin());
drop policy if exists "admin settings" on public.oral_settings;
create policy "admin settings" on public.oral_settings for all using (is_admin()) with check (is_admin());
drop policy if exists "read own sessions" on public.oral_sessions;
create policy "read own sessions" on public.oral_sessions for select using (user_id = auth.uid() or is_admin());
drop policy if exists "read own messages" on public.oral_messages;
create policy "read own messages" on public.oral_messages for select
  using (exists (select 1 from public.oral_sessions s where s.id = session_id and (s.user_id = auth.uid() or is_admin())));
drop policy if exists "admin reports" on public.oral_reports;
create policy "admin reports" on public.oral_reports for select using (is_admin());
drop policy if exists "admin usage" on public.oral_usage;
create policy "admin usage" on public.oral_usage for select using (is_admin());
-- No insert/update/delete policies for clients on sessions, messages, reports or usage: the Edge Function writes them with the service role.
