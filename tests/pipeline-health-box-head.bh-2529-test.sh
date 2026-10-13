#!/bin/bash
# tests/pipeline-health-box-head.bh-2529-test.sh — BH-2529 (goal-gap B15, file
# state -> DB state): the cost autohalt writes the pause ROW or pages that it
# could not, and the fleet checkout freshness check reads each remote box's
# harness HEAD from box_status instead of ssh-ing into the box.
#
# WHAT IS DRIVEN. bin/pipeline-health.sh's `cost budget` and `fleet checkout
# freshness` blocks, extracted VERBATIM by their own markers (the way every
# other pipeline-health suite drives it), against a scratch tree: the real
# bin/fleet-conf.sh and bin/box-for.sh, a scratch git origin whose commits carry
# pinned dates, and the real bin/lib/jobs/boxes.sh for the box_heads reader.
# ssh is a PATH shim that records every call; alert() and page_critical() record
# to files. Every assertion is on one of those artifacts.
#
# CASES
#   (BH-5526: the breaker's flag is the hold spend-hold-<p>, not paused-<p>.)
#   A1 no jobs client, project at 3x its $/PR budget: no ssh touches the hold
#      flag, no flags/spend-hold-<p> is written anywhere
#   A2 same: pages costhaltfail naming the unwritten hold row; no costhalt page,
#      no state/costhalt re-arm stamp (the next check tries again)
#   A3 zero-merge breaker, no client: the page says the hold row was NOT written
#   A4 flag_set present and answering: costhalt page, stamp written, no ssh
#   B0 box_heads: TSV of reporting boxes only; rc 1 when the worker cannot answer
#   B1 fresh report at origin tip -> no alert
#   B2 fresh report lacking a first-parent main commit older than the grace
#      -> one driftfail alert with the box_status wording
#   B3 the same sha, but reported longer ago than the grace -> logged, no alert
#   B4 main merged a branch whose commits are hours old, minutes ago; the box is
#      on the pre-merge sha -> no alert (first-parent)
#   B5 no row / box_heads fails / box_heads not defined -> logged, no alert
#   B6 no case in section 8 ever calls ssh
#   B7 flags/orchestrator-sync-in-progress fresh + drifted box -> suppressed
#   B8 box_status names the box differently from fleet.conf (box id "project-3",
#      hostname "box-project-3-1" without the generation suffix): it is still
#      judged, and where two rows answer for one box the newest report wins
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pipeline-health-box-head.bh-2529-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export T
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq git awk; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done

NOW=$(date +%s)
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }   # iso <seconds-ago>

mkdir -p "$T/fakebin"
cat > "$T/fakebin/ssh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/calls.ssh"
exit 0
SH
chmod +x "$T/fakebin/ssh"

# ════════════════════════════════════════════════════════════════════════════
# A. the cost autohalt
# ════════════════════════════════════════════════════════════════════════════
awk '/^# >>> cost budget/{f=1;next} /^# <<< cost budget/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/cost.sh"
[ -s "$T/cost.sh" ] && ok || bad "could not extract the cost budget block — markers missing?"

C="$T/c"
cost_fixture() {
  scratch_rm "$C"; mkdir -p "$C/bin/lib" "$C/logs" "$C/flags" "$C/state/cost" "$C/env"
  # busy: $30/PR on 1 PR against a $10 budget (3x: the RATE autohalt).
  # zm:   $400/24h, nothing merged in 24h or 7d (the zero-merge breaker).
  cat > "$C/state/cost/summary.json" <<'JSON'
{"projects":{
  "busy":{"delivery_cost_24h":30,"merged_prs_24h":1,"cost_7d":30,"product_7d":0,"merged_prs_7d":1,"merged_prs_status":"ok"},
  "zm":{"delivery_cost_24h":400,"merged_prs_24h":0,"cost_7d":350,"product_7d":0,"merged_prs_7d":0,"merged_prs_status":"ok"}}}
JSON
  printf 'cost_budget_for() { echo "10 1"; }\ncost_budget_source() { echo fixture; }\n' > "$C/bin/lib/cost-budget.sh"
  echo 0 > "$C/state/costbreaker.stamp"
  # Both projects have a box AND a tailnet address: the old no-client branch
  # would ssh-touch the flag there, which is what A1 must not see.
  printf 'busy Acme/busy - - 1 box-a 10.0.0.1\nzm Acme/zm - - 2 box-b 10.0.0.2\n' > "$C/fleet.conf"
  cp "$DIR/bin/fleet-conf.sh" "$C/bin/"
  : > "$T/alerts.txt"; : > "$T/pages.txt"; rm -f "$T/calls.ssh"
}
drive_cost() { # drive_cost [flagset]   -> $T/alerts.txt, $T/pages.txt
  ( export H="$C" HARNESS="$C" NOW HENV="$C/env" FLEET_CONF="$C/fleet.conf" PATH="$T/fakebin:$PATH" \
           WITH_FLAGSET="${1:-}" JOBS_URL= HARNESS_JOBS_URL=
    bash -c 'STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
             alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
             page_critical() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/pages.txt"; }
             if [ -n "$WITH_FLAGSET" ]; then
               flag_set() { printf "%s %s\n" "$1" "$2" >> "$T/flagset.txt"; return 0; }
             fi
             . "$0"' "$T/cost.sh" ) >"$T/cost.out" 2>&1
}
line() { grep "^[0-9]*|$2|" "$T/$1.txt" 2>/dev/null | head -1; }

# A1 / A2 / A3 — no jobs client
cost_fixture; drive_cost
! grep -q 'spend-hold-\|paused-' "$T/calls.ssh" 2>/dev/null && ok \
  || bad "A1: with no client the halt must not ssh the hold flag anywhere (calls.ssh: $(cat "$T/calls.ssh" 2>/dev/null))"
[ ! -e "$C/flags/spend-hold-busy" ] && [ ! -e "$C/flags/spend-hold-zm" ] && ok \
  || bad "A1: with no client no flags/spend-hold-* file may be written (flags: $(ls "$C/flags"))"
L=$(line pages costhaltfail:busy)
[ -n "$L" ] && grep -q 'hold row could not be written' <<<"$L" && grep -q 'flag_set spend-hold-busy on' <<<"$L" && ok \
  || bad "A2: no client must page costhaltfail naming the unwritten hold row and how to hold it by hand (pages: $(cat "$T/pages.txt"))"
! grep -qi 'unreachable' <<<"$L" && ok || bad "A2: the fail page must not blame an unreachable box ($L)"
[ -z "$(line pages costhalt:busy)" ] && ok || bad "A2: a halt that wrote nothing must not page costhalt"
[ ! -e "$C/state/costhalt/busy" ] && ok || bad "A2: a failed halt must not stamp state/costhalt/busy (the next check retries)"
L=$(line pages costzeromerge:zm)
[ -n "$L" ] && grep -q 'hold row could NOT be written' <<<"$L" && ! grep -q 'NEW BUILDS HELD' <<<"$L" && ok \
  || bad "A3: the zero-merge page must say the hold row was NOT written (got: $L)"

# A4 — flag_set present
cost_fixture; rm -f "$T/flagset.txt"; drive_cost flagset
grep -qx 'spend-hold-busy on' "$T/flagset.txt" 2>/dev/null && ok || bad "A4: the halt must go through flag_set spend-hold-busy on"
[ -n "$(line pages costhalt:busy)" ] && [ -z "$(line pages costhaltfail:busy)" ] && ok \
  || bad "A4: a landed row pages costhalt, not costhaltfail ($(cat "$T/pages.txt"))"
[ -s "$C/state/costhalt/busy" ] && ok || bad "A4: a landed halt stamps state/costhalt/busy"
! grep -q 'spend-hold-\|paused-' "$T/calls.ssh" 2>/dev/null && ok || bad "A4: the client path must not ssh"

# ════════════════════════════════════════════════════════════════════════════
# B0. box_heads — the reader both consumers share
# ════════════════════════════════════════════════════════════════════════════
B0=$( bash -c '. "$1" || exit 9
  _jobs_req() { printf "%s" "{\"boxes\":[{\"box\":\"box-project-4-1\",\"harness_commit\":\"abc1234\",\"harness_reported_at\":\"2026-09-25T20:00:00Z\"},{\"box\":\"box-project-3-2\",\"harness_commit\":null,\"harness_reported_at\":null}]}"; }
  box_heads' _ "$DIR/bin/lib/jobs/boxes.sh" ); RC=$?
[ "$RC" = 0 ] && [ "$B0" = "$(printf 'box-project-4-1\tabc1234\t2026-09-25T20:00:00Z')" ] && ok \
  || bad "B0: box_heads must print one TSV line per box that reported a commit (rc $RC, got: $B0)"
B0=$( bash -c '. "$1" || exit 9; _jobs_req() { return 1; }; box_heads' _ "$DIR/bin/lib/jobs/boxes.sh" ); RC=$?
[ "$RC" = 1 ] && [ -z "$B0" ] && ok || bad "B0: an unanswered GET must be rc 1 with no output, not an empty list (rc $RC)"

# ════════════════════════════════════════════════════════════════════════════
# B. section 8 — fleet checkout freshness from box_status
# ════════════════════════════════════════════════════════════════════════════
awk '/^# >>> fleet checkout freshness/{f=1;next} /^# <<< fleet checkout freshness/{exit} f' \
  "$DIR/bin/pipeline-health.sh" > "$T/fresh.sh"
[ -s "$T/fresh.sh" ] && ok || bad "could not extract the fleet checkout freshness block — markers missing?"
# B6's static half: nothing in the block can reach a box over ssh.
[ -s "$T/fresh.sh" ] && ! grep -q 'ssh' "$T/fresh.sh" && ok || bad "B6: the freshness block must not mention ssh"

# Main's history, dated relative to NOW (grace 5400s):
#   C0 -6h -> C1 -5h (touches bin/c1.sh) -> M -10m, M merging a branch (off C1) dated -3h.
G="$T/g"; mkdir -p "$G"
git init -q --bare "$G/origin.git"
git init -q "$G/src"
gc() { # gc <seconds-ago> <msg> [git-commit args]
  local at="@$(( NOW - $1 ))"; local m="$2"; shift 2
  GIT_AUTHOR_DATE="$at" GIT_COMMITTER_DATE="$at" git -C "$G/src" -c user.name=t -c user.email=t@t \
    commit -q --allow-empty -m "$m" "$@"
}
git -C "$G/src" checkout -q -b main
gc 21600 C0; C0=$(git -C "$G/src" rev-parse --short HEAD)
# C1 changes a fleet path (BH-5247): a box behind it only on docs would be current.
mkdir -p "$G/src/bin"; echo c1 > "$G/src/bin/c1.sh"; git -C "$G/src" add bin/c1.sh
gc 18000 C1; C1=$(git -C "$G/src" rev-parse --short HEAD)
git -C "$G/src" checkout -q -b feat
gc 10800 F1
git -C "$G/src" checkout -q main
GIT_AUTHOR_DATE="@$(( NOW - 600 ))" GIT_COMMITTER_DATE="@$(( NOW - 600 ))" \
  git -C "$G/src" -c user.name=t -c user.email=t@t merge -q --no-ff -m M feat
M=$(git -C "$G/src" rev-parse --short HEAD)
git -C "$G/src" push -q "$G/origin.git" main
git clone -q -b main "$G/origin.git" "$G/co" 2>/dev/null
[ "$(git -C "$G/co" rev-parse --short HEAD)" = "$M" ] && ok || bad "fixture: the hub checkout must sit at origin tip"

F="$T/f"; mkdir -p "$F/bin" "$F/logs" "$F/flags" "$F/state"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$F/bin/"
mkdir -p "$F/bin/lib"; cp "$DIR/bin/lib/cron-lines.sh" "$F/bin/lib/"
scratch_install_closure bin/lib/fleet-paths.sh "$F" >/dev/null || exit 1
printf 'project-4 Acme/project-4 - - 1 box-project-4-1 10.0.0.4\nproject-3 Acme/project-3 - - 2 box-project-3-2 10.0.0.5\n' > "$F/fleet.conf"
# harness-sync must never run: the hub checkout is current in every case.
printf '#!/bin/bash\necho "$*" >> "%s/calls.sync"\n' "$T" > "$F/bin/harness-sync.sh"; chmod +x "$F/bin/harness-sync.sh"

heads() { # heads <project-4 sha> <project-4 seconds-ago> [<project-3 sha> <project-3 seconds-ago>]
  : > "$T/heads.tsv"
  [ -n "${1:-}" ] && printf 'box-project-4-1\t%s\t%s\n' "$1" "$(iso "$2")" >> "$T/heads.tsv"
  [ -n "${3:-}" ] && printf 'box-project-3-2\t%s\t%s\n' "$3" "$(iso "$4")" >> "$T/heads.tsv"
  return 0
}
: > "$T/calls.ssh"   # the cost block's own ceiling sweep above is not section 8
drive_fresh() { # drive_fresh [rows|fail|undef]
  : > "$T/alerts.txt"; : > "$F/logs/pipeline-health.log"
  ( export H="$F" HARNESS="$F" NOW FLEET_CONF="$F/fleet.conf" HARNESS_CHECKOUT="$G/co" \
           PATH="$T/fakebin:$PATH" BH_MODE="${1:-rows}"
    bash -c 'STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
             alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
             case "$BH_MODE" in
               rows) box_heads() { cat "$T/heads.tsv"; } ;;
               fail) box_heads() { return 1; } ;;
             esac
             . "$0"' "$T/fresh.sh" ) >"$T/fresh.out" 2>&1
}
drift() { grep "|driftfail:$1:" "$T/alerts.txt" 2>/dev/null; }
logged() { grep -q "$1" "$F/logs/pipeline-health.log" 2>/dev/null; }

# B1 both boxes at origin tip
heads "$M" 300 "$M" 300; drive_fresh
[ ! -s "$T/alerts.txt" ] && ok || bad "B1: boxes at origin tip must not alert ($(cat "$T/alerts.txt"))"

# B2 project-4 on C0, reported 5 min ago: lacks C1 (5h old) -> one alert
heads "$C0" 300 "$M" 300; drive_fresh
A=$(drift project-4)
[ "$(printf '%s' "$A" | grep -c .)" = 1 ] && ok || bad "B2: a fresh report lacking an old main commit must alert once (alerts: $(cat "$T/alerts.txt"))"
grep -q "^5400|driftfail:project-4:$M|" <<<"$A" && ok || bad "B2: key driftfail:project-4:<origin>, ttl 5400 (got: $A)"
grep -q "box-project-4-1 reports harness at $C0" <<<"$A" && grep -q "lacks origin/main $C1" <<<"$A" \
  && grep -q 'fleet-propagate did not land there' <<<"$A" && ok || bad "B2: the alert must name the reported sha and the missing main commit (got: $A)"
[ -z "$(drift project-3)" ] && ok || bad "B2: the current box must not alert"

# B3 the same sha, reported 3h ago (older than the grace) -> log only
heads "$C0" 10800 "$M" 300; drive_fresh
[ -z "$(drift project-4)" ] && ok || bad "B3: a stale report must not alert ($(cat "$T/alerts.txt"))"
logged 'box-project-4-1 harness HEAD unknown' && ok || bad "B3: a stale report must log 'harness HEAD unknown' ($(cat "$F/logs/pipeline-health.log"))"

# B4 project-4 on C1 (the pre-merge sha) 5 min ago; the merged branch commit is 3h
# old but it is not on main's first-parent line older than the grace
heads "$C1" 300 "$M" 300; drive_fresh
[ -z "$(drift project-4)" ] && ok || bad "B4: a pre-merge sha must not alert after a merge of an old branch ($(cat "$T/alerts.txt"))"

# B4b the grace is a knob: a 10h grace makes C0 the reference, so C0 is fine
heads "$C0" 300 "$M" 300
( export HARNESS_HEAD_GRACE_S=36000; drive_fresh )
[ -z "$(drift project-4)" ] && ok || bad "B4b: HARNESS_HEAD_GRACE_S must move the reference commit ($(cat "$T/alerts.txt"))"

# B5 no row for project-4; box_heads failing; box_heads not defined
heads "" 0 "$M" 300; drive_fresh
[ ! -s "$T/alerts.txt" ] && logged 'box-project-4-1 harness HEAD unknown' && ok \
  || bad "B5: a box with no row must log, not alert (alerts: $(cat "$T/alerts.txt"); log: $(cat "$F/logs/pipeline-health.log"))"
drive_fresh fail
[ ! -s "$T/alerts.txt" ] && logged 'box-project-3-2 harness HEAD unknown' && ok \
  || bad "B5: box_heads failing must log, not alert"
drive_fresh undef
[ ! -s "$T/alerts.txt" ] && logged 'box-project-4-1 harness HEAD unknown' && ok \
  || bad "B5: no jobs client must log, not alert"

# B5b a row with a commit but no report time: `date -d ""` is today's midnight,
# a time nobody reported, so it must read as unknown rather than be judged
printf 'box-project-4-1\t%s\t\n' "$C0" > "$T/heads.tsv"; drive_fresh
[ -z "$(drift project-4)" ] && logged "box-project-4-1 harness HEAD unknown: report time '' unreadable" && ok \
  || bad "B5b: an empty report time must log unreadable, not be judged (alerts: $(cat "$T/alerts.txt"); log: $(cat "$F/logs/pipeline-health.log"))"

# B7 orchestrator sync in progress: drift is logged as suppressed
heads "$C0" 300 "$M" 300; touch "$F/flags/orchestrator-sync-in-progress"; drive_fresh
[ -z "$(drift project-4)" ] && logged 'driftfail:project-4 suppressed' && ok \
  || bad "B7: a fresh orchestrator-sync flag must suppress the page and log it ($(cat "$T/alerts.txt"))"
rm -f "$F/flags/orchestrator-sync-in-progress"

# B8 box_status names the box its own way. project-3 reports as the box id "project-3"
# (behind) -> judged and alerted under fleet.conf's name, not "unknown"
printf 'box-project-4-1\t%s\t%s\nproject-3\t%s\t%s\n' "$M" "$(iso 300)" "$C0" "$(iso 300)" > "$T/heads.tsv"; drive_fresh
[ -n "$(drift project-3)" ] && ! logged 'box-project-3-2 harness HEAD unknown' && ok \
  || bad "B8: a row named by the box id must be matched to fleet.conf's box-project-3-2 (alerts: $(cat "$T/alerts.txt"); log: $(cat "$F/logs/pipeline-health.log"))"
# the hostname without the generation suffix, current -> matched, no alert, not unknown
printf 'box-project-4-1\t%s\t%s\nbox-project-3-1\t%s\t%s\n' "$M" "$(iso 300)" "$M" "$(iso 300)" > "$T/heads.tsv"; drive_fresh
[ ! -s "$T/alerts.txt" ] && ! logged 'box-project-3-2 harness HEAD unknown' && ok \
  || bad "B8: box-project-3-1 must be matched to box-project-3-2 (alerts: $(cat "$T/alerts.txt"); log: $(cat "$F/logs/pipeline-health.log"))"
# two rows for one box: an old one under the fleet name (behind, but its report
# is stale) and a fresh one under the hostname (current) -> the fresh one wins
printf 'box-project-4-1\t%s\t%s\nbox-project-3-2\t%s\t%s\nbox-project-3-1\t%s\t%s\n' \
  "$M" "$(iso 300)" "$C0" "$(iso 20000)" "$M" "$(iso 300)" > "$T/heads.tsv"; drive_fresh
[ ! -s "$T/alerts.txt" ] && ! logged 'box-project-3-2 harness HEAD unknown' && ok \
  || bad "B8: the newest of two rows for one box must win (alerts: $(cat "$T/alerts.txt"); log: $(cat "$F/logs/pipeline-health.log"))"

# B6 — across every section-8 run above
[ ! -s "$T/calls.ssh" ] && ok || bad "B6: section 8 must never ssh (calls.ssh: $(cat "$T/calls.ssh"))"
[ ! -e "$T/calls.sync" ] && ok || bad "fixture: the hub is current, harness-sync must not run"

echo "pipeline-health-box-head: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
