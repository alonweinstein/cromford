// The three blocking-artifact sources BH-531 added to the ledger. The console
// is the only reader of a transcript row's `source`, and its fallback note says
// "provenance not recorded by the box that pushed this" — which would be FALSE
// for these rows: the box recorded the provenance precisely, it is just a file
// rather than a model session. A row that renders a false sentence is a bug in
// the sentence, so each new source names itself and says what it is not.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sourceLabel, sourceNote, transcriptMeta } from '../src/lib/transcripts.js';

const ARTIFACTS = [
  ['plan_md', 'plan.md'],
  ['review_md', 'review.md'],
  ['decompose_run', 'decompose-run.txt']
];

test('each blocking artifact source is labelled with the file it is', () => {
  for (const [source, file] of ARTIFACTS) {
    const label = sourceLabel(source);
    assert.ok(label.includes(file), `${source} label should name ${file}, got "${label}"`);
    assert.notEqual(label, source, `${source} must not render as its raw column value`);
  }
});

test('a blocking artifact never reads as a model session', () => {
  for (const [source] of ARTIFACTS) {
    const note = sourceNote({ source });
    assert.match(note, /not a model session/, `${source} note should say what it is not`);
    assert.doesNotMatch(note, /provenance not recorded/,
      `${source} fell through to the unknown-source note, which is false for it`);
  }
});

test('the unknown-source fallback is unchanged', () => {
  assert.match(sourceNote({ source: 'weird' }), /provenance not recorded/);
  assert.match(sourceNote({}), /provenance not recorded/);
  assert.equal(sourceLabel('weird'), 'weird');
  assert.equal(sourceLabel(''), 'unknown');
});

test('the sessions the console already knew about still read the same', () => {
  assert.equal(sourceLabel('session_jsonl'), 'session');
  assert.equal(sourceNote({ source: 'session_jsonl' }), 'the whole session, turn by turn');
  assert.match(sourceNote({ source: 'stage_output' }), /final output only/);
});

test('an artifact row summarises with its label and its tail flag', () => {
  const meta = transcriptMeta({ source: 'plan_md', runner: 'pipeline', bytes: 2048, truncated: 1 });
  assert.ok(meta.includes('plan.md'), `expected the artifact label in "${meta}"`);
  assert.ok(meta.includes('TAIL ONLY'), `expected the tail flag in "${meta}"`);
});
