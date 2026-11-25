// Materials list — Supabase Edge Function (admin only).
// The admin page keeps lists of ticked labs in public.materials_lists. One POST { action: "refresh", list_id } brings a
// list up to date: the function reads the ticked labs' Materials sections (lab files only, never student work), and if
// their material lines differ from what the list was last built from, it asks Claude to merge them into one cumulative
// list with no repeats and stores the result. Nothing changed = no model call and no cost.
//
// The code, not the model, decides which lines exist and guarantees that none is left out of the list (lib.ts).
//
// Deploy:  npx supabase functions deploy materials --project-ref nioebkjtrweyxvboajyv
// Secrets: ANTHROPIC_API_KEY (the one the owner set for Socratic 1). SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are provided.

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";
import { fingerprint, materialsLines, MAX_LINES, numberLines, OUTPUT_SCHEMA, PROMPT_VERSION, settle, SYSTEM_PROMPT, userMessage } from "./lib.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (code: number, body: unknown) => new Response(JSON.stringify(body), { status: code, headers: { ...CORS, "Content-Type": "application/json" } });

const MODEL = "claude-opus-5-5";
const EFFORT = "medium";
// $ per million tokens: input, output (the same table as the socratic function).
const PRICES: Record<string, { in: number; out: number }> = {
  "claude-opus-5-5": { in: 4.0, out: 20.0 },
  "claude-sonnet-5-5": { in: 2.0, out: 10.0 },
  "claude-haiku-5-5": { in: 0.10, out: 0.50 },
};
const costOf = (model: string, usage: any) => { const p = PRICES[model] || PRICES[MODEL]; return ((usage?.input_tokens || 0) * p.in + (usage?.output_tokens || 0) * p.out) / 1e6; };

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
// The key as the owner set it; a doubled "sk-ant-" (pasted after a template's prefix) and stray whitespace are forgiven.
const apiKey = () => (Deno.env.get("ANTHROPIC_API_KEY") || "").trim().replace(/^sk-ant-(?=sk-ant-)/, "");
const anthropic = new Anthropic({ apiKey: apiKey() });

function sseResponse(run: (send: (o: unknown) => void) => Promise<void>) {
  const enc = new TextEncoder();
  const body = new ReadableStream({
    async start(controller) {
      const send = (o: unknown) => controller.enqueue(enc.encode(`data: ${JSON.stringify(o)}\n\n`));
      try { await run(send); } catch (e) { console.error(e); send({ type: "error", message: (e as Error).message || String(e) }); }
      controller.close();
    },
  });
  return new Response(body, { headers: { ...CORS, "Content-Type": "text/event-stream", "Cache-Control": "no-cache" } });
}

async function merge(lines: ReturnType<typeof numberLines>, titles: Record<string, string>, previous: { name: string; category: string }[]) {
  const params: any = {
    model: MODEL, max_tokens: 32000,
    system: SYSTEM_PROMPT,
    messages: [{ role: "user", content: userMessage(lines, titles, previous) }],
    output_config: { effort: EFFORT, format: { type: "json_schema", schema: OUTPUT_SCHEMA } },
    betas: ["server-side-fallback-2026-07-01"], fallbacks: "default",   // a safety-classifier decline is retried server-side on the recommended model
  };
  const final: any = await (anthropic as any).beta.messages.stream(params).finalMessage();
  if (final.stop_reason === "refusal") throw new Error("Claude declined to read these lines. Nothing was changed.");
  if (final.stop_reason === "max_tokens") throw new Error("The list is too long for one reply. Nothing was changed.");
  const text = (final.content || []).filter((b: any) => b.type === "text").map((b: any) => b.text).join("");
  let parsed: any; try { parsed = JSON.parse(text); } catch { throw new Error("Claude's reply could not be read. Nothing was changed; try again."); }
  return { entries: Array.isArray(parsed?.items) ? parsed.items : [], model: String(final.model || MODEL), usage: final.usage || {} };
}

async function refresh(listId: string, force: boolean, send: (o: unknown) => void) {
  const { data: list, error } = await admin.from("materials_lists").select("*").eq("id", listId).maybeSingle();
  if (error) throw error;
  if (!list) throw new Error("That list no longer exists.");
  const want: string[] = [...new Set((list.lab_ids || []).map(String))];
  const { data: labRows, error: e1 } = want.length ? await admin.from("labs").select("id,title").in("id", want) : { data: [], error: null };
  if (e1) throw e1;
  const titles: Record<string, string> = {}; for (const l of labRows || []) titles[l.id] = l.title;
  const here = want.filter((id) => id in titles);          // a ticked lab that was deleted since is simply not read
  const { data: content, error: e2 } = here.length ? await admin.from("lab_content").select("lab_id,content,format").in("lab_id", here) : { data: [], error: null };
  if (e2) throw e2;
  const byLab = new Map((content || []).map((c: any) => [c.lab_id, c]));

  const labs: { lab_id: string; lines: { text: string; group: string }[] }[] = [], missing: string[] = [], empty: string[] = [];
  for (const id of here) {
    const c: any = byLab.get(id);
    const r = c ? materialsLines(c.content, c.format) : { found: false, lines: [] };
    if (!r.found) missing.push(id); else if (!r.lines.length) empty.push(id); else labs.push({ lab_id: id, lines: r.lines });
  }
  const numbered = numberLines(labs);
  if (numbered.length > MAX_LINES) throw new Error(`These labs list ${numbered.length} materials between them; the most one list can hold is ${MAX_LINES}. Untick some labs.`);
  const hash = await fingerprint(PROMPT_VERSION, MODEL, labs);
  const report = { read: labs.map((l) => ({ lab_id: l.lab_id, lines: l.lines.length })), missing, empty, gone: want.filter((id) => !(id in titles)), lines: numbered.length, unmerged: 0 };

  if (!force && list.source_hash === hash) {               // the list already holds exactly these lines
    if (JSON.stringify({ ...(list.report || {}), unmerged: 0 }) !== JSON.stringify(report)) {   // only the side notes moved (e.g. a ticked lab has no Materials section)
      const kept = { ...report, unmerged: Number(list.report?.unmerged || 0) };
      await admin.from("materials_lists").update({ report: kept }).eq("id", listId);
      list.report = kept;
    }
    return send({ type: "done", changed: false, list });
  }

  let items: unknown[] = [], model: string | null = null, cost = 0;
  if (numbered.length) {
    if (!apiKey()) throw new Error("The site's Claude key is not set (the ANTHROPIC_API_KEY secret).");
    send({ type: "delta", text: "building" });
    const previous = (Array.isArray(list.items) ? list.items : []).filter((it: any) => it && !it.unmerged && it.name).map((it: any) => ({ name: String(it.name), category: String(it.category || "") }));
    const alive = setInterval(() => send({ type: "delta", text: "building" }), 15000);   // the reply can take a minute or two; keep the connection from idling out
    let r; try { r = await merge(numbered, titles, previous); } finally { clearInterval(alive); }
    const settled = settle(r.entries, numbered);
    items = settled.items; report.unmerged = settled.unmerged; model = r.model; cost = costOf(r.model, r.usage);
  }
  const row = { items, report, source_hash: hash, model, cost, built_at: new Date().toISOString() };
  const { data: saved, error: e3 } = await admin.from("materials_lists").update(row).eq("id", listId).select("*").maybeSingle();
  if (e3) throw e3;
  if (!saved) throw new Error("That list was deleted while it was being built.");
  send({ type: "done", changed: true, list: saved });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "POST only" });
  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return json(401, { error: "sign in first" });
  const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) return json(401, { error: "sign in first" });
  if ((user.app_metadata as any)?.role !== "admin") return json(403, { error: "admins only" });
  let body: any = {}; try { body = await req.json(); } catch { return json(400, { error: "bad json" }); }
  if (String(body.action || "") !== "refresh") return json(400, { error: "unknown action" });
  const listId = String(body.list_id || "");
  if (!/^ml-[0-9]{10,16}$/.test(listId)) return json(400, { error: "bad list id" });
  return sseResponse((send) => refresh(listId, body.force === true, send));
});
