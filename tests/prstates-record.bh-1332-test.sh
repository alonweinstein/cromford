#!/bin/bash
# tests/prstates-record.bh-1332-test.sh — BH-1332: the record of the PR-state
# ledger's `-ge` rule must say what the code does.
#
# WHAT WAS WRONG. Three surfaces (the comment above triage_prstates_ingest, the
# verification-map page's first ledger bullet, and the (B5) header in
# tests/triage-shards-prstates.bh-1079-test.sh) all explained `-ge` with the same
# sentence: "the gate writes queuefp and the tick's own REST refresh stamps the
# ledger inside the same tick, so a freshly written vector routinely carries the
# same second as the row it should replace". That is not the mechanism.
# triage_prstates_refresh runs AFTER triage_prstates_ingest in the same tick and
# skips every row whose stamp is younger than TRIAGE_PRSTATES_TTL_S, so the row
# ingest just stamped is never re-read or re-stamped by that tick's refresh. The
# ties the suites actually produce come from TWO GATE READS inside one second.
#
# So this suite asserts the MECHANISM against the real library (cases 1-3) and
# then asserts the record matches it (case 4). Case 4 is a source grep on
# purpose — the claim under test IS text — and every grep is guarded on the file
# existing first, so a moved or deleted file fails instead of passing (D3).
#
# The library under test is the production file, copied verbatim into a scratch
# $HARNESS and sourced the way bin/lib/rt/shards.sh sources it; the same
# functions driven through the REAL bin/run-triage.sh tick are covered by
# tests/triage-shards-prstates.bh-1079-test.sh (Part B) and
# tests/triage-shards-ticket-fp-test.sh (Part B), which stay green unchanged.
#
# Run from anywhere: tests/prstates-record.bh-1332-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ONE clock read for the whole file: every fixture age below is derived from it,
# so this suite cannot pick its own red day (bin/test-determinism-lint.sh).
NOW=$(date +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/state" "$H/logs" "$H/env"
: > "$H/env/global.env"
P=project-5
cp "$DIR/bin/lib/triage-shards-lib.sh" "$H/bin/lib/triage-shards-lib.sh"
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
export FLEET_CONF="$DIR/fleet.conf"

# The REST reader, stubbed in the PARENT shell so the lib() subshell inherits
# it: triage_prstates_refresh does `command -v gh_rest_pr_state || . gh-rest.sh`,
# so a defined function means bin/lib/gh-rest.sh is never sourced and no real
# call is ever made. Every lookup appends the PR number to $T/pulls, so "no
# lookup happened" is an assertion on a file and not on a log line.
# No bin/lib/gh-budget.sh is copied into the scratch tree: _tsh_gh_budget_low
# answers rc 2 (unknown) and unknown PROCEEDS, which is the branch the lib
# documents and the one that lets these cases reach the reader at all.
# BH-1485: the lane reads through gh_rest_pr_state_var (the variant that keeps
# GH_REST_STATUS alive in the caller's shell), so THAT is the name the stub
# defines and the name the lib's `command -v` guard probes. Same recorded
# lookups, same answers, same 44 — only the calling convention moved.
gh_rest_pr_state_var() {
  local s
  printf '%s\n' "${3:-}" >> "$T/pulls"
  s=$(cat "$T/pr-state" 2>/dev/null)
  case "$s" in 404) printf -v "$1" '%s' ''; return 44 ;; esac
  printf -v "$1" '%s' "$s"
}

lib() { ( PATH="$H/bin:$PATH"; export PATH; . "$H/bin/lib/triage-shards-lib.sh"; "$@" ) }
tick() { triage_prstates_ingest "$H" "$P"; triage_prstates_refresh "$H" "$P" "$H/units"; }

npulls() { grep -c . "$T/pulls" 2>/dev/null | tr -d ' ' || true; }
led()    { cat "$H/state/$P.prstates" 2>/dev/null; }
ledts()  { awk -F'\t' -v n="$1" '$1==n{v=$3} END{print v+0}' "$H/state/$P.prstates" 2>/dev/null; }
reset()  { rm -f "$H/state/$P.prstates" "$H/state/$P.queuefp"; : > "$T/pulls"; echo open > "$T/pr-state"; }

# The queue line the refresh reads its PR numbers out of (awk $2=="queue", then
# `PR ?#<n>`), in the units-file shape bin/lib/rt/shards.sh hands it.
printf '563\tqueue\tTS-563 — ready to build, waiting on PR #12 to merge\n' > "$H/units"

# ═══ (1) MECHANISM: the same tick's refresh never touches what ingest wrote ══
# A fresh vector lands at the gate's own epoch, and the refresh that runs next
# in the SAME tick sees a row younger than the TTL and skips it — no read, no
# re-stamp. This is what makes the old "the refresh stamps the ledger inside the
# same tick" explanation of `-ge` wrong.
reset
printf 'hash\n%s\n12=OPEN;\n' "$NOW" > "$H/state/$P.queuefp"
echo merged > "$T/pr-state"        # would move the row if the refresh ran
lib tick
[ "$(npulls)" = 0 ] && ok \
  || bad "(1) the same tick's refresh must not re-read a row ingest just stamped (pulls: $(npulls))"
[ "$(led)" = "$(printf '12\tOPEN\t%s' "$NOW")" ] && ok \
  || bad "(1) the ingested pair must keep the GATE's epoch and its state (ledger: $(led))"

# ═══ (2) NEGATIVE CONTROL: an aged row IS refreshed ═════════════════════════
# Proves the stub reader is live and reachable — without this, case (1) would
# pass on a refresh that never works at all.
reset
printf '12\tOPEN\t%s\n' "$(( NOW - 4000 ))" > "$H/state/$P.prstates"
echo merged > "$T/pr-state"
lib tick
[ "$(npulls)" = 1 ] && ok \
  || bad "(2) an OPEN row past the TTL needs exactly one lookup (pulls: $(npulls))"
[ "$(lib triage_prstates_get "$H" "$P" 12)" = MERGED ] && ok \
  || bad "(2) the refreshed value must reach the ledger (ledger: $(led))"

# ═══ (3) ABSENT IS NOT TERMINAL ═════════════════════════════════════════════
# A cached 404 is re-read once per TTL exactly like an OPEN, so a queue line
# naming a PR before it exists heals on its own. Only MERGED and CLOSED are on
# the refresh's skip list.
reset
printf '12\tABSENT\t%s\n' "$(( NOW - 4000 ))" > "$H/state/$P.prstates"
echo 404 > "$T/pr-state"
lib triage_prstates_refresh "$H" "$P" "$H/units"
[ "$(npulls)" = 1 ] && ok \
  || bad "(3) an ABSENT row past the TTL must be re-read once, not skipped as terminal (pulls: $(npulls))"
[ "$(lib triage_prstates_get "$H" "$P" 12)" = ABSENT ] && ok \
  || bad "(3) a 404 stays cached as ABSENT (ledger: $(led))"
[ "$(ledts 12)" -ge "$NOW" ] && ok \
  || bad "(3) the re-read must restamp the ABSENT row (stamp $(ledts 12), expected >= $NOW)"
lib triage_prstates_refresh "$H" "$P" "$H/units"
[ "$(npulls)" = 1 ] && ok \
  || bad "(3) a FRESH ABSENT row is quiet for a TTL — no second lookup (pulls: $(npulls))"
# Contrast: a terminal row that old costs nothing at all.
reset
printf '12\tMERGED\t%s\n' "$(( NOW - 4000 ))" > "$H/state/$P.prstates"
lib triage_prstates_refresh "$H" "$P" "$H/units"
[ "$(npulls)" = 0 ] && ok \
  || bad "(3) MERGED is terminal — an aged one is never re-read (pulls: $(npulls))"

# ═══ (4) THE RECORD SAYS WHAT THE CODE DOES ═════════════════════════════════
LIBF="$DIR/bin/lib/triage-shards-lib.sh"
MAPF="$DIR/docs/verification-map/triage-shard-ticket-fp.md"
T1079="$DIR/tests/triage-shards-prstates.bh-1079-test.sh"
NOTEF="$DIR/docs/notes/2026-09-22-BH-1332-prstates-record-corrections.md"
OLDNOTE="$DIR/docs/notes/2026-09-19-BH-1079-prstates-consume-and-epoch.md"

for f in "$LIBF" "$MAPF" "$T1079" "$NOTEF" "$OLDNOTE"; do
  [ -f "$f" ] && ok || bad "(4) record surface is missing: $f"
done

# The wrong mechanism is gone from all three surfaces that carried it.
for f in "$LIBF" "$MAPF" "$T1079"; do
  if [ -f "$f" ] && ! grep -q 'refresh stamps the ledger' "$f"; then ok
  else bad "(4) $(basename "$f") still explains -ge with 'refresh stamps the ledger'"; fi
done

# The rule itself is unchanged: not-older, not strictly-newer.
if [ -f "$LIBF" ] && grep -q '"\$ep" -ge "\$old"' "$LIBF"; then ok
else bad "(4) the ingest comparator must still be -ge (this ticket changes no behaviour)"; fi

# The new dated note (D37: a correction to a merged note is a LATER note).
if [ -f "$NOTEF" ] && head -1 "$NOTEF" | grep -q '^# '; then ok
else bad "(4) the new note needs a '# ' title line"; fi
for pat in '^Doc: EVENTS' 'gh_rest_pr_state' '45'; do
  if [ -f "$NOTEF" ] && grep -q "$pat" "$NOTEF"; then ok
  else bad "(4) the new note must carry $pat"; fi
done

# ABSENT is called out on the map page, where someone would otherwise add it to
# the refresh's skip list by mistake.
if [ -f "$MAPF" ] && grep -qi 'ABSENT.*not terminal' "$MAPF"; then ok
else bad "(4) the map page must say ABSENT is not terminal"; fi

# D37 the other way: the merged 2026-09-19 note is never edited.
if [ -f "$OLDNOTE" ] && grep -q 'Not \*strictly newer\*' "$OLDNOTE"; then ok
else bad "(4) docs/notes/2026-09-19-BH-1079-prstates-consume-and-epoch.md must be left byte-identical"; fi

echo "prstates-record.bh-1332: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
