# Socratic problem bank: exact format

Written 2026-11-09. This is the grammar the site actually parses (`oralParseBank` in `index.html` for the
admin-side check, `parseBank` in `supabase/functions/socratic/index.ts` for the tutor; the two are identical).
A worked 15-problem example is `sample-bank.txt` in this folder.

## Where a bank goes

1. Site admin → **Widgets** tab → **Socratic 1** → **Banks** → New bank (or an existing one).
2. Drop the `.txt` file anywhere on the Socratic 1 page (or on the drop zone in the editor, or click the
   zone to choose it). Dropping with no editor open starts a new bank; dropping into an open editor replaces
   its text after a confirmation. Pasting into the text box still works. The **title** (shown in the Builder
   picker and to you; students never see it) is filled from `\bank[title=…]`, else from the file name; change
   it if you like. The check line under the box updates as you type: problem count, opener count, concept
   count, and any problem missing a `\prompt`, `\solution` or `\rubric`.
3. Save. The bank gets an id `b-<timestamp>`. In a lab, Builder's Widget block with type `socratic`
   lets you pick the bank; in markup it is `\widget[type=socratic, id=…, bank=b-…, label=…]{framing}`.
4. A bank with saved student sessions cannot be deleted, only hidden. Hidden banks leave the Builder
   picker; labs already using one keep working.

## Shape of the file

```
% comment lines start with % (whole line only; the parser drops them before reading anything)

\bank[slug=…, title="…", topic="…"]
\concepts{concept-a, concept-b, …}

\intro{…}
\levelcheck{…}

\problem[pid=…, difficulty=N, opener, concepts="…, …"]{
\catalog{…}
\prompt{…}
\answer[value=…, unit=…, tol=…]
\solution{…}
\rubric{…}
\scaffolds{…}
\extensions{…}
\misconceptions{…}
}

\problem[…]{ … }
```

Commands are `\name`, then optional `[options]`, then an optional `{body}`. Braces nest and must balance.
A backslash escapes the next character, so `\ce{H2O}` inside a body is fine. Whitespace between `]` and
`{` is allowed. Anything outside a recognised command is ignored.

## `\bank[…]` (once, no body)

| Option | Required | Used for |
|---|---|---|
| `slug` | no | Short handle. Falls back as the title if `title` is missing. Not shown to students. |
| `title` | no | Heading of the bank text the model reads. Default: the slug, else "Untitled bank". |
| `topic` | no | One line under the heading in the model's copy. Default empty. |

The bank's **site** title (the one in the Widgets tab) is the separate title box, not this option.

## `\concepts{…}` (once)

Comma-separated list. **This list is what the student is credited for.** The bank is a pool: the tutor
uses only as many problems as it takes for the student to demonstrate every concept here, then suggests
ending. A student who knows the material may be done in four problems; one who is struggling may need
twelve. Each problem's `concepts=` must use names from this list. Hyphenated single tokens are easiest
to read back (`hydrogen-bonding`, `vapor-pressure`).

How credit works: when the tutor credits a problem, every concept that problem is tagged with counts as
credited. When it reveals the solution, those concepts are marked as needing work and the tutor comes back
to them with a different problem. A skipped problem changes nothing. So **tag a problem only with the
concepts a credit on it genuinely demonstrates**; a problem tagged with five concepts credits all five at
once. Keep the list to the handful of ideas the set is meant to teach (roughly 5 to 12), and give each one
several problems at different difficulties so the tutor has choices.

## `\intro{…}` and `\levelcheck{…}` (once each, added 2026-11-10)

How a session opens. When the student presses **Start session** the site shows the `\intro` text and then
the `\levelcheck` question, exactly as written, as the tutor's first message. **The tutor is not called**: no
model reply is generated until the student answers, so starting costs nothing.

| Block | Required | What it is |
|---|---|---|
| `\intro{…}` | no | A short written overview of what the session covers. Plain sentences, blank line between paragraphs, math as in the problems. Without it the student gets no overview. |
| `\levelcheck{…}` | no | One question asking how much the student already knows about the first topic of the session. Without it the site asks its general question (site text `socLevelAsk`, editable under the tutor's Words students see). |

The student's reply to the level question is a self-report, not an answer. The tutor does not grade it: it
picks a starting difficulty from it (all new or unsure 1, seen it but shaky 2, comfortable 3, knows it
well 4, never 5; 2 if they skip the question), records it with `level=N` in its hidden state line, and poses
the first problem at that difficulty on the topic the question asked about. From there the difficulty moves
with how the student actually does. So the topic named in `\levelcheck` should have problems at difficulties
1 through 4.

Both blocks go after `\concepts{…}` and before the first `\problem`. Neither may contain a line starting
with `%`. The check line shows "opening overview" and "level question" when they are present and gives
advice when they are not.

## `\problem[…]{…}` (one per problem)

Options:

| Option | Required | Values | Default | Effect |
|---|---|---|---|---|
| `pid` | **yes** | any token without spaces, unique in the bank | none; the file is rejected without it or if two problems share one | The id the tutor writes in its hidden state line and the key under which the site records credited/revealed. Keep pids stable once students have sessions on the bank. |
| `difficulty` | no | 1–5 (numbers; anything non-numeric becomes NaN, so use a plain integer) | 3 | 1 recall · 2 apply one idea · 3 compare two ideas · 4 weigh competing effects · 5 synthesize or evaluate a claim. The code moves a target up (+1 after a clean credit), holds it (credit after scaffolding) or down (−1 after a reveal), clamped 1–5, and tells the tutor the target each turn. |
| `opener` | no | bare flag, no value | off | Marks a broad problem suitable to start with. The tutor prefers an opener for the first problem when one fits the starting difficulty it chose from the student's self-report. Optional since 2026-11-10; the check line no longer asks for one. |
| `concepts` | no | quoted, comma-separated | empty | Which concepts this problem tests. Drives the "not yet touched" list and the remaining-problems line in the reminder. |

Body sub-commands (all optional to the parser; the check line flags a problem missing `prompt`, `solution`
or `rubric`, and the tutor cannot run a problem well without them):

| Sub-command | What to write | How the tutor uses it |
|---|---|---|
| `\catalog{…}` | One or two sentences on **what this problem discriminates**: which misunderstanding it catches, not what topic it is about. | Read when choosing the next problem. Write it for the tutor, not the student. |
| `\prompt{…}` | The problem exactly as the student should hear it. Formulas as `\ce{...}` or `$…$`. | Posed verbatim at the start of the problem. |
| `\answer[…]` | Options only, no body: `value=`, `unit=`, `tol=` (free-form, e.g. `tol=3%`), and `of="…"` naming which quantity the value is when the prompt asks for several (`of="gasoline to liquid hydrogen, energy per liter"`). Any option names are accepted and passed through. | Shown to the model as a JSON line. The tutor checks the student's number for the named quantity against it and judges the problem's other numbers against the solution. Only useful for numeric problems; omit otherwise. The check line flags a problem with several questions and an answer field without `of=`. |
| `\solution{…}` | Full worked reasoning, the standard the student's explanation is judged against. | Private to the model. Never shown to students. |
| `\rubric{…}` | Checkable items, one per line, as `- item`. | The tutor credits when the student's own words cover these. Fewer, sharper items credit more cleanly ("ties go to the student"). |
| `\scaffolds{…}` | Numbered questions to ask when the student stalls, from gentlest to most pointed. | Asked one at a time, in order, before any reveal. The prompt reveals after about three. |
| `\extensions{…}` | Numbered "and what if" pushes for a student who answered well. | Used to deepen a strong answer before moving on. |
| `\misconceptions{…}` | One per line: `- what the student says → what to ask back`. | The tutor names the error in the student's words and asks the paired question. |

The parser trims each body. Line structure inside bodies is kept and passed to the model as written, so
lists written with `-` and `1.` arrive intact.

## What the model sees

Per problem, rendered as text and cached for an hour:

```
## imf-01  (difficulty 2, opener; concepts: hydrogen-bonding, dispersion, boiling-point)
catalog: …
prompt: …
answer: {"value":"-3.4","unit":"°C","tol":"3%"}      (only if \answer is present)
solution: …
rubric:
- …
scaffolds:
1. …
extensions:
1. …
misconceptions:
- … → …
```

Every turn also ends with a reminder listing problems used, problems remaining (pid, difficulty, opener flag,
concepts), concepts not yet touched, and the target difficulty. That is all code; nothing in the bank changes it.

## Rejections

The check line turns red and Save is refused when:

- a `{` is never closed
- a `\problem` has no `pid=`
- two problems share a pid
- there are no `\problem` blocks at all

A problem missing `\prompt`, `\solution` or `\rubric` is listed by pid as a warning; the file still saves.

## Writing guidance (not enforced)

- The bank can be large (a week's homework, 50 problems is fine); the student will see only a handful.
  What matters is that every concept has several problems to choose from.
- Give the topic named in `\levelcheck` problems at difficulties 1 through 4, so the first problem can match the student's self-report. Mark the broad ones `opener`.
- Cover every concept in `\concepts` with at least three problems at different difficulties, including one at
  difficulty 1 or 2: after a reveal the tutor must come back to that concept with an easier problem before
  anything new, and after two reveals it explains the idea with a worked example instead of posing a third.
  The check line lists concepts that have no easy problem.
- Keep `\catalog` about the discrimination, keep `\rubric` to the three or four things that actually
  distinguish understanding, and keep pids stable after students have used the bank.
