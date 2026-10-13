#!/bin/bash
# tests/main-red-pair-suspected.bh-1451-test.sh — the SUSPECTED FREEZE half of
# BH-1451: bin/main-red-pr-pair.sh raising (and clearing) flags/main-red-<slug>
# when a pair fires and bin/main-red-detector.sh has no verdict of its own,
# plus the per-repo verdict file that makes "has the detector decided?" a
# machine-readable question at all.
#
#   THE BLINDNESS THIS KILLS (2026-09-22). Main was red, the detector could not
#   see it (every run on main was still in flight — see
#   tests/main-red-burst-backwalk.bh-1451-test.sh), and this lane DID know: it
#   raised the PR-pair alert at 12:40Z. By design it wrote no flag, so its
#   knowledge could not stop a merge, and five PRs landed on the red main.
#
#   THE PROPERTY UNDER TEST: a firing pair against a detector that has NOT
#   decided is a suspected red — it holds merges through the same flag every
#   merge lane already reads, carries the shared job and first error into the
#   alert that pages the medic, and is cleared by this lane (and only this lane)
#   when a COMPLETE look finds no pair. Against a detector that HAS looked —
#   decision=red, decision=green, or a verdict file that is simply absent — the
#   lane alerts exactly as it does today and freezes nothing, because a pair can
#   also be one shared flake and a freeze is expensive to be wrong about.
#
# Every timestamp in the PR half is a literal; the detector half pins one NOW
# and derives from it, the shape tests/main-red-tip-red-test.sh uses.
# Run from anywhere: tests/main-red-pair-suspected.bh-1451-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-1939: the scratch tree below carries no lane registry, and main-red-gate.sh
# no longer has a literal default; these are the values a box resolves from
# catalog/lanes.d/_lib.main-red-gate.json.
export MC_MAIN_RED_LABEL=fix-main-red MC_MAIN_RED_TEST_PATHS='tests/* worker/*/test/*'
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

for S in bin/main-red-pr-pair.sh bin/main-red-detector.sh bin/lib/main-red-gate.sh; do
  [ -f "$DIR/$S" ] || {
    echo "FAIL: $S does not exist — there is nothing to test"
    echo "main-red-pair-suspected: 0 passed, 1 failed"; exit 1; }
done
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-pair-suspected: SKIPPED — jq/python3 is not installed"; exit 0; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin"
cp "$DIR/bin/main-red-pr-pair.sh" "$DIR/bin/main-red-detector.sh" "$T/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/main-red-gate.sh" "$T/bin/lib/"
: > "$T/env/global.env"

# lane-alert.sh, recording: one line per send, argv verbatim.
cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# jobs-client.sh, recording. The freeze is not just a local file: the hub has to
# PUBLISH the pause_flags row or no box can see it (BH-945). Both scripts source
# this guarded, so the sink is how this suite proves the row went out.
cat > "$T/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s\n' "$*" >> "${FLAG_SINK:-/dev/null}"; return 0; }
SHIM

# gh shim, serving BOTH lanes. The open-PR list comes from $T/pulls.json; a
# head's runs from $T/runs-<sha>.json; MAIN's runs from $T/mainruns.json,
# sliced at the per_page the caller asked for; a run's failing job from
# $T/jobs-<runid>.txt; one job's log from $T/joblog-<jobid>.txt. An absent
# fixture file means that read FAILED, which is a different fact from an empty
# answer and both lanes are written against the difference.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
A="$*"
printf '%s\n' "$A" >> "$GH_SINK"
PROJ='[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id}]'
case "$A" in
  "api repos/"*" -q .id")     exit 0 ;;
  *"/pulls?state=open"*)      [ -f "$T/pulls-fail" ] && exit 1
                              case "$A" in *" -i "*) printf 'HTTP/2.0 200\r\n\r\n' ;; esac
                              cat "$T/pulls.json" ;;
  "pr list"*)                 [ -f "$T/pulls-fail" ] && exit 1
                              echo "[]" ;;
  *"/actions/jobs/"*"/logs"*) jid=${A##*/actions/jobs/}; jid=${jid%%/logs*}
                              case "$A" in *--allow-escape-sequences*) ;; *) exit 1 ;; esac
                              [ -f "$T/joblog-$jid.txt" ] || exit 1
                              cat "$T/joblog-$jid.txt" ;;
  *"/actions/runs/"*"/jobs"*) rid=${A##*/actions/runs/}; rid=${rid%%/jobs*}
                              cat "$T/jobs-$rid.txt" 2>/dev/null || echo "" ;;
  *"actions/runs"*)           case "$A" in
                                *"branch=main"*)
                                  [ -s "$T/mainruns.json" ] || exit 1
                                  pp=${A##*per_page=}; pp=${pp%% *}
                                  case "$pp" in ''|*[!0-9]*) pp=100 ;; esac
                                  jq -c --argjson pp "$pp" "$PROJ | .[0:\$pp]" "$T/mainruns.json" ;;
                                *)
                                  sha=${A##*head_sha=}; sha=${sha%% *}
                                  [ -s "$T/runs-$sha.json" ] || exit 1
                                  jq -c "$PROJ" "$T/runs-$sha.json" ;;
                              esac ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

CI=".github/workflows/harness-ci.yml"; E2E=".github/workflows/e2e.yml"
MARKS="$T/state/main-red/pairs/o-r"
LEDGER="$T/state/main-red/pr-errors/o-r"
VERDICT="$T/state/main-red/o-r.verdict"
FLAG="$T/flags/main-red-o-r"
LOG="$T/logs/main-red-pr-pair.log"

pulls() { # pulls <number:head-sha:updatedAt>...
  local out='[' first=1 spec num sha upd
  for spec in "$@"; do
    IFS=':' read -r num sha upd <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --argjson n "$num" --arg sha "$sha" --arg u "$upd" \
      '{number:$n, html_url:("https://github.com/o/r/pull/"+($n|tostring)),
        title:"t", body:"", head:{sha:$sha, ref:("b"+($n|tostring))},
        base:{ref:"main"}, draft:false, user:{login:"operator", type:"User"},
        created_at:$u, updated_at:$u, merged_at:null, closed_at:null,
        labels:[], state:"open"}')
  done
  printf '%s]' "$out" > "$T/pulls.json"
}

head_runs() { # head_runs <head-sha> <name|path|conclusion|created_at|run-id[|status]>...
  local sha="$1"; shift
  local out='{"workflow_runs":[' first=1 spec n p c t id s
  for spec in "$@"; do
    IFS='|' read -r n p c t id s <<<"$spec"; s=${s:-completed}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg p "$p" --arg s "$s" --arg t "$t" \
      --argjson id "$id" --arg c "$c" --arg sha "$sha" \
      '{name:$n, path:$p, status:$s, head_sha:$sha,
        conclusion:(if $c=="null" then null else $c end),
        created_at:$t, html_url:("https://github.com/o/r/actions/runs/"+($id|tostring)), id:$id}')
  done
  printf '%s]}' "$out" > "$T/runs-$sha.json"
}
job_of() { printf '%s\t%s\n' "$2" "$3" > "$T/jobs-$1.txt"; }
joblog() { printf '%s\n' "$2"          > "$T/joblog-$1.txt"; }

verdict_file() { # verdict_file <decision> <reason> [sha]
  mkdir -p "$T/state/main-red"
  { echo "decision=$1"; echo "reason=$2"; echo "sha=${3:-}"; echo "at=2026-09-22 12:40:00Z"; } > "$VERDICT"
}

drive() { # drive [args...] — one tick of the real PR-pair lane
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt" FLAG_SINK="$T/flagset.txt"; unset GH_TOKEN
    bash "$T/bin/main-red-pr-pair.sh" "$@" >"$T/out.txt" 2>"$T/err.txt" )
}
drive_detector() { # drive_detector [args...] — one tick of the real detector
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt" FLAG_SINK="$T/flagset.txt"; unset GH_TOKEN
    bash "$T/bin/main-red-detector.sh" "$@" >"$T/out.txt" 2>"$T/err.txt" )
}
alerts()  { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
markers() { ls -A "$MARKS" 2>/dev/null | awk 'END{print NR+0}'; }
reset_case() {
  : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$T/flagset.txt"; : > "$LOG"
  scratch_rm "$T/state/main-red"; rm -f "$T"/flags/main-red-*
  rm -f "$T"/runs-*.json "$T"/jobs-*.txt "$T"/joblog-*.txt "$T/mainruns.json" \
        "$T/pulls-fail" "$T/jobs-fail"
}

# THE PAIR FIXTURE: two open PRs, one job, one first error, 35 seconds apart.
ERRTEXT="FAIL: clock-rolling-window worker/jobs/test/burn.test.js"
pair_fixture() {
  pulls "1:aaaa111:2026-09-22T12:35:00Z" "2:bbbb222:2026-09-22T12:36:00Z"
  head_runs aaaa111 "Harness CI|$CI|failure|2026-09-22T12:30:00Z|9001"
  head_runs bbbb222 "Harness CI|$CI|failure|2026-09-22T12:30:35Z|9002"
  job_of 9001 "Test determinism lint" 8001; joblog 8001 "2026-09-22T12:31:02.1234567Z $ERRTEXT"
  job_of 9002 "Test determinism lint" 8002; joblog 8002 "2026-09-22T12:31:40.7654321Z $ERRTEXT"
}

# ── P1 — the pair fires, the detector has NOT decided: hold merges ──────────
reset_case
verdict_file none no-required
pair_fixture
drive o/r
[ -f "$FLAG" ] && ok || bad "P1: a pair against decision=none must raise the freeze (log: $(cat "$LOG"))"
grep -q '^reason=pr-pair-suspected$' "$FLAG" && ok || bad "P1: the flag must say what raised it: $(cat "$FLAG" 2>/dev/null)"
grep -q '^owner=main-red-pr-pair$'   "$FLAG" && ok || bad "P1: and who owns it: $(cat "$FLAG" 2>/dev/null)"
grep -q '^job=Test determinism lint$' "$FLAG" && ok || bad "P1: and the shared job: $(cat "$FLAG" 2>/dev/null)"
grep -q "^first_error=$ERRTEXT$"     "$FLAG" && ok || bad "P1: and the shared first error: $(cat "$FLAG" 2>/dev/null)"
grep -q '^prs=#1, #2$'               "$FLAG" && ok || bad "P1: and both PR numbers: $(cat "$FLAG" 2>/dev/null)"
# bin/merge-conductor.sh:2910 logs only `head -c 200` of this body, so the field
# that says WHY merges are frozen has to fit inside it.
head -c 200 "$FLAG" | grep -q '^reason=pr-pair-suspected$' && ok \
  || bad "P1: reason= must survive the conductor's head -c 200: $(head -c 200 "$FLAG")"
# the row, not just the file: a freeze no box can see froze nothing (BH-945).
grep -q '^main-red-o-r on' "$T/flagset.txt" && ok \
  || bad "P1: the pause_flags row was never published: $(cat "$T/flagset.txt")"
[ -f "$T/state/main-red/main-red-o-r.published" ] && ok \
  || bad "P1: the published marker (what makes the OFF side self-heal) was not written"

# ── P2 — exactly one critical alert, and it says merges are now held ────────
[ "$(alerts)" = 1 ] && ok || bad "P2: expected exactly one alert: $(cat "$T/alerts.txt")"
grep -q '^--severity critical --id main-red-prs:o-r:' "$T/alerts.txt" && ok \
  || bad "P2: the pair alert must stay critical and id-held: $(cat "$T/alerts.txt")"
grep -q 'Test determinism lint' "$T/alerts.txt" && ok \
  || bad "P2: the alert must carry the shared job: $(cat "$T/alerts.txt")"
grep -q "$ERRTEXT" "$T/alerts.txt" && ok \
  || bad "P2: the alert must carry the shared first error: $(cat "$T/alerts.txt")"
grep -q 'main-red-o-r' "$T/alerts.txt" && ok \
  || bad "P2: the alert must name the freeze it just raised: $(cat "$T/alerts.txt")"
grep -q 'fix-main-red' "$T/alerts.txt" && ok \
  || bad "P2: and the way out of it: $(cat "$T/alerts.txt")"

# ── P6 — the name it raised is the name the MERGE LANES read ────────────────
NAME=$( export HARNESS="$T"; . "$T/bin/lib/main-red-gate.sh"; main_red_flag "" o/r )
[ "$NAME" = "main-red-o-r" ] && ok || bad "P6: the shared gate does not see this freeze: got '$NAME'"

# ── P7 — the exemption is EXACTLY as it is today, neither narrowed nor widened
( export HARNESS="$T"; . "$T/bin/lib/main-red-gate.sh"
  main_red_exempt o/r 7 https://github.com/o/r/pull/7 aaaa111 fix-main-red ) && ok \
  || bad "P7: a fix-main-red PR must still merge through a pr-pair freeze"
( export HARNESS="$T"; . "$T/bin/lib/main-red-gate.sh"
  main_red_exempt o/r 7 https://github.com/o/r/pull/7 aaaa111 merge-queue ) \
  && bad "P7: an ordinary PR must still be held by a pr-pair freeze" || ok

# ── P8 — an INCOMPLETE look clears nothing ─────────────────────────────────
#    PRs 1 and 2 moved to green heads, but PR 3's runs are still in flight, so
#    "no pair here" is an unearned claim and the freeze stands.
: > "$T/alerts.txt"; : > "$LOG"
pulls "1:cccc333:2026-09-22T12:50:00Z" "2:dddd444:2026-09-22T12:51:00Z" "3:eeee555:2026-09-22T12:52:00Z"
head_runs cccc333 "Harness CI|$CI|success|2026-09-22T12:45:00Z|9003"
head_runs dddd444 "Harness CI|$CI|success|2026-09-22T12:46:00Z|9004"
head_runs eeee555 "Harness CI|$CI|null|2026-09-22T12:47:00Z|9005|in_progress"
drive o/r
{ [ -f "$FLAG" ] && [ "$(markers)" = 1 ]; } && ok \
  || bad "P8: an incomplete look cleared a freeze: flag=$([ -f "$FLAG" ] && echo yes) markers=$(markers)"

# ── P5 — the freeze ENDS: a complete look with no pair clears it ────────────
: > "$T/alerts.txt"; : > "$T/flagset.txt"; : > "$LOG"
pulls "1:cccc333:2026-09-22T12:50:00Z" "2:dddd444:2026-09-22T12:51:00Z"
drive o/r
[ ! -f "$FLAG" ] && ok || bad "P5: a complete look with no pair must clear the freeze it raised: $(cat "$FLAG" 2>/dev/null)"
grep -q '^main-red-o-r off' "$T/flagset.txt" && ok \
  || bad "P5: the pause_flags row was never turned off: $(cat "$T/flagset.txt")"
[ -f "$T/state/main-red/main-red-o-r.published" ] \
  && bad "P5: the published marker must go with the row" || ok
[ "$(alerts)" = 1 ] && ok || bad "P5: expected exactly one resolve alert: $(cat "$T/alerts.txt")"
grep -q '^--resolve --id main-red-prs:o-r:' "$T/alerts.txt" && ok \
  || bad "P5: and it is the pair resolve: $(cat "$T/alerts.txt")"

# ── P5b — a freeze this lane does NOT own is never cleared here ─────────────
#    A detector-owned freeze (or a hand-written one) outlives a quiet pair tick.
reset_case
{ echo "sha=bbbb0002"; echo "workflow=Harness CI"; echo "reason=burst"; } > "$FLAG"
BEFORE=$(cat "$FLAG")
pulls "1:cccc333:2026-09-22T12:50:00Z"
head_runs cccc333 "Harness CI|$CI|success|2026-09-22T12:45:00Z|9003"
drive o/r
[ "$(cat "$FLAG" 2>/dev/null)" = "$BEFORE" ] && ok \
  || bad "P5b: the pair lane cleared a freeze it did not raise: $(cat "$FLAG" 2>/dev/null)"

# ── P3 — decision=green: the detector HAS looked. Alert, freeze nothing ─────
reset_case
verdict_file green green
pair_fixture
drive o/r
{ [ "$(alerts)" = 1 ] && [ ! -f "$FLAG" ]; } && ok \
  || bad "P3: a pair against an explicit green verdict must alert and freeze nothing: flag=$(cat "$FLAG" 2>/dev/null)"

# ── P3b — decision=red: already frozen by the detector, nothing rewritten ───
reset_case
verdict_file red tip bbbb0002
{ echo "sha=bbbb0002"; echo "reason=tip"; } > "$FLAG"
BEFORE=$(cat "$FLAG")
pair_fixture
drive o/r
{ [ "$(alerts)" = 1 ] && [ "$(cat "$FLAG")" = "$BEFORE" ]; } && ok \
  || bad "P3b: the detector's own freeze must not be rewritten: $(cat "$FLAG" 2>/dev/null)"

# ── P3c — decision=held: the detector looked and is WAITING on a re-test ───
#    The one verdict this lane must not read as "nobody has looked". A held tick
#    is bin/main-red-detector.sh declining to raise on evidence a run now in
#    flight is about to replace (BH-1281); the pairs that fail alike during that
#    window are the PRs that inherited the red it is re-testing. A freeze here
#    hands that flag to the next detector tick, which sees no sha= in it, calls
#    it its own first red, pages --critical and rewrites the mtime the lift
#    reads — exactly the fight BH-1281 ended, arriving through this lane.
reset_case
verdict_file held re-test f1x00001
pair_fixture
drive o/r
{ [ "$(alerts)" = 1 ] && [ ! -f "$FLAG" ]; } && ok \
  || bad "P3c: a pair against a held verdict must alert and freeze nothing: flag=$(cat "$FLAG" 2>/dev/null)"
grep -q 'decision=held' "$LOG" && ok \
  || bad "P3c: and the log must name the verdict it stood down for: $(cat "$LOG")"

# ── P4 — NO verdict file at all: fail OPEN ─────────────────────────────────
#    A hub still running the old detector, or the five minutes between this
#    deploy and the next conductor tick, must not be able to freeze a repo.
reset_case
pair_fixture
drive o/r
{ [ "$(alerts)" = 1 ] && [ ! -f "$FLAG" ]; } && ok \
  || bad "P4: an ABSENT verdict file must not freeze: flag=$(cat "$FLAG" 2>/dev/null)"
# and the log says WHICH of the two silences this was. "There is no verdict
# file" and "the verdict says the detector has looked" are different facts about
# the hub, and only one of them is worth an operator's attention.
grep -q 'never looked' "$LOG" && ok \
  || bad "P4: the log must say the detector left no verdict at all, not that it had one: $(cat "$LOG")"

# ── P9 — MAIN_RED_PAIR_FREEZE=0 is the kill switch ─────────────────────────
reset_case
verdict_file none no-required
pair_fixture
MAIN_RED_PAIR_FREEZE=0 drive o/r
{ [ "$(alerts)" = 1 ] && [ ! -f "$FLAG" ]; } && ok \
  || bad "P9: MAIN_RED_PAIR_FREEZE=0 must alert exactly as before and freeze nothing: flag=$(cat "$FLAG" 2>/dev/null)"
grep -q 'main-red-o-r' "$T/alerts.txt" \
  && bad "P9: and the alert must not claim a freeze that was not raised: $(cat "$T/alerts.txt")" || ok

# ── P10 — --explain is READ-ONLY, on this path too ─────────────────────────
reset_case
verdict_file none no-required
rm -rf "$T/state/main-red/pairs"
pair_fixture
drive --explain o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ] && [ ! -d "$MARKS" ] && [ ! -s "$T/flagset.txt" ]; } && ok \
  || bad "P10: --explain wrote something: flag=$([ -f "$FLAG" ] && echo yes) marks=$([ -d "$MARKS" ] && echo yes) rows=$(cat "$T/flagset.txt")"
grep -q 'WOULD ALERT' "$T/out.txt" && ok || bad "P10: --explain must still say what it would send: $(cat "$T/out.txt")"

# ── V — the verdict file, one per decision path of bin/main-red-detector.sh ─
#    This is what makes "has the detector decided?" answerable at all, and the
#    freeze above hangs off it, so every path writes one and --explain none.
NOW=$(date +%s)                     # the ONLY clock read in this file
ago() { date -u -d "@$((NOW - $1 * 60))" +%FT%TZ; }
mainruns() { # mainruns <name|path|conclusion|created_at|sha[|status]>... (newest first)
  local out='{"workflow_runs":[' first=1 spec n p c t s sha
  for spec in "$@"; do
    IFS='|' read -r n p c t sha s <<<"$spec"; s=${s:-completed}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg p "$p" --arg s "$s" --arg t "$t" --arg sha "$sha" \
      --arg c "$c" --arg u "https://github.com/o/r/actions/runs/${t//[^0-9]/}" \
      '{name:$n, path:$p, status:$s, conclusion:(if $c=="null" then null else $c end),
        created_at:$t, head_sha:$sha, html_url:$u,
        id:(($t|gsub("[^0-9]";"")) as $d | (if $d=="" then 0 else ($d|tonumber) end))}')
  done
  printf '%s]}' "$out" > "$T/mainruns.json"
}
v_says() { # v_says <decision> <reason> <label>
  grep -q "^decision=$1$" "$VERDICT" 2>/dev/null && grep -q "^reason=$2$" "$VERDICT" 2>/dev/null \
    && ok || bad "V($3): expected decision=$1 reason=$2, got: $(cat "$VERDICT" 2>/dev/null || echo '(no file)')"
}

reset_case                                   # no mainruns.json = the read failed
drive_detector o/r
v_says none no-runs no-runs

reset_case                                   # only a skip-listed workflow: nothing required completed
mainruns "E2E Nightly|$E2E|failure|$(ago 40)|f1f1f1f1"
drive_detector o/r
v_says none no-required no-required

reset_case                                   # the burst shape
mainruns "Harness CI|$CI|null|$(ago 2)|dddd0004|in_progress" \
         "Harness CI|$CI|null|$(ago 10)|cccc0003|in_progress" \
         "Harness CI|$CI|failure|$(ago 20)|bbbb0002" \
         "Harness CI|$CI|success|$(ago 40)|aaaa0001"
drive_detector o/r
v_says red burst burst
grep -q '^sha=bbbb0002$' "$VERDICT" && ok || bad "V(burst): the verdict must carry the deciding sha: $(cat "$VERDICT")"

reset_case                                   # the tip shape
mainruns "Harness CI|$CI|failure|$(ago 40)|f1f1f1f1"
drive_detector o/r
v_says red tip tip

reset_case                                   # green
mainruns "Harness CI|$CI|success|$(ago 10)|a2a2a2a2"
drive_detector o/r
v_says green green green

# BELOW THE STREAK WITH NOTHING GREEN is the one that must NOT read as green:
# one red run, too young for the tip arm, on a tip the burst arm never claims.
# The detector has looked and cannot call it — and this is exactly the tick on
# which the PR-pair lane's own evidence is the only evidence anybody has, so a
# `green` here would silence the freeze above in the case it exists for.
reset_case
mainruns "Harness CI|$CI|failure|$(ago 5)|f1f1f1f1"
drive_detector o/r
v_says none below-streak below-streak
[ ! -f "$FLAG" ] && ok || bad "V(below-streak): nothing should be frozen on this fixture: $(cat "$FLAG")"

# THE HOLD PATH. Two completed reds and the fix's own run in flight one sha up:
# the streak arm holds (BH-1281) and nothing is frozen — but the detector HAS
# looked, and `none` here is what makes the lane above freeze a repo that is
# already being fixed. Its sha is the re-test being waited on, not a judgement.
reset_case
mainruns "Harness CI|$CI|null|$(ago 2)|f1x00001|in_progress" \
         "Harness CI|$CI|failure|$(ago 20)|aaaa1111" \
         "Harness CI|$CI|failure|$(ago 30)|cccc3333" \
         "Harness CI|$CI|success|$(ago 60)|dddd4444"
drive_detector o/r
v_says held re-test held
grep -q '^sha=f1x00001$' "$VERDICT" && ok \
  || bad "V(held): the verdict must name the re-test it is waiting on: $(cat "$VERDICT" 2>/dev/null)"
[ ! -f "$FLAG" ] && ok || bad "V(held): a held tick freezes nothing: $(cat "$FLAG")"

reset_case                                   # and --explain writes none of it
mainruns "Harness CI|$CI|failure|$(ago 40)|f1f1f1f1"
drive_detector --explain o/r
[ ! -d "$T/state/main-red" ] && ok \
  || bad "V(explain): --explain created state/main-red: $(ls -A "$T/state/main-red" 2>/dev/null)"

# ── P11 — the handover: main's history CONFIRMS a suspected freeze ──────────
#    This is the state this build newly makes reachable: a freeze is up, raised
#    by the lane above off PR evidence, so its body carries NO sha= — nobody had
#    judged a run on main yet. The detector then turns red on the same repo.
#    That is its FIRST red call, so it has to page --critical "main is RED".
#    The flag-already-there branch would send the non-critical "STILL RED on a
#    new sha: something landed on main and it did not fix this", and both halves
#    of that sentence are false here — nothing landed, and nobody had called
#    this repo red. The one page a human gets when a suspicion is confirmed is
#    not the place to be wrong about what happened.
reset_case
{ echo "reason=pr-pair-suspected"; echo "owner=main-red-pr-pair";
  echo "job=Test determinism lint"; echo "first_error=$ERRTEXT"; echo "prs=#1, #2";
  echo "since=2026-09-22 12:40:00Z"; } > "$FLAG"
mainruns "Harness CI|$CI|failure|$(ago 40)|f1f1f1f1"
drive_detector o/r
[ "$(alerts)" = 1 ] && ok || bad "P11: expected exactly one alert: $(cat "$T/alerts.txt")"
grep -q '^--critical ' "$T/alerts.txt" && ok \
  || bad "P11: the detector's first red call must page critical: $(cat "$T/alerts.txt")"
grep -q 'main is RED' "$T/alerts.txt" && ok \
  || bad "P11: and with the first-red copy: $(cat "$T/alerts.txt")"
grep -q 'Something landed on main' "$T/alerts.txt" \
  && bad "P11: nothing landed on main, and no fix was ever claimed: $(cat "$T/alerts.txt")" || ok
grep -q '^sha=f1f1f1f1$' "$FLAG" && ok \
  || bad "P11: the flag must now carry the sha the detector judged: $(cat "$FLAG")"
# `since=` is the detector's own ISO run time, not the pair lane's STAMP format
# — every other alert on this path prints an ISO created_at.
grep -qE '^since=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$FLAG" && ok \
  || bad "P11: since= must be the ISO run time, not the pair lane's stamp: $(cat "$FLAG")"
grep -q '^owner=' "$FLAG" \
  && bad "P11: the detector owns this flag now, so the pair lane must not clear it: $(cat "$FLAG")" || ok
grep -q 'confirms a freeze that was already up' "$T/logs/main-red.log" && ok \
  || bad "P11: the log must say the detector took over a freeze it did not raise: $(cat "$T/logs/main-red.log")"

echo "main-red-pair-suspected: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
