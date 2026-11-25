// Materials list: the parts that need no network (tested by scripts/materials-test.mjs with plain node).
//
//   materialsLines(content, format)  the material lines of one lab's Materials section
//   numberLines(labs)                every line of every lab, numbered from 1
//   settle(entries, lines)           Claude's entries, repaired so that no line is left out
//   fingerprint(...)                 what the list was built from; unchanged fingerprint = no model call
//
// A lab's Materials section is the part under the first heading whose text starts with "Materials" ("# Materials",
// "## Materials and equipment"), up to the next heading of the same or a higher level (or the end of its tab). In it:
//   * every list item ("- [ ] 50 mL beaker", "- thermometer", "1. ruler") is one material, at any indent;
//   * a bold line ("**Chemicals**") or a deeper heading ("## Chemicals") is the label of the items that follow;
//   * anything else (paragraphs, a \safety{ … } block, tables) is not a material and is left out.

export type Line = { text: string; group: string };
export type Numbered = { n: number; lab_id: string; text: string; group: string };
export type Source = { lab_id: string; text: string; group: string };
export type Item = { name: string; category: string; sources: Source[]; unmerged?: boolean };

export const CATEGORIES = ["Chemicals", "Equipment"];
export const MAX_LINES = 1500;

const HEADING = /^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/;
const BULLET = /^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s*)?(.*\S)\s*$/;
const BOLD_LINE = /^\s*(?:\*\*|__)(.+?)(?:\*\*|__)\s*:?\s*$/;
const BLOCK_START = /^\s*\\[a-zA-Z]+(?:\[[^\]]*\])?\{/;   // a line that starts a command, e.g. "\safety{"; it is a block when its braces stay open
const BLOCK_CLOSE = /^\s*\}\s*$/;
const net = (row: string) => { const s = row.replace(/\\[{}]/g, ""); return (s.match(/\{/g) || []).length - (s.match(/\}/g) || []).length; };
const label = (s: string) => s.replace(/[*_`]/g, "").replace(/:\s*$/, "").trim();

function fromLabFile(src: string): { found: boolean; lines: Line[] } {
  const rows = String(src || "").replace(/\r\n?/g, "\n").split("\n");
  let start = -1, level = 0;
  for (let i = 0; i < rows.length; i++) {
    const h = rows[i].match(HEADING);
    if (h && /^materials\b/i.test(label(h[2]))) { start = i; level = h[1].length; break; }
  }
  if (start < 0) return { found: false, lines: [] };
  const lines: Line[] = []; let group = "", depth = 0;
  for (let i = start + 1; i < rows.length; i++) {
    const row = rows[i];
    if (depth > 0) { depth = Math.max(0, depth + net(row)); continue; }   // inside a block such as \safety{ … }: not materials
    if (BLOCK_CLOSE.test(row)) break;                      // the "}" that closes the tab this section sits in
    if (/^\s*\\(tab|report)\b/.test(row)) break;
    if (BLOCK_START.test(row) && net(row) > 0) { depth = net(row); continue; }
    const h = row.match(HEADING);
    if (h) { if (h[1].length <= level) break; group = label(h[2]); continue; }
    const b = row.match(BULLET);
    if (b) { lines.push({ text: b[1].trim(), group }); continue; }
    const bold = row.match(BOLD_LINE);
    if (bold) { group = label(bold[1]); continue; }
    // a wrapped list item: indented text straight after an item belongs to that item
    if (/^\s{2,}\S/.test(row) && lines.length && i > 0 && rows[i - 1].trim()) { lines[lines.length - 1].text += " " + row.trim(); continue; }
  }
  return { found: true, lines };
}

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'", apos: "'", nbsp: " " };
const plain = (html: string) => html.replace(/<[^>]*>/g, "").replace(/&(#?\w+);/g, (m, k) => ENTITIES[k] ?? (/^#\d+$/.test(k) ? String.fromCodePoint(Number(k.slice(1))) : m)).replace(/\s+/g, " ").trim();

function fromHtml(src: string): { found: boolean; lines: Line[] } {
  const html = String(src || "");
  const head = /<h([1-6])\b[^>]*>([\s\S]*?)<\/h\1>/gi;
  let m: RegExpExecArray | null, from = -1, level = 0;
  while ((m = head.exec(html))) { if (/^materials\b/i.test(plain(m[2]))) { from = head.lastIndex; level = Number(m[1]); break; } }
  if (from < 0) return { found: false, lines: [] };
  let to = html.length;
  while ((m = head.exec(html))) { if (Number(m[1]) <= level) { to = m.index; break; } }
  const part = html.slice(from, to), lines: Line[] = []; let group = "";
  const piece = /<li\b[^>]*>([\s\S]*?)<\/li>|<h[1-6]\b[^>]*>([\s\S]*?)<\/h[1-6]>|<p\b[^>]*>\s*<(?:strong|b)\b[^>]*>([\s\S]*?)<\/(?:strong|b)>\s*:?\s*<\/p>/gi;
  while ((m = piece.exec(part))) {
    if (m[1] !== undefined) { const t = plain(m[1]); if (t) lines.push({ text: t, group }); }
    else group = label(plain(m[2] ?? m[3] ?? ""));
  }
  return { found: true, lines };
}

export function materialsLines(content: string | null, format: string | null): { found: boolean; lines: Line[] } {
  return format === "labtags" ? fromLabFile(content || "") : fromHtml(content || "");
}

export function numberLines(labs: { lab_id: string; lines: Line[] }[]): Numbered[] {
  const out: Numbered[] = [];
  for (const lab of labs) for (const l of lab.lines) out.push({ n: out.length + 1, lab_id: lab.lab_id, text: l.text, group: l.group });
  return out;
}

// Claude answers with entries that point at line numbers. Whatever it answers, the stored list holds every line at
// least once: a number that does not exist is dropped, a number repeated inside one entry counts once, an entry left
// with no line is dropped, and a line no entry took becomes an entry of its own, marked unmerged. No material is ever
// lost. A line may sit in several entries: that is how a line naming several things ("goggles and gloves") is listed
// under each of them.
export function settle(entries: { name?: unknown; category?: unknown; lines?: unknown }[], lines: Numbered[]): { items: Item[]; unmerged: number } {
  const byN = new Map(lines.map((l) => [l.n, l]));
  const taken = new Set<number>(), items: Item[] = [];
  for (const e of Array.isArray(entries) ? entries : []) {
    const name = String(e?.name ?? "").replace(/\s+/g, " ").trim();
    const own: Numbered[] = [];
    for (const raw of Array.isArray(e?.lines) ? e.lines : []) {
      const n = Number(raw);
      if (!Number.isInteger(n) || !byN.has(n) || own.some((l) => l.n === n)) continue;
      taken.add(n); own.push(byN.get(n)!);
    }
    if (!own.length) continue;
    const category = CATEGORIES.includes(String(e?.category)) ? String(e.category) : guessCategory(own);
    items.push({ name: name || own[0].text, category, sources: own.map((l) => ({ lab_id: l.lab_id, text: l.text, group: l.group })) });
  }
  let unmerged = 0;
  for (const l of lines) {
    if (taken.has(l.n)) continue;
    unmerged++;
    items.push({ name: l.text, category: guessCategory([l]), sources: [{ lab_id: l.lab_id, text: l.text, group: l.group }], unmerged: true });
  }
  items.sort((a, b) => (CATEGORIES.indexOf(a.category) - CATEGORIES.indexOf(b.category)) || a.name.localeCompare(b.name, "en", { sensitivity: "base", numeric: true }));
  return { items, unmerged };
}
function guessCategory(own: { group: string }[]): string {
  return own.some((l) => /chemical|reagent|solution|substance/i.test(l.group)) ? "Chemicals" : "Equipment";
}

export async function fingerprint(version: string, model: string, labs: { lab_id: string; lines: Line[] }[]): Promise<string> {
  const basis = JSON.stringify([version, model, [...labs].sort((a, b) => a.lab_id.localeCompare(b.lab_id)).map((l) => [l.lab_id, l.lines.map((x) => [x.group, x.text])])]);
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(basis));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ---------- what Claude is asked ----------
export const PROMPT_VERSION = "2";
export const SYSTEM_PROMPT = `You merge the materials lists of several chemistry labs into one cumulative list, for the person who has to gather everything for the semester. The labs are done one at a time, so one item can be reused from lab to lab.

You are given numbered lines. Each line is one list item exactly as one lab's Materials section words it, with the lab it comes from and the label it sat under in that lab (usually Chemicals or Equipment).

Return the cumulative list: one entry for each distinct thing to obtain. The reader's main complaint about a list like this is the same thing appearing several times, so merge wherever one item really does the job.

Merging:
- Lines that call for the same thing become one entry, however differently the labs word it. "50 mL clear beaker" in one lab and "50 mL glass beaker" in another are one beaker and must not appear twice.
- More generally, lines belong in one entry whenever a single item, or a single purchase, would serve every one of them. Labs describe the same tool with different amounts of detail: "Thermometer", "Thermometer reading to 0.1 °C" and "Digital thermometer reading to 0.1 °C with a metal stem" are served by one thermometer that meets the most demanding line. "Beaker, 250 mL or larger" is served by the 250 mL beaker another lab asks for.
- Keep lines apart when one item could not serve both: a size or capacity that differs where the size matters (a 50 mL beaker and a 250 mL beaker), a different concentration or grade (3% and 30% hydrogen peroxide), a different substance (table salt and Epsom salt; distilled water where a lab requires distilled, and tap water), or requirements that exclude each other (a foam cup, and a cup that must not be foam).
- When you cannot tell whether one item would serve both lines, keep them apart. A near-duplicate costs the reader a second look; a wrong merge means something is missing on lab day.
- A line that offers alternatives for one job ("wire cutter, pliers or multitool") is one thing and goes in one entry.
- A line that names several separate things to obtain ("safety goggles and gloves"; "beaker, metal spoon, lighter") belongs in the entry for each of those things: put its number in every one of them. That is the only case in which a line number appears in more than one entry.
- Every line number appears in at least one entry. An entry always has at least one line.

Naming an entry:
- Name it the way a supply list would: the item with its size, capacity or concentration, in the standard term for it. Where the labs word the same thing loosely, give the standard, fully specific name: a "50 mL clear beaker" and a "50 mL glass beaker" are a "50 mL borosilicate glass beaker"; "baking soda" is "Sodium bicarbonate (baking soda)".
- When an entry merges lines with different amounts of detail, the name carries every requirement the lines state, so that the one item named serves all of them ("Digital thermometer, 0.1 °C, metal stem").
- Do not add a size, quantity, concentration, requirement or brand that no line states.
- Leave out amounts needed, counts, shopping advice, substitutions and instructions. The reader sees the labs' original lines under your entry, so nothing is lost by keeping the name short.
- For a line of alternatives, name what the item is used as and keep the alternatives short ("Wire cutter or similar cutting tool").

Category: "Chemicals" for substances that are used in the lab (chemicals, solutions, household substances, foods, water, ice); "Equipment" for everything else, including glassware, tools, containers, safety gear and paper goods. The label a line sat under is usually right.

When a previous list is given, an entry that is the same thing as a previous entry, and covers the same requirements, keeps that previous name exactly, so the list does not change wording from one update to the next.`;

export const OUTPUT_SCHEMA = {
  type: "object",
  properties: {
    items: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          category: { type: "string", enum: CATEGORIES },
          lines: { type: "array", items: { type: "integer" } },
        },
        required: ["name", "category", "lines"],
        additionalProperties: false,
      },
    },
  },
  required: ["items"],
  additionalProperties: false,
};

export function userMessage(lines: Numbered[], titles: Record<string, string>, previous: { name: string; category: string }[]): string {
  const ids = [...new Set(lines.map((l) => l.lab_id))];
  const tag = (id: string) => "L" + (ids.indexOf(id) + 1);
  const oneLine = (s: string) => s.replace(/\s+/g, " ").trim();
  const out = ["Labs:", ...ids.map((id) => `${tag(id)} = ${oneLine(titles[id] || id)}`), "", "Lines (number | lab | label in that lab | the lab's wording):",
    ...lines.map((l) => `${l.n} | ${tag(l.lab_id)} | ${l.group || "-"} | ${oneLine(l.text)}`)];
  if (previous.length) out.push("", "Previous list (keep these names where the entry is the same thing):", ...previous.map((p) => `- ${p.category}: ${oneLine(p.name)}`));
  return out.join("\n");
}
