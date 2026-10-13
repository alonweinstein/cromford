// BH-4991 (BH-4947 wave 2): every ticket key across the console links to its
// ticket page, /t/<KEY>, through ONE formatter: ticketPath (src/lib/line.js,
// wave 1) wrapped by the TicketKey component (src/ui/TicketKey.js).
//
// The grep half fails when a screen in scope prints a ticket field as bare
// text: a template text node `>${… .ticket_key …}`, `.ticket`, `.ticket_id` or
// `ticket.key`, or a table cell that returns the key as a string. Waves 3 and 4
// redraw some of these screens; this wave changes only how the key renders.
// Alerts and CI carry no ticket field (their keys are inside free-text alert
// lines and batch names), so for them the check is that none is printed bare.
// (File name per the scope update: console-ui runs tests/*.test.js only.)

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { h } from 'preact';

globalThis.window = globalThis.window || {
  location: { pathname: '/', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { render } = await import('preact-render-to-string');
const { TicketKey } = await import('../src/ui/TicketKey.js');
const { needRows } = await import('../src/lib/cockpit.js');

const src = (f) => readFileSync(new URL(`../src/screens/${f}`, import.meta.url), 'utf8');
// A ticket field printed as a text node right after a tag (not after `=>`).
const BARE = /[^=]>\s*\$\{[^}]*(\.ticket_key\b|\.ticket_id\b|\.ticket\b|\bticket\.key\b)/;

test('L1 TicketKey links the key to /t/<KEY> through ticketPath', () => {
  assert.equal(render(h(TicketKey, { k: 'BH-4991' })), '<a href="/t/BH-4991" class="tk">BH-4991</a>');
  assert.equal(render(h(TicketKey, { k: 'BH 1#2' })), '<a href="/t/BH%201%232" class="tk">BH 1#2</a>');
  assert.equal(render(h(TicketKey, { k: 'BH-1', cls: 'cell-name' })), '<a href="/t/BH-1" class="tk cell-name">BH-1</a>');
  assert.equal(render(h(TicketKey, { k: '' })), '<span class="na">—</span>', 'no key is a dash, never a dead link');
  assert.equal(render(h(TicketKey, { k: null, fallback: 'build #7' })), '<span>build #7</span>');
});

const LINKED = ['Now.js', 'Kanban.js', 'Needs.js', 'Costs.js', 'Project.js'];
const NO_FIELD = ['Alerts.js', 'CiHealth.js'];

test('L2 the screens in scope print no bare ticket key', () => {
  for (const f of [...LINKED, ...NO_FIELD]) {
    const lines = src(f).split('\n');
    lines.forEach((line, i) => {
      // The one exception is marked in the source: a key inside an element
      // that is itself a link (a nested <a> is invalid HTML).
      if (i > 0 && lines[i - 1].includes('ticket-link: inside-a-link')) return;
      assert.doesNotMatch(line, BARE, `${f}:${i + 1} prints a ticket key without TicketKey: ${line.trim()}`);
    });
  }
  // The marker is used once, on the Kanban pipeline card, and nowhere else.
  for (const f of [...LINKED, ...NO_FIELD]) {
    const n = (src(f).match(/ticket-link: inside-a-link/g) || []).length;
    assert.equal(n, f === 'Kanban.js' ? 1 : 0, `${f} carries ${n} inside-a-link markers`);
  }
});

test('L3 every screen that shows a ticket key renders it through TicketKey', () => {
  for (const f of LINKED) {
    assert.match(src(f), /import \{ TicketKey \} from '\.\.\/ui\/TicketKey\.js';/, `${f} imports TicketKey`);
    assert.match(src(f), /<\$\{TicketKey\}/, `${f} renders TicketKey`);
  }
});

test('L4 a Needs build row carries its ticket key, so the screen can link it', () => {
  const rows = needRows({ builds: [{ id: 7, project: 'cromford', ticket_key: 'BH-4991', stage: 'plan', tier: 2, updated_at: '2026-10-09T20:00:00Z' }] });
  assert.equal(rows[0].ticket, 'BH-4991');
  assert.equal(needRows({ alerts: [{ id: 1, line: 'x' }] })[0].ticket, null, 'an alert row has no ticket field');
});
