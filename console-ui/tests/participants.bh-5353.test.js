import test, { afterEach, mock } from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { flush } from './helpers/settle.js';

// BH-5353 (BH-5348.4): the Mission Control participants screen. The pending
// approval card, APPROVE / DENY / REVOKE through the in-app modal, the sorted
// table of enrolled machines and the detail view, mounted through the real
// screen and the real api client with a faked fetch. window.confirm, alert
// and prompt throw: a native dialog anywhere is a failure.

const native = () => { throw new Error('a native dialog was called'); };
globalThis.window = globalThis.window || {
  location: { pathname: '/machines/participants', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};
Object.assign(globalThis.window, { confirm: native, alert: native, prompt: native });

const { render } = await import('preact-render-to-string');
const { ParticipantsScreen, ParticipantScreen, isOnline, prRoute, approveBody } = await import('../src/screens/Participants.js');
const { MachinesScreen } = await import('../src/screens/Machines.js');
const { ROUTES, NAV } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');

const P1 = '11111111-1111-1111-1111-111111111111';
const P2 = '22222222-2222-2222-2222-222222222222';
const P3 = '33333333-3333-3333-3333-333333333333';
// The screen asks the clock whether a machine is online, so Date is pinned to
// one anchor for the whole file and every "recent" fixture is derived from it.
const ANCHOR = Date.parse('2026-10-08T12:00:00Z');
mock.timers.enable({ apis: ['Date'], now: ANCHOR });
const recent = () => new Date(ANCHOR - 60 * 1000).toISOString();

const PENDING = { id: P1, name: 'mac-new', owner: 'operator', status: 'pending', requested_roles: ['lead-review', 'fix'], granted_roles: null,
  requested_at: '2026-10-08T01:00:00Z', billing_account: 'acct-7', last_seen_at: null, knobs: {}, claims: 0, last_result: null };
const APPROVED = () => ({ id: P2, name: 'mac-a', owner: 'dana', status: 'approved', requested_roles: ['lead-review'], granted_roles: ['lead-review'],
  requested_at: '2026-10-07T01:00:00Z', billing_account: null, last_seen_at: recent(), knobs: {}, claims: 2,
  last_result: { verdict: 'MERGE', repo: 'example-org/cromford', pr: 41, project: null, at: '2026-10-08T00:30:00Z' } });
const REVOKED = { id: P3, name: 'zz-old', owner: null, status: 'revoked', requested_roles: ['fix'], granted_roles: ['fix'],
  requested_at: '2026-10-01T01:00:00Z', billing_account: null, last_seen_at: null, knobs: {}, claims: 0, last_result: null };
const list = (participants) => ({ participants, truncated: false, online_window_s: 900 });

// ---- the fake DOM (the build-queue-panel.bh-2510 pattern) ------------------
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
  addEventListener(t, fn) { this.listeners[t.toLowerCase()] = fn; (this.types = this.types || {})[t.toLowerCase()] = t; }
  removeEventListener(t) { delete this.listeners[t.toLowerCase()]; }
  focus() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
let mounted = null;
afterEach(async () => {
  if (mounted) { const { render: mount } = await import('preact'); mount(null, mounted); mounted = null; }
});

async function mountScreen(vnode, respond) {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, method: init.method || 'GET', body: init.body });
    const [status, body] = respond(u, init);
    return { ok: status < 300, status, text: async () => JSON.stringify(body) };
  };
  const { render: mount } = await import('preact');
  const root = doc.createElement('div');
  mount(vnode, root);
  mounted = root;
  await flush();
  return { root, calls };
}
const byText = (root, tag, text) => all(root).filter((n) => n.localName === tag && n.textContent.trim() === text);
const modalBox = (root) => all(root).find((n) => n.attrs && n.attrs.class === 'modal__actions');
const modalBtn = (root, text) => { const box = modalBox(root); return box ? byText(box, 'button', text)[0] : undefined; };
const fire = (node, type, extra = {}) => node.listeners[type].call(node, { type: node.types[type], button: 0, preventDefault() {}, ...extra });
const cards = (root) => all(root).filter((n) => n.attrs && n.attrs['data-testid'] === 'participant-pending');
const boxes = (root) => all(root).filter((n) => n.localName === 'input' && n.attrs.type === 'checkbox');
const isDisabled = (n) => n.attrs.disabled !== undefined || n.disabled === true;
const isChecked = (n) => n.attrs.checked !== undefined || n.checked === true;
const hrefs = (root) => all(root).filter((n) => n.localName === 'a').map((n) => n.attrs.href);
const posts = (calls) => calls.filter((c) => c.method === 'POST');

// ---- pure helpers -----------------------------------------------------------
test('7. isOnline: within the window, outside it, and never a guess on null or garbage', () => {
  const now = Date.parse('2026-10-08T12:00:00Z');
  assert.equal(isOnline('2026-10-08T11:58:00Z', 900, now), true);
  assert.equal(isOnline('2026-10-08T11:00:00Z', 900, now), false);
  assert.equal(isOnline(null, 900, now), false);
  assert.equal(isOnline('soon', 900, now), false);
  assert.equal(isOnline('2026-10-08T11:58:00Z', undefined, now), false);
  assert.equal(isOnline('2026-10-08T11:58:00Z', 0, now), false);
});

test('prRoute: project from the join, else the repo basename; null without a pr', () => {
  assert.equal(prRoute({ project: 'project-3', repo: 'example-org/project-3', pr: 3 }), '/pr/project-3/3');
  assert.equal(prRoute({ project: null, repo: 'example-org/cromford', pr: 41 }), '/pr/cromford/41');
  assert.equal(prRoute({ project: null, repo: null, pr: 41 }), null);
  assert.equal(prRoute({ project: 'p', repo: 'a/p', pr: null }), null);
  assert.deepEqual(approveBody(['lead-review']), { granted_roles: ['lead-review'] });
});

// ---- the list screen --------------------------------------------------------
test('1. one approval card per pending row, a ticked checkbox per requested role; the approved row is in the table', async () => {
  const { root, calls } = await mountScreen(h(ParticipantsScreen), () => [200, list([PENDING, APPROVED()])]);
  assert.deepEqual(calls.map((c) => `${c.method} ${c.url}`), ['GET /api/coord/participants']);
  const c = cards(root);
  assert.equal(c.length, 1);
  assert.match(c[0].textContent, /mac-new/);
  assert.match(c[0].textContent, /operator/);
  assert.match(c[0].textContent, /acct-7/);
  const cb = boxes(c[0]);
  assert.equal(cb.length, 2);
  assert.ok(cb.every(isChecked), 'every requested role starts ticked');
  assert.ok(!c[0].textContent.includes('mac-a'), 'the approved row is not a card');
  assert.ok(hrefs(root).includes(`/machines/participants/${P2}`), 'the approved row is in the table');
  assert.ok(!hrefs(root).includes(`/machines/participants/${P1}`), 'the pending row is not in the table');
});

test('2. APPROVE with fix unticked opens the in-app modal and posts only the ticked role, then reloads; CANCEL posts nothing', async () => {
  let approved = false;
  const { root, calls } = await mountScreen(h(ParticipantsScreen), (u, init) => {
    if (init.method === 'POST') { approved = true; return [200, { participant: { ...PENDING, status: 'approved', granted_roles: ['lead-review'] } }]; }
    return [200, list(approved ? [{ ...PENDING, status: 'approved', granted_roles: ['lead-review'] }, APPROVED()] : [PENDING, APPROVED()])];
  });
  const fix = boxes(cards(root)[0])[1];
  fire(fix, 'change');
  await flush();
  assert.equal(isChecked(boxes(cards(root)[0])[1]), false, 'fix is unticked');

  // CANCEL first: nothing is sent
  fire(byText(cards(root)[0], 'button', 'APPROVE')[0], 'click');
  await flush();
  assert.ok(modalBox(root), 'the in-app dialog is open');
  assert.match(root.textContent, /Grants: lead-review/);
  fire(modalBtn(root, 'CANCEL'), 'click');
  await flush();
  assert.equal(posts(calls).length, 0, 'a cancelled dialog posts nothing');

  fire(byText(cards(root)[0], 'button', 'APPROVE')[0], 'click');
  await flush();
  fire(modalBtn(root, 'APPROVE'), 'click');
  await flush(); await flush();
  const p = posts(calls);
  assert.equal(p.length, 1);
  assert.equal(p[0].url, `/api/coord/participants/${P1}/approve`);
  assert.deepEqual(JSON.parse(p[0].body), { granted_roles: ['lead-review'] });
  assert.equal(calls.filter((c) => c.method === 'GET').length, 2, 'the list reloads after the decision');
  assert.equal(cards(root).length, 0, 'the approved machine left the cards');
  assert.ok(hrefs(root).includes(`/machines/participants/${P1}`), 'and is in the table');
});

test('3. every role unticked: APPROVE is disabled', async () => {
  const { root } = await mountScreen(h(ParticipantsScreen), () => [200, list([PENDING])]);
  for (const i of [0, 1]) { fire(boxes(cards(root)[0])[i], 'change'); await flush(); }
  assert.ok(isDisabled(byText(cards(root)[0], 'button', 'APPROVE')[0]));
  assert.ok(!isDisabled(byText(cards(root)[0], 'button', 'DENY')[0]), 'DENY stays available');
});

test('4. DENY goes through the modal and posts an empty body', async () => {
  const { root, calls } = await mountScreen(h(ParticipantsScreen), (u, init) =>
    (init.method === 'POST' ? [200, { participant: { ...PENDING, status: 'denied' } }] : [200, list([PENDING])]));
  fire(byText(cards(root)[0], 'button', 'DENY')[0], 'click');
  await flush();
  fire(modalBtn(root, 'DENY'), 'click');
  await flush(); await flush();
  const p = posts(calls);
  assert.equal(p.length, 1);
  assert.equal(p[0].url, `/api/coord/participants/${P1}/deny`);
  assert.deepEqual(JSON.parse(p[0].body), {});
});

test('5. a 409 shows the worker\'s text in a warn banner, with no success copy and no reload', async () => {
  const { root, calls } = await mountScreen(h(ParticipantsScreen), (u, init) =>
    (init.method === 'POST' ? [409, { error: 'participant is denied; approve needs pending' }] : [200, list([PENDING])]));
  fire(byText(cards(root)[0], 'button', 'APPROVE')[0], 'click');
  await flush();
  fire(modalBtn(root, 'APPROVE'), 'click');
  await flush(); await flush();
  const warn = all(root).find((n) => n.attrs && n.attrs.class === 'banner banner--warn');
  assert.ok(warn, 'a warn banner');
  assert.match(warn.textContent, /participant is denied; approve needs pending/);
  assert.ok(!/approved mac-new/i.test(root.textContent), 'no success copy');
  assert.equal(calls.filter((c) => c.method === 'GET').length, 1, 'no reload after a refusal');
  assert.ok(!isDisabled(byText(cards(root)[0], 'button', 'APPROVE')[0]), 'buttons are live again');
});

test('6. the table: NAME sorts with aria-sort, links to the detail, LAST RESULT links to its PR', async () => {
  const { root } = await mountScreen(h(ParticipantsScreen), () => [200, list([REVOKED, APPROVED()])]);
  const th = () => all(root).find((n) => n.localName === 'th' && n.textContent.trim().startsWith('NAME'));
  const names = () => all(root).filter((n) => n.localName === 'a' && /^\/machines\/participants\/./.test(n.attrs.href)).map((n) => n.textContent.trim());
  fire(byText(th(), 'button', 'NAME')[0] || th().childNodes.find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.equal(th().attrs['aria-sort'], 'ascending');
  assert.deepEqual(names(), ['mac-a', 'zz-old']);
  fire(th().childNodes.find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.equal(th().attrs['aria-sort'], 'descending');
  assert.deepEqual(names(), ['zz-old', 'mac-a']);
  assert.ok(hrefs(root).includes(`/machines/participants/${P2}`));
  assert.ok(hrefs(root).includes('/pr/cromford/41'), 'last result links to its PR');
  assert.match(root.textContent, /online/);
  assert.match(root.textContent, /never/, 'a null heartbeat reads never');
  for (const hd of ['NAME', 'OWNER', 'ROLES', 'STATUS', 'LAST HEARTBEAT', 'CLAIMS', 'LAST RESULT']) {
    assert.ok(all(root).some((n) => n.localName === 'th' && n.textContent.trim().startsWith(hd)), `header ${hd}`);
  }
});

test('8. empty and error render differently', async () => {
  const empty = await mountScreen(h(ParticipantsScreen), () => [200, list([])]);
  assert.match(empty.root.textContent, /no machines enrolled/);
  assert.equal(byText(empty.root, 'button', 'RETRY').length, 0);
  const { render: mount } = await import('preact'); mount(null, mounted); mounted = null;

  const err = await mountScreen(h(ParticipantsScreen), () => [503, { error: 'participant_machines unavailable' }]);
  assert.equal(byText(err.root, 'button', 'RETRY').length, 1);
  assert.match(err.root.textContent, /participant_machines unavailable/);
  assert.ok(!/no machines enrolled/.test(err.root.textContent), 'an error is never shown as empty');
});

const scrollsInOwnBox = (root, want) => {
  const tables = all(root).filter((n) => n.localName === 'table');
  assert.equal(tables.length, want);
  for (const t of tables) {
    let p = t.parentNode; let ok = false;
    while (p) { if (/overflow-x:\s*auto/.test(p.style.cssText || p.attrs.style || '')) { ok = true; break; } p = p.parentNode; }
    assert.ok(ok, 'the table scrolls inside its own container');
  }
};
test('10. every table sits in its own overflow-x:auto container', async () => {
  const { root } = await mountScreen(h(ParticipantsScreen), () => [200, list([APPROVED()])]);
  scrollsInOwnBox(root, 1);
});

// ---- the detail screen ------------------------------------------------------
const DETAIL = (status = 'approved') => ({
  participant: { ...APPROVED(), status },
  claims: [{ id: 'r1', repo: 'example-org/cromford', pr: 50, head_sha: 'abc', status: 'running', verdict: null, heartbeat_at: recent(), updated_at: recent(), project: 'cromford' }],
  results: [{ id: 'r2', repo: 'example-org/project-3', pr: 9, head_sha: 'def', status: 'done', verdict: 'BLOCK', heartbeat_at: null, updated_at: '2026-10-07T00:00:00Z', project: 'project-3' }],
  truncated: false, online_window_s: 900,
});

test('9. detail: claims and results link to their PRs; REVOKE through the modal, then the reload reads revoked', async () => {
  let revoked = false;
  const { root, calls } = await mountScreen(h(ParticipantScreen, { id: P2 }), (u, init) => {
    if (init.method === 'POST') { revoked = true; return [200, { participant: { ...APPROVED(), status: 'revoked' } }]; }
    return [200, DETAIL(revoked ? 'revoked' : 'approved')];
  });
  assert.equal(calls[0].url, `/api/coord/participants/${P2}`);
  assert.ok(hrefs(root).includes('/pr/cromford/50'));
  assert.ok(hrefs(root).includes('/pr/project-3/9'));
  assert.ok(hrefs(root).includes('/machines/participants'), 'crumb back to the list');
  scrollsInOwnBox(root, 2);
  fire(byText(root, 'button', 'REVOKE')[0], 'click');
  await flush();
  fire(modalBtn(root, 'REVOKE'), 'click');
  await flush(); await flush();
  const p = posts(calls);
  assert.equal(p.length, 1);
  assert.equal(p[0].url, `/api/coord/participants/${P2}/revoke`);
  assert.deepEqual(JSON.parse(p[0].body), {});
  assert.match(root.textContent, /revoked/);
  assert.equal(byText(root, 'button', 'REVOKE').length, 0, 'REVOKE is gone once revoked');
});

test('9b. detail: no REVOKE on a revoked row; empty lists say so; a 404 is its own empty state', async () => {
  const r = await mountScreen(h(ParticipantScreen, { id: P3 }), () => [200, { ...DETAIL('revoked'), claims: [], results: [] }]);
  assert.equal(byText(r.root, 'button', 'REVOKE').length, 0);
  assert.match(r.root.textContent, /no claims/);
  assert.match(r.root.textContent, /no results/);
  const { render: mount } = await import('preact'); mount(null, mounted); mounted = null;

  const nf = await mountScreen(h(ParticipantScreen, { id: P1 }), () => [404, { error: 'no such participant' }]);
  assert.match(nf.root.textContent, /no such participant/);
  assert.equal(byText(nf.root, 'button', 'RETRY').length, 0, 'a 404 is not a load failure');
});

// ---- nav --------------------------------------------------------------------
test('11. nav: routes resolve to the new screens, FLEET is active, MACHINES links to the list', () => {
  const resolve = (path) => { for (const [p, C] of ROUTES) { const m = matchRoute(p, path); if (m) return [C, m]; } return null; };
  assert.equal(resolve('/machines/participants')[0], ParticipantsScreen);
  const [C, params] = resolve(`/machines/participants/${P2}`);
  assert.equal(C, ParticipantScreen);
  assert.deepEqual(params, { id: P2 });
  assert.equal(resolve('/machines')[0], MachinesScreen, '/machines is untouched');
  const fleet = NAV.find((n) => n.label === 'FLEET');
  assert.equal(fleet.match('/machines/participants'), true);
  assert.equal(fleet.match(`/machines/participants/${P2}`), true);
  const out = render(h(MachinesScreen));
  assert.ok(out.includes('href="/machines/participants"'), 'SEE PARTICIPANTS links to the screen');
  assert.match(out, /SEE PARTICIPANTS/);
});
