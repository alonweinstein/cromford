#!/bin/bash
# tests/issue-state-memo.bh-1735-test.sh — BH-1735 (lead scope addition): the
# closed-issue read at build enqueue keeps the issue JSON it already paid for,
# so run-build's created-at stamp is served from it instead of a second GET of
# the same `repos/<slug>/issues/<n>`.
#
# WHAT IS ASSERTED. issue_state / issue_is_closed are called the way
# bin/run-build.sh calls them, against the real gh-rest.sh (and its ledger) out
# of a fixture tree, with a fake gh that logs every call. The claims are counted
# on that call log, on the ledger rows gh_rest writes and on the memo FILE —
# never on source text.
#
# THE RULES the memo must keep, each a case below:
#   A. a good read answers exactly as before AND leaves the whole issue JSON;
#   B. no memo path = byte-for-byte the old call: one GET, no file anywhere;
#   C. a failed read (403, network, non-JSON, a state word that is neither)
#      is UNKNOWN as before, stores nothing, and REMOVES a memo a previous run
#      left, so a consumer can never be served an answer this run did not get;
#   D. the memo file name keeps two repos and two numbers apart;
#   E. issue_is_closed passes the path through, and its kill switch reads
#      nothing and writes nothing;
#   F. the read is ledgered (it goes through gh_rest, not a raw gh api).
#
# Every fixture value is a literal. No clock, no RNG, no network.
# Run from anywhere: tests/issue-state-memo.bh-1735-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/bin/lib" "$T/h/env" "$T/h/flags" "$T/fakebin" "$T/b" "$T/tmp"
cp "$DIR/bin/lib/issue-state-lib.sh" "$DIR"/bin/lib/gh-rest*.sh "$T/h/bin/lib/" || exit 1
: > "$T/h/env/global.env"
LED="$T/h/state/gh-rest-ledger"

# The fake gh answers only gh_rest's shape. $T/st is the HTTP status (default
# 200), $T/net makes the call die with no answer, $T/issue.json is the body.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
[ -e "$T/net" ] && exit 1
case "\$*" in
  "api -i -X GET repos/"*"/issues/"*)
    S=\$(cat "$T/st" 2>/dev/null || echo 200)
    printf 'HTTP/1.1 %s X\r\nX-RateLimit-Remaining: 4000\r\nX-RateLimit-Limit: 5000\r\nX-RateLimit-Resource: core\r\n\r\n' "\$S"
    cat "$T/issue.json"
    [ "\$S" = 200 ] || exit 1
    exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/fakebin/gh"

# answer <status|net> <json> — what the issue route says next.
answer() {
  rm -f "$T/net" "$T/st"; : > "$T/gh.txt"
  if [ "$1" = net ]; then : > "$T/net"; else printf '%s' "$1" > "$T/st"; fi
  printf '%s' "$2" > "$T/issue.json"
}
gets() { grep -c "^api -i -X GET repos/$1/issues/$2\$" "$T/gh.txt"; }

# run <fn> <args...> — one fresh process per call, the lib sourced off the
# fixture harness exactly as the driver sources it. Prints "<out>|rc=<rc>".
run() {
  env PATH="$T/fakebin:$PATH" HARNESS="$T/h" TMPDIR="$T/tmp" GH_ETAG=0 GH_TOKEN= \
    bash -u -c '. "$HARNESS/bin/lib/issue-state-lib.sh"; out=$("$@"); rc=$?; printf "%s|rc=%s" "$out" "$rc"' \
    bash "$@" 2>/dev/null
}
memo_of() { run issue_memo_file "$T/b" "$1" "$2" | sed 's/|rc=0$//'; }

GOOD='{"number":9,"state":"open","created_at":"2026-09-16T05:53:02Z","body":"FIXTURE body"}'

# ══ A. a good read answers as before and keeps the JSON ═════════════════════
M=$(memo_of Org/x-os 9)
case "$M" in "$T/b/"?*) ok ;; *) bad "A: issue_memo_file must name a file under the dir it was given, got '$M'" ;; esac
answer 200 "$GOOD"
eq "A: an open issue still answers OPEN rc 0" "$(run issue_state Org/x-os 9 "$T/h" "$M")" "OPEN|rc=0"
eq "A: with exactly one GET"                   "$(gets Org/x-os 9)" "1"
eq "A: and the memo holds the issue it read"   "$(jq -r '.created_at' "$M" 2>/dev/null)" "2026-09-16T05:53:02Z"
eq "A: the whole object, not a projection"     "$(jq -r '.body' "$M" 2>/dev/null)" "FIXTURE body"
answer 200 '{"number":9,"state":"closed","created_at":"2026-09-16T05:53:02Z"}'
eq "A: a closed issue still answers CLOSED"    "$(run issue_state Org/x-os 9 "$T/h" "$M")" "CLOSED|rc=0"
eq "A: and the memo is this read's, not the last one's" "$(jq -r '.state' "$M" 2>/dev/null)" "closed"
LEFT=$(find "$T/b" "$T/tmp" -name '*.tmp*' -o -name 'gh-rest.*' 2>/dev/null | wc -l | tr -d ' ')
eq "A: no temp file outlives the read" "$LEFT" "0"

# ══ B. no memo path: the old call, exactly ══════════════════════════════════
scratch_rm "$T/b"; mkdir -p "$T/b"
answer 200 "$GOOD"
eq "B: no memo path still answers OPEN rc 0" "$(run issue_state Org/x-os 9 "$T/h")" "OPEN|rc=0"
eq "B: with one GET"                          "$(gets Org/x-os 9)" "1"
eq "B: and writes no file anywhere"           "$(find "$T/b" "$T/tmp" -type f | wc -l | tr -d ' ')" "0"

# ══ C. a failed read stores nothing and clears a stale memo ═════════════════
for c in 403 404 net junk weird; do
  printf '%s' '{"number":9,"state":"open","created_at":"2001-01-01T00:00:00Z"}' > "$M"   # a previous run's memo
  case "$c" in
    net)   answer net '' ;;
    junk)  answer 200 'not json' ;;
    weird) answer 200 '{"number":9,"state":"locked","created_at":"2026-09-16T05:53:02Z"}' ;;
    *)     answer "$c" '{"message":"FIXTURE refusal"}' ;;
  esac
  eq "C/$c: an unreadable answer is UNKNOWN rc 2, as before" "$(run issue_state Org/x-os 9 "$T/h" "$M")" "|rc=2"
  [ ! -e "$M" ] && ok || bad "C/$c: the stale memo from a previous run must be removed, it still says $(cat "$M")"
done

# ══ D. the file name keeps repos and numbers apart ══════════════════════════
A1=$(memo_of Org/x-os 9); A2=$(memo_of Org/x-os 90); A3=$(memo_of Org/y-os 9); A4=$(memo_of org/x-os 9)
[ "$A1" != "$A2" ] && ok || bad "D: #9 and #90 share a memo file: $A1"
[ "$A1" != "$A3" ] && ok || bad "D: two repos share a memo file: $A1"
eq "D: GitHub slugs are case-insensitive, so the memo is too" "$A4" "$A1"
eq "D: a missing argument names no file" "$(run issue_memo_file "$T/b" Org/x-os '')" "|rc=1"

# ══ E. issue_is_closed passes the path through; its switch reads nothing ═════
rm -f "$M"
answer 200 '{"number":9,"state":"closed","created_at":"2026-09-16T05:53:02Z"}'
eq "E: CLOSED is rc 0 through issue_is_closed" "$(run issue_is_closed Org/x-os 9 "$T/h" "$M")" "|rc=0"
eq "E: and it left the memo"                   "$(jq -r '.state' "$M" 2>/dev/null)" "closed"
rm -f "$M"; answer 200 "$GOOD"
eq "E: OPEN is rc 1 through issue_is_closed"   "$(run issue_is_closed Org/x-os 9 "$T/h" "$M")" "|rc=1"
[ -s "$M" ] && ok || bad "E: an OPEN answer must leave the memo too"
rm -f "$M"; : > "$T/h/flags/skip-closed-off"; : > "$T/gh.txt"
eq "E: the kill switch still answers rc 1"     "$(run issue_is_closed Org/x-os 9 "$T/h" "$M")" "|rc=1"
eq "E: with no read"                           "$(wc -l < "$T/gh.txt" | tr -d ' ')" "0"
[ ! -e "$M" ] && ok || bad "E: the kill switch must write no memo"
rm -f "$T/h/flags/skip-closed-off"

# ══ F. the read is ledgered ═════════════════════════════════════════════════
scratch_rm "$LED"; rm -f "$M"; answer 200 "$GOOD"
run issue_state Org/x-os 9 "$T/h" "$M" >/dev/null
ROWS=$(cat "$LED"/*.tsv 2>/dev/null | awk -F'\t' '$5=="repos/Org/x-os/issues/N" && $6=="200"' | wc -l | tr -d ' ')
eq "F: one ledger row for the memo-keeping read" "$ROWS" "1"
eq "F: and no raw gh api call" "$(grep -c '^api repos/' "$T/gh.txt")" "0"

echo "issue-state-memo.bh-1735-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
