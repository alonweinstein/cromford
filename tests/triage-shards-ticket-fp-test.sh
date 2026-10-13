#!/bin/bash
# tests/triage-shards-ticket-fp-test.sh — BH-1015: a triage shard is DEDUPED PER
# TICKET, on a fingerprint persisted BEFORE the session is bought.
#
# WHAT WENT WRONG (Mac-side runaway-spend audit, 2026-09-17..19, site 4 of 8).
# bin/triage-gate.sh already brakes the TICK on state/<project>.queuefp — but
# that brake is all-or-nothing. One ticket's queue line gaining a word un-brakes
# the whole tick, and bin/lib/rt/shards.sh then buys a session for EVERY key in
# scope, including the dozen whose world is byte-identical to the last time
# somebody paid to read them. A shard that concludes "hold, nothing to do" is a
# billed empty result, and it was re-offered every RUN tick: project-4 2,073
# shards in 3 days, project-1 TK-265 153, cromford $896/day.
#
# THE GUARD UNDER TEST is the one the fleet rule demands
# (~/.claude/rules/metered-api-dedup.md): a PERSISTED "have we already paid for
# this?" check that runs BEFORE the billable call, keyed on a fingerprint of the
# INPUT rather than on anything that churns.
#
# ── THE TWO THINGS THIS SUITE LEARNED THE HARD WAY (review of b301d8f7) ──────
# The first cut of this suite stubbed bin/triage-gate.sh AND hand-wrote a
# 3-line state/<p>.queuefp in every reset. Both defects it hid were real, both
# are BLOCKing, and each now has its own section driving the REAL script:
#
#   Part B — THE PR-STATE INPUT MUST BE CARRIED FORWARD. The real gate writes
#   its PR-state vector into line 3 of queuefp on ONE of its three write
#   branches and erases it on the other two, and bin/lib/rt/shards.sh deletes
#   the whole file whenever the hourly cap defers a unit. Reading that line
#   directly made one unchanged "waiting on PR #12" key flip between `pr 12=?`
#   and `pr 12=OPEN` and buy a session on each flip — twice per 45-minute
#   cycle, on precisely the line this ticket is about. Part B drives the ACTUAL
#   bin/triage-gate.sh through that sequence with gh stubbed and asserts the
#   fingerprint never moves.
#
#   Part C — A SKIPPED KEY MUST NOT HIDE A CLIENT REPLY. bin/gate-diff.sh names
#   a ticket NEW when the consumed fingerprint lacks it and CHANGED when it has
#   it, and only the CHANGED line carries `(comments: 5 -> 6)`. A key re-armed
#   out of state/<p>.gate.json sits on `NEW 563 "c"`, byte-identical at five
#   comments and at six — so fingerprinting the diff line let a client's reply
#   be skipped for the whole TTL, webhook wake included. The fingerprint now
#   reads the ticket's own entry in the LIVE board fingerprint instead, and the
#   re-arm-on-skip is gone.
#
# WHAT IS AT STAKE IN EACH CASE. "0 calls" alone would pass a dispatcher that
# had simply stopped working, so every skip case is paired with one that MUST
# still dispatch: a PR that merged, a build that finished, a client comment, a
# stamp that aged out, a fingerprint file that cannot be read.
#
# Part A runs the REAL bin/run-triage.sh end to end; only the harness and repo
# ROOTS are rewritten (the precedent tests/triage-shards-test.sh set). The stub
# agent-call COUNTS its calls and writes a cost row, so "no shard was bought" is
# asserted on logs/cost.csv and not only on a log line. The stub `gh` records
# every call, so "one refresh pass per tick, never per key" is asserted too.
#
# Run from anywhere: tests/triage-shards-ticket-fp-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ONE clock read for the whole file: every fixture age below is derived from it,
# so this suite cannot pick its own red day (bin/test-determinism-lint.sh).
NOW=$(date +%s)

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" project-5 || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/prompts" \
         "$H/builds" "$H/catalog" "$T/calls" "$T/repos"
: > "$H/env/global.env"
# A GitHub-Issues project, deliberately: the key reaches the dispatcher as `563`
# from the board and as `TK-563` from the queue and the build dirs, and both the
# fingerprint's build-dir scan and its live-entry lookup have to canonicalise.
P=project-5
K=563
echo "SOP for $P. Fetch the thread. Do the work." > "$H/prompts/$P.md"
export FLEET_CONF="$DIR/fleet.conf"

for s in run-triage.sh triage-shard.sh triage-gate.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/$s" > "$H/bin/real-$s"
  chmod +x "$H/bin/real-$s"
done
cp "$H/bin/real-run-triage.sh" "$H/bin/run-triage.sh"
cp "$H/bin/real-triage-shard.sh" "$H/bin/triage-shard.sh"
chmod +x "$H/bin/run-triage.sh" "$H/bin/triage-shard.sh"
mkdir -p "$H/bin/lib/rt"
for s in "$DIR"/bin/lib/rt/*.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"
done
cp "$DIR/bin/lib/triage-shards-lib.sh" "$H/bin/lib/triage-shards-lib.sh"
# The shared gh libraries the PR-state refresh goes through, real and unmodified:
# gh-rest.sh is the REST reader (and the source of the three exit codes this
# suite leans on), gh-app-auth.sh is what arms the App identity, gh-budget.sh is
# the non-essential-read gate. The scratch box has no env/github-app.env and no
# bin/gh-token.sh, so gh_auth_armed says no and the pass runs on the ambient
# identity — which is exactly an un-onboarded box, and the path worth testing.
# BH-1485: gh-rest-var.sh rides with gh-rest.sh (sourced by path from beside it).
for s in gh-rest.sh gh-rest-var.sh gh-app-auth.sh gh-budget.sh; do
  sed -e "s|/root/harness|$H|g" "$DIR/bin/lib/$s" > "$H/bin/lib/$s"
done
for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do
  ln -sf "$DIR/bin/$s" "$H/bin/$s"
done
printf '#!/bin/sh\necho box-project-5-1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"

# --- stubs -------------------------------------------------------------------
# The gate stub of Part A. Part B swaps the REAL gate in.
cat > "$H/bin/triage-gate.sh" <<STUB
#!/bin/bash
P="\$1"; MODE="\${2:-}"
cp "$H/fixture/pending.json" "$H/state/\$P.gate.pending" 2>/dev/null
[ "\$MODE" = "--pending" ] && exit 0
cat "$H/fixture/gate-decision"
exit 0
STUB
chmod +x "$H/bin/triage-gate.sh"
cat > "$H/bin/gate-diff.sh" <<STUB
#!/bin/bash
[ -s "$H/fixture/diff" ] || exit 2
cat "$H/fixture/diff"
STUB
chmod +x "$H/bin/gate-diff.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/unblocked-children.sh"; chmod +x "$H/bin/unblocked-children.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"; chmod +x "$H/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
# `gh`, for BOTH the real gate's PR-gate lookup (`gh pr view`) and the
# fingerprint ledger's refresh, which goes through bin/lib/gh-rest.sh and so
# arrives here as `gh api -i -X GET repos/<slug>/pulls/<n>` — headers included,
# because gh_rest reads the status line to tell 404 from "come back later".
# Every invocation is logged so the "one pass per tick, never per key" claim is
# an assertion and not a hope; the PR's state comes from a fixture file so the
# test drives the merge, and a fixture of `RATELIMIT` drives the 403 path.
cat > "$H/bin/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$H/fixture/gh-calls"
ST=\$(cat "$H/fixture/pr12-state" 2>/dev/null || echo OPEN)
case "\$*" in
  *rate_limit*)
    # gh_budget_refresh reads this WITHOUT -i; a plain body is what it wants.
    echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}'
    exit 0 ;;
esac
case "\$1" in
  pr) [ "\$2" = view ] && { echo "\$ST"; exit 0; } ;;
  api)
    case "\$ST" in
      RATELIMIT) printf 'HTTP/2 403\r\n\r\n{"message":"API rate limit exceeded"}\n'; exit 1 ;;
      GONE)      printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
      MERGED)    printf 'HTTP/2 200\r\n\r\n{"state":"closed","merged_at":"2026-09-19T05:00:00Z"}\n'; exit 0 ;;
      CLOSED)    printf 'HTTP/2 200\r\n\r\n{"state":"closed","merged_at":null}\n'; exit 0 ;;
      *)         printf 'HTTP/2 200\r\n\r\n{"state":"open","merged_at":null}\n'; exit 0 ;;
    esac ;;
esac
exit 1
STUB
chmod +x "$H/bin/gh"
# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt|@file>
# It writes a COST ROW as well as a prompt file: the assertion this suite is
# really making is about money, and a call that left no row in logs/cost.csv is
# indistinguishable from one that never happened — which is exactly the shape
# the fleet rule says never to accept as proof.
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
D="${CALLDIR:?}"
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
F=$(mktemp "$D/prompt-XXXXXXXX.txt")
printf '%s' "$PR" > "$F"
printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$D/calls.tsv"
printf '2026-09-19T00:00:00Z,box,%s,%s,claude,%s,,,,,,,0.9100\n' "$2" "$1" "$3" >> "$COSTCSV"
echo "tickets=1 done" > "$5"
exit "${STUB_RC:-0}"
STUB
chmod +x "$H/bin/agent-call.sh"

mkdir -p "$H/fixture"
# The live board fingerprint. `comments` is the field a client reply moves, and
# Part C bumps it without touching the diff line.
fpjson() { printf '{"issues":[{"number":%s,"state":"OPEN","title":"c","comments":%s,"updatedAt":"2026-09-19T05:00:00Z"}],"prs":[]}' "$K" "${1:-0}"; }

held() { [ -e "$1" ] || return 1; if ( exec 9>"$1" || exit 0; flock -n 9 || exit 1 ) 2>/dev/null; then return 1; fi; return 0; }
ncalls() { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
ncost()  { grep -c ',triage,' "$H/logs/cost.csv" 2>/dev/null | tr -d ' ' || true; }
ngh()    { grep -c . "$H/fixture/gh-calls" 2>/dev/null | tr -d ' ' || true; }
# ONLY the PR-state reads. The pass also touches `gh api rate_limit` (the budget
# gate, cached) and `gh auth token`; counting those would conflate "how many PRs
# did we look up" with "how much bookkeeping happened", and the claim under test
# is the first one.
npr()    { grep -c 'pulls/' "$H/fixture/gh-calls" 2>/dev/null | tr -d ' ' || true; }
fpfile() { printf '%s/state/triage-shards/%s/%s.fp\n' "$H" "$P" "$K"; }

# The two queue lines of case (a): same ticket, same machine facts (it names
# PR #12 and project=project-5 either way), different session prose and a
# different "Re-checked" stamp. This is what a no-action tick REWRITES, and it
# is what used to buy another session.
QL1="TK-$K tid-$K — ready to build, waiting on PR #12 to merge; Re-checked 2026-09-19T05:00:00Z project=project-5"
QL2="TK-$K tid-$K — still waiting on PR #12; nothing to do this tick. Re-checked 2026-09-19T05:40:00Z project=project-5"

reset() { # reset <gate-decision> <diff-text> — a fresh box, no stamps anywhere
  rm -rf "$T/calls"; mkdir -p "$T/calls"
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"; scratch_rm "$H/builds"
  model_routes_fixture "$H" project-5 || exit 1   # the reset above took the model-routes cache with it
  mkdir -p "$H/state" "$H/locks" "$H/logs" "$H/builds"
  rm -f "$H/flags/triage-shards-off"
  fpjson 0 > "$H/fixture/pending.json"
  fpjson 0 > "$H/state/$P.gate.json"
  echo "$1" > "$H/fixture/gate-decision"
  printf '%s' "$2" > "$H/fixture/diff"
  : > "$H/logs/READY-QUEUE.log"
  : > "$H/logs/cost.csv"
  : > "$H/fixture/gh-calls"
  echo OPEN > "$H/fixture/pr12-state"
  # The carried-forward PR-state ledger, seeded the way a box that has already
  # seen PR #12 once would have it. NOT queuefp line 3 — that file is the gate's
  # and the gate rewrites it; Part B is where that is proven.
  printf '12\tOPEN\t%s\n' "$NOW" > "$H/state/$P.prstates"
}
nextick() { rm -rf "$T/calls"; mkdir -p "$T/calls"; : > "$H/logs/cost.csv"; : > "$H/fixture/gh-calls"; }
run() { CALLDIR="$T/calls" COSTCSV="$H/logs/cost.csv" PATH="$H/bin:$PATH" "$@" "$H/bin/run-triage.sh" "$P" >/dev/null 2>&1; }
settle() { # wait for the detached shards to land, then one grace second
  local i=0 busy
  while [ "$i" -lt 80 ]; do
    if [ "$(ncalls)" -ge "${1:-0}" ]; then
      busy=0
      for L in "$H"/locks/triage-key-*.lock; do held "$L" && busy=1; done
      [ "$busy" = 0 ] && { sleep 1; return 0; }
    fi
    i=$((i+1)); sleep 0.25
  done
  sleep 1; return 1
}

# ═══ PART A — the guard, end to end through the real bin/run-triage.sh ═══════

# ---------- (a) an identical world is not bought twice -----------------------
reset "RUN queue-pending" ""
printf '%s\n' "$QL1" > "$H/logs/READY-QUEUE.log"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(a) the first tick over a new queue line must buy exactly one shard (got $(ncalls))"
[ "$(ncost)" = 1 ] && ok || bad "(a) the first shard must leave one stage=triage cost row (got $(ncost))"
[ -s "$(fpfile)" ] && ok || bad "(a) the dispatcher must persist state/triage-shards/$P/$K.fp BEFORE it spends — nothing was written"

nextick
printf '%s\n' "$QL2" > "$H/logs/READY-QUEUE.log"
run
settle 0 >/dev/null
[ "$(ncalls)" = 0 ] && ok || bad "(a) a re-stamped, re-worded, otherwise IDENTICAL queue line must buy 0 shards (got $(ncalls) — this is the \$896/day defect)"
[ "$(ncost)" = 0 ] && ok || bad "(a) the skipped tick must write no cost row (got $(ncost))"
grep -qE "triage shards: $K .*unchanged" "$H/logs/$P.log" \
  && ok || bad "(a) the skip must log ONE line naming the key and 'unchanged' — a saving nobody can read is a saving nobody trusts"

# ---------- (b) a referenced PR that merged is a NEW world --------------------
nextick
printf '12\tMERGED\t%s\n' "$NOW" > "$H/state/$P.prstates"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(b) a referenced PR flipping OPEN->MERGED must dispatch the shard (got $(ncalls))"
[ "$(ncost)" = 1 ] && ok || bad "(b) the dispatched shard must leave its cost row (got $(ncost))"

# ---------- (c) a finished build for this key is a NEW world ------------------
nextick
printf '%s\n' "$QL2" > "$H/logs/READY-QUEUE.log"
run                                   # settle the world: same fp, no shard
settle 0 >/dev/null
[ "$(ncalls)" = 0 ] && ok || bad "(c) precondition: the unchanged world must be quiet before the build lands (got $(ncalls))"
nextick
mkdir -p "$H/builds/$P-TK-$K-202609190101"
echo "PR_CREATED https://github.com/example-org/project-5/pull/99" > "$H/builds/$P-TK-$K-202609190101/RESULT"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(c) a new RESULT dir for this key must dispatch the shard (got $(ncalls)) — a finished build whose close-out is deduped away is a client who never hears back"

# ---------- (d) the stamp ages out, dispatches once, and restamps -------------
reset "RUN queue-pending" ""
printf '%s\n' "$QL1" > "$H/logs/READY-QUEUE.log"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(d) precondition: the first tick must dispatch (got $(ncalls))"
FPVAL=$(head -1 "$(fpfile)" 2>/dev/null)
# backdate the stamp past the 4h TTL, leaving the fingerprint itself alone
printf '%s\n%s\n' "$FPVAL" "$(( NOW - 15000 ))" > "$(fpfile)"
nextick
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(d) a stamp older than TRIAGE_SHARD_FP_TTL_S must dispatch again (got $(ncalls))"
NEWTS=$(sed -n 2p "$(fpfile)" 2>/dev/null)
case "$NEWTS" in ''|*[!0-9]*) NEWTS=0 ;; esac
[ "$NEWTS" -ge "$NOW" ] && ok || bad "(d) the aged-out dispatch must RESTAMP the fingerprint (stamp is $NEWTS, tick ran at >= $NOW) — without that it re-dispatches every tick for ever"
nextick
run
settle 0 >/dev/null
[ "$(ncalls)" = 0 ] && ok || bad "(d) after the restamp the next tick must be quiet again (got $(ncalls)) — 'dispatches once' is the whole point of the TTL"

# ---------- (e) an unreadable fingerprint fails OPEN --------------------------
: > "$(fpfile)"
nextick
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(e) a 0-byte .fp must dispatch (fail open) — a guard that reads corruption as 'already paid' never answers the ticket again (got $(ncalls))"
grep -qE "triage shards: $K .*(fingerprint|unreadable)" "$H/logs/$P.log" \
  && ok || bad "(e) the fail-open must say so in one log line"
printf 'not-a-fingerprint\nnot-a-stamp\n' > "$(fpfile)"
nextick
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(e) a garbage .fp must dispatch too (got $(ncalls))"

# ---------- (f) the knob is env-resolved like its neighbours ------------------
# TRIAGE_SHARD_FP_TTL_S=0 is the off switch an operator reaches for at 3am: a
# TTL of zero can never be "younger than", so every key dispatches exactly as it
# did before this change.
reset "RUN queue-pending" ""
printf '%s\n' "$QL1" > "$H/logs/READY-QUEUE.log"
run
settle 1 >/dev/null
nextick
printf '%s\n' "$QL2" > "$H/logs/READY-QUEUE.log"
run env TRIAGE_SHARD_FP_TTL_S=0
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(f) TRIAGE_SHARD_FP_TTL_S=0 must restore the old behaviour exactly (got $(ncalls))"
nextick
echo 'TRIAGE_SHARD_FP_TTL_S=0' >> "$H/env/global.env"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(f) the knob must resolve from env/global.env too, like every other TRIAGE_SHARD_* knob (got $(ncalls))"
sed -i'' -e '/TRIAGE_SHARD_FP_TTL_S/d' "$H/env/global.env"

# ---------- (g) the skip HOLDS: five quiet ticks, not one --------------------
reset "RUN queue-pending" ""
printf '%s\n' "$QL1" > "$H/logs/READY-QUEUE.log"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(g) precondition: the first tick must dispatch (got $(ncalls))"
QUIET=1
for i in 1 2 3 4 5; do
  nextick
  # the session re-stamps its own queue line every quiet tick, which is the churn
  printf '%s tick %s\n' "$QL2" "$i" > "$H/logs/READY-QUEUE.log"
  run
  settle 0 >/dev/null
  [ "$(ncalls)" = 0 ] || { QUIET=0; break; }
done
[ "$QUIET" = 1 ] && ok || bad "(g) five consecutive unchanged ticks must buy nothing — a skip that only holds for one tick halves the waste instead of removing it"
python3 -c "
import json,sys
fp=json.load(open('$H/state/$P.gate.json'))
sys.exit(0 if $K in [i['number'] for i in fp['issues']] else 1)" \
  && ok || bad "(g) a queue-only key skipped as unchanged must NOT be dropped from the consumed board fingerprint"

# ═══ PART B — the PR-state input, against the REAL bin/triage-gate.sh ════════
# BLOCK 1 of the review. The gate is the script that owns state/<p>.queuefp, and
# it writes the PR-state vector into line 3 on ONE branch and erases it on the
# others. These cases run that script for real, with gh stubbed, and assert the
# fingerprint does not move across the sequence it produces.

gatefp() { # gatefp -> the fingerprint for K, exactly as the dispatcher takes it
  # ingest THEN refresh THEN fingerprint — the same three steps, in the same
  # order, that bin/lib/rt/shards.sh runs once per tick. Doing only the ingest
  # here would under-model the real flow and show a `?`->OPEN flip on the first
  # tick that the dispatcher does not actually have.
  ( . "$H/bin/lib/triage-shards-lib.sh"
    PATH="$H/bin:$PATH"
    triage_prstates_ingest "$H" "$P"
    triage_prstates_refresh "$H" "$P" "$H/fixture/units"
    triage_shard_fp "$H" "$P" "$K" 1 "$H/fixture/units" )
}
gaterun() { HARNESS="$H" PATH="$H/bin:$PATH" "$H/bin/real-triage-gate.sh" "$P" 2>/dev/null; }
qfplines() { grep -c . "$H/state/$P.queuefp" 2>/dev/null | tr -d ' ' || true; }
backdate() { # backdate <seconds> — age the gate's own stamp without touching the hash
  local f="$H/state/$P.queuefp" h s v
  [ -s "$f" ] || return 0
  h=$(sed -n 1p "$f"); s=$(sed -n 2p "$f"); v=$(sed -n 3p "$f")
  printf '%s\n%s\n' "$h" "$(( s - $1 ))" > "$f"
  [ -n "$v" ] && printf '%s\n' "$v" >> "$f"
  return 0
}

reset "RUN queue-pending" ""
rm -f "$H/state/$P.prstates"          # a box that has never seen PR #12
printf '%s\t%s\t%s\n' "$K" queue "$QL1" > "$H/fixture/units"
printf '%s\n' "$QL1" > "$H/logs/READY-QUEUE.log"

B1=$(gaterun); FP1=$(gatefp)
[ "$(qfplines)" = 2 ] && ok || bad "(B) t1: the real gate's first write must be 2 lines, no PR vector (got $(qfplines): $B1)"
printf '%s\n' "$QL2" > "$H/logs/READY-QUEUE.log"
B2=$(gaterun); FP2=$(gatefp)
[ "$(qfplines)" = 2 ] && ok || bad "(B) t2: a reworded queue line must still write 2 lines (got $(qfplines): $B2)"
backdate 3000                          # a quiet stretch past the gate's 45m window
B3=$(gaterun); FP3=$(gatefp)
[ "$(qfplines)" = 3 ] && ok || bad "(B) t3: after 45 quiet minutes the gate must write its PR vector as line 3 (got $(qfplines): $B3)"
grep -q '12=OPEN' "$H/state/$P.queuefp" && ok || bad "(B) t3: line 3 must carry 12=OPEN — the fixture gh says the PR is open"
printf '%s tick 4\n' "$QL2" > "$H/logs/READY-QUEUE.log"
B4=$(gaterun); FP4=$(gatefp)
[ "$(qfplines)" = 2 ] && ok || bad "(B) t4: the next reworded tick must drop back to 2 lines — this is the erasure the fingerprint must survive (got $(qfplines): $B4)"

if [ "$FP1" = "$FP2" ] && [ "$FP2" = "$FP3" ] && [ "$FP3" = "$FP4" ] && [ -n "$FP1" ]; then ok
else bad "(B) the fingerprint must not move across the real gate's 2/2/3/2-line sequence for an unchanged world (got $FP1 $FP2 $FP3 $FP4) — each flip is a session bought for nothing, twice per 45-minute cycle"; fi

# and a real merge, seen through the same sequence, MUST move it
echo MERGED > "$H/fixture/pr12-state"
backdate 3000
B5=$(gaterun); FP5=$(gatefp)
[ -n "$FP5" ] && [ "$FP5" != "$FP4" ] && ok \
  || bad "(B) a PR that actually merged must move the fingerprint (got $FP5 vs $FP4, gate said $B5)"

# ---------- (B2) the ledger refreshes itself when the gate never looks --------
# On a busy queue the gate's QFP keeps moving, so it NEVER reaches its
# 45-minute PR lookup and line 3 is never written. The ledger refreshes itself
# by REST in that case — once per tick, for the numbers the queue names, never
# per key.
reset "RUN queue-pending" ""
rm -f "$H/state/$P.prstates"
printf '%s\n' "$QL1" > "$H/logs/READY-QUEUE.log"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(B2) precondition: the first tick must dispatch (got $(ncalls))"
grep -q '^12	OPEN' "$H/state/$P.prstates" 2>/dev/null \
  && ok || bad "(B2) the dispatcher must refresh the PR-state ledger itself when the gate left no vector — got: $(cat "$H/state/$P.prstates" 2>/dev/null)"
[ "$(npr)" = 1 ] && ok \
  || bad "(B2) the one PR the queue names must be read exactly once (PR reads: $(npr), all gh calls: $(ngh))"
nextick
printf '%s\n' "$QL2" > "$H/logs/READY-QUEUE.log"
run
settle 0 >/dev/null
[ "$(ncalls)" = 0 ] && ok || bad "(B2) the next tick over the same world must be quiet (got $(ncalls))"
[ "$(npr)" = 0 ] && ok || bad "(B2) a fresh ledger entry must not be re-fetched every tick (PR reads: $(npr))"
nextick
echo MERGED > "$H/fixture/pr12-state"
printf '12\tOPEN\t%s\n' "$(( NOW - 4000 ))" > "$H/state/$P.prstates"   # aged past the 45m window
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(B2) a stale ledger entry must be refreshed and a merge must dispatch WITHOUT waiting for the 4h TTL (got $(ncalls))"

# ---------- (B2b) three keys naming one PR is still ONE read ------------------
# "One pass per tick, never per key" cannot be proven with a single key. Three
# queued tickets all waiting on PR #12: the refresh runs once over the tick's
# whole unit list, so the PR is read once and not three times — which is the
# difference between a bounded read and one that scales with the backlog.
reset "RUN queue-pending" ""
rm -f "$H/state/$P.prstates"
{ printf '%s\n' "$QL1"
  printf 'TK-564 tid-564 — waiting on PR #12 to merge project=project-5\n'
  printf 'TK-565 tid-565 — waiting on PR #12 to merge project=project-5\n'; } > "$H/logs/READY-QUEUE.log"
run
settle 3 >/dev/null
[ "$(ncalls)" = 3 ] && ok || bad "(B2b) precondition: three queued tickets must buy three shards on the first tick (got $(ncalls))"
[ "$(npr)" = 1 ] && ok \
  || bad "(B2b) three keys naming PR #12 must produce ONE PR read, not one per key (PR reads: $(npr))"

# ---------- (B4) a rate-limited read is UNVERIFIABLE, not an answer ----------
# The whole reason the refresh goes through bin/lib/gh-rest.sh: a raw `gh` call
# collapses "GitHub said 404" and "GitHub said come back later" into one empty
# string (incident #768). A 403 here must leave the carried-forward OPEN and its
# stamp exactly as they were — turning a known state into `?` would move every
# fingerprint that names the PR and buy a session for each of them.
reset "RUN queue-pending" ""
printf '%s\n' "$QL1" > "$H/logs/READY-QUEUE.log"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(B4) precondition: the first tick must dispatch (got $(ncalls))"
BEFORE=$(cat "$H/state/$P.prstates" 2>/dev/null)
nextick
echo RATELIMIT > "$H/fixture/pr12-state"
printf '12\tOPEN\t%s\n' "$(( NOW - 4000 ))" > "$H/state/$P.prstates"   # stale, so it WILL be read
printf '%s\n' "$QL2" > "$H/logs/READY-QUEUE.log"
run
settle 0 >/dev/null
[ "$(ncalls)" = 0 ] && ok || bad "(B4) a rate-limited PR read must not re-buy an unchanged key (got $(ncalls))"
grep -q '^12	OPEN' "$H/state/$P.prstates" 2>/dev/null \
  && ok || bad "(B4) an UNVERIFIABLE read must leave the carried-forward value alone — got: $(cat "$H/state/$P.prstates" 2>/dev/null)"
[ "$(awk -F'\t' '$1==12{print $3}' "$H/state/$P.prstates" 2>/dev/null)" = "$(( NOW - 4000 ))" ] \
  && ok || bad "(B4) an UNVERIFIABLE read must leave the STAMP alone too, or the next tick believes a value nobody confirmed"

# ---------- (B5) a 404 is a real answer and is cached --------------------------
nextick
echo GONE > "$H/fixture/pr12-state"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(B5) a PR that 404s is a change of state and must dispatch once (got $(ncalls))"
grep -q '^12	ABSENT' "$H/state/$P.prstates" 2>/dev/null \
  && ok || bad "(B5) a 404 must be cached as ABSENT — got: $(cat "$H/state/$P.prstates" 2>/dev/null)"
nextick
run
settle 0 >/dev/null
[ "$(ncalls)" = 0 ] && ok || bad "(B5) the cached ABSENT must then be quiet, not re-asked every tick for ever (got $(ncalls))"

# ---------- (B3) a cap deferral deletes queuefp; the ledger survives ----------
# bin/lib/rt/shards.sh drops state/<p>.queuefp whenever the hourly cap withheld
# a unit, and TRIAGE_SHARD_CAPS=1 is live on all six boxes. When the PR vector
# lived in that file, the next tick re-bought every byte-identical key.
reset "RUN queue-pending" ""
printf '%s\n' "$QL1" > "$H/logs/READY-QUEUE.log"
printf 'deadbeefdeadbeef\n%s\n12=OPEN;\n' "$NOW" > "$H/state/$P.queuefp"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(B3) precondition: the first tick must dispatch (got $(ncalls))"
nextick
rm -f "$H/state/$P.queuefp"            # exactly what the cap path does
printf '%s\n' "$QL2" > "$H/logs/READY-QUEUE.log"
run
settle 0 >/dev/null
[ "$(ncalls)" = 0 ] && ok || bad "(B3) losing state/$P.queuefp to a cap deferral must NOT re-buy an unchanged key (got $(ncalls))"
[ -s "$H/state/$P.prstates" ] && ok || bad "(B3) the PR-state ledger must survive the queuefp deletion"

# ═══ PART C — a skipped key must never hide a client reply ══════════════════
# BLOCK 2 of the review. The diff line is a statement about what we CONSUMED;
# the ticket's entry in the live fingerprint is the world. These cases move only
# the world and expect a dispatch, and move only the diff VERB and expect quiet.

reset "RUN board-changed" "board issues: CHANGED $K \"c\" (comments: 0 -> 1)"
fpjson 1 > "$H/fixture/pending.json"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(C) precondition: a board-changed tick must dispatch (got $(ncalls))"
nextick
run                                   # identical line, identical world
settle 0 >/dev/null
[ "$(ncalls)" = 0 ] && ok || bad "(C) an identical board line over an identical world must be skipped (got $(ncalls))"

# the re-armed shape: gate-diff now calls the SAME ticket NEW, with no counts in
# the line at all. Nothing about the ticket changed, so it must stay quiet.
nextick
printf 'board issues: NEW %s "c"' "$K" > "$H/fixture/diff"
run
settle 0 >/dev/null
[ "$(ncalls)" = 0 ] && ok || bad "(C) NEW vs CHANGED is a fact about state/$P.gate.json, not about the ticket — it must not buy a session (got $(ncalls))"

# THE DEFECT: a client replies. The diff line is still the count-less `NEW`
# line, byte-identical — only the live fingerprint moved.
nextick
fpjson 2 > "$H/fixture/pending.json"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(C) a client reply must dispatch even when the diff line is the count-less NEW line (got $(ncalls)) — this is a client waiting up to 4h for an answer"
F=$(ls "$T/calls"/prompt-*.txt 2>/dev/null | head -1)
grep -q "Work ONLY ticket $K this tick" "${F:-/dev/null}" \
  && ok || bad "(C) the dispatched shard must be scoped to $K"

# and the same reply reaching the box as a webhook wake, which scopes off the
# very same diff line
nextick
fpjson 3 > "$H/fixture/pending.json"
echo "RUN event-wake" > "$H/fixture/gate-decision"
printf '%s\n' "$K" > "$H/state/wake-keys-$P"
run
settle 1 >/dev/null
[ "$(ncalls)" = 1 ] && ok || bad "(C) an event-wake carrying the same key must dispatch on a new comment too (got $(ncalls))"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
