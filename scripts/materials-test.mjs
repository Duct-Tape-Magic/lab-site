// Checks the parts of the materials list that need no network: node scripts/materials-test.mjs
// (supabase/functions/materials/lib.ts: finding a lab's Materials lines, and keeping every line in exactly one entry.)
import { materialsLines, numberLines, settle, fingerprint, userMessage } from '../supabase/functions/materials/lib.ts';

let fails = 0;
const eq = (name, got, want) => { const a = JSON.stringify(got), b = JSON.stringify(want); if (a !== b) { fails++; console.log(`FAIL ${name}\n  got  ${a}\n  want ${b}`); } };
const texts = r => r.lines.map(l => l.text);

// ---- a lab file as the labs are written: bold labels, ticked items ----
const lab = `\\title{Kinetics}

# Equations

- [ ] not a material (wrong section)

# Materials

**Chemicals**

- [ ] Glycerin, 99% or higher: about 300 mL
- [ ] Hydrogen peroxide, 3%

**Equipment**

- [ ] 250 mL glass beaker (inside diameter about 65 mm)
- [x] Stopwatch (a phone is fine)
* Ruler, mm graduations
1. Thermometer

\\safety{
- Wear goggles.
Iodine stains.
}

Some sentence that is not a material.

| a | b |
|---|---|

# Safety

- [ ] not a material either
`;
const r1 = materialsLines(lab, 'labtags');
eq('found', r1.found, true);
eq('items', texts(r1), ['Glycerin, 99% or higher: about 300 mL', 'Hydrogen peroxide, 3%', '250 mL glass beaker (inside diameter about 65 mm)', 'Stopwatch (a phone is fine)', 'Ruler, mm graduations', 'Thermometer']);
eq('labels', r1.lines.map(l => l.group), ['Chemicals', 'Chemicals', 'Equipment', 'Equipment', 'Equipment', 'Equipment']);

// ---- headings ----
eq('no section', materialsLines('# Purpose\n\n- [ ] x\n', 'labtags'), { found: false, lines: [] });
eq('empty content', materialsLines(null, 'labtags'), { found: false, lines: [] });
eq('section with no items', materialsLines('# Materials\n\nNone needed.\n\n# Procedure\n- step', 'labtags'), { found: true, lines: [] });
eq('lower-level heading and longer title', texts(materialsLines('# Part 1\n## Materials and equipment\n- a\n### Glassware\n- b\n## Procedure\n- c\n', 'labtags')), ['a', 'b']);
eq('deeper heading is a label', materialsLines('## Materials\n### Glassware\n- b\n', 'labtags').lines, [{ text: 'b', group: 'Glassware' }]);
eq('not "Materials" mid-title', materialsLines('# Raw materials\n- a\n', 'labtags').found, false);
eq('last section of the file', texts(materialsLines('# Materials\n- a\n- b', 'labtags')), ['a', 'b']);
eq('windows line ends', texts(materialsLines('# Materials\r\n- a\r\n- b\r\n# Next\r\n- c', 'labtags')), ['a', 'b']);
eq('inside a tab: stops at the closing brace', texts(materialsLines('\\tab[name=Prep]{\n# Materials\n- a\n- b\n}\n\\tab[name=2]{\n- c\n}', 'labtags')), ['a', 'b']);
eq('stops at the next tab', texts(materialsLines('# Materials\n- a\n\\tab[name=2]{\n- c\n}', 'labtags')), ['a']);
eq('one-line command is not a block', texts(materialsLines('# Materials\n\\note{Buy early.}\n- a\n- b', 'labtags')), ['a', 'b']);
eq('block opened with text on its line', texts(materialsLines('# Materials\n- a\n\\safety{Wear goggles.\n- not a material\n}\n- b', 'labtags')), ['a', 'b']);
eq('math braces in an item', texts(materialsLines('# Materials\n- $\\ce{NaHCO3}$, 5 g\n- b', 'labtags')), ['$\\ce{NaHCO3}$, 5 g', 'b']);
eq('wrapped item', texts(materialsLines('# Materials\n- a long\n  line\n- b', 'labtags')), ['a long line', 'b']);
eq('nested items are items', texts(materialsLines('# Materials\n- kit\n  - part one\n  - part two', 'labtags')), ['kit', 'part one', 'part two']);

// ---- a rich-text (html) lab ----
const html = '<h2>Purpose</h2><ul><li>no</li></ul><h2>Materials</h2><p><strong>Chemicals</strong></p><ul><li>Vinegar &amp; water</li><li data-list="unchecked"><span>Baking&nbsp;soda</span></li></ul><p>Note.</p><h3>Equipment</h3><ol><li>Cup</li></ol><h2>Procedure</h2><ul><li>no</li></ul>';
eq('html', materialsLines(html, 'html').lines, [{ text: 'Vinegar & water', group: 'Chemicals' }, { text: 'Baking soda', group: 'Chemicals' }, { text: 'Cup', group: 'Equipment' }]);
eq('html without section', materialsLines('<p>hello</p>', 'html'), { found: false, lines: [] });

// ---- numbering and the every-line-once guarantee ----
const lines = numberLines([{ lab_id: 'A', lines: [{ text: '50 mL clear beaker', group: 'Equipment' }, { text: 'Vinegar', group: 'Chemicals' }] }, { lab_id: 'B', lines: [{ text: '50 mL glass beaker', group: 'Equipment' }, { text: 'Stopwatch', group: '' }, { text: 'Table salt', group: 'Chemicals' }] }]);
eq('numbers', lines.map(l => [l.n, l.lab_id]), [[1, 'A'], [2, 'A'], [3, 'B'], [4, 'B'], [5, 'B']]);
const good = settle([{ name: '50 mL borosilicate glass beaker', category: 'Equipment', lines: [1, 3] }, { name: 'White vinegar', category: 'Chemicals', lines: [2] }, { name: 'Stopwatch', category: 'Equipment', lines: [4] }, { name: 'Table salt', category: 'Chemicals', lines: [5] }], lines);
eq('merged: no repeats', good.items.map(i => [i.category, i.name, i.sources.map(s => s.lab_id).join('')]), [['Chemicals', 'Table salt', 'B'], ['Chemicals', 'White vinegar', 'A'], ['Equipment', '50 mL borosilicate glass beaker', 'AB'], ['Equipment', 'Stopwatch', 'B']]);
eq('merged: nothing unplaced', good.unmerged, 0);
const bad = settle([{ name: 'Beaker', category: 'Equipment', lines: [1, 3, 3, 99, 'x'] }, { name: 'Also beaker', category: 'Equipment', lines: [1] }, { name: 'Ghost', category: 'Nonsense', lines: [] }, { name: '', category: 'Nonsense', lines: [4] }], lines);
const all = bad.items.flatMap(i => i.sources.map(s => s.text)).sort();
eq('repair: every line exactly once', all, ['50 mL clear beaker', '50 mL glass beaker', 'Stopwatch', 'Table salt', 'Vinegar']);
eq('repair: unplaced lines become their own entries', [bad.unmerged, bad.items.filter(i => i.unmerged).map(i => [i.name, i.category])], [2, [['Table salt', 'Chemicals'], ['Vinegar', 'Chemicals']]]);
eq('repair: empty and duplicate entries dropped, blank name and bad category filled', bad.items.filter(i => !i.unmerged).map(i => [i.name, i.category]), [['Beaker', 'Equipment'], ['Stopwatch', 'Equipment']]);
eq('no reply at all: every line still listed', settle(null, lines).items.length, 5);

// ---- fingerprint: same lines = same print, whatever the lab order; any change of wording, label or lab = new print ----
const L = (id, ...t) => ({ lab_id: id, lines: t.map(text => ({ text, group: 'Equipment' })) });
const f = (...labs) => fingerprint('1', 'm', labs);
eq('print ignores lab order', await f(L('A', 'x'), L('B', 'y')), await f(L('B', 'y'), L('A', 'x')));
eq('print sees a reworded line', (await f(L('A', 'x'))) === (await f(L('A', 'x!'))), false);
eq('print sees a moved line', (await f(L('A', 'x'), L('B', 'y'))) === (await f(L('A', 'y'), L('B', 'x'))), false);
eq('print sees a removed lab', (await f(L('A', 'x'), L('B', 'y'))) === (await f(L('A', 'x'))), false);

// ---- what Claude is sent ----
const msg = userMessage(lines, { A: 'Kinetics', B: 'Density\nlab' }, [{ name: 'Stopwatch', category: 'Equipment' }]);
eq('message', msg.split('\n'), ['Labs:', 'L1 = Kinetics', 'L2 = Density lab', '', 'Lines (number | lab | label in that lab | the lab\'s wording):', '1 | L1 | Equipment | 50 mL clear beaker', '2 | L1 | Chemicals | Vinegar', '3 | L2 | Equipment | 50 mL glass beaker', '4 | L2 | - | Stopwatch', '5 | L2 | Chemicals | Table salt', '', 'Previous list (keep these names where the entry is the same thing):', '- Equipment: Stopwatch']);

console.log(fails ? `${fails} check(s) FAILED` : 'materials-test: all checks passed');
process.exit(fails ? 1 : 0);
