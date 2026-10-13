// BH-4080: the console's two deployment literals moved into one defaults
// module (src/lib/deployment.js). These pin that the consumers still behave:
// a claim by the fleet login is ours, any other login is not, and the Ideas
// page still links the product cockpit at the configured address.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { FLEET_LOGIN, PRODUCT_COCKPIT_URL } from '../src/lib/deployment.js';
import { actorLabel, ticketClaim } from '../src/lib/lanes.js';
import { CockpitLink } from '../src/screens/Ideas.js';

test('a claim made by the fleet login is the harness; another login is not', () => {
  assert.equal(typeof FLEET_LOGIN, 'string');
  assert.ok(FLEET_LOGIN.length > 0);
  assert.equal(actorLabel(FLEET_LOGIN, false), 'harness');
  assert.notEqual(actorLabel('someone-else', false), 'harness');
  // no `fleet` flag: only the actor can say whose claim it is
  const ours = ticketClaim({ claim: { actor: FLEET_LOGIN, kind: 'pr', at: '2026-10-01T00:00:00Z' } });
  const theirs = ticketClaim({ claim: { actor: 'someone-else', kind: 'pr', at: '2026-10-01T00:00:00Z' } });
  assert.equal(ours.fleet, true);
  assert.equal(ours.label, 'harness');
  assert.equal(theirs.fleet, false);
  assert.notEqual(theirs.label, 'harness');
});

test('the Ideas page links the product cockpit at the configured address, in a new tab', () => {
  const out = render(h(CockpitLink, {}));
  assert.ok(PRODUCT_COCKPIT_URL.startsWith('https://'), PRODUCT_COCKPIT_URL);
  assert.ok(out.includes(`href="${PRODUCT_COCKPIT_URL}"`), out);
  assert.ok(out.includes('target="_blank"'), out);
  assert.ok(out.includes('rel="noopener noreferrer"'), out);
  assert.ok(out.includes('product cockpit'), out);
});
