import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import {
  transcriptKey, transcriptRows, transcriptLabel, transcriptMeta,
  sourceLabel, sourceNote, emptyStateNote
} from '../src/lib/transcripts.js';
import { TranscriptList, TranscriptAttempt } from '../src/ui/Transcript.js';

// The rules under test are the ones a reader will TRUST on sight. A transcript
// is evidence, and the way this feature fails badly is not by crashing - it is
// by quietly overstating itself: showing one stage's final answer as though it
// were the whole session, showing a tail as though it were everything, or
// showing "no transcript" for a lane that was never going to have one.

const T = (over) => ({
  job_id: 'build-project-3-TK-1-1', phase_id: 7, attempt: 1, stage: 'execute',
  runner: 'claude', model: 'claude-opus-5', source: 'session_jsonl',
  bytes: 48000, truncated: 0, redactions: 0, created_at: '2026-08-29T10:00:00Z',
  ...over
});
const PHASE = (over) => ({
  id: 7, job_id: 'build-project-3-TK-1-1', phase: 'execute', runner: 'claude',
  model: 'claude-opus-5', status: 'done', rc: 0, ...over
});

// --- addressing --------------------------------------------------------------

test('an attempt is addressed by phase and attempt, with 0 as the no-phase sentinel', () => {
  assert.equal(transcriptKey(T()), '7:1');
  assert.equal(transcriptKey(T({ phase_id: null, attempt: null })), '0:1');
});

test('rows come back in phase then attempt order, whatever order the ledger returned', () => {
  const rows = transcriptRows({
    transcripts: [T({ phase_id: 9, attempt: 2 }), T({ phase_id: 7, attempt: 2 }), T({ phase_id: 7, attempt: 1 })],
    phases: []
  });
  assert.deepEqual(rows.map((r) => r.key), ['7:1', '7:2', '9:2']);
});

test('a transcript is joined to its phase, so the row carries the status and rc', () => {
  const rows = transcriptRows({
    transcripts: [T()],
    phases: [PHASE({ status: 'failed', rc: 137 })]
  });
  assert.equal(rows[0].status, 'failed');
  assert.equal(rows[0].rc, 137);
});

test('the phase row wins over the pushed copy when they disagree', () => {
  // agent-call.sh pushes what it BELIEVED the stage was; the phase row is what
  // the ledger recorded. When they differ the ledger is the record.
  const rows = transcriptRows({ transcripts: [T({ stage: 'execute' })], phases: [PHASE({ phase: 'review' })] });
  assert.equal(rows[0].stage, 'review');
});

test('a transcript with no phase row still renders, unattributed', () => {
  const rows = transcriptRows({ transcripts: [T({ phase_id: 0 })], phases: [PHASE()] });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].phase, null);
  assert.equal(rows[0].rc, null);
});

// --- labels: the part that must not overstate --------------------------------

test('a stage that ran once does not advertise "attempt 1"', () => {
  // "attempt 1" implies a retry nobody made.
  const rows = transcriptRows({ transcripts: [T()], phases: [PHASE()] });
  assert.equal(transcriptLabel(rows[0], rows), 'EXECUTE');
});

test('a stage that failed over names each attempt', () => {
  const rows = transcriptRows({ transcripts: [T(), T({ attempt: 2, runner: 'codex' })], phases: [PHASE()] });
  assert.equal(transcriptLabel(rows[0], rows), 'EXECUTE · attempt 1');
  assert.equal(transcriptLabel(rows[1], rows), 'EXECUTE · attempt 2');
});

test('a full session and a bare stage output never read the same', () => {
  assert.equal(sourceLabel('session_jsonl'), 'session');
  assert.equal(sourceLabel('stage_output'), 'final output only');
  assert.match(sourceNote(T()), /whole session, turn by turn/);
  const note = sourceNote(T({ source: 'stage_output' }));
  assert.match(note, /final output only/);
  // The enrolment gap, stated where a reader meets it: every non-claude runner
  // looks like this, and the note has to say so rather than leave them guessing.
  assert.match(note, /codex, grok, gemini, openrouter, fireworks/);
});

test('the meta line states the tail and the redactions as facts, not as decoration', () => {
  const m = transcriptMeta(T({ bytes: 150000, truncated: 1, redactions: 3 }));
  assert.match(m, /claude\/claude-opus-5/);
  assert.match(m, /TAIL ONLY/);
  assert.match(m, /3 values redacted/);
  assert.match(m, /146 KB/);
  // A clean, complete transcript claims neither.
  const clean = transcriptMeta(T());
  assert.doesNotMatch(clean, /TAIL ONLY/);
  assert.doesNotMatch(clean, /redacted/);
  assert.match(transcriptMeta(T({ redactions: 1 })), /1 value redacted/);
});

// --- the honest empty state --------------------------------------------------

test('a coordination claim is told it was never going to have one', () => {
  // merge-sweep, the watchdog, a migration apply: they claim a row to serialise
  // work and never call a model. Rendering these the same way as a build whose
  // push failed would teach a reader to distrust the whole section.
  const note = emptyStateNote({ job: { kind: 'merge', stage: 'sweep' }, phases: [] });
  assert.match(note, /never call a model|no model session/i);
  assert.match(note, /merge-sweep/);
});

test('a claim whose phases carry no runner or model reads as a coordination lane', () => {
  const note = emptyStateNote({ job: { kind: 'merge' }, phases: [{ id: 1, phase: 'sweep', status: 'done' }] });
  assert.match(note, /no runner or model recorded/);
});

test('a real model job with nothing on file gets the three real reasons', () => {
  const note = emptyStateNote({ job: { kind: 'build', stage: 'execute' }, phases: [PHASE()] });
  assert.match(note, /before transcripts shipped/);
  assert.match(note, /predates them/);
  assert.match(note, /push failed/);
  // And it must not blame the stage: a push failure never fails a build.
  assert.match(note, /never fails the stage/);
});

// --- the component -----------------------------------------------------------
// Rendered for real, so the branches a reader actually sees are under test
// rather than inspected by eye in a browser.

test('the empty state renders the sentence lib/transcripts computed', () => {
  const out = render(h(TranscriptList, { jobId: 'j', rows: [], emptyNote: 'a very specific reason' }));
  assert.match(out, /NO TRANSCRIPT PUSHED/);
  assert.match(out, /a very specific reason/);
});

test('every attempt gets a row, and each row is collapsed', () => {
  const rows = transcriptRows({ transcripts: [T(), T({ attempt: 2, runner: 'codex', source: 'stage_output' })], phases: [PHASE()] });
  const out = render(h(TranscriptList, { jobId: 'j', rows, emptyNote: 'x' }));
  assert.match(out, /EXECUTE · attempt 1/);
  assert.match(out, /EXECUTE · attempt 2/);
  // Collapsed by default and honest about it to a screen reader: a 150KB body
  // per attempt is not something a drill-down should fetch to draw a heading.
  assert.equal(out.match(/aria-expanded="false"/g).length, 2);
  assert.doesNotMatch(out, /term--transcript/);
});

test('a collapsed head still shows the status, the rc and the provenance', () => {
  // This is what makes a row worth opening: "the attempt that died at 137" is a
  // better invitation than "attempt 3".
  const rows = transcriptRows({ transcripts: [T()], phases: [PHASE({ status: 'failed', rc: 137 })] });
  const out = render(h(TranscriptAttempt, { jobId: 'j', row: rows[0], rows }));
  assert.match(out, /FAILED/);
  assert.match(out, /rc 137/);
  assert.match(out, /session/);
});

test('a transcript head is a real button, not a clickable div', () => {
  // Keyboard reachability is the point; the caret is decoration on top of it.
  const rows = transcriptRows({ transcripts: [T()], phases: [PHASE()] });
  const out = render(h(TranscriptAttempt, { jobId: 'j', row: rows[0], rows }));
  assert.match(out, /<button[^>]*class="tr__head"/);
  assert.match(out, /aria-expanded="false"/);
});
