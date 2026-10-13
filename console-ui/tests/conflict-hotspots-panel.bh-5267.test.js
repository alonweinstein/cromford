import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { hotspotCells, panelNote, HOTSPOTS_SHOWN } from '../src/lib/conflict-hotspots-panel.js';
import ConflictHotspotsPanel from '../src/screens/ConflictHotspotsPanel.js';
import { flush } from './helpers/settle.js';

// BH-5267: the CONFLICT HOTSPOTS section of /p/<project>. Body shape from
// GET /api/conflict-hotspots (worker/jobs): { project, run: null | {...},
// hotspots: [{ file, conflicts, rebases, prs, ... }], total, truncated, as_of }.
// `prs` is bin/conflict-hotspots.sh's raw comma-separated PR-ids column.

const SHA = '0123456789abcdef0123456789abcdef01234567';
const NOW = Date.now();  // determinism: ok every fixture timestamp below is an offset from this one read
const iso = (minAgo) => new Date(NOW - minAgo * 60000).toISOString();
const okRun = (o) => ({ project: 'cromford', repo: 'example-org/cromford', box: 'hub', status: 'ok',
  detail: null, window_days: 30, since: iso(43200), until: iso(60), ref_sha: SHA, pr_merges: 40, sync_merges: 3,
  merge_tree_errors: 0, files_total: 12, rows_stored: 2, run_at: iso(60), last_ok_at: iso(60), ...o });

// ---- C1 / C2: the pure half ----

test('C1: hotspotCells turns "#12,#7,ticket/x" into two PR links and one plain label', () => {
  const c = hotspotCells({ file: 'bin/a.sh', prs: '#12,#7,ticket/x' }, 'cromford', okRun());
  assert.deepEqual(c.prs, [
    { label: '#12', href: '/pr/cromford/12' },
    { label: '#7', href: '/pr/cromford/7' },
    { label: 'ticket/x', href: null }
  ]);
  assert.deepEqual(hotspotCells({ prs: ' #3 , ,#4,' }, 'a b', null).prs,
    [{ label: '#3', href: '/pr/a%20b/3' }, { label: '#4', href: '/pr/a%20b/4' }], 'trimmed, empties dropped, project encoded');
  for (const v of [null, undefined, '', ' , ']) {
    assert.deepEqual(hotspotCells({ prs: v }, 'p', null).prs, [], `prs=${JSON.stringify(v)}`);
  }
  // Only #<digits> is a PR: a bare number, #0, #x and #12a stay text.
  assert.deepEqual(hotspotCells({ prs: '12,#0,#x,#12a' }, 'p', null).prs.map((p) => p.href), [null, null, null, null]);
});

test('C2: fileHref is the GitHub commits URL at ref_sha, null when repo or sha is missing', () => {
  const row = { file: 'console-ui/src/My File#1.js', ref_sha: SHA };
  assert.equal(hotspotCells(row, 'p', okRun()).fileHref,
    `https://github.com/example-org/cromford/commits/${SHA}/console-ui/src/My%20File%231.js`);
  // the run's sha stands in for a row without one
  assert.equal(hotspotCells({ file: 'bin/a.sh' }, 'p', okRun()).fileHref,
    `https://github.com/example-org/cromford/commits/${SHA}/bin/a.sh`);
  assert.equal(hotspotCells(row, 'p', okRun({ repo: null })).fileHref, null, 'no repo');
  assert.equal(hotspotCells({ file: 'bin/a.sh', ref_sha: null }, 'p', okRun({ ref_sha: null })).fileHref, null, 'no sha');
  assert.equal(hotspotCells({ file: 'bin/a.sh', ref_sha: '' }, 'p', okRun({ ref_sha: '' })).fileHref, null, 'blank sha');
  assert.equal(hotspotCells(row, 'p', null).fileHref, null, 'no run');
  assert.equal(hotspotCells({ file: '', ref_sha: SHA }, 'p', okRun()).fileHref, null, 'no file');
});

test('panelNote: never measured, last measured, and a failed latest run say only what is true', () => {
  assert.equal(HOTSPOTS_SHOWN, 50);
  assert.equal(panelNote(null, NOW), 'never measured');
  assert.equal(panelNote(okRun({ run_at: iso(120) }), NOW), 'last measured 2h ago, 30-day window');
  const kept = panelNote(okRun({ status: 'timeout', run_at: iso(5), last_ok_at: iso(180) }), NOW);
  assert.equal(kept, 'latest run failed: timeout — showing the window from 3h ago');
  const none = panelNote(okRun({ status: 'fetch-failed', detail: 'git fetch rc=128', last_ok_at: null }), NOW);
  assert.equal(none, 'latest run failed: fetch-failed (git fetch rc=128) — no successful run yet');
  assert.doesNotMatch(none, /showing/);
});

// ---- the component, mounted into a minimal DOM (merge-trains-panel.bh-2510 pattern) ----
class FakeNode {
  constructor(nodeType, name, data) {
    Object.assign(this, { nodeType, localName: name, nodeName: name ? name.toUpperCase() : '#text', data,
      childNodes: [], parentNode: null, attrs: {}, style: {}, listeners: {} });
  }
  get firstChild() { return this.childNodes[0] || null; }
  get nextSibling() {
    if (!this.parentNode) return null;
    const s = this.parentNode.childNodes;
    return s[s.indexOf(this) + 1] || null;
  }
  insertBefore(n, ref) {
    if (n.parentNode) n.parentNode.removeChild(n);
    n.parentNode = this;
    const i = ref ? this.childNodes.indexOf(ref) : -1;
    if (i < 0) this.childNodes.push(n); else this.childNodes.splice(i, 0, n);
    return n;
  }
  appendChild(n) { return this.insertBefore(n, null); }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n; }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  removeAttribute(k) { delete this.attrs[k]; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(t, fn) { this.listeners[t] = fn; }
  removeEventListener(t) { delete this.listeners[t]; }
  get onclick() { return null; } // preact lowercases the event name only when on<name> exists
  focus() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const byTag = (root, tag) => all(root).filter((n) => n.localName === tag);
const click = (n) => n.listeners.click.call(n, { type: 'click', target: n, currentTarget: n });
const mounted = [];
afterEach(() => { while (mounted.length) mount(null, mounted.pop()); });

const URL_50 = '/api/coord/conflict-hotspots?project=cromford&limit=50';
const spot = (o) => ({ file: 'bin/a.sh', conflicts: 1, rebases: 0, prs: '', window_days: 30,
  since: iso(43200), until: iso(60), ref_sha: SHA, run_at: iso(60), ...o });
const body = (o) => ({ project: 'cromford', run: okRun(), hotspots: [], total: 0, truncated: false, as_of: iso(0), ...o });

// answer(url, n) -> {status, body}; every call is recorded.
async function mountPanel(answer) {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET' });
    const { status = 200, body: b } = answer(String(url), calls.length);
    return { ok: status < 400, status, text: async () => JSON.stringify(b) };
  };
  const root = doc.createElement('div');
  mount(h(ConflictHotspotsPanel, { project: 'cromford' }), root);
  mounted.push(root);
  await flush();
  await flush();
  return { root, calls };
}

const THREE = [
  spot({ file: 'bin/low.sh', conflicts: 2, rebases: 9, prs: '#3' }),
  spot({ file: 'bin/high.sh', conflicts: 11, rebases: 1, prs: '#12,#7,ticket/x' }),
  spot({ file: 'bin/mid.sh', conflicts: 5, rebases: 4, prs: null })
];

test('C3: every #N in the rendered panel is an anchor to /pr/<project>/<N>; names stay text', async () => {
  const { root, calls } = await mountPanel(() => ({ body: body({ hotspots: THREE, total: 3 }) }));
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [['GET', URL_50]]);
  const hrefs = byTag(root, 'a').map((a) => a.attrs.href);
  for (const n of [12, 7, 3]) assert.ok(hrefs.includes(`/pr/cromford/${n}`), `#${n}: ${hrefs.join(' ')}`);
  const prAnchors = byTag(root, 'a').filter((a) => /^#/.test(a.textContent.trim()));
  assert.deepEqual(prAnchors.map((a) => [a.textContent.trim(), a.attrs.href]).sort(),
    [['#12', '/pr/cromford/12'], ['#3', '/pr/cromford/3'], ['#7', '/pr/cromford/7']]);
  assert.ok(byTag(root, 'a').every((a) => a.textContent.trim() !== 'ticket/x'), 'a branch name is not a link');
  assert.match(root.textContent, /ticket\/x/);
  // the file cell links to its history at the measured sha
  assert.ok(hrefs.includes(`https://github.com/example-org/cromford/commits/${SHA}/bin/high.sh`), hrefs.join(' '));
});

test('C3: without a repo the file is plain text, never a made-up link', async () => {
  const { root } = await mountPanel(() => ({ body: body({ run: okRun({ repo: null }), hotspots: THREE, total: 3 }) }));
  assert.ok(byTag(root, 'a').every((a) => !/github\.com/.test(a.attrs.href || '')));
  assert.match(root.textContent, /bin\/high\.sh/);
});

test('C4: every header is a sortable button; CONFLICTS sorts desc by default and a click flips aria-sort', async () => {
  const { root } = await mountPanel(() => ({ body: body({ hotspots: THREE, total: 3 }) }));
  const heads = () => byTag(root, 'th');
  assert.deepEqual(heads().map((t) => t.textContent.replace(/[↑↓]/g, '').trim()), ['FILE', 'CONFLICTS', 'REBASES', 'PRS']);
  assert.ok(heads().every((t) => byTag(t, 'button').length === 1), 'every header sorts');
  assert.ok(all(root).some((n) => n.attrs && /\btablewrap\b/.test(n.attrs.class || '')), 'the table scrolls inside its own wrapper');
  const files = () => byTag(byTag(root, 'tbody')[0], 'tr').map((tr) => byTag(tr, 'td')[0].textContent.trim());
  assert.equal(heads()[1].attrs['aria-sort'], 'descending');
  assert.deepEqual(files(), ['bin/high.sh', 'bin/mid.sh', 'bin/low.sh']);
  click(byTag(heads()[1], 'button')[0]);
  await flush();
  assert.equal(heads()[1].attrs['aria-sort'], 'ascending');
  assert.deepEqual(files(), ['bin/low.sh', 'bin/mid.sh', 'bin/high.sh']);
  click(byTag(heads()[2], 'button')[0]);
  await flush();
  assert.equal(heads()[2].attrs['aria-sort'], 'ascending');
  assert.equal(heads()[1].attrs['aria-sort'], 'none');
  assert.deepEqual(files(), ['bin/high.sh', 'bin/mid.sh', 'bin/low.sh'], 'REBASES ascending');
});

for (const [name, answer] of [
  ['a 500', () => ({ status: 500, body: { error: 'boom' } })],
  ['a body without hotspots', () => ({ body: { project: 'cromford', run: null } })]
]) {
  test(`C5: ${name} is an ErrorBox with RETRY, never "NO HOTSPOTS" or "NOT MEASURED YET"`, async () => {
    const { root, calls } = await mountPanel(answer);
    assert.match(root.textContent, /could not load/);
    assert.doesNotMatch(root.textContent, /NO HOTSPOTS|NOT MEASURED YET/);
    assert.equal(byTag(root, 'table').length, 0);
    const retry = byTag(root, 'button').find((b) => b.textContent.trim() === 'RETRY');
    assert.ok(retry, 'a RETRY button');
    click(retry);
    await flush();
    assert.equal(calls.length, 2, 'RETRY issues a second read');
    assert.ok(calls.every((c) => c.method === 'GET' && c.url === URL_50));
  });
}

test('C5: run:null is "NOT MEASURED YET", not "NO HOTSPOTS"', async () => {
  const { root } = await mountPanel(() => ({ body: body({ run: null }) }));
  assert.match(root.textContent, /NOT MEASURED YET/);
  assert.doesNotMatch(root.textContent, /NO HOTSPOTS|could not load/);
});

test('C5: an ok run with zero rows is "NO HOTSPOTS" with the run note', async () => {
  const { root } = await mountPanel(() => ({ body: body({ run: okRun({ run_at: iso(120) }) }) }));
  assert.match(root.textContent, /NO HOTSPOTS/);
  assert.match(root.textContent, /last measured 2h ago, 30-day window/);
  assert.doesNotMatch(root.textContent, /NOT MEASURED YET|could not load/);
  assert.equal(byTag(root, 'table').length, 0);
});

test('C5: truncated shows the capped note; untruncated does not', async () => {
  const a = await mountPanel(() => ({ body: body({ hotspots: THREE, total: 120, truncated: true }) }));
  assert.match(a.root.textContent, /showing 3 of 120/);
  mount(null, mounted.pop());
  const b = await mountPanel(() => ({ body: body({ hotspots: THREE, total: 3, truncated: false }) }));
  assert.doesNotMatch(b.root.textContent, /showing 3 of/);
});

test('C5: a non-ok run puts "latest run failed" above the kept rows', async () => {
  const { root } = await mountPanel(() => ({ body: body({
    run: okRun({ status: 'timeout', run_at: iso(5), last_ok_at: iso(180) }), hotspots: THREE, total: 3 }) }));
  const text = root.textContent;
  assert.match(text, /latest run failed: timeout — showing the window from 3h ago/);
  assert.ok(text.indexOf('latest run failed') < text.indexOf('bin/high.sh'), 'the note sits above the table');
  assert.equal(byTag(byTag(root, 'tbody')[0], 'tr').length, 3, 'the kept rows still render');
});

test('C5: a failed run with no good window yet is "NOT MEASURED YET", never "NO HOTSPOTS"', async () => {
  const { root } = await mountPanel(() => ({ body: body({ run: okRun({ status: 'error', last_ok_at: null }) }) }));
  assert.match(root.textContent, /NOT MEASURED YET/);
  assert.match(root.textContent, /latest run failed: error — no successful run yet/);
  assert.doesNotMatch(root.textContent, /NO HOTSPOTS/);
});

test('before the first answer it is a skeleton, neither an error nor an empty state', async () => {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.fetch = () => new Promise(() => {});
  const root = doc.createElement('div');
  mount(h(ConflictHotspotsPanel, { project: 'cromford' }), root);
  mounted.push(root);
  await flush();
  assert.ok(all(root).some((n) => n.attrs && n.attrs.class === 'skel'), 'a skeleton while loading');
  assert.doesNotMatch(root.textContent, /could not load|NO HOTSPOTS|NOT MEASURED YET/);
});

test('D2: the real Project page mounts CONFLICT HOTSPOTS beside PREPLAN ADOPTION and reads the newest 50', async () => {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, method: init.method || 'GET' });
    const b = u.startsWith('/api/dash/p/') ? { board: {}, runs: [], builds: [], alerts: [], events: [] }
      : u.startsWith('/api/coord/conflict-hotspots?') ? body({ hotspots: THREE, total: 3 }) : {};
    return { ok: true, status: 200, text: async () => JSON.stringify(b) };
  };
  const { ProjectScreen } = await import('../src/screens/Project.js');
  const root = doc.createElement('div');
  mount(h(ProjectScreen, { project: 'cromford' }), root);
  mounted.push(root);
  await flush();
  await flush();
  const titles = all(root).filter((n) => n.attrs && n.attrs.class === 'section__title').map((n) => n.textContent);
  assert.equal(titles.filter((t) => t === 'CONFLICT HOTSPOTS').length, 1, titles.join(', '));
  assert.equal(titles.indexOf('CONFLICT HOTSPOTS'), titles.indexOf('PREPLAN ADOPTION') + 1, titles.join(', '));
  const section = all(root).find((n) => n.attrs && n.attrs.class === 'section__title'
    && n.textContent === 'CONFLICT HOTSPOTS').parentNode.parentNode;
  assert.match(section.textContent, /files that conflicted or were rebased most, measured weekly on this project's box/);
  assert.ok(byTag(section, 'a').some((a) => a.attrs.href === '/pr/cromford/12'));
  assert.deepEqual(calls.filter((c) => /conflict-hotspots/.test(c.url)).map((c) => `${c.method} ${c.url}`), [`GET ${URL_50}`]);
});
