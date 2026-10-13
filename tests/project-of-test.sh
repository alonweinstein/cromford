#!/bin/bash
# tests/project-of-test.sh — bin/project-of.sh, the one place that answers
# "which fleet project does this string name?".
#
# Before this existed the question was answered by four hand-written copies:
# `^(project-1|project-2|project-3|project-4)-os` in metrics-collect.sh, `*"$P"-*` over a
# four-name loop in review-rescue.sh, `grep -qi "${p%-os}"` in preplan-tick.sh,
# and `\[(project-1|project-2|project-3)` in poll-commands.sh. Each answered
# "no project" for everything enrolled after the original four, and each failure
# was silent in its own way: a metrics row with an empty project column, a
# review marked rescued without being rescued, a ticket never pre-planned, an
# alert routed to the General topic.
#
# Because every one of those lanes now routes through this script, its edge
# cases are the fleet's edge cases — so they are pinned here rather than in each
# caller.
#
# Run from anywhere: tests/project-of-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/fleet.conf" <<'EOF'
alpha-os   Acme/alpha-os  https://alpha.example /api/board 2 box-alpha
beta-os    Acme/beta-os   https://beta.example  /api/board 4 box-beta
gamma      Acme/gamma     -                     -          6 box-small
sib        Acme/sib       -                     -          5 box-small
sib-nav    Acme/sib-nav   -                     -          7 box-small
ledger-os  Acme/books     -                     -          8 box-small
EOF
po() { FLEET_CONF="$T/fleet.conf" "$DIR/bin/project-of.sh" "$@" 2>/dev/null; }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

# --- repository identity: names are independent of project identifiers ------
eq "registered repository alias" "$(po --repo Acme/books)" "ledger-os"
eq "repository case is ignored" "$(po --repo ACME/BOOKS)" "ledger-os"
eq "canonical repository" "$(po --repo Acme/alpha-os)" "alpha-os"
eq "unregistered owner cannot claim a project" "$(po --repo Other/alpha-os)" ""
eq "repository suffix cannot claim a project" "$(po --repo Acme/books-extra)" ""
eq "a bare project is not a repository" "$(po --repo alpha-os)" ""
po --repo Acme/missing >/dev/null 2>&1 && bad "unknown repository must exit non-zero" || ok
# Drive the actual resolver discovery function with only its external readers
# stubbed. An alias must reach the candidate stream under its registered name.
discovered=$(
  export FLEET_CONF="$T/fleet.conf"
  H="$DIR"; ONLY=ledger-os
  source <(sed -n '/^br_conductor_emit() {/,/^}/p' "$DIR/bin/blocked-resolver.sh")
  mc_record_for() { printf '%s' -; }
  # main reads the head branch through br_pr_field (gh_rest), not `gh pr view`.
  br_pr_field() { printf '%s' ticket/L-1; }
  gh() { echo 'unstubbed gh call' >&2; return 1; }
  br_ticket_key() { printf 'L-1\tbranch'; }
  say() { :; }
  br_key_source_phrase() { printf '%s' branch; }
  br_rkey() { printf '%s' "${1//[^A-Za-z0-9._-]/-}"; }
  br_tkey_sync() { printf '%s' "$3"; }
  br_conductor_emit 'Acme/books#531' conflict-unresolvable https://github.com/Acme/books/pull/531
)
# The 8th field is the park epoch (BH-1122); absent here, so it reads '-'.
eq "resolver discovers an aliased repository" "$discovered" \
   $'conductor\tledger-os\tAcme-books-531\tconflict-unresolvable\thttps://github.com/Acme/books/pull/531\t-\tL-1\t-'

# --- --prefix: build-dir names ----------------------------------------------
eq "build dir"          "$(po --prefix alpha-os-A-12-202609081703)" "alpha-os"
eq "no -os suffix"      "$(po --prefix gamma-G-1-202609081703)"     "gamma"
# The collision that makes "longest first" load-bearing: builds/sib-nav-* also
# starts with "sib-", so a shorter name that prefixes a longer one would claim
# every one of the longer one's builds.
eq "prefix collision"   "$(po --prefix sib-nav-N-4-2026)"          "sib-nav"
eq "the short one too"  "$(po --prefix sib-S-2-2026)"              "sib"
eq "bare project name"  "$(po --prefix sib)"                       ""
eq "not a project"      "$(po --prefix nope-X-1)"                  ""
# THE ONE PREFIX THAT IS STRIPPED: pool-. A relayed pool build dir is named
# pool-<project>-<KEY>-<stamp> and genuinely BELONGS to <project> — it is the
# hub's own copy marker, not another sweep's namespace. On 2026-09-13 thirty-nine
# stranded pool builds asked this script about "pool-project-5-TK-551-…", got
# "no project", and review-rescue.sh retired every one of them unrescued.
#
# TEST-CHANGE: the line below used to assert pool-alpha-os-… -> "" under the
# heading "mid-string is not a prefix". That assertion was right about mq-* and
# wrong about pool-*: bin/reconcile-prs.sh already had to strip `pool-` by hand
# before calling here, which is the tell that the contract, not the caller, was
# wrong. The mq-*/ext-* half of the rule is kept verbatim below.
eq "a pool build dir names its project"  "$(po --prefix pool-alpha-os-A-1-2026)" "alpha-os"
eq "pool- respects the collision rule"   "$(po --prefix pool-sib-nav-N-4-2026)"  "sib-nav"
eq "pool- alone is not a project"        "$(po --prefix pool-nope-X-1)"          ""
# Every OTHER project named only in the MIDDLE is still not this build's project
# — mq-* and ext-* records belong to other sweeps, and claiming them would move
# work.
eq "mid-string is not a prefix" "$(po --prefix mq-alpha-os-A-1-2026)" ""

# --- default: a project mentioned anywhere ----------------------------------
eq "bracketed tag"   "$(po '[alpha-os] STUCK rc=1')"                   "alpha-os"
eq "stem only"       "$(po 'MIGRATION-PR merged for beta, 0 pending')" "beta-os"
eq "case-insensitive" "$(po 'Alpha-OS watcher exited')"                "alpha-os"
eq "inside a url"    "$(po 'https://github.com/Acme/gamma/pull/12')"   "gamma"
eq "no project"      "$(po 'OpenRouter key down to $3 of $50')"        ""
# A full name anywhere beats a stem anywhere. Otherwise an alert that mentions
# "sib" in passing while being about sib-nav routes to the wrong project.
eq "full name beats stem" "$(po 'sib-nav build failed on the alpha box')" "sib-nav"

# --- THE SUBJECT IS THE FIRST NAME, NOT THE LONGEST -------------------------
# Two projects share one box, so the box NAME carries a project name inside it.
# Resolving by name length picked the longer one wherever it appeared, which is
# how "[gamma] watcher on box-alpha-os exited rc=1" resolves to
# alpha-os: alerts-groom step 4 then tails ALPHA's watcher log for a GAMMA
# alert, and one healthy alpha cycle closes a live gamma alert. An alert line
# names its subject first and its context after, so the earliest match wins.
eq "the subject wins over a longer name in the context" \
   "$(po '[gamma] watcher on box-alpha-os exited rc=1')" "gamma"
eq "…and the same line the other way round" \
   "$(po '[alpha-os] watcher on the gamma box exited rc=1')" "alpha-os"
# A shared box name on its own still resolves to the project it names — this is
# only about which of TWO candidates wins, never about matching fewer lines.
eq "a bare box name still resolves" "$(po 'box-alpha ran out of disk')" "alpha-os"
# Earliest must not undo the collision rule: at the SAME offset, longest wins.
eq "tie at offset 0 goes to the longer name" "$(po 'sib-nav-N-4 failed')" "sib-nav"
# The honest limit of "earliest wins": when two FULL names appear and the first
# one is context rather than subject, the first one still wins. That is the
# deliberate trade — an alert line names its subject first far more often than
# it opens with an aside — and it is a strictly smaller error than the old rule,
# which got the common shape wrong every single time instead of the rare one.
eq "earliest wins even when a longer name follows" \
   "$(po 'the sib box is fine, sib-nav is not')" "sib"
# The two passes stay ordered regardless: a FULL name anywhere still beats a
# stem anywhere, so offset only ever breaks ties within one pass.
eq "a full name later still beats a stem earlier" \
   "$(po 'the alpha box is fine, sib-nav is not')" "sib-nav"

# --- exit codes: no match is rc=1, so callers can `|| echo ""` --------------
po --prefix nope-X-1 >/dev/null 2>&1 && bad "an unmatched prefix must exit non-zero" || ok
po 'nothing here'    >/dev/null 2>&1 && bad "an unmatched mention must exit non-zero" || ok
po --prefix alpha-os-A-1 >/dev/null 2>&1 && ok || bad "a match must exit zero"

# --- an unreadable registry is rc=1, never a wrong answer -------------------
mkdir -p "$T/iso/bin"; cp "$DIR/bin/project-of.sh" "$DIR/bin/fleet-conf.sh" "$T/iso/bin/"
FLEET_CONF="" "$T/iso/bin/project-of.sh" --prefix alpha-os-A-1 >/dev/null 2>&1 \
  && bad "with no registry project-of must exit non-zero" || ok

# --- the LIVE registry: every project resolves from its own build-dir name ---
# This is the assertion the four hand-written copies would have failed on
# 2026-09-10, project-7 included.
for P in $("$DIR/bin/fleet-conf.sh" --projects); do
  G=$("$DIR/bin/project-of.sh" --prefix "$P-KEY-1-202609081703" 2>/dev/null)
  [ "$G" = "$P" ] && ok || bad "live registry: $P-KEY-… resolved to '$G'"
  G=$("$DIR/bin/project-of.sh" "[$P] something happened" 2>/dev/null)
  [ "$G" = "$P" ] && ok || bad "live registry: an alert tagged [$P] resolved to '$G'"
done
# THE LIVE SHARED-BOX CASE. project-7 and project-6 are both watched by
# box-project-6-1, so every project-7 watcher alert carries the string
# "project-6" in it. This is the line that made the old rule dangerous.
eq "live: a project-7 alert naming the shared box resolves to project-7" \
   "$("$DIR/bin/project-of.sh" '[project-7] watcher on box-project-6-1 exited rc=1')" "project-7"
eq "live: the same line for project-6 still resolves to project-6" \
   "$("$DIR/bin/project-of.sh" '[project-6] watcher on box-project-6-1 exited rc=1')" "project-6"
for P in project-7 project-6 project-5 project-9 project-8; do
  "$DIR/bin/fleet-conf.sh" "$P" repo >/dev/null 2>&1 || { bad "$P is not in fleet.conf"; continue; }
  [ "$("$DIR/bin/project-of.sh" --prefix "$P-K-1-2026")" = "$P" ] && ok \
    || bad "$P — the class of project the old four-name regexes could not see"
done

echo "project-of-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
