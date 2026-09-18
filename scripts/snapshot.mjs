// Builds data/snapshot.json from the live Supabase project using the publishable key.
// Row-level security guarantees only public, published content comes back.
// Run by .github/workflows/snapshot.yml every hour; can also be run locally:
//   SUPABASE_URL=... SUPABASE_ANON_KEY=... node scripts/snapshot.mjs
import { writeFileSync, readFileSync, existsSync } from 'node:fs';

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_ANON_KEY;
if (!URL || !KEY) {
  console.error('SUPABASE_URL and SUPABASE_ANON_KEY are required');
  process.exit(1);
}

async function fetchTable(table, select = '*', order = null) {
  const rows = [];
  const page = 1000;
  for (let from = 0; ; from += page) {
    let q = `${URL}/rest/v1/${table}?select=${encodeURIComponent(select)}`;
    if (order) q += `&order=${order}`;
    const res = await fetch(q, {
      headers: {
        apikey: KEY,
        Authorization: `Bearer ${KEY}`,
        Range: `${from}-${from + page - 1}`,
        'Range-Unit': 'items'
      }
    });
    if (!res.ok && res.status !== 206) throw new Error(`${table}: HTTP ${res.status} ${await res.text()}`);
    const chunk = await res.json();
    rows.push(...chunk);
    if (chunk.length < page) break;
  }
  return rows;
}

const [folders, labs, lab_content, attachments, site_content] = await Promise.all([
  fetchTable('folders', '*', 'sort_order,name'),
  fetchTable('labs', '*', 'sort_order,title'),
  fetchTable('lab_content'),
  fetchTable('attachments', '*', 'sort_order,name'),
  fetchTable('site_content')
]);

const snapshot = { folders, labs, lab_content, attachments, site_content };
const body = JSON.stringify(snapshot);

const out = 'data/snapshot.json';
const previous = existsSync(out) ? readFileSync(out, 'utf8') : '';
// Compare without the timestamp so an unchanged site produces no commit.
if (previous === body) {
  console.log('Snapshot unchanged');
} else {
  writeFileSync(out, body);
  console.log(`Snapshot written: ${folders.length} folders, ${labs.length} labs, ${attachments.length} attachments`);
}
writeFileSync('data/last-run.txt', new Date().toISOString() + '\n');
