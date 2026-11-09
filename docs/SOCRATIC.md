# Socratic 1 — oral tutor widget (plan, 2026-11-08)

Built from the owner's standalone prototype "Socratic 1 Proto" (Oral Tutor Prototype folder; its HANDOFF.md
describes what was learned). The sample bank and prompt from the prototype are kept here only as format
references (`docs/socratic/`); they are not the content that ships.

## What it is

A widget block, `\widget[type=socratic, bank=<bank id>]{optional framing}`. A signed-in student taps Start,
the tutor (a Claude model) poses a problem from a bank the owner wrote, the student answers in words, the
tutor credits, diagnoses or corrects, and chooses the next problem by difficulty. Formative only; never graded;
no camera. The owner adds problems and edits the tutor's prompt from the admin bar on the live site.

## Pieces

1. **Database** (`supabase/socratic.sql`, run by the owner in the SQL editor; then the Data API grant line):
   - `oral_banks` (id, title, source text, problem_count, updated_at). Admin only. Solutions never reach a
     browser: students have no read policy at all; the server function reads with the service role.
   - `oral_settings` (key, value): `system_prompt`, `reminder`, `model`, `effort`, `caps` (JSON). Admin only.
   - `oral_sessions` (id, user_id, bank_id, lab_id, model, started_at, ended_at, target_difficulty, served
     jsonb, summary, cost). `oral_messages` (id, session_id, role, blocks jsonb, raw, text, state jsonb, usage
     jsonb, created_at). `oral_reports` (session_id, message_id, pid, note). `oral_usage` (user_id, day,
     turns, input_tokens, output_tokens, cost). Students read their own sessions and messages; all writes go
     through the function. Admin reads everything (for a later TA view). Nothing student-authored is deleted.
2. **Edge Function `socratic`** (`supabase/functions/socratic/index.ts`, Deno, deployed with the Supabase CLI
   or pasted into the dashboard). Actions `start`, `turn`, `end`, `report`, `resume`. Verifies the caller's
   session token, refuses anonymous callers, checks the per-student and site-wide daily caps, assembles the
   call exactly as the prototype does (system prompt + rendered bank as the cached prefix, append-only
   transcript, reminder with live status as the last message), streams the reply, strips and stores the hidden
   state line, moves the difficulty target in code. Secrets: `ANTHROPIC_API_KEY` set by the owner only.
3. **Widget** (`WIDGETS.socratic` + `widgets/socratic.v1.js`): passive until Start; bare interface: the
   conversation, a text box, Send, I'm stuck, End session, and a one-line progress note; plain green text
   confirmations; formulas rendered with the vendored KaTeX. Not signed in → one calm line, no Start. Records
   nothing into lab tables (its data is the session). Resumes an open session on reopening the lab.
4. **Admin: Socratic tab** in the admin bar: the prompt (two text boxes: guiding prompt, reminder), model and
   effort, daily caps, and the bank list: add, edit (a text box in the bank format with a live parse check:
   problem count, missing fields, duplicate ids), delete (refused while sessions reference it; hide instead).
5. **Builder**: the Widget picker gains Socratic; its card has a bank dropdown and the framing text.
6. **Docs**: LAB-FORMAT.md "Widgets" gains the socratic entry; WIDGETS.md gets the build log; this file.

## Rules carried over

No emails, no student logins beyond codes/seats; seat numbers only ever leave the browser. Every student-facing
string is a text key. Widgets passive until tapped, no memory in the browser, bare interface, calm failures,
Get help never automatic. Backup before the push that adds the block type. Keys pasted by the owner only.

## Decisions (owner)

1. Who may use it: signed-in students only (recommended; anonymous visitors see "sign in to practise").
2. Photos of hand-drawn work: not in v1 (recommended; text only, add later).
3. Caps: per student 60 turns a day; site-wide a daily spend ceiling in the function plus a monthly limit set
   in the Anthropic Console. Numbers to confirm.
4. Model: Sonnet 5.5, effort medium, changeable in the Socratic tab.
5. Transcripts are stored (the model needs them); no TA screen in v1.

## Owner setup (once)

1. Run `supabase/socratic.sql` in the project's SQL editor.
2. Install the Supabase CLI through npm (`npx supabase login`, `npx supabase link --project-ref nioebkjtrweyxvboajyv`),
   or paste the function into the dashboard's Edge Functions editor.
3. Set the secret: `npx supabase secrets set ANTHROPIC_API_KEY=…` in your own terminal (or Project Settings →
   Edge Functions → Secrets). Set a monthly spend limit in the Anthropic Console.
