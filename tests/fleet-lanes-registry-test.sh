#!/bin/bash
# tests/fleet-lanes-registry-test.sh — the lanes that gate work and alerts must
# read the registry, and reach EVERY project in it.
#
# On 2026-09-10 nine approved project-7 PRs had sat unmerged for ten days behind
# a four-name regex. The same four names were copied into a dozen other lanes,
# and each one failed the same way: quietly, on the projects it could not name,
# while reporting success. tests/fleet-projects-not-hardcoded-test.sh proves the
# literal lists are GONE; this file proves what replaced them actually resolves
# — a lane can read fleet.conf and still produce the wrong list.
#
# Every assertion here is driven against a FIXTURE registry with a shape the
# original four never had: a project with no board API, a project with no box
# column, and names that are prefixes of each other.
#
# Run from anywhere: tests/fleet-lanes-registry-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

# ── the fixture harness tree ─────────────────────────────────────────────────
F="$T/h"; mkdir -p "$F/bin" "$F/env" "$F/logs" "$F/flags" "$F/state" "$F/builds"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/fleet-projects-or-alert.sh" "$F/bin/"
cat > "$F/fleet.conf" <<'EOF'
alpha-os  Acme/alpha-os  https://alpha.example /api/board         2 box-alpha
beta-os   Acme/beta-os   https://beta.example  /api/feature-board 4 box-beta
gamma     Acme/gamma     -                     -                  6 box-small
zeta-os   Acme/zeta-os   https://zeta.example  /api/board         1
EOF
export FLEET_CONF="$F/fleet.conf"
printf 'ALPHA_INTERNAL_API_TOKEN="tok-alpha"\nALPHA_MIGRATION_TOKEN="mig-alpha"\n' > "$F/env/alpha-os.env"
printf 'ZED_INTERNAL_API_TOKEN=tok-zeta\nZED_MIGRATION_TOKEN=mig-zeta\n' > "$F/env/zeta-os.env"

ALL="alpha-os beta-os gamma zeta-os"
BOARDS="alpha-os beta-os zeta-os"

# list_from <script> <grep-pattern> — evaluate the command substitution on the
# line that builds a script's project list, against the fixture registry. This
# is how a lane whose loop is a one-liner gets driven rather than grepped.
list_from() { # list_from <script> <grep-pattern> [nth-match, default 1]
  local L S N="${3:-1}"
  L=$(grep -- "$2" "$DIR/bin/$1" | sed -n "${N}p") ; [ -n "$L" ] || { echo "__NOLINE__"; return; }
  S=$(sed -E 's/.*(\$\([^)]*\)).*/\1/' <<<"$L")
  [ "$S" = "$L" ] && { echo "__NOSUBST__"; return; }
  HARNESS="$F" H="$F" bash -c "echo $S" 2>/dev/null | tr -s ' '
}

# ── 1. the lanes whose list is a one-line substitution ───────────────────────
eq "quiesce-for-resize pauses every project" \
   "$(list_from quiesce-for-resize.sh 'PROJECTS=\$(')" "$ALL"
eq "poll-commands beats a flags row for every project" \
   "$(list_from poll-commands.sh 'FLAG_PROJECTS=')" "$ALL"
eq "board-invariants sweeps every BOARD project" \
   "$(list_from board-invariants.sh 'PROJECTS=')" "$BOARDS"
eq "tickets-snapshot-push snapshots every BOARD project" \
   "$(list_from tickets-snapshot-push.sh 'BOARD_PROJECTS=')" "$BOARDS"
eq "stale-owed-tickets sweeps every BOARD project" \
   "$(list_from stale-owed-tickets.sh 'BOARD_PROJECTS=')" "$BOARDS"
# gamma has no board API. A sweep that curls "-" as a URL is not a wider sweep,
# it is a broken one, so the board lanes must stop at the registry's own split.
for L in board-invariants.sh tickets-snapshot-push.sh stale-owed-tickets.sh; do
  case "$(list_from "$L" 'PROJECTS=')" in *gamma*) bad "$L includes a project with no board API" ;; *) ok ;; esac
done

# ── 2. metrics-collect.sh, driven end to end ─────────────────────────────────
# The regression in the open: a build for a project the old regex could not name
# landed in metrics.csv with an EMPTY project column, and an empty column reads
# as a project that shipped nothing — which is then reopen-metrics' denominator.
for B in alpha-os-A-12-202609081703 zeta-os-Z-3-202609081703 gamma-G-7-202609081703; do
  mkdir -p "$F/builds/$B"
  echo "PR_MERGED https://github.com/Acme/x/pull/1" > "$F/builds/$B/RESULT"
  echo "2026-09-08 17:03:00Z start" > "$F/builds/$B/pipeline.log"
done
HARNESS="$F" bash "$DIR/bin/metrics-collect.sh" >/dev/null 2>&1
for ROW in "alpha-os-A-12-202609081703,alpha-os,A-12" "zeta-os-Z-3-202609081703,zeta-os,Z-3" "gamma-G-7-202609081703,gamma,G-7"; do
  grep -q "^$ROW," "$F/logs/metrics.csv" && ok \
    || bad "metrics.csv row wrong for ${ROW%%,*} (got: $(grep "^${ROW%%,*}," "$F/logs/metrics.csv"))"
done
grep -q '^[a-z0-9-]*,,' "$F/logs/metrics.csv" && bad "a build landed with an EMPTY project column" || ok

# ── 3. review-rescue.sh: which project owns a stuck build dir ────────────────
awk '/^# >>> build dir project/{f=1;next} /^# <<< build dir project/{exit} f' \
  "$DIR/bin/review-rescue.sh" > "$T/rr.sh"
[ -s "$T/rr.sh" ] && ok || bad "could not extract review-rescue's project parse — markers missing?"
rr() { H="$F" BN="$1" bash -c '. "$0"; printf "%s|%s" "$PROJECT" "$KEY"' "$T/rr.sh" 2>/dev/null; }
eq "review-rescue parses a new project's build dir" "$(rr zeta-os-Z-3-202609081703)" "zeta-os|Z-3"
eq "review-rescue parses an original build dir"     "$(rr alpha-os-A-12-202609081703)" "alpha-os|A-12"
eq "review-rescue refuses a foreign dir"            "$(rr ext-something-1)" "|"

# ── 4. alert-triage.sh: the Sentry-first hint names every owned app ──────────
awk '/^# >>> sentry apps/{f=1;next} /^# <<< sentry apps/{exit} f' \
  "$DIR/bin/alert-triage.sh" > "$T/sa.sh"
[ -s "$T/sa.sh" ] && ok || bad "could not extract alert-triage's Sentry app list — markers missing?"
SA=$(HARNESS="$F" bash -c '. "$0"; printf "%s" "$SENTRY_APPS"' "$T/sa.sh" 2>/dev/null)
for P in $ALL; do
  grep -q "$P" <<<"$SA" && ok || bad "the Sentry-first hint omits $P (got: '$SA')"
done
# With no registry it must point at the orientation map, not name a stale subset
# — a prompt that lists four apps teaches the model those are the only ones.
NF2="$T/nf"; mkdir -p "$NF2/bin"; cp "$DIR/bin/fleet-conf.sh" "$NF2/bin/"
SA0=$(FLEET_CONF="" HARNESS="$NF2" bash -c '. "$0"; printf "%s" "$SENTRY_APPS"' "$T/sa.sh" 2>/dev/null)
[ -n "$SA0" ] && ! grep -q 'alpha-os' <<<"$SA0" && ok \
  || bad "with no registry the Sentry hint must name no project at all (got: '$SA0')"

# ── 5. alerts-supersede.py: PRs on different repos must not collapse ─────────
python3 - "$DIR/bin/alerts-supersede.py" "$F/fleet.conf" <<'PY' > "$T/sup.out" 2>&1
import os, re, subprocess, sys
src = open(sys.argv[1]).read()
os.environ["FLEET_CONF"] = sys.argv[2]
i = src.index("def _fleet_stems():")
j = src.index("\ndef ", src.index("def subject(line):"))
ns = {"os": os, "re": re, "subprocess": subprocess, "sys": sys,
      "__file__": os.path.abspath(sys.argv[1])}
exec(src[i:j], ns)
for line in ["alpha-os PR #128 failed CI", "zeta #128 failed CI",
             "gamma-os build #4412 stuck", "see https://x/y/pull/91", "no project here"]:
    print("%s -> %s" % (line, ns["subject"](line)))
PY
grep -q 'alpha-os PR #128 failed CI -> pr:alpha#128' "$T/sup.out" && ok \
  || bad "alerts-supersede must key a PR subject on project+number: $(cat "$T/sup.out")"
grep -q 'zeta #128 failed CI -> pr:zeta#128' "$T/sup.out" && ok \
  || bad "a PR on a project the old four-name alternation could not see must still key on its project"
grep -q 'gamma-os build #4412 stuck -> pr:gamma#4412' "$T/sup.out" && ok \
  || bad "a project with no -os suffix must still be recognised"
grep -q 'no project here -> None' "$T/sup.out" && ok \
  || bad "a line naming no project must not be given a project subject"

# ── 6. alerts-groom.sh: the migration settle asks about the right project ───
# BH-2526 replaced the ssh hop to the owning box with a coordination-DB read
# (groom_migration_applied, bin/lib/groom-db.sh, pinned end to end by
# tests/alerts-groom-db.bh-2526-test.sh). What this file owns is the registry
# half: the project the DB is asked about comes from fleet.conf, for a row with
# a box column and a legacy row without one alike, and a remote box is never
# reached over ssh.
awk '/# >>> migration pending/{f=1;next} /# <<< migration pending/{exit} f' \
  "$DIR/bin/alerts-groom.sh" > "$T/mp.sh"
[ -s "$T/mp.sh" ] && ok || bad "could not extract alerts-groom's migration probe — markers missing?"
mkdir -p "$T/stub"
cat > "$T/stub/ssh" <<EOF
#!/bin/bash
# Any ssh at all is the regression: record it and answer 0 pending, so a probe
# that still hops would settle and be caught by the log check below.
cat >/dev/null
printf '%s\n' "\$*" >> "$T/ssh.log"
echo 0
EOF
chmod +x "$T/stub/ssh"
# groom_ask/hold_unknown live outside the markers; the DB helper is stubbed to
# record its arguments and answer $MIG_ANSWER.
groom() { PATH="$T/stub:$PATH" HARNESS="$F" SETTLED="" LINE="$1" MIG_ANSWER="${2:-applied}" \
  ASK_LOG="$T/ask.log" bash -c '
    groom_ask() { GROOM_OUT="unknown no-lib"; declare -F "$1" >/dev/null 2>&1 && "$@"; return 0; }
    hold_unknown() { :; }
    groom_migration_applied() { printf "%s %s\n" "$1" "$2" >> "$ASK_LOG"; GROOM_OUT="$MIG_ANSWER"; }
    . "$0"; printf "%s" "${SETTLED:-none}"' "$T/mp.sh" 2>/dev/null; }
: > "$T/ssh.log"; : > "$T/ask.log"
eq "an alpha migration ping settles when the DB shows it applied" \
   "$(groom '[alpha-os] MIGRATION-PR merged: #128 (add t) — confirm SQL applied to prod')" "migration-applied"
grep -qx 'alpha-os 128' "$T/ask.log" && ok \
  || bad "the DB must be asked about the registry project and the PR number (log: $(cat "$T/ask.log"))"
: > "$T/ask.log"
# A project with no box column: resolved from the registry all the same.
eq "a legacy row still gets asked" \
   "$(groom '[zeta-os] MIGRATION-PR merged: #7 (add t) — confirm SQL applied to prod')" "migration-applied"
grep -qx 'zeta-os 7' "$T/ask.log" && ok \
  || bad "a row with no box column must still resolve its project (log: $(cat "$T/ask.log"))"
eq "a remote box the DB has no APPLIED for stays open" \
   "$(groom '[alpha-os] MIGRATION-PR merged: #129 (add t) — confirm SQL applied to prod' none)" "none"
[ ! -s "$T/ssh.log" ] && ok \
  || bad "the migration settle must never ssh to a box (log: $(cat "$T/ssh.log"))"
eq "an unrecognised line settles nothing" "$(groom 'MIGRATION-PR merged somewhere')" "none"

# ── 7. bootstrap-machine.sh: the registry is the registry, not a fallback ────
OUT=$(HARNESS="$F" bash "$DIR/bin/bootstrap-machine.sh" not-a-project 2>&1); RC=$?
[ "$RC" != 0 ] && ok || bad "bootstrapping an unregistered project must fail, not proceed"
grep -q 'no fleet.conf row' <<<"$OUT" && ok \
  || bad "the failure must say the registry row is missing (got: '$OUT')"

# ── 8. refresh-catalog.sh names every project to survey ─────────────────────
CAT=$("$DIR/bin/refresh-catalog.sh" 2>/dev/null)
for P in $("$DIR/bin/fleet-conf.sh" --projects); do
  grep -q "$P" <<<"$CAT" && ok || bad "refresh-catalog does not list $P for survey"
done

# ── 9. AN EMPTY REGISTRY IS LOUD, NOT AN EMPTY SWEEP ────────────────────────
# `for P in $(fleet-conf.sh --projects)` is correct every day the registry is
# readable, and on the day it is not it iterates zero times, finishes, and
# reports success. That is the wave's own failure at fleet scale: every project
# missing at once instead of five. quiesce-for-resize.sh is the sharp end — it
# has no `set -e`, so it could print SAFE_TO_RESIZE having paused nobody.
NR="$T/noreg"; mkdir -p "$NR/bin" "$NR/logs" "$NR/flags" "$NR/state" "$NR/builds" "$NR/env" "$NR/locks"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/fleet-projects-or-alert.sh" "$NR/bin/"
cp "$DIR/bin/alert-line.sh" "$NR/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
noreg() { FLEET_CONF="" HARNESS="$NR" H="$NR" "$@" 2>/dev/null; }

# The helper itself: rc=1, a named ALERTS line, and NEVER an empty list at rc=0.
noreg "$NR/bin/fleet-projects-or-alert.sh" some-lane >/dev/null && bad "the guard must exit non-zero on an empty registry" || ok
grep -q '\[some-lane\] fleet.conf gave an EMPTY project list' "$NR/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "the guard must name the lane in ALERTS.log (got: $(cat "$NR/logs/ALERTS.log" 2>/dev/null))"
# Deduped per lane per day — these crons run as often as every minute.
B=$(wc -l < "$NR/logs/ALERTS.log")
noreg "$NR/bin/fleet-projects-or-alert.sh" some-lane >/dev/null
[ "$(wc -l < "$NR/logs/ALERTS.log")" = "$B" ] && ok || bad "the guard re-alerted within the same day"
# …but a DIFFERENT lane still gets its own line: one broken lane must not
# silence the next one.
noreg "$NR/bin/fleet-projects-or-alert.sh" other-lane >/dev/null
grep -q '\[other-lane\]' "$NR/logs/ALERTS.log" && ok || bad "the dedup is fleet-wide, not per lane"

# quiesce: refuses, says so in its OWN log, and pauses nothing.
awk '/# >>> pause all/{f=1;next} /# <<< pause all/{exit} f' "$DIR/bin/quiesce-for-resize.sh" > "$T/q.sh"
[ -s "$T/q.sh" ] && ok || bad "could not extract quiesce's pause block — markers missing?"
QOUT=$(FLEET_CONF="" H="$NR" LOG="$NR/logs/quiesce.log" \
  bash -c 'STAMP(){ echo TS; }; . "$0"; echo REACHED_END' "$T/q.sh" 2>/dev/null)
grep -q REACHED_END <<<"$QOUT" && bad "quiesce continued past an empty project list — SAFE_TO_RESIZE would follow" || ok
[ -z "$(ls -A "$NR/flags" 2>/dev/null | grep '^paused-')" ] && ok || bad "quiesce paused something from an empty list"
grep -q 'NOT safe to resize' "$NR/logs/quiesce.log" 2>/dev/null && ok \
  || bad "quiesce must say why it stopped in its own log"

# metrics-collect: refuses rather than writing rows with a blank project column
# and marking them seen, which is unrecoverable — those builds are never revisited.
mkdir -p "$NR/builds/alpha-os-A-1-202609081703"
echo "PR_MERGED https://github.com/Acme/x/pull/1" > "$NR/builds/alpha-os-A-1-202609081703/RESULT"
noreg bash "$DIR/bin/metrics-collect.sh" >/dev/null && bad "metrics-collect must refuse an empty registry" || ok
[ ! -s "$NR/logs/metrics.csv" ] || ! grep -q '^alpha-os-A-1' "$NR/logs/metrics.csv" && ok \
  || bad "metrics-collect wrote a row with no project and marked it seen"
[ ! -s "$NR/state/metrics-seen.txt" ] && ok || bad "metrics-collect marked builds seen despite refusing"

# The board lanes and review-rescue refuse too, driven for real.
# TEST-CHANGE: BH-3321 — tickets-snapshot-push exits before its registry read
# when WATCHDOG_URL is unset or bin/lib/watchdog-url.sh is absent.
mkdir -p "$NR/bin/lib"; cp "$DIR/bin/lib/watchdog-url.sh" "$NR/bin/lib/"
for L in tickets-snapshot-push stale-owed-tickets board-invariants review-rescue; do
  FLEET_CONF="" HARNESS="$NR" H="$NR" HARNESS_SECRET=x WATCHDOG_URL=http://watchdog.invalid \
    bash "$DIR/bin/$L.sh" >/dev/null 2>&1 && bad "$L must refuse an empty registry" || ok
done
grep -q '\[tickets-snapshot\]' "$NR/logs/ALERTS.log" && ok || bad "tickets-snapshot-push did not alert"
grep -q '\[stale-owed\]' "$NR/logs/ALERTS.log" && ok || bad "stale-owed-tickets did not alert"
grep -q '\[board-invariants\]' "$NR/logs/ALERTS.log" && ok || bad "board-invariants did not alert"
grep -q '\[review-rescue\]' "$NR/logs/ALERTS.log" && ok || bad "review-rescue did not alert"
# preplan-tick and alerts-groom cannot be driven to the guard on this host —
# preplan exits early unless a run-build is in flight, and alerts-groom needs
# flock plus a live console — so their guard is checked STRUCTURALLY: it must
# exist, and it must run BEFORE the first project resolution, which is the only
# property that matters. (Same shape as the ordering assertions in
# tests/rollup-crash-loud-test.sh.)
for L in preplan-tick alerts-groom; do
  G=$(grep -n '"$HARNESS/bin/fleet-projects-or-alert.sh"' "$DIR/bin/$L.sh" | head -1 | cut -d: -f1)
  # non-comment lines only: the guard's own comment mentions project-of.sh
  U=$(grep -n '"$HARNESS/bin/project-of.sh"' "$DIR/bin/$L.sh" | head -1 | cut -d: -f1)
  [ -n "$G" ] && [ -n "$U" ] && ok || bad "$L: could not locate guard=$G and first use=$U"
  [ -n "$G" ] && [ -n "$U" ] && [ "$G" -lt "$U" ] && ok \
    || bad "$L resolves a project before checking the registry is readable (guard=$G use=$U)"
done
# alerts-supersede.py is the one deliberate exception to the ALERTS.log rule: it
# writes its degraded-mode notice to STDERR (which alerts-groom tees into its
# own log) because a lane whose job is grooming the alert feed must never write
# into the feed it reads — that is the alert-loop shape, not a guard.
grep -q 'file=sys.stderr' "$DIR/bin/alerts-supersede.py" && ok \
  || bad "alerts-supersede.py must announce a disabled extractor on stderr"
grep -q 'ALERTS.log' "$DIR/bin/alerts-supersede.py" \
  && bad "alerts-supersede.py must not write into the alert feed it grooms" || ok
# alert-triage keeps running on a degraded prompt (the alert list is the point
# of the lane), but must SAY the hint names no app.
awk '/# >>> sentry apps/{f=1;next} /# <<< sentry apps/{exit} f' "$DIR/bin/alert-triage.sh" > "$T/sa0.sh"
FLEET_CONF="" HARNESS="$NR" bash -c 'STAMP(){ echo TS; }; . "$0"' "$T/sa0.sh" >/dev/null 2>&1
grep -q '\[alert-triage\] fleet.conf gave an EMPTY project list' "$NR/logs/ALERTS.log" && ok \
  || bad "alert-triage must announce a degraded Sentry hint rather than run quietly"
# review-rescue must refuse BEFORE it can mark a build permanently rescued.
[ -z "$(find "$NR/builds" -name .review-rescued 2>/dev/null)" ] && ok \
  || bad "review-rescue retired a build while the registry was unreadable"

# ── 10. THE TOKEN IS CHOSEN, NOT GUESSED ────────────────────────────────────
# The board lanes read a project's internal API token out of its env file. The
# variable NAME differs per project and is not derivable from the project name
# (project-2 uses PROJECT_2_, project-8 uses IA_), and fleet.conf has no
# column for it — so the lanes match on the *_INTERNAL_API_TOKEN suffix.
#
# "First matching line" is fine on today's env files (each carries exactly one)
# and silently wrong the day one carries two: the sweep would authenticate with
# whichever happened to be first, get a 401, and log "board list failed" — a
# credential bug wearing an outage's clothes. So exactly one match is a token;
# zero or many is an ALERTS line naming the file and a skipped project.
TK="$T/tok"; mkdir -p "$TK/bin" "$TK/env" "$TK/logs" "$TK/flags"
cp "$DIR/bin/internal-token-for.sh" "$TK/bin/" 2>/dev/null || true
mkdir -p "$TK/bin/lib"; cp "$DIR/bin/lib/internal-token.sh" "$TK/bin/lib/" 2>/dev/null || true
[ -x "$TK/bin/internal-token-for.sh" ] && ok || bad "bin/internal-token-for.sh is missing"
printf 'ALPHA_INTERNAL_API_TOKEN="tok-alpha"\nOTHER=x\n'        > "$TK/env/alpha-os.env"
printf 'export PROJECT_2_INTERNAL_API_TOKEN=tok-beta\n'                 > "$TK/env/beta-os.env"
printf 'OLD_INTERNAL_API_TOKEN=stale\nZED_INTERNAL_API_TOKEN=live\n' > "$TK/env/zeta-os.env"
printf 'SOMETHING_ELSE=1\n'                                      > "$TK/env/gamma.env"
tok() { HARNESS="$TK" "$TK/bin/internal-token-for.sh" "$1" 2>/dev/null; }
eq "one token, quoted"            "$(tok alpha-os)" "tok-alpha"
eq "one token, exported+unquoted" "$(tok beta-os)"  "tok-beta"
# A NEIGHBOURING variable whose name merely starts with the same prefix is not a
# second token. Counting it would refuse a project whose env file is fine, and
# the two passes (count, extract) would be disagreeing about what a token is.
printf 'PROJECT_3_INTERNAL_API_TOKEN="tok-project-3"\nproject-3_INTERNAL_API_TOKEN_OLD=junk\n' > "$TK/env/delta.env"
eq "a prefix-sharing neighbour is not a second token" "$(tok delta)" "tok-project-3"
# TWO tokens: refuse. Picking the first is how a rotated-but-not-removed stale
# token becomes the one the sweep authenticates with.
eq "two tokens is a refusal, not a coin flip" "$(tok zeta-os)" ""
tok zeta-os >/dev/null && bad "two tokens must exit non-zero" || ok
grep -q 'zeta-os.env' "$TK/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "an ambiguous env file must be NAMED in ALERTS.log (got: $(cat "$TK/logs/ALERTS.log" 2>/dev/null))"
grep -qE 'OLD_INTERNAL_API_TOKEN.*ZED_INTERNAL_API_TOKEN|ZED_INTERNAL_API_TOKEN.*OLD_INTERNAL_API_TOKEN' \
  "$TK/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "the alert must name BOTH variables so the fix is obvious, without printing their values"
grep -q 'SECRETVALUE' "$TK/logs/ALERTS.log" 2>/dev/null \
  && bad "the alert must never print a token VALUE" || ok
# ZERO tokens: also a refusal, also named. A project silently skipped for want
# of a credential looks exactly like a project with nothing to report.
tok gamma >/dev/null && bad "a missing token must exit non-zero" || ok
grep -q 'gamma.env' "$TK/logs/ALERTS.log" 2>/dev/null && ok || bad "a missing token must be named in ALERTS.log"
# Deduped per project per day, like every other daily alert here.
BT=$(wc -l < "$TK/logs/ALERTS.log")
tok zeta-os >/dev/null; tok gamma >/dev/null
[ "$(wc -l < "$TK/logs/ALERTS.log")" = "$BT" ] && ok || bad "the token alert re-fired within the same day"

# The three board lanes must all resolve their token through it, so the rule is
# in one place rather than three greps that drift apart.
for L in board-invariants stale-owed-tickets tickets-snapshot-push; do
  grep -q 'internal-token-for.sh' "$DIR/bin/$L.sh" && ok \
    || bad "$L still picks a token with its own grep"
  grep -qE "grep .*INTERNAL_API_TOKEN.*head -1|head -1.*INTERNAL_API_TOKEN" "$DIR/bin/$L.sh" \
    && bad "$L still has a first-match token grep" || ok
done

echo "fleet-lanes-registry-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
