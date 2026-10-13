#!/bin/bash
# tests/harness-ctl-test.sh — bin/harness-ctl.sh, the operator's hand on the
# control plane (BH-1132).
#
# WHY THESE ASSERTIONS. Every one of them is a way this script could report
# success while changing nothing, which is the only failure mode that matters
# for a stop button: an operator who is told "OFF alert-triage" and walks away
# while the lane keeps spending is worse off than one who got an error.
#
# What is proved here:
#   1. a typo'd lane is REFUSED, and writes nothing (flags/lane-off-<typo> is a
#      file nothing reads, and reporting it as a stop is the lie above);
#   2. a project argument on a HUB lane is refused — the bug this caught: with
#      a free-form trailing reason, `off merge-conductor project-3 "spend"` read
#      project-3 as the first word of the reason and stopped the conductor
#      FLEET-WIDE while printing a line an operator reads as "I stopped project-3";
#   3. off writes the right switch name, with the reason, through flag_set;
#   4. off with no reason is refused;
#   5. on clears that switch and SAYS that other switches may still hold it;
#   6. set refuses a knob the lane does not have;
#   7. set clamps at both ends, refusing rather than silently correcting;
#   8. set writes lane.<id>.<env> and, with a project, lane.<id>.<proj>.<env>;
#   9. set 0 says which zero this lane means;
#  10. all-off without a reason is refused and posts nothing;
#  12. ON AND OFF TAKE THE SAME ARGUMENTS (BH-1165, the operator on the hub smoke test).
#      `on <lane> "<reason>"` read the reason as a PROJECT and refused with
#      "lane is not project-scoped — drop the project argument", so the two
#      halves of one switch had different grammars and the resume — a decision
#      during an incident — recorded nothing about who made it or why.
#  13. `seed` puts this box's env values on the page (BH-1165). A knob whose
#      row does not exist reads as "unset" on the settings screen while the lane
#      runs on a number from env/global.env. Seeding writes the row the page
#      shows — ONLY where there is no row already, because the second box to
#      seed must never overwrite the first box's value with its own.
#  14. `set` REFUSES a knob the registry marks `settable: false` — a command,
#      a host, a path or an identity a root lane runs (BH-1165 review).
#  15. `seed` never publishes one either, and treats a bearer-in-a-URL
#      (DEPLOY_HOOK_URL, WATCHDOG_URL, LOCKS_URL) as the credential it is.
#  11. `status` RUNS, against the worker's real payload shape, and prints the
#      lane's actual spend. It read .stats.usd_today while the worker emits
#      cost_today at the lane's top level, so every lane printed $0.00 —
#      including the $793 one. No suite ran `status` at all, which is why.
# Run from anywhere: tests/harness-ctl-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/bin/lib" "$T/h/catalog" "$T/h/flags" "$T/h/env" "$T/h/logs" "$T/h/state"
cp "$DIR/bin/harness-ctl.sh" "$T/h/bin/"
cp "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/" 2>/dev/null || true
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"

# bin/jobs-client.sh stands in as a recorder. flag_set / setting_set / _jobs_req
# keep the real names and the real rcs; every call lands in $T/ops, so "wrote
# nothing" is a file that stayed empty and not an inference.
cat > "$T/h/bin/jobs-client.sh" <<'SH'
JOBS_BOX=testbox
flag_set()    { echo "flag_set $1 $2 $3" >> "$OPS"; }
setting_set() { echo "setting_set $1 $2" >> "$OPS"; }
# The body is OPTIONAL in the real client (api_status and the seed's GET pass
# two arguments), and harness-ctl runs under `set -u` — a stub that names $3
# unconditionally makes every two-argument call look like a worker outage.
# SETTINGS_JSON, when set, is what GET /api/settings answers (BH-1511.1's
# seed cases need rows that already exist); everything else gets the flag body.
_jobs_req()   { echo "req $1 $2 ${3:-}" >> "$OPS"
  if [ "$1 $2" = "GET /api/settings" ] && [ -n "${SETTINGS_JSON:-}" ]; then printf '%s' "$SETTINGS_JSON"; return 0; fi
  if [ "$1 $2" = "GET /api/boxes" ]; then [ -n "${BOXES_DOWN:-}" ] && return 1; printf '%s' "${BOXES_JSON:-{\"boxes\":[]\}}"; return 0; fi
  case "$1 $2" in "GET /api/lanes/tick-boxes?"*) [ -n "${TICKS_DOWN:-}" ] && return 1; printf '%s' "${TICKS_JSON:-{\"boxes\":[]\}}"; return 0 ;; esac
  if [ "$1 $2" = "POST /api/settings/seed-registry" ] && [ -n "${SEED_RESP:-}" ]; then printf '%s' "$SEED_RESP"; return 0; fi
  if [ "$1 $2" = "GET /api/settings/seed-registry/plan" ]; then printf '%s' "${PLAN_JSON:-{\"rows\":0,\"insert\":[],\"update\":[],\"prune\":[]\}}"; return 0; fi
  printf '{"flag":{"updated_at":"2026-09-20T10:00:00Z","reason":"r"}}'; }
SH

# `set … <project>` refuses a project fleet.conf does not list (BH-1985). The
# fixture lives OUTSIDE the scratch harness, through FLEET_CONF, which only
# `set` reads — so `on`'s own fleet.conf read (12) sees exactly what it did.
printf 'project-2 example-org/project-2 x\n' > "$T/fleet-set.conf"
ctl() { env HARNESS="$T/h" OPS="$T/ops" FLEET_CONF="$T/fleet-set.conf" bash "$T/h/bin/harness-ctl.sh" "$@" 2>&1; }
# `lane.<id>[.<project>].<env lowercased>` — the published contract's form,
# spelled out here so this suite fails if the CLI ever drifts to another one.
key() { # key <lane> <ENV> [project]
  local low; low=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  if [ -n "${3:-}" ]; then printf 'lane.%s.%s.%s' "$1" "$3" "$low"; else printf 'lane.%s.%s' "$1" "$low"; fi
}
reset() { : > "$T/ops"; }
wrote_nothing() { [ ! -s "$T/ops" ]; }

# 1 — a typo'd lane
reset; OUT=$(ctl off merge-condcutor "spend"); RC=$?
[ "$RC" -ne 0 ] && wrote_nothing && case "$OUT" in *"no lane"*) true ;; *) false ;; esac \
  && ok || bad "1 a typo'd lane was not refused cleanly: rc=$RC out=$OUT ops=$(cat "$T/ops")"

# 2 — a project on a hub lane
reset; OUT=$(ctl off merge-conductor project-3 "spend"); RC=$?
[ "$RC" -ne 0 ] && wrote_nothing && ok || bad "2 a project argument on a hub lane was accepted: $OUT"

# 3 — off writes the switch and the reason
reset; ctl off alert-triage "burning \$793" >/dev/null
grep -q 'flag_set lane-off-alert-triage on burning' "$T/ops" && ok \
  || bad "3 off did not write the switch: $(cat "$T/ops")"

# 3b — a PROJECT-scoped lane keeps the suffix
reset; ctl off review-prs project-2 "flaky ci" >/dev/null
grep -q 'flag_set lane-off-review-prs-project-2 on' "$T/ops" && ok \
  || bad "3b project switch name wrong: $(cat "$T/ops")"

# 4 — no reason, no stop
reset; OUT=$(ctl off alert-triage); RC=$?
[ "$RC" -ne 0 ] && wrote_nothing && ok || bad "4 a reasonless stop was accepted: $OUT"

# 5 — on clears it and warns that it may still be held
reset; OUT=$(ctl on alert-triage)
grep -q 'flag_set lane-off-alert-triage off' "$T/ops" || bad "5a on did not clear the switch"
grep -q 'flag_set lane-off-alert-triage off' "$T/ops" && ok
case "$OUT" in *"other switches may still hold it"*) ok ;; *) bad "5b on did not warn about other holds: $OUT" ;; esac

# 6 — a knob the lane does not have
reset; OUT=$(ctl set alert-triage NOT_A_KNOB 3); RC=$?
[ "$RC" -ne 0 ] && wrote_nothing && ok || bad "6 an unknown knob was accepted: $OUT"

# 7 — the clamp refuses rather than corrects. TRIAGE_MAX_FAMILIES is 0..50.
reset; OUT=$(ctl set alert-triage TRIAGE_MAX_FAMILIES 999); RC=$?
[ "$RC" -ne 0 ] && wrote_nothing && ok || bad "7a above max was accepted: $OUT"
reset; OUT=$(ctl set alert-triage TRIAGE_MAX_FAMILIES -1); RC=$?
[ "$RC" -ne 0 ] && wrote_nothing && ok || bad "7b below min was accepted: $OUT"

# 8 — the settings keys
reset; ctl set alert-triage TRIAGE_MAX_FAMILIES 2 >/dev/null
grep -qx "setting_set $(key alert-triage TRIAGE_MAX_FAMILIES) 2" "$T/ops" && ok \
  || bad "8a global key wrong: $(cat "$T/ops")"
reset; ctl set review-prs REVIEW_CI_STALE_SECS 900 project-2 >/dev/null
grep -qx "setting_set $(key review-prs REVIEW_CI_STALE_SECS project-2) 900" "$T/ops" && ok \
  || bad "8b project key wrong: $(cat "$T/ops")"

# 9 — which zero this is
reset; OUT=$(ctl set alert-triage TRIAGE_MAX_FAMILIES 0)
case "$OUT" in *"0 means off"*) ok ;; *) bad "9a alert-triage 0 not named as off: $OUT" ;; esac
reset; OUT=$(ctl set review-autopilot REVIEW_AUTOPILOT_DAILY_CAP 0)
case "$OUT" in *"0 means unlimited"*) ok ;; *) bad "9b autopilot 0 not named as unlimited: $OUT" ;; esac

# 10 — a fleet stop with no reason
reset; OUT=$(ctl all-off); RC=$?
[ "$RC" -ne 0 ] && wrote_nothing && ok || bad "10 a reasonless fleet stop was accepted: $OUT"
reset; ctl all-off "everything is burning" >/dev/null
grep -q 'req POST /api/lanes/all-off' "$T/ops" && [ -f "$T/h/flags/all-off" ] && ok \
  || bad "10b all-off did not post and touch the file: $(cat "$T/ops")"

# 11 — `status` against the payload the worker actually sends.
cat > "$T/h/bin/jobs-client.sh" <<'SH'
JOBS_BOX=testbox
flag_set()    { echo "flag_set $1 $2 $3" >> "$OPS"; }
setting_set() { echo "setting_set $1 $2" >> "$OPS"; }
_jobs_req() {
  echo "req $1 $2" >> "$OPS"
  cat "$FIXTURE"
}
SH
cat > "$T/status.json" <<'JSON'
{"as_of":"2026-09-20T12:00:00Z","projects":["project-4"],"all_off":false,
 "lanes":[
  {"id":"alert-triage","name":"Alert triage","scope":"hub","project":null,
   "cadence":"*/10 * * * *","off":true,"off_source":"db","held_by":["lane-off-alert-triage"],
   "runs_today":42,"cost_today":793.14,"cost_7d":900.5,
   "cost_attribution":"lane","cost_shared_with":[],"knobs":{},"cost_rows":[]},
  {"id":"merge-conductor","name":"Merge conductor","scope":"hub","project":null,
   "cadence":"*/5 * * * *","off":false,"off_source":null,"held_by":[],
   "runs_today":null,"cost_today":null,"cost_7d":null,
   "cost_attribution":"shared","cost_shared_with":["review-prs","review-autopilot"],
   "knobs":{},"cost_rows":[]}]}
JSON
OUT=$(env HARNESS="$T/h" OPS="$T/ops" FIXTURE="$T/status.json" bash "$T/h/bin/harness-ctl.sh" status 2>&1)
case "$OUT" in *793.14*) ok ;; *) bad "11a status did not print the lane's real spend (the \$793 lane): $OUT" ;; esac
case "$OUT" in *OFF*) ok ;; *) bad "11b status did not mark the stopped lane OFF: $OUT" ;; esac
# a lane whose spend nobody can attribute prints a dash and names the sharers,
# never a confident 0.00
case "$OUT" in *"spend shared with review-prs"*) ok ;; *) bad "11c status did not name the shared-spend lanes: $OUT" ;; esac
case "$OUT" in *'$0'*) bad "11d status printed a confident \$0 for a lane with null spend: $OUT" ;; *) ok ;; esac

# 12 — on and off take the same arguments.
# Section 11 swapped the client for the status FIXTURE reader; these sections
# are about what is WRITTEN, so the recorder goes back.
cat > "$T/h/bin/jobs-client.sh" <<'SH'
JOBS_BOX=testbox
flag_set()    { echo "flag_set $1 $2 $3" >> "$OPS"; }
setting_set() { echo "setting_set $1 $2" >> "$OPS"; }
_jobs_req()   { echo "req $1 $2 ${3:-}" >> "$OPS"
  if [ "$1 $2" = "GET /api/settings" ] && [ -n "${SETTINGS_JSON:-}" ]; then printf '%s' "$SETTINGS_JSON"; return 0; fi
  if [ "$1 $2" = "GET /api/boxes" ]; then [ -n "${BOXES_DOWN:-}" ] && return 1; printf '%s' "${BOXES_JSON:-{\"boxes\":[]\}}"; return 0; fi
  case "$1 $2" in "GET /api/lanes/tick-boxes?"*) [ -n "${TICKS_DOWN:-}" ] && return 1; printf '%s' "${TICKS_JSON:-{\"boxes\":[]\}}"; return 0 ;; esac
  if [ "$1 $2" = "POST /api/settings/seed-registry" ] && [ -n "${SEED_RESP:-}" ]; then printf '%s' "$SEED_RESP"; return 0; fi
  if [ "$1 $2" = "GET /api/settings/seed-registry/plan" ]; then printf '%s' "${PLAN_JSON:-{\"rows\":0,\"insert\":[],\"update\":[],\"prune\":[]\}}"; return 0; fi
  printf '{"flag":{"updated_at":"2026-09-20T10:00:00Z","reason":"r"}}'; }
SH
reset; OUT=$(ctl on alert-triage "the spike is over"); RC=$?
[ "$RC" -eq 0 ] || bad "12a on with a reason was refused: $OUT"
grep -q 'flag_set lane-off-alert-triage off the spike is over' "$T/ops" && ok \
  || bad "12b the resume did not record WHY: $(cat "$T/ops")"
# the project form still works, and the reason is still its own argument
reset; OUT=$(ctl on review-prs project-2 "ci is green again"); RC=$?
grep -q 'flag_set lane-off-review-prs-project-2 off ci is green again' "$T/ops" && ok \
  || bad "12c on <lane> <project> \"<reason>\" did not write the project switch: $OUT $(cat "$T/ops")"
# and a hub lane still refuses two arguments — the ambiguity `off` was fixed for
# (a project read as the first word of a reason) must not come back through `on`
reset; OUT=$(ctl on merge-conductor project-3 "resume"); RC=$?
[ "$RC" -ne 0 ] && wrote_nothing && ok || bad "12d a project argument on a hub lane's resume was accepted: $OUT"
# with no reason at all it still works, and says so in the row
reset; ctl on alert-triage >/dev/null
grep -q 'flag_set lane-off-alert-triage off resumed via harness-ctl' "$T/ops" && ok \
  || bad "12e a bare resume stopped working: $(cat "$T/ops")"

# 13 — seed: this box's env values become the rows the page shows.
mkdir -p "$T/h/env"
cat > "$T/h/env/global.env" <<'ENV'
TRIAGE_MAX_FAMILIES=6
MC_MERGE_BUDGET=4
NOT_A_KNOB_AT_ALL=9
MIGRATION_TOKEN=shhh
ENV
reset; OUT=$(ctl seed 2>&1)
grep -qx "setting_set $(key alert-triage TRIAGE_MAX_FAMILIES) 6" "$T/ops" && ok \
  || bad "13a seed did not write the env value the lane is running on: $(cat "$T/ops")"
grep -qx "setting_set $(key merge-conductor MC_MERGE_BUDGET) 4" "$T/ops" && ok \
  || bad "13b seed missed a second lane's knob: $(cat "$T/ops")"
grep -q 'NOT_A_KNOB_AT_ALL' "$T/ops" && bad "13c seed wrote a variable no lane declares" || ok
# A CREDENTIAL IS NEVER SEEDED. env/global.env is full of them, and a settings
# row is readable on a web page.
grep -qi 'migration_token\|shhh' "$T/ops" && bad "13d seed put a credential in a settings row" || ok
# --dry-run says what it would do and writes nothing. The settings READ is not
# a write, so the check is on setting_set and not on an empty ops file.
reset; OUT=$(ctl seed --dry-run 2>&1)
case "$OUT" in *TRIAGE_MAX_FAMILIES*) ok ;; *) bad "13e --dry-run printed nothing useful: $OUT" ;; esac
grep -q 'setting_set' "$T/ops" && bad "13f --dry-run wrote rows: $(cat "$T/ops")" || ok


# 14 — A COMMAND, A HOST, A PATH OR AN IDENTITY IS NOT SETTABLE (BH-1165 review).
#
# Wiring all 78 lanes registered every `${X:-…}` an automatic script reads, and
# about eighty of those are not numbers an operator tunes: `CLI_CHECK_SSH` is
# expanded UNQUOTED as the command (`$SSH_CMD "root@$1" "bash -s"`), `JOBS_URL`
# is the host every request of that tick sends `Bearer $HARNESS_SECRET` to, and
# `*_API_BASE` is where `MIGRATION_TOKEN` is POSTed. bin/lib/lane-gate.sh
# exports a settings row into a lane cron runs AS ROOT, so `settable: false` is
# refused at every write surface and this is the CLI's half.
reset; OUT=$(ctl set doorbell-coverage-check JOBS_URL https://attacker.example 2>&1); RC=$?
[ "$RC" -ne 0 ] && wrote_nothing && ok \
  || bad "14a set wrote a settings row for a host a root lane curls: $OUT $(cat "$T/ops")"
case "$OUT" in *settable*) ok ;; *) bad "14b the refusal did not say why: $OUT" ;; esac
# and a normal knob is untouched by the rule
reset; ctl set alert-triage TRIAGE_MAX_FAMILIES 6 >/dev/null
grep -qx "setting_set $(key alert-triage TRIAGE_MAX_FAMILIES) 6" "$T/ops" && ok \
  || bad "14c the settable-check swallowed an ordinary knob: $(cat "$T/ops")"

# 15 — seed does not publish them either, and a bearer-in-a-URL is a credential.
# `DEPLOY_HOOK_URL` is a Vercel deploy hook — a token inside a URL — and the
# suffix-only credential filter did not match it, nor WATCHDOG_URL, nor
# LOCKS_URL. All three would have been copied out of env/global.env into rows
# that render on a web page.
cat > "$T/h/env/global.env" <<'ENV'
TRIAGE_MAX_FAMILIES=6
JOBS_URL=https://harness-jobs.example
WATCHDOG_URL=https://harness-watchdog.example/secret-path
DEPLOY_HOOK_URL=https://api.vercel.com/v1/integrations/deploy/prj_x/abc123
CLI_CHECK_SSH=ssh -o BatchMode=yes
ENV
reset; ctl seed >/dev/null 2>&1
grep -q 'jobs_url\|watchdog_url\|deploy_hook_url\|cli_check_ssh' "$T/ops" \
  && bad "15a seed published a host/command/hook row on a web page: $(cat "$T/ops")" || ok
grep -qx "setting_set $(key alert-triage TRIAGE_MAX_FAMILIES) 6" "$T/ops" && ok \
  || bad "15b seed stopped writing ordinary knobs: $(cat "$T/ops")"

# 16 — BH-1511.1: a REGISTRY-SEED row is the DB's copy of the default, not a
# value anybody chose, so `seed` writes this box's env value over it (it is
# what the lane is running on); an OPERATOR's row is still left alone.
cat > "$T/h/env/global.env" <<'ENV'
TRIAGE_MAX_FAMILIES=6
ENV
reset
SETTINGS_JSON="{\"settings\":[{\"key\":\"$(key alert-triage TRIAGE_MAX_FAMILIES)\",\"value\":\"4\",\"actor\":\"registry-seed\"}]}" ctl seed >/dev/null 2>&1
grep -qx "setting_set $(key alert-triage TRIAGE_MAX_FAMILIES) 6" "$T/ops" && ok \
  || bad "16a seed must write the env value over a registry-seed mirror row: $(cat "$T/ops")"
reset
OUT=$(SETTINGS_JSON="{\"settings\":[{\"key\":\"$(key alert-triage TRIAGE_MAX_FAMILIES)\",\"value\":\"4\",\"actor\":\"operator\"}]}" ctl seed 2>&1)
grep -q "setting_set $(key alert-triage TRIAGE_MAX_FAMILIES)" "$T/ops" \
  && bad "16b seed overwrote an operator's row: $(cat "$T/ops")" || ok
case "$OUT" in *MISMATCH*) ok ;; *) bad "16c an operator row that disagrees must be reported, not written: $OUT" ;; esac
# 17 — `seed-registry` REFUSES until every box runs the contract (review I2).
# A pre-contract lane-gate reads a registry-seed row as an operator value and
# would move the 15 knobs whose read disagrees with the registry. So the CLI
# finds the commit that introduced the seed actor in its own checkout and
# demands that every box's reported harness_commit (box_status, written hourly
# by the new lane-gate's liveness post) descends from it, reported within 2h.
# Unreadable, silent, stale or behind = refused, naming the box; nothing is
# POSTed. `--exclude-box <name>` is the explicit, printed way past a retired box.
CO="$T/co"; mkdir -p "$CO/bin/lib"
g() { git -C "$CO" -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }
g init -q; echo old > "$CO/bin/lib/lane-gate.sh"; g add -A; g commit -qm pre
PRE=$(git -C "$CO" rev-parse HEAD)
echo '_LG_SEED_ACTOR=registry-seed' > "$CO/bin/lib/lane-gate.sh"; g commit -qam contract
echo 'more' >> "$CO/bin/lib/lane-gate.sh"; g commit -qam later
CUR=$(git -C "$CO" rev-parse HEAD)
NOWE=1758300000; FRESH="2025-09-19T16:30:00Z"; STALE="2025-09-19T10:00:00Z"   # NOWE is 2025-09-19T16:40:00Z
box() { printf '{"box":"%s","harness_commit":%s,"harness_reported_at":%s}' "$1" "$2" "$3"; }
seedctl() { env HARNESS="$T/h" OPS="$T/ops" HARNESS_CHECKOUT="$CO" HARNESS_CTL_NOW="$NOWE" \
  BOXES_JSON="$BOXES_JSON" BOXES_DOWN="${BOXES_DOWN:-}" TICKS_JSON="${TICKS_JSON:-}" TICKS_DOWN="${TICKS_DOWN:-}" \
  PLAN_JSON="${PLAN_JSON:-}" SEED_RESP="${SEED_RESP:-}" ${SEED_GATE_TICK_WINDOW_S:+SEED_GATE_TICK_WINDOW_S="$SEED_GATE_TICK_WINDOW_S"} \
  bash "$T/h/bin/harness-ctl.sh" seed-registry "$@" 2>&1; }
# The boxes the gate must prove are the ones that RUN lane-gate: the distinct
# lane_ticks.box that ticked inside the window (GET /api/lanes/tick-boxes).
ticks() { local o="" b; for b in "$@"; do o="$o${o:+,}{\"box\":\"$b\",\"last_tick_at\":\"$FRESH\"}"; done; printf '{"boxes":[%s]}' "$o"; }
seeded() { grep -qx "req POST /api/settings/seed-registry {}" "$T/ops"; }
BOXES_JSON="{\"boxes\":[$(box hub "\"$CUR\"" "\"$FRESH\""),$(box old1 "\"$PRE\"" "\"$FRESH\""),$(box quiet "null" "null"),$(box gone "\"$CUR\"" "\"$STALE\"")]}"
TICKS_JSON=$(ticks hub old1 quiet gone)
reset; OUT=$(seedctl); RC=$?
[ "$RC" -ne 0 ] && ! seeded && ok || bad "17a a fleet with a lagging box must be refused, nothing POSTed: rc=$RC $(cat "$T/ops")"
for b in old1 quiet gone; do
  case "$OUT" in *"$b"*) ok ;; *) bad "17b the refusal must name $b: $OUT" ;; esac
done
case "$OUT" in *"hub "*|*"hub:"*|*"hub ("*) bad "17c a current box was named as lagging: $OUT" ;; *) ok ;; esac
reset; OUT=$(seedctl --exclude-box old1 --exclude-box quiet --exclude-box gone); RC=$?
[ "$RC" = 0 ] && seeded && ok || bad "17d every lagging box explicitly excluded -> seed runs: rc=$RC $OUT $(cat "$T/ops")"
case "$OUT" in *excluded*old1*|*old1*excluded*) ok ;; *) bad "17e the exclusions must be printed: $OUT" ;; esac
BOXES_JSON="{\"boxes\":[$(box hub "\"$CUR\"" "\"$FRESH\"")]}"; TICKS_JSON=$(ticks hub)
reset; OUT=$(seedctl); RC=$?
[ "$RC" = 0 ] && seeded && ok || bad "17f every box current -> one POST: rc=$RC $OUT $(cat "$T/ops")"
[ "$(grep -c 'POST' "$T/ops")" = 1 ] && ok || bad "17g exactly one write: $(cat "$T/ops")"
reset; OUT=$(BOXES_DOWN=1 seedctl); RC=$?
[ "$RC" -ne 0 ] && ! seeded && ok || bad "17h an unreadable box list must refuse: rc=$RC $OUT"
reset; OUT=$(env HARNESS="$T/h" OPS="$T/ops" HARNESS_CHECKOUT="$T/nogit" HARNESS_CTL_NOW="$NOWE" BOXES_JSON="$BOXES_JSON" \
  bash "$T/h/bin/harness-ctl.sh" seed-registry 2>&1); RC=$?
[ "$RC" -ne 0 ] && ! seeded && ok || bad "17i no checkout to find the contract commit in must refuse: rc=$RC $OUT"

# 17j-q — review round 2 of #1565 (B1, I-a, --dry-run).
# B1: box_status is NOT the fleet. cli-version-check names boxes by
# cron_box_id_for (box-hub -> hub, box-project-4-1 -> project-4) and
# those alias rows can never carry a harness_commit, so a gate that walks
# box_status refuses forever on the live fleet. The set to prove is the boxes
# that tick lanes; an alias row with no tick is not a box that reads settings.
BOXES_JSON="{\"boxes\":[$(box box-hub "\"$CUR\"" "\"$FRESH\""),$(box hub "null" "null"),$(box box-project-4-1 "\"$CUR\"" "\"$FRESH\""),$(box project-4 "null" "null")]}"
TICKS_JSON=$(ticks box-hub box-project-4-1)
reset; OUT=$(seedctl); RC=$?
[ "$RC" = 0 ] && seeded && ok || bad "17j a dual-named fleet (alias rows with no ticks) must seed: rc=$RC $OUT $(cat "$T/ops")"
case "$OUT" in *"hub:"*|*"project-4:"*) bad "17j an alias row with no lane tick was named as lagging: $OUT" ;; *) ok ;; esac
# B1, the fail-open half: a box that ticks lanes but has NO box_status row
# (old lane-gate, no backup or CLI reporter) must be checked, and refused.
BOXES_JSON="{\"boxes\":[$(box hub "\"$CUR\"" "\"$FRESH\"")]}"; TICKS_JSON=$(ticks hub ghost)
reset; OUT=$(seedctl); RC=$?
[ "$RC" -ne 0 ] && ! seeded && ok || bad "17k a ticking box with no box_status row must refuse, nothing POSTed: rc=$RC $OUT $(cat "$T/ops")"
case "$OUT" in *ghost*) ok ;; *) bad "17k the refusal must name ghost: $OUT" ;; esac
# the tick list is the fleet: unreadable or empty is a refusal, never a pass
TICKS_JSON=$(ticks hub)
reset; OUT=$(TICKS_DOWN=1 seedctl); RC=$?
[ "$RC" -ne 0 ] && ! seeded && ok || bad "17l an unreadable tick list must refuse: rc=$RC $OUT"
reset; OUT=$(TICKS_JSON='{"boxes":[]}' seedctl); RC=$?
[ "$RC" -ne 0 ] && ! seeded && ok || bad "17l an empty tick list must refuse: rc=$RC $OUT"
# the window is a knob, sent to the worker, and a non-number is refused
reset; OUT=$(SEED_GATE_TICK_WINDOW_S=3600 seedctl); RC=$?
grep -q 'req GET /api/lanes/tick-boxes?within_s=3600' "$T/ops" && ok || bad "17m SEED_GATE_TICK_WINDOW_S must be the window asked for: $(cat "$T/ops")"
reset; OUT=$(SEED_GATE_TICK_WINDOW_S=soon seedctl); RC=$?
[ "$RC" -ne 0 ] && ! seeded && ok || bad "17m a non-numeric window must refuse: rc=$RC $OUT"
# I-a: a commit this checkout does not have is "fetch", not "behind" — and still refused
UNK=0123456789abcdef0123456789abcdef01234567
BOXES_JSON="{\"boxes\":[$(box hub "\"$UNK\"" "\"$FRESH\"")]}"; TICKS_JSON=$(ticks hub)
reset; OUT=$(seedctl); RC=$?
[ "$RC" -ne 0 ] && ! seeded && ok || bad "17n an unknown commit must still refuse: rc=$RC $OUT"
case "$OUT" in *"does not contain"*) bad "17n an unknown commit was reported as lacking the contract: $OUT" ;; *fetch*) ok ;; *) bad "17n an unknown commit must say to fetch the checkout: $OUT" ;; esac
# --dry-run: the gate runs, the plan is printed key by key, nothing is POSTed
PLAN_JSON='{"rows":3,"insert":["lane.a.x_new"],"update":[{"key":"lane.b.y_moved","from":"1","to":"2"}],"prune":["lane.c.z_gone"],"operator_owned":1,"unchanged":0}'
BOXES_JSON="{\"boxes\":[$(box hub "\"$CUR\"" "\"$FRESH\"")]}"; TICKS_JSON=$(ticks hub)
reset; OUT=$(PLAN_JSON="$PLAN_JSON" seedctl --dry-run); RC=$?
[ "$RC" = 0 ] && ! seeded && ok || bad "17o --dry-run on a proven fleet: rc 0 and no POST: rc=$RC $OUT $(cat "$T/ops")"
grep -q 'POST' "$T/ops" && bad "17o --dry-run wrote: $(cat "$T/ops")" || ok
for k in lane.a.x_new lane.b.y_moved lane.c.z_gone; do
  case "$OUT" in *"$k"*) ok ;; *) bad "17o --dry-run must print $k: $OUT" ;; esac
done
TICKS_JSON=$(ticks hub ghost)
reset; OUT=$(PLAN_JSON="$PLAN_JSON" seedctl --dry-run); RC=$?
[ "$RC" -ne 0 ] && ! seeded && ok || bad "17p --dry-run on an unproven fleet must say it would refuse (rc!=0), no POST: rc=$RC $OUT"
case "$OUT" in *ghost*lane.a.x_new*|*lane.a.x_new*ghost*) ok ;; *) bad "17p --dry-run must name the blocking box AND still print the plan: $OUT" ;; esac
# the real run prints the keys it changed and pruned, not only counts
TICKS_JSON=$(ticks hub)
reset; OUT=$(SEED_RESP='{"rows":3,"changed":1,"pruned":1,"changed_keys":["lane.a.x_new"],"pruned_keys":["lane.c.z_gone"],"actor":"registry-seed"}' seedctl); RC=$?
[ "$RC" = 0 ] && seeded && ok || bad "17q the seed must run: rc=$RC $OUT"
case "$OUT" in *lane.a.x_new*lane.c.z_gone*) ok ;; *) bad "17q the seed must print the changed and pruned keys: $OUT" ;; esac

# 17r (BH-1632) — a pool machine that ticks lanes but never reported a commit is
# REFUSED, never skipped, and the message says what a pool box is missing: no
# .git and no HARNESS_COMMIT stamp, not only "its lane-gate predates the contract".
BOXES_JSON="{\"boxes\":[$(box hub "\"$CUR\"" "\"$FRESH\""),$(box pool-demo-abc123 "null" "null")]}"; TICKS_JSON=$(ticks hub pool-demo-abc123)
reset; OUT=$(seedctl --dry-run); RC=$?
[ "$RC" -ne 0 ] && ! seeded && ok || bad "17r an unreported pool box must refuse, nothing POSTed: rc=$RC $OUT"
case "$OUT" in *pool-demo-abc123*HARNESS_COMMIT*) ok ;; *) bad "17r the refusal must name pool-demo-abc123 and the HARNESS_COMMIT stamp: $OUT" ;; esac
# and one that reports a stamp sha holding the contract passes like any box
BOXES_JSON="{\"boxes\":[$(box hub "\"$CUR\"" "\"$FRESH\""),$(box pool-demo-abc123 "\"$CUR\"" "\"$FRESH\"")]}"
reset; OUT=$(seedctl --dry-run); RC=$?
[ "$RC" = 0 ] && ! seeded && ok || bad "17r a pool box reporting a contract commit must pass the gate: rc=$RC $OUT"

echo "harness-ctl: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
