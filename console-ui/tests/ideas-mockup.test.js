import test from 'node:test';
import assert from 'node:assert/strict';
import {
  mockupLink, mockupShots, hasMockup, mockupState, mockupRank,
  mockupAnchor, withMockups, mockupCountText, summarise, MOCKUP_HASH
} from '../src/lib/ideas.js';
import { sortRows } from '../src/lib/sort.js';

// A proposal's mockup lives in two places and the screen has to be honest about
// both: `mockup_url` is the interactive mockup post-proposal.sh attached to the
// client's board, and `shots` counts the desktop/mobile PNGs the drafting stage
// pushed into the console's own asset store. Either one means "there is a
// mockup"; neither means the idea never reached the drafting stage, which is a
// real state and not a failed upload.

const live = { project: 'project-3', slug: 'roster', mockup_url: 'https://os.project-3.example/board/mockups/9', shots: 2 };
const linkOnly = { project: 'project-3', slug: 'link-only', mockup_url: 'https://os.project-3.example/board/mockups/7', shots: 0 };
const shotsOnly = { project: 'project-4', slug: 'gate', shots: 2 };
const bare = { project: 'project-4', slug: 'idea-only', shots: 0 };

test('a mockup is either a live viewer link or the shots on file', () => {
  assert.equal(hasMockup(live), true);
  assert.equal(hasMockup(linkOnly), true);
  assert.equal(hasMockup(shotsOnly), true);
  assert.equal(hasMockup(bare), false);
  assert.equal(hasMockup(null), false);
  assert.equal(hasMockup({}), false);
});

test('the viewer link is only trusted when it is https', () => {
  assert.equal(mockupLink(live), 'https://os.project-3.example/board/mockups/9');
  assert.equal(mockupLink({ mockup_url: 'javascript:alert(1)' }), null);
  assert.equal(mockupLink({ mockup_url: 'http://os.project-3.example/x' }), null);
  assert.equal(mockupLink({ mockup_url: '//evil.example/x' }), null);
  assert.equal(mockupLink({ mockup_url: '' }), null);
  assert.equal(mockupLink(null), null);
  // A row whose only mockup_url is unusable has no mockup to click into.
  assert.equal(hasMockup({ mockup_url: 'http://os.project-3.example/x', shots: 0 }), false);
});

test('shot counts arrive from D1 as strings and still count', () => {
  assert.equal(mockupShots({ shots: '2' }), 2);
  assert.equal(mockupShots({ shots: 0 }), 0);
  assert.equal(mockupShots({ shots: null }), 0);
  assert.equal(mockupShots({ shots: 'lots' }), 0);
  assert.equal(mockupShots(null), 0);
  assert.equal(hasMockup({ shots: '1' }), true);
});

test('the three states are named, so the cell can say which kind of empty it is', () => {
  assert.equal(mockupState(live), 'live');
  assert.equal(mockupState(linkOnly), 'live');
  assert.equal(mockupState(shotsOnly), 'shots');
  assert.equal(mockupState(bare), 'none');
  assert.equal(mockupState(null), 'none');
});

test('no mockup sorts last in BOTH directions, and a live link outranks shots', () => {
  assert.equal(mockupRank(bare), null);
  assert.ok(mockupRank(live) > mockupRank(shotsOnly));
  const rows = [bare, shotsOnly, live];
  const asc = sortRows(rows, mockupRank, 'asc').map((r) => r.slug);
  const desc = sortRows(rows, mockupRank, 'desc').map((r) => r.slug);
  assert.deepEqual(asc, ['gate', 'roster', 'idea-only']);
  assert.deepEqual(desc, ['roster', 'gate', 'idea-only']);
});

test('the anchor opens the idea at its mockup, encoded like every other link', () => {
  assert.equal(mockupAnchor(shotsOnly), `/ideas/project-4/gate${MOCKUP_HASH}`);
  assert.equal(mockupAnchor({ project: 'a/b', slug: 'c d' }), `/ideas/a%2Fb/c%20d${MOCKUP_HASH}`);
});

test('the with-mockups filter keeps only rows that have one, and off it keeps everything', () => {
  const rows = [live, linkOnly, shotsOnly, bare];
  assert.deepEqual(withMockups(rows, true).map((r) => r.slug), ['roster', 'link-only', 'gate']);
  assert.deepEqual(withMockups(rows, false).map((r) => r.slug), ['roster', 'link-only', 'gate', 'idea-only']);
  assert.deepEqual(withMockups(null, true), []);
  // It filters, it does not reorder or mutate.
  assert.deepEqual(rows.map((r) => r.slug), ['roster', 'link-only', 'gate', 'idea-only']);
});

test('the count says how many of the rows in view have one', () => {
  assert.equal(mockupCountText([live, linkOnly, shotsOnly, bare]), '3 of 4 have a mockup');
  assert.equal(mockupCountText([bare]), '0 of 1 have a mockup');
  assert.equal(mockupCountText([]), '0 of 0 have a mockup');
  assert.equal(mockupCountText(null), '0 of 0 have a mockup');
});

test('the strip agrees with the column: a live link counts even with no shots on file', () => {
  // Before this, WITH A MOCKUP counted shots only, so a proposal whose asset
  // upload failed after it was posted to the client read as having no mockup
  // while the client was looking at one.
  const s = summarise([live, linkOnly, shotsOnly, bare]);
  assert.equal(s.withMockup, 3);
});
