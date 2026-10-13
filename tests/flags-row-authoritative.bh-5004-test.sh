#!/bin/bash
# tests/flags-row-authoritative.bh-5004-test.sh — BH-5004 (BH-4951.5): the
# pause_flags ROW is the decision, and flags/<name> is its mirror and fallback.
#
# What changed in bin/lib/jobs/flags.sh: flag_active used to reconcile the file
# and then answer `[ -f flags/<name> ]`, so a mirror write that failed (flags/
# unwritable, a stale file rm could not remove) changed the answer. It now
# answers from the row it read, a short process-local TTL cache bounds the GETs,
# flag_set PUTs the row before it touches the file, and the file decides only
# when the row cannot be read, with one jobs-client.log line when a configured
# worker failed. Case 7 pins the main-red publish -> main_red_events chain end
# to end through the REAL bin/main-red-detector.sh and the REAL worker.
#
# Driven, not grepped: the real bin/jobs-client.sh (CLI and sourced) against a
# curl shim standing in for the worker. Assertions are on rc, files, mtimes,
# the request sink, the log and DB rows. Every timestamp is a literal.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/flags-row-authoritative.bh-5004-test.sh
# TEST-CHANGE (the operator, 2026-10-09, #4332): paused-*, automerge-disabled* and
# lanedown-* are BH-4153 harness_flags rows now; BH-5004 governs every other
# name. This suite pins BH-5004, so its subject is a non-ported name
# (builder-fly-p, a real pause_flags family) instead of paused-p. Every
# assertion is unchanged. tests/flags-composition.bh-4153-test.sh pins the split.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The library under test, by rooted path (D41).
FLAGS_LIB="$DIR/bin/lib/jobs/flags.sh"
[ -r "$FLAGS_LIB" ] || { echo "FAIL: no $FLAGS_LIB"; exit 1; }

T1=2026-09-19T01:00:00Z; E1=1789779600
T2=2026-09-19T02:00:00Z; E2=1789783200
E3=1789786800            # the shim PUT's updated_at, 2026-09-19T03:00:00Z

# curl: the fake worker. Every request lands in REQ_SINK as "METHOD URL BODY".
# GET /api/flags/<n> answers $ROWS/<n>.json (404 without one). PUT /api/flags
# echoes the written row at a FIXED updated_at, and first records whether
# $PROBE_FLAG existed at that moment. CURL_MODE=down|500 are the outage arms.
mkdir -p "$T/fakebin" "$T/rmbin"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "${REQ_SINK:-/dev/null}"
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
  500)  printf '{}\n500\n'; exit 0 ;;
esac
case "$METHOD $URL" in
  "PUT "*/api/flags)
    if [ -n "${PROBE_FLAG:-}" ]; then
      if [ -e "$PROBE_FLAG" ]; then echo present >> "$PROBE_OUT"; else echo absent >> "$PROBE_OUT"; fi
    fi
    printf '%s' "$BODY" | jq -c '{flag:{name:.name,active:.active,updated_at:"2026-09-19T03:00:00Z"}}'
    printf '200\n' ;;
  "GET "*/api/flags/*)
    n="${URL##*/}"
    if [ -s "${ROWS:-/nonexistent}/$n.json" ]; then cat "$ROWS/$n.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  "GET "*"/api/main-red?all=1") printf '{"main_red":[],"truncated":false}\n200\n' ;;
  "PUT "*"/api/main-red") printf '{"ok":true}\n200\n' ;;
  *) printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
# rm: refuses exactly $RM_REFUSE (case 2b), so a stale file survives the mirror.
cat > "$T/rmbin/rm" <<'EOF'
#!/bin/bash
for a in "$@"; do [ -n "${RM_REFUSE:-}" ] && [ "$a" = "$RM_REFUSE" ] && exit 1; done
exec /bin/rm "$@"
EOF
chmod +x "$T/rmbin/rm"

TPL="$T/tpl"; mkdir -p "$TPL"
scratch_install_closure bin/jobs-client.sh "$TPL" >/dev/null || { echo "FAIL: install bin/jobs-client.sh closure"; exit 1; }
mkdir -p "$TPL/env" "$TPL/logs" "$TPL/state"
echo "HARNESS_SECRET=test-secret" > "$TPL/env/global.env"

H=""; FLAG=""; SINK="$T/req.log"
fresh() { # fresh [flags-as-file] — a new scratch harness in $H
  H="$T/h$((++_N))"; cp -a "$TPL" "$H"; mkdir -p "$H/rows"
  if [ "${1:-}" = flags-as-file ]; then : > "$H/flags"; else mkdir -p "$H/flags"; fi
  FLAG="$H/flags/builder-fly-p"; : > "$SINK"; : > "$T/probe"
}
_N=0
row() { printf '{"flag":{"name":"builder-fly-p","active":%s,"updated_at":"%s"}}' "$1" "$2" > "$H/rows/builder-fly-p.json"; }
rawrow() { printf '%s' "$1" > "$H/rows/builder-fly-p.json"; }
# env for every client run; JOBS_URL_V lets a case blank the worker.
_env() { printf '%s\n' PATH="${XPATH:-}$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_RETRIES=0 \
  JOBS_URL="${JOBS_URL_V-https://jobs.invalid}" ROWS="$H/rows" REQ_SINK="$SINK" PROBE_OUT="$T/probe"; }
client() { # client <verb> [args...] — the CLI; stdout $T/out, stderr $T/err, rc returned
  ( while IFS= read -r kv; do export "${kv?}"; done < <(_env)
    # shellcheck disable=SC2086
    [ -n "${EXTRA_ENV:-}" ] && export ${EXTRA_ENV}
    bash "$H/bin/jobs-client.sh" "$@" >"$T/out" 2>"$T/err" )
}
insh() { # insh '<commands>' — one sourced shell, so the in-process cache is live
  ( while IFS= read -r kv; do export "${kv?}"; done < <(_env)
    # shellcheck disable=SC2086
    [ -n "${EXTRA_ENV:-}" ] && export ${EXTRA_ENV}
    bash -c ". \"\$HARNESS/bin/jobs-client.sh\" || exit 99; $1" >"$T/out" 2>"$T/err" )
}
gets() { grep -c '^GET [^ ]*/api/flags/' "$SINK"; }
puts() { grep -c '^PUT [^ ]*/api/flags ' "$SINK"; }
log_has() { grep -qF -- "$1" "$H/logs/jobs-client.log" 2>/dev/null; }
mt() { stat -c %Y "$1" 2>/dev/null; }

echo "== 1. row active=1, no file, flags/ is a regular FILE: the row answers =="
fresh flags-as-file; row 1 "$T1"
insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 0 ] && ok || bad "1: rc $RC — a row that says ON must be ON when the mirror cannot write ($(cat "$T/err"))"
echo "== 1b. the same with a writable flags/: the mirror creates the file at the row's epoch =="
fresh; row 1 "$T1"
insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 0 ] && ok || bad "1b: rc $RC"
[ "$(mt "$FLAG")" = "$E1" ] && ok || bad "1b: mirror file mtime '$(mt "$FLAG")', want $E1"

echo "== 2. row active=0 @T2, stale file @T1: rc 1 and the file is gone =="
fresh; row 0 "$T2"; touch -d "@$E1" "$FLAG"
insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 1 ] && ok || bad "2: rc $RC"
[ -e "$FLAG" ] && bad "2: stale file survived the mirror" || ok
echo "== 2b. the same stale file, unremovable: the row still answers rc 1 =="
fresh; row 0 "$T2"; touch -d "@$E1" "$FLAG"
XPATH="$T/rmbin:" EXTRA_ENV="RM_REFUSE=$FLAG" insh 'flag_active builder-fly-p'; RC=$?
[ -e "$FLAG" ] && ok || bad "2b: the rm shim did not hold the file (fixture broken)"
[ "$RC" = 1 ] && ok || bad "2b: rc $RC — a leftover stale file must not read as paused"
echo "== 2c. BH-1370 kept: row active=0 @T1, local touch @T2: the newer touch wins =="
fresh; row 0 "$T1"; touch -d "@$E2" "$FLAG"
insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 0 ] && ok || bad "2c: rc $RC — a local touch newer than the row must hold"
[ -e "$FLAG" ] && ok || bad "2c: the newer local file was removed"

echo "== 3. worker 500: the file decides, and the fallback is logged =="
fresh; row 1 "$T1"; touch -d "@$E1" "$FLAG"
EXTRA_ENV="CURL_MODE=500" insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 0 ] && ok || bad "3: rc $RC with the file present"
log_has 'decided from flags/builder-fly-p (active)' && ok || bad "3: no fallback line: $(cat "$H/logs/jobs-client.log" 2>/dev/null)"
fresh; row 1 "$T1"
EXTRA_ENV="CURL_MODE=500" insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 1 ] && ok || bad "3: rc $RC with the file absent"
log_has 'decided from flags/builder-fly-p (inactive)' && ok || bad "3: no inactive fallback line: $(cat "$H/logs/jobs-client.log" 2>/dev/null)"
echo "== 3. malformed row (active \"yes\"): unreadable, the file decides, logged =="
fresh; rawrow '{"flag":{"name":"builder-fly-p","active":"yes","updated_at":"2026-09-19T01:00:00Z"}}'; touch -d "@$E1" "$FLAG"
insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 0 ] && ok || bad "3m: rc $RC — a malformed row must not read as inactive"
log_has 'decided from flags/builder-fly-p (active)' && ok || bad "3m: no fallback line"
echo "== 3b. JOBS_URL empty: the file decides, silently =="
fresh; touch -d "@$E1" "$FLAG"
JOBS_URL_V="" insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 0 ] && ok || bad "3b: rc $RC"
log_has 'decided from' && bad "3b: a DB-less box logged a fallback line" || ok
echo "== 3c. no row (404): the file decides, no line =="
fresh; touch -d "@$E1" "$FLAG"
insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 0 ] && ok || bad "3c: rc $RC — 404 is not 'off'"
log_has 'decided from' && bad "3c: a 404 logged a fallback line" || ok
fresh
insh 'flag_active builder-fly-p'; RC=$?
[ "$RC" = 1 ] && ok || bad "3c: rc $RC with no row and no file"

echo "== 4a. flag-set on: the PUT runs before the file exists =="
fresh
EXTRA_ENV="PROBE_FLAG=$FLAG" client flag-set builder-fly-p on; RC=$?
[ "$RC" = 0 ] && ok || bad "4a: rc $RC ($(cat "$T/err"))"
[ "$(puts)" = 1 ] && ok || bad "4a: $(puts) PUTs"
[ "$(cat "$T/probe")" = absent ] && ok || bad "4a: the file was '$(cat "$T/probe")' when the PUT ran — row must come first"
[ "$(mt "$FLAG")" = "$E3" ] && ok || bad "4a: file mtime '$(mt "$FLAG")', want the row's $E3"
echo "== 4b. worker down: rc 1, and the local file is STILL written (the brake) =="
fresh
EXTRA_ENV="CURL_MODE=down" client flag-set builder-fly-p on; RC=$?
[ "$RC" = 1 ] && ok || bad "4b: rc $RC"
[ -e "$FLAG" ] && ok || bad "4b: no local file after a failed PUT"
echo "== 4c. flag_set then flag_active in one shell: no GET =="
fresh
insh 'flag_set builder-fly-p on && flag_active builder-fly-p'; RC=$?
[ "$RC" = 0 ] && ok || bad "4c: rc $RC"
[ "$(gets)" = 0 ] && ok || bad "4c: $(gets) GETs after a landed PUT"

echo "== 5. the TTL cache: two reads, one GET; TTL 0 two; junk TTL means the default =="
fresh; row 1 "$T1"
insh 'flag_active builder-fly-p && flag_active builder-fly-p'; RC=$?
[ "$RC" = 0 ] && ok || bad "5: rc $RC"
[ "$(gets)" = 1 ] && ok || bad "5: $(gets) GETs inside the TTL, want 1"
: > "$SINK"
EXTRA_ENV="FLAG_ROW_TTL_S=0" insh 'flag_active builder-fly-p && flag_active builder-fly-p'
[ "$(gets)" = 2 ] && ok || bad "5: $(gets) GETs with FLAG_ROW_TTL_S=0, want 2"
: > "$SINK"
EXTRA_ENV="FLAG_ROW_TTL_S=abc" insh 'flag_active builder-fly-p && flag_active builder-fly-p'
[ "$(gets)" = 1 ] && ok || bad "5: $(gets) GETs with FLAG_ROW_TTL_S=abc, want 1"
: > "$SINK"
EXTRA_ENV="CURL_MODE=500" insh 'flag_active builder-fly-p; flag_active builder-fly-p'
[ "$(gets)" = 1 ] && ok || bad "5: an outage cost $(gets) GETs inside the TTL, want 1"

echo "== 6. CLI flag-active: row active=1, flags/ unwritable: exit 0, named from the row =="
fresh flags-as-file; row 1 "$T1"
client flag-active builder-fly-p; RC=$?
[ "$RC" = 0 ] && ok || bad "6: exit $RC"
grep -q 'source: pause_flags row (active=1' "$T/err" && ok || bad "6: source line: $(cat "$T/err")"
[ "$(gets)" = 1 ] && ok || bad "6: the CLI made $(gets) GETs, want 1 (the source line reads the cache)"

# ============================================================================
# 7. main-red publish -> pause_flags row first -> main_red_events (real worker)
# ============================================================================
if ! command -v node >/dev/null || ! command -v python3 >/dev/null; then
  echo "node/python3 missing — skipping case 7"
elif [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  echo "node < 22 has no node:sqlite — skipping case 7"
elif ! "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1; then
  # worker/jobs imports the git-ignored catalog/lanes.json statically.
  bad "7: catalog/lanes.json could not be composed from catalog/lanes.d"
else
  SLUG=example-org/demo-os; FLAGNAME=main-red-example-org-demo-os; CI=".github/workflows/harness-ci.yml"
  D="$T/d"; mkdir -p "$D/logs" "$D/flags" "$D/locks" "$D/env" "$D/state" "$T/fix"
  scratch_install_closure bin/main-red-detector.sh "$D" >/dev/null || bad "7: install main-red-detector closure"
  scratch_install_closure bin/jobs-client.sh "$D" >/dev/null || bad "7: install jobs-client closure"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\n' > "$D/env/global.env"
  printf 'demo-os %s - - 2 box-demo\n' "$SLUG" > "$D/fleet.conf"
  printf '#!/bin/bash\nexit 0\n' > "$D/bin/lane-alert.sh"; chmod +x "$D/bin/lane-alert.sh"
  printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"; chmod +x "$T/fakebin/sleep"
  export FIX="$T/fix"
  export JOBS_ANSWER='{"total_count":1,"jobs":[{"name":"decisions","conclusion":"failure","run_attempt":1,"steps":[{"name":"run suites","conclusion":"failure"}]}]}'
  cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
case "$*" in
  *"/actions/runs/"*"/jobs"*) printf '%s\n' "${JOBS_ANSWER:-}" ;;
  *"actions/runs"*)
      [ -s "$FIX/runs.json" ] || exit 1
      jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id}]' "$FIX/runs.json" ;;
  *) printf '\n' ;;
esac
exit 0
SHIM
  chmod +x "$T/fakebin/gh"
  red_on() { # red_on <sha> <t-newest> — two consecutive reds of Harness CI, newest on <sha>
    local out='{"workflow_runs":[' first=1 spec n p c t sha
    for spec in "Harness CI|$CI|failure|$2|$1" "Harness CI|$CI|failure|2026-09-18T20:10:00Z|cccc3333" \
                "Harness CI|$CI|success|2026-09-18T19:00:00Z|dddd4444"; do
      IFS='|' read -r n p c t sha <<<"$spec"
      [ "$first" = 1 ] || out+=','; first=0
      out+=$(jq -nc --arg n "$n" --arg p "$p" --arg t "$t" --arg sha "$sha" --arg c "$c" \
        --arg u "https://github.com/o/r/actions/runs/${t//[^0-9]/}" \
        '{name:$n, path:$p, status:"completed", conclusion:$c, created_at:$t, head_sha:$sha, html_url:$u,
          id:($t|gsub("[^0-9]";"")|tonumber)}')
    done
    printf '%s]}' "$out" > "$FIX/runs.json"
  }
  detect() {
    : > "$SINK"
    ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$D" REQ_SINK="$SINK" \
        bash "$D/bin/main-red-detector.sh" "$SLUG" >"$T/det.out" 2>"$T/det.err" )
  }
  mr_body() { grep '^PUT [^ ]*/api/main-red ' "$SINK" | tail -1 | sed 's/^PUT [^ ]* //'; }
  cat > "$T/replay.mjs" <<'EOF'
// replay.mjs <worker-dir> <body-file>... — PUT each body to /api/main-red on the
// REAL worker against a schema.sql database; print main_red_events as JSON.
const [dir, ...files] = process.argv.slice(2);
const { readFileSync } = await import('node:fs');
const worker = (await import(`${dir}/src/index.js`)).default;
const { openDb } = await import(`${dir}/test/lib/d1-sqlite.bh-1030.js`);
const opened = await openDb();
if (opened === null) { console.log('SKIP node:sqlite'); process.exit(0); }
const { db, DB } = opened;
for (const f of files) {
  const res = await worker.fetch(new Request('https://jobs.test/api/main-red', {
    method: 'PUT', headers: { authorization: 'Bearer s', 'content-type': 'application/json' },
    body: readFileSync(f, 'utf8') }), { DB, HARNESS_SECRET: 's' });
  if (res.status !== 200) { console.log(`HTTP ${res.status} ${await res.text()}`); process.exit(1); }
}
console.log(JSON.stringify(db.prepare('SELECT action, sha FROM main_red_events ORDER BY id').all()));
EOF

  echo "== 7a. a red tick: PUT /api/flags (active 1) BEFORE PUT /api/main-red =="
  red_on aaaa1111 2026-09-18T20:41:00Z; detect
  FL=$(grep -n '^PUT [^ ]*/api/flags {.*"active":1' "$SINK" | head -1 | cut -d: -f1)
  ML=$(grep -n '^PUT [^ ]*/api/main-red ' "$SINK" | head -1 | cut -d: -f1)
  [ -n "$FL" ] && [ -n "$ML" ] && [ "$FL" -lt "$ML" ] && ok \
    || bad "7a: flag PUT line '${FL:-none}', main-red PUT line '${ML:-none}' ($(cat "$SINK") | $(cat "$T/det.err"))"
  mr_body > "$T/mr1.json"
  echo "== 7b. that body, replayed into the real worker: one raise event on the sha =="
  OUT=$(node "$T/replay.mjs" "$DIR/worker/jobs" "$T/mr1.json" 2>"$T/node.err")
  case "$OUT" in
    "SKIP "*) echo "node:sqlite unavailable — skipping 7b/7c" ;;
    *)
      [ "$OUT" = '[{"action":"raise","sha":"aaaa1111"}]' ] && ok || bad "7b: events $OUT $(cat "$T/node.err") (body $(cat "$T/mr1.json"))"
      echo "== 7c. a second red tick on a new sha: new_sha =="
      red_on bbbb2222 2026-09-18T21:41:00Z; detect
      mr_body > "$T/mr2.json"
      OUT=$(node "$T/replay.mjs" "$DIR/worker/jobs" "$T/mr1.json" "$T/mr2.json" 2>"$T/node.err")
      [ "$OUT" = '[{"action":"raise","sha":"aaaa1111"},{"action":"new_sha","sha":"bbbb2222"}]' ] && ok \
        || bad "7c: events $OUT $(cat "$T/node.err") (body $(cat "$T/mr2.json"))" ;;
  esac
fi

echo "flags-row-authoritative: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
