#!/bin/bash
# tests/main-red-infra-rerun.bh-2165-test.sh — BH-2165: a main run that failed
# ONLY on `infra:` steps (apt installs) is re-run once, recorded as INFRA, and
# never raises the main-red freeze.
#
#   THE INCIDENT (2026-09-24, cromford). Harness CI runs 36029556164 and
#   36029663354 failed on main because apt could not install packages. No test
#   ran, let alone failed, and bin/main-red-detector.sh froze every merge lane
#   on the two-red streak. #2159 gave those steps `infra:` names; this suite
#   pins that the detector reads the failed run's jobs JSON over REST and:
#     - an infra-only failure at run_attempt 1: no flag, one POST
#       rerun-failed-jobs, verdict decision=infra, ledger rerun=requested;
#     - the same run infra-only again after its rerun (attempt >= 2): one
#       non-critical alert, still no flag, no second POST;
#     - anything that is not PROVABLY infra-only (a test step failed, a mixed
#       job, an unreadable/truncated/empty jobs list, a near-miss step name)
#       raises exactly as before: flag + --critical alert, no POST.
#
# Fixtures are raw GitHub jobs JSON (total_count, jobs[].run_attempt, steps[])
# using #2159's real step names. Every case drives the real detector through a
# PATH gh shim. Run from anywhere; exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-infra-rerun.bh-2165-test: SKIPPED — jq/python3 is not installed"; exit 0; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin" "$T/fx" "$T/ledger"
cp "$DIR/bin/main-red-detector.sh" "$T/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$T/bin/lib/"
: > "$T/env/global.env"

cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# The coordination-DB client: flag_set records, the ledger verbs keep
# bin/lib/jobs/jobs.sh's contract (get rc 0 + status, rc 2 no row) over files.
cat > "$T/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
_lrow() { printf '%s/%s__%s' "$LEDGER_DIR" "$1" "$(printf '%s' "$2" | tr '/#' '-_')"; }
job_ledger_get() {
  local f; f=$(_lrow "$1" "$2"); [ -f "$f" ] || return 2
  cat "$f"; return 0
}
job_ledger_put() {
  printf '%s %s %s\n' "$1" "$2" "$3" >> "$LEDGER_DIR/.puts"
  printf '%s' "$3" > "$(_lrow "$1" "$2")"; return 0
}
SHIM

# gh shim: every argv is recorded. The POST answers $T/post-rc (default 0).
# A jobs read serves $T/fx/jobs-<rid>.json RAW, or exits $T/fx/jobs-rc.
# A runs read serves $T/fx/runs.json through the projection the detector asks.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/"*" -q .id") exit 0 ;;
  *"-X POST"*"rerun-failed-jobs"*) exit "$(cat "$T/post-rc" 2>/dev/null || echo 0)" ;;
  *"/actions/runs/"*"/jobs"*)
    [ -f "$T/fx/jobs-rc" ] && exit "$(cat "$T/fx/jobs-rc")"
    rid=$(printf '%s' "$*" | sed -n 's|.*/actions/runs/\([0-9]*\)/jobs.*|\1|p')
    [ -f "$T/fx/jobs-$rid.json" ] || exit 1
    case "$*" in
      *" -q "*) jq -r '[.jobs[]? | select(.conclusion=="failure") | .name] | join(", ")' "$T/fx/jobs-$rid.json" 2>/dev/null ;;
      *) cat "$T/fx/jobs-$rid.json" ;;
    esac ;;
  *"actions/runs"*)
    [ -s "$T/fx/runs.json" ] || exit 1
    R='[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id}]'
    jq -c "{total:.total_count, runs:$R}" "$T/fx/runs.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

CI=".github/workflows/harness-ci.yml"
FLAG="$T/flags/main-red-o-r"
VERDICT="$T/state/main-red/o-r.verdict"
OLD=36029556164; NEW=36029663354
NOW=$(date +%s)
ago() { date -u -d "@$(( NOW - $1 * 60 ))" +%FT%TZ; }

runs() { # runs <id|status|conclusion|sha|minutes-ago>...
  local out='[' first=1 spec id s c sha m
  for spec in "$@"; do
    IFS='|' read -r id s c sha m <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "Harness CI" --arg p "$CI" --arg s "$s" --arg c "$c" --arg sha "$sha" \
      --arg t "$(ago "$m")" --arg u "https://github.com/o/r/actions/runs/$id" --argjson id "$id" \
      '{name:$n, path:$p, status:$s, conclusion:(if $c=="null" then null else $c end),
        head_sha:$sha, created_at:$t, html_url:$u, id:$id}')
  done
  jq -nc --argjson r "$out]" '{total_count:($r|length), workflow_runs:$r}' > "$T/fx/runs.json"
}
# jobs <rid> <attempt> <total_count|-> <jobname|conclusion|step~concl;step~concl>...
# total_count "-" means "the number of jobs given".
jobs() {
  local rid="$1" att="$2" tc="$3" out='[' first=1 spec jn jc steps st sn sc sarr sf n; shift 3
  for spec in "$@"; do
    IFS='|' read -r jn jc steps <<<"$spec"
    sarr='['; sf=1; n=0
    IFS=';' read -ra st <<<"$steps"
    for s in "${st[@]}"; do
      sn=${s%~*}; sc=${s##*~}; n=$((n+1))
      [ "$sf" = 1 ] || sarr+=','; sf=0
      sarr+=$(jq -nc --arg n "$sn" --arg c "$sc" --argjson i "$n" \
        '{name:$n, status:"completed", conclusion:$c, number:$i}')
    done
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$jn" --arg c "$jc" --argjson a "$att" --argjson s "$sarr]" --argjson r "$rid" \
      '{id:($r*10+1), run_id:$r, run_attempt:$a, name:$n, status:"completed", conclusion:$c, steps:$s}')
  done
  if [ "$tc" = - ]; then
    jq -nc --argjson j "$out]" '{total_count:($j|length), jobs:$j}' > "$T/fx/jobs-$rid.json"
  else
    jq -nc --argjson j "$out]" --argjson tc "$tc" '{total_count:$tc, jobs:$j}' > "$T/fx/jobs-$rid.json"
  fi
}
APT="infra: install age, zstd, rsync (apt)"
PYY="infra: install PyYAML (apt)"
SUITE="tests/ suite (shard 3 of 8)"
# The incident's job: the apt step failed, so the suite step was skipped.
infra_job()  { printf '%s' "Pure-logic gate fixtures (shard 3/8)|failure|Set up job~success;actions/checkout~success;$APT~failure;$PYY~skipped;$SUITE~skipped"; }
green_job()  { printf '%s' "Syntax + shellcheck + config integrity|success|Set up job~success;bash -n every script~success"; }
test_job()   { printf '%s' "Pure-logic gate fixtures (shard 3/8)|failure|Set up job~success;$APT~success;$SUITE~failure"; }

drive() { # drive [args...] — one tick against o/r
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh-calls.txt" \
           ALERT_SINK="$T/alerts.txt" PUBLISH_SINK="$T/publish.txt" LEDGER_DIR="$T/ledger"
    unset GH_TOKEN MAIN_RED_INFRA_RERUN MAIN_RED_STALE_GUARD
    bash "$T/bin/main-red-detector.sh" "$@" o/r >"$T/out.txt" 2>"$T/err.txt" )
}
reset_case() {
  : > "$T/alerts.txt"; : > "$T/publish.txt"; : > "$T/logs/main-red.log"; : > "$T/ledger/.puts"
  : > "$T/gh-calls.txt"; : > "$T/env/global.env"
  rm -f "$T"/flags/* "$T"/locks/* "$T"/fx/* "$T/post-rc" "$T"/ledger/main_red_*
  scratch_rm "$T/state/main-red"
}
next_tick() { : > "$T/gh-calls.txt"; : > "$T/alerts.txt"; : > "$T/ledger/.puts"; }
posts()   { grep -c -- '-X POST .*rerun-failed-jobs' "$T/gh-calls.txt" 2>/dev/null | tr -d ' '; }
alerts()  { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
crit()    { grep -c -- '--critical' "$T/alerts.txt" 2>/dev/null | tr -d ' '; }
irow()    { cat "$T/ledger/main_red_infra__o-r_$1" 2>/dev/null; }
iputs()   { grep -c '^main_red_infra ' "$T/ledger/.puts" 2>/dev/null | tr -d ' '; }
verdict() { cat "$VERDICT" 2>/dev/null; }
mrlog()   { cat "$T/logs/main-red.log" 2>/dev/null; }
ctx()     { printf 'log: %s | alerts: %s | gh: %s | err: %s' "$(mrlog)" "$(cat "$T/alerts.txt")" "$(cat "$T/gh-calls.txt")" "$(cat "$T/err.txt")"; }
tip_red() { runs "$NEW|completed|failure|shaB|40" "$OLD|completed|success|shaA|90"; }

# A negative: a tip red whose jobs JSON is NOT provably infra-only must raise
# exactly as it always has — flag, --critical alert, no rerun POST.
expect_raise() { # expect_raise <label>
  [ -s "$FLAG" ] && ok || bad "$1: no main-red flag was raised ($(ctx))"
  grep -q "^sha=shaB$" "$FLAG" 2>/dev/null && ok || bad "$1: flag body: $(cat "$FLAG" 2>/dev/null)"
  [ "$(crit)" = 1 ] && ok || bad "$1: want one --critical alert ($(ctx))"
  [ "$(posts)" = 0 ] && ok || bad "$1: a rerun was POSTed for a non-infra red ($(ctx))"
  case "$(verdict)" in *"decision=red"*) ok ;; *) bad "$1: verdict: $(verdict)" ;; esac
}

# ── T1 — THE INCIDENT: two consecutive infra-only reds (streak arm) ───────
reset_case
runs "$NEW|completed|failure|shaB|40" "$OLD|completed|failure|shaA|50"
jobs "$NEW" 1 - "$(infra_job)" "$(green_job)"
jobs "$OLD" 1 - "$(infra_job)" "$(green_job)"
drive
[ -e "$FLAG" ] && bad "T1: the infra-only streak raised main-red: $(cat "$FLAG")" || ok
[ "$(crit)" = 0 ] && ok || bad "T1: paged --critical ($(ctx))"
[ "$(posts)" = 1 ] && ok || bad "T1: want exactly one rerun POST, got $(posts) ($(ctx))"
grep -q -- "-X POST repos/o/r/actions/runs/$NEW/rerun-failed-jobs" "$T/gh-calls.txt" && ok \
  || bad "T1: the POST was not for the newest run $NEW ($(ctx))"
grep -q "actions/runs/$NEW/jobs?per_page=100" "$T/gh-calls.txt" && ok \
  || bad "T1: the jobs steps were not read over REST ($(ctx))"
case "$(verdict)" in *"decision=infra"*) ok ;; *) bad "T1: verdict: $(verdict)" ;; esac
[ -s "$T/publish.txt" ] && bad "T1: a pause row was published: $(cat "$T/publish.txt")" || ok

# ── P1 — tip-shape single infra-only red, attempt 1 ────────────────────────
reset_case; tip_red; jobs "$NEW" 1 - "$(infra_job)" "$(green_job)"
drive
[ -e "$FLAG" ] && bad "P1: raised main-red: $(cat "$FLAG")" || ok
[ "$(posts)" = 1 ] && ok || bad "P1: want one POST, got $(posts) ($(ctx))"
grep -q -- "-X POST repos/o/r/actions/runs/$NEW/rerun-failed-jobs" "$T/gh-calls.txt" && ok || bad "P1: POST target ($(ctx))"
[ "$(irow "$NEW")" = "rerun=requested attempt=1" ] && ok || bad "P1: ledger row: '$(irow "$NEW")'"
case "$(mrlog)" in *"INFRA:"*"$APT"*"NOT raised"*) ok ;; *) bad "P1: no INFRA log line naming the step: $(mrlog)" ;; esac
[ "$(alerts)" = 0 ] && ok || bad "P1: the first infra failure alerted ($(ctx))"
case "$(verdict)" in *"decision=infra"*"reason=rerun"*"sha=shaB"*) ok ;; *) bad "P1: verdict: $(verdict)" ;; esac

# ── P2 — the rerun is in flight: nothing more happens ─────────────────────
next_tick
runs "$NEW|in_progress|null|shaB|40" "$OLD|completed|success|shaA|90"
drive
[ "$(posts)" = 0 ] && ok || bad "P2: POSTed again while the rerun is in flight ($(ctx))"
[ -e "$FLAG" ] && bad "P2: raised: $(cat "$FLAG")" || ok
[ "$(alerts)" = 0 ] && ok || bad "P2: alerted ($(ctx))"

# ── P2b — a tick that still reads attempt 1 after the POST landed ─────────
# (GitHub has not flipped the run yet): the ledger says a rerun is already
# requested, so no second POST and no alert.
next_tick; tip_red
drive
[ "$(posts)" = 0 ] && ok || bad "P2b: POSTed a second rerun for the same attempt ($(ctx))"
[ "$(alerts)" = 0 ] && ok || bad "P2b: alerted ($(ctx))"
[ -e "$FLAG" ] && bad "P2b: raised: $(cat "$FLAG")" || ok

# ── P3 — the rerun failed on infra AGAIN (attempt 2) ──────────────────────
next_tick; tip_red; jobs "$NEW" 2 - "$(infra_job)" "$(green_job)"
drive
[ "$(posts)" = 0 ] && ok || bad "P3: POSTed a second rerun ($(ctx))"
[ -e "$FLAG" ] && bad "P3: a repeat infra failure raised main-red: $(cat "$FLAG")" || ok
[ "$(alerts)" = 1 ] && ok || bad "P3: want one alert, got $(alerts) ($(ctx))"
[ "$(crit)" = 0 ] && ok || bad "P3: the repeat alert is --critical ($(ctx))"
case "$(cat "$T/alerts.txt")" in *"again after its rerun"*"NOT frozen"*) ok ;; *) bad "P3: alert text: $(cat "$T/alerts.txt")" ;; esac
[ "$(irow "$NEW")" = "alerted attempt=2" ] && ok || bad "P3: ledger row: '$(irow "$NEW")'"
case "$(verdict)" in *"decision=infra"*"reason=repeat"*) ok ;; *) bad "P3: verdict: $(verdict)" ;; esac

# ── P4 — P3 ticked again: no second alert ─────────────────────────────────
next_tick
drive
[ "$(alerts)" = 0 ] && ok || bad "P4: re-alerted on the same attempt ($(ctx))"
[ "$(posts)" = 0 ] && ok || bad "P4: POSTed ($(ctx))"
[ -e "$FLAG" ] && bad "P4: raised: $(cat "$FLAG")" || ok

# ── P5 — --explain on P1's fixture: read-only ─────────────────────────────
reset_case; tip_red; jobs "$NEW" 1 - "$(infra_job)" "$(green_job)"
drive --explain
[ "$(posts)" = 0 ] && ok || bad "P5: --explain POSTed a rerun ($(ctx))"
[ "$(iputs)" = 0 ] && ok || bad "P5: --explain wrote the ledger: $(cat "$T/ledger/.puts")"
grep -q 'WOULD RERUN' "$T/out.txt" && ok || bad "P5: stdout has no WOULD RERUN: $(cat "$T/out.txt")"
[ -e "$FLAG" ] && bad "P5: --explain wrote a flag" || ok
[ -e "$VERDICT" ] && bad "P5: --explain wrote a verdict" || ok

# ── P6 — the rerun POST is refused: one loud line, still no freeze ────────
reset_case; tip_red; jobs "$NEW" 1 - "$(infra_job)" "$(green_job)"; echo 1 > "$T/post-rc"
drive
[ -e "$FLAG" ] && bad "P6: raised: $(cat "$FLAG")" || ok
[ "$(posts)" = 1 ] && ok || bad "P6: want one POST attempt ($(ctx))"
[ "$(alerts)" = 1 ] && ok || bad "P6: want one alert, got $(alerts) ($(ctx))"
[ "$(crit)" = 0 ] && ok || bad "P6: the refused alert is --critical ($(ctx))"
case "$(cat "$T/alerts.txt")" in *"rerun request was refused"*"NOT frozen"*) ok ;; *) bad "P6: alert text: $(cat "$T/alerts.txt")" ;; esac
[ "$(irow "$NEW")" = "rerun=refused attempt=1" ] && ok || bad "P6: ledger row: '$(irow "$NEW")' — a refused POST must never read as requested"
case "$(verdict)" in *"decision=infra"*"reason=rerun-refused"*) ok ;; *) bad "P6: verdict: $(verdict)" ;; esac
next_tick
drive
[ "$(posts)" = 1 ] && ok || bad "P6/t2: the next tick did not retry the POST ($(ctx))"
[ "$(alerts)" = 0 ] && ok || bad "P6/t2: re-alerted a refused rerun ($(ctx))"

# ── P7 — a freeze already up on an older sha is left exactly as it is ─────
reset_case; tip_red; jobs "$NEW" 1 - "$(infra_job)" "$(green_job)"
printf 'sha=shaOLD\nworkflow=Harness CI\npath=%s\njob=x\nsince=2026-09-24T08:00:00Z\nstreak=2\nrun=u\ndetected=d\nreason=streak\n' "$CI" > "$FLAG"
cp "$FLAG" "$T/flag.before"
drive
cmp -s "$FLAG" "$T/flag.before" && ok || bad "P7: the flag body changed: $(cat "$FLAG")"
grep -q 'STILL RED' "$T/alerts.txt" && bad "P7: sent a still-red-on-a-new-sha alert ($(ctx))" || ok
#     and when that run fails on infra again, the alert must not claim merges
#     are unfrozen: the earlier freeze is still up.
next_tick; jobs "$NEW" 2 - "$(infra_job)" "$(green_job)"
drive
cmp -s "$FLAG" "$T/flag.before" && ok || bad "P7/t2: the flag body changed: $(cat "$FLAG")"
[ "$(alerts)" = 1 ] && ok || bad "P7/t2: want one alert ($(ctx))"
grep -q 'NOT frozen' "$T/alerts.txt" && bad "P7/t2: says NOT frozen while a freeze is up: $(cat "$T/alerts.txt")" || ok
grep -q 'stay frozen on the earlier red (main-red-o-r)' "$T/alerts.txt" && ok || bad "P7/t2: alert text: $(cat "$T/alerts.txt")"

# ── N1 — a test step failed ────────────────────────────────────────────────
reset_case; tip_red; jobs "$NEW" 1 - "$(test_job)" "$(green_job)"
drive; expect_raise N1
# a raise still costs ONE jobs read: the job is named from the body the infra
# check already read, and it is the failed job, not the green one.
[ "$(grep -c '/jobs' "$T/gh-calls.txt")" = 1 ] && ok || bad "N1: want one jobs read ($(ctx))"
grep -q '^job=Pure-logic gate fixtures (shard 3/8)$' "$FLAG" && ok || bad "N1: flag job: $(cat "$FLAG" 2>/dev/null)"
# ── N2 — one job: an infra step AND a test step both failed ───────────────
reset_case; tip_red
jobs "$NEW" 1 - "Pure-logic gate fixtures (shard 3/8)|failure|$APT~failure;$SUITE~failure"
drive; expect_raise N2
# ── N3 — two failed jobs: one infra-only, one with a test failure ─────────
reset_case; tip_red; jobs "$NEW" 1 - "$(infra_job)" "$(test_job)"
drive; expect_raise N3
# ── N4 — a failed (timed out) job whose steps show no `failure` ───────────
reset_case; tip_red
jobs "$NEW" 1 - "Pure-logic gate fixtures (shard 3/8)|timed_out|$APT~success;$SUITE~cancelled"
drive; expect_raise N4
# ── N5 — the prefix not at the start, and the wrong case ──────────────────
reset_case; tip_red
jobs "$NEW" 1 - "Pure-logic gate fixtures (shard 3/8)|failure|install infra: foo~failure"
drive; expect_raise N5a
reset_case; tip_red
jobs "$NEW" 1 - "Pure-logic gate fixtures (shard 3/8)|failure|Infra: apt~failure"
drive; expect_raise N5b
# ── N6 — no colon ──────────────────────────────────────────────────────────
reset_case; tip_red
jobs "$NEW" 1 - "Pure-logic gate fixtures (shard 3/8)|failure|infrastructure check~failure"
drive; expect_raise N6
# ── N7 — the jobs read fails / is not JSON / has no jobs ──────────────────
reset_case; tip_red; echo 1 > "$T/fx/jobs-rc"
drive; expect_raise N7a
reset_case; tip_red; echo 'Pure-logic gate fixtures' > "$T/fx/jobs-$NEW.json"
drive; expect_raise N7b
reset_case; tip_red; echo '{"total_count":0,"jobs":[]}' > "$T/fx/jobs-$NEW.json"
drive; expect_raise N7c
# ── N8 — a truncated jobs list (total_count 40, 30 returned) ──────────────
reset_case; tip_red
set --; for i in $(seq 1 29); do set -- "$@" "job $i|success|step~success"; done
jobs "$NEW" 1 40 "$(infra_job)" "$@"
drive; expect_raise N8
# ── N9 — startup_failure: the run has no jobs at all ──────────────────────
reset_case
runs "$NEW|completed|startup_failure|shaB|40" "$OLD|completed|success|shaA|90"
echo '{"total_count":0,"jobs":[]}' > "$T/fx/jobs-$NEW.json"
drive; expect_raise N9

# ── K1 — MAIN_RED_INFRA_RERUN=0: byte-for-byte today's raise ──────────────
reset_case; tip_red; jobs "$NEW" 1 - "$(infra_job)" "$(green_job)"
echo 'MAIN_RED_INFRA_RERUN=0' > "$T/env/global.env"
drive; expect_raise K1
grep -q "actions/runs/$NEW/jobs?per_page=100" "$T/gh-calls.txt" && bad "K1: the disarmed detector still read the steps ($(ctx))" || ok

# ── H1 — the header documents the knob and -h still ends on --explain ─────
HELP=$(bash "$DIR/bin/main-red-detector.sh" --help); HRC=$?
[ "$HRC" = 0 ] && ok || bad "H1: --help rc $HRC"
grep -q MAIN_RED_INFRA_RERUN <<<"$HELP" && ok || bad "H1: --help does not name MAIN_RED_INFRA_RERUN"
case "$(tail -1 <<<"$HELP")" in *"cannot freeze or unfreeze the fleet by itself."*) ok ;;
  *) bad "H1: --help's last line is not the --explain paragraph's: $(tail -1 <<<"$HELP")" ;; esac

echo "main-red-infra-rerun.bh-2165-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
