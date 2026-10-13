#!/bin/bash
# tests/board-conformance-origin.bh-3960-test.sh — the origin probe and the
# write-route catalog of the board conformance lane (BH-3960, part of BH-3947).
#
# Drives the REAL bin/board-conformance.sh with the REAL origin.sh and writes.sh,
# copied into a scratch harness by tests/lib/board-conformance-fixture.sh, with a
# stub curl answering from tests/fixtures/board-conformance/origin-*. The board
# lib is swapped for an rc-0 stub so these cases do not depend on the board probe.
# Fixed BC_NOW, no sleep, no network.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/board-conformance-origin.bh-3960-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/board-conformance-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
# logged <path> <want> [<unwanted>] — some curl line names <path>, carries <want>
# and not <unwanted>; one pass over the file, no grep|grep -q pipe.
logged() { awk -v p="$1" -v w="$2" -v u="${3:-}" 'index($0,p) && (w=="" || index($0,w)) && (u=="" || !index($0,u)) {f=1} END {exit !f}' "$CURL_LOG"; }

ENTRY="$DIR/bin/board-conformance.sh"
ORIGIN="$DIR/bin/lib/board-conformance/origin.sh"
WRITES="$DIR/bin/lib/board-conformance/writes.sh"
CATALOG="$DIR/catalog/board-features.json"
LIVE_BEFORE=$(ls -la /root/harness/state/board-conformance 2>/dev/null)
: > "$T/all-curl.log"; : > "$T/all-out.log"

# run — the real entry over p1; every run's curl log and output are kept for C14
# and C-secret2.
run() {
  OUT=$("$HARNESS/bin/board-conformance.sh" "$@" 2>"$T/err"); RC=$?
  cat "$CURL_LOG" >> "$T/all-curl.log"
  { printf '%s\n' "$OUT"; cat "$T/err" "$HARNESS/logs/board-conformance.log" "$HARNESS"/state/board-conformance/*.json; } >> "$T/all-out.log" 2>/dev/null
}
st() { printf '%s' "$HARNESS/state/board-conformance/p1.json"; }
item() { jq -r --arg n "$1" '.items[$n] | "\(.status)|\(.note)"' "$(st)"; }
setup() {
  bc_fixture_setup || bad "fixture setup"
  printf '# shellcheck shell=bash\nbc_probe_board() { return 0; }\n' > "$HARNESS/bin/lib/board-conformance/board.sh"
  bc_fixture_case "$1"
}
catalog() { mkdir -p "$HARNESS/catalog" && printf '%s\n' "$1" > "$HARNESS/catalog/board-features.json"; }
WRITE_ROUTES="write.comments write.move write.turn write.triage write.create"

# --- static ---------------------------------------------------------------------
for f in "$ORIGIN" "$WRITES"; do
  check "static bash -n $f" 'bash -n "$f"'
  if command -v shellcheck >/dev/null 2>&1; then
    check "static shellcheck $f" 'shellcheck -S error "$f" >/dev/null'
  fi
  check "static no /root/harness literal in $f" '! grep -q /root/harness "$f"'
done
check "static writes.sh makes no network call" '[ "$(grep -cE "bc_get|curl" "$WRITES")" -eq 0 ]'
check "static catalog ships empty" "jq -e '.projects=={} and (._doc|length)>0' \"$CATALOG\" >/dev/null"

# --- C1 (origin-ok) ---------------------------------------------------------------
setup origin-ok
run p1
check "C1 rc 0 (got $RC: $(cat "$T/err"))" '[ "$RC" -eq 0 ]'
check "C1 origin.health ok (got $(item origin.health))" '[ "$(item origin.health)" = "ok|" ]'
check "C1 internal.version ok with sha prefix (got $(item internal.version))" '[ "$(item internal.version)" = "ok|sha abc123def456" ]'
check "C1 internal.migrations ok (got $(item internal.migrations))" '[ "$(item internal.migrations)" = "ok|" ]'
for r in $WRITE_ROUTES; do
  check "C1-writes $r unverified, no catalog (got $(item "$r"))" '[ "$(item "$r")" = "unverified|no catalog/board-features.json" ]'
done
check "C1 exactly 5 write items" "[ \"\$(jq '[.items|keys[]|select(startswith(\"write.\"))]|length' \"$(st)\")\" -eq 5 ]"
check "C1 no gaps" "jq -e '.gaps==[]' \"$(st)\" >/dev/null"
check "C1 summary (got: $OUT)" '[ "$OUT" = "p1 ok=3 missing=0 malformed=0 unverified=5 gaps: " ]'
# --- C-count ---
check "C-count 3 GETs (got $(wc -l < "$CURL_LOG"))" '[ "$(wc -l < "$CURL_LOG")" -eq 3 ]'
check "C-count health without a token" 'logged /api/health "" Authorization'
check "C-count version with the board token" 'logged /api/internal/version "Authorization: Bearer tok-p1"'
check "C-count migrations with the migration token" 'logged /api/internal/migrations/status "Authorization: Bearer mt-p1"'

# --- C6 / C6b -------------------------------------------------------------------
setup origin-version404
run p1
check "C6 rc 1 (got $RC)" '[ "$RC" -eq 1 ]'
check "C6 internal.version missing (got $(item internal.version))" '[ "$(item internal.version)" = "missing|" ]'
check "C6 gaps" "jq -e '.gaps==[\"internal.version\"]' \"$(st)\" >/dev/null"
setup origin-version-empty
run p1
check "C6b internal.version malformed (got $(item internal.version))" '[ "$(item internal.version)" = "malformed|2xx without a .sha string" ]'
check "C6b rc 1" '[ "$RC" -eq 1 ]'
# a 2xx that is not JSON, and a .sha that is not a non-empty string
for body in '<html>hi</html>' '{"sha":12345}' '{"sha":""}' '{"sha":null}'; do
  setup origin-ok
  mkdir -p "$T/fx" && cp "$FX"/* "$T/fx/" && printf '%s\n' "$body" > "$T/fx/api_internal_version.json"; FX="$T/fx"
  run p1
  check "C6b body $body is malformed (got $(item internal.version))" '[ "$(item internal.version)" = "malformed|2xx without a .sha string" ]'
  scratch_rm "$T/fx"
done

# --- C8 / C8-notoken ---------------------------------------------------------------
setup origin-unwell
run p1
check "C8 health 503 is ok with the note (got $(item origin.health))" '[ "$(item origin.health)" = "ok|5xx: present, reporting unwell" ]'
check "C8 migrations targets shape ok (got $(item internal.migrations))" '[ "$(item internal.migrations)" = "ok|" ]'
check "C8 rc 0 (got $RC)" '[ "$RC" -eq 0 ]'
setup origin-ok
printf 'P1_API_BASE=https://p1.example\nP1_INTERNAL_API_TOKEN=tok-p1\n' > "$HARNESS/env/p1.env"
run p1
check "C8-notoken migrations unverified (got $(item internal.migrations))" '[ "$(item internal.migrations)" = "unverified|no MIGRATION_TOKEN" ]'
check "C8-notoken no migrations request" '! grep -q migrations/status "$CURL_LOG"'
check "C8-notoken rc 0" '[ "$RC" -eq 0 ]'
# migrations bodies that are 2xx but not the contract
for body in '{"targets":{}}' '{"targets":{"prod":{"pending":[]}}}' '{"applied":["001"]}' 'not json'; do
  setup origin-ok
  mkdir -p "$T/fx" && cp "$FX"/* "$T/fx/" && printf '%s\n' "$body" > "$T/fx/api_internal_migrations_status.json"; FX="$T/fx"
  run p1
  check "C8 migrations body $body is malformed (got $(item internal.migrations))" '[ "$(item internal.migrations)" = "malformed|2xx with neither applied+pending arrays nor a targets map" ]'
  scratch_rm "$T/fx"
done

# --- C-other ---------------------------------------------------------------------------
setup origin-other
run p1
check "C-other health 302 malformed (got $(item origin.health))" '[ "$(item origin.health)" = "malformed|HTTP 302" ]'
check "C-other version 401 malformed (got $(item internal.version))" '[ "$(item internal.version)" = "malformed|HTTP 401" ]'
check "C-other migrations 500 unverified (got $(item internal.migrations))" '[ "$(item internal.migrations)" = "unverified|HTTP 500" ]'
check "C-other gaps" "jq -e '.gaps==[\"internal.version\",\"origin.health\"]' \"$(st)\" >/dev/null"
# version 5xx and 000 are unverified; health 000 is unverified; migrations 404 missing
setup origin-ok
mkdir -p "$T/fx" && cp "$FX"/* "$T/fx/" && echo 502 > "$T/fx/api_internal_version.code.txt" \
  && echo 404 > "$T/fx/api_internal_migrations_status.code.txt" && echo 000 > "$T/fx/api_health.code.txt"; FX="$T/fx"
run p1
check "C-other version 502 unverified (got $(item internal.version))" '[ "$(item internal.version)" = "unverified|HTTP 502" ]'
check "C-other migrations 404 missing (got $(item internal.migrations))" '[ "$(item internal.migrations)" = "missing|" ]'
check "C-other health 000 unverified (got $(item origin.health))" '[ "$(item origin.health)" = "unverified|no answer" ]'
scratch_rm "$T/fx"

# --- C-noprod --------------------------------------------------------------------------
setup origin-ok
sed -i 's#^p1 org/p1 https://p1.example #p1 org/p1 - #' "$HARNESS/fleet.conf"
run p1
check "C-noprod health unverified (got $(item origin.health))" '[ "$(item origin.health)" = "unverified|no prod origin" ]'
check "C-noprod no health request" '! grep -q /api/health "$CURL_LOG"'
check "C-noprod version still ok (got $(item internal.version))" '[ "$(item internal.version)" = "ok|sha abc123def456" ]'

# --- C12 (the catalog) ------------------------------------------------------------------
setup origin-ok
catalog '{"_doc":"t","projects":{"p1":{"write.comments":{"status":"ok","source":"app PR #1"}}}}'
run p1
check "C12a write.comments ok from the catalog (got $(item write.comments))" '[ "$(item write.comments)" = "ok|app PR #1" ]'
check "C12a write.move no row (got $(item write.move))" '[ "$(item write.move)" = "unverified|no catalog row" ]'
setup origin-ok
catalog '{"_doc":"t","projects":{"p1":{"write.comments":{"status":"ok"}}}}'
run p1
check "C12b no source is unverified (got $(item write.comments))" '[ "$(item write.comments)" = "unverified|row has no source" ]'
setup origin-ok
catalog '{"_doc":"t","projects":{"p1":{"write.comments":{"status":"ok","source":""}}}}'
run p1
check "C12b empty source is unverified (got $(item write.comments))" '[ "$(item write.comments)" = "unverified|row has no source" ]'
setup origin-ok
catalog '{"_doc":"t","projects":{"p2":{"write.comments":{"status":"ok","source":"app PR #1"}}}}'
run p1
check "C12c another project's row does not apply (got $(item write.comments))" '[ "$(item write.comments)" = "unverified|no catalog row" ]'
run p2
P2ST="$HARNESS/state/board-conformance/p2.json"
check "C12c p2 reads its own row (got $(jq -c '.items["write.comments"]' "$P2ST"))" "jq -e '.items[\"write.comments\"]=={status:\"ok\",note:\"app PR #1\"}' \"$P2ST\" >/dev/null"
setup origin-ok
catalog '{"_doc":"t","projects":{"p1":{"write.move":{"status":"missing","source":"app PR #2"}}}}'
run p1
check "C12-status missing (got $(item write.move))" '[ "$(item write.move)" = "missing|app PR #2" ]'
check "C12-status in gaps, rc 1" "[ \"\$RC\" -eq 1 ] && jq -e '.gaps==[\"write.move\"]' \"$(st)\" >/dev/null"
setup origin-ok
catalog '{"_doc":"t","projects":{"p1":{"write.turn":{"status":"malformed","source":"app PR #3"}}}}'
run p1
check "C12-status other status unverified (got $(item write.turn))" '[ "$(item write.turn)" = "unverified|row status malformed is not ok|missing" ]'
setup origin-ok
catalog '[]'
run p1
for r in $WRITE_ROUTES; do
  check "C12-bad [] catalog: $r unverified (got $(item "$r"))" '[ "$(item "$r")" = "unverified|catalog unreadable" ]'
done
setup origin-ok
catalog '{"projects":'
run p1
check "C12-bad unparseable catalog (got $(item write.create))" '[ "$(item write.create)" = "unverified|catalog unreadable" ]'
setup origin-ok
catalog '{"_doc":"t","projects":{}}'
run p1
check "C12-empty the shipped shape reads no row (got $(item write.triage))" '[ "$(item write.triage)" = "unverified|no catalog row" ]'

# --- C14 / C-secret2 (over every run above) ----------------------------------------------
check "C14 curl ran" '[ -s "$T/all-curl.log" ]'
check "C14 no -X/-d/--data" '! grep -qE "(^| )(-X|-d|--data[a-z-]*)( |$)" "$T/all-curl.log"'
check "C14 no write-route path" '! grep -qE "/(comments|move|turn|triage)( |$|/|\?)" "$T/all-curl.log"'
check "C-secret2 tokens only as bearers" '[ -z "$(grep -E "tok-p1|mt-p1" "$T/all-curl.log" | sed -E "s/Authorization: Bearer (tok|mt)-p1//g" | grep -E "tok-p1|mt-p1")" ]'
check "C-secret2 no token in state, output or log" '! grep -qE "tok-p|mt-p" "$T/all-out.log"'

# --- the live harness was never touched ----------------------------------------------------
check "live /root/harness/state/board-conformance unchanged" '[ "$(ls -la /root/harness/state/board-conformance 2>/dev/null)" = "$LIVE_BEFORE" ]'

echo "board-conformance-origin: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
