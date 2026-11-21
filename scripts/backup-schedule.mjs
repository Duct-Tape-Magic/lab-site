#!/usr/bin/env node
// The backup schedule on the owner's Mac (owner, 2026-11-21): a new verified backup every BACKUP_EVERY_DAYS, and no backup kept
// longer than KEEP_DAYS, so a student who deletes their account is gone from the backups too.
//   node scripts/backup-schedule.mjs install   → copy the backup scripts out of Dropbox and start the daily check
//   node scripts/backup-schedule.mjs status    → is it running, how old is the newest backup, the last lines of its log
//   node scripts/backup-schedule.mjs remove    → stop the daily check (backups already made stay where they are)
//   node scripts/backup-schedule.mjs run       → what the schedule runs: back up if one is due, then delete what has expired
//                                                (run --force backs up even when none is due; used to test the job)
// How it works: macOS (launchd) runs `run` once a day at 17:00, at the next wake if the Mac was asleep at 17:00, and at login.
// A failed backup stays due, so the next daily check tries again; nothing is deleted until a backup has verified. The job
// runs a COPY of these scripts kept in ~/.config/ohschemlabs/backup, because a background job is not reliably allowed to read
// files inside Dropbox. backup.mjs refreshes that copy whenever it is run from the project, so the two cannot drift apart.
// No AI is involved in a scheduled run: it is plain node, and it prints counts only.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { BACKUP_ROOT, KEEP_DAYS, BACKUP_EVERY_DAYS, listBackups, newestVerified, backupTime, expireBackups } from './backup-lib.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const LABEL = 'com.ohschemlabs.backup';
const INSTALLED = path.join(os.homedir(), '.config', 'ohschemlabs', 'backup');
const PLIST = path.join(os.homedir(), 'Library', 'LaunchAgents', LABEL + '.plist');
const LOG = path.join(BACKUP_ROOT, 'schedule.log');
const FILES = ['backup-lib.mjs', 'backup.mjs', 'backup-schedule.mjs'];
const scrub = s => String(s).replace(/sb_secret_[A-Za-z0-9_-]+/g, '[key]').replace(/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_.-]+/g, '[key]');

// Called by backup.mjs: when the project's scripts differ from the copy the schedule runs, bring the copy up to date.
export function refreshInstalled() {
  if (HERE === INSTALLED || !fs.existsSync(INSTALLED)) return '';
  const changed = FILES.filter(f => { const a = path.join(HERE, f), b = path.join(INSTALLED, f); return !fs.existsSync(b) || !fs.readFileSync(a).equals(fs.readFileSync(b)); });
  for (const f of changed) fs.copyFileSync(path.join(HERE, f), path.join(INSTALLED, f));
  return changed.length ? `scheduled copy of the backup scripts updated (${changed.join(', ')})` : '';
}

function log(line) { fs.mkdirSync(BACKUP_ROOT, { recursive: true }); fs.appendFileSync(LOG, `${new Date().toISOString()}  ${scrub(line)}\n`); console.log(scrub(line)); }
function notify(text) {   // a courtesy: the log has the line either way
  let ok = false; try { ok = spawnSync('/usr/bin/osascript', ['-e', `display notification ${JSON.stringify(text)} with title "Lab site backup"`], { timeout: 10000 }).status === 0; } catch (e) { /* ignore */ }
  if (!ok) log('(the Mac notification could not be shown)');
}
const ageDays = name => (Date.now() - backupTime(name)) / 864e5;
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function run() {
  const good = newestVerified();
  if (good && ageDays(good) < BACKUP_EVERY_DAYS - 0.25 && !process.argv.includes('--force')) {   // nothing due: only clear out what has expired
    try {
      const x = expireBackups();
      log(`no backup due (newest is ${good}); expiry: ${x.removed} backup(s) and ${x.files} stored photo(s) deleted, ${x.kept} kept${x.note ? '; NOTE: ' + x.note : ''}`);
    } catch (e) { log('EXPIRY FAILED, nothing deleted: ' + e.message); notify('Old backups could not be cleared. See schedule.log.'); process.exitCode = 1; }
    return;
  }
  let out = null;
  for (let attempt = 1; attempt <= 4; attempt++) {   // the Mac may have just woken with no network yet
    out = spawnSync(process.execPath, [path.join(HERE, 'backup.mjs'), '--verify'], { encoding: 'utf8', timeout: 30 * 60 * 1000 });
    if (out.status === 0) break;
    log(`backup attempt ${attempt} failed: ${(out.stderr || out.error?.message || 'no reason given').trim().split('\n').filter(l => l.trim() && !/^Node\.js v/.test(l)).pop() || 'no reason given'}`);
    if (attempt < 4) await sleep((+process.env.LAB_BACKUP_RETRY_SECONDS || 90) * 1000);   // the override exists for testing the failure path
  }
  if (out.status === 0) { for (const l of out.stdout.trim().split('\n')) log(l.trim()); return; }
  const last = newestVerified();
  log(`BACKUP FAILED. Newest verified backup: ${last || 'none'}. Nothing was deleted.`);
  notify(`The scheduled backup failed. Newest good backup: ${last || 'none'}.`);
  process.exitCode = 1;
}

function loaded() { return spawnSync('/bin/launchctl', ['print', `gui/${process.getuid()}/${LABEL}`], { encoding: 'utf8' }).status === 0; }
function status() {
  const all = listBackups(), good = newestVerified();
  console.log(`schedule: ${loaded() ? 'running (daily check at 17:00, or at the next wake if the Mac was asleep then, and at login)' : 'NOT running: node scripts/backup-schedule.mjs install'}`);
  console.log(`backups in ${BACKUP_ROOT}: ${all.length}${all.length ? ` (oldest ${all[0]}, newest ${all.at(-1)})` : ''}`);
  console.log(`newest verified backup: ${good ? `${good} (${ageDays(good).toFixed(1)} days old)` : 'none'}; a new one is made every ${BACKUP_EVERY_DAYS} days, each is deleted after ${KEEP_DAYS}`);
  if (fs.existsSync(LOG)) { console.log('last lines of the log:'); for (const l of fs.readFileSync(LOG, 'utf8').trim().split('\n').slice(-6)) console.log('  ' + l); }
}
function install() {
  if (HERE === INSTALLED) { console.error('Run install from the project folder, not from the installed copy.'); process.exit(1); }
  fs.mkdirSync(INSTALLED, { recursive: true }); fs.mkdirSync(path.dirname(PLIST), { recursive: true }); fs.mkdirSync(BACKUP_ROOT, { recursive: true });
  for (const f of FILES) fs.copyFileSync(path.join(HERE, f), path.join(INSTALLED, f));
  const x = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  fs.writeFileSync(PLIST, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key><array><string>${x(process.execPath)}</string><string>${x(path.join(INSTALLED, 'backup-schedule.mjs'))}</string><string>run</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>17</integer><key>Minute</key><integer>0</integer></dict>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>${x(path.join(INSTALLED, 'launchd.log'))}</string>
  <key>StandardErrorPath</key><string>${x(path.join(INSTALLED, 'launchd.log'))}</string>
</dict></plist>
`);
  const dom = `gui/${process.getuid()}`;
  spawnSync('/bin/launchctl', ['bootout', `${dom}/${LABEL}`]);   // replace an older copy of the job, if there is one
  const r = spawnSync('/bin/launchctl', ['bootstrap', dom, PLIST], { encoding: 'utf8' });
  if (r.status !== 0) { console.error('launchctl could not start the job: ' + (r.stderr || '').trim()); process.exit(1); }
  console.log(`installed: scripts in ${INSTALLED}, job ${LABEL}`);
  status();
}
function remove() {
  spawnSync('/bin/launchctl', ['bootout', `gui/${process.getuid()}/${LABEL}`]);
  if (fs.existsSync(PLIST)) fs.rmSync(PLIST);
  console.log('schedule removed. Backups already made are untouched.');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {   // run as a command, not imported by backup.mjs
  const cmd = process.argv[2];
  if (cmd === 'run') await run();
  else if (cmd === 'install') install();
  else if (cmd === 'remove') remove();
  else if (cmd === 'status') status();
  else { console.error('Usage: node scripts/backup-schedule.mjs install | status | remove | run'); process.exit(1); }
}
