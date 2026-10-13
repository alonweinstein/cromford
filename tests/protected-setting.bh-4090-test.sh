#!/bin/bash
# tests/protected-setting.bh-4090-test.sh — BH-4090: bin/protected-setting.sh,
# the Mac CLI that PUTs a lead_* / switch setting with the human verdict token.
# Only curl is stubbed: it logs its argv to $T/argv, copies every `-H @file` to
# $T/hdr, the --data-binary body to $T/body, and answers $T/code + $T/resp.
#   PS1  200 signed -> rc 0, token in the header file and never in argv, no temp left
#   PS2  403 -> rc 1 with the worker's error
#   PS3  mode 644 token -> warned, still sent; missing token -> rc 1, no curl
#   PS4  200 signed:false -> rc 1 NOT signed; usage rc 2; bash -n; bash 3.2 shapes
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/protected-setting.bh-4090-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

S="$DIR/bin/protected-setting.sh"
K=lead_authority.example-org.cromford
TOK=human-secret-token-4090
mkdir -p "$T/fakebin" "$T/tmp" "$T/tok"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/argv"
prev=""
for a in "\$@"; do
  case "\$prev" in
    -H) case "\$a" in @*) cat "\${a#@}" >> "$T/hdr" ;; esac ;;
    --data-binary) printf '%s' "\$a" > "$T/body" ;;
  esac
  prev="\$a"
done
printf '%s\n%s' "\$(cat "$T/resp")" "\$(cat "$T/code")"
EOF
chmod +x "$T/fakebin/curl"
printf '%s\n' "$TOK" > "$T/tok/h"; chmod 600 "$T/tok/h"

export PATH="$T/fakebin:$PATH" TMPDIR="$T/tmp" JOBS_URL=https://jobs.test HARNESS_SECRET=bearer-s \
  HUMAN_VERDICT_TOKEN_FILE="$T/tok/h" USER=tester
reset() { rm -f "$T/argv" "$T/hdr" "$T/body" "$T/out" "$T/err"; }
answer() { printf '%s' "$1" > "$T/code"; printf '%s' "$2" > "$T/resp"; }
run() { bash "$S" "$@" > "$T/out" 2> "$T/err"; }

[ -x "$S" ] && ok || bad "bin/protected-setting.sh is missing or not executable"

# PS1
reset; answer 200 "{\"setting\":{\"key\":\"$K\",\"value\":\"lane\"},\"signed\":true,\"sig_seq\":3}"
run "$K" lane "restore after review"; RC=$?
[ "$RC" = 0 ] && ok || bad "PS1 rc $RC (want 0): $(cat "$T/err")"
grep -q 'signed=true sig_seq=3' "$T/out" && ok || bad "PS1 stdout: $(cat "$T/out")"
grep -q "$K = lane" "$T/out" && ok || bad "PS1 stdout names key and value: $(cat "$T/out")"
grep -q "$TOK" "$T/argv" 2>/dev/null && bad "PS1 the token is in curl's argv" || ok
grep -q bearer-s "$T/argv" 2>/dev/null && bad "PS1 the bearer is in curl's argv" || ok
grep -qx "x-human-verdict-token: $TOK" "$T/hdr" 2>/dev/null && ok || bad "PS1 header file lacks the token: $(cat "$T/hdr" 2>/dev/null)"
grep -qx "authorization: Bearer bearer-s" "$T/hdr" 2>/dev/null && ok || bad "PS1 header file lacks the bearer"
grep -q -- '-X PUT' "$T/argv" && grep -q 'https://jobs.test/api/settings' "$T/argv" && ok || bad "PS1 argv: $(cat "$T/argv")"
[ "$(jq -r '[.key,.value,.note,.actor]|join("|")' "$T/body" 2>/dev/null)" = "$K|lane|restore after review|protected-setting:tester" ] \
  && ok || bad "PS1 body: $(cat "$T/body" 2>/dev/null)"
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "PS1 a temp file was left: $(ls -A "$T/tmp")"
reset; run "$K" lane; RC=$?
[ "$RC" = 0 ] && [ "$(jq 'has("note")' "$T/body")" = false ] && ok || bad "PS1 no note -> no note field (rc $RC): $(cat "$T/body")"

# PS2
reset; answer 403 "{\"error\":\"$K human -> lane loosens it and needs the human verdict token\",\"key\":\"$K\"}"
run "$K" lane; RC=$?
[ "$RC" = 1 ] && ok || bad "PS2 rc $RC (want 1)"
grep -q "http 403: $K human -> lane loosens it" "$T/err" && ok || bad "PS2 stderr: $(cat "$T/err")"
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "PS2 a temp file was left"

# PS3
reset; chmod 644 "$T/tok/h"; answer 200 '{"signed":true,"sig_seq":1}'
run "$K" human; RC=$?
[ "$RC" = 0 ] && grep -q 'chmod 600' "$T/err" && [ -s "$T/argv" ] && ok || bad "PS3 mode 644: rc $RC, err $(cat "$T/err")"
chmod 600 "$T/tok/h"
reset; HUMAN_VERDICT_TOKEN_FILE="$T/tok/missing" bash "$S" "$K" human > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 1 ] && [ ! -e "$T/argv" ] && ok || bad "PS3 missing token: rc $RC, curl called: $([ -e "$T/argv" ] && echo yes)"
grep -q 'HUMAN_VERDICT_TOKEN_FILE' "$T/err" && ok || bad "PS3 missing token stderr: $(cat "$T/err")"
reset; : > "$T/tok/empty"; chmod 600 "$T/tok/empty"
HUMAN_VERDICT_TOKEN_FILE="$T/tok/empty" bash "$S" "$K" human > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 1 ] && [ ! -e "$T/argv" ] && ok || bad "PS3 empty token: rc $RC"
reset; HARNESS_SECRET='' bash "$S" "$K" human > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 1 ] && [ ! -e "$T/argv" ] && grep -q HARNESS_SECRET "$T/err" && ok || bad "PS3 no HARNESS_SECRET: rc $RC"

# PS4
reset; answer 200 '{"signed":false}'
run "$K" human; RC=$?
[ "$RC" = 1 ] && grep -q 'NOT signed' "$T/err" && ok || bad "PS4 signed:false rc $RC: $(cat "$T/err")"
reset; run "$K"; RC=$?
[ "$RC" = 2 ] && grep -qi usage "$T/err" && [ ! -e "$T/argv" ] && ok || bad "PS4 usage rc $RC"
bash -n "$S" && ok || bad "PS4 bash -n"
grep -vE '^[[:space:]]*#' "$S" | grep -nE 'mapfile|readarray|declare -A|,,\}' && bad "PS4 bash 4 only shapes in the script" || ok

echo "protected-setting.bh-4090: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
