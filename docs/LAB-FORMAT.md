# Lab file format

This document tells you how to write a **lab file** for the OHS lab website. Give it to Claude together with a PDF of a lab and the instruction: *"Convert this lab to a lab file following LAB-FORMAT.md. Keep the original structure and wording."*

A lab file is plain text: **Markdown for the writing**, plus a small set of **LaTeX-style commands** (`\command[options]{content}`) that mark the places where the website should embed something interactive — a data table students fill in, a place to add a photo, a video, a question with an answer box, and so on. The website reads the file and renders a clean, interactive report. Students' entries save automatically in their own browser and print with the lab.

**You do not have to write this format by hand.** The site's lab editor opens in **Builder** mode by default: a block-based, form-driven editor (headings, text, numbered steps, data tables, questions, graphs, callouts, pictures, report sections…) that produces exactly this format. Builder and the **Lab file** view are two views of the same text and you can switch between them at any time; anything the Builder has no form for is kept as a "Raw" block and round-trips untouched. Importing a `.md` file written by hand or converted by Claude opens it as blocks. This document remains the reference for the stored format and for converting PDFs.

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
| `\figure[caption=…]{path or IMAGE_n}` | A figure. Use `IMAGE_1`, `IMAGE_2`… for pictures from the PDF that the teacher must upload; the teacher replaces them with the site's "Insert image…" button, which uploads a PNG or JPG and writes the `\figure` line. Markdown images `![caption](path)` also work. |
| `\safety{…}` `\warning{…}` `\info{…}` `\tip{…}` `\hint{…}` | Highlighted callout boxes. Markdown works inside. `[label=…]` overrides the box label. |
| `\graph[table=…, x=…, y=…, type=…, fit=linear, title=…, xlabel=…, ylabel=…]{Optional caption}` | A live graph drawn from a `\datatable`. It redraws as the student types. See "Graphs" below. |
| `\pagebreak` | Starts a new page when printed. |

Notes on syntax:
- Options go in square brackets, comma-separated: `[id=q1, lines=3]`. Values with commas or spaces can be quoted: `[title="Trial 1, run A"]`.
- Content goes in curly braces and may span many lines. Braces must balance (LaTeX inside is fine).
- Commands that stand alone (`\datatable`, `\answer`, `\photo`, `\video`, `\figure`, callouts, `\procedure`) go on their own line. `\input` sits inside a sentence.
- Anything inside `$…$`, `$$…$$`, `\ce{…}` or backticks is left alone, so LaTeX like `\frac{}` never conflicts with commands.

## Graphs

Whenever the lab asks students to plot their data, add a `\graph` right after the table (or after the analysis question that refers to it). Options:

- `table=` the `id` of the `\datatable` to read (required).
- `x=` and `y=` which columns to plot, as `c1`, `c2`, … (1-based). Simple formulas are allowed: `x="1/(c1+273.15)"`, `y="ln(c2)"`, `y="c3-c2"`. Functions: `ln`, `log` (base 10), `exp`, `sqrt`, `abs`; operators `+ - * / ^`. Quote any value containing commas or spaces.
- Several y series: `y="c2;c3"`, with optional names `series="Trial 1;Trial 2"`.
- `type=scatter` (default), `line` (points joined), or `both`.
- `fit=linear` adds a least-squares line and prints its equation and R².
- `title=`, `xlabel=`, `ylabel=` for labels; `xmin/xmax/ymin/ymax` to fix axis ranges (otherwise automatic).
- Caption in the braces.

Rows with a blank or non-numeric x or y are skipped, so the graph simply grows as the student fills the table.

```
\datatable[id=visc, addrows]{
| Temperature (°C) | Viscosity (mPa·s) |
|---|---|
| 20 | ___ |
| 40 | ___ |
| 60 | ___ |
}

\graph[table=visc, x=c1, y=c2, type=both, title="Viscosity vs temperature", xlabel="Temperature (°C)", ylabel="Viscosity (mPa·s)"]{Viscosity falls as temperature rises.}

\graph[table=visc, x="1/(c1+273.15)", y="ln(c2)", fit=linear, xlabel="1/T (K⁻¹)", ylabel="ln η"]{Arrhenius plot: the slope gives Eₐ/R.}
```

## Report tab (write-up skeleton)

A lab may end with a `\report{…}` block. When present, the lab page shows two tabs, **Procedure** and **Report**; when absent there is no Report tab. The Report tab guides the student through writing up the lab and, with "Preview report", turns their writing into a clean printable document (title, date, numbered tables and figures) that they save as a PDF and submit.

Inside `\report{…}` use ordinary Markdown plus:

| Command | What it does |
|---|---|
| `\section[id=…, required, words=min-max, hint="…", lines=6, title=…]{Question or instructions}` | One question in the report: your prompt (Markdown), an expandable hint, and a writing box. `title` is optional and adds a heading above the question; leave it out for a plain numbered-style question. `required` marks it; `words=40-120` shows a gentle word-count target (`words=40` for a minimum only, `words=-120` for a maximum only). |
| `\usetable{id}` | Shows a read-only copy of the `\datatable` with that id, filled with the student's own data, captioned "Table n". |
| `\usegraph{id}` | Shows the `\graph` with that id (give the graph an `id=` option), drawn from the student's data, captioned "Figure n". |
| `\useanswer{id}` | Shows a procedure `\answer` or `\notes` box (by its id): the prompt plus what the student wrote there. Read-only; the student edits it on the Procedure tab. |
| `\usephoto{id}` | Shows the photo the student added in the procedure `\photo` slot with that id, with its prompt. |
| `\answer`, `\datatable`, `\photo`, `\notes`, `\graph` | Work inside the report exactly as in the procedure: use them when the report should *ask* for something new (a fresh data table to fill in, a question answered only in the write-up, a photo of the final result) instead of copying it from the procedure. |

The `\use…` commands only refer to blocks in the procedure, so every referenced block needs an explicit `id=`.

Rules for converting a PDF: if the PDF includes report instructions, a rubric, or "write-up" requirements, turn them into `\section`s in the same order, using the PDF's own wording for prompts. Put every data table the report must include in `\usetable{…}` and every required plot in `\usegraph{…}`; if the write-up asks for a table the procedure never collected, put a `\datatable` in the report instead. Keep report sections short and specific; do not invent requirements the PDF does not state.

```
\report{
\section[id=purpose, title="Purpose", required, words=30-80, hint="One or two sentences: what was measured and why."]{State the goal of this experiment in your own words.}

\section[id=results, title="Results", required, words=80-200]{Summarize what the data show. Refer to Table 1 and Figure 1.}

\usetable{visc}

\usegraph{arrhenius}

\section[id=calculations, title="Calculations", required, hint="Show one worked example for each type of calculation, with units."]

\section[id=error, title="Sources of error", words=50-150]{Identify two specific sources of error and how each would change your result.}

\section[id=conclusion, title="Conclusion", required, words=50-150]
}
```

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
