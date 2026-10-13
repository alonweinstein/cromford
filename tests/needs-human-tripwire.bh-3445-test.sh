#!/bin/bash
# tests/needs-human-tripwire.bh-3445-test.sh — the same-finding tripwire
# (BH-3445, slice 3 of BH-3433): bin/lib/needs-human/trip.sh.
#   N  nh_trip_note counts distinct REVIEW_BLOCKED builds per (project, issue, fp)
#   D  the same build id never counts twice (a resumed build)
#   U  an unreadable ledger (read outage, put outage, malformed row, no client)
#      is rc 2: never counted, never trips, logged
#   K  the threshold is the settings row lib.needs-human.needs_human_trip_count
#   T  the fp comes from the final round's NEEDS_HUMAN: action, else its BLOCK
#      headlines; neither gives fp:none and no ledger call
#   F  only the final round of an appended review.md feeds the fp
#   H  a trip places the hold (source tripwire) and writes one TRIPWIRE alert
#   S  the needs-human-hold-off switch skips the hold, the alert says so
#   E  LENS_REFUSE review cut from the flattened pipeline, twice: the terminal
#      is unchanged and the second one trips
#   C  no cost read, no network, no /root/harness literal
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

LIB="$DIR/bin/lib/needs-human.sh"
TRIP="$DIR/bin/lib/needs-human/trip.sh"

# ── scratch root: the lib, lane-gate, lane-switch, and stubs at rooted paths ──
H="$T/h"
mkdir -p "$H/bin/lib/needs-human" "$H/logs" "$H/flags" "$H/state" "$T/bin" "$T/ledger"
cp "$LIB" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lane-switch.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/needs-human/"*.sh "$H/bin/lib/needs-human/"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.log"\nexit 0\n' "$T" > "$H/bin/alert-line.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/placer.log"\nexit "${PLACER_RC:-0}"\n' "$T" > "$H/bin/needs-human-hold.sh"
chmod +x "$H/bin/alert-line.sh" "$H/bin/needs-human-hold.sh"
for s in gh gh_rest curl jobs; do
  printf '#!/bin/bash\n: > "%s/called.%s"\nexit 1\n' "$T" "$s" > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
export PATH="$T/bin:$PATH"
bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "lanes-build failed"; exit 1; }
export LANE_REGISTRY="$T/lanes.json"
unset NEEDS_HUMAN_TRIP_COUNT LANE_GATE_DISABLE NH_SLUG NH_ISSUE

# rows <key=value>... — a FRESH settings cache holding exactly those rows.
rows() {
  local v='{}' kv
  for kv in "$@"; do v=$(jq -c --arg k "${kv%%=*}" --arg x "${kv#*=}" '. + {($k): $x}' <<<"$v"); done
  scratch_rm "$H/state/lane-gate"
  jq -nc --argjson fa "$NOW" --argjson v "$v" '{fetched_at:$fa, values:$v, seeded:{}}' \
    > "$H/state/settings-cache.json"
}
rows

# The fake D1 ledger: file-backed, every call recorded.
lf() { printf '%s' "$1|$2" | sha1sum | cut -c1-40; }
job_ledger_row() {
  echo "job_ledger_row $1 $2" >> "$T/ledger.calls"
  [ -n "${LEDGER_READ_RC:-}" ] && return "$LEDGER_READ_RC"
  local f; f="$T/ledger/$(lf "$1" "$2").json"
  [ -r "$f" ] || return 2
  jq -c '{status, detail}' "$f"
}
job_ledger_put() {
  echo "job_ledger_put $1 $2" >> "$T/ledger.calls"
  [ -n "${LEDGER_PUT_RC:-}" ] && return "$LEDGER_PUT_RC"
  jq -nc --arg s "$3" --arg d "${4:-}" '{status:$s, detail:$d}' > "$T/ledger/$(lf "$1" "$2").json"
}
# row <key> — "<status>|<detail>" of a review_block_fp row, or "none"
row() { local f; f="$T/ledger/$(lf review_block_fp "$1").json"; [ -r "$f" ] && jq -r '.status + "|" + .detail' "$f" || echo none; }
seed() { jq -nc --arg s "$2" --arg d "$3" '{status:$s, detail:$d}' > "$T/ledger/$(lf review_block_fp "$1").json"; }
puts() { grep -c '^job_ledger_put ' "$T/ledger.calls" 2>/dev/null || true; }
reset() { rm -f "$T/ledger/"*.json "$T/ledger.calls" "$T/alerts.log" "$T/placer.log" "$H/logs/needs-human.log"; }

export HARNESS="$H"
# shellcheck disable=SC1090
. "$H/bin/lib/needs-human.sh"

# ── N: note ────────────────────────────────────────────────────────────────
reset
nh_trip_note p 7 aaaaaaaaaaaa b1; RC=$?
[ "$RC" = 1 ] && [ "$(row 'p#7#aaaaaaaaaaaa')" = '1|["b1"]' ] && ok || bad "N1: rc $RC row '$(row 'p#7#aaaaaaaaaaaa')'"
nh_trip_note p 7 aaaaaaaaaaaa b2; RC=$?
[ "$RC" = 0 ] && [ "$(row 'p#7#aaaaaaaaaaaa')" = '2|["b1","b2"]' ] && ok || bad "N2: rc $RC row '$(row 'p#7#aaaaaaaaaaaa')'"
nh_trip_note p 7 bbbbbbbbbbbb b3; RC=$?
[ "$RC" = 1 ] && ok || bad "N3: a different fp on the same issue gave rc $RC"
nh_trip_note p 70 aaaaaaaaaaaa b3; RC=$?
[ "$RC" = 1 ] && ok || bad "N4: the same fp on another issue gave rc $RC"

# ── D: dedup ───────────────────────────────────────────────────────────────
reset
nh_trip_note p 8 cccccccccccc b1; R1=$?
nh_trip_note p 8 cccccccccccc b1; R2=$?
[ "$R1" = 1 ] && [ "$R2" = 1 ] && [ "$(row 'p#8#cccccccccccc')" = '1|["b1"]' ] && [ "$(puts)" = 1 ] \
  && ok || bad "D1: rc $R1/$R2 row '$(row 'p#8#cccccccccccc')' puts $(puts)"

# ── U: unreadable ──────────────────────────────────────────────────────────
reset
LEDGER_READ_RC=1 nh_trip_note p 9 dddddddddddd b1; RC=$?
[ "$RC" = 2 ] && [ "$(puts)" = 0 ] && grep -q 'ledger unreadable' "$H/logs/needs-human.log" 2>/dev/null \
  && ok || bad "U1: rc $RC puts $(puts) log '$(cat "$H/logs/needs-human.log" 2>/dev/null)'"
printf '### 1. BLOCK — the retry loop is unbounded\nVERDICT: BLOCK\n' > "$T/u.md"
FP=$(nh_fingerprint "1. BLOCK — the retry loop is unbounded")
seed "p#9#$FP" 1 '["b1"]'
OUT=$(LEDGER_READ_RC=1 nh_trip_on_block p 9 "$T/u.md" b2); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$T/alerts.log" ] && [ ! -e "$T/placer.log" ] \
  && ok || bad "U1: on_block with an unreadable ledger rc $RC out '$OUT' alerted/placed"
reset; seed 'p#9#eeeeeeeeeeee' 1 '["b1"]'
LEDGER_PUT_RC=1 nh_trip_note p 9 eeeeeeeeeeee b2; RC=$?
[ "$RC" = 2 ] && ok || bad "U2: a failed put gave rc $RC"
reset; seed 'p#9#ffffffffffff' 3 'not json'
nh_trip_note p 9 ffffffffffff b2; RC=$?
[ "$RC" = 2 ] && [ "$(row 'p#9#ffffffffffff')" = '3|not json' ] && [ "$(puts)" = 0 ] \
  && ok || bad "U3: malformed detail rc $RC row '$(row 'p#9#ffffffffffff')'"
reset; seed 'p#9#ffffffffffff' 1 '[1,2]'
nh_trip_note p 9 ffffffffffff b2; RC=$?
[ "$RC" = 2 ] && [ "$(puts)" = 0 ] && ok || bad "U3: a non-string array gave rc $RC"
reset
OUT=$(unset -f job_ledger_row; nh_trip_note p 9 aaaaaaaaaaaa b1; echo "rc=$?")
[ "$OUT" = "rc=2" ] && ok || bad "U4: no jobs client gave '$OUT'"
reset
nh_trip_note p 9 aaaaaaaaaaaa b1; RC=$?
[ "$RC" = 1 ] && [ "$(row 'p#9#aaaaaaaaaaaa')" = '1|["b1"]' ] && ok || bad "U5: no row (rc 2) gave rc $RC"

# ── K: knob ────────────────────────────────────────────────────────────────
reset; rows lib.needs-human.needs_human_trip_count=3
nh_trip_note p 10 aaaaaaaaaaaa b1; R1=$?
nh_trip_note p 10 aaaaaaaaaaaa b2; R2=$?
nh_trip_note p 10 aaaaaaaaaaaa b3; R3=$?
[ "$R1$R2$R3" = 110 ] && ok || bad "K1: row 3 gave rc $R1 $R2 $R3, want 1 1 0"
reset; rows lib.needs-human.needs_human_trip_count=1
nh_trip_note p 10 aaaaaaaaaaaa b1; R1=$?
nh_trip_note p 10 aaaaaaaaaaaa b2; R2=$?
[ "$R1$R2" = 10 ] && ok || bad "K2: row 1 gave rc $R1 $R2, want 1 0 (clamped to 2)"
reset; rows
( export NEEDS_HUMAN_TRIP_COUNT=1
  nh_trip_note p 10 aaaaaaaaaaaa b1; R1=$?
  nh_trip_note p 10 aaaaaaaaaaaa b2; R2=$?
  [ "$R1$R2" = 10 ] ) && grep -q 'NEEDS_HUMAN_TRIP_COUNT=1 .*clamped to 2' "$H/logs/needs-human.log" 2>/dev/null \
  && ok || bad "K2: env 1 was not clamped and logged: $(cat "$H/logs/needs-human.log" 2>/dev/null)"
reset; rows
nh_trip_note p 11 aaaaaaaaaaaa b1; R1=$?
nh_trip_note p 11 aaaaaaaaaaaa b2; R2=$?
[ "$R1$R2" = 10 ] && ok || bad "K3: no row, no env gave rc $R1 $R2, want the default 2"

# ── T: fingerprint source ──────────────────────────────────────────────────
export NH_SLUG=o/r
# two_builds <md> [action] — note the same review.md for builds b1 and b2
two_builds() { nh_trip_on_block p 12 "$1" b1 ${2:+"$2"}; nh_trip_on_block p 12 "$1" b2 ${2:+"$2"}; }
placed_fp() { awk 'NR==1{print $3}' "$T/placer.log" 2>/dev/null; }
cat > "$T/t1.md" <<'EOF'
## Review

### 1. BLOCK — the vs_publish probe was never run
### 2. BLOCK — the PR body claims a live probe

NEEDS_HUMAN: run the vs_publish probe from the hub

TIER: 2
VERDICT: BLOCK
EOF
WANT=$(nh_fingerprint "run the vs_publish probe from the hub")
reset; two_builds "$T/t1.md"
[ -n "$WANT" ] && [ "$(placed_fp)" = "$WANT" ] && ok || bad "T1: action fp '$(placed_fp)', want '$WANT'"
grep -v '^NEEDS_HUMAN:' "$T/t1.md" > "$T/t2.md"
reset; two_builds "$T/t2.md" "run the vs_publish probe from the hub"
[ "$(placed_fp)" = "$WANT" ] && ok || bad "T2: arg-5 fp '$(placed_fp)', want '$WANT'"
WANT=$(nh_fingerprint "$(printf '%s\n' "1. BLOCK — the vs_publish probe was never run" "2. BLOCK — the PR body claims a live probe")")
reset; two_builds "$T/t2.md"
[ -n "$WANT" ] && [ "$(placed_fp)" = "$WANT" ] && ok || bad "T3: headline fp '$(placed_fp)', want '$WANT'"
sed -e 's/^### 1\./### 9./; s/^### 2\./### 1./; s/^### 9\./### 2./' "$T/t2.md" > "$T/t3.md"
reset; nh_trip_on_block p 12 "$T/t2.md" b1; nh_trip_on_block p 12 "$T/t3.md" b2
[ "$(placed_fp)" = "$WANT" ] && ok || bad "T3: renumbered headlines did not trip on the same fp: '$(placed_fp)'"
printf '## Review\nsee NEEDS_HUMAN: run the probe\nNEEDS-HUMAN: set the env\nVERDICT: BLOCK\n' > "$T/t4.md"
reset; OUT=$(nh_trip_on_block p 12 "$T/t4.md" b1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$T/ledger.calls" ] && grep -q 'fp:none (b1)' "$H/logs/needs-human.log" \
  && ok || bad "T4/T5: no headline and no field rc $RC, ledger calls '$(cat "$T/ledger.calls" 2>/dev/null)'"

# ── F: final round ─────────────────────────────────────────────────────────
# Round one's finding and its NEEDS_HUMAN action were fixed; round two blocks
# on something else. Re-reviews are appended, so both rounds are in the file.
cat > "$T/f2.md" <<'EOF'
## Review
### 1. BLOCK — old thing in the retry loop
NEEDS_HUMAN: an action only round one asked for
TIER: 2
VERDICT: BLOCK

## Re-review
### 1. BLOCK — new thing in the migration
### 4. Gap — nothing asserts the empty state
### 5. Minor — not blocking
### 6. non-blocking nit about naming
TIER: 2
VERDICT: BLOCK
EOF
WANT=$(nh_fingerprint "1. BLOCK — new thing in the migration")
reset; two_builds "$T/f2.md"
[ -n "$WANT" ] && [ "$(placed_fp)" = "$WANT" ] && ok || bad "F1: final-round fp '$(placed_fp)', want '$WANT' (new thing only)"
grep -q 'new thing in the migration tripwire$' "$T/placer.log" 2>/dev/null && ok || bad "F1: the headline is not the placer action: $(cat "$T/placer.log" 2>/dev/null)"

# ── H: trip actions ────────────────────────────────────────────────────────
printf '## Review\n### 1. BLOCK — the retry loop is unbounded\nTIER: 2\nVERDICT: BLOCK\n' > "$T/h.md"
FP=$(nh_fingerprint "1. BLOCK — the retry loop is unbounded")
reset
O1=$(nh_trip_on_block p 9 "$T/h.md" b1); R1=$?
[ ! -e "$T/alerts.log" ] && [ ! -e "$T/placer.log" ] && ok || bad "H1: the first block alerted or placed"
O2=$(nh_trip_on_block p 9 "$T/h.md" b2); R2=$?
[ "$(wc -l < "$T/alerts.log" 2>/dev/null)" = 1 ] \
  && grep -qF -- "--project p --id nh-trip:p#9#$FP [needs-human] TRIPWIRE p#9: 2 REVIEW_BLOCKED builds on the same finding (fp $FP), paused for diagnosis — https://github.com/o/r/issues/9" "$T/alerts.log" \
  && ok || bad "H1: alert '$(cat "$T/alerts.log" 2>/dev/null)'"
[ "$(cat "$T/placer.log" 2>/dev/null)" = "p 9 $FP pause-and-diagnose: the same review finding blocked 2 builds: 1. BLOCK — the retry loop is unbounded tripwire" ] \
  && ok || bad "H1: placer '$(cat "$T/placer.log" 2>/dev/null)'"
grep -q "TRIPPED fp $FP count 2 source headlines placer rc 0" "$H/logs/needs-human.log" && ok || bad "H1: no TRIPPED log line"
reset
nh_trip_on_block p 9 "$T/h.md" b1
O3=$(PLACER_RC=1 nh_trip_on_block p 9 "$T/h.md" b2); R3=$?
grep -qF "(fp $FP), hold NOT placed (placer rc 1) — https://github.com/o/r/issues/9" "$T/alerts.log" 2>/dev/null \
  && ! grep -q paused "$T/alerts.log" && ok || bad "H2: placer failure alert '$(cat "$T/alerts.log" 2>/dev/null)'"
[ "$R1$R2$R3" = 000 ] && [ -z "$O1$O2$O3" ] && ok || bad "H3: rc $R1 $R2 $R3 stdout '$O1$O2$O3'"
reset
OUT=$(nh_trip_on_block p "" "$T/h.md" b1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$T/ledger.calls" ] && grep -q 'not an issues board' "$H/logs/needs-human.log" \
  && ok || bad "H4: empty issue rc $RC, ledger '$(cat "$T/ledger.calls" 2>/dev/null)'"
# No NH_SLUG and no git remote: the alert names the issue number only.
reset
( unset NH_SLUG; cd "$T" && nh_trip_on_block p 9 "$T/h.md" b1 && nh_trip_on_block p 9 "$T/h.md" b2 )
grep -qF "paused for diagnosis — issue #9" "$T/alerts.log" 2>/dev/null && ok || bad "H5: slug-less alert '$(cat "$T/alerts.log" 2>/dev/null)'"
# No root at all: nothing rooted is called, the log goes to stderr.
reset
ERR=$( ( unset HARNESS H; nh_trip_on_block p 9 "$T/h.md" b1; nh_trip_on_block p 9 "$T/h.md" b2 ) 2>&1 >/dev/null )
[ ! -e "$T/alerts.log" ] && [ ! -e "$T/placer.log" ] && [[ "$ERR" == *"trip: p#9: TRIPPED"* ]] \
  && ok || bad "H6: rootless trip called a rooted path or logged nothing: '$ERR'"

# ── S: the switch ──────────────────────────────────────────────────────────
reset; touch "$H/flags/needs-human-hold-off"
( export LANE_GATE_DISABLE=1; nh_trip_on_block p 9 "$T/h.md" b1; nh_trip_on_block p 9 "$T/h.md" b2 )
[ ! -e "$T/placer.log" ] && [ "$(wc -l < "$T/alerts.log" 2>/dev/null)" = 1 ] \
  && grep -qF "(fp $FP), NOT paused: needs-human-hold-off is on — https://github.com/o/r/issues/9" "$T/alerts.log" \
  && grep -q 'hold switch needs-human-hold-off on, no hold placed' "$H/logs/needs-human.log" \
  && ok || bad "S1: switch on: placer '$(cat "$T/placer.log" 2>/dev/null)' alert '$(cat "$T/alerts.log" 2>/dev/null)'"
rm -f "$H/flags/needs-human-hold-off"

# ── E: LENS_REFUSE review, cut from the flattened pipeline ─────────────────
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
cut_block() { awk -v n="$1" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' "$RB_ALL" > "$2"; }
cut_fn() { awk -v f="$1" 'index($0, f "() {")==1{p=1} p{print} p&&/^}/{exit}' "$RB_ALL"; }
cut_block "stage lane verdict" "$T/lane.sh"
{ cut_fn LENS_ART; cut_fn LENS_VARS; cut_fn LENS_REFUSE; } > "$T/lens.sh"
[ -s "$T/lane.sh" ] && grep -q 'nh_trip_on_block' "$T/lens.sh" && ok || bad "E0: could not extract LENS_REFUSE with its trip hook"
DRIVE() { # DRIVE <build-dir>
  local B="$1"
  ( BUILD="$B"; PROJECT=p; KEY=BH-3348; BASE=main; BRANCH=ticket/bh-3348
    REVIEW_MODEL=m; FIX_MODEL=m; RISKY=1; HIGHRISK=1; NH_ISSUE=3348; NH_SLUG=o/r
    STAMP() { echo 2026-09-29T00:00:00Z; }
    RESULT() { echo "$*" > "$B/RESULT"; }
    BB() { :; }
    # shellcheck disable=SC1090
    . "$T/lane.sh"; . "$T/lens.sh"
    LENS_REFUSE review ) >/dev/null 2>"$B/stderr"
  echo "$? $(cat "$B/RESULT" 2>/dev/null || echo none)"
}
reset
for b in lb1 lb2; do mkdir -p "$T/$b"; cp "$T/h.md" "$T/$b/review.md"; done
OUT=$(DRIVE "$T/lb1")
[ "$OUT" = "6 REVIEW_BLOCKED $T/lb1/review.md" ] && [ ! -e "$T/alerts.log" ] && ok || bad "E1: first block '$OUT' alerts '$(cat "$T/alerts.log" 2>/dev/null)'"
OUT=$(DRIVE "$T/lb2")
[ "$OUT" = "6 REVIEW_BLOCKED $T/lb2/review.md" ] && ok || bad "E2: second block changed the terminal: '$OUT'"
[ "$(grep -c 'TRIPWIRE p#3348: 2 REVIEW_BLOCKED' "$T/alerts.log" 2>/dev/null)" = 1 ] \
  && [ "$(grep -c ' tripwire$' "$T/placer.log" 2>/dev/null)" = 1 ] \
  && [ "$(row "p#3348#$FP")" = '2|["lb1","lb2"]' ] \
  && ok || bad "E2: no trip: alerts '$(cat "$T/alerts.log" 2>/dev/null)' placer '$(cat "$T/placer.log" 2>/dev/null)' row '$(row "p#3348#$FP")'"

# ── C: no cost, no network, no root literal ────────────────────────────────
[ -z "$(awk '{print $1, $2}' "$T/ledger.calls" 2>/dev/null | grep -v '^job_ledger_\(row\|put\) review_block_fp$')" ] \
  && ok || bad "C1: a ledger call outside review_block_fp: $(cat "$T/ledger.calls")"
[ -z "$(find "$T" -maxdepth 1 -name 'called.*')" ] && ok || bad "C2: a network stub was called: $(ls "$T"/called.* 2>/dev/null)"
[ "$(grep -v '^[[:space:]]*#' "$TRIP" | grep -Eic 'cost|usd|\$[0-9]+\.[0-9]')" = 0 ] && ok || bad "C3: trip.sh reads a cost field or a dollar amount"
[ "$(grep -c '/root/harness' "$TRIP")" = 0 ] && ok || bad "C4: trip.sh carries a /root/harness literal (D43)"
[ -z "$(find "$T" -name ALERTS.log)" ] && ok || bad "C5: an ALERTS.log was written directly"

echo "needs-human-tripwire: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
