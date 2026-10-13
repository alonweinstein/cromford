#!/bin/bash
# tests/concurrency-plan-test.sh — one readable build ceiling per project.
#
# WHY THIS EXISTS (the operator, 2026-09-12). "The DB says repo/*/build = 1, so how did
# project-5 run twelve builds at once?" took three files and an ssh hop to
# answer, and the answer was that nothing was wrong: worker/jobs/schema.sql
# SEEDS 1 with INSERT OR IGNORE and the live row had been raised to 20 the same
# morning. The seed is what a reader finds; the row is what binds. That gap is
# the defect — not a bypass.
#
# Five files hold a cap on how many builds one project may run:
#
#   concurrency_rules repo/<p>/build   the fleet-wide DB rule (worker enforces)
#   fly/pool-caps.conf                 how many pool machines may live
#   flags/wip-limit-<p>                per-project local builds
#   flags/build-slots                  box-wide local build slots
#   concurrency_rules box/*/build      the fleet-wide per-box rule
#
# ...and which of them APPLIES depends on how the project is routed, because
# bin/run-build.sh returns QUEUED_FLY above the wip gate, above the slot flock
# and above job_open. A fly-routed project is not gated by any local number at
# all, which is exactly the mistake tests/free-slots-test.sh already caught once
# in the other direction. So the table is not "print five numbers": it is "print
# which ones bind, and the smallest".
#
# DRIVEN, not grepped: the plan is run against scratch HARNESS trees whose
# flags, pool-caps.conf and rules TSV have really been shaped like a box's, and
# the assertions are about the number it concludes. The last blocks ARE greps and
# say so — the claim there is that bin/fly-dispatch.sh no longer carries its own
# copy of the dispatcher wip, which is a text claim about a second constant.
#
# Run from anywhere: tests/concurrency-plan-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/flags" "$H/fly" "$H/env"
for f in concurrency-plan.sh concurrency-apply.sh account-capacity.sh pool-cap.sh; do
  cp "$DIR/bin/$f" "$H/bin/" 2>/dev/null
done
cp "$DIR/bin/lib/build-caps.sh" "$H/bin/lib/" 2>/dev/null
chmod +x "$H/bin/"*.sh 2>/dev/null

# fleet.conf: the project registry the plan iterates. Two projects is enough to
# prove the per-project answer is per-project; the real file has ten.
cat > "$H/fleet.conf" <<'EOF'
# <project> <repo> <prod> <board-prefix> <offset> [box] [tailnet_ip]
project-1   example-org/project-1  https://os.example.com  /api/board  2 box-project-1-1 10.0.0.1
project-5     example-org/project-5    https://project-5.example    -           9 box-project-5-1 10.0.0.5
EOF

# THE RULES, AS THE WORKER WOULD ANSWER THEM. job_rules prints TSV
# (scope, selector, kind, max, note) — bin/jobs-client.sh:711. A stub rather
# than the network because the whole question is what the plan CONCLUDES from a
# specific rule set, including the selector ladder.
rules() { cat > "$T/rules.tsv"; }
cat > "$H/bin/jobs-client.sh" <<'STUB'
job_rules() { cat "${RULES_TSV:-/dev/null}" 2>/dev/null; }
job_rule_set() { echo "rule-set $*" >> "${RULE_SET_LOG:-/dev/null}"; }
STUB

plan() { ( export HARNESS="$H" RULES_TSV="$T/rules.tsv"
           bash "$H/bin/concurrency-plan.sh" "$@" 2>/dev/null ); }
apply() { ( export HARNESS="$H" RULES_TSV="$T/rules.tsv" RULE_SET_LOG="$T/ruleset.log"
            bash "$H/bin/concurrency-apply.sh" "$@" 2>/dev/null ); }
# One project's field, from the machine-readable half of the answer.
row() { plan --json | jq -r --arg p "$1" ".[] | select(.project==\$p) | .$2" 2>/dev/null; }
prop() { apply --dry-run --json | jq -r --arg p "$1" ".[] | select(.project==\$p) | .$2" 2>/dev/null; }
# `says <pattern> -- <cmd...>` — a text claim about an answer.
#
# A HERESTRING, NOT A PIPE, and that is not a style choice: this file runs under
# `set -o pipefail`, and `grep -q` exits the moment it matches, which SIGPIPEs
# the writer and makes the whole pipeline 141 whenever the producer has not
# finished. The same assertion then passes or fails by timing. Capturing first
# removes the race entirely.
says() { local pat="$1"; shift; [ "$1" = -- ] && shift
         grep -qi -- "$pat" <<<"$("$@")"; }

# The live rule set as of 2026-09-12, which is the case that started this.
rules <<'EOF'
ticket	*	*	1	one ticket, one claim, fleet-wide
repo	*	build	10	the operator 2026-09-11: every project may build in parallel on the pool
repo	project-5	build	20	the operator 2026-09-12: project-5 even more parallel
box	*	build	1	one build per box at a time
EOF
printf 'project-5 20\n' > "$H/fly/pool-caps.conf"

# ══ 1. THE SELECTOR LADDER, THE WAY THE WORKER WALKS IT ═════════════════════
# worker/jobs/src/index.js ruleFor(): [selector,kind] then [selector,*] then
# [*,kind] then [*,*] — selector outranks kind. A plan that reported repo/*/build
# for project-5 would say 10 where the worker says 20, and the table would be
# lying about the only number it exists to show.
[ "$(row project-5 db_rule)" = 20 ] \
  && ok || bad "project-5 must resolve its OWN repo rule (20), got '$(row project-5 db_rule)' — the exact selector outranks '*'"
[ "$(row project-1 db_rule)" = 10 ] \
  && ok || bad "a project with no exact row falls back to repo/*/build (10), got '$(row project-1 db_rule)'"
[ "$(row project-5 box_rule)" = 1 ] && ok || bad "the box rule must be reported too, got '$(row project-5 box_rule)'"
[ "$(row project-5 ticket_rule)" = 1 ] && ok || bad "the ticket rule must be reported, got '$(row project-5 ticket_rule)'"

# A kind-specific row must not be answered by a rule for another kind.
rules <<'EOF'
repo	*	triage	3	triage only
EOF
[ "$(row project-5 db_rule)" = unlimited ] \
  && ok || bad "no build rule at any rung means UNLIMITED, not 3 from a triage row — got '$(row project-5 db_rule)'"
# ...and an empty rule set is unlimited, which is what the worker does with zero
# rows (checkRules returns null before it looks at anything).
: > "$T/rules.tsv"
[ "$(row project-5 db_rule)" = unlimited ] \
  && ok || bad "an empty rules table is unlimited (worker checkRules), got '$(row project-5 db_rule)'"

rules <<'EOF'
ticket	*	*	1	one ticket, one claim, fleet-wide
repo	*	build	10	every project may build in parallel on the pool
repo	project-5	build	20	project-5 even more parallel
box	*	build	1	one build per box at a time
EOF

# ══ 2. ROUTE DECIDES WHICH CAPS APPLY AT ALL ════════════════════════════════
# bin/run-build.sh:78 returns QUEUED_FLY and exits BEFORE the wip gate (:171),
# the slot flock (:175) and job_open (:259). So for a fly-routed project the
# local numbers are not conservative — they are answers to a different question,
# and including them is the free-slots bug wearing a different hat.
printf '2\n' > "$H/flags/build-slots"
printf '2\n' > "$H/flags/wip-limit-project-5"
touch "$H/flags/builder-fly-project-5" "$H/flags/fly-pool-project-5"

[ "$(row project-5 route)" = pool ] \
  && ok || bad "builder-fly + fly-pool is the POOL route, got '$(row project-5 route)'"
[ "$(row project-5 effective)" = 20 ] \
  && ok || bad "a pool project is capped by pool-cap and the DB rule only — 20 — got '$(row project-5 effective)'"
plan --json | jq -e '.[] | select(.project=="project-5") | .applies.wip_limit == false' >/dev/null 2>&1 \
  && ok || bad "wip-limit must be marked NOT APPLYING on the pool route — run-build.sh never reaches it"
plan --json | jq -e '.[] | select(.project=="project-5") | .applies.box_slots == false' >/dev/null 2>&1 \
  && ok || bad "build-slots must be marked NOT APPLYING on the pool route"
says pool -- plan project-5 \
  && ok || bad "the text answer must SAY which cap bound it: $(plan project-5)"

# Lower the pool cap under the rule: now the pool binds, and the table must say
# so rather than reporting the rule it is no longer reaching.
printf 'project-5 5\n' > "$H/fly/pool-caps.conf"
[ "$(row project-5 effective)" = 5 ] \
  && ok || bad "pool cap 5 under rule 20 must bind at 5, got '$(row project-5 effective)'"
says 5 -- plan project-5 && ok || bad "the bound-by text must name the 5: $(plan project-5)"
# ...and a flag NUMBER overrides the conf, exactly as bin/pool-cap.sh resolves.
printf '7\n' > "$H/flags/fly-pool-project-5"
[ "$(row project-5 pool_cap)" = 7 ] \
  && ok || bad "a number in flags/fly-pool-<p> must override pool-caps.conf (bin/pool-cap.sh), got '$(row project-5 pool_cap)'"
printf '' > "$H/flags/fly-pool-project-5"     # empty flag = enable switch only
[ "$(row project-5 pool_cap)" = 5 ] \
  && ok || bad "an EMPTY flag is the enable switch and takes the conf value, got '$(row project-5 pool_cap)'"
printf 'project-5 20\n' > "$H/fly/pool-caps.conf"

# THE LEGACY ONE-MACHINE ROUTE. builder-fly without fly-pool is bin/fly-dispatch.sh,
# which holds exactly one <p>-active.json and therefore runs one job at a time.
rm -f "$H/flags/fly-pool-project-5"
[ "$(row project-5 route)" = fly1 ] \
  && ok || bad "builder-fly WITHOUT fly-pool is the single-machine dispatcher, got '$(row project-5 route)'"
[ "$(row project-5 effective)" = 1 ] \
  && ok || bad "the single-machine dispatcher is wip=1 whatever the DB rule says, got '$(row project-5 effective)'"
touch "$H/flags/fly-pool-project-5"

# THE LOCAL ROUTE. Every local cap applies, and the DB box rule is one of them:
# box/*/build=1 caps a box at one build even where flags/build-slots says 2, so
# a table that reported 2 would promise a slot job_open refuses.
[ "$(row project-1 route)" = local ] \
  && ok || bad "a project with no fly flag builds locally, got '$(row project-1 route)'"
[ "$(row project-1 effective)" = 1 ] \
  && ok || bad "box/*/build=1 binds a local project below build-slots=2, got '$(row project-1 effective)'"
says box -- plan project-1 \
  && ok || bad "the bound-by must name the box rule: $(plan project-1)"
# Raise the box rule and the local caps take over, smallest first.
rules <<'EOF'
ticket	*	*	1	one ticket
repo	*	build	10	parallel
repo	project-5	build	20	more parallel
box	*	build	4	raised
EOF
[ "$(row project-1 effective)" = 2 ] \
  && ok || bad "with the box rule at 4, build-slots=2 binds, got '$(row project-1 effective)'"
printf '1\n' > "$H/flags/wip-limit-project-1"
[ "$(row project-1 effective)" = 1 ] \
  && ok || bad "a wip-limit below the slots must bind, got '$(row project-1 effective)'"
rm -f "$H/flags/wip-limit-project-1"
# A generous wip-limit must never RAISE the answer above the slots.
printf '9\n' > "$H/flags/wip-limit-project-1"
[ "$(row project-1 effective)" = 2 ] \
  && ok || bad "a generous wip-limit must not raise the ceiling, got '$(row project-1 effective)'"
rm -f "$H/flags/wip-limit-project-1"

# ══ 3. NO CAP SET IS "UNLIMITED", THE DEFAULT run-build.sh USES ═════════════
# 2026-09-13 ("we never lock and serialize"): with BUILD_SLOTS unset run-build.sh
# opens no slot lock at all, so the honest column is `unlimited`, not 1 — and it
# must NOT enter the minimum as a 0, which would read as "no builds allowed".
rm -f "$H/flags/build-slots"
[ "$(row project-1 box_slots)" = unlimited ] \
  && ok || bad "no slot cap must read unlimited, as run-build.sh behaves — got '$(row project-1 box_slots)'"
[ "$(row project-1 effective)" = 4 ] \
  && ok || bad "an uncapped box must fall through to the next real cap (box/*/build=4), never to 0 — got '$(row project-1 effective)'"
# BUILD_SLOTS in env/global.env is the source of truth and outranks the flag.
printf '2\n' > "$H/flags/build-slots"
printf 'BUILD_SLOTS=3\n' > "$H/env/global.env"
[ "$(row project-1 box_slots)" = 3 ] \
  && ok || bad "BUILD_SLOTS must outrank flags/build-slots — got '$(row project-1 box_slots)'"
: > "$H/env/global.env"

# ══ 4. THE ACCOUNT CEILING, WHICH IS THE ONE NOBODY WROTE DOWN ══════════════
# docs/LESSONS.md#6: model capacity is the throughput ceiling, ~3-4 heavy
# sessions per account. bin/fly-envbundle.sh pushes ONE CLAUDE_CODE_OAUTH_TOKEN
# to every pool machine, so twenty pool builds are twenty sessions on one
# account. The constant is DATA (fly/account-capacity.conf), not a literal.
acct() { ( export HARNESS="$H"; bash "$H/bin/account-capacity.sh" "$@" 2>/dev/null ); }
printf 'claude 4\n' > "$H/fly/account-capacity.conf"
[ "$(acct claude | awk '{print $1}')" = 4 ] \
  && ok || bad "no accounts.d and no quota data means the implicit 'default' account alone: 1 x 4 = 4, got '$(acct claude)'"
says account -- acct claude \
  && ok || bad "the ceiling must say where it came from: $(acct claude)"
# A registry of accounts multiplies it — that is the whole point of routing.
mkdir -p "$H/env/accounts.d"
printf 'ACCOUNT_NAME=a\nACCOUNT_VENDOR=claude\nACCOUNT_ENABLED=1\n' > "$H/env/accounts.d/a.env"
printf 'ACCOUNT_NAME=b\nACCOUNT_VENDOR=claude\nACCOUNT_ENABLED=1\n' > "$H/env/accounts.d/b.env"
[ "$(acct claude | awk '{print $1}')" = 12 ] \
  && ok || bad "two registered claude accounts plus the implicit default is 3 x 4 = 12, got '$(acct claude)'"
printf 'ACCOUNT_NAME=b\nACCOUNT_VENDOR=claude\nACCOUNT_ENABLED=0\n' > "$H/env/accounts.d/b.env"
[ "$(acct claude | awk '{print $1}')" = 8 ] \
  && ok || bad "a disabled account must not be counted, got '$(acct claude)'"
printf 'ACCOUNT_NAME=b\nACCOUNT_VENDOR=grok\nACCOUNT_ENABLED=1\n' > "$H/env/accounts.d/b.env"
[ "$(acct claude | awk '{print $1}')" = 8 ] \
  && ok || bad "another vendor's account must not raise the claude ceiling, got '$(acct claude)'"
# A metered API vendor has no session ceiling at all — saying "4" there would be
# a made-up number, and a made-up ceiling is worse than none.
[ "$(acct grok | awk '{print $1}')" = unlimited ] \
  && ok || bad "a metered API vendor has no session ceiling, got '$(acct grok)'"
scratch_rm "$H/env/accounts.d"
# The constant is a reviewed line, not a literal in the script.
printf 'claude 2\n' > "$H/fly/account-capacity.conf"
[ "$(acct claude | awk '{print $1}')" = 2 ] \
  && ok || bad "fly/account-capacity.conf must be the home of the per-account number, got '$(acct claude)'"
rm -f "$H/fly/account-capacity.conf"
[ "$(acct claude | awk '{print $1}')" = 4 ] \
  && ok || bad "with no conf the documented LESSONS.md#6 default of 4 stands, got '$(acct claude)'"
grep -q 'LESSONS' "$DIR/fly/account-capacity.conf" \
  && ok || bad "fly/account-capacity.conf must cite where its number comes from"

# ══ 5. THE APPLY SCRIPT PROPOSES, AND DRY-RUN WRITES NOTHING ════════════════
printf 'project-5 20\n' > "$H/fly/pool-caps.conf"
: > "$T/ruleset.log"
apply --dry-run >/dev/null
[ ! -s "$T/ruleset.log" ] \
  && ok || bad "--dry-run must not call rule-set at all, log has: $(cat "$T/ruleset.log")"
says project-5 -- apply --dry-run \
  && ok || bad "--dry-run must print the plan it would apply: $(apply --dry-run)"
# The proposal is min(pool cap, account ceiling) — 20 pool machines on one
# account is the LESSONS.md#6 overshoot, and the dry run is where that shows.
[ "$(prop project-5 proposed)" = 4 ] \
  && ok || bad "proposed must be min(pool 20, account 4) = 4, got '$(prop project-5 proposed)'"
[ "$(prop project-5 current)" = 20 ] \
  && ok || bad "the plan must state the CURRENT rule beside the proposal, got '$(prop project-5 current)'"
says account -- apply --dry-run \
  && ok || bad "a proposal that lowers a cap must say why: $(apply --dry-run)"
# A non-pool project is not proposed at all: its ceiling is local, and a repo
# rule raised for it would promise parallelism the box cannot deliver.
[ "$(prop project-1 proposed)" = null ] \
  && ok || bad "a local-route project must get no proposal, got '$(prop project-1 proposed)'"
# Neither flag = refuse. An apply script whose default is to write is a trap.
apply >/dev/null 2>&1 && bad "concurrency-apply.sh with no --dry-run/--apply must refuse" || ok
[ ! -s "$T/ruleset.log" ] && ok || bad "a refused invocation must still write nothing"
# --apply goes through the jobs-client verb, never raw SQL.
apply --apply >/dev/null 2>&1
grep -q '^rule-set repo project-5 build 4' "$T/ruleset.log" \
  && ok || bad "--apply must call jobs-client rule-set repo <p> build <n>, log: $(cat "$T/ruleset.log")"
grep -qiE 'wrangler|d1 execute|INSERT INTO|UPDATE .*SET' "$DIR/bin/concurrency-apply.sh" \
  && bad "concurrency-apply.sh must never reach for raw SQL — the rule is a jobs-client verb" || ok
# Idempotent: a second apply of an already-correct value writes nothing.
rules <<'EOF'
repo	project-5	build	4	already right
repo	*	build	10	parallel
box	*	build	4	raised
EOF
: > "$T/ruleset.log"
apply --apply >/dev/null 2>&1
[ ! -s "$T/ruleset.log" ] \
  && ok || bad "an apply that changes nothing must call nothing, log: $(cat "$T/ruleset.log")"

# ══ 6. ONE SOURCE FOR THE DISPATCHER WIP (a grep, deliberately) ═════════════
# bin/fly-dispatch.sh ran "one job at a time (wip=1)" as a COMMENT and a shape:
# one <p>-active.json. The plan has to report that same 1, and the two must not
# be able to disagree — so it lives in bin/lib/build-caps.sh and both read it.
grep -q 'FLY_DISPATCH_WIP' "$DIR/bin/lib/build-caps.sh" \
  && ok || bad "bin/lib/build-caps.sh must define FLY_DISPATCH_WIP — it is the one home of the dispatcher's per-project wip"
grep -q 'FLY_DISPATCH_WIP' "$DIR/bin/fly-dispatch.sh" \
  && ok || bad "bin/fly-dispatch.sh must READ FLY_DISPATCH_WIP, not restate 1 in a comment"
grep -q 'build-caps.sh' "$DIR/bin/fly-dispatch.sh" \
  && ok || bad "bin/fly-dispatch.sh must source bin/lib/build-caps.sh"
grep -q 'build-caps.sh' "$DIR/bin/concurrency-plan.sh" \
  && ok || bad "bin/concurrency-plan.sh must read the SAME lib, or there are two constants again"
# pool-cap.sh stays the one reader of the pool cap: a second copy of that
# resolution order is how flags/fly-pool-<p> and pool-caps.conf came to disagree.
grep -q 'pool-cap.sh' "$DIR/bin/concurrency-plan.sh" \
  && ok || bad "concurrency-plan.sh must resolve the pool cap through bin/pool-cap.sh"
grep -q 'pool-caps.conf' "$DIR/bin/concurrency-plan.sh" \
  && bad "concurrency-plan.sh must not re-read pool-caps.conf itself — bin/pool-cap.sh owns that order" || ok

# ══ 7. THE INVARIANT THAT CATCHES A SILENT BYPASS ═══════════════════════════
# A cap nothing checks is a wish. pipeline-health must compare RUNNING builds
# per project against the effective limit and page when they exceed it — the
# exact question that could not be answered on 2026-09-12.
grep -q 'concurrency-plan.sh' "$DIR/bin/pipeline-health.sh" \
  && ok || bad "bin/pipeline-health.sh must read the effective limit from concurrency-plan.sh, not recompute it"
grep -q 'overcap' "$DIR/bin/pipeline-health.sh" \
  && ok || bad "pipeline-health needs an overcap finding-key so the alert dedupes and retracts like the others"
grep -q 'overcap' <(sed -n '/^RETRACT_NS=/p' "$DIR/bin/pipeline-health.sh") \
  && ok || bad "the overcap namespace must be retractable — it runs every tick, and a cleared overshoot must clear its alert"

# ══ 8. THE PLAN NEVER STACK-TRACES ══════════════════════════════════════════
# A launch rule or a health check that cannot read this must fall back to its
# own judgement, never to a non-zero exit — the free-slots.sh contract.
( export HARNESS="$T/nonexistent"; bash "$H/bin/concurrency-plan.sh" >/dev/null 2>&1 ) \
  && ok || bad "concurrency-plan.sh must exit 0 even with no HARNESS tree"
( export HARNESS="$H" RULES_TSV="$T/nope.tsv"; bash "$H/bin/concurrency-plan.sh" >/dev/null 2>&1 ) \
  && ok || bad "an unreachable rules table must not fail the plan"
( export HARNESS="$H" RULES_TSV="$T/nope.tsv"
  bash "$H/bin/concurrency-plan.sh" --json 2>/dev/null | jq -e 'type=="array"' >/dev/null ) \
  && ok || bad "--json must stay valid JSON when the rules are unreadable"

echo "concurrency-plan-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
