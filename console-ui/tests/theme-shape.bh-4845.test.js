// BH-4845 (Mission Control wave 3): the Mill Floor form.
//
// Mill and Paper get Archivo display titles, Geist body, Geist Mono
// uppercase labels and pills, 10-14px panels and pill buttons; Phosphor keeps
// its square JetBrains Mono look. The form lives in each theme's `shape`, next
// to its colour `tokens`, and goes onto :root in the same paint. Brick (the
// Mill accent) is for in-progress only: the running build, the active stage.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { h } from 'preact';

globalThis.window = globalThis.window || {
  location: { pathname: '/now', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { render } = await import('preact-render-to-string');
const { BUILTIN_THEMES, THEME_ORDER, TEXT_PAIRS } = await import('../src/theme/themes.js');
const { SHAPE_TOKENS, EXTENDED_TOKENS } = await import('../src/theme/tokens.js');
const { paintTheme } = await import('../src/theme/apply.js');
const { bootScript } = await import('../src/theme/boot.js');
const { BuildMission } = await import('../src/screens/Build.js');
const { NowView } = await import('../src/screens/Now.js');
const { BuildsTable } = await import('../src/screens/Project.js');
const { PipelineBoard } = await import('../src/screens/Kanban.js');
const { JobsTable } = await import('../src/screens/Jobs.js');
const { jobRows } = await import('../src/lib/jobs.js');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CSS = fs.readFileSync(path.join(root, 'src', 'styles.css'), 'utf8');
const INDEX = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const norm = (v) => String(v).toLowerCase().replace(/\s+/g, ' ').replace(/\s*([(),])\s*/g, '$1').trim();
const px = (v) => parseFloat(String(v));

function rootVars(css) {
  const m = css.match(/:root\s*\{([\s\S]*?)\n\}/);
  assert.ok(m, 'styles.css has no :root block');
  const vars = new Map();
  for (const d of m[1].replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) vars.set(d[1], d[2].trim());
  return vars;
}

// Every innermost `selectors { decls }` block, @media bodies included. The
// declarations of every block whose selector list names `sel`, in file order.
const RULES = [...CSS.replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/([^{}]+)\{([^{}]*)\}/g)]
  .map((m) => ({ sels: m[1].split(',').map((s) => s.trim().replace(/\s+/g, ' ')), body: m[2] }));
function decls(sel) {
  const hit = RULES.filter((r) => r.sels.includes(sel));
  assert.ok(hit.length, `no rule for ${sel}`);
  const out = {};
  for (const r of hit) {
    for (const d of r.body.matchAll(/([\w-]+)\s*:\s*([^;]+)/g)) out[d[1].trim()] = d[2].trim();
  }
  return out;
}
const allDecls = (sel) => RULES.filter((r) => r.sels.includes(sel)).map((r) => r.body).join(';');

function fakeDoc() {
  const props = {};
  const attrs = {};
  const metas = { 'color-scheme': { content: 'dark' }, 'theme-color': { content: '#000000' } };
  for (const m of Object.values(metas)) m.setAttribute = (k, v) => { m[k] = v; };
  return {
    props, attrs,
    documentElement: {
      style: { setProperty: (k, v) => { props[k] = v; } },
      setAttribute: (k, v) => { attrs[k] = v; }
    },
    querySelector: (s) => metas[(s.match(/name="([^"]+)"/) || [])[1]] || null
  };
}

function boot(store) {
  const doc = fakeDoc();
  const localStorage = { getItem: (k) => (Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null) };
  vm.runInContext(bootScript(), vm.createContext({ document: doc, window: { localStorage } }));
  return doc;
}

const { mill, phosphor } = BUILTIN_THEMES;
const paper = BUILTIN_THEMES.paper;
const JB = "'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";

// ----------------------------------------------------------------- shape

test('S1 shape and font tokens differ between Mill and Phosphor', () => {
  assert.ok(Array.isArray(SHAPE_TOKENS) && SHAPE_TOKENS.length === 13, 'SHAPE_TOKENS lists the thirteen form keys');
  for (const k of SHAPE_TOKENS) {
    assert.notEqual(norm(mill.shape[k]), norm(phosphor.shape[k]), `${k} is the same in Mill and Phosphor`);
  }
  assert.match(mill.shape['--font-display'], /^'Archivo'/);
  assert.match(mill.shape['--font-body'], /^'Geist'/);
  assert.match(mill.shape['--font-mono'], /^'Geist Mono'/);
  for (const k of ['--font-display', '--font-body', '--font-mono']) assert.equal(norm(phosphor.shape[k]), norm(JB), k);
  assert.equal(mill.shape['--display-stretch'], '75%');
  assert.equal(mill.shape['--label-case'], 'uppercase');
  assert.deepEqual(paper.shape, mill.shape);
});

test('S2 Phosphor\'s shape is today\'s :root, key for key', () => {
  const vars = rootVars(CSS);
  for (const k of SHAPE_TOKENS) {
    assert.ok(vars.has(k), `${k} is not declared in :root`);
    assert.equal(norm(phosphor.shape[k]), norm(vars.get(k)), k);
  }
});

test('S3 every theme sets every shape key; Mill panels are 10-14px, pills round, Phosphor square', () => {
  for (const id of THEME_ORDER) {
    assert.deepEqual(Object.keys(BUILTIN_THEMES[id].shape).sort(), [...SHAPE_TOKENS].sort(), `${id} shape keys`);
  }
  for (const k of ['--radius-md', '--radius-lg']) {
    const v = px(mill.shape[k]);
    assert.ok(v >= 10 && v <= 14, `Mill ${k} ${mill.shape[k]} is within 10..14px`);
  }
  assert.ok(px(mill.shape['--radius-pill']) >= 999);
  for (const k of ['--radius-sm', '--radius-md', '--radius-lg', '--radius-pill']) assert.equal(phosphor.shape[k], '2px', k);
  // Shape is not colour, so it stays out of `tokens` (BH-4844 C3/C5).
  for (const id of THEME_ORDER) for (const k of SHAPE_TOKENS) assert.ok(!(k in BUILTIN_THEMES[id].tokens), `${id} tokens has ${k}`);
});

test('S4 paintTheme writes the shape, and a switch resets every key', () => {
  const a = fakeDoc();
  paintTheme(a, mill);
  paintTheme(a, phosphor);
  for (const k of SHAPE_TOKENS) assert.equal(a.props[k], phosphor.shape[k], `Mill -> Phosphor left ${k}=${a.props[k]}`);
  const b = fakeDoc();
  paintTheme(b, phosphor);
  paintTheme(b, mill);
  for (const k of SHAPE_TOKENS) assert.equal(b.props[k], mill.shape[k], `Phosphor -> Mill left ${k}=${b.props[k]}`);
  assert.equal(b.attrs['data-theme'], 'mill');
});

test('S5 the boot script paints the shape before first paint', () => {
  const p = boot({ 'ui.theme': 'phosphor' });
  for (const k of SHAPE_TOKENS) assert.equal(p.props[k], phosphor.shape[k], `phosphor boot ${k}`);
  const m = boot({});
  for (const k of SHAPE_TOKENS) assert.equal(m.props[k], mill.shape[k], `default boot ${k}`);
  assert.match(m.props['--font-display'], /^'Archivo'/);
  assert.equal(m.props['--radius-pill'], '999px');
});

test('S6 Archivo, Geist and Geist Mono are self-hosted woff2 with their licence; no Google Fonts', () => {
  for (const fam of ['Archivo', 'Geist', 'Geist Mono']) {
    const re = new RegExp(`@font-face\\s*\\{[^}]*font-family:\\s*'${fam}';[^}]*url\\('/fonts/([\\w-]+\\.woff2)'\\)`);
    const m = CSS.match(re);
    assert.ok(m, `no @font-face for ${fam}`);
    const file = path.join(root, 'public', 'fonts', m[1]);
    assert.ok(fs.existsSync(file), `${m[1]} is not in public/fonts`);
    assert.equal(fs.readFileSync(file).subarray(0, 4).toString('latin1'), 'wOF2', `${m[1]} is a woff2`);
  }
  const ofl = fs.readFileSync(path.join(root, 'public', 'fonts', 'OFL.txt'), 'utf8');
  for (const name of ['Archivo', 'Geist', 'Geist Mono', 'SIL OPEN FONT LICENSE Version 1.1']) assert.ok(ofl.includes(name), `OFL.txt names ${name}`);
  assert.match(INDEX, /<link rel="preload" href="\/fonts\/geist-latin\.woff2" as="font" type="font\/woff2" crossorigin>/);
  const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]));
  for (const f of [...walk(path.join(root, 'src')), path.join(root, 'index.html')]) {
    assert.doesNotMatch(fs.readFileSync(f, 'utf8'), /fonts\.(googleapis|gstatic)/, f);
  }
});

test('S7 the form rules read the shape tokens; rules stay hairline', () => {
  const title = decls('.page-title');
  assert.equal(title['font-family'], 'var(--font-display)');
  assert.equal(title['font-stretch'], 'var(--display-stretch)');
  assert.equal(title['text-shadow'], 'var(--title-shadow)');
  const brand = decls('.topbar__title');
  assert.equal(brand['font-family'], 'var(--font-display)');
  assert.equal(brand['text-shadow'], 'var(--brand-shadow)');
  assert.equal(decls('.navlink--on')['box-shadow'], 'var(--nav-shadow)');
  assert.equal(decls('.stat--link:hover .stat__value')['text-shadow'], 'var(--stat-shadow)');
  for (const sel of ['.pill', '.tag', '.section__title', 'table.tbl th', '.btn', '.toggle']) {
    const d = decls(sel);
    assert.equal(d['font-family'], 'var(--font-mono)', `${sel} font-family`);
    assert.equal(d['text-transform'], 'var(--label-case)', `${sel} text-transform`);
  }
  for (const sel of ['.btn', '.pill', '.toggle']) assert.equal(decls(sel)['border-radius'], 'var(--radius-pill)', `${sel} radius`);
  for (const sel of ['.panel', '.stat', '.tr', '.card']) assert.equal(decls(sel)['border-radius'], 'var(--radius-md)', `${sel} radius`);
  for (const sel of ['.panel', '.tr']) assert.equal(decls(sel).border, '1px solid var(--line)', `${sel} border`);
  assert.match(allDecls('table.tbl th'), /border-bottom:\s*1px solid var\(--line\)/);
});

test('S8 Mill puts no brick glow on titles, the brand, the active nav tab or a stat', () => {
  for (const t of [mill, paper]) {
    for (const k of ['--title-shadow', '--brand-shadow', '--nav-shadow', '--stat-shadow']) {
      assert.equal(t.shape[k], 'none', `${t.id} ${k}`);
    }
  }
  assert.equal(phosphor.shape['--nav-shadow'], '0 0 14px var(--glow)');
  assert.equal(phosphor.shape['--stat-shadow'], '0 0 10px var(--glow)');
});

// ------------------------------------------------------- in-progress colour

test('L1 --live / --live-text: brick in Mill, today\'s green in Phosphor, and checked for contrast', () => {
  for (const k of ['--live', '--live-text']) assert.ok(EXTENDED_TOKENS.includes(k), `${k} is an extended token`);
  for (const t of [mill, paper]) {
    for (const k of ['--live', '--live-text']) {
      for (const other of ['--ok', '--warn']) {
        assert.notEqual(norm(t.tokens[k]), norm(t.tokens[other]), `${t.id} ${k} equals ${other}`);
      }
    }
  }
  assert.equal(mill.tokens['--live'], '#c8572f');
  assert.equal(phosphor.tokens['--live'], '#2E5A3A');
  assert.equal(phosphor.tokens['--live-text'], '#8CFFB0');
  for (const bg of ['--surface-0', '--surface-1', '--surface-2']) {
    assert.ok(TEXT_PAIRS.some(([f, b]) => f === '--live-text' && b === bg), `TEXT_PAIRS checks --live-text on ${bg}`);
  }
});

// The fill colour of each step span inside the first .build__bar of `html`.
function barFills(html) {
  const at = html.indexOf('class="build__bar"');
  assert.notEqual(at, -1, 'no stage bar in the render');
  const bar = html.slice(at, html.indexOf('</span>\n', at) === -1 ? undefined : at + 2000);
  return [...bar.matchAll(/background:(var\(--[\w-]+\)|transparent)/g)].slice(0, 6).map((m) => m[1]);
}

const build = {
  id: 88, project: 'project-1', ticket_key: 'TK-7', bkey: 'build:project-1:TK-7:1',
  stage: 'executing', tier: 2, merged: 0, verdict: null, pr_url: null, age_min: 4, detail: null
};

test('L2 the running step paints --live on /builds/:id, /now and /p/:project; the BUILDING card is card--green', () => {
  // /builds/:id: no live feed, so the strip follows the beat: plan done, execute running.
  const b = barFills(render(h(BuildMission, { build, live: null, liveError: null, timeline: [], artifactAction: async () => ({}) })));
  assert.deepEqual(b, ['var(--green)', 'var(--live)', 'transparent', 'transparent', 'transparent', 'transparent']);

  // /now BUILDING NOW: one running job at execute.
  const NOW = Date.UTC(2026, 9, 6, 12, 0);
  const ago = (s) => new Date(NOW - s * 1000).toISOString();
  const job = {
    id: 'build-cromford-BH-1-1', project: 'cromford', ticket_id: 'BH-1', kind: 'build', status: 'running',
    stage: 'execute', box: 'hub', heartbeating: true, activity_age_s: 30, beat_age_s: 30, last_beat_at: ago(30), created_at: ago(1800)
  };
  const nowHtml = render(h(NowView, {
    data: { data: { boards: [], active_builds: [], recent_runs: [], events: [], needs: { total: 0 } }, error: null, loading: false, reload() {} },
    jobs: { data: { jobs: [job], as_of: ago(0) }, error: null, loading: false, reload() {} },
    nowMs: NOW
  }));
  assert.deepEqual(barFills(nowHtml), ['var(--green)', 'var(--live)', 'transparent', 'transparent', 'transparent', 'transparent']);

  // /p/:project BUILDS table.
  const p = barFills(render(h(BuildsTable, { builds: [build], project: 'project-1' })));
  assert.deepEqual(p, ['var(--green)', 'var(--live)', 'transparent', 'transparent', 'transparent', 'transparent']);

  // /kanban: the BUILDING column card carries the in-progress class.
  const card = (id, ticket, stage) => ({ id, project: 'project-3', ticket, ticket_key: ticket, bkey: ticket, stage, age_min: 5, tier: 2 });
  const board = {
    columns: {
      queued: [], building: [card(1, 'TK-1', 'executing')], merge_queue: [], review: [],
      merged_deployed: [card(2, 'TK-2', 'merged')], dead_failed: []
    },
    counts: { queued: 0, building: 1, merge_queue: 0, review: 0, merged_deployed: 1, dead_failed: 0 },
    building_stale: 0, snapshot_age_min: 1
  };
  const kb = render(h(PipelineBoard, { board, external: [], shipped: null, showEmpty: false, emptyNote: '', onToggleAudit() {} }));
  assert.match(kb, /class="card card--green"[^>]*>[\s\S]*?TK-1/);
  assert.match(kb, /class="card card--done"[^>]*>[\s\S]*?TK-2/);

  // /jobs PHASE: a running job's active stage is pill--live; a finished one is not.
  const jr = (id, over) => ({
    id, project: 'project-3', kind: 'build', stage: 'execute', lane: 'build', box: 'project-3', status: 'running',
    created_at: ago(600), age_s: 600, heartbeating: true, beat_age_s: 30, ...over
  });
  const jobsHtml = render(h(JobsTable, { rows: jobRows({ jobs: [
    jr('j-run', { phase: 'execute', phase_status: 'running' }),
    jr('j-done', { status: 'done', phase: 'review', phase_status: 'done', phase_rc: 0 })
  ] }) }));
  const pillOf = (name) => (jobsHtml.match(new RegExp(`<span class="([^"]*)"[^>]*>\\s*${name}<`)) || [])[1];
  assert.equal(pillOf('EXECUTE'), 'pill pill--live');
  assert.equal(pillOf('REVIEW'), 'pill pill--muted');
});

test('L3 brick reaches in-progress only: done, blocked, dead, review, merge queue and titles never read it', () => {
  assert.equal(decls('.card--green')['border-left-color'], 'var(--accent)');
  assert.equal(decls('.build__stages .on').color, 'var(--live-text)');
  assert.equal(decls('.build__sub').color, 'var(--live-text)');
  assert.equal(decls('.card__age--live').color, 'var(--live-text)');
  assert.equal(decls('.pill--live').color, 'var(--live-text)');
  assert.equal(decls('.pill--live')['border-color'], 'var(--live)');
  for (const sel of ['.card--done', '.build__stages .done', '.card--dead', '.card--stale', '.kb__stale', '.card--cyan', '.card--bright',
    '.pill--muted', '.navlink--on', '.stat--link:hover .stat__value']) {
    assert.doesNotMatch(allDecls(sel), /var\(--(live|live-text|accent)\)/, `${sel} reads an in-progress colour`);
  }
  // The nav tab and a hovered stat are not states: no raw --glow (brick in Mill)
  // either, only their shape key, which Mill sets to none (S8).
  for (const sel of ['.navlink--on', '.stat--link:hover .stat__value']) {
    assert.doesNotMatch(allDecls(sel), /var\(--glow\)/, `${sel} reads --glow directly`);
  }
  assert.match(allDecls('.card--done'), /var\(--green/);
  assert.match(allDecls('.card--stale') + allDecls('.kb__stale'), /var\(--(amber|warn)/);
  // A finished build: every step green, none --live.
  const done = barFills(render(h(BuildMission, {
    build: { ...build, stage: 'merged', merged: 1 }, live: null, liveError: null, timeline: [], artifactAction: async () => ({})
  })));
  assert.deepEqual(done, Array(6).fill('var(--green)'));
});
