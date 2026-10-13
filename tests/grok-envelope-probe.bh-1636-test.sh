#!/bin/bash
# tests/grok-envelope-probe.bh-1636-test.sh — bin/grok-envelope-probe.sh, the
# one metered call that decides whether GROK_OUTPUT_JSON may be flipped.
#
# BH-1636 item 1: (a) probe a grok 1.0.40 box to confirm the answer is at
# `.result`, (b) keep the real envelope and unified.jsonl as fixtures, (c) flip
# GROK_OUTPUT_JSON as a DB row. the operator, 2026-09-24: "A billed grok call must land a
# priced cost row." So the flip is gated on the probe's envelope carrying the
# nonce at .result AND pricing, and a probe is never bought twice or blind.
#
# DRIVEN: a fake grok at $HOME/.grok/bin/grok (argv recorded, envelope and
# unified.jsonl lines per FAKE_MODE) and a fake jobs-client (ledger and settings
# calls recorded). The model comes from the real resolver, bin/lib/model-route.sh,
# reading the box cache — the branch a box whose worker is down takes.
#   P1  good envelope: exit 0, three files, CAPTURED, ledger started -> ok,
#       no setting-set without --flip, the command printed.
#   P2  --flip: setting-set + read-back, exit 0.
#   P3  .result an object; P3b no dollars; P3c zero dollars -> exit 1, no flip.
#   P4  nonce missing; P4b ledger already ok -> no call; P4c ledger down -> no
#       call, exit 4, one ALERTS line.
#   P5  read-back mismatch -> exit 5, one ALERTS line.
#   P6  unified.jsonl holds only the probe session's lines.
#   P7  a key-shaped string in the capture -> nothing written, exit 1.
#   P8  floor / missing grok / refusal / empty stdout / timeout / no route.
#   P9  agent-call with GROK_OUTPUT_JSON=1 prices a probe-shaped envelope, and
#       without dollars says UNPRICED, never blank (D2, production entry point).
#   P10 the captured dir arms tests/cost-grok-usage.bh-1494-test.sh §A8.
#   P11 a good probe lands ONE priced logs/cost.csv row (stage
#       grok-envelope-probe, runner grok, the model, rc 0, tokens, cost_usd > 0,
#       the envelope's session id, note probe:ok).
#   P12 a .result miss is still billed: one priced row, no flip.
#   P13 tokens without dollars price from MODEL_PRICES; a table without the
#       model leaves cost_usd BLANK with UNPRICED:no-price (never 0); a real
#       timeout writes rc 124; a refusal writes a priced $0 naming the refusal.
#   P14 nothing called -> no row (already probed, in flight, below floor, no
#       grok, ledger down); a ledger that dies after the call still has the row.
# MUTATION (D1): delete the cost_row_emit line in bin/grok-envelope-probe.sh and
# P11 goes red.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/grok-envelope-probe.bh-1636-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PROBE="$DIR/bin/grok-envelope-probe.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
H="$T/h"; GH="$T/home"
mkdir -p "$H/logs" "$H/env" "$H/state/model-routes" "$GH/.grok/bin" "$GH/.grok/logs" "$T/fakebin"
# The price table the probe's cost row is priced from: grok-4.7 only, so a
# grok-4.6 row has no price (P13).
echo '{"per_token":{"grok-4.7":{"prompt":0.000002,"completion":0.000006,"cache_read":5e-7,"cache_write":null}}}' > "$T/prices.json"
: > "$H/env/global.env"
printf '0\tgrok-4.7\tgrok\n1\tgrok-4.6\tgrok\n' > "$H/state/model-routes/grok.default.tsv"

# --- fake grok -----------------------------------------------------------------
cat > "$GH/.grok/bin/grok" <<'EOF'
#!/bin/bash
if [ "${1:-}" = --version ]; then echo "grok ${FAKE_GROK_VERSION:-1.0.40} (eb1a2256660d)"; exit 0; fi
printf '%s\n' "$*" > "$FAKE_ARGV"
env > "$FAKE_ENVDUMP"
P=""; while [ $# -gt 0 ]; do case "$1" in -p) P="$2"; shift 2 ;; *) shift ;; esac; done
N="${P##* }"; S=sess-probe-7f3a
U="$HOME/.grok/logs/unified.jsonl"; mkdir -p "$(dirname "$U")"
printf '{"session_id":"%s","event":"turn","usage":{"input_tokens":812,"output_tokens":9}}\n' "$S" >> "$U"
printf '{"session_id":"sess-foreign-0000","event":"turn","usage":{"input_tokens":5,"output_tokens":1}}\n' >> "$U"
printf '{"session_id":"%s","event":"end"}\n' "$S" >> "$U"
base() { jq -nc --arg n "$N" --arg s "$S" '{type:"result",result:$n,session_id:$s,usage:{input_tokens:812,output_tokens:9,reasoning_tokens:3},total_cost_usd:0.0012}'; }
case "${FAKE_MODE:-good}" in
  good)      base ;;
  resobj)    base | jq -c '.result={text:.result}' ;;
  nocost)    base | jq -c 'del(.total_cost_usd)' ;;
  zerocost)  base | jq -c '.total_cost_usd=0' ;;
  nononce)   base | jq -c '.result="ok"' ;;
  nosession) base | jq -c 'del(.session_id)' ;;
  secret)    base | jq -c '.result=.result+" xai-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' ;;
  empty)     : ;;
  partial)   base | head -c 40 ;;
  refusal)   echo 'Error: API Error: 402 credit limit reached for team' >&2 ;;
  sleep)     sleep 5; base ;;  # determinism: ok the hang under test: the 1 s shimmed timeout kills this, nothing waits on it
esac
exit "${FAKE_RC:-0}"
EOF
chmod +x "$GH/.grok/bin/grok"

# --- fake jobs-client ------------------------------------------------------------
cat > "$T/jobs" <<'EOF'
#!/bin/bash
echo "$*" >> "$JOBS_LOG"
case "$1" in
  ledger-get) case "${FAKE_LEDGER:-up}" in down|get-down) echo; exit 1 ;; esac
              [ -s "$LEDGER_STATE" ] && { cat "$LEDGER_STATE"; echo; exit 0; }; echo; exit 2 ;;
  ledger-put) [ "${FAKE_LEDGER:-up}" = down ] && exit 1
              [ "${FAKE_LEDGER:-up}" = die-after-start ] && case "$4" in started*) ;; *) exit 1 ;; esac
              printf '%s' "$4" > "$LEDGER_STATE"; exit 0 ;;
  setting-set) printf '%s' "$3" > "$SETTING_STATE"; exit 0 ;;
  setting-get) if [ -n "${FAKE_READBACK:-}" ]; then echo "$FAKE_READBACK"; else cat "$SETTING_STATE"; echo; fi; exit 0 ;;
esac
exit 2
EOF
chmod +x "$T/jobs"

N=0
COST="$H/logs/cost.csv"
rows() { if [ -f "$COST" ]; then awk 'NR>1 && NF{n++} END{print n+0}' "$COST"; else echo 0; fi; }
# probe [args...] -> OUT RC NEWA (ALERTS lines added) CASE (its --out dir)
#                    NEWROWS (cost.csv rows added)
probe() {
  N=$((N+1)); CASE="$T/out/$N"
  local before=0 rbefore
  [ -f "$H/logs/ALERTS.log" ] && before=$(wc -l < "$H/logs/ALERTS.log")
  rbefore=$(rows)
  [ "${KEEP_LEDGER:-0}" = 1 ] || rm -f "$T/ledger"
  rm -f "$T/argv" "$T/setting" "$T/envdump"; : > "$T/jobs.log"
  OUT=$(env -u HARNESS_SECRET -u JOBS_URL -u GROK_MODEL \
        HOME="$GH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" PATH="$T/fakebin:$PATH" \
        GROK_PROBE_HOME="$GH" GROK_PROBE_JOBS="$T/jobs" HARNESS_ALERTS="$H/logs/ALERTS.log" \
        GROK_PROBE_CATALOG="$DIR/catalog/cli-min-versions.json" \
        JOBS_LOG="$T/jobs.log" LEDGER_STATE="$T/ledger" SETTING_STATE="$T/setting" \
        FAKE_ARGV="$T/argv" FAKE_ENVDUMP="$T/envdump" XAI_API_KEY=xai-should-be-unset-for-the-call \
        MODEL_PRICES="${PRICES:-$T/prices.json}" \
        bash "$PROBE" --out "$CASE" "$@" 2>&1); RC=$?
  NEWA=$(tail -n +$((before+1)) "$H/logs/ALERTS.log" 2>/dev/null)
  NEWROWS=$(( $(rows) - rbefore ))
}
# c <n> — field n of the newest cost.csv row
c() { tail -1 "$COST" 2>/dev/null | awk -F, -v n="$1" '{print $n}'; }
puts()     { grep '^ledger-put' "$T/jobs.log" | awk '{print $4}' | sed 's/:.*//' | paste -sd' '; }
flipped()  { grep -q '^setting-set' "$T/jobs.log"; }
UJ="$GH/.grok/logs/unified.jsonl"

# ── P1 ────────────────────────────────────────────────────────────────────────
: > "$UJ"; printf '{"session_id":"sess-probe-7f3a","event":"from-an-earlier-run"}\n' >> "$UJ"
probe
[ "$RC" = 0 ] && ok || bad "P1 a good probe must exit 0 (rc=$RC): $OUT"
[ -s "$CASE/envelope.json" ] && ok || bad "P1 envelope.json not written"
[ -s "$CASE/unified.jsonl" ] && ok || bad "P1 unified.jsonl not written"
head -1 "$CASE/PROVENANCE.md" 2>/dev/null | grep -q '^# CAPTURED' && ok || bad "P1 PROVENANCE.md must open with '# CAPTURED': $(head -1 "$CASE/PROVENANCE.md" 2>/dev/null)"
grep -q 'grok-usage.sh --envelope' "$CASE/PROVENANCE.md" 2>/dev/null && ok || bad "P1 PROVENANCE.md must carry the envelope read"
[ "$(puts)" = "started ok" ] && ok || bad "P1 ledger must go started -> ok: '$(puts)' ($(cat "$T/jobs.log"))"
grep -q '^ledger-put grok-envelope-probe 1.0.40:grok-4.7 ' "$T/jobs.log" && ok || bad "P1 ledger key must be <version>:<model>: $(cat "$T/jobs.log")"
flipped && bad "P1 no --flip must not write the setting" || ok
grep -q 'setting-set lib.agent-call.grok_output_json 1' <<<"$OUT" && ok || bad "P1 the flip command must be printed: $OUT"
grep -q -- '-m grok-4.7' "$T/argv" && ok || bad "P1 the model must come from grok.default rung 0: $(cat "$T/argv" 2>/dev/null)"
for f in --always-approve '--output-format json' '--max-turns 1'; do
  grep -q -- "$f" "$T/argv" && ok || bad "P1 argv lacks $f: $(cat "$T/argv")"
done
grep -q '^XAI_API_KEY=' "$T/envdump" && bad "P1 XAI_API_KEY must be unset for a subscription probe" || ok
[ "$(jq -r .result "$CASE/envelope.json")" = "$(awk '{print $NF}' "$T/argv")" ] && ok || bad "P1 envelope.result is the nonce"
[ -z "$NEWA" ] && ok || bad "P1 a good probe wrote ALERTS: $NEWA"
P1_DIR="$CASE"

# ── P11 (on P1's run): one priced cost row ────────────────────────────────────
[ "$NEWROWS" = 1 ] && ok || bad "P11 a billed probe must write exactly one cost.csv row (got $NEWROWS): $(cat "$COST" 2>/dev/null)"
# TEST-CHANGE BH-2537: 25 -> 26 on the header (guard_fp); the probe's row stays 25.
[ "$(head -1 "$COST" 2>/dev/null | awk -F, '{print NF}')" = 26 ] && ok || bad "P11 cost.csv must open with the 26-column header (guard_fp, BH-2537): $(head -1 "$COST" 2>/dev/null)"
[ "$(tail -1 "$COST" 2>/dev/null | awk -F, '{print NF}')" = 25 ] && ok || bad "P11 the row must have 25 fields: $(tail -1 "$COST" 2>/dev/null)"
[ "$(c 4)" = grok-envelope-probe ] && ok || bad "P11 stage: '$(c 4)'"
[ "$(c 5)" = grok ] && ok || bad "P11 runner: '$(c 5)'"
[ "$(c 6)" = grok-4.7 ] && ok || bad "P11 model: '$(c 6)'"
[ "$(c 7)" = 0 ] && ok || bad "P11 rc: '$(c 7)'"
[ -n "$(c 9)" ] && [ -n "$(c 10)" ] && ok || bad "P11 tokens in/out must be on the row: '$(c 9)' '$(c 10)'"
awk -v u="$(c 13)" 'BEGIN{exit !(u+0 > 0)}' && ok || bad "P11 cost_usd must be > 0: '$(c 13)'"
[ "$(c 17)" = sess-probe-7f3a ] && ok || bad "P11 session_id: '$(c 17)'"
[ "$(c 18)" = result ] && ok || bad "P11 row_source: '$(c 18)'"
case "$(c 24)" in probe:ok*) ok ;; *) bad "P11 note must start probe:ok: '$(c 24)'" ;; esac

# ── P6 (on P1's capture) ─────────────────────────────────────────────────────
grep -q 'sess-foreign-0000' "$P1_DIR/unified.jsonl" && bad "P6 a foreign session's line was captured" || ok
grep -q 'from-an-earlier-run' "$P1_DIR/unified.jsonl" && bad "P6 a line from before the call was captured" || ok
[ "$(wc -l < "$P1_DIR/unified.jsonl")" = 2 ] && ok || bad "P6 expected the probe's 2 lines: $(cat "$P1_DIR/unified.jsonl")"
# no session id -> no unified.jsonl, and PROVENANCE says so
FAKE_MODE=nosession probe
[ ! -e "$CASE/unified.jsonl" ] && ok || bad "P6 no session id must write no unified.jsonl"
grep -qi 'no session id' "$CASE/PROVENANCE.md" 2>/dev/null && ok || bad "P6 PROVENANCE must say there was no session id"

# ── P2 ────────────────────────────────────────────────────────────────────────
probe --flip
[ "$RC" = 0 ] && ok || bad "P2 --flip on a good probe must exit 0 (rc=$RC): $OUT"
grep -q '^setting-set lib.agent-call.grok_output_json 1 BH-1636 probe 1.0.40/grok-4.7' "$T/jobs.log" && ok || bad "P2 setting-set: $(cat "$T/jobs.log")"
grep -q '^setting-get lib.agent-call.grok_output_json$' "$T/jobs.log" && ok || bad "P2 no read-back: $(cat "$T/jobs.log")"
[ "$(grep -n '^ledger-put.* ok ' "$T/jobs.log" | cut -d: -f1)" -lt "$(grep -n '^setting-set' "$T/jobs.log" | cut -d: -f1)" ] && ok \
  || bad "P2 the verdict must be in the ledger before the flip: $(cat "$T/jobs.log")"

# ── P3 / P3b / P3c / P4 : billed, not good enough -> no flip ──────────────────
for m in resobj:result-field-miss nocost:unpriced zerocost:unpriced nononce:result-field-miss; do
  FAKE_MODE="${m%%:*}" probe --flip
  [ "$RC" = 1 ] && ok || bad "P3/4 ${m%%:*} must exit 1 (rc=$RC): $OUT"
  flipped && bad "P3/4 ${m%%:*} flipped the setting" || ok
  [ "$(puts)" = "started billed-fail" ] && ok || bad "P3/4 ${m%%:*} ledger: '$(puts)'"
  grep -q "billed-fail ${m##*:}" "$T/jobs.log" && ok || bad "P3/4 ${m%%:*} detail must be ${m##*:}: $(cat "$T/jobs.log")"
  [ "$(grep -c . <<<"$NEWA")" = 1 ] && ok || bad "P3/4 ${m%%:*} one ALERTS line: $NEWA"
done

# ── P4b: already probed -> no call at all ─────────────────────────────────────
printf 'ok' > "$T/ledger"
KEEP_LEDGER=1 probe --flip
[ "$RC" = 0 ] && ok || bad "P4b already ok must exit 0 (rc=$RC): $OUT"
[ ! -e "$T/argv" ] && ok || bad "P4b grok was called although the ledger said ok"
flipped && bad "P4b flipped without a probe" || ok
printf 'billed-fail' > "$T/ledger"
KEEP_LEDGER=1 probe
[ ! -e "$T/argv" ] && ok || bad "P4b billed-fail is terminal: grok was called again"
# ...--force buys a new one
KEEP_LEDGER=1 probe --force
[ -e "$T/argv" ] && ok || bad "P4b --force must call"
# a fresh started row is a probe in flight -> no call; a stale one is a crash -> call
printf 'started:%s' "$(date +%s)" > "$T/ledger"
KEEP_LEDGER=1 probe
[ ! -e "$T/argv" ] && ok || bad "P4b a probe started seconds ago must not be doubled"
[ "$RC" = 4 ] && ok || bad "P4b in-flight rc=$RC"
printf 'started:%s' "$(( $(date +%s) - 7200 ))" > "$T/ledger"
KEEP_LEDGER=1 probe
[ -e "$T/argv" ] && ok || bad "P4b a started row 2h old is a crashed run and must be retried"
# a started row whose epoch is not digits is read as stale, and never evaluated
printf 'started:a[$(touch %s)]' "$T/pwned" > "$T/ledger"
KEEP_LEDGER=1 probe
[ ! -e "$T/pwned" ] && ok || bad "P4b the ledger's started value was evaluated as code"
[ -e "$T/argv" ] && ok || bad "P4b an unparseable started row is a crashed run and must be retried"
printf 'refused' > "$T/ledger"
KEEP_LEDGER=1 probe
[ -e "$T/argv" ] && ok || bad "P4b refused is not terminal: nothing was billed"

# ── P4c: ledger unreachable -> refuse to spend ────────────────────────────────
FAKE_LEDGER=down probe --flip
[ "$RC" = 4 ] && ok || bad "P4c ledger down must exit 4 (rc=$RC): $OUT"
[ ! -e "$T/argv" ] && ok || bad "P4c grok was called blind"
[ "$(grep -c . <<<"$NEWA")" = 1 ] && ok || bad "P4c one ALERTS line: $NEWA"
# only the READ fails (the write would work): still no call, because an
# unreadable ledger cannot say this probe was not already paid for
FAKE_LEDGER=get-down probe --flip
[ "$RC" = 4 ] && ok || bad "P4c an unreadable ledger must exit 4 (rc=$RC): $OUT"
[ ! -e "$T/argv" ] && ok || bad "P4c grok was called on an unreadable ledger"
grep -q 'unreachable' <<<"$NEWA" && ok || bad "P4c the ALERT must say the ledger is unreachable: $NEWA"
# the ledger dies between started and the verdict: verdict printed, alert, no flip
FAKE_LEDGER=die-after-start probe --flip
[ "$RC" = 4 ] && ok || bad "P4c ledger lost after the call must exit 4 (rc=$RC): $OUT"
flipped && bad "P4c an unrecorded spend flipped the setting" || ok
grep -q 'verdict ok' <<<"$OUT" && ok || bad "P4c the verdict must still be printed: $OUT"

# ── P5: read-back mismatch ────────────────────────────────────────────────────
FAKE_READBACK=0 probe --flip
[ "$RC" = 5 ] && ok || bad "P5 read-back 0 must exit 5 (rc=$RC): $OUT"
[ "$(grep -c . <<<"$NEWA")" = 1 ] && ok || bad "P5 one ALERTS line: $NEWA"
grep -q 'read back' <<<"$NEWA" && ok || bad "P5 the ALERT must name the read-back: $NEWA"

# ── P7: a secret in the capture -> nothing written ────────────────────────────
FAKE_MODE=secret probe --flip
[ "$RC" = 1 ] && ok || bad "P7 rc=$RC: $OUT"
[ -z "$(ls -A "$CASE" 2>/dev/null)" ] && ok || bad "P7 files were written: $(ls "$CASE")"
grep -q 'billed-fail secret-in-capture' "$T/jobs.log" && ok || bad "P7 ledger detail: $(cat "$T/jobs.log")"
flipped && bad "P7 flipped" || ok
grep -q 'xai-AAAA' <<<"$OUT$NEWA" && bad "P7 the secret was echoed" || ok

# ── P8: stops before any spend, and failed calls ──────────────────────────────
FAKE_GROK_VERSION=1.0.13 probe --flip
[ "$RC" = 3 ] && ok || bad "P8 1.0.13 must exit 3 (rc=$RC): $OUT"
[ ! -e "$T/argv" ] && ok || bad "P8 1.0.13 was called"
[ ! -s "$T/jobs.log" ] && ok || bad "P8 a below-floor probe must not even read the ledger"
[ "$(grep -c . <<<"$NEWA")" = 1 ] && ok || bad "P8 floor: one ALERTS line: $NEWA"
mv "$GH/.grok/bin/grok" "$T/grok.aside"
OUT=$(env -u HARNESS_SECRET HOME="$GH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" PATH="$T/fakebin:/usr/bin:/bin" \
      GROK_PROBE_HOME="$GH" GROK_PROBE_JOBS="$T/jobs" HARNESS_ALERTS="$H/logs/ALERTS.log" \
      JOBS_LOG="$T/jobs.log" bash "$PROBE" --out "$T/out/nogrok" 2>&1); RC=$?
mv "$T/grok.aside" "$GH/.grok/bin/grok"
[ "$RC" = 3 ] && ok || bad "P8 no grok must exit 3 (rc=$RC): $OUT"
FAKE_MODE=refusal FAKE_RC=1 probe --flip
[ "$RC" = 1 ] && ok || bad "P8 refusal rc=$RC: $OUT"
[ "$(puts)" = "started refused" ] && ok || bad "P8 a refusal is 'refused', not billed: '$(puts)'"
flipped && bad "P8 refusal flipped" || ok
FAKE_MODE=empty probe --flip
[ "$RC" = 1 ] && ok || bad "P8 empty stdout rc=$RC"
grep -q 'billed-fail empty-envelope' "$T/jobs.log" && ok || bad "P8 empty stdout: $(cat "$T/jobs.log")"
FAKE_MODE=partial FAKE_RC=124 probe --flip
[ "$RC" = 1 ] && ok || bad "P8 timeout rc=$RC"
grep -q 'billed-fail rc=124' "$T/jobs.log" && ok || bad "P8 timeout: $(cat "$T/jobs.log")"
flipped && bad "P8 timeout flipped" || ok
mv "$H/state/model-routes/grok.default.tsv" "$T/route.aside"
probe --flip
mv "$T/route.aside" "$H/state/model-routes/grok.default.tsv"
[ "$RC" = 3 ] && ok || bad "P8 no grok.default route must exit 3 (rc=$RC): $OUT"
[ ! -e "$T/argv" ] && ok || bad "P8 no route: grok was called with a guessed model"
probe --model grok-4.6
grep -q -- '-m grok-4.6' "$T/argv" && ok || bad "P8 --model must win: $(cat "$T/argv")"

# ── P12: a .result miss is billed: one priced row, no flip ────────────────────
FAKE_MODE=resobj probe --flip
[ "$NEWROWS" = 1 ] && ok || bad "P12 result-field-miss must write one row (got $NEWROWS)"
awk -v u="$(c 13)" 'BEGIN{exit !(u+0 > 0)}' && ok || bad "P12 cost_usd must be > 0: '$(c 13)'"
[ "$(c 24)" = probe:billed-fail:result-field-miss ] && ok || bad "P12 note: '$(c 24)'"
flipped && bad "P12 flipped" || ok

# ── P13: pricing from the table, unpriced, timeout, refusal ───────────────────
FAKE_MODE=nocost probe
[ "$NEWROWS" = 1 ] && ok || bad "P13 nocost must write one row (got $NEWROWS)"
# 812*0.000002 + (9+3 reasoning)*0.000006 = 0.001696; the point is > 0 from the table
awk -v u="$(c 13)" 'BEGIN{exit !(u+0 > 0)}' && ok || bad "P13 tokens with no dollars must price from MODEL_PRICES: '$(c 13)' ($(tail -1 "$COST"))"
[ -z "$(c 19)" ] && ok || bad "P13 result_usd must stay blank when the vendor said no dollars: '$(c 19)'"
FAKE_MODE=nocost probe --model grok-4.6
[ "$NEWROWS" = 1 ] && ok || bad "P13 unpriced must still write one row (got $NEWROWS)"
[ -z "$(c 13)" ] && ok || bad "P13 a model the table lacks must leave cost_usd BLANK, never 0: '$(c 13)'"
grep -q 'UNPRICED:no-price:grok-4.6' <<<"$(c 24)" && ok || bad "P13 note must say UNPRICED:no-price: '$(c 24)'"
# a REAL timeout: the 180 s bound shimmed to 1 s, a grok that sleeps 5
printf '#!/bin/bash\nshift\nexec %s 1 "$@"\n' "$(command -v timeout)" > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"
FAKE_MODE=sleep probe --flip
rm -f "$T/fakebin/timeout"
[ "$RC" = 1 ] && ok || bad "P13 timeout rc=$RC: $OUT"
[ "$NEWROWS" = 1 ] && ok || bad "P13 a timed-out call must write one row (got $NEWROWS)"
[ "$(c 7)" = 124 ] && ok || bad "P13 timeout row rc must be 124: '$(c 7)'"
[ "$(c 13)" != 0 ] && ok || bad "P13 a timed-out billed call must not read as \$0"
[ "$(c 24)" = probe:billed-fail:rc=124 ] && ok || bad "P13 timeout note: '$(c 24)'"
flipped && bad "P13 timeout flipped" || ok
FAKE_MODE=refusal FAKE_RC=1 probe --flip
[ "$NEWROWS" = 1 ] && ok || bad "P13 a refusal must write one row (got $NEWROWS)"
[ "$(c 13)" = 0 ] && ok || bad "P13 a refusal is a priced \$0: '$(c 13)'"
grep -q 'refused' <<<"$(c 24)" && ok || bad "P13 refusal note: '$(c 24)'"

# ── P14: nothing called -> no row; a lost ledger after the call keeps it ──────
printf 'ok' > "$T/ledger"
KEEP_LEDGER=1 probe --flip
[ "$NEWROWS" = 0 ] && ok || bad "P14 already probed wrote a row ($NEWROWS)"
printf 'started:%s' "$(date +%s)" > "$T/ledger"
KEEP_LEDGER=1 probe
[ "$NEWROWS" = 0 ] && ok || bad "P14 in flight wrote a row ($NEWROWS)"
FAKE_GROK_VERSION=1.0.13 probe --flip
[ "$NEWROWS" = 0 ] && ok || bad "P14 below floor wrote a row ($NEWROWS)"
FAKE_LEDGER=down probe --flip
[ "$NEWROWS" = 0 ] && ok || bad "P14 ledger down wrote a row ($NEWROWS)"
mv "$GH/.grok/bin/grok" "$T/grok.aside"
R0=$(rows)
env -u HARNESS_SECRET HOME="$GH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" PATH="$T/fakebin:/usr/bin:/bin" \
    GROK_PROBE_HOME="$GH" GROK_PROBE_JOBS="$T/jobs" HARNESS_ALERTS="$H/logs/ALERTS.log" \
    JOBS_LOG="$T/jobs.log" bash "$PROBE" --out "$T/out/nogrok2" >/dev/null 2>&1
mv "$T/grok.aside" "$GH/.grok/bin/grok"
[ "$(rows)" = "$R0" ] && ok || bad "P14 no grok wrote a row"
FAKE_LEDGER=die-after-start probe --flip
[ "$RC" = 4 ] && ok || bad "P14 ordering: a ledger lost after the call must exit 4 (rc=$RC)"
[ "$NEWROWS" = 1 ] && ok || bad "P14 ordering: the cost row must be written BEFORE the ledger verdict (got $NEWROWS)"

# ── P9: the production consumer prices a probe-shaped envelope ────────────────
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
A="$T/ac"; mkdir -p "$A/logs" "$A/flags" "$A/locks" "$A/env" "$A/.grok/bin" "$A/fakebin"
: > "$A/env/global.env"
mrs_fixture "$A" testproj
cp "$P1_DIR/envelope.json" "$T/p9-envelope.json"
cat > "$A/.grok/bin/grok" <<'EOF'
#!/bin/bash
for a in "$@"; do [ "$a" = json ] && { cat "$GROK_ENVELOPE"; exit 0; }; done
echo plain; exit 0
EOF
chmod +x "$A/.grok/bin/grok"
printf '#!/bin/bash\necho subscription\n' > "$A/fakebin/billing-mode.sh"; chmod +x "$A/fakebin/billing-mode.sh"
printf '#!/bin/bash\n[ "${1:-}" = --kill-after ] && shift 2\ncase "${1:-}" in --kill-after=*) shift ;; esac\nshift\nexec "$@"\n' > "$A/fakebin/timeout"
chmod +x "$A/fakebin/timeout"
echo '{"per_token":{}}' > "$A/prices.json"
drive() { # drive <envelope>
  ( unset OPENROUTER_API_KEY FIREWORKS_API_KEY XAI_API_KEY GROK_CODE_XAI_API_KEY \
          OPENAI_API_KEY CODEX_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY HARNESS_SECRET
    export HOME="$A" HARNESS="$A" HARNESS_ENV_DIR="$A/env" PATH="$A/fakebin:$PATH" MODEL_PRICES="$A/prices.json" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" GROK_ENVELOPE="$1" \
           RUNNER_TRIAGE=grok RUNNER_TRIAGE_FALLBACK=grok GROK_OUTPUT_JSON=1
    bash "$DIR/bin/agent-call.sh" triage testproj grok-4.7 60 "$A/out.txt" "hello" >/dev/null 2>&1 )
}
col() { tail -1 "$A/logs/cost.csv" | awk -F, -v c="$1" '{print $c}'; }
drive "$T/p9-envelope.json"
[ "$(col 13)" = 0.001200 ] && ok || bad "P9 cost_usd must be the probe envelope's dollars: '$(col 13)' ($(tail -1 "$A/logs/cost.csv" 2>/dev/null))"
[ "$(col 18)" = ledger ] && ok || bad "P9 row_source: '$(col 18)'"
[ "$(cat "$A/out.txt")" = "$(jq -r .result "$T/p9-envelope.json")" ] && ok || bad "P9 \$OUT must be the envelope's .result"
jq -c 'del(.total_cost_usd)' "$T/p9-envelope.json" > "$T/p9-nocost.json"
drive "$T/p9-nocost.json"
[ -z "$(col 13)" ] && ok || bad "P9 no dollars and no price must leave cost_usd empty, not a number: '$(col 13)'"
grep -q "UNPRICED:no-price:$(col 6)" <<<"$(col 24)" && ok || bad "P9 an unpriced grok row must say so: note='$(col 24)'"

# ── P10: the capture arms §A8 of the bh-1494 suite ────────────────────────────
R="$T/repo"; mkdir -p "$R/tests"
cp -r "$DIR/bin" "$DIR/catalog" "$R/"
cp -r "$DIR/tests/lib" "$DIR/tests/fixtures" "$R/tests/"
cp "$DIR/tests/cost-grok-usage.bh-1494-test.sh" "$R/tests/"
cp -r "$P1_DIR" "$R/tests/fixtures/grok-usage/9.9.9"
A8=$(HARNESS_TEST_SANDBOX=1 bash "$R/tests/cost-grok-usage.bh-1494-test.sh" 2>&1); A8RC=$?
[ "$A8RC" = 0 ] && ok || bad "P10 the bh-1494 suite over a CAPTURED fixture must pass (rc=$A8RC): $(grep -E 'FAIL|A8' <<<"$A8")"
grep -q 'TODO(BH-1494)' <<<"$A8" && bad "P10 a CAPTURED fixture must replace the TODO: $(grep TODO <<<"$A8")" || ok
grep -q 'A8 9.9.9' <<<"$A8" && ok || bad "P10 §A8 must name the captured dir it checked: $(grep -i a8 <<<"$A8")"
jq -c 'del(.total_cost_usd)' "$P1_DIR/envelope.json" > "$R/tests/fixtures/grok-usage/9.9.9/envelope.json"
A8=$(HARNESS_TEST_SANDBOX=1 bash "$R/tests/cost-grok-usage.bh-1494-test.sh" 2>&1); A8RC=$?
[ "$A8RC" != 0 ] && ok || bad "P10 a CAPTURED envelope without dollars must fail §A8"
grep -q 'FAIL: A8' <<<"$A8" && ok || bad "P10 the failure must be §A8's: $(grep FAIL <<<"$A8")"

echo "grok-envelope-probe.bh-1636-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
