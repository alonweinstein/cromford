#!/bin/bash
# BH-2492 — follow-ups from the review of PR #2486 (BH-2457).
#
# 1. bin/review-prs.sh hands RP_AC_ENV to `env` through the
#    ${RP_AC_ENV[@]+"${RP_AC_ENV[@]}"} idiom, so an empty array expands to no
#    words without touching an unset array. The plain "${RP_AC_ENV[@]}" is an
#    "unbound variable" error under `set -u` on bash < 4.4 (macOS 3.2).
# 2. REVIEW_D1_HOLD_MAX_H has one bound, the registry's 0-168: the code, its
#    log line and the registry note all say so. A value above 168 goes down the
#    same logged garbage path as a non-number and reads as the default 6.
#
# N3-N5 drive the REAL rp_d1_hold_or_fallback, pulled out of bin/review-prs.sh,
# with everything it calls stubbed. The d1_off half of the ticket is pinned in
# tests/review-prs-gh-dedup-test.sh V6.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RP="$DIR/bin/review-prs.sh"
REG="$DIR/catalog/lanes.d/review-prs.json"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# ═══ N1 — the idiom's expansion under set -u ═══
N1_SNIPPET='set -u
a=(); set -- ${a[@]+"${a[@]}"}; [ $# -eq 0 ] || { echo "empty gave $# words"; exit 1; }
a=(X=1 "Y=two words"); set -- ${a[@]+"${a[@]}"}
[ $# -eq 2 ] && [ "$2" = "Y=two words" ] || { echo "two gave $# words, second [${2:-}]"; exit 1; }'
out=$(bash -c "$N1_SNIPPET" 2>&1) && ok || bad "N1 the idiom under set -u on $(bash --version | head -1): $out"
old=""
for sh in bash3.2 bash3 /bin/bash; do
  p=$(command -v "$sh" 2>/dev/null) || continue
  case "$("$p" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"' 2>/dev/null)" in
    3.*|4.[0-3]) old="$p"; break ;;
  esac
done
if [ -n "$old" ]; then
  out=$("$old" -c "$N1_SNIPPET" 2>&1) && ok || bad "N1 the idiom under set -u on $old: $out"
else
  echo "N1 note: no bash < 4.4 on this box, so the idiom ran on $(bash -c 'echo $BASH_VERSION') only"
fi

# ═══ N2 — the env line of the paid review uses the idiom ═══
line=$(grep -E '^[[:space:]]*env .*AGENT_CALL_FP=' "$RP")
if [ -z "$line" ]; then
  bad "N2 no 'env … AGENT_CALL_FP=' line in bin/review-prs.sh"
else
  case "$line" in
    *'${RP_AC_ENV[@]+"${RP_AC_ENV[@]}"}'*) ok ;;
    *) bad "N2 the env line does not guard RP_AC_ENV: $line" ;;
  esac
fi
n=$(grep -c 'env "${RP_AC_ENV\[@\]}"' "$RP")
[ "$n" -eq 0 ] && ok || bad "N2 bin/review-prs.sh still expands \"\${RP_AC_ENV[@]}\" bare ($n line(s))"

# ═══ N3-N5 — REVIEW_D1_HOLD_MAX_H is bounded by the registry max ═══
FN=$(awk '/^rp_d1_hold_or_fallback\(\) \{/,/^}/' "$RP")
REGMAX=$(jq -r '.. | objects | select(.env? == "REVIEW_D1_HOLD_MAX_H") | .max' "$REG")
if [ -z "$FN" ]; then
  bad "N3 rp_d1_hold_or_fallback() not found in bin/review-prs.sh"
elif ! [ "$REGMAX" -ge 0 ] 2>/dev/null; then
  bad "N3 no numeric max for REVIEW_D1_HOLD_MAX_H in $REG: '$REGMAX'"
else
  mkdir -p "$T/h/bin" "$T/h/state"
  printf '#!/bin/bash\n[ "$1" = claude ] && echo subscription || echo metered\n' > "$T/h/bin/billing-mode.sh"
  printf '#!/bin/bash\necho "$*" >> "%s/alerts.log"\n' "$T" > "$T/h/bin/alert-line.sh"
  printf '#!/bin/bash\necho "$*" >> "%s/beats.log"\n' "$T" > "$T/h/bin/beat.sh"
  chmod +x "$T/h/bin/"*.sh

  # run_fn <max> — prints the rc of the real function with the outage 7h old.
  run_fn() {
    rm -f "$T/log" "$T/h/state/p.review-d1-hold.fallback"
    (
      STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
      rp_d1_since() { echo $(( $(date +%s) - 7 * 3600 )); }
      rp_d1_hold() { :; }
      LOG="$T/log" PROJECT=p HARNESS="$T/h" RP_D1_KNOB_LOGGED=0
      RP_D1_HOLD_FILE="$T/h/state/p.review-d1-hold"
      unset AGENT_CALL_RUNNERS
      export REVIEW_D1_HOLD_MAX_H="$1"
      eval "$FN"
      rp_d1_hold_or_fallback 7 abcdef1234567
      echo "rc=$?"
    ) 2>&1 | tail -1
  }
  knob_lines() { local n; n=$(grep -c 'REVIEW_D1_HOLD_MAX_H is ' "$T/log" 2>/dev/null); echo "${n:-0}"; }

  # N3 — the registry max itself is a valid hold: 7h < 168h, held.
  r=$(run_fn "$REGMAX")
  [ "$r" = rc=3 ] && ok || bad "N3 REVIEW_D1_HOLD_MAX_H=$REGMAX (the registry max) at 7h must hold (rc 3): $r"
  [ "$(knob_lines)" = 0 ] && ok || bad "N3 the registry max was logged as not an hour count: $(cat "$T/log" 2>/dev/null)"

  # N4 — one past it is out of range: the default 6, and 7h is past that.
  r=$(run_fn $((REGMAX + 1)))
  [ "$r" = rc=1 ] && ok || bad "N4 REVIEW_D1_HOLD_MAX_H=$((REGMAX + 1)) must read as the default 6 and fall back at 7h (rc 1): $r"

  # N5 — exactly one knob line, and it names the registry's range.
  [ "$(knob_lines)" = 1 ] && ok || bad "N5 expected one REVIEW_D1_HOLD_MAX_H log line, got $(knob_lines): $(cat "$T/log" 2>/dev/null)"
  grep 'REVIEW_D1_HOLD_MAX_H is ' "$T/log" 2>/dev/null | grep -q "0-$REGMAX" \
    && ok || bad "N5 the knob line must say 0-$REGMAX: $(grep 'REVIEW_D1_HOLD_MAX_H is ' "$T/log" 2>/dev/null)"
  note=$(jq -r '.. | objects | select(.env? == "REVIEW_D1_HOLD_MAX_H") | .note' "$REG")
  case "$note" in *"0-$REGMAX"*) ok ;; *) bad "N5 the registry note must say 0-$REGMAX: $note" ;; esac
  case "$note" in *0-999*) bad "N5 the registry note still says 0-999" ;; *) ok ;; esac
fi

echo "review-prs-d1-nits.bh-2492: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
