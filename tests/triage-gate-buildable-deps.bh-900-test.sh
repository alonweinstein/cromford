#!/bin/bash
# tests/triage-gate-buildable-deps.bh-900-test.sh — BH-900 (BH-815.1): the
# buildable gate refuses a dependency-blocked ticket FIRST, naming the keys.
#
# `bin/triage-gate.sh <project> --buildable <id>` reads the ticket's `blocked`
# field BEFORE the waitingOn / triageVerdict / newest-comment checks and, when
# it is the JSON boolean true, prints `BLOCKED dependencies <keys>`. The order
# is the point: a blocked ticket is also usually waiting on somebody, and the
# line a human reads in logs/<project>.log should name the thing that actually
# holds the work — the one block that clears itself when the last dependency
# lands.
#
# THE NEGATIVES CARRY THE WEIGHT. Feature detection is per ticket on the TYPE
# of `blocked` (docs/BOARD-API-CONTRACT.md, "Dependencies"): only a JSON
# boolean counts. The string "true", a null, an absent key, a top-level array
# body and any jq failure all mean "this board has no dependency primitive",
# which is every in-app board on the fleet today — they must answer exactly
# what they answered before this existed. Fail-open, like the rest of the gate.
#
# Drives the REAL bin/triage-gate.sh CLI and the real bin/board-fetch.sh
# against a scratch $HARNESS with a stubbed curl that serves the shared BH-899
# fixtures. No network, no model, no clock reads.
#
# Point it at a mutated copy to prove the suite bites:
#   S=$(mktemp); sed '/# DEPENDENCIES FIRST (BH-815)/,/^  fi$/d' bin/triage-gate.sh > "$S"
#   HARNESS_TEST_SANDBOX=1 TRIAGE_GATE_UNDER_TEST="$S" bash tests/triage-gate-buildable-deps.bh-900-test.sh
#
# Run from anywhere: tests/triage-gate-buildable-deps.bh-900-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1

DIR=$(cd "$(dirname "$0")/.." && pwd)
FIX="$DIR/tests/fixtures/triage-gate-dependencies"
GATE_SRC="${TRIAGE_GATE_UNDER_TEST:-$DIR/bin/triage-gate.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "triage-gate-buildable-deps: jq missing, cannot run" >&2; exit 1; }
[ -r "$GATE_SRC" ]            || { echo "triage-gate-buildable-deps: no script under test at $GATE_SRC" >&2; exit 1; }
[ -d "$FIX" ]                 || { echo "triage-gate-buildable-deps: missing fixtures at $FIX" >&2; exit 1; }

mkdir -p "$T/bin" "$T/env" "$T/state" "$T/logs" "$T/flags" "$T/fixture"

# The scripts under test, run against the scratch harness.
cp "$GATE_SRC"               "$T/bin/triage-gate.sh"
# BH-1955: the generic arm resolves its token through these two libs.
mkdir -p "$T/bin/lib" && cp "$DIR/bin/lib/board-creds.sh" "$DIR/bin/lib/internal-token.sh" "$T/bin/lib/"
cp "$DIR/bin/board-fetch.sh" "$T/bin/board-fetch.sh"
chmod +x "$T/bin/triage-gate.sh" "$T/bin/board-fetch.sh"

# fleet.conf stand-in: x-os is an in-app product board, ghproj is GitHub Issues.
cat > "$T/bin/fleet-conf.sh" <<'EOC'
#!/bin/bash
case "${1:-}" in
  x-os)
    case "${2:-}" in
      repo) echo "" ;;
      board_prefix|*) echo "/api/board" ;;
    esac ;;
  ghproj)
    case "${2:-}" in
      repo) echo "example-org/ghproj" ;;
      board_prefix|*) echo "-" ;;
    esac ;;
  *) echo "" ;;
esac
EOC
chmod +x "$T/bin/fleet-conf.sh"

# Board credentials discovered by suffix (the generic in-app arm of the gate).
cat > "$T/env/x-os.env" <<'EOC'
XOS_API_BASE=https://board.example
XOS_INTERNAL_API_TOKEN=tok
EOC

# curl stand-in. board-fetch.sh reads the body from -o and the status from -w,
# so the stub must honour BOTH: a stub that swallows -w hands the gate an empty
# HTTP code, board-fetch.sh prints BOARD-FETCH FAILED, and every case below
# would answer OK whatever the script does.
cat > "$T/bin/curl" <<EOC
#!/bin/bash
OUT=""; FMT=""; URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift; OUT="\${1:-}" ;;
    -w) shift; FMT="\${1:-}" ;;
    -H) shift; : ;;
    -m) shift; : ;;
    -*) : ;;
    *) URL="\$1" ;;
  esac
  shift || true
done
BODY="BOARD-FETCH stub: no route for \$URL"; HTTP="404"
case "\$URL" in
  */tickets/*)
    F="$T/fixture/ticket-\${URL##*/tickets/}.json"
    if [ -f "\$F" ]; then HTTP="200"; BODY=\$(cat "\$F"); fi
    ;;
esac
if [ -n "\$OUT" ]; then printf '%s' "\$BODY" > "\$OUT"; else printf '%s' "\$BODY"; fi
printf '%s' "\$FMT" | sed "s/%{http_code}/\$HTTP/g"
EOC
chmod +x "$T/bin/curl"

# gh is never legitimate on an in-app board, and a GitHub-Issues board must
# short-circuit to OK before any fetch. Make a call loud AND recorded.
cat > "$T/bin/gh" <<EOC
#!/bin/bash
echo gh-called-unexpectedly >&2
touch "$T/gh-called"
exit 99
EOC
chmod +x "$T/bin/gh"

export HARNESS="$T"
export PATH="$T/bin:$PATH"

# Single-ticket bodies come out of the shared BH-899 LIST fixtures, so there is
# one description of each board shape in the repo. The optional third argument
# is a jq mutation applied to the ticket — that is how the adversarial rows
# (dependsOn empty, id-only entries, the {ticket:{…}} envelope) are expressed
# without a file each.
serve() { # serve <id> <list-fixture> [jq-mutation]  -> $T/fixture/ticket-<id>.json
  jq -c --argjson id "$1" ".tickets[] | select(.id == \$id) ${3:+| $3}" "$FIX/$2" \
    > "$T/fixture/ticket-$1.json" || { bad "serve $1 $2 ${3:-}"; return 1; }
}

gate() { bash "$T/bin/triage-gate.sh" x-os --buildable "$1" 2>/dev/null; }

# Whole-stdout compare, never grep -q: a trailing comma, a second line or an
# extra reason after the one under test all have to be findings.
check() { # check <label> <ticket-id> <expected stdout>
  local out rc
  out=$(gate "$2"); rc=$?
  if [ "$rc" -ne 0 ]; then bad "$1: exit $rc, want 0 (the gate always exits 0)"; return; fi
  if [ "$out" != "$3" ]; then bad "$1: got [$out], want [$3]"; return; fi
  ok
}

# 1. blocked:true with a keyed dependency — the core behaviour.
serve 1825 tickets-cap.json && check "case 1 blocked:true names the key" 1825 "BLOCKED dependencies TK-1800"

# 2. blocked:false on an adopted board falls through to today's answer.
serve 1826 tickets-cap.json && check "case 2 blocked:false is buildable" 1826 "OK"

# 3. no `blocked` key at all (a board that never adopted the contract).
serve 1826 tickets-old.json && check "case 3 absent blocked is buildable" 1826 "OK"

# 4. blocked:null (the field exists, the board serves no value).
serve 1826 tickets-null.json && check "case 4 null blocked is buildable" 1826 "OK"

# 5. blocked:"true" — a STRING must not block, even though dependsOn is
#    non-empty. Type detection, not truthiness.
serve 1840 tickets-cap.json && check "case 5 string \"true\" does not block" 1840 "OK"

# 6. Order: dependencies are reported ahead of the waitingOn reason.
if serve 1825 tickets-cap.json '.waitingOn = "client"'; then
  check "case 6 dependencies beat waitingOn=client" 1825 "BLOCKED dependencies TK-1800"
  out6=$(gate 1825)
  if [ "$out6" = "BLOCKED waitingOn=client" ]; then
    bad "case 6b: the turn was reported instead of the dependency"
  else
    ok
  fi
fi

# 7a. An empty dependsOn still blocks — the board says blocked, we just cannot
#     name what by. `unlisted` is the word, never an empty tail.
serve 1825 tickets-cap.json '.dependsOn = []' && \
  check "case 7a empty dependsOn says unlisted" 1825 "BLOCKED dependencies unlisted"

# 7b. key, falling back to id, in list order.
serve 1825 tickets-cap.json '.dependsOn = [{id:1800,status:"review"},{id:1801,key:"TK-1801"}]' && \
  check "case 7b id fallback, list order" 1825 "BLOCKED dependencies 1800,TK-1801"

# 7c. The {ticket:{…}} envelope answers the same as a bare body, like the
#     waitingOn lookups next to it.
serve 1825 tickets-cap.json '{ticket: .}' && \
  check "case 7c ticket envelope" 1825 "BLOCKED dependencies TK-1800"

# 8. Fail-open on a fetch failure (no fixture -> the stub answers 404, and
#    board-fetch.sh prints BOARD-FETCH FAILED). Unchanged by this ticket.
rm -f "$T/fixture/ticket-1899.json"
check "case 8 fetch failure fails open" 1899 "OK"

# 9. A top-level ARRAY body: jq finds no boolean, $b stays empty, the gate falls
#    through to the checks below it rather than erroring or blocking.
printf '%s' '[{"id":1825,"blocked":true,"dependsOn":[{"key":"TK-1800"}]}]' > "$T/fixture/ticket-1898.json"
check "case 9 array body falls through" 1898 "OK"

# 10. A GitHub-Issues board short-circuits to OK before any fetch, so `gh` is
#     never called for a buildability question.
out10=$(bash "$T/bin/triage-gate.sh" ghproj --buildable 123 2>/dev/null); rc10=$?
if [ "$rc10" -eq 0 ] && [ "$out10" = "OK" ]; then ok; else bad "case 10: got [$out10] rc $rc10, want [OK] rc 0"; fi
if [ -e "$T/gh-called" ]; then bad "case 10b: gh was called for a --buildable check"; else ok; fi

echo "triage-gate-buildable-deps.bh-900: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
