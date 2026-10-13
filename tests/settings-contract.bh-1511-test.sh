#!/bin/bash
# tests/settings-contract.bh-1511-test.sh — the SETTINGS CONTRACT (BH-1511.1).
#
# WHY. Registered knobs reach a lane through bin/lib/lane-gate.sh's
# lane_env_apply, and until this slice that was fail-OPEN to the script's own
# `${VAR:-literal}`: with the worker unreachable and no row, the literal in the
# file is what ran, so the literal could never be deleted. The contract closes
# that for every knob the registry marks `required: true` (the knob whose
# literal a conversion slice has removed):
#
#   operator row (fresh)  >  operator row from the box cache (logged)
#     >  the process env (env/global.env, today's behaviour)
#     >  the registry default  >  FAIL CLOSED (exit 75, one ALERTS line a day)
#
# and it never moves a knob that is NOT required: those keep today's
# behaviour byte for byte (a row is exported, nothing else is).
#
# What is proved here:
#   1. worker up, operator row -> exported, and no cache line is written;
#   2. worker DOWN + cache present -> the cached row is served, with ONE
#      "served from the box cache" line in logs/lane-gate.log;
#   3. worker DOWN + NO cache -> a required knob gets its REGISTRY default (and
#      that is said in the log); a non-required knob stays unset (today);
#   4. the env beats the registry default, and an operator row beats the env;
#   5. a SEEDED row (actor registry-seed, written by POST
#      /api/settings/seed-registry) changes nothing: it is not exported for a
#      non-required knob, it never beats the env, and lane_knob still answers
#      the registry default for it;
#   6. a required knob with NO default and nothing answering -> the lane exits
#      75 before its body, with exactly ONE ALERTS line however many ticks;
#   7. lib_env_apply: a knob read by a shared bin/lib/*.sh is resolved from the
#      registry's `libs` scope, keyed `lib.<id>.<env lowercased>`;
#   8. an unreadable registry still runs the lane (nothing can be known about
#      which knobs exist, and 78 lanes must not stop on a render failure);
#   9. (review I1) a seeded row answers NOTHING: with the registry unreadable,
#      lane_knob returns empty exactly as before the seed existed, so the
#      caller's own literal still decides;
#  10. (review I2) the liveness post carries this box's harness commit (the
#      checkout HEAD) at most once an hour, which is what `harness-ctl
#      seed-registry` checks every box against before it seeds.
# Run from anywhere: tests/settings-contract.bh-1511-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=1758300000
mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/flags"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/"

# A fixture registry: the contract is about the RUNGS, so the knobs are ours and
# no real lane's default can drift under this suite.
cat > "$T/reg.json" <<'JSON'
{
  "version": 1,
  "note": "fixture",
  "lanes": [
    { "id": "demo", "script": "bin/demo.sh", "knobs": [
      { "env": "DEMO_REQ", "type": "int", "default": 42, "zero_means": null, "required": true },
      { "env": "DEMO_OPT", "type": "int", "default": 7,  "zero_means": null }
    ] },
    { "id": "demo-closed", "script": "bin/demo-closed.sh", "knobs": [
      { "env": "DEMO_NODEF", "type": "int", "default": null, "zero_means": null, "required": true }
    ] }
  ],
  "libs": [
    { "id": "demo-lib", "file": "bin/lib/demo-lib.sh", "knobs": [
      { "env": "DEMO_LIB_S", "type": "int", "default": 900, "zero_means": null, "required": true }
    ] }
  ]
}
JSON

# The stub worker. ROWS are operator rows, SEEDS are rows the registry seed
# wrote (actor registry-seed) — both as `key=value` words.
cat > "$T/h/bin/stub-jobs-client.sh" <<'SH'
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  local out="[]" kv
  for kv in ${ROWS:-}; do
    out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"console"}]')
  done
  for kv in ${SEEDS:-}; do
    out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"registry-seed"}]')
  done
  printf '{"settings":%s}' "$out"
}
SH

cat > "$T/h/bin/demo.sh" <<'SH'
#!/bin/bash
set -uo pipefail
. "$HARNESS/bin/stub-jobs-client.sh"
. "$HARNESS/bin/lib/lane-gate.sh"
lane_env_apply "${LANE_ID:-demo}"
echo "WORKED REQ=${DEMO_REQ-UNSET} OPT=${DEMO_OPT-UNSET}"
SH
chmod +x "$T/h/bin/demo.sh"

RC=0
tick() { # tick [lane-id] -> the lane's stdout in $out, its exit code in $RC
  env HARNESS="$T/h" LANE_REGISTRY="${REG:-$T/reg.json}" LANE_GATE_NOW="$NOW" \
      CALLS="$T/calls" ROWS="${ROWS:-}" SEEDS="${SEEDS:-}" UNREACHABLE="${UNREACHABLE:-}" \
      LANE_ID="${1:-demo}" ${KENV:-} bash "$T/h/bin/demo.sh" > "$T/out" 2>/dev/null; RC=$?
  out=$(cat "$T/out")
}
reset() {
  rm -rf "$T/h/state/lane-gate" "$T/h/flags"; mkdir -p "$T/h/flags"
  rm -f "$T/h/state/settings-cache.json" "$T/h/logs/lane-gate.log" "$T/h/logs/ALERTS.log"
  : > "$T/calls"; ROWS=""; SEEDS=""; UNREACHABLE=""; KENV=""; REG=""; NOW=1758300000
}
count() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }
cachelines() { count 'served from the box cache' "$T/h/logs/lane-gate.log"; }

# 1 — worker up, operator row.
reset; ROWS="lane.demo.demo_req=5"
tick
[ "$out" = "WORKED REQ=5 OPT=UNSET" ] && ok || bad "1 operator row: got '$out'"
[ "$(cachelines)" = 0 ] && ok || bad "1 a fresh answer must not log a cache line"

# 2 — worker DOWN, cache present: the last good answer is served, and said.
reset; ROWS="lane.demo.demo_req=5 lane.demo.demo_opt=9"; tick   # a good answer fills the cache
NOW=$(( NOW + 600 )); UNREACHABLE=1; ROWS=""
tick
[ "$out" = "WORKED REQ=5 OPT=9" ] && ok || bad "2 worker down + cache: got '$out'"
[ "$(cachelines)" = 1 ] && ok || bad "2 cache served must write ONE log line, got $(cachelines): $(cat "$T/h/logs/lane-gate.log" 2>/dev/null)"
grep -q 'demo' "$T/h/logs/lane-gate.log" 2>/dev/null && ok || bad "2 the cache line must name the lane"

# 3 — worker DOWN, NO cache: the registry default for the required knob.
reset; UNREACHABLE=1
tick
[ "$out" = "WORKED REQ=42 OPT=UNSET" ] && ok || bad "3 worker down + no cache: got '$out' (want REQ=42 from the registry, OPT untouched)"
grep -q 'registry default' "$T/h/logs/lane-gate.log" 2>/dev/null && ok \
  || bad "3 serving registry defaults with the worker down must be logged: $(cat "$T/h/logs/lane-gate.log" 2>/dev/null)"
# Worker UP and simply no row: the same default, and no outage line.
reset
tick
[ "$out" = "WORKED REQ=42 OPT=UNSET" ] && ok || bad "3b no row: got '$out'"
[ ! -s "$T/h/logs/lane-gate.log" ] && ok || bad "3b a healthy no-row tick must log nothing: $(cat "$T/h/logs/lane-gate.log")"

# 4 — env beats the registry default; an operator row beats the env.
reset; KENV="DEMO_REQ=11"
tick
[ "$out" = "WORKED REQ=11 OPT=UNSET" ] && ok || bad "4a env must beat the registry default: got '$out'"
reset; KENV="DEMO_REQ=11"; ROWS="lane.demo.demo_req=5"
tick
[ "$out" = "WORKED REQ=5 OPT=UNSET" ] && ok || bad "4b an operator row must beat the env: got '$out'"

# 5 — a SEEDED row moves nothing.
reset; SEEDS="lane.demo.demo_opt=99 lane.demo.demo_req=99"
tick
[ "$out" = "WORKED REQ=42 OPT=UNSET" ] && ok || bad "5a a seed row must not be exported nor beat the registry: got '$out'"
reset; SEEDS="lane.demo.demo_req=99"; KENV="DEMO_REQ=11"
tick
[ "$out" = "WORKED REQ=11 OPT=UNSET" ] && ok || bad "5b a seed row must never beat the env: got '$out'"
reset; SEEDS="lane.demo.demo_opt=99"
v=$(env HARNESS="$T/h" LANE_REGISTRY="$T/reg.json" LANE_GATE_NOW="$NOW" CALLS="$T/calls" SEEDS="$SEEDS" \
    bash -c '. "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; lane_knob demo DEMO_OPT' 2>/dev/null)
[ "$v" = 7 ] && ok || bad "5c lane_knob must answer the registry default over a seed row: got '$v'"

# 6 — FAIL CLOSED: a required knob with no default and nothing answering.
reset; UNREACHABLE=1
tick demo-closed
[ "$RC" = 75 ] && ok || bad "6a the lane must exit 75, got rc=$RC"
case "$out" in *WORKED*) bad "6b the lane body ran with an empty required knob: '$out'" ;; *) ok ;; esac
[ "$(count . "$T/h/logs/ALERTS.log")" = 1 ] && ok || bad "6c want ONE ALERTS line, got: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
grep -q 'DEMO_NODEF' "$T/h/logs/ALERTS.log" 2>/dev/null && ok || bad "6d the ALERTS line must name the knob"
tick demo-closed
[ "$RC" = 75 ] && ok || bad "6e the second tick must fail closed too, got rc=$RC"
[ "$(count . "$T/h/logs/ALERTS.log")" = 1 ] && ok || bad "6f the second tick must not add a second ALERTS line"
# The env still answers it — failing closed is only for NOTHING answering.
KENV="DEMO_NODEF=3"; tick demo-closed
[ "$RC" = 0 ] && ok || bad "6g an env value must satisfy a required knob, got rc=$RC"

# 7 — the lib scope.
lib() {
  env HARNESS="$T/h" LANE_REGISTRY="$T/reg.json" LANE_GATE_NOW="$NOW" CALLS="$T/calls" \
      ROWS="${ROWS:-}" UNREACHABLE="${UNREACHABLE:-}" \
      bash -c '. "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; lib_env_apply demo-lib; printf "%s" "${DEMO_LIB_S-UNSET}"' 2>/dev/null
}
reset; ROWS="lib.demo-lib.demo_lib_s=60"
[ "$(lib)" = 60 ] && ok || bad "7a a lib.<id>.<env> row must reach the lib knob: got '$(lib)'"
reset; ROWS="lane.demo-lib.demo_lib_s=60"
[ "$(lib)" = 900 ] && ok || bad "7b a lib knob is keyed lib.<id>, not lane.<id>: got '$(lib)'"
reset; UNREACHABLE=1
[ "$(lib)" = 900 ] && ok || bad "7c worker down + no cache: the lib knob's registry default, got '$(lib)'"

# 8 — an unreadable registry runs the lane exactly as today.
reset; REG="$T/nope.json"; UNREACHABLE=1
tick
[ "$RC" = 0 ] && [ "$out" = "WORKED REQ=UNSET OPT=UNSET" ] && ok || bad "8 unreadable registry must run the lane untouched: rc=$RC '$out'"

# 9 — a seeded row has no resolution role, even when the registry is gone.
reset; SEEDS="lane.review-prs.review_ci_stale_secs=600"
v=$(env HARNESS="$T/h" LANE_REGISTRY="$T/nope.json" LANE_GATE_NOW="$NOW" CALLS="$T/calls" SEEDS="$SEEDS" \
    bash -c '. "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; lane_knob review-prs REVIEW_CI_STALE_SECS' 2>/dev/null)
[ -z "$v" ] && ok || bad "9 registry unreadable + a seeded row: lane_knob must answer nothing (the caller's literal decides), got '$v'"

# 10 — the liveness post names this box's harness commit, hourly.
mkdir -p "$T/co"; ( cd "$T/co" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m c ) >/dev/null 2>&1
SHA=$(git -C "$T/co" rev-parse HEAD)
cat > "$T/h/bin/stub-post.sh" <<'SH'
_jobs_req() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$CALLS"; return 0; }
SH
live() {
  env HARNESS="$T/h" HARNESS_CHECKOUT="$T/co" LANE_REGISTRY="$T/reg.json" LANE_GATE_NOW="$NOW" CALLS="$T/calls" JOBS_BOX=box1 \
    bash -c '. "$HARNESS/bin/stub-post.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; _lg_liveness demo "" ran' >/dev/null 2>&1
}
reset; live
grep -F '/api/lanes/liveness' "$T/calls" | grep -qF "\"harness_commit\":\"$SHA\"" && ok \
  || bad "10a the liveness post must carry harness_commit=$SHA: $(cat "$T/calls")"
: > "$T/calls"; NOW=$(( NOW + 600 )); live
grep -q harness_commit <<<"$(grep -F '/api/lanes/liveness' "$T/calls")" && bad "10b harness_commit sent again inside the hour: $(cat "$T/calls")" || ok
grep -qF '/api/lanes/liveness' "$T/calls" && ok || bad "10c the tick itself must still be posted"
: > "$T/calls"; NOW=$(( NOW + 3600 )); live
grep -F '/api/lanes/liveness' "$T/calls" | grep -q harness_commit && ok || bad "10d harness_commit must be re-sent after an hour"
# 10e (review N2) — no stamp yet, or no checkout at all: the tick says NOTHING
# on stderr. The `< "$stampf"` redirect fails before a trailing 2>/dev/null
# applies, so a box with no checkout printed "No such file" on every tick. Run
# under set -u, as real lanes do: an unset local there printed "unbound variable".
rm -rf "$T/h/state/lane-gate"; : > "$T/calls"
err=$(env HARNESS="$T/h" HARNESS_CHECKOUT="$T/nonexistent" LANE_REGISTRY="$T/reg.json" LANE_GATE_NOW="$NOW" CALLS="$T/calls" JOBS_BOX=box1 \
  bash -c 'set -uo pipefail; . "$HARNESS/bin/stub-post.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; _lg_liveness demo "" ran' 2>&1 >/dev/null)
[ -z "$err" ] && ok || bad "10e the liveness tick must print nothing on stderr with no stamp/checkout: '$err'"

# 11 (BH-1632) — a pool box runs from /data/harness, a tarball with no .git. Its
# checkout carries a HARNESS_COMMIT stamp (bin/lib/harness-tarball.sh), and the
# liveness post reads that when there is no .git. A .git still wins; a stamp
# that is not a sha, or no stamp at all, sends no harness_commit key.
PSHA=0123456789abcdef0123456789abcdef01234567
livein() {
  env HARNESS="$T/h" HARNESS_CHECKOUT="$1" LANE_REGISTRY="$T/reg.json" LANE_GATE_NOW="$NOW" CALLS="$T/calls" JOBS_BOX=pool-demo-abc123 \
    bash -c '. "$HARNESS/bin/stub-post.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; _lg_liveness demo "" ran' >/dev/null 2>&1
}
mkdir -p "$T/pool"; printf '%s\n' "$PSHA" > "$T/pool/HARNESS_COMMIT"
reset; livein "$T/pool"
grep -F '/api/lanes/liveness' "$T/calls" | grep -qF "\"harness_commit\":\"$PSHA\"" && ok \
  || bad "11a no .git + a HARNESS_COMMIT stamp: the post must carry harness_commit=$PSHA: $(cat "$T/calls")"
printf '%s\n' "$PSHA" > "$T/co/HARNESS_COMMIT"
reset; livein "$T/co"
grep -F '/api/lanes/liveness' "$T/calls" | grep -qF "\"harness_commit\":\"$SHA\"" && ok \
  || bad "11b a .git and a stamp: the .git HEAD must win ($SHA): $(cat "$T/calls")"
rm -f "$T/co/HARNESS_COMMIT"
printf 'not-a-sha deadbeef\n' > "$T/pool/HARNESS_COMMIT"
reset; livein "$T/pool"
grep -qF '/api/lanes/liveness' "$T/calls" && ok || bad "11c a garbage stamp must still post the tick"
grep -q harness_commit <<<"$(grep -F '/api/lanes/liveness' "$T/calls")" && bad "11c a garbage stamp must send no harness_commit: $(cat "$T/calls")" || ok
rm -f "$T/pool/HARNESS_COMMIT"
reset
err=$(env HARNESS="$T/h" HARNESS_CHECKOUT="$T/pool" LANE_REGISTRY="$T/reg.json" LANE_GATE_NOW="$NOW" CALLS="$T/calls" JOBS_BOX=pool-demo-abc123 \
  bash -c 'set -uo pipefail; . "$HARNESS/bin/stub-post.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; _lg_liveness demo "" ran' 2>&1 >/dev/null)
grep -q harness_commit <<<"$(grep -F '/api/lanes/liveness' "$T/calls")" && bad "11d no .git and no stamp must send no harness_commit: $(cat "$T/calls")" || ok
[ -z "$err" ] && ok || bad "11d no .git and no stamp, under set -u: the tick must print nothing on stderr: '$err'"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
