#!/bin/bash
# tests/client-court-gate-test.sh — client-court gate: tickets waiting on the
# client, not ready, or with a harness/system newest comment must never be
# dispatched, commented on, or claimed as a build.
#
# Drives bin/triage-gate.sh --buildable and bin/board-closeout.sh with stubbed
# curl/gh and a scratch HARNESS tree. All external calls are reads; failures
# are fail-open OK per the gate contract.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1

DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/bin/lib" "$T/env" "$T/state" "$T/logs" "$T/flags" "$T/prompts"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The scripts under test, run against the scratch harness.
cp "$DIR/bin/triage-gate.sh" "$T/bin/triage-gate.sh"
# BH-1955: the generic arm resolves its token through these two libs.
mkdir -p "$T/bin/lib" && cp "$DIR/bin/lib/board-creds.sh" "$DIR/bin/lib/internal-token.sh" "$T/bin/lib/"
cp "$DIR/bin/board-fetch.sh" "$T/bin/board-fetch.sh"
cp "$DIR/bin/board-closeout.sh" "$T/bin/board-closeout.sh"

# Minimal fleet.conf: x-os is an in-app product board.
cat > "$T/bin/fleet-conf.sh" <<'EOC'
#!/bin/bash
case "${1:-}" in
  x-os)
    case "${2:-}" in
      prod) echo "https://board.example" ;;
      board_prefix|*) echo "/api/board" ;;
    esac ;;
  *) echo "" ;;
esac
EOC
chmod +x "$T/bin/fleet-conf.sh"

# Board credentials discovered by suffix (generic in-app arm in triage-gate.sh).
cat > "$T/env/x-os.env" <<'EOC'
XOS_API_BASE=https://board.example
XOS_INTERNAL_API_TOKEN=tok
EOC

# Stub curl: honours -o <file> and -w <format> so board-fetch.sh can read
# status and body separately, then returns fixtures by ticket id in the URL.
cat > "$T/bin/curl" <<'EOC'
#!/bin/bash
OUT=""; FMT=""; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift; OUT="${1:-}" ;;
    -w) shift; FMT="${1:-}" ;;
    -*) : ;;
    *) URL="$1" ;;
  esac
  shift || true
done
BODY=""; HTTP="200"
case "$URL" in
  */tickets/tk-client)
    BODY='{"id":"tk-client","key":"TK-216","status":"open","waitingOn":"client","triageVerdict":"ready","commentCount":1,"lastActivityAt":"2026-09-16T01:00:00Z","title":"discount toggle","comments":[{"id":"c1","createdAt":"2026-09-16T01:00:00Z","author":{"userId":"Harness","name":"Harness"},"isInternal":true,"body":"how is the fee set?"}]}'
    ;;
  */tickets/tk-waiting)
    BODY='{"id":"tk-waiting","key":"TK-219","status":"open","waitingOn":"client","triageVerdict":"ready","commentCount":1,"lastActivityAt":"2026-09-16T01:00:00Z","title":"waiting on client only","comments":[{"id":"c1","createdAt":"2026-09-16T01:00:00Z","author":{"userId":"client-1","name":"Client User"},"isInternal":false,"body":"what?"}]}'
    ;;
  */tickets/tk-system)
    BODY='{"id":"tk-system","key":"TK-220","status":"open","waitingOn":"team","triageVerdict":"ready","commentCount":1,"lastActivityAt":"2026-09-16T01:00:00Z","title":"system comment only","comments":[{"id":"c1","createdAt":"2026-09-16T01:00:00Z","author":{"userId":"Harness","name":"Harness"},"isInternal":true,"body":"checking in"}]}'
    ;;
  */tickets/tk-harness-public)
    BODY='{"id":"tk-harness-public","key":"TK-222","status":"open","waitingOn":"team","triageVerdict":"ready","commentCount":1,"lastActivityAt":"2026-09-16T01:00:00Z","title":"harness public comment","comments":[{"id":"c1","createdAt":"2026-09-16T01:00:00Z","author":{"userId":"Harness","name":"Harness"},"body":"public harness note"}]}'
    ;;
  */tickets/tk-ready)
    BODY='{"id":"tk-ready","key":"TK-217","status":"open","waitingOn":"team","triageVerdict":"ready","commentCount":1,"lastActivityAt":"2026-09-16T01:00:00Z","title":"ok","comments":[{"id":"c1","createdAt":"2026-09-16T01:00:00Z","author":{"userId":"client-1","name":"Client User"},"isInternal":false,"body":"yes please"}]}'
    ;;
  */tickets/tk-needs-clarify)
    BODY='{"id":"tk-needs-clarify","key":"TK-218","status":"open","waitingOn":"team","triageVerdict":"needs_clarification","commentCount":0,"lastActivityAt":"2026-09-16T01:00:00Z","title":"clarify me"}'
    ;;
  */tickets/tk-clean)
    BODY='{"id":"tk-clean","key":"TK-221","status":"open","triageVerdict":"ready","commentCount":0,"lastActivityAt":"2026-09-16T01:00:00Z","title":"clean"}'
    ;;
  */tickets/tk-fetch-fails)
    HTTP="503"
    BODY="BOARD-FETCH FAILED: HTTP 503 for $URL — this is NOT a ticket."
    ;;
  */boards/*/tickets)
    BODY='[]'
    ;;
  */boards)
    BODY='[{"id":"b1"}]'
    ;;
  */tickets/*/comments)
    HTTP="201"
    BODY='{"comment":{"id":"c-new"}}'
    ;;
  */tickets/*/move)
    BODY='{"status":"done"}'
    ;;
  *)
    HTTP="000"
    BODY="BOARD-FETCH FAILED: HTTP 000 for $URL"
    ;;
esac
if [ -n "$OUT" ]; then
  printf '%s' "$BODY" > "$OUT"
else
  printf '%s' "$BODY"
fi
printf '%s' "$FMT" | sed "s/%{http_code}/$HTTP/g"
EOC
chmod +x "$T/bin/curl"

# board-closeout.sh calls gh only on GitHub-Issues boards; x-os is in-app, so
# this should never run. Provide a loud fail-if-called stub.
cat > "$T/bin/gh" <<'EOC'
#!/bin/bash
echo "gh-called-unexpectedly" >&2
exit 99
EOC
chmod +x "$T/bin/gh"

# Builder-direct guard: board-closeout.sh sources this and checks if direct
# close-out is enabled. We enable it so the guard can refuse to post.
cat > "$T/bin/lib/builder-direct.sh" <<'EOC'
#!/bin/bash
builder_direct_on() { echo 1; }
bd_closed_out() { return 1; }
EOC
chmod +x "$T/bin/lib/builder-direct.sh"

# internal-token-for.sh used by board-closeout.sh on in-app boards.
cat > "$T/bin/internal-token-for.sh" <<'EOC'
#!/bin/bash
echo "tok"
EOC
chmod +x "$T/bin/internal-token-for.sh"

export HARNESS="$T"
# Put scratch bin first so stubs win.
export PATH="$T/bin:$PATH"

# Fixture 1: waitingOn=client + newest comment from Harness -> BLOCKED.
OUT=$(bash "$T/bin/triage-gate.sh" x-os --buildable tk-client 2>&1)
case "$OUT" in
  *BLOCKED*) ok ;;
  *) bad "fixture 1 expected BLOCKED, got: $OUT" ;;
esac

# Fixture 1a: waitingOn=client alone (newest comment from client) -> BLOCKED.
OUT=$(bash "$T/bin/triage-gate.sh" x-os --buildable tk-waiting 2>&1)
case "$OUT" in
  *BLOCKED*) ok ;;
  *) bad "fixture 1a expected BLOCKED waitingOn=client, got: $OUT" ;;
esac

# Fixture 1b: system/harness newest comment alone -> BLOCKED.
OUT=$(bash "$T/bin/triage-gate.sh" x-os --buildable tk-system 2>&1)
case "$OUT" in
  *BLOCKED*) ok ;;
  *) bad "fixture 1b expected BLOCKED newest-comment-system, got: $OUT" ;;
esac
# Fixture 1c: generic in-app board recognises Harness by name even without isInternal.
OUT=$(bash "$T/bin/triage-gate.sh" x-os --buildable tk-harness-public 2>&1)
case "$OUT" in
  *BLOCKED*) ok ;;
  *) bad "fixture 1c expected BLOCKED newest-comment-system on generic-board Harness, got: $OUT" ;;
esac

# Fixture 2: ready + team + client comment -> OK.
OUT=$(bash "$T/bin/triage-gate.sh" x-os --buildable tk-ready 2>&1)
[ "$OUT" = "OK" ] && ok || bad "fixture 2 expected OK, got: $OUT"

# Fixture 3: triageVerdict=needs_clarification -> BLOCKED.
OUT=$(bash "$T/bin/triage-gate.sh" x-os --buildable tk-needs-clarify 2>&1)
case "$OUT" in
  *BLOCKED*) ok ;;
  *) bad "fixture 3 expected BLOCKED, got: $OUT" ;;
esac

# Fixture 4: board-closeout.sh on a client-court ticket must refuse to POST.
BUILD="$T/builds/x-os-TK-216-202609160100"
mkdir -p "$BUILD"
printf 'PR_CREATED https://github.com/example-org/x-os/pull/42\n' > "$BUILD/RESULT"
printf 'something\n' > "$BUILD/what.txt"
printf '## QA screens\nNo screens.\n' > "$BUILD/plan.md"
touch "$BUILD/qa.md"
bash "$T/bin/board-closeout.sh" x-os tk-client TK-216 "$BUILD" >/dev/null 2>"$T/logs/closeout-err.txt"
RC=$?
[ "$RC" -eq 4 ] && ok || bad "fixture 4 expected board-closeout rc=4, got rc=$RC"
case "$(cat "$T/logs/closeout-err.txt" 2>/dev/null)" in
  *client-court*) ok ;;
  *) bad "fixture 4 expected 'client-court' stderr line, got: $(cat "$T/logs/closeout-err.txt" 2>/dev/null)" ;;
esac

# Negative: fetch failure is fail-open OK.
OUT=$(bash "$T/bin/triage-gate.sh" x-os --buildable tk-fetch-fails 2>&1)
[ "$OUT" = "OK" ] && ok || bad "fetch-fail expected OK, got: $OUT"

# GitHub-Issues board has no waitingOn/triageVerdict, gate always OK.
bash "$T/bin/triage-gate.sh" ghproj --buildable 123 >/dev/null 2>&1 && ok \
  || bad "GitHub-Issues board should be fail-open OK"

# Negative: no waitingOn, ready verdict, no comments -> OK.
OUT=$(bash "$T/bin/triage-gate.sh" x-os --buildable tk-clean 2>&1)
[ "$OUT" = "OK" ] && ok || bad "clean ticket (no waitingOn, ready, no comments) expected OK, got: $OUT"

# Fixture 5: the shard-dispatch guard (bin/lib/rt/shards.sh) drops client-court units.
# The guard block is extracted verbatim by the >>> / <<< markers so the test
# exercises exactly the code production uses.
mkdir -p "$T/rt-guard/bin" "$T/rt-guard/state" "$T/rt-guard/logs"
cp "$DIR/bin/lib/rt/shards.sh" "$T/rt-guard/shards.sh"
cat > "$T/rt-guard/bin/triage-gate.sh" <<'EOC'
#!/bin/bash
TID="${3:-}"
case "$TID" in
  tk-client|tk-needs-clarify) echo "BLOCKED $TID" ;;
  *) echo "OK" ;;
esac
EOC
chmod +x "$T/rt-guard/bin/triage-gate.sh"
printf '{"TK-218":"tk-needs-clarify","tk-needs-clarify":"TK-218"}\n' > "$T/rt-guard/state/x-os.keymap.json"
SHARD_U="$T/rt-guard/state/shard.units"
printf 'tk-client\tboard\tboard b1: CHANGED tk-client "discount toggle"\ntk-ready\tboard\tboard b1: CHANGED tk-ready "ok"\nPB-218\tqueue\tPB-218 (target main, attempt 0, queued 2026-09-16T00:00:00Z)\n' > "$SHARD_U"
SHARD_ON=1 HARNESS="$T/rt-guard" PROJECT="x-os" LOG="$T/rt-guard/logs/run-triage.log" SHARD_UNITS="$SHARD_U" PATH="$T/rt-guard/bin:$PATH" bash -c '
  sed -n "/# >>> client-court guard/,/# <<< client-court guard/p" "$HARNESS/shards.sh" | sed "1d;$d" > "$HARNESS/guard.sh"
  . "$HARNESS/guard.sh"
  printf "SHARD_ON=%s\n" "$SHARD_ON"
  cat "$SHARD_UNITS" 2>/dev/null || true
' > "$T/rt-guard/out.txt"
grep -q 'SHARD_ON=1' "$T/rt-guard/out.txt" && ok || bad "run-triage guard should leave SHARD_ON=1"
grep -q $'^tk-ready\t' "$T/rt-guard/out.txt" && ok || bad "run-triage guard should keep the buildable tk-ready unit"
! grep -qE $'^tk-client\t|^TK-218\t' "$T/rt-guard/out.txt" && ok || bad "run-triage guard should drop client-court tk-client and TK-218 units"
grep -q 'client-court skipped' "$T/rt-guard/logs/run-triage.log" && ok || bad "run-triage guard should log the skipped keys"

# Fixture 6: fly-dispatch.sh refuses to claim a client-court queued job.
mkdir -p "$T/fly-guard/bin" "$T/fly-guard/state/build-queue/x-os"
cp "$DIR/bin/fly-dispatch.sh" "$T/fly-guard/bin/fly-dispatch.sh"
cat > "$T/fly-guard/bin/triage-gate.sh" <<'EOC'
#!/bin/bash
TID="${3:-}"
[ "$TID" = "tk-client" ] && echo "BLOCKED waitingOn=client" || echo "OK"
EOC
chmod +x "$T/fly-guard/bin/triage-gate.sh"
printf '{"ticket_id":"tk-client","key":"TK-216","attempt":0}\n' > "$T/fly-guard/state/build-queue/x-os/TK-216.json"
SAY_LOG="$T/fly-guard/say.log"
HARNESS="$T/fly-guard" BIN="$T/fly-guard/bin" PATH="$T/fly-guard/bin:$PATH" p="x-os" key="TK-216" next_job="$T/fly-guard/state/build-queue/x-os/TK-216.json" active="$T/fly-guard/state/x-os-active.json" qdir="$T/fly-guard/state/build-queue/x-os" SAY_LOG="$SAY_LOG" bash -c '
  say() { echo "$*" >> "$SAY_LOG"; }
  sed -n "/# >>> client-court guard/,/# <<< client-court guard/p" "$BIN/fly-dispatch.sh" | sed "1d;$d" > "$BIN/fly-guard-block.sh"
  _run_guard() { . "$BIN/fly-guard-block.sh"; }
  _run_guard
  echo "rc=$?"
  [ -f "$active" ] && echo "active-exists" || echo "active-missing"
' > "$T/fly-guard/out.txt"
grep -q 'rc=0' "$T/fly-guard/out.txt" && ok || bad "fly-dispatch guard should return 0"
grep -q 'active-missing' "$T/fly-guard/out.txt" && ok || bad "fly-dispatch guard should not create active file"
grep -q 'client-court, leaving TK-216 queued' "$SAY_LOG" && ok || bad "fly-dispatch guard should log the blocked key"

# Fixture 7: orphan-reconcile.sh is a no-op for in-app product boards.
mkdir -p "$T/orphan-guard/bin" "$T/orphan-guard/logs" "$T/orphan-guard/locks"
cp "$DIR/bin/orphan-reconcile.sh" "$T/orphan-guard/bin/orphan-reconcile.sh"
cat > "$T/orphan-guard/bin/fleet-conf.sh" <<'EOC'
#!/bin/bash
[ "$1" = "x-os" ] && [ "$2" = "board_prefix" ] && echo "/api/board"
EOC
chmod +x "$T/orphan-guard/bin/fleet-conf.sh"
HARNESS="$T/orphan-guard" PATH="$T/orphan-guard/bin:$PATH" bash "$T/orphan-guard/bin/orphan-reconcile.sh" x-os --explain >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok || bad "orphan-reconcile.sh should no-op for in-app board (rc=$RC)"

echo "client-court-gate-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
