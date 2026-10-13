// BH-4992 (BH-4947 wave 3): Fleet states box health in words.
//
// The headline is drawn from the machines read only: how many boxes answer
// (a ping under 10 minutes), are overdue (10-30), are silent (30+) or never
// pinged; the lede names every box that is not answering and links nothing it
// cannot. (File name: console-ui runs tests/*.test.js.)
import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';

globalThis.window = globalThis.window || {
  location: { pathname: '/', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};
const { render } = await import('preact-render-to-string');
const { FleetHeadline } = await import('../src/screens/Fleet.js');
const { fleetHeadline } = await import('../src/lib/line-screens.js');
const visible = (html) => html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');

const BOXES = { hub: '1m ago', 'box-hub': '3m ago', 'box-2': '15m ago', 'box-3': '2h ago', 'box-4': 'never' };

test('F1 box health in words, from the machines read', () => {
  const f = fleetHeadline({ boxes: BOXES, building: 3, queueDepth: 2, openAlerts: 1 });
  assert.equal(f.line1, '5 boxes. 2 answering.');
  assert.equal(f.line2, '1 overdue. 1 silent. 1 never pinged.');
  assert.match(f.lede, /^Not answering: box-2 \(15m\), box-3 \(2h\), box-4 \(never\)\. /);
  assert.match(f.lede, /3 building, 2 waiting for a machine, 1 open alert\.$/);
  const all = fleetHeadline({ boxes: { hub: '1m ago', b: '2m ago' }, building: 0, queueDepth: 0, openAlerts: 0 });
  assert.equal(all.line1, '2 boxes. All answering.');
  assert.equal(all.line2, 'None overdue. None silent.');
  assert.equal(fleetHeadline({ boxes: null }).line1, 'Reading the fleet.');
});

test('F2 the headline renders with its stat grid, and every box in it links to /machines', () => {
  const out = render(h(FleetHeadline, { boxes: BOXES, building: 3, queueDepth: 2, openAlerts: 1 }));
  assert.match(out, /<h1 class="line-headline">5 boxes\. 2 answering\.<br\/><span class="line-headline__dim">1 overdue\. 1 silent\. 1 never pinged\.<\/span>/);
  assert.match(out, /class="statgrid"/);
  for (const label of ['Answering', 'Overdue', 'Silent', 'Building now', 'Waiting for a machine', 'Open alerts']) {
    assert.match(visible(out), new RegExp(label), `stat ${label}`);
  }
  assert.ok(out.includes('href="/machines"'), 'the box cells link to /machines');
  assert.ok(out.includes('href="/alerts"'), 'open alerts links to /alerts');
});
