#!/bin/bash
# tests/ticket-hold-issue.bh-5820-test.sh — BH-5820: a hold_ticket command that
# names the issue by number, `{issue:<n>}`, the shape the MCP hold_issue tool
# sends. bin/lib/ticket-hold-cmd.sh takes it when `ticket` is absent; a bad
# `ticket` string is still refused and never rescued by `issue`.
#
# The gh stub keeps the issue's labels as state, as in
# tests/ticket-hold-cmd.bh-2326-test.sh, so H2 reads the label through the REAL
# hold_classify.
# Run from anywhere: tests/ticket-hold-issue.bh-5820-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/ticket-hold-cmd.sh"
PC="$DIR/bin/poll-commands.sh"
[ -r "$LIB" ] || { echo "FAIL: $LIB is missing"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h" "$T/stubbin" "$T/state"
scratch_install_closure bin/fleet-conf.sh "$T/h" >/dev/null || { echo "FAIL: cannot install fleet-conf.sh"; exit 1; }
cat > "$T/h/fleet.conf" <<'EOF'
# fixture
cromford example-org/cromford  -  -  1 hub
EOF
export FLEET_CONF="$T/h/fleet.conf"

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
case "$method $path" in
  "GET repos/"*/issues/[0-9]*/comments*) printf '[]' ;;
  "GET repos/"*/issues/[0-9]*) cat "$GHSTATE/issue.json" ;;
  "POST repos/"*/labels)
    jq -c '.labels += [{name:"hold"}]' "$GHSTATE/issue.json" > "$GHSTATE/i.tmp" && mv "$GHSTATE/i.tmp" "$GHSTATE/issue.json"
    echo '[{"name":"hold"}]' ;;
  "POST repos/"*/comments) echo '{"id":1}' ;;
  *) echo "gh stub: unexpected call $method $path" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/stubbin/gh"

cat > "$T/stubs.sh" <<'EOF'
gh_auth_for() { printf 'gh_auth_for %s\n' "$1" >> "$GHLOG"; export GH_TOKEN=ghs_test; return 0; }
gh_auth_reset() { printf 'gh_auth_reset\n' >> "$GHLOG"; export GH_TOKEN=ghp_pat; }
job_ledger_put() { printf '%s\x1f%s\x1f%s\x1f%s\n' "$1" "$2" "$3" "${4:-}" >> "$LEDGER"; JOBS_HTTP=200; return 0; }
EOF

GHLOG="$T/gh.log"; LEDGER="$T/ledger.log"; GHSTATE="$T/state"
issue() { jq -nc '{number:7,state:"open",title:"t",body:"",labels:[{name:"ai-build"}]}' > "$GHSTATE/issue.json"; }
thc() {
  : > "$GHLOG"; : > "$LEDGER"
  OUT=$(PATH="$T/stubbin:$PATH" HARNESS="$T/h" GHLOG="$GHLOG" LEDGER="$LEDGER" GHSTATE="$GHSTATE" GH_TOKEN=ghp_pat \
    bash -c 'set -uo pipefail; . "$0"; . "$1"; thc_run "$2" "$3" "$4"' "$LIB" "$T/stubs.sh" "$@"); RC=$?
}
writes() { grep -cE ' -X (POST|DELETE) ' "$GHLOG" 2>/dev/null || true; }

echo "--- H1: {issue:7} holds #7"
issue
thc hold cromford '{"issue":7,"reason":"r","actor":"operator"}'
CB=$(grep -- '/comments --input' "$GHLOG" | sed 's/.* BODY=//')
IFS=$'\x1f' read -r LK LKEY LS _ < "$LEDGER"
[ "$RC" = 0 ] && [ "$OUT" = "held #7 (label added)" ] \
  && [ "$(grep -c -- '-X POST repos/example-org/cromford/issues/7/labels' "$GHLOG")" = 1 ] \
  && [ "$(grep -c -- '/comments --input' "$GHLOG")" = 1 ] \
  && grep -q '^TOKEN=ghs_test ' <<<"$(grep -- '/comments --input' "$GHLOG")" \
  && [[ "$(jq -r .body <<<"$CB")" == "Held from Mission Control by operator: r."* ]] \
  && [ "$LK $LKEY $LS" = "ticket_hold cromford#7 held" ] \
  && ok || bad "H1 (rc=$RC out=$OUT ledger=$LK $LKEY $LS log=$(cat "$GHLOG"))"

echo "--- H2: the real hold_classify reads the label as held"
( . "$DIR/bin/lib/hold.sh"; hold_classify "$(cat "$GHSTATE/issue.json")" '[]' ) > "$T/hc.out"; HRC=$?
[ "$HRC" = 1 ] && [ "$(cat "$T/hc.out")" = "$(printf 'held\thold:label hold')" ] && ok || bad "H2 hold_classify rc=$HRC out=$(cat "$T/hc.out")"

echo "--- H3: a bad issue, or a bad ticket next to a good issue, is refused"
for pj in '{"issue":"7"}' '{"issue":0}' '{"issue":-3}' '{"issue":1.5}' '{"issue":null}' '{"ticket":"BH-7a","issue":7}' '{"ticket":null,"issue":"x"}' '{"ticket":"#7"}' '{"ticket":"i:7"}' '{"ticket":7,"issue":7}'; do
  issue
  thc hold cromford "$pj"
  [ "$RC" = 3 ] && [ "$OUT" = "refused: bad ticket" ] && [ "$(writes)" = 0 ] && ! grep -q 'repos/' "$GHLOG" \
    && ok || bad "H3 $pj (rc=$RC out=$OUT)"
done
# A null ticket is absent, so the issue still counts.
issue
thc hold cromford '{"ticket":null,"issue":7}'
[ "$RC" = 0 ] && [ "$OUT" = "held #7 (label added)" ] && ok || bad "H3 null ticket + issue (rc=$RC out=$OUT)"
# The ticket form is unchanged.
issue
thc hold cromford '{"ticket":"BH-7"}'
[ "$RC" = 0 ] && [ "$OUT" = "held #7 (label added)" ] && ok || bad "H3 ticket form (rc=$RC out=$OUT)"

echo "--- H4: the poll-commands hold arm with the issue payload"
{ echo 'case "$TYPE" in'
  awk '/^    # >>> ticket hold handler/{f=1;next} /^    # <<< ticket hold handler/{exit} f{print}' "$PC"
  echo 'esac'
} > "$T/arm.body"
[ "$(wc -l < "$T/arm.body")" -gt 3 ] || { echo "FAIL: could not extract the ticket hold handler"; exit 1; }
issue; : > "$GHLOG"; : > "$LEDGER"
E2E=$(PATH="$T/stubbin:$PATH" HARNESS="$T/h" GHLOG="$GHLOG" LEDGER="$LEDGER" GHSTATE="$GHSTATE" GH_TOKEN=ghp_pat \
  TYPE=hold_ticket PROJECT=cromford PAYLOAD='{"issue":7,"reason":"r","actor":"console"}' bash -c '
    set -uo pipefail; . "$0"; . "$1"; OK=false RESULT="" OUTCOME=""
    . "$2"; echo "OK=$OK OUTCOME=$OUTCOME RESULT=$RESULT"' "$LIB" "$T/stubs.sh" "$T/arm.body")
[ "$E2E" = "OK=true OUTCOME= RESULT=held #7 (label added)" ] && ok || bad "H4 arm (got $E2E)"

echo "ticket-hold-issue: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
