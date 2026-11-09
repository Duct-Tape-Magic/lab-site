# Socratic 1 — oral tutor widget

Built 2026-11-08 from the owner's standalone prototype ("Socratic 1 Proto", Oral Tutor Prototype folder, HANDOFF.md).
The prototype's bank, prompt and reminder are kept in `docs/socratic/` as format references only.

**Prompt precedence.** The tutor's guiding prompt and reminder live as defaults in `supabase/functions/socratic/index.ts`.
The Widgets tab shows them in text boxes; saving the page stores whatever is in the boxes in `oral_settings`, and a stored
text overrides the default from then on, so a later change to the default in code is not seen until the stored copy is
cleared (empty the box and save) or edited to match. `settings` reports `defaults.system_prompt` / `defaults.reminder`
true when the code default is in force. Prompt rules as of 2026-11-09: explain the concept fully when asked, then a
follow-up or "does that make sense"; rigorous but let go once understood (qualitative); quantitative problems run to a
numerically correct answer; grade kindly and honestly; credit quickly what the student already knows and move on.

## What it is

A widget block, `\widget[type=socratic, bank=<bank id>, label=…]{optional framing}`, picked in the Builder's Widget menu.
A signed-in student (access code or account) taps Start; the tutor poses a problem from a bank the owner wrote, the
student answers in words, the tutor credits, diagnoses or scaffolds and picks the next problem by difficulty. Text only.
Formative, never graded. Everything about it is managed on the admin bar's **Widgets** tab, under **Socratic tutor**:
the guiding prompt, the per-turn reminder, model and effort, the weekly message allowance per student, the warning shown
as it runs low, the site-wide daily spend ceiling, and the problem banks (drop a .txt file or paste, edit with a live parse check, hide, delete).

## Pieces

| Piece | Where |
|---|---|
| Tables, grants, RLS | `supabase/socratic.sql` — `oral_banks`, `oral_settings` (admin only); `oral_sessions`, `oral_messages`, `oral_reports`, `oral_usage` (written only by the function; a student reads their own sessions and messages, an admin reads all). |
| Server function | `supabase/functions/socratic/index.ts` — actions `settings`, `check-bank` (admin), `resume`, `start`, `turn`, `end`, `report`. Verifies the login, applies the caps, assembles the call (prompt + rendered bank cached 1 h, append-only transcript, reminder as a mid-conversation system message), streams SSE, strips and stores the hidden state line, moves the difficulty target in code. Model `claude-sonnet-5-5`, effort medium by default; `fallbacks: "default"` so a safety-classifier decline is retried server-side. |
| Widget | `widgets/socratic.v2.js` + `WIDGETS.socratic` — conversation, text box, Send, End session, one progress line, warning line. Sign-in gate before Start. `ctx.call` = `ltFnStream('socratic', …)`. |
| Credit by topic | The bank is a pool, not a set to finish. Credit attaches to the concepts in `\concepts`: a credited problem demonstrates the concepts it is tagged with, a revealed one marks them "needs work", skipped changes nothing. `conceptState(session, bank)` in the function derives `{ total, credited[], needs_work[], untouched[], all_done }` from `served`, sends it as `progress.topics / topics_total / all_done`, puts it in the per-turn reminder (credited, needs work, untouched; when all are credited the tutor is told to suggest ending instead of posing more) and writes it to `oral_sessions.concepts` after every turn (**needs the column: `alter table public.oral_sessions add column if not exists concepts jsonb;`**, in `supabase/socratic.sql`; the function retries without it until then). Student progress line: "{topics} of {total} topics credited · {posed} problems worked"; `socAllDone` note when every topic is credited; report line `socDoneLine` and admin review use the same numbers. The problem count of the bank is no longer shown to students. |
| Skip and Report | `widgets/socratic.v3.js`. **Skip this problem**: action `skip`; code closes the problem in play as `skipped` (no difficulty change, never re-posed, counted as posed but not done) and the tutor is told, acknowledges in a sentence and poses the next. Counts as one message against the weekly allowance. **Report a problem**: a small box under the tutor (intro, text, Send report); action `report` stores the note in `oral_reports` with the problem id and, when the session belongs to a lab, posts it into the student's help thread for that lab (`help_threads`/`help_messages`, role student, "Where" = bank title + problem id) so it shows in the Help panel and triggers the same email notice as a help question, whether or not Get help is switched on for that lab. Admin review of the student's lab lists the reports above the transcript. |
| Admin review | A reviewed student's lab shows every session of theirs on the block's bank, transcript folded under a one-line summary (`socraticReviewInto`). |
| Report | `\usesocratic{widget-id}` shows one line, "Socratic problems completed: N of M · K credited", once a session has ended; `\usesocratic[transcript]{…}` shows the whole conversation and the tutor's closing summary too. Builder: "Include the tutor session". |
| Banks | Exact grammar and every option in `docs/socratic/BANK-FORMAT.md`; worked example `docs/socratic/sample-bank.txt`; parsed by `parseBank` (function) and `oralParseBank` (admin check) — identical grammars, keep them in step. |

## Session carry-over

`oral_settings.carry_summary` (`on`/`off`, default off; the checkbox on the Socratic 1 page). Off: every session starts
clean. On: the closing summary of the student's last ended session on the same bank is handed to the tutor at the start
of the next one. The default prompt tells the tutor never to greet a student as returning.

## Limits and warning

`oral_settings.caps` = `{ turnsPerWeek, warnAt, siteDailyUsd }`. A student's messages are counted per calendar week (Monday
to Sunday, UTC) across all banks; when the allowance is used the tutor shows the `socLimit` text and takes no more turns
(ending a session is always allowed). When `remaining ≤ warnAt`, the owner's `warn_text` (with `{n}`) shows under the
conversation. `siteDailyUsd` stops every tutor for the rest of the day once the site's model spend passes it (0 = off).
A monthly spend limit in the Anthropic Console is the backstop.

## Owner setup (once)

1. **Tables.** Supabase dashboard → SQL editor → paste all of `supabase/socratic.sql` → Run.
2. **Command line.** In a terminal, in the Lab Site folder: `npx supabase login` (opens the browser), then
   `npx supabase link --project-ref nioebkjtrweyxvboajyv`. After that the assistant can run
   `npx supabase functions deploy socratic` for every change.
3. **Key.** `npx supabase secrets set ANTHROPIC_API_KEY=sk-ant-…` in your own terminal (never pasted into chat), or
   dashboard → Edge Functions → Secrets. Set a monthly spend limit in the Anthropic Console.

## Rules carried over

No emails, no student logins beyond codes/seats. Every student-facing string is a text key (`soc*`, `widgetSignIn`).
Widgets passive until tapped, nothing kept in the browser, bare interface, calm failures, Get help never automatic.
Nothing student-authored is deleted by the site; a bank with sessions cannot be deleted, only hidden.
