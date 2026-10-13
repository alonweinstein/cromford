#!/bin/bash
# tests/blocked-resolver-done-ticket.bh-4438-test.sh — BH-4438. blocked-resolver
# rebuilt project-3 TK-231 after the ticket was already done on the board: the only
# ticket read in front of a rebuild (br_hold_gate) is a no-op on a product-board
# project, so a board ticket's status was never read before the enqueue.
#
# Section U extracts br_board_status and drives it against a stubbed board.
# Section E runs the REAL bin/blocked-resolver.sh end to end in a scratch harness
# (the bh-1007 Section B scaffolding): a done ticket gets no rebuild, no PR close
# and one terminal note; an open ticket is enqueued exactly as before; a board
# that cannot be read holds the park (no rebuild, no rung spent).
# Run from anywhere: tests/blocked-resolver-done-ticket.bh-4438-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "blocked-resolver-done-ticket.bh-4438-test: SKIPPED — jq is required"; exit 0; }
ORIG_PATH="$PATH"

# cnt <pattern> <file> — a match count that is always one number (grep -c prints
# 0 AND exits 1 on no match, so `|| echo 0` would make it "0\n0").
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }

# mk_curl <dest> <fixture-dir> — answers /boards from boards.body and
# /boards/<id>/tickets from tickets.body + tickets.code, and logs every URL to
# <fixture-dir>/curl.txt so a section can assert the board was (or was not) read.
mk_curl() {
  cat > "$1" <<INNER
#!/bin/bash
OUT=""; WANTCODE=0; URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) OUT="\$2"; shift 2 ;;
    -w) WANTCODE=1; shift 2 ;;
    -H|-m) shift 2 ;;
    -*) shift ;;
    *) URL="\$1"; shift ;;
  esac
done
printf '%s\n' "\$URL" >> "$2/curl.txt"
CODE=200
case "\$URL" in
  *"/boards/"*"/tickets"*) BODY=\$(cat "$2/tickets.body" 2>/dev/null); CODE=\$(cat "$2/tickets.code" 2>/dev/null || echo 200) ;;
  *"/boards"*)             BODY=\$(cat "$2/boards.body" 2>/dev/null) ;;
  *)                       BODY="" ;;
esac
if [ -n "\$OUT" ]; then printf '%s' "\$BODY" > "\$OUT"; else printf '%s\n' "\$BODY"; fi
[ "\$WANTCODE" = 1 ] && printf '%s' "\$CODE"
exit 0
INNER
  chmod +x "$1"
}

# ═══════════════════════════════════════════════════════════════════════════
# Section U — br_board_status in-process against a stubbed board API.
# ═══════════════════════════════════════════════════════════════════════════
UH="$T/uh"; FA="$T/fa"
mkdir -p "$UH/bin" "$FA" "$T/ubin"
awk '/^br_board_status\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$DIR/bin/blocked-resolver.sh" > "$T/brlib.sh"
grep -q '^br_board_status()' "$T/brlib.sh" && ok || bad "U0: could not extract br_board_status from bin/blocked-resolver.sh"
cat > "$UH/bin/fleet-conf.sh" <<INNER
#!/bin/bash
case "\$2" in
  board_prefix) cat "$FA/prefix" 2>/dev/null || echo "/api/board" ;;
  prod) echo "https://api.example.com" ;;
  *) echo "-" ;;
esac
INNER
cat > "$UH/bin/internal-token-for.sh" <<INNER
#!/bin/bash
[ -e "$FA/notoken" ] && exit 1
echo token123
INNER
chmod +x "$UH/bin/"*.sh
printf '[{"id":"b1"}]' > "$FA/boards.body"
mk_curl "$T/ubin/curl" "$FA"
export PATH="$T/ubin:$ORIG_PATH"
BS() { H="$UH" bash -c '. "$0"; br_board_status "$@"' "$T/brlib.sh" "$@"; }
board() { printf '%s' "$1" > "$FA/tickets.body"; printf '%s' "${2:-200}" > "$FA/tickets.code"; }

board '[{"id":"t1","key":"TK-231","status":"done"}]'
GOT=$(BS fproj TK-231); RC=$?
[ "$RC" = 0 ] && [ "$GOT" = done ] && ok || bad "U1: a listed done ticket should print 'done' rc 0, got '$GOT' rc $RC"
board '{"tickets":[{"id":"t1","number":231,"status":"review"}]}'
GOT=$(BS fproj TK-231); RC=$?
[ "$RC" = 0 ] && [ "$GOT" = review ] && ok || bad "U2: a listed review ticket (number match, wrapped list) should print 'review' rc 0, got '$GOT' rc $RC"
board '[{"id":"t9","key":"TK-999","status":"done"}]'
GOT=$(BS fproj TK-231); RC=$?
[ "$RC" = 3 ] && [ -z "$GOT" ] && ok || bad "U3: a list without the ticket should be rc 3, got '$GOT' rc $RC"
board '{"error":"Unauthorized"}' 401
GOT=$(BS fproj TK-231); RC=$?
[ "$RC" = 2 ] && ok || bad "U4: a 401 should be UNREADABLE rc 2, got '$GOT' rc $RC"
board '{"error":"Internal Server Error"}' 500
GOT=$(BS fproj TK-231); RC=$?
[ "$RC" = 2 ] && ok || bad "U5: a 500 should be UNREADABLE rc 2, got '$GOT' rc $RC"
board '[{"id":"t1","key":"TK-231","status":"done"}]'
: > "$FA/notoken"
GOT=$(BS fproj TK-231); RC=$?
[ "$RC" = 2 ] && ok || bad "U6: no internal token should be UNREADABLE rc 2, got '$GOT' rc $RC"
rm -f "$FA/notoken"
# U7: a 200 that is not a ticket list is not the board answering.
board '{"error":"Forbidden"}' 200
GOT=$(BS fproj TK-231); RC=$?
[ "$RC" = 2 ] && ok || bad "U7: a 200 error object should be UNREADABLE rc 2, got '$GOT' rc $RC"
# U11: a 5xx is unreadable even when its body happens to be a ticket list —
# the STATUS is part of the answer, not only the body's shape.
board '[{"id":"t1","key":"TK-231","status":"done"}]' 503
GOT=$(BS fproj TK-231); RC=$?
[ "$RC" = 2 ] && ok || bad "U11: a 503 carrying a ticket list should be UNREADABLE rc 2, got '$GOT' rc $RC"
# U8: a GitHub-issues lane has no board: rc 1 and not one curl call.
board '[{"id":"t1","key":"TK-231","status":"done"}]'
printf -- '-' > "$FA/prefix"; : > "$FA/curl.txt"
GOT=$(BS fproj TK-231); RC=$?
[ "$RC" = 1 ] && [ ! -s "$FA/curl.txt" ] && ok || bad "U8: board_prefix '-' should be rc 1 with no curl call, got rc $RC and $(wc -l < "$FA/curl.txt") calls"
rm -f "$FA/prefix"
# U9: an answered ticket with no status field prints empty, rc 0 (open).
board '[{"id":"t1","key":"TK-231"}]'
GOT=$(BS fproj TK-231); RC=$?
[ "$RC" = 0 ] && [ -z "$GOT" ] && ok || bad "U9: a listed ticket with no status should be rc 0 and empty, got '$GOT' rc $RC"
# U10: no temp file left behind by any path. BH-6180: br_board_status runs with
# its own TMPDIR, so the tmp.* files of a suite running in parallel in the
# shared TMPDIR are never counted. The count is exact: any file in it is a leak.
U10T="$T/u10-tmpdir"; mkdir -p "$U10T"
board '{"error":"x"}' 500; TMPDIR="$U10T" BS fproj TK-231 >/dev/null
board '[{"id":"t1","key":"TK-231","status":"done"}]'; TMPDIR="$U10T" BS fproj TK-231 >/dev/null
LEFT=$(find "$U10T" -mindepth 1 2>/dev/null | wc -l)
[ "$LEFT" -eq 0 ] && ok || bad "U10: br_board_status left a temp file behind ($LEFT in its TMPDIR)"

# ═══════════════════════════════════════════════════════════════════════════
# Section E — the real lane, end to end.
# ═══════════════════════════════════════════════════════════════════════════
RH="$T/rh"
RST="$RH/state/blocked-resolver"
RLOG="$RH/logs/blocked-resolver.log"
ALOG="$RH/logs/ALERTS.log"
FB="$T/fb"
mkdir -p "$RH/bin/lib" "$RH/logs" "$RH/state" "$RH/flags" "$RH/locks" "$RH/env" \
         "$RH/builds" "$RH/state/merge-conductor" "$RH/state/build-queue/tproj" \
         "$T/rbin" "$T/rrepos" "$FB"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$RH/bin/"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$RH" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$RH/bin/lib/"
mkdir -p "$RH/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$RH/bin/lib/mc/"
chmod +x "$RH/bin/"*.sh
cat > "$RH/bin/internal-token-for.sh" <<INNER
#!/bin/bash
[ -e "$FB/notoken" ] && exit 1
echo token123
INNER
chmod +x "$RH/bin/internal-token-for.sh"

# tproj: a fly-pool product-board project (column 4 is the board API URL path).
# gproj: a fly-pool GitHub-issues project (column 4 is "-").
printf 'tproj o/tproj https://api.example.com /api/board 2 box-tproj 100.0.0.9\ngproj o/gproj https://api.example.com - 2 box-gproj 100.0.0.8\n' > "$RH/fleet.conf"
: > "$RH/env/global.env"
: > "$RH/flags/fly-pool-tproj"; : > "$RH/flags/fly-pool-gproj"
for f in beat.sh agent-call.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$RH/bin/$f"; chmod +x "$RH/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$RH/bin/lane-alert.sh"
chmod +x "$RH/bin/lane-alert.sh"

# The jobs client logs every queue_put / queue_done. $T/queue.answer overrides
# queue_put's answer (default "queued") so a scenario can make an enqueue fail.
cat > "$RH/bin/jobs-client.sh" <<INNER
queue_put() { printf 'queue_put %s\n' "\$*" >> "$T/queue.txt"; cat "$T/queue.answer" 2>/dev/null || echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { cat "$T/queue-list.txt" 2>/dev/null; }
INNER
: > "$T/queue-list.txt"

cat > "$T/rbin/gh" <<INNER
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*) printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"--json headRefName"*) cat "$T/prbranch" ;;
  *"--json title"*) cat "$T/prtitle" ;;
  *"--json state"*) cat "$T/prstate" ;;
  *"pr list"*) cat "$T/mergedprs" 2>/dev/null ;;
  *) echo "" ;;
esac
exit 0
INNER
chmod +x "$T/rbin/gh"
printf 'ticket/TK-1838' > "$T/prbranch"
printf 'TK-1838 fix the thing' > "$T/prtitle"
printf 'OPEN\n' > "$T/prstate"
printf 'abc123' > "$T/prhead"
: > "$T/mergedprs"
printf '#!/bin/bash\nexit 0\n' > "$T/rbin/flock"; chmod +x "$T/rbin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/rbin/br-ssh"
chmod +x "$T/rbin/br-ssh"
printf '[{"id":"b1"}]' > "$FB/boards.body"
mk_curl "$T/rbin/curl" "$FB"
export PATH="$T/rbin:$ORIG_PATH"
export GH_TOKEN=""

RUN() { ( HARNESS="$RH" FLEET_CONF="$RH/fleet.conf" REPOS_ROOT="$T/rrepos" \
           BR_SSH="$T/rbin/br-ssh" \
           bash "$RH/bin/blocked-resolver.sh" "${1:-tproj}" >>"$T/run.log" 2>>"$T/run.err" ) ; }

# reset_e [project] — a clean scenario: one parked PR in the conductor's row
# shape (merge-failed-twice maps to rebuild-fresh), no resolver state.
reset_e() {
  local p="${1:-tproj}"
  scratch_rm "$RST"
  scratch_rm "$RH/builds"; mkdir -p "$RH/builds"
  rm -f "$RH/flags/blocked-resolver-observe" "$FB/notoken" "$T/queue.answer"
  : > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/comments.txt"; : > "$T/lane-alert.txt"
  : > "$T/ssh.txt"; : > "$T/queue.txt"; : > "$FB/curl.txt"
  : > "$RLOG"; : > "$ALOG"
  printf 'o/%s#9\tBLOCKED_HUMAN\t1758240000\tabc123\tabc123\t-\tmerge-failed-twice: gh pr merge refused\thttps://github.com/o/%s/pull/9\n' "$p" "$p" \
    > "$RH/state/merge-conductor/pr-state.tsv"
}
close_row() {
  printf 'o/tproj#9\tCLOSED\t1758240000\tabc123\tabc123\t-\tmerge-failed-twice: gh pr merge refused\thttps://github.com/o/tproj/pull/9\n' \
    > "$RH/state/merge-conductor/pr-state.tsv"
}
# The board's answer for the ticket under test.
bstatus() { printf '%s' "[{\"id\":\"tid1838\",\"number\":1838,\"title\":\"the ticket\",\"status\":$1}]" > "$FB/tickets.body"; printf '200' > "$FB/tickets.code"; }
SJ()  { cat "$RST/${2:-tproj}/${2:-tproj}-TK-1838.json" 2>/dev/null; }
OUT() { SJ "" "${1:-tproj}" | jq -r '.outcome // ""' 2>/dev/null; }
ACTS() { local n; n=$(SJ "" "${2:-tproj}" | jq -r --arg a "$1" '[.attempts[]? | select((.action // "") == $a)] | length' 2>/dev/null); printf '%s' "${n:-0}"; }
QP()  { cnt '^queue_put' "$T/queue.txt"; }
CL()  { cnt . "$T/closed.txt"; }

# expect_dropped <label> — the done-ticket contract after two ticks.
expect_dropped() {
  local l="$1" o a
  [ "$(QP)" = 0 ] && ok || bad "$l: a done ticket must not be rebuilt, got $(QP) queue_put"
  [ "$(CL)" = 0 ] && ok || bad "$l: a done ticket's PR must not be closed as superseded, got $(CL) closes"
  o=$(OUT); [ "$o" = RESOLVED_DONE ] && ok || bad "$l: outcome should be RESOLVED_DONE, got '$o'"
  a=$(ACTS done-on-board); [ "${a:-0}" = 1 ] && ok || bad "$l: exactly one done-on-board attempt over two ticks, got ${a:-0}"
  [ "$(cnt '\[resolver\] TK-1838 is .* on the board — rebuild dropped' "$RLOG")" = 1 ] && ok \
    || bad "$l: exactly one '[resolver] … rebuild dropped' line over two ticks, got $(cnt 'rebuild dropped' "$RLOG")"
  [ ! -s "$ALOG" ] && ok || bad "$l: a dropped rebuild is not an incident, ALERTS got: $(head -2 "$ALOG")"
  [ "$(cnt "^done tproj TK-1838 done" "$T/queue.txt")" -ge 1 ] && ok || bad "$l: the queue row should be closed done (queue_done)"
}

# E1 + E3: done on the board, the rebuild-fresh rung, two ticks.
reset_e; bstatus '"done"'
RUN; RUN
expect_dropped E1
[ "$(SJ | jq -r '.done_status // ""')" = done ] && ok || bad "E1: done_status should be 'done', got '$(SJ | jq -r '.done_status // ""')'"
[ "$(cnt '/boards/b1/tickets' "$FB/curl.txt")" -ge 1 ] && ok || bad "E1: the rebuild rung never read the board"

# E2: case and whitespace — " Cancelled " and CLOSED are closed.
for s in '" Cancelled "' '"CLOSED"'; do
  reset_e; bstatus "$s"
  RUN; RUN
  expect_dropped "E2($s)"
done

# E4: the retry rung. Tick 1: the ticket is open and the enqueue fails, so the
# PR is closed and rebuild-fresh-failed is recorded; the conductor sweep moves the
# row to CLOSED, leaving br_from_rebuilds as the only source. Then the ticket goes
# done on the board — the retry must drop, not enqueue.
reset_e; bstatus '"review"'
printf 'nope' > "$T/queue.answer"
RUN
[ "$(ACTS rebuild-fresh-failed)" -ge 1 ] && ok || bad "E4: setup — tick 1 should have recorded rebuild-fresh-failed, got $(SJ | jq -c '[.attempts[]?.action]')"
close_row; rm -f "$T/queue.answer"; : > "$T/queue.txt"; : > "$RLOG"
bstatus '"done"'
RUN; RUN
[ "$(QP)" = 0 ] && ok || bad "E4: the retry rung must not enqueue a done ticket, got $(QP) queue_put"
[ "$(OUT)" = RESOLVED_DONE ] && ok || bad "E4: outcome should be RESOLVED_DONE, got '$(OUT)'"
[ "$(ACTS done-on-board)" = 1 ] && ok || bad "E4: exactly one done-on-board attempt, got $(ACTS done-on-board)"
[ "$(cnt 'enqueue retry\|rebuild-enqueue-failed' "$RLOG")" -ge 1 ] && ok || bad "E4: the retry rung (rebuild-enqueue-failed) was never offered — the scenario did not exercise it"

# E5: an unreadable board holds: 500, 401, no token — two ticks each.
for mode in 500 401 notoken; do
  reset_e; bstatus '"done"'
  case "$mode" in
    500) printf '%s' '{"error":"Internal Server Error"}' > "$FB/tickets.body"; printf '500' > "$FB/tickets.code" ;;
    401) printf '%s' '{"error":"Unauthorized"}' > "$FB/tickets.body"; printf '401' > "$FB/tickets.code" ;;
    notoken) : > "$FB/notoken" ;;
  esac
  RUN; RUN
  l="E5($mode)"
  [ "$(QP)" = 0 ] && ok || bad "$l: an unreadable board must not rebuild, got $(QP) queue_put"
  [ "$(CL)" = 0 ] && ok || bad "$l: an unreadable board must not close the PR, got $(CL) closes"
  [ -z "$(OUT)" ] && ok || bad "$l: an unreadable board must set no outcome, got '$(OUT)'"
  [ "$(ACTS hold-board-unreadable)" = 1 ] && ok || bad "$l: exactly one hold-board-unreadable attempt per episode, got $(ACTS hold-board-unreadable)"
  [ "$(SJ | jq -r '.board_misses // 0')" = 0 ] && ok || bad "$l: board_misses should stay 0"
  [ "$(ACTS done-on-board)" = 0 ] && ok || bad "$l: an unreadable board is never 'done'"
  [ "$(cnt 'board state for TK-1838 unreadable' "$RLOG")" = 2 ] && ok || bad "$l: one unreadable line per tick (2), got $(cnt 'board state for TK-1838 unreadable' "$RLOG")"
  [ -e "$RST/tproj/tproj-TK-1838.board-unreadable" ] && ok || bad "$l: the episode marker should be set"
done
# …and the marker goes the moment the board answers again (open → enqueue).
rm -f "$FB/notoken"; bstatus '"review"'
RUN
[ ! -e "$RST/tproj/tproj-TK-1838.board-unreadable" ] && ok || bad "E5: the episode marker should be removed once the board answers"
[ "$(QP)" = 1 ] && ok || bad "E5: once readable and open, the rebuild should enqueue once, got $(QP)"

# E6: an open ticket rebuilds exactly as today.
reset_e; bstatus '"review"'
RUN
[ "$(QP)" = 1 ] && ok || bad "E6: an open (review) ticket should enqueue once, got $(QP)"
[ "$(CL)" = 1 ] && ok || bad "E6: the stale PR should be closed as superseded as before, got $(CL)"
[ -z "$(OUT)" ] && ok || bad "E6: no outcome on an open ticket, got '$(OUT)'"
[ "$(ACTS done-on-board)" = 0 ] && ok || bad "E6: no done-on-board on an open ticket"

# E7: adversarial negatives — each must still enqueue.
for s in '"in_progress"' '"todo"' '"backlog"' '""' 'null' '"not done"' '"undone"' '"done-review"'; do
  reset_e; bstatus "$s"
  RUN
  [ "$(QP)" = 1 ] && ok || bad "E7($s): an open status must still enqueue, got $(QP) queue_put"
  [ "$(ACTS done-on-board)" = 0 ] && ok || bad "E7($s): must not be read as done"
done
# …a ticket with no status field at all,
reset_e
printf '%s' '[{"id":"tid1838","number":1838,"title":"the ticket"}]' > "$FB/tickets.body"; printf '200' > "$FB/tickets.code"
RUN
[ "$(QP)" = 1 ] && ok || bad "E7(absent): a ticket with no status field must still enqueue, got $(QP)"
# …a title that says done,
reset_e
printf '%s' '[{"id":"tid1838","number":1838,"title":"done done done","status":"review"}]' > "$FB/tickets.body"; printf '200' > "$FB/tickets.code"
RUN
[ "$(QP)" = 1 ] && ok || bad "E7(title): a 'done' title must not drop the rebuild, got $(QP)"
# …and a DIFFERENT ticket that is done while this one is in review.
reset_e
printf '%s' '[{"id":"o1","key":"TK-77","number":77,"status":"done"},{"id":"tid1838","number":1838,"status":"review"}]' > "$FB/tickets.body"; printf '200' > "$FB/tickets.code"
RUN
[ "$(QP)" = 1 ] && ok || bad "E7(other): another ticket being done must not drop this rebuild, got $(QP)"

# E8: reopened. A RESOLVED_DONE row whose ticket is back in review rebuilds.
reset_e; bstatus '"done"'
RUN
[ "$(OUT)" = RESOLVED_DONE ] && ok || bad "E8: setup — outcome should be RESOLVED_DONE, got '$(OUT)'"
bstatus '"review"'
RUN
[ -z "$(OUT)" ] && ok || bad "E8: a reopened ticket should clear RESOLVED_DONE, got '$(OUT)'"
[ "$(ACTS done-lifted)" = 1 ] && ok || bad "E8: exactly one done-lifted attempt, got $(ACTS done-lifted)"
[ "$(QP)" = 1 ] && ok || bad "E8: a reopened ticket should enqueue once, got $(QP)"

# E9: observe mode with a done ticket writes nothing.
reset_e; bstatus '"done"'
: > "$RH/flags/blocked-resolver-observe"
RUN
[ "$(cnt 'WOULD drop' "$RLOG")" = 1 ] && ok || bad "E9: observe mode should log one WOULD drop line, got $(cnt 'WOULD drop' "$RLOG")"
[ "$(ACTS done-on-board)" = 0 ] && [ -z "$(OUT)" ] && ok || bad "E9: observe mode must write no record (outcome '$(OUT)')"
[ "$(QP)" = 0 ] && [ "$(cnt '^done' "$T/queue.txt")" = 0 ] && ok || bad "E9: observe mode must not touch the queue"
rm -f "$RH/flags/blocked-resolver-observe"

# E10: a GitHub-issues project never reads a board, and rebuilds as today.
reset_e gproj; bstatus '"done"'
RUN gproj
[ "$(cnt '/boards' "$FB/curl.txt")" = 0 ] && ok || bad "E10: an issues lane must make no /boards call, got $(cnt '/boards' "$FB/curl.txt")"
[ "$(QP)" = 1 ] && ok || bad "E10: an issues lane should enqueue as today, got $(QP)"
[ "$(ACTS done-on-board gproj)" = 0 ] && ok || bad "E10: an issues lane gets no done-on-board"

if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi
echo "RESULT: $PASS passed, 0 failed"
exit 0
