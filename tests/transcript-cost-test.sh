#!/bin/bash
# tests/transcript-cost-test.sh — bin/transcript-cost.sh against hand-built
# session transcripts, and agent-call.sh's cost_row_source() against a stubbed
# one.
#
# WHY THIS SUITE EXISTS. Every cost row the fleet writes for a claude call used
# to come from the CLI's `--output-format json` envelope, which has two holes in
# the same column: it is only written when the run SURVIVES to print it (a
# killed run shipped blank tokens and blank dollars — 16 of one day's 478 hub
# rows, 2,008 of 8,000 all-time), and its `.usage` covers one turn rather than
# the session. The transcript has neither problem. So the transcript is now the
# source, and this file is what stops the new source from being wrong in a
# quieter way than the old one.
#
# What is proved here, in the order a reader cares about it:
#   1. DE-DUPLICATION. Claude Code writes one JSONL entry per CONTENT BLOCK of
#      an API response and repeats the identical usage object on each. Summing
#      lines reads ~2.2x high (measured on hub session 4c9ab765: 5,378,875
#      cache_read claimed where the session read 2,400,809). A fixture writes
#      one response three times and the sum must not move.
#   2. THE ARITHMETIC IS EXACT, against a fixture price table rather than the
#      live catalog, so a catalog refresh cannot turn this suite red and a
#      pricing bug cannot hide behind a moving number.
#   3. CACHE WRITES ARE PRICED PER TTL: the per-message cache_creation split is
#      read (5m at the table rate, 1h at 2x prompt), COST_CACHE_TTL forces the
#      rate for messages that carry no split, and a split that does not add up
#      keeps its remainder instead of losing it.
#   4. SUBAGENT turns are counted — both the isSidechain entries in the session
#      file and a companion file — and --no-subagents turns that off.
#   5. A KILLED run still gets an answer: a transcript with no result message
#      prices normally (exit 0), a transcript with no usage at all exits 4 with
#      a reason, and a session with no transcript exits 3 with a reason. Three
#      distinct outcomes, because the caller writes a different row for each.
#   6. AN UNPRICED MODEL IS NAMED, never funded from a neighbour's rate: usd
#      comes back partial AND says which model made it partial.
#   7. cost_row_source() picks transcript over envelope, falls back to the
#      envelope when there is no transcript, writes neither when there is
#      neither, leaves non-claude runners alone, obeys the kill switch, and logs
#      the >20% disagreement that is how the fleet learns what `.usage` means.
#
# No network, no model call, no CLAUDE_CONFIG_DIR outside the temp dir.
# Run from anywhere: tests/transcript-cost-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/cfg/projects" "$T/bin/lib" "$T/logs" "$T/locks" "$T/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

TC="$DIR/bin/transcript-cost.sh"

# A fixture price table. Deliberately NOT catalog/model-prices.json: the numbers
# below are checked to the cent, and the catalog is refreshed by a cron.
#   prompt 1e-5  completion 2e-5  cache_read 1e-6  cache_write(5m) 1.25e-5
#   => the derived 1h write rate is prompt*2 = 2e-5
cat > "$T/prices.json" <<'JSON'
{"per_token":{
  "test-model":   {"prompt":0.00001,"completion":0.00002,"cache_read":0.000001,"cache_write":0.0000125},
  "other-model":  {"prompt":0.00002,"completion":0.00004,"cache_read":0.000002,"cache_write":0.000025}
}}
JSON

# The project directory Claude Code would use for a session whose cwd is /work.
PROJ="$T/cfg/projects/-work"
mkdir -p "$PROJ"

# msg <file> <msg-id> <model> <in> <out> <cache_read> <cw5m> <cw1h> [ts] [extra-json]
# One assistant entry, shaped the way the CLI writes them.
msg() {
  local f="$1" id="$2" model="$3" i="$4" o="$5" cr="$6" w5="$7" w1="$8" ts="${9:-2026-09-14T20:00:00.000Z}" extra="${10:-}"
  python3 - "$f" "$id" "$model" "$i" "$o" "$cr" "$w5" "$w1" "$ts" "$extra" <<'PY'
import json, sys
f, mid, model, i, o, cr, w5, w1, ts, extra = sys.argv[1:11]
e = {"type": "assistant", "uuid": "u-" + mid + "-" + str(hash(ts) % 9999),
     "timestamp": ts,
     "message": {"id": mid, "type": "message", "role": "assistant", "model": model,
                 "content": [{"type": "text", "text": "hi"}],
                 "usage": {"input_tokens": int(i), "output_tokens": int(o),
                           "cache_read_input_tokens": int(cr),
                           "cache_creation_input_tokens": int(w5) + int(w1),
                           "cache_creation": {"ephemeral_5m_input_tokens": int(w5),
                                              "ephemeral_1h_input_tokens": int(w1)}}}}
if extra:
    e.update(json.loads(extra))
open(f, "a").write(json.dumps(e) + "\n")
PY
}
field() { printf '%s' "$1" | cut -d'|' -f"$2"; }
run_tc() { "$TC" "$@" --config-dir "$T/cfg" --prices "$T/prices.json" 2>"$T/err"; }

# ── 1. one response written three times is ONE response ──────────────────────
# The bug this whole file is named after. Three entries, one message.id, the
# identical usage object on each — exactly what the CLI writes for a turn with
# a text block and two tool_use blocks.
S1=11111111-1111-1111-1111-111111111111
for _ in 1 2 3; do msg "$PROJ/$S1.jsonl" msg_a test-model 10 20 1000 500 300; done
L=$(run_tc "$S1" --cwd /work); RC=$?
[ "$RC" = 0 ] && ok || bad "a normal transcript must exit 0 (rc=$RC: $(cat "$T/err"))"
[ "$(field "$L" 1)" = 10 ]   && ok || bad "input must be counted ONCE, got $(field "$L" 1) (repeated content blocks summed?)"
[ "$(field "$L" 2)" = 20 ]   && ok || bad "output must be counted once, got $(field "$L" 2)"
[ "$(field "$L" 3)" = 1000 ] && ok || bad "cache_read must be counted once, got $(field "$L" 3) — this is the 2.2x overcount"
[ "$(field "$L" 4)" = 800 ]  && ok || bad "cache_write must be 5m+1h counted once, got $(field "$L" 4)"
[ "$(field "$L" 7)" = 1 ]    && ok || bad "three entries for one API response must report 1 message, got $(field "$L" 7)"
[ "$(field "$L" 6)" = test-model ] && ok || bad "the model column must name the model, got $(field "$L" 6)"
[ -z "$(field "$L" 9)" ]     && ok || bad "a fully priced session must report no unpriced models, got $(field "$L" 9)"

# ── 2. the arithmetic, to the cent ───────────────────────────────────────────
#   10*1e-5 + 20*2e-5 + 1000*1e-6 + 500*1.25e-5 + 300*(1e-5*2)
# =  0.0001  + 0.0004  +  0.001    +  0.00625    +  0.006      = 0.01375
[ "$(field "$L" 5)" = "0.013750" ] \
  && ok || bad "usd must be 0.013750 (5m writes at the table rate, 1h at 2x prompt), got $(field "$L" 5)"

# 1h writes really are priced ABOVE 5m writes — the same 800 tokens, all 1h.
S1B=1111111b-1111-1111-1111-111111111111
msg "$PROJ/$S1B.jsonl" msg_b test-model 0 0 0 0 800
LB=$(run_tc "$S1B" --cwd /work)
[ "$(field "$LB" 5)" = "0.016000" ] \
  && ok || bad "800 tokens of 1h cache write must price at 2x prompt = 0.016, got $(field "$LB" 5)"
S1C=1111111c-1111-1111-1111-111111111111
msg "$PROJ/$S1C.jsonl" msg_c test-model 0 0 0 800 0
LC=$(run_tc "$S1C" --cwd /work)
[ "$(field "$LC" 5)" = "0.010000" ] \
  && ok || bad "800 tokens of 5m cache write must price at the table rate = 0.010, got $(field "$LC" 5)"

# ── 3. COST_CACHE_TTL only decides messages that carry NO split ──────────────
# An older transcript has cache_creation_input_tokens and no breakdown. The
# default reads 5m; COST_CACHE_TTL=1h says this run used the 1-hour cache.
S2=22222222-2222-2222-2222-222222222222
python3 - "$PROJ/$S2.jsonl" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.dumps({
  "type": "assistant", "uuid": "u1", "timestamp": "2026-09-14T20:00:00.000Z",
  "message": {"id": "old_1", "model": "test-model",
              "usage": {"input_tokens": 0, "output_tokens": 0,
                        "cache_read_input_tokens": 0,
                        "cache_creation_input_tokens": 800}}}) + "\n")
PY
L2=$(run_tc "$S2" --cwd /work)
[ "$(field "$L2" 5)" = "0.010000" ] \
  && ok || bad "with no split the default must price as 5m (0.010), got $(field "$L2" 5)"
L2H=$(COST_CACHE_TTL=1h run_tc "$S2" --cwd /work)
[ "$(field "$L2H" 5)" = "0.016000" ] \
  && ok || bad "COST_CACHE_TTL=1h must price a split-less write at 2x prompt (0.016), got $(field "$L2H" 5)"
# ...and it must NOT override a message that DID declare its split.
L1H=$(COST_CACHE_TTL=1h run_tc "$S1" --cwd /work)
[ "$(field "$L1H" 5)" = "0.013750" ] \
  && ok || bad "a declared split outranks COST_CACHE_TTL, expected 0.013750, got $(field "$L1H" 5)"

# A split that does not add up to the total keeps the remainder rather than
# losing it — undercounting is the failure this file exists to end.
S2B=2222222b-2222-2222-2222-222222222222
python3 - "$PROJ/$S2B.jsonl" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.dumps({
  "type": "assistant", "uuid": "u1", "timestamp": "2026-09-14T20:00:00.000Z",
  "message": {"id": "partial_1", "model": "test-model",
              "usage": {"input_tokens": 0, "output_tokens": 0,
                        "cache_read_input_tokens": 0,
                        "cache_creation_input_tokens": 800,
                        "cache_creation": {"ephemeral_5m_input_tokens": 300,
                                           "ephemeral_1h_input_tokens": 0}}}}) + "\n")
PY
L2B=$(run_tc "$S2B" --cwd /work)
[ "$(field "$L2B" 4)" = 800 ] \
  && ok || bad "a short split must keep its remainder (800 written), got $(field "$L2B" 4)"

# ── 4. subagents ─────────────────────────────────────────────────────────────
# A Task subagent's turns land in the SAME file with isSidechain:true, so they
# are summed by construction; some CLI versions write a companion file instead.
S3=33333333-3333-3333-3333-333333333333
msg "$PROJ/$S3.jsonl" main_1 test-model 10 10 0 0 0
msg "$PROJ/$S3.jsonl" side_1 test-model 10 10 0 0 0 2026-09-14T20:00:01.000Z '{"isSidechain":true}'
msg "$PROJ/$S3-agent-1.jsonl" comp_1 test-model 10 10 0 0 0
L3=$(run_tc "$S3" --cwd /work)
[ "$(field "$L3" 1)" = 30 ] && ok || bad "sidechain + companion turns must be summed, expected input 30, got $(field "$L3" 1)"
[ "$(field "$L3" 8)" = 2 ]  && ok || bad "the companion file must be counted as a second file, got $(field "$L3" 8)"
L3N=$(run_tc "$S3" --cwd /work --no-subagents)
[ "$(field "$L3N" 1)" = 20 ] && ok || bad "--no-subagents must drop the companion file but keep in-file sidechains, got $(field "$L3N" 1)"

# A SIBLING file that names this session as its parent is picked up too.
S3P=3333333p-3333-3333-3333-333333333333
msg "$PROJ/$S3P.jsonl" p_1 test-model 10 0 0 0 0
msg "$PROJ/aaaa-child.jsonl" c_1 test-model 5 0 0 0 0 2026-09-14T20:00:00.000Z "{\"parentSessionId\":\"$S3P\"}"
L3P=$(run_tc "$S3P" --cwd /work)
[ "$(field "$L3P" 1)" = 15 ] && ok || bad "a sibling naming this session as parent must be summed, got $(field "$L3P" 1)"
# An unrelated sibling must NOT be — a scan that over-collects bills this run
# for someone else's tokens, which is the 15x mis-attribution in another shape.
msg "$PROJ/bbbb-stranger.jsonl" x_1 test-model 999 0 0 0 0
L3P2=$(run_tc "$S3P" --cwd /work)
[ "$(field "$L3P2" 1)" = 15 ] && ok || bad "an unrelated sibling must not be summed, got $(field "$L3P2" 1)"

# ── 5. the killed run, which is the whole point ──────────────────────────────
# No result message, no final assistant turn — just the responses that happened
# before the kill. It prices normally, because they are real spend.
S4=44444444-4444-4444-4444-444444444444
msg "$PROJ/$S4.jsonl" k_1 test-model 100 200 0 0 0
printf '%s\n' '{"type":"user","uuid":"u9","timestamp":"2026-09-14T20:00:05.000Z","message":{"role":"user","content":"go on"}}' >> "$PROJ/$S4.jsonl"
L4=$(run_tc "$S4" --cwd /work); RC4=$?
[ "$RC4" = 0 ] && ok || bad "a transcript with no result message must still price (rc=$RC4)"
[ "$(field "$L4" 2)" = 200 ] && ok || bad "a killed run's completed turns must be counted, got $(field "$L4" 2)"

# A transcript that exists but holds no API response at all: exit 4, with a
# reason. Distinct from "no transcript" because the caller writes a row either
# way and should be able to say which happened.
S5=55555555-5555-5555-5555-555555555555
printf '%s\n' '{"type":"user","uuid":"u1","timestamp":"2026-09-14T20:00:00.000Z","message":{"role":"user","content":"hello"}}' > "$PROJ/$S5.jsonl"
run_tc "$S5" --cwd /work >/dev/null; RC5=$?
[ "$RC5" = 4 ] && ok || bad "a transcript with no usage must exit 4, got $RC5"
grep -qi 'no API response\|carries no usage' "$T/err" && ok || bad "exit 4 must say WHY on stderr, got: $(cat "$T/err")"

# No transcript at all: exit 3, with a reason that names the session.
run_tc 99999999-9999-9999-9999-999999999999 --cwd /work >/dev/null; RC6=$?
[ "$RC6" = 3 ] && ok || bad "a session with no transcript must exit 3, got $RC6"
grep -q 'no transcript' "$T/err" && ok || bad "exit 3 must say WHY on stderr, got: $(cat "$T/err")"

# ── 6. an unpriced model is NAMED, and the dollars say they are partial ──────
S7=77777777-7777-7777-7777-777777777777
msg "$PROJ/$S7.jsonl" pr_1 test-model     0 1000 0 0 0
msg "$PROJ/$S7.jsonl" pr_2 model-nobody-priced 0 1000 0 0 0 2026-09-14T20:00:02.000Z
L7=$(run_tc "$S7" --cwd /work)
[ "$(field "$L7" 9)" = "model-nobody-priced" ] \
  && ok || bad "an unpriced model must be named in the unpriced column, got '$(field "$L7" 9)'"
[ "$(field "$L7" 5)" = "0.020000" ] \
  && ok || bad "the priced half must still be charged (1000*2e-5), got $(field "$L7" 5)"
[ "$(field "$L7" 1)" = 0 ] && ok || bad "token totals must include the unpriced model's tokens"

# ── 7. --since, for a `claude -c` continuation ───────────────────────────────
# The session file already holds earlier turns; summing it whole would bill this
# turn for the history.
S8=88888888-8888-8888-8888-888888888888
msg "$PROJ/$S8.jsonl" old_1 test-model 1000 0 0 0 0 2026-09-14T19:00:00.000Z
msg "$PROJ/$S8.jsonl" new_1 test-model 7 0 0 0 0 2026-09-14T21:00:00.000Z
CUT=$(date -u -d '2026-09-14T20:00:00Z' +%s 2>/dev/null)
if [ -n "$CUT" ]; then
  L8=$(run_tc "$S8" --cwd /work --since "$CUT")
  [ "$(field "$L8" 1)" = 7 ] && ok || bad "--since must exclude turns before the cut, got $(field "$L8" 1)"
  L8A=$(run_tc "$S8" --cwd /work)
  [ "$(field "$L8A" 1)" = 1007 ] && ok || bad "without --since the whole file is summed, got $(field "$L8A" 1)"
fi

# ── 8. a path may be passed instead of a session id ──────────────────────────
LP=$(run_tc "$PROJ/$S1.jsonl")
[ "$(field "$LP" 1)" = 10 ] && ok || bad "a jsonl PATH must be accepted as the target, got '$LP'"

# ── 9. --format json carries the per-model split ─────────────────────────────
J=$(run_tc "$S7" --cwd /work --format json)
python3 - "$J" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["models"]["test-model"]["priced"] is True, d
assert d["models"]["model-nobody-priced"]["priced"] is False, d
assert d["unpriced"] == ["model-nobody-priced"], d
assert d["models"]["test-model"]["usd"] == 0.02, d
PY
[ $? = 0 ] && ok || bad "--format json must carry the per-model breakdown and priced flags"

# A session id is never guessed from a neighbouring file: the wrong transcript is
# worse than none, because it produces a number that looks right.
[ "$(field "$L4" 1)" = 100 ] && ok || bad "session $S4 must be priced from its OWN file"

# ── 10. cost_row_source(): transcript vs envelope, in agent-call.sh ──────────
# Extracted the way tests/cost-append-test.sh extracts cost_append, and driven
# against a STUB transcript-cost.sh — the decision is what is under test, not
# the pricing (proved above).
cp "$DIR/bin/lib/cost-row.sh" "$T/bin/lib/"
awk '/^# >>> cost_row_source/{f=1;next} /^# <<< cost_row_source/{exit} f' \
  "$DIR/bin/agent-call.sh" > "$T/bin/fn.sh"
[ -s "$T/bin/fn.sh" ] && ok || bad "could not extract cost_row_source — markers missing?"
grep -q 'cost_row_source()' "$T/bin/fn.sh" && ok || bad "extraction did not capture the function"

# stub_tc <line-to-print> <exit-code>  (empty line = print nothing)
stub_tc() {
  { printf '#!/bin/bash\n'
    [ -n "$1" ] && printf 'printf "%%s\\n" %q\n' "$1"
    printf 'exit %s\n' "$2"
  } > "$T/bin/transcript-cost.sh"
  chmod +x "$T/bin/transcript-cost.sh"
}
# src_run <runner> <session-id> ; R_* come from the environment
src_run() {
  HARNESS="$T" PROJECT=demo STAGE=build \
  bash -c '
    . "$0"
    . "'"$T"'/bin/lib/cost-row.sh"
    STAMP() { echo 2026-09-14T20:00:00Z; }
    IN=""; OUTT=""; CR=""; CW=""; USD=""; ROW_SRC=none; rmodel=asked-for
    cost_row_source "$1" "$2" /work
    printf "%s|%s|%s|%s|%s|%s|%s\n" "$IN" "$OUTT" "$CR" "$CW" "$USD" "$ROW_SRC" "$rmodel"
  ' "$T/bin/fn.sh" "$1" "$2"
}

# a) a transcript answer wins, and renames the model to what actually ran
stub_tc "5|6|7|8|1.500000|really-ran|3|1|" 0
R=$(R_IN=1 R_OUT=1 R_CR=1 R_CW=1 R_USD=1.40 src_run claude sess-1)
[ "$R" = "5|6|7|8|1.500000|transcript|really-ran" ] \
  && ok || bad "a transcript reading must become the row (got $R)"

# b) no transcript, but the CLI envelope answered: the row is the envelope,
#    byte-for-byte what agent-call.sh wrote before this wave.
stub_tc "" 3
R=$(R_IN=11 R_OUT=22 R_CR=33 R_CW=44 R_USD=0.90 src_run claude sess-2)
[ "$R" = "11|22|33|44|0.90|result|asked-for" ] \
  && ok || bad "with no transcript the envelope must be the row (got $R)"

# c) neither: a row with rc, duration and who paid, and honest empty tokens.
stub_tc "" 3
R=$(src_run claude sess-3)
[ "$R" = "|||||none|asked-for" ] \
  && ok || bad "with neither source the row must be blank tokens and row_source=none (got $R)"

# d) a non-claude runner never consults a claude transcript, even when one would
#    answer — grok's session files are not claude's.
stub_tc "5|6|7|8|1.5|really-ran|3|1|" 0
R=$(R_IN=11 R_OUT=22 R_CR=33 R_CW=44 R_USD=0.90 src_run grok sess-4)
[ "$R" = "11|22|33|44|0.90|result|asked-for" ] \
  && ok || bad "a non-claude runner must take the envelope path (got $R)"

# e) THE KILL SWITCHES. Both turn off a NUMBER, never a row: the envelope still
#    writes, which is exactly the behaviour before this wave.
stub_tc "5|6|7|8|1.5|really-ran|3|1|" 0
R=$(COST_TRANSCRIPT_ROWS=0 R_IN=11 R_OUT=22 R_CR=33 R_CW=44 R_USD=0.90 src_run claude sess-5)
[ "$R" = "11|22|33|44|0.90|result|asked-for" ] \
  && ok || bad "COST_TRANSCRIPT_ROWS=0 must fall back to the envelope (got $R)"
touch "$T/flags/transcript-cost-off"
R=$(R_IN=11 R_OUT=22 R_CR=33 R_CW=44 R_USD=0.90 src_run claude sess-6)
[ "$R" = "11|22|33|44|0.90|result|asked-for" ] \
  && ok || bad "flags/transcript-cost-off must fall back to the envelope (got $R)"
rm -f "$T/flags/transcript-cost-off"

# f) THE COMPARE. A >20% disagreement is logged — that log is how the fleet
#    learns what `.usage` actually covers instead of assuming.
rm -f "$T/logs/cost-source-delta.log"
stub_tc "5|6|7|8|1.500000|really-ran|3|1|" 0
R_IN=1 R_USD=0.50 src_run claude sess-7 >/dev/null
grep -q 'transcript \$1.500000 vs result \$0.50' "$T/logs/cost-source-delta.log" 2>/dev/null \
  && ok || bad "a >20% gap between the two readings must be logged"
# ...and a reading that agrees is not logged. A line per call would be noise,
# and noise is how a real signal gets ignored.
rm -f "$T/logs/cost-source-delta.log"
stub_tc "5|6|7|8|1.000000|really-ran|3|1|" 0
R_IN=1 R_USD=0.95 src_run claude sess-8 >/dev/null
[ ! -s "$T/logs/cost-source-delta.log" ] \
  && ok || bad "a reading within the threshold must NOT be logged (got: $(cat "$T/logs/cost-source-delta.log"))"
# The threshold is a knob, not a constant.
rm -f "$T/logs/cost-source-delta.log"
R_IN=1 R_USD=0.95 COST_SOURCE_DELTA_PCT=1 src_run claude sess-9 >/dev/null
[ -s "$T/logs/cost-source-delta.log" ] \
  && ok || bad "COST_SOURCE_DELTA_PCT must lower the threshold"

# g) an unpriced model is carried through to the box's log, so a partial
#    cost_usd is discoverable without re-reading the transcript.
rm -f "$T/logs/claude-cost.log"
stub_tc "5|6|7|8|1.5|really-ran|3|1|weird-model" 0
src_run claude sess-10 >/dev/null
grep -q 'UNPRICED model(s) weird-model' "$T/logs/claude-cost.log" 2>/dev/null \
  && ok || bad "an unpriced model must be logged against the session"

# h) no session id (the uuid mint failed, or the switch was off at call time):
#    the envelope path, silently.
stub_tc "5|6|7|8|1.5|really-ran|3|1|" 0
R=$(R_IN=11 R_OUT=22 R_CR=33 R_CW=44 R_USD=0.90 src_run claude "")
[ "$R" = "11|22|33|44|0.90|result|asked-for" ] \
  && ok || bad "with no session id the envelope must be used (got $R)"

echo "transcript-cost: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
