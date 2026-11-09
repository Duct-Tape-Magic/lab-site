# Socratic problem bank: exact format

Written 2026-11-09. This is the grammar the site actually parses (`oralParseBank` in `index.html` for the
admin-side check, `parseBank` in `supabase/functions/socratic/index.ts` for the tutor; the two are identical).
A worked 15-problem example is `sample-bank.txt` in this folder.

## Where a bank goes

1. Site admin → **Widgets** tab → **Socratic 1** → **Banks** → New bank (or an existing one).
2. Give it a **title** (shown in the Builder picker and to you; students never see it) and paste the file
   into the source box. The check line under the box updates as you type: problem count, opener count,
   concept count, and any problem missing a `\prompt`, `\solution` or `\rubric`.
3. Save. The bank gets an id `b-<timestamp>`. In a lab, Builder's Widget block with type `socratic`
   lets you pick the bank; in markup it is `\widget[type=socratic, id=…, bank=b-…, label=…]{framing}`.
4. A bank with saved student sessions cannot be deleted, only hidden. Hidden banks leave the Builder
   picker; labs already using one keep working.

## Shape of the file

```
% comment lines start with % (whole line only; the parser drops them before reading anything)

\bank[slug=…, title="…", topic="…"]
\concepts{concept-a, concept-b, …}

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

Comma-separated list. Each problem's `concepts=` should use names from this list. The function uses it to
tell the tutor which concepts the student has not yet met (`Concepts not yet touched`), so the tutor can
steer toward them before the bank runs out. Hyphenated single tokens are easiest to read back
(`hydrogen-bonding`, `vapor-pressure`).

## `\problem[…]{…}` (one per problem)

Options:

| Option | Required | Values | Default | Effect |
|---|---|---|---|---|
| `pid` | **yes** | any token without spaces, unique in the bank | none; the file is rejected without it or if two problems share one | The id the tutor writes in its hidden state line and the key under which the site records credited/revealed. Keep pids stable once students have sessions on the bank. |
| `difficulty` | no | 1–5 (numbers; anything non-numeric becomes NaN, so use a plain integer) | 3 | 1 recall · 2 apply one idea · 3 compare two ideas · 4 weigh competing effects · 5 synthesize or evaluate a claim. The code moves a target up (+1 after a clean credit), holds it (credit after scaffolding) or down (−1 after a reveal), clamped 1–5, and tells the tutor the target each turn. |
| `opener` | no | bare flag, no value | off | Marks a broad problem suitable to start with. The tutor opens with an opener. The session's starting target difficulty is the lowest opener difficulty (2 if there are no openers). **Mark at least one**; the check line warns if none. |
| `concepts` | no | quoted, comma-separated | empty | Which concepts this problem tests. Drives the "not yet touched" list and the remaining-problems line in the reminder. |

Body sub-commands (all optional to the parser; the check line flags a problem missing `prompt`, `solution`
or `rubric`, and the tutor cannot run a problem well without them):

| Sub-command | What to write | How the tutor uses it |
|---|---|---|
| `\catalog{…}` | One or two sentences on **what this problem discriminates**: which misunderstanding it catches, not what topic it is about. | Read when choosing the next problem. Write it for the tutor, not the student. |
| `\prompt{…}` | The problem exactly as the student should hear it. Formulas as `\ce{...}` or `$…$`. | Posed verbatim at the start of the problem. |
| `\answer[…]` | Options only, no body: `value=`, `unit=`, `tol=` (free-form, e.g. `tol=3%`). Any option names are accepted and passed through. | Shown to the model as a JSON line. Only useful for numeric problems; omit otherwise. |
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

- 10–20 problems per bank; students pose roughly one problem per 3–6 messages.
- Two or three openers at difficulty 2, spread across concepts.
- Cover every concept in `\concepts` with at least two problems at different difficulties so the tutor
  can go at a shaky concept "from another angle".
- Keep `\catalog` about the discrimination, keep `\rubric` to the three or four things that actually
  distinguish understanding, and keep pids stable after students have used the bank.
