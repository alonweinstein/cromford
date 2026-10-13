#!/bin/bash
# tests/daily-digest-summary.bh-3688-test.sh — BH-3707 (BH-3688.4): the optional
# LLM paragraph, dd_summary in bin/lib/daily-digest-summary.sh.
#
# A scratch harness $T/h holds copies of the real lib and the real prompt, and a
# recording $T/h/bin/agent-call.sh stub that logs its argv, the AGENT_CALL_* env
# and the prompt it was handed, then writes a scripted answer and exits with a
# scripted rc. The route (lane_role_model / lane_model_ladder) and the jobs
# ledger (job_ledger_row / job_ledger_put) are shell stubs backed by files, so
# dedup is checked across separate runs exactly as the lane would call it.
#
#   S1  off by default: no call, no ledger read, no out file.
#   S2  one call, the exact argv and env, a cleaned paragraph, ledger ok.
#   S3  the same digest with another as_of reuses the text, no second call.
#   S4  an answer that cleans to empty is terminal `empty`; S4b rc 1 is
#       terminal `billed-failed`; S4c any other status is terminal too.
#   S5  rc 77 writes no ledger row and the rerun calls.
#   S6  an unreadable ledger fails closed; S6b an ok row with a broken detail.
#   S7  route rc 75: no call; S7b a non-claude runner: no call.
#   S8  a zero or malformed cap: no call.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/daily-digest-summary.bh-3688-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "daily-digest-summary: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

SRC="$DIR/bin/lib/daily-digest-summary.sh"
PROMPT="$DIR/catalog/prompts/daily-digest-summary.md"
FIX="$DIR/tests/fixtures/daily-digest/fixture-day.json"
for f in "$SRC" "$PROMPT" "$FIX"; do [ -f "$f" ] && ok || bad "missing $f"; done

H="$T/h"
export FXT="$T/fx"
mkdir -p "$H/bin/lib" "$H/catalog/prompts" "$FXT/ledger"
cp "$SRC" "$H/bin/lib/daily-digest-summary.sh" 2>/dev/null
cp "$PROMPT" "$H/catalog/prompts/daily-digest-summary.md" 2>/dev/null
LIB="$H/bin/lib/daily-digest-summary.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
n=$(( $(wc -l < "$FXT/calls.log" 2>/dev/null || echo 0) + 1 ))
{ printf 'call'; printf ' [%s]' "$@"; printf '\n'; } >> "$FXT/calls.log"
env | grep -E '^AGENT_CALL_' | sort > "$FXT/env.$n"
case "$6" in @*) cat "${6#@}" > "$FXT/prompt.$n" 2>/dev/null ;; *) printf '%s' "$6" > "$FXT/prompt.$n" ;; esac
cat "$FXT/answer" > "$5" 2>/dev/null
exit "$(cat "$FXT/stub.rc")"
SH
chmod +x "$H/bin/agent-call.sh"

# A fake model id built at runtime, never a vendor literal.
MODEL="stub-model-$(printf '%s' daily | cksum | cut -d' ' -f1)"

reset() {
  scratch_rm "$FXT"; mkdir -p "$FXT/ledger"
  printf '%s' "$MODEL" > "$FXT/model"
  printf 'claude' > "$FXT/runner"
  echo 0 > "$FXT/route.rc"; echo ok > "$FXT/ledger.rc"; echo 0 > "$FXT/stub.rc"
  # An answer with an em dash, an en dash, newlines and well over 600 chars.
  { printf 'We merged 2 PRs yesterday — one on cromford and one on project-5.\n\n'
    for i in $(seq 1 12); do printf 'Spend was $12.50 over 41 calls – line %s of the tail.\n' "$i"; done; } > "$FXT/answer"
  rm -f "$T/out"
}
# summ <json> [env ...]: runs the real dd_summary; rc in $T/rc
summ() {
  local json=$1; shift
  env "$@" bash -c '
    lane_role_model() { r=$(cat "$FXT/route.rc"); [ "$r" = 0 ] || return "$r"; cat "$FXT/model"; }
    lane_model_ladder() { printf "0\t%s\t%s\n" "$(cat "$FXT/model")" "$(cat "$FXT/runner")"; }
    job_ledger_row() {
      echo "$1 $2" >> "$FXT/ledger-reads.log"
      r=$(cat "$FXT/ledger.rc"); [ "$r" = ok ] || return "$r"
      [ -f "$FXT/ledger/$1.$2" ] || return 2
      cat "$FXT/ledger/$1.$2"
    }
    job_ledger_put() { jq -nc --arg s "$3" --arg d "${4:-}" "{status:\$s, detail:\$d}" > "$FXT/ledger/$1.$2"; }
    . "$1" || exit 9
    dd_summary "$2" "$3"' _ "$LIB" "$json" "$T/out" >/dev/null 2>"$T/err"
  echo $? > "$T/rc"
}
rc() { cat "$T/rc"; }
calls() { if [ -f "$FXT/calls.log" ]; then wc -l < "$FXT/calls.log"; else echo 0; fi; }
lstatus() { jq -r .status "$FXT/ledger/daily_digest_summary.$FP" 2>/dev/null; }
ON=(DAILY_DIGEST_LLM_SUMMARY=1 DAILY_DIGEST_LLM_MAX_USD=0.10)
FP=$(jq -S -c 'del(.as_of)' "$FIX" | sha256sum | cut -c1-64)

# ── S1: off by default ──────────────────────────────────────────────────────
reset; summ "$FIX" -u DAILY_DIGEST_LLM_SUMMARY
check "S1 rc 1 (got $(rc))" '[ "$(rc)" = 1 ]'
check "S1 no out file" '[ ! -e "$T/out" ]'
check "S1 no call" '[ "$(calls)" = 0 ]'
check "S1 no ledger read" '[ ! -s "$FXT/ledger-reads.log" ]'
reset; summ "$FIX" DAILY_DIGEST_LLM_SUMMARY=yes
check "S1 a knob of yes is off: no call" '[ "$(rc)" = 1 ] && [ "$(calls)" = 0 ]'

# ── S2: one call, exact argv and env ────────────────────────────────────────
reset; summ "$FIX" "${ON[@]}"
check "S2 rc 0 (got $(rc); $(cat "$T/err"))" '[ "$(rc)" = 0 ]'
check "S2 exactly one call ($(calls))" '[ "$(calls)" = 1 ]'
CALL=$(head -1 "$FXT/calls.log" 2>/dev/null)
check "S2 argv [$CALL]" '[[ $CALL == "call [daily-digest] [fleet] [$MODEL] [300] ["*"] [@/"*"]" ]]'
check "S2 AGENT_CALL_LANE" 'grep -qx "AGENT_CALL_LANE=daily-digest" "$FXT/env.1"'
check "S2 AGENT_CALL_FP is the canonical sha256" 'grep -qx "AGENT_CALL_FP=$FP" "$FXT/env.1"'
check "S2 AGENT_CALL_BUDGET_USD_DAILY_DIGEST" 'grep -qx "AGENT_CALL_BUDGET_USD_DAILY_DIGEST=0.10" "$FXT/env.1"'
check "S2 AGENT_CALL_RUNNERS" 'grep -qx "AGENT_CALL_RUNNERS=claude" "$FXT/env.1"'
check "S2 the prompt carries the Voice section" 'grep -q "^## Voice" "$FXT/prompt.1"'
check "S2 the prompt carries the digest" 'grep -q "2026-09-29" "$FXT/prompt.1" && grep -q "cromford" "$FXT/prompt.1"'
check "S2 the prompt drops as_of" '! grep -q "2026-09-30T07:00:05Z" "$FXT/prompt.1"'
OUT=$(cat "$T/out" 2>/dev/null)
check "S2 out is non-empty" '[ -n "$OUT" ]'
check "S2 no em or en dash" '! grep -q "[—–]" "$T/out"'
check "S2 one paragraph (one line)" '[ "$(wc -l < "$T/out")" -le 1 ] && [ "$(grep -c . "$T/out")" = 1 ]'
LEN=$(LC_ALL=C.UTF-8 bash -c 'x=$(cat "$1"); printf %s ${#x}' _ "$T/out")
check "S2 at most 600 chars ($LEN)" '[ "$LEN" -le 600 ] && [ "$LEN" -ge 500 ]'
check "S2 dashes become a comma" 'grep -q "yesterday, one on cromford" "$T/out"'
check "S2 ledger ok with the text" \
  '[ "$(lstatus)" = ok ] && [ "$(jq -r ".detail | fromjson | .text" "$FXT/ledger/daily_digest_summary.$FP")" = "$OUT" ]'
check "S2 the ledger was read before the call" '[ "$(head -1 "$FXT/ledger-reads.log")" = "daily_digest_summary $FP" ]'

# ── S3: another as_of, same digest: reuse ───────────────────────────────────
jq '.as_of = "2026-09-30T09:15:00Z"' "$FIX" > "$T/asof.json"
rm -f "$T/out"; summ "$T/asof.json" "${ON[@]}"
check "S3 rc 0 (got $(rc))" '[ "$(rc)" = 0 ]'
check "S3 no second call ($(calls))" '[ "$(calls)" = 1 ]'
check "S3 identical text" '[ "$(cat "$T/out" 2>/dev/null)" = "$OUT" ]'
jq '.throughput.merged = 3' "$FIX" > "$T/other.json"
rm -f "$T/out"; summ "$T/other.json" "${ON[@]}"
check "S3 a different digest does call ($(calls))" '[ "$(calls)" = 2 ]'

# ── S4: empty is billed and terminal ────────────────────────────────────────
reset; printf -- '— \n –\n' > "$FXT/answer"; summ "$FIX" "${ON[@]}"
check "S4 rc 1 (got $(rc))" '[ "$(rc)" = 1 ]'
check "S4 ledger empty ($(lstatus))" '[ "$(lstatus)" = empty ]'
check "S4 no out file" '[ ! -e "$T/out" ]'
summ "$FIX" "${ON[@]}"
check "S4 rerun: no call ($(calls)), rc 1" '[ "$(calls)" = 1 ] && [ "$(rc)" = 1 ]'
reset; echo 1 > "$FXT/stub.rc"; summ "$FIX" "${ON[@]}"
check "S4b rc 1 (got $(rc))" '[ "$(rc)" = 1 ]'
check "S4b ledger billed-failed ($(lstatus))" '[ "$(lstatus)" = billed-failed ]'
echo 0 > "$FXT/stub.rc"; summ "$FIX" "${ON[@]}"
check "S4b rerun: no call ($(calls))" '[ "$(calls)" = 1 ] && [ "$(rc)" = 1 ] && [ ! -e "$T/out" ]'
reset; jq -nc '{status:"weird", detail:""}' > "$FXT/ledger/daily_digest_summary.$FP"; summ "$FIX" "${ON[@]}"
check "S4c unknown status: no call, rc 1" '[ "$(calls)" = 0 ] && [ "$(rc)" = 1 ]'

# ── S5: rc 74-79 was not billed: no row, the rerun calls ───────────────────
reset; echo 77 > "$FXT/stub.rc"; summ "$FIX" "${ON[@]}"
check "S5 rc 1 (got $(rc))" '[ "$(rc)" = 1 ]'
check "S5 no ledger row" '[ ! -e "$FXT/ledger/daily_digest_summary.$FP" ]'
check "S5 no out file" '[ ! -e "$T/out" ]'
echo 0 > "$FXT/stub.rc"; summ "$FIX" "${ON[@]}"
check "S5 rerun calls ($(calls)) and succeeds" '[ "$(calls)" = 2 ] && [ "$(rc)" = 0 ] && [ "$(lstatus)" = ok ]'

# ── S6: an unreadable ledger fails closed ───────────────────────────────────
reset; echo 1 > "$FXT/ledger.rc"; summ "$FIX" "${ON[@]}"
check "S6 ledger rc 1: no call, rc 1" '[ "$(calls)" = 0 ] && [ "$(rc)" = 1 ] && [ ! -e "$T/out" ]'
reset; jq -nc '{status:"ok", detail:"not json"}' > "$FXT/ledger/daily_digest_summary.$FP"; summ "$FIX" "${ON[@]}"
check "S6b ok row with a broken detail: no call, rc 1" '[ "$(calls)" = 0 ] && [ "$(rc)" = 1 ] && [ ! -e "$T/out" ]'

# ── S7: no route, wrong runner ──────────────────────────────────────────────
reset; echo 75 > "$FXT/route.rc"; summ "$FIX" "${ON[@]}"
check "S7 route rc 75: no call, rc 1" '[ "$(calls)" = 0 ] && [ "$(rc)" = 1 ]'
reset; printf 'grok' > "$FXT/runner"; summ "$FIX" "${ON[@]}"
check "S7b runner grok: no call, rc 1" '[ "$(calls)" = 0 ] && [ "$(rc)" = 1 ]'
check "S7b says why on stderr" 'grep -q "grok" "$T/err"'

# ── S8: the cap ─────────────────────────────────────────────────────────────
for cap in 0 0.00 abc -1; do
  reset; summ "$FIX" DAILY_DIGEST_LLM_SUMMARY=1 DAILY_DIGEST_LLM_MAX_USD="$cap"
  check "S8 cap '$cap': no call, rc 1" '[ "$(calls)" = 0 ] && [ "$(rc)" = 1 ]'
done

# ── inputs ──────────────────────────────────────────────────────────────────
reset; summ "$T/nope.json" "${ON[@]}"
check "a missing JSON: no call, rc 1" '[ "$(calls)" = 0 ] && [ "$(rc)" = 1 ]'
bash -c '. "$1"; dd_summary only-one' _ "$LIB" >/dev/null 2>&1; RC=$?
check "1 arg: rc 2 (got $RC)" '[ "$RC" = 2 ]'

echo "daily-digest-summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
