#!/bin/bash
# tests/flags-composition.bh-4153-test.sh — BH-4153 on top of BH-5004 (the operator,
# 2026-10-09, #4332): which model answers which flag name.
#
#   paused-*, automerge-disabled, automerge-disabled-*, lanedown-* (ported)
#     BH-4153: the harness_flags row is the answer, the box keeps a last-good
#     cache in state/flags-cache/, NO flags/<name> file is written, and a stop
#     switch that cannot be read and has nothing cached is ON.
#   every other name
#     BH-5004: the pause_flags row is the answer, flags/<name> is its mirror and
#     the fallback, a file strictly newer than an inactive row is ON (BH-1370's
#     local-touch rule), and flag_set PUTs first and still writes the file when
#     the PUT fails.
#
#   C1 ported, active row: ON, no file, cache on
#   C2 ported flag_set on: rc 0, PUT carries scope, no file
#   C3 ported, worker down, nothing cached: ON (fails closed), one log line
#   C4 ported, worker down, a cleared row cached: OFF
#   C5 non-ported, active row: ON, the mirror file written at the row's time
#   C6 non-ported, inactive row: a file touched after it is ON; an older file
#      is OFF and removed
#   C7 non-ported, worker down: the file decides, with BH-5004's log line
#   C8 non-ported flag_set with the PUT failing: rc 1 and the file is written
#   C9 CLI flag-active names its source: harness_flags for a ported name,
#      the pause_flags row for any other
#
# Driven, not grepped: the real bin/jobs-client.sh against a curl shim. Every
# timestamp is a literal.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/flags-composition.bh-4153-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -r "$DIR/bin/lib/jobs/flags.sh" ] || { echo "FAIL: no bin/lib/jobs/flags.sh"; exit 1; }

T1=2026-09-19T01:00:00Z; E1=1789779600
E2=1789783200            # 2026-09-19T02:00:00Z

# curl: the fake worker. GET /api/flags/<n> answers $ROWS/<n>.json (404 without
# one). PUT /api/flags echoes the written row in the harness_flags shape, which
# carries the legacy active/updated_at too. CURL_MODE=down is the outage arm,
# CURL_MODE=putfail fails PUTs only.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "${REQ_SINK:-/dev/null}"
[ "${CURL_MODE:-ok}" = down ] && exit 7
case "$METHOD $URL" in
  "PUT "*/api/flags)
    [ "${CURL_MODE:-ok}" = putfail ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    printf '%s' "$BODY" | jq -c '{flag:{name, scope:(.scope // "fleet"), active, value:(.value // null),
      set_by:.actor, set_at:"2026-09-19T03:00:00Z",
      cleared_at:(if .active == 1 then null else "2026-09-19T03:00:00Z" end), updated_at:"2026-09-19T03:00:00Z"}}'
    printf '200\n' ;;
  "GET "*/api/flags/*)
    n="${URL##*/}"; n="${n%%\?*}"
    if [ -s "${ROWS:-/nonexistent}/$n.json" ]; then cat "$ROWS/$n.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

TPL="$T/tpl"; mkdir -p "$TPL"
scratch_install_closure bin/jobs-client.sh "$TPL" >/dev/null || { echo "FAIL: install bin/jobs-client.sh closure"; exit 1; }
mkdir -p "$TPL/env" "$TPL/logs" "$TPL/state"
echo "HARNESS_SECRET=test-secret" > "$TPL/env/global.env"

H=""; SINK="$T/req.log"; _N=0
fresh() { H="$T/h$((++_N))"; cp -a "$TPL" "$H"; mkdir -p "$H/rows" "$H/flags"; : > "$SINK"; }
# hrow <name> <set_at> [cleared_at] — a harness_flags row (ported)
hrow() { jq -nc --arg n "$1" --arg s "$2" --arg c "${3:-}" \
  '{flag:{name:$n, scope:"fleet", value:null, set_by:"console", reason:null, set_at:$s,
     cleared_at:(if $c == "" then null else $c end), active:(if $c == "" then 1 else 0 end),
     actor:"console", updated_at:(if $c == "" then $s else $c end)}}' > "$H/rows/$1.json"; }
# prow <name> <active> <updated_at> — a legacy pause_flags row (non-ported)
prow() { printf '{"flag":{"name":"%s","active":%s,"updated_at":"%s"}}' "$1" "$2" "$3" > "$H/rows/$1.json"; }
_env() { printf '%s\n' PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_RETRIES=0 \
  JOBS_URL=https://jobs.invalid JOBS_BOX=boxa ROWS="$H/rows" REQ_SINK="$SINK"; }
insh() { # insh '<commands>' — one sourced shell; stdout $T/out, stderr $T/err
  ( while IFS= read -r kv; do export "${kv?}"; done < <(_env)
    # shellcheck disable=SC2086
    [ -n "${EXTRA_ENV:-}" ] && export ${EXTRA_ENV}
    bash -c ". \"\$HARNESS/bin/jobs-client.sh\" || exit 99; $1" >"$T/out" 2>"$T/err" )
}
client() { # client <verb> [args...] — the CLI
  ( while IFS= read -r kv; do export "${kv?}"; done < <(_env)
    bash "$H/bin/jobs-client.sh" "$@" >"$T/out" 2>"$T/err" )
}
log_has() { grep -qF -- "$1" "$H/logs/jobs-client.log" 2>/dev/null; }
mt() { stat -c %Y "$1" 2>/dev/null; }

echo "== C1. ported, active row: ON, no file, cache on =="
fresh; hrow paused-p "$T1"
insh 'flag_active paused-p'; RC=$?
[ "$RC" = 0 ] && ok || bad "C1: rc $RC, want 0 ($(cat "$T/err"))"
[ ! -e "$H/flags/paused-p" ] && ok || bad "C1: a ported flag must write no flags/ file"
[ "$(jq -r .on "$H/state/flags-cache/fleet/paused-p" 2>/dev/null)" = true ] && ok \
  || bad "C1: the cache must say on ($(cat "$H/state/flags-cache/fleet/paused-p" 2>/dev/null))"

echo "== C2. ported flag_set on: rc 0, scope in the PUT, no file =="
fresh
insh 'flag_set paused-p on "freeze"'; RC=$?
[ "$RC" = 0 ] && ok || bad "C2: rc $RC ($(cat "$T/err"))"
grep -q '^PUT [^ ]*/api/flags .*"name":"paused-p".*"scope":"fleet"' "$SINK" && ok || bad "C2: the PUT must carry scope fleet ($(cat "$SINK"))"
[ ! -e "$H/flags/paused-p" ] && ok || bad "C2: no flags/paused-p file"

echo "== C3. ported, worker down, nothing cached: ON =="
fresh
EXTRA_ENV="CURL_MODE=down" insh 'flag_active paused-p'; RC=$?
[ "$RC" = 0 ] && ok || bad "C3: an unreadable stop switch with no cache must read ON (rc $RC)"
log_has 'read as ON' && ok || bad "C3: no fail-closed log line ($(cat "$H/logs/jobs-client.log" 2>/dev/null))"
[ ! -e "$H/flags/paused-p" ] && ok || bad "C3: no file"

echo "== C4. ported, worker down, a cleared row cached: OFF =="
fresh; hrow paused-p "$T1" "$T1"
insh 'flag_active paused-p'; RC=$?
[ "$RC" = 1 ] && ok || bad "C4 setup: a cleared row is OFF (rc $RC)"
EXTRA_ENV="CURL_MODE=down" insh 'flag_active paused-p'; RC=$?
[ "$RC" = 1 ] && ok || bad "C4: the last good answer (cleared) must decide during the outage (rc $RC)"

echo "== C5. non-ported, active row: ON, mirror file at the row's time =="
fresh; prow builder-fly-p 1 "$T1"
insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 0 ] && ok || bad "C5: rc $RC"
[ "$(mt "$H/flags/builder-fly-p")" = "$E1" ] && ok || bad "C5: mirror mtime '$(mt "$H/flags/builder-fly-p")', want $E1"
[ ! -e "$H/state/flags-cache/fleet/builder-fly-p" ] && ok || bad "C5: a non-ported name has no harness_flags cache"

echo "== C6. non-ported, inactive row: the local-touch rule =="
fresh; prow builder-fly-p 0 "$T1"; touch -d "@$E2" "$H/flags/builder-fly-p"
insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 0 ] && ok || bad "C6: a file touched after the inactive row must be ON (rc $RC)"
[ -e "$H/flags/builder-fly-p" ] && ok || bad "C6: the newer file stays"
fresh; prow builder-fly-p 0 "$T1"; touch -d "@$((E1 - 600))" "$H/flags/builder-fly-p"
insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 1 ] && ok || bad "C6: a file older than the inactive row is OFF (rc $RC)"
[ ! -e "$H/flags/builder-fly-p" ] && ok || bad "C6: the older file is removed by the mirror"

echo "== C7. non-ported, worker down: the file decides =="
fresh; touch -d "@$E1" "$H/flags/builder-fly-p"
EXTRA_ENV="CURL_MODE=down" insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 0 ] && ok || bad "C7: the file must decide ON (rc $RC)"
log_has 'decided from flags/builder-fly-p (active)' && ok || bad "C7: no BH-5004 fallback line ($(cat "$H/logs/jobs-client.log" 2>/dev/null))"
fresh
EXTRA_ENV="CURL_MODE=down" insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 1 ] && ok || bad "C7: no file and no row is OFF for a non-ported name (rc $RC)"

echo "== C8. non-ported flag_set, PUT fails: rc 1, file written =="
fresh
EXTRA_ENV="CURL_MODE=putfail" insh 'flag_set builder-fly-p on "brake"'; RC=$?
[ "$RC" = 1 ] && ok || bad "C8: rc $RC, want 1"
[ -e "$H/flags/builder-fly-p" ] && ok || bad "C8: the file is the local brake during the outage"

echo "== C9. CLI flag-active names its source =="
fresh; hrow paused-p "$T1"
client flag-active paused-p; RC=$?
[ "$RC" = 0 ] && grep -q 'source: harness_flags row' "$T/err" && ok || bad "C9: ported source line ($(cat "$T/err"))"
fresh; prow builder-fly-p 1 "$T1"
client flag-active builder-fly-p; RC=$?
[ "$RC" = 0 ] && grep -q 'source: pause_flags row' "$T/err" && ok || bad "C9: non-ported source line ($(cat "$T/err"))"

echo "flags-composition.bh-4153: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
