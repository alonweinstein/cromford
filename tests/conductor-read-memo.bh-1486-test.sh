#!/bin/bash
# tests/conductor-read-memo.bh-1486-test.sh — the merge conductor's READ MEMO
# and its per-project cadence hold (BH-1486).
#
# WHAT IS UNDER TEST, AND WHY IT IS DRIVEN AND NOT GREPPED. The claim of this
# ticket is a NUMBER: "the same read is not made twice". The only honest way to
# assert that is to run the whole tick against a stub `gh` that RECORDS every
# argv, and count the lines. A `grep -q read_memo_get bin/merge-conductor.sh`
# passes just as happily on a memo nothing calls, on a memo that stores the
# wrong key, and on a memo whose TTL never expires.
#
# THE FOUR STORES, and the sections that pin each:
#   A   the per-tick stack-parent memo: two children of one parent branch cost
#       ONE `pulls?state=all&head=owner:<branch>` read, not one each. A2 proves
#       a refused read (NONE) is never stored; A3 proves nothing waits on a
#       sibling worker's lifetime (flock -w 20, then an unmemoised read).
#   B   the cross-tick CI memo: a terminal answer (green|red) on an unchanged
#       (head, updated_at, attempts fingerprint) is not re-read. B2-B7 are the
#       adversarial negatives — every one of them must RE-READ.
#   C   the cross-tick iron-law SCAN memo, and C2 that an UNREAD diff is never
#       memoised (D11: absent is not "no hits").
#   D   the memo is OFF when the list carries no `updatedAt` (`-`), which is
#       what keeps every existing conductor fixture byte-identical.
#   E   the cadence hold: a project younger than MC_TICK_SECS logs
#       `TICK <p> held … (decision=held)` and makes NO GitHub read at all; E3
#       is the knob's own resolution through lane_knob.
#   F   the ETag half: the second tick's PR-object read goes out with
#       If-None-Match, answers 304, and lands in the per-project
#       `gh-etag lane=merge-conductor:<P> fetched= cached=` counter.
#
# Every section resets state/ and logs/ so a count is about the ticks THIS
# section ran. The stub `gh` fails the run on any write verb: this lane is
# observe-only here, and a memo that changed a decision path into a write would
# fail on the write, not on the count.
# Run from anywhere: tests/conductor-read-memo.bh-1486-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# BH-1247: catalog/lanes.json is GENERATED and not committed; section E3 reads
# the registry through the renderer, never from the checkout.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ============================================================================
# 0. The scratch harness
# ============================================================================
# fixture: tests/lib/fixture-harness.sh (BH-1196).
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
fx_conductor_tick "$DIR" "$T" || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
[ -d "$DIR/bin/lib/mc" ] || exit 1               # impact: and every mc module it reads through
# THE ETAG CACHE RIDES ALONG (section F). fx_mc_harness copies gh-rest.sh but
# not its ETag half, and gh-rest.sh degrades silently without it — so a suite
# that claims a 304 without this line would be green on a conductor that never
# sent an If-None-Match in its life.
cp "$DIR/bin/lib/gh-rest-etag.sh" "$T/h/bin/lib/" || exit 1

H1=aaaaaaaa1111; H2=bbbbbbbb2222; H3=cccccccc3333
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\nissuer example-org/issuer - - 3 box-issuer\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"

# A build record per PR, each APPROVE bound to that PR's own head, so nothing
# here is HEAD_MOVED and nothing buys a detached re-review: PR 11 and PR 13
# classify READY (the iron-law scan runs) and PR 12 sits WAIT_CI on a head
# whose runs are still in flight.
mkrec() { # mkrec <dir> <pr number> <reviewed sha>
  mkdir -p "$T/h/builds/$1"
  echo "PR_CREATED https://github.com/example-org/demo-os/pull/$2" > "$T/h/builds/$1/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/$1/review.md"
  echo "$3" > "$T/h/builds/$1/reviewed-sha"
}
mkrec demo-os-TK-11-202609120001 11 "$H1"
mkrec demo-os-TK-12-202609120002 12 "$H2"
mkrec demo-os-TK-13-202609120003 13 "$H3"

# ---- the fixture's answer files --------------------------------------------
# Every arm of the stub below reads one of these, so a section changes an
# ANSWER (CI went green, the parent is 403, the diff is unreadable) with one
# write instead of a second stub.
rm -f "$T/etag-on"
printf 'completed|success\n' > "$T/ci-h1"
printf 'in_progress|\n'      > "$T/ci-h2"
printf 'completed|success\n' > "$T/ci-h3"
printf 'open\n'              > "$T/parent-mode"
printf 'ok\n'                > "$T/diff-mode"
rm -f "$T/slow-parent" "$T/slow-parent-seen"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*)
    echo "WRITE VERB IN OBSERVE MODE: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  # ---- the stacked parent read (mc_stack_parent -> gh_rest_pr_list) --------
  # ABOVE the generic \`-i -X GET\` arm: gh_rest spells it
  # \`repos/<slug>/pulls -f state=all -f head=<owner>:<branch> -F per_page=1\`.
  *"-f head=example-org:"*)
    if [ -f "$T/slow-parent" ] && [ ! -f "$T/slow-parent-seen" ]; then
      : > "$T/slow-parent-seen"
      sleep 22   # determinism: ok the 20 s flock timeout in stack_parent_memo IS the subject of section A3 — this sleep holds the lock PAST that deadline on purpose, and it is the first read only (the marker above), so the tick is bounded by this one 22 s read and nothing waits on a condition
    fi
    case "\$(cat "$T/parent-mode" 2>/dev/null)" in
      403) restpr --raw 403 '{"message":"forbidden"}' ;;
      none) restpr --raw 200 '[]' ;;
      *) restpr --raw 200 '[{"state":"open","merged_at":null,"html_url":"https://github.com/example-org/demo-os/pull/40"}]' ;;
    esac ;;
  # ---- the iron-law diff --------------------------------------------------
  # ABOVE the PR-object arms: mc_pr_diff's argv is that same
  # \`.../pulls/<n>\` path plus \`-H Accept: application/vnd.github.v3.diff\`,
  # so a PR-object arm placed first would answer the diff read with a JSON PR
  # object — a 200 the scan then reads as a clean diff, and C2 would be green
  # on a conductor that never saw a refusal.
  *"v3.diff"*)
    case "\$(cat "$T/diff-mode" 2>/dev/null)" in
      403) restpr --raw 403 '{"message":"forbidden"}' ;;
      *) restpr --diff ;;
    esac ;;
  # ---- the PR object ------------------------------------------------------
  *"api -i -X GET repos/example-org/demo-os/pulls/11"*) restpr OPEN "$H1" ticket/TK-11 main "" ;;
  # TEST-CHANGE (BH-1592): section F's ETag arm moved here from the closed
  # list, which the conductor no longer walks. PR 30 has a WAIT_CI row and is
  # not on the open list, so the closed-unmerged pass reads it by number through
  # gh_rest on every tick while it answers open: that is the steady-state read
  # F arms now (the read memo takes the open PRs' object reads off tick 2).
  *"api -i -X GET repos/example-org/demo-os/pulls/30"*)
    if [ -f "$T/etag-on" ]; then
      case "\$*" in
        *'If-None-Match: "e1"'*)
          printf '%s\n' "\$*" >> "$T/gh-304.txt"
          printf 'HTTP/1.1 304 Not Modified\r\nETag: "e1"\r\n\r\n'; exit 0 ;;
      esac
      printf 'HTTP/1.1 200 OK\r\nETag: "e1"\r\n\r\n'; restpr OPEN deadbeef30 ticket/TK-30 main "" | tail -1; exit 0
    fi
    restpr OPEN deadbeef30 ticket/TK-30 main "" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/12"*) restpr OPEN "$H2" ticket/TK-12 main "" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/13"*) restpr OPEN "$H3" ticket/TK-13 main "" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/21"*) restpr OPEN "$H1" ticket/TK-21 ticket/TK-40 "" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/22"*) restpr OPEN "$H1" ticket/TK-22 ticket/TK-40 "" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/40"*) restpr OPEN deadbeef40 ticket/TK-40 main "" ;;
  # ---- the lists ----------------------------------------------------------
  *"pr list -R example-org/demo-os --state open"*) cat "$T/openlist" ;;
  *"pr list -R example-org/issuer --state open"*) echo "[]" ;;
  # The CLOSED list is the conductor's one steady-state gh_rest read per
  # project per tick, so it is what section F arms the ETag on: it is made on
  # EVERY tick whatever the PRs are doing, which is exactly the traffic
  # If-None-Match exists to take off the counted budget.
  *"repos/example-org/demo-os/pulls?state=closed"*)
    if [ -f "$T/etag-on" ]; then
      case "\$*" in
        *'If-None-Match: "e1"'*)
          printf '%s\n' "\$*" >> "$T/gh-304.txt"
          printf 'HTTP/1.1 304 Not Modified\r\nETag: "e1"\r\n\r\n'; exit 0 ;;
      esac
      printf 'HTTP/1.1 200 OK\r\nETag: "e1"\r\n\r\n'; printf '[]'; exit 0
    fi
    restpr --raw 200 '[]' ;;
  *"pulls?state=closed"*) restpr --raw 200 '[]' ;;
  # ---- CI: through gh_rest since BH-1586; this stub sends no ETag on it, so
  # it still never 304s and every read the memo does not save is counted -----
  *"actions/runs?head_sha=$H1"*) restpr --runs - < "$T/ci-h1" ;;
  *"actions/runs?head_sha=$H2"*) restpr --runs - < "$T/ci-h2" ;;
  *"actions/runs?head_sha=$H3"*) restpr --runs - < "$T/ci-h3" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# ---- the driver ------------------------------------------------------------
# One whole tick, with a FRESH MC_TICK_ID (the script mints its own), so two
# calls are two ticks exactly as two cron fires are.
tick() { # tick [VAR=value ...]
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
      MC_MAIN_RED_DETECT=0 \
      env "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>>"$T/tick.err" ) || true
}
# Every section starts from nothing: no rows, no memo files, no counted calls.
fresh() {
  rm -rf "$T/h/state" "$T/h/logs" "$T/h/locks"
  mkdir -p "$T/h/state" "$T/h/logs" "$T/h/locks"
  : > "$T/gh-calls.txt"; : > "$T/gh-writes.txt"; : > "$T/gh-304.txt"
  printf 'open\n' > "$T/parent-mode"; printf 'ok\n' > "$T/diff-mode"
  printf 'completed|success\n' > "$T/ci-h1"; printf 'in_progress|\n' > "$T/ci-h2"
  printf 'completed|success\n' > "$T/ci-h3"
  rm -f "$T/slow-parent" "$T/slow-parent-seen" "$T/etag-on"
}
calls() { grep -c -- "$1" "$T/gh-calls.txt" 2>/dev/null || true; }
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv" 2>/dev/null; }
log_has() { grep -q -- "$1" "$T/h/logs/merge-conductor.log" 2>/dev/null; }

# The two list shapes, one WITH updatedAt (every section but D) and one without.
UPD1=2026-09-22T10:00:00Z
list_stacked() { # list_stacked <updatedAt>
  jq -nc --arg h "$H1" --arg u "$1" '[
    {number:21,url:"https://github.com/example-org/demo-os/pull/21",headRefOid:$h,headRefName:"ticket/TK-21",baseRefName:"ticket/TK-40",isDraft:false,mergeStateStatus:"BLOCKED",mergeable:"MERGEABLE",state:"OPEN",updatedAt:$u},
    {number:22,url:"https://github.com/example-org/demo-os/pull/22",headRefOid:$h,headRefName:"ticket/TK-22",baseRefName:"ticket/TK-40",isDraft:false,mergeStateStatus:"BLOCKED",mergeable:"MERGEABLE",state:"OPEN",updatedAt:$u}]' > "$T/openlist"
}
list_plain() { # list_plain <updatedAt|-> — PR 11 (READY) and PR 12 (CI pending)
  if [ "$1" = "-" ]; then
    jq -nc --arg a "$H1" --arg b "$H2" '[
      {number:11,url:"https://github.com/example-org/demo-os/pull/11",headRefOid:$a,headRefName:"ticket/TK-11",baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN"},
      {number:12,url:"https://github.com/example-org/demo-os/pull/12",headRefOid:$b,headRefName:"ticket/TK-12",baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN"}]' > "$T/openlist"
  else
    jq -nc --arg a "$H1" --arg b "$H2" --arg u "$1" '[
      {number:11,url:"https://github.com/example-org/demo-os/pull/11",headRefOid:$a,headRefName:"ticket/TK-11",baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",updatedAt:$u},
      {number:12,url:"https://github.com/example-org/demo-os/pull/12",headRefOid:$b,headRefName:"ticket/TK-12",baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",updatedAt:$u}]' > "$T/openlist"
  fi
}
list_three() { # list_three <updatedAt> — two READY PRs and one WAIT_CI (section F)
  jq -nc --arg a "$H1" --arg b "$H2" --arg c "$H3" --arg u "$1" '[
    {number:11,url:"https://github.com/example-org/demo-os/pull/11",headRefOid:$a,headRefName:"ticket/TK-11",baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",updatedAt:$u},
    {number:12,url:"https://github.com/example-org/demo-os/pull/12",headRefOid:$b,headRefName:"ticket/TK-12",baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",updatedAt:$u},
    {number:13,url:"https://github.com/example-org/demo-os/pull/13",headRefOid:$c,headRefName:"ticket/TK-13",baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",updatedAt:$u}]' > "$T/openlist"
}
# The COUNTED reads of one tick: every `gh api` line whose path is a PR read
# (a pull object, a pull list, a diff, a check-run list), minus the ones the
# stub answered 304 — a 304 does not count against GitHub's primary limit,
# which is the whole point of the ETag half. The per-repo probes (rulesets,
# .mergify.yml, rate_limit) are excluded on purpose: they are one per repo per
# tick whatever the PRs do, and this ticket is about the per-PR traffic.
pr_reads() {
  grep -c -E '^api (-i -X GET )?repos/[^ ]*(/pulls|actions/runs)' "$T/gh-calls.txt" 2>/dev/null || true
}

# ============================================================================
# A. the per-tick stack-parent memo
# ============================================================================
fresh; list_stacked "$UPD1"
tick
[ "$(calls '-f head=example-org:ticket/TK-40')" = 1 ] && ok || bad "A two children of one parent branch must cost ONE stack-parent read, got $(calls '-f head=example-org:ticket/TK-40')"
[ "$(state_of 'example-org/demo-os#21')" = STACKED_WAIT ] && ok || bad "A PR 21 must be STACKED_WAIT (got '$(state_of 'example-org/demo-os#21')')"
[ "$(state_of 'example-org/demo-os#22')" = STACKED_WAIT ] && ok || bad "A PR 22 must be STACKED_WAIT (got '$(state_of 'example-org/demo-os#22')')"
log_has 'READ-MEMO tick=' && ok || bad "A every project tick must log one READ-MEMO line"
grep -q 'READ-MEMO .*stack_hits=1' "$T/h/logs/merge-conductor.log" && ok || bad "A the READ-MEMO line must count the stack memo hit: $(grep -o 'READ-MEMO.*' "$T/h/logs/merge-conductor.log" | head -2 | tr '\n' ' ')"
[ -s "$T/gh-writes.txt" ] && bad "A observe-only tick used a write verb: $(cat "$T/gh-writes.txt")" || ok

# A2 — a REFUSED parent read answers NONE, and NONE is never memoised.
fresh; list_stacked "$UPD1"; printf '403\n' > "$T/parent-mode"
tick
[ "$(calls '-f head=example-org:ticket/TK-40')" = 2 ] && ok || bad "A2 a refused stack-parent read must not be memoised (want 2 reads, got $(calls '-f head=example-org:ticket/TK-40'))"
[ "$(state_of 'example-org/demo-os#21')" = STACKED_WAIT ] && ok || bad "A2 NONE keeps the child waiting (got '$(state_of 'example-org/demo-os#21')')"

# A3 — nothing waits on a sibling worker's lifetime (D33). The first reader
# holds the memo lock past its 20 s timeout; the second must read unmemoised
# and the tick must still classify both rows.
fresh; list_stacked "$UPD1"; : > "$T/slow-parent"
tick
[ "$(calls '-f head=example-org:ticket/TK-40')" = 2 ] && ok || bad "A3 the waiter must fall back to its own read after the lock timeout (want 2, got $(calls '-f head=example-org:ticket/TK-40'))"
[ "$(state_of 'example-org/demo-os#21')" = STACKED_WAIT ] && [ "$(state_of 'example-org/demo-os#22')" = STACKED_WAIT ] \
  && ok || bad "A3 both children must still classify in this tick (21='$(state_of 'example-org/demo-os#21')' 22='$(state_of 'example-org/demo-os#22')')"
rm -f "$T/slow-parent" "$T/slow-parent-seen"

# ============================================================================
# B. the cross-tick CI memo — terminal answers only
# ============================================================================
CIQ="actions/runs?head_sha=$H1"
fresh; list_plain "$UPD1"
tick; S1=$(state_of 'example-org/demo-os#11'); C1=$(calls "$CIQ")
tick; S2=$(state_of 'example-org/demo-os#11'); C2=$(calls "$CIQ")
[ "$C1" = 1 ] && ok || bad "B tick 1 must read the check runs once (got $C1)"
[ "$C2" = 1 ] && ok || bad "B tick 2 must NOT re-read a green head whose sha and updated_at did not move (got $C2)"
[ -n "$S1" ] && [ "$S1" = "$S2" ] && ok || bad "B the memo must not change the row's state ('$S1' -> '$S2')"
grep -q 'READ-MEMO .*ci_skipped=1' "$T/h/logs/merge-conductor.log" && ok || bad "B tick 2 must report ci_skipped=1"

# B2 — updated_at moved: re-read.
list_plain 2026-09-22T11:00:00Z
tick
[ "$(calls "$CIQ")" = 2 ] && ok || bad "B2 a new updatedAt must re-read the check runs (got $(calls "$CIQ"))"

# B3 — the conductor's own CI write (an attempts marker on this head) moves the
# fingerprint, so the next tick re-reads even with sha and updated_at unchanged.
echo "cikick example-org/demo-os#11 $H1" >> "$T/h/state/merge-conductor/attempts.txt"
tick
[ "$(calls "$CIQ")" = 3 ] && ok || bad "B3 an attempts marker on this head must invalidate the memo (got $(calls "$CIQ"))"

# B4 — TTL 0 is OFF.
tick MC_READ_MEMO_TTL_SECS=0
[ "$(calls "$CIQ")" = 4 ] && ok || bad "B4 MC_READ_MEMO_TTL_SECS=0 must re-read (got $(calls "$CIQ"))"

# B5 — a torn memo line (wrong field count) is a MISS, never a hit.
tick   # re-arm a good memo after B4's uncached read
B5BASE=$(calls "$CIQ")
[ -f "$T/h/state/merge-conductor/read-memo/example-org_demo-os_11.ci" ] \
  && ok || bad "B5 a terminal CI answer must be stored under state/merge-conductor/read-memo/"
printf 'only two\n' > "$T/h/state/merge-conductor/read-memo/example-org_demo-os_11.ci"
tick
[ "$(calls "$CIQ")" = $((B5BASE + 1)) ] && ok || bad "B5 a torn memo file must be re-read (want $((B5BASE + 1)), got $(calls "$CIQ"))"

# B6 — the operator kill switch.
B6BASE=$(calls "$CIQ")
tick MC_READ_MEMO=0
[ "$(calls "$CIQ")" = $((B6BASE + 1)) ] && ok || bad "B6 MC_READ_MEMO=0 must re-read (want $((B6BASE + 1)), got $(calls "$CIQ"))"

# B7 — a NON-terminal answer is never memoised: PR 12's head is in_progress, so
# it is read on every tick for ever.
CIQ2="actions/runs?head_sha=$H2"
fresh; list_plain "$UPD1"
tick; tick; tick
[ "$(calls "$CIQ2")" = 3 ] && ok || bad "B7 a pending head must be re-read every tick (want 3, got $(calls "$CIQ2"))"
[ "$(state_of 'example-org/demo-os#12')" = WAIT_CI ] && ok || bad "B7 PR 12 must stay WAIT_CI (got '$(state_of 'example-org/demo-os#12')')"
[ -f "$T/h/state/merge-conductor/read-memo/example-org_demo-os_12.ci" ] \
  && bad "B7 a pending CI answer must never be stored" || ok

# ============================================================================
# C. the cross-tick iron-law SCAN memo
# ============================================================================
fresh; list_plain "$UPD1"
tick; tick
[ "$(calls 'v3.diff')" = 1 ] && ok || bad "C the diff must be read once across two unchanged ticks (got $(calls 'v3.diff'))"
[ "$(state_of 'example-org/demo-os#11')" = READY ] && ok || bad "C a memoised scan must still classify READY (got '$(state_of 'example-org/demo-os#11')')"
grep -q 'READ-MEMO .*scan_skipped=1' "$T/h/logs/merge-conductor.log" && ok || bad "C tick 2 must report scan_skipped=1"
list_plain 2026-09-22T12:00:00Z
tick
[ "$(calls 'v3.diff')" = 2 ] && ok || bad "C a new updatedAt must re-read the diff (got $(calls 'v3.diff'))"

# C2 — an UNREAD diff is not a clean diff, and is never memoised (D11).
fresh; list_plain "$UPD1"; printf '403\n' > "$T/diff-mode"
tick
log_has 'iron-law scan NOT run' && ok || bad "C2 an unreadable diff must log UNVERIFIABLE"
[ -f "$T/h/state/merge-conductor/read-memo/example-org_demo-os_11.scan" ] \
  && bad "C2 an unread diff must never be memoised as a scan" || ok
tick
[ "$(calls 'v3.diff')" = 2 ] && ok || bad "C2 an unread diff must be re-read next tick (got $(calls 'v3.diff'))"

# ============================================================================
# D. no updatedAt in the list -> the memo is OFF (absent is not unchanged)
# ============================================================================
fresh; list_plain -
tick; tick
[ "$(calls "$CIQ")" = 2 ] && ok || bad "D with no updatedAt the CI memo must be OFF (want 2 reads, got $(calls "$CIQ"))"
[ "$(calls 'v3.diff')" = 2 ] && ok || bad "D with no updatedAt the scan memo must be OFF (want 2 reads, got $(calls 'v3.diff'))"
grep -q 'READ-MEMO .*ci_skipped=0' "$T/h/logs/merge-conductor.log" && ok || bad "D the READ-MEMO line must report ci_skipped=0"

# ============================================================================
# E. the per-project cadence hold
# ============================================================================
fresh; list_plain "$UPD1"
tick MC_TICK_SECS=600
E1=$(calls 'pr list -R example-org/demo-os --state open')
STARTED1=$(jq -r '.started_at' "$T/h/state/merge-conductor/tick-demo-os.json" 2>/dev/null)
# A project with no tick of its own on record ticks: the age is unknown, and
# fail-open on the hold is the rule (an unparseable row must never freeze a
# repo's PRs).
grep -q 'held:' "$T/h/logs/merge-conductor.log" && bad "E the first fire, with no prior tick recorded, must not be held" || ok
tick MC_TICK_SECS=600
[ "$(calls 'pr list -R example-org/demo-os --state open')" = "$E1" ] && ok || bad "E a held project must make NO GitHub read (want $E1, got $(calls 'pr list -R example-org/demo-os --state open'))"
grep -q 'TICK demo-os held' "$T/h/logs/merge-conductor.log" && ok || bad "E the hold must be logged"
grep -q 'TICK demo-os held.*(decision=held)' "$T/h/logs/merge-conductor.log" && ok || bad "E the hold line must carry (decision=held)"
[ "$(jq -r '.started_at' "$T/h/state/merge-conductor/tick-demo-os.json" 2>/dev/null)" = "$STARTED1" ] \
  && ok || bad "E a hold must not write tick metrics (started_at moved)"
# An unparseable tick row is the fail-open case: the project ticks.
echo 'not json' > "$T/h/state/merge-conductor/tick-demo-os.json"
E2BASE=$(calls 'pr list -R example-org/demo-os --state open')
tick MC_TICK_SECS=600
[ "$(calls 'pr list -R example-org/demo-os --state open')" -gt "$E2BASE" ] \
  && ok || bad "E an unparseable tick row must fail OPEN (the project ticks)"

# E2 — the default is 0 and 0 is every cron fire, which is today's behaviour.
fresh; list_plain "$UPD1"
tick MC_TICK_SECS=0
E2=$(calls 'pr list -R example-org/demo-os --state open')
tick MC_TICK_SECS=0
[ "$(calls 'pr list -R example-org/demo-os --state open')" = $((E2 * 2)) ] && ok || bad "E2 MC_TICK_SECS=0 must tick every fire (want $((E2 * 2)), got $(calls 'pr list -R example-org/demo-os --state open'))"
grep -q 'TICK demo-os held' "$T/h/logs/merge-conductor.log" && bad "E2 nothing may be held at MC_TICK_SECS=0" || ok

# E3 — the knob itself, through lane_knob and the RENDERED registry.
mkdir -p "$T/lk/bin/lib" "$T/lk/state" "$T/lk/logs" "$T/lk/catalog" "$T/lk/flags"
cp "$DIR/bin/lib/lane-gate.sh" "$T/lk/bin/lib/" || exit 1
cp "$(rendered_registry)" "$T/lk/catalog/lanes.json" || exit 1
cat > "$T/lk/bin/stub-jobs-client.sh" <<'SH'
_jobs_req() {
  local out="[]" k v
  for kv in ${ROWS:-}; do
    k="${kv%%=*}"; v="${kv#*=}"
    out=$(printf '%s' "$out" | jq -c --arg k "$k" --arg v "$v" '. + [{key:$k,value:$v}]')
  done
  printf '{"settings":%s}' "$out"
}
SH
askknob() { # askknob <ROWS> <ENV> [project]
  rm -rf "$T/lk/state/lane-gate" "$T/lk/state/settings-cache.json"
  env HARNESS="$T/lk" ROWS="$1" bash -c '
    set -uo pipefail
    . "$HARNESS/bin/stub-jobs-client.sh"
    . "$HARNESS/bin/lib/lane-gate.sh"
    lane_knob merge-conductor "$1" "${2:-}"' _ "$2" "${3:-}" 2>/dev/null
}
[ "$(askknob "lane.merge-conductor.demo-os.mc_tick_secs=600 lane.merge-conductor.mc_tick_secs=120" MC_TICK_SECS demo-os)" = 600 ] \
  && ok || bad "E3 a project row must beat the fleet row (got '$(askknob "lane.merge-conductor.demo-os.mc_tick_secs=600 lane.merge-conductor.mc_tick_secs=120" MC_TICK_SECS demo-os)')"
[ "$(askknob "lane.merge-conductor.mc_tick_secs=120" MC_TICK_SECS demo-os)" = 120 ] \
  && ok || bad "E3 the fleet row must apply to a project with no row of its own"
[ "$(askknob "lane.merge-conductor.demo-os.mc_tick_secs=9999" MC_TICK_SECS demo-os)" = 3600 ] \
  && ok || bad "E3 a settings row above max must clamp to 3600"
[ "$(askknob "" MC_TICK_SECS demo-os)" = 0 ] && ok || bad "E3 with no row the default must be 0 (today's cadence)"
[ "$(askknob "" MC_READ_MEMO_TTL_SECS)" = 900 ] && ok || bad "E3 MC_READ_MEMO_TTL_SECS default must be 900"
[ "$(askknob "" MC_READ_MEMO)" = 1 ] && ok || bad "E3 MC_READ_MEMO default must be 1"

# ============================================================================
# F. the ETag half: a second tick's PR read goes out conditional and 304s
# ============================================================================
fresh; list_three "$UPD1"; : > "$T/etag-on"
# TEST-CHANGE (BH-1592): the row that makes PR 30 a closed-pass candidate.
mkdir -p "$T/h/state/merge-conductor"
printf 'example-org/demo-os#30\tWAIT_CI\t1\t-\t-\t-\t-\thttps://github.com/example-org/demo-os/pull/30\n' > "$T/h/state/merge-conductor/pr-state.tsv"
tick
F1C=$(( $(pr_reads) - $(wc -l < "$T/gh-304.txt" | tr -d '[:space:]') ))
: > "$T/gh-calls.txt"; : > "$T/gh-304.txt"
tick
F2C=$(( $(pr_reads) - $(wc -l < "$T/gh-304.txt" | tr -d '[:space:]') ))
grep -q 'If-None-Match: "e1"' "$T/gh-calls.txt" && ok || bad "F tick 2's list read must carry If-None-Match"
[ "$(wc -l < "$T/gh-304.txt" | tr -d '[:space:]')" -ge 1 ] && ok || bad "F the stub must have answered at least one 304 on tick 2"
grep -q 'gh-etag lane=merge-conductor:demo-os' "$T/h/logs/gh-rate.log" && ok || bad "F the per-project ETag counter line must be written"
ETCACHED=$(grep -o 'gh-etag lane=merge-conductor:demo-os fetched=[0-9]* cached=[0-9]*' "$T/h/logs/gh-rate.log" | tail -1 | sed 's/.*cached=//')
[ "${ETCACHED:-0}" -ge 1 ] && ok || bad "F a 304 must land in the project's cached= counter (line: $(grep -o 'gh-etag lane=merge-conductor:demo-os.*' "$T/h/logs/gh-rate.log" | tail -1))"
[ "$F2C" -le $((F1C / 2)) ] && ok || bad "F counted PR reads per tick must at least halve (tick1=$F1C tick2=$F2C)"

echo "conductor-read-memo.bh-1486-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
