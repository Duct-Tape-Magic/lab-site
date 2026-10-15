# Widgets — plan

Agreed with the owner on 2026-10-15. Nothing here is built yet. Read this whole file before adding the Widget block or any widget; the rules in "Student-facing behaviour" are not optional.

## What a widget is

An interactive tool inside a lab that uses the device (camera, timer, sensors, a simulation) and **records values into ordinary lab fields**. Examples: a colorimeter that reads the camera, a stopwatch, later a physics sandbox. Widgets are added slowly, one per lab that needs one. The first and currently only one wanted is the **colorimeter** (spec below).

## Architecture decisions

1. **A widget is one more block type**, like Graph. Lab file tag `\widget[type=…, id=…, …]{Optional instruction}`; a Widget card in the Builder; a case in `ltRender`; mounting in `ltBind`. Same id rules as every other block (descriptive ids, `BM_PIN_KINDS`, `ltExplicitIds`/`bmExplicitIds` kept in sync).
2. **One catalog, read by everything.** A single `WIDGETS` registry in `index.html`: for each type its label, description, device needs, options (name, label, default, kind), `render(ctx)` (static HTML), `mount(el, ctx)` (starts it after a tap, returns `{stop}`), `print()` (what the PDF shows, usually nothing). The Builder card, the Widgets admin tab, `ltRender`, `ltBind`, the report and the PDF all read this one object, so the Builder and renderer cannot drift.
3. **Curated, never raw code.** Lab authors pick from the catalog. There is no block that accepts pasted HTML or script. Adding a widget means a code change in the repo.
4. **Heavy widgets live in their own file**, `widgets/<type>.js`, loaded only when a lab that uses the type is opened (a script tag inserted on demand, cache-busted by a version in the filename). Small widgets may sit in `index.html`. No CDN; vendor anything needed.
5. **Big simulations are embedded, not inlined**: their own page in an iframe, results sent to the parent with `postMessage`, the parent records them into fields. Not needed yet (would let the mechanics sandbox be reused).
6. **Widgets never own student data.** A widget shows live values and has a **Record** button that writes into existing blocks: a row appended to a `\datatable`, a value into an `\input`, a picture into a `\photo`. Nothing of the widget's own state is saved. Autosave, account sync, admin review, Stats, Clear entries, report and PDF therefore keep working unchanged.
7. **Manual fallback always.** The table or field a widget feeds is an ordinary table or field the student can type into. A lab must be finishable with the widget never starting.

## Admin interface

- **Widgets tab in the admin bar** (after Design): a showroom read from the catalog. One card per widget: name, description, device needs (e.g. "camera; phone recommended"), the options it accepts, what it records and into which kind of block, a live demo, and a per-site on/off switch (stored in `site_content` key `_widgets` as JSON, extend rather than add tables). Switched-off widgets stay out of the Builder picker; labs already using them keep working.
- **Builder: "Add widget" button** next to "Add block". Opens the catalog as a picker (enabled widgets only). Choosing one inserts a Widget card with that type's options laid out: label/instruction, the target block (dropdown of the lab's tables / inputs / photos as fits the widget), the type's own settings, and the help toggle (below). The card drags, duplicates, deletes and is included in the report like any block.

## Student-facing behaviour

- **Passive until tapped.** A widget never asks for camera or sensor permission on page load. It shows an instruction and a Start button. Students reading on a desktop never see a browser prompt.
- **No camera is not a failure.** On a device without a usable camera the widget shows a calm note ("This needs a camera. Open this lab on your phone and tap Start there."), no red state, no help prompt. Many students read on a laptop and use the widget on their phone; values recorded on the phone sync to the laptop through their account.
- **Three states:** `idle` (not started), `running`, `failed`. `failed` means the student tapped Start and it broke: permission denied, camera opened then died, script error. Only `failed` shows the failure box: a short plain message, the manual-entry target highlighted, and an optional **Get help** button.
- **Get help is never automatic.** The button is only a shortcut to the lab's existing help box, which opens empty; the student writes their own words. No thread is created, no draft message prefilled. The button appears only when the lab has Get help on and the student is signed in; otherwise the failure box shows just the manual fallback. Per-widget Builder option "Offer Get help when it fails", default on.
- **Stop cleanly.** Streams are released on Stop, on leaving the lab, and when the page is hidden (`visibilitychange`).
- **Report and PDF:** a widget prints nothing (or a small static snapshot such as a colour swatch); the data it recorded is in the table/field, which prints as usual. In admin read-only review the widget is not mounted.
- **Test mode** (nice to have, not required): a `demo` option or query flag that substitutes a synthetic source (e.g. a drawn gradient) for the camera so the preview and `entriesSelfTest()` can exercise Record without hardware. Real-device testing on a phone is still needed for camera widgets.

## Lab format addition (to add to LAB-FORMAT.md when built)

`\widget[type=colorimeter, id=colorReader, table=colorData, columns=c2;c3;c4, label=…]{Instruction shown above the widget}` — options are per type and documented in the catalog; `table`/`field`/`photo` name the target block by id. Stands on its own line.

## Widget 1: Colorimeter

Reads the average colour of a small square at the centre of the camera view and records R, G, B.

- **Camera:** `getUserMedia({ video: { facingMode: 'environment' } })`, falling back to any camera. `<video playsinline muted autoplay>` (iOS needs all three). HTTPS and a tap are required; the site already serves HTTPS.
- **Sampling:** draw frames to a canvas at ~10 fps; sample a centred square of about 4% of the shorter frame side (option `region`, default ~24 px); average each channel; smooth over the last ~10 frames so the numbers steady. Show a reticle over the video, the R G B numbers large, and a swatch of the colour. Optional display extras later (hex, HSV). A **Hold** button freezes the reading; **Record** writes it.
- **Record:** appends the values to the target `\datatable` (which should have `addrows`), placing R, G, B in the columns named by `columns`; an optional `sample` column takes a name typed in a small box on the widget. Uses the table's existing add-row and save path so the row syncs and prints like any typed row. If the target has no free row and no `addrows`, Record is disabled with a note.
- **Lighting:** phone cameras auto-expose, so absolute values drift with lighting. The lab, not the widget, handles this (a white or blank reference row, consistent lighting). The instruction text should say to hold the phone steady and keep the lighting the same across samples.
- **Failure rules** exactly as above. No camera on the device → calm note, not failure.
- **File:** `widgets/colorimeter.js`, loaded on demand.

## Build order (each step a separate, verified push)

1. Widget block end to end: tag + `WIDGETS` catalog + Builder card/picker + Widgets admin tab + three-state box + `print()`; prove it with a trivial placeholder or stopwatch widget. Run `entriesSelfTest()`; check that labs without widgets render byte-for-byte the same.
2. Record-to-table through the existing add-row/save path; verify a recorded row syncs to the cloud and appears in admin review and the PDF.
3. Colorimeter as a lazily loaded file, tested on a real phone (iOS Safari and Android Chrome) and on a laptop without a camera.
4. iframe bridge only when a simulation-sized widget is actually wanted.
