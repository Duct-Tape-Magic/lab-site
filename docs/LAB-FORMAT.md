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
| `\figure[caption=…, size=small\|medium\|full]{path or IMAGE_n}` | A figure. `size` sets how wide it is shown: `full` (default, the text column), `medium` (about 60%) or `small` (about a third); use `small` for icons and simple diagrams, `full` for anything students must read values from. Consecutive `small` figures sit side by side three to a row, consecutive `medium` ones two to a row, so put related pictures (e.g. steps of a setup) on adjacent lines. Use `IMAGE_1`, `IMAGE_2`… for pictures from the PDF that the teacher must upload; the teacher replaces them with the site's "Insert image…" button, which uploads a PNG or JPG and writes the `\figure` line. Markdown images `![caption](path)` also work. |
| `\safety{…}` `\warning{…}` `\info{…}` `\tip{…}` `\hint{…}` | Highlighted callout boxes. Markdown works inside. `[label=…]` overrides the box label. |
| `\graph[table=…, x=…, y=…, type=…, fit=linear, title=…, xlabel=…, ylabel=…]{Optional caption}` | A live graph drawn from a `\datatable`. It redraws as the student types. See "Graphs" below. |
| `\widget[type=colorimeter, id=…, table=…, columns=c2;c3;c4, sample=c1]{Optional instruction}` | An in-lab tool that uses the student's device and records what it reads into a `\datatable`. See "Widgets" below. |
| `\pagebreak` | Starts a new page when printed. |

Notes on syntax:
- Options go in square brackets, comma-separated: `[id=ka-calc, lines=3]`. Ids should be descriptive words (`ka-acetic`, `mass-data`), never the automatic pattern of a letter plus a number such as `q1` or `table2`, which the site uses for blocks without an id. Values with commas or spaces can be quoted: `[title="Trial 1, run A"]`.
- Content goes in curly braces and may span many lines. Braces must balance (LaTeX inside is fine).
- Links: ordinary Markdown `[words to show](https://address)`; students see only the words and it opens in a new tab. Never paste a bare long address into the text.
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

## Widgets (tools that record into a table)

A widget is a tool inside the lab that uses the device (for now: the phone camera) and **records values into an ordinary data table**. It never stores anything of its own, so the table prints, syncs and is reviewed exactly as if the student had typed the numbers. Students without the device type the values in by hand, so a lab must make sense with the widget never started. Add a widget only where the lab asks students to take that kind of reading, and put it right after the table it fills. Widgets go in the procedure, not in `\report{}`.

The widget is passive until the student taps Start (no camera prompt on page load). On a device without a camera it shows a calm note telling the student to open the lab on their phone.

Options common to every widget:

- `type=` which tool (required). Available: `colorimeter`.
- `id=` a permanent name, like any block.
- `table=` the `id` of the `\datatable` it records into (required). Give the table `addrows` so every reading gets a row; otherwise only the table's blank rows can take readings.
- `label=` an optional title shown in the tool's header.
- `help=off` hides the Get help button from the tool's failure note (it is offered by default, only when the lab has Get help on and the student is signed in).
- The instruction in the braces replaces the standard one. Say where to point the camera and remind students to keep the lighting the same for every sample.

### Colorimeter

Shows the camera picture with two small squares the student drags into place: a **Reference** square on any plain, matte object that stays under the same light for the whole lab (a grey card, a sheet of paper, the bench; a mid-tone is better than white, which the camera clips) and a **Sample** square on what is being measured. The student taps **Set reference** once; from then on the tool records the sample's **R, G, B** (0–255) *corrected* channel by channel: corrected = sample × (reference reading when it was set) ÷ (reference reading now). Phone cameras keep adjusting exposure and white balance, but both squares are in the same picture, so the drift moves both readings together and mostly cancels. The reference needs no known colour, only constancy. The tool keeps no memory: the baseline lasts until the student taps Stop or leaves the lab, so a data set should be taken in one run, and after a restart the student taps Set reference again (a forgotten tap is taken at the first Record). The data table holds the data; record the uncorrected values too (`rawcolumns`) if anyone may need to recompute. The interface is bare on purpose: the picture with the two squares, the R G B readout, Set reference and Record, and nothing else. Any instructions (which object to use as the reference, keeping both in the same light, avoiding readings near 0 or 255) go in the lab text or in the optional instruction in the braces. Camera values are gamma-encoded, so ratios are only roughly proportional to light intensity; for comparing tubes and plotting trends that is fine.

- `columns=c2;c3;c4` the table columns (1-based, `c1`, `c2`, …) that take the corrected R, G and B, in that order. Default `c1;c2;c3`.
- `rawcolumns=c5;c6;c7` optional columns for the camera's uncorrected R, G, B, when students should see what the correction did.
- `sample=c1` an optional column for a sample name typed on the tool before recording.

```
\datatable[id=color-data, title="Colour readings", addrows]{
| Sample | R | G | B |
|---|---|---|---|
| blank | ___ | ___ | ___ |
}

\widget[type=colorimeter, id=color-reader, table=color-data, columns=c2;c3;c4, sample=c1]{Put a grey card beside the cuvette. Drag the Reference square onto the card and tap Set reference once, drag the Sample square onto the liquid, keep the lamp still, then tap Record for each tube.}
```

## Report tab (write-up skeleton)

A lab may end with a `\report{…}` block. When present, the lab page shows two tabs, **Procedure** and **Report**; when absent there is no Report tab. The Report tab guides the student through writing up the lab and, with "Preview report", turns their writing into a clean printable document (title, date, numbered tables and figures) that they save as a PDF and submit.

Inside `\report{…}` use ordinary Markdown plus:

| Command | What it does |
|---|---|
| `\answer[id=…, title=…, required, words=min-max, hint="…", lines=6]{Question or instructions}` | The same `\answer` as in the procedure, with options that suit a write-up: `title` adds a heading above the question; `required` marks it and shows a note while it is empty; `words=40-120` shows a gentle word-count target (`words=40` for a minimum only, `words=-120` for a maximum only); `hint` adds an expandable hint. All optional. (`\section` is accepted as an old alias.) |
| `\usetable{id}` | Shows a read-only copy of the `\datatable` with that id, filled with the student's own data, captioned "Table n". |
| `\usegraph{id}` | Shows the `\graph` with that id (give the graph an `id=` option), drawn from the student's data, captioned "Figure n". |
| `\useanswer{id}` | Shows a procedure `\answer` or `\notes` box (by its id): the prompt plus what the student wrote there. Read-only; the student edits it on the Procedure tab. |
| `\usephoto{id}` | Shows the photo the student added in the procedure `\photo` slot with that id, with its prompt. |
| `\answer`, `\datatable`, `\photo`, `\notes`, `\graph`, `\figure`, `\video` | Work inside the report exactly as in the procedure (a `\figure` in the report is the teacher's own picture, e.g. a table of literature values to compare against): use them when the report should *ask* for something new (a fresh data table to fill in, a question answered only in the write-up, a photo of the final result) instead of copying it from the procedure. |

The `\use…` commands only refer to blocks in the procedure, so every referenced block needs an explicit `id=`.

Rules for converting a PDF: if the PDF includes report instructions, a rubric, or "write-up" requirements, turn them into `\answer`s in the same order, using the PDF's own wording for prompts. Put every data table the report must include in `\usetable{…}` and every required plot in `\usegraph{…}`; if the write-up asks for a table the procedure never collected, put a `\datatable` in the report instead. Keep report questions short and specific; do not invent requirements the PDF does not state.

```
\report{
\answer[id=purpose, title="Purpose", required, words=30-80, hint="One or two sentences: what was measured and why."]{State the goal of this experiment in your own words.}

\answer[id=results, title="Results", required, words=80-200]{Summarize what the data show. Refer to Table 1 and Figure 1.}

\usetable{visc}

\usegraph{arrhenius}

\answer[id=calculations, title="Calculations", required, hint="Show one worked example for each type of calculation, with units."]

\answer[id=error, title="Sources of error", words=50-150]{Identify two specific sources of error and how each would change your result.}

\answer[id=conclusion, title="Conclusion", required, words=50-150]
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

\answer[id=ka-acetic, lines=3]{Show your calculation of $K_a$ for acetic acid.}

2. Explain why the pH at the equivalence point is above 7.

\answer[id=ka-oxalic, lines=4]

\notes[id=reflection]{Reflection}

<!-- Figures needed
IMAGE_1: titration curve graph from page 3 of the PDF (pH vs. volume of NaOH, half-equivalence point marked)
-->
```
