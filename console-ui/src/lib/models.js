// MODELS (BH-1510.3) — the logic behind the model-routes screen, kept out of
// the component so the write path, the validation and the spend attribution
// are testable with stubs (the lib/settings.js idiom).
//
// NO MODEL ID LIVES IN THIS FILE, and none may: console-ui/src is inside
// tests/model-literal-lint.sh's scan. Model choices come from model_prices
// (GET /api/model-prices), runner choices from the worker's own list (the
// `runners` field of GET /api/model-routes), ladders from model_routes.

export const ACTOR = 'console';
export const SPEND_DAYS = 7;
export const DEFAULT_SAVE_REASON = 'set from Mission Control';
export const DEFAULT_RESET_REASON = 'reset to hub default from Mission Control';
export const DEFAULT_REMOVE_REASON = 'removed from Mission Control';
export const DEFAULT_KEEP_REASON = 'seed value reviewed and kept from Mission Control';
export const KEEP_SEED_LABEL = 'KEEP SEEDED VALUE';

// ─────────────────────────────────────────────────── spend attribution
//
// The cost ledger (cost_rows) records the STAGE a call ran under — the first
// argument to bin/agent-call.sh — plus runner and project, never the role. So
// spend per role is a mapping onto those labels, and this table is that
// mapping. It holds cost labels, not models. Four honest grades:
//   exact   — the filters select this role's calls and nobody else's
//   shared  — the filters select this role AND the roles named in `shared`;
//             the figure is the whole stage, not this role's slice of it
//   partial — the filters select only some of this role's calls
//   none    — no label in the ledger distinguishes this role yet
// A role missing from the table (added after this file) reads as `none`, so a
// new role shows a dash, never a confident $0.
//
// Labels come from catalog/context-budgets.json's lane stages and the
// agent-call.sh call sites (2026-09-22). `project` pins a lane whose cost rows
// carry a fixed pseudo-project (alert-triage, bench), which makes it exact —
// and makes it a hub-only lane with nothing to show on a project tab.
export const ROLE_ATTRIBUTION = {
  'build.execute': { filters: [{ stage: 'execute' }], shared: ['build.execute.fallback'] },
  'build.execute.fallback': { filters: [{ stage: 'execute' }], shared: ['build.execute'] },
  'build.plan': { filters: [{ stage: 'plan' }] },
  'build.review': { filters: [{ stage: 'review' }], shared: ['rescue.review'] },
  'rescue.review': { filters: [{ stage: 'review' }], shared: ['build.review'] },
  'build.qa': { filters: [{ stage: 'qa' }] },
  'postmerge.qa': { filters: [{ stage: 'prodqa' }] },
  plan: { filters: [{ stage: 'preplan' }, { stage: 'preplan-files' }, { stage: 'map' }] },
  triage: { filters: [{ stage: 'triage' }], shared: ['triage.light', 'triage.shard', 'alert.triage', 'bench'] },
  'triage.light': { filters: [{ stage: 'triage' }], shared: ['triage', 'triage.shard', 'alert.triage', 'bench'] },
  'triage.shard': { filters: [{ stage: 'triage' }], shared: ['triage', 'triage.light', 'alert.triage', 'bench'] },
  'alert.triage': { filters: [{ stage: 'triage', project: 'alert-triage' }] },
  bench: { filters: [{ stage: 'triage', project: 'bench' }] },
  decompose: { filters: [{ stage: 'decompose' }] },
  orchestrate: { filters: [{ stage: 'orchestrator' }] },
  product: {
    filters: ['ideate', 'signals', 'synth', 'prd', 'mockup', 'revise'].map((stage) => ({ stage })),
    partial: 'sums run-product\'s sub-stages; product-cmd\'s own calls run as stage chat, shared with box chat, and are not summed'
  },
  greenfield: {
    filters: ['gf-map', 'gf-signals', 'gf-synth', 'gf-deck'].map((stage) => ({ stage })),
    partial: 'gf-ideate-<dept> and gf-mockup-<slug> are named per run and are not summed'
  },
  'codex.default': { filters: [{ runner: 'codex' }], note: 'every codex call, whichever stage ran it' },
  'grok.default': { filters: [{ runner: 'grok' }], note: 'every grok call, whichever stage ran it' },
  'fireworks.default': { filters: [{ runner: 'fireworks' }], shared: ['housekeeping.floor'] },
  'housekeeping.floor': { filters: [{ runner: 'fireworks' }], shared: ['fireworks.default'] },
  'auth.fallback': { filters: [], note: 'a failover model for any stage; its calls carry that stage\'s label' },
  // BH-1766: a stage.* role is a runner choice, not a spend line. Its calls are
  // already summed under that stage's model roles (triage, build.plan, …), so
  // a second sum here would double-count them.
  ...Object.fromEntries(['triage', 'plan', 'preplan', 'execute', 'review', 'fix'].map((stage) => [
    `stage.${stage}`, { filters: [], note: `runner choice for the ${stage} stage; its spend is on that stage's model roles` }
  ]))
};

// The stage.* roles (BH-1766): which runner a build stage calls, and its
// fallback. /models shows them as their own STAGE RUNNERS group.
export const isStageRole = (role) => role.startsWith('stage.');

export function attributionFor(role) {
  const a = ROLE_ATTRIBUTION[role];
  if (!a || !a.filters.length) {
    return { kind: 'none', filters: [], shared: [], note: (a && a.note) || 'no attribution: no cost-ledger label names this role yet' };
  }
  const kind = a.partial ? 'partial' : a.shared && a.shared.length ? 'shared' : 'exact';
  const note = a.partial || (a.shared && a.shared.length ? `shared with ${a.shared.join(', ')}` : a.note || '');
  return { kind, filters: a.filters, shared: a.shared || [], note };
}

const spendKey = (params) => Object.keys(params).sort().map((k) => `${k}=${params[k]}`).join('&');

// Which llm-spend reads the table needs, deduped (two roles on one stage are
// one read), and which of them each role sums. On a project tab every read is
// scoped to that project, and a lane pinned to its own pseudo-project is n/a.
export function spendPlan(roles, project) {
  const queries = new Map();
  const byRole = {};
  for (const role of roles) {
    const a = attributionFor(role);
    if (project && a.filters.some((f) => f.project)) {
      byRole[role] = { kind: 'none', keys: [], shared: [], note: 'hub lane: its cost rows carry their own project, never this one' };
      continue;
    }
    const keys = a.filters.map((f) => {
      const params = project ? { ...f, project } : { ...f };
      const key = spendKey(params);
      queries.set(key, { key, params });
      return key;
    });
    byRole[role] = { kind: a.kind, keys, shared: a.shared, note: a.note };
  }
  return { queries: [...queries.values()], byRole };
}

// cost_rows.ts is `YYYY-MM-DDTHH:MM:SSZ` and llm-spend compares it as a string,
// so `since` must be the same shape — a millisecond suffix sorts differently.
export const spendSince = (nowMs) =>
  new Date(nowMs - SPEND_DAYS * 86400000).toISOString().replace(/\.\d{3}Z$/, 'Z');

export const perMillion = (v) =>
  (v === null || v === undefined || !Number.isFinite(Number(v)) ? null : Math.round(Number(v) * 1e6 * 1e6) / 1e6);

// ───────────────────────────────────────────────────────────────── rows

export const roleHref = (role, project) =>
  `/models/${encodeURIComponent(role)}${project ? `?project=${encodeURIComponent(project)}` : ''}`;

// The scopes the resolver hides (BH-1563): rows that exist but do not start at
// rung 0, so nothing reads them and no row on the list page is theirs. The
// worker lists them fleet-wide on every tab; each one becomes a link to the
// role page on its OWN tab, which is where it can be repaired.
export function gapRows(routes) {
  return ((routes && routes.gaps) || []).map((g) => ({
    project: g.project || null,
    role: g.role,
    positions: g.positions || [],
    href: roleHref(g.role, g.project),
    label: `${g.project || 'hub'} / ${g.role} (rungs ${(g.positions || []).join(', ')})`
  }));
}

// BH-2512: the stages the cost ledger saw in the window with no stage.* route
// agent-call would use (GET /api/model-routes?unrouted_since=). null when the
// ledger read failed (render that, never "every stage is routed"); undefined
// when the read did not ask for the list.
export function unroutedRows(routes, project) {
  if (!routes || !('unrouted_stages' in routes)) return undefined;
  if (routes.unrouted_stages === null) return null;
  return routes.unrouted_stages.map((s) => ({
    stage: s.stage,
    role: s.role,
    href: s.role ? roleHref(s.role, project) : null,
    projects: s.projects || [],
    calls: s.calls,
    last_seen: s.last_seen,
    runners: s.runners || []
  }));
}

function roleSpend(entry, spend) {
  if (!entry || !entry.keys.length) return { usd: null, calls: null, error: null };
  let usd = 0, calls = 0;
  for (const k of entry.keys) {
    const s = spend && spend[k];
    if (!s) return { usd: null, calls: null, error: null };
    if (s.error) return { usd: null, calls: null, error: s.error };
    usd += Number(s.usd) || 0;
    calls += Number(s.calls) || 0;
  }
  return { usd, calls, error: null };
}

// BH-1613: priced at the vendor's direct rate from the committed catalog, not
// OpenRouter's. The worker stores the value lowercase, so only the exact string counts.
export const isDirect = (price) => Boolean(price && price.price_source === 'vendor-direct');

// BH-2512: one row per priced model, for the MODEL PRICES table.
export function priceRows(prices) {
  const perToken = (prices && prices.per_token) || {};
  return Object.keys(perToken).sort().map((model) => {
    const p = perToken[model];
    return {
      model,
      price_in: perMillion(p.prompt),
      price_out: perMillion(p.completion),
      direct: isDirect(p),
      vendorRates: Boolean(p.vendor_direct)
    };
  });
}

export function modelRows({ routes, prices, spend, plan, project }) {
  const perToken = (prices && prices.per_token) || {};
  return ((routes && routes.roles) || []).map((r) => {
    const ladder = r.ladder || [];
    const primary = ladder[0] || null;
    const price = primary ? perToken[primary.model] : null;
    const entry = plan && plan.byRole[r.role];
    const s = roleSpend(entry, spend);
    return {
      role: r.role,
      href: roleHref(r.role, project),
      ladder,
      primary: primary ? primary.model : null,
      runner: primary ? primary.runner : null,
      fallbacks: ladder.slice(1),
      price_in: price ? perMillion(price.prompt) : null,
      price_out: price ? perMillion(price.completion) : null,
      direct: isDirect(price),
      usd_7d: s.usd,
      calls_7d: s.calls,
      spend_error: s.error,
      attribution: entry || { kind: 'none', keys: [], shared: [], note: 'no attribution' },
      source: r.source,
      gapped: r.gapped === true,
      seed: ladder.some((x) => x.updated_by === 'seed')
    };
  });
}

export function coverage(rows) {
  const out = { exact: [], shared: [], partial: [], none: [] };
  for (const r of rows) (out[r.attribution.kind] || out.none).push(r.role);
  return out;
}

// What /models' SPEND ATTRIBUTION note lists: the stage runners are left out,
// because they carry no spend of their own (ROLE_ATTRIBUTION above).
export const screenCoverage = (rows) => coverage(rows.filter((r) => !isStageRole(r.role)));

// ─────────────────────────────────────────────────────────────── edits

export const pricedModels = (prices) =>
  Object.keys((prices && prices.per_token) || {}).sort();

// The worker's own refusals, checked first so a ladder that can only 400 never
// opens a modal. The worker still checks: this is the order, not the gate.
export function validateLadder(draft, priced, runners) {
  if (!Array.isArray(draft) || draft.length === 0) {
    return { ok: false, message: 'a ladder needs at least one rung' };
  }
  const ladder = [];
  for (let i = 0; i < draft.length; i++) {
    const model = String((draft[i] && draft[i].model) || '').trim();
    const runner = String((draft[i] && draft[i].runner) || '').trim();
    if (!model) return { ok: false, message: `rung ${i} has no model` };
    if (!priced.has(model)) return { ok: false, message: `rung ${i}: ${model} is not priced (no model_prices row)` };
    if (!runners.includes(runner)) return { ok: false, message: `rung ${i}: runner must be one of ${runners.join(', ')}` };
    ladder.push({ model, runner });
  }
  return { ok: true, ladder };
}

const rung = (r) => (r ? { model: r.model, runner: r.runner } : null);

export function ladderChanges(before, after) {
  const out = [];
  const n = Math.max(before.length, after.length);
  for (let i = 0; i < n; i++) {
    const b = rung(before[i]);
    const a = rung(after[i]);
    if (b && a && b.model === a.model && b.runner === a.runner) continue;
    out.push({ position: i, before: b, after: a });
  }
  return out;
}

// After is checked FIRST: an empty hub remove writes a tombstone row with
// before AND after null (BH-1928), and that row is a removal, not an add.
export function changeRows(changes) {
  return (changes || []).map((c) => ({
    ...c,
    anchor: `change-${c.id}`,
    kind: c.after_model === null || c.after_model === undefined ? 'removed'
      : c.before_model === null || c.before_model === undefined ? 'added' : 'changed'
  }));
}

// The write path: validation, the confirm (with before/after), the exact body
// and the refetch, in one place that takes stubs. Every action answers with a
// status: `cancelled`, `invalid` and `unchanged` are outcomes to render, and
// `failed` must never read as success.
export function makeModelActions({ confirm, writeLadder, resetLadder, removeLadder, writePriceSource, refresh, onNote }) {
  const note = (ok, text) => { if (onNote) onNote({ ok, text }); };
  const run = async (label, write, done) => {
    try {
      await write();
    } catch (e) {
      // 409 = someone else wrote this scope since it was loaded (the worker's
      // version guard). Reload so the page shows THEIR ladder, and say so —
      // re-editing on top of a stale view is exactly what the guard prevents.
      if (e && e.status === 409) {
        // WHICH scope moved changes what the operator is looking at when the
        // page reloads (BH-1563): their own ladder, or the hub ladder the
        // override they were creating was based on.
        const which = e.body && e.body.stale;
        const moved = which === 'hub'
          ? 'the hub ladder this edit was based on changed since you loaded it'
          : which === 'both'
            ? 'both this ladder and the hub ladder it was based on changed since you loaded them'
            : 'this ladder changed since you loaded it';
        const message = `${label} not written — ${moved}. Reloaded: review it and edit again.`;
        if (refresh) refresh();
        note(false, message);
        return { status: 'stale', message };
      }
      const message = `${label} refused — ${e && e.message ? e.message : e}`;
      note(false, message);
      return { status: 'failed', message };
    }
    if (refresh) refresh();
    note(true, done || `${label} written — a box reads it on its next resolve (its cached answer only covers a dead worker).`);
    return { status: 'written' };
  };

  const versioned = (body, version) =>
    (Number.isInteger(version) ? { ...body, expected_version: version } : body);

  return {
    async saveLadder({ role, project, before, draft, priced, runners, reason, source, version, hubVersion }) {
      const v = validateLadder(draft, priced, runners);
      if (!v.ok) { note(false, v.message); return { status: 'invalid', message: v.message }; }
      // A project on the hub default starts from nothing of its own: the PUT
      // writes a whole new ladder, so compare against the hub ladder shown.
      const changes = ladderChanges(before || [], v.ladder);
      if (!changes.length) {
        note(false, `Nothing changed in the ${role} ladder, so nothing was written. To record a seeded rung as reviewed without changing it, use ${KEEP_SEED_LABEL}.`);
        return { status: 'unchanged' };
      }
      const scope = project ? project : 'the hub default';
      const ok = await confirm({
        title: `CHANGE ${role.toUpperCase()} FOR ${project ? project.toUpperCase() : 'THE HUB'}?`,
        changes,
        note: project && source !== 'project'
          ? `This creates an override for ${project}: it stops following the hub default for ${role}. The hub ladder is untouched.`
          : `This replaces the whole ${role} ladder for ${scope}. Every changed rung is audited.`,
        confirmLabel: 'SAVE LADDER'
      });
      if (!ok) return { status: 'cancelled' };
      const body = versioned({ role, project: project || null, ladder: v.ladder, actor: ACTOR, reason: (reason && reason.trim()) || DEFAULT_SAVE_REASON }, version);
      // The hub guard, and ONLY when this save is creating an override from
      // the inherited hub ladder (BH-1563). A project that already owns its
      // ladder sends nothing about the hub: a hub edit does not touch what it
      // is editing, and guarding on it would refuse a save for a change that
      // cannot affect it. A hub save never sends it (the worker 400s it).
      if (project && source !== 'project' && Number.isInteger(hubVersion)) body.expected_hub_version = hubVersion;
      return run(`${role} ladder`, () => writeLadder(body));
    },

    // "This seeded value is right": the same ladder, PUT with confirm:true, so
    // the worker re-stamps every rung with this actor and audits before = after.
    // The only way a SEED tag clears without the model changing.
    async keepSeed({ role, project, current, reason, version }) {
      const ladder = (current || []).map(rung);
      if (!ladder.length) {
        const message = 'there is no ladder here to keep';
        note(false, message);
        return { status: 'invalid', message };
      }
      const ok = await confirm({
        title: `KEEP ${role.toUpperCase()} AS SEEDED FOR ${project ? project.toUpperCase() : 'THE HUB'}?`,
        changes: ladder.map((r, position) => ({ position, before: r, after: r })),
        note: 'Nothing about the model changes. This records that you reviewed the seeded ladder and kept it: every rung is re-stamped with you and audited, and the SEED tag clears.',
        confirmLabel: KEEP_SEED_LABEL
      });
      if (!ok) return { status: 'cancelled' };
      const body = versioned({
        role, project: project || null, ladder, actor: ACTOR,
        reason: (reason && reason.trim()) || DEFAULT_KEEP_REASON, confirm: true
      }, version);
      return run(`${role} kept as seeded`, () => writeLadder(body));
    },

    async resetOverride({ role, project, current, hub, reason, version }) {
      if (!project) {
        const message = 'the hub default has nothing to reset to';
        note(false, message);
        return { status: 'invalid', message };
      }
      const ok = await confirm({
        title: `RESET ${role.toUpperCase()} ON ${project.toUpperCase()} TO THE HUB DEFAULT?`,
        changes: ladderChanges(current || [], (hub || []).map(rung)),
        note: `This deletes ${project}'s own ladder for ${role}; it follows the hub default from its next resolve. Every removed rung is audited.`,
        confirmLabel: 'RESET TO HUB',
        tone: 'warn'
      });
      if (!ok) return { status: 'cancelled' };
      return run(`${role} reset`, () => resetLadder(versioned({
        role, project, actor: ACTOR, reason: (reason && reason.trim()) || DEFAULT_RESET_REASON
      }, version)));
    },

    // BH-2512: take a role off the HUB (POST /api/model-routes/remove). A
    // project override is dropped with RESET TO HUB instead; the worker refuses
    // a project too, this is the order, not the gate.
    async removeRoute({ role, project, current, reason, version }) {
      if (project) {
        const message = 'remove takes the hub route only; a project override is dropped with RESET TO HUB';
        note(false, message);
        return { status: 'invalid', message };
      }
      if (!current || !current.length) {
        const message = 'the hub has no rungs for this role to remove';
        note(false, message);
        return { status: 'invalid', message };
      }
      const after = isStageRole(role)
        ? `agent-call falls back to RUNNER_${role.slice('stage.'.length).toUpperCase().replace(/[^A-Z0-9]/g, '_')} from env, else claude`
        : 'a caller resolving it gets no route: a floor rung is skipped, a build lane defers';
      const ok = await confirm({
        title: `REMOVE ${role.toUpperCase()} FROM THE HUB?`,
        changes: ladderChanges(current, []),
        note: `This deletes every hub rung of ${role}; ${after}. A project override is untouched. Every removed rung is audited, and the removal survives a deploy (the seeds skip a removed role). Put it back with SAVE LADDER.`,
        confirmLabel: 'REMOVE ROUTE',
        tone: 'warn'
      });
      if (!ok) return { status: 'cancelled' };
      return run(`${role} removal`, () => removeLadder(versioned({
        role, actor: ACTOR, reason: (reason && reason.trim()) || DEFAULT_REMOVE_REASON
      }, version)));
    },

    // BH-2512: one model's price source. `direct` is the CURRENT state; the
    // action flips it. The price itself moves at the hub's next refresh.
    async setPriceSource({ model, direct }) {
      const next = direct ? 'openrouter' : 'vendor-direct';
      const ok = await confirm({
        title: direct ? `PRICE ${model} FROM OPENROUTER?` : `MARK ${model} VENDOR-DIRECT?`,
        changes: [],
        note: direct
          ? `${model} goes back to OpenRouter's rate at the hub's daily 04:30 price refresh. This also clears any vendor rates stored for it.`
          : `${model} is priced at the vendor's direct rate (its catalog/model-prices.json row) from the hub's daily 04:30 price refresh. A model with no catalog row stays on OpenRouter.`,
        confirmLabel: direct ? 'USE OPENROUTER' : 'MARK VENDOR-DIRECT',
        tone: direct ? 'warn' : undefined
      });
      if (!ok) return { status: 'cancelled' };
      return run(`${model} price source`, () => writePriceSource({ model, price_source: next }),
        `${model} price source set to ${next} — the price moves at the hub's next 04:30 refresh.`);
    }
  };
}
