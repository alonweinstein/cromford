import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { sortRows } from '../src/lib/sort.js';
import {
  ALERT_STATE_ORDER, FLEET_ROWS_LIMIT, FLEET_ROWS_DEFAULT_STATE,
  splitClaim, stateRank, shapeAlertRows, alertSortValue,
  filterHref, familyHref, boxHref, stateHref
} from '../src/lib/alertrows.js';
import { FleetRowsSection } from '../src/screens/Alerts.js';

// The FLEET ROWS section reads the alerts table through the coord proxy. Two
// things can be wrong without anybody noticing: the URL the screen asks for
// (a missing `state` sends back every resolved row ever written) and what the
// rows say about themselves once they land — an unclaimed row must not render
// "null@null", a fleet-wide row must not link to /p/, and a load failure must
// not read as "nothing has fired".
//
// Fixtures are the wire shape of GET /api/alerts, column for column, from
// worker/jobs/README.md "## Alerts table (2026-09-19)".

// A fetch stub that records the URL and answers with the smallest valid body.
function captureFetch() {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    return { ok: true, status: 200, text: async () => JSON.stringify({ alerts: [], truncated: false }) };
  };
  return calls;
}

const paramsOf = (url) => new URL(url, 'https://console.test').searchParams;

// determinism: ok every age in this file is measured from this literal epoch,
// never from the wall clock, so the fixtures cannot slide out from under it.
const NOW = Date.parse('2026-09-19T12:00:00Z');

const rowA = {
  id: 'lane-medic-dead',
  family: 'a1b2c3d4e5f6',
  box: 'hub',
  project: 'project-3',
  line: 'medic lane has not ticked in 40m',
  severity: 'warn',
  first_seen: '2026-09-19T10:30:00Z',
  last_seen: '2026-09-19T11:55:00Z',
  count: 3,
  state: 'new',
  claimed_by: 'medic@hub',
  claimed_at: '2026-09-19T11:00:00Z',
  notified_at: '2026-09-19T11:05:00Z'
};

// Fleet-wide (`project: ''` per the contract), never claimed, never notified.
const rowB = {
  id: 'disk-85pct',
  family: '',
  box: 'orgo-3',
  project: '',
  line: 'disk at 85%',
  severity: 'info',
  first_seen: '2026-09-19T09:00:00Z',
  last_seen: '2026-09-19T11:00:00Z',
  count: 12,
  state: 'parked',
  claimed_by: null,
  claimed_at: null,
  notified_at: null
};

const payload = { alerts: [rowA, rowB], truncated: false, as_of: '2026-09-19T12:00:00Z' };

test('api.alerts builds the coord URL from the filters it was given', async () => {
  const calls = captureFetch();
  await api.alerts({ state: 'new', family: 'abc' });
  assert.equal(calls[0], '/api/coord/alerts?state=new&family=abc');

  await api.alerts({ state: FLEET_ROWS_DEFAULT_STATE, box: 'hub', limit: FLEET_ROWS_LIMIT });
  const q = paramsOf(calls[1]);
  assert.equal(q.get('state'), '!resolved', 'the default query excludes resolved rows');
  assert.equal(q.get('box'), 'hub');
  assert.equal(q.get('limit'), '500');
  assert.equal(q.get('family'), null, 'an unset filter is not sent as an empty one');

  await api.alerts();
  assert.equal(calls[2], '/api/coord/alerts', 'no filters means no dangling ?');
  assert.equal(FLEET_ROWS_LIMIT, 500, 'the request and the constant agree');
  assert.equal(FLEET_ROWS_DEFAULT_STATE, '!resolved');
});

test('shapeAlertRows shapes the wire payload the GET actually returns', () => {
  const { rows } = shapeAlertRows(payload, NOW);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].lane, 'medic');
  assert.equal(rows[0].laneBox, 'hub');
  assert.equal(rows[0].ageMin, 90, 'age is measured from first_seen — the incident, not the last sighting');
  assert.equal(rows[0].lastSeenMin, 5);
  assert.equal(rows[0].id, 'lane-medic-dead', 'the raw row rides along untouched');
  assert.equal(rows[1].lane, null, 'an unclaimed row has no lane');
  assert.equal(rows[1].laneBox, null);
  assert.equal(rows[1].project, '', 'fleet-wide stays fleet-wide');
  assert.equal(rows[1].ageMin, 180);
});

test('an age we cannot parse is unknown, never zero', () => {
  const { rows } = shapeAlertRows({ alerts: [{ ...rowA, first_seen: 'not a date', last_seen: null }] }, NOW);
  assert.equal(rows[0].ageMin, null, 'null, not 0 — 0 would render as "now"');
  assert.equal(rows[0].lastSeenMin, null);
});

test('a payload with no alerts array is no rows, not a throw', () => {
  assert.equal(shapeAlertRows({ alerts: undefined }, NOW).rows.length, 0);
  assert.equal(shapeAlertRows(null, NOW).rows.length, 0);
});

test('claimed_by splits on the FIRST @ and only on a real value', () => {
  assert.deepEqual(splitClaim('medic@hub'), { lane: 'medic', laneBox: 'hub' });
  assert.deepEqual(splitClaim(null), { lane: null, laneBox: null });
  assert.deepEqual(splitClaim(''), { lane: null, laneBox: null });
  assert.deepEqual(splitClaim('medic'), { lane: 'medic', laneBox: null });
  assert.deepEqual(splitClaim('a@b@c'), { lane: 'a', laneBox: 'b@c' });
});

test('truncated surfaces on the shaped result, and a missing field is false', () => {
  assert.equal(shapeAlertRows({ alerts: [], truncated: true, as_of: '2026-09-19T12:00:00Z' }, NOW).truncated, true);
  assert.equal(shapeAlertRows({ alerts: [] }, NOW).truncated, false, 'absent is not truncated');
  assert.equal(shapeAlertRows(payload, NOW).asOf, '2026-09-19T12:00:00Z');
});

test('the state comparator is the contract order, and unknown states sink', () => {
  const states = ['parked', 'new', 'resolved', 'quarantined', 'bogus'];
  const { rows } = shapeAlertRows({ alerts: states.map((s, i) => ({ ...rowB, id: `r${i}`, state: s })) }, NOW);
  const sorted = sortRows(rows, (r) => alertSortValue(r, 'state'), 'asc').map((r) => r.state);
  assert.deepEqual(sorted, ['new', 'quarantined', 'parked', 'resolved', 'bogus']);
  assert.ok(stateRank('new') < stateRank('parked'), 'new is louder than parked');
  assert.equal(stateRank('nope'), ALERT_STATE_ORDER.length, 'an unknown state is unknown, not first');
  assert.deepEqual(ALERT_STATE_ORDER, ['new', 'quarantined', 'triaged', 'parked', 'resolved']);
});

test('count sorts as a number, so 9 does not beat 10', () => {
  const { rows } = shapeAlertRows({ alerts: [{ ...rowB, id: 'a', count: '9' }, { ...rowB, id: 'b', count: '10' }] }, NOW);
  assert.equal(alertSortValue(rows[0], 'count'), 9);
  assert.deepEqual(sortRows(rows, (r) => alertSortValue(r, 'count'), 'asc').map((r) => r.id), ['a', 'b']);
  assert.equal(alertSortValue({ count: '' }, 'count'), null, 'a blank count is unknown, not zero');
  assert.equal(alertSortValue(rows[0], 'family'), rows[0].family, 'every other column sorts on its own value');
});

test('the filter hrefs are query-only and replace the filter set', () => {
  assert.equal(familyHref('abc'), '?family=abc');
  assert.equal(boxHref('a b'), '?box=a+b');
  assert.equal(stateHref('new'), '?state=new');
  assert.equal(filterHref({ family: 'x', box: 'y' }), '?family=x&box=y');
  assert.equal(filterHref({}), '/alerts', 'clearing the last filter goes back to the bare screen');
  assert.equal(filterHref({ family: null, box: '', state: 'new' }), '?state=new');
});

const draw = (props) => render(h(FleetRowsSection, {
  loading: false, error: null, onRetry: () => {}, shaped: null, filters: {}, ...props
}));

test('the section renders the ten contract columns in the shared sortable table', () => {
  const shaped = shapeAlertRows({ ...payload, truncated: true }, NOW);
  const out = draw({ shaped });
  assert.match(out, /class="tablewrap"/, 'the wrapper with overflow-x:auto');
  assert.ok(!out.includes('tablewrap--wide'), 'nothing here widens the body at 375px');

  const head = out.slice(out.indexOf('<thead'), out.indexOf('</thead>'));
  for (const label of ['id', 'family', 'box', 'project', 'state', 'count', 'first seen', 'last seen', 'claimed by', 'notified']) {
    assert.ok(head.includes(`sort by ${label}`), `${label} is a clickable header`);
  }
  assert.equal((head.match(/aria-sort="/g) || []).length, 10, 'all ten columns announce their sort state');
  assert.equal((out.match(/aria-sort="ascending"/g) || []).length, 1, 'first_seen is the default, ascending');

  assert.ok(out.includes('href="?family=a1b2c3d4e5f6"'), 'the family cell drills into its own family');
  assert.ok(out.includes('href="?box=hub"'), 'the box cell drills into its box');
  assert.ok(out.includes('href="?state=new"'), 'the state cell drills into its state');
  assert.ok(out.includes('href="/p/project-3"'), 'the project cell is the existing project link');
  assert.ok(out.includes('medic') && out.includes('@hub'), 'the claim shows lane and box');
  assert.ok(out.includes('fleet'), 'a fleet-wide row says so instead of linking to /p/');
  assert.ok(!out.includes('href="/p/"'), 'and never links to an empty project');
  assert.ok(!out.includes('null@null'), 'an unclaimed row renders no claim at all');
  assert.ok(out.includes('showing 2 of more'), 'a truncated read says it was truncated');
  assert.ok(out.includes('1h'), 'the 90m-old row renders its age');
  assert.ok(!out.includes('RESOLVE'), 'this section never writes');
});

test('an untruncated read counts what it is showing', () => {
  const out = draw({ shaped: shapeAlertRows(payload, NOW) });
  assert.ok(out.includes('2 rows'), 'the honest count, with no "of more"');
  assert.ok(!out.includes('of more'));
});

test('the empty copy is true in both states', () => {
  const none = draw({ shaped: { rows: [], truncated: false, asOf: null } });
  assert.ok(none.includes('no fleet rows yet'), 'the unfiltered empty state');
  assert.ok(none.includes('alerts-db'), 'and names the flag that would explain it');

  const filtered = draw({ shaped: { rows: [], truncated: false, asOf: null }, filters: { family: 'abc' } });
  assert.ok(filtered.includes('no fleet rows match'), 'behind a filter the copy is about the filter');
  assert.ok(!filtered.includes('nothing has fired'), 'because that claim would be false here');
});

test('a failed read is not the same thing as no rows', () => {
  const out = draw({ error: new Error('http_404'), shaped: null });
  assert.ok(out.includes('could not load'), 'the failure is named');
  assert.ok(out.includes('http_404'), 'with the reason the request returned');
  assert.ok(!out.includes('<table'), 'and no table is drawn over it');
  assert.ok(!out.includes('no fleet rows yet'), 'a 404 never reads as "nothing has fired"');
  assert.ok(!out.includes('RESOLVE'));

  const first = draw({ loading: true, shaped: null });
  assert.match(first, /class="skel"/, 'the first paint is a skeleton, not an empty state');
  assert.ok(!first.includes('no fleet rows yet'), 'and "still finding out" is not "nothing has fired" either');
});

test('each chip clears itself and keeps the others', () => {
  const out = draw({ shaped: { rows: [], truncated: false, asOf: '2026-09-19T12:00:00Z' }, filters: { family: 'abc', box: 'hub' } });
  assert.equal((out.match(/class="pill"/g) || []).length, 2, 'one chip per active filter');
  assert.ok(out.includes('family=abc') && out.includes('box=hub'), 'each chip says what it filters on');
  assert.ok(out.includes('href="?box=hub"'), 'clearing family keeps box');
  assert.ok(out.includes('href="?family=abc"'), 'clearing box keeps family');
  assert.ok(out.includes('12:00Z'), 'the read stamps itself');

  const one = draw({ shaped: { rows: [], truncated: false, asOf: null }, filters: { state: 'new' } });
  assert.equal((one.match(/class="pill"/g) || []).length, 1);
  assert.ok(one.includes('href="/alerts"'), 'clearing the last filter goes back to the bare screen');
});

test('the /alerts route component is what mounts this section', () => {
  // AlertsScreen cannot be rendered here (it needs the fleet context and a
  // window), so the mount is pinned in source with the absent-symbol case
  // guarded: a deleted or renamed mount fails here instead of passing.
  const src = readFileSync(new URL('../src/screens/Alerts.js', import.meta.url), 'utf8');
  assert.notEqual(src.indexOf('export function AlertsScreen'), -1, 'the route component is still exported');
  assert.notEqual(src.indexOf('<${FleetRowsSection}'), -1, 'and it still mounts the section these tests render');
  assert.notEqual(src.indexOf('api.alerts('), -1, 'through its own read');
  assert.notEqual(src.indexOf('FLEET_ROWS_DEFAULT_STATE'), -1, 'with the !resolved default');
  assert.notEqual(src.indexOf("useSearchParam('family')"), -1, 'and the three filters come from the URL');
  assert.notEqual(src.indexOf("useSearchParam('box')"), -1);
  assert.notEqual(src.indexOf("useSearchParam('state')"), -1);
});
