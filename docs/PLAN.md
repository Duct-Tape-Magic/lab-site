# Lab Site — Implementation Plan

Prepared 2026-09-18, revised the same day after owner decisions. This document is written so it can become the new project's `CLAUDE.md` once the repo exists: it holds the goals, architecture, schema, feature specs, and build order that Claude Code needs to carry the work forward across sessions.

---

## 1. Goal

A website where students open lab procedures — rich text with photos, embedded video, math, and downloadable documents — organized into a folder tree the owner controls. Every lab (or folder) carries an access level: public, password-locked, restricted to a fixed set of student accounts, or admin-only. The owner manages everything from a hidden admin mode on the live site: add and edit labs, organize folders, set access, manage student accounts, publish or schedule, edit every student-facing word and the site's look, watch activity, manage storage, and back up.

It is built on the same foundation as the Clark Knives site — static single-page site on GitHub Pages plus Supabase — with two additions the knife site never needed: a paid Supabase plan (no inactivity pausing) and a small set of Supabase Edge Functions that enforce access control server-side.

**Hard requirements**
- Budget under $50 / month all-in.
- Stability: students rely on it for deadlines. Must stay up under 100 continuous users, must never be paused for inactivity, and a database problem must not take public content down.

**Decisions already made by the owner**
- Video on YouTube (unlisted).
- Folder tree of any depth.
- Access levels per item: public / password / accounts / admin-only.
- Every student-facing string is editable by admins (site-text panel).
- Custom domain will be purchased.
- All non-student-facing names (repo, tables, buckets, functions, files) are chosen in this plan (§12).

**Non-goals (for now)**
- Grading, submissions, quizzes, per-student progress tracking.
- Any build step or framework. Server code is limited to Supabase SQL and three small Edge Functions that Claude Code deploys; the owner never touches them.

---

## 2. Architecture

```
Student browser ──loads──▶ GitHub Pages (custom domain): index.html + vendor/ (pinned libs) + data/snapshot.json
       │
       ├── public content, live ────▶ Supabase Pro: Postgres (RLS) + Storage bucket lab-files-public (CDN)
       │
       ├── locked content ──────────▶ Supabase Edge Function `gate` ──▶ Postgres + private bucket lab-files-private
       │                                (checks password / student account / admin, returns content + 1-hour signed file URLs)
       │
       └── fallback if Supabase is unreachable ──▶ data/snapshot.json (public content only; refreshed hourly by a GitHub Action)

Video ◀── YouTube unlisted embeds (never stored in Supabase)
Admin ──▶ Supabase Auth (admin role) ──▶ direct table writes under RLS + Edge Functions `admin-users`, `move-files`
Students with accounts ──▶ Supabase Auth (student role, created by the admin)
```

- **GitHub repo `lab-site`**, GitHub Pages from `main`, root folder, custom domain with automatic HTTPS. Same deploy habit as the knife site.
- **Supabase Pro** in a **new organization** "Lab Site" (the knife site stays on its free org, untouched).
- **`index.html` + `vendor/` + `data/`**: one HTML file to edit, no build step; libraries copied into the repo with pinned versions so a CDN outage cannot break the site.
- **Hash routing** (`#/lab/<slug>`, `#/f/<slug>`) so every lab and folder has a shareable link and a QR code.
- **Three Edge Functions** (TypeScript, deployed with the Supabase CLI by Claude Code): `gate` (locked-content reads), `admin-users` (student account management), `move-files` (moves a lab's files between the public and private buckets when its access level changes).

### 2.1 Stability design — why this will not repeat the knife site's outage

The knife site's Supabase project stopped because the **free plan pauses any project with no database activity for 7 days**. That is a billing policy, not a crash, and the Pro plan removes it: paid projects are never paused. Beyond that, the design stacks independent layers so no single failure takes students' content away:

1. **Never paused.** Supabase Pro, spend cap ON (a surprise can never cost more than the plan price). Daily backups with 7-day retention.
2. **Static-first public path.** Students always get the page itself from GitHub's CDN. Live content is fetched from Supabase; if that fails (timeout, outage), the page silently falls back to `data/snapshot.json`, then to the last catalogue cached in the browser. Public content stays readable through a Supabase outage, at most an hour stale.
3. **Locked content is honest about its dependency.** Password- and account-locked labs must be checked by the server, so they cannot be served from the static fallback. The site still shows they exist (lock icon) and an editable message. Option for Phase 7: the snapshot can carry password-locked lab text **encrypted with the lab's password** (AES-GCM, key derived in the browser), so password labs also survive an outage; files would still need the server.
4. **No third-party CDN at runtime.** All libraries vendored and pinned.
5. **Traffic that cannot overload anything.** Small catalogue on load (cached in the browser for 5 minutes), lab content lazily per lab, images through Supabase's CDN, events fire-and-forget.
6. **Defensive client.** Global error handler shows a banner instead of a blank page; every render is wrapped; fetches time out, retry twice with backoff, and detect offline; loaded data is validated so a missing field cannot throw.
7. **Alerts before students notice.** Free uptime monitor (UptimeRobot or Better Stack) checks the site, the database API, the `gate` function, and one public file every 5 minutes and emails the owner. Subscribe the owner's email to status.supabase.com and githubstatus.com.
8. **Verified, not assumed.** A load test at twice the expected peak before launch (Phase 7), and a smoke checklist before every deploy.
9. **Optional extra layer with the custom domain:** put the domain on Cloudflare DNS (free) with the proxy on. Cloudflare's "Always Online" serves a cached copy of the static page if GitHub Pages itself has an incident, and adds free web analytics and DDoS protection.

What this does *not* promise: perfect uptime. Supabase Pro has no contractual SLA (that starts at far more expensive plans). The layers above mean a Supabase incident degrades locked labs only, and a GitHub incident is covered by Cloudflare's cache if the option in item 9 is taken.

### 2.2 Capacity check for 100 continuous users

| Load source | Estimate | Comment |
|---|---|---|
| Page load (HTML + vendored libs) | ~1.2 MB first visit, then browser-cached | Served by GitHub's CDN |
| Catalogue fetch on load | 1 request, ~50–100 KB | Cached in the browser for 5 minutes |
| Opening a public lab | 1–2 small requests + images | Images ~300 KB each via Supabase CDN |
| Opening a locked lab | 1 Edge Function call (~50 ms) + files | Signed URLs valid 1 hour, so re-opens are free |
| Logging an event | 1 tiny insert, fire-and-forget | Never blocks rendering |
| Steady state: 100 users each opening a lab every ~5 min | ≈ 1 request / second | Micro compute handles hundreds per second of simple queries |
| Worst burst: all 100 open the site within 10 s | ≈ 30 requests / second for 10 s | Within PostgREST + Postgres on Micro; Edge Functions scale automatically |
| Egress: 100 users × 20 lab views/day × ~1 MB × 20 school days | ≈ 40 GB / month | Pro includes 250 GB; video is on YouTube so it costs nothing |

If the site ever grows well past this, the only change is a compute add-on in the Supabase dashboard.

### 2.3 Monthly cost

| Item | Monthly | Notes |
|---|---|---|
| Supabase Pro | $25 | Includes a $10 compute credit that covers the Micro instance; 8 GB database, 100 GB storage, 250 GB egress, 2M Edge Function calls, daily backups |
| GitHub Pages + Actions | $0 | Public repo = unlimited Actions minutes |
| YouTube unlisted video | $0 | |
| Uptime monitoring | $0 | Free tier of UptimeRobot / Better Stack |
| Cloudflare DNS + proxy (optional) | $0 | |
| Custom domain | ~$1 | About $12/year at a registrar |
| Staging Supabase project (optional) | +$10 | Second project's compute; test code changes away from real content |
| **Expected total** | **$26** | $36 with staging |

### 2.4 Media strategy

| Media | Where it lives | How it is shown | Notes |
|---|---|---|---|
| Photos | Supabase Storage: `lab-files-public` for public labs, `lab-files-private` for locked labs | Slideshow (reused from knife site) and inline figures in rich text | Compressed in the browser before upload: max edge 1600 px, WebP (JPEG fallback), quality ~0.82, typically 150–400 KB. Alt-text per image. |
| Video | **YouTube unlisted** | Responsive embed via `youtube-nocookie.com`; thumbnail + play overlay on cards | Note for locked labs: YouTube unlisted videos are reachable by anyone who has the link; the page hides the link behind the lock, but a student could share the video URL. If a video must be truly locked, upload it as a private-bucket file instead (works on Pro, no adaptive streaming). |
| Documents (PDF) | Same buckets as photos | Inline viewer (iframe) on desktop, "Open / Download" button on phones (iOS renders only page 1 in iframes) | Optional later: PDF.js viewer for inline paging on mobile. |
| Documents (DOCX, XLSX, PPTX, CSV) | Same buckets | Download button with icon, name, size | Encourage exporting handouts to PDF so they display inline. "Attachment-only" labs (just a PDF) are supported. |

Storage path convention in both buckets: `labs/<lab-id>/<timestamp>-<safe-filename>.<ext>`; site-level assets (logo, intro images) under `site/` in the public bucket. Media and attachment records store the **bucket-relative path**, never a full URL; the client builds a public URL or asks `gate` for a signed one. When a lab's effective access changes between public and locked, the admin's save calls `move-files`, which moves the lab's folder between buckets server-side.

---

## 3. Access control

### 3.1 Levels

| Level | Who can open the lab | How it is enforced |
|---|---|---|
| `public` | Anyone with the link (listed unless the folder is hidden) | Direct reads under RLS; files in the public bucket |
| `password` | Anyone who enters the item's password | `gate` checks the password (bcrypt via pgcrypto), returns a signed 8-hour access token; content and signed file URLs are only returned for a valid token; 10 wrong attempts per 10 minutes per item locks that visitor out temporarily |
| `accounts` | Signed-in students who belong to a group allowed on the item | `gate` verifies the student's Supabase Auth session and group membership |
| `admin` | Admins only (also the natural state for drafts) | RLS: only the admin role can read it |
| `inherit` | *(labs and sub-folders only)* use the parent folder's level | Resolved server-side by `resolve_access()`; top level defaults to `public` |

Access is set on the item that governs it (a folder or a lab); groups and passwords attach to that same item. A student who unlocks a folder's password has unlocked every lab that inherits from it, for the session. Levels are independent of publish status: a `scheduled` lab with `accounts` access appears to its group only after its publish time.

### 3.2 Roles

- **Admin**: Supabase Auth user with `app_metadata.role = 'admin'` (set once by SQL in Phase 0). All write policies and the stats functions check `is_admin()`. More admins can be added the same way.
- **Student**: Supabase Auth user with `app_metadata.role = 'student'`, created by the admin from the Accounts panel (email + generated temporary password, or emailed invite link). Students can sign in from a footer link and only gain access to `accounts`-level items their groups allow. They can change their own password.
- **Anonymous**: everyone else.

### 3.3 Where the security lives

- Row-level security on every table; catalogue reads never expose content of locked labs (content lives in its own table, `lab_content`, that anonymous users cannot select).
- The `gate` Edge Function is the only path to locked content and private files. It runs with the service key on the server, never in the browser.
- Private files live in a private bucket; the browser only ever receives short-lived signed URLs.
- Passwords are stored as bcrypt hashes in an admin-only table.

---

## 4. Data model

```sql
create extension if not exists pgcrypto;

create or replace function is_admin() returns boolean language sql stable as $$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin'
$$;

-- Folders form the tree (course → unit → …), any depth.
create table folders (
  id          text primary key,                    -- 'f-<timestamp>'
  parent_id   text references folders(id) on delete cascade,
  name        text not null,
  slug        text not null unique,
  description text,
  sort_order  integer not null default 0,
  listed      boolean not null default true,       -- false = not shown in navigation, still reachable by link
  access      text not null default 'inherit',     -- 'inherit' | 'public' | 'password' | 'accounts' | 'admin'
  created_at  timestamptz not null default now()
);

-- Catalogue row: everything safe to show in lists, never the procedure text itself.
create table labs (
  id                text primary key,              -- 'l-<timestamp>'
  folder_id         text references folders(id) on delete set null,
  title             text not null,
  slug              text not null unique,
  summary           text,
  cover_path        text,                          -- bucket-relative path
  status            text not null default 'draft', -- 'draft' | 'published' | 'scheduled'
  publish_at        timestamptz,
  access            text not null default 'inherit',
  tags              text[] not null default '{}',
  estimated_minutes integer,
  sort_order        integer not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- The procedure itself, kept apart so RLS can hide it for locked labs.
create table lab_content (
  lab_id  text primary key references labs(id) on delete cascade,
  media   text[] not null default '{}',            -- 'img:<path>' | 'youtube:<id>'
  content text                                     -- HTML from Quill
);

create table attachments (
  id         text primary key,                     -- 'att-<timestamp>'
  lab_id     text not null references labs(id) on delete cascade,
  name       text not null,
  path       text not null,                        -- bucket-relative
  mime       text,
  size_bytes bigint not null default 0,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table lab_revisions (
  id       bigint generated always as identity primary key,
  lab_id   text not null references labs(id) on delete cascade,
  snapshot jsonb not null,                         -- lab + content + attachments before a save
  note     text,
  saved_at timestamptz not null default now()
);

-- Access control
create table item_passwords (                      -- admin-only; one row per governing item
  item_id       text primary key,                  -- folder id or lab id
  password_hash text not null,                     -- crypt(password, gen_salt('bf'))
  updated_at    timestamptz not null default now()
);

create table groups (
  id         text primary key,                     -- 'g-<timestamp>'
  name       text not null,                        -- e.g. 'Period 3 Chemistry'
  created_at timestamptz not null default now()
);

create table group_members (
  group_id text references groups(id) on delete cascade,
  user_id  uuid references auth.users(id) on delete cascade,
  primary key (group_id, user_id)
);

create table item_groups (                         -- which groups may open a governing item
  item_id  text not null,                          -- folder id or lab id
  group_id text references groups(id) on delete cascade,
  primary key (item_id, group_id)
);

create table students (                            -- display info the admin manages; auth.users holds credentials
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  full_name  text,
  created_at timestamptz not null default now()
);

create table unlock_attempts (                     -- rate limiting for password guesses
  item_id    text not null,
  client_key text not null,                        -- hash of IP + user agent, computed in `gate`
  attempts   integer not null default 0,
  window_end timestamptz not null,
  primary key (item_id, client_key)
);

create table site_content (                        -- identical to the knife site
  key   text primary key,
  value text
);
-- keys: every student-facing string (mirrors DEFAULTS in JS), '_design', '_announcement', '_settings'

create table events (                              -- analytics, no personal data
  id         bigint generated always as identity primary key,
  ts         timestamptz not null default now(),
  type       text not null,                        -- 'view' | 'download' | 'video_play' | 'search' | 'print' | 'unlock'
  lab_id     text,
  folder_id  text,
  path       text,
  visitor_id text,                                 -- random UUID in the visitor's localStorage
  referrer   text,
  device     text                                  -- 'mobile' | 'tablet' | 'desktop'
);
create index events_ts_idx on events (ts);
create index events_lab_ts_idx on events (lab_id, ts);

create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger labs_updated_at before update on labs for each row execute function set_updated_at();
```

### 4.1 Access resolution helpers (security definer, used by RLS and by `gate`)

```sql
-- Walks up the tree until it finds a non-'inherit' level. Returns the level and the governing item id.
create or replace function resolve_access(p_lab_id text)
returns table(level text, governing_id text)
language plpgsql stable security definer set search_path = public as $$
declare v_level text; v_folder text; v_depth int := 0;
begin
  select access, folder_id into v_level, v_folder from labs where id = p_lab_id;
  if v_level <> 'inherit' then return query select v_level, p_lab_id; return; end if;
  while v_folder is not null and v_depth < 20 loop
    select access, parent_id, id into v_level, v_folder, governing_id from folders where id = v_folder;
    if v_level <> 'inherit' then return query select v_level, governing_id; return; end if;
    v_depth := v_depth + 1;
  end loop;
  return query select 'public', null::text;
end $$;

create or replace function lab_is_live(p_status text, p_publish_at timestamptz) returns boolean
language sql immutable as $$
  select p_status = 'published' or (p_status = 'scheduled' and p_publish_at is not null and p_publish_at <= now())
$$;

-- True when the current signed-in student may open the governing item.
create or replace function student_allowed(p_governing_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from item_groups ig join group_members gm on gm.group_id = ig.group_id
                 where ig.item_id = p_governing_id and gm.user_id = auth.uid())
$$;
```

### 4.2 Row-level security

```sql
alter table folders enable row level security;  alter table labs enable row level security;
alter table lab_content enable row level security; alter table attachments enable row level security;
alter table lab_revisions enable row level security; alter table item_passwords enable row level security;
alter table groups enable row level security;   alter table group_members enable row level security;
alter table item_groups enable row level security; alter table students enable row level security;
alter table unlock_attempts enable row level security; alter table site_content enable row level security;
alter table events enable row level security;

-- Catalogue: everyone may see folders and live labs except admin-only ones (so locked labs show with a lock icon)
create policy "read folders" on folders for select using (
  is_admin() or access <> 'admin');
create policy "read lab catalogue" on labs for select using (
  is_admin() or (lab_is_live(status, publish_at) and (select level from resolve_access(id)) <> 'admin'));

-- Content and attachments: directly readable only for public labs (locked ones go through `gate`)
create policy "read public content" on lab_content for select using (
  is_admin() or exists (select 1 from labs l where l.id = lab_content.lab_id and lab_is_live(l.status, l.publish_at)
                        and (select level from resolve_access(l.id)) = 'public'));
create policy "read public attachments" on attachments for select using (
  is_admin() or exists (select 1 from labs l where l.id = attachments.lab_id and lab_is_live(l.status, l.publish_at)
                        and (select level from resolve_access(l.id)) = 'public'));

create policy "read site_content" on site_content for select using (true);

-- Students may see their own record and group names (for the sign-in page); nothing else
create policy "student reads self" on students for select using (user_id = auth.uid() or is_admin());
create policy "student reads own groups" on group_members for select using (user_id = auth.uid() or is_admin());

-- Admin writes everywhere
create policy "admin all folders"       on folders        for all using (is_admin()) with check (is_admin());
create policy "admin all labs"          on labs           for all using (is_admin()) with check (is_admin());
create policy "admin all lab_content"   on lab_content    for all using (is_admin()) with check (is_admin());
create policy "admin all attachments"   on attachments    for all using (is_admin()) with check (is_admin());
create policy "admin all revisions"     on lab_revisions  for all using (is_admin()) with check (is_admin());
create policy "admin all passwords"     on item_passwords for all using (is_admin()) with check (is_admin());
create policy "admin all groups"        on groups         for all using (is_admin()) with check (is_admin());
create policy "admin all members"       on group_members  for all using (is_admin()) with check (is_admin());
create policy "admin all item_groups"   on item_groups    for all using (is_admin()) with check (is_admin());
create policy "admin all students"      on students       for all using (is_admin()) with check (is_admin());
create policy "admin all site_content"  on site_content   for all using (is_admin()) with check (is_admin());
-- unlock_attempts: no client policies at all; only `gate` (service key) touches it

-- Analytics: anyone may log an event; only admins read or delete
create policy "anyone logs events" on events for insert with check (
  type in ('view','download','video_play','search','print','unlock') and coalesce(length(path), 0) <= 300);
create policy "admin reads events"   on events for select using (is_admin());
create policy "admin deletes events" on events for delete using (is_admin());

-- Admin sets or clears an item password (never stores plaintext)
create or replace function set_item_password(p_item_id text, p_password text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if p_password is null or p_password = '' then delete from item_passwords where item_id = p_item_id; return; end if;
  insert into item_passwords (item_id, password_hash) values (p_item_id, crypt(p_password, gen_salt('bf')))
  on conflict (item_id) do update set password_hash = excluded.password_hash, updated_at = now();
end $$;
```

### 4.3 Storage buckets

```sql
insert into storage.buckets (id, name, public) values ('lab-files-public', 'lab-files-public', true);
insert into storage.buckets (id, name, public, file_size_limit) values ('lab-files-private', 'lab-files-private', false, 52428800);

create policy "anyone reads public files" on storage.objects for select using (bucket_id = 'lab-files-public');
create policy "admin writes files" on storage.objects for insert with check (is_admin() and bucket_id in ('lab-files-public','lab-files-private'));
create policy "admin updates files" on storage.objects for update using (is_admin() and bucket_id in ('lab-files-public','lab-files-private'));
create policy "admin deletes files" on storage.objects for delete using (is_admin() and bucket_id in ('lab-files-public','lab-files-private'));
create policy "admin lists private" on storage.objects for select using (is_admin() and bucket_id = 'lab-files-private');
```

### 4.4 Analytics aggregation (admin-only; the dashboard never downloads raw events)

```sql
create or replace function stats_daily(n_days int default 30)
returns table(day date, views bigint, visitors bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query select e.ts::date, count(*) filter (where e.type = 'view'), count(distinct e.visitor_id)
    from events e where e.ts >= now() - make_interval(days => n_days) group by 1 order by 1;
end $$;

create or replace function stats_top_labs(n_days int default 30, lim int default 20)
returns table(lab_id text, views bigint, downloads bigint, visitors bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  return query select e.lab_id, count(*) filter (where e.type = 'view'), count(*) filter (where e.type = 'download'),
    count(distinct e.visitor_id) from events e
    where e.lab_id is not null and e.ts >= now() - make_interval(days => n_days)
    group by e.lab_id order by 2 desc limit lim;
end $$;

-- stats_summary(n_days) returns json: views, downloads, visitors, unlocks, device split — same admin guard.
-- Optional retention with pg_cron: delete events older than 365 days weekly.
```

### 4.5 Edge Functions

| Function | Caller | Does |
|---|---|---|
| `gate` | Students / anonymous | `unlock(item_id, password)` → checks bcrypt hash, applies the 10-attempts-per-10-minutes limit, returns a signed 8-hour token. `lab(slug, token?)` → resolves access; for `password` needs a valid token for the governing item, for `accounts` needs a student session in an allowed group, for `admin` needs an admin session; returns content, media, attachments, and signed URLs (1 hour) for private files. |
| `admin-users` | Admin only | List / create (email, name, temporary password or invite) / reset password / delete student accounts; sets `app_metadata.role = 'student'`; keeps `students` in sync. Bulk create from pasted "name, email" lines. |
| `move-files` | Admin only | Moves `labs/<lab-id>/` between the public and private buckets when the effective access of a lab changes (or when a folder's access changes, for every lab under it). Idempotent, reports what moved. |

All three verify the caller's JWT server-side and use the service key only inside the function. Secrets (service key, token signing secret) live in Supabase function secrets, never in the repo.

---

## 5. Student-facing site

**Home (`#/`)**: editable intro block, announcement banner (text, optional link, expiry; dismissible per visitor), top-level folders as cards or sections, optional "recently updated" strip, search box, footer with editable "Student sign in" link.

**Folder page (`#/f/<slug>`)**: breadcrumb, description, sub-folders, labs as cards (cover, title, summary, tags, estimated time, updated date, lock icon and level label for locked items). Attachment-only labs show a document icon instead of a cover.

**Lab page (`#/lab/<slug>`)**:
- Public: loads content directly.
- Password: shows an editable prompt ("This lab is locked. Enter the password your teacher gave you."); on success the token is kept in sessionStorage so every lab under the same governing item opens without asking again; wrong password shows an editable message; too many attempts shows an editable wait message.
- Accounts: prompts to sign in; after sign-in, opens if the student's group is allowed, otherwise an editable "not available to your account" message.
- Once open: title, breadcrumb, tags, time, last-updated; media slideshow (arrows, dots, counter, keyboard, swipe — reused) with YouTube embeds; rich content with KaTeX (`$…$`, `$$…$$`) and mhchem (`\ce{H2O}`); attachments list (PDF inline on desktop, open button on phones, downloads for other types, each with name, type, size); toolbar: Print, Copy link, previous/next within folder.
- Content loaded lazily per lab; last-viewed content cached in sessionStorage (never for locked labs).

**Student sign-in (`#/signin`)**: email + password; "forgot password" sends Supabase's reset email; signed-in students see their name and a sign-out link. Students see nothing of admin mode.

**Search**: instant client-side search over title, summary, tags (catalogue already loaded); full-text search inside public lab content via a Postgres RPC in Phase 4. Locked content is never searchable by anonymous visitors.

**Cross-cutting**: mobile-first layout; same CSS-variable theming as the knife site so the Design panel works; print stylesheet (hides navigation and admin UI, page breaks before major headings); accessibility (semantic headings, alt text, focus states, keyboard slideshow, contrast); not-found route.

**Every student-facing string** (nav labels, buttons, prompts, error messages, lock labels, sign-in copy, footer, empty states) is a key in `DEFAULTS` and therefore editable in the Site text panel.

**Loading order for content**: live Supabase (5 s timeout, 2 retries) → `data/snapshot.json` from GitHub Pages → last catalogue cached in localStorage → editable "Content temporarily unavailable" message. A thin banner (editable text) notes when a fallback is in use.

---

## 6. Admin mode

Login via the gear icon as on the knife site (admin accounts only; a student signing in there is told to use the student sign-in). Admin bar: **+ Lab · + Folder · Organize · Accounts · Site text · Design · Activity · Storage · Backup · Log out**.

**Lab editor (modal)**
- Fields: title, slug (auto, editable, uniqueness checked), folder, summary, tags, estimated minutes, status (draft / published / scheduled with date-time), cover image.
- **Access**: Inherit from folder (shows the resolved level) / Public / Password (set or change password; "show password" toggle; a note that changing it logs everyone out of the lab) / Accounts (multi-select of groups) / Admin only. Saving a change between public and locked calls `move-files` and shows progress.
- Media manager: drag-drop upload with compression, add YouTube URL, drag-to-reorder, remove, alt-text per image. Ported from `renderKnifeMediaManager`.
- Quill content editor: existing toolbar (headers, fonts, colors, lists, links, images, Σ LaTeX, ▶ video) plus **Insert lab template** (Objectives · Safety · Materials · Procedure · Data · Analysis questions) and **Table** (via `quill-table-better`, confirmed with a prototype in Phase 1).
- Attachments: drop zone for PDF/DOCX/XLSX/PPTX/CSV up to 50 MB; list with rename, reorder, remove.
- Buttons: Save · Save as copy · Delete · History (revisions with Restore-into-editor) · Preview.

**Folder editor (modal)**: name, slug, description, parent, listed/hidden, access (same control as labs; applies to everything that inherits).

**Organize (panel)**: whole tree in one view; drag labs and folders to reorder or move (HTML5 drag-and-drop, plus up/down/move buttons as keyboard fallback); inline rename; status and lock badges; delete folder only when empty. Persists as a batch upsert.

**Accounts (panel)**
- Students tab: table (name, email, groups, created, last sign-in), add one, bulk add from pasted lines, reset password (generates a new temporary one to hand out), remove. Uses `admin-users`.
- Groups tab: create/rename/delete groups, add or remove members with a checklist.
- Assignments happen on the lab/folder editor's Access control; this panel also lists which items each group can open.

**Click-to-edit**: intro block and announcement use the knife site's dashed-outline "✎ edit" pattern.

**Site text**: same grouped panel as the knife site, with groups for Navigation, Cards, Lab page, Locks and sign-in, Forms and errors, Footer, Fallback messages.

**Design**: whole panel ported (palettes, typography, layout, cards, background); defaults tuned for long procedures (wider measure, larger base font).

**Activity**: see §7.

**Storage**: usage bar against the plan quota (both buckets), largest files, per-lab usage, **orphan finder** (files not referenced by any lab, attachment, cover, or site content) with one-click delete, and a flag on any image over 1 MB. Reference counting before any delete, because "Save as copy" shares files between labs.

**Backup**: Export JSON (everything except passwords and account credentials) as a download; Import JSON (merge by id, or replace after confirmation); shows the date of the last export and of the last automatic snapshot.

**Per-lab utilities**: Copy link, QR code (SVG, printable).

---

## 7. Activity monitoring

Logged client-side only when no admin session is active. Students with accounts are logged the same anonymous way as everyone else (no user ids in `events`).

| Event | When | Fields |
|---|---|---|
| `view` | a lab or folder renders (once per lab per browser session) | lab_id / folder_id, path, device, referrer |
| `download` | an attachment is opened or downloaded | lab_id, path |
| `video_play` | a YouTube embed starts (IFrame API) | lab_id |
| `search` | a search is submitted | path = `search:<query>` |
| `print` | Print is used | lab_id |
| `unlock` | a password or account lab is opened successfully | lab_id |

Dashboard (Activity panel): range selector (7 / 30 / 90 days); tiles for views, unique visitors, downloads, unlocks; views-per-day bar chart (inline SVG, no chart library); top labs table; device split; recent activity feed; CSV export; "Clear data older than…" button. All numbers come from the admin-guarded `stats_*` functions.

Uptime alerts (external) and Supabase's usage dashboards complete the picture. Cloudflare Web Analytics is free if the domain is on Cloudflare.

---

## 8. Operations and safety nets

1. **Supabase Pro, spend cap ON.** Daily backups automatic (7-day retention); do one test restore into a scratch project during Phase 0 so the procedure is known before it is needed.
2. **Snapshot workflow** (`.github/workflows/snapshot.yml`), hourly: `scripts/snapshot.mjs` fetches public folders, the lab catalogue, public lab content and attachments, and site content through the REST API with the publishable key (RLS guarantees nothing locked comes back), writes `data/snapshot.json`, commits only if it changed. A weekly heartbeat commit keeps GitHub from disabling the schedule after 60 idle days. Side benefit: git history of every public content change.
3. **Client fallback chain**: live → snapshot → local cache → editable message (§5).
4. **Uptime monitoring**: UptimeRobot (or Better Stack) free tier, 5-minute checks with email alerts: the site URL with a keyword check; `…/rest/v1/site_content?select=key&limit=1&apikey=<publishable key>`; the `gate` function's health route; one public storage file. Status-page email subscriptions for Supabase and GitHub.
5. **Security**: publishable key only in client code and Action secrets; service key only in Edge Function secrets. RLS is the boundary for tables, `gate` for locked content, private bucket + signed URLs for locked files. MFA on the Supabase account and on GitHub. Student-supplied strings escaped everywhere; passwords never logged.
6. **Local preview**: `.claude/launch.json` static server as on the knife site, against the live project; use draft status while testing. Optional staging project (+$10/mo).
7. **Release discipline**: every deploy is a git commit (rollback = revert). Smoke checklist before pushing: home, folder, public lab with video and PDF, password lab (right and wrong password), account lab (allowed and not allowed student), search, print preview, admin login, save a draft, move a lab between public and locked, log out.
8. **Owner guide** (`OWNER-GUIDE.md`): add a lab in 5 steps; choosing an access level; managing student accounts and groups; media rules of thumb; what each alert means and what to do; restore a backup; roll back a deploy; a monthly 5-minute health check (storage meter, Supabase usage page, last snapshot time, uptime monitor status).

---

## 9. Build phases

Each phase ends with a deployed, usable site.

**Phase 0 — Setup (½ day)**
Create repo `lab-site` + Pages; buy domain, point it at Pages (and optionally Cloudflare); create the Supabase Pro organization and project (spend cap on, backups confirmed); run schema, helpers, RLS, buckets, and stats SQL; create the admin user with the admin role and MFA; vendor the libraries; add the snapshot workflow and secrets; set up uptime monitors and status subscriptions; write the new `CLAUDE.md` (this plan, trimmed), `OWNER-GUIDE.md` skeleton, `.claude/launch.json`.

**Phase 1 — Core (first deployable)**
Scaffold `index.html` from the knife site (auth, admin bar, modals, toast, Quill + LaTeX + YouTube, dropzone, storage helpers). Folders and labs CRUD with the split catalogue/content tables. Hash router, home, folder page, lab page (lazy content), draft/published, quick search. Table module prototype. Basic print stylesheet. Public access only at this stage.

**Phase 2 — Media and documents**
Client-side image compression + alt text; YouTube embeds in slideshow and cards; attachments with PDF inline viewer and download list; Storage panel with usage meter; reference-counted cleanup; mhchem.

**Phase 3 — Access control**
`gate`, `admin-users`, `move-files` Edge Functions; private bucket; Access control on lab and folder editors; password prompt, student sign-in, group checks in the student UI; Accounts panel; rate limiting; `unlock` events. Ends with all four levels working end to end and tested with a throwaway student account.

**Phase 4 — Organization and publishing**
Organize tree with drag-and-drop and move; scheduled publishing; Save-as-copy; revision history with restore; lab template button; Copy link + QR code; announcement banner; full-text search RPC for public content.

**Phase 5 — Activity**
Event logging, `stats_*` functions, Activity dashboard with chart, top labs, device split, CSV export, retention control.

**Phase 6 — Customization and polish**
Site text panel with every student-facing string grouped; Design panel ported; readable defaults; accessibility pass; mobile QA on real phones; empty states; not-found route.

**Phase 7 — Hardening and launch**
Fallback chain with visible banner; global error banner and fetch timeouts/retries; Export/Import JSON; orphan finder; load test with k6 at twice the expected peak (about 60 requests/s for a minute, including `gate`) and fix anything it surfaces; smoke checklist; finish the owner guide; test-restore a backup; optional encrypted snapshot for password labs.

---

## 10. Reuse map from the Clark Knives `index.html`

| Knife site | Lab site use |
|---|---|
| `checkSession`, `tryLogin`, `logoutAdmin`, `openAdminLogin`, admin bar | Reused; admin check becomes "session with admin role" |
| `getText`, `DEFAULTS`, `renderAll`, `openSiteTextModal`, `saveSiteText`, `humanizeKey` | Same pattern, many new keys |
| Design panel (`openDesignModal` … `saveDesign`, palettes, typography, layout, cards, topo background) | Port as-is; adjust defaults |
| `buildQuillEditor`, `registerYoutubeBlot`, `insertLatex`, `insertYoutube`, `renderMathIn` | Port; add mhchem, table module, lab template |
| `setupDropzone`, `uploadImage`, `uploadImageFromUrl` | Port; add compression, non-image files, bucket selection, per-lab paths |
| `renderKnifeMediaManager`, `renderKnifeMediaGrid`, `getKnifeMedia`, `youtubeThumb`, `extractYoutubeId` | Becomes the lab media manager (paths instead of URLs) |
| `renderSlideshow`, `changeSlide`, `goToSlide`, `applySlide` | Lab page media |
| `deleteStorageMedia`, `storagePathFromUrl` | Port; add reference counting, two buckets, orphan finder |
| `openRichTextEditor`, `openPlainTextEditor`, `saveRichText`, `saveText` (click-to-edit) | Intro block, announcement |
| `toast`, `openModal`, `closeModal`, `escapeHTML`, `setIfExists`, `isColorDark` | Unchanged |
| Inquiries | Dropped |

---

## 11. Risks and open questions

- **Tables in Quill 2**: no official table module. Plan: `quill-table-better`; fallback is a simple "insert table" blot or attaching tables as PDF. Decide in Phase 1 with a quick prototype.
- **HEIC photos from iPhones**: Chrome cannot decode HEIC in the browser. Detect and ask for JPEG (iPhone "Most Compatible" setting), or add a HEIC decoder library later.
- **PDF on iOS**: iframes show only page 1; the plan uses an Open button on mobile. PDF.js can be added if inline paging matters.
- **YouTube links leak past locks**: unlisted videos are reachable by anyone with the link; for a truly locked video, upload the file to the private bucket instead.
- **Password sharing**: a lab password is only as private as the students keep it; the `accounts` level is the answer where that matters.
- **Egress spikes**: fine at ~300 KB/image and 250 GB/month included; compression is mandatory in the upload path and the storage panel flags any image over 1 MB.
- **Provider outages**: Supabase incidents degrade locked labs only; a GitHub Pages incident is covered by Cloudflare's cache if the domain sits on Cloudflare.
- **Analytics spam**: open insert policy constrained by policy checks; a rate-limiting trigger can be added if needed.
- **Bus factor**: keep the admin password and MFA recovery codes in a password manager; the owner guide documents restore and rollback.

---

## 12. Names (non-student-facing, decided here)

| Thing | Name |
|---|---|
| GitHub repo | `lab-site` |
| Supabase organization / project | `Lab Site` / `lab-site` |
| Storage buckets | `lab-files-public`, `lab-files-private` |
| Edge Functions | `gate`, `admin-users`, `move-files` |
| Tables | `folders`, `labs`, `lab_content`, `attachments`, `lab_revisions`, `item_passwords`, `groups`, `group_members`, `item_groups`, `students`, `unlock_attempts`, `site_content`, `events` |
| Repo files | `index.html`, `vendor/`, `data/snapshot.json`, `scripts/snapshot.mjs`, `supabase/functions/{gate,admin-users,move-files}/index.ts`, `supabase/schema.sql`, `.github/workflows/snapshot.yml`, `CLAUDE.md`, `OWNER-GUIDE.md`, `.claude/launch.json` |
| Site-content JSON keys | `_design`, `_announcement`, `_settings` |
| Site title default | "Labs" placeholder, editable in Site text |
