#!/bin/bash
# tests/ticket-hold-cmd.bh-2326-test.sh — BH-3147 (BH-2326.1): the hub side of
# the console's hold_ticket / unhold_ticket commands.
#
# bin/lib/ticket-hold-cmd.sh adds or removes the GitHub `hold` label, posts one
# App comment when the label changed, re-reads the hold through hold_check and
# writes the ledgers(kind=ticket_hold, key=<project>#<n>) row the cards read.
# bin/poll-commands.sh runs it from one marked arm.
#
# `gh` is a stub on PATH that keeps the issue's labels as state across calls, so
# a label POST is seen by the next issue GET (section 4 reads it through the
# REAL hold_classify). gh_auth_for, gh_auth_reset and job_ledger_put are stubs
# defined after the lib is sourced; hold_check is overridden only where a
# section says so.
#
# Sections: 1 refusals (rc 3, zero gh writes), 1b retryable reads (rc 1, never
# refused:), 2 HOLD, 3 UNHOLD, 4 the real hold_classify after HOLD, 5 the
# poll-commands arm extracted by its markers.
# Run from anywhere: tests/ticket-hold-cmd.bh-2326-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/ticket-hold-cmd.sh"
[ -r "$LIB" ] || { echo "FAIL: $LIB is missing"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/bin" "$T/stubbin" "$T/state"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/fleet-conf.sh"
cat > "$T/h/fleet.conf" <<'EOF'
# fixture
cromford example-org/cromford  -                     -                  1 hub
project-3       example-org/project-3        https://os.project-3.example  /api/feature-board 6 box-project-3-2
EOF
export FLEET_CONF="$T/h/fleet.conf"

# gh stub. One log line per call: "TOKEN=<GH_TOKEN> <argv> BODY=<stdin or ->".
# State: $GHSTATE/issue.json is the issue; a label POST adds `hold` to it, a
# DELETE removes it. Per-call failure is set by env: GH_ISSUE_RC/_ERR,
# GH_LABEL_RC/_ERR, GH_DEL_RC/_ERR, GH_COMMENT_RC/_ERR.
cat > "$T/stubbin/gh" <<'EOF'
#!/bin/bash
method=GET; path=""; input=0; a=("$@")
for ((i=0; i<${#a[@]}; i++)); do
  case "${a[$i]}" in
    -X) method="${a[$((i+1))]}" ;;
    --input) input=1 ;;
    repos/*) path="${a[$i]}" ;;
  esac
done
body=-; [ "$input" = 1 ] && body=$(cat)
printf 'TOKEN=%s %s BODY=%s\n' "${GH_TOKEN:-}" "$*" "$body" >> "$GHLOG"
fail() { [ -n "$2" ] && echo "$2" >&2; exit "$1"; }
case "$method $path" in
  "GET repos/"*/issues/[0-9]*/comments*) printf '%s' "${GH_COMMENTS:-[]}" ;;
  "GET repos/"*/issues/[0-9]*)
    [ "${GH_ISSUE_RC:-0}" = 0 ] || fail "$GH_ISSUE_RC" "${GH_ISSUE_ERR:-}"
    cat "$GHSTATE/issue.json" ;;
  "POST repos/"*/labels)
    [ "${GH_LABEL_RC:-0}" = 0 ] || fail "$GH_LABEL_RC" "${GH_LABEL_ERR:-}"
    jq -c '.labels += [{name:"hold"}]' "$GHSTATE/issue.json" > "$GHSTATE/i.tmp" && mv "$GHSTATE/i.tmp" "$GHSTATE/issue.json"
    echo '[{"name":"hold"}]' ;;
  "DELETE repos/"*/labels/hold)
    [ "${GH_DEL_RC:-0}" = 0 ] || fail "$GH_DEL_RC" "${GH_DEL_ERR:-}"
    jq -c '.labels |= map(select((if type=="object" then .name else . end) != "hold"))' "$GHSTATE/issue.json" > "$GHSTATE/i.tmp" && mv "$GHSTATE/i.tmp" "$GHSTATE/issue.json"
    echo '[]' ;;
  "POST repos/"*/comments)
    [ "${GH_COMMENT_RC:-0}" = 0 ] || fail "$GH_COMMENT_RC" "${GH_COMMENT_ERR:-}"
    echo '{"id":1}' ;;
  *) fail 9 "gh stub: unexpected call $method $path" ;;
esac
EOF
chmod +x "$T/stubbin/gh"

# Stubs defined AFTER the lib, so they replace gh-app-auth.sh's real ones.
cat > "$T/stubs.sh" <<'EOF'
gh_auth_for() {
  printf 'gh_auth_for %s\n' "$1" >> "$GHLOG"
  [ "${STUB_AUTH_RC:-0}" = 0 ] || return 1
  export GH_TOKEN=ghs_stub; return 0
}
gh_auth_reset() { printf 'gh_auth_reset\n' >> "$GHLOG"; export GH_TOKEN=ghp_pat; }
job_ledger_put() {
  printf '%s\x1f%s\x1f%s\x1f%s\n' "$1" "$2" "$3" "${4:-}" >> "$LEDGER"
  [ "${STUB_LEDGER_RC:-0}" = 0 ] || { JOBS_HTTP=503; return 1; }
  JOBS_HTTP=200; return 0
}
if [ -n "${STUB_HC:-}" ]; then
  hold_check() { printf '%b\n' "$STUB_HC"; case "$STUB_HC" in held*) return 1 ;; clear*) return 0 ;; *) return 2 ;; esac; }
fi
EOF

GHLOG="$T/gh.log"; LEDGER="$T/ledger.log"; GHSTATE="$T/state"
issue() { # issue <state> <labels-json-array> [pr]
  if [ "${3:-}" = pr ]; then
    jq -nc --arg s "$1" --argjson l "$2" '{number:2326,state:$s,title:"t",body:"",labels:$l,pull_request:{url:"x"}}'
  else
    jq -nc --arg s "$1" --argjson l "$2" '{number:2326,state:$s,title:"t",body:"",labels:$l}'
  fi > "$GHSTATE/issue.json"
}
# thc <verb> <project> <payload>: stdout in OUT, rc in RC. Any env set by the
# caller (GH_*_RC, STUB_*) rides through.
thc() {
  : > "$GHLOG"; : > "$LEDGER"
  OUT=$(PATH="$T/stubbin:$PATH" HARNESS="$T/h" GHLOG="$GHLOG" LEDGER="$LEDGER" GHSTATE="$GHSTATE" GH_TOKEN=ghp_pat \
    bash -c 'set -uo pipefail; . "$0"; . "$1"; thc_run "$2" "$3" "$4"' "$LIB" "$T/stubs.sh" "$@"); RC=$?
}
writes() { grep -cE ' -X (POST|DELETE) ' "$GHLOG" 2>/dev/null || true; }
ledger_n() { grep -c . "$LEDGER" 2>/dev/null || true; }
HP='{"ticket":"BH-2326","reason":"waiting on legal","actor":"operator"}'

echo "--- 1: refusals make no gh write"
issue open '[{"name":"ai-build"}]'
for tk in '"BH-2326a"' '"2326"' '"BH-0"' '"BH-02"' '"../2326"' '"BH-2326/../1"' '2326' 'null'; do
  thc hold cromford "{\"ticket\":$tk,\"reason\":\"r\"}"
  [ "$RC" = 3 ] && [[ "$OUT" == "refused: bad ticket" ]] && [ "$(writes)" = 0 ] && [ "$(ledger_n)" = 0 ] \
    && ! grep -q 'repos/' "$GHLOG" \
    && ok || bad "ticket $tk should be refused with no call (rc=$RC out=$OUT log=$(cat "$GHLOG"))"
done
thc hold cromford '{"reason":"r"}'
[ "$RC" = 3 ] && [ "$OUT" = "refused: bad ticket" ] && [ "$(writes)" = 0 ] && ok || bad "missing ticket (rc=$RC out=$OUT)"
thc hold cromford 'not json'
[ "$RC" = 3 ] && [ "$OUT" = "refused: bad payload" ] && [ "$(writes)" = 0 ] && ok || bad "non-json payload (rc=$RC out=$OUT)"
for pj in 'cromford;rm' 'nope' 'project-3' ''; do
  thc hold "$pj" "$HP"
  [ "$RC" = 3 ] && [[ "$OUT" == "refused: "*"is not a GitHub-issues board" ]] && [ "$(writes)" = 0 ] && ! grep -q 'repos/' "$GHLOG" \
    && ok || bad "project '$pj' should be refused (rc=$RC out=$OUT)"
done
thc lock cromford "$HP"
[ "$RC" = 3 ] && [ "$OUT" = "refused: bad verb" ] && ok || bad "bad verb (rc=$RC out=$OUT)"
issue open '[]' pr
thc hold cromford "$HP"
[ "$RC" = 3 ] && [ "$OUT" = "refused: #2326 is a pull request" ] && [ "$(writes)" = 0 ] && ok || bad "PR refused (rc=$RC out=$OUT)"
issue closed '[{"name":"ai-build"}]'
thc hold cromford "$HP"
[ "$RC" = 3 ] && [ "$OUT" = "refused: #2326 is closed" ] && [ "$(writes)" = 0 ] && [ "$(ledger_n)" = 0 ] && ok || bad "closed refused (rc=$RC out=$OUT)"

echo "--- 1b: an unreadable read is retryable, never refused:"
mv "$T/h/bin/fleet-conf.sh" "$T/h/bin/fleet-conf.real"
printf '#!/bin/bash\nexit 1\n' > "$T/h/bin/fleet-conf.sh"; chmod +x "$T/h/bin/fleet-conf.sh"
thc hold cromford "$HP"
[ "$RC" = 1 ] && [ "$OUT" = "ticket hold not changed: fleet-conf --projects could not be read; retry" ] && [ "$(writes)" = 0 ] \
  && ok || bad "fleet-conf unreadable is rc 1 (rc=$RC out=$OUT)"
mv "$T/h/bin/fleet-conf.real" "$T/h/bin/fleet-conf.sh"
issue open '[{"name":"ai-build"}]'
GH_ISSUE_RC=1 GH_ISSUE_ERR='gh: API rate limit exceeded (HTTP 429)' thc hold cromford "$HP"
[ "$RC" = 1 ] && [[ "$OUT" == "ticket hold not changed: issue read failed (gh: API rate limit exceeded (HTTP 429))" ]] \
  && [ "$(writes)" = 0 ] && [ "$(ledger_n)" = 0 ] && ok || bad "429 on the issue GET is rc 1 (rc=$RC out=$OUT)"
GH_ISSUE_RC=1 GH_ISSUE_ERR='gh: Forbidden (HTTP 403)' thc unhold cromford "$HP"
[ "$RC" = 1 ] && [[ "$OUT" != refused:* ]] && [ "$(writes)" = 0 ] && ok || bad "403 on the issue GET is rc 1 (rc=$RC out=$OUT)"
printf 'not json' > "$GHSTATE/issue.json"
thc hold cromford "$HP"
[ "$RC" = 1 ] && [ "$OUT" = "ticket hold not changed: issue read unparseable" ] && [ "$(writes)" = 0 ] && ok || bad "unparseable issue is rc 1 (rc=$RC out=$OUT)"

echo "--- 2: HOLD adds the label, comments once, records held"
issue open '[{"name":"ai-build"}]'
STUB_HC='held\thold:label hold' thc hold cromford "$HP"
LP=$(grep -n -- '-X POST repos/example-org/cromford/issues/2326/labels' "$GHLOG" | cut -d: -f1)
AF=$(grep -n '^gh_auth_for example-org/cromford$' "$GHLOG" | head -1 | cut -d: -f1)
CB=$(grep -- '-X POST repos/example-org/cromford/issues/2326/comments' "$GHLOG" | sed 's/.* BODY=//')
[ "$RC" = 0 ] && [ "$OUT" = "held #2326 (label added)" ] && ok || bad "hold rc/result (rc=$RC out=$OUT)"
[ -n "$LP" ] && [ -n "$AF" ] && [ "$AF" -lt "$LP" ] && ok || bad "gh_auth_for slug before the label POST (log=$(cat "$GHLOG"))"
grep -F -- '-X POST repos/example-org/cromford/issues/2326/labels' "$GHLOG" | grep -F 'BODY={"labels":["hold"]}' >/dev/null \
  && grep -F -- 'issues/2326/labels' "$GHLOG" | grep 'TOKEN=ghs_stub' >/dev/null && ok || bad "label POST body/token (log=$(cat "$GHLOG"))"
[ "$(grep -c -- '/comments --input' "$GHLOG")" = 1 ] \
  && [ "$(jq -r .body <<<"$CB")" = 'Held from Mission Control by operator: waiting on legal. The `hold` label stops every build, rebuild and requeue of this ticket. Remove the label, or UNHOLD it from the console, to lift it.' ] \
  && ! grep -q '—' <<<"$CB" && ok || bad "one HOLD comment, exact text, no em dash (body=$CB)"
IFS=$'\x1f' read -r LK LKEY LS LD < "$LEDGER"
[ "$(ledger_n)" = 1 ] && [ "$LK $LKEY $LS" = "ticket_hold cromford#2326 held" ] \
  && [[ "$LD" =~ ^hold\ by\ operator\ at\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z:\ waiting\ on\ legal\ \|\ hold:label\ hold$ ]] \
  && node -e 'const m=/^\S+ by (.+?) at (\S+): (.*)$/s.exec(process.argv[1]); process.exit(m && m[1]==="operator" ? 0 : 1)' "$LD" \
  && ok || bad "ledger row (got $LK $LKEY $LS '$LD')"
tail -n 1 "$GHLOG" | grep -q '^gh_auth_reset$' && ok || bad "gh_auth_reset runs last (log=$(tail -n 2 "$GHLOG"))"

echo "--- 2b: HOLD replay with the label on writes nothing but the card"
issue open '[{"name":"ai-build"},{"name":"hold"}]'
STUB_HC='held\thold:label hold' thc hold cromford "$HP"
[ "$RC" = 0 ] && [ "$OUT" = "already held #2326 (label was on)" ] && [ "$(writes)" = 0 ] && [ "$(ledger_n)" = 1 ] \
  && ok || bad "replay (rc=$RC out=$OUT writes=$(writes))"

echo "--- 2c: a failed label POST is rc 1 with no comment and no ledger row"
issue open '[{"name":"ai-build"}]'
GH_LABEL_RC=1 GH_LABEL_ERR='gh: Server Error (HTTP 500)' STUB_HC='held\thold:label hold' thc hold cromford "$HP"
[ "$RC" = 1 ] && [ "$OUT" = "hold not set: label add failed (gh: Server Error (HTTP 500))" ] \
  && ! grep -q '/comments' "$GHLOG" && [ "$(ledger_n)" = 0 ] && ok || bad "label POST failure (rc=$RC out=$OUT ledger=$(cat "$LEDGER"))"

echo "--- 2d: no App token: the label goes on, the comment does not"
issue open '[{"name":"ai-build"}]'
STUB_AUTH_RC=1 STUB_HC='held\thold:label hold' thc hold cromford "$HP"
[ "$RC" = 0 ] && grep -F -- 'issues/2326/labels' "$GHLOG" | grep 'TOKEN=ghp_pat' >/dev/null && ! grep -q -- '/comments --input' "$GHLOG" \
  && [ "$OUT" = "held #2326 (label added); comment not posted (no App token)" ] && [ "$(ledger_n)" = 1 ] \
  && ok || bad "unarmed hold (rc=$RC out=$OUT log=$(cat "$GHLOG"))"

echo "--- 2e: reason cap, blank reason, bad actor; comment/ledger failures keep OK"
issue open '[{"name":"ai-build"}]'
LONG=$(printf 'x%.0s' $(seq 1 600))
STUB_HC='held\thold:label hold' thc hold cromford "$(jq -nc --arg r "  $LONG  " '{ticket:"BH-2326",reason:$r,actor:"bad actor!"}')"
IFS=$'\x1f' read -r _ _ _ LD < "$LEDGER"
R=$(sed -E 's/^hold by console at [^ ]+: //; s/ \| .*$//' <<<"$LD")
[ "$RC" = 0 ] && [ "${#R}" = 500 ] && [[ "$LD" == "hold by console at "* ]] && ok || bad "cap 500 + actor console (len=${#R} ld=${LD:0:60})"
issue open '[{"name":"ai-build"}]'
STUB_HC='held\thold:label hold' thc hold cromford '{"ticket":"BH-2326","reason":"   "}'
IFS=$'\x1f' read -r _ _ _ LD < "$LEDGER"
CB=$(grep -- '/comments --input' "$GHLOG" | sed 's/.* BODY=//')
[[ "$LD" == *": no reason given | "* ]] && [[ "$(jq -r .body <<<"$CB")" == "Held from Mission Control by console: no reason given."* ]] \
  && ok || bad "blank reason (ld=$LD cb=$CB)"
issue open '[{"name":"ai-build"}]'
GH_COMMENT_RC=1 GH_COMMENT_ERR='gh: Server Error (HTTP 502)' STUB_LEDGER_RC=1 STUB_HC='held\thold:label hold' thc hold cromford "$HP"
[ "$RC" = 0 ] && [ "$OUT" = "held #2326 (label added); comment not posted (gh: Server Error (HTTP 502)); card not updated (ledger http=503)" ] \
  && ok || bad "comment + ledger failures named, OK kept (rc=$RC out=$OUT)"
issue open '[{"name":"ai-build"}]'
STUB_HC='unreadable\tgh: boom' thc hold cromford "$HP"
IFS=$'\x1f' read -r _ _ LS LD < "$LEDGER"
[ "$RC" = 0 ] && [ "$LS" = held ] && [[ "$LD" == *"| re-read unreadable: gh: boom" ]] && ok || bad "hold + unreadable re-read records held (ls=$LS ld=$LD)"

echo "--- 3: UNHOLD"
UP='{"ticket":"BH-2326","reason":"legal cleared it","actor":"operator"}'
issue open '[{"name":"ai-build"},{"name":"hold"}]'
STUB_HC='clear\tno-hold' thc unhold cromford "$UP"
IFS=$'\x1f' read -r _ _ LS LD < "$LEDGER"
CB=$(grep -- '/comments --input' "$GHLOG" | sed 's/.* BODY=//')
[ "$RC" = 0 ] && [ "$OUT" = "hold lifted on #2326" ] && [ "$LS" = clear ] \
  && [ "$(grep -c -- '-X DELETE repos/example-org/cromford/issues/2326/labels/hold' "$GHLOG")" = 1 ] \
  && [ "$(grep -c -- '/comments --input' "$GHLOG")" = 1 ] \
  && [ "$(jq -r .body <<<"$CB")" = "Hold lifted from Mission Control by operator: legal cleared it." ] \
  && [[ "$LD" == "unhold by operator at "*": legal cleared it | no-hold" ]] && ok || bad "unhold clear (rc=$RC out=$OUT ls=$LS cb=$CB)"
issue open '[{"name":"ai-build"},{"name":"hold"}]'
STUB_HC='held\thold:title X (HOLD)' thc unhold cromford "$UP"
IFS=$'\x1f' read -r _ _ LS _ < "$LEDGER"
[ "$RC" = 0 ] && [ "$LS" = held ] && [ "$OUT" = "hold label removed from #2326; still held: hold:title X (HOLD)" ] && ok || bad "unhold still held by title (out=$OUT ls=$LS)"
issue open '[{"name":"ai-build"},{"name":"hold"}]'
STUB_HC='unreadable\tgh: boom' thc unhold cromford "$UP"
IFS=$'\x1f' read -r _ _ LS _ < "$LEDGER"
[ "$RC" = 0 ] && [ "$LS" = unknown ] && [[ "$OUT" == "hold label removed from #2326; hold state unknown: gh: boom" ]] && ok || bad "unhold unreadable → unknown (out=$OUT ls=$LS)"
issue open '[{"name":"ai-build"}]'
STUB_HC='clear\tno-hold' thc unhold cromford "$UP"
IFS=$'\x1f' read -r _ _ LS _ < "$LEDGER"
[ "$RC" = 0 ] && [ "$(writes)" = 0 ] && [ "$LS" = clear ] && [ "$OUT" = "hold label was not on #2326; not held" ] && ok || bad "unhold label absent (out=$OUT writes=$(writes))"
issue open '[{"name":"ai-build"},{"name":"hold"}]'
GH_DEL_RC=1 GH_DEL_ERR='gh: Label does not exist (HTTP 404)' STUB_HC='clear\tno-hold' thc unhold cromford "$UP"
[ "$RC" = 0 ] && ! grep -q -- '/comments --input' "$GHLOG" && [ "$OUT" = "hold label was not on #2326; not held" ] && ok || bad "DELETE 404 = already gone (rc=$RC out=$OUT)"
issue open '[{"name":"ai-build"},{"name":"hold"}]'
GH_DEL_RC=1 GH_DEL_ERR='gh: Server Error (HTTP 500)' STUB_HC='clear\tno-hold' thc unhold cromford "$UP"
[ "$RC" = 1 ] && [ "$OUT" = "hold not lifted: label remove failed (gh: Server Error (HTTP 500))" ] && [ "$(ledger_n)" = 0 ] \
  && ! grep -q -- '/comments --input' "$GHLOG" && ok || bad "DELETE 500 is rc 1, no ledger (rc=$RC out=$OUT)"

echo "--- 4: the real hold_check / hold_classify reads the label after HOLD"
issue open '[{"name":"ai-build"}]'
thc hold cromford "$HP"
IFS=$'\x1f' read -r _ _ LS LD < "$LEDGER"
[ "$RC" = 0 ] && [ "$LS" = held ] && [[ "$LD" == *"| hold:label hold" ]] && ok || bad "real re-read (rc=$RC out=$OUT ls=$LS ld=$LD)"
( . "$DIR/bin/lib/hold.sh"; hold_classify "$(cat "$GHSTATE/issue.json")" '[]' ) > "$T/hc.out"; HRC=$?
[ "$HRC" = 1 ] && [ "$(cat "$T/hc.out")" = "$(printf 'held\thold:label hold')" ] \
  && jq -e '[.labels[].name] == ["ai-build","hold"]' "$GHSTATE/issue.json" >/dev/null && ok || bad "hold_classify rc=$HRC out=$(cat "$T/hc.out")"

echo "--- 5: the poll-commands arm, extracted by its markers"
PC="$DIR/bin/poll-commands.sh"
{ echo 'case "$TYPE" in'
  awk '/^    # >>> ticket hold handler/{f=1;next} /^    # <<< ticket hold handler/{exit} f{print}' "$PC"
  echo 'esac'
} > "$T/arm.body"
[ "$(wc -l < "$T/arm.body")" -gt 3 ] || { echo "FAIL: could not extract the ticket hold handler — markers missing?"; exit 1; }
grep -q '"${TYPE%_ticket}"' "$T/arm.body" && ! grep -qE 'box_ccmd_forward|bcx_run' "$T/arm.body" && ok || bad "arm passes \${TYPE%_ticket} and is not forwarded"
grep -qxF '[ -r "$HARNESS/bin/lib/ticket-hold-cmd.sh" ] && . "$HARNESS/bin/lib/ticket-hold-cmd.sh"' "$PC" && ok || bad "guarded source line in poll-commands"
arm() { # arm <type> <stub-rc|none> -> "OK=.. OUTCOME=.. RESULT=.."
  TYPE="$1" SRC="$2" bash -c '
    set -uo pipefail
    if [ "$SRC" != none ]; then thc_run() { echo "$1 $2 $3" > "$0.args"; [ "$SRC" = 3 ] && echo "refused: bad ticket" || echo "r$SRC"; return "$SRC"; }; fi
    PROJECT=cromford PAYLOAD="{\"ticket\":\"BH-1\"}" OK=false RESULT="" OUTCOME=""
    . "$0"; echo "OK=$OK OUTCOME=$OUTCOME RESULT=$RESULT"' "$T/arm.body"
}
[ "$(arm hold_ticket 0)" = "OK=true OUTCOME= RESULT=r0" ] && [ "$(cat "$T/arm.body.args")" = 'hold cromford {"ticket":"BH-1"}' ] && ok || bad "arm rc 0 (got $(arm hold_ticket 0))"
[ "$(arm unhold_ticket 0 >/dev/null; cut -d' ' -f1 "$T/arm.body.args")" = unhold ] && ok || bad "unhold_ticket passes verb unhold"
[ "$(arm hold_ticket 3)" = "OK=false OUTCOME=refused RESULT=refused: bad ticket" ] && ok || bad "arm rc 3 (got $(arm hold_ticket 3))"
[ "$(arm hold_ticket 1)" = "OK=false OUTCOME= RESULT=r1" ] && ok || bad "arm rc 1 (got $(arm hold_ticket 1))"
[ "$(arm hold_ticket none)" = "OK=false OUTCOME= RESULT=ticket hold not run (lib not loaded)" ] && ok || bad "arm lib absent (got $(arm hold_ticket none))"
# End to end: the real lib behind the real arm.
issue open '[{"name":"ai-build"}]'; : > "$GHLOG"; : > "$LEDGER"
E2E=$(PATH="$T/stubbin:$PATH" HARNESS="$T/h" GHLOG="$GHLOG" LEDGER="$LEDGER" GHSTATE="$GHSTATE" GH_TOKEN=ghp_pat \
  TYPE=hold_ticket PROJECT=cromford PAYLOAD="$HP" bash -c '
    set -uo pipefail; . "$0"; . "$1"; OK=false RESULT="" OUTCOME=""
    . "$2"; echo "OK=$OK OUTCOME=$OUTCOME RESULT=$RESULT TOKEN=$GH_TOKEN"' "$LIB" "$T/stubs.sh" "$T/arm.body")
[ "$E2E" = "OK=true OUTCOME= RESULT=held #2326 (label added) TOKEN=ghp_pat" ] && [ "$(ledger_n)" = 1 ] && ok || bad "e2e arm + lib (got $E2E)"

echo "ticket-hold-cmd: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
