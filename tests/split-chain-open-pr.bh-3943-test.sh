#!/bin/bash
# tests/split-chain-open-pr.bh-3943-test.sh — BH-3949 (BH-3943 item 3): no
# paid session to learn a PR already exists.
#
# project-4 TK-2125 paid a split-ready session to answer "SPLIT_DEFER: PR #1787
# already covers the scope". Two places now ask GitHub first, through the
# BH-3948 contract (bin/lib/open-pr-precheck.sh open_pr_for_key):
#
#   O1-O5  bin/lib/split-chain.sh split_chain_gate (the gate's step 1c): a due
#          child with an open PR is not offered, nothing is printed, and the
#          skip is logged `SPLIT_DEFER ... paid_avoided`. No PR, an unreadable
#          read, a prefix-sibling's PR, or the pass's read cap: offered as today.
#   O6     the REAL bin/triage-shard.sh for a launch-only shard whose key has an
#          open ticket/<key> PR: no agent-call, `BUILD_DEFER ... paid_avoided`,
#          exit 0. The same key with a board line still gets its session.
#   O7     a deferred line is dropped from READY-QUEUE.log; a re-plan (carried
#          note, CI_PARKED record, or a rebuild line) next to the parked PR is
#          never deferred.
#
# The contract lib and gh-rest-var.sh are the real ones; only the bottom REST
# helpers (gh_rest_pr_list, gh_rest_pr_state) are stubbed from fixtures.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/split-chain-open-pr.bh-3943-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "split-chain-open-pr: jq missing, cannot run" >&2; exit 1; }

H="$T/h"; FX="$T/fx"
P=project-4
mkdir -p "$H/bin/lib" "$H/state" "$H/logs" "$H/locks" "$H/builds" "$H/env" "$FX"
scratch_install_closure bin/lib/split-chain.sh "$H" >/dev/null || exit 1
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1/$2" in
  project-4/repo) echo example-org/project-4 ;;
  *) exit 1 ;;
esac
SH
# The bottom of the REST path. fixture prs.json holds the repo's PRs; a list
# read answers every PR whose head.ref STARTS WITH the asked branch (a filter
# looser than GitHub's), so only the contract's exact compare keeps TK-212 off
# TK-2125's PR. FX/list-mode=fail answers rc 75. Every call is logged.
cat > "$H/bin/lib/gh-rest.sh" <<'SH'
gh_rest_pr_list() { # <slug> <state> [head] [per_page]
  echo "list $1 $2 ${3:-}" >> "$FX/gh-calls"
  [ "$(cat "$FX/list-mode" 2>/dev/null)" = fail ] && { GH_REST_STATUS=502; return 75; }
  GH_REST_STATUS=200
  jq -c --arg br "${3#*:}" --arg st "$2" '[.[] | select((.head.ref | startswith($br)) and .state == $st)]' "$FX/prs.json"
}
gh_rest_pr_state() { # <slug> <n>
  echo "state $1 $2" >> "$FX/gh-calls"
  cat "$FX/pr-$2" 2>/dev/null || return 44
}
[ -r "$(dirname "${BASH_SOURCE[0]}")/gh-rest-var.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-rest-var.sh"
SH
# The jobs client: the observe-column write is recorded, nothing else answers.
cat > "$H/bin/jobs-client.sh" <<'SH'
job_open() { return 1; }
triage_state_put() { cat "$1" >> "$FX/puts"; echo >> "$FX/puts"; return 0; }
SH
chmod +x "$H/bin/"*.sh

res() { # res <KEY> <line1>
  local d="$H/builds/$P-$1-$((RANDOM))$((RANDOM))"
  mkdir -p "$d"; printf '%s\nTICKET_ID: x\n' "$2" > "$d/RESULT"; touch "$d/COMMENTED"
}
prs() { # prs <n:ref:state> ...
  local a="[]" x
  for x in "$@"; do
    a=$(jq -c --argjson n "${x%%:*}" --arg r "$(printf '%s' "$x" | cut -d: -f2)" --arg s "${x##*:}" \
      '. + [{number:$n,state:$s,head:{ref:$r}}]' <<<"$a")
  done
  printf '%s\n' "$a" > "$FX/prs.json"
}
chain() { # chain <child> — TK-2120 split into TK-2124,<child>; TK-2124's PR merged
  scratch_rm "$H/state"; scratch_rm "$H/logs"; scratch_rm "$H/builds"; scratch_rm "$FX"; mkdir -p "$H/state" "$H/logs" "$H/builds" "$FX"
  jq -n --arg c "$1" '{"TK-2120":"9120","TK-2124":"9124"} + {($c):"9125"}' > "$H/state/$P.keymap.json"
  res TK-2120 "DECOMPOSED TK-2124,$1"
  res TK-2124 "PR_CREATED https://github.com/example-org/project-4/pull/1780 (tier 2)"
  echo merged > "$FX/pr-1780"
  prs
}
ngh()   { local n; n=$(grep -c '^list ' "$FX/gh-calls" 2>/dev/null); echo "${n:-0}"; }
sgate() { ( HARNESS="$H"; export FX; . "$H/bin/lib/split-chain.sh"; split_chain_gate "$H" "$P" ) 2>/dev/null; }
KF="$H/state/split-ready-keys-$P"

# --- O1: an open agent/TK-2125 PR -> not offered, nothing printed -------------
chain TK-2125; prs "1787:agent/TK-2125:open"
OUT=$(sgate)
[ -z "$OUT" ] && ok || bad "O1a the gate printed '$OUT' for a key whose PR is open"
[ -e "$KF" ] && bad "O1b the one-shot keys file was written" || ok
grep -q "SPLIT_DEFER TK-2125 open-pr #1787 - paid_avoided" "$H/logs/$P.log" 2>/dev/null && ok \
  || bad "O1c no SPLIT_DEFER line: $(cat "$H/logs/$P.log" 2>/dev/null)"
grep -q 'SPLIT_READY' "$H/logs/$P.log" 2>/dev/null && bad "O1d a skipped key was logged SPLIT_READY" || ok
[ "$(jq -sr '.[0].last_decision' "$FX/puts" 2>/dev/null)" = "skip split-defer open-pr #1787" ] && ok \
  || bad "O1e the observe column was not written: $(cat "$FX/puts" 2>/dev/null)"
[ "$(jq -sr '.[0] | has("verdict")' "$FX/puts" 2>/dev/null)" = false ] && [ "$(jq -sr '.[0].ticket_key + "/" + .[0].project' "$FX/puts" 2>/dev/null)" = "TK-2125/$P" ] && ok \
  || bad "O1f the note must carry only project/ticket_key/last_decision: $(cat "$FX/puts" 2>/dev/null)"
[ -f "$H/state/split-chain/$P/offered/TK-2125" ] && ok || bad "O1g the remind watermark was not written"
rm -f "$FX/gh-calls"; OUT=$(sgate)
[ -z "$OUT" ] && [ "$(ngh)" = 0 ] && ok || bad "O1h the next pass inside the remind window re-read GitHub ($(ngh)) or offered '$OUT'"

# --- O2: no PR on either head -> offered as today ------------------------------
chain TK-2125
OUT=$(sgate)
[ "$OUT" = TK-2125 ] && ok || bad "O2a no PR: want TK-2125 offered, got '$OUT'"
[ "$(cat "$KF" 2>/dev/null)" = TK-2125 ] && ok || bad "O2b the keys file was not written"
[ "$(ngh)" = 2 ] && ok || bad "O2c want both heads read, got $(ngh) list reads"
grep -q 'SPLIT_DEFER' "$H/logs/$P.log" && bad "O2d a no-PR key was logged SPLIT_DEFER" || ok

# --- O3: an unreadable list (rc 2) is never "none", and never "a PR" --------
chain TK-2125; prs "1787:agent/TK-2125:open"; echo fail > "$FX/list-mode"
OUT=$(sgate)
[ "$OUT" = TK-2125 ] && ok || bad "O3 an unreadable read must still offer the key, got '$OUT'"

# --- O3b: a CLOSED PR is not cover -------------------------------------------
chain TK-2125; prs "1787:agent/TK-2125:closed"
OUT=$(sgate)
[ "$OUT" = TK-2125 ] && ok || bad "O3b a closed PR skipped the key, got '$OUT'"

# --- O4: the prefix sibling TK-212 is not covered by TK-2125's PR ------------
chain TK-212; prs "1787:agent/TK-2125:open" "1788:agent/TK-2125-other:open"
OUT=$(sgate)
[ "$OUT" = TK-212 ] && ok || bad "O4 TK-212 must still be offered next to TK-2125's PR, got '$OUT'"

# --- O5: the pass's read cap is shared with the merged checks ----------------
# TK-2124's merge costs one read; at SPLIT_CHAIN_MAX_LOOKUPS=2 the open-PR check
# (charged 2) no longer fits, so it is skipped and the key offered unchecked.
chain TK-2125; prs "1787:agent/TK-2125:open"
OUT=$( export SPLIT_CHAIN_MAX_LOOKUPS=2; sgate )
[ "$OUT" = TK-2125 ] && ok || bad "O5a a capped pass must still offer the key, got '$OUT'"
[ "$(ngh)" = 0 ] && ok || bad "O5b a capped pass read the PR list $(ngh) times"
grep -q 'lookup cap' "$H/logs/$P.log" && ok || bad "O5c the capped open-PR check left no line"
chain TK-2125; prs "1787:agent/TK-2125:open"
OUT=$( export SPLIT_CHAIN_MAX_LOOKUPS=3; sgate )
[ -z "$OUT" ] && ok || bad "O5d with room for 1+2 reads the open PR must still skip the key, got '$OUT'"

# --- O6: the shard -------------------------------------------------------------
cp "$DIR/bin/triage-shard.sh" "$H/bin/triage-shard.sh"
scratch_install_closure bin/triage-shard.sh "$H" >/dev/null || exit 1
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/decision-log.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/sh\necho called >> "$FX/agent-calls"\necho "tickets=1 done" > "$5"\nexit 0\n' > "$H/bin/agent-call.sh"
chmod +x "$H/bin/"*.sh
Q='READY-QUEUE: TK-2125 launch when TK-2124 merged'
printf 'TICK SCOPE (triage shard)\n\nWhat moved for TK-2125:\nIn the launch queue:\n%s\n\nWork ONLY ticket TK-2125 this tick.\n' "$Q" > "$H/q.prompt"
printf 'TICK SCOPE (triage shard)\n\nWhat moved for TK-2125:\nOn the board:\nboard: TK-2125 new comment\nIn the launch queue:\n%s\n\nWork ONLY ticket TK-2125 this tick.\n' "$Q" > "$H/qb.prompt"
shard() { # shard <prompt>; sets SRC
  rm -f "$FX/agent-calls" "$FX/puts"; : > "$H/logs/$P.log"; : > "$H/logs/ALERTS.log"
  ( export HARNESS="$H" FX TSH_MODEL=claude-fable-5-1 TSH_RUNNER=claude
    bash "$H/bin/triage-shard.sh" "$P" TK-2125 "$1" >/dev/null 2>&1 ); SRC=$?
}
chain TK-2125; prs "1787:ticket/TK-2125:open"
shard "$H/q.prompt"
[ "$SRC" = 0 ] && ok || bad "O6a a BUILD_DEFER shard exited $SRC"
[ -f "$FX/agent-calls" ] && bad "O6b agent-call ran for a launch-only key whose PR is open" || ok
grep -q "BUILD_DEFER TK-2125 open-pr #1787 - paid_avoided" "$H/logs/$P.log" && ok \
  || bad "O6c no BUILD_DEFER line: $(cat "$H/logs/$P.log")"
[ "$(jq -sr '.[0].last_decision' "$FX/puts" 2>/dev/null)" = "skip build-defer open-pr #1787" ] && ok \
  || bad "O6d the observe column was not written: $(cat "$FX/puts" 2>/dev/null)"
shard "$H/qb.prompt"
[ -f "$FX/agent-calls" ] && ok || bad "O6e a shard with a board line must keep its session"
grep -q 'BUILD_DEFER' "$H/logs/$P.log" && bad "O6f a board+queue shard was deferred" || ok
chain TK-2125
shard "$H/q.prompt"
[ -f "$FX/agent-calls" ] && ok || bad "O6g no PR: the launch-only shard must still call the model"
chain TK-2125; prs "1787:ticket/TK-2125:open"; echo fail > "$FX/list-mode"
shard "$H/q.prompt"
[ -f "$FX/agent-calls" ] && ok || bad "O6h an unreadable PR list must fall through to the model"

# --- O7: a deferred line is dropped; a re-plan next to a parked PR is not deferred
# The parked PR of a CI re-plan stays open until the re-plan's own PR replaces
# it (guardrail 1), so an open ticket/<key> PR must not defer the re-plan line.
[ -x "$H/bin/queue-line-drop.sh" ] || { cp "$DIR/bin/queue-line-drop.sh" "$H/bin/queue-line-drop.sh"; chmod +x "$H/bin/queue-line-drop.sh"; }
chain TK-2125; prs "1787:ticket/TK-2125:open"
printf 'TK-2125 launch when TK-2124 merged\nAR-9 other ticket\n' > "$H/logs/READY-QUEUE.log"
shard "$H/q.prompt"
[ -f "$FX/agent-calls" ] && bad "O7a the deferred shard called the model" || ok
grep -q '^TK-2125 ' "$H/logs/READY-QUEUE.log" && bad "O7b the deferred key's queue line was left in place" || ok
grep -q '^TK-9 ' "$H/logs/READY-QUEUE.log" && ok || bad "O7c another key's queue line was dropped"
grep -q 'BUILD_DEFER TK-2125 open-pr #1787 - paid_avoided; dropped 1 line' "$H/logs/$P.log" && ok \
  || bad "O7d the BUILD_DEFER line does not say the queue line was dropped: $(cat "$H/logs/$P.log")"
chain TK-2125; prs "1787:ticket/TK-2125:open"
mkdir -p "$H/state/build-notes/$P"; printf 'KIND: ci-replan\nPRIOR PR: https://github.com/example-org/project-4/pull/1787 (parked OPEN, CI still red)\n' > "$H/state/build-notes/$P/TK-2125.md"
printf 'TK-2125 launch when TK-2124 merged\n' > "$H/logs/READY-QUEUE.log"
rm -f "$FX/gh-calls"; shard "$H/q.prompt"
[ -f "$FX/agent-calls" ] && ok || bad "O7e a ci-replan waiting next to its parked PR was deferred"
grep -q 'BUILD_DEFER TK-2125 open-pr' "$H/logs/$P.log" && bad "O7f the re-plan was logged BUILD_DEFER" || ok
grep -q '^TK-2125 ' "$H/logs/READY-QUEUE.log" && ok || bad "O7g the re-plan's queue line was dropped"
[ "$(ngh)" = 0 ] && ok || bad "O7h a re-plan shard still read the PR list $(ngh) times"
chain TK-2125; prs "1787:ticket/TK-2125:open"
mkdir -p "$H/state/blocked-resolver/$P"; echo '{"outcome":"CI_PARKED","ci_parked_url":"https://github.com/example-org/project-4/pull/1787"}' > "$H/state/blocked-resolver/$P/$P-TK-2125.json"
shard "$H/q.prompt"
[ -f "$FX/agent-calls" ] && ok || bad "O7i a key whose PR the blocked-resolver parked CI_PARKED was deferred"
chain TK-2125; prs "1787:ticket/TK-2125:open"
printf 'TICK SCOPE (triage shard)\n\nWhat moved for TK-2125:\nIn the launch queue:\nAR-2125 rebuild fresh (ci-replan: 2 red CI rounds on #1787)\n\nWork ONLY ticket TK-2125 this tick.\n' > "$H/qr.prompt"
shard "$H/qr.prompt"
[ -f "$FX/agent-calls" ] && ok || bad "O7j a queue line naming a rebuild was deferred"

echo "split-chain-open-pr: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
