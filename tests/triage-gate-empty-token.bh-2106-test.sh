#!/bin/bash
# tests/triage-gate-empty-token.bh-2106-test.sh — an env file whose board token
# (or base) variable RESOLVES to exactly one name but carries an EMPTY value
# makes bin/triage-gate.sh refuse (SKIP/BLOCKED token-unresolved, no board call)
# AND write one ALERTS line per project per day, the same line and the same
# dedup flag as the no-match and duplicate refusals (BH-1955).
#
# THE DEFECT THIS PINS (BH-2106). board_token_var/board_base_var returned the
# name with no alert, the gate expanded it to "", and the empty-value branch
# printed SKIP token-unresolved and exited with nothing in ALERTS.log, so triage
# for that project stopped silently.
#
# Mutation note (D1): deleting the _bc_alert call in the gate's empty-value
# branch turns E1, E2, E2b and E4 red.
#
# Drives the REAL gate copied into a scratch harness with its libs (D2). The
# assertions are stdout, the ALERTS lines and what curl was asked, never source.
# No network, nothing written outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/state" "$H/logs" "$T/fakebin"
cp "$DIR/bin/triage-gate.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/lib/board-creds.sh" "$DIR/bin/lib/internal-token.sh" "$H/bin/lib/"
chmod +x "$H/bin/"*.sh
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
model_routes_fixture "$H" || exit 1

cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
et  org/et  https://x.invalid /api/board 1 box-1
eq  org/eq  https://x.invalid /api/board 1 box-1
ex  org/ex  https://x.invalid /api/board 1 box-1
eb  org/eb  https://x.invalid /api/board 1 box-1
ok  org/ok  https://x.invalid /api/board 1 box-1
dup org/dup https://x.invalid /api/board 1 box-1
CONF
: > "$H/env/global.env"
# The shapes a real /etc/harness/env/<p>.env can hold for "set but empty".
printf 'ET_APP_BASE=https://x.invalid\nET_INTERNAL_API_TOKEN=\n'                > "$H/env/et.env"
printf 'EQ_APP_BASE=https://x.invalid\nEQ_INTERNAL_API_TOKEN=""\n'              > "$H/env/eq.env"
printf "export EX_APP_BASE=https://x.invalid\nexport EX_INTERNAL_API_TOKEN=''\n" > "$H/env/ex.env"
printf 'EB_APP_BASE=\nEB_INTERNAL_API_TOKEN=tok-eb\n'                           > "$H/env/eb.env"
printf 'OK_APP_BASE=https://x.invalid\nOK_INTERNAL_API_TOKEN=tok-ok\n'          > "$H/env/ok.env"
printf 'DUP_APP_BASE=https://x.invalid\nA_INTERNAL_API_TOKEN=secret-a\nB_INTERNAL_API_TOKEN=secret-b\n' > "$H/env/dup.env"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/curl.log"
URL="\${!#}"
case "\$URL" in
  */boards)           printf '{"boards":[{"id":"b1"}]}\n' ;;
  */boards/*/tickets) printf '{"tickets":[]}\n' ;;
  *)                  printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"

reset() { : > "$T/curl.log"; scratch_rm "$H/flags"; : > "$H/logs/ALERTS.log"; rm -f "$H/state/"*.gate* 2>/dev/null; }
alerts() { grep -c "\[internal-token\] $1:" "$H/logs/ALERTS.log" 2>/dev/null || true; }
calls()  { grep -c . "$T/curl.log" 2>/dev/null || true; }
E=(env HARNESS="$H" HARNESS_ENV_DIR="$H/env" FLEET_CONF="$H/fleet.conf" PATH="$T/fakebin:$PATH")
gate() { "${E[@]}" bash "$H/bin/triage-gate.sh" "$@" 2>"$T/gate.err"; }

# E1/E2: an empty token in each shape — SKIP, one ALERTS line naming the
# variable and the caller, no board call.
for pair in et:ET_INTERNAL_API_TOKEN eq:EQ_INTERNAL_API_TOKEN ex:EX_INTERNAL_API_TOKEN eb:EB_APP_BASE; do
  p=${pair%%:*}; var=${pair#*:}
  reset; OUT=$(gate "$p")
  [ "$OUT" = "SKIP token-unresolved" ] && ok || bad "E1/E2: $p must print 'SKIP token-unresolved', got '$OUT' err: $(cat "$T/gate.err")"
  [ "$(alerts "$p")" = 1 ] && ok || bad "E1/E2: $p must write exactly one ALERTS line, got $(alerts "$p"): '$(cat "$H/logs/ALERTS.log")'"
  grep "\[internal-token\] $p:" "$H/logs/ALERTS.log" | grep -q "sets $var to an empty value (triage-gate)" \
    && ok || bad "E1/E2: $p's ALERTS line must name $var and (triage-gate): '$(cat "$H/logs/ALERTS.log")'"
  [ "$(calls)" = 0 ] && ok || bad "E1/E2: $p must make no board call: $(cat "$T/curl.log")"
done

# E3: one per project per day — more calls the same day add no line.
reset; gate et >/dev/null; gate et >/dev/null; gate et >/dev/null; gate et --buildable 5 >/dev/null
[ "$(alerts et)" = 1 ] && ok || bad "E3: repeated gate calls for et must stay at one ALERTS line, got $(alerts et)"
[ "$(calls)" = 0 ] && ok || bad "E3: et must never make a board call: $(cat "$T/curl.log")"

# E3b: the flag is shared with the duplicate refusal — a project already
# alerted today for two tokens gets no second line when its token goes empty.
reset; gate dup >/dev/null
[ "$(alerts dup)" = 1 ] && ok || bad "E3b: dup must alert once for two tokens, got $(alerts dup)"
printf 'DUP_APP_BASE=https://x.invalid\nDUP_INTERNAL_API_TOKEN=\n' > "$H/env/dup.env"
OUT=$(gate dup)
[ "$OUT" = "SKIP token-unresolved" ] && ok || bad "E3b: dup with an empty token must SKIP, got '$OUT'"
[ "$(alerts dup)" = 1 ] && ok || bad "E3b: the shared flag must hold dup at one line, got $(alerts dup)"

# E4: --buildable answers BLOCKED with the alert; --seed fetches nothing;
# --pending keeps rc 1 and prints nothing.
reset; OUT=$(gate et --buildable 5)
[ "$OUT" = "BLOCKED token-unresolved" ] && ok || bad "E4: --buildable on et must print 'BLOCKED token-unresolved', got '$OUT'"
[ "$(alerts et)" = 1 ] && ok || bad "E4: --buildable on et must write one ALERTS line, got $(alerts et)"
gate et --seed >/dev/null
[ "$(calls)" = 0 ] && ok || bad "E4: --seed on et must make no board call: $(cat "$T/curl.log")"
reset; OUT=$(gate et --pending); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "E4: --pending on et must be rc 1 with no output, got rc=$RC out='$OUT'"

# E5: a healthy project fetches with its own token and alerts nothing.
reset; gate ok --seed >/dev/null
grep -q 'Bearer tok-ok .*https://x.invalid/api/board/boards$' "$T/curl.log" \
  && ok || bad "E5: ok must fetch with tok-ok: '$(cat "$T/curl.log")' err: $(cat "$T/gate.err")"
[ -s "$H/logs/ALERTS.log" ] && bad "E5: a healthy project must write no ALERTS line: '$(cat "$H/logs/ALERTS.log")'" || ok

# E6: no token value ever reaches ALERTS.log.
reset; for p in et eq ex eb dup; do gate "$p" >/dev/null; done
grep -q 'tok-\|secret-' "$H/logs/ALERTS.log" && bad "E6: a token value reached ALERTS.log: '$(cat "$H/logs/ALERTS.log")'" || ok

bash -n "$DIR/bin/triage-gate.sh" && ok || bad "bin/triage-gate.sh is not valid bash"

echo "triage-gate-empty-token.bh-2106: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
