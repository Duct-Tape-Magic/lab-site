#!/usr/bin/env node
// Full backup of student work and site content: every table in TABLES plus every photo/file in the private bucket.
//   node scripts/backup.mjs            → new dated folder under "Lab Site Backups" (next to the project), prints the counts
//   node scripts/backup.mjs --verify   → after writing, re-reads the folder and checks every row and file is there
// Photos are kept once, by path, in "Lab Site Backups/files-store"; each dated backup carries a manifest of the paths and sizes
// as they were at that moment, so a photo deleted later is still restorable from the store.
import fs from 'node:fs';
import path from 'node:path';
import { loadKey, fetchAll, listBucket, downloadObject, stamp, TABLES, BACKUP_ROOT } from './backup-lib.mjs';

const key = loadKey();
const name = stamp(), dir = path.join(BACKUP_ROOT, name), store = path.join(BACKUP_ROOT, 'files-store');
fs.mkdirSync(path.join(dir, 'tables'), { recursive: true }); fs.mkdirSync(store, { recursive: true });

const counts = {};
for (const t of TABLES) {
  const rows = await fetchAll(key, t);
  fs.writeFileSync(path.join(dir, 'tables', t + '.json'), JSON.stringify(rows));
  counts[t] = rows.length;
}
const entries = JSON.parse(fs.readFileSync(path.join(dir, 'tables', 'lab_entries.json'), 'utf8'));
const students = new Set(entries.map(r => r.user_id)), labs = new Set(entries.map(r => r.lab_id));

const files = await listBucket(key, '');
let downloaded = 0, reused = 0, bytes = 0;
for (const f of files) {
  const local = path.join(store, f.path);
  if (fs.existsSync(local) && (f.size == null || fs.statSync(local).size === f.size)) { reused++; continue; }
  const buf = await downloadObject(key, f.path);
  fs.mkdirSync(path.dirname(local), { recursive: true }); fs.writeFileSync(local, buf); downloaded++; bytes += buf.length;
}
fs.writeFileSync(path.join(dir, 'files.json'), JSON.stringify(files));
const summary = { backup: name, when: new Date().toISOString(), rows: counts, students_with_entries: students.size, labs_with_entries: labs.size, files: files.length, files_downloaded: downloaded, files_already_stored: reused, bytes_downloaded: bytes };
fs.writeFileSync(path.join(dir, 'summary.json'), JSON.stringify(summary, null, 2));

if (process.argv.includes('--verify')) {
  let bad = 0;
  for (const t of TABLES) { const n = JSON.parse(fs.readFileSync(path.join(dir, 'tables', t + '.json'), 'utf8')).length; if (n !== counts[t]) { console.error(`VERIFY: ${t} has ${n} rows on disk, expected ${counts[t]}`); bad++; } }
  for (const f of files) { const local = path.join(store, f.path); if (!fs.existsSync(local) || (f.size != null && fs.statSync(local).size !== f.size)) { console.error(`VERIFY: missing or wrong size: ${f.path}`); bad++; } }
  summary.verified = bad === 0; fs.writeFileSync(path.join(dir, 'summary.json'), JSON.stringify(summary, null, 2));
  if (bad) { console.error(`VERIFY FAILED: ${bad} problem(s)`); process.exit(1); }
}
console.log(`Backup ${name} written to ${dir}`);
console.log(`  students with entries: ${students.size}   labs with entries: ${labs.size}   lab_entries rows: ${counts.lab_entries}`);
console.log(`  photos/files in bucket: ${files.length} (${downloaded} downloaded now, ${reused} already stored)`);
console.log(`  other tables: ` + TABLES.filter(t => t !== 'lab_entries').map(t => `${t} ${counts[t]}`).join(', '));
if (summary.verified) console.log('  verified: every row and file re-read from disk');
