#!/bin/bash
# tests/pr-state-review-gate.bh-4950-test.sh — BH-4954 (BH-4950.1): the gate
# table the lead-review worklist reads is FED by the routes that already see
# each fact. One PR is replayed end to end through the production entry point,
# `worker.fetch` from "$DIR/worker/jobs/src/index.js", over the real schema.sql
# in node:sqlite:
#   1 synchronize head A                       -> not listed (no CI, no approve)
#   2 check_suite success on A                 -> not listed (no approve)
#   3 builder APPROVE on A (pr_url + verdict)  -> listed on A
#   4 synchronize head B                       -> not listed
#   5 check_suite on B + reapproved@B          -> listed on B
#   6 HOLD comment                             -> not listed
#   7 UNHOLD comment                           -> listed on B
#   8 lead MERGE on B (POST /api/verdicts)     -> not listed
# The writers are "$DIR/worker/jobs/src/lib/pr-gate-intake.js", hooked from
# "$DIR/worker/jobs/src/routes/webhooks.js",
# "$DIR/worker/jobs/src/routes/job-artifacts.js" and
# "$DIR/worker/jobs/src/routes/verdicts.js". The suite asserts needs-review
# membership AND the listed head at every step.
# Skips (and says so) when node or node:sqlite is absent.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pr-state-review-gate.bh-4950-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v node >/dev/null || { echo "node missing — skipping"; exit 0; }
node -e 'import("node:sqlite").then(()=>process.exit(0),()=>process.exit(1))' 2>/dev/null \
  || { echo "node:sqlite unavailable on this runtime — skipping"; exit 0; }
# worker/jobs imports the git-ignored catalog/lanes.json statically, so it is
# rendered first, as tests/jobs-worker-test.sh does (BH-1247).
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 \
    || { echo "FAIL: catalog/lanes.json could not be composed from catalog/lanes.d"; exit 1; }
fi

INTAKE="$DIR/worker/jobs/src/lib/pr-gate-intake.js"
[ -f "$INTAKE" ] && ok || bad "worker/jobs/src/lib/pr-gate-intake.js does not exist"

cat > "$T/driver.mjs" <<'EOF'
import { createHmac } from 'node:crypto';
const DIR = process.argv[2];
const { default: worker } = await import(`${DIR}/worker/jobs/src/index.js`);
const { openDb } = await import(`${DIR}/worker/jobs/test/lib/d1-sqlite.bh-1030.js`);
const o = await openDb();
const REPO = 'example-org/cromford';
const URL7 = `https://github.com/${REPO}/pull/7`;
const A = 'a'.repeat(40), B = 'b'.repeat(40);
const env = { DB: o.DB, HARNESS_SECRET: 'bearer', GITHUB_WEBHOOK_SECRET: 'gh-secret', LEAD_VERDICT_TOKEN: 'lead-tok' };
let dn = 0;
async function hook(event, payload) {
  const raw = JSON.stringify(payload);
  dn += 1;
  const res = await worker.fetch(new Request('https://jobs.test/webhooks/github', {
    method: 'POST', body: raw,
    headers: { 'content-type': 'application/json', 'x-github-event': event,
      'x-github-delivery': `d-${dn}`, 'x-hub-signature-256': 'sha256=' + createHmac('sha256', 'gh-secret').update(raw).digest('hex') },
  }), env);
  return res.status;
}
async function api(path, { method = 'GET', body, headers = {} } = {}) {
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, {
    method, body: body === undefined ? undefined : JSON.stringify(body),
    headers: { 'content-type': 'application/json', authorization: 'Bearer bearer', ...headers },
  }), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const repository = { full_name: REPO };
const sync = (sha) => hook('pull_request', { action: 'synchronize', number: 7, repository,
  pull_request: { number: 7, state: 'open', draft: false, html_url: URL7, head: { sha } } });
const ci = (sha) => hook('check_suite', { action: 'completed', repository,
  check_suite: { head_sha: sha, conclusion: 'success', app: { slug: 'github-actions' }, pull_requests: [{ number: 7 }] } });
const comment = (body) => hook('issue_comment', { action: 'created', repository,
  issue: { number: 7, pull_request: { url: URL7 } }, comment: { body, user: { type: 'User' } } });
async function needs(step) {
  const r = await api(`/api/pr-state/needs-review?repo=${REPO}`);
  const rows = (r.body && r.body.rows) || [];
  console.log(`step${step} status=${r.status} listed=${rows.map((x) => x.number).join(',') || '-'} head=${rows[0] ? rows[0].head : '-'}`);
}
await sync(A);
const g = await api(`/api/pr-state/gate?repo=${REPO}`);
console.log(`gate1 rows=${(g.body.rows || []).length} head=${(g.body.rows || [])[0]?.head || '-'}`);
await needs(1);
await ci(A); await needs(2);
o.db.prepare(`INSERT INTO jobs (id,project,kind,stage,box,ticket_id,status,created_at,updated_at)
  VALUES ('job-7','cromford','build','done','b','BH-1','done','2026-10-07T00:00:00Z','2026-10-07T00:00:00Z')`).run();
const p1 = await api('/api/jobs/job-7/artifacts', { method: 'PUT', body: { artifact_kind: 'pr_url', artifact_ref: URL7 } });
const p2 = await api('/api/jobs/job-7/artifacts', { method: 'PUT',
  body: { artifact_kind: 'verdict', artifact_ref: 'APPROVE', detail: { reviewed_sha: A, headbound: 'n/a', settled: true, tier: '2' } } });
console.log(`puts ${p1.status} ${p2.status}`);
await needs(3);
await sync(B); await needs(4);
await ci(B);
const p3 = await api('/api/jobs/job-7/artifacts', { method: 'PUT',
  body: { artifact_kind: 'verdict', artifact_ref: 'APPROVE', detail: { reviewed_sha: A, headbound: `reapproved@${B}`, settled: true, tier: '2' } } });
console.log(`rebind ${p3.status}`);
await needs(5);
await comment('HOLD: waiting on the migration'); await needs(6);
await comment('UNHOLD'); await needs(7);
const v = await api('/api/verdicts', { method: 'POST', headers: { 'x-lead-verdict-token': 'lead-tok' },
  body: { repo: REPO, pr: 7, head_sha: B, verdict: 'MERGE', source: 'lead' } });
console.log(`verdict ${v.status}`);
await needs(8);
EOF

node "$T/driver.mjs" "$DIR" > "$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "driver rc=$RC: $(head -c 2000 "$T/err")"
A=$(printf 'a%.0s' {1..40}); B=$(printf 'b%.0s' {1..40})
line() { grep "^$1 " "$T/out" | head -1; }
want() { [ "$(line "$1")" = "$1 $2" ] && ok || bad "$1: want '$2', got '$(line "$1")'"; }

want gate1 "rows=1 head=$A"
want step1 "status=200 listed=- head=-"
want step2 "status=200 listed=- head=-"
want puts "200 200"
want step3 "status=200 listed=7 head=$A"
want step4 "status=200 listed=- head=-"
want rebind "200"
want step5 "status=200 listed=7 head=$B"
want step6 "status=200 listed=- head=-"
want step7 "status=200 listed=7 head=$B"
want verdict "201"
want step8 "status=200 listed=- head=-"

echo "pr-state-review-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
