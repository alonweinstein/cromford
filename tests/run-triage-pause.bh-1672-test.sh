#!/bin/bash
# tests/run-triage-pause.bh-1672-test.sh — BH-1684 (BH-1672.3): the triage lane
# honours the `pauses` rows bin/lib/pause.sh reads.
#
#   T  a live `triage` row for the project: the tick exits 0 with one
#      PAUSED(triage) line, buys no agent session and claims no job.
#   B  a live `builds` row: triage still runs, the agent is called once, its
#      prompt carries the BUILDS PAUSED directive, and the log has exactly one
#      PAUSED(builds) line. That directive is the whole enforcement: every
#      run-build launch on this path is made by the agent, so what can be proven
#      here is that the agent was TOLD, not that it obeyed.
#   E  an expired triage row, O another project's row, and the negatives (an
#      ended row, a garbage expires_at, no cache at all): a normal tick, with no
#      PAUSED( line and no directive.
#
# Drives the REAL bin/run-triage.sh with its roots rewritten (the scratch tree of
# tests/run-triage-inapp-release.bh-901-test.sh), the REAL bin/lib/pause.sh and
# bin/lib/pause-rows.sh, and the REAL bin/jobs-client.sh over a curl stub, so
# "no job claim" is a request that did not happen rather than a client that was
# never loaded. pause_refresh is overridden in the scratch copy so the suite
# keeps reading its hand-written cache once the real refresh lands (#1683).
# Shards are disarmed (TRIAGE_SHARDS=0): the directive is appended before
# SHARD_SOP is taken, but no shard is dispatched here.
# No network, no model. Exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "run-triage-pause.bh-1672: jq missing, cannot run"; exit 1; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mkdir -p "$H/bin/lib/rt" "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/calls" "$T/repos" "$T/fakebin"
: > "$H/env/global.env"
echo "SOP for x-os. Fetch the thread. Do the work." > "$H/prompts/x-os.md"
cat > "$T/fleet.conf" <<'EOC'
x-os   example-org/x-os    https://board.example  /api/board  2 box-1 10.0.0.1
y-os   example-org/y-os    https://board.example  /api/board  2 box-1 10.0.0.1
EOC
export FLEET_CONF="$T/fleet.conf"

sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/run-triage.sh" > "$H/bin/run-triage.sh"
chmod +x "$H/bin/run-triage.sh"
for s in "$DIR"/bin/lib/rt/*.sh; do
  [ -r "$s" ] || continue
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"
done
for s in fleet-conf.sh project-of.sh decision-log.sh; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
cp "$DIR/bin/lib/triage-shards-lib.sh" "$H/bin/lib/triage-shards-lib.sh"
cp "$DIR/bin/jobs-client.sh" "$H/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/pause.sh" "$DIR/bin/lib/pause-rows.sh" "$H/bin/lib/"
echo "pause_refresh(){ echo x >> \"$T/refresh.calls\"; return 0; }" >> "$H/bin/lib/pause.sh"
printf '#!/bin/sh\necho box-1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"

# --- stubs -------------------------------------------------------------------
cat > "$H/bin/triage-gate.sh" <<STUB
#!/bin/bash
PRJ="\$1"; MODE="\${2:-}"
cp "$H/fixture/pending.json" "$H/state/\$PRJ.gate.pending" 2>/dev/null
[ "\$MODE" = "--pending" ] && exit 0
[ "\$MODE" = "--buildable" ] && { echo OK; exit 0; }
echo "RUN board-changed"
exit 0
STUB
chmod +x "$H/bin/triage-gate.sh"
sed -e "s|/root/harness|$H|g" "$DIR/bin/gate-diff.sh" > "$H/bin/gate-diff.sh"; chmod +x "$H/bin/gate-diff.sh"
for s in unblocked-children.sh decompose-parent-close.sh beat.sh lane-alert.sh; do
  printf '#!/bin/sh\nexit 0\n' > "$H/bin/$s"; chmod +x "$H/bin/$s"
done
printf '#!/bin/sh\necho "$*" >> "%s/hotfix-seen.calls"\nexit 0\n' "$T" > "$H/bin/hotfix-seen.sh"; chmod +x "$H/bin/hotfix-seen.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"; chmod +x "$H/bin/triage-contract.sh"
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
D="${CALLDIR:?}"
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
F=$(mktemp "$D/prompt-XXXXXXXX.txt")
printf '%s' "$PR" > "$F"
echo "tickets=1 done" > "$5"
exit 0
STUB
chmod +x "$H/bin/agent-call.sh"
# The worker: every request is recorded; the job claim answers 201 so the
# normal tick really does claim (the positive control for T's "no claim").
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; METHOD=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) METHOD="\$2"; shift 2;; *) shift;; esac; done
printf '%s %s\n' "\$METHOD" "\$URL" >> "$T/curl.log"
case "\$URL" in
  */api/jobs) printf '{"job":{"id":"triage-x-os-1","budget_usd":1}}\n201\n' ;;
  # TEST-CHANGE BH-4153: paused-<project> is a harness_flags row read DB-first,
  # and a {} 200 is an unreadable row: with nothing cached that is UNKNOWN,
  # which a stop switch reads as ON (fails closed) and would pause every case.
  # This suite pins the pauses ROWS, not the flag, so the flag has no row.
  */api/flags/*) printf '{"error":"not found"}\n404\n' ;;
  *)          printf '{}\n200\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

FP_OLD='{"b1":[{"id":"t1","status":"todo","waitingOn":"team","triageVerdict":"ready","commentCount":1,"lastActivityAt":"2026-09-18T05:00:00Z","title":"a ticket"}]}'
FP_NEW='{"b1":[{"id":"t1","status":"todo","waitingOn":"team","triageVerdict":"ready","commentCount":2,"lastActivityAt":"2026-09-18T06:00:00Z","title":"a ticket, answered"}]}'

# 2026-09-24T12:00:00Z. Rows are created 2d 3h before it and expire 21h after.
NOW=1790251200
CREATED="2026-09-22T09:00:00Z"
FUTURE="2026-09-25T09:00:00Z"
PAST="2026-09-24T11:59:00Z"
row() { # row <scope> <what> <expires_at> [ended_at]
  jq -cn --arg s "$1" --arg w "$2" --arg e "$3" --arg c "$CREATED" --arg x "${4:-}" \
    '{id:("p-"+$s+"-"+$w), scope:$s, what:$w, reason:"runaway fix", actor:"operator",
      created_at:$c, expires_at:$e,
      ended_at:(if $x == "" then null else $x end),
      end_reason:(if $x == "" then null else "resumed" end)}'
}
cache() { jq -cn --argjson r "[$(IFS=,; echo "$*")]" '{pauses:$r, truncated:false}' > "$H/state/pauses.json"; }

reset() {
  rm -rf "$T/calls" "$H/state" "$H/locks" "$H/logs" "$H/builds"
  mkdir -p "$T/calls" "$H/state" "$H/locks" "$H/logs" "$H/builds"
  model_routes_fixture "$H" x-os y-os || exit 1
  rm -f "$T/curl.log" "$T/refresh.calls" "$T/hotfix-seen.calls"
  printf '%s' "$FP_OLD" > "$H/state/x-os.gate.json"
  printf '%s' "$FP_NEW" > "$H/fixture/pending.json"
  : > "$H/logs/READY-QUEUE.log"
  return 0
}
run() {
  RC=0
  PATH="$T/fakebin:$PATH" CALLDIR="$T/calls" TRIAGE_SHARDS=0 PAUSE_NOW="$NOW" \
    HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
    "$H/bin/run-triage.sh" x-os >/dev/null 2>&1 || RC=$?
}
ncalls()  { ls "$T/calls"/prompt-*.txt 2>/dev/null | grep -c . || true; }
prompt()  { cat "$(ls "$T/calls"/prompt-*.txt 2>/dev/null | head -1)" 2>/dev/null; }
claims()  { grep -c 'POST .*/api/jobs$' "$T/curl.log" 2>/dev/null || true; }
npaused() { grep -c "PAUSED($1)" "$H/logs/x-os.log" 2>/dev/null || true; }
LOGF="$H/logs/x-os.log"

# normal() <case>: the tick behaved exactly as an unpaused one.
normal() {
  [ "$RC" = 0 ] && ok || bad "$1 rc must be 0, got $RC"
  [ "$(ncalls)" = 1 ] && ok || bad "$1 the agent must be called once, got $(ncalls)"
  [ "$(claims)" = 1 ] && ok || bad "$1 the tick must claim its job once, got $(claims)"
  grep -q 'BUILDS PAUSED' <<<"$(prompt)" && bad "$1 no builds directive expected in the prompt" || ok
  grep -q 'PAUSED(' "$LOGF" 2>/dev/null && bad "$1 no PAUSED( line expected: $(grep 'PAUSED(' "$LOGF")" || ok
}

# ---------- T. a triage row: the tick skips before anything is bought -------
reset; cache "$(row x-os triage "$FUTURE")"
run
[ "$RC" = 0 ] && ok || bad "T rc must be 0 (a pause is a clean skip), got $RC"
[ "$(npaused triage)" = 1 ] && ok || bad "T exactly one PAUSED(triage) line expected, got $(npaused triage): $(cat "$LOGF" 2>/dev/null)"
grep -q 'PAUSED(triage) reason=runaway fix age=2d 3h' "$LOGF" 2>/dev/null && ok \
  || bad "T the line must carry the row's reason and age: $(grep 'PAUSED' "$LOGF" 2>/dev/null)"
[ "$(ncalls)" = 0 ] && ok || bad "T the agent must not be called, got $(ncalls) call(s)"
[ "$(claims)" = 0 ] && ok || bad "T no job may be claimed: $(cat "$T/curl.log" 2>/dev/null)"
[ -s "$T/refresh.calls" ] && ok || bad "T pause_refresh must run before the decision"
[ "$(cat "$T/hotfix-seen.calls" 2>/dev/null)" = "x-os --paused" ] && ok \
  || bad "T the held hotfix must be made visible like the flag pause: $(cat "$T/hotfix-seen.calls" 2>/dev/null)"

# A fleet-scoped triage row pauses this project too.
reset; cache "$(row fleet triage "$FUTURE")"
run
[ "$RC" = 0 ] && [ "$(ncalls)" = 0 ] && [ "$(npaused triage)" = 1 ] && ok \
  || bad "T a fleet triage row must pause x-os (rc=$RC calls=$(ncalls) lines=$(npaused triage))"

# ---------- B. a builds row: triage runs, the agent is told not to launch ---
reset; cache "$(row x-os builds "$FUTURE")"
run
[ "$RC" = 0 ] && ok || bad "B rc must be 0, got $RC"
[ "$(ncalls)" = 1 ] && ok || bad "B triage must still run: one agent call expected, got $(ncalls)"
[ "$(claims)" = 1 ] && ok || bad "B the tick still claims its job, got $(claims)"
grep -q 'BUILDS PAUSED' <<<"$(prompt)" && ok || bad "B the prompt must carry the BUILDS PAUSED directive"
grep -q 'launch NO run-build.sh' <<<"$(prompt)" && ok || bad "B the directive must forbid run-build launches: $(prompt | grep 'BUILDS PAUSED')"
[ "$(npaused builds)" = 1 ] && ok || bad "B exactly one PAUSED(builds) line expected, got $(npaused builds)"
grep -q 'PAUSED(builds) reason=runaway fix age=2d 3h' "$LOGF" 2>/dev/null && ok \
  || bad "B the line must carry the row's reason and age: $(grep 'PAUSED' "$LOGF" 2>/dev/null)"
# D13: the directive is the enforcement, so neither label may claim more.
grep -q 'PAUSED(builds).*withheld by prompt directive (not enforced at run-build.sh)' "$LOGF" 2>/dev/null && ok \
  || bad "B the log line must say the launches are withheld by prompt directive, not enforced: $(grep 'PAUSED(builds)' "$LOGF" 2>/dev/null)"
grep -qi 'deterministic' <<<"$(prompt | grep 'BUILDS PAUSED')" && bad "B the directive must not call itself deterministic" || ok
[ "$(npaused triage)" = 0 ] && ok || bad "B a builds row must not read as a triage pause"
grep -q 'rc=0 ::' "$LOGF" 2>/dev/null && ok || bad "B the tick must run to its summary line"

# ---------- E. an expired triage row: normal -------------------------------
reset; cache "$(row x-os triage "$PAST")"
run; normal E
# An expired builds row: no directive.
reset; cache "$(row x-os builds "$PAST")"
run; normal E-builds

# ---------- O. another project's rows: normal -------------------------------
reset; cache "$(row y-os triage "$FUTURE")" "$(row y-os builds "$FUTURE")"
run; normal O

# ---------- negatives -------------------------------------------------------
reset; cache "$(row x-os triage "$FUTURE" "2026-09-24T10:00:00Z")" "$(row x-os builds "$FUTURE" "2026-09-24T10:00:00Z")"
run; normal N-ended
reset; cache "$(row x-os triage "not-a-date")" "$(row x-os builds "tomorrow")"
run; normal N-garbage
reset; cache "$(row x-os reviews "$FUTURE")" "$(row x-os merges "$FUTURE")"
run; normal N-other-what
reset; echo '{"pauses":[]}' > "$H/state/pauses.json"
run; normal N-empty
reset; echo 'not json {' > "$H/state/pauses.json"
run; normal N-garbage-json
reset
run; normal N-no-cache
[ -s "$T/refresh.calls" ] && ok || bad "N-no-cache pause_refresh must still run once per tick"

echo "run-triage-pause.bh-1672: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
