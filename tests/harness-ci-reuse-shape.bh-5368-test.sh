#!/bin/bash
# tests/harness-ci-reuse-shape.bh-5368-test.sh — the suite-reuse wiring in
# .github/workflows/harness-ci.yml and harness-nightly.yml (BH-5354.2 / BH-5368).
#
# Parsed as YAML (values, not text). The token is a WRITE credential for the
# suite ledger, so where it appears is the thing pinned hardest.
#
#   S1a  secrets.SUITE_LEDGER_TOKEN only in the plan step and the record step,
#        each gated on a push or a merge-queue head ref; never job/workflow env
#   S1b  plan step env: CI_PLAN_REUSE '1', CI_REUSE_CTX from vars.CI_RUNNER,
#        SUITE_LEDGER_URL from vars, CI_PLAN_REUSE_DIR
#   S1c  plan job outputs reused, saved_s, reuse; artifact suite-reuse-plan
#   S1d  tests-shard downloads it before the re-plan, which sets
#        CI_PLAN_REUSED_FILE, refuses a missing file when reused != 0 and keeps
#        its pinned ci-plan line
#   S1e  the trace step: pipefail first, its command kept, teed to gate.log
#   S1f  `record suite results` after the trace step, if: always(), record
#        --from-gate-log with the run key of run_id, attempt and shard
#   S1g  the record run has no `test-trace-safety.sh --gate`; no other shard
#        step holds the token
#   S1h  the record step's own script, run: shard 0 passes --reused, shard 1
#        does not; no token is one skipped line, rc 0, the helper not called
#   S1i  decisions reads needs.plan.outputs.reuse and echoes a `reuse:` line
#   S1j  nightly: a record step, if: always(), token only there, gated on
#        schedule; no `suite-reuse.sh plan`, no CI_PLAN_REUSE anywhere
#   S1k  no other job of harness-ci.yml references SUITE_LEDGER_TOKEN
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
NOW=2026-10-08T00:00:00Z

if ! python3 -c 'import yaml' > /dev/null 2>&1; then
  echo "harness-ci-reuse-shape: FAIL — needs python3 with PyYAML"; exit 1
fi

# The YAML half writes the record step's run scripts for S1h and prints one
# `ok <name>` / `FAIL <name>: <why>` line per check.
python3 - "$DIR" "$T" > "$T/py.out" 2>&1 <<'PY'
import sys, yaml, json
root, tmp = sys.argv[1], sys.argv[2]
ci = yaml.safe_load(open(root + '/.github/workflows/harness-ci.yml'))
ng = yaml.safe_load(open(root + '/.github/workflows/harness-nightly.yml'))
GATE = "(github.event_name == 'push' || (startsWith(github.head_ref, 'mergify/merge-queue/') && github.event.pull_request.user.login == 'mergify[bot]')) && secrets.SUITE_LEDGER_TOKEN || ''"
def check(name, cond, why=''):
    print(('ok ' + name) if cond else ('FAIL %s: %s' % (name, why)))
def step(job, name):
    return next((s for s in job['steps'] if s.get('name') == name), None)
def idx(job, pred):
    return next((i for i, s in enumerate(job['steps']) if pred(s)), -1)
def holds(obj, needle):
    return needle in json.dumps(obj)

jobs = ci['jobs']
plan, shard = jobs['plan'], jobs['tests-shard']
ps = next(s for s in plan['steps'] if s.get('id') == 'plan')
rec = step(shard, 'record suite results')

# S1a / S1g / S1k — where the token is
check('S1a no workflow-level env token', not holds(ci.get('env', {}), 'SUITE_LEDGER_TOKEN'))
for jn, j in jobs.items():
    check('S1a no job-level env token in ' + jn, not holds(j.get('env', {}), 'SUITE_LEDGER_TOKEN'))
check('S1a plan step token is event-gated', ps['env'].get('SUITE_LEDGER_TOKEN') == '${{ ' + GATE + ' }}', ps['env'].get('SUITE_LEDGER_TOKEN'))
check('S1a record step exists', rec is not None)
rec = rec or {'env': {}, 'run': ''}
check('S1a record step token is event-gated', rec.get('env', {}).get('SUITE_LEDGER_TOKEN') == '${{ ' + GATE + ' }}', rec.get('env', {}).get('SUITE_LEDGER_TOKEN'))
holders = [(jn, s.get('name') or s.get('uses')) for jn, j in jobs.items() for s in j.get('steps', [])
           if holds(s, 'SUITE_LEDGER_TOKEN')]
check('S1a/S1g/S1k exactly two steps hold the token', holders == [('plan', ps['name']), ('tests-shard', 'record suite results')], holders)
check('S1k token only via secrets in those two', json.dumps(ci).count('secrets.SUITE_LEDGER_TOKEN') == 2)
for jn in ('lint', 'console-ui', 'worker-jobs', 'determinism', 'prompt-evals', 'decisions', 'harness-safety'):
    check('S1k no token in ' + jn, jn in jobs and not holds(jobs[jn], 'SUITE_LEDGER_TOKEN'))

# S1b
e = ps['env']
check('S1b CI_PLAN_REUSE is the string 1', e.get('CI_PLAN_REUSE') == '1', e.get('CI_PLAN_REUSE'))
check('S1b CI_REUSE_CTX from vars.CI_RUNNER, joined', 'vars.CI_RUNNER' in str(e.get('CI_REUSE_CTX')) and 'join(' in str(e.get('CI_REUSE_CTX')), e.get('CI_REUSE_CTX'))
check('S1b SUITE_LEDGER_URL from vars', e.get('SUITE_LEDGER_URL') == '${{ vars.SUITE_LEDGER_URL }}', e.get('SUITE_LEDGER_URL'))
check('S1b CI_PLAN_REUSE_DIR under runner.temp', e.get('CI_PLAN_REUSE_DIR') == '${{ runner.temp }}/suite-reuse', e.get('CI_PLAN_REUSE_DIR'))

# S1c
for k in ('reused', 'saved_s', 'reuse'):
    check('S1c plan output ' + k, plan['outputs'].get(k) == '${{ steps.plan.outputs.%s }}' % k, plan['outputs'].get(k))
iup = idx(plan, lambda s: str(s.get('uses', '')).startswith('actions/upload-artifact') and s.get('with', {}).get('name') == 'suite-reuse-plan')
check('S1c plan uploads suite-reuse-plan after the plan step', iup > idx(plan, lambda s: s.get('id') == 'plan'), iup)
if iup >= 0:
    up = plan['steps'][iup]
    check('S1c upload: corpus runs only, the reuse dir, missing is an error',
          up.get('if') == "steps.plan.outputs.corpus == '1'" and up['with'].get('path') == '${{ runner.temp }}/suite-reuse/'
          and up['with'].get('if-no-files-found') == 'error', up)

# S1d
RP = "which suites this shard's run tests (must match the plan job)"
irp = idx(shard, lambda s: s.get('name') == RP)
idl = idx(shard, lambda s: str(s.get('uses', '')).startswith('actions/download-artifact') and s.get('with', {}).get('name') == 'suite-reuse-plan')
check('S1d shard downloads suite-reuse-plan before the re-plan', 0 <= idl < irp, (idl, irp))
if idl >= 0:
    check('S1d download is continue-on-error into the reuse dir',
          shard['steps'][idl].get('continue-on-error') is True and shard['steps'][idl]['with'].get('path') == '${{ runner.temp }}/suite-reuse')
rp = shard['steps'][irp] if irp >= 0 else {'run': '', 'env': {}}
check('S1d re-plan exports CI_PLAN_REUSED_FILE', 'export CI_PLAN_REUSED_FILE=' in rp['run'])
check('S1d re-plan keeps its pinned line', 'bin/ci-plan.sh --out "$RUNNER_TEMP/impact.txt" --expect-n "$PLAN_N"' in rp['run'])
check('S1d re-plan reads the plan reused count', rp['env'].get('PLAN_REUSED') == '${{ needs.plan.outputs.reused }}')
check('S1d re-plan holds no token and no ledger switch', not holds(rp, 'SUITE_LEDGER') and 'CI_PLAN_REUSE:' not in json.dumps(rp) and 'CI_PLAN_REUSE=' not in rp['run'])
open(tmp + '/replan.sh', 'w').write(rp['run'])

# S1e
itr = idx(shard, lambda s: str(s.get('name', '')).startswith('tests/ suite, traced'))
tr = shard['steps'][itr]['run'] if itr >= 0 else ''
check('S1e trace step starts with set -o pipefail', [l for l in tr.splitlines() if l.strip() and not l.strip().startswith('#')][:1] == ['set -o pipefail'])
for frag in ('bin/test-trace-safety.sh --gate', '--verdict "$RUNNER_TEMP/verdict/shard-$SHARD.txt"', '--shard "$SHARD/$PLAN_N"',
             '--only-file "$RUNNER_TEMP/impact.txt" . 2>&1 | tee "$RUNNER_TEMP/gate.log"'):
    check('S1e trace step keeps ' + frag, frag in tr)

# S1f / S1g
irec = idx(shard, lambda s: s.get('name') == 'record suite results')
iver = idx(shard, lambda s: s.get('with', {}).get('name') == 'verdict-${{ matrix.shard }}')
check('S1f record step after the trace step, before the verdict upload', itr < irec < iver, (itr, irec, iver))
check('S1f record step is if: always()', rec.get('if') == 'always()', rec.get('if'))
check('S1f record step runs record --from-gate-log', 'bin/suite-reuse.sh record' in rec['run'] and '--from-gate-log "$RUNNER_TEMP/gate.log"' in rec['run'])
check('S1f run key is run_id-attempt-shard', rec['env'].get('RUN_KEY') == '${{ github.run_id }}-${{ github.run_attempt }}-${{ matrix.shard }}', rec['env'].get('RUN_KEY'))
check('S1f record ctx matches the plan ctx', rec['env'].get('CI_REUSE_CTX') == ps['env'].get('CI_REUSE_CTX'))
check('S1f record never points --url at the run page', '--url' not in rec['run'] and 'server_url' not in json.dumps(rec))
check('S1g record run never runs the gate', 'test-trace-safety.sh --gate' not in rec['run'])
check('S1g record step name is not a tests/ suite step', not rec.get('name', '').startswith('tests/ suite'))
open(tmp + '/record.sh', 'w').write(rec['run'])

# S1i
dec = step(jobs['decisions'], 'every planned shard ran, and every test passed')
check('S1i decisions reads the reuse output', dec['env'].get('PLAN_REUSE') == '${{ needs.plan.outputs.reuse }}')
check('S1i decisions echoes a reuse line beside the summary', 'echo "reuse: ' in dec['run'] and dec['run'].index('echo "$PLAN_SUMMARY"') < dec['run'].index('echo "reuse: '))
check('S1i ci-verdicts call unchanged', 'bin/ci-verdicts.sh pure "$RUNNER_TEMP/verdicts" "${PLAN_N:-0}" "${PLAN_COUNT:-0}"' in dec['run'])

# S1j
nj = ng['jobs']
nrec = [(jn, s) for jn, j in nj.items() for s in j.get('steps', []) if s.get('name') == 'record suite results']
check('S1j nightly has one record step, in the shard job', [jn for jn, _ in nrec] == ['shard'])
if nrec:
    s = nrec[0][1]
    check('S1j nightly record is if: always()', s.get('if') == 'always()')
    check('S1j nightly record calls record --from-gate-log', 'bin/suite-reuse.sh record' in s['run'] and '--from-gate-log' in s['run'])
    check('S1j nightly token gated on schedule',
          s['env'].get('SUITE_LEDGER_TOKEN') == "${{ github.event_name == 'schedule' && secrets.SUITE_LEDGER_TOKEN || '' }}")
    check('S1j nightly record ctx matches CI', s['env'].get('CI_REUSE_CTX') == ps['env'].get('CI_REUSE_CTX'))
    ifp = idx(nj['shard'], lambda x: x.get('name') == "fingerprint tonight's suites")
    itn = idx(nj['shard'], lambda x: str(x.get('name', '')).startswith('the nightly suites, traced'))
    check('S1j nightly fingerprints before the traced run', 0 <= ifp < itn, (ifp, itn))
    open(tmp + '/nrecord.sh', 'w').write(s['run'])
nholders = [s.get('name') for j in nj.values() for s in j.get('steps', []) if holds(s, 'SUITE_LEDGER_TOKEN')]
check('S1j nightly token only in the record step', nholders == ['record suite results'], nholders)
check('S1j nightly never plans', 'suite-reuse.sh plan' not in json.dumps(ng) and 'CI_PLAN_REUSE' not in json.dumps(ng))
check('S1j nightly no job/workflow env token', not holds(ng.get('env', {}), 'SUITE_LEDGER') and all(not holds(j.get('env', {}), 'SUITE_LEDGER') for j in nj.values()))
PY
PYRC=$?

PASS=$(grep -c '^ok ' "$T/py.out"); FAIL=$(grep -c '^FAIL ' "$T/py.out")
grep '^FAIL ' "$T/py.out"
[ "$PYRC" = 0 ] || { FAIL=$((FAIL + 1)); echo "FAIL the YAML checks crashed: $(tail -5 "$T/py.out")"; }
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }

# ── S1h: the record step's own script, run against a stub helper ───────────
W="$T/tree"
mkdir -p "$W/bin" "$T/rt/suite-reuse"
cat > "$W/bin/suite-reuse.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/stub-calls"
EOF
chmod +x "$W/bin/suite-reuse.sh"
printf 'TRACE: 1 tests, 0 nonzero exit(s), 0 hit(s)\n' > "$T/rt/gate.log"
printf 'tests/a.sh\t%064d\t-\n' 0 > "$T/rt/suite-reuse/fingerprints.tsv"
: > "$T/rt/suite-reuse/reused.tsv"
rec() { # rec <shard> <token> — runs record.sh in $W; rc in RRC, stdout in $T/rec.out
  : > "$T/stub-calls"
  ( cd "$W" && env RUNNER_TEMP="$T/rt" SUITE_LEDGER_URL=https://ledger.test SUITE_LEDGER_TOKEN="$2" CI_REUSE_CTX=ctx \
      SHARD="$1" RUN_KEY="9-1-$1" REPO=o/r bash -e "$T/record.sh" ) > "$T/rec.out" 2>&1
  RRC=$?
}
if [ -s "$T/record.sh" ]; then
  rec 0 tok
  { [ "$RRC" = 0 ] && grep -qF -- "--run-key 9-1-0" "$T/stub-calls" && grep -qF -- "--reused $T/rt/suite-reuse/reused.tsv" "$T/stub-calls" \
    && grep -qF -- "--from-gate-log $T/rt/gate.log" "$T/stub-calls"; } \
    && ok || bad "S1h shard 0 passes --reused (rc=$RRC calls=$(cat "$T/stub-calls"))"
  rec 1 tok
  { [ "$RRC" = 0 ] && grep -qF -- "--run-key 9-1-1" "$T/stub-calls" && ! grep -qF -- "--reused" "$T/stub-calls"; } \
    && ok || bad "S1h shard 1 passes no --reused (rc=$RRC calls=$(cat "$T/stub-calls"))"
  rec 0 ''
  { [ "$RRC" = 0 ] && [ ! -s "$T/stub-calls" ] && [ "$(cat "$T/rec.out")" = "suite-reuse: record skipped (no credential)" ]; } \
    && ok || bad "S1h no token: one skipped line, rc 0, helper not called (rc=$RRC out=$(cat "$T/rec.out") calls=$(cat "$T/stub-calls"))"
  mv "$T/rt/gate.log" "$T/rt/gate.away"
  rec 0 tok
  { [ "$RRC" = 0 ] && [ ! -s "$T/stub-calls" ] && grep -q 'record skipped' "$T/rec.out"; } \
    && ok || bad "S1h no gate log: skipped, rc 0 (rc=$RRC out=$(cat "$T/rec.out"))"
  mv "$T/rt/gate.away" "$T/rt/gate.log"
else
  bad "S1h no record step script"
fi

# The re-plan: a missing artifact with reused != 0 is red; with reused 0 it
# plans as before. bin/ci-plan.sh is a stub that reports what it was handed.
cat > "$W/bin/ci-plan.sh" <<EOF
#!/bin/bash
echo "file=\${CI_PLAN_REUSED_FILE:-unset} args=\$*" >> "$T/stub-calls"
EOF
chmod +x "$W/bin/ci-plan.sh"
replan() { : > "$T/stub-calls"; ( cd "$W" && env RUNNER_TEMP="$T/rt" PLAN_N=2 PLAN_REUSED="$1" bash -e "$T/replan.sh" ) > "$T/rp.out" 2>&1; RRC=$?; }
replan 1
{ [ "$RRC" = 0 ] && grep -qF "file=$T/rt/suite-reuse/reused.tsv args=--out $T/rt/impact.txt --expect-n 2" "$T/stub-calls"; } \
  && ok || bad "S1d artifact present: the shard subtracts it (rc=$RRC calls=$(cat "$T/stub-calls"))"
rm -rf "$T/rt/suite-reuse"
replan 3
{ [ "$RRC" != 0 ] && [ ! -s "$T/stub-calls" ] && grep -q '::error::' "$T/rp.out"; } \
  && ok || bad "S1d missing artifact with reused=3 is red before planning (rc=$RRC out=$(cat "$T/rp.out"))"
replan 0
{ [ "$RRC" = 0 ] && grep -qF "file=unset" "$T/stub-calls"; } \
  && ok || bad "S1d missing artifact with reused=0 plans the whole list (rc=$RRC calls=$(cat "$T/stub-calls"))"

# The nightly record step: no fingerprints writes nothing, rc 0.
if [ -s "$T/nrecord.sh" ]; then
  mkdir -p "$T/nt/verdict"; printf 'TRACE: 1 tests\n' > "$T/nt/verdict/shard-0.log"; : > "$T/nt/suite-fp.tsv"
  : > "$T/stub-calls"
  ( cd "$W" && env RUNNER_TEMP="$T/nt" SUITE_LEDGER_TOKEN=tok CI_REUSE_CTX=ctx SHARD=0 RUN_KEY=nightly-9-1-0 REPO=o/r \
      bash -e "$T/nrecord.sh" ) > "$T/nr.out" 2>&1; RRC=$?
  { [ "$RRC" = 0 ] && [ ! -s "$T/stub-calls" ]; } && ok || bad "S1j nightly with no fingerprints: rc 0, nothing recorded (rc=$RRC)"
  printf 'tests/a.sh\t%064d\t-\n' 0 > "$T/nt/suite-fp.tsv"
  ( cd "$W" && env RUNNER_TEMP="$T/nt" SUITE_LEDGER_TOKEN=tok CI_REUSE_CTX=ctx SHARD=0 RUN_KEY=nightly-9-1-0 REPO=o/r \
      bash -e "$T/nrecord.sh" ) > "$T/nr.out" 2>&1; RRC=$?
  { [ "$RRC" = 0 ] && grep -qF -- "--run-key nightly-9-1-0" "$T/stub-calls" && grep -qF -- "--from-gate-log $T/nt/verdict/shard-0.log" "$T/stub-calls"; } \
    && ok || bad "S1j nightly records its shard log (rc=$RRC calls=$(cat "$T/stub-calls"))"
fi

echo "harness-ci-reuse-shape: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
