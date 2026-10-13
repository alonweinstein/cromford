// The lead_report source BH-5915 added to the ledger: the whole lead review
// report, pushed by the lead-review lane when the job artifact had to cut it.
// It is neither a model session nor a blocked build's file, so it must not
// borrow either sentence, and it must not fall through to "provenance not
// recorded", which would be false about a row whose provenance is exact.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sourceLabel, sourceNote } from '../src/lib/transcripts.js';

test('C1: lead_report has its own label', () => {
  assert.equal(sourceLabel('lead_report'), 'lead review report (full)');
});

test('C2: lead_report gets a true note, not a borrowed one', () => {
  const note = sourceNote({ source: 'lead_report' });
  assert.doesNotMatch(note, /provenance not recorded/);
  assert.doesNotMatch(note, /ended blocked/);
  assert.doesNotMatch(note, /turn by turn/);
  assert.match(note, /lead review report/);
});
