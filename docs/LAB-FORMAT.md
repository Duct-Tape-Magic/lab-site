# Lab file format

This document tells you how to write a **lab file** for the OHS lab website. Give it to Claude together with a PDF of a lab and the instruction: *"Convert this lab to a lab file following LAB-FORMAT.md. Keep the original structure and wording."*

A lab file is plain text: **Markdown for the writing**, plus a small set of **LaTeX-style commands** (`\command[options]{content}`) that mark the places where the website should embed something interactive — a data table students fill in, a place to add a photo, a video, a question with an answer box, and so on. The website reads the file and renders a clean, interactive report. Students' entries save automatically in their own browser and print with the lab.

## Rules for converting a PDF

1. **Keep the lab's own structure.** Same sections, same order, same headings, same step numbering, same wording. Do not reorganize, summarize, shorten, or add content. Fix only obvious typos.
2. **Use commands only where they add something the paper could not do**: a table the student fills in, a spot for a photo of their work, a video, an answer box under a question, notes on steps, a safety callout. If a passage is just text, leave it as text.
3. **Every blank the student would fill in on paper becomes a field.** Blank table cells become `___`. Blank lines under a question become `\answer`. A single value to record (a mass, a temperature) becomes `\input`.
4. **Math and chemistry become LaTeX**: `$c = \frac{n}{V}$`, `$$K_a = \frac{[H^+][A^-]}{[HA]}$$`, `\ce{CH3COOH + NaOH -> CH3COONa + H2O}`. Units like $\pu{0.100 M}$ are fine.
5. **Figures in the PDF cannot be copied by you.** Put `\figure[caption=...]{IMAGE_1}`, `{IMAGE_2}`, … where they belong and, at the very end of the file, list them under a `<!-- Figures needed -->` comment with a one-line description of each so the teacher can upload them.
6. **Start with the header commands** (`\title`, `\summary`, `\tags`, `\minutes`). Write the summary yourself (one or two sentences) if the PDF has none.
7. Give every field an `id` when there is any chance the lab will be edited later (ids keep students' saved entries attached to the right field). Use short lowercase ids: `trial1`, `q3`, `setup-photo`.
8. Output only the lab file, nothing else.

## Markdown you can use

Headings (`#`, `##`, `###`), paragraphs, **bold**, *italic*, numbered lists (`1.`), bullet lists (`-`), checklists (`- [ ] item` — students can tick them), links, blockquotes (`>`), horizontal rules (`---`), and tables (`| a | b |`) for information that is *not* filled in by the student. Inline code with backticks. Images with `![caption](path)` if the teacher gives you a path.

## Commands

| Command | What it does |
|---|---|
| `\title{…}` `\summary{…}` `\tags{a, b}` `\minutes{90}` | Header. Not shown in the lab; the website uses them to fill in the lab's title, card summary, tags, and estimated time. |
| `\datatable[id=…, title=…, addrows]{ table }` | A table students fill in. Write a normal Markdown table inside; every cell containing `___` becomes an editable cell, other cells are fixed text. `addrows` lets students add rows. |
| `\input[id=…, label=…, unit=…]` | A small inline box for one value, e.g. `Mass of sample: \input[id=mass, unit=g]`. |
| `\answer[id=…, lines=4]{Optional prompt}` | A multi-line answer box, `lines` tall. Usually placed right after a question. |
| `\notes[id=…]{Optional label}` | A collapsible "My notes" box. |
| `\procedure{ numbered list }` | Wraps a numbered list of steps; every step gets its own collapsible notes box automatically. |
| `\photo[id=…]{Instruction}` | A place for the student to add a photo from their phone or computer, e.g. `\photo[id=setup]{Photograph your titration setup before starting.}` |
| `\video{YouTube link}` | Embeds the video (any YouTube link, including unlisted). |
| `\figure[caption=…]{path or IMAGE_n}` | A figure. Use `IMAGE_1`, `IMAGE_2`… for pictures from the PDF that the teacher must upload. |
| `\safety{…}` `\warning{…}` `\info{…}` `\tip{…}` `\hint{…}` | Highlighted callout boxes. Markdown works inside. `[label=…]` overrides the box label. |
| `\pagebreak` | Starts a new page when printed. |

Notes on syntax:
- Options go in square brackets, comma-separated: `[id=q1, lines=3]`. Values with commas or spaces can be quoted: `[title="Trial 1, run A"]`.
- Content goes in curly braces and may span many lines. Braces must balance (LaTeX inside is fine).
- Commands that stand alone (`\datatable`, `\answer`, `\photo`, `\video`, `\figure`, callouts, `\procedure`) go on their own line. `\input` sits inside a sentence.
- Anything inside `$…$`, `$$…$$`, `\ce{…}` or backticks is left alone, so LaTeX like `\frac{}` never conflicts with commands.

## Example

```
\title{Determination of Ka for Weak Acids}
\summary{Titrate acetic acid and oxalic acid with standardized NaOH to determine their acid dissociation constants.}
\tags{acids, Ka, titration}
\minutes{130}

# Purpose

To determine the $K_a$ of acetic acid (monoprotic) and the second $K_a$ of oxalic acid (diprotic) by titration with $\pu{0.100 M}$ NaOH.

\video{https://www.youtube.com/watch?v=dQw4w9WgXcQ}

# Safety

\safety{
- Wear goggles at all times.
- NaOH is caustic. Rinse any spill on skin with water for 5 minutes.
}

# Materials

- [ ] 50 mL burette
- [ ] 25 mL pipette and bulb
- [ ] pH probe
- [ ] Phenolphthalein indicator

# Procedure

\procedure{
1. Rinse the burette with a small amount of NaOH solution, then fill it. Record the initial volume.
2. Pipette 25.00 mL of acetic acid into a clean flask and add 2 drops of phenolphthalein.
3. Place the pH probe in the flask. Record the initial pH: \input[id=ph0, unit=pH]
4. Add NaOH in 1.00 mL increments, recording the pH after each addition, until the pH exceeds 12.
}

\photo[id=setup]{Take a photo of your titration setup with the burette, flask and probe visible.}

# Data

\datatable[id=trial1, title="Trial 1 — acetic acid", addrows]{
| Volume NaOH added (mL) | pH |
|---|---|
| 0.00 | ___ |
| 1.00 | ___ |
| 2.00 | ___ |
}

\figure[caption=Expected shape of the titration curve for a weak acid.]{IMAGE_1}

# Analysis

1. At the half-equivalence point, $\text{pH} = \text{p}K_a$. Read the pH at half the equivalence volume and calculate $K_a$.

\answer[id=q1, lines=3]{Show your calculation of $K_a$ for acetic acid.}

2. Explain why the pH at the equivalence point is above 7.

\answer[id=q2, lines=4]

\notes[id=reflection]{Reflection}

<!-- Figures needed
IMAGE_1: titration curve graph from page 3 of the PDF (pH vs. volume of NaOH, half-equivalence point marked)
-->
```
