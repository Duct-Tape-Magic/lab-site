# Custom tabs — plan (2026-11-02) · built 2026-11-02 in the reduced form below

**What shipped:** `\tab[name=…]{…}` tabs between Procedure and Report, six tabs at most; Builder has "+ Add a tab", a name box and "Remove tab" (blocks move to the tab above). Not built, by the owner's choice: `kind=report` on custom tabs, "Move to tab" on cards, templates, a separate tab strip. Original plan follows.

Today a lab has at most two panes: the body of the file is the **Procedure** tab and `\report{…}` is the **Report** tab. Their names come from Site text (`procedureTab`, `reportTab`). This plan lets a lab have any number of named tabs, with nothing changing for existing labs or saved student work.

## What stays the same (the guarantees)

- **Student entries are keyed by block id, not by tab.** Moving a block to another tab never changes what a student saved. Automatic ids (`q1`, `table1`…) keep counting in document order across tabs, exactly as they do across Procedure → Report today.
- **Every existing lab file renders identically.** A file with no `\tab` and no `\report` is one pane with no tab bar. A file with `\report{…}` is Procedure + Report, named from Site text, as now. The Builder writes `\report{…}` back for that case, so saved files round-trip byte for byte.
- **Nothing is deleted when a tab is removed in Builder.** Removing a tab moves its blocks to the previous tab; the Builder never drops blocks.

## Lab file format

A new top-level command marks the start of a tab:

```
\title{Enzyme kinetics}
(Procedure content — everything before the first tab command)

\tab[name="Data analysis"]{
… blocks …
}

\report{
… the write-up, as today …
}
```

- `\tab[name=…, id=…, kind=report]{…}` — `name` is the label on the tab bar (required). `id` is optional; it keys the remembered-open-tab and defaults to a slug of the name. `kind=report` gives the tab the write-up treatment (document header, "Report" PDF title, print mode, style guide at the top).
- `\report{…}` is kept and means `\tab[name=<reportTab site text>, kind=report]{…}`.
- Content before the first tab command is the first tab, named `procedureTab` from Site text, unless the file starts with a `\tab` (then there is no implicit first tab).
- Tab order = document order. Limit six tabs (the bar must fit a phone).
- `\tab` is recognised only at the top level. A `\report` nested inside another block keeps its current legacy behaviour; a nested `\tab` is shown as raw text with an error, like a broken command.
- "Include" blocks (`\usetable`, `\usegraph`, `\useanswer`, `\usephoto`) work in **any** tab and may point at a block in any **other** tab. The old warning "Include block outside the report" becomes "this block includes something from the same tab".

## Renderer (`ltRender`, lab page)

- `ltRender` returns `tabs: [{ id, name, kind, html }]`. It keeps returning `html` (first tab) and `report` (the last `kind=report` tab, or '') so every existing caller (signature check, entry schema, snapshot, self-test) keeps working unchanged.
- `buildLabTagsHTML` renders the tab bar from `tabs` and one `.lab-pane` per tab with id `lab-pane-<tabId>`. With one tab, no bar (as now).
- `switchLabTab(id)` and `activeLabTab()` work on tab ids; the remembered tab per lab (`sessionStorage`) stores the id, and an unknown id falls back to the first tab.
- Mirrors (`rpPrepare`, `rpRefreshMirrors`, `rpBind`) stop assuming the source is in `#lab-pane-procedure`: the source is the original block anywhere in the lab area that is not itself a copy (`.rp-table`, `.rp-graph`, `.rp-copy`). The live-copy behaviour of tables stays exactly as it is now.
- Checkbox numbering (`check1…`) and math restoration continue across tabs in order, as they do for the report now.
- PDF: "Download PDF" and "Preview" are offered on every tab; a `kind=report` tab gets the document header and "— Report" title as now, other tabs print like the procedure does today. File name gains the tab name for non-first tabs.
- Print CSS (`body.report-print`) targets the active pane instead of `#lab-pane-report`.

## Builder model

- `model.tabs = [{ key, name, kind: 'plain' | 'report', blocks: [] }]` replaces `model.procedure` / `model.report`. Compatibility accessors keep `model.procedure` (= `tabs[0].blocks`) and `model.report` (= blocks of the last report tab) so the many `[...model.procedure, ...model.report]` loops become one `bmAllBlocks(model)` helper in a single pass, and nothing else needs to know.
- Parse: `bmParseFlow` splits the top level at `\tab` / `\report` boundaries in order. Serialize: writes each tab back in order; a report-kind tab whose name equals the Site-text default is written as `\report{…}`, anything else as `\tab[name=…]{…}`.
- `reportPresent` (an empty `\report{}` still shows a Report tab) generalises to "a tab exists even when it has no blocks".
- Validation: unknown tab names are fine; duplicate tab names get a warning; a tab with no blocks shows the existing "will be empty" note.

## Builder UI

- A **tab strip** at the top of the Builder: one button per tab (click to show that tab's block list), then **+ Add tab**. Each tab button has a small menu: Rename, Move left / right, "Write-up tab" toggle (the `kind=report` switch), Remove.
- **Remove** moves the tab's blocks to the previous tab and says so in a confirm. No block is ever deleted by removing a tab.
- Block cards gain **Move to tab ▸** in their existing card menu, next to Move up / down. Moving a block never changes its id; if it has only an automatic id, the existing "students have saved work under its automatic name" check runs before the move exactly as it does for reordering today.
- One palette for every tab (the current procedure + report palettes merged). "Include" buttons are enabled when a matching block exists in another tab.
- Templates ("Standard lab", "Data collection only", "Report only") keep their current output; a fourth, "Procedure · Data · Report", is optional.
- The live preview below the Builder shows the real tab bar, so the owner sees the tabs as students will.

## Elsewhere

- Site text: `procedureTab` / `reportTab` remain the defaults for unnamed tabs. No new keys needed; the tab names live in the lab file.
- Stats / Review: read-only rendering uses the same shell, so the reviewer sees the same tabs the student saw.
- Snapshot fallback (`data/snapshot.json`) carries lab files, not rendered HTML, so nothing changes there.
- Docs: `LAB-FORMAT.md` gets a "Tabs" section and the AI-prompt rules ("put the write-up in `\report`") stay valid.

## Order of work and checks

1. **Renderer + lab page shell + mirrors** (about half a day). Check: for every live lab file, the render signature and the pane HTML are identical before and after (scripted in the preview against all 16 `lab_content` rows). `entriesSelfTest()` gains a three-tab fixture with a `\usetable` in a middle tab.
2. **Builder model + parse/serialize** (about half a day). Check: every live lab file round-trips byte for byte through the Builder, as it does now.
3. **Builder UI + templates + docs + Site text review** (about a day).
4. Ship once, outside lab hours, after `node scripts/backup.mjs --verify`, because the entry binder's mirror code is touched.

## Decisions to confirm before building

1. Six tabs maximum.
2. "Include" blocks allowed in any tab (recommended), pointing at a block in a different tab.
3. PDF button on every tab, with the write-up header only on `kind=report` tabs.
4. Removing a tab in Builder moves its blocks to the previous tab rather than refusing.
