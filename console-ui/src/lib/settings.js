// The SETTINGS screen's whole vocabulary, kept out of the component so the
// names it writes, the bounds it enforces and the order it asks in are all
// testable without a DOM.
//
// Two payloads meet here (issue #1132):
//   GET /api/lanes/registry  — catalog/lanes.json as the worker baked it. The
//                              DECLARATION: which lanes exist, what each one's
//                              switch is called, and what its knobs may be set
//                              to. Static between deploys.
//   GET /api/lanes/status[?project=] — the LIVE half: which switches are
//                              actually thrown, what each knob currently reads,
//                              and what the lane has cost today and over 7 days.
//
// The registry is the source of the lane LIST and of every bound. The status is
// the source of every VALUE. Where they disagree about which lanes exist, both
// are shown and the row says which side is missing — a lane that quietly
// vanishes from this page is the failure this page exists to prevent.

export const ACTOR = 'console';

// ─────────────────────────────────────────────────────────────────── tabs

// The hub plus one tab per project, and the project list comes from the STATUS
// payload — never a constant here. A hardcoded fleet is one more place to
// forget a project, and that is the mistake tests/fleet-projects-not-hardcoded
// exists because of.
// `held` is the last strip that a payload actually produced, and `activeTab` is
// where the operator is standing right now.
//
// WHY BOTH. useApi CLEARS `data` the moment its deps change, so from the click
// on a project tab until that project's status lands, the payload is null. A
// strip derived from null collapses to HUB alone — and if the project status
// then 404s it STAYS collapsed, stranding the operator on a screen with no way
// back to the tab they came from. The tab strip is the navigation; it does not
// get to disappear because one pane is loading. So a fresh payload wins, a
// missing one falls back to the last real strip, and the active tab is always
// in the list whether or not anything ever named it.
export function tabsFrom(status, held, activeTab) {
  const fromPayload = (status && Array.isArray(status.projects) ? status.projects : [])
    .map((p) => (typeof p === 'string' ? p : p && p.project))
    .filter(Boolean);
  const ids = fromPayload.length
    ? ['hub'].concat(fromPayload)
    : (Array.isArray(held) && held.length ? held.slice() : ['hub']);
  if (activeTab && !ids.includes(activeTab)) ids.push(activeTab);
  const seen = new Set();
  return ids.filter((id) => (seen.has(id) ? false : seen.add(id)))
    .map((id) => ({ id, label: id === 'hub' ? 'HUB' : id }));
}

export const isHub = (tab) => !tab || tab === 'hub';

// ─────────────────────────────────────────────────────────────────── rows

const num = (v) => (v === null || v === undefined || v === '' ? null : Number(v));

// UNKNOWN is a third state, and it is not OFF and it is not ON.
//
// `Boolean(s.off)` collapses a present row carrying `off: null` into `false`,
// which draws a live ON toggle for a lane whose switch was never read — and the
// operator's next move is to trust it. A switch that shows a state it did not
// read is worse than one that admits it does not know. Both row branches below
// go through this, so the rule exists once rather than twice.
const offState = (v) => (v === null || v === undefined || v === '' ? null : Boolean(v));

// A knob row: the registry's declaration with the live value folded in. The
// value falls back to the registry default rather than to blank, because an
// empty input reads as "this knob has no setting", which is never true.
function knobRow(decl, live) {
  const cur = live && Object.prototype.hasOwnProperty.call(live, decl.env) ? live[decl.env] : null;
  const value = cur && typeof cur === 'object' ? cur.value : cur;
  return {
    ...decl,
    value: value === undefined || value === null ? (decl.default ?? null) : value,
    source: (cur && typeof cur === 'object' && cur.source) || (value === undefined || value === null ? 'default' : null)
  };
}

export function laneHref(id, project) {
  const base = `/settings/${encodeURIComponent(id)}`;
  return isHub(project) ? base : `${base}?project=${encodeURIComponent(project)}`;
}

// One lane row: the registry's declaration with its live status entry `s`
// (null when the status never mentioned it) folded in. Shared by laneRows()
// and boxLaneRows() so both draw a lane the same way.
function laneRow(decl, s, project, scope) {
  return {
    id: decl.id,
    name: decl.name || decl.id,
    project,
    scope,
    script: decl.script || null,
    cadence: (s && s.cadence) || decl.cadence || null,
    switchName: flagName(decl.id, project),
    // ONLY THE SETTABLE ONES REACH THE SCREEN (BH-1165 review). The registry
    // now declares every `${X:-...}` a lane reads so nothing is invisible to
    // tests/lanes-registry-test.sh section 7 — but about eighty of those are
    // the command a lane runs, the host it sends `Bearer $HARNESS_SECRET` to,
    // the path it deletes under, or a test seam. Drawing an input for one is
    // drawing remote code execution on a lane cron runs as root.
    knobs: (decl.knobs || []).filter((k) => k && k.settable !== false).map((k) => knobRow(k, s && s.knobs)),
    // `unknown` is not `off` and it is not zero: the status payload simply
    // never mentioned this lane, and saying "0 runs today" for it would be a
    // number nobody measured.
    unknown: !s,
    unregistered: false,
    off: s ? offState(s.off) : null,
    off_source: (s && s.off_source) || null,
    // BH-1165. A file under flags/ that no row drove is a REAL stop on the
    // box that holds it, and the toggle on this page cannot clear it: the
    // page writes a row, and that box is stopped by a file. Saying which box
    // is the difference between "press this" and "ssh there".
    flag_boxes: (s && Array.isArray(s.flag_boxes) ? s.flag_boxes : []),
    held_by: (s && Array.isArray(s.held_by) ? s.held_by : []),
    paused_reason: (s && s.paused_reason) || null,
    // The pre-BH-1132 switches that do not STOP a lane: `partial` aliases
    // change what it does (merge-conductor-observe makes it dry-run) and
    // `absent` aliases are what ARM it. Showing neither told an operator a
    // lane was plainly "on" while it was observing and merging nothing.
    modifiers: (s && Array.isArray(s.modifiers) ? s.modifiers : []),
    enables: (s && Array.isArray(s.enables) ? s.enables : []),
    paused_since: (s && s.paused_since) || null,
    last_tick_at: (s && s.last_tick_at) || null,
    last_outcome: (s && s.last_outcome) || null,
    runs_today: s ? num(s.runs_today) : null,
    cost_today: s ? num(s.cost_today) : null,
    cost_7d: s ? num(s.cost_7d) : null,
    // "none" (BH-3557): the lane declares no cost stage or filter, so the
    // counts above are null by design, not unmeasured. Absent from an older
    // worker, which keeps the plain dash.
    cost_attribution: (s && s.cost_attribution) || null,
    cost_rows: (s && s.cost_rows) || [],
    log: (decl.stats && decl.stats.log) || null,
    cost_stage: (decl.stats && decl.stats.cost_stage) || null,
    href: laneHref(decl.id, project)
  };
}

export function laneRows(registry, status, tab) {
  const project = isHub(tab) ? null : tab;
  const scope = project ? 'project' : 'hub';
  const declared = ((registry && registry.lanes) || []).filter((l) => (l.scope || 'hub') === scope);
  const live = new Map(((status && status.lanes) || []).map((l) => [l.id, l]));

  const rowFor = (decl) => laneRow(decl, live.get(decl.id) || null, project, scope);

  const rows = declared.map(rowFor);

  // A knob a box/hub lane reads per project (BH-1985): `project_scoped: true`.
  const projectKnobs = (l) => (l.knobs || []).filter((k) => k && k.project_scoped === true && k.settable !== false);

  // A HUB LANE THAT TAKES A PER-PROJECT HOLD BELONGS ON THE PROJECT TAB
  // (BH-1466). #1463 gave five of them `per_project_hold` and a gate that stops
  // that lane for that project alone on one `lane-off-<id>-<project>` row. The
  // row existed and this page had nowhere to draw it, so the only way to hold
  // the conductor off project-3 was a curl. The row below is that switch, on the tab
  // the operator is already standing on.
  const holdDecls = project
    ? ((registry && registry.lanes) || [])
      .filter((l) => (l.scope || 'hub') !== 'project' && l.per_project_hold === true)
    : [];
  const holdRows = holdDecls.map((decl) => ({
    ...rowFor(decl),
    // It is still a HUB lane and the label says so: its cadence, its spend and
    // its log are the fleet's, and only the switch is this project's.
    name: `${decl.name || decl.id} (hub lane)`,
    scope: 'hub',
    per_project_hold: true,
    // No knob inputs: a hub lane reads `lane.<id>.<env>`, never
    // `lane.<id>.<project>.<env>`, so a per-project knob here would be a
    // control that writes a row nothing ever reads. The one exception is a
    // knob the registry declares `project_scoped` (BH-1985, below).
    knobs: projectKnobs(decl).map((k) => knobRow(k, (live.get(decl.id) || {}).knobs))
  }));

  // A BOX/HUB LANE'S PER-PROJECT KNOBS BELONG ON THE PROJECT TAB (BH-1985). A
  // knob declared `project_scoped: true` is read from `lane.<id>.<project>.<env>`
  // for that project (lane-reaper's deadline), so until now only harness-ctl
  // could see or set it. The row carries those knobs and NO switch: the lane's
  // switch is fleet-wide and nothing reads `lane-off-<id>-<project>` for it.
  const knobDecls = project
    ? ((registry && registry.lanes) || [])
      .filter((l) => (l.scope || 'hub') !== 'project' && projectKnobs(l).length)
    : [];
  // A hold lane already has a row on this tab and carries the knobs there
  // (above) rather than getting a second row.
  const knobRows = knobDecls.filter((d) => !holdDecls.some((h) => h.id === d.id)).map((decl) => ({
    ...rowFor(decl),
    name: `${decl.name || decl.id} (${decl.scope || 'hub'} lane)`,
    scope: decl.scope || 'hub',
    knobsOnly: true,
    switchName: null,
    knobs: projectKnobs(decl).map((k) => knobRow(k, (live.get(decl.id) || {}).knobs))
  }));

  // A lane the LIVE side knows and this SPA build's registry does not: a newer
  // catalog against an older bundle. It gets a row with its live numbers and no
  // knob inputs (there are no declared bounds to enforce), flagged as such.
  const extra = ((status && status.lanes) || [])
    // A hold lane or a knob-only lane is declared for this tab now, so it must
    // not ALSO come back through here as an unregistered duplicate of itself.
    .filter((s) => !declared.some((d) => d.id === s.id) && !holdDecls.some((d) => d.id === s.id)
      && !knobDecls.some((d) => d.id === s.id))
    .map((s) => ({
      id: s.id, name: s.name || s.id, project, scope, script: null,
      cadence: s.cadence || null, switchName: flagName(s.id, project), knobs: [],
      unknown: false, unregistered: true,
      off: offState(s.off), off_source: s.off_source || null, paused_since: s.paused_since || null,
      flag_boxes: Array.isArray(s.flag_boxes) ? s.flag_boxes : [],
      held_by: Array.isArray(s.held_by) ? s.held_by : [],
      paused_reason: s.paused_reason || null,
      modifiers: Array.isArray(s.modifiers) ? s.modifiers : [],
      enables: Array.isArray(s.enables) ? s.enables : [],
      last_tick_at: s.last_tick_at || null, last_outcome: s.last_outcome || null,
      runs_today: num(s.runs_today), cost_today: num(s.cost_today), cost_7d: num(s.cost_7d),
      cost_attribution: s.cost_attribution || null,
      cost_rows: s.cost_rows || [], log: null, cost_stage: null,
      href: laneHref(s.id, project)
    }));

  return rows.concat(holdRows, knobRows, extra);
}

// THE BOX LANES (BH-2327). A `scope: "box"` lane runs on every box and was on no
// tab at all. The hub tab lists them; each row's fleet-wide switch is the lane's
// own `lane-off-<id>`, and its lane page carries one switch per box.
//
// `boxes` is null, not [], when the status did not report per-box state (an
// older worker): an empty list would say "no box runs this lane", which nobody
// measured.
function boxEntry(b) {
  return {
    box: b.box,
    switch_name: b.switch_name || null,
    off: offState(b.off),
    off_source: b.off_source || null,
    paused_since: b.paused_since || null,
    paused_by: b.paused_by || null,
    paused_reason: b.paused_reason || null,
    last_tick_at: b.last_tick_at || null,
    last_outcome: b.last_outcome || null
  };
}

export function boxLaneRows(registry, status) {
  const live = new Map(((status && status.lanes) || []).map((l) => [l.id, l]));
  return ((registry && registry.lanes) || []).filter((l) => l.scope === 'box').map((decl) => {
    const s = live.get(decl.id) || null;
    const boxes = s && Array.isArray(s.boxes) ? s.boxes.filter((b) => b && b.box).map(boxEntry) : null;
    return {
      ...laneRow(decl, s, null, 'box'),
      boxes,
      boxes_off: boxes ? boxes.filter((b) => b.off === true).length : null,
      boxes_complete: boxes ? s.boxes_complete !== false : null
    };
  });
}

// The Settings tab's two tables. On the hub tab a box lane is drawn in BOX
// LANES, so it is lifted out of the main table, where laneRows() would
// otherwise draw it again as a live-only "not in registry" row. Other tabs are
// laneRows() exactly as before.
export function settingsRows(registry, status, tab) {
  const rows = laneRows(registry, status, tab);
  if (!isHub(tab)) return { rows, boxRows: [] };
  const boxRows = boxLaneRows(registry, status);
  const ids = new Set(boxRows.map((r) => r.id));
  return { rows: rows.filter((r) => !ids.has(r.id)), boxRows };
}

// The row a lane's detail page (/settings/<id>[?project=]) draws: the BOX
// LANES row for a box lane on the hub tab, else the tab's own row.
export function findLaneRow(registry, status, tab, id) {
  const { rows, boxRows } = settingsRows(registry, status, tab);
  return boxRows.concat(rows).find((r) => r.id === id) || null;
}

// ──────────────────────────────────────────────────────── words (BH-3570)

// A lane's cadence in words. The registry holds 5-field cron lines (several
// joined by "; ") or prose ("on demand (...)"). Only the shapes it actually
// uses are translated; any other cron line is shown raw and marked (cron), so
// a pattern this does not know is never guessed at.
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const INT = /^\d{1,2}$/;
const pad2 = (n) => String(n).padStart(2, '0');

function cronPartWords(part) {
  const f = part.split(/\s+/);
  if (f.length !== 5) return /[a-z]/i.test(part) ? part : `${part} (cron)`;
  const [m, hr, dom, mon, dow] = f;
  const rest = `${dom} ${mon}`;
  if (rest === '* *' && dow === '*' && hr === '*') {
    if (m === '*') return 'every min';
    if (/^\*\/\d+$/.test(m)) return `every ${m.slice(2)} min`;
    if (m.split(',').every((x) => INT.test(x))) return `hourly at ${m.split(',').map((x) => `:${pad2(x)}`).join(', ')}`;
  }
  if (rest === '* *' && INT.test(m) && INT.test(hr)) {
    if (dow === '*') return `daily at ${pad2(hr)}:${pad2(m)}Z`;
    if (/^[0-6]$/.test(dow)) return `weekly, ${DAYS[Number(dow)]} ${pad2(hr)}:${pad2(m)}Z`;
  }
  return `${part} (cron)`;
}

export function cadenceWords(s) {
  if (s === null || s === undefined) return null;
  const raw = String(s).trim();
  if (!raw) return null;
  return raw.split(/\s*;\s*/).map(cronPartWords).join('; ');
}

// A knob note's first sentence: up to the first . ! or ? followed by
// whitespace or the end, so "BH-1510.2:" and "bin/lib/x.sh" do not cut it.
export function firstSentence(s) {
  if (s === null || s === undefined) return null;
  const t = String(s).trim();
  if (!t) return null;
  const m = t.match(/^[\s\S]*?[.!?](?=\s|$)/);
  return (m ? m[0] : t).trim();
}

// ──────────────────────────────────────────────────────── names and keys

// The switch is a flag FILE name on every box, so it lives in the same
// character set the worker enforces on PUT /api/flags (^[A-Za-z0-9._-]+$) —
// which is also the set that cannot escape the flags/ directory.
export function flagName(laneId, project) {
  return isHub(project) ? `lane-off-${laneId}` : `lane-off-${laneId}-${project}`;
}

// The per-box switch (BH-2327): the name bin/lib/lane-gate.sh reads for a box
// lane on that box. `.box.` so it can never be read as a project switch.
export function boxFlagName(laneId, box) {
  return `lane-off-${laneId}.box.${box}`;
}

// The worker's own rule, copied verbatim so the page refuses exactly what the
// worker would refuse (worker/jobs/src/index.js, SETTING_KEY_RE).
export const SETTING_KEY_RE = /^[a-z0-9_.-]{1,64}$/;
export const SETTING_KEY_MAX = 64;
// PUT /api/settings: "value must be non-empty and <= 256 chars".
export const SETTING_VALUE_MAX = 256;

// LOWERCASE, and that is not a style choice. `PUT /api/settings` validates every
// key against SETTING_KEY_RE, so a key carrying the ENV name verbatim
// (`lane.merge-conductor.MC_MAX_PRS`) is a 400 on every single write.
//
// The WHOLE key is lowercased, not only the env segment: a lane id or a project
// slug carrying an uppercase character would build a key the worker refuses,
// and the page would have no idea why. Any reader of these rows has to
// lowercase to match.
export function settingKey(laneId, env, project) {
  const parts = isHub(project)
    ? ['lane', laneId, env]
    : ['lane', laneId, project, env];
  return parts.map((x) => String(x === null || x === undefined ? '' : x)).join('.').toLowerCase();
}

// The whole key, checked before the write rather than after the click. The
// 64-character bound is not theoretical: `review-autopilot` on
// `project-8` with `AUTOPILOT_DAILY_CAP_USD` is 65 characters, so
// that knob is unsettable from this page and the operator has to be told so
// instead of watching a silent 400.
export function checkSettingKey(laneId, env, project) {
  const key = settingKey(laneId, env, project);
  if (key.length > SETTING_KEY_MAX) {
    return {
      ok: false, key,
      message: `the settings key for this knob is ${key.length} characters and the worker's `
        + `limit is ${SETTING_KEY_MAX} — it cannot be set from here (key: ${key})`
    };
  }
  if (!SETTING_KEY_RE.test(key)) {
    return {
      ok: false, key,
      message: `the settings key for this knob carries a character the worker will not store `
        + `(key: ${key}) — it must match ${SETTING_KEY_RE}`
    };
  }
  return { ok: true, key };
}

// ────────────────────────────────────────────────────────────────── knobs

// `0` means different things to different lanes — unlimited for the pool caps,
// off for TRIAGE_MAX_FAMILIES — and that inconsistency is half of why this
// screen exists. The registry says which, and the page never shows a bare 0.
export function zeroLabel(knob) {
  const z = knob && knob.zero_means;
  return z === 'unlimited' || z === 'off' ? `0 = ${z}` : null;
}

// A STRICT decimal, because Number() is not one: Number('0x10') is 16 and
// passes Number.isInteger, and Number('1e1') is 10 — so a naive parse would
// write a number nobody typed and show it back as though they had.
const DECIMAL_RE = /^[+-]?(\d+(\.\d+)?|\.\d+)$/;

// `ctx` is `{laneId, project}` when the caller can supply it. Given it, the
// KEY is validated too — the value being in range is no use if the key it
// would be written under is one the worker refuses.
export function validateKnob(knob, raw, ctx) {
  const env = (knob && knob.env) || 'value';
  // `settable: false` IS A REFUSAL, NOT A STYLE (BH-1165 review). Wiring all 78
  // lanes registered every `${X:-...}` an automatic script reads, and about
  // eighty of those are the command a lane runs, the host it sends its bearer
  // to, the path it deletes under or a test seam. bin/lib/lane-gate.sh exports a
  // settings row into a lane cron runs as ROOT. laneRows() already drops them
  // from the screen; this is the second half, so a caller that builds a knob by
  // hand cannot write one either.
  if (knob && knob.settable === false) {
    return { ok: false, message: `${env} is not settable from here — it is a command, host, path or identity a root lane runs (catalog/lanes.json: settable:false)` };
  }
  if (ctx && ctx.laneId) {
    const k = checkSettingKey(ctx.laneId, env, ctx.project);
    if (!k.ok) return { ok: false, message: k.message };
  }
  const text = String(raw === null || raw === undefined ? '' : raw).trim();
  if (text === '') return { ok: false, message: `${env} needs a value` };
  // A STRING KNOB IS A STRING (BH-1165). 212 knobs joined the registry when
  // every lane was wired, and about eighty of them are a model slug, a list of
  // boxes or a regex. Refusing them as "must be a decimal number" left the page
  // offering an input that could only ever 400 — a control that is worse than
  // no control, because it looks like one. The bounds are the worker's own:
  // PUT /api/settings stores a trimmed, non-empty value of at most 256 chars.
  if ((knob && knob.type) === 'string') {
    if (text.length > SETTING_VALUE_MAX) {
      return { ok: false, message: `${env} must be ${SETTING_VALUE_MAX} characters or fewer — the worker refuses a longer value` };
    }
    if (/[\n\r]/.test(text)) return { ok: false, message: `${env} cannot contain a line break` };
    return { ok: true, value: text };
  }
  if (!DECIMAL_RE.test(text)) return { ok: false, message: `${env} must be a decimal number` };
  const n = Number(text);
  if (!Number.isFinite(n)) return { ok: false, message: `${env} must be a number` };
  const type = (knob && knob.type) || 'int';
  if (type === 'int' && !Number.isInteger(n)) {
    return { ok: false, message: `${env} must be a whole number` };
  }
  const min = knob && knob.min !== undefined && knob.min !== null ? Number(knob.min) : null;
  const max = knob && knob.max !== undefined && knob.max !== null ? Number(knob.max) : null;
  if ((min !== null && n < min) || (max !== null && n > max)) {
    const bound = min !== null && max !== null ? `${min}–${max}`
      : min !== null ? `at least ${min}` : `at most ${max}`;
    return { ok: false, message: `${env} must be ${bound} — ${n} is outside the registry's range` };
  }
  return { ok: true, value: n };
}

// ───────────────────────────────────────────────────────── write bodies

export const flagBody = (laneId, project, off, reason) => ({
  name: flagName(laneId, project),
  active: off ? 1 : 0,
  actor: ACTOR,
  reason
});

export const settingBody = (laneId, env, value, project) => ({
  key: settingKey(laneId, env, project),
  value,
  actor: ACTOR,
  note: 'set from Mission Control'
});

export const ALL_OFF_REASON = 'all lanes stopped from Mission Control';
export const ALL_ON_REASON = 'all lanes resumed from Mission Control';

// ──────────────────────────────────────────────────────────────── actions

// The screen's write path, with the confirm, the validation, the exact body and
// the refetch in ONE place that takes stubs. Every action answers with a status
// rather than throwing: `cancelled` and `invalid` are outcomes to render, not
// failures to swallow, and `failed` must never read as success.
export function makeLaneActions({ confirm, writeFlag, writeSetting, writeAll, refresh, onNote }) {
  const note = (ok, text) => { if (onNote) onNote({ ok, text }); };

  const run = async (label, write) => {
    try {
      await write();
    } catch (e) {
      const message = `${label} refused — ${e && e.message ? e.message : e}`;
      note(false, message);
      return { status: 'failed', message };
    }
    if (refresh) refresh();
    note(true, `${label} written — the boxes apply it on their next tick.`);
    return { status: 'written' };
  };

  return {
    async toggleLane(row) {
      // A knob-only row has no per-project switch (BH-1985). Refused here as
      // well as undrawn, so no caller can write a flag nothing reads.
      if (row.knobsOnly) {
        const message = 'this lane’s switch is fleet-wide; it is not switched per project';
        note(false, message);
        return { status: 'invalid', message };
      }
      const off = !row.off;
      const label = `${row.name} ${off ? 'OFF' : 'ON'}`;
      const ok = await confirm({
        title: off ? `TURN ${row.name.toUpperCase()} OFF?` : `TURN ${row.name.toUpperCase()} ON?`,
        body: off
          ? `This writes ${flagName(row.id, row.project)}. The lane stops at its own gate on its next `
            + 'tick — within about a minute. Work already running is not killed.'
          : `This clears ${flagName(row.id, row.project)}. The lane resumes on its next scheduled tick.`,
        confirmLabel: off ? 'TURN OFF' : 'TURN ON',
        tone: off ? 'warn' : undefined
      });
      if (!ok) return { status: 'cancelled' };
      const body = flagBody(row.id, row.project, off, `turned ${off ? 'off' : 'on'} from Mission Control`);
      return run(label, () => writeFlag(body));
    },

    // ONE BOX'S SWITCH (BH-2327). Only a box lane has one, and a box whose
    // state was not reported cannot be flipped: the toggle would be guessing.
    async toggleBox(row, box) {
      if (!row || row.scope !== 'box' || !box || !box.box || box.off === null || box.off === undefined) {
        const message = 'only a box lane with a reported box state can be switched per box';
        note(false, message);
        return { status: 'invalid', message };
      }
      const off = !box.off;
      const name = boxFlagName(row.id, box.box);
      const ok = await confirm({
        title: `TURN ${row.name.toUpperCase()} ${off ? 'OFF' : 'ON'} ON ${box.box.toUpperCase()}?`,
        body: off
          ? `This writes ${name}. It stops ${row.name} on ${box.box} only; every other box keeps running. `
            + 'The lane stops at its own gate on its next tick there. Work already running is not killed.'
          : `This clears ${name}. ${row.name} resumes on ${box.box} on its next tick.`
            + (box.off_source === 'flag'
              ? ` It is stopped by a file on ${box.box} that no row wrote; this row is newer, so that box removes the file when it next reads the switch.`
              : ''),
        confirmLabel: off ? 'TURN OFF' : 'TURN ON',
        tone: off ? 'warn' : undefined
      });
      if (!ok) return { status: 'cancelled' };
      const body = {
        name, active: off ? 1 : 0, actor: ACTOR,
        reason: `turned ${off ? 'off on' : 'on for'} ${box.box} from Mission Control`
      };
      return run(`${row.name} ${off ? 'OFF' : 'ON'} on ${box.box}`, () => writeFlag(body));
    },

    // A value the registry would refuse never reaches the API and never even
    // opens the modal: asking a human to confirm something that cannot be
    // written is the wrong order to find out in.
    async setKnob(row, knob, raw) {
      const v = validateKnob(knob, raw, { laneId: row.id, project: row.project });
      if (!v.ok) {
        note(false, v.message);
        return { status: 'invalid', message: v.message };
      }
      const body = settingBody(row.id, knob.env, v.value, row.project);
      return run(`${knob.env} = ${v.value}`, () => writeSetting(body));
    },

    async allOff() {
      const ok = await confirm({
        title: 'STOP EVERY LANE?',
        body: 'This throws the fleet-wide all-off switch. Every registered lane stops at its own '
          + 'gate on its next tick. Nothing already running is killed, and nothing resumes until '
          + 'ALL ON is pressed.',
        confirmLabel: 'STOP EVERYTHING',
        tone: 'danger'
      });
      if (!ok) return { status: 'cancelled' };
      return run('ALL OFF', () => writeAll('all-off', { actor: ACTOR, reason: ALL_OFF_REASON }));
    },

    async allOn() {
      const ok = await confirm({
        title: 'START EVERY LANE?',
        body: 'This clears the fleet-wide all-off switch. Every lane that is not individually '
          + 'switched off resumes on its next scheduled tick.',
        confirmLabel: 'START EVERYTHING'
      });
      if (!ok) return { status: 'cancelled' };
      return run('ALL ON', () => writeAll('all-on', { actor: ACTOR, reason: ALL_ON_REASON }));
    }
  };
}
