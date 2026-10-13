#!/bin/bash
# tests/publish-cromford-message.bh-4901-test.sh — the public release commit's
# message is neutral and guarded (BH-4901).
#
# Every file in GitHub's file view shows the last commit's message, so it is the
# most-read text in the public repo. bin/share/release_message.py builds it as
# "Cromford <YYYY.MM.DD> (upstream <sha12>)", plus an optional one-line summary,
# and refuses wording from mapping.RELEASE_MESSAGE_FORBIDDEN or any name token.
#
#   M1  a sha gives one line, dated today (UTC)
#   M2  --date and --summary give line 1, a blank line, the summary
#   M3  M1/M2's output carries none of the forbidden words
#   M4  a summary with forbidden wording, or a newline, refuses rc 1 with empty stdout
#   M5  leakcheck refuses a message whose summary carries a 32-hex id
#   M6  a bad sha refuses rc 2
#
# Run from anywhere: tests/publish-cromford-message.bh-4901-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

if [ ! -f "$DIR/bin/publish-share.sh" ] || [ ! -d "$DIR/bin/share" ]; then
  echo "SKIP publish-cromford-message: no bin/publish-share.sh or bin/share/ in this copy"
  exit 0
fi
RM="$DIR/bin/share/release_message.py"
SHA=$(git -C "$DIR" rev-parse HEAD 2>/dev/null)
[ "${#SHA}" = 40 ] || SHA=$(printf '%040d' 7 | tr 0 a)
msg() { python3 -I "$RM" "$@" > "$T/out" 2> "$T/err"; echo $?; }

# M1
rc=$(msg "$SHA")
if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = "Cromford $(date -u +%Y.%m.%d) (upstream ${SHA:0:12})" ] \
   && grep -qxE 'Cromford [0-9]{4}\.[0-9]{2}\.[0-9]{2} \(upstream [0-9a-f]{12}\)' "$T/out"; then ok
else bad "M1 expected one line 'Cromford <today> (upstream ${SHA:0:12})' (rc=$rc): $(cat "$T/out" "$T/err")"; fi
cp "$T/out" "$T/m1"

# M2
rc=$(msg "$SHA" --date 2026.10.06 --summary "Faster triage")
if [ "$rc" = 0 ] && [ "$(sed -n 1p "$T/out")" = "Cromford 2026.10.06 (upstream ${SHA:0:12})" ] \
   && [ -z "$(sed -n 2p "$T/out")" ] && [ "$(sed -n 3p "$T/out")" = "Faster triage" ] \
   && [ "$(wc -l < "$T/out" | tr -d ' ')" = 3 ]; then ok
else bad "M2 expected header, blank, summary (rc=$rc): $(tr '\n' '|' < "$T/out") $(cat "$T/err")"; fi
cp "$T/out" "$T/m2"

# M3
if grep -qiE 'sanitized|mirror|private|client|upstream history' "$T/m1" "$T/m2"; then
  bad "M3 the message carries a forbidden word: $(cat "$T/m1" "$T/m2")"
else ok; fi

# M4
for s in "regenerated mirror" "from the Private repo" "client names removed" "no upstream history here" "Sanitized build"; do
  rc=$(msg "$SHA" --summary "$s")
  if [ "$rc" = 1 ] && [ ! -s "$T/out" ] && grep -q 'forbidden wording' "$T/err"; then ok
  else bad "M4 summary '$s' should refuse rc 1 with 'forbidden wording' and no stdout (rc=$rc): $(cat "$T/out" "$T/err")"; fi
done
rc=$(msg "$SHA" --summary $'line one\nline two')
[ "$rc" = 1 ] && [ ! -s "$T/out" ] && ok || bad "M4 a two-line summary should refuse rc 1 (rc=$rc)"
# A name token refuses by class and never echoes the token.
TOK=$(cd "$DIR/bin/share" && python3 -I -c 'import sys; sys.path.insert(0, "."); from mapping import NAME_TOKENS; print(sorted(t for t in NAME_TOKENS if len(t) > 4 and t.isalpha())[0])' 2>/dev/null)
if [ -n "$TOK" ]; then
  rc=$(msg "$SHA" --summary "Work for $TOK")
  if [ "$rc" = 1 ] && [ ! -s "$T/out" ] && grep -q 'a name token' "$T/err" && ! grep -qiF "$TOK" "$T/err"; then ok
  else bad "M4 a name token must refuse rc 1 by class without echoing it (rc=$rc)"; fi
else bad "M4 could not read a name token from mapping.py"; fi

# M5 the message-side leak guard: a 32-hex id built at runtime
HEX=$(printf 'ab%.0s' $(seq 16))
mkdir -p "$T/msg"
python3 -I "$RM" "$SHA" --summary "ref $HEX" > "$T/msg/COMMIT_MSG.txt" 2>/dev/null
python3 -I "$DIR/bin/share/leakcheck.py" "$T/msg" > "$T/leak.out" 2>&1
rc=$?
[ "$rc" = 1 ] && grep -q 'COMMIT_MSG.txt' "$T/leak.out" && ok \
  || bad "M5 leakcheck should refuse the message carrying a 32-hex id (rc=$rc): $(head -3 "$T/leak.out")"
# and passes the plain one
mkdir -p "$T/msg2"; cp "$T/m2" "$T/msg2/COMMIT_MSG.txt"
python3 -I "$DIR/bin/share/leakcheck.py" "$T/msg2" > "$T/leak2.out" 2>&1 && ok \
  || bad "M5 leakcheck should pass a plain release message: $(head -3 "$T/leak2.out")"

# M6
for s in main "${SHA:0:7}" "${SHA:0:11}" "ZZ${SHA:2:12}"; do
  rc=$(msg "$s")
  [ "$rc" = 2 ] && [ ! -s "$T/out" ] && ok || bad "M6 sha '$s' should refuse rc 2 (rc=$rc)"
done

echo "publish-cromford-message.bh-4901-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
