// Shared pieces for backup.mjs / restore.mjs. Talks to Supabase with the project's service-role key, which lives OUTSIDE the
// repo in ~/.config/ohschemlabs/service-role.key (pasted there by the owner; never printed, never committed).
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

export const URL_BASE = 'https://nioebkjtrweyxvboajyv.supabase.co';
export const BUCKET = 'lab-files-private';
export const KEY_FILE = path.join(os.homedir(), '.config', 'ohschemlabs', 'service-role.key');
// Backups live next to the project in Dropbox (so there is an off-machine copy), never inside the repo.
export const BACKUP_ROOT = process.env.LAB_BACKUP_DIR || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'Lab Site Backups');
export const TABLES = ['lab_entries', 'students', 'seats', 'classes', 'group_members', 'help_threads', 'help_messages', 'user_prefs', 'labs', 'lab_content', 'folders', 'site_content', 'attachments', 'item_groups', 'item_users', 'help_notify', 'lab_revisions'];

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
    const r = await fetch(`${URL_BASE}/rest/v1/${table}?select=${encodeURIComponent(select)}`, { headers: headers(key, { Range: `${from}-${from + 999}`, Prefer: 'count=exact' }) });   // PostgREST pages in primary-key order
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
