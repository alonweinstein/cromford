import test from 'node:test';
import assert from 'node:assert/strict';
import {
  repoFromPrUrl, prNumber, withinDays, weekStart,
  mergedInWindow, perRepo, weeklyBurn, findingRows, costRows, summarise,
  outcomeLabel, outcomeTone, pct, thresholdFor
} from '../src/lib/outcomes.js';

// The OUTCOMES logic fails SILENTLY or not at all. A crash would be obvious; a
// denominator that counted a parked PR, a rate that read 150% because one PR
// was reverted and reopened, or a week that looked cheap because the tracker
// missed four days are all wrong numbers rendered confidently. Those are the
// properties under test.

const NOW = Date.parse('2026-08-29T12:00:00Z');
const daysAgo = (n) => new Date(NOW - n * 86400000).toISOString();

const PR = (repo, n) => `https://github.com/${repo}/pull/${n}`;
const merge = (repo, n, ageDays, over = {}) => ({
  kind: 'merge', key: PR(repo, n), status: 'merged', job_id: `build-x-${n}`,
  created_at: daysAgo(ageDays), updated_at: daysAgo(ageDays), ...over
});
const finding = (repo, n, outcome, over = {}) => ({
  repo, pr: PR(repo, n), outcome, day: daysAgo(1).slice(0, 10), evidence: 'e', ...over
});
const cost = (repo, n, usd) => ({ pr_url: PR(repo, n), cost_usd: usd, stage_breakdown: 'execute:1' });

// --- parsing -----------------------------------------------------------------

test('a repo slug is only ever read off a real github pull url', () => {
  assert.equal(repoFromPrUrl('https://github.com/example-org/project-3/pull/12'), 'example-org/project-3');
  assert.equal(prNumber('https://github.com/example-org/project-3/pull/12'), 12);
  // These arrive in D1 from a shell script, so a near-miss must be null and not
  // a guessed slug that would silently found its own repo row.
  assert.equal(repoFromPrUrl('https://github.com/example-org/project-3/issues/12'), null);
  assert.equal(repoFromPrUrl('https://evil.example/example-org/project-3/pull/12'), null);
  assert.equal(repoFromPrUrl(''), null);
  assert.equal(repoFromPrUrl(null), null);
});

// --- windows -----------------------------------------------------------------

test('a timestamp we cannot read is NOT recent', () => {
  assert.equal(withinDays(daysAgo(3), 14, NOW), true);
  assert.equal(withinDays(daysAgo(20), 14, NOW), false);
  // The denominator of a revert rate must never gain a merge nobody can place
  // in time — that would silently make the rate look better than it is.
  assert.equal(withinDays('-', 14, NOW), false);
  assert.equal(withinDays(null, 14, NOW), false);
  assert.equal(withinDays('not a date', 14, NOW), false);
});

test('a Sunday belongs to the week that started six days earlier', () => {
  // 2026-08-29 is a Saturday; 2026-08-30 the Sunday after it. Both are in the
  // week starting Monday 2026-08-24. The naive getUTCDay() maths puts the
  // Sunday in the NEXT week, which is the off-by-one this exists to pin.
  assert.equal(weekStart('2026-08-24'), '2026-08-24');
  assert.equal(weekStart('2026-08-29'), '2026-08-24');
  assert.equal(weekStart('2026-08-30'), '2026-08-24');
  assert.equal(weekStart('2026-08-31'), '2026-08-31');
  assert.equal(weekStart(null), null);
  assert.equal(weekStart('nonsense'), null);
});

// --- the denominator ---------------------------------------------------------

test('only MERGED ledger rows are counted, and only inside the window', () => {
  const merges = [
    merge('o/a', 1, 2),
    merge('o/a', 2, 20),                                  // outside 14d
    merge('o/a', 3, 1, { status: 'parked' }),             // never reached main
    merge('o/a', 4, 1, { status: 'flagged' }),
    merge('o/a', 5, 1, { updated_at: '-', created_at: '-' }) // unplaceable in time
  ];
  const byRepo = mergedInWindow(merges, 14, NOW);
  assert.deepEqual([...byRepo.get('o/a').keys()], [PR('o/a', 1)]);
});

test('the same PR ledgered twice counts once', () => {
  const byRepo = mergedInWindow([merge('o/a', 1, 2), merge('o/a', 1, 1)], 14, NOW);
  assert.equal(byRepo.get('o/a').size, 1);
});

// --- the rate ----------------------------------------------------------------

test('a PR that was both reverted and reopened is ONE merge that did not hold', () => {
  const rows = perRepo({
    merges: [merge('o/a', 1, 2), merge('o/a', 2, 2)],
    outcomes: [finding('o/a', 1, 'reverted'), finding('o/a', 1, 'reopened')],
    prCosts: [], gates: []
  }, 14, NOW);
  const a = rows.find((r) => r.repo === 'o/a');
  assert.equal(a.merged, 2);
  assert.equal(a.reverted, 1);
  assert.equal(a.reopened, 1);
  // Counting finding ROWS here would give 2/2 = 100%. It is one bad PR of two.
  assert.equal(a.bad, 1);
  assert.equal(a.rate, 0.5);
});

test('main-red is reported but is NOT in the revert/reopen rate', () => {
  const rows = perRepo({
    merges: [merge('o/a', 1, 2), merge('o/a', 2, 2)],
    outcomes: [finding('o/a', 1, 'merged_then_red')],
    prCosts: [], gates: []
  }, 14, NOW);
  const a = rows[0];
  assert.equal(a.mainRed, 1);
  assert.equal(a.bad, 0);
  assert.equal(a.rate, 0);
});

test('a finding for a PR outside the window does not move the rate', () => {
  const rows = perRepo({
    merges: [merge('o/a', 1, 2), merge('o/a', 9, 40)],
    outcomes: [finding('o/a', 9, 'reverted')],
    prCosts: [], gates: []
  }, 14, NOW);
  assert.equal(rows[0].merged, 1);
  assert.equal(rows[0].bad, 0);
});

test('cost per PR divides by the PRICED merges, never by the merged ones', () => {
  const rows = perRepo({
    merges: [merge('o/a', 1, 2), merge('o/a', 2, 2), merge('o/a', 3, 2)],
    outcomes: [],
    prCosts: [cost('o/a', 1, 10), cost('o/a', 2, 30), cost('o/a', 99, 500)],
    gates: []
  }, 14, NOW);
  const a = rows[0];
  assert.equal(a.merged, 3);
  assert.equal(a.pricedPrs, 2);
  assert.equal(a.costUsd, 40);
  // 40/2, not 40/3: dividing by merges the rollup never priced reports a number
  // that goes DOWN as attribution gets worse.
  assert.equal(a.costPerPr, 20);
  // A priced PR that is not in this window's merged set is somebody else's cost.
  assert.equal(rows.length, 1);
});

test('a repo with no priced merges reports unknown, never zero', () => {
  const rows = perRepo({ merges: [merge('o/a', 1, 2)], outcomes: [], prCosts: [], gates: [] }, 14, NOW);
  assert.equal(rows[0].costUsd, null);
  assert.equal(rows[0].costPerPr, null);
});

// --- the gate ----------------------------------------------------------------

test('the GATE column is read off the detector row, never recomputed here', () => {
  // A repo at a 100% rate with an INACTIVE gate row must still read as
  // auto-merge: the rule lives in bin/review-tighten.sh, and a screen that
  // second-guessed it would disagree with what actually parks PRs.
  const rows = perRepo({
    merges: [merge('o/a', 1, 2)],
    outcomes: [finding('o/a', 1, 'reverted')],
    prCosts: [],
    gates: [{ repo: 'o/a', tightened: 0, rate: 0.0, decision: 'clear' }]
  }, 14, NOW);
  assert.equal(rows[0].rate, 1);
  assert.equal(rows[0].tightened, false);

  const parked = perRepo({
    merges: [merge('o/b', 1, 2)],
    outcomes: [],
    prCosts: [],
    gates: [{ repo: 'o/b', tightened: 1, rate: 0.4, decision: 'tighten' }]
  }, 14, NOW);
  assert.equal(parked[0].rate, 0);
  assert.equal(parked[0].tightened, true);
});

test('a repo with no gate row is "not measured", which is not the same as "fine"', () => {
  const rows = perRepo({ merges: [merge('o/a', 1, 2)], outcomes: [], prCosts: [], gates: [] }, 14, NOW);
  assert.equal(rows[0].gate, null);
  assert.equal(rows[0].tightened, false);
});

// --- weekly burn -------------------------------------------------------------

test('a partial week says so and is never compared against', () => {
  const day = (d, usd) => ({ day: d, usd_equiv: usd, output: 10, api_calls: 5, peak_cache_read: 100 });
  const full = (start, usd) => Array.from({ length: 7 }, (_, i) => {
    const d = new Date(`${start}T00:00:00Z`);
    d.setUTCDate(d.getUTCDate() + i);
    return day(d.toISOString().slice(0, 10), usd);
  });
  const rows = weeklyBurn([
    ...full('2026-08-10', 10),   // 7 days, $70
    ...full('2026-08-17', 20),   // 7 days, $140
    day('2026-08-24', 30)        // 1 day
  ]);
  assert.deepEqual(rows.map((r) => r.week), ['2026-08-24', '2026-08-17', '2026-08-10']);
  const partial = rows[0];
  assert.equal(partial.days, 1);
  assert.equal(partial.complete, false);
  // "burn dropped 79%" would be a lie told by six missing days.
  assert.equal(partial.deltaPct, null);
  const complete = rows[1];
  assert.equal(complete.usd, 140);
  assert.equal(complete.deltaPct, 1);
  assert.equal(complete.deltaUsd, 70);
  // The oldest week has nothing before it to compare with.
  assert.equal(rows[2].deltaPct, null);
});

test('the burn bar is scaled against the dearest week in view, and survives an all-zero set', () => {
  const rows = weeklyBurn([{ day: '2026-08-24', usd_equiv: 0 }, { day: '2026-08-17', usd_equiv: 0 }]);
  assert.equal(rows.every((r) => r.share === 0), true);
});

test('a burn row with an unreadable day is dropped rather than bucketed somewhere', () => {
  assert.equal(weeklyBurn([{ day: 'never', usd_equiv: 9 }]).length, 0);
});

// --- findings + costs --------------------------------------------------------

test('a finding carries its cost and the job that built it when the ledgers know them', () => {
  const rows = findingRows({
    outcomes: [finding('o/a', 1, 'reverted'), finding('o/a', 2, 'reopened')],
    prCosts: [cost('o/a', 1, 12.5)],
    merges: [merge('o/a', 1, 2, { job_id: 'build-a-1' })]
  });
  assert.equal(rows[0].costUsd, 12.5);
  assert.equal(rows[0].jobId, 'build-a-1');
  // A PR the merge ledger never recorded gets nulls, not invented links.
  assert.equal(rows[1].costUsd, null);
  assert.equal(rows[1].jobId, null);
});

test('a landing with no finding reads as held, and one with findings carries them', () => {
  const rows = costRows({
    prCosts: [cost('o/a', 1, 5), cost('o/a', 2, 9)],
    merges: [merge('o/a', 1, 2), merge('o/a', 2, 2)],
    outcomes: [finding('o/a', 2, 'reverted')]
  }, 14, NOW);
  const held = rows.find((r) => r.number === 1);
  const bad = rows.find((r) => r.number === 2);
  assert.deepEqual(held.outcomes, []);
  assert.deepEqual(bad.outcomes, ['reverted']);
});

// --- the strip ---------------------------------------------------------------

test('the fleet rate is bad over merged, not the mean of the per-repo rates', () => {
  const rows = perRepo({
    merges: [
      merge('o/big', 1, 1), merge('o/big', 2, 1), merge('o/big', 3, 1), merge('o/big', 4, 1),
      merge('o/small', 1, 1)
    ],
    outcomes: [finding('o/small', 1, 'reverted')],
    prCosts: [], gates: []
  }, 14, NOW);
  const s = summarise(rows, []);
  assert.equal(s.merged, 5);
  assert.equal(s.bad, 1);
  // Averaging the per-repo rates (0% and 100%) would report 50% and give a repo
  // with one merge the same weight as one with four.
  assert.equal(s.rate, 0.2);
});

test('the strip counts parked repos off the gate rows it was handed', () => {
  const s = summarise([], [{ repo: 'o/a', tightened: 1 }, { repo: 'o/b', tightened: 0 }]);
  assert.equal(s.tightened, 1);
  assert.equal(s.rate, null);
  assert.equal(s.costPerPr, null);
});

// --- labels ------------------------------------------------------------------

test('an outcome nobody taught this screen still renders, and stays muted', () => {
  assert.equal(outcomeLabel('reverted'), 'REVERTED');
  assert.equal(outcomeLabel('merged_then_red'), 'MAIN WENT RED');
  assert.equal(outcomeLabel('something_new'), 'SOMETHING NEW');
  assert.equal(outcomeTone('something_new'), 'muted');
  assert.equal(outcomeTone('reverted'), 'dead');
});

test('an unknown rate prints as unknown, never as 0%', () => {
  assert.equal(pct(null), '—');
  assert.equal(pct(undefined), '—');
  assert.equal(pct(0), '0%');
  assert.equal(pct(0.205), '21%');
});

test('the display threshold ladder is repo, then fleet, then nothing', () => {
  const th = [{ scope: '*', tighten_rate: 0.2 }, { scope: 'o/a', tighten_rate: 0.5 }];
  assert.equal(thresholdFor(th, 'o/a').tighten_rate, 0.5);
  assert.equal(thresholdFor(th, 'o/z').tighten_rate, 0.2);
  assert.equal(thresholdFor([], 'o/a'), null);
});
