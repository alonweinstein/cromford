#!/bin/bash
# tests/pr-dep-gate-rest.bh-994-test.sh — BH-994: the three per-PR reads on the
# merge path go over REST, so an exhausted GraphQL budget cannot hold a repo.
#
# THE INCIDENT (2026-09-19 17:53Z–18:04Z, hub). Every READY cromford row —
# #933, #956, #955, #785 — was held on four consecutive conductor ticks with
# `dep gate: could not read the PR body — HOLD (rc 2)` and `merges=0`, while CI
# was green and mergeable_state was clean. Reproduced on the hub under the
# conductor's own repo token: `gh pr view <url> --json body` answered
# `GraphQL: API rate limit already exceeded for installation ID 161623167`,
# while REST core on the SAME token still had 3141 of 6600 points left. The
# GraphQL window reset at 18:04:42Z and the holds cleared by themselves;
# logs/pr-dep-gate.log carried 81 rc-2 lines across projects that day.
#
# WHY IT EMPTIED. `gh pr view` is GraphQL. THREE GraphQL reads ran per PR per
# tick — pdg_hold's own body fetch (the conductor always hands it ""), the
# conductor's mc_is_harness_pr body probe, and the pre-merge state guard's
# re-read of state/head/base — and with ~55 open PRs, a tick every 5 minutes and
# 30+ overlapping workers, the App installation's 6600 points/h GraphQL budget
# went to zero while its REST budget was barely touched. The merge step then
# went dark for every project on the hub. Failing closed on an unreadable answer
# is correct; failing closed on the budget that empties first, while the other
# one sits idle, is not.
#
# THE STATE GUARD IS THE ONE THAT ACTUALLY BLOCKED MERGES. The dep gate held a
# row; the guard at `# >>> pre-merge state guard` REFUSED it, logging
# "not merged: state changed under the tick ()" — an empty parenthesis naming no
# state, because the read returned nothing at all.
#
# WHAT IS ASSERTED. All three reads are driven with a `gh` on PATH that answers
# over REST and FAILS every `gh pr view` and `gh api graphql` with the incident's
# own message — the shape of an exhausted installation. A read that still
# reaches for GraphQL therefore cannot pass this suite by accident: it gets the
# rate-limit failure the hub got. Assertions are on the return code, the shim's
# call log, logs/pr-dep-gate.log and the conductor's own log line; nothing here
# greps a script for its source text except the one cheap backstop in section 7.
# The conductor's two blocks are EXTRACTED VERBATIM by their
# `# >>> harness pr probe` and `# >>> pre-merge state guard` markers and run, the
# way the other conductor slices are driven. The state guard's fixture is the
# REST document in GitHub's own spelling — lower-case state, .head.sha,
# .base.ref — run through jq, so a dropped `ascii_upcase` or a mistyped field
# path fails here rather than in production. The state-guard slice ENDS before
# the base guard that consumes its third field, so case 6d alone hands the
# slice's own NBASE to the production `mc_base_guard` out of the lib, with the
# conductor's argv. The rest of §6 stops at the slice, which is all they assert.
#
# Every fixture value is a literal. Nothing here reads the wall clock, rolls a
# random number or sleeps.
# Run from anywhere: tests/pr-dep-gate-rest.bh-994-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SLUG=o/r
NUM=41
PRURL="https://github.com/$SLUG/pull/$NUM"
LOG="$T/h/logs/pr-dep-gate.log"

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/flags" "$T/h/state/merge-conductor" "$T/fakebin" "$T/answers"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/" || exit 1
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
cp "$DIR/bin/lib/pr-dep-gate.sh"         "$T/h/bin/lib/" || exit 1
# The conductor's probe reads the body through bin/lib/gh-rest.sh (BH-784), and
# without it in the fixture tree the lib's fail-closed shim answers
# "unverifiable" to every read — 5a would then fail on a read that never ran.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh"             "$T/h/bin/lib/" || exit 1
: > "$T/gh-calls.txt"; : > "$T/graphql-calls.txt"; : > "$T/prbody.txt"; : > "$T/allstderr"

# THE SHIM IS THE WHOLE POINT. `pr view` and `api graphql` are the two spellings
# of a GraphQL call and both answer exactly what the hub's installation token
# answered at 17:53Z. Every such attempt is recorded in its own sink, which is
# what "no GraphQL body read survives" is asserted on — a sink that is empty
# because the read never happened, not because the shim was lenient.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  "pr view"*|*"api graphql"*)
    printf '%s\n' "\$*" >> "$T/graphql-calls.txt"
    echo 'GraphQL: API rate limit already exceeded for installation ID 161623167' >&2
    exit 1 ;;
esac
# The conductor's probe (5) reads through bin/lib/gh-rest.sh, which judges the
# HTTP STATUS LINE of "gh api -i -X GET ..." and never gh's exit code (BH-784), so
# that shape gets a whole REST response with the body as the pull's .body field.
# Since BH-1735 the dep gate's own read (1-4) takes this shape too; the plain
# "gh api repos/.../pulls/N -q" branch below is the path without gh-rest.sh.
case "\$*" in
  "api -i -X GET repos/"*"/pulls/"*)
    [ -e "$T/rest-body-fail" ] && { printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n{"message":"Bad gateway"}'; exit 0; }
    printf 'HTTP/1.1 200 OK\r\n\r\n'; jq -Rs '{body: .}' "$T/prbody.txt"; exit 0 ;;
  # BH-1735: the dep gate resolves a dependency through gh_rest too, so the
  # issue read has the same shape. \$T/answers/<n> holds "<state> <merged_at|->".
  "api -i -X GET repos/"*"/issues/"*)
    N=\$(printf '%s' "\${5:-}" | sed -E 's|.*/issues/([0-9]+).*|\1|')
    [ -f "$T/answers/\$N" ] || { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}'; exit 0; }
    read -r S M < "$T/answers/\$N"
    printf 'HTTP/1.1 200 OK\r\n\r\n'
    jq -nc --arg s "\$S" --arg m "\$M" 'if \$m == "-" then {state: \$s} else {state: \$s, pull_request: {merged_at: \$m}} end'
    exit 0 ;;
esac
case "\${1:-}" in
  api)
    case "\${2:-}" in
      */pulls/*)
        [ -e "$T/rest-body-fail" ] && { echo 'HTTP 502: Bad gateway' >&2; exit 1; }
        cat "$T/prbody.txt" 2>/dev/null; exit 0 ;;
      */issues/*)
        N=\$(printf '%s' "\${2:-}" | sed -E 's|.*/issues/([0-9]+).*|\1|')
        [ -f "$T/answers/\$N" ] && { cat "$T/answers/\$N"; exit 0; }
        echo 'HTTP 404: Not Found' >&2; exit 1 ;;
    esac ;;
esac
exit 1
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

ans()      { printf '%s\n' "$2" > "$T/answers/$1"; }
calls()    { tr '\n' '|' < "$T/gh-calls.txt"; }
gqlcalls() { tr '\n' '|' < "$T/graphql-calls.txt"; }
logn()     { wc -l < "$LOG" 2>/dev/null | tr -d ' '; }
no_graphql() {  # no_graphql <case>
  [ -s "$T/graphql-calls.txt" ] \
    && bad "$1: THE DEFECT — a PR body was read over GraphQL: $(gqlcalls)" || ok
}

# run_case <shell-code> [VAR=VAL ...] — the production entry point, in a fresh
# `bash -u` (every lane runs with -u), against $T/h. Sets RC and OUT, and
# truncates both sinks and the gate log so a case's counts are its own.
RC=0; OUT=""
run_case() {
  local code="$1"; shift
  : > "$T/gh-calls.txt"; : > "$T/graphql-calls.txt"; : > "$LOG"; : > "$T/stderr"
  OUT=$(env HARNESS="$T/h" "$@" bash -u -c \
        ". \"\$HARNESS/bin/lib/merge-conductor-lib.sh\"; $code" 2>"$T/stderr")
  RC=$?
  cat "$T/stderr" >> "$T/allstderr"
}

HOLD="pdg_hold $SLUG $NUM $PRURL \"\""

# ══ 1. gate-passes-while-graphql-is-exhausted ══════════════════════════════
# A body with no declared dependency. Before BH-994 this held with rc 2 on a
# hub whose GraphQL budget was empty — which is what stopped every merge.
printf 'A plain change.\nCloses #994\n' > "$T/prbody.txt"
run_case "$HOLD"
[ "$RC" = 1 ] && ok || bad "gate-passes-while-graphql-is-exhausted: expected rc 1 (pass), got rc $RC — calls: $(calls)"
no_graphql gate-passes-while-graphql-is-exhausted
grep -q "api -i -X GET repos/$SLUG/pulls/$NUM" "$T/gh-calls.txt" && ok \
  || bad "gate-passes-while-graphql-is-exhausted: the body must be read over REST, got: $(calls)"
grep -q 'no declared dependency' "$LOG" && ok \
  || bad "gate-passes-while-graphql-is-exhausted: the log must say nothing was declared: $(cat "$LOG")"
[ "$(logn)" = 1 ] && ok || bad "gate-passes-while-graphql-is-exhausted: exactly one log line, got: $(cat "$LOG")"

# ══ 2. gate-holds-open-dependency-while-graphql-is-exhausted ═══════════════
# The incident line of BH-629, read over REST: an open dependency still HOLDS.
# A gate that answers "pass" here would merge over an open dependency, which is
# the failure this whole lane exists to prevent.
printf 'A change.\nDepends on #609 (PR #612) for tests/lib/scratch.sh.\n' > "$T/prbody.txt"
ans 612 'open -'
run_case "$HOLD"
[ "$RC" = 0 ] && ok || bad "gate-holds-open-dependency-while-graphql-is-exhausted: expected rc 0 (HOLD), got rc $RC — calls: $(calls)"
no_graphql gate-holds-open-dependency-while-graphql-is-exhausted
grep -q 'open dependency' "$LOG" && ok \
  || bad "gate-holds-open-dependency-while-graphql-is-exhausted: the log must say it holds: $(cat "$LOG")"
grep -q '612' "$LOG" && ok \
  || bad "gate-holds-open-dependency-while-graphql-is-exhausted: the log must name the dependency: $(cat "$LOG")"
[ "$(logn)" = 1 ] && ok || bad "gate-holds-open-dependency-while-graphql-is-exhausted: exactly one log line, got: $(cat "$LOG")"

# ══ 3. rest-read-failure-still-holds-rc-2 ══════════════════════════════════
# The rc contract does not move: a body nobody can read is still a HOLD with
# rc 2 and the same log line the lanes already key their dedupe on.
touch "$T/rest-body-fail"
run_case "$HOLD"
[ "$RC" = 2 ] && ok || bad "rest-read-failure-still-holds-rc-2: expected rc 2, got rc $RC — calls: $(calls)"
grep -q 'could not read the PR body' "$LOG" && ok \
  || bad "rest-read-failure-still-holds-rc-2: the log line must be unchanged: $(cat "$LOG")"
[ "$(logn)" = 1 ] && ok || bad "rest-read-failure-still-holds-rc-2: exactly one log line, got: $(cat "$LOG")"
grep -q 'issues/' "$T/gh-calls.txt" \
  && bad "rest-read-failure-still-holds-rc-2: an unreadable body costs no dependency read: $(calls)" || ok
scratch_rm "$T/rest-body-fail"

# ══ 4. queue-wrapper-reads-rest ════════════════════════════════════════════
# pdg_queue_hold is the box queue's body-less entry point and goes through the
# same fetch, so it inherits the fix rather than needing its own.
printf 'A change.\nDepends on #609 (PR #612)\n' > "$T/prbody.txt"
run_case 'pdg_queue_hold 41' SLUG="$SLUG"
[ "$RC" = 0 ] && ok || bad "queue-wrapper-reads-rest: expected rc 0 (HOLD), got rc $RC — calls: $(calls)"
no_graphql queue-wrapper-reads-rest
grep -q "api -i -X GET repos/$SLUG/pulls/$NUM" "$T/gh-calls.txt" && ok \
  || bad "queue-wrapper-reads-rest: the wrapper must fetch over REST, got: $(calls)"

# ══ 5. the conductor's harness-PR probe, extracted and driven ══════════════
# bin/merge-conductor.sh's second body read per PR per tick. It decides whether
# a PR is the harness's at all, so a GraphQL failure there marks a real harness
# PR "not a harness PR" and the tick walks away from it entirely.
awk '/^  # >>> harness pr probe/{f=1;next} /^  # <<< harness pr probe/{exit} f' \
  "$DIR/bin/merge-conductor.sh" > "$T/probe.sh"
[ -s "$T/probe.sh" ] && ok || bad "could not extract the conductor's harness-PR probe — markers missing?"
# The block calls pr_body_read, the conductor's own helper (BH-784: the read
# runs down a pipe, and a flag file carries a refused read's rc back out). It is
# extracted by name from the same script, so the arm runs the real read.
sed -n '/^pr_body_read() {/,/^}/p' "$DIR/bin/lib/mc/classify.sh" > "$T/probe-helper.sh"
[ -s "$T/probe-helper.sh" ] && ok || bad "could not extract pr_body_read from bin/lib/mc/classify.sh"
# The block ends its arm with `return 0`, so it is wrapped — verbatim, nothing
# retyped — in a function, exactly as tests/pr-dep-gate-lanes.bh-878-test.sh
# wraps the dep-gate arm. IGNORED is printed by the arm that walks away.
{ printf 'arm() {\n'; cat "$T/probe.sh"; printf '  printf "KEPT\\n"\n}\n'; } > "$T/probe-arm.sh"

MC_ATT="$T/h/state/merge-conductor/attempts.txt"
probe_arm() {  # probe_arm <branch> ; prints KEPT when the PR is treated as ours
  : > "$T/gh-calls.txt"; : > "$T/graphql-calls.txt"; : > "$MC_ATT"
  ( cd "$T" && HARNESS="$T/h" \
      SLUG="$SLUG" NUM="$NUM" URL="$PRURL" KEY="$SLUG#$NUM" BR="$1" REC="" \
      MC_ATTEMPTS="$MC_ATT" CLOG="$T/probe.log" \
      bash -c 'set -uo pipefail
        . "$HARNESS/bin/lib/merge-conductor-lib.sh"
        mc_log() { printf "%s\n" "$*" >> "$CLOG"; }
        . "$2"
        . "$1"
        arm' bash "$T/probe-arm.sh" "$T/probe-helper.sh" 2>"$T/probe.err" )
}

# 5a. probe-keeps-harness-pr-over-rest: a plain branch with no build record, so
#     the body IS read — and the marker run-build.sh writes is found over REST.
printf 'Closes #994\n\n[harness build] BH-994\n' > "$T/prbody.txt"
: > "$T/probe.log"
OUT=$(probe_arm feature/not-a-ticket)
grep -q KEPT <<<"$OUT" && ok \
  || bad "probe-keeps-harness-pr-over-rest: THE DEFECT — a harness PR was ignored because its body was unreadable (calls: $(calls), stderr: $(cat "$T/probe.err"))"
no_graphql probe-keeps-harness-pr-over-rest
# `api -i -X GET repos/…` is the REST contract's spelling of the same read.
grep -q "api -i -X GET repos/$SLUG/pulls/$NUM" "$T/gh-calls.txt" && ok \
  || bad "probe-keeps-harness-pr-over-rest: the probe must read the body over REST, got: $(calls)"
[ -s "$MC_ATT" ] \
  && bad "probe-keeps-harness-pr-over-rest: a kept PR records no not-harness line ($(cat "$MC_ATT"))" || ok

# 5b. probe-ignores-foreign-pr: the other answer is unchanged — a body without
#     the marker is somebody else's PR, ignored once and recorded once.
printf 'A pull request a person opened by hand.\n' > "$T/prbody.txt"
: > "$T/probe.log"
OUT=$(probe_arm feature/not-a-ticket)
grep -q KEPT <<<"$OUT" \
  && bad "probe-ignores-foreign-pr: a body with no harness marker is not ours (stderr: $(cat "$T/probe.err"))" || ok
grep -q "not-harness $SLUG#$NUM" "$MC_ATT" && ok \
  || bad "probe-ignores-foreign-pr: the ignore must be recorded once ($(cat "$MC_ATT"))"

# 5c. probe-ticket-branch-costs-no-read: the two cheap tests still short-circuit,
#     so the common harness PR makes no body call at all, REST or otherwise.
: > "$T/probe.log"
OUT=$(probe_arm ticket/bh-994)
grep -q KEPT <<<"$OUT" && ok \
  || bad "probe-ticket-branch-costs-no-read: a ticket/* branch is ours without any read (stderr: $(cat "$T/probe.err"))"
[ -s "$T/gh-calls.txt" ] \
  && bad "probe-ticket-branch-costs-no-read: a ticket/* branch must cost no GitHub read: $(calls)" || ok

# ══ 6. the pre-merge state guard, extracted and driven ════════════════════
# The THIRD GraphQL read on the merge path and the one that actually stops a
# merge: the tick's own list read is minutes old, so the arm re-reads state,
# head and base immediately before writing. With GraphQL exhausted the read
# answered NOTHING, and an empty answer is not OPEN — so every READY row on the
# fleet was refused with "not merged: state changed under the tick ()", the
# empty parenthesis the hub logged all afternoon.
awk '/^      # >>> pre-merge state guard/{f=1;next} /^      # <<< pre-merge state guard/{exit} f' \
  "$DIR/bin/merge-conductor.sh" > "$T/stateguard.sh"
[ -s "$T/stateguard.sh" ] && ok || bad "could not extract the pre-merge state guard — markers missing?"
# Wrapped verbatim, the way the probe above is: the guard ends its refusal with
# `return 0`, so MERGES is printed only by the path that reaches the write.
{ printf 'arm() {\n'; cat "$T/stateguard.sh"; printf '  printf "MERGES\\n"\n}\n'; } > "$T/stateguard-arm.sh"

# The shim answers the REST pulls endpoint in GitHub's own spelling — lower-case
# state, .head.sha, .base.ref — so the production jq template is what converts
# it, not the fixture. $T/state.json is the PR as GitHub would return it.
# THE LIB IS SOURCED HERE NOW (BH-784). The slice reads through mc_pr_view and
# names the failed read's status with mc_rest_status, so an arm without the lib
# would answer "command not found" to the production line and every case below
# would pass or fail on the shell, not on the guard. The lib is sourced BEFORE
# the mc_log shim, the way run_case and state_base_arm do it, so the shim wins.
state_arm() {  # state_arm <expected-head> ; prints MERGES when the guard passes
  : > "$T/gh-calls.txt"; : > "$T/graphql-calls.txt"; : > "$T/state.log"
  ( cd "$T" && HARNESS="$T/h" \
      SLUG="$SLUG" NUM="$NUM" URL="$PRURL" KEY="$SLUG#$NUM" HEAD="$1" \
      CLOG="$T/state.log" \
      bash -c 'set -uo pipefail
        . "$HARNESS/bin/lib/merge-conductor-lib.sh"
        mc_log() { printf "%s\n" "$*" >> "$CLOG"; }
        . "$1"
        arm' bash "$T/stateguard-arm.sh" 2>"$T/state.err" )
}

# 6d NEEDS ONE LINK MORE THAN THE REST OF §6. The extracted slice stops at the
# `# <<<` marker, which is BEFORE the `mc_base_guard` call that actually reads
# NBASE — so the third field can render as the word `null` and the slice still
# prints MERGES, because the only test it makes is `= OPEN` plus the head. This
# second wrapper runs the SAME verbatim slice, prints the block's own NOWST and
# NBASE, and then hands NBASE to the PRODUCTION mc_base_guard out of the lib
# copy at $T/h, with the conductor's own argv. 6a/6b/6c/6e keep state_arm.
{ printf 'arm() {\n'; cat "$T/stateguard.sh"
  printf '  printf "MERGES\\n"\n'
  printf '  printf "NOWST=[%%s] NBASE=[%%s]\\n" "$NOWST" "${NBASE:-}"\n'
  printf '  if WRONGB=$(mc_base_guard "$PBASE" "" "${NBASE:-}"); then printf "BASE_ABSTAIN\\n"; else printf "BASE_REFUSED %%s\\n" "$WRONGB"; fi\n'
  printf '}\n'; } > "$T/stateguard-base-arm.sh"

# Same shape as state_arm, plus PBASE and the lib. The lib is sourced BEFORE the
# mc_log shim, the way run_case does it, so the shim wins.
state_base_arm() {  # state_base_arm <expected-head> ; MERGES, then NBASE and the base guard's answer
  : > "$T/gh-calls.txt"; : > "$T/graphql-calls.txt"; : > "$T/state.log"
  ( cd "$T" && HARNESS="$T/h" \
      SLUG="$SLUG" NUM="$NUM" URL="$PRURL" KEY="$SLUG#$NUM" HEAD="$1" \
      PBASE=main CLOG="$T/state.log" \
      bash -c 'set -uo pipefail
        . "$HARNESS/bin/lib/merge-conductor-lib.sh"
        mc_log() { printf "%s\n" "$*" >> "$CLOG"; }
        . "$1"
        arm' bash "$T/stateguard-base-arm.sh" 2>"$T/state.err" )
}

H_NOW=aaaaaaaa1111
H_OLD=bbbbbbbb2222
# jq renders the real REST document, so an `ascii_upcase` that was dropped or a
# field path that was mistyped shows up here rather than in production.
printf '{"state":"open","head":{"sha":"%s"},"base":{"ref":"main"}}\n' "$H_NOW" > "$T/state.json"
# UNLINKED, NOT OVERWRITTEN. mc_is_harness_pr reads the body DOWN A PIPE, so
# §5's last `gh` can still be dying of SIGPIPE while this runs; writing over a
# file that is still executing answers "Text file busy" and would leave §6
# driving §5's stub. Unlink first and the new file is a new inode.
rm -f "$T/fakebin/gh"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  "pr view"*|*"api graphql"*)
    printf '%s\n' "\$*" >> "$T/graphql-calls.txt"
    echo 'GraphQL: API rate limit already exceeded for installation ID 161623167' >&2
    exit 1 ;;
esac
case "\$*" in
  *"ascii_upcase"*)
    Q=\$(printf '%s' "\$4")
    jq -r "\$Q" < "$T/state.json"; exit 0 ;;
esac
# THE READ IS THE REST CONTRACT'S NOW (BH-784): gh api -i -X GET
# repos/<slug>/pulls/<n>, judged on the HTTP STATUS LINE, with the jq template
# applied by the lib and not by gh. (No backticks in this heredoc: it is
# unquoted, and a backtick here would RUN the stub it is describing.) The SAME $T/state.json drives it, so a
# mistyped field path still shows up here rather than in production — and a
# state.json that is not JSON is still the unreadable-read case (6e), because
# the body the contract parses is what breaks.
case "\$*" in
  *"-i -X GET repos/$SLUG/pulls/$NUM"*)
    printf 'HTTP/1.1 200 OK\r\nServer: stub\r\n\r\n'; cat "$T/state.json"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/fakebin/gh"

# 6a. state-guard-merges-on-unchanged-head: the row this whole lane exists to
#     land. Before BH-994 this was refused with an empty NOWST.
OUT=$(state_arm "$H_NOW")
grep -q MERGES <<<"$OUT" && ok \
  || bad "state-guard-merges-on-unchanged-head: THE DEFECT — a clean READY row was refused while GraphQL was exhausted (log: $(cat "$T/state.log"), calls: $(calls), stderr: $(cat "$T/state.err"))"
no_graphql state-guard-merges-on-unchanged-head
# `api -i -X GET repos/…` is the REST contract's spelling of the same read.
grep -q "api -i -X GET repos/$SLUG/pulls/$NUM" "$T/gh-calls.txt" && ok \
  || bad "state-guard-merges-on-unchanged-head: the state must be re-read over REST, got: $(calls)"
[ -s "$T/state.log" ] \
  && bad "state-guard-merges-on-unchanged-head: a passing guard logs nothing ($(cat "$T/state.log"))" || ok

# 6b. state-guard-refuses-moved-head: the guard's whole job. Somebody pushed
#     under the tick, so the sha this row was reviewed at is gone.
OUT=$(state_arm "$H_OLD")
grep -q MERGES <<<"$OUT" \
  && bad "state-guard-refuses-moved-head: THE DEFECT — merged at a head the row was never reviewed at" || ok
grep -q 'state changed under the tick' "$T/state.log" && ok \
  || bad "state-guard-refuses-moved-head: the refusal must be logged (log: $(cat "$T/state.log"))"
grep -q "OPEN $H_NOW main" "$T/state.log" && ok \
  || bad "state-guard-refuses-moved-head: the log must name the state it read, upper-cased, with the base (log: $(cat "$T/state.log"))"

# 6c. state-guard-refuses-closed-pr: REST spells a merged or closed PR
#     "closed", and neither spelling is OPEN.
printf '{"state":"closed","head":{"sha":"%s"},"base":{"ref":"main"}}\n' "$H_NOW" > "$T/state.json"
OUT=$(state_arm "$H_NOW")
grep -q MERGES <<<"$OUT" \
  && bad "state-guard-refuses-closed-pr: a closed PR must never be merged again" || ok
grep -q "CLOSED $H_NOW main" "$T/state.log" && ok \
  || bad "state-guard-refuses-closed-pr: the log must name the closed state (log: $(cat "$T/state.log"))"

# 6d. state-guard-abstains-on-null-base: a null base renders EMPTY, never the
#     word "null" — the base guard downstream reads this string as a branch.
#     Driven through state_base_arm, so all three links are proven on one run:
#     the slice still passes the state test, `// ""` turns the null into an
#     EMPTY third field, and the production mc_base_guard ABSTAINS on it. Drop
#     `// ""` from bin/merge-conductor.sh:2217 and the two checks below go red
#     with NBASE=[null] and BASE_REFUSED null — a base guard reading `null` as a
#     branch name refuses every merge on the fleet.
printf '{"state":"open","head":{"sha":"%s"},"base":{"ref":null}}\n' "$H_NOW" > "$T/state.json"
OUT=$(state_base_arm "$H_NOW")
grep -q MERGES <<<"$OUT" && ok \
  || bad "state-guard-abstains-on-null-base: an open PR at the right head still passes the state test (log: $(cat "$T/state.log"))"
grep -q 'NBASE=\[\]' <<<"$OUT" && ! grep -q null <<<"$OUT" && ok \
  || bad "state-guard-abstains-on-null-base: THE DEFECT — a null base must render EMPTY, never the word null (got: $OUT)"
grep -q '^BASE_ABSTAIN$' <<<"$OUT" && ok \
  || bad "state-guard-abstains-on-null-base: THE DEFECT — the base guard must abstain on an empty fresh base, not refuse (got: $OUT) — 'null' as a branch would refuse every merge on the fleet"

# 6e. state-guard-read-failure-refuses: the fail-closed contract is unchanged —
#     an unreadable state is not an unchanged one, and nothing merges.
#     WHAT THE REFUSAL SAYS CHANGED WITH BH-784, and it is stricter, not looser:
#     the read's rc is carried, so an unreadable state is logged AS unreadable
#     instead of being reported as "state changed under the tick ()" — a claim
#     about the PR made out of an answer nobody got (the #768 sentence). Both
#     halves are asserted: the merge is still refused, the refusal is still
#     logged, and the log must NOT claim a state change it never read.
printf 'not json\n' > "$T/state.json"
OUT=$(state_arm "$H_NOW")
grep -q MERGES <<<"$OUT" \
  && bad "state-guard-read-failure-refuses: an unreadable state must never merge" || ok
grep -q 'UNVERIFIABLE' "$T/state.log" && ok \
  || bad "state-guard-read-failure-refuses: the refusal must be logged, and must name the read (log: $(cat "$T/state.log"))"
grep -q 'state changed under the tick' "$T/state.log" \
  && bad "state-guard-read-failure-refuses: an unread state must not be reported as a state change (log: $(cat "$T/state.log"))" || ok

# ══ 7. no read on the merge path still goes through `gh pr view` ══════════
# The three reads above are the ones the incident emptied the budget with. This
# is the cheap backstop for a fourth one being added later; the driven cases
# above are what actually prove the behaviour.
grep -nE 'gh pr view .*--json (body|state,headRefOid,baseRefName)' \
  "$DIR/bin/lib/pr-dep-gate.sh" "$DIR/bin/merge-conductor.sh" > "$T/grep.txt" 2>/dev/null
[ -s "$T/grep.txt" ] \
  && bad "no-graphql-read-in-source: a PR body or pre-merge state is still read over GraphQL: $(cat "$T/grep.txt")" || ok

# ══ 8. nothing on either path is unbound under set -u ══════════════════════
grep -q 'unbound variable' "$T/allstderr" \
  && bad "set-u-clean: a case tripped set -u: $(grep 'unbound variable' "$T/allstderr" | head -3)" || ok

echo "pr-dep-gate-rest.bh-994: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
