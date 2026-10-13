#!/bin/bash
# tests/overlap-guard.bh-580-test.sh — bin/overlap-guard.sh REROUTES a shared
# test path instead of deferring the whole ticket on it (BH-584, part of #580).
#
# WHY THIS EXISTS. Test files are the fleet's largest merge-conflict surface: 20
# of 24 unresolvable conductor cases were two siblings appending cases to the
# same shared tests/<tier>/<area>.test.ts. Before this, one of those two tickets
# was held at the launch gate for as long as the other one built — a full stop
# for a file that nobody actually needs to share, because the right answer is
# "write your cases to your OWN file". So the guard now partitions the hit set:
# a shared test file becomes a recorded reroute, everything else is judged with
# the exact same jaccard the guard always used.
#
# Every claim here is DRIVEN through the real bin/overlap-guard.sh (D2) against a
# fake jobs ledger and a fake gh, and asserted on rc, stdout, the record file,
# the log and the rewritten pre-plan list — never on the guard's source (D3).
#
# Run: tests/overlap-guard.bh-580-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/proj
export HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/flags" "$T/h/state" "$T/h/plans" \
         "$T/h/builds" "$T/h/env" "$T/h/locks" "$T/fakebin"
cp "$DIR/bin/overlap-guard.sh" "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cp "$DIR/bin/lib/scheduler-conf.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/test-home-lib.sh" "$T/h/bin/lib/"
# TEST-CHANGE (BH-1585): the list is REST, which needs the contract lib beside it.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
printf 'proj %s https://proj.example /api/board 0 local -\n' "$SLUG" > "$T/h/fleet.conf"

# --- the fake jobs ledger (same shape as tests/overlap-guard-test.sh) --------
cat > "$T/h/bin/jobs-client.sh" <<EOF
_jobs_req() {
  [ "\$(cat "$T/ledger.rc" 2>/dev/null || echo 0)" = 0 ] || return 1
  cat "$T/ledger.json" 2>/dev/null
}
EOF
echo 0 > "$T/ledger.rc"
echo '{"jobs":[]}' > "$T/ledger.json"

# --- the fake gh ------------------------------------------------------------
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  # TEST-CHANGE (BH-1585): \`files\` is a REST read now — the open page, then
  # pulls/N/files per PR. Same \$T/prs.json, answered in the REST shape.
  *"repos/$SLUG/pulls?"*)
    printf 'HTTP/2.0 200\r\n\r\n'
    jq -c --arg s "$SLUG" '[.[] | {number, html_url: .url, draft: (.isDraft // false), state: "open",
      user: {login: "operator", type: "User"}, labels: [], title: "t", body: "",
      created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z", merged_at: null, closed_at: null,
      head: {ref: .headRefName, sha: "x", repo: {full_name: \$s}}, base: {ref: "main", repo: {full_name: \$s}}}]' "$T/prs.json" ;;
  *"repos/$SLUG/pulls/"*"/files"*)
    n=\$(printf '%s\n' "\$*" | sed -nE 's#.*/pulls/([0-9]+)/files.*#\1#p')
    printf 'HTTP/2.0 200\r\n\r\n'
    jq -c --argjson n "\$n" '[.[] | select(.number == \$n) | .files[]? | {filename: .path}]' "$T/prs.json" ;;
  *"pr list -R $SLUG --state open --author operator"*) cat "$T/prs.json" ;;
  *"pr list"*) echo '[]' ;;
  *) echo '' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
echo '[]' > "$T/prs.json"

G="$T/h/bin/overlap-guard.sh"
SHARED=R/tests/level2-unit/foo.test.ts
MINE=R/tests/level2-unit/foo.ab-1.test.ts
SIBS=R/tests/level2-unit/foo.ab-2.test.ts
LIST="$T/h/plans/proj-AB-1/planned-files.txt"
REC="$T/h/state/preplan-files/proj-AB-1"
LOG="$T/h/logs/overlap-guard.log"

setplan() { local k="$1"; shift; mkdir -p "$T/h/plans/proj-$k"; printf '%s\n' "$@" > "$T/h/plans/proj-$k/planned-files.txt"; }
# The record is deliberately NOT cleared here: case 6 runs the same collision
# twice and the record surviving between them is the thing it pins.
reset() {
  rm -rf "$T/h/state/overlap-guard"
  : > "$T/gh-calls.txt"; : > "$LOG"
  echo '[]' > "$T/prs.json"; echo '{"jobs":[]}' > "$T/ledger.json"
  rm -f "$T/h/flags/test-reroute-off"
}
clearrec() { rm -rf "$T/h/state/preplan-files"; }
run() { OUT=$("$G" proj "$1" 2>/dev/null); RC=$?; }
building() { printf '{"jobs":[{"kind":"build","ticket_id":"%s"}]}\n' "$1" > "$T/ledger.json"; }
mkpr() { # mkpr <num> <branch> <draft> <file>...
  local n="$1" br="$2" d="$3"; shift 3
  jq -nc --arg n "$n" --arg br "$br" --argjson d "$d" --args '
    [{number: ($n|tonumber), url: ("https://github.com/o/r/pull/"+$n),
      headRefName: $br, isDraft: $d, files: [$ARGS.positional[] | {path: .}]}]' "$@"
}

# ============================================================================
# 1. A running sibling holds the shared test file: REROUTE, not DEFER
# ============================================================================
reset; clearrec
building AB-2
setplan AB-2 "$SHARED"
setplan AB-1 "$SHARED"
run AB-1
[ "$RC" = 0 ] && ok || bad "1: a shared test file must not hold the ticket (rc $RC, out: $OUT)"
grep -q '^LAUNCH AB-1 rerouted 1 test path(s) vs AB-2' <<<"$OUT" && ok \
  || bad "1: the LAUNCH line must name how many paths were rerouted and against whom (got: $OUT)"
[ -s "$REC" ] && ok || bad "1: the reroute must be recorded at state/preplan-files/proj-AB-1"
[ "$(wc -l < "$REC" 2>/dev/null)" = 1 ] && ok || bad "1: the record must hold exactly one line (got: $(cat "$REC" 2>/dev/null))"
[ "$(cat "$REC" 2>/dev/null)" = "REROUTE tests: $SHARED -> $MINE" ] && ok \
  || bad "1: the record line format is the contract's (got: $(cat "$REC" 2>/dev/null))"
grep -q "REROUTE vs AB-2" "$LOG" && ok || bad "1: the log must name the holder it rerouted against"
grep -q "$SHARED -> $MINE" "$LOG" && ok || bad "1: the log line must name both paths"
grep -qxF "$MINE" "$LIST" && ok || bad "1: the pre-plan list must now name the per-ticket path (got: $(cat "$LIST"))"
grep -qxF "$SHARED" "$LIST" && bad "1: the pre-plan list must no longer name the shared path" || ok

# ============================================================================
# 2. A real source file alongside it still DEFERS — and records NOTHING
# ============================================================================
reset; clearrec
building AB-2
setplan AB-2 "$SHARED" R/src/lib/pay.ts
setplan AB-1 "$SHARED" R/src/lib/pay.ts
run AB-1
[ "$RC" = 1 ] && ok || bad "2: a shared source file must still DEFER (rc $RC, out: $OUT)"
grep -q '^DEFER AB-1 vs AB-2' <<<"$OUT" && ok || bad "2: DEFER must name the holder (got: $OUT)"
grep -q 'files=\[R/src/lib/pay.ts\]' <<<"$OUT" && ok \
  || bad "2: files=[...] must name the REAL conflict, not the rerouted test file (got: $OUT)"
[ ! -e "$REC" ] && ok || bad "2: a deferred ticket must not leave a reroute record (got: $(cat "$REC" 2>/dev/null))"
grep -qxF "$SHARED" "$LIST" && ok || bad "2: a deferred ticket's pre-plan list must be untouched"

# ============================================================================
# 3. Our OWN per-ticket file is not a collision at all (a rebuild)
# ============================================================================
reset; clearrec
building AB-2
setplan AB-2 "$SHARED"
setplan AB-1 "$MINE"
cp "$LIST" "$T/list.before"
run AB-1
[ "$RC" = 0 ] && ok || bad "3: our own per-ticket file must LAUNCH (rc $RC, out: $OUT)"
[ ! -e "$REC" ] && ok || bad "3: nothing was rerouted, so nothing may be recorded"
cmp -s "$LIST" "$T/list.before" && ok || bad "3: the pre-plan list must be byte-identical"
grep -q 'rerouted' <<<"$OUT" && bad "3: the LAUNCH line must not claim a reroute (got: $OUT)" || ok

# ============================================================================
# 4. A SIBLING's per-ticket file is a real overlap — nobody's file is taken
# ============================================================================
reset; clearrec
building AB-2
setplan AB-2 "$SIBS"
setplan AB-1 "$SIBS"
run AB-1
[ "$RC" = 1 ] && ok || bad "4: a sibling's own test file must DEFER, never be rerouted (rc $RC, out: $OUT)"
[ ! -e "$REC" ] && ok || bad "4: a sibling's own test file must not be recorded as a reroute"

# ============================================================================
# 5. An OPEN harness PR holding the shared test file is rerouted the same way
# ============================================================================
reset; clearrec
setplan AB-1 R/tests/x-test.sh
mkpr 7 ticket/ab-3 false R/tests/x-test.sh > "$T/prs.json"
run AB-1
[ "$RC" = 0 ] && ok || bad "5: a shared test file held by an open PR must not hold the ticket (rc $RC, out: $OUT)"
[ "$(cat "$REC" 2>/dev/null)" = "REROUTE tests: R/tests/x-test.sh -> R/tests/x.ab-1-test.sh" ] && ok \
  || bad "5: a shell suite reroutes to <area>.<key>-test.sh (got: $(cat "$REC" 2>/dev/null))"
grep -q 'REROUTE vs PR#7' "$LOG" && ok || bad "5: the log must name the PR it rerouted against"

# ============================================================================
# 6. Idempotent: the same collision twice leaves ONE record line
# ============================================================================
reset; clearrec
building AB-2
setplan AB-2 "$SHARED"
setplan AB-1 "$SHARED"
run AB-1
[ "$RC" = 0 ] && ok || bad "6: first pass must LAUNCH (rc $RC)"
setplan AB-1 "$SHARED"   # the next tick re-planned the same shared file
reset
building AB-2
run AB-1
[ "$RC" = 0 ] && ok || bad "6: second pass must LAUNCH too (rc $RC, out: $OUT)"
[ "$(wc -l < "$REC" 2>/dev/null)" = 1 ] && ok \
  || bad "6: the record must not grow on a repeat (got: $(cat "$REC" 2>/dev/null))"

# ============================================================================
# 7. The kill switch restores today's behaviour byte-for-byte
# ============================================================================
TODAY="DEFER AB-1 vs AB-2(building) jaccard=1.00 files=[$SHARED]"
reset; clearrec
building AB-2
setplan AB-2 "$SHARED"
setplan AB-1 "$SHARED"
touch "$T/h/flags/test-reroute-off"
run AB-1
[ "$RC" = 1 ] && ok || bad "7: flags/test-reroute-off must defer as today (rc $RC, out: $OUT)"
[ "$OUT" = "$TODAY" ] && ok || bad "7: the flagged stdout must equal the pre-change line exactly (got: $OUT)"
[ ! -e "$REC" ] && ok || bad "7: the kill switch must write no record"
rm -f "$T/h/flags/test-reroute-off"
reset; clearrec
building AB-2
OUT=$(TEST_REROUTE=0 "$G" proj AB-1 2>/dev/null); RC=$?
[ "$RC" = 1 ] && ok || bad "7: TEST_REROUTE=0 must defer as today (rc $RC, out: $OUT)"
[ "$OUT" = "$TODAY" ] && ok || bad "7: TEST_REROUTE=0 stdout must equal the pre-change line (got: $OUT)"
[ ! -e "$REC" ] && ok || bad "7: TEST_REROUTE=0 must write no record"

# ============================================================================
# 8. An unwritable record is NOT a reroute (D9/D11): defer as today, say so
# ============================================================================
reset; clearrec
building AB-2
setplan AB-2 "$SHARED"
setplan AB-1 "$SHARED"
printf 'not a directory\n' > "$T/h/state/preplan-files"   # the record's parent, as a FILE
chmod 444 "$T/h/state/preplan-files"
run AB-1
[ "$RC" = 1 ] && ok || bad "8: an unrecordable reroute must defer, never launch on an unwritten record (rc $RC, out: $OUT)"
grep -q "^DEFER AB-1 vs AB-2" <<<"$OUT" && ok || bad "8: it must defer with today's line (got: $OUT)"
grep -q 'unwritable' "$LOG" && ok || bad "8: the log must say the record could not be written"
chmod 644 "$T/h/state/preplan-files"; rm -f "$T/h/state/preplan-files"

# ============================================================================
# 9. A bare directory entry is not a file this ticket can rename
# ============================================================================
reset; clearrec
building AB-2
setplan AB-2 "$SHARED"
setplan AB-1 R/tests/level2-unit
run AB-1
[ "$RC" = 1 ] && ok || bad "9: a directory collision must DEFER as today (rc $RC, out: $OUT)"
[ ! -e "$REC" ] && ok || bad "9: a directory must never be rerouted to a per-ticket path"
reset; clearrec
setplan AB-2 R/tests/level2-unit
building AB-2
setplan AB-1 R/tests/level2-unit
run AB-1
[ "$RC" = 1 ] && ok || bad "9: both sides naming the bare directory must DEFER (rc $RC, out: $OUT)"
[ ! -e "$REC" ] && ok || bad "9: a bare directory on both sides must never be recorded"
# The other direction, and the reason only EXACT-equal hits are reroutable: the
# sibling holds the whole directory, so foo.ab-1.test.ts would land inside it
# too. Renaming here buys nothing and the ticket must still stand down.
reset; clearrec
setplan AB-2 R/tests/level2-unit
building AB-2
setplan AB-1 "$SHARED"
run AB-1
[ "$RC" = 1 ] && ok || bad "9: a file under a directory a sibling holds must DEFER (rc $RC, out: $OUT)"
[ ! -e "$REC" ] && ok || bad "9: a per-ticket target inside a held directory must never be recorded"
# And a directory whose NAME looks like a test file (tests/smoke.spec/) with a
# sibling holding a file inside it: only an EXACT-equal hit is reroutable, so
# this one is not. Renaming the directory would leave the sibling's file where
# it was and claim a path that does not exist.
reset; clearrec
setplan AB-2 R/tests/smoke.spec/login.ts
building AB-2
setplan AB-1 R/tests/smoke.spec
run AB-1
[ "$RC" = 1 ] && ok || bad "9: a directory that only CONTAINS the sibling's file must DEFER (rc $RC, out: $OUT)"
[ ! -e "$REC" ] && ok || bad "9: a directory must never be renamed out from under a sibling's file"

echo "overlap-guard.bh-580: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
