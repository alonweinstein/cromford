#!/bin/bash
# tests/lane-knob-test.sh — bin/lib/lane-gate.sh's KNOB resolver (BH-1132).
#
# WHY. Every number that shapes fleet spend — how many families alert-triage
# hands a model, how many merges the conductor lands, how many rungs the
# resolver buys — lives in env/global.env behind `chattr +i` on each box, so
# changing one is an ssh and a deploy. lane_knob makes it a settings row, with
# the env kept as the fallback so a box with no rows behaves byte-for-byte as it
# does today.
#
# What is proved here:
#   1. nothing set anywhere -> the REGISTRY default;
#   2. the process env beats the registry default (today's behaviour survives);
#   3. a global settings row beats the env;
#   4. a project row beats the global row, and does not leak to a sibling;
#   5. clamping: below min comes back as min, above max as max, in range as-is;
#   6. a STRING knob (a model slug) passes through byte-for-byte, unclamped —
#      a clamp that touched it would hand a lane a number as a model name;
#   7. zero_means is read from the registry, and it is NOT the same word for
#      every lane (off for TRIAGE_MAX_FAMILIES, unlimited for the autopilot
#      daily cap) — the whole reason the field exists;
#   8. the cache: many knobs in one tick cost ONE GET /api/settings;
#   9. the clamp is never SILENT: a settings row outside the bounds is trimmed
#      AND logged, and a value that came from env/global.env is used AS IT
#      STANDS — trimming what the env already says would change fleet behaviour
#      the first time a lane adopted lane_knob, with nobody deciding;
#  10. FAIL OPEN: an unreachable worker resolves to env-then-default and never
#      to empty — a lane that runs with an empty number is worse than a lane
#      that runs with the number it had yesterday.
#  11. lane_env_apply (BH-1165): the settings row reaches a lane that was never
#      rewritten to call lane_knob. Every registered knob with a row is EXPORTED
#      into the lane's environment right after the gate, so the script's own
#      `${KNOB:-default}` read picks it up; a knob with no row is not exported
#      at all (the env, then the script's own default, still decide); and the
#      registry — never the settings table — decides which names exist, so a row
#      can never inject a variable the lane did not declare.
#  12. `unlimited` is a row, not a magic zero (BH-1165). `lane.<id>[.<proj>].<env
#      lowercased>.unlimited` says it in words; it is honoured ONLY for a knob
#      the registry marks zero_means=unlimited, and REFUSED with a line for a
#      knob whose 0 means off — where "unlimited" would be the exact opposite of
#      what the operator asked for.
#  13. THE ORDERING, on the shipped script (BH-1165 review): bin/clock-sync.sh's
#      own preamble is executed with an env/global.env and a settings row that
#      disagree, and the ROW has to win. lane_env_apply above `set -a; . global.env`
#      is overwritten by it, which is the bug this ticket exists to close.
#  14. `settable: false` (BH-1165 review): a registered name that is a command,
#      a host, a path, an identity or a test seam is never driven by a settings
#      row — not exported, not resolved — and the refusal is logged.
# Run from anywhere: tests/lane-knob-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=1758300000
mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/catalog" "$T/h/flags"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/"
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"

# The stub worker. ROWS is the settings table as `key=value` words; every
# request is counted, so "one fetch per tick" is a countable fact.
cat > "$T/h/bin/stub-jobs-client.sh" <<'SH'
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  local out="[]" k v
  for kv in ${ROWS:-}; do
    k="${kv%%=*}"; v="${kv#*=}"
    out=$(printf '%s' "$out" | jq -c --arg k "$k" --arg v "$v" '. + [{key:$k,value:$v}]')
  done
  printf '{"settings":%s}' "$out"
}
SH

# One knob read, in a child shell, so each case starts from a cold in-process
# state and only the on-disk cache carries over.
ask() { # ask <id> <ENV> [project]
  env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS="${ROWS:-}" \
      UNREACHABLE="${UNREACHABLE:-}" KENV="${KENV:-}" \
      bash -c '
        set -uo pipefail
        . "$HARNESS/bin/stub-jobs-client.sh"
        . "$HARNESS/bin/lib/lane-gate.sh"
        [ -n "$KENV" ] && export ${KENV}
        lane_knob "$1" "$2" "${3:-}"' _ "$1" "$2" "${3:-}" 2>/dev/null
}
# state/lane-gate holds the once-an-hour throttle stamps as well as the flag
# cache. A case that does not clear them inherits the previous case's silence,
# which is how "the clamp logged nothing" and "the clamp logged an hour ago"
# become the same result.
reset() { rm -rf "$T/h/state/lane-gate"; rm -f "$T/h/state/settings-cache.json" "$T/calls" "$T/h/logs/lane-gate.log"; : > "$T/calls"; ROWS=""; UNREACHABLE=""; KENV=""; }

# `lane.<id>[.<project>].<env lowercased>` — the form the published contract
# names and the Mission Control console writes. Spelled out here rather than
# read from the registry so this suite fails if the reader ever drifts to some
# other spelling: a knob set on the page that lands on a row the lane never
# reads errors nowhere and is invisible.
key() { # key <lane> <ENV> [project]
  local low; low=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  if [ -n "${3:-}" ]; then printf 'lane.%s.%s.%s' "$1" "$3" "$low"; else printf 'lane.%s.%s' "$1" "$low"; fi
}

# 1 — the registry default. alert-triage's TRIAGE_MAX_FAMILIES is 4.
reset
[ "$(ask alert-triage TRIAGE_MAX_FAMILIES)" = 4 ] && ok || bad "1 default: got '$(ask alert-triage TRIAGE_MAX_FAMILIES)'"

# 2 — the process env wins over the default.
reset; KENV="TRIAGE_MAX_FAMILIES=7"
[ "$(ask alert-triage TRIAGE_MAX_FAMILIES)" = 7 ] && ok || bad "2 env did not beat the default"

# 3 — a global settings row beats the env.
reset; KENV="TRIAGE_MAX_FAMILIES=7"; ROWS="$(key alert-triage TRIAGE_MAX_FAMILIES)=2"
[ "$(ask alert-triage TRIAGE_MAX_FAMILIES)" = 2 ] && ok || bad "3 settings row did not beat the env"

# 4 — a project row beats the global row, and its sibling is untouched.
reset
ROWS="$(key review-prs REVIEW_CI_STALE_SECS)=600 $(key review-prs REVIEW_CI_STALE_SECS project-2)=900"
[ "$(ask review-prs REVIEW_CI_STALE_SECS project-2)" = 900 ] || bad "4a project row lost to the global row"
[ "$(ask review-prs REVIEW_CI_STALE_SECS project-2)" = 900 ] && ok
[ "$(ask review-prs REVIEW_CI_STALE_SECS project-3)" = 600 ] && ok || bad "4b a project row leaked to a sibling"

# 5 — clamping, against the registry's own [min,max] for this knob (0..50).
reset; ROWS="$(key alert-triage TRIAGE_MAX_FAMILIES)=999"
[ "$(ask alert-triage TRIAGE_MAX_FAMILIES)" = 50 ] && ok || bad "5a above max was not clamped"
reset; ROWS="$(key alert-triage TRIAGE_MAX_FAMILIES)=-5"
[ "$(ask alert-triage TRIAGE_MAX_FAMILIES)" = 0 ] && ok || bad "5b below min was not clamped"
reset; ROWS="$(key alert-triage TRIAGE_MAX_FAMILIES)=11"
[ "$(ask alert-triage TRIAGE_MAX_FAMILIES)" = 11 ] && ok || bad "5c an in-range value was changed"

# 6 — a string knob is not a number and must not be clamped or blanked.
reset; ROWS="$(key blocked-resolver EXECUTE_MODEL)=claude-opus-5"
[ "$(ask blocked-resolver EXECUTE_MODEL)" = "claude-opus-5" ] && ok || bad "6 string knob mangled: '$(ask blocked-resolver EXECUTE_MODEL)'"

# 7 — zero_means, and that it differs by lane.
reset
Z1=$(env HARNESS="$T/h" bash -c '. "$HARNESS/bin/lib/lane-gate.sh"; lane_knob_zero_means alert-triage TRIAGE_MAX_FAMILIES' 2>/dev/null)
Z2=$(env HARNESS="$T/h" bash -c '. "$HARNESS/bin/lib/lane-gate.sh"; lane_knob_zero_means review-autopilot REVIEW_AUTOPILOT_DAILY_CAP' 2>/dev/null)
[ "$Z1" = off ] && [ "$Z2" = unlimited ] && ok || bad "7 zero_means: got '$Z1' and '$Z2' (want off, unlimited)"

# 8 — one settings fetch per tick, however many knobs are read.
reset; ROWS="$(key merge-conductor MC_MERGE_BUDGET)=3"
env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS="$ROWS" bash -c '
  set -uo pipefail
  . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
  for k in MC_MERGE_BUDGET MC_REBASE_BUDGET MC_REREVIEW_BUDGET MC_RETRY_MAX MC_REQUEUE_CAP; do
    lane_knob merge-conductor "$k" >/dev/null
  done' 2>/dev/null
N=$(wc -l < "$T/calls" | tr -d ' ')
[ "$N" = 1 ] && ok || bad "8 five knobs cost $N settings requests (want 1)"

# 9 — the clamp says so, and the env is not clamped.
reset; ROWS="$(key alert-triage TRIAGE_MAX_FAMILIES)=999"
V=$(ask alert-triage TRIAGE_MAX_FAMILIES)
[ "$V" = 50 ] || bad "9a a settings row over max was not clamped"
[ "$V" = 50 ] && ok
grep -q 'TRIAGE_MAX_FAMILIES CLAMPED 999 -> 50' "$T/h/logs/lane-gate.log" 2>/dev/null && ok \
  || bad "9b the clamp was silent: $(cat "$T/h/logs/lane-gate.log" 2>/dev/null)"
# A different lane and knob, so this is not the previous case's throttle window.
reset; KENV="BR_PER_TICK=999"
V=$(ask blocked-resolver BR_PER_TICK)
[ "$V" = 999 ] && ok || bad "9c an env value was clamped to $V — that changes fleet behaviour nobody chose"
grep -q 'USED AS IS, not clamped' "$T/h/logs/lane-gate.log" 2>/dev/null && ok \
  || bad "9d an out-of-bounds env value passed through with no line at all"

# 10 — fail open: env first, then the registry default, never empty.
reset; UNREACHABLE=1; KENV="TRIAGE_MAX_FAMILIES=6"
[ "$(ask alert-triage TRIAGE_MAX_FAMILIES)" = 6 ] && ok || bad "10a outage did not fall back to the env"
reset; UNREACHABLE=1
[ "$(ask alert-triage TRIAGE_MAX_FAMILIES)" = 4 ] && ok || bad "10b outage did not fall back to the registry default"

# 11 — lane_env_apply: the row reaches a lane nobody rewrote.
#
# WHY THIS AND NOT A PER-KNOB REWRITE. 78 lanes read ~320 `${KNOB:-default}`
# variables between them. Rewriting every read into `lane_knob` is 320 chances
# to change a default by hand; exporting the knobs the registry already declares
# is one mechanism, and a lane with no settings rows keeps byte-for-byte the
# behaviour it has today because nothing is exported.
reset; ROWS="$(key alert-triage TRIAGE_MAX_FAMILIES)=9"
V=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS="$ROWS" bash -c '
  set -uo pipefail
  . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
  lane_env_apply alert-triage
  printf "%s" "${TRIAGE_MAX_FAMILIES:-UNSET}"' 2>/dev/null)
[ "$V" = 9 ] && ok || bad "11a a settings row did not reach an unmodified \${TRIAGE_MAX_FAMILIES:-} reader (got '$V')"

# no row: the variable is left exactly as it was — UNSET, so the script's own
# default still decides. Exporting the registry default here would quietly
# become the fleet's default the first time a lane adopted this.
reset
V=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" bash -c '
  set -uo pipefail
  . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
  lane_env_apply alert-triage
  printf "%s" "${TRIAGE_MAX_FAMILIES:-UNSET}"' 2>/dev/null)
[ "$V" = UNSET ] && ok || bad "11b with no row the lane's own default was overwritten with '$V'"

# an env value with no row survives untouched (today's behaviour, exactly).
reset
V=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" TRIAGE_MAX_FAMILIES=3 bash -c '
  set -uo pipefail
  . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
  lane_env_apply alert-triage
  printf "%s" "${TRIAGE_MAX_FAMILIES:-UNSET}"' 2>/dev/null)
[ "$V" = 3 ] && ok || bad "11c env/global.env's value was replaced by something else ('$V') with no row set"

# the exported value is CLAMPED, the same as lane_knob's: one reader may not see
# a number the other would have refused.
reset; ROWS="$(key alert-triage TRIAGE_MAX_FAMILIES)=999"
V=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS="$ROWS" bash -c '
  set -uo pipefail
  . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
  lane_env_apply alert-triage
  printf "%s" "${TRIAGE_MAX_FAMILIES:-UNSET}"' 2>/dev/null)
[ "$V" = 50 ] && ok || bad "11d the exported value was not clamped to the registry max (got '$V')"

# THE REGISTRY DECIDES WHICH NAMES EXIST. A settings row is operator input that
# arrives over HTTP; if the exporter walked the settings table instead of the
# lane's declared knobs, `lane.alert-triage.path` would export PATH into a lane
# that runs models with a token in its environment.
reset; ROWS="lane.alert-triage.path=/tmp/evil lane.alert-triage.gh_token=leak"
V=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS="$ROWS" bash -c '
  set -uo pipefail
  . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
  lane_env_apply alert-triage
  printf "%s|%s" "$PATH" "${GH_TOKEN:-UNSET}"' 2>/dev/null)
case "$V" in */tmp/evil*|*leak*) bad "11e a settings row exported a variable the registry never declared: $V" ;;
  *) ok ;; esac

# a project row applies to that project's run and not to its sibling's.
reset; ROWS="$(key review-prs REVIEW_CI_STALE_SECS project-2)=900"
V=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS="$ROWS" bash -c '
  set -uo pipefail
  . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
  lane_env_apply review-prs project-2; printf "%s," "${REVIEW_CI_STALE_SECS:-UNSET}"
  ' 2>/dev/null)
V2=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS="$ROWS" bash -c '
  set -uo pipefail
  . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
  lane_env_apply review-prs project-3; printf "%s" "${REVIEW_CI_STALE_SECS:-UNSET}"' 2>/dev/null)
[ "$V" = "900," ] && [ "$V2" = UNSET ] && ok || bad "11f project scoping in lane_env_apply: got '$V' and '$V2'"

# 12 — `unlimited` is a row, not a magic zero.
# The value row is deliberately NON-zero: this lane's registry default is
# already 0, so an assertion made against an empty table would pass on a reader
# that never learned the word. 42 and an unlimited row must resolve to 0.
reset; ROWS="$(key review-autopilot REVIEW_AUTOPILOT_DAILY_CAP)=42 $(key review-autopilot REVIEW_AUTOPILOT_DAILY_CAP).unlimited=1"
env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS="$ROWS" bash -c '
  set -uo pipefail
  . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
  lane_knob_unlimited review-autopilot REVIEW_AUTOPILOT_DAILY_CAP' 2>/dev/null \
  && ok || bad "12a an explicit unlimited row was not read as unlimited"
V=$(ask review-autopilot REVIEW_AUTOPILOT_DAILY_CAP)
[ "$V" = 0 ] && ok || bad "12b the unlimited row did not beat the 42 the value row carries (got '$V')"

# the legacy spelling keeps working: a 0 on a zero_means=unlimited knob is still
# unlimited, because that is what every row written before this says.
reset; ROWS="$(key review-autopilot REVIEW_AUTOPILOT_DAILY_CAP)=0"
env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS="$ROWS" bash -c '
  set -uo pipefail
  . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
  lane_knob_unlimited review-autopilot REVIEW_AUTOPILOT_DAILY_CAP' 2>/dev/null \
  && ok || bad "12c a 0 on a zero_means=unlimited knob stopped reading as unlimited"

# AND IT IS REFUSED WHERE 0 MEANS OFF. TRIAGE_MAX_FAMILIES=0 stops the lane;
# reading an `unlimited` row there as "0" would turn "spend without limit" into
# "do not run", which is the one mistranslation this field exists to prevent.
reset; ROWS="$(key alert-triage TRIAGE_MAX_FAMILIES)=2 $(key alert-triage TRIAGE_MAX_FAMILIES).unlimited=1"
env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS="$ROWS" bash -c '
  set -uo pipefail
  . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
  lane_knob_unlimited alert-triage TRIAGE_MAX_FAMILIES' 2>/dev/null \
  && bad "12d an unlimited row was honoured on a knob whose 0 means OFF" || ok
V=$(ask alert-triage TRIAGE_MAX_FAMILIES)
[ "$V" = 2 ] && ok || bad "12e the refused unlimited row changed the value the operator set to '$V'"
grep -q 'unlimited' "$T/h/logs/lane-gate.log" 2>/dev/null && ok \
  || bad "12f the refusal was silent — nothing in logs/lane-gate.log says the row was ignored"


# 13 — THE SHIPPED PREAMBLE, not a fixture (BH-1165 review).
#
# Section 11 proves lane_env_apply exports a row. It cannot see WHERE the call
# sits in the script that calls it, and in 24 of the wired lanes it sat ABOVE
# `set -a; . env/global.env` — so the env file re-assigned every knob the row
# had just exported, the lane ran on env/global.env, the page went on reporting
# `source: settings`, and nothing errored anywhere: the exact bug this ticket
# exists to close, shipped inside the fix for it.
#
# So: run bin/clock-sync.sh's OWN first lines, verbatim, with an env file that
# says 30 and a settings row that says 777.
# THE CUT IS THE LATER OF THE TWO LINES, and that matters: cutting at
# lane_env_apply alone would leave the env load out of the probe whenever the
# apply is above it — which is precisely the broken arrangement, so the probe
# would pass on the bug it exists to catch.
CS_A=$(grep -nE '^[^#]*lane_env_apply' "$DIR/bin/clock-sync.sh" | tail -1 | cut -d: -f1)
CS_E=$(grep -nE '^[^#]*\.[[:space:]]+"[^"]*global\.env"' "$DIR/bin/clock-sync.sh" | tail -1 | cut -d: -f1)
CS_END=${CS_A:-0}; [ "${CS_E:-0}" -gt "$CS_END" ] && CS_END=$CS_E
mkdir -p "$T/p/bin/lib" "$T/p/env" "$T/p/catalog" "$T/p/state" "$T/p/logs" "$T/p/flags"
cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/env-path.sh" "$T/p/bin/lib/" 2>/dev/null
cp "$(rendered_registry)" "$T/p/catalog/lanes.json"
head -n "$CS_END" "$DIR/bin/clock-sync.sh" > "$T/p/bin/clock-sync-preamble.sh"
echo 'printf "CLOCK_SYNC_TOLERANCE=%s\n" "${CLOCK_SYNC_TOLERANCE:-UNSET}"' >> "$T/p/bin/clock-sync-preamble.sh"
printf 'CLOCK_SYNC_TOLERANCE=30\n' > "$T/p/env/global.env"
# A WARM settings cache, so the probe needs no worker at all: this is about
# ordering, not about reaching the control plane.
jq -nc --argjson fa "$NOW" '{fetched_at:$fa,values:{"lane.clock-sync.clock_sync_tolerance":"777"}}' \
  > "$T/p/state/settings-cache.json"
V=$(env -i PATH="$PATH" HOME="$T" HARNESS="$T/p" LANE_GATE_NOW="$NOW" \
      bash "$T/p/bin/clock-sync-preamble.sh" 2>/dev/null | sed -n 's/^CLOCK_SYNC_TOLERANCE=//p' | tail -1)
[ "$V" = 777 ] && ok || bad "13a bin/clock-sync.sh's own preamble ran on env/global.env, not the settings row (CLOCK_SYNC_TOLERANCE=$V) — lane_env_apply is above the env load"

# and with no row the env file still decides, byte for byte as today
jq -nc --argjson fa "$NOW" '{fetched_at:$fa,values:{}}' > "$T/p/state/settings-cache.json"
rm -rf "$T/p/state/lane-gate"
V=$(env -i PATH="$PATH" HOME="$T" HARNESS="$T/p" LANE_GATE_NOW="$NOW" \
      bash "$T/p/bin/clock-sync-preamble.sh" 2>/dev/null | sed -n 's/^CLOCK_SYNC_TOLERANCE=//p' | tail -1)
[ "$V" = 30 ] && ok || bad "13b with no settings row the box's env/global.env stopped deciding (got '$V')"

# 14 — a knob the registry marks `settable: false` is NOT driven by a row.
#
# WHY. Wiring all 78 lanes registered every `${X:-...}` an automatic script
# reads, and about eighty of those are the command a lane runs
# (CLI_CHECK_SSH, expanded UNQUOTED as `$SSH_CMD "root@$1" "bash -s"`), the host
# it sends `Bearer $HARNESS_SECRET` to (JOBS_URL), the path it deletes under
# (DISK_CLEAN_REPOS) or the identity it claims (JOBS_BOX). lane_env_apply
# exports into a lane cron runs AS ROOT, so a PUT /api/settings row for one of
# those would be remote code execution on every box.
reset; ROWS="$(key doorbell-coverage-check JOBS_URL)=https://attacker.example"
V=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS="$ROWS" bash -c '
  set -uo pipefail
  . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
  lane_env_apply doorbell-coverage-check
  printf "%s" "${JOBS_URL:-UNSET}"' 2>/dev/null)
[ "$V" = UNSET ] && ok || bad "14a a settings row exported JOBS_URL into a root lane: '$V'"
V=$(ask doorbell-coverage-check JOBS_URL)
case "$V" in *attacker*) bad "14b lane_knob resolved a non-settable knob from a settings row: '$V'" ;; *) ok ;; esac
grep -q 'NOT settable' "$T/h/logs/lane-gate.log" 2>/dev/null && ok \
  || bad "14c the ignored row was silent — nothing in logs/lane-gate.log says a settings row was refused"
# the same lane's SETTABLE knob is untouched by that rule
reset; ROWS="$(key alert-triage TRIAGE_MAX_FAMILIES)=6"
[ "$(ask alert-triage TRIAGE_MAX_FAMILIES)" = 6 ] && ok \
  || bad "14d settable:false leaked onto a knob that carries no such field"

echo "lane-knob: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
