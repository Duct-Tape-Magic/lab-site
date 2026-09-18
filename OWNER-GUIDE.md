# Owner guide — Lab Site

## First-time setup (one afternoon, done once)

1. **Supabase.** Create a new organization on the Pro plan (keep the knife site's free organization separate), then a project named `lab-site`. Leave the spend cap ON. In Project Settings → API copy the Project URL and the publishable (anon) key.
2. **Database.** Open SQL Editor, paste all of `supabase/schema.sql`, run it. It creates every table, security rule, storage bucket, and statistics function.
3. **Admin account.** Authentication → Users → Add user (your email + a strong password; turn on MFA for your Supabase login too). Then in SQL Editor run, with your email:
   ```sql
   update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb where email = 'you@example.com';
   ```
4. **Connect the site.** In `index.html`, near the top of the `<script>`, set `SUPABASE_URL` and `SUPABASE_KEY` in `CONFIG`.
5. **GitHub.** Create a public repo named `lab-site`, push this folder, enable Pages (Settings → Pages → Deploy from branch `main`, root). Add two repository secrets (Settings → Secrets and variables → Actions): `SUPABASE_URL` and `SUPABASE_ANON_KEY`. Run the `content-snapshot` workflow once by hand (Actions tab) to confirm it works.
6. **Domain.** Buy the domain, add it under Settings → Pages → Custom domain, follow GitHub's DNS instructions, tick "Enforce HTTPS". Optional: host the DNS on Cloudflare (free) for an extra caching layer.
7. **Alerts.** Create a free UptimeRobot account and add monitors (5-minute interval, email alerts) for the site URL and for `https://<project>.supabase.co/rest/v1/site_content?select=key&limit=1&apikey=<publishable key>`. Subscribe to status.supabase.com and githubstatus.com.

## Everyday use

- **Log in:** click the small ⚙ at the top right, enter your admin email and password. A dark admin bar appears.
- **Add a folder:** admin bar → + Folder. Folders can sit inside other folders. "Show in navigation" off makes a folder reachable only by its link.
- **Add a lab:** admin bar → + Lab. Title, folder, a one-line summary, photos (they are compressed automatically), a YouTube link for video, the procedure text (the ☰ Template button inserts the standard sections), and files (PDF is best; it opens inside the site).
- **Publish:** Status = Published. Draft keeps it invisible to students; Scheduled makes it appear at a chosen date and time.
- **Who can open it:** Public, password, selected student accounts, or admins only. Password and account locks are enabled in a later update; until then keep labs Public or Draft.
- **Edit text anywhere:** in admin mode, hover any editable text (dashed outline) and click it. Every other label lives in admin bar → Site text.
- **Look and feel:** admin bar → Design.
- **Share a lab:** open it and click Copy link. Links look like `…/#/lab/lab-3-titration` and never change unless you rename the link name.

## Media rules of thumb

- Photos: JPG or PNG straight from a phone are fine; the site shrinks them. iPhone HEIC photos need "Most Compatible" format in Camera settings.
- Video: upload to YouTube as **Unlisted**, paste the link. Never upload video files to the site.
- Documents: export handouts as PDF so students can read them without downloading. Word/Excel files are offered as downloads.

## If something goes wrong

- **Site shows "Showing a saved copy…"**: Supabase is unreachable. Students still see public labs. Check status.supabase.com; check the Supabase dashboard for the project's health. Locked labs wait until the connection returns.
- **A change broke the site after a deploy:** in GitHub, revert the last commit (or ask Claude Code to). Pages redeploys in about a minute.
- **Restore content:** Supabase Pro keeps daily backups for 7 days (Database → Backups). The git history of `data/snapshot.json` also holds every hourly version of the public content.
- **Forgot the admin password:** Supabase dashboard → Authentication → Users → send a reset email.

## Monthly five-minute check

Supabase dashboard → Reports: storage used, egress, API errors. GitHub → Actions: the snapshot workflow ran recently. UptimeRobot: all monitors green.
