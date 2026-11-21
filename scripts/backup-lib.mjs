// Shared pieces for backup.mjs / restore.mjs. Talks to Supabase with the project's service-role key, which lives OUTSIDE the
// repo in ~/.config/ohschemlabs/service-role.key (pasted there by the owner; never printed, never committed).
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

export const URL_BASE = 'https://nioebkjtrweyxvboajyv.supabase.co';
export const BUCKET = 'lab-files-private';
export const KEY_FILE = path.join(os.homedir(), '.config', 'ohschemlabs', 'service-role.key');
// Backups live in the owner's home folder, outside Dropbox and outside the repo (owner, 2026-11-21): a copy inside Dropbox is
// held by Dropbox, shared with whoever shares that folder, and kept by Dropbox after we delete it, so the Privacy page's promise
// that backups are deleted after KEEP_DAYS could not be kept there.
export const BACKUP_ROOT = process.env.LAB_BACKUP_DIR || path.join(os.homedir(), 'Lab Site Backups');
export const KEEP_DAYS = 30;        // a backup older than this is deleted (the Privacy page says so: change both together)
export const BACKUP_EVERY_DAYS = 7; // the scheduled job makes a new backup when the newest verified one is this old
export const TABLES = ['lab_entries', 'students', 'seats', 'classes', 'group_members', 'help_threads', 'help_messages', 'user_prefs', 'labs', 'lab_content', 'folders', 'site_content', 'attachments', 'item_groups', 'item_users', 'help_notify', 'lab_revisions',
  'oral_banks', 'oral_settings', 'oral_sessions', 'oral_messages', 'oral_reports', 'oral_usage'];   // the Socratic tutor: banks, settings, every student conversation, problem reports, usage (added 2026-11-13)
const ORDER = { oral_banks: 'id', oral_settings: 'key', oral_sessions: 'id', oral_messages: 'id', oral_reports: 'id', oral_usage: 'user_id,day' };   // an explicit order, so paging through a table of more than 1000 rows cannot skip or repeat one

export function loadKey() {
  const k = (process.env.SUPABASE_SERVICE_ROLE_KEY || (fs.existsSync(KEY_FILE) ? fs.readFileSync(KEY_FILE, 'utf8') : '')).trim();
  if (!k) throw new Error(`No service-role key. Paste it into ${KEY_FILE} (one line) — the owner does this, never Claude.`);
  if (k.length < 30 || !(k.startsWith('sb_secret_') || k.startsWith('eyJ'))) throw new Error('The key file does not look like a secret / service-role key.');
  return k;
}
// New-style secret keys (sb_secret_…) go in the apikey header alone; the legacy service_role JWT also needs the Bearer header.
export function headers(key, extra = {}) { return key.startsWith('sb_') ? { apikey: key, ...extra } : { apikey: key, Authorization: `Bearer ${key}`, ...extra }; }

export async function fetchAll(key, table, select = '*') {   // every row, 1000 at a time
  const out = []; let from = 0;
  for (;;) {
    const r = await fetch(`${URL_BASE}/rest/v1/${table}?select=${encodeURIComponent(select)}${ORDER[table] ? '&order=' + ORDER[table] : ''}`, { headers: headers(key, { Range: `${from}-${from + 999}`, Prefer: 'count=exact' }) });   // PostgREST pages in primary-key order
    if (r.status === 416) break;
    if (!r.ok) throw new Error(`${table}: HTTP ${r.status} ${await r.text()}`);
    const rows = await r.json(); out.push(...rows);
    if (rows.length < 1000) break; from += 1000;
  }
  return out;
}
export async function listBucket(key, prefix) {   // recursive listing of the private bucket
  const files = [];
  async function walk(p) {
    let offset = 0;
    for (;;) {
      const r = await fetch(`${URL_BASE}/storage/v1/object/list/${BUCKET}`, { method: 'POST', headers: headers(key, { 'Content-Type': 'application/json' }), body: JSON.stringify({ prefix: p, limit: 1000, offset, sortBy: { column: 'name', order: 'asc' } }) });
      if (!r.ok) throw new Error(`list ${p}: HTTP ${r.status} ${await r.text()}`);
      const items = await r.json();
      for (const it of items) {
        const full = p ? `${p}/${it.name}` : it.name;
        if (it.id) files.push({ path: full, size: it.metadata?.size ?? null, updated_at: it.updated_at || null, etag: it.metadata?.eTag || null });
        else await walk(full);   // a folder
      }
      if (items.length < 1000) break; offset += 1000;
    }
  }
  await walk(prefix);
  return files;
}
export async function downloadObject(key, objPath) {
  const r = await fetch(`${URL_BASE}/storage/v1/object/${BUCKET}/${objPath.split('/').map(encodeURIComponent).join('/')}`, { headers: headers(key) });
  if (!r.ok) throw new Error(`download ${objPath}: HTTP ${r.status}`);
  return Buffer.from(await r.arrayBuffer());
}
export async function uploadObject(key, objPath, buf, contentType = 'image/jpeg') {
  const r = await fetch(`${URL_BASE}/storage/v1/object/${BUCKET}/${objPath.split('/').map(encodeURIComponent).join('/')}`, { method: 'POST', headers: headers(key, { 'Content-Type': contentType, 'x-upsert': 'true', 'cache-control': '0' }), body: buf });
  if (!r.ok) throw new Error(`upload ${objPath}: HTTP ${r.status} ${await r.text()}`);
}
export function stamp(d = new Date()) { return d.toISOString().replace(/[:T]/g, '-').slice(0, 16); }
export function listBackups() {
  if (!fs.existsSync(BACKUP_ROOT)) return [];
  return fs.readdirSync(BACKUP_ROOT).filter(n => /^\d{4}-\d{2}-\d{2}-\d{2}-\d{2}$/.test(n)).sort();
}
export function readTable(backup, table) { const p = path.join(BACKUP_ROOT, backup, 'tables', table + '.json'); return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : []; }

// ---- Expiry (owner, 2026-11-21): a student who deletes their account must also disappear from the backups, so no backup is
// kept longer than KEEP_DAYS. The newest verified backup is always kept, however old, so a broken schedule can never leave the
// site with no backup at all. A stored photo goes once no kept backup lists it.
export function backupTime(name) { const m = /^(\d{4})-(\d{2})-(\d{2})-(\d{2})-(\d{2})$/.exec(name); return m ? Date.UTC(+m[1], m[2] - 1, +m[3], +m[4], +m[5]) : NaN; }   // stamp() names are UTC
export function isVerified(name) { try { return JSON.parse(fs.readFileSync(path.join(BACKUP_ROOT, name, 'summary.json'), 'utf8')).verified === true; } catch (e) { return false; } }
export function newestVerified() { return listBackups().filter(isVerified).at(-1) || null; }
export function expireBackups(now = Date.now()) {
  const all = listBackups(), good = newestVerified();
  if (!good) return { removed: 0, kept: all.length, files: 0, note: 'no verified backup yet, nothing deleted' };
  const cutoff = now - KEEP_DAYS * 864e5, old = all.filter(n => n !== good && backupTime(n) < cutoff), kept = all.filter(n => !old.includes(n));
  // Which stored photos the kept backups still need. Worked out BEFORE anything is deleted: an unreadable manifest stops the run.
  const need = new Set();
  for (const n of kept) { const p = path.join(BACKUP_ROOT, n, 'files.json'); if (fs.existsSync(p)) for (const f of JSON.parse(fs.readFileSync(p, 'utf8'))) need.add(f.path); }
  for (const n of old) fs.rmSync(path.join(BACKUP_ROOT, n), { recursive: true, force: true });
  const store = path.join(BACKUP_ROOT, 'files-store'); let files = 0;
  const walk = (dir, rel) => {
    for (const it of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, it.name), r = rel ? rel + '/' + it.name : it.name;
      if (it.isDirectory()) { walk(full, r); if (!fs.readdirSync(full).length) fs.rmdirSync(full); }
      else if (!need.has(r) && now - fs.statSync(full).mtimeMs > 864e5) { fs.rmSync(full); files++; }   // a day's grace: a backup running right now has stored photos its manifest does not list yet
    }
  };
  if (fs.existsSync(store)) walk(store, '');
  return { removed: old.length, kept: kept.length, files, note: backupTime(good) < cutoff ? `the newest verified backup (${good}) is older than ${KEEP_DAYS} days and was kept: the schedule is not running` : '' };
}
