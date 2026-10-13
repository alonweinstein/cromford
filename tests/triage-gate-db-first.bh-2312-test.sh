#!/bin/bash
# tests/triage-gate-db-first.bh-2312-test.sh — THE GATE WAKES FOR A REMOTE
# RESULT THE LEDGER HOLDS AND THIS BOX HAS NOT STAGED (BH-2350, slice 4 of
# BH-2312).
#
# bin/triage-gate.sh section 3b reads bor_list for the project. A row built on
# another box, with no local dir, no .handled/<job>.job marker and newer than
# staging's .since watermark, answers `RUN remote-results-pending` so the tick's
# staging (bin/lib/rt/staging.sh) pulls it. The set is fingerprinted into
# state/<p>.remotefp with sweepfp's 45-minute brake.
#
# Driven, not grepped: the REAL gate and the REAL bin/lib/builds-of-record.sh.
# The stub is bin/jobs-client.sh, whose job_artifact_feed answers from fixture
# TSV (with the worker's strict `since` and the limit), and a fake gh board as in
# tests/triage-gate-ledger.bh-2318-test.sh, seeded so the gate otherwise SKIPs.
#
#   G1 remote row -> RUN, remotefp written, nothing staged by the gate
#   G2 same set within 45m -> the board's own SKIP
#   G3 new row -> RUN; same set, stamp 46m old -> RUN
#   G4 own-box row -> no RUN
#   G5 feed outage / empty feed -> no RUN, no remotefp
#   G6 .handled marker / at-or-below .since / pool- dir -> no RUN
#   G7 JOBS_BOX unset -> no RUN
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-gate-db-first.bh-2312-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }
unset FULL_SWEEP_SECS TRIAGE_FAIL_CONSUME_AFTER JOBS_BOX
P=boardA
FEED="$T/feed"
mkdir -p "$FEED" "$T/fakebin" "$T/stub"

# ── the stub client: a fixture feed, no ledger twin ──────────────────────────
cat > "$T/stub/jobs-client.sh" <<'SH'
job_ledger_get() { return 2; }
job_ledger_put() { return 0; }
flag_active() { [ -f "${HARNESS:-/nonexistent}/flags/$1" ]; }
job_artifact_feed() {
  echo "FEED $1 $2 since=${3:-} limit=${4:-}" >> "$FEED/calls"
  [ -f "$FEED/down" ] && return 1
  [ -f "$FEED/$1" ] || return 0
  awk -F'\t' -v s="${3:-}" -v n="${4:-100}" '(s == "" || $5 > s) && c < n { print; c++ }' "$FEED/$1"
}
SH

H="$T/h"
mkdir -p "$H/bin" "$H/state" "$H/flags" "$H/logs" "$H/env" "$H/builds"
cp "$T/stub/jobs-client.sh" "$H/bin/jobs-client.sh"
cp "$DIR/bin/triage-gate.sh" "$H/bin/triage-gate.sh"
cp -r "$DIR/bin/lib" "$H/bin/lib"
cat > "$H/bin/fleet-conf.sh" <<'SH'
case "${2:-}" in board_prefix) echo "-" ;; repo) echo "o/r" ;; *) exit 1 ;; esac
SH
printf '#!/bin/sh\nexit 0\n' > "$H/bin/lane-alert.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/decision-log.sh"
chmod +x "$H/bin/"*.sh

# fake gh: an unchanging ai-build issue list and no PRs.
cat > "$T/fakebin/gh" <<'SH'
[ "${1:-}" = api ] || exit 1
shift; P=""
while [ $# -gt 0 ]; do case "$1" in -i) shift ;; -X|-f|-F|-H) shift 2 ;; -*) shift ;; *) P="$1"; break ;; esac; done
case "$P" in
  repos/o/r/issues/*/comments*) BODY='[]' ;;
  repos/o/r/issues*) BODY='[{"number":7,"state":"open","title":"Add sort","comments":1,"updated_at":"2026-09-24T11:00:00Z","body":"b","labels":[{"name":"ai-build"}],"assignees":[],"milestone":null}]' ;;
  repos/o/r/pulls*)  BODY='[]' ;;
  *) exit 1 ;;
esac
printf 'HTTP/2.0 200\r\n\r\n%s\n' "$BODY"
SH
chmod +x "$T/fakebin/gh"

# gate — the real gate, JOBS_BOX=hub unless NOBOX=1.
gate() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FEED="$FEED"
    [ "${NOBOX:-0}" = 1 ] || export JOBS_BOX=hub
    "$H/bin/triage-gate.sh" "$P" "$@" 2>>"$T/err.txt" )
}
TAB=$'\t'
# row <job> <box> <updated_at> <build_dir> <key> — one `result` feed line.
row() { printf '%s\tPR_CREATED https://github.com/o/r/pull/%s\t%s\t-\t%s\t{"build_dir":"%s","key":"%s"}\n' "$1" "${1#J}" "$2" "$3" "$4" "$5"; }
reset() {
  scratch_rm "$FEED"; scratch_rm "$H/builds"; scratch_rm "$H/state/remote-results"
  scratch_rm "$H/state/$P.remotefp"
  mkdir -p "$FEED" "$H/builds"
}
builds_snapshot() { ls -A "$H/builds" | sort; }

OUT=$(gate --seed); grep -q '^SEEDED' <<<"$OUT" && ok || bad "setup: seed '$OUT' err=$(tail -3 "$T/err.txt")"
OUT=$(gate); [ "${OUT%% *}" = SKIP ] && ok || bad "setup: an empty ledger must SKIP, got '$OUT'"
BASE_SKIP="$OUT"

# ═════════════════════════════════════════════════════════════════════════════
# G1 / G2 / G3 — wake, hold, wake again
# ═════════════════════════════════════════════════════════════════════════════
reset
row J1 w2 2026-09-25T10:00:00.000Z "$P-BH-1-a" BH-1 > "$FEED/result"
BEFORE=$(builds_snapshot)
OUT=$(gate)
[ "$OUT" = "RUN remote-results-pending" ] && ok || bad "G1: a remote row with no local dir must RUN, got '$OUT'"
[ -s "$H/state/$P.remotefp" ] && [ "$(wc -l < "$H/state/$P.remotefp")" = 2 ] && ok \
  || bad "G1: state/$P.remotefp must hold fp and epoch: '$(cat "$H/state/$P.remotefp" 2>/dev/null)'"
[ "$(builds_snapshot)" = "$BEFORE" ] && ok || bad "G1: the gate staged something itself: $(builds_snapshot)"
grep -q "FEED result $P since= limit=50" "$FEED/calls" 2>/dev/null && ok || bad "G1: the result feed was not read with staging's window: $(cat "$FEED/calls" 2>/dev/null)"

OUT=$(gate)
[ "$OUT" = "$BASE_SKIP" ] && ok || bad "G2: the same set within 45m must fall through to the board's '$BASE_SKIP', got '$OUT'"

row J2 w3 2026-09-25T11:00:00.000Z "$P-BH-2-a" BH-2 >> "$FEED/result"
OUT=$(gate)
[ "$OUT" = "RUN remote-results-pending" ] && ok || bad "G3: a new remote row must RUN again, got '$OUT'"
OUT=$(gate); [ "$OUT" = "$BASE_SKIP" ] && ok || bad "G3: held again after the new set, got '$OUT'"
printf '%s\n%s\n' "$(head -1 "$H/state/$P.remotefp" 2>/dev/null)" "$(( $(date +%s) - 2760 ))" > "$H/state/$P.remotefp"
OUT=$(gate)
[ "$OUT" = "RUN remote-results-pending" ] && ok || bad "G3: the same set 46m later must RUN again, got '$OUT'"

# ═════════════════════════════════════════════════════════════════════════════
# G4 — own-box rows never wake
# ═════════════════════════════════════════════════════════════════════════════
reset
row J1 hub 2026-09-25T10:00:00.000Z "$P-BH-1-a" BH-1 > "$FEED/result"
OUT=$(gate); [ "$OUT" = "$BASE_SKIP" ] && ok || bad "G4: an own-box row must not RUN, got '$OUT'"

# ═════════════════════════════════════════════════════════════════════════════
# G5 — outage, empty feed
# ═════════════════════════════════════════════════════════════════════════════
reset
row J1 w2 2026-09-25T10:00:00.000Z "$P-BH-1-a" BH-1 > "$FEED/result"
: > "$FEED/down"
OUT=$(gate); [ "$OUT" = "$BASE_SKIP" ] && ok || bad "G5: a feed outage must not RUN, got '$OUT'"
[ -e "$H/state/$P.remotefp" ] && bad "G5: an outage must not write remotefp" || ok
reset
OUT=$(gate); [ "$OUT" = "$BASE_SKIP" ] && ok || bad "G5: an empty feed must not RUN, got '$OUT'"

# ═════════════════════════════════════════════════════════════════════════════
# G6 — already staged, below the watermark, or a local copy
# ═════════════════════════════════════════════════════════════════════════════
reset
row J1 w2 2026-09-25T10:00:00.000Z "$P-BH-1-a" BH-1 > "$FEED/result"
mkdir -p "$H/state/remote-results/$P/.handled"; : > "$H/state/remote-results/$P/.handled/J1.job"
OUT=$(gate); [ "$OUT" = "$BASE_SKIP" ] && ok || bad "G6: a .handled job must not RUN, got '$OUT'"
reset
row J1 w2 2026-09-25T10:00:00.000Z "$P-BH-1-a" BH-1 > "$FEED/result"
mkdir -p "$H/state/remote-results/$P"; printf '2026-09-25T10:00:00.000Z' > "$H/state/remote-results/$P/.since"
OUT=$(gate); [ "$OUT" = "$BASE_SKIP" ] && ok || bad "G6: a row at the .since watermark must not RUN, got '$OUT'"
grep -q "since=2026-09-25T10:00:00.000Z limit=50" "$FEED/calls" 2>/dev/null && ok || bad "G6: .since was not passed to the feed: $(cat "$FEED/calls" 2>/dev/null)"
reset
row J1 w2 2026-09-25T10:00:00.000Z "$P-BH-1-a" BH-1 > "$FEED/result"
mkdir -p "$H/builds/pool-$P-BH-1-a"
OUT=$(gate); [ "$OUT" = "$BASE_SKIP" ] && ok || bad "G6: a row with a pool- local dir must not RUN, got '$OUT'"

# ═════════════════════════════════════════════════════════════════════════════
# G7 — no box name, no way to tell own rows apart
# ═════════════════════════════════════════════════════════════════════════════
reset
row J1 w2 2026-09-25T10:00:00.000Z "$P-BH-1-a" BH-1 > "$FEED/result"
OUT=$(NOBOX=1 gate); [ "$OUT" = "$BASE_SKIP" ] && ok || bad "G7: JOBS_BOX unset must not RUN, got '$OUT'"

echo "triage-gate-db-first: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
