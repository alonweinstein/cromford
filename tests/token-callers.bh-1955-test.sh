#!/bin/bash
# tests/token-callers.bh-1955-test.sh — every board caller resolves its token
# (and triage-gate its base) through bin/lib/board-creds.sh, which sits on the
# ONE definition in bin/lib/internal-token.sh (BH-1953), and refuses the same
# way: no match or a duplicate prints nothing, writes ONE deduped ALERTS line,
# and makes NO board call.
#
# THE DEFECT THIS PINS (BH-1955). bin/triage-gate.sh, bin/run-decompose.sh,
# bin/run-build.sh (TICKET_FP, TICKET_META) and bin/file-health-ticket.sh each
# picked the token with their own `grep -oE '^[A-Z_]+_…' | head -1`: no digit
# (project-32_INTERNAL_API_TOKEN did not match, and triage-gate then died on
# `${!}` with "invalid variable name"), and the first of two tokens won, with no
# ALERTS line — a rotated-but-not-deleted token takes a 401 that reads as an
# outage.
#
# Drives the REAL scripts (D2): the gate copied into a scratch harness with its
# libs, run-decompose/file-health-ticket from the repo, and run-build's two
# functions lifted out of the pipeline text the way bh-985 lifts TICKET_META.
# The assertions are what curl was asked (URL + bearer) and the ALERTS count,
# never source text — except T0, which is the ticket's own grep item.
#
# No network, no model call, nothing written outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

# ════════════════════════════════════════════════════════════════════════════
# T0 — no hardcoded board path left in the two scripts the ticket names
# ════════════════════════════════════════════════════════════════════════════
for f in bin/file-health-ticket.sh bin/run-decompose.sh; do
  if [ -r "$DIR/$f" ]; then
    n=$(grep -c '/api/board' "$DIR/$f"); n=${n:-0}
    [ "$n" -eq 0 ] && ok || bad "T0: $f still carries $n '/api/board' literal(s): $(grep -n '/api/board' "$DIR/$f")"
  else
    bad "T0: $f is missing — the negative cannot pass by absence"
  fi
done

# ─────────────────────────────────────────────────────────────── scratch tree
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/state" "$H/logs" "$H/prompts" "$T/fakebin"
cp "$DIR/bin/triage-gate.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
# The gate sources its libs from its own dir: exactly the two it needs for this.
cp "$DIR/bin/lib/board-creds.sh" "$DIR/bin/lib/internal-token.sh" "$H/bin/lib/" 2>/dev/null
chmod +x "$H/bin/"*.sh
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
model_routes_fixture "$H" o2d dup dupx dupb || exit 1

# o2d is served at a NON-default prefix, so a URL that reaches it can only have
# come from fleet.conf column 4, never from a literal.
cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
gm    org/gm    https://x.invalid /api/board 1 box-1
gt    org/gt    https://x.invalid /api/board 1 box-1
go    org/go    https://x.invalid /api/board 1 box-1
gc    org/gc    https://x.invalid /api/board 1 box-1
o2    org/o2    https://x.invalid /api/board 1 box-1
o2d   org/o2d   https://x.invalid /api/fb    1 box-1
cx    org/cx    https://x.invalid /api/board 1 box-1
dup   org/dup   https://x.invalid /api/board 1 box-1
dupb  org/dupb  https://x.invalid /api/board 1 box-1
none  org/none  https://x.invalid /api/board 1 box-1
dupx  org/dupx  https://x.invalid /api/board 1 box-1
negex org/negex https://x.invalid /api/board 1 box-1
negold org/negold https://x.invalid /api/board 1 box-1
negcm org/negcm https://x.invalid /api/board 1 box-1
CONF
: > "$H/env/global.env"
# The four live projects' real names, generic arm and named arm alike.
printf 'PROJECT_1_API_BASE=https://m.invalid\nproject-1_INTERNAL_API_TOKEN=tok-m\n' > "$H/env/gm.env"
printf 'PROJECT_2_APP_BASE=https://t.invalid\nTA_INTERNAL_API_TOKEN=tok-t\n'             > "$H/env/gt.env"
printf 'PROJECT_3_APP_BASE=https://o.invalid\nproject-3_INTERNAL_API_TOKEN=tok-o\n'         > "$H/env/go.env"
printf 'PROJECT_4_API_BASE=https://c.invalid\nproject-4_INTERNAL_API_TOKEN=tok-c\n'         > "$H/env/gc.env"
cp "$H/env/gm.env" "$H/env/project-1.env"; cp "$H/env/gt.env" "$H/env/project-2.env"
cp "$H/env/go.env" "$H/env/project-3.env";     cp "$H/env/gc.env" "$H/env/project-4.env"
cp "$H/env/gc.env" "$H/env/cx.env"
# The digit prefix, in the repro's own shape (project-32_APP_BASE): o2 at the
# default prefix, o2d the same env file at a non-default one, so D1/F1/B1 fail
# if fc_board_base cannot read a digit-prefixed *_APP_BASE.
printf 'project-32_APP_BASE=https://x.invalid\nproject-32_INTERNAL_API_TOKEN=tok-o2\n'      > "$H/env/o2.env"
cp "$H/env/o2.env" "$H/env/o2d.env"
DUPENV='DUP_API_BASE=https://x.invalid
A_INTERNAL_API_TOKEN=secret-a
B_INTERNAL_API_TOKEN=secret-b
'
printf '%s' "$DUPENV" > "$H/env/dup.env"; printf '%s' "$DUPENV" > "$H/env/dupx.env"
printf 'X_API_BASE=https://x.invalid\nX_APP_BASE=https://y.invalid\nX_INTERNAL_API_TOKEN=tok-x\n' > "$H/env/dupb.env"
printf 'X_API_BASE=https://x.invalid\n' > "$H/env/none.env"
# Adversarial negatives: each must RESOLVE, never refuse.
printf 'export NX_APP_BASE=https://x.invalid\nexport NX_INTERNAL_API_TOKEN=tok-nx\n' > "$H/env/negex.env"
printf 'NO_APP_BASE=https://x.invalid\nNO_INTERNAL_API_TOKEN="tok-no"\nFOO_INTERNAL_API_TOKEN_OLD=stale\n' > "$H/env/negold.env"
printf 'NC_APP_BASE=https://x.invalid\n# B_INTERNAL_API_TOKEN=x\nNC_INTERNAL_API_TOKEN=tok-nc\n' > "$H/env/negcm.env"

# curl logs its whole argv (the bearer included) and answers by URL.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/curl.log"
URL="\${!#}"
case "\$URL" in
  */boards)             printf '{"boards":[{"id":"b1"}]}\n' ;;
  */boards/*/tickets)   printf '{"tickets":[],"ticket":{"id":"t9","key":"K-9"}}\n' ;;
  */move)               printf '{"status":"in_progress"}\n' ;;
  */tickets/*)          printf '{"ticket":{"id":"77","boardId":"b1","title":"T","lastActivityAt":"a"}}\n' ;;
  *)                    printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"

reset() { : > "$T/curl.log"; scratch_rm "$H/flags"; : > "$H/logs/ALERTS.log"; rm -f "$H/state/"*.gate* 2>/dev/null; }
alerts() { grep -c "\[internal-token\] $1:" "$H/logs/ALERTS.log" 2>/dev/null || true; }
calls()  { grep -c . "$T/curl.log" 2>/dev/null || true; }
E=(env HARNESS="$H" HARNESS_ENV_DIR="$H/env" FLEET_CONF="$H/fleet.conf" PATH="$T/fakebin:$PATH")
gate() { "${E[@]}" bash "$H/bin/triage-gate.sh" "$@" 2>"$T/gate.err"; }

# ════════════════════════════════════════════════════════════════════════════
# L — the lib directly
# ════════════════════════════════════════════════════════════════════════════
lib() { "${E[@]}" bash -c '. "$1"; shift; "$@"' _ "$DIR/bin/lib/board-creds.sh" "$@"; }
reset
[ "$(lib board_token_var o2 "$H/env/o2.env" t)" = project-32_INTERNAL_API_TOKEN ] && ok || bad "L1: the digit prefix must resolve to project-32_INTERNAL_API_TOKEN"
[ "$(lib board_base_var o2 "$H/env/o2.env" t)" = project-32_APP_BASE ] && ok || bad "L1: the digit prefix base must resolve to project-32_APP_BASE"
OUT=$(lib board_token_var dup "$H/env/dup.env" t); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "L2: two tokens must be rc 1 with nothing printed, got rc=$RC out='$OUT'"
[ "$(alerts dup)" = 1 ] && ok || bad "L2: two tokens must write exactly one ALERTS line, got $(alerts dup): $(cat "$H/logs/ALERTS.log")"
grep -q 'A_INTERNAL_API_TOKEN,B_INTERNAL_API_TOKEN' "$H/logs/ALERTS.log" && ok || bad "L2: the ALERTS line must name both variables: $(cat "$H/logs/ALERTS.log")"
grep -q 'secret-' "$H/logs/ALERTS.log" && bad "L2: a token VALUE reached ALERTS.log" || ok
lib board_token_var dup "$H/env/dup.env" t >/dev/null; lib board_base_var dup "$H/env/dup.env" t2 >/dev/null
[ "$(alerts dup)" = 1 ] && ok || bad "L3: a second call the same day must add no line, got $(alerts dup)"
reset
for p in negex negold negcm; do
  tv=$(lib board_token_var "$p" "$H/env/$p.env" t) && bv=$(lib board_base_var "$p" "$H/env/$p.env" t) \
    && ok || bad "L4: the adversarial negative $p must resolve, not refuse: $(cat "$H/logs/ALERTS.log")"
done
lib board_base_var dupb "$H/env/dupb.env" t >/dev/null && bad "L4: API_BASE + APP_BASE must refuse" || ok
lib board_token_var none "$H/env/none.env" t >/dev/null && bad "L4: no token line must refuse" || ok
lib board_token_var gone "$H/env/gone.env" t >/dev/null && bad "L4: an unreadable env file must refuse" || ok
[ "$(alerts gone)" = 1 ] && ok || bad "L4: an unreadable env file must write one ALERTS line"
bash -n "$DIR/bin/lib/board-creds.sh" && ok || bad "L4: bin/lib/board-creds.sh is not valid bash"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S error "$DIR/bin/lib/board-creds.sh" && ok || bad "L4: shellcheck -S error flags bin/lib/board-creds.sh"
fi

# ════════════════════════════════════════════════════════════════════════════
# G — the real triage gate (copied, with its libs)
# ════════════════════════════════════════════════════════════════════════════
# G1: the four live names through the generic arm, and the four named arms.
for pair in gm:tok-m:https://m.invalid gt:tok-t:https://t.invalid go:tok-o:https://o.invalid gc:tok-c:https://c.invalid \
            project-1:tok-m:https://m.invalid project-2:tok-t:https://t.invalid project-3:tok-o:https://o.invalid project-4:tok-c:https://c.invalid; do
  p=${pair%%:*}; rest=${pair#*:}; tok=${rest%%:*}; base=${rest#*:}
  reset; gate "$p" --seed >/dev/null
  grep -q "Bearer $tok .*$base/api/[a-z/-]*boards\$" "$T/curl.log" \
    && ok || bad "G1: $p must fetch $base…/boards with its own token, curl saw: $(cat "$T/curl.log") err: $(cat "$T/gate.err")"
done
# G2: the digit prefix fetches with its own token and no expansion error.
reset; gate o2 --seed >/dev/null
grep -q 'Bearer tok-o2 .*https://x.invalid/api/board/boards$' "$T/curl.log" && ok || bad "G2: o2 must fetch with the project-32 token: $(cat "$T/curl.log")"
grep -q 'invalid variable name' "$T/gate.err" && bad "G2: the gate hit an expansion error: $(cat "$T/gate.err")" || ok
reset; OUT=$(gate o2)
case "$OUT" in *unknown-project*|SKIP\ token*) bad "G2: o2 must not be refused or unknown, got '$OUT'" ;; *) ok ;; esac
# G3: two tokens — SKIP, one ALERTS line, no board call.
reset; OUT=$(gate dup)
[ "$OUT" = "SKIP token-unresolved" ] && ok || bad "G3: dup must print 'SKIP token-unresolved', got '$OUT'"
[ "$(alerts dup)" = 1 ] && ok || bad "G3: dup must write exactly one ALERTS line, got $(alerts dup)"
[ "$(calls)" = 0 ] && ok || bad "G3: dup must make no board call, curl saw: $(cat "$T/curl.log")"
gate dup --seed >/dev/null
[ "$(calls)" = 0 ] && ok || bad "G3: --seed on dup must make no board call either: $(cat "$T/curl.log")"
# G4: no token, and two bases, the same.
for p in none dupb; do
  reset; OUT=$(gate "$p")
  [ "$OUT" = "SKIP token-unresolved" ] && ok || bad "G4: $p must print 'SKIP token-unresolved' (never RUN unknown-project), got '$OUT'"
  [ "$(alerts "$p")" = 1 ] && ok || bad "G4: $p must write exactly one ALERTS line, got $(alerts "$p")"
  [ "$(calls)" = 0 ] && ok || bad "G4: $p must make no board call: $(cat "$T/curl.log")"
done
# G5: --buildable answers BLOCKED, which its two callers read as defer.
reset; OUT=$(gate dup --buildable 5)
[ "$OUT" = "BLOCKED token-unresolved" ] && ok || bad "G5: --buildable on dup must print 'BLOCKED token-unresolved', got '$OUT'"
# G6: the adversarial negatives fetch, they are not refused.
for pair in negex:tok-nx negold:tok-no negcm:tok-nc; do
  p=${pair%%:*}; tok=${pair#*:}
  reset; gate "$p" --seed >/dev/null
  grep -q "Bearer $tok " "$T/curl.log" && ok || bad "G6: $p must fetch with $tok: curl saw '$(cat "$T/curl.log")' alerts '$(cat "$H/logs/ALERTS.log")'"
done
grep -q 'tok-\|secret-' "$H/logs/ALERTS.log" && bad "G: a token value reached ALERTS.log" || ok

# ════════════════════════════════════════════════════════════════════════════
# D — the real bin/run-decompose.sh (as run-decompose.bh-1340 drives it)
# ════════════════════════════════════════════════════════════════════════════
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
B=$(dirname "$5")
printf 'LG-77.0\n' > "$B/children.txt"
printf 'DECOMPOSED: LG-77.0\n' > "$5"
exit 0
SH
chmod +x "$H/bin/agent-call.sh"
dec() { # dec <project> -> rc
  B="$T/b-$1"; scratch_rm "$B"; mkdir -p "$B"
  # The re-map read pinned here is the model-filed path, behind this switch since BH-3965.
  mkdir -p "$H/flags" && : > "$H/flags/decompose-board-filer-off"
  ( "${E[@]}" bash "$DIR/bin/run-decompose.sh" "$1" 77 LG-77 "$B" 300 12 ) >"$T/dec.out" 2>"$T/dec.err"
  echo $?
}
reset; dec o2d >/dev/null
grep -q 'Bearer tok-o2 .*https://x.invalid/api/fb/tickets/77$' "$T/curl.log" \
  && ok || bad "D1: o2d's re-map read must go to fc_board_base's URL with the project-32 token, curl saw: $(cat "$T/curl.log") err: $(tail -3 "$T/dec.err")"
grep -q 'https://x.invalid/api/fb/boards/b1/tickets$' "$T/curl.log" && ok || bad "D1: the board list read must use \$BOARD_BASE: $(cat "$T/curl.log")"
reset; dec dupb >/dev/null
[ "$(calls)" = 0 ] && ok || bad "D3: a duplicate base must make no board call from run-decompose: $(cat "$T/curl.log")"
[ "$(alerts dupb)" = 1 ] && ok || bad "D3: a duplicate base must write exactly one ALERTS line, got $(alerts dupb)"
reset; dec dup >/dev/null
[ "$(calls)" = 0 ] && ok || bad "D2: dup must make no board call from run-decompose: $(cat "$T/curl.log")"
[ "$(alerts dup)" = 1 ] && ok || bad "D2: dup must write exactly one ALERTS line, got $(alerts dup)"
cat "$T/b-dup/pipeline.log" "$T/b-dup/decompose-run.txt" 2>/dev/null | grep -q "the parent's board could not be read" \
  && ok || bad "D2: the refusal must land in the DEC_FAIL arm: $(cat "$T/b-dup/decompose-run.txt" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# F — the real bin/file-health-ticket.sh
# ════════════════════════════════════════════════════════════════════════════
fht() { "${E[@]}" bash "$DIR/bin/file-health-ticket.sh" "$1" https://prod.invalid https://pr.invalid 2>&1; }
reset; OUT=$(fht o2d); RC=$?
[ "$RC" = 0 ] && ok || bad "F1: o2d must file the ticket (rc=$RC): $OUT"
grep -q 'Bearer tok-o2 .*https://x.invalid/api/fb/boards$' "$T/curl.log" && ok || bad "F1: the board list must be at fc_board_base's URL with the project-32 token: $(cat "$T/curl.log")"
grep -q 'https://x.invalid/api/fb/boards/b1/tickets$' "$T/curl.log" && ok || bad "F1: the create must be at fc_board_base's URL: $(cat "$T/curl.log")"
grep -q 'https://x.invalid/api/fb/tickets/t9/move$' "$T/curl.log" && ok || bad "F1: the move must be at fc_board_base's URL: $(cat "$T/curl.log")"
reset; OUT=$(fht dup); RC=$?
[ "$RC" = 1 ] && case "$OUT" in FAIL*) true ;; *) false ;; esac && ok || bad "F2: dup must FAIL with rc 1, got rc=$RC '$OUT'"
[ "$(calls)" = 0 ] && ok || bad "F2: dup must make no board call: $(cat "$T/curl.log")"
[ "$(alerts dup)" = 1 ] && ok || bad "F2: dup must write one ALERTS line, got $(alerts dup)"
reset; OUT=$(fht dupb); RC=$?
[ "$RC" = 1 ] && case "$OUT" in FAIL*) true ;; *) false ;; esac && ok || bad "F4: a duplicate base must FAIL with rc 1, got rc=$RC '$OUT'"
[ "$(calls)" = 0 ] && ok || bad "F4: a duplicate base must make no board call: $(cat "$T/curl.log")"
[ "$(alerts dupb)" = 1 ] && ok || bad "F4: a duplicate base must write one ALERTS line, got $(alerts dupb)"
printf 'NB_API_BASE=https://x.invalid\nNB_INTERNAL_API_TOKEN=tok-nb\n' > "$H/env/nobp.env"
reset; OUT=$(fht nobp); RC=$?
[ "$RC" = 1 ] && case "$OUT" in *"no board base"*) true ;; *) false ;; esac && ok || bad "F3: a project with no board prefix must FAIL naming the board base, got rc=$RC '$OUT'"
[ "$(calls)" = 0 ] && ok || bad "F3: no board prefix must make no board call: $(cat "$T/curl.log")"

# ════════════════════════════════════════════════════════════════════════════
# B — run-build's TICKET_FP and TICKET_META, lifted from the pipeline text
# ════════════════════════════════════════════════════════════════════════════
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^TICKET_FP\(\) \{/{f=1} f{print} f && /^\}/{exit}'   "$RB" >  "$T/rbfns.sh"
awk '/^TICKET_META\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$RB" >> "$T/rbfns.sh"
[ "$(grep -c '^TICKET_\(FP\|META\)() {' "$T/rbfns.sh")" = 2 ] && ok || bad "B: TICKET_FP/TICKET_META could not be extracted from bin/run-build.sh"
rbfn() { # rbfn <fn> <project>
  "${E[@]}" HENV="$H/env" PROJECT="$2" KEY=LG-77 TICKET=77 \
    bash -c 'set -uo pipefail; . "$1"; . "$2"; "$3"' _ "$DIR/bin/lib/board-creds.sh" "$T/rbfns.sh" "$1" 2>/dev/null
}
for fn in TICKET_FP TICKET_META; do
  reset; OUT=$(rbfn "$fn" o2d)
  grep -q 'Bearer tok-o2 .*https://x.invalid/api/fb/tickets/77$' "$T/curl.log" && ok || bad "B1: $fn on o2d must read with the project-32 bearer: $(cat "$T/curl.log")"
  [ -n "$OUT" ] && ok || bad "B1: $fn on o2d must print the snapshot"
  reset; OUT=$(rbfn "$fn" dup)
  [ -z "$OUT" ] && ok || bad "B2: $fn on dup must print nothing (the gate's 'no snapshot'), got '$OUT'"
  [ "$(calls)" = 0 ] && ok || bad "B2: $fn on dup must make no board call: $(cat "$T/curl.log")"
  [ "$(alerts dup)" = 1 ] && ok || bad "B2: $fn on dup must write one ALERTS line, got $(alerts dup)"
  reset; rbfn "$fn" cx >/dev/null
  grep -q 'Bearer tok-c ' "$T/curl.log" && ok || bad "B3: $fn must still resolve PROJECT_4_INTERNAL_API_TOKEN: $(cat "$T/curl.log")"
done

# ════════════════════════════════════════════════════════════════════════════
# X1 — the gate, decompose and internal-token-for share ONE daily line
# ════════════════════════════════════════════════════════════════════════════
reset
gate dupx >/dev/null; dec dupx >/dev/null
"${E[@]}" bash "$DIR/bin/internal-token-for.sh" dupx >/dev/null 2>&1
[ "$(alerts dupx)" = 1 ] && ok || bad "X1: three callers on one broken env file must write ONE line a day, got $(alerts dupx): $(cat "$H/logs/ALERTS.log")"
[ "$(calls)" = 0 ] && ok || bad "X1: no caller may reach the board with a guessed token: $(cat "$T/curl.log")"

echo "token-callers.bh-1955: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
