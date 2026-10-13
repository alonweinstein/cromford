#!/bin/bash
# tests/ci-durations-post.bh-5653-test.sh — a merge-queue batch posts its suite
# timings to the jobs worker (BH-5653), through bin/ci-durations.sh post.
#
#   P1  a real bin/test-trace-safety.sh --gate --timings run on a 4-suite
#       scratch root (one suite fails) -> post --run-id 7 -> the REAL worker
#       (tests/lib/ci-durations-worker.bh-5653.mjs over node:sqlite) stores 3
#       samples, one per passing suite, and GET answers them with source_run 7
#   P2  the same post again -> "run 7 already posted", samples unchanged
#   P3  the failing suite's seconds (rc != 0) are not in the body
#   P4  no JOBS_URL, or no token -> rc 0, "not configured", no request sent
#   P5  a worker answering 500 -> rc 0, one ::warning::, never "posted", and
#       the token is in neither stdout nor stderr
#   P6  no timing rows -> rc 0, "no timings", no request sent
#   P7  the same run id with other seconds -> 409 -> rc 0 and a ::warning::
#       naming the run; samples unchanged
#   P8  a run id that is not a positive integer -> rc 2, no request sent
#
# The worker route under test is worker/jobs/src/routes/ci-durations.js; its
# own node suite is worker/jobs/test/ci-durations.bh-5653.test.js.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
CDS="$DIR/bin/ci-durations.sh"
ROUTE="$DIR/worker/jobs/src/routes/ci-durations.js"
SRV="$DIR/tests/lib/ci-durations-worker.bh-5653.mjs"
TRACER="$DIR/bin/test-trace-safety.sh"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "SKIP: node/python3 missing"; exit 0; }
TOK=fixture-ci-token
mkdir -p "$T/h"
# HARNESS is a scratch tree with no env/global.env, so no live secret is read.
export HARNESS="$T/h"
unset CI_DURATIONS_TOKEN HARNESS_SECRET CI_DURATIONS_CACHE

PIDS=()
# srv <name> worker|canned [<status> <body file>] -> PORT, or rc 3 (no node:sqlite)
srv() {
  local n="$1"; shift
  : > "$T/$n.log"; : > "$T/$n.port"
  node "$SRV" "$1" "$T/$n.log" "${@:2}" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 100); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
}
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
samples() { curl -sS "http://127.0.0.1:$1/__samples" | python3 -c 'import json,sys; print(json.load(sys.stdin)["samples"])'; }

echo "P7: the names this suite pins"
[ -f "$CDS" ] && ok "P7 $CDS exists" || bad "P7 no bin/ci-durations.sh"
[ -f "$ROUTE" ] && ok "P7 $ROUTE exists" || bad "P7 no worker/jobs/src/routes/ci-durations.js"

echo "P1: real tracer timings -> post -> the real worker"
FX="$T/fx"; mkdir -p "$FX/tests" "$T/td"
for s in alpha beta gamma; do printf '#!/bin/bash\nexit 0\n' > "$FX/tests/$s-test.sh"; done
printf '#!/bin/bash\nexit 3\n' > "$FX/tests/broken-test.sh"
HARNESS_TEST_SANDBOX=1 "$TRACER" --gate --timings "$T/td/shard-0.tsv" "$FX" > "$T/trace.out" 2>&1; rc=$?
[ "$rc" = 1 ] && ok "P1 the tracer ran and saw the failing suite (rc 1)" || bad "P1 tracer rc=$rc $(tail -5 "$T/trace.out")"
[ "$(grep -c . "$T/td/shard-0.tsv" 2>/dev/null)" = 4 ] && ok "P1 the tracer wrote 4 timing rows" || bad "P1 timings: $(cat "$T/td/shard-0.tsv" 2>&1)"
srv w1 worker; src=$?
if [ "$src" = 3 ]; then
  echo "SKIP P1-P3, P7: node:sqlite unavailable in this runtime"
else
  [ -n "$PORT" ] && ok "P1 the worker listens" || bad "P1 worker did not start: $(cat "$T/w1.err")"
  W1="$PORT"
  JOBS_URL="http://127.0.0.1:$W1" CI_DURATIONS_TOKEN=$TOK "$CDS" post --run-id 7 --timings-dir "$T/td" > "$T/p1.out" 2> "$T/p1.err"; rc=$?
  [ "$rc" = 0 ] && ok "P1 post rc 0" || bad "P1 post rc=$rc $(cat "$T/p1.out" "$T/p1.err")"
  grep -qxF 'ci-durations: posted run 7: 3 rows' "$T/p1.out" && ok "P1 posted 3 rows" || bad "P1 out: $(cat "$T/p1.out" "$T/p1.err")"
  [ "$(samples "$W1")" = 3 ] && ok "P1 the worker holds 3 samples" || bad "P1 samples=$(samples "$W1")"
  curl -sS -H "authorization: Bearer $TOK" "http://127.0.0.1:$W1/api/ci/suite-durations" > "$T/p1.get"
  python3 - "$T/p1.get" "$T/td/shard-0.tsv" <<'PY' && ok "P1 GET answers each passing suite at its traced seconds, source_run 7" || bad "P1 GET: $(cat "$T/p1.get")"
import json, sys
got = {r["suite"]: r for r in json.load(open(sys.argv[1]))["rows"]}
want = {}
for line in open(sys.argv[2]):
    s, sec, rc = line.rstrip("\n").split("\t")
    if rc == "0":
        want[s] = float(sec)
assert set(got) == set(want) == {"tests/alpha-test.sh", "tests/beta-test.sh", "tests/gamma-test.sh"}, (got, want)
for s, sec in want.items():
    assert got[s]["seconds"] == sec and got[s]["source_run"] == 7 and got[s]["samples"] == 1, got[s]
PY

  echo "P3: a failing suite's seconds are not posted"
  B=$(head -1 "$T/w1.log.body")
  case "$B" in *broken-test.sh*) bad "P3 the body carries the failing suite: $B" ;; *alpha-test.sh*) ok "P3 rc != 0 row left out" ;; *) bad "P3 body unreadable: $B" ;; esac
  printf '%s' "$B" | python3 -c 'import json,sys; b=json.load(sys.stdin); assert b["run_id"]==7 and b["source"]=="ci" and len(b["rows"])==3' \
    && ok "P3 body is {run_id 7, source ci, 3 rows}" || bad "P3 body shape: $B"

  echo "P2: the same run posted twice"
  JOBS_URL="http://127.0.0.1:$W1" CI_DURATIONS_TOKEN=$TOK "$CDS" post --run-id 7 --timings-dir "$T/td" > "$T/p2.out" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -qxF 'ci-durations: run 7 already posted' "$T/p2.out" && ok "P2 already posted" || bad "P2 rc=$rc $(cat "$T/p2.out")"
  [ "$(samples "$W1")" = 3 ] && ok "P2 samples unchanged" || bad "P2 samples=$(samples "$W1")"

  echo "P7: the same run id with other seconds"
  mkdir -p "$T/td7"; sed 's/\t[0-9.]*\t0$/\t99.0\t0/' "$T/td/shard-0.tsv" > "$T/td7/shard-0.tsv"
  JOBS_URL="http://127.0.0.1:$W1" CI_DURATIONS_TOKEN=$TOK "$CDS" post --run-id 7 --timings-dir "$T/td7" > "$T/p7.out" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q '^::warning::ci-durations: run 7 was already posted with other rows' "$T/p7.out" \
    && ok "P7 409 is a warning naming the run" || bad "P7 rc=$rc $(cat "$T/p7.out")"
  grep -q 'posted run' "$T/p7.out" && bad "P7 a 409 printed 'posted'" || ok "P7 a 409 never reads as posted"
  [ "$(samples "$W1")" = 3 ] && ok "P7 samples unchanged" || bad "P7 samples=$(samples "$W1")"
fi

echo "P4: not configured -> no request"
printf '{}' > "$T/empty.json"
srv c4 canned 200 "$T/empty.json"; C4="$PORT"
JOBS_URL= CI_DURATIONS_TOKEN=$TOK "$CDS" post --run-id 8 --timings-dir "$T/td" > "$T/p4a.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qxF 'ci-durations: post skipped, not configured (no JOBS_URL or token)' "$T/p4a.out" \
  && ok "P4 no JOBS_URL: rc 0, not configured" || bad "P4a rc=$rc $(cat "$T/p4a.out")"
JOBS_URL="http://127.0.0.1:$C4" "$CDS" post --run-id 8 --timings-dir "$T/td" > "$T/p4b.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qxF 'ci-durations: post skipped, not configured (no JOBS_URL or token)' "$T/p4b.out" \
  && ok "P4 no token: rc 0, not configured" || bad "P4b rc=$rc $(cat "$T/p4b.out")"
[ ! -s "$T/c4.log" ] && ok "P4 the worker received no request" || bad "P4 requests: $(cat "$T/c4.log")"

echo "P6: no timings -> no request"
mkdir -p "$T/none"; : > "$T/none/shard-0.tsv"
JOBS_URL="http://127.0.0.1:$C4" CI_DURATIONS_TOKEN=$TOK "$CDS" post --run-id 8 --timings-dir "$T/none" > "$T/p6.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qxF 'ci-durations: post skipped, no timings' "$T/p6.out" && ok "P6 no timings: rc 0" || bad "P6 rc=$rc $(cat "$T/p6.out")"
[ ! -s "$T/c4.log" ] && ok "P6 the worker received no request" || bad "P6 requests: $(cat "$T/c4.log")"

echo "P8: a bad run id"
JOBS_URL="http://127.0.0.1:$C4" CI_DURATIONS_TOKEN=$TOK "$CDS" post --run-id 7x --timings-dir "$T/td" > "$T/p8.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "P8 rc 2" || bad "P8 rc=$rc $(cat "$T/p8.out")"
[ ! -s "$T/c4.log" ] && ok "P8 no request" || bad "P8 requests: $(cat "$T/c4.log")"

echo "P5: the worker answers 500"
printf '{"error":"boom"}' > "$T/boom.json"
srv c5 canned 500 "$T/boom.json"; C5="$PORT"
JOBS_URL="http://127.0.0.1:$C5" CI_DURATIONS_TOKEN=$TOK "$CDS" post --run-id 9 --timings-dir "$T/td" > "$T/p5.out" 2> "$T/p5.err"; rc=$?
[ "$rc" = 0 ] && ok "P5 rc 0 (fail open)" || bad "P5 rc=$rc"
grep -q '^::warning::ci-durations: post of run 9 failed (HTTP 500' "$T/p5.out" && ok "P5 one ::warning:: naming the status" || bad "P5 out: $(cat "$T/p5.out" "$T/p5.err")"
grep -q 'posted run' "$T/p5.out" && bad "P5 a 500 printed 'posted'" || ok "P5 a 500 never reads as posted"
grep -qF "$TOK" "$T/p5.out" "$T/p5.err" && bad "P5 the token leaked into the output" || ok "P5 the token is not printed"
grep -q 'auth=yes' "$T/c5.log" && ok "P5 the request carried a bearer" || bad "P5 no bearer sent: $(cat "$T/c5.log")"
# a dead port is a curl failure, not a status
stop_all
JOBS_URL="http://127.0.0.1:$C5" CI_DURATIONS_TOKEN=$TOK "$CDS" post --run-id 9 --timings-dir "$T/td" > "$T/p5b.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^::warning::ci-durations: post of run 9 failed (curl rc' "$T/p5b.out" \
  && ok "P5 a dead worker is a curl warning, rc 0" || bad "P5b rc=$rc $(cat "$T/p5b.out")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
