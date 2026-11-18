# Lab file format

This document tells you how to write a **lab file** for the OHS lab website. Give it to Claude together with a PDF of a lab and the instruction: *"Convert this lab to a lab file following LAB-FORMAT.md. Keep the original structure and wording."*

A lab file is plain text: **Markdown for the writing**, plus a small set of **LaTeX-style commands** (`\command[options]{content}`) that mark the places where the website should embed something interactive — a data table students fill in, a place to add a photo, a video, a question with an answer box, and so on. The website reads the file and renders a clean, interactive lab, organized into **tabs** (see "Tabs" below): by default a Procedure tab holding the body of the file and, when the file ends with `\report{…}`, a Report tab for the write-up; `\tab{…}` adds as many tabs of your own as you like. Students' entries save automatically in their own browser (and to their account when signed in) and print with the lab.

**You do not have to write this format by hand.** The site's lab editor opens in **Builder** mode by default: a block-based, form-driven editor (headings, text, numbered steps, data tables, questions, graphs, callouts, pictures, report sections…) that produces exactly this format. Builder and the **Lab file** view are two views of the same text and you can switch between them at any time; anything the Builder has no form for is kept as a "Raw" block and round-trips untouched. Importing a `.md` file written by hand or converted by Claude opens it as blocks. This document remains the reference for the stored format and for converting PDFs.

## Rules for converting a PDF

1. **Keep the lab's own structure.** Same sections, same order, same headings, same step numbering, same wording. Do not reorganize, summarize, shorten, or add content. Fix only obvious typos.
2. **Use commands only where they add something the paper could not do**: a table the student fills in, a spot for a photo of their work, a video, an answer box under a question, notes on steps, a safety callout. If a passage is just text, leave it as text.
3. **Every blank the student would fill in on paper becomes a field.** Blank table cells become `___`. Blank lines under a question become `\answer`. A single value to record (a mass, a temperature) becomes `\input`.
4. **Math and chemistry become LaTeX**: `$c = \frac{n}{V}$`, `$$K_a = \frac{[H^+][A^-]}{[HA]}$$`, `\ce{CH3COOH + NaOH -> CH3COONa + H2O}`. Units like $\pu{0.100 M}$ are fine.
5. **Figures in the PDF cannot be copied by you.** Put `\figure[caption=...]{IMAGE_1}`, `{IMAGE_2}`, … where they belong and, at the very end of the file, list them under a `<!-- Figures needed -->` comment with a one-line description of each so the teacher can upload them.
6. **Start with the header commands** (`\title`, `\summary`, `\tags`, `\minutes`). Write the summary yourself (one or two sentences) if the PDF has none.
7. Give every field an `id` when there is any chance the lab will be edited later (ids keep students' saved entries attached to the right field). Use short lowercase ids: `trial1`, `q3`, `setup-photo`.
8. **Tabs**: put everything in the body of the file (the Procedure tab) unless the teacher asks for tabs or the PDF is plainly split into separate parts that students work through one at a time (a problem set with numbered problems, a multi-day lab with one part per day). Then give each part its own `\tab[name=…]{…}`, named exactly as the PDF names the part (`1`, `2`, `3` or `Day 1`, `Day 2`), and leave the body empty if the PDF has no introduction. See "Tabs".
9. Output only the lab file, nothing else.

## Markdown you can use

Headings (`#`, `##`, `###`), paragraphs, **bold**, *italic*, numbered lists (`1.`), bullet lists (`-`), checklists (`- [ ] item` — students can tick them), links, blockquotes (`>`), horizontal rules (`---`), and tables (`| a | b |`) for information that is *not* filled in by the student. Inline code with backticks. Images with `![caption](path)` if the teacher gives you a path.

## Commands

| Command | What it does |
|---|---|
| `\title{…}` `\summary{…}` `\tags{a, b}` `\minutes{90}` | Header. Not shown in the lab; the website uses them to fill in the lab's title, card summary, tags, and estimated time. |
| `\datatable[id=…, title=…, addrows]{ table }` | A table students fill in. Write a normal Markdown table inside; every cell containing `___` becomes an editable cell, other cells are fixed text. `addrows` lets students add rows. `view=hidden` never shows the table where it stands (graphs still read it; use it for a table a tool fills, such as a continuous colorimeter run); `view=collapsed` keeps it behind a "Show the numbers" line the student can open. Without `view=` the table is shown as usual. A `\usetable` in the report shows the table whatever its `view`. |
| `\input[id=…, label=…, unit=…]` | A small inline box for one value, e.g. `Mass of sample: \input[id=mass, unit=g]`. |
| `\answer[id=…, lines=4]{Optional prompt}` | A multi-line answer box, `lines` tall. Usually placed right after a question. |
| `\choice[id=…, multi, required, title=…]{ question, then one `- choice` per line }` | A multiple-choice question. Write the question first, then each choice on its own line starting with `- `. Students tick one; `multi` lets them tick several. `required` and `title` work as on `\answer`. The saved value is the text of the chosen choice(s). |
| `\notes[id=…]{Optional label}` | A collapsible "My notes" box. |
| `\procedure{ numbered list }` | Wraps a numbered list of steps; every step gets its own collapsible notes box automatically. |
| `\photo[id=…, max=…]{Instruction}` | A place for the student to add a photo from their phone or computer, e.g. `\photo[id=setup]{Photograph your titration setup before starting.}`. `max=3` lets them add up to three photos (default one, up to six); the first keeps the slot's name, extras are stored as `setup.2`, `setup.3`. |
| `\video{YouTube link}` | Embeds the video (any YouTube link, including unlisted). |
| `\figure[caption=…, size=small\|medium\|full]{path or IMAGE_n}` | A figure. `size` sets how wide it is shown: `full` (default, the text column), `medium` (about 60%) or `small` (about a third); use `small` for icons and simple diagrams, `full` for anything students must read values from. Consecutive `small` figures sit side by side three to a row, consecutive `medium` ones two to a row, so put related pictures (e.g. steps of a setup) on adjacent lines. Use `IMAGE_1`, `IMAGE_2`… for pictures from the PDF that the teacher must upload; the teacher replaces them with the site's "Insert image…" button, which uploads a PNG or JPG and writes the `\figure` line. Markdown images `![caption](path)` also work. |
| `\safety{…}` `\warning{…}` `\info{…}` `\tip{…}` `\hint{…}` | Highlighted callout boxes. Markdown works inside. `[label=…]` overrides the box label. |
| `\graph[table=…, x=…, y=…, type=…, fit=linear, title=…, xlabel=…, ylabel=…]{Optional caption}` | A live graph drawn from a `\datatable`. It redraws as the student types. See "Graphs" below. |
| `\widget[type=colorimeter, id=…, table=…, columns=c2;c3;c4]{Description}` | An in-lab tool that uses the student's device and records what it reads into a `\datatable`. See "Widgets" below. |
| `\pagebreak` | Starts a new page when printed. |
| `\tab[name=…, id=…]{ … }` | A tab of your own. See "Tabs". |
| `\report{ … }` | The write-up tab, always shown last. See "Report tab". |

Notes on syntax:
- Options go in square brackets, comma-separated: `[id=ka-calc, lines=3]`. Ids should be descriptive words (`ka-acetic`, `mass-data`), never the automatic pattern of a letter plus a number such as `q1` or `table2`, which the site uses for blocks without an id. Values with commas or spaces can be quoted: `[title="Trial 1, run A"]`.
- Content goes in curly braces and may span many lines. Braces must balance (LaTeX inside is fine).
- Links: ordinary Markdown `[words to show](https://address)`; students see only the words and it opens in a new tab. Never paste a bare long address into the text.
- Commands that stand alone (`\datatable`, `\answer`, `\choice`, `\photo`, `\video`, `\figure`, callouts, `\procedure`) go on their own line. `\input` sits inside a sentence.
- Anything inside `$…$`, `$$…$$`, `\ce{…}` or backticks is left alone, so LaTeX like `\frac{}` never conflicts with commands.

## Tabs

The lab page shows one tab per part of the file:

- **The body of the file** (everything that is not inside a `\tab` or `\report`) is the first tab. The site names it from its Site text, "Procedure" by default. If the body is empty, there is no Procedure tab and the lab opens on the first tab you wrote.
- **`\tab[name="Data analysis"]{ … }`** adds a tab with that name, holding anything the body may hold: text, steps, tables, questions, photos, graphs, widgets. Tabs appear in file order. There is no limit on how many; short names (`1`, `2`, `3`) let a whole problem set fit on a phone. `id=` is optional and only fixes the name the site uses to remember which tab a student had open (the default is the tab name in lowercase). `\tab` is recognized only at the top level of the file, never inside another command.
- **`\report{ … }`** is the write-up tab and is always last, whatever its position in the file. It is optional.
- With a single tab in all (only a body, or only one `\tab`, or only a `\report`), the page shows no tab bar.

Students' entries are keyed by block id, never by tab, so moving a block between tabs keeps every saved answer. A report `\usetable`, `\usegraph`, `\useanswer` or `\usephoto` may point at a block on any tab.

In **Builder**, the Procedure and Report tabs are there by default and each has a "Remove tab" button; "+ Add a tab" adds one with a name box. Removing a tab never deletes anything: its blocks move to the neighbouring tab, and a removed Procedure or Report tab can be added back with one click.

```
\title{Equilibrium problem set}

\tab[name=1]{
A 2.0 L flask holds 0.40 mol of $\ce{N2O4}$ at equilibrium with $\ce{NO2}$ …
\answer[id=p1, lines=4]{Show your work.}
}

\tab[name=2]{
…
\choice[id=p2]{Which way does the equilibrium shift when the flask is warmed?
- Toward $\ce{NO2}$
- Toward $\ce{N2O4}$
- It does not shift
}
}
```

## Graphs

Whenever the lab asks students to plot their data, add a `\graph` right after the table (or after the analysis question that refers to it). Options:

- `table=` the `id` of the `\datatable` to read (required).
- `x=` and `y=` which columns to plot, as `c1`, `c2`, … (1-based). Simple formulas are allowed: `x="1/(c1+273.15)"`, `y="ln(c2)"`, `y="c3-c2"`. Functions: `ln`, `log` (base 10), `exp`, `sqrt`, `abs`; operators `+ - * / ^`. Quote any value containing commas or spaces.
- Several y series: `y="c2;c3"`, with optional names `series="Trial 1;Trial 2"`. Each entry of the list may be a formula: `y="ln(c2);ln(c3)"`, `y="1/c2;1/c3"`.
- `type=` how the series is drawn: `scatter` (default, dots), `both` (dots joined by a line), `line` (a line with small dots), `solid`, `dashed` or `dotted` (a bare line), or `dashed+points` / `dotted+points` / `solid+points`. With several y series, a list sets each one: `type="scatter;dashed"`.
- `color=` a fixed colour: `accent` (the site's blue), `red`, `green`, `orange`, `purple`, `gray`, `black`, or `#rrggbb`. Without it colours are assigned in order. A list works as for `type`.
- `rows=` plot only some rows of the table: `rows=2`, `rows=1-3`, `rows="1,4"` (1-based, in table order).
- `fit=linear` adds a least-squares line and prints its equation and R². Other kinds, several at once, and limiting which points a fit uses: see "Best-fit curves" below. With several y series every series gets its own fit and its own equation, labelled with the series name.
- `title=`, `xlabel=`, `ylabel=` for labels; `xmin/xmax/ymin/ymax` to fix axis ranges (otherwise automatic).
- Caption in the braces.

Rows with a blank or non-numeric x or y are skipped, so the graph simply grows as the student fills the table. "Non-numeric" includes every result that is not a real number: `ln` or `log` of zero or a negative number, the square root of a negative number, division by zero, and anything computed from one of those (`0*sqrt(-1)` is skipped too, not 0).

A graph may stand anywhere and read any table: a `\graph` inside `\report{}` (or on any tab) can take its `table=`, its layers' `table=` and its cell references from tables on the Procedure tab or any other tab, hidden ones included.

### Best-fit curves (2026-11-18)

`fit=` draws a best-fit curve through a series and prints its equation and R² under the graph. Three kinds:

| `fit=` | Curve | Equation printed | Rate-law reading (y = concentration, x = time) |
|---|---|---|---|
| `linear` | a straight line | `y = mx + b` | zero order, k = −m |
| `exponential` | an exponential rise or decay | `y = a·e^(bx)` | first order, k = −b |
| `reciprocal` | a curve for which 1/y is a straight line in x | `1/y = mx + c` | second order, k = m |

- **Several fits on one series**: join the kinds with `+`: `fit=linear+exponential+reciprocal`. Each curve is drawn across the whole graph in its own colour and dash, and each gets its own line under the graph: a sample of its line, its name (Straight line, Exponential, Reciprocal; the three names are in Site text) and its equation with R². This is the one-graph comparison of models: the data with all three curves over it.
- **How they are fitted.** Every kind is the least-squares fit **to the plotted y values themselves**, and R² is 1 − (squared distance of the points from the curve) ÷ (squared distance of the points from their mean) on those same y values. So the three R² values on one graph can be compared directly, and the drawn curve is the closest curve of that shape to the points. This is not the same as fitting a straight line to ln y or 1/y on a separate graph: that fit weights the small values at the end of a run much more heavily, so its slope differs slightly from `b` or `m` here.
- An exponential or reciprocal needs y values on one side of zero; a few points on the other side (noise around zero) are tolerated. With fewer than two usable points no curve is drawn.
- **On layers and several series**: `fit=` works the same on a `\layer` (also on a graph with `table=none`); each layer is fitted on its own and its equations carry the layer's name. With `y="c2;c3"` every series gets the same fits; a `;` list gives each series its own: `fit="linear;exponential"`.

**Limiting which points a fit uses.** Every point is still drawn; only the fit ignores the points outside the limits.

- `fitmin=0.1` use only points whose plotted y is at least 0.1. `fitmax=` at most.
- `fitvalue=c2` makes `fitmin`/`fitmax` test that column or formula instead of the plotted y. Example: on a graph of `y="ln(c2)"`, `fitvalue=c2, fitmin=0.1` fits only the rows where the concentration itself is 0.1 or more.
- `fitxmin=5`, `fitxmax=60` use only points whose plotted x lies in that range (here: ignore the first 5 seconds and everything after one minute).
- They combine (a point must pass all that are set) and apply to every fit of the series. On a `\layer`, a limit that is not written takes the graph's own value, so limits written once on a `table=none` graph apply to all its layers.

```
\graph[id=models, table=fade-1, x=c1, y=c2, type=solid, fit=linear+exponential+reciprocal, fitmin=0.1, fitxmin=5,
  xlabel="Time (s)", ylabel="Relative concentration"]{Which curve follows your data?}
```

### Reading a point off a graph (2026-11-18)

Every graph does this by itself; nothing is written in the lab file. A tap or click inside the plot marks the nearest plotted point (of any series) with a ring and guide lines to both axes, and a line under the graph gives its coordinates, using the axis labels: `Time (s): 42 · Relative concentration: 0.513` (with the series name first when the graph draws several). Dragging sideways along the plot moves the mark from point to point; with a mouse, hovering does the same. A tap in the margin of the graph clears it. It reads plotted data points only, never the fitted curves, and nothing about it is saved, printed or put in the PDF. Tell students to use it where the lab asks for a value from a curve ("tap the curve to find the time at which the concentration reaches 0.5").

### Layers: several data sources in one graph (2026-11-14)

A graph can draw more than its own table. Put one `\layer` line per extra data source inside the graph's braces, before the caption. Every layer is drawn in the same axes; lines are always drawn underneath points, so student points sit on top of reference curves.

- **Values typed in** (literature or accepted values): `\layer[name="NaCl, accepted", type=dashed, color=red]{ … }` with one point per line in the braces, `x, y` (a comma, a tab or spaces between the two numbers; `;` may separate points on one line). Digits, signs, decimal points and `e` only.
- **Another table**: `\layer[name="Trial 2", table=other, x=c1, y=c2]`. Options: `table=` (default: the graph's own table), `x=`, `y=` (same expressions as the graph; `x` defaults to the graph's `x`, `y` to `c2`), `rows=`, `type=`, `color=`, `fit=` with its limits `fitmin=`, `fitmax=`, `fitvalue=`, `fitxmin=`, `fitxmax=` (see "Best-fit curves"), `name=` (the legend entry).
- `table=none` on the graph itself means it has no table of its own and draws only its layers.
- The legend lists every series when there is more than one and wraps onto extra lines as needed.

```
\datatable[id=results, title="Your results"]{
| Solute | Molality (mol/kg) | van't Hoff factor |
|---|---|---|
| Table salt | ___ | ___ |
| Epsom salt | ___ | ___ |
}

\graph[id=vh, table=none, title="van't Hoff factor against molality", xlabel="Molality (mol/kg)", ylabel="van't Hoff factor"]{
\layer[name="NaCl, accepted", type=dashed, color=red]{
0.1, 1.87
0.5, 1.82
1.0, 1.81
}
\layer[name="MgSO4, accepted", type=dashed, color=green]{
0.1, 1.32
0.5, 1.14
1.0, 1.09
}
\layer[name="Your table salt", table=results, x=c2, y=c3, rows=1, color=red]
\layer[name="Your Epsom salt", table=results, x=c2, y=c3, rows=2, color=green]
Accepted curves (dashed) with your own values as points.
}
```

### Cell references: a formula may read any table on the page (2026-11-14)

An `x=` or `y=` formula, on a graph or on a layer, is worked out once per row of its own table (`c1`, `c2`, … are that row's cells). It may also read a cell of any other table in the lab, so a plotted quantity can combine tables without the student copying numbers:

| Written | Reads |
|---|---|
| `freezing(@).c2` | column 2 of the row of table `freezing` whose **first-column label is the same as this row's** (Sucrose row to Sucrose row; row order does not matter) |
| `freezing(Water).c2` | column 2 of the row of `freezing` labelled Water (a fixed cell, e.g. a shared blank) |
| `freezing(1).c2` | column 2 of row 1 of `freezing` (by number) |

- **Round brackets, never square ones.** A `]` ends the option list, so `freezing["Water"].c2` cannot be written.
- A label may be written bare, `freezing(Table salt).c2`. Quote it only if it contains brackets or is a number, and then use single quotes inside a double-quoted option: `y="freezing('Run (2)').c2"`. Labels match ignoring case and extra spaces.
- The table name is the table's `id`. A blank, non-numeric or missing cell makes that row skip, exactly as for a blank `c2`.
- Per-row constants (a molar mass, a hydrate factor) go in as plain numbers: give each row its own `\layer` with `rows=`.
- Options may run over several lines inside the square brackets.

```
\layer[name="Your table salt", table=solutions, rows=2, color=accent,
  x="1000*c3/(58.44*c2)",
  y="(freezing(Water).c2+freezing(Water).c3-freezing(@).c2-freezing(@).c3)/2*58.44*c2/(1860*c3)"]
```

Here the layer's own table is `solutions` (masses in `c2`, `c3`); the two freezing points come from the row of `freezing` with the same label, and the water blank from its Water row.

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

- `type=` which tool (required). Available: `colorimeter` (single readings), `colorimeter-run` (a continuous run drawn as a graph; it takes `runs=` instead of `table=`, see "Colorimeter, continuous runs" below), `socratic` (an oral tutor over a problem bank the teacher writes on the Widgets tab; `bank=` names the bank, no table; students must be signed in; the student presses Start session and the bank's own overview and level question open it; see docs/SOCRATIC.md).
- `fullpage` (socratic only, beta): the tutor is the whole page, laid out like a chat, for a Socratic-only review with no lab around it. Builder: the "Full page interface" checkbox on the widget block.
- `id=` a permanent name, like any block.
- `table=` the `id` of the `\datatable` it records into (required). Give the table `addrows` so every reading gets a row; otherwise only the table's blank rows can take readings.
- `label=` an optional title shown in the tool's header.
- `help=off` hides the Get help button from the tool's failure note (it is offered by default, only when the lab has Get help on and the student is signed in).
- The instruction in the braces replaces the standard one. Say where to point the camera and remind students to keep the lighting the same for every sample.

### Colorimeter

Shows the camera picture with two small squares the student drags into place: a **Reference** square on a sheet of plain white printer paper and a **Sample** square on what is being measured. The paper is taken as white, so the tool records the sample's **R, G, B** (0–255) *relative to it*, channel by channel and every frame: corrected = sample × 255 ÷ (what the camera reads on the paper). Phone cameras keep adjusting exposure and white balance, but both squares are in the same picture, so the drift moves both readings together and cancels; there is nothing to set and the tool keeps no memory. Keep the paper and the sample in the same light, with the paper the brightest matte thing in the picture (a sample brighter than the paper reads 255). The data table holds the data; record the uncorrected values too (`rawcolumns`) if anyone may need to recompute. The interface is bare on purpose: the picture with the two squares, the R G B readout and Record (a line of green text under the button says "Data recorded" for a moment), and nothing else. Students type sample names or concentrations into the table's other columns themselves. The text in the braces is the per-lab description, shown under the Colorimeter title (the Builder card's Description field); use it to say where the paper goes, to keep both squares in the same light, and to avoid readings near 0 or 255. Camera values are gamma-encoded, so ratios are only roughly proportional to light intensity; for comparing tubes and plotting trends that is fine.

- `columns=c2;c3;c4` the table columns (1-based, `c1`, `c2`, …) that take the corrected R, G and B, in that order. Default `c1;c2;c3`.
- `rawcolumns=c5;c6;c7` optional columns for the camera's uncorrected R, G, B, when students should see what the correction did.
- `interval=10` optional **auto record** (2026-11-16): the number of seconds between readings (1 to 3600). The tool then shows a second button, "Start auto record", beside Record. One reading is recorded when the student taps it and then one every `interval` seconds, each on its own table row, until the student taps "Stop auto record", stops the tool, leaves the page, or the table has no room. Give the table `addrows`. Without `interval` there is no auto record button.
- `readings=30` optional: an auto-record run stops by itself after this many readings. Default 200.
- `timecolumn=c1` optional: the table column that takes the time of each auto-recorded reading, in seconds since the student tapped "Start auto record" (0, then 10, 20, … for `interval=10`). A reading taken with the plain Record button leaves this column empty.
- The tool shows one warning by itself: "The reference is too bright. Dim the light or move the paper." when the camera overexposes the paper under the Reference square. Readings taken while it shows are not reliable.

```
\datatable[id=color-data, title="Colour readings", addrows]{
| Sample | R | G | B |
|---|---|---|---|
| blank | ___ | ___ | ___ |
}

\widget[type=colorimeter, id=color-reader, table=color-data, columns=c2;c3;c4]{Put a sheet of white paper beside the cuvette. Drag the Reference square onto the paper and the Sample square onto the liquid, keep the lamp still, then tap Record for each tube.}
```

A timed run (kinetics), one reading every 10 seconds for 5 minutes:

```
\datatable[id=fade-data, title="Colour against time", addrows]{
| Time (s) | R | G | B |
|---|---|---|---|
| ___ | ___ | ___ | ___ |
}

\widget[type=colorimeter, id=fade-reader, table=fade-data, columns=c2;c3;c4, timecolumn=c1, interval=10, readings=31]{Set the squares, mix the solutions, then tap Start auto record straight away. Keep the phone and the lamp still until it stops.}
```

### Colorimeter, continuous runs (`type=colorimeter-run`, 2026-11-17)

For a reaction whose colour changes over a minute or a few minutes (kinetics): a colour that fades, or a clear solution that gains colour. The same camera picture and the same two squares as the colorimeter, but the output is a **curve, not numbers**: the student picks a run, taps **Start recording**, and until they tap **Stop recording** the tool writes one reading every interval into that run's table. Graphs that read the table redraw as each reading arrives, so the student watches the line form. The tool itself shows no numbers.

Each reading is the **relative concentration** of whatever colours the sample, per colour channel:

1. the Sample and Reference values are converted from camera RGB to linear light;
2. A = log(reference ÷ sample), averaged over every camera frame in the interval;
3. the value follows from how A changes during the run, and the tool works out which case it is by itself (per channel, from the run; there is nothing to set):
   - **the colour fades**: value = A ÷ A₀, where A₀ is A at the start of the run. The run starts at 1 and falls.
   - **colour forms** (the run starts clear or pale and darkens): value = (A − A₀) ÷ the largest (A − A₀) of the run. The run starts at 0 and its highest point is 1, so the value is the fraction of the final colour reached. Because the starting reading is subtracted, whatever the clear sample read at the start does not matter.

   While colour is still forming the highest point keeps moving, so the numbers on the y axis rescale as the run goes; the shape of the curve does not change. A run in which nothing changes records a flat line near 0 (or near 1 if it started coloured).

   **A₀ does not rest on one reading** (2026-11-18). It is read from every camera frame of the first four seconds: a line is fitted through them by medians and its value at time 0 is A₀. A stirring rod leaving the picture or liquid still settling in the first second therefore does not rescale the whole run, and the reaction's own progress during those seconds is not mistaken for the start. The first few points adjust slightly while those four seconds pass. The points recorded during a disturbance are still recorded as they were read; use `fitxmin=` to keep them out of a fit.

Options (there is no `table=`):

- `runs=run1;run2;run3` (required) the `id`s of the `\datatable`s it records into, **one table per run**. The student chooses the run from a list before starting; a table's `title=` is the run's name in that list (without a title: "Run 1", "Run 2", … in the order listed). With one run there is no list. Write each run table as a header row only, give it `addrows`, and usually `view=hidden` (students see only graphs) or `view=collapsed`.
- `timecolumn=c1` the column that takes the time in seconds since Start recording (0, then the interval, …). Default `c1`.
- `columns=c2;c3;c4` the columns that take the relative concentration by the **red, green and blue** channel, in that order. Default `c2;c3;c4`. Leave an entry empty to skip that channel (quote the value when it starts or ends with `;`): `columns="c2;c3;"` records red and green and skips blue, `columns=";c2;"` records only green, `columns=";;c2"` records only blue; a two-column table with the default records time and red only. Use the channel the sample absorbs: red for a blue or green sample, green for a red or purple one, blue for a yellow one. **Record only the channels the lab uses**: the too-dark warning below looks at every recorded channel.
- `interval=1` seconds between readings, 1 to 3600. Default 1.
- `minutes=10` a forgotten run stops by itself after this many minutes (at most 60; never more than 1200 readings). Default 10. Normally the student ends the run.
- `change=fades` or `change=forms` (optional, 2026-11-18) says what the colour does. Write it whenever the lab knows: the run is then always scaled that way and never has to be worked out from the data. `change=fades` also makes Start recording wait while the sample has too little colour (see the warnings below). Without `change=` the tool works out the direction itself and a run may start clear.
- `mixtable=mix` (optional, 2026-11-18) adds a **Mixed now** button and names the `\datatable` that takes each run's **time from mixing to the start of recording**, in seconds. The student taps Mixed now at the moment of mixing (the tool then counts "Mixed 0:07 ago"; a second tap marks it again) and Start recording when the sample is in place; the seconds in between, to one decimal, go into **row n of that table for the n-th run listed in `runs=`**, in the column `mixcolumn=` (default `c2`). Give the table one row per run with a `___` cell in that column. It is an ordinary table: students see the number, a `\usetable` shows it in the report, and a graph formula reads it as `mix(1).c2` for the first run, `mix(2).c2` for the second. A student who did not tap Mixed now leaves the cell as it was and may type their own count into it. Deleting a run from its graph, or recording over it, empties that run's cell too.

What the lab must know:

- **The y axis of a graph fits the curve by itself** unless the graph fixes `ymin`/`ymax`. Draw runs with `type=solid` (a run has too many points for dots).
- **Every graph of a recorded run carries a red Delete button** (top right of the graph) once the run is over: "Delete", or "Delete Trial 1" / "Delete Trial 2" when the graph draws several runs. It asks "Delete the recording in Trial 1? It cannot be brought back." and then empties that run, in every graph that draws it. There is no button while the run is recording, on an empty graph, in the report's copy of a graph, or in a PDF. Nothing needs to be written in the lab file for it.
- **A run that already holds a recording is never overwritten silently.** Choosing it and tapping Start recording asks "… already has a recording. Record over it?" first. After a run the list moves to the next empty run. A lab that wants three trials lists three runs.
- **Relative means relative to the moment Start recording was tapped**, not to the moment of mixing. For a fading colour, a first-order slope (ln of the value against time) is unaffected; zero- and second-order slopes come out divided or multiplied by the concentration at that moment. With `mixtable=` the lab has the delay and can plot against time since mixing, `x="c1+mix(1).c2"`, so a fitted line or curve can be read back to x = 0, the moment of mixing. (A formula that reads an empty delay cell skips every point, so keep one graph against plain `c1` as well, or tell students to type 0 if they did not mark the mixing.)
- **For a colour that forms, 1 is the highest point of the run, not the end of the reaction.** If the student stops early, 1 is simply where they stopped. Have them record until the colour stops changing when the lab needs the fraction of the final amount (for example `y="ln(1-c2)"` against time for a first-order product; the last point, exactly 1, is skipped by the graph).
- **For a colour that fades, the reference must be "the sample with no colour".** A = 0 has to mean "no dye", so put the Reference square on an identical container of plain water (or the colourless solvent) standing beside the sample, in the same light, not on bare paper. With bare paper the container and the water add a constant to A, the value never reaches 0, and an ln plot of a true first-order reaction bends. A colour that forms does not need this (the clear start is subtracted), though the same setup does no harm.
- **Warnings that hold Start recording back** (2026-11-18). Start recording is disabled while the tool shows any of these, and works again as soon as the warning clears; a run that is already recording is never stopped by one.
  - "The reference is too bright. …" the camera overexposes the Reference square.
  - "The sample is too dark to measure. …" in **any channel the chosen run records**, the sample absorbs more than about 1.5 (it lets through under about 3% of the reference's light), or it is all but black. A phone camera cannot tell such a sample from black, and the run comes out as a jagged trace. The cure is a more dilute solution or a thinner container; choose concentrations that start well under this.
  - "The sample has too little colour to measure. …" **only with `change=fades`**, and only when **every** recorded channel absorbs less than about 0.08. (Without `change=fades` there is no such warning, because a colour that forms has to start clear.)
  - All three texts are in Site text. They also appear while the squares are not yet in place, which is the usual reason for them.
- A channel that shows no colour during the run stays near 0, so plot the column of the channel the coloured substance absorbs.
- The phone has to stay put for the whole run: tell students to stand it up before they mix. A run ends, keeping what it recorded, when the student taps Stop recording, stops the tool, or leaves the page; it cannot be resumed, only recorded again.
- A hidden run table cannot be typed into, so this tool has no type-it-in fallback: a student without a camera cannot do this part.

```
\datatable[id=fade-1, title="Trial 1", view=hidden, addrows]{
| Time (s) | Relative concentration |
|---|---|
}

\datatable[id=fade-2, title="Trial 2", view=hidden, addrows]{
| Time (s) | Relative concentration |
|---|---|
}

\datatable[id=mix, title="Time from mixing to recording"]{
| Trial | Delay (s) |
|---|---|
| Trial 1 | ___ |
| Trial 2 | ___ |
}

\widget[type=colorimeter-run, id=fade-recorder, runs=fade-1;fade-2, change=fades, mixtable=mix]{Stand the phone up. Drag Reference onto the tube of plain water and Sample onto the dye. Tap Mixed now as you pour the solutions together, then tap Start recording as soon as the tube is back in place. Tap Stop recording when the colour is gone.}

\graph[id=fade-curve, table=fade-1, x=c1, y=c2, type=solid, series="Trial 1", xlabel="Time (s)", ylabel="Relative concentration"]{
\layer[name="Trial 2", table=fade-2, x=c1, y=c2, type=solid]
How the dye concentration falls.
}

\graph[id=fade-ln, table=fade-1, x=c1, y="ln(c2)", type=solid, fit=linear, series="Trial 1", xlabel="Time (s)", ylabel="ln(relative concentration)"]{
\layer[name="Trial 2", table=fade-2, x=c1, y="ln(c2)", type=solid, fit=linear]
First-order test: a straight line, slope −k.
}
```

The same run can feed any number of graphs: `y=c2` (zero-order test), `y="ln(c2)"` (first order), `y="1/c2"` (second order). Or one graph with all three models drawn over the data, fitted only where the reading is reliable (see "Best-fit curves"):

```
\graph[id=fade-models, table=fade-1, x="c1+mix(1).c2", y=c2, type=solid, fit=linear+exponential+reciprocal, fitmin=0.1,
  xlabel="Time since mixing (s)", ylabel="Relative concentration"]{Trial 1 with a zero-, first- and second-order curve.}
```

## Report tab (write-up skeleton)

A lab may include a `\report{…}` block. When present, the lab page's last tab is **Report**; when absent there is no Report tab. The Report tab guides the student through writing up the lab and, with "Preview report", turns their writing into a clean printable document (title, date, numbered tables and figures) that they save as a PDF and submit.

Inside `\report{…}` use ordinary Markdown plus:

| Command | What it does |
|---|---|
| `\answer[id=…, title=…, required, words=min-max, hint="…", lines=6]{Question or instructions}` | The same `\answer` as in the procedure, with options that suit a write-up: `title` adds a heading above the question; `required` marks it and shows a note while it is empty; `words=40-120` shows a gentle word-count target (`words=40` for a minimum only, `words=-120` for a maximum only); `hint` adds an expandable hint. All optional. (`\section` is accepted as an old alias.) |
| `\usetable{id}` | Shows the `\datatable` with that id in the report as well, captioned "Table n". It is the same table: students can type into it from either tab, and rows added in one place appear in the other. |
| `\usegraph{id}` | Shows the `\graph` with that id (give the graph an `id=` option), drawn from the student's data, captioned "Figure n". |
| `\useanswer{id}` | Shows an `\answer`, `\choice` or `\notes` box from another tab (by its id): the prompt plus what the student wrote or ticked there. Read-only; the student edits it on its own tab. |
| `\usephoto{id}` | Shows the photo the student added in the `\photo` slot with that id on another tab, with its prompt. |
| `\usesocratic[transcript]{id}` | Reports on a Socratic tutor widget (by its id). Without the option: one line once the student has ended a session, "Socratic topics credited: N of M · K problems worked". With `transcript`: the whole conversation and the tutor's closing summary as well. Optional either way. |
| `\answer`, `\datatable`, `\photo`, `\notes`, `\graph`, `\figure`, `\video` | Work inside the report exactly as in the procedure (a `\figure` in the report is the teacher's own picture, e.g. a table of literature values to compare against): use them when the report should *ask* for something new (a fresh data table to fill in, a question answered only in the write-up, a photo of the final result) instead of copying it from the procedure. |

The `\use…` commands refer to blocks on the other tabs (the body or any `\tab`), so every referenced block needs an explicit `id=`.

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
