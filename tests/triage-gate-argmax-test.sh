#!/bin/bash
# tests/triage-gate-argmax-test.sh — triage-gate must not put a board fingerprint
# on jq's argv (--argjson). Linux MAX_ARG_STRLEN (~128KiB) is smaller than a
# 400-ticket fingerprint; project-9 crossed it at 434 tickets / 135KB and the
# gate fail-opened a full paid session every tick.
#
# Run from anywhere: tests/triage-gate-argmax-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

GATE="$DIR/bin/triage-gate.sh"

# 1. the live merge line must not use --argjson on $fp (the ARG_MAX bug).
if grep -n -- '--argjson t "$fp"' "$GATE" >/dev/null; then
  bad 'triage-gate.sh still passes $fp via --argjson (argv bomb)'
else
  ok
fi

# 2. it must stream $fp via jq `input` (stdin), not argv.
if grep -n -- '. + {($bid): input}' "$GATE" >/dev/null; then
  ok
else
  bad 'triage-gate.sh missing stdin merge (. + {($bid): input})'
fi

# 3. stdin merge equals --argjson on a small fingerprint (behaviour lock).
small='[{"id":"T-1","status":"open","waitingOn":null,"triageVerdict":null,"commentCount":0,"lastActivityAt":"a","title":"x"}]'
via_arg=$(jq -cS --arg bid b1 --argjson t "$small" '. + {($bid): $t}' <<<"{}")
via_in=$(jq -cS --arg bid b1 '. + {($bid): input}' <<<"{}"$'\n'"$small")
[ "$via_arg" = "$via_in" ] && ok || bad "small merge mismatch argjson=$via_arg stdin=$via_in"

# 4. a fingerprint bigger than MAX_ARG_STRLEN: --argjson dies, stdin merge works
#    and yields the expected ticket count. 140KB is over the ~132KB cliff we
#    measured on the fleet kernels (131072 OK, 132696 FAIL).
big=$(python3 -c 'import json; print(json.dumps([{"id":f"T-{i}","status":"open","waitingOn":None,"triageVerdict":None,"commentCount":0,"lastActivityAt":"a","title":"x"*160} for i in range(450)], indent=2))')
bytes=${#big}
if [ "$bytes" -lt 140000 ]; then
  bad "fixture too small ($bytes bytes); need >=140000 to clear MAX_ARG_STRLEN"
else
  ok
fi

arg_rc=0
jq -cS --arg bid product-board --argjson t "$big" '. + {($bid): $t}' <<<"{}" >/dev/null 2>/tmp/triage-gate-argmax.err || arg_rc=$?
if [ "$arg_rc" -ne 0 ] && grep -qi 'Argument list too long' /tmp/triage-gate-argmax.err; then
  ok
else
  # Some kernels have a larger MAX_ARG_STRLEN; still require stdin merge to work.
  echo "note: --argjson did not hit ARG_MAX here (rc=$arg_rc bytes=$bytes) — stdin path still asserted"
  ok
fi

got=$(jq -cS --arg bid product-board '. + {($bid): input}' <<<"{}"$'\n'"$big") || { bad 'stdin merge failed on 140KB+ fingerprint'; got=''; }
n=$(jq '."product-board"|length' <<<"$got" 2>/dev/null || echo 0)
[ "$n" = "450" ] && ok || bad "stdin merge ticket count=$n want=450 (bytes=$bytes)"

# 5. keymap persist must not pass $all via the jq argfile flag (removed in
#    jq 1.7). BH-411 wrote that flag plus process-sub printf, which SIGPIPEs
#    on every tick; run-triage 2>> ALERTS.log turns that into a fleet alert
#    (project-9, 500 tickets).
if grep -n -- '--argfile' "$GATE" >/dev/null; then
  bad 'triage-gate.sh still uses the jq argfile flag (jq 1.7 unknown option → printf SIGPIPE)'
else
  ok
fi

# 6. keymap persist must read $all via here-string/stdin, not process-sub printf.
if grep -n -- '<<<"$all"' "$GATE" >/dev/null; then
  ok
else
  bad 'triage-gate.sh keymap persist does not here-string $all'
fi

# 7. behaviour lock: here-string keymap jq on a board object, and on a 140KB+
#    fingerprint, produces the id<->key map with no stderr.
km_err=$(mktemp)
km_small='{"product-board":[{"id":"1","key":"TK-1","title":"x"},{"id":"2","title":"n"}]}'
km_got=$(jq -S '[ .[] | .[] | select(.key) | {(.id | tostring): .key, (.key): (.id | tostring)} ] | add // {}' <<<"$km_small" 2>"$km_err")
km_id=$(jq -r '.["1"]' <<<"$km_got")
km_key=$(jq -r '.["TK-1"]' <<<"$km_got")
if [ "$km_id" = "TK-1" ] && [ "$km_key" = "1" ] && [ ! -s "$km_err" ]; then
  ok
else
  bad "small keymap: id=$km_id key=$km_key err=$(tr '\n' ' ' <"$km_err")"
fi

# wrap the ARG_MAX-sized ticket list as a board object (same shape as $all).
km_big=$(jq -cS --arg bid product-board '. + {($bid): input}' <<<"{}"$'\n'"$big")
km_big_out=$(jq -S '[ .[] | .[] | select(.key) | {(.id | tostring): .key, (.key): (.id | tostring)} ] | add // {}' <<<"$km_big" 2>"$km_err")
# fixture tickets have no .key, so the map is {}.
if [ "$km_big_out" = "{}" ] && [ ! -s "$km_err" ]; then
  ok
else
  bad "big keymap: out=$(printf '%s' "$km_big_out" | tr '\n' ' ') err=$(tr '\n' ' ' <"$km_err")"
fi
rm -f "$km_err"

rm -f /tmp/triage-gate-argmax.err
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
