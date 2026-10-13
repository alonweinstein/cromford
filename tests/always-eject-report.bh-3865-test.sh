#!/bin/bash
# tests/always-eject-report.bh-3865-test.sh — BH-3865 (BH-3860.4): the REAL
# bin/always-eject-report.sh, driven through a curl stub on PATH that answers
# the worker's GET /api/dequeue-watch/events (body, then `\n<code>`, the shape
# bin/lib/jobs/req.sh reads with -w '\n%{http_code}'). Any other URL exits 7, so
# lane knobs fall back to their defaults.
#   E1  three events on one day, one on the next -> per-day counts and PRs
#   E2  worker unreachable / non-JSON -> rc 1 `unreadable`, 0 bytes on stdout
#   E3  no rows -> rc 3, the not-writing-yet message, 0 bytes on stdout
#   E4  truncated -> rows, then `# truncated`, rc 4
#   E5  always / fast set unavailable -> rc 1, no rows, no curl call
#   E6  a row past --until is dropped client-side
#   E7  bad arguments -> rc 2, no curl call; no cron/registry line names the script
# Run: HARNESS_TEST_SANDBOX=1 bash tests/always-eject-report.bh-3865-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

CLI="$DIR/bin/always-eject-report.sh"
[ -x "$CLI" ] && bash -n "$CLI" 2>/dev/null && ok || bad "missing, non-executable or unparseable $CLI"

# --- fixture --------------------------------------------------------------------
mkdir -p "$T/h/env" "$T/stubbin"
printf 'JOBS_URL=http://jobs.stub\nHARNESS_SECRET=x\nJOBS_RETRIES=0\n' > "$T/h/env/global.env"
# TEST-CHANGE BH-5292: tests/env-path-test.sh gets a 30s row. E1's
# "always-not-fast" case used it UNMEASURED, which used to mean "left out of the
# fast set"; an unmeasured suite now weighs the file's median (the shard split's
# stand-in) and would join it. A measured slow row keeps the case what it says:
# an always-suite that is not in the fast set.
printf 'tests/gh-rest-no-subshell-lint.sh\t1\tfx\ntests/config-literal-lint.sh\t2\tfx\ntests/env-path-test.sh\t30\tfx\n' > "$T/durations.tsv"
cat > "$T/stubbin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
case "$*" in
  */api/dequeue-watch/events*)
    [ -n "${STUB_EXIT:-}" ] && exit "$STUB_EXIT"
    printf '%s\n%s' "$STUB_BODY" "${STUB_CODE:-200}" ;;
  *) exit 7 ;;
esac
EOF
chmod +x "$T/stubbin/curl"
export CURL_LOG="$T/curl.log"
export HARNESS="$T/h" FAST_LINTS_DURATIONS="$T/durations.tsv" PATH="$T/stubbin:$PATH"

# The fixture premise, checked rather than assumed: the durations fixture puts
# gh-rest-no-subshell-lint in the fast set.
"$DIR/bin/fast-lints.sh" --list 2>/dev/null | grep -qx 'tests/gh-rest-no-subshell-lint.sh' && ok \
  || bad "fixture: fast-lints --list does not contain tests/gh-rest-no-subshell-lint.sh"

# row <pr> <created_at> <class> <suites>
row() { jq -nc --argjson pr "$1" --arg c "$2" --arg k "$3" --arg s "$4" \
  '{repo:"example-org/cromford", pr:$pr, head:"0123456789abcdef0123456789abcdef01234567",
    run_id:"1", created_at:$c, class:$k, suites:$s}'; }
A=$(row 101 2026-10-01T05:00:00Z rule-break 'tests/gh-rest-no-subshell-lint.sh')
B=$(row 102 2026-10-01T06:00:00Z semantic-test 'tests/x.sh tests/gh-rest-no-subshell-lint.sh')
C=$(row 103 2026-10-01T07:00:00Z semantic-test 'tests/not-an-always-suite.sh')
D=$(row 104 2026-10-02T08:00:00Z flake 'tests/gh-rest-no-subshell-lint.sh')
E=$(row 105 2026-10-03T09:00:00Z rule-break 'tests/gh-rest-no-subshell-lint.sh')
body() { jq -nc --argjson t "$1" '{rows: $ARGS.positional | map(fromjson), truncated: $t}' --args "${@:2}"; }

# run <cli> <args...> — STUB_BODY / STUB_CODE / STUB_EXIT come from the caller's env.
run() { local cli="$1"; shift; : > "$CURL_LOG"; "$cli" "$@" > "$T/out" 2> "$T/err"; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }
bytes() { wc -c < "$T/out" | tr -d ' '; }
ncurl() { grep -c . "$CURL_LOG"; }
evcurl() { grep -c '/api/dequeue-watch/events' "$CURL_LOG"; }

HDR=$'day\tdequeues\tby_always_suite\tby_fast_suite\tprs'
D1=$'2026-10-01\t3\t2\t2\t#101,#102'
D2=$'2026-10-02\t1\t0\t0\t-'

# --- E1 -------------------------------------------------------------------------
STUB_BODY=$(body false "$A" "$B" "$C" "$D") run "$CLI" --since 2026-10-01 --until 2026-10-02
[ "$(rc)" = 0 ] && ok || bad "E1 rc=$(rc) (want 0); stderr: $(cat "$T/err")"
[ "$(cat "$T/out")" = "$HDR"$'\n'"$D1"$'\n'"$D2" ] && ok || bad "E1 stdout: $(cat "$T/out")"
grep -q 'since=2026-10-01T00%3A00%3A00Z' "$CURL_LOG" && ok || bad "E1 since not sent as a timestamp: $(cat "$CURL_LOG")"
grep -q 'repo=example-org%2Fcromford' "$CURL_LOG" && ok || bad "E1 repo not sent: $(cat "$CURL_LOG")"
grep -q 'http://jobs.stub/api/dequeue-watch/events' "$CURL_LOG" && ok || bad "E1 JOBS_URL from \$HARNESS/env not used: $(cat "$CURL_LOG")"

# suites written as a JSON array or comma list tokenize the same way.
B2=$(row 102 2026-10-01T06:00:00Z semantic-test '["tests/x.sh","tests/gh-rest-no-subshell-lint.sh"]')
A2=$(row 101 2026-10-01T05:00:00Z rule-break 'tests/x.sh,tests/gh-rest-no-subshell-lint.sh')
STUB_BODY=$(body false "$A2" "$B2" "$C" "$D") run "$CLI" --since 2026-10-01 --until 2026-10-02
[ "$(rc)" = 0 ] && [ "$(cat "$T/out")" = "$HDR"$'\n'"$D1"$'\n'"$D2" ] && ok \
  || bad "E1 json/comma suites rc=$(rc) stdout: $(cat "$T/out")"

# by_fast differs from by_always: an always-suite that is not in the fast set.
F=$(row 106 2026-10-01T05:00:00Z rule-break 'tests/env-path-test.sh')
STUB_BODY=$(body false "$F") run "$CLI" --since 2026-10-01 --until 2026-10-01
[ "$(sed -n 2p "$T/out")" = $'2026-10-01\t1\t1\t0\t#106' ] && ok || bad "E1 always-not-fast row: $(cat "$T/out")"

# --- E2 -------------------------------------------------------------------------
STUB_EXIT=7 STUB_BODY='' run "$CLI" --since 2026-10-01 --until 2026-10-02
[ "$(rc)" = 1 ] && ok || bad "E2a rc=$(rc) (want 1)"
grep -q 'always-eject-report: dequeue-watch rows unreadable' "$T/err" && ok || bad "E2a stderr: $(cat "$T/err")"
[ "$(bytes)" = 0 ] && ok || bad "E2a stdout not empty: $(cat "$T/out")"

STUB_BODY='not json' run "$CLI" --since 2026-10-01 --until 2026-10-02
[ "$(rc)" = 1 ] && ok || bad "E2b rc=$(rc) (want 1)"
grep -q 'always-eject-report: dequeue-watch rows unreadable' "$T/err" && ok || bad "E2b stderr: $(cat "$T/err")"
[ "$(bytes)" = 0 ] && ok || bad "E2b stdout not empty: $(cat "$T/out")"

STUB_BODY='{"error":"boom"}' STUB_CODE=500 run "$CLI" --since 2026-10-01 --until 2026-10-02
[ "$(rc)" = 1 ] && [ "$(bytes)" = 0 ] && ok || bad "E2c 500 rc=$(rc) stdout: $(cat "$T/out")"

# --- E3 -------------------------------------------------------------------------
STUB_BODY='{"rows":[],"truncated":false}' run "$CLI" --since 2026-10-01 --until 2026-10-02
[ "$(rc)" = 3 ] && ok || bad "E3 rc=$(rc) (want 3)"
grep -q 'no dequeue-watch rows in 2026-10-01..2026-10-02' "$T/err" && grep -q 'PR #3833' "$T/err" && ok \
  || bad "E3 stderr: $(cat "$T/err")"
[ "$(bytes)" = 0 ] && ok || bad "E3 stdout not empty: $(cat "$T/out")"

# --- E4 -------------------------------------------------------------------------
STUB_BODY=$(body true "$A" "$B" "$C" "$D") run "$CLI" --since 2026-10-01 --until 2026-10-02
[ "$(rc)" = 4 ] && ok || bad "E4 rc=$(rc) (want 4)"
[ "$(tail -n 1 "$T/out")" = '# truncated' ] && ok || bad "E4 last line: $(tail -n 1 "$T/out")"
grep -qxF "$D1" "$T/out" && grep -qxF "$D2" "$T/out" && ok || bad "E4 day rows missing: $(cat "$T/out")"
# capped and empty after the until filter is still rc 4, never "none".
STUB_BODY=$(body true "$E") run "$CLI" --since 2026-10-01 --until 2026-10-02
[ "$(rc)" = 4 ] && [ "$(tail -n 1 "$T/out")" = '# truncated' ] && ok || bad "E4 capped-empty rc=$(rc) out: $(cat "$T/out")"

# --- E5 -------------------------------------------------------------------------
# A scratch copy of the CLI beside the real jobs client and lib, with the two
# set sources stubbed: one of them fails, the other answers.
for which in test-impact fast-lints; do
  S="$T/s-$which"; mkdir -p "$S"
  cp "$CLI" "$DIR/bin/jobs-client.sh" "$S/"
  cp -r "$DIR/bin/lib" "$S/lib"
  printf '#!/bin/bash\necho tests/gh-rest-no-subshell-lint.sh\n' > "$S/test-impact.sh"
  printf '#!/bin/bash\necho tests/gh-rest-no-subshell-lint.sh\n' > "$S/fast-lints.sh"
  printf '#!/bin/bash\nexit 2\n' > "$S/$which.sh"
  chmod +x "$S/test-impact.sh" "$S/fast-lints.sh"
  STUB_BODY=$(body false "$A") run "$S/always-eject-report.sh" --since 2026-10-01 --until 2026-10-02
  [ "$(rc)" = 1 ] && ok || bad "E5 $which rc=$(rc) (want 1)"
  case "$which" in test-impact) msg='always-suite set unavailable' ;; *) msg='fast-lint set unavailable' ;; esac
  grep -q "always-eject-report: $msg" "$T/err" && ok || bad "E5 $which stderr: $(cat "$T/err")"
  [ "$(bytes)" = 0 ] && ok || bad "E5 $which stdout not empty: $(cat "$T/out")"
  [ "$(evcurl)" = 0 ] && ok || bad "E5 $which made an events request"
done
# The same scratch copy with both sources answering does read rows: the copy is sound.
printf '#!/bin/bash\necho tests/gh-rest-no-subshell-lint.sh\n' > "$S/fast-lints.sh"
STUB_BODY=$(body false "$A") run "$S/always-eject-report.sh" --since 2026-10-01 --until 2026-10-01
[ "$(rc)" = 0 ] && [ "$(sed -n 2p "$T/out")" = $'2026-10-01\t1\t1\t1\t#101' ] && ok \
  || bad "E5 control copy rc=$(rc) out: $(cat "$T/out") err: $(cat "$T/err")"
# --- E6 -------------------------------------------------------------------------
STUB_BODY=$(body false "$A" "$B" "$C" "$D" "$E") run "$CLI" --since 2026-10-01 --until 2026-10-02
[ "$(rc)" = 0 ] && [ "$(cat "$T/out")" = "$HDR"$'\n'"$D1"$'\n'"$D2" ] && ok \
  || bad "E6 row past --until not dropped: rc=$(rc) $(cat "$T/out")"

# --- E7 -------------------------------------------------------------------------
for args in "--since 2026-13-01" "--since x" "--bogus" "--since 2026-10-03 --until 2026-10-02" "--since" "--until 2026-02-30"; do
  # shellcheck disable=SC2086
  STUB_BODY=$(body false "$A") run "$CLI" $args
  [ "$(rc)" = 2 ] && ok || bad "E7 '$args' rc=$(rc) (want 2)"
  [ "$(ncurl)" = 0 ] && ok || bad "E7 '$args' made a curl call"
  [ "$(bytes)" = 0 ] && ok || bad "E7 '$args' stdout not empty"
done
run "$CLI" -h
[ "$(rc)" = 0 ] && grep -q 'usage: always-eject-report.sh' "$T/out" "$T/err" && ok || bad "E7 -h rc=$(rc)"

# E7b: no cron line, no lane registry entry.
if grep -rln 'always-eject-report' "$DIR/cron" "$DIR/catalog/lanes.d" 2>/dev/null; then bad "E7b a cron/registry file names the script"; else ok; fi

echo "always-eject-report.bh-3865: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
