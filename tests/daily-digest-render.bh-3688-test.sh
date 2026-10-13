#!/bin/bash
# tests/daily-digest-render.bh-3688-test.sh — BH-3707 (BH-3688.4): the
# daily-digest renderer, bin/lib/daily-digest-render.sh.
#
# Sources the real lib and calls dd_render against the contract fixtures
# (tests/fixtures/daily-digest/*.json) and jq variants of them, with the console
# base https://console.test. Pinned inputs only: no clock read anywhere.
#
#   D1-text  fixture-day: every section in order, the approve command, the
#            protected-paths line, $/merged PR, the factory stop.
#   D2-text  empty-day: `Nothing happened on <D>.`, every counter 0 (target 0).
#   R1       every numeric line carries the console base.
#   R2       spend ok:false is `n/a (read failed: ...)`, never $0; R2b all unpriced.
#   R4       lists cut at max-items with `+N more`.
#   R5       every URL path matches a ROUTES pattern of console-ui/src/app.js.
#   R6       `<`, `>` and `&` are stripped from every interpolated value.
#   B1       dd_spotcheck_bucket == lrl_spotcheck's expression; B2 sampling off.
#   L1       lead precision from the file, no fallback to an older one.
#   U1       the summary sits right under the header.
#   F1       the factory variants.
#   A1       the frozen signature's failure codes.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/daily-digest-render.bh-3688-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "daily-digest-render: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

RENDER="$DIR/bin/lib/daily-digest-render.sh"
FIX="$DIR/tests/fixtures/daily-digest/fixture-day.json"
EMPTY="$DIR/tests/fixtures/daily-digest/empty-day.json"
APP="$DIR/console-ui/src/app.js"
LRL="$DIR/bin/lead-review-land.sh"
C=https://console.test
DORA="$C/dora?days=1"  # determinism: ok the link text dd_render prints, compared as a string; no request is made and no clock is read
for f in "$RENDER" "$FIX" "$EMPTY" "$APP" "$LRL"; do [ -f "$f" ] && ok || bad "missing $f"; done

# render <json> <prec> <pct> <max> <summary>  (stdout: the text; $T/rc: its rc)
render() {
  bash -c '. "$1" || exit 9; shift; dd_render "$@"' _ "$RENDER" "$1" "$C/" "$2" "$3" "$4" "$5" 2>"$T/err"
  echo $? > "$T/rc"
}
rc() { cat "$T/rc"; }
has() { grep -qF -- "$2" <<<"$1"; }
# line index (1-based) of the first line starting with $2
at() { grep -nF -- "$2" <<<"$1" | head -1 | cut -d: -f1; }
variant() { jq "$2" "$FIX" > "$T/$1.json"; printf '%s' "$T/$1.json"; }

# ── D1-text ─────────────────────────────────────────────────────────────────
D1=$(render "$FIX" - 100 5 -)
check "D1 rc 0 (got $(rc))" '[ "$(rc)" = 0 ]'
check "D1 header is line 1" '[ "$(sed -n 1p <<<"$D1")" = "Daily digest 2026-09-29 (UTC)" ]'
prev=0
for s in "Daily digest 2026-09-29 (UTC)" "Throughput" "Spend" "Autonomy" "Tripwires" "Holds" \
         "PRs awaiting a human verdict" "Model watch" "Spot-checks" "Factory stop"; do
  n=$(at "$D1" "$s")
  if [ -n "$n" ] && [ "$n" -gt "$prev" ]; then ok; prev=$n; else bad "D1 section '$s' missing or out of order (line ${n:-none} after $prev)"; fi
done
check "D1 approve command for the anthropic row" \
  'has "$D1" "  approve: $DIR/bin/model-watch-approve.sh anthropic claude-opus-5-6"'
check "D1 no approve command for the empty-suggestion row" '! grep -q "approve:.*gpt-6-astra-mini" <<<"$D1"'
check "D1 the openai row itself is listed" 'has "$D1" "openai gpt-6-astra-mini"'
check "D1 protected paths line" 'grep -qx "  protected paths: not tracked yet (BH-3683)" <<<"$D1"'
check "D1 \$/merged PR value" 'has "$D1" "\$/merged PR: \$6.25 $C/costs"'
check "D1 factory STOPPED" 'has "$D1" "STOPPED since 2026-09-29T18:00:00Z by operator $C/"'
check "D1 build pause" 'has "$D1" "build paused until 2026-09-30T18:00:00Z by operator $C/"'
check "D1 throughput with its link" 'has "$D1" "Throughput: merged 2 $DORA"'
check "D1 per-project merge links" 'has "$D1" "cromford: 1 $C/p/cromford"'
check "D1 filing to merge p50" 'has "$D1" "filing→merge p50 1h30m (measured 2, unmeasured 1) $DORA"'
check "D1 spend line" 'has "$D1" "Spend: \$12.50 over 41 calls $C/costs"'
check "D1 unpriced calls" 'has "$D1" "unpriced: 3 calls $C/costs"'
check "D1 top ticket links its job" 'has "$D1" "\$7.25 $C/jobs/9101" && has "$D1" "TK-1712 \$3.10 $C/jobs/9102"'
check "D1 autonomy counters show target 0" \
  'has "$D1" "batch dequeues 1 (target 0)" && has "$D1" "manual requeues 1 (target 0)" && has "$D1" "rebuild loops 1 (target 0), abandoned 1" && has "$D1" "human interventions 3 (target 0)"'
check "D1 non-zero intervention tables" 'has "$D1" "config_changes 1, alert_actions 1, pauses 1 $C/history"'
check "D1 PR row links its PR screen" 'has "$D1" "example-org/cromford#3591 BLOCKED_HUMAN since 2026-09-29T09:00:00Z $C/pr/cromford/3591"'
check "D1 spot-check sampled at 100%" 'has "$D1" "sampled 1 of 1 at 100%" && has "$D1" "example-org/project-5#1788 @4f2a9c1e0b7d $C/pr/project-5/1788"'
check "D1 no Summary line" '! grep -q "^Summary:" <<<"$D1"'
check "D1 no lead precision run" 'has "$D1" "lead precision n/a (no precision run for 2026-09-29)"'

# ── D2-text ─────────────────────────────────────────────────────────────────
D2=$(render "$EMPTY" - 10 5 -)
check "D2 rc 0 (got $(rc))" '[ "$(rc)" = 0 ]'
check "D2 Nothing happened is line 2" '[ "$(sed -n 2p <<<"$D2")" = "Nothing happened on 2026-09-29." ]'
for k in "batch dequeues" "manual requeues" "rebuild loops" "human interventions"; do
  check "D2 $k 0 (target 0)" 'has "$D2" "$k 0 (target 0)"'
done
check "D2 \$/merged PR n/a (0 merges)" 'has "$D2" "\$/merged PR: n/a (0 merges)"'
check "D2 filing to merge n/a" 'has "$D2" "filing→merge p50 n/a (0 measured)"'
check "D2 factory not set" 'has "$D2" "Factory stop: not set $C/"'
check "D2 still renders every section" \
  '(for s in Throughput Spend Autonomy Tripwires Holds "PRs awaiting" "Model watch" Spot-checks "Factory stop"; do has "$D2" "$s" || exit 1; done)'

# ── R1: every numeric line carries its console link ─────────────────────────
r1() { # r1 <text>: prints the offending lines
  sed 1d <<<"$1" | grep -E '[0-9]' | grep -vE '^(Summary:|Nothing happened|  protected paths:|  approve:|    approve:)' \
    | grep -vF "$C/" || true
}
check "R1 fixture-day: every numeric line has a link [$(r1 "$D1")]" '[ -z "$(r1 "$D1")" ]'
check "R1 empty-day: every numeric line has a link [$(r1 "$D2")]" '[ -z "$(r1 "$D2")" ]'

# ── R2: absent is not zero ──────────────────────────────────────────────────
X80=$(printf 'x%.0s' $(seq 1 80))
R2=$(render "$(variant r2 '.spend = {ok:false, error:("x"*200)}')" - 100 5 -)
check "R2 rc 0" '[ "$(rc)" = 0 ]'
check "R2 spend read failed, 80 chars" 'has "$R2" "Spend: n/a (read failed: $X80) $C/costs"'
check "R2 no \$0 anywhere" '! grep -qF "\$0" <<<"$R2"'
check "R2 \$/merged PR read failed" 'has "$R2" "\$/merged PR: n/a (read failed)"'
R2B=$(render "$(variant r2b '.spend.usd = null | .spend.usd_per_merged_pr = null')" - 100 5 -)
check "R2b all unpriced" 'has "$R2B" "\$/merged PR: n/a (all unpriced)"'
check "R2b no \$0 anywhere" '! grep -qF "\$0" <<<"$R2B"'
R2C=$(render "$(variant r2c '.throughput = {ok:false, error:"worker 503"}')" - 100 5 -)
check "R2c throughput read failed" 'has "$R2C" "Throughput: n/a (read failed: worker 503) $DORA"'
check "R2c \$/merged PR read failed" 'has "$R2C" "\$/merged PR: n/a (read failed)"'
check "R2c no merged 0" '! grep -q "merged 0" <<<"$R2C"'
R2D=$(render "$(variant r2d '.autonomy = {ok:false, error:"x"}')" - 100 5 -)
check "R2d autonomy read failed, no counter" 'has "$R2D" "Autonomy: n/a (read failed: x)" && ! grep -q "(target 0)" <<<"$R2D"'

# ── R4: lists cut at max-items ──────────────────────────────────────────────
trip_rows() { sed -n '/^Tripwires:/,/^Holds/p' <<<"$1" | grep -cE '^  [A-Z_]+ '; }
R4=$(render "$FIX" - 100 5 -)
check "R4 max 5: 5 tripwire rows ($(trip_rows "$R4"))" '[ "$(trip_rows "$R4")" = 5 ]'
check "R4 max 5: +3 more" 'has "$R4" "  +3 more $C/alerts"'
R4B=$(render "$FIX" - 100 20 -)
check "R4 max 20: 8 rows ($(trip_rows "$R4B"))" '[ "$(trip_rows "$R4B")" = 8 ]'
check "R4 max 20: no +N more" '! grep -q "^ *+[0-9]* more" <<<"$R4B"'
R4C=$(render "$(variant r4c '.tripwires.truncated = true | .tripwires.n = 30')" - 100 5 -)
check "R4c cut at the source is said" 'has "$R4C" "+25 more (list cut at the source) $C/alerts"'

# ── R5: every link is a real console route ──────────────────────────────────
PATS=$(grep -oE "^[[:space:]]*\['(/[^']*)'," "$APP" | sed -E "s/^[[:space:]]*\['//; s/',$//; s/:[a-zA-Z]+/[^\/]+/g; s/.*/^&\$/")
check "R5 ROUTES parsed ($(wc -l <<<"$PATS") patterns)" '[ "$(wc -l <<<"$PATS")" -ge 20 ]'
r5() {
  grep -oE "https://console\.test(/[^ ?]*)?" <<<"$1" | sed 's#^https://console\.test##' | sort -u \
    | while IFS= read -r p; do
        [ -n "$p" ] || p=/
        grep -qE -f <(printf '%s\n' "$PATS") <<<"$p" || echo "$p"
      done
}
check "R5 D1 paths all routes [$(r5 "$D1")]" '[ -z "$(r5 "$D1")" ]'
check "R5 D2 paths all routes [$(r5 "$D2")]" '[ -z "$(r5 "$D2")" ]'
check "R5 D1 carries at least 10 distinct paths" '[ "$(grep -oE "https://console\.test(/[^ ?]*)?" <<<"$D1" | sort -u | wc -l)" -ge 10 ]'

# ── R6: <, > and & stripped ─────────────────────────────────────────────────
R6=$(render "$(variant r6 '.tripwires.rows[1].key = "a<b>&c" | .holds.rows[0].key = "a<b>&c"
  | .autonomy.manual_requeues.rows[0].actor = "a<b>&c" | .model_watch.rows[0].suggestion = "a<b>&c"
  | .tripwires.rows[2].project = "p<q>&r"')" - 100 20 -)
check "R6 rc 0" '[ "$(rc)" = 0 ]'
R6NOURL=$(sed -E 's#https://console\.test[^ ]*##g' <<<"$R6")
check "R6 no <, > or & outside URLs [$(grep -E '[<>&]' <<<"$R6NOURL")]" '! grep -qE "[<>&]" <<<"$R6NOURL"'
check "R6 the stripped value is still shown" 'has "$R6" "abc"'
check "R6 no <, > or & inside URLs either" '! grep -oE "https://console\.test[^ ]*" <<<"$R6" | grep -qE "[<>&]"'

# ── B1: the sampler is lrl_spotcheck's, verbatim ────────────────────────────
EXPR=$(sed -n '/^lrl_spotcheck()/,/^}/p' "$LRL" | grep -E '^[[:space:]]*b=\$\(\(' | head -1 | sed -E 's/^[[:space:]]*//')
check "B1 lrl_spotcheck's expression extracted [$EXPR]" '[ -n "$EXPR" ]'
bmis=""
if [ -n "$EXPR" ]; then
  for tr in "example-org/project-5 1788 4f2a9c1e0b7d6a5c3e2f1a0b9c8d7e6f5a4b3c2d" "example-org/cromford 1 0000000000000000000000000000000000000000" \
            "example-org/cromford 99999 ffffffffffffffffffffffffffffffffffffffff" "a/b 2 1234567890abcdef1234567890abcdef12345678" \
            "example-org/project-3 212 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "example-org/project-4 2101 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
            "o/r 3 c0ffee" "o/r 4 c0ffee" "o/r 5 c0ffee" "o/r 6 c0ffee" "x/y-z 10 deadbeef" "x/y-z 11 deadbeef" \
            "example-org/project-2 25 0123456789abcdef0123456789abcdef01234567" "example-org/project-1 7 9876543210fedcba9876543210fedcba98765432" \
            "example-org/cromford 3591 1111111111111111111111111111111111111111" "example-org/cromford 3592 1111111111111111111111111111111111111111" \
            "org/deep/repo 42 abc" "o/r 100 def" "o/r 1000 feed" "o/r 12345 beef"; do
    set -- $tr
    want=$(bash -c "set -- x \"\$1\" \"\$2\" \"\$3\"; $EXPR; echo \"\$b\"" _ "$1" "$2" "$3")
    got=$(bash -c '. "$1"; shift; dd_spotcheck_bucket "$@"' _ "$RENDER" "$1" "$2" "$3" 2>/dev/null)
    [ -n "$want" ] && [ "$want" = "$got" ] || bmis="$bmis [$tr: want $want got $got]"
  done
fi
check "B1 20 triples agree$bmis" '[ -n "$EXPR" ] && [ -z "$bmis" ]'
for p in '' 0 abc -5; do
  B2=$(render "$FIX" - "$p" 5 -)
  check "B2 pct '$p': sampling off" 'has "$B2" "Spot-checks: spot-check sampling off" && ! grep -q "@4f2a9c1e0b7d" <<<"$B2"'
done
BK=$(bash -c '. "$1"; dd_spotcheck_bucket example-org/project-5 1788 4f2a9c1e0b7d6a5c3e2f1a0b9c8d7e6f5a4b3c2d' _ "$RENDER")
B3=$(render "$FIX" - "$BK" 5 -)
check "B3 pct == bucket ($BK): not sampled" 'has "$B3" "sampled 0 of 1 at $BK%" && ! grep -q "@4f2a9c1e0b7d" <<<"$B3"'
B4=$(render "$FIX" - "$((BK + 1))" 5 -)
check "B4 pct == bucket+1: sampled" 'has "$B4" "sampled 1 of 1 at $((BK + 1))%" && grep -q "@4f2a9c1e0b7d" <<<"$B4"'

# ── L1: lead precision from the file ────────────────────────────────────────
jq -n '{repos: [
  {repo: "example-org/cromford", prs: [range(0; 6) | {pr: (100 + .), verdict: "APPROVE", head: "h", reverted: false, batch_failed: false}]},
  {repo: "example-org/project-5", prs: [
     {pr: 1, verdict: "APPROVE", head: "h", reverted: true,  batch_failed: false},
     {pr: 2, verdict: "APPROVE", head: "h", reverted: false, batch_failed: true},
     {pr: 3, verdict: "APPROVE", head: "h", reverted: false, batch_failed: false},
     {pr: 4, verdict: "APPROVE", head: "h", reverted: false, batch_failed: false},
     {pr: 5, verdict: "APPROVE", head: "h", reverted: null,  batch_failed: false}]}]}' > "$T/prec.json"
L1=$(render "$FIX" "$T/prec.json" 100 5 -)
check "L1 lead precision 0.8 (8/10)" 'has "$L1" "lead precision 0.8 (8/10) $C/outcomes"'
L1B=$(render "$FIX" - 100 5 -)
check "L1 '-' gives no precision run" 'has "$L1B" "lead precision n/a (no precision run for 2026-09-29)"'
mkdir -p "$T/lrp"; cp "$T/prec.json" "$T/lrp/2026-09-28.json"
L1C=$(render "$FIX" "$T/lrp/2026-09-29.json" 100 5 -)
check "L1 missing file, older one beside it: no fallback" \
  'has "$L1C" "lead precision n/a (no precision run for 2026-09-29)" && ! grep -q "8/10" <<<"$L1C"'
jq '.repos[].prs[].reverted = null' "$T/prec.json" > "$T/prec0.json"
L1D=$(render "$FIX" "$T/prec0.json" 100 5 -)
check "L1 zero scored" 'has "$L1D" "lead precision n/a (0 scored)"'

# ── U1: the summary under the header ────────────────────────────────────────
printf 'A quiet day.\n' > "$T/sum.txt"
U1=$(render "$FIX" - 100 5 "$T/sum.txt")
check "U1 line 2 is the summary" '[ "$(sed -n 2p <<<"$U1")" = "Summary: A quiet day." ]'
: > "$T/sum0.txt"
U1B=$(render "$FIX" - 100 5 "$T/sum0.txt")
check "U1 an empty summary file prints no Summary line" '! grep -q "^Summary:" <<<"$U1B"'
U1C=$(render "$EMPTY" - 100 5 "$T/sum.txt")
check "U1 empty day: summary, then Nothing happened" \
  '[ "$(sed -n 2p <<<"$U1C")" = "Summary: A quiet day." ] && [ "$(sed -n 3p <<<"$U1C")" = "Nothing happened on 2026-09-29." ]'

# ── F1: the factory ─────────────────────────────────────────────────────────
F=$(render "$(variant f1 '.factory.factory_stop.value = "true"')" - 100 5 -)
check "F1 value true: STOPPED" 'has "$F" "Factory stop: STOPPED since 2026-09-29T18:00:00Z by operator"'
F=$(render "$(variant f2 '.factory.factory_stop.set = false')" - 100 5 -)
check "F1 set false: not set" 'has "$F" "Factory stop: not set $C/"'
F=$(render "$(variant f3 '.factory.factory_stop.value = "maybe"')" - 100 5 -)
check "F1 value maybe: unreadable" 'has "$F" "Factory stop: not set (row unreadable: maybe) $C/"'
F=$(render "$(variant f4 '.factory.factory_stop.value = "0"')" - 100 5 -)
check "F1 value 0: not set" 'has "$F" "Factory stop: not set $C/"'
F=$(render "$(variant f5 '.factory.all_off = {set: true, actor: "operator", since: "2026-09-29T20:00:00Z"}')" - 100 5 -)
check "F1 all lanes off" 'has "$F" "ALL LANES OFF since 2026-09-29T20:00:00Z by operator $C/"'
check "F1 the pause line" 'has "$F" "  build paused until 2026-09-30T18:00:00Z by operator $C/"'
F=$(render "$(variant f6 '.factory = {ok:false, error:"settings read failed"}')" - 100 5 -)
check "F1 factory unread" 'has "$F" "Factory stop: n/a (read failed: settings read failed) $C/" && ! grep -q "not set" <<<"$F"'

# ── A1: the frozen signature ────────────────────────────────────────────────
bash -c '. "$1"; dd_render a b c d e' _ "$RENDER" >/dev/null 2>&1; RC=$?
check "A1 5 args: rc 2 (got $RC)" '[ "$RC" = 2 ]'
OUT=$(render "$T/nope.json" - 100 5 -)
check "A1 nonexistent JSON: rc 1 (got $(rc)), empty stdout" '[ "$(rc)" = 1 ] && [ -z "$OUT" ]'
printf '[1,2]' > "$T/arr.json"
OUT=$(render "$T/arr.json" - 100 5 -)
check "A1 non-object JSON: rc 1, empty stdout" '[ "$(rc)" = 1 ] && [ -z "$OUT" ]'
OUT=$(render "$FIX" - 100 0 -)
check "A1 max-items 0: rc 2, empty stdout" '[ "$(rc)" = 2 ] && [ -z "$OUT" ]'

echo "daily-digest-render: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
