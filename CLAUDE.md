# CLAUDE.md — Lab Site

## What this is

A website where students open lab procedures (rich text, photos, YouTube video, math, downloadable files) organized in a folder tree. The owner (a teacher, not a professional developer) manages everything from a hidden admin mode on the live site. Built as a static site on GitHub Pages with Supabase (Pro plan) for data, auth, and file storage. The full design rationale, capacity math, cost, and phase plan live in `docs/PLAN.md` — read it before any significant change.

**Hard requirements:** under $50/month; must stay up for 100 concurrent students; never paused for inactivity (the owner's earlier free-tier Supabase project was paused and they consider downtime an emergency); public content must survive a database outage.

## Files

| Path | Purpose |
|---|---|
| `index.html` | The whole app: CSS, markup, JS. No build step. `CONFIG` at the top of the script holds the Supabase URL and publishable key. |
| `vendor/` | Pinned copies of supabase-js, Quill 2, KaTeX (+ mhchem, auto-render, woff2 fonts), qrcode-generator. No CDN at runtime except Google Fonts (non-blocking, falls back to system fonts). See `vendor/VERSIONS.txt`. |
| `supabase/schema.sql` | Tables, helper functions, row-level security, storage buckets and policies, admin-guarded stats functions. Idempotent; run in the SQL editor. |
| `supabase/functions/` | Edge Functions (Phase 3: `gate`, `admin-users`, `move-files`). Not written yet. |
| `scripts/snapshot.mjs` + `.github/workflows/snapshot.yml` | Hourly GitHub Action copies all public content to `data/snapshot.json` (the outage fallback) and keeps a weekly heartbeat commit. Needs repo secrets `SUPABASE_URL`, `SUPABASE_ANON_KEY`. |
| `data/snapshot.json` | Fallback content, maintained by the Action. `data/snapshot.sample.json` is demo content for local previews (copy it over `snapshot.json` temporarily, never commit that). |
| `docs/PLAN.md` | The implementation plan (architecture, schema, features, phases, decisions). |
| `docs/LAB-FORMAT.md` | The lab file format: Markdown + LaTeX-style `\commands` for interactive labs. The owner hands this file to Claude together with a PDF to convert it. |
| `OWNER-GUIDE.md` | Setup and day-to-day instructions for the owner. |
| `.claude/launch.json` | `lab-static`: python http.server on port 8766 for browser previews. |

## Architecture in one paragraph

Students load `index.html` from GitHub Pages. The page fetches the catalogue (folders, lab list, site text) from Supabase; if that fails after retries it falls back to `data/snapshot.json`, then to a copy cached in localStorage, then shows an editable "unavailable" message. Lab content (`lab_content` + `attachments`) is loaded lazily per lab. Public labs are read directly under RLS. Locked labs (password / accounts / admin) have their content hidden by RLS and will be served by the `gate` Edge Function (Phase 3). Files live in two buckets: `lab-files-public` (public labs, plain URLs) and `lab-files-private` (locked labs, signed URLs from `gate`; Phase 3). The admin is a Supabase Auth user with `app_metadata.role = 'admin'`; every write policy and stats function checks `is_admin()`.

## Data conventions

- IDs: `f-<ts>` folders, `l-<ts>` labs, `att-<ts>-<rand>` attachments, `g-<ts>` groups.
- Slugs are unique per table and form the URLs: `#/f/<slug>`, `#/lab/<slug>`, `#/search?q=`, `#/signin`.
- `labs` is the catalogue (safe to list). Procedure content and media live in `lab_content` (`format` = `html` from Quill, or `labtags` = a lab file rendered by `ltRender()`); files in `attachments`. Never put content in `labs`.
- Lab files: parsing is `ltProtect` (stash code/math) → `ltExtractTags` (replace `\commands` with placeholders, build widget HTML) → `marked.parse` → `ltInject` → `ltRestore`. Widgets carry `data-field` / `data-check` / `data-photo` ids; `ltBind(area, labId)` restores and autosaves student entries to localStorage (`labsite.entries.<labId>`) and photos to IndexedDB (`labsite` / `photos`). Field ids are stable as long as the author sets `id=`; auto ids are sequential per type in document order. Cloud sync of entries is planned once student accounts exist.
- Media entries in `lab_content.media`: `img:<bucket path>|<alt text>` or `youtube:<id>`. `labs.cover_path` uses the same form (alt dropped). Full `http(s)` URLs are tolerated for legacy/external images.
- Storage paths: `labs/<lab-id>/<timestamp>-<rand>-<safe-name>.<ext>`; site-level uploads under `site/`. Records store bucket-relative paths; `fileUrl(path)` builds the public URL. Rich-text images inside Quill HTML are stored as full public URLs (Quill needs a `src`); `imagePathsInHTML()` maps them back for cleanup.
- Access levels on folders and labs: `inherit | public | password | accounts | admin`. `effectiveAccess(lab)` (client) mirrors `resolve_access()` (SQL); the SQL is authoritative.
- Status: `draft | published | scheduled` (+ `publish_at`). `lab_is_live()` in SQL, `labIsLive()` in JS.
- `site_content` holds every student-facing string (keys mirror `DEFAULTS`), plus JSON blobs `_design`, `_announcement` (`{text, link, expires}`), `_settings`.
- Every save of an existing lab inserts a `lab_revisions` row first (restore UI comes in Phase 4).
- Storage cleanup on save/delete: files under the lab's own folder that are no longer referenced are removed (`referencedPaths`, `removeStoragePaths`, `listStorageFolder`). Reference counting across labs is needed once "Save as copy" exists.
- Analytics: `logEvent()` inserts anonymous rows into `events` only when live and not admin; views deduplicated per lab per browser session; visitor id is a random UUID in localStorage.

## JS conventions

- Global `state`: `folders`, `labs`, `content` (per-lab cache), `text`, `session`, `role`, `source` (`live | snapshot | cache | none`), `route`.
- `render()` re-renders the current route into `#view`; `renderChrome()` updates nav/footer/banners; `reloadCatalogue()` refetches and re-renders after any data change.
- `getText(key)` / `fmt(key, vars)` for all student-facing strings. Add new strings to `DEFAULTS`, `SITE_TEXT_GROUPS`, and `TEXT_LABELS` together.
- `escapeHTML()` on all data interpolated into HTML. Owner-authored Quill HTML is inserted unescaped by design.
- Quill editors are created lazily once (`labEditor`, `richTextEditor`); set `root.innerHTML` on open. Empty check: `'<p><br></p>'`.
- `uploadFile(file, folder, {compress})` compresses images client-side (max edge 1600, WebP/JPEG q0.82) before upload. HEIC cannot be decoded in Chrome; the error message tells the owner what to do.
- Errors never blank the page: `window.onerror` shows `#error-banner`; `render()` and `init()` are wrapped.

## Status (updated 2026-09-18)

Deployed 2026-09-18 at https://duct-tape-magic.github.io/lab-site/ (repo Duct-Tape-Magic/lab-site, Supabase project `nioebkjtrweyxvboajyv` "AP Chem" in the Pro org "OHS Student Labs"; admin whclark09@gmail.com). Snapshot workflow runs hourly. Added 2026-09-18: interactive lab files (`docs/LAB-FORMAT.md`, `ltRender`, `ltBind`, editor import panel, `lab_content.format`).

Done: Phase 0 files (schema, vendoring, snapshot workflow, docs), Phase 1 core (routing, home/folder/lab/search/not-found views, folders + labs CRUD with cover/media/attachments, Quill with LaTeX/mhchem/YouTube/lab template, click-to-edit intro and title, site text panel, design panel, print stylesheet, fallback chain, event logging, revisions insert). Phase 2 items already included: image compression, attachments with inline PDF viewer, storage cleanup.

Verified so far only against the snapshot fallback (no Supabase project yet). First run against a real project must exercise: admin login, role check, lab save/delete, uploads to `lab-files-public`, RLS visibility of drafts vs published.

Decided 2026-09-18: grading stays in Canvas (students print / save PDF from the site); public comments are on hold.

Not built yet: Phase 3 access control (Edge Functions, private bucket flow, password prompt wiring, student sign-in, Accounts panel), Phase 4 (Organize drag-and-drop, Save-as-copy, revision restore UI, QR codes, announcement editor UI, full-text search RPC), Phase 5 (Activity dashboard), Phase 6 polish, Phase 7 (export/import, orphan finder, load test, encrypted snapshot option, owner guide completion), Quill table module decision.

## Guardrails

- Keep `index.html` single-file with vendored libraries; no build step; never add a CDN script.
- Never commit the service key. The publishable key belongs in `CONFIG` and in Action secrets only.
- Every student-facing string goes through `getText`/`fmt` so the owner can edit it.
- All owner settings persist to Supabase (`site_content`), never localStorage (localStorage is only for caches and per-visitor conveniences).
- Keep the fallback chain working: any new public data must also be included in `scripts/snapshot.mjs` and `applyCatalogue()`.
- Locked content must never be readable without the gate: check RLS before exposing any new table.
- Default new visual features OFF so the owner's saved look never changes unexpectedly.
