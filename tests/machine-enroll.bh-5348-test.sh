#!/bin/bash
# tests/machine-enroll.bh-5348-test.sh — bin/machine-enroll.sh against a stub
# worker (BH-5348 / BH-5350). Every case drives the real script; a stub curl
# answers from control files in $W and records argv, header files (with their
# mode) and request bodies, and logging wrappers record the argv of every
# other binary the script runs.
#
#   R1  request prints `pending <id> my-laptop`, the token file holds 64 hex
#   R2  the token file is mode 600
#   R3  the body's token_sha256 = sha256(file), roles reach it, the token does not
#   R4  409 -> rc 1, token file removed, stderr names the worker's error
#   R5  curl fails (unreachable) -> rc 1, token file removed
#   R6  201 without an id -> rc 1, token file removed
#   R7  an existing token file -> rc 1, no curl call, file byte-identical
#   S1  whoami 403 `participant is pending` -> stdout `pending`, rc 3; the header
#       file carried x-participant-token
#   S2  whoami 200 -> `approved ...`, rc 0
#   S3  whoami 403 `unknown participant token` -> rc 1
#   S4  an empty token file -> rc 1
#   A1  no lead token file -> rc 1, no curl call
#   A2  the lead token rides a 0600 header file, never argv
#   A3  approve body {granted_roles, actor} and path /api/participants/<id>/approve
#   A4  deny posts to /deny, rc 0
#   A5  revoke answered 409 -> rc 1, stderr names the error
#   X1  no argv line of any wrapped binary carries the participant token
#   X2  no stdout, stderr or request body carries the participant token
#   D1  docs/add-your-own-machine.md has request, approve, run, revoke sections
#   D2  the doc names no fleet box, client or owner
#   D3  the dated note has a Doc: line
#   W1  every bin/machine-enroll.sh line in the doc, run verbatim in order
# Run from anywhere: bash tests/machine-enroll.bh-5348-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "machine-enroll.bh-5348: jq absent — skipping"; exit 0; }

H="$T/h"; W="$T/w"; FB="$T/fakebin"
mkdir -p "$H" "$W" "$FB" "$T/home"
{ scratch_install_closure bin/machine-enroll.sh "$H" && scratch_install_closure bin/jobs-client.sh "$H"; } >/dev/null || { echo "FAIL: bin/machine-enroll.sh could not be installed"; exit 1; }
ME="$H/bin/machine-enroll.sh"
DOC="$DIR/docs/add-your-own-machine.md"
NOTE="$DIR/docs/notes/2026-10-08-BH-5348-participant-machines.md"

# Logging wrappers: record argv, then run the real binary.
for b in openssl sha256sum shasum jq od stat chmod head tr cut mkdir rm mktemp; do
  real=$(command -v "$b" 2>/dev/null) || continue
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/argv"\nexec "%s" "$@"\n' "$b" "$W" "$real" > "$FB/$b"
  chmod +x "$FB/$b"
done
REAL_STAT=$(command -v stat)
# The stub worker. -w '\n%{http_code}' is what the script asks for, so the
# answer is the body, a newline, the code.
cat > "$FB/curl" <<EOF
#!/bin/bash
W="$W"; STAT="$REAL_STAT"
EOF
cat >> "$FB/curl" <<'EOF'
printf '%s\n' "curl $*" >> "$W/argv"
echo x >> "$W/curl_calls"
method=GET; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H) case "$2" in @*) f="${2#@}"
          { echo "## mode=$("$STAT" -c %a "$f" 2>/dev/null || "$STAT" -f %Lp "$f")"; cat "$f"; } >> "$W/hdrs" ;;
        esac; shift 2 ;;
    --data-binary) case "$2" in @*) cat "${2#@}" > "$W/last_body"; { cat "${2#@}"; echo; } >> "$W/bodies" ;; esac; shift 2 ;;
    -m|--connect-timeout|-w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
path="${url#http://stub}"
echo "$method $path" >> "$W/paths"
[ -f "$W/curl_rc" ] && exit "$(cat "$W/curl_rc")"
case "$path" in
  /api/participants/request) k=req ;;
  /api/participants/whoami) k=who ;;
  /api/participants/*/approve|/api/participants/*/deny|/api/participants/*/revoke) k=dec ;;
  *) k=none ;;
esac
code=$(cat "$W/${k}_code" 2>/dev/null || echo 404)
body=$(cat "$W/${k}_body" 2>/dev/null || echo '{"error":"no stub"}')
printf '%s\n%s' "$body" "$code"
EOF
chmod +x "$FB/curl"

export PATH="$FB:$PATH" HOME="$T/home" JOBS_URL=http://stub HARNESS_SECRET=test-secret
unset HARNESS_PARTICIPANT_TOKEN_FILE LEAD_VERDICT_TOKEN_FILE
TF="$HOME/.config/cromford/participant-token"
PENDING='{"participant":{"id":"p-1","name":"my-laptop","status":"pending","requested_roles":["lead-review"],"granted_roles":null}}'

reset_w() { rm -f "$W"/req_* "$W"/who_* "$W"/dec_* "$W/curl_rc" "$W/curl_calls" "$W/last_body" "$W/paths"; : > "$W/hdrs"; }
# run <args...> — runs the script, sets RC, OUT, ERR; keeps every output in $W/all-out
run() {
  "$ME" "$@" > "$W/out" 2> "$W/err"; RC=$?
  OUT=$(cat "$W/out"); ERR=$(cat "$W/err")
  cat "$W/out" "$W/err" >> "$W/all-out"
}
: > "$W/argv"; : > "$W/bodies"; : > "$W/all-out"

# ── request ─────────────────────────────────────────────────────────────────
reset_w; echo 201 > "$W/req_code"; echo "$PENDING" > "$W/req_body"
run request my-laptop --roles lead-review --owner owner@example.com
TOKEN=$(cat "$TF" 2>/dev/null)
if [ "$RC" = 0 ] && [[ "$OUT" =~ ^pending\ [^\ ]+\ my-laptop$ ]] && [[ "$TOKEN" =~ ^[0-9a-f]{64}$ ]]; then ok; else bad "R1 rc=$RC out='$OUT' err='$ERR' token-shape='${#TOKEN}'"; fi
m=$(stat -c %a "$TF" 2>/dev/null || stat -f %Lp "$TF" 2>/dev/null)
[ "$m" = 600 ] && ok || bad "R2 token file mode is '$m', not 600"
h=$(jq -r .token_sha256 "$W/last_body" 2>/dev/null)
fh=$(sha256sum < "$TF" 2>/dev/null | cut -d' ' -f1)
roles=$(jq -c .requested_roles "$W/last_body" 2>/dev/null)
own=$(jq -r .owner "$W/last_body" 2>/dev/null)
if [[ "$h" =~ ^[0-9a-f]{64}$ ]] && [ "$h" = "$fh" ] && [ "$roles" = '["lead-review"]' ] && [ "$own" = owner@example.com ] \
   && [ -n "$TOKEN" ] && ! grep -qF "$TOKEN" "$W/last_body"; then ok; else bad "R3 body $(cat "$W/last_body" 2>/dev/null) file-hash=$fh"; fi
# the worker hashes the TRIMMED header value: the file must hash to the same thing
[ "$(printf '%s' "$TOKEN" | sha256sum | cut -d' ' -f1)" = "$h" ] && ok || bad "R3b token_sha256 is not sha256 of the token value"
TOKENS=("$TOKEN")

# R7 the file exists now: refused, no call, untouched
reset_w; echo 201 > "$W/req_code"; echo "$PENDING" > "$W/req_body"
before=$(cat "$TF")
run request my-laptop --roles lead-review
if [ "$RC" = 1 ] && [ ! -s "$W/curl_calls" ] && [ "$(cat "$TF")" = "$before" ]; then ok; else bad "R7 rc=$RC curl_calls=$(wc -l < "$W/curl_calls" 2>/dev/null) err='$ERR'"; fi

# ── status (with R1's token file) ───────────────────────────────────────────
reset_w; echo 403 > "$W/who_code"; echo '{"error":"participant is pending"}' > "$W/who_body"
run status
if [ "$RC" = 3 ] && [ "$OUT" = pending ] && grep -qxF "x-participant-token: $TOKEN" "$W/hdrs" \
   && grep -q '^## mode=600$' "$W/hdrs" && grep -qx 'GET /api/participants/whoami' "$W/paths"; then ok; else bad "S1 rc=$RC out='$OUT' err='$ERR'"; fi
reset_w; echo 200 > "$W/who_code"; echo '{"id":"p-1","name":"my-laptop","status":"approved","granted_roles":["lead-review"],"knobs":{}}' > "$W/who_body"
run status
if [ "$RC" = 0 ] && [[ "$OUT" == approved* ]] && [[ "$OUT" == *"roles=lead-review" ]]; then ok; else bad "S2 rc=$RC out='$OUT' err='$ERR'"; fi
reset_w; echo 403 > "$W/who_code"; echo '{"error":"unknown participant token"}' > "$W/who_body"
run status
if [ "$RC" = 1 ] && [ -z "$OUT" ] && [[ "$ERR" == *"unknown participant token"* ]]; then ok; else bad "S3 rc=$RC out='$OUT' err='$ERR'"; fi
mv "$TF" "$TF.keep"; (umask 077; : > "$TF")
reset_w; echo 401 > "$W/who_code"; echo '{"error":"needs x-participant-token"}' > "$W/who_body"
run status
[ "$RC" = 1 ] && [[ "$ERR" == *"empty"* ]] && [ ! -s "$W/curl_calls" ] && ok || bad "S4 empty token file: rc=$RC err='$ERR'"
rm -f "$TF"

# ── request failures: the token file never outlives a refused POST ─────────
reset_w; echo 409 > "$W/req_code"; echo '{"error":"name my-laptop is already pending"}' > "$W/req_body"
run request my-laptop --roles lead-review
if [ "$RC" = 1 ] && [ ! -e "$TF" ] && [[ "$ERR" == *"name my-laptop is already pending"* ]] && [ -s "$W/curl_calls" ]; then ok; else bad "R4 rc=$RC exists=$([ -e "$TF" ] && echo y || echo n) err='$ERR'"; fi
reset_w; echo 7 > "$W/curl_rc"
run request my-laptop --roles lead-review
[ "$RC" = 1 ] && [ ! -e "$TF" ] && [[ "$ERR" == *unreachable* ]] && ok || bad "R5 rc=$RC exists=$([ -e "$TF" ] && echo y || echo n) err='$ERR'"
reset_w; echo 201 > "$W/req_code"; echo '{}' > "$W/req_body"
run request my-laptop --roles lead-review
[ "$RC" = 1 ] && [ ! -e "$TF" ] && ok || bad "R6 rc=$RC exists=$([ -e "$TF" ] && echo y || echo n) err='$ERR'"
reset_w; echo 500 > "$W/req_code"; echo '{"error":"boom"}' > "$W/req_body"
run request my-laptop --roles lead-review
[ "$RC" = 1 ] && [ ! -e "$TF" ] && [[ "$ERR" == *boom* ]] && ok || bad "R6b 500: rc=$RC err='$ERR'"
reset_w; echo 201 > "$W/req_code"; echo "$PENDING" > "$W/req_body"
JOBS_URL= run request my-laptop --roles lead-review
[ "$RC" = 1 ] && [ ! -e "$TF" ] && [ ! -s "$W/curl_calls" ] && ok || bad "R6c JOBS_URL empty: rc=$RC err='$ERR'"
mv "$TF.keep" "$TF"

# ── approve / deny / revoke ─────────────────────────────────────────────────
reset_w; echo 200 > "$W/dec_code"
run approve p-1 --roles lead-review
[ "$RC" = 1 ] && [ ! -s "$W/curl_calls" ] && [[ "$ERR" == *LEAD_VERDICT_TOKEN_FILE* ]] && ok || bad "A1 rc=$RC err='$ERR'"
LTF="$T/lead-token"; (umask 077; echo lead-test-token > "$LTF")
export LEAD_VERDICT_TOKEN_FILE="$LTF"
reset_w; echo 200 > "$W/dec_code"
echo '{"participant":{"id":"p-1","name":"my-laptop","status":"approved","granted_roles":["lead-review"]}}' > "$W/dec_body"
run approve p-1 --roles lead-review --by ops
if grep -qxF 'x-lead-verdict-token: lead-test-token' "$W/hdrs" && grep -q '^## mode=600$' "$W/hdrs" \
   && ! grep -qF lead-test-token "$W/argv"; then ok; else bad "A2 lead token: hdrs=$(grep -c lead-test-token "$W/hdrs") argv=$(grep -c lead-test-token "$W/argv")"; fi
if [ "$RC" = 0 ] && [ "$OUT" = "approved p-1 my-laptop" ] && grep -qx 'POST /api/participants/p-1/approve' "$W/paths" \
   && [ "$(jq -c '{granted_roles, actor}' "$W/last_body")" = '{"granted_roles":["lead-review"],"actor":"ops"}' ]; then ok; else bad "A3 rc=$RC out='$OUT' body=$(cat "$W/last_body")"; fi
reset_w; echo 200 > "$W/dec_code"
echo '{"participant":{"id":"p-1","name":"my-laptop","status":"approved"},"unchanged":true}' > "$W/dec_body"
run approve p-1 --roles lead-review
[ "$RC" = 0 ] && [ "$OUT" = "approved p-1 my-laptop (unchanged)" ] && ok || bad "A3b repeat: rc=$RC out='$OUT'"
reset_w; echo 409 > "$W/dec_code"; echo '{"error":"participant is already approved with different granted_roles"}' > "$W/dec_body"
run approve p-1 --roles lead-review,other
[ "$RC" = 1 ] && [[ "$ERR" == *"different granted_roles"* ]] && ok || bad "A3c approve 409: rc=$RC err='$ERR'"
reset_w; echo 200 > "$W/dec_code"; echo '{"participant":{"id":"p-2","name":"other","status":"denied"}}' > "$W/dec_body"
run deny p-2
if [ "$RC" = 0 ] && [ "$OUT" = "denied p-2 other" ] && grep -qx 'POST /api/participants/p-2/deny' "$W/paths" \
   && [ "$(jq -c . "$W/last_body")" = '{}' ]; then ok; else bad "A4 rc=$RC out='$OUT'"; fi
reset_w; echo 409 > "$W/dec_code"; echo '{"error":"participant is pending; revoke needs approved"}' > "$W/dec_body"
run revoke p-1
[ "$RC" = 1 ] && [ -z "$OUT" ] && [[ "$ERR" == *"revoke needs approved"* ]] && ok || bad "A5 rc=$RC out='$OUT' err='$ERR'"
reset_w; echo 200 > "$W/dec_code"; echo '{}' > "$W/dec_body"
run revoke p-1
[ "$RC" = 1 ] && ok || bad "A5b a 200 with no participant is not success: rc=$RC out='$OUT'"

# ── doc ─────────────────────────────────────────────────────────────────────
for s in Request Approve Run Revoke; do
  grep -qi "^## .*$s" "$DOC" 2>/dev/null && ok || bad "D1 no '## ... $s' section in docs/add-your-own-machine.md"
done
if [ -f "$DOC" ] && ! grep -niE 'operator|cto\.com|project-3|project-1|project-2|project-4|project-5|mac-operator' "$DOC"; then ok; else bad "D2 the doc names a fleet box, client or owner (or is missing)"; fi
grep -q '^Doc: ' "$NOTE" 2>/dev/null && ok || bad "D3 no Doc: line in $NOTE"

# W1 the doc's own commands, verbatim and in order, against the stub: request,
# status (pending), approve, status (approved), revoke. `<id>` is the one
# placeholder, and it takes the id request printed.
rm -f "$TF"
grep -E '^bin/machine-enroll\.sh ' "$DOC" > "$W/doc-cmds" 2>/dev/null
n=0; walk=""
while IFS= read -r line; do
  n=$((n+1)); reset_w
  echo 201 > "$W/req_code"; echo "$PENDING" > "$W/req_body"
  echo 403 > "$W/who_code"; echo '{"error":"participant is pending"}' > "$W/who_body"
  [[ "$walk" == *approve* ]] && { echo 200 > "$W/who_code"; echo '{"id":"p-1","name":"my-laptop","status":"approved","granted_roles":["lead-review"],"knobs":{}}' > "$W/who_body"; }
  echo 200 > "$W/dec_code"
  case "$line" in *revoke*) s=revoked ;; *) s=approved ;; esac
  echo "{\"participant\":{\"id\":\"p-1\",\"name\":\"my-laptop\",\"status\":\"$s\"}}" > "$W/dec_body"
  cmd="${line//<id>/p-1}"
  (cd "$H" && eval "$cmd") > "$W/out" 2> "$W/err"; RC=$?
  cat "$W/out" "$W/err" >> "$W/all-out"
  walk="$walk $(printf '%s' "$line" | awk '{print $2}'):$RC:$(head -1 "$W/out")"
done < "$W/doc-cmds"
want=" request:0:pending p-1 my-laptop status:3:pending approve:0:approved p-1 my-laptop status:0:approved p-1 my-laptop roles=lead-review revoke:0:revoked p-1 my-laptop"
[ "$walk" = "$want" ] && ok || bad "W1 doc walk ($n commands): got '$walk' want '$want'"
[ -f "$TF" ] && TOKENS+=("$(cat "$TF")")

# ── cross-cutting: no participant token on argv, in output or in a body ────
for tk in "${TOKENS[@]}"; do
  [ -n "$tk" ] || continue
  grep -qF "$tk" "$W/argv" && bad "X1 a participant token is on argv: $(grep -F "$tk" "$W/argv" | head -1 | cut -c1-40)" || ok
  if grep -qF "$tk" "$W/all-out" || grep -qF "$tk" "$W/bodies"; then bad "X2 a participant token is in output or a body"; else ok; fi
done
grep -q '^openssl \|^od ' "$W/argv" && ok || bad "X1 the argv log saw no token generator (the wrappers are not in the path)"

echo "machine-enroll.bh-5348: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
