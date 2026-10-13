#!/bin/bash
# tests/cost-grok-usage.bh-1494-test.sh — cost-capture parity on grok 1.0.x.
#
# THE GAP (BH-1494, the operator's comment of 2026-09-22 18:05Z). On a 1.0.40 session
# bin/grok-usage.sh printed `58550 1 <blank> <blank> <blank>`: a token count,
# no cache figures and no dollars, while the CLI's own `--output-format json`
# envelope carried `usage.input_tokens 57398`, `cache_read_input_tokens 1152`,
# `cache_creation_input_tokens 0`, `output_tokens 1`, a `total_cost_usd` of
# 0.11785 and a `modelUsage["grok-4.7"]` dict. Two different reasons:
#
#   * `total_cost_usd` sits at the envelope's TOP level, beside `usage`, not
#     inside the usage dict the walk looks at; and
#   * `modelUsage`'s spellings (cacheReadInputTokens, cacheCreationInputTokens,
#     costUSD, total_cost_usd_ticks) were in none of the reader's key lists.
#
# So the fix is two-sided and this suite drives both: the envelope is read
# FIRST when the lane ran with `--output-format json` (one parse, the vendor's
# own dollars), and the tree walk — still the only thing a KILLED run leaves
# behind — learns the 1.0.x spellings.
#
# Run from anywhere: tests/cost-grok-usage.bh-1494-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1510.1: agent-call and lane-probe read grok.default from model_routes; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj fleet   # fleet: bin/lane-probe.sh's canary runs agent-call as project fleet (BH-2560)
GU="$DIR/bin/grok-usage.sh"
FIX="$DIR/tests/fixtures"
ENV_FIX="$FIX/grok-usage/1.0.40/envelope.json"
mkdir -p "$T/logs" "$T/flags" "$T/locks" "$T/fakebin" "$T/bin" "$T/env"
: > "$T/env/global.env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/prices.json" <<'EOF'
{"per_token": {
  "grok-4.6": {"prompt": 0.000002, "completion": 0.000006, "cache_read": 5e-7, "cache_write": null}
}}
EOF

# A walk-only grok home carrying the verified 0.2.x ledger, for every case that
# has to prove the walk is still there.
WALK="$T/walk"; mkdir -p "$WALK/sessions/s1"
cp "$FIX/grok-usage-nested-ticks.jsonl" "$WALK/sessions/s1/updates.jsonl"
WALK_SUMMARY="402118 11003 128044 2011 0.905636"

# ── A. bin/grok-usage.sh on 1.0.x ────────────────────────────────────────────
echo "--- A. bin/grok-usage.sh"
[ -s "$ENV_FIX" ] && ok || bad "A0 the 1.0.40 envelope fixture is missing"
[ -s "$FIX/grok-usage/1.0.40/PROVENANCE.md" ] && ok || bad "A0 the fixture has no provenance note"

# A1. THE HEADLINE. The envelope prices exactly, cache fields and all, with no
# ledger in sight — a grok home that does not exist at all is passed on purpose.
# BH-1636: output is 413, the envelope's output_tokens 1 plus its sibling reasoning_tokens 412.
OUT=$(bash "$GU" --envelope "$ENV_FIX" 0 "$T/nonexistent"); RC=$?
[ "$RC" = 0 ] && ok || bad "A1 the reader must never fail the caller (rc=$RC)"
[ "$OUT" = "57398 413 1152 0 0.117850" ] && ok \
  || bad "A1 the 1.0.40 envelope must price in full: expected '57398 413 1152 0 0.117850', got '$OUT'"

# A2. The envelope is the FIRST read, not a fallback: a newer ledger sitting in
# the tree must not override the figures the CLI itself reported.
mkdir -p "$T/gh2/sessions/s"
printf '%s\n' '{"usage":{"inputTokens":999999,"outputTokens":7777,"costUsdTicks":5000000000}}' > "$T/gh2/sessions/s/updates.jsonl"
OUT=$(bash "$GU" --envelope "$ENV_FIX" 0 "$T/gh2")
[ "$OUT" = "57398 413 1152 0 0.117850" ] && ok \
  || bad "A2 the envelope must win over a ledger in the tree: got '$OUT'"

# A3. ...and the walk is still the answer when there is no envelope. A killed
# run never gets to write one, and that run's tokens were still billed.
OUT=$(bash "$GU" --envelope "$T/no/such/file" 0 "$WALK")
[ "$OUT" = "$WALK_SUMMARY" ] && ok || bad "A3 a missing envelope must fall through to the walk: got '$OUT'"

# A4. An envelope that is not an envelope (a killed run whose stderr landed in
# $OUT) falls through too, rather than blanking the row.
printf 'error: connection reset by peer\n' > "$T/prose.txt"
OUT=$(bash "$GU" --envelope "$T/prose.txt" 0 "$WALK")
[ "$OUT" = "$WALK_SUMMARY" ] && ok || bad "A4 a prose 'envelope' must fall through to the walk: got '$OUT'"
# ...and an envelope whose usage dict has no output key is not a usage record.
printf '%s\n' '{"usage":{"input_tokens":5},"total_cost_usd":9.99}' > "$T/half.json"
OUT=$(bash "$GU" --envelope "$T/half.json" 0 "$WALK")
[ "$OUT" = "$WALK_SUMMARY" ] && ok || bad "A4 a half-usage envelope must fall through, not price: got '$OUT'"

# A5. THE 1.0.x SPELLINGS, through the walk. This is what a modelUsage-shaped
# record looks like, and every one of its four cache/dollar keys was missing
# from the reader's lists.
mkdir -p "$T/gh5"
printf '%s\n' '{"modelUsage":{"grok-4.7":{"inputTokens":57398,"outputTokens":1,"cacheReadInputTokens":1152,"cacheCreationInputTokens":0,"modelCalls":1,"costUSD":0.11785}}}' \
  > "$T/gh5/unified.jsonl"
OUT=$(bash "$GU" 0 "$T/gh5")
[ "$OUT" = "57398 1 1152 0 0.117850" ] && ok \
  || bad "A5 the 1.0.x modelUsage spellings must price: expected '57398 1 1152 0 0.117850', got '$OUT'"

# A6. total_cost_usd_ticks, the 1e-10 spelling 1.0.x prints beside the dollars.
mkdir -p "$T/gh6"
printf '%s\n' '{"usage":{"input_tokens":57398,"output_tokens":1,"total_cost_usd_ticks":1178500000}}' > "$T/gh6/a.json"
OUT=$(bash "$GU" 0 "$T/gh6")
[ "${OUT##* }" = "0.117850" ] && ok || bad "A6 total_cost_usd_ticks must be read as dollars: got '$OUT'"

# A7. --calls is the LEDGER's series and never the envelope's single row: the
# caller differences it to find the context cliff, and one row would hide it.
OUT=$(bash "$GU" --calls --envelope "$ENV_FIX" 0 "$WALK")
[ "$(wc -l <<<"$OUT")" = 3 ] && ok || bad "A7 --calls must still print the ledger series: got '$OUT'"
[ "$(tail -1 <<<"$OUT")" = "3 402118 11003 128044 2011" ] && ok || bad "A7 the last record: '$(tail -1 <<<"$OUT")'"

# A8. A REAL 1.0.x CAPTURE, or a NAMED TODO — never a fake green. 1.0.40 dropped
# sessions/**/updates.jsonl for ~/.grok/logs/unified.jsonl, and A5/A6 pin the
# key spellings that file is expected to carry, not the file itself. BH-1636:
# bin/grok-envelope-probe.sh captures one real session in this layout, with a
# PROVENANCE.md whose first line is `# CAPTURED`. Every such dir committed under
# tests/fixtures/grok-usage/ is asserted here: its envelope prices (tokens and a
# non-zero usd), its .result is a string, and its unified.jsonl (when the probe
# could tie one to the session) walks to input and output tokens. With none
# committed the TODO stays, counted as neither a pass nor a fail on purpose. The
# 1.0.40 dir beside it is RECONSTRUCTED and never arms this.
A8_SEEN=0
for d in "$FIX"/grok-usage/*/; do
  d="${d%/}"; v="${d##*/}"
  head -1 "$d/PROVENANCE.md" 2>/dev/null | grep -q '^# CAPTURED' || continue
  A8_SEEN=$((A8_SEEN+1)); echo "A8 $v: CAPTURED fixture"
  IFS='|' read -r a_in a_out _ _ a_usd <<<"$(bash "$GU" --envelope "$d/envelope.json" 0 "$T/nonexistent" | tr ' ' '|')"
  [ -n "$a_in" ] && [ -n "$a_out" ] && ok || bad "A8 $v: the captured envelope has no tokens: in='$a_in' out='$a_out'"
  [ -n "$a_usd" ] && awk -v u="$a_usd" 'BEGIN{exit !(u+0 > 0)}' && ok || bad "A8 $v: the captured envelope does not price: usd='$a_usd'"
  [ "$(jq -r '.result|type' "$d/envelope.json" 2>/dev/null)" = string ] && ok || bad "A8 $v: .result is not a string in the captured envelope"
  if [ -s "$d/unified.jsonl" ]; then
    rm -rf "$T/a8"; mkdir -p "$T/a8/logs"; cp "$d/unified.jsonl" "$T/a8/logs/unified.jsonl"
    read -r w_in w_out _ <<<"$(bash "$GU" 0 "$T/a8")"
    [ -n "$w_in" ] && [ -n "$w_out" ] && ok || bad "A8 $v: the captured unified.jsonl walks to no tokens: '$w_in $w_out'"
  fi
done
[ "$A8_SEEN" -gt 0 ] || echo "TODO(BH-1494): no ~/.grok/logs/unified.jsonl fixture from a real 1.0.x session yet — A5/A6 pin the key spellings that file is expected to carry, not the file itself. Capture one with: bin/grok-envelope-probe.sh on a grok 1.0.40 box (it writes state/grok-probe/<version>/), then cp -r that dir to tests/fixtures/grok-usage/"

# ── D. the production entry point: bin/agent-call.sh ─────────────────────────
echo "--- D. bin/agent-call.sh (driven)"
mkdir -p "$T/.grok/bin"
cat > "$T/.grok/bin/grok" <<'EOF'
#!/bin/bash
# fake grok 1.0.40: records its argv, and answers in whichever output format it
# was asked for.
printf '%s\n' "$*" > "$GROK_ARGV"
# GROK_SILENT=1: exit 0 having printed nothing at all, in either format. That is
# what a CLI that dies after its last token looks like from the lane's side.
[ "${GROK_SILENT:-0}" = 1 ] && exit "${GROK_EXIT:-0}"
for a in "$@"; do
  if [ "$a" = json ]; then cat "$GROK_ENVELOPE"; exit "${GROK_EXIT:-0}"; fi
done
echo "DECISION: BH-1494 :: skip :: fake"
exit "${GROK_EXIT:-0}"
EOF
chmod +x "$T/.grok/bin/grok"
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"; chmod +x "$T/fakebin/billing-mode.sh"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"

drive() { # drive <GROK_OUTPUT_JSON value or empty> ; echoes agent-call's rc
  #   GROK_SILENT — 1 makes the fake CLI exit 0 printing nothing
  #   SEED_OUT    — text planted in $OUT before the call, to stand in for an
  #                 earlier attempt's answer on the same (PR, head) path
  rm -f "$T/out.txt" "$T/out.txt.envelope" "$T/grok.argv"
  [ -n "${SEED_OUT:-}" ] && printf '%s\n' "$SEED_OUT" > "$T/out.txt"
  # Same fence as the sibling suite: with the vendor keys in the ambient env an
  # unfenced run would let the survival ladder spend real money and then report
  # success from a lane this test never asked for.
  ( unset OPENROUTER_API_KEY FIREWORKS_API_KEY XAI_API_KEY GROK_CODE_XAI_API_KEY \
          OPENAI_API_KEY CODEX_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY HARNESS_SECRET
    export HOME="$T" HARNESS="$T" PATH="$T/fakebin:$PATH" \
           MODEL_PRICES="$T/prices.json" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           GROK_ENVELOPE="$ENV_FIX" GROK_ARGV="$T/grok.argv" GROK_EXIT=0 \
           GROK_SILENT="${GROK_SILENT:-0}" \
           RUNNER_TRIAGE=grok RUNNER_TRIAGE_FALLBACK=grok
    [ -n "$1" ] && export GROK_OUTPUT_JSON="$1"
    bash "$DIR/bin/agent-call.sh" triage testproj grok-4.6 60 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
col() { tail -1 "$T/logs/cost.csv" | awk -F, -v c="$1" '{print $c}'; }

rm -f "$T/logs/cost.csv"
# D1. GROK_OUTPUT_JSON=1: the lane asks for the envelope, keeps it beside the
# answer, prices the row from it, and hands the caller the answer text.
RC=$(drive 1)
[ "$RC" = 0 ] && ok || bad "D1 the driven call failed (rc=$RC)"
grep -q -- '--output-format json' "$T/grok.argv" && ok || bad "D1 the lane never asked for the envelope: $(cat "$T/grok.argv" 2>/dev/null)"
[ -s "$T/out.txt.envelope" ] && ok || bad "D1 the raw envelope must be kept beside the answer"
[ "$(cat "$T/out.txt")" = "ok" ] && ok || bad "D1 \$OUT must be the envelope's answer text, got '$(cat "$T/out.txt" 2>/dev/null)'"
[ "$(col 9)" = 57398 ] && ok  || bad "D1 input_toks (col 9): got '$(col 9)'"
# BH-1636: 1 output + 412 sibling reasoning tokens.
[ "$(col 10)" = 413 ] && ok   || bad "D1 output_toks (col 10): got '$(col 10)'"
[ "$(col 11)" = 1152 ] && ok  || bad "D1 cache_read (col 11): got '$(col 11)'"
[ "$(col 12)" = 0 ] && ok     || bad "D1 cache_write (col 12): got '$(col 12)'"
# TEST-CHANGE: BH-3984 reverses the precedence: cost_usd is the table's price of
# the row's tokens. On this envelope the two agree to the digit
# (57398*2e-6 + 413*6e-6 + 1152*5e-7 = 0.117850), so the value is unchanged and
# only what it is compared against moves to cost_price_tokens.
D1_WANT=$( export MODEL_PRICES="$T/prices.json"; . "$DIR/bin/lib/cost-row.sh"; cost_price_tokens grok-4.6 57398 413 1152 0 )
[ "$(col 13)" = "$D1_WANT" ] && [ "$D1_WANT" = 0.117850 ] && ok || bad "D1 cost_usd (col 13) must be cost_price_tokens over the row's tokens ('$D1_WANT'): got '$(col 13)'"
[ "$(col 18)" = ledger ] && ok || bad "D1 row_source (col 18): got '$(col 18)'"
[ "$(col 19)" = 0.117850 ] && ok || bad "D1 result_usd (col 19): got '$(col 19)'"

# D2. THE NEGATIVE, and the default. With the knob unset the lane is byte for
# byte what it is today: today's flag set, no --output-format, no envelope file,
# and the CLI's stdout is the answer. 1.0.40 takes --output-format json, but
# which envelope field carries the ANSWER is not documented anywhere this box
# can reach — so the default must not depend on the guess.
RC=$(drive "")
[ "$RC" = 0 ] && ok || bad "D2 the default driven call failed (rc=$RC)"
grep -q -- '--output-format' "$T/grok.argv" && bad "D2 the default lane must not change its flags: $(cat "$T/grok.argv")" || ok
[ -e "$T/out.txt.envelope" ] && bad "D2 the default lane must not write an envelope file" || ok
grep -q 'DECISION: BH-1494' "$T/out.txt" && ok || bad "D2 \$OUT must be the CLI's own stdout: '$(cat "$T/out.txt" 2>/dev/null)'"
ARGV=$(cat "$T/grok.argv")
for f in --always-approve --max-turns -m -p; do
  grep -q -- "$f" <<<"$ARGV" && ok || bad "D2 today's flag $f is gone from the grok lane: $ARGV"
done
grep -q -- '-m grok-4.6' <<<"$ARGV" && ok || bad "D2 the lane must pin the model: $ARGV"

# D3. THE STALE-ANSWER NEGATIVE. $OUT is keyed on (PR, head) and the survival
# ladder reuses the path across attempts, so the answer file has to belong to
# THIS call or be empty — never to the attempt before it. At knob 0 the CLI's
# own `> "$OUT"` redirect guarantees that; at knob 1 stdout goes to the envelope
# instead, so the lane truncates $OUT itself. Drive the case that finds it: a
# CLI that exits 0 and prints nothing, with an earlier answer planted on disk.
STALE="STALE ANSWER FROM AN EARLIER ATTEMPT"
for knob in 1 ""; do
  GROK_SILENT=1 SEED_OUT="$STALE" drive "$knob" >/dev/null
  grep -q "$STALE" "$T/out.txt" 2>/dev/null \
    && bad "D3 (GROK_OUTPUT_JSON='${knob:-unset}') an empty answer returned the previous attempt's text: '$(cat "$T/out.txt")'" \
    || ok
done
unset STALE GROK_SILENT SEED_OUT

# ── E. -m everywhere: bin/lane-probe.sh ──────────────────────────────────────
# 1.0.40's default model is grok-4.20-0309-non-reasoning, so anything calling
# grok without -m now gets a different model than the lane it is the canary for.
echo "--- E. bin/lane-probe.sh"
probe() { # probe [GROK_MODEL]
  rm -f "$T/grok.argv"
  env -i PATH="$T/fakebin:$PATH" HOME="$T" HARNESS="$T" HARNESS_ENV_DIR="$T/env" \
      GROK_ARGV="$T/grok.argv" GROK_ENVELOPE="$ENV_FIX" GROK_EXIT=0 \
      ${1:+GROK_MODEL="$1"} \
      bash "$DIR/bin/lane-probe.sh" grok >/dev/null 2>&1
  cat "$T/grok.argv" 2>/dev/null
}
ARGV=$(probe)
grep -q -- '-m grok-4.6' <<<"$ARGV" && ok || bad "E the grok canary must pin the default model: '$ARGV'"
ARGV=$(probe grok-4.7)
grep -q -- '-m grok-4.7' <<<"$ARGV" && ok || bad "E GROK_MODEL must reach the canary's -m: '$ARGV'"

echo "cost-grok-usage.bh-1494-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
