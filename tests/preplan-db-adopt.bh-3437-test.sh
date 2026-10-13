#!/bin/bash
# tests/preplan-db-adopt.bh-3437-test.sh — the builder asks the coordination DB
# for its own pre-plan when the relay dir and plans/ are both empty (BH-3437).
# Run from anywhere: tests/preplan-db-adopt.bh-3437-test.sh   (exit 0 = all pass)
#
# THE DEFECT. The only reader of a published pre-plan row was the hub's
# bin/fly-pool.sh:push_preplan, and it reads once, at dispatch. BH-3437's own
# build was dispatched 21 s before its pre-plan was published, so the relay dir
# was empty and the build logged PREPLAN_MISS. cromford: 0 adopted / 76
# miss over 7 days while 328 rows sat in the preplans table.
#
# HOW IT IS DRIVEN. The adopt block is extracted verbatim from the flattened
# run-build pipeline by its markers (as tests/preplan-adopt.bh-776-test.sh
# does), run against a real scratch git repo, with the REAL
# bin/lib/preplan-lib.sh and a stub bin/jobs-client.sh whose preplan_get answers
# from a fixture. Assertions read what the block wrote.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/plans" "$T/builds" "$T/db"
cp "$DIR/bin/lib/preplan-lib.sh" "$T/bin/lib/"
: > "$T/env/global.env"

awk '/^# >>> preplan adopt$/{f=1} /^# <<< preplan adopt$/{exit} f' "$RB_ALL" > "$T/adopt.sh"
[ -s "$T/adopt.sh" ] || { echo "FAIL: could not extract the preplan adopt block"; exit 1; }

# The stub client: preplan_get answers the fixture row with the fixture rc, the
# way bin/lib/jobs/queue.sh does (0 row, 2 = 404, 1 = anything else).
cat > "$T/bin/jobs-client.sh" <<'EOF'
preplan_get() {
  printf '%s %s\n' "$1" "$2" >> "$HARNESS/db/calls"
  local rc; rc=$(cat "$HARNESS/db/rc" 2>/dev/null || echo 1)
  [ "$rc" = 0 ] && cat "$HARNESS/db/row.json"
  return "$rc"
}
EOF

R="$T/repo"; mkdir -p "$R/src/lib" "$R/src/ui"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t; git -C "$R" config user.name t
echo a > "$R/src/lib/pay.ts"; echo b > "$R/src/ui/card.tsx"
git -C "$R" add -A; git -C "$R" commit -qm one
BASE0=$(git -C "$R" rev-parse main)
FP_NOW='2026-09-29T17:00:00Z|2026-09-29T17:00:00Z||1'
# The plan ends in a blank line on purpose: the adopted bytes must be the
# published bytes, and a $(…) capture anywhere on the path would eat it.
PLAN_MD=$'## Scope\nTouch src/lib/pay.ts.\nSIZE: S\n\n'

dbrow() { # dbrow <rc> [ticket_key] [ticket_fp] [base_sha] — the fixture the DB answers
  printf '%s\n' "$1" > "$T/db/rc"; rm -f "$T/db/calls"
  jq -n --arg k "${2:-AB-1}" --arg fp "${3:-$FP_NOW}" --arg sha "${4:-$BASE0}" --arg plan "$PLAN_MD" \
    '{project:"proj",ticket_key:$k,base_sha:$sha,plan_md:$plan,planned_files:"src/lib/pay.ts\n",ticket_fp:$fp}' \
    > "$T/db/row.json"
}
RUN_N=0
adopt() { # adopt [relay-dir] -> a fresh $BUILD, left in $BLD
  RUN_N=$((RUN_N+1))
  BLD="$T/builds/run-$RUN_N"; scratch_rm "$BLD"; mkdir -p "$BLD"
  ( HARNESS="$T"; PROJECT=proj; KEY=AB-1; BUILD="$BLD"; WT="$R"; BASE=main; FP_BEFORE="$FP_NOW"
    export PREPLAN_RELAY_DIR="${1:-$T/relay-none}"
    STAMP() { printf '2026-09-29 17:08:40Z'; }
    BB() { :; }
    # shellcheck source=/dev/null
    . "$T/adopt.sh" ) >/dev/null 2>&1
}
outcome() { cat "$BLD/preplan-outcome" 2>/dev/null; }
nlines() { grep -c 'PREPLAN_' "$BLD/pipeline.log" 2>/dev/null; }

echo "--- 1. relay empty, plans/ empty, the DB has the row -> HIT"
dbrow 0; adopt
case "$(outcome)" in HIT*) ok ;; *) bad "a DB row must be adopted (got: $(outcome))" ;; esac
cmp -s "$BLD/plan.md" <(printf '%s' "$PLAN_MD") && ok \
  || bad "the adopted plan.md must be byte-identical to the row's plan_md, trailing blank line included"
[ "$(cat "$BLD/ticket-fp" 2>/dev/null)" = "$FP_NOW" ] && ok || bad "a DB HIT must carry ticket-fp"
[ "$(nlines)" = 1 ] && ok || bad "exactly one PREPLAN_ line (got: $(nlines))"
grep -q "PREPLAN_HIT adopted $BLD/preplan-db " "$BLD/pipeline.log" && ok \
  || bad "the HIT must name \$BUILD/preplan-db (log: $(cat "$BLD/pipeline.log" 2>/dev/null))"
[ "$(cat "$T/db/calls" 2>/dev/null)" = "proj AB-1" ] && ok || bad "the DB must be asked once for proj AB-1 (calls: $(cat "$T/db/calls" 2>/dev/null))"

echo "--- 2. the DB answers 404 -> MISS, has no row"
dbrow 2; adopt
case "$(outcome)" in "MISS no pre-plan for AB-1 (relay dir empty, hub plans/ empty, coordination DB has no row)") ok ;;
  *) bad "a 404 must be a MISS naming the DB (got: $(outcome))" ;; esac
[ ! -e "$BLD/plan.md" ] && ok || bad "a MISS adopts nothing"
[ "$(nlines)" = 1 ] && grep -q PREPLAN_MISS "$BLD/pipeline.log" && ok || bad "a MISS logs exactly one PREPLAN_MISS line"

echo "--- 3. the DB is down -> MISS, unreachable, never 'has no row'"
dbrow 1; adopt
case "$(outcome)" in "MISS no pre-plan for AB-1 (relay dir empty, hub plans/ empty, coordination DB unreachable)") ok ;;
  *) bad "an outage must say unreachable (got: $(outcome))" ;; esac
[ ! -e "$BLD/plan.md" ] && ok || bad "an outage adopts nothing"

echo "--- 4. the row is for AB-10, the build is AB-1 -> MISS"
dbrow 0 AB-10; adopt
case "$(outcome)" in MISS*) ok ;; *) bad "another ticket's row must never be adopted (got: $(outcome))" ;; esac
[ ! -e "$BLD/plan.md" ] && ok || bad "a prefix-collision row adopts nothing"

echo "--- 5. a planned file moved on main -> STALE, evidence kept"
echo moved >> "$R/src/lib/pay.ts"; git -C "$R" add -A; git -C "$R" commit -qm two
touch "$T/plans/.sentinel"
dbrow 0; adopt
case "$(outcome)" in STALE*) ok ;; *) bad "a moved planned file must be STALE (got: $(outcome))" ;; esac
[ ! -e "$BLD/plan.md" ] && ok || bad "a stale DB pre-plan must not be adopted"
[ -s "$BLD/preplan-db/plan.md" ] && ok || bad "the STALE branch must leave \$BUILD/preplan-db as evidence"
[ "$(ls -A "$T/plans")" = .sentinel ] && ok || bad "plans/ must be untouched (got: $(ls -A "$T/plans"))"
BASE1=$(git -C "$R" rev-parse main)

echo "--- 6. a valid relay copy wins and the DB is never asked"
RELAY="$T/relay"; mkdir -p "$RELAY"
printf 'the relayed plan\n' > "$RELAY/plan.md"; printf '%s\n' "$BASE1" > "$RELAY/base-sha"
printf 'src/lib/pay.ts\n' > "$RELAY/planned-files.txt"; printf 'AB-1\n' > "$RELAY/key"
dbrow 0 AB-1 "$FP_NOW" "$BASE1"; adopt "$RELAY"
case "$(outcome)" in HIT*) ok ;; *) bad "a valid relay copy must be a HIT (got: $(outcome))" ;; esac
[ "$(cat "$BLD/plan.md" 2>/dev/null)" = "the relayed plan" ] && ok || bad "the relay copy, not the DB row, must be adopted"
[ ! -e "$T/db/calls" ] && ok || bad "the DB must not be asked when the relay answered (calls: $(cat "$T/db/calls"))"

echo "--- 7. the row was written against an older thread -> STALE thread"
dbrow 0 AB-1 '2026-09-29T09:00:00Z|2026-09-29T09:00:00Z||0' "$BASE1"; adopt
case "$(outcome)" in STALE*thread*) ok ;; *) bad "a row with another ticket_fp must be STALE thread (got: $(outcome))" ;; esac
[ ! -e "$BLD/plan.md" ] && ok || bad "a thread-stale DB pre-plan adopts nothing"

echo "--- 8. a box with no jobs client never claims to have asked"
dbrow 0 AB-1 "$FP_NOW" "$BASE1"; mv "$T/bin/jobs-client.sh" "$T/bin/jobs-client.off"; adopt
case "$(outcome)" in *"coordination DB not asked"*) ok ;; *) bad "no client must read 'not asked' (got: $(outcome))" ;; esac
mv "$T/bin/jobs-client.off" "$T/bin/jobs-client.sh"

echo "preplan-db-adopt: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
