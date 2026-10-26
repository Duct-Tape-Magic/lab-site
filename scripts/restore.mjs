#!/usr/bin/env node
// Surgical restore from a backup made by backup.mjs. Never touches anything it was not asked to, and refuses to overwrite newer
// work unless told --force.
//   node scripts/restore.mjs --list                                  → backups available
//   node scripts/restore.mjs --backup <name> --students                → who has entries in that backup (seat/name, user id)
//   node scripts/restore.mjs --backup <name> --student <uid> --labs    → that student's labs in the backup, with saved times
//   node scripts/restore.mjs --backup <name> --student <uid> --lab <labId> [--force]   → put back one student's entries for one lab
//   node scripts/restore.mjs --backup <name> --student <uid> --lab <labId> --photos [--force]   → put back that student's photos for that lab
//   node scripts/restore.mjs --backup <name> --file <bucket path> [--force]   → put back one file from the store
// Without --backup the newest backup is used. "Newer work" = the live row's updated_at is later than the backup's; a live file
// that already exists counts as newer.
import fs from 'node:fs';
import path from 'node:path';
import { loadKey, headers, URL_BASE, listBackups, readTable, uploadObject, listBucket, BACKUP_ROOT } from './backup-lib.mjs';

const args = process.argv.slice(2);
const opt = n => { const i = args.indexOf('--' + n); return i >= 0 ? (args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : true) : null; };
const backups = listBackups();
if (opt('list') !== null) { for (const b of backups) { const s = JSON.parse(fs.readFileSync(path.join(BACKUP_ROOT, b, 'summary.json'), 'utf8')); console.log(`${b}  students ${s.students_with_entries}  labs ${s.labs_with_entries}  files ${s.files}${s.verified ? '  verified' : ''}`); } process.exit(0); }
const backup = opt('backup') || backups.at(-1);
if (!backup || !fs.existsSync(path.join(BACKUP_ROOT, backup))) { console.error('No such backup. Run with --list.'); process.exit(1); }
const entries = readTable(backup, 'lab_entries'), seats = readTable(backup, 'seats'), classes = readTable(backup, 'classes'), students = readTable(backup, 'students'), labs = readTable(backup, 'labs');
const who = uid => { const s = seats.find(x => x.user_id === uid); if (s) { const c = classes.find(x => x.id === s.class_id); return `${c ? c.name : s.class_id} · Seat ${s.seat_no}${s.nickname ? ` (${s.nickname})` : ''}`; } const st = students.find(x => x.user_id === uid); return st ? (st.full_name || st.email || 'student') : 'unknown'; };
const labTitle = id => (labs.find(l => l.id === id) || {}).title || id;
const force = opt('force') !== null;

if (opt('students') !== null) { const seen = new Map(); for (const e of entries) seen.set(e.user_id, (seen.get(e.user_id) || 0) + 1); for (const [uid, n] of seen) console.log(`${uid}  ${who(uid)}  (${n} lab${n === 1 ? '' : 's'})`); process.exit(0); }
const uid = opt('student'), labId = opt('lab'), file = opt('file');
if (uid && opt('labs') !== null) { for (const e of entries.filter(x => x.user_id === uid)) console.log(`${e.lab_id}  ${labTitle(e.lab_id)}  saved ${e.updated_at}  ${Object.keys(e.data || {}).length} fields`); process.exit(0); }

const key = loadKey();
if (file) {
  const local = path.join(BACKUP_ROOT, 'files-store', file);
  if (!fs.existsSync(local)) { console.error('Not in the store: ' + file); process.exit(1); }
  const live = await listBucket(key, path.dirname(file)); const exists = live.some(f => f.path === file);
  if (exists && !force) { console.error('That file exists on the live site. Add --force to overwrite it with the backup copy.'); process.exit(1); }
  await uploadObject(key, file, fs.readFileSync(local)); console.log(`Restored ${file}${exists ? ' (overwrote the live copy)' : ''}`); process.exit(0);
}
if (!uid || !labId) { console.error('Need --student <uid> and --lab <labId> (or --file, --students, --labs, --list).'); process.exit(1); }
if (opt('photos') !== null) {
  const prefix = `photos/${uid}/${labId}`;
  const manifest = JSON.parse(fs.readFileSync(path.join(BACKUP_ROOT, backup, 'files.json'), 'utf8')).filter(f => f.path.startsWith(prefix + '/'));
  if (!manifest.length) { console.log('No photos for that student and lab in this backup.'); process.exit(0); }
  const live = new Set((await listBucket(key, prefix)).map(f => f.path));
  let put = 0, kept = 0;
  for (const f of manifest) { if (live.has(f.path) && !force) { kept++; continue; } await uploadObject(key, f.path, fs.readFileSync(path.join(BACKUP_ROOT, 'files-store', f.path))); put++; }
  console.log(`Photos for ${who(uid)} on "${labTitle(labId)}": ${put} restored, ${kept} left as they are (already on the live site; use --force to overwrite)`); process.exit(0);
}
const row = entries.find(e => e.user_id === uid && e.lab_id === labId);
if (!row) { console.error('No entries for that student and lab in this backup.'); process.exit(1); }
const r = await fetch(`${URL_BASE}/rest/v1/lab_entries?user_id=eq.${uid}&lab_id=eq.${encodeURIComponent(labId)}&select=updated_at,data`, { headers: headers(key) });
const live = (await r.json())[0] || null;
if (live && !force && new Date(live.updated_at) > new Date(row.updated_at)) {
  console.error(`The live copy (${live.updated_at}, ${Object.keys(live.data || {}).length} fields) is newer than the backup (${row.updated_at}, ${Object.keys(row.data || {}).length} fields). Add --force to replace it anyway.`); process.exit(1);
}
const put = await fetch(`${URL_BASE}/rest/v1/lab_entries`, { method: 'POST', headers: headers(key, { 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates,return=minimal' }), body: JSON.stringify({ user_id: uid, lab_id: labId, data: row.data, updated_at: row.updated_at }) });
if (!put.ok) { console.error('Restore failed: HTTP ' + put.status + ' ' + await put.text()); process.exit(1); }
console.log(`Restored entries for ${who(uid)} on "${labTitle(labId)}" from backup ${backup} (${Object.keys(row.data || {}).length} fields, saved ${row.updated_at})${live ? ' — replaced the live row' : ''}.`);
console.log('The student sees it after reloading the lab; their browser copy is merged by time, so a newer local copy on their device would still win.');
