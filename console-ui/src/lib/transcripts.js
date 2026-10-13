// Derivations for the TRANSCRIPT section on the job drill-down. Pure, so the
// rules that decide what a reader is looking at - a full session or just the
// stage's final answer, all of it or only its tail, attached to a phase or
// floating - are tested in tests/transcripts.test.js rather than eyeballed.
//
// The rule this file keeps, and it is the same one lib/jobs.js keeps: say what
// the row actually is. A transcript is EVIDENCE, and evidence that quietly
// overstates itself is worse than none. So "stage_output" never renders as a
// session, a tail always says it is a tail, and a job with nothing on file gets
// a sentence explaining WHY rather than an empty box.

// The address of one attempt. phase_id 0 is the worker's "no phase row existed"
// sentinel, not a missing value - see worker/jobs/schema.sql.
export const transcriptKey = (t) =>
  `${Number(t && t.phase_id) || 0}:${Number(t && t.attempt) || 1}`;

// The blocking artifacts (BH-531) are not sessions at all: when a build ends
// PLAN_BLOCKED / REVIEW_BLOCKED / DECOMPOSE_FAILED, the pipeline pushes the BODY
// of the file its RESULT line points at, because that file lives on a pool
// machine that is destroyed at reap. They are named for the file they are.
const SOURCE_LABEL = {
  session_jsonl: 'session',
  stage_output: 'final output only',
  plan_md: 'plan.md (blocking artifact)',
  review_md: 'review.md (blocking artifact)',
  decompose_run: 'decompose-run.txt (blocking artifact)',
  lead_report: 'lead review report (full)'
};
const ARTIFACT_SOURCES = new Set(['plan_md', 'review_md', 'decompose_run']);
export const sourceLabel = (s) => SOURCE_LABEL[s] || (s ? String(s) : 'unknown');

// The one sentence that has to be exactly right: a reader must never think they
// are looking at a conversation when they are looking at one answer.
export function sourceNote(t) {
  const s = t && t.source;
  if (s === 'session_jsonl') return 'the whole session, turn by turn';
  if (s === 'stage_output') {
    return 'the stage’s final output only — no claude session file was resolvable for this attempt, '
      + 'which is what every non-claude runner (codex, grok, gemini, openrouter, fireworks) looks like here';
  }
  // The lead-review lane pushes the whole report when the job artifact had to
  // cut it at its 4000-unit cap. It is a finished file, not a blocked build.
  if (s === 'lead_report') {
    return 'the whole lead review report, pushed by the lead-review lane because the job artifact holds only its first 4000 characters — not a model session';
  }
  // Without this arm the artifacts fall through to the sentence below, which
  // would be false about them: the box recorded their provenance precisely, it
  // is simply a file rather than a conversation.
  if (ARTIFACT_SOURCES.has(s)) {
    return 'the file the build’s RESULT pointed at, pushed by the pipeline when the build ended blocked — not a model session';
  }
  return 'provenance not recorded by the box that pushed this';
}

// A transcript row joined to the phase it came out of. The phase carries the
// status and the rc, which is most of what makes a transcript worth opening:
// "the attempt that died at 137" is a better invitation than "attempt 3".
export function transcriptRows(detail) {
  const list = (detail && detail.transcripts) || [];
  const phases = (detail && detail.phases) || [];
  const byId = new Map(phases.map((p) => [Number(p.id), p]));
  return list
    .map((t) => {
      const phaseId = Number(t.phase_id) || 0;
      const phase = byId.get(phaseId) || null;
      return {
        ...t,
        key: transcriptKey(t),
        phase_id: phaseId,
        attempt: Number(t.attempt) || 1,
        // The phase's own words win over the transcript's copy: agent-call
        // pushes what it BELIEVED the stage was, and the phase row is what the
        // ledger recorded. They agree in practice; when they do not, the ledger
        // is the record.
        stage: (phase && phase.phase) || t.stage || null,
        phase,
        rc: phase && phase.rc !== null && phase.rc !== undefined ? Number(phase.rc) : null,
        status: (phase && phase.status) || null
      };
    })
    .sort((a, b) => (a.phase_id - b.phase_id) || (a.attempt - b.attempt));
}

// "EXECUTE · attempt 2". The attempt number is shown only when there is more
// than one on the phase - "attempt 1" on a stage that ran once is noise that
// implies a retry nobody made.
export function transcriptLabel(row, rows) {
  const stage = String((row && row.stage) || 'stage').toUpperCase();
  const siblings = (rows || []).filter((r) => r.phase_id === row.phase_id).length;
  return siblings > 1 || Number(row.attempt) > 1
    ? `${stage} · attempt ${row.attempt}`
    : stage;
}

// The one-line summary beside the heading. Everything in it is a fact the row
// carries; nothing is inferred.
export function transcriptMeta(row) {
  const bits = [];
  if (row.runner) bits.push(row.model ? `${row.runner}/${row.model}` : row.runner);
  bits.push(sourceLabel(row.source));
  if (row.bytes) bits.push(`${Math.max(1, Math.round(Number(row.bytes) / 1024))} KB`);
  if (Number(row.truncated)) bits.push('TAIL ONLY');
  const n = Number(row.redactions) || 0;
  if (n > 0) bits.push(`${n} value${n === 1 ? '' : 's'} redacted`);
  return bits.join(' · ');
}

// ── the honest empty state ───────────────────────────────────────────────────
// THE ENROLLMENT GAP IS REAL AND IT IS NAMED. bin/agent-call.sh pushes a
// transcript, so a job has one only if a MODEL SESSION ran under it. Plenty of
// rows in this ledger are coordination claims - merge-sweep, the watchdog, a
// migration apply - which call no model at all and never will. Rendering "no
// transcript" the same way for those as for a build whose push failed would
// teach a reader to distrust the section. So the note says which case this is,
// and it says "predates the feature" out loud for every row older than it.
export function emptyStateNote(detail) {
  const job = (detail && detail.job) || {};
  const phases = (detail && detail.phases) || [];
  const kind = String(job.kind || '').toLowerCase();
  const stage = String(job.stage || '').toLowerCase();
  const modelish = phases.some((p) => p.model || p.runner);
  if (!phases.length) {
    return 'This claim opened no stage, so there was no model session to record. '
      + 'Coordination lanes (merge-sweep, the watchdog, a migration apply) are the usual reason: '
      + 'they claim a row to serialise work, they never call a model, and they will never have a transcript.';
  }
  if (!modelish) {
    return `This claim ran ${phases.length} phase${phases.length === 1 ? '' : 's'} with no runner or model recorded on `
      + `${phases.length === 1 ? 'it' : 'any of them'}, which is what a coordination lane looks like. `
      + 'No model session ran, so there is nothing to read.';
  }
  return `No transcript was pushed for this ${kind || 'job'}${stage ? `/${stage}` : ''}. `
    + 'Either it ran before transcripts shipped (2026-08-29), or the box was running a bin/ that predates them, '
    + 'or the push failed - a push failure never fails the stage, so it leaves a line in logs/transcripts.log on the box and nothing here.';
}
