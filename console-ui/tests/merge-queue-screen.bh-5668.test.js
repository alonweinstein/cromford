import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';

// BH-5668 (BH-5008 child 2): the batch table at the top of /merge-queue and
// the one-line strip at the top of /jobs. The views take the hook's answer
// (useMergeQueueLive: { state, batches, complete, error, fetchedAt, reload })
// as a prop, so every state renders server-side here without a fetch.

globalThis.window = globalThis.window || {
  location: { pathname: '/merge-queue', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { render } = await import('preact-render-to-string');
const {
  MergeQueueBatches, MergeQueueBatchesView, MergeQueueStripView, etaWords, pct, prHref,
} = await import('../src/ui/merge-queue-live.js');

const REPO = 'example-org/cromford';
const batch = (draft, o = {}) => ({
  repo: REPO, draft, url: `https://github.com/${REPO}/pull/${draft}`, members: [101, 102], base_sha: 'a'.repeat(40),
  stage: null, checks: { done: 10, total: 14 }, progress: 0.712, eta_s: 400, eta_basis: 'name',
  failing: null, bisect: null, outcome: null, ...o,
});
const res = (o = {}) => ({
  state: 'ok', batches: [], waiting: [], complete: true, error: null, fetchedAt: Date.parse('2026-10-09T03:10:00Z'), reload() {}, ...o,
});
const text = (s) => s.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');

test('S1 one [data-mq-batch] progressbar per batch, aria-valuenow = pct(progress), fill width matches', () => {
  const out = render(h(MergeQueueBatchesView, { res: res({ batches: [batch(9001), batch(9002, { progress: 0.25 })] }) }));
  const bars = [...out.matchAll(/<div[^>]*data-mq-batch="(\d+)"[^>]*>/g)];
  assert.deepEqual(bars.map((m) => m[1]), ['9001', '9002']);
  for (const [tag] of bars) assert.match(tag, /role="progressbar"/);
  assert.match(out, /data-mq-batch="9001"[^>]*aria-valuenow="71"|aria-valuenow="71"[^>]*data-mq-batch="9001"/);
  assert.match(out, /aria-valuenow="25"/);
  assert.match(out, /width:\s*71%/);
  assert.match(out, /width:\s*25%/);
  assert.equal(pct(0.712), 71);
  assert.equal(pct(null), 0);
});

test('S2 the row says Checks 10/14', () => {
  const out = render(h(MergeQueueBatchesView, { res: res({ batches: [batch(9001)] }) }));
  assert.match(text(out), /Checks 10\/14/);
});

test('S3 ETA words: about N min left, under 1 min left, no estimate yet, finished', () => {
  assert.equal(etaWords(batch(1, { eta_s: 400 })), 'about 7 min left');
  assert.equal(etaWords(batch(1, { eta_s: 30 })), 'under 1 min left');
  assert.equal(etaWords(batch(1, { eta_s: null, eta_basis: 'partial' })), 'no estimate yet');
  assert.equal(etaWords(batch(1, { eta_s: 0, eta_basis: 'done' })), 'finished');
  const out = text(render(h(MergeQueueBatchesView, { res: res({ batches: [batch(1, { eta_s: 400 }), batch(2, { eta_s: null })] }) })));
  assert.match(out, /about 7 min left/);
  assert.match(out, /no estimate yet/);
});

test('S4 members link to /pr/<project>/<n>; the draft links to its GitHub PR', () => {
  const out = render(h(MergeQueueBatchesView, { res: res({ batches: [batch(9001)] }) }));
  assert.match(out, /<a href="\/pr\/cromford\/101"[^>]*>#101<\/a>/);
  assert.match(out, /<a href="\/pr\/cromford\/102"[^>]*>#102<\/a>/);
  assert.match(out, new RegExp(`<a href="https://github.com/${REPO}/pull/9001"[^>]*>#9001</a>`));
  assert.equal(prHref(batch(1), 7), '/pr/cromford/7');
  assert.equal(prHref({ url: 'https://github.com/o/some-repo/pull/5' }, 7), '/pr/some-repo/7');
  assert.equal(prHref({ project: 'project-3', repo: REPO }, 7), '/pr/project-3/7');
});

test('S5 a stage renders a chip; a null stage renders no chip element', () => {
  const on = render(h(MergeQueueBatchesView, { res: res({ batches: [batch(9001, { stage: 'checking' })] }) }));
  assert.match(on, /<span[^>]*data-mq-stage[^>]*>checking<\/span>/);
  const off = render(h(MergeQueueBatchesView, { res: res({ batches: [batch(9001)] }) }));
  assert.doesNotMatch(off, /data-mq-stage/);
});

test('S6 a load error with no data is not the empty queue, and the empty queue is not an error', () => {
  const err = render(h(MergeQueueBatchesView, { res: res({ state: 'error', error: 'http_503', fetchedAt: null }) }));
  assert.match(text(err), /could not load/);
  assert.match(err, /RETRY/);
  assert.doesNotMatch(err, /No batch is running/);
  const empty = render(h(MergeQueueBatchesView, { res: res({ state: 'empty' }) }));
  assert.match(empty, /No batch is running\./);
  assert.doesNotMatch(empty, /could not load|Last update failed/);
  const loading = render(h(MergeQueueBatchesView, { res: res({ state: 'loading', fetchedAt: null }) }));
  assert.doesNotMatch(loading, /No batch is running|could not load/);
});

test('S6 an error over stale data shows the table and says it is stale; a capped list says so', () => {
  const out = text(render(h(MergeQueueBatchesView, { res: res({ batches: [batch(9001)], error: 'http_503', complete: false }) })));
  assert.match(out, /Checks 10\/14/);
  assert.match(out, /Last update failed; showing data from \d\d:\d\d/);
  assert.match(out, /The list is capped\./);
  const fresh = text(render(h(MergeQueueBatchesView, { res: res({ batches: [batch(9001)] }) })));
  assert.doesNotMatch(fresh, /Last update failed|capped/);
});

test('S7 the table sits in .tablewrap and every header sorts (aria-sort)', () => {
  const out = render(h(MergeQueueBatchesView, { res: res({ batches: [batch(9001), batch(9002)] }) }));
  assert.match(out, /class="tablewrap[^"]*"/);
  const ths = [...out.matchAll(/<th[\s>][^>]*>/g)].map((m) => m[0]);
  assert.equal(ths.length, 6);
  for (const th of ths) assert.match(th, /aria-sort="/);
  assert.equal((out.match(/<th[\s>][^>]*>\s*<button/g) || []).length, 6);
  // Default sort: draft ascending.
  assert.ok(out.indexOf('data-mq-batch="9001"') < out.indexOf('data-mq-batch="9002"'));
  const rev = render(h(MergeQueueBatchesView, { res: res({ batches: [batch(9002), batch(9001)] }) }));
  assert.ok(rev.indexOf('data-mq-batch="9001"') < rev.indexOf('data-mq-batch="9002"'));
});

test('S8 the strip is one line linked to /merge-queue in every state', () => {
  const one = render(h(MergeQueueStripView, { res: res({ batches: [batch(9001)] }) }));
  assert.match(one, /^<a href="\/merge-queue"/);
  assert.match(text(one), /Merge queue: 1 batch running · #9001 71% about 7 min left/);
  const two = text(render(h(MergeQueueStripView, { res: res({ batches: [batch(9005, { progress: 0.1 }), batch(9002, { eta_s: null })] }) })));
  assert.match(two, /2 batches running · #9002 71% no estimate yet/);
  const empty = render(h(MergeQueueStripView, { res: res({ state: 'empty' }) }));
  assert.match(empty, /^<a href="\/merge-queue"/);
  assert.match(text(empty), /Merge queue: nothing running/);
  const err = render(h(MergeQueueStripView, { res: res({ state: 'error', error: 'boom', fetchedAt: null }) }));
  assert.match(err, /^<a href="\/merge-queue"/);
  assert.match(text(err), /Merge queue: could not load/);
  const loading = render(h(MergeQueueStripView, { res: res({ state: 'loading', fetchedAt: null }) }));
  assert.match(text(loading), /Merge queue: loading/);
});

test('S9 the mounted component renders through the real hook (SSR: the loading state)', () => {
  const out = render(h(MergeQueueBatches, { project: 'cromford' }));
  assert.match(out, /class="skel"/);
});
