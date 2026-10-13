import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { api } from '../src/api.js';
import { useTicketHold, TicketHoldControl } from '../src/ui/TicketHold.js';
import { BuildScreen } from '../src/screens/Build.js';
import { flush } from './helpers/settle.js';

// BH-2326.3 (#3149): the HOLD / UNHOLD control on /builds/<id>. The fixtures
// are the shapes the BH-2326.0 contract produces: the worker's ledger row,
// its 404 {error:'not found'} for an absent row, and /api/dash/action's
// {command_id}.

const HELD_ROW = { ledger: { kind: 'ticket_hold', key: 'cromford#7', status: 'held', detail: 'hold by operator at 2026-09-28T10:00:00Z: x | y' } };
const LEDGER = '/api/coord/ledger?';
const ACTION = '/api/dash/action';

// Routed by URL; `action` answers the POST, `ledger` the hold read.
function routedFetch({ ledger = [404, { error: 'not found' }], action = [200, { command_id: 42 }], extra } = {}) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    calls.push({ url: u, method, body: init.body ? JSON.parse(init.body) : undefined });
    let a = extra ? extra(u, method) : null;
    if (!a && u.startsWith(LEDGER)) a = ledger;
    if (!a && u === ACTION) a = action;
    if (!a) a = [404, { error: 'nope' }];
    if (a instanceof Error) throw a;
    const [status, body] = a;
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

// A native dialog anywhere in the flow is a failure, never a prompt.
globalThis.confirm = () => { throw new Error('native confirm called'); };
globalThis.alert = () => { throw new Error('native alert called'); };
globalThis.prompt = () => { throw new Error('native prompt called'); };

// The FakeNode DOM from job-abandon.bh-2406 (inline there, not exported).
class FakeNode {
  constructor(nodeType, name, data) {
    this.nodeType = nodeType;
    this.localName = name;
    this.nodeName = name ? name.toUpperCase() : '#text';
    this.data = data;
    this.childNodes = [];
    this.parentNode = null;
    this.attrs = {};
    this.style = {};
    this.listeners = {};
  }
  get onclick() { return null; }
  get onchange() { return null; }
  get oninput() { return null; }
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
  removeChild(n) {
    this.childNodes.splice(this.childNodes.indexOf(n), 1);
    n.parentNode = null;
    return n;
  }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  removeAttribute(k) { delete this.attrs[k]; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(t, fn) { this.listeners[t] = fn; }
  removeEventListener(t) { delete this.listeners[t]; }
  focus() { globalThis.document.activeElement = this; }
  querySelectorAll(sel) {
    const parts = sel.split(',').map((p) => p.trim().split(/\s+/));
    const hasClassAbove = (n, cls) => {
      for (let p = n.parentNode; p && p !== this.parentNode; p = p.parentNode) {
        if ((p.attrs.class || '').split(/\s+/).includes(cls)) return true;
      }
      return false;
    };
    return all(this).slice(1).filter((n) => n.nodeType === 1 && parts.some((p) => (p.length === 1
      ? n.localName === p[0]
      : n.localName === p[1] && hasClassAbove(n, p[0].replace(/^\./, '')))));
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}

function installDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.hidden = false;
  doc.activeElement = null;
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  return doc;
}

const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const dialogOf = (root) => all(root).find((n) => n.attrs && n.attrs.role === 'dialog');
// A row button lives outside the dialog; the dialog's confirm is its last button.
const rowButton = (root, label) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === label && !all(dialogOf(root) || new FakeNode(1, 'x')).includes(n));
const confirmOf = (dialog) => all(dialog).filter((n) => n.localName === 'button').pop();
const cancelOf = (dialog) => all(dialog).find((n) => n.localName === 'button' && n.textContent.trim() === 'CANCEL');
const links = (root) => all(root).filter((n) => n.localName === 'a').map((n) => n.attrs.href);
const fire = (el, type, extra = {}) => el.listeners[type].call(el, { type, target: el, currentTarget: el, preventDefault() {}, stopPropagation() {}, button: 0, ...extra });
const isDisabled = (n) => n.disabled === true || ('disabled' in n.attrs && n.attrs.disabled !== 'false');
const posts = (calls) => calls.filter((c) => c.method === 'POST');

// The production pairing Build.js uses: one hold read, handed to the control.
function Probe({ project, ticket, reloadMs }) {
  const th = useTicketHold(project, ticket);
  return h(TicketHoldControl, { project, ticket, hold: th.hold, reload: th.reload, reloadMs });
}

async function mounted(vnode, fn) {
  const doc = installDom();
  const root = doc.createElement('div');
  mount(vnode, root);
  try { await flush(); await fn(root, doc); } finally { mount(null, root); }
}

test('A1: not held shows HOLD and no UNHOLD; held shows UNHOLD and no HOLD; loading shows neither', async () => {
  routedFetch();
  await mounted(h(TicketHoldControl, { project: 'cromford', ticket: 'BH-7', hold: { held: false }, reload: () => {} }), async (root) => {
    assert.ok(rowButton(root, 'HOLD'));
    assert.equal(rowButton(root, 'UNHOLD'), undefined);
    assert.doesNotMatch(root.textContent, /hold state unknown/);
  });
  await mounted(h(TicketHoldControl, { project: 'cromford', ticket: 'BH-7', hold: { held: true, by: 'operator', at: 'x', why: 'y' }, reload: () => {} }), async (root) => {
    assert.ok(rowButton(root, 'UNHOLD'));
    assert.equal(rowButton(root, 'HOLD'), undefined);
  });
  await mounted(h(TicketHoldControl, { project: 'cromford', ticket: 'BH-7', hold: null, reload: () => {} }), async (root) => {
    assert.equal(rowButton(root, 'HOLD'), undefined, 'never HOLD before the answer');
    assert.equal(rowButton(root, 'UNHOLD'), undefined);
    assert.match(root.textContent, /checking hold state/);
  });
});

test('A2: through useTicketHold, a 404 not found reads as not held and a held row as held', async () => {
  let calls = routedFetch({ ledger: [404, { error: 'not found' }] });
  await mounted(h(Probe, { project: 'cromford', ticket: 'BH-7' }), async (root) => {
    assert.ok(rowButton(root, 'HOLD'));
    assert.equal(rowButton(root, 'UNHOLD'), undefined);
  });
  assert.deepEqual(calls.map((c) => c.url), ['/api/coord/ledger?kind=ticket_hold&key=cromford%237']);
  calls = routedFetch({ ledger: [200, HELD_ROW] });
  await mounted(h(Probe, { project: 'cromford', ticket: 'BH-7' }), async (root) => {
    assert.ok(rowButton(root, 'UNHOLD'));
    assert.equal(rowButton(root, 'HOLD'), undefined);
  });
});

test('A3: a failed hold read is unknown: both buttons and the note, never "not held"', async () => {
  for (const ledger of [[500, { error: 'boom' }], [404, { error: 'nope' }], new Error('down'), [200, { ledger: { kind: 'ticket_hold', status: 'weird' } }]]) {
    routedFetch({ ledger });
    await mounted(h(Probe, { project: 'cromford', ticket: 'BH-7' }), async (root) => {
      assert.ok(rowButton(root, 'HOLD'), JSON.stringify(ledger));
      assert.ok(rowButton(root, 'UNHOLD'), JSON.stringify(ledger));
      assert.match(root.textContent, /hold state unknown/);
    });
  }
});

test('A4: no hold target renders nothing and reads nothing', async () => {
  for (const [project, ticket] of [['cromford', 'BH-01'], ['cromford', 'BH-0'], ['', 'BH-7'], [null, null], ['cromford', 'foo']]) {
    const calls = routedFetch();
    await mounted(h(Probe, { project, ticket }), async (root) => {
      assert.equal(root.textContent, '', `${project} ${ticket}`);
      assert.equal(all(root).length, 1, `${project} ${ticket}: no nodes`);
    });
    assert.equal(calls.filter((c) => c.url.startsWith(LEDGER)).length, 0, `${project} ${ticket}`);
  }
});

test('A5: HOLD and UNHOLD open the in-app dialog with the ticket copy and a 500-char reason', async () => {
  routedFetch();
  await mounted(h(TicketHoldControl, { project: 'cromford', ticket: 'BH-7', hold: { unknown: true }, reload: () => {} }), async (root, doc) => {
    fire(rowButton(root, 'HOLD'), 'click');
    await flush();
    let dialog = dialogOf(root);
    assert.ok(dialog, 'the in-app dialog opened');
    assert.equal(dialog.attrs['aria-label'], 'HOLD TICKET');
    assert.match(dialog.textContent, /HOLD TICKET/);
    assert.match(dialog.textContent, /Adds the hold label as the App; every build, rebuild and requeue of BH-7 stops until it is removed\./);
    const ta = all(dialog).find((n) => n.localName === 'textarea');
    assert.ok(ta, 'a reason textarea');
    assert.equal(ta.attrs.maxlength, '500');
    assert.equal(ta.attrs['aria-label'], 'Reason');
    assert.equal(doc.activeElement, ta, 'focus starts on the reason');
    assert.equal(confirmOf(dialog).textContent.trim(), 'HOLD');
    assert.equal(isDisabled(confirmOf(dialog)), false, 'the reason is optional');
    assert.equal(isDisabled(rowButton(root, 'HOLD')), true, 'row buttons are disabled while the dialog is open');
    assert.equal(isDisabled(rowButton(root, 'UNHOLD')), true);
    fire(cancelOf(dialog), 'click');
    await flush();

    fire(rowButton(root, 'UNHOLD'), 'click');
    await flush();
    dialog = dialogOf(root);
    assert.equal(dialog.attrs['aria-label'], 'UNHOLD TICKET');
    assert.match(dialog.textContent, /Removes the label; a HOLD comment or a \(HOLD\) title from a person still holds it\./);
    assert.equal(confirmOf(dialog).textContent.trim(), 'UNHOLD');
    fire(cancelOf(dialog), 'click');
    await flush();
  });
});

test('A6: confirm sends one POST and shows the queued banner linking the command', async () => {
  for (const [label, type] of [['HOLD', 'hold_ticket'], ['UNHOLD', 'unhold_ticket']]) {
    const calls = routedFetch({ action: [200, { command_id: 42 }] });
    await mounted(h(TicketHoldControl, { project: 'cromford', ticket: 'BH-7', hold: { unknown: true }, reload: () => {} }), async (root) => {
      fire(rowButton(root, label), 'click');
      await flush();
      const ta = all(dialogOf(root)).find((n) => n.localName === 'textarea');
      ta.value = '  flaky infra ';
      fire(ta, 'input');
      await flush();
      assert.equal(calls.length, 0, 'typing sends nothing');
      fire(confirmOf(dialogOf(root)), 'click');
      await flush();
      assert.deepEqual(posts(calls).map((c) => [c.url, c.body]),
        [[ACTION, { type, project: 'cromford', ticket: 'BH-7', reason: 'flaky infra' }]]);
      assert.equal(calls.length, 1);
      const status = all(root).find((n) => n.attrs && n.attrs.role === 'status');
      assert.ok(status, 'a status banner');
      assert.match(status.textContent, new RegExp(`^${label} queued as command #42`));
      assert.deepEqual(links(root), ['/history/commands?id=42']);
      assert.equal(dialogOf(root), undefined);
    });
  }
});

test('A7: Escape and CANCEL close the dialog with nothing sent and no banner', async () => {
  const calls = routedFetch();
  await mounted(h(TicketHoldControl, { project: 'cromford', ticket: 'BH-7', hold: { held: false }, reload: () => {} }), async (root, doc) => {
    fire(rowButton(root, 'HOLD'), 'click');
    await flush();
    const ta = all(dialogOf(root)).find((n) => n.localName === 'textarea');
    ta.value = 'typed then thought better';
    fire(ta, 'input');
    await flush();
    fire(doc, 'keydown', { key: 'Escape' });
    await flush();
    assert.equal(dialogOf(root), undefined, 'Escape closes it');
    assert.equal(isDisabled(rowButton(root, 'HOLD')), false);

    fire(rowButton(root, 'HOLD'), 'click');
    await flush();
    fire(cancelOf(dialogOf(root)), 'click');
    await flush();
    assert.equal(dialogOf(root), undefined, 'CANCEL closes it');

    fire(rowButton(root, 'HOLD'), 'click');
    await flush();
    const scrim = all(root).find((n) => n.attrs && n.attrs.class === 'modal__scrim');
    fire(scrim, 'click');
    await flush();
    assert.equal(dialogOf(root), undefined, 'a scrim click closes it');

    assert.equal(calls.length, 0);
    assert.equal(all(root).find((n) => n.attrs && n.attrs.role === 'status'), undefined, 'no banner');
    assert.deepEqual(links(root), []);
  });
});

test('A8: a failed POST and an id-less 200 never claim a queue, and the buttons come back', async () => {
  const cases = [
    [[500, { error: 'boom' }], /^HOLD failed: boom$/],
    [new Error('down'), /^HOLD failed: network unreachable$/],
    [[200, {}], /^HOLD sent, but no command id came back$/],
    [[200, { command_id: 'x' }], /^HOLD sent, but no command id came back$/],
    [[200, { command_id: 0 }], /^HOLD sent, but no command id came back$/],
  ];
  for (const [action, re] of cases) {
    const calls = routedFetch({ action });
    await mounted(h(TicketHoldControl, { project: 'cromford', ticket: 'BH-7', hold: { held: false }, reload: () => {} }), async (root) => {
      fire(rowButton(root, 'HOLD'), 'click');
      await flush();
      fire(confirmOf(dialogOf(root)), 'click');
      await flush();
      assert.equal(posts(calls).length, 1);
      const status = all(root).find((n) => n.attrs && n.attrs.role === 'status');
      assert.ok(status, JSON.stringify(action));
      assert.match(status.textContent, re);
      assert.doesNotMatch(status.textContent, /queued/);
      assert.deepEqual(links(root), [], 'no command link');
      assert.equal(isDisabled(rowButton(root, 'HOLD')), false, 'enabled again after the POST');
    });
  }
});

test('A9: a queued command reloads the hold once, later; a cancel or a failure never does', async () => {
  const RELOAD_MS = 300;
  for (const [action, cancel, expected] of [[[200, { command_id: 7 }], false, 1], [[200, { command_id: 7 }], true, 0], [[500, { error: 'boom' }], false, 0]]) {
    routedFetch({ action });
    let reloads = 0;
    await mounted(h(TicketHoldControl, { project: 'cromford', ticket: 'BH-7', hold: { held: false }, reload: () => { reloads += 1; }, reloadMs: RELOAD_MS }), async (root) => {
      fire(rowButton(root, 'HOLD'), 'click');
      await flush();
      fire((cancel ? cancelOf : confirmOf)(dialogOf(root)), 'click');
      await flush();
      assert.equal(reloads, 0, 'not before the delay');
      await flush(RELOAD_MS + 50);
      assert.equal(reloads, expected, JSON.stringify([action, cancel]));
      await flush(RELOAD_MS + 50);
      assert.equal(reloads, expected, 'exactly once');
    });
  }
  // Unmounting before the delay clears the timer.
  routedFetch();
  let reloads = 0;
  await mounted(h(TicketHoldControl, { project: 'cromford', ticket: 'BH-7', hold: { held: false }, reload: () => { reloads += 1; }, reloadMs: RELOAD_MS }), async (root) => {
    fire(rowButton(root, 'HOLD'), 'click');
    await flush();
    fire(confirmOf(dialogOf(root)), 'click');
    await flush();
  });
  await flush(RELOAD_MS + 50);
  assert.equal(reloads, 0, 'no reload after unmount');
});

test('A10: the real BuildScreen shows the HELD tag by the verdict and the control after the stats', async () => {
  const build = { id: 9, project: 'cromford', ticket_key: 'BH-7', bkey: 'cromford:BH-7:x', stage: 'execute', verdict: 'APPROVE' };
  const extra = (u) => {
    if (u.startsWith('/api/dash/builds/')) return [200, { build, timeline: [] }];
    if (u.startsWith('/api/coord/jobs?')) return [200, { jobs: [] }];
    return null;
  };
  const cases = [
    [[200, HELD_ROW], { held: true, hold: false, unhold: true }],
    [[404, { error: 'not found' }], { held: false, hold: true, unhold: false }],
    [[500, { error: 'boom' }], { held: false, hold: true, unhold: true }],
  ];
  for (const [ledger, want] of cases) {
    const calls = routedFetch({ ledger, extra });
    await mounted(h(BuildScreen, { id: '9' }), async (root) => {
      await flush();
      assert.match(root.textContent, /BH-7/);
      const tag = all(root).find((n) => n.localName === 'span' && n.textContent === 'HELD');
      assert.equal(Boolean(tag), want.held, JSON.stringify(ledger));
      if (tag) {
        assert.equal(tag.attrs.class, 'tag tag--warn');
        const verdict = all(root).find((n) => n.localName === 'span' && n.textContent === 'approved'); // BH-3569: verdict tag reads as words
        assert.equal(tag.parentNode, verdict.parentNode, 'the tag sits in the header next to the verdict');
        assert.equal(verdict.nextSibling, tag, 'right after the verdict tag');
      }
      assert.equal(Boolean(rowButton(root, 'HOLD')), want.hold, JSON.stringify(ledger));
      assert.equal(Boolean(rowButton(root, 'UNHOLD')), want.unhold, JSON.stringify(ledger));
      // The control sits after the .stats block, in the page body.
      const stats = all(root).find((n) => n.attrs && n.attrs.class === 'stats');
      const btn = rowButton(root, want.hold ? 'HOLD' : 'UNHOLD');
      let row = btn; while (row.parentNode !== stats.parentNode) row = row.parentNode;
      const kids = stats.parentNode.childNodes;
      assert.ok(kids.indexOf(row) > kids.indexOf(stats), 'under the stats');
    });
    assert.equal(calls.filter((c) => c.url.startsWith(LEDGER)).length, 1, 'one hold read feeds both the tag and the control');
  }
});

test('A10b: the real BuildScreen queues a HOLD through /api/dash/action', async () => {
  const build = { id: 9, project: 'cromford', ticket_key: 'BH-7', bkey: 'cromford:BH-7:x', stage: 'execute' };
  const calls = routedFetch({
    action: [200, { command_id: 5 }],
    extra: (u) => (u.startsWith('/api/dash/builds/') ? [200, { build, timeline: [] }] : u.startsWith('/api/coord/jobs?') ? [200, { jobs: [] }] : null)
  });
  await mounted(h(BuildScreen, { id: '9' }), async (root) => {
    await flush();
    fire(rowButton(root, 'HOLD'), 'click');
    await flush();
    fire(confirmOf(dialogOf(root)), 'click');
    await flush();
    assert.deepEqual(posts(calls).map((c) => c.body), [{ type: 'hold_ticket', project: 'cromford', ticket: 'BH-7', reason: '' }]);
    assert.match(root.textContent, /HOLD queued as command #5/);
    assert.ok(links(root).includes('/history/commands?id=5'));
  });
});
