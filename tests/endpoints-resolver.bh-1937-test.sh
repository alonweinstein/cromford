#!/bin/bash
# tests/endpoints-resolver.bh-1937-test.sh — bin/lib/endpoints.sh's endpoint_url
# (BH-1937), the one URL resolver every BH-1511 endpoint conversion imports.
#
# endpoint_url <service> runs lib_env_apply "endpoint-<service>" and prints
# $ENDPOINT_<SERVICE>. It fails CLOSED: nothing answering is rc 1, an empty
# stdout and one stderr line, never a literal URL.
#
# The driver is the production call shape: a script under `set -euo pipefail`
# that sources endpoints.sh and runs `url=$(endpoint_url …)`, then prints a
# sentinel, so a resolver that `exit 75`s its caller (lane-gate's fail-closed
# rung) is caught.
#   E1 an operator row wins over the env;
#   E2 worker down: the cached row is served, with ONE log line;
#   E3 no row: the env;  E4 no row, no env: the registry default;
#   E5 nothing: rc 1, empty stdout, one stderr line, and the caller survives,
#      whether it calls in $() or directly (E5b);
#   E6 no registry and no env: rc 1, empty stdout (no literal anywhere);
#   E7 service names outside [a-z0-9-] are refused;
#   E8 a `settable: false` knob (how real endpoint knobs register, BH-1165)
#      ignores a row and serves the env, then the registry default.
# Run from anywhere: tests/endpoints-resolver.bh-1937-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/flags"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/"
cp "$DIR/bin/lib/endpoints.sh" "$T/h/bin/lib/" 2>/dev/null

cat > "$T/reg.json" <<'JSON'
{
  "version": 1,
  "note": "fixture",
  "lanes": [],
  "libs": [
    { "id": "endpoint-demo-svc", "file": "bin/lib/endpoints.sh", "knobs": [
      { "env": "ENDPOINT_DEMO_SVC", "type": "string", "default": "https://default.example.test", "zero_means": null, "required": true }
    ] },
    { "id": "endpoint-nodef", "file": "bin/lib/endpoints.sh", "knobs": [
      { "env": "ENDPOINT_NODEF", "type": "string", "default": null, "zero_means": null, "required": true }
    ] },
    { "id": "endpoint-locked", "file": "bin/lib/endpoints.sh", "knobs": [
      { "env": "ENDPOINT_LOCKED", "type": "string", "default": "https://locked-default.example.test", "zero_means": null, "required": true, "settable": false }
    ] }
  ]
}
JSON

# The stub worker, as in settings-contract.bh-1511-test.sh: ROWS are operator
# rows as `key=value` words.
cat > "$T/h/bin/stub-jobs-client.sh" <<'SH'
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  local out="[]" kv
  for kv in ${ROWS:-}; do
    out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"console"}]')
  done
  printf '{"settings":%s}' "$out"
}
SH

cat > "$T/h/bin/driver.sh" <<'SH'
#!/bin/bash
set -euo pipefail
. "$HARNESS/bin/stub-jobs-client.sh"
. "$HARNESS/bin/lib/endpoints.sh"
if [ -n "${DIRECT:-}" ]; then   # called without $(), in the caller's own shell
  endpoint_url "$SVC" >/dev/null || { echo "RC1 direct"; echo SURVIVED; exit 0; }
fi
url=$(endpoint_url "$SVC") || { echo "RC1 url=[$url]"; echo SURVIVED; exit 0; }
echo "URL=[$url]"
echo SURVIVED
SH

RC=0
resolve() { # resolve <svc> -> driver stdout in $out, stderr in $err, rc in $RC
  env HARNESS="$T/h" LANE_REGISTRY="${REG:-$T/reg.json}" LANE_GATE_NOW="$NOW" \
      CALLS="$T/calls" ROWS="${ROWS:-}" UNREACHABLE="${UNREACHABLE:-}" DIRECT="${DIRECT:-}" SVC="$1" \
      ${KENV:-} bash "$T/h/bin/driver.sh" > "$T/out" 2> "$T/err"; RC=$?
  out=$(cat "$T/out"); err=$(cat "$T/err")
}
reset() {
  rm -rf "$T/h/state/lane-gate" "$T/h/flags"; mkdir -p "$T/h/flags"
  rm -f "$T/h/state/settings-cache.json" "$T/h/logs/lane-gate.log" "$T/h/logs/ALERTS.log"
  : > "$T/calls"; ROWS=""; UNREACHABLE=""; KENV=""; REG=""; DIRECT=""; NOW=1758300000
}
nlines() { [ -z "$1" ] && echo 0 || printf '%s\n' "$1" | wc -l | tr -d ' '; }

# E1 — an operator row beats the env.
reset; ROWS="lib.endpoint-demo-svc.endpoint_demo_svc=https://row.test"; KENV="ENDPOINT_DEMO_SVC=https://env.test"
resolve demo-svc
[ "$RC" = 0 ] && [ "$out" = "$(printf 'URL=[https://row.test]\nSURVIVED')" ] && ok || bad "E1 row: rc=$RC out='$out' err='$err'"

# E2 — worker down, past the settings cache TTL: the cached row, said once.
NOW=$(( NOW + 600 )); UNREACHABLE=1; ROWS=""; KENV=""
resolve demo-svc
[ "$out" = "$(printf 'URL=[https://row.test]\nSURVIVED')" ] && ok || bad "E2 cached row: out='$out' err='$err'"
n=$(grep -c 'worker unreachable.*box cache' "$T/h/logs/lane-gate.log" 2>/dev/null); n=${n:-0}
[ "$n" = 1 ] && grep -q 'endpoint-demo-svc' "$T/h/logs/lane-gate.log" && ok \
  || bad "E2 want ONE cache line naming endpoint-demo-svc, got $n: $(cat "$T/h/logs/lane-gate.log" 2>/dev/null)"

# E3 — no row: the env.
reset; KENV="ENDPOINT_DEMO_SVC=https://env.test"
resolve demo-svc
[ "$out" = "$(printf 'URL=[https://env.test]\nSURVIVED')" ] && ok || bad "E3 env: out='$out' err='$err'"

# E4 — no row, no env: the registry default.
reset
resolve demo-svc
[ "$out" = "$(printf 'URL=[https://default.example.test]\nSURVIVED')" ] && ok || bad "E4 default: out='$out' err='$err'"

# E5 — nothing answers: rc 1, empty, one line, and the caller is not killed.
reset
resolve nodef
[ "$RC" = 0 ] && [ "$out" = "$(printf 'RC1 url=[]\nSURVIVED')" ] && ok \
  || bad "E5 want rc 1 + empty url + a surviving caller: rc=$RC out='$out' err='$err'"
[ "$(nlines "$err")" = 1 ] && grep -q "^endpoint_url: .*'nodef'" "$T/err" && ok \
  || bad "E5 want exactly one endpoint_url stderr line, got: '$err'"
grep -q 'ENDPOINT_NODEF' "$T/h/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "E5 the fail-closed ALERTS line must still be written: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"

# E5b — called directly, not in $(): lib_env_apply's exit 75 must not reach
# the caller's shell.
reset; DIRECT=1
resolve nodef
[ "$RC" = 0 ] && [ "$out" = "$(printf 'RC1 direct\nSURVIVED')" ] && ok \
  || bad "E5b a direct call must return rc 1 to a live caller: rc=$RC out='$out' err='$err'"

# E6 — no registry, no env: no literal answers.
reset; REG="$T/nope.json"
resolve demo-svc
[ "$out" = "$(printf 'RC1 url=[]\nSURVIVED')" ] && ok || bad "E6 no registry: out='$out' err='$err'"
[ "$(nlines "$err")" = 1 ] && ok || bad "E6 want one stderr line: '$err'"

# E7 — service names that are not [a-z0-9-] (nor start with -) are refused.
for s in "" Demo a_b -x 'a;b' 'demo svc'; do
  reset; KENV="ENDPOINT_DEMO_SVC=https://env.test ENDPOINT_A_B=https://env.test"
  resolve "$s"
  [ "$out" = "$(printf 'RC1 url=[]\nSURVIVED')" ] && [ "$(nlines "$err")" = 1 ] && ok \
    || bad "E7 service '$s' must be refused: out='$out' err='$err'"
done

# E8 — settable:false: a row is ignored; env, then the registry default.
reset; ROWS="lib.endpoint-locked.endpoint_locked=https://row.test"; KENV="ENDPOINT_LOCKED=https://env.test"
resolve locked
[ "$out" = "$(printf 'URL=[https://env.test]\nSURVIVED')" ] && ok || bad "E8a settable:false + row + env: out='$out' err='$err'"
reset; ROWS="lib.endpoint-locked.endpoint_locked=https://row.test"
resolve locked
[ "$out" = "$(printf 'URL=[https://locked-default.example.test]\nSURVIVED')" ] && ok || bad "E8b settable:false + row: out='$out' err='$err'"

# The resolver may be sourced twice, and sourcing it runs nothing.
v=$(env HARNESS="$T/h" LANE_REGISTRY="$T/reg.json" bash -c '. "$HARNESS/bin/lib/endpoints.sh"; . "$HARNESS/bin/lib/endpoints.sh"; echo sourced' 2>&1)
[ "$v" = sourced ] && ok || bad "double source: '$v'"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
