#!/bin/bash
# tests/utilization-verdict.bh-3988-test.sh — BH-4009 (BH-3988.1): the full
# util_verdict precedence in bin/lib/utilization.sh, first match wins:
#   1 unknown (an input unmeasured)  2 paused (a stops_builds pause, or cap 0)
#   3 saturated  4 busy  5 blocked  6 starved  7 unknown (no rule matched)
#
# The verdicts are read off the PUT body of the REAL bin/utilization-push.sh,
# run from a scratch $HARNESS (a symlink copy of bin/ and catalog/) with the
# real section-builds.sh driven by FAKE_CAP / FAKE_RUNNING (D4: the builds
# numbers come out of the real collector). The tickets section is replaced by
# a stub printing $FAKE_TICKETS, and a stub pauses section prints $FAKE_PAUSES.
#
#   D   util_verdict called directly: the why string per rule, rc 0
#   C1  starved: cap 4, running 0, all 0; and cap unlimited
#   C2  paused: cap 0 with ready 3 (paused beats saturated); a stops_builds
#       pause; a stops_builds:false pause is busy, never paused
#   C3  blocked: blocked 2; held/parked null name themselves as unmeasured
#   C4  saturated: cap 2, running 2, ready 3 (saturated beats busy)
#   C5  busy: running 1 ready 0; running 0 ready 2 with free slots
#   C6  unknown: ready null with everything else 0; concurrency-plan rc 1
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/utilization-verdict.bh-3988-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', wanted '$3'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
TAB=$'\t'

VERDICT_SRC="$DIR/bin/lib/utilization.sh"
[ -f "$VERDICT_SRC" ] || { echo "FAIL: $VERDICT_SRC is missing"; exit 1; }

# ── D: the why strings, sourced alone ───────────────────────────────────────
# shellcheck disable=SC1090
. "$VERDICT_SRC" || { echo "FAIL: cannot source $VERDICT_SRC"; exit 1; }
v() { util_verdict "$1"; }
eq "D rule 1 unchanged" "$(v '{"builds":{"free_slots":2}}')" "unknown${TAB}inputs unmeasured: tickets.ready"
eq "D rule 1 unparseable unchanged" "$(v '[]')" "unknown${TAB}snapshot unparseable"
eq "D paused by pause" \
  "$(v '{"tickets":{"ready":2},"builds":{"running":0,"pool_cap":4,"free_slots":4},"pauses":[{"kind":"flag","name":"x","stops_builds":false},{"kind":"flag","name":"paused-acme","stops_builds":true}]}')" \
  "paused${TAB}pause flag:paused-acme stops builds"
eq "D paused by cap 0" "$(v '{"tickets":{"ready":3},"builds":{"running":0,"pool_cap":0,"free_slots":0}}')" "paused${TAB}pool cap 0"
eq "D saturated" "$(v '{"tickets":{"ready":3},"builds":{"running":2,"pool_cap":2,"free_slots":0}}')" \
  "saturated${TAB}ready 3, 0 free slots, running 2"
eq "D busy" "$(v '{"tickets":{"ready":0},"builds":{"running":1,"pool_cap":4,"free_slots":3}}')" "busy${TAB}running 1, ready 0"
eq "D blocked" "$(v '{"tickets":{"ready":0,"blocked":2,"held":0,"parked":1},"builds":{"running":0,"pool_cap":4,"free_slots":4}}')" \
  "blocked${TAB}blocked 2 held 0 parked 1"
eq "D blocked with unmeasured" "$(v '{"tickets":{"ready":0,"blocked":1,"held":null,"parked":null},"builds":{"running":0,"pool_cap":4,"free_slots":4}}')" \
  "blocked${TAB}blocked 1 held ? parked ?; unmeasured: held parked"
eq "D starved" "$(v '{"tickets":{"ready":0,"blocked":0,"held":0,"parked":0},"builds":{"running":0,"pool_cap":4,"free_slots":4}}')" \
  "starved${TAB}nothing ready, blocked, held or parked; free slots 4"
eq "D starved unmeasured tail" "$(v '{"tickets":{"ready":0,"blocked":0,"held":0,"parked":null},"builds":{"running":0,"pool_cap":"unlimited","free_slots":"unlimited"}}')" \
  "starved${TAB}nothing ready, blocked, held or parked; free slots unlimited; unmeasured: parked"
eq "D pauses not an array is []" "$(v '{"tickets":{"ready":0,"blocked":0,"held":0,"parked":0},"pauses":"x","builds":{"running":0,"pool_cap":4,"free_slots":4}}')" \
  "starved${TAB}nothing ready, blocked, held or parked; free slots 4"
eq "D no rule matched" "$(v '{"tickets":{"ready":"many"},"builds":{"running":0,"pool_cap":4,"free_slots":4}}')" \
  "unknown${TAB}no verdict rule matched"
v '{"tickets":{"ready":0},"builds":{"running":0,"pool_cap":4,"free_slots":4}}' >/dev/null; eq "D rc" "$?" 0

# ── the scratch harness ─────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/flags" "$H/logs" "$T/stub" "$T/env"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
rm -f "$H/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" > "$H/catalog/lanes.json" 2> "$T/build.err" \
  || bad "setup: bin/lanes-build.sh failed: $(cat "$T/build.err")"
rm -f "$H/bin/fleet-conf.sh" "$H/bin/concurrency-plan.sh" "$H/bin/lib/utilization/section-tickets.sh"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${1:-}" in --projects) printf 'acme\n' ;; *) exit 1 ;; esac
SH
cat > "$H/bin/concurrency-plan.sh" <<'SH'
#!/bin/bash
[ "${FAKE_CAP_RC:-0}" = 0 ] || exit "$FAKE_CAP_RC"
printf '[{"project":"%s","effective":"%s","bound_by":"fixture"}]\n' "$1" "${FAKE_CAP:-5}"
SH
cat > "$H/bin/lib/utilization/section-tickets.sh" <<'SH'
util_section_tickets() { printf '%s\n' "$FAKE_TICKETS"; }
SH
cat > "$H/bin/lib/utilization/section-zpauses.sh" <<'SH'
util_section_zpauses() { [ -n "${FAKE_PAUSES:-}" ] || { echo '{}'; return 0; }; printf '{"pauses":%s}\n' "$FAKE_PAUSES"; }
SH
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
M=GET; D=""; U=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M="$2"; shift 2 ;;
    --data-binary) D="$2"; shift 2 ;;
    -m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) U="$1"; shift ;;
  esac
done
P="${U#http://jobs.test}"
case "$M $P" in
  "GET /api/jobs?"*)
    jq -nc --argjson n "${FAKE_RUNNING:-0}" '{jobs:[range(0;$n)|{id:("j"+(.|tostring)),status:"running",kind:"build",ticket_id:("ZZ-"+(.|tostring))}]}'
    printf '\n200' ;;
  "PUT /api/utilization")
    case "$D" in @*) D=$(cat "${D#@}") ;; esac
    printf '%s\n' "$D" >> "$HARNESS/puts.jsonl"
    printf '{"ok":true}\n200' ;;
  *) printf '{"error":"unknown endpoint"}\n404' ;;
esac
SH
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/concurrency-plan.sh" "$T/stub/curl"

ALL0='{"tickets":{"ready":0,"blocked":0,"held":0,"parked":0,"held_complete":true}}'
tk() { # tk <ready> [blocked] [held] [parked]
  jq -nc --argjson r "$1" --argjson b "${2:-0}" --argjson h "${3:-0}" --argjson p "${4:-0}" \
    '{tickets:{ready:$r,blocked:$b,held:$h,parked:$p,held_complete:true}}'
}
# verdict_of VAR=val... — run the shipped lane, print acme's PUT verdict.
verdict_of() {
  rm -f "$H/puts.jsonl"
  env -i PATH="$T/stub:$PATH" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$T/env" HARNESS_TEST_SANDBOX=1 \
    JOBS_URL=http://jobs.test HARNESS_SECRET=s3cret JOBS_BOX=hub-fixture JOBS_RETRY_SLEEP=0 "$@" \
    bash "$H/bin/utilization-push.sh" > "$T/lane.out" 2> "$T/lane.err"
  jq -r 'select(.project=="acme")|.verdict' "$H/puts.jsonl" 2>/dev/null
}

# ── C1 starved ──────────────────────────────────────────────────────────────
eq "C1 starved" "$(verdict_of FAKE_CAP=4 FAKE_RUNNING=0 FAKE_TICKETS="$ALL0")" starved
eq "C1 starved, cap unlimited" "$(verdict_of FAKE_CAP=unlimited FAKE_RUNNING=0 FAKE_TICKETS="$ALL0")" starved
# ── C2 paused ───────────────────────────────────────────────────────────────
eq "C2 cap 0 with ready 3 is paused, not saturated" "$(verdict_of FAKE_CAP=0 FAKE_RUNNING=0 FAKE_TICKETS="$(tk 3)")" paused
eq "C2 a stops_builds pause" "$(verdict_of FAKE_CAP=4 FAKE_RUNNING=0 FAKE_TICKETS="$(tk 2)" \
  FAKE_PAUSES='[{"kind":"flag","name":"paused-acme","since":"2026-10-03T00:00:00Z","stops_builds":true}]')" paused
eq "C2 a stops_builds:false pause is busy" "$(verdict_of FAKE_CAP=4 FAKE_RUNNING=0 FAKE_TICKETS="$(tk 2)" \
  FAKE_PAUSES='[{"kind":"flag","name":"automerge-disabled","since":"2026-10-03T00:00:00Z","stops_builds":false}]')" busy
# ── C3 blocked ──────────────────────────────────────────────────────────────
eq "C3 blocked 2" "$(verdict_of FAKE_CAP=4 FAKE_RUNNING=0 FAKE_TICKETS="$(tk 0 2)")" blocked
eq "C3 blocked, unmeasured held/parked" "$(verdict_of FAKE_CAP=4 FAKE_RUNNING=0 FAKE_TICKETS="$(tk 0 1 null null)")" blocked
eq "C3 why" "$(v "$(jq -c '.payload' "$H/puts.jsonl")" | cut -f2)" "blocked 1 held ? parked ?; unmeasured: held parked"
# ── C4 saturated (the mutation pin: rule 4 would also match) ────────────────
eq "C4 saturated" "$(verdict_of FAKE_CAP=2 FAKE_RUNNING=2 FAKE_TICKETS="$(tk 3)")" saturated
# ── C5 busy ─────────────────────────────────────────────────────────────────
eq "C5 busy running 1 ready 0" "$(verdict_of FAKE_CAP=4 FAKE_RUNNING=1 FAKE_TICKETS="$(tk 0)")" busy
eq "C5 busy running 0 ready 2" "$(verdict_of FAKE_CAP=4 FAKE_RUNNING=0 FAKE_TICKETS="$(tk 2)")" busy
# ── C6 unknown ──────────────────────────────────────────────────────────────
eq "C6 ready null is unknown, never starved" "$(verdict_of FAKE_CAP=4 FAKE_RUNNING=0 FAKE_TICKETS="$(tk null)")" unknown
eq "C6 concurrency-plan rc 1" "$(verdict_of FAKE_CAP_RC=1 FAKE_RUNNING=0 FAKE_TICKETS="$ALL0")" unknown

echo "utilization-verdict: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
