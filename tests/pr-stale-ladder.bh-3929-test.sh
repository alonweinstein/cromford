#!/bin/bash
# tests/pr-stale-ladder.bh-3929-test.sh — BH-3935 (BH-3929.3): the stale-PR
# ladder by age. bin/lib/pr-owner/stale.sh (po_stale, the sweep's age hook),
# bin/lib/br/opt/stale.sh (the resolver's re-plan rung) and the plan stage's
# reading of a `KIND: stale-replan` note.
#
#   A  the hook, sourced, every collaborator a recording stub (S1-S9)
#   B  the resolver half through the REAL bin/blocked-resolver.sh on the shared
#      fixture (S3b, S3d, S3e, S3f, S3h) and the plan-stage block (S3g)
#   C  the production entry point: the REAL bin/pr-owner-sweep.sh (S10)
#
# Every assertion is on an OUTPUT: the call log the stubs write, the lines the
# hook logs, the resolver's record and the PRs it closed. The clock is pinned
# (PO_STALE_NOW) in part A; parts B and C run on the fixture's own clock, with
# ages far from any threshold.
# Run from anywhere: tests/pr-stale-ladder.bh-3929-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
[ -r "$DIR/bin/lib/pr-owner/stale.sh" ] || { echo "FAIL: bin/lib/pr-owner/stale.sh missing"; exit 1; }

# ============================================================================
# A. THE HOOK
# ============================================================================
NOW0=1790000000; NOW=$NOW0   # the pinned clock: PO_STALE_NOW for every hook run in part A
HR=3600; DY=86400
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
UH="$T/uh"; CALLS="$T/calls.log"; SAYF="$T/say.log"
mkdir -p "$UH/bin" "$UH/logs" "$UH/state/build-notes/tproj" "$T/fakebin" "$T/att"
SLUG=o/tproj
HEADSHA=1111111111111111111111111111111111111111

# The scripts the hook runs by path, each recording what it was asked.
cat > "$UH/bin/fleet-conf.sh" <<EOF
#!/bin/bash
case "\$2" in
  board_prefix) cat "$T/prefix" 2>/dev/null || echo - ;;
  prod)         echo https://board.test ;;
  repo)         echo o/tproj ;;
esac
EOF
printf '#!/bin/bash\necho tok\n' > "$UH/bin/internal-token-for.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$UH/bin/lane-alert.sh"
chmod +x "$UH/bin/"*.sh
# The board's HTTP: records the url and the POST body; answers by path.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
data=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in -d|--data|--data-binary) data="\$2"; shift ;; http*) url="\$1" ;; esac
  shift
done
printf 'CURL %s %s\n' "\$url" "\$data" >> "$T/curl.log"
case "\$url" in
  */tickets/t77/move) cat "$T/move-echo" 2>/dev/null || echo '{"ticket":{"id":"t77","status":"todo"}}' ;;
  */boards/b1/tickets) echo '[{"id":"t76","key":"TK-8"},{"id":"t77","key":"TK-9"}]' ;;
  */boards) echo '[{"id":"b1"}]' ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# shellcheck source=bin/lib/pr-health.sh
. "$DIR/bin/lib/pr-health.sh" || exit 1
# THE COLLABORATORS, defined before the hook file is sourced: its lazy loader
# skips every lib whose entry function is already here.
gh_rest() {
  printf 'GH %s %s\n' "$1" "$2" >> "$CALLS"
  case "$2" in
    repos/*/commits/*)
      [ -n "${F_COMMIT_RC:-}" ] && return "$F_COMMIT_RC"
      printf '{"commit":{"committer":{"date":"%s"}},"parents":%s}\n' "$(iso $((NOW - F_COMMIT_AGE)))" "${F_PARENTS:-[]}" ;;
    repos/*/pulls/*)
      printf '{"state":"open","updated_at":"%s","head":{"ref":"%s"},"labels":%s}\n' \
        "$(iso $((NOW - F_COMMIT_AGE)))" "${F_BRANCH:-ticket/TK-9}" "${F_LABELS:-[]}" ;;
    *) return 75 ;;
  esac
}
gh_rest_comment() { printf 'COMMENT %s %s\n' "$1" "$2" >> "$CALLS"; cat "$3" >> "$T/bodies.txt"; echo >> "$T/bodies.txt"; return "${F_COMMENT_RC:-0}"; }
gh_rest_close()   { printf 'CLOSE %s %s %s\n' "$1" "$2" "${3:-}" >> "$CALLS"; return "${F_CLOSE_RC:-0}"; }
_jobs_req() {
  printf 'JOBS %s %s\n' "$1" "$2" >> "$CALLS"
  case "$2" in
    /api/verdicts\?*)
      [ -n "${F_VERDICTS_RC:-}" ] && return "$F_VERDICTS_RC"
      if [ -n "${F_VERDICT_AGE:-}" ]; then printf '{"rows":[{"id":9,"created_at":"%s"}],"standing":null}' "$(iso $((NOW - F_VERDICT_AGE)))"
      else printf '{"rows":[],"standing":null}'; fi ;;
    /api/verdict\?*) return 2 ;;
    *) return 1 ;;
  esac
}
pr_attempt_has() { printf 'ATT_HAS %s\n' "$*" >> "$CALLS"; [ -n "${F_ATT_RC:-}" ] && return "$F_ATT_RC"; [ -e "$T/att/$2-$3-$4" ] && return 0; return 2; }
pr_attempt_put() { printf 'ATT_PUT %s\n' "$*" >> "$CALLS"; : > "$T/att/$2-$3-$4"; }
pr_attempt_del() { printf 'ATT_DEL %s\n' "$*" >> "$CALLS"; rm -f "$T/att/$2-$3-$4"; }
pr_attempt_list() {
  local f n=0; [ -n "${F_LIST_RC:-}" ] && return "$F_LIST_RC"
  for f in "$T/att/$2-$3-"*; do [ -e "$f" ] || continue; printf '%s\n' "${f#"$T/att/$2-$3-"}"; n=1; done
  [ "$n" = 1 ] || return 2
}
mc_row_get() {
  [ -n "${F_ROW:-}" ] || return 0
  printf '%s\t%s\t1789000000\tabc\tdef\t-\t%s\thttps://github.com/%s/pull/%s\n' "$1" "${F_ROW%%|*}" "${F_ROW#*|}" "$SLUG" "${1##*#}"
}
mc_handoff_owns() { case "${1:-}" in red-ci-twice*|red-twice*|stale-replan*|head-not-reapproved*|conflict-unresolvable*) return 0 ;; esac; return 1; }
mc_transition() { printf 'TRANSITION %s\n' "$*" >> "$CALLS"; }
mc_rebase()     { printf 'MC_REBASE %s\n' "$*" >> "$CALLS"; [ -n "${F_REBASE_OUT:-}" ] && echo "$F_REBASE_OUT"; return "${F_REBASE_RC:-0}"; }
hold_check()    { printf 'HOLD %s %s\n' "$1" "$2" >> "$CALLS"; if [ "$2" = "${F_NUM:-9}" ]; then return "${F_HOLD_PR:-0}"; fi; return "${F_HOLD_ISSUE:-0}"; }
cm_clear()      { printf 'CM_CLEAR %s\n' "$1" >> "$CALLS"; return 0; }
br_mechanical() { echo MECH >> "$CALLS"; }
issue_strip_ai_build() { echo STRIP >> "$CALLS"; }
say() { printf '%s\n' "$*" >> "$SAYF"; }
# shellcheck source=bin/lib/pr-owner/stale.sh
. "$DIR/bin/lib/pr-owner/stale.sh" || exit 1

RESET() {
  : > "$CALLS"; : > "$SAYF"; : > "$T/bodies.txt"; : > "$T/curl.log"; : > "$T/lane-alert.txt"
  rm -f "$T/att/"* "$T/move-echo" "$T/prefix" "$UH/state/build-notes/tproj/"*
  unset F_COMMIT_RC F_VERDICT_AGE F_VERDICTS_RC F_ATT_RC F_BRANCH F_LABELS F_COMMENT_RC F_CLOSE_RC \
        F_REBASE_RC F_HOLD_PR F_HOLD_ISSUE F_KEY F_AUTHOR F_CLASS F_DRAFT F_NUM F_DRY F_MAX F_RH F_RD F_CD \
        F_PARENTS F_LIST_RC F_REBASE_OUT F_HEAD
  NOW=$NOW0
  F_ROW="WAIT_REVIEW|-"; F_CREATED_AGE=$((30 * DY)); F_COMMIT_AGE=$HR
}
# HOOK — one per-PR call, the way bin/pr-owner-sweep.sh makes it, in a subshell.
HOOK() { (
  PO_PROJECT=tproj PO_SLUG=$SLUG PO_NUM="${F_NUM:-9}" PO_HEAD="${F_HEAD:-$HEADSHA}" PO_AUTHOR="${F_AUTHOR:-harness-bot}"
  PO_CLASS="${F_CLASS:-OWNED}" PO_KEY="${F_KEY:-TK-9}" PO_CREATED="$(iso $((NOW - F_CREATED_AGE)))"
  PO_DRAFT="${F_DRAFT:-0}" PO_MERGEABLE=MERGEABLE PO_OWNED=1
  PO_STALE_REBASE_H="${F_RH:-24}" PO_STALE_REPLAN_D="${F_RD:-5}" PO_STALE_CLOSE_D="${F_CD:-10}"
  PO_STALE_NOW=$NOW MAX_ACTIONS="${F_MAX:-5}" DRY="${F_DRY:-0}" H="$UH" HARNESS="$UH"
  PATH="$T/fakebin:$PATH"
  po_stale </dev/null
); }
N() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
LOGHAS() { grep -q -- "$1" "$SAYF" 2>/dev/null; }

# ---- S1 the clock -----------------------------------------------------------
RESET; F_COMMIT_AGE=$((23 * HR)); HOOK
[ "$(N MC_REBASE)" = 0 ] && [ "$(N ATT_PUT)" = 0 ] && ! LOGHAS STALE_RUNG && ok \
  || bad "S1 23h since the head commit: no rung (calls: $(cat "$CALLS"); log: $(cat "$SAYF"))"
RESET; F_COMMIT_AGE=$((9 * DY + 23 * HR)); F_VERDICT_AGE=$HR; HOOK
[ "$(N ATT_PUT)" = 0 ] && [ "$(N COMMENT)" = 0 ] && [ "$(N MC_REBASE)" = 0 ] && [ "$(N TRANSITION)" = 0 ] && ok \
  || bad "S1b a verdict 1h old restarts the clock: no rung on a 9d23h-old commit (calls: $(cat "$CALLS"))"
RESET; F_COMMIT_RC=75; HOOK
[ "$(N ATT_PUT)" = 0 ] && [ "$(N MC_REBASE)" = 0 ] && [ "$(N COMMENT)" = 0 ] && ok \
  || bad "S1c an unreadable head commit is no rung, never 'infinitely old' (calls: $(cat "$CALLS"))"
RESET; F_COMMIT_AGE=$((3 * DY)); F_VERDICTS_RC=1; HOOK
[ "$(N ATT_PUT)" = 0 ] && [ "$(N MC_REBASE)" = 0 ] && ok || bad "S1d a verdicts outage is no rung (calls: $(cat "$CALLS"))"

# ---- S2 rung 1, rebase ------------------------------------------------------
RESET; F_COMMIT_AGE=$((25 * HR)); HOOK
[ "$(N "MC_REBASE $SLUG tproj ticket/TK-9 $HEADSHA https://github.com/$SLUG/pull/9")" = 1 ] && ok \
  || bad "S2 exactly one mc_rebase <slug> <project> <branch> <head> <url> (calls: $(cat "$CALLS"))"
LOGHAS "STALE_RUNG rebase $SLUG#9 ${HEADSHA:0:12} age=25h reason=no head/verdict change" && ok \
  || bad "S2 the rung is logged with its reason (log: $(cat "$SAYF"))"
[ "$(N "ATT_PUT $SLUG 9 stale-rebase $HEADSHA")" = 1 ] && ok || bad "S2 the attempt row is written (calls: $(cat "$CALLS"))"
HOOK
[ "$(N MC_REBASE)" = 1 ] && ok || bad "S2 a second tick on the same head rebases nothing (calls: $(cat "$CALLS"))"
[ "$(N MECH)" = 0 ] && ok || bad "S2 br_mechanical is never called"
# the attempt row is written BEFORE the side effect
[ "$(grep -n 'ATT_PUT' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n 'MC_REBASE' "$CALLS" | head -1 | cut -d: -f1)" ] && ok \
  || bad "S2 the attempt row precedes mc_rebase (calls: $(cat "$CALLS"))"
RESET; F_COMMIT_AGE=$((25 * HR)); F_REBASE_RC=3; HOOK
[ "$(N "ATT_DEL $SLUG 9 stale-rebase $HEADSHA")" = 1 ] && ok || bad "S2b mc_rebase rc 3 forgets the attempt (calls: $(cat "$CALLS"))"
RESET; F_COMMIT_AGE=$((25 * HR)); F_ATT_RC=1; HOOK
[ "$(N MC_REBASE)" = 0 ] && ok || bad "S2e an attempt-ledger outage is no side effect (calls: $(cat "$CALLS"))"
RESET; F_CREATED_AGE=$((2 * HR)); F_COMMIT_AGE=$((30 * DY)); HOOK
[ "$(N MC_REBASE)" = 0 ] && [ "$(N ATT_PUT)" = 0 ] && ok || bad "S2c a PR opened 2h ago on a 30d-old commit takes no rung (calls: $(cat "$CALLS"))"
[ "$(N 'GH ')" = 0 ] && ok || bad "S2c the young PR returns before any GitHub read (calls: $(cat "$CALLS"))"
# S2g the ladder's own rebase does not reset the clock (rung 1 at 25h, then the
# head it pushed at 5d+1h takes rung 2, not another rebase)
NEWSHA=3333333333333333333333333333333333333333
RESET; NOW=$((NOW0 - 4 * DY)); F_COMMIT_AGE=$((25 * HR)); F_REBASE_OUT=$NEWSHA; HOOK
[ "$(N MC_REBASE)" = 1 ] && [ "$(N "ATT_PUT $SLUG 9 stale-carry $NEWSHA $((NOW0 - 5 * DY - HR))")" = 1 ] && LOGHAS "clock carried to ${NEWSHA:0:12}" && ok \
  || bad "S2g rung 1 carries the clock onto the head it pushed (calls: $(cat "$CALLS"); log: $(cat "$SAYF"))"
: > "$CALLS"; : > "$SAYF"; NOW=$((NOW0 - 3 * DY)); F_HEAD=$NEWSHA; F_COMMIT_AGE=$DY; unset F_REBASE_OUT
F_PARENTS="[{\"sha\":\"$HEADSHA\"},{\"sha\":\"4444444444444444444444444444444444444444\"}]"; HOOK
[ "$(N MC_REBASE)" = 0 ] && [ "$(N ATT_PUT)" = 0 ] && LOGHAS "STALE_RUNG skip $SLUG#9 ${NEWSHA:0:12} rung=rebase reason=this head is the ladder's own rebase" && ok \
  || bad "S2g the ladder's own head at 2d is not rebased again (calls: $(cat "$CALLS"); log: $(cat "$SAYF"))"
: > "$CALLS"; : > "$SAYF"; NOW=$NOW0; F_COMMIT_AGE=$((4 * DY)); HOOK
[ "$(N "TRANSITION $SLUG#9 BLOCKED_HUMAN stale-replan: no head or verdict change for 5d $NEWSHA")" = 1 ] && [ "$(N MC_REBASE)" = 0 ] && ok \
  || bad "S2g the rebased head at 5d+1h takes rung 2, not another rebase (calls: $(cat "$CALLS"); log: $(cat "$SAYF"))"
# the pool path (rc 6) pushes later: the carry sits on the head it read and
# covers the merge commit the pool makes on top of it
RESET; NOW=$((NOW0 - 4 * DY)); F_COMMIT_AGE=$((25 * HR)); F_REBASE_RC=6; HOOK
[ "$(N "ATT_PUT $SLUG 9 stale-carry $HEADSHA $((NOW0 - 5 * DY - HR))")" = 1 ] && ok || bad "S2h rc 6 carries the clock on the head it read (calls: $(cat "$CALLS"))"
: > "$CALLS"; NOW=$NOW0; unset F_REBASE_RC; F_HEAD=$NEWSHA; F_COMMIT_AGE=$((3 * DY))
F_PARENTS="[{\"sha\":\"$HEADSHA\"},{\"sha\":\"4444444444444444444444444444444444444444\"}]"; HOOK
[ "$(N "TRANSITION $SLUG#9 BLOCKED_HUMAN stale-replan")" = 1 ] && ok || bad "S2h the pool's merge on top of a carried head keeps the clock (calls: $(cat "$CALLS"))"
# a push that is not a merge of a carried head is real movement
: > "$CALLS"; F_PARENTS="[{\"sha\":\"$HEADSHA\"}]"; F_COMMIT_AGE=$HR; HOOK
[ "$(N TRANSITION)" = 0 ] && [ "$(N MC_REBASE)" = 0 ] && ok || bad "S2h an author's own commit on a carried head restarts the clock (calls: $(cat "$CALLS"))"
RESET; F_COMMIT_AGE=$((25 * HR)); F_LIST_RC=1; HOOK
[ "$(N MC_REBASE)" = 0 ] && [ "$(N ATT_PUT)" = 0 ] && ok || bad "S2i an unreadable carry list is no rung (calls: $(cat "$CALLS"))"
RESET; F_COMMIT_AGE=$((25 * HR)); F_DRAFT=1; HOOK
[ "$(N MC_REBASE)" = 0 ] && [ "$(N ATT_PUT)" = 0 ] && ok || bad "S2d a draft takes no rebase (calls: $(cat "$CALLS"))"
RESET; F_COMMIT_AGE=$((25 * HR)); F_ROW="BLOCKED_HUMAN|red-ci-twice: x"; HOOK
[ "$(N MC_REBASE)" = 0 ] && LOGHAS "STALE_RUNG skip" && ok || bad "S2f a resolver-owned park is not rebased (calls: $(cat "$CALLS"); log: $(cat "$SAYF"))"

# ---- S3 rung 2, re-plan -----------------------------------------------------
RESET; F_COMMIT_AGE=$((5 * DY + HR)); HOOK
[ "$(N "TRANSITION $SLUG#9 BLOCKED_HUMAN stale-replan: no head or verdict change for 5d $HEADSHA def https://github.com/$SLUG/pull/9")" = 1 ] && ok \
  || bad "S3a one BLOCKED_HUMAN stale-replan transition (calls: $(cat "$CALLS"))"
LOGHAS "STALE_RUNG replan $SLUG#9" && ok || bad "S3a STALE_RUNG replan logged (log: $(cat "$SAYF"))"
[ "$(N MC_REBASE)" = 0 ] && ok || bad "S3a the higher rung is taken, not the rebase too"
HOOK
[ "$(N TRANSITION)" = 1 ] && ok || bad "S3a a second tick on the same head re-plans nothing (calls: $(cat "$CALLS"))"
RESET; F_COMMIT_AGE=$((5 * DY + HR)); F_ROW="BLOCKED_HUMAN|red-ci-twice: still red"; HOOK
[ "$(N TRANSITION)" = 0 ] && [ "$(N ATT_PUT)" = 0 ] && LOGHAS "STALE_RUNG skip $SLUG#9" && ok \
  || bad "S3c a CI-red park is not re-planned by this ladder (calls: $(cat "$CALLS"); log: $(cat "$SAYF"))"
RESET; F_COMMIT_AGE=$((5 * DY + HR)); printf 'KIND: ci-replan\nPRIOR PR: x\n' > "$UH/state/build-notes/tproj/TK-9.md.relayed-1789000000"; HOOK
[ "$(N TRANSITION)" = 0 ] && LOGHAS "STALE_RUNG skip $SLUG#9" && ok \
  || bad "S3c a ticket already carrying a ci-replan note is not re-planned (calls: $(cat "$CALLS"); log: $(cat "$SAYF"))"
RESET; F_COMMIT_AGE=$((5 * DY + HR)); F_KEY=-; HOOK
[ "$(N TRANSITION)" = 0 ] && LOGHAS "STALE_RUNG skip" && ok || bad "S3c no ticket key: no re-plan (calls: $(cat "$CALLS"))"
RESET; F_COMMIT_AGE=$((5 * DY + HR)); F_ROW="READY|-"; HOOK
[ "$(N TRANSITION)" = 0 ] && [ "$(N ATT_PUT)" = 0 ] && ok || bad "S3i a READY row is the conductor's (calls: $(cat "$CALLS"))"

# ---- S4 rung 3, close -------------------------------------------------------
RESET; F_COMMIT_AGE=$((10 * DY + HR)); HOOK
CI=$(grep -n '^COMMENT' "$CALLS" | head -1 | cut -d: -f1); CC=$(grep -n '^CLOSE' "$CALLS" | head -1 | cut -d: -f1)
[ -n "$CI" ] && [ -n "$CC" ] && [ "$CI" -lt "$CC" ] && ok || bad "S4a the comment goes out before the close (calls: $(cat "$CALLS"))"
[ "$(N "CLOSE $SLUG 9 pulls")" = 1 ] && ok || bad "S4a the PR is closed through gh_rest_close pulls"
grep -q "Closing this. Nothing has moved on it for 10 days: no new commits and no new review. The ticket goes back to todo so it gets picked up fresh." "$T/bodies.txt" \
  && ok || bad "S4a the body is the ticket's template with N=10 (body: $(cat "$T/bodies.txt"))"
[ "$(N "CM_CLEAR blocked tproj TK-9")" = 1 ] && ok || bad "S4a the blocked row is cleared (calls: $(cat "$CALLS"))"
grep -qE 'GH [A-Z]+ repos/[^ ]*/issues/' "$CALLS" && bad "S4a no issue label/state call on an issues board" || ok
[ "$(N STRIP)" = 0 ] && [ ! -s "$T/curl.log" ] && ok || bad "S4a no issue_strip_ai_build and no board HTTP on an issues board"
[ "$(N "TRANSITION $SLUG#9 CLOSED stale-close")" = 1 ] && ok || bad "S4a the conductor row goes CLOSED (calls: $(cat "$CALLS"))"
LOGHAS "STALE_RUNG close $SLUG#9" && ok || bad "S4a STALE_RUNG close logged (log: $(cat "$SAYF"))"
[ "$(N "ATT_PUT $SLUG 9 stale-close $HEADSHA")" = 1 ] && [ "$(grep -n 'ATT_PUT' "$CALLS" | head -1 | cut -d: -f1)" -lt "$CI" ] && ok \
  || bad "S4a the stale-close row is written before the comment"
# S4b the product board
RESET; F_COMMIT_AGE=$((10 * DY + HR)); echo /api/internal > "$T/prefix"; HOOK
grep -q 'CURL https://board.test/api/internal/boards ' "$T/curl.log" && grep -q 'CURL https://board.test/api/internal/boards/b1/tickets ' "$T/curl.log" \
  && grep -qF 'CURL https://board.test/api/internal/tickets/t77/move {"toStatus":"todo","sortOrder":999999}' "$T/curl.log" && ok \
  || bad "S4b the product-board ticket is moved to todo after the id lookup (curl: $(cat "$T/curl.log"))"
LOGHAS "TK-9 moved to todo" && ok || bad "S4b the move is logged (log: $(cat "$SAYF"))"
: > "$CALLS"; HOOK
[ "$(N COMMENT)" = 0 ] && [ "$(N "CLOSE $SLUG 9 pulls")" = 1 ] && ok || bad "S4b a rerun on the same head retries the close only (calls: $(cat "$CALLS"))"
# S4c the move echo does not say todo
RESET; F_COMMIT_AGE=$((10 * DY + HR)); echo /api/internal > "$T/prefix"; echo '{"error":"nope"}' > "$T/move-echo"; HOOK
LOGHAS "not moved" && [ "$(grep -c . "$T/lane-alert.txt")" = 1 ] && grep -q 'pr-owner-sweep/stale' "$T/lane-alert.txt" && ok \
  || bad "S4c a refused move is logged and alerted once (log: $(cat "$SAYF"); alerts: $(cat "$T/lane-alert.txt"))"
[ "$(N "CLOSE $SLUG 9 pulls")" = 1 ] && ok || bad "S4c the PR stays closed"
# S4d EXTERNAL, no key
RESET; F_COMMIT_AGE=$((10 * DY + HR)); F_CLASS=EXTERNAL; F_AUTHOR=alice; F_KEY=-; HOOK
head -c 7 "$T/bodies.txt" | grep -q '^@alice ' && ! grep -q 'goes back to todo' "$T/bodies.txt" && ok \
  || bad "S4d the external close mentions the author and promises no board move (body: $(cat "$T/bodies.txt"))"
[ ! -s "$T/curl.log" ] && [ "$(N CM_CLEAR)" = 0 ] && ok || bad "S4d no board call without a key"
# S4e the comment is refused
RESET; F_COMMIT_AGE=$((10 * DY + HR)); F_COMMENT_RC=75; HOOK
[ "$(N CLOSE)" = 0 ] && [ "$(N "ATT_DEL $SLUG 9 stale-close $HEADSHA")" = 1 ] && ok \
  || bad "S4e a refused comment closes nothing and forgets the attempt (calls: $(cat "$CALLS"))"

# ---- S5 a new head restarts the clock --------------------------------------
RESET; F_CREATED_AGE=$((11 * DY)); F_COMMIT_AGE=$HR; HOOK
[ "$(N ATT_PUT)" = 0 ] && [ "$(N COMMENT)" = 0 ] && [ "$(N MC_REBASE)" = 0 ] && ok || bad "S5 an 11d PR with a 1h head takes no rung"

# ---- S6 knob 0 is off (the settings row, through ph_knob) -------------------
RESET; F_COMMIT_AGE=$((11 * DY))
setting_get() { case "$1" in pr_stale.close_days) printf 0 ;; *) return 2 ;; esac; }
F_CD=$(ph_knob pr_stale.close_days PR_STALE_CLOSE_DAYS 10 2>/dev/null); unset -f setting_get
HOOK
[ "$F_CD" = 0 ] && [ "$(N COMMENT)" = 0 ] && [ "$(N CLOSE)" = 0 ] && [ "$(N 'TRANSITION .* stale-replan')" = 1 ] && ok \
  || bad "S6 close_days=0 closes nothing and the re-plan rung is chosen (knob=$F_CD; calls: $(cat "$CALLS"))"
RESET; F_COMMIT_AGE=$((11 * DY)); F_RH=0; F_RD=0; F_CD=0; HOOK
[ ! -s "$CALLS" ] && ok || bad "S6 every rung off: nothing read, nothing done (calls: $(cat "$CALLS"))"

# ---- S7 never close a held PR ----------------------------------------------
RESET; F_COMMIT_AGE=$((11 * DY)); F_LABELS='[{"name":"parked"}]'; HOOK
[ "$(N COMMENT)" = 0 ] && [ "$(N CLOSE)" = 0 ] && [ "$(N ATT_PUT)" = 0 ] && ok || bad "S7a a parked label is never closed (calls: $(cat "$CALLS"))"
RESET; F_COMMIT_AGE=$((11 * DY)); F_LABELS='[{"name":"Hold"}]'; HOOK
[ "$(N COMMENT)" = 0 ] && [ "$(N CLOSE)" = 0 ] && ok || bad "S7a a hold label is never closed"
RESET; F_COMMIT_AGE=$((11 * DY)); F_HOLD_PR=1; F_KEY=TK-12; HOOK
[ "$(N COMMENT)" = 0 ] && [ "$(N CLOSE)" = 0 ] && [ "$(N ATT_PUT)" = 0 ] && ok || bad "S7b a HOLD comment on the PR stops the close (calls: $(cat "$CALLS"))"
RESET; F_COMMIT_AGE=$((11 * DY)); F_HOLD_ISSUE=1; F_KEY=TK-12; HOOK
[ "$(N "HOLD $SLUG 12")" = 1 ] && [ "$(N COMMENT)" = 0 ] && [ "$(N CLOSE)" = 0 ] && ok \
  || bad "S7c a held issues-board ticket stops the close (calls: $(cat "$CALLS"))"
RESET; F_COMMIT_AGE=$((11 * DY)); F_HOLD_PR=2; F_KEY=TK-12; HOOK
[ "$(N COMMENT)" = 0 ] && [ "$(N CLOSE)" = 0 ] && ok || bad "S7d an unreadable hold is no close"
RESET; F_COMMIT_AGE=$((15 * DY)); F_ROW="MERGING|-"; HOOK
[ "$(N COMMENT)" = 0 ] && [ "$(N CLOSE)" = 0 ] && ok || bad "S7e a MERGING row at 15d is never closed"
RESET; F_COMMIT_AGE=$((15 * DY)); F_CLASS=PARKED; HOOK
[ ! -s "$CALLS" ] && ok || bad "S7f a PARKED PR is never aged (calls: $(cat "$CALLS"))"
RESET; F_COMMIT_AGE=$((15 * DY)); F_CLASS=ORPHAN; HOOK
[ ! -s "$CALLS" ] && ok || bad "S7f an ORPHAN is never aged here"
RESET; F_COMMIT_AGE=$((15 * DY)); F_ROW=""; HOOK
[ "$(N COMMENT)" = 0 ] && [ "$(N ATT_PUT)" = 0 ] && ok || bad "S7g no conductor row: the PR is not ours to age"

# ---- S8 dry run and the cap -------------------------------------------------
RESET; F_COMMIT_AGE=$((11 * DY)); echo /api/internal > "$T/prefix"; F_DRY=1; HOOK
LOGHAS "DRY-RUN would:" && [ "$(N ATT_PUT)" = 0 ] && [ "$(N COMMENT)" = 0 ] && [ "$(N CLOSE)" = 0 ] \
  && [ "$(N TRANSITION)" = 0 ] && [ "$(N CM_CLEAR)" = 0 ] && [ ! -s "$T/curl.log" ] && ok \
  || bad "S8a a dry run writes nothing (calls: $(cat "$CALLS"); log: $(cat "$SAYF"))"
# Two PRs in ONE shell, the way the sweep's per-repo loop calls the hook.
RESET; F_COMMIT_AGE=$((25 * HR))
( PO_PROJECT=tproj PO_SLUG=$SLUG PO_HEAD="$HEADSHA" PO_AUTHOR=harness-bot PO_CLASS=OWNED PO_KEY=TK-9
  PO_CREATED="$(iso $((NOW - F_CREATED_AGE)))" PO_DRAFT=0 PO_STALE_REBASE_H=24 PO_STALE_REPLAN_D=5 PO_STALE_CLOSE_D=10
  PO_STALE_NOW=$NOW MAX_ACTIONS=1 DRY=0 H="$UH" HARNESS="$UH"
  : > "$CALLS"; : > "$SAYF"; rm -f "$T/att/"*
  PO_NUM=9; po_stale </dev/null; PO_NUM=10; po_stale </dev/null )
[ "$(N MC_REBASE)" = 1 ] && LOGHAS "STALE_RUNG held $SLUG#10 cap" && ok \
  || bad "S8b PR_OWNER_MAX_ACTIONS=1: one acted, the other held (calls: $(cat "$CALLS"); log: $(cat "$SAYF"))"

# ---- S9 never merges --------------------------------------------------------
[ -r "$DIR/bin/lib/br/opt/stale.sh" ] && ! grep -nE 'pr merge|/merge([^-a-z]|$)|merge_pr|gh_pr_merge|mc_merge' "$DIR/bin/lib/pr-owner/stale.sh" "$DIR/bin/lib/br/opt/stale.sh" \
  && ok || bad "S9 the ladder has no merge call (and bin/lib/br/opt/stale.sh exists)"

# ============================================================================
# B. THE RESOLVER HALF (the real bin/blocked-resolver.sh)
# ============================================================================
# shellcheck source=tests/lib/rb-all.sh
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
scratch_install_closure bin/lib/br/opt/cirepair.sh "$H" >/dev/null && scratch_install_closure bin/lib/br/opt/stale.sh "$H" >/dev/null || exit 1
cat > "$H/bin/lib/hold.sh" <<'EOF'
hold_check() { printf 'clear\tno hold on this ticket\n'; return 0; }
hold_check_thread() { printf 'clear\tno-hold\n'; return 0; }
hold_is_pause()   { return 1; }
hold_is_abandon() { return 1; }
EOF
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\nexit 0\n' "$T" > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
LOGF="$H/logs/blocked-resolver.log"
URL="https://github.com/o/tproj/pull/9"; URL10="https://github.com/o/tproj/pull/10"
PARKHEAD=cccccccccccccccccccccccccccccccccccccccc
STALEWHY="stale-replan: no head or verdict change for 5d"
NOTEF="$H/state/build-notes/tproj/TK-9.md"
RM_POOL() { local p; for p in "$H/builds/pool-tproj-TK-9-"*; do [ -e "$p" ] && scratch_rm "$p"; done; return 0; }
BFRESH() {
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/state/build-notes"; RM_POOL
  : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/comment-bodies.txt"; : > "$T/comments.txt"; : > "$LOGF"
  : > "$T/beats.txt"; rm -f "$T/st-comment"
  scratch_rm "$H/state/merge-conductor/handoff"; scratch_rm "$H/state/merge-conductor/handoff-released"
  printf 'ticket/TK-9' > "$T/prbranch"; printf 'TK-9: a thing' > "$T/prtitle"
  printf '%s' "$PARKHEAD" > "$T/prhead"; echo OPEN > "$T/prstate"
  ROW "o/tproj#9" "$STALEWHY" "$URL"
}
REC() { STATEJSON tproj-TK-9; }
NQ() { grep -c '^tproj TK-9 ' "$T/queue.txt" 2>/dev/null || true; }
RUNG() { grep -oE '\-> (mechanical|regen|fix-round|rebuild-fresh|rebuild-retry|abandon-rebuild)|ladder rung: [a-z-]+' "$LOGF" 2>/dev/null | head -1; }
BRENV=(BR_SUPERSEDE_SETTLE_SECS=0 BR_SUPERSEDE_DECLINE_ALERT_SECS=3600)

# S3b the stale park is re-planned through the CI-park re-plan path, once
BFRESH; RUN
head -1 "$NOTEF" 2>/dev/null | grep -qx 'KIND: stale-replan' \
  && sed -n 2p "$NOTEF" | grep -q 'parked OPEN, no head or verdict movement for 5 days' && grep -q "$URL" "$NOTEF" && ok \
  || bad "S3b the note is KIND: stale-replan with the prior PR (note: $(cat "$NOTEF" 2>/dev/null); log: $(tail -5 "$LOGF"))"
[ "$(NQ)" = 1 ] && ok || bad "S3b exactly one re-plan enqueued (queue: $(cat "$T/queue.txt"); log: $(tail -5 "$LOGF"))"
[ "$(REC | jq -r '.stale_replan_url // ""')" = "$URL" ] && [ "$(REC | jq -r '.ci_replans // ""')" = 1 ] && ok \
  || bad "S3b the record stamps the re-plan and counts it on the shared cap (record: $(REC))"
[ -z "$(RUNG)" ] && [ ! -s "$T/closed.txt" ] && ok || bad "S3b no ladder rung, nothing closed (rung '$(RUNG)'; closed: $(cat "$T/closed.txt"))"
RUN; RUN
[ "$(NQ)" = 1 ] && [ -z "$(RUNG)" ] && ok || bad "S3b later ticks enqueue nothing more (queue: $(cat "$T/queue.txt"); rung '$(RUNG)')"
# S3e the re-plan's PR supersedes the stale one (head unchanged)
newrec() { local d="$H/builds/pool-tproj-TK-9-202610040101"; mkdir -p "$d"; printf 'PR_CREATED %s\n' "$URL10" > "$d/RESULT"; }
: > "$T/closed.txt"; : > "$T/comment-bodies.txt"; newrec; RUN
[ "$(grep -c 'pulls/9' "$T/closed.txt")" = 1 ] && ok || bad "S3e the stale PR is closed once the re-plan's PR exists (closed: $(cat "$T/closed.txt"); log: $(tail -4 "$LOGF"))"
grep -q 'Superseded by #10 (re-plan after no movement)' "$T/comment-bodies.txt" && ok \
  || bad "S3e the close says Superseded by #10 (bodies: $(head -c 300 "$T/comment-bodies.txt"))"
grep -q 'pulls/10' "$T/closed.txt" && bad "S3e the re-plan's own PR is never closed" || ok
: > "$T/closed.txt"; RUN
[ ! -s "$T/closed.txt" ] && ok || bad "S3e superseded exactly once ($(cat "$T/closed.txt"))"
# S3e with the head moved since the park: left open
BFRESH; RUN; printf 'dddddddddddddddddddddddddddddddddddddddd' > "$T/prhead"; : > "$T/closed.txt"; newrec; : > "$LOGF"; RUN
grep -q 'pulls/9' "$T/closed.txt" && bad "S3e a stale PR someone pushed to is not closed ($(cat "$T/closed.txt"))" || ok
grep -q 'NOT superseded' "$LOGF" && ok || bad "S3e the leave is logged (log: $(tail -3 "$LOGF"))"
# S3d the shared cap: a prior ci-replan note already spent the one re-plan
BFRESH; mkdir -p "$H/state/build-notes/tproj"
printf 'KIND: ci-replan\nPRIOR PR: x\n' > "$H/state/build-notes/tproj/TK-9.md.relayed-1789000000"
BRENV+=(BR_CI_REPLAN_MAX=1); RUN; BRENV=("${BRENV[@]:0:2}")
[ "$(NQ)" = 0 ] && ok || bad "S3d no re-plan once the shared cap is spent (queue: $(cat "$T/queue.txt"))"
REC | jq -e '[.attempts[]? | select(.action == "stale-replan-skipped")] | length == 1' >/dev/null && ok \
  || bad "S3d the record says stale-replan-skipped (record: $(REC))"
[ -z "$(RUNG)" ] && ok || bad "S3d a skipped re-plan dispatches no ladder rung ('$(RUNG)')"
# S3f the floor counts a stale-replan note too: a CI park at the cap ABANDONs
BFRESH
A() { jq -nc --arg a "$1" --arg r "$2" --arg d "$3" '{at:"2026-09-24 10:00:00Z",action:$a,reason:$r,detail:$d}'; }
REDWHY="red-twice: still red on aaaaaaaa after its failed jobs were re-run once"
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --argjson a "[$(A mechanical "$REDWHY" "merged origin/main into ticket/TK-9 and pushed bbbbbbbb (mc_rebase rc=0)"),$(A regen "$REDWHY" "regenerated ticket/TK-9: pushed cccccccc over head8=bbbbbbbb (mc_rebase rc=0)")]" --arg u "$URL" \
  '{project:"tproj",rkey:"tproj-TK-9",mechanicals:1,fixrounds:0,regens:1,rebuilds:0,outcome:"",attempts:$a,ci_lineage_url:$u,ci_lineage_from:"0"}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
mkdir -p "$H/builds/pool-tproj-TK-9-202610010101"; printf 'KIND: stale-replan\nPRIOR PR: x\n' > "$H/builds/pool-tproj-TK-9-202610010101/carried-note.md"
ROWST "o/tproj#9" RED_TWICE "$REDWHY" "$URL"
BRENV+=(BR_CI_REPLAN_MAX=1); RUN; BRENV=("${BRENV[@]:0:2}")
[ "$(REC | jq -r '.outcome // ""')" = ABANDONED ] && [ "$(NQ)" = 0 ] && ok \
  || bad "S3f a stale re-plan already carried spends the shared cap: the CI park ABANDONs (record: $(REC); queue: $(cat "$T/queue.txt"))"
# S3h the module off: a stale park reaches no paid rung
BFRESH; BRENV+=(BR_OPT_OFF=stale); RUN; BRENV=("${BRENV[@]:0:2}")
[ "$(NQ)" = 0 ] && [ -z "$(RUNG)" ] && grep -q 'left where it is' "$LOGF" && ok \
  || bad "S3h BR_OPT_OFF=stale: no rung, no enqueue, said out loud (rung '$(RUNG)'; log: $(tail -4 "$LOGF"))"
# S3g the plan stage frames the note as a re-plan, not a ruling
awk '/^# >>> carried note/{f=1;next} /^# <<< carried note/{exit} f' "$RB_ALL" > "$T/cn.sh"
mkdir -p "$T/cnb" "$T/cnh/state/build-notes/tproj"
printf 'KIND: stale-replan\nPRIOR PR: https://x/pull/9 (parked OPEN, no head or verdict movement for 5 days)\n' > "$T/cnh/state/build-notes/tproj/TK-9.md"
CNL=$( HARNESS="$T/cnh" BUILD="$T/cnb" PROJECT=tproj KEY=TK-9; STAMP() { echo T; }; . "$T/cn.sh"; printf '%s' "$CARRIED_NOTE_LINE" )
case "$CNL" in *ADJUDICATED*) CNADJ=1 ;; *) CNADJ=0 ;; esac
case "$CNL" in *"AUTOMATIC RE-PLAN"*) [ "$CNADJ" = 0 ] ;; *) false ;; esac && ok \
  || bad "S3g a stale-replan note is a re-plan brief, not a ruling (line: $(printf '%.300s' "$CNL"))"

# ============================================================================
# C. THE PRODUCTION ENTRY POINT (the real bin/pr-owner-sweep.sh)
# ============================================================================
SH="$T/sw"
mkdir -p "$SH/bin/lib" "$SH/logs" "$SH/state/merge-conductor" "$SH/locks" "$SH/flags" "$SH/env" "$SH/fixture" "$T/swbin"
cp "$DIR/bin/pr-owner-sweep.sh" "$SH/bin/"
scratch_install_closure bin/pr-owner-sweep.sh "$SH" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$SH" >/dev/null || exit 1
cp "$DIR/bin/alert-line.sh" "$SH/bin/"
ln -sf "$DIR/bin/fleet-conf.sh" "$SH/bin/fleet-conf.sh"
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$SH/fleet.conf"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$SH/env/global.env"
printf '#!/bin/bash\necho box-tproj\n' > "$SH/bin/box-for.sh"
printf '#!/bin/bash\nexit 0\n' > "$SH/bin/lane-alert.sh"; printf '#!/bin/sh\nexit 0\n' > "$SH/bin/beat.sh"
chmod +x "$SH/bin/"*.sh
# The conductor lib the hook loads lazily, as a sourced override: its row read
# is the real file shape, its rebase is recorded.
cat > "$SH/bin/lib/merge-conductor-lib.sh" <<EOF
MC_ROWS="\${HARNESS}/state/merge-conductor/pr-state.tsv"
mc_init() { :; }
mc_row_get() { awk -F'\t' -v k="\$1" '\$1==k {print; exit}' "\$MC_ROWS" 2>/dev/null; }
mc_handoff_owns() { return 1; }
mc_transition() { printf 'TRANSITION %s\n' "\$*" >> "$T/sw-calls.log"; }
mc_rebase() { printf 'MC_REBASE %s\n' "\$*" >> "$T/sw-calls.log"; return 0; }
EOF
printf 'hold_check() { return 0; }\n' > "$SH/bin/lib/hold.sh"
SWHEAD=2222222222222222222222222222222222222222
cat > "$T/swbin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/sw-gh.log"
case "\$*" in
  "api rate_limit"*) printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":1},"graphql":{"remaining":4000,"limit":5000,"reset":1}}}\n'; exit 0 ;;
  *"-i -X GET repos/o/tproj/commits/"*) printf 'HTTP/2 200\r\n\r\n{"commit":{"committer":{"date":"%s"}}}' "\$(cat "$T/sw-commit-date")"; exit 0 ;;
  *"-i -X GET repos/o/tproj/pulls/"*) printf 'HTTP/2 200\r\n\r\n{"state":"open","updated_at":"%s","head":{"ref":"ticket/TK-9"},"labels":[]}' "\$(cat "$T/sw-commit-date")"; exit 0 ;;
  *"-i -X "*) printf 'HTTP/2 404\r\n\r\n{}'; exit 0 ;;
  "api repos/"*) echo 1234; exit 0 ;;
  *"pr list"*"--state open"*) cat "$SH/fixture/open.json" ;;
  *"pr list"*"--state merged"*) echo '[]' ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/swbin/curl" <<EOF
#!/bin/bash
URL="\${!#}"
printf '%s\n' "\$*" >> "$T/sw-curl.log"
case "\$URL" in
  */api/jobs*)       printf '{"jobs":[]}\n200\n' ;;
  */api/queue*)      printf '{"rows":[]}\n200\n' ;;
  */api/verdicts\?*) printf '{"rows":[],"standing":null}\n200\n' ;;
  */api/pr-attempts\?*sha=*) case "\$*" in *"-X GET"*) printf '{}\n404\n' ;; *) printf '{"ok":true}\n200\n' ;; esac ;;
  */api/pr-attempts\?*) case "\$*" in *"-X GET"*) printf '{"attempts":[],"count":0}\n200\n' ;; *) printf '{"ok":true}\n200\n' ;; esac ;;
  */api/settings/*|*/api/verdict\?*) printf '{}\n404\n' ;;
  *)                 printf '{"ok":true}\n200\n' ;;
esac
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/swbin/ssh"
chmod +x "$T/swbin/"*
SWNOW=$(date -u +%s)  # determinism: ok the sweep reads its own clock; ages below are hours from any threshold
date -u -d "@$((SWNOW - 25 * HR - 1800))" +%Y-%m-%dT%H:%M:%SZ > "$T/sw-commit-date"
jq -nc --arg c "$(date -u -d "@$((SWNOW - 30 * DY))" +%Y-%m-%dT%H:%M:%SZ)" --arg h "$SWHEAD" \
  '[{number:9,title:"TK-9: a thing",headRefName:"ticket/TK-9",headRefOid:$h,author:{login:"operator"},labels:[],body:"",mergeable:"MERGEABLE",updatedAt:$c,createdAt:$c,url:"https://github.com/o/tproj/pull/9",isDraft:false}]' \
  > "$SH/fixture/open.json"
printf 'o/tproj#9\tWAIT_REVIEW\t%s\t%s\t%s\t-\t-\thttps://github.com/o/tproj/pull/9\n' "$SWNOW" "$SWHEAD" "$SWHEAD" > "$SH/state/merge-conductor/pr-state.tsv"
echo box-hub > "$SH/state/box-name"   # BH-5124: the conductor file is read only on the conductor's box
SWEEP() { ( HARNESS="$SH" FLEET_CONF="$SH/fleet.conf" PATH="$T/swbin:$PATH" GH_TOKEN=t GH_BUDGET_TTL_S=0 HUB_BOX_NAME=box-hub \
            bash "$SH/bin/pr-owner-sweep.sh" ) >/dev/null 2>&1 </dev/null; }
: > "$T/sw-calls.log"; SWEEP
grep -q "STALE_RUNG rebase o/tproj#9 ${SWHEAD:0:12} age=25h" "$SH/logs/pr-owner-sweep.log" 2>/dev/null \
  && [ "$(grep -c "MC_REBASE o/tproj tproj ticket/TK-9 $SWHEAD https://github.com/o/tproj/pull/9" "$T/sw-calls.log")" = 1 ] && ok \
  || bad "S10 the real sweep reaches the ladder and rebases (log: $(tail -5 "$SH/logs/pr-owner-sweep.log" 2>/dev/null); calls: $(cat "$T/sw-calls.log"))"

echo "pr-stale-ladder (BH-3935): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
