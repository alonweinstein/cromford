#!/bin/bash
# tests/overlap-schedule-stack.bh-1174-test.sh — BH-1174: bin/overlap-schedule.sh
# recommends a STACK base when a ready ticket's plan overlaps exactly one OPEN
# harness PR and nothing in flight, and the two tick prompts turn that line into
# a `STACK_BASE=<base>` launch. Run from anywhere (exit 0 = all pass).
#
# THE RATCHET (the ticket's item 5): three fake tickets, AB-1 and AB-2 sharing
# code/shared.ts, AB-3 disjoint. The order is AB-1 and AB-3 first, then AB-2
# stacked on AB-1's branch once AB-1's PR is open — not AB-2 launched on main
# and deferred by bin/overlap-guard.sh every tick until AB-1 merges.
#
# The expensive way for this to be wrong is a STACK line built from data that
# does not say so: a stale cache, the candidate's own repair PR, a draft, a
# directory that merely contains a PR's file, two parents at once. Each of those
# is a negative here, and case 6 pins that every missing input prints today's
# output byte for byte.
#
# No network, no gh, no LLM. The only input added is the PR cache
# bin/overlap-guard.sh writes (state/overlap-guard/<project>-prs.json), in the
# shape harness_pr_list returns (number, headRefName, isDraft, files[{path}]).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCHED="$DIR/bin/overlap-schedule.sh"

# ── the fixture harness (the tests/overlap-schedule-test.sh scaffold) ───────
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/plans" "$H/builds" \
         "$H/locks" "$H/state/claims/proj" "$H/state/preplan-candidates" \
         "$H/state/overlap-guard"
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/dep-verify-lib.sh" \
   "$DIR/bin/lib/scheduler-conf.sh" "$H/bin/lib/" 2>/dev/null
cp "$SCHED" "$H/bin/overlap-schedule.sh"
cat > "$H/fleet.conf" <<'CONF'
proj  example-org/proj   -  -  0 local -
CONF

plan_files() { # plan_files <KEY> <path>...
  local k="$1"; shift
  mkdir -p "$H/plans/proj-$k"
  printf '%s\n' "$@" > "$H/plans/proj-$k/planned-files.txt"
}
cands() { # cands <KEY>... — a FRESH candidate snapshot, rows in this order
  local k
  for k in "$@"; do printf '%s\t%s\tahead\n' "$k" "${k#AB-}"; done \
    > "$H/state/preplan-candidates/proj.tsv"
}
# pr <num> <branch> [draft] -- <file>... — one open PR, as harness_pr_list returns it
pr() { local n="$1" br="$2" dr=false; shift 2
  [ "${1:-}" = draft ] && { dr=true; shift; }
  [ "${1:-}" = -- ] && shift
  jq -nc --arg n "$n" --arg br "$br" --argjson dr "$dr" --args '{number: ($n|tonumber),
    url: ("https://github.com/o/r/pull/"+$n), headRefName: $br, isDraft: $dr,
    files: [$ARGS.positional[] | {path: .}]}' "$@"; }
CACHE="$H/state/overlap-guard/proj-prs.json"
prs() { jq -s '.' > "$CACHE"; }
nocache() { rm -f "$CACHE"; }
reset() {
  scratch_rm "$H/state/claims/proj"; mkdir -p "$H/state/claims/proj"
  rm -f "$H/flags/stacked-builds-off"
  plan_files AB-1 code/shared.ts code/a.ts
  plan_files AB-2 code/shared.ts code/b.ts
  plan_files AB-3 code/c.ts
  nocache
}
run() { HARNESS="$H" "$H/bin/overlap-schedule.sh" "$@" 2>/dev/null; }

STACK_LINE='STACK: AB-2 base=ticket/ab-1 (overlaps open PR #11 on code/shared.ts)'

# ---------- 1. the ratchet: A, C, then B stacked on A ----------------------
reset
cands AB-1 AB-2 AB-3
OUT=$(run proj)
grep -qxF 'WAVE 1: AB-1 AB-3' <<<"$OUT" && ok || bad "1a: AB-1 and AB-3 are disjoint, WAVE 1 must be exactly them (got: $OUT)"
grep -qxF 'WAVE 2: AB-2' <<<"$OUT" && ok || bad "1a: AB-2 overlaps AB-1, it must be WAVE 2 (got: $OUT)"
grep -q '^STACK:' <<<"$OUT" && bad "1a: nothing is open yet, so nothing can stack (got: $OUT)" || ok

# 1b. AB-1 built: it left the candidates and its PR #11 is open.
cands AB-2 AB-3
NOSTACK=$(run proj)
pr 11 ticket/ab-1 -- code/shared.ts code/a.ts | prs
OUT=$(run proj); RC=$?
[ "$RC" = 0 ] && ok || bad "1b: rc must be 0 (got $RC)"
EXP=$(printf '%s\n%s' 'WAVE 1: AB-2 AB-3' "$STACK_LINE")
[ "$OUT" = "$EXP" ] && ok || bad "1b: expected exactly
$EXP
got:
$OUT"
grep -q '^STACK: AB-3' <<<"$OUT" && bad "1b: AB-3 shares nothing with PR #11 — no STACK (got: $OUT)" || ok
[ "$(grep -c '^STACK:' <<<"$OUT")" = 1 ] && ok || bad "1b: exactly one STACK line (got: $OUT)"
[ "$NOSTACK" = 'WAVE 1: AB-2 AB-3' ] && ok || bad "1b: the no-cache baseline must be 'WAVE 1: AB-2 AB-3' (got: $NOSTACK)"

# ---------- 2. an in-flight overlap is HELD, never stacked -----------------
echo 'code/b.ts' > "$H/state/claims/proj/AB-9"
touch "$H/locks/build-key-proj-AB-9.lock"
OUT=$(run proj)
grep -qxF 'HELD: AB-2 overlaps in-flight AB-9 on code/b.ts' <<<"$OUT" && ok \
  || bad "2: AB-2 overlaps a running build — it must be HELD (got: $OUT)"
grep -q '^STACK: AB-2' <<<"$OUT" && bad "2: a HELD key must get no STACK line (got: $OUT)" || ok
rm -f "$H/state/claims/proj/AB-9" "$H/locks/build-key-proj-AB-9.lock"

# ---------- 3. --key mode ---------------------------------------------------
OUT=$(run proj --key AB-2)
[ "$OUT" = 'AB-2 STACK base=ticket/ab-1 (overlaps open PR #11 on code/shared.ts)' ] && ok \
  || bad "3: --key AB-2 must answer the STACK verdict (got: $OUT)"
OUT=$(run proj --key AB-3)
[ "$OUT" = 'AB-3 WAVE 1 (shares no planned file with an in-flight build)' ] && ok \
  || bad "3: --key AB-3 must still answer WAVE 1 (got: $OUT)"

# ---------- 4. the stacked-builds kill switch ------------------------------
touch "$H/flags/stacked-builds-off"
OUT=$(run proj)
[ "$OUT" = "$NOSTACK" ] && ok || bad "4: flags/stacked-builds-off must print the no-cache output (got: $OUT)"
OUT=$(run proj --key AB-2)
grep -q STACK <<<"$OUT" && bad "4: --key with the switch on must not STACK (got: $OUT)" || ok
rm -f "$H/flags/stacked-builds-off"
OUT=$(STACKED_BUILDS=0 run proj)
[ "$OUT" = "$NOSTACK" ] && ok || bad "4: STACKED_BUILDS=0 must print the no-cache output (got: $OUT)"
echo 'STACKED_BUILDS=0' > "$H/env/global.env"
OUT=$(run proj)
[ "$OUT" = "$NOSTACK" ] && ok || bad "4: STACKED_BUILDS=0 in env/global.env must print the no-cache output (got: $OUT)"
: > "$H/env/global.env"
# ...and the positive control: with the switch off again, it stacks.
OUT=$(run proj)
grep -qxF "$STACK_LINE" <<<"$OUT" && ok || bad "4: positive control — switch cleared, STACK must come back (got: $OUT)"

# ---------- 5. negatives ----------------------------------------------------
# 5a. two open PRs on the same file: a ticket cannot sit on two parents
{ pr 11 ticket/ab-1 -- code/shared.ts code/a.ts; pr 12 ticket/ab-7 -- code/b.ts; } | prs
OUT=$(run proj)
grep -q '^STACK:' <<<"$OUT" && bad "5a: overlapping two open PRs must not STACK (got: $OUT)" || ok
[ "$OUT" = "$NOSTACK" ] && ok || bad "5a: output must be today's (got: $OUT)"
# 5b. the candidate's own branch (a repair round) is not a parent
pr 11 ticket/ab-2-r2 -- code/shared.ts code/b.ts | prs
OUT=$(run proj)
grep -q '^STACK:' <<<"$OUT" && bad "5b: a PR on AB-2's own branch must not STACK (got: $OUT)" || ok
# 5c. a planned DIRECTORY that contains a PR's file is not an exact match
plan_files AB-2 code/sub code/b.ts
pr 11 ticket/ab-1 -- code/sub/x.ts | prs
OUT=$(run proj)
grep -q '^STACK:' <<<"$OUT" && bad "5c: directory-vs-file must not STACK (exact files only, like the guard) (got: $OUT)" || ok
plan_files AB-2 code/shared.ts code/b.ts
# 5d. unsafe branch names never reach a launch line
for BR in 'ticket/ab-1;rm' 'a..b' 'ticket/ab 1'; do
  pr 11 "$BR" -- code/shared.ts | prs
  OUT=$(run proj)
  grep -q '^STACK:' <<<"$OUT" && bad "5d: branch '$BR' must be dropped, no STACK (got: $OUT)" || ok
done
# 5e. a draft PR is not a parent (the guard ignores drafts too)
pr 11 ticket/ab-1 draft -- code/shared.ts | prs
OUT=$(run proj)
grep -q '^STACK:' <<<"$OUT" && bad "5e: a draft PR must not STACK (got: $OUT)" || ok
# 5f. sharing only an OVERLAP_IGNORE path is not an overlap
plan_files AB-2 package.json code/b.ts
pr 11 ticket/ab-1 -- package.json code/a.ts | prs
OUT=$(run proj)
grep -q '^STACK:' <<<"$OUT" && bad "5f: sharing only package.json must not STACK (got: $OUT)" || ok
plan_files AB-2 code/shared.ts code/b.ts
# 5h. OVERLAP_THRESHOLD is the guard's Jaccard bar, over the IGNORE-pruned lists
# on BOTH sides: PR {shared.ts, package.json} vs AB-2 {shared.ts, b.ts} is 1 hit
# over a union of 2 once package.json is dropped (0.5, stacks at 0.5), and 1 of
# 3 if it were counted (0.33, would not).
pr 11 ticket/ab-1 -- code/shared.ts package.json | prs
OUT=$(OVERLAP_THRESHOLD=0.5 run proj)
grep -qxF "$STACK_LINE" <<<"$OUT" && ok || bad "5h: at threshold 0.5 the ignore-pruned PR list must STACK (got: $OUT)"
OUT=$(OVERLAP_THRESHOLD=0.6 run proj)
grep -q '^STACK:' <<<"$OUT" && bad "5h: at threshold 0.6 a 0.5 Jaccard must not STACK (got: $OUT)" || ok
# 5g. a WAVE 2 candidate never stacks: AB-4 overlaps wave-1 AB-2 and PR #11
plan_files AB-4 code/b.ts code/shared.ts
cands AB-2 AB-3 AB-4
pr 11 ticket/ab-1 -- code/shared.ts code/a.ts | prs
OUT=$(run proj)
grep -q '^STACK: AB-4' <<<"$OUT" && bad "5g: a WAVE 2 key must not STACK (got: $OUT)" || ok
grep -qxF "$STACK_LINE" <<<"$OUT" && ok || bad "5g: AB-2 (wave 1) must still STACK (got: $OUT)"
OUT=$(run proj --key AB-4)
grep -q '^AB-4 WAVE 2' <<<"$OUT" && ok || bad "5g: --key AB-4 must stay WAVE 2 (got: $OUT)"
cands AB-2 AB-3

# ---------- 6. missing inputs print today's output -------------------------
nocache
OUT=$(run proj); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$NOSTACK" ] && ok || bad "6: no cache -> today's output, rc 0 (rc=$RC got: $OUT)"
pr 11 ticket/ab-1 -- code/shared.ts code/a.ts | prs
touch -d '-2 hours' "$CACHE"
OUT=$(run proj); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$NOSTACK" ] && ok || bad "6: a stale cache -> today's output (rc=$RC got: $OUT)"
# the knob moves the bar: the same 2h-old file is fresh at a 3h max age
OUT=$(OVERLAP_SNAPSHOT_MAX_AGE=10800 run proj)
grep -qxF "$STACK_LINE" <<<"$OUT" && ok || bad "6: OVERLAP_SNAPSHOT_MAX_AGE must govern the cache age (got: $OUT)"
echo 'not json' > "$CACHE"
OUT=$(run proj); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$NOSTACK" ] && ok || bad "6: an unparseable cache -> today's output (rc=$RC got: $OUT)"
echo '[]' > "$CACHE"
OUT=$(run proj); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$NOSTACK" ] && ok || bad "6: an empty cache -> today's output (rc=$RC got: $OUT)"
nocache

# ---------- 7. the tick feed carries STACK and STACK_BASE ------------------
cut_block() { # cut_block <file> <marker-word...> <outfile> (as tests/overlap-schedule-test.sh)
  awk -v n="$2" '{l=$0; sub(/^[ \t]+/,"",l)}
                 index(l,"# >>> " n)==1{f=1;next}
                 index(l,"# <<< " n)==1{exit} f' "$1" > "$3"
}
cut_block "$DIR/bin/lib/rt/scope.sh" "overlap schedule feed" "$T/feed.sh"
[ -s "$T/feed.sh" ] && ok || bad "7: could not extract the overlap schedule feed from bin/lib/rt/scope.sh"
FH="$T/fh"; mkdir -p "$FH/bin" "$FH/logs"
printf '%s\n%s\n' 'WAVE 1: AB-2 AB-3' "$STACK_LINE" > "$FH/stub-out.txt"
cat > "$FH/bin/overlap-schedule.sh" <<'SH'
#!/bin/bash
cat "$HARNESS/stub-out.txt"
SH
chmod +x "$FH/bin/overlap-schedule.sh"
SEC=$( set -uo pipefail
  export HARNESS="$FH"; PROJECT=proj; LOG="$FH/logs/proj.log"; STAMP=x
  # shellcheck disable=SC1090
  . "$T/feed.sh"
  printf '%s' "${OVERLAP_SEC:-}" )
grep -qxF "$STACK_LINE" <<<"$SEC" && ok || bad "7: OVERLAP_SEC must carry the STACK line (got: $SEC)"
grep -qF 'STACK_BASE=' <<<"$SEC" && ok || bad "7: the launch rule must teach STACK_BASE=<base> (got: $SEC)"
grep -qi 'not a veto' <<<"$SEC" && ok || bad "7: the existing ORDER-not-a-veto wording must survive (got: $SEC)"

# ---------- 8. the shard note carries a STACK verdict and STACK_BASE -------
cut_block "$DIR/bin/lib/rt/shards.sh" "shard overlap verdict" "$T/shardov.sh"
[ -s "$T/shardov.sh" ] && ok || bad "8: could not extract the shard overlap verdict from bin/lib/rt/shards.sh"
OVLINE=$(grep -F 'OVERLAP SCHEDULE (deterministic, bin/overlap-schedule.sh)' "$DIR/bin/lib/rt/shards.sh")
[ -n "$OVLINE" ] && ok || bad "8: bin/lib/rt/shards.sh must carry the shard OVERLAP SCHEDULE line"
SH2="$T/sh2"; mkdir -p "$SH2/bin"
cat > "$SH2/bin/overlap-schedule.sh" <<'SH'
#!/bin/bash
[ "$2" = --key ] || exit 0
printf '%s STACK base=ticket/ab-1 (overlaps open PR #11 on code/shared.ts)\n' "$3"
SH
chmod +x "$SH2/bin/overlap-schedule.sh"
TAIL=$( set -uo pipefail
  HARNESS="$SH2"; PROJECT=proj; K=AB-2
  # shellcheck disable=SC1090
  . "$T/shardov.sh"
  eval "SHARD_TAIL=\"$OVLINE\""
  printf '%s' "$SHARD_TAIL" )
grep -qF 'AB-2 STACK base=ticket/ab-1 (overlaps open PR #11 on code/shared.ts)' <<<"$TAIL" && ok \
  || bad "8: the shard prompt must carry the STACK verdict (got: $TAIL)"
grep -qF 'STACK_BASE=' <<<"$TAIL" && ok || bad "8: the shard prompt must teach STACK_BASE=<base> (got: $TAIL)"
grep -qi 'not a veto' <<<"$TAIL" && ok || bad "8: the existing WAVE wording must survive (got: $TAIL)"

echo "overlap-schedule-stack.bh-1174: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
