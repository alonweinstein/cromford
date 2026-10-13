#!/bin/bash
# tests/lead-verdict-priority.bh-5151-test.sh — BH-5151: `bin/lead-verdict.sh
# request … --priority <n>` puts the request ahead of older ones, replacing the
# hand-backdating of created_at. Driven through the REAL CLI with only curl
# stubbed (it records the posted body and answers from $T/answer):
#   * --priority 5 sends "priority":5 and is rc 0 when the row comes back with it;
#   * 0 / abc / 1001 / -3 are usage (rc 2) and send nothing;
#   * a row that comes back without that priority (an old worker, or a running
#     row that keeps its order) is rc 1 with a "was not stored" line, never a
#     quiet success;
#   * no --priority sends no priority key at all.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-verdict-priority.bh-5151-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SHA=abcdef0123456789abcdef0123456789abcdef01
SLUG=example-org/cromford
H="$T/h"; mkdir -p "$H/bin" "$T/fakebin" "$T/log" "$T/tmp"
scratch_install_closure bin/lead-verdict.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/lead-reviews.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
# jobs-client.sh exits on a missing module: the closure must have brought them.
[ -r "$H/bin/lib/jobs/req.sh" ] || { echo "the closure did not install bin/lib/jobs/*.sh"; exit 1; }

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
prev=""; post=0; body=""
for a in "\$@"; do
  [ "\$prev" = -X ] && [ "\$a" = POST ] && post=1
  [ "\$prev" = --data-binary ] && body="\$a"
  prev="\$a"
done
[ "\$post" = 1 ] && printf '%s\n' "\$body" >> "$T/log/posted"
code=\$(head -1 "$T/answer"); resp=\$(tail -n +2 "$T/answer")
printf '%s\n%s' "\$resp" "\$code"
EOF
chmod +x "$T/fakebin/curl"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
TOKF="$T/tok"; printf 'tok-9\n' > "$TOKF"; chmod 600 "$TOKF"
export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BOX=testbox TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$TOKF"

row() { # row <status> [priority] -> a POST answer body
  jq -nc --arg s "$SHA" --arg st "$1" --arg p "${2:-}" \
    '{request:({id:31,repo:"example-org/cromford",pr:12,head_sha:$s,status:$st}
      + (if $p == "" then {} else {priority:($p|tonumber)} end))}'
}
answer() { printf '%s\n%s' "$1" "$2" > "$T/answer"; }
reset()  { rm -f "$T/log"/*; }
# posts — the request bodies posted. BH-4956: a stored request is followed by
# the nudge's gate event and doorbell POSTs, which carry no requested_by.
posts()  { [ -f "$T/log/posted" ] && grep -c '"requested_by"' "$T/log/posted" || echo 0; }
lv()     { bash "$H/bin/lead-verdict.sh" "$@" > "$T/out" 2> "$T/err"; RC=$?; }

# p1: --priority 5 rides in the body as a number; the stored row echoes it -> rc 0
reset; answer 201 "$(row requested 5)"
lv request "$SLUG" 12 "$SHA" --priority 5
[ "$RC" = 0 ] && ok || bad "p1 rc=$RC: $(cat "$T/out" "$T/err")"
[ "$(posts)" = 1 ] && ok || bad "p1 posts=$(posts)"
[ "$(head -1 "$T/log/posted" 2>/dev/null | jq -c .priority)" = 5 ] && ok || bad "p1 body: $(cat "$T/log/posted" 2>/dev/null)"
# with --notes beside it, in either order
reset; answer 201 "$(row requested 7)"
lv request "$SLUG" 12 "$SHA" --priority 7 --notes "look at the lane"
[ "$RC" = 0 ] && [ "$(head -1 "$T/log/posted" | jq -c '[.priority,.scope_notes]')" = '[7,"look at the lane"]' ] \
  && ok || bad "p1b rc=$RC body: $(cat "$T/log/posted" 2>/dev/null)"

# p2: out-of-range or not a number -> usage, nothing sent
for v in 0 abc 1001 -3 1.5 ''; do
  reset; answer 201 "$(row requested 5)"
  lv request "$SLUG" 12 "$SHA" --priority "$v"
  [ "$RC" = 2 ] && ok || bad "p2 --priority '$v' rc=$RC (want 2)"
  [ "$(posts)" = 0 ] && ok || bad "p2 --priority '$v' sent a request"
done
reset; answer 201 "$(row requested 5)"
lv request "$SLUG" 12 "$SHA" --priority
[ "$RC" = 2 ] && [ "$(posts)" = 0 ] && ok || bad "p2 a bare --priority rc=$RC posts=$(posts)"

# p3: an old worker ignores the field -> rc 1 and says so
reset; answer 201 "$(row requested)"
lv request "$SLUG" 12 "$SHA" --priority 5
[ "$RC" = 1 ] && ok || bad "p3 rc=$RC (want 1): $(cat "$T/out" "$T/err")"
grep -q 'priority 5 was not stored' "$T/err" && ok || bad "p3 stderr: $(cat "$T/err")"

# p4: the existing row is running and keeps its old priority -> rc 1
reset; answer 200 "$(row running 2 | jq -c '. + {existing:true}')"
lv request "$SLUG" 12 "$SHA" --priority 9
[ "$RC" = 1 ] && grep -q 'priority 9 was not stored (request #31 is running' "$T/err" && ok \
  || bad "p4 rc=$RC err: $(cat "$T/err")"

# p5: no --priority -> no priority key, rc 0 even when the row carries none
reset; answer 201 "$(row requested)"
lv request "$SLUG" 12 "$SHA"
[ "$RC" = 0 ] && ok || bad "p5 rc=$RC"
B=$(head -1 "$T/log/posted" 2>/dev/null)
jq -e 'has("priority")|not' <<<"$B" >/dev/null 2>&1 && ok || bad "p5 body carries priority: $B"
[ "$(jq -c 'keys' <<<"$B")" = '["head_sha","pr","repo","requested_by"]' ] && ok || bad "p5 body keys changed: $B"

# p6: a refused request is still rc 1 (the priority check never turns it into 0)
reset; answer 400 '{"error":"priority must be an integer 1..1000"}'
lv request "$SLUG" 12 "$SHA" --priority 5
[ "$RC" = 1 ] && ok || bad "p6 rc=$RC"

echo "lead-verdict-priority: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
