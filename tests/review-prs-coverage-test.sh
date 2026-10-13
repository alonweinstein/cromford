#!/bin/bash
# BH-659: the external-PR review lane must cover every project the crontab
# points at it. bin/lib/cron-lines.sh emits `review-prs.sh <project>` for EVERY
# fleet.conf project, so any project the script cannot resolve is a cron firing
# twice an hour that reviews nothing and tells nobody (7 of 11 projects, until
# this suite).
#
# It drives the REAL bin/review-prs.sh against a scratch $HARNESS with `gh`
# stubbed to an empty PR list, so nothing here can reach GitHub or spend a
# review session. What it asserts is artifacts: the script's exit code, what
# landed in logs/ALERTS.log, and what it did (or did not) create under state/
# and locks/.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RP="${RP:-$DIR/bin/review-prs.sh}"
CONF="$DIR/fleet.conf"
FC="$DIR/bin/fleet-conf.sh"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

mkdir -p "$T/fakebin"
# Empty PR list, rc 0: every lane under test stops at "nothing to review".
# It records its argv so a test can ask WHICH repo the lane went to.
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
exit 0
STUB
chmod +x "$T/fakebin/gh"

export GH_LOG="$T/gh-calls.log"

fresh_harness() {
  scratch_rm "$T/h"
  mkdir -p "$T/h/logs" "$T/h/locks" "$T/h/state" "$T/h/env"
  mkdir -p "$T/h/bin" && cp "$DIR/bin/alert-line.sh" "$T/h/bin/"
  : > "$GH_LOG"
}

# run_lane <project> [script] -> sets RC
run_lane() {
  local P="$1" S="${2:-$RP}"
  PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$CONF" \
    bash "$S" "$P" >/dev/null 2>&1
  RC=$?
}

alerts() {
  if [ -f "$T/h/logs/ALERTS.log" ]; then
    wc -l < "$T/h/logs/ALERTS.log" | tr -d ' '
  else
    echo 0
  fi
}

# ── A. coverage: a generated cron line means a project the script handles ────
# Iterates the REAL registry, so a newly loaded project cannot fall through
# silently — it either gets no review-prs cron line, or it runs clean here.
# shellcheck source=bin/lib/cron-lines.sh
. "$DIR/bin/lib/cron-lines.sh"
SEEN=0
while read -r P; do
  [ -n "$P" ] || continue
  OFF=$(FLEET_CONF="$CONF" "$FC" "$P" offset 2>/dev/null)
  PROD=$(FLEET_CONF="$CONF" "$FC" "$P" prod 2>/dev/null)
  cron_project_block "$P" "${OFF:-0}" "$PROD" "$DIR" \
    | grep -q "review-prs\.sh $P\$" || continue
  SEEN=$((SEEN + 1))
  fresh_harness
  run_lane "$P"
  [ "$RC" -eq 0 ] \
    && ok || bad "$P has a review-prs cron line but the lane exits $RC for it"
  [ "$(alerts)" -eq 0 ] \
    && ok || bad "$P has a review-prs cron line but the lane alerted: $(cat "$T/h/logs/ALERTS.log")"
done < <(FLEET_CONF="$CONF" "$FC" --projects)
[ "$SEEN" -ge 1 ] \
  && ok || bad "no project was iterated — an empty registry must not read as covered"

# ── B. an unhandled project pages, loudly, and leaves nothing behind ─────────
fresh_harness
run_lane no-such-project-zz
[ "$RC" -ne 0 ] && ok || bad "an unhandled project exited 0 — a silent no-op"
[ "$(alerts)" -eq 1 ] \
  && ok || bad "an unhandled project wrote $(alerts) ALERTS line(s), expected exactly 1"
grep -q 'no-such-project-zz' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "the ALERTS line does not name the project: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
[ ! -f "$T/h/state/no-such-project-zz.pr-reviews.json" ] \
  && ok || bad "an unhandled project created a review-ledger state file"
[ ! -f "$T/h/locks/review-prs-no-such-project-zz.lock" ] \
  && ok || bad "an unhandled project took the lane's lock"

# ── C. the registry itself unreadable: page, never a quiet 0 ────────────────
# The resolver is gone from BOTH locations the script looks in (no sibling
# bin/fleet-conf.sh, no $HARNESS/bin/fleet-conf.sh), which is the only way to
# make "registry unreadable" deterministic: fleet-conf.sh's own lookup falls
# back to /root/harness/fleet.conf, so on a live box an unreadable $FLEET_CONF
# still answers. Fail-open is the property under test — a lane that cannot ask
# the registry must alert, not decide it has no work.
fresh_harness
mkdir -p "$T/lonebin"
cp "$RP" "$T/lonebin/review-prs.sh"
mkdir -p "$T/lonebin/lib"
cp "$DIR/bin/lib/gh-pr-list.sh" "$T/lonebin/lib/"
PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$T/nope.conf" \
  bash "$T/lonebin/review-prs.sh" cromford >/dev/null 2>&1
RC=$?
[ "$RC" -ne 0 ] && ok || bad "an unreadable registry exited 0 instead of paging"
[ "$(alerts)" -eq 1 ] \
  && ok || bad "an unreadable registry wrote $(alerts) ALERTS line(s), expected exactly 1"
grep -q 'cromford' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "the unreadable-registry ALERTS line does not name the project"
grep -qi 'registry' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "the unreadable-registry ALERTS line does not give the reason: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"

# ── D. handled + idle = quiet (no false alert on the formerly dark projects) ─
fresh_harness
run_lane cromford
[ "$RC" -eq 0 ] && ok || bad "cromford with no open PRs exited $RC"
[ "$(alerts)" -eq 0 ] && ok || bad "cromford with no open PRs alerted"
[ ! -s "$T/h/logs/pr-reviews.log" ] \
  && ok || bad "an idle tick wrote to pr-reviews.log: $(cat "$T/h/logs/pr-reviews.log")"

# ── E. the four originally-handled projects did not regress ────────────────
# The slug each one resolves to is pinned, because that is what moved: it used
# to be a literal in this script and is now a registry column. project-2's
# repo really is spelled "project-2" — a fleet.conf edit that "fixed" the
# typo would point the lane at a repo that does not exist.
while read -r P WANT; do
  fresh_harness
  run_lane "$P"
  [ "$RC" -eq 0 ] && ok || bad "legacy project $P now exits $RC"
  [ "$(alerts)" -eq 0 ] && ok || bad "legacy project $P now alerts"
  grep -q -- "pr list -R $WANT " "$GH_LOG" \
    && ok || bad "legacy project $P no longer reaches $WANT: $(cat "$GH_LOG")"
done <<'LEGACY'
project-1 example-org/project-1
project-2 example-org/project-2
project-3 example-org/project-3
project-4 example-org/project-4
LEGACY

# ── F. no arguments: say what the lane covers, write nothing ────────────────
fresh_harness
USAGE=$(PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$CONF" bash "$RP" 2>&1)
RC=$?
[ "$RC" -eq 2 ] && ok || bad "no-argument run exited $RC, expected 2 (usage)"
grep -q 'usage: review-prs.sh' <<<"$USAGE" \
  && ok || bad "no-argument run printed no usage line: $USAGE"
MISSING=""
while read -r P; do
  [ -n "$P" ] || continue
  # whole-line match: the script's own path contains "cromford", and a
  # substring match would read that as a listing it never printed.
  grep -qxF "$P" <<<"$USAGE" || MISSING="$MISSING $P"
done < <(FLEET_CONF="$CONF" "$FC" --projects)
[ -z "$MISSING" ] \
  && ok || bad "the no-argument listing omits:$MISSING"
[ "$(alerts)" -eq 0 ] && ok || bad "a no-argument run wrote an ALERTS line"

echo "review-prs-coverage: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
