/**
 * K2 — the OUTSIDE dead-man: progress, not just liveness (docs/OUTSIDE-DEADMAN.md).
 *
 * The liveness steps in index.js page when a box stops pinging or the hub stops
 * pushing status. They cannot see a fleet that is alive and doing nothing: the
 * 09-19 hub-lease outage (29 min, no page), a merge conductor that merged 0 for
 * hours on an empty GraphQL budget, a share mirror frozen for two days, a
 * project that spent $643 in a week with no merge. This module judges PROGRESS
 * stamps the hub pushes (bin/progress-push.sh, from the jobs worker's
 * GET /api/progress/stamps) plus stamps pushed straight here from outside the
 * fleet (POST /api/stamp/<name>, with a dedicated STAMP_SECRET).
 *
 * DETERMINISTIC and LLM-free: pure rules over numbers. Every threshold arrives
 * as DATA — the settings rows on the hub's `progress-push` lane, pushed in the
 * payload's `cfg`, CLAMPED here to sane bounds and kept as the last good copy
 * (PROGRESS_CFG_KEY). A change to it pages once with the diff; three rejected
 * pushes in a row page once. With no config stored nothing is judged.
 *
 * Rules (each skipped when a source it reads is in the snapshot's `errors`):
 *   (a)  spend-without-progress, per (project, lane): priced spend in the short
 *        window >= spend_min_usd while that lane's progress stamp is older than
 *        spend_quiet_min (or absent). Stages map to lanes via cfg.stage_lanes;
 *        a stage mapped to `any` (or unmapped) is judged against the project's
 *        newest progress of any kind. Paused projects are skipped.
 *   (a2) spend-no-merge, per (project, window): for each cfg.nomerge window,
 *        spend >= its floor with no merge inside it. Paused projects skipped.
 *   (b)  silent stop, per (project, lane): work pending and no progress for >
 *        silent_mult x the lane's cadence. Only lanes WITH a cadence row are
 *        judged (triage has none by default: #2289 B2). Paused projects skip.
 *   (c)  watch the watchers: every detector in cfg.detectors must have a run
 *        newer than detector_mult x its cadence. Box-scope detectors are judged
 *        per watched box; hub-scope ones (cfg.detector_hub) by their NEWEST row
 *        across boxes, since a standby hub's row is stale by design.
 *        `progress-push` is the push itself: when IT is stale every other rule
 *        is held, because stale stamps prove nothing.
 *   Stamps from the snapshot are aged against the SNAPSHOT's receipt time
 *   (#2289 B3) — the push's own staleness has its own rule. Direct stamps are
 *   aged against the worker's clock, which wrote them.
 *   An `all_off` marker means the fleet is stopped on purpose: one
 *   `fleet:all-off` incident and nothing else is judged.
 *
 * Paging (#2289 B1): an incident opens only after 2 CONSECUTIVE failing ticks
 * (`pseen:<key>`); a clear sends one resolve and leaves a cooldown tombstone
 * (`pcool:<key>`) for repage_min, during which the same key never re-opens. An
 * open incident re-sends at most once per repage_min. `detector:progress-push`
 * is exempt from the confirm and the cooldown: its own limit absorbs missed
 * pushes, and a second hub outage right after a clear must still page. Everything is SEND FIRST:
 * KV records a page or a clear only when Telegram answered ok, so a failed send
 * is retried next tick instead of being remembered as delivered.
 *
 * KV layout:
 *   progress:snap         {ts, body}     last push (ts = this worker's clock on receipt)
 *   progress:cfg          {...}          last VALID cfg, clamped
 *   progress:cfg_rejects  {n, error}     consecutive rejected configs
 *   stamp:<name>          {ts}           direct stamps from outside the fleet
 *   pseen:<key>           {first, n}     consecutive failing ticks, not yet open
 *   pinc:<key>            {first, paged, text}   open incidents
 *   pcool:<key>           {until}        cooldown after a clear
 */

import { tg } from "./telegram.js";

export const PROGRESS_SNAP_KEY = "progress:snap";
export const PROGRESS_CFG_KEY = "progress:cfg";
export const CFG_REJECTS_KEY = "progress:cfg_rejects";
export const INCIDENT_PREFIX = "pinc:";
export const PENDING_PREFIX = "pseen:";
export const COOL_PREFIX = "pcool:";
export const STAMP_PREFIX = "stamp:";
export const NAME_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const STAGE_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/;
const PUSH = "progress-push";
const CONFIRM_TICKS = 2;
const REJECTS_PAGE_AT = 3;
const MSG_MAX = 3900; // Telegram caps a message at 4096 characters

// Sane bounds: an in-band value outside them is CLAMPED (and named), a value
// that is not a positive number rejects the whole config.
const BOUNDS = {
  spend_window_min: [5, 1440],
  spend_min_usd: [1, 100000],
  spend_quiet_min: [30, 10080],
  silent_mult: [1, 20],
  detector_mult: [1, 20],
  repage_min: [30, 10080],
};
const CADENCE_BOUNDS = [1, 10080];
const NOMERGE_MIN_BOUNDS = [60, 20160];
const NOMERGE_USD_BOUNDS = [1, 1000000];

const pos = (v) => typeof v === "number" && Number.isFinite(v) && v > 0;
const isObj = (v) => v && typeof v === "object" && !Array.isArray(v);

/** {cfg, error, clamped}: a config is all-or-nothing; in-band values clamp. */
export function validateCfg(raw) {
  const clamped = [];
  const fail = (error) => ({ cfg: null, error, clamped });
  if (!isObj(raw)) return fail("cfg missing");
  const clamp = (name, v, [lo, hi]) => {
    const c = Math.min(Math.max(v, lo), hi);
    if (c !== v) clamped.push(`${name} ${v}→${c}`);
    return c;
  };
  const out = {};
  for (const [f, b] of Object.entries(BOUNDS)) {
    if (!pos(raw[f])) return fail(`${f} must be a positive number`);
    out[f] = clamp(f, raw[f], b);
  }
  // [map, error]: a bad map rejects the whole config.
  const numMap = (field) => {
    const m = raw[field];
    if (!isObj(m)) return [null, `${field} must be an object`];
    const o = {};
    for (const [k, v] of Object.entries(m)) {
      if (!NAME_RE.test(k)) return [null, `${field}: bad name "${k}"`];
      if (!pos(v)) return [null, `${field}.${k} must be a positive number`];
      o[k] = clamp(`${field}.${k}`, v, CADENCE_BOUNDS);
    }
    return [o, null];
  };
  const [cad, cadErr] = numMap("lane_cadence_min"); if (cadErr) return fail(cadErr);
  const [det, detErr] = numMap("detectors"); if (detErr) return fail(detErr);
  if (!det[PUSH]) return fail(`detectors must include ${PUSH} (the push itself)`);
  out.lane_cadence_min = cad;
  out.detectors = det;
  if (!isObj(raw.stage_lanes)) return fail("stage_lanes must be an object");
  out.stage_lanes = {};
  for (const [k, v] of Object.entries(raw.stage_lanes)) {
    if (!STAGE_RE.test(k) || typeof v !== "string" || !NAME_RE.test(v)) return fail(`stage_lanes: bad pair "${k}"`);
    out.stage_lanes[k] = v;
  }
  if (!isObj(raw.nomerge)) return fail("nomerge must be an object");
  out.nomerge = {};
  for (const [k, v] of Object.entries(raw.nomerge)) {
    if (!/^\d+$/.test(k) || !pos(Number(k))) return fail(`nomerge: bad window "${k}"`);
    if (!pos(v)) return fail(`nomerge.${k} must be a positive number`);
    const w = clamp(`nomerge window ${k}`, Number(k), NOMERGE_MIN_BOUNDS);
    out.nomerge[w] = clamp(`nomerge.${k}`, v, NOMERGE_USD_BOUNDS);
  }
  const hub = raw.detector_hub ?? [];
  if (!Array.isArray(hub) || hub.some((h) => typeof h !== "string" || !NAME_RE.test(h))) return fail("detector_hub must be a list of names");
  out.detector_hub = [...new Set(hub)].sort();
  return { cfg: out, error: null, clamped };
}
export const normalizeCfg = (raw) => validateCfg(raw).cfg;

/** Human diff of two configs, one line per changed leaf. */
export function cfgDiff(a, b) {
  const flat = (o, pre = "", acc = {}) => {
    for (const [k, v] of Object.entries(o || {})) {
      if (isObj(v)) flat(v, `${pre}${k}.`, acc);
      else acc[`${pre}${k}`] = Array.isArray(v) ? v.join(",") : String(v);
    }
    return acc;
  };
  const fa = flat(a); const fb = flat(b);
  return [...new Set([...Object.keys(fa), ...Object.keys(fb)])].sort()
    .filter((k) => fa[k] !== fb[k])
    .map((k) => `${k}: ${fa[k] ?? "—"} → ${fb[k] ?? "—"}`);
}

export function fmtAge(ms) {
  const m = Math.floor(ms / 60000);
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h${m % 60}m`;
}
const agoTxt = (a) => (a === null ? "never on record" : `${fmtAge(a)} ago`);

// Which stamp says a lane moved. (a) reads success; (b) reads any result.
const PROGRESS_STAMP = { triage: "triage", build: "build_ok", review: "review", merge: "merge", qa: "qa" };
const SILENT_STAMP = { triage: "triage", build: "build_result", merge: "merge" };
const ANY = ["triage", "build_ok", "review", "merge", "qa"];

/**
 * Pure: the incidents a snapshot shows. Sorted by key.
 *   snap    the hub's pushed body
 *   snapTs  when this worker received it (ms): the reference for its stamps
 *   cfg     normalizeCfg() output, or null (disarmed: returns [])
 *   stamps  { name: ms } direct stamps (worker clock)
 *   boxes   watched box names (boxes.json)
 *   now     the worker's clock (ms)
 */
export function evaluateProgress({ snap, snapTs, cfg, stamps = {}, boxes = [], now }) {
  if (!cfg || !isObj(snap)) return [];
  const out = [];
  const add = (key, text) => out.push({ key, text });
  const ref = Number.isFinite(snapTs) ? snapTs : now;
  const ageOf = (iso) => {
    if (typeof iso !== "string") return null;
    const t = Date.parse(iso);
    return Number.isFinite(t) ? ref - t : null;
  };
  const stampLine = (st) => `Stamps: ${["triage", "build_ok", "build_result", "review", "merge", "qa", "cost"]
    .map((k) => { const a = ageOf(st[k]); return `${k} ${a === null ? "never" : fmtAge(a)}`; }).join(" · ")}.`;

  // The push itself first. Stale: nothing else can be judged.
  const pushCad = cfg.detectors[PUSH];
  if (now - ref > cfg.detector_mult * pushCad * 60000) {
    const why = snap.all_off === true
      ? "The last push said the fleet is all-off, so this is expected until it is lifted."
      : "Every progress rule is held until it resumes: check the hub lease and cron on the hub.";
    return [{ key: `detector:${PUSH}`, text: `the hub's progress push is ${fmtAge(now - ref)} old (expected every ${pushCad}m, limit ${cfg.detector_mult}x). ${why}` }];
  }
  if (snap.all_off === true) {
    return [{ key: "fleet:all-off", text: "the fleet is all-off (flags/all-off or its row): every progress rule is paused until it is lifted." }];
  }

  const errors = Array.isArray(snap.errors) ? snap.errors.filter((e) => typeof e === "string" && NAME_RE.test(e)) : [];
  const unknown = (...names) => errors.includes("jobs-unreachable") || names.some((n) => errors.includes(n));
  for (const e of errors) {
    add(`source:${e}`, `progress source "${e}" was unreadable on the hub, so every rule that reads it is held. Unknown is not healthy.`);
  }

  const projects = isObj(snap.projects) ? snap.projects : {};
  for (const p of Object.keys(projects).sort()) {
    const d = isObj(projects[p]) ? projects[p] : {};
    if (d.paused === true) continue; // a paused project is an operator decision: no spend or silent rule
    const st = isObj(d.stamps) ? d.stamps : {};
    const age = (k) => ageOf(st[k]);

    // (a) spend without progress, per lane.
    if (!unknown("cost", "jobs", "verdicts", "merges") && isObj(d.spend)) {
      const byLane = {};
      for (const [stage, usd] of Object.entries(d.spend)) {
        const n = Number(usd);
        if (!Number.isFinite(n)) continue;
        const lane = cfg.stage_lanes[stage] || "any";
        byLane[lane] = (byLane[lane] || 0) + n;
      }
      for (const lane of Object.keys(byLane).sort()) {
        const usd = byLane[lane];
        if (usd < cfg.spend_min_usd) continue;
        let a;
        if (PROGRESS_STAMP[lane]) a = age(PROGRESS_STAMP[lane]);
        else {
          const ages = ANY.map(age).filter((x) => x !== null);
          a = ages.length ? Math.min(...ages) : null;
        }
        if (a === null || a > cfg.spend_quiet_min * 60000) {
          add(`spend:${p}:${lane}`,
            `${p} ${lane}: spent $${usd.toFixed(2)} in the last ${cfg.spend_window_min}m and its progress has not moved (last ${lane === "any" ? "progress of any kind" : lane} ${agoTxt(a)}, limit ${fmtAge(cfg.spend_quiet_min * 60000)}). ${stampLine(st)}`);
        }
      }
    }

    // (a2) spend with no merge, per configured window.
    if (!unknown("cost", "merges") && isObj(d.spend_long)) {
      for (const w of Object.keys(cfg.nomerge).map(Number).sort((x, y) => x - y)) {
        const usd = Number(d.spend_long[w]);
        if (!Number.isFinite(usd) || usd < cfg.nomerge[w]) continue;
        const a = age("merge");
        if (a === null || a > w * 60000) {
          add(`spend-nomerge:${p}:${w}`,
            `${p}: spent $${usd.toFixed(2)} in the last ${fmtAge(w * 60000)} with no merge in that time (last merge ${agoTxt(a)}, floor $${cfg.nomerge[w]}). ${stampLine(st)}`);
        }
      }
    }

    // (b) silent stop: work waiting, lane not moving. Only lanes with a cadence.
    if (!unknown("queues", "jobs", "merges")) {
      const pending = isObj(d.pending) ? d.pending : {};
      for (const lane of Object.keys(SILENT_STAMP)) {
        const cad = cfg.lane_cadence_min[lane];
        if (!cad) continue;
        const n = Number(pending[lane]);
        if (pending[lane] === null || !Number.isFinite(n) || n <= 0) continue;
        const a = age(SILENT_STAMP[lane]);
        const limit = cfg.silent_mult * cad * 60000;
        if (a === null || a > limit) {
          add(`silent:${p}:${lane}`,
            `${p} ${lane}: ${n} pending and the lane has not moved (last ${lane} ${agoTxt(a)}, limit ${cfg.silent_mult}x${cad}m = ${fmtAge(limit)}). ${stampLine(st)}`);
        }
      }
    }
  }

  // (c) watch the watchers.
  const detRows = Array.isArray(snap.detectors) ? snap.detectors : [];
  for (const name of Object.keys(cfg.detectors).sort()) {
    if (name === PUSH) continue;
    const cad = cfg.detectors[name];
    const limit = cfg.detector_mult * cad * 60000;
    const hubScope = cfg.detector_hub.includes(name);
    const judged = []; // {box, age, where}
    if (Number.isFinite(stamps[name])) judged.push({ box: null, age: now - stamps[name] });
    let known = [];
    let alien = null;
    let paused = 0;
    if (!unknown("detectors")) {
      for (const r of detRows) {
        if (!isObj(r) || r.lane !== name) continue;
        if (r.outcome === "paused") { paused++; continue; }
        const a = ageOf(r.at);
        if (!boxes.includes(r.box)) {
          if (a !== null && (!alien || a < alien.age)) alien = { box: String(r.box), age: a };
          continue;
        }
        known.push({ box: r.box, age: a });
      }
    } else if (!judged.length) {
      continue; // its source is unknown, already paged as source:detectors
    }
    if (hubScope && known.length) {
      // One hub does this job at a time: the newest row is the detector.
      const best = known.filter((k) => k.age !== null).sort((x, y) => x.age - y.age)[0] || known[0];
      known = [{ box: null, age: best.age, where: best.box }];
    }
    judged.push(...known);
    if (!known.length && alien) judged.push({ box: null, age: alien.age, where: `${alien.box}, not a watched box` });
    if (!judged.length) {
      if (paused) continue; // an operator paused it: a decision, not a death
      add(`detector:${name}`, `detector ${name}: no run on record. It is expected every ${cad}m.`);
      continue;
    }
    for (const r of judged) {
      if (r.age === null || r.age > limit) {
        add(r.box ? `detector:${name}@${r.box}` : `detector:${name}`,
          `detector ${name}${r.box ? ` on ${r.box}` : r.where ? ` (last seen on ${r.where})` : ""}: last run ${agoTxt(r.age)} (expected every ${cad}m, limit ${cfg.detector_mult}x = ${fmtAge(limit)}). The thing watching this part of the fleet has stopped.`);
      }
    }
  }

  return out.sort((x, y) => (x.key < y.key ? -1 : x.key > y.key ? 1 : 0));
}

async function listKeys(env, prefix) {
  const out = [];
  let cursor;
  for (;;) {
    const page = await env.KV.list({ prefix, ...(cursor ? { cursor } : {}) });
    for (const k of page.keys) out.push(k.name);
    if (page.list_complete !== false || !page.cursor) break;
    cursor = page.cursor;
  }
  return out;
}
const readJson = async (env, k) => { try { return JSON.parse(await env.KV.get(k)); } catch { return null; } };
async function readPrefix(env, prefix) {
  const m = new Map();
  for (const k of await listKeys(env, prefix)) m.set(k.slice(prefix.length), (await readJson(env, k)) || {});
  return m;
}

export async function readStamps(env) {
  const stamps = {};
  for (const [name, v] of await readPrefix(env, STAMP_PREFIX)) if (Number.isFinite(v.ts)) stamps[name] = v.ts;
  return stamps;
}

function oneMessage(head, lines) {
  let msg = head;
  let shown = 0;
  for (const l of lines) {
    if (msg.length + l.length + 1 > MSG_MAX) break;
    msg += `\n${l}`;
    shown++;
  }
  if (shown < lines.length) msg += `\n… +${lines.length - shown} more (GET /api/progress lists them all)`;
  return msg;
}

/** The cron step: judge, confirm, page what is new or re-due, resolve what cleared. */
export async function progressTick(env, now, boxes, send = (text) => tg(env, text)) {
  const snapRow = await readJson(env, PROGRESS_SNAP_KEY);
  const cfg = normalizeCfg(await readJson(env, PROGRESS_CFG_KEY));
  if (!isObj(snapRow) || !isObj(snapRow.body) || !cfg) return { armed: false };

  const incidents = evaluateProgress({
    snap: snapRow.body, snapTs: snapRow.ts, cfg, stamps: await readStamps(env), boxes, now,
  });
  const cur = new Map(incidents.map((i) => [i.key, i]));
  const open = await readPrefix(env, INCIDENT_PREFIX);
  const seen = await readPrefix(env, PENDING_PREFIX);
  const cool = await readPrefix(env, COOL_PREFIX);
  const repageMs = cfg.repage_min * 60000;

  // Expired cooldowns go; a pending key that did not fail THIS tick resets.
  for (const [k, v] of cool) if (!(Number(v.until) > now)) { await env.KV.delete(COOL_PREFIX + k); cool.delete(k); }
  for (const k of seen.keys()) if (!cur.has(k) || open.has(k)) await env.KV.delete(PENDING_PREFIX + k);

  const opening = []; const repaging = [];
  for (const i of incidents) {
    const o = open.get(i.key);
    if (o) {
      if (!Number.isFinite(o.paged) || now - o.paged >= repageMs) repaging.push({ i, o });
      continue;
    }
    const s = seen.get(i.key);
    const n = (s && Number.isFinite(s.n) ? s.n : 0) + 1;
    const first = s && Number.isFinite(s.first) ? s.first : now;
    await env.KV.put(PENDING_PREFIX + i.key, JSON.stringify({ first, n }));
    // The push's own staleness is exempt from both (#2289 nit 1): its limit
    // (detector_mult x cadence) already absorbs missed pushes, and a cooldown
    // would hide a second hub outage inside the next repage window.
    const immediate = i.key === `detector:${PUSH}`;
    if (immediate || (n >= CONFIRM_TICKS && !cool.has(i.key))) opening.push({ i, first });
  }

  // A stale push holds everything else: its stamps cannot prove a clear.
  const held = cur.has(`detector:${PUSH}`);
  const clearing = [...open.entries()].sort()
    .filter(([k]) => !cur.has(k) && !(held && k !== `detector:${PUSH}`));

  let paged = 0; let resolved = 0;
  if (opening.length || repaging.length) {
    const lines = [
      ...opening.map(({ i }) => `• [${i.key}] ${i.text}`),
      ...repaging.map(({ i, o }) => `• [${i.key}] (still open, ${Number.isFinite(o.first) ? fmtAge(now - o.first) : "?"}) ${i.text}`),
    ];
    // SEND FIRST: KV records the page only when Telegram took it.
    if (await send(oneMessage(`🚨 PROGRESS (outside dead-man): ${lines.length} incident(s), no LLM in this path`, lines))) {
      for (const { i, first } of opening) {
        await env.KV.put(INCIDENT_PREFIX + i.key, JSON.stringify({ first, paged: now, text: i.text }));
        await env.KV.delete(PENDING_PREFIX + i.key);
      }
      for (const { i, o } of repaging) await env.KV.put(INCIDENT_PREFIX + i.key, JSON.stringify({ ...o, paged: now, text: i.text }));
      paged = lines.length;
    }
  }
  if (clearing.length) {
    const lines = clearing.map(([k, o]) => `• [${k}] (open ${Number.isFinite(o.first) ? fmtAge(now - o.first) : "?"})`);
    if (await send(oneMessage(`✅ PROGRESS cleared: ${lines.length}`, lines))) {
      for (const [k] of clearing) {
        await env.KV.delete(INCIDENT_PREFIX + k);
        if (k !== `detector:${PUSH}`) await env.KV.put(COOL_PREFIX + k, JSON.stringify({ until: now + repageMs }));
      }
      resolved = lines.length;
    }
  }
  return { armed: true, incidents: incidents.length, paged, resolved };
}

/**
 * POST /api/progress: store the snapshot; store the config when valid; page
 * once on any threshold change (with the diff) and once on the third rejected
 * config in a row. Returns the response text.
 */
export async function acceptPush(env, body, now, send = (text) => tg(env, text)) {
  await env.KV.put(PROGRESS_SNAP_KEY, JSON.stringify({ ts: now, body }));
  const v = validateCfg(body.cfg);
  if (!v.cfg) {
    const prev = await readJson(env, CFG_REJECTS_KEY);
    const n = (prev && Number.isFinite(prev.n) ? prev.n : 0) + 1;
    await env.KV.put(CFG_REJECTS_KEY, JSON.stringify({ n, error: v.error }));
    if (n === REJECTS_PAGE_AT) {
      await send(`⚙️ PROGRESS config rejected ${n} pushes in a row: ${v.error}. The last good config stays in force; fix the progress-push settings rows.`);
    }
    return `ok (cfg rejected: ${v.error}; the last good config stays in force)`;
  }
  await env.KV.delete(CFG_REJECTS_KEY);
  const old = normalizeCfg(await readJson(env, PROGRESS_CFG_KEY));
  const diff = old ? cfgDiff(old, v.cfg) : [];
  if (!old || diff.length) {
    const clampNote = v.clamped.length ? `\nclamped to bounds: ${v.clamped.join(", ")}` : "";
    const sent = await send(old
      ? oneMessage(`⚙️ PROGRESS thresholds changed (${diff.length}):`, diff) + clampNote
      : `⚙️ PROGRESS armed: the outside dead-man now judges progress (${Object.keys(v.cfg.detectors).length} detectors, repage ${v.cfg.repage_min}m).${clampNote}`);
    // SEND FIRST here too (#2289 nit 2): a threshold nobody was told about is
    // not put in force. The next push retries the page and the store.
    if (!sent) return "ok (cfg change not announced: Telegram failed; the previous config stays in force, retried next push)";
    await env.KV.put(PROGRESS_CFG_KEY, JSON.stringify(v.cfg));
  }
  return "ok";
}

/** POST /api/progress/dry-run: what this payload WOULD raise. Writes nothing. */
export async function dryRun(env, body, now, boxes) {
  const v = validateCfg(body.cfg);
  const asOf = Date.parse(body.as_of);
  const ref = Number.isFinite(asOf) ? asOf : now;
  const incidents = v.cfg
    ? evaluateProgress({ snap: body, snapTs: ref, cfg: v.cfg, stamps: await readStamps(env), boxes, now: ref })
    : [];
  const open = await readPrefix(env, INCIDENT_PREFIX);
  const cool = await readPrefix(env, COOL_PREFIX);
  return {
    cfg_ok: !!v.cfg, cfg_error: v.error, clamped: v.clamped,
    note: `a live incident needs ${CONFIRM_TICKS} consecutive failing ticks to page, and does not re-open inside its cooldown`,
    incidents: incidents.map((i) => ({ ...i, open: open.has(i.key), cooling: cool.has(i.key) })),
  };
}

/** GET /api/progress: what the watchdog knows, readable while the hub is down. */
export async function progressView(env, now) {
  const snapRow = await readJson(env, PROGRESS_SNAP_KEY);
  const stamps = await readStamps(env);
  const open = [];
  for (const [key, v] of await readPrefix(env, INCIDENT_PREFIX)) {
    open.push({ key, open_min: Number.isFinite(v.first) ? Math.floor((now - v.first) / 60000) : null, text: v.text ?? null });
  }
  return {
    snapshot_age_min: isObj(snapRow) && Number.isFinite(snapRow.ts) ? Math.floor((now - snapRow.ts) / 60000) : null,
    snapshot: isObj(snapRow) ? snapRow.body : null,
    cfg: await readJson(env, PROGRESS_CFG_KEY),
    cfg_rejects: await readJson(env, CFG_REJECTS_KEY),
    stamps: Object.fromEntries(Object.entries(stamps).map(([k, ts]) => [k, Math.floor((now - ts) / 60000)])),
    pending: [...(await readPrefix(env, PENDING_PREFIX)).keys()].sort(),
    cooling: [...(await readPrefix(env, COOL_PREFIX)).keys()].sort(),
    open: open.sort((a, b) => (a.key < b.key ? -1 : 1)),
  };
}
