#!/bin/bash
# tests/ticket-ownership-refs.bh-5905-test.sh — BH-5905: to_pr_issue reads a
# partial build's `Refs #<n>` line. A partial build (BH-5798) says Refs, not
# Closes. Before this ticket to_pr_issue fell back to the head-ref KEY, so a
# split child's partial build mapped to no issue (ticket/bh-1510-0 is no plain
# KEY) and its merge hold was never read.
#
#   O1  head ticket/bh-1510-0, body `Refs #57`          -> 57
#   O2  `Closes #57` and `Refs #9`                       -> 57 (closing keyword first)
#   O3  `Ticket BH-60`, `Refs #57`, `Refs #9`            -> 57 (the first Refs line)
#   O4  `see Refs #57` in prose, head ticket/bh-1486     -> 1486 (not a link line)
#   O5  no keyword, head ticket/bh-1486-local            -> 1486 (head-ref fallback kept)
#   O6  the production reader: to_merge_hold on a pool PR whose body is
#       `Refs #57` and whose issue #57 carries a HOLD line holds the merge
#
# The rig is section A/F of tests/ticket-ownership.bh-1526-test.sh: the library
# sourced into a subshell, a stub gh that answers per issue and PR number.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ticket-ownership-refs.bh-5905-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; FIX="$T/fix"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$FIX" "$T/fakebin"
scratch_install_closure bin/lib/ticket-ownership.sh "$H" >/dev/null || bad "closure of bin/lib/ticket-ownership.sh"
scratch_install_closure bin/lib/hold.sh "$H" >/dev/null || bad "closure of bin/lib/hold.sh"
cat > "$H/bin/fleet-conf.sh" <<'SHIM'
#!/bin/bash
case "$1 ${2:-}" in
  "iss repo")         echo "o/r" ;;
  "iss board_prefix") echo "-" ;;
esac
exit 0
SHIM
chmod +x "$H/bin/fleet-conf.sh"

# gh: answers `gh api -i -X …` (gh-rest.sh) and the plain `gh api …` reads
# hold.sh makes, from $FIX per number; a missing fixture is a 404.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$FIX/argv.log"
I=0; case " $* " in *" -i "*) I=1 ;; esac
hdr() { [ "$I" = 1 ] && printf 'HTTP/1.1 %s Stub\r\n\r\n' "$1"; return 0; }
miss() { if [ "$I" = 1 ]; then hdr 404; echo '{"message":"Not Found"}'; exit 0; fi
         echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
N=$(printf '%s' "$*" | sed -nE 's#.*repos/[^/]+/[^/]+/(issues|pulls)/([0-9]+).*#\2#p')
case "$*" in
  *"/issues/"*"/comments"*) hdr 200; cat "$FIX/comments-$N.json" 2>/dev/null || echo '[]'; exit 0 ;;
  *"/issues/"*) [ -s "$FIX/issue-$N.json" ] || miss; hdr 200; cat "$FIX/issue-$N.json"; exit 0 ;;
  *"/pulls/"*)  [ -s "$FIX/pr-$N.json" ] || miss; hdr 200; cat "$FIX/pr-$N.json"; exit 0 ;;
esac
printf '\n'
exit 0
SHIM
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH" FIX HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_ETAG=0

issue() { jq -nc --argjson n "$1" --arg b "$2" '{number:$n,state:"open",labels:[{name:"ai-build"}],title:"BH-\($n): x",body:$b}' > "$FIX/issue-$1.json"; }
# pr <n> <head-ref> <login> [body]
pr()    { jq -nc --argjson n "$1" --arg r "$2" --arg l "$3" --arg b "${4:-}" \
            '{number:$n,state:"open",merged_at:null,head:{ref:$r,sha:"aaaaaaaa1111"},base:{ref:"main"},labels:[],user:{login:$l,type:"User"},body:$b,draft:false}' > "$FIX/pr-$1.json"; }
LIB="$H/bin/lib/ticket-ownership.sh"
lib() { ( . "$LIB" 2>/dev/null || exit 97; eval "$1" ); }
issue_of() { lib "to_pr_issue \"\$(cat $FIX/pr-$1.json)\""; }

pr 701 ticket/bh-1510-0 'cromford[bot]' $'Ticket BH-1510.0\nRefs #57\n\n## Acceptance self-check'
got=$(issue_of 701); [ "$got" = 57 ] && ok || bad "O1: a split child's Refs #57 must map to 57 (got '$got')"
pr 702 ticket/bh-1510-0 'cromford[bot]' $'Closes #57\nRefs #9'
got=$(issue_of 702); [ "$got" = 57 ] && ok || bad "O2: the closing keyword wins over Refs (got '$got')"
pr 703 ticket/bh-1510-0 'cromford[bot]' $'Ticket BH-60\nRefs #57\nRefs #9'
got=$(issue_of 703); [ "$got" = 57 ] && ok || bad "O3: the first Refs line wins (got '$got')"
pr 704 ticket/bh-1486 'cromford[bot]' 'This is related; see Refs #57 in prose.'
got=$(issue_of 704); [ "$got" = 1486 ] && ok || bad "O4: prose Refs is not a link line, the head ref decides (got '$got')"
pr 705 ticket/bh-1486-local operator 'no closing keyword here'
got=$(issue_of 705); [ "$got" = 1486 ] && ok || bad "O5: no keyword falls back to the head ref's key (got '$got')"

# O6: the merge hold reads the Refs ticket.
HELD_BODY=$'HOLD: the lead is building this on the Mac; the pool must not build or split it.\n\n## Build\nstuff'
LEADROW='setting_get() { echo operator; }'
issue 57 "$HELD_BODY"
got=$(lib "$LEADROW; to_merge_hold iss o/r 701 && echo HOLD || echo GO")
case "$got" in *"#57 is held"*HOLD) ok ;; *) bad "O6: a pool PR whose Refs ticket is held must not merge (got '$got')" ;; esac
issue 57 '## Build'
got=$(lib "$LEADROW; to_merge_hold iss o/r 701 && echo HOLD || echo GO")
[ "$got" = GO ] && ok || bad "O6: a clear Refs ticket's PR merges (got '$got')"
grep -q 'repos/o/r/issues/57' "$FIX/argv.log" && ok || bad "O6: issue #57 was never read: $(cat "$FIX/argv.log")"

echo "ticket-ownership-refs.bh-5905: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
