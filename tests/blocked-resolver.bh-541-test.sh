#!/bin/bash
# tests/blocked-resolver.bh-541-test.sh — br_mechanical's POOL arms (BH-541).
#
# WHAT THIS PINS. Rung 1 of the ladder is mc_rebase, and under REBASE_ON_POOL
# that call answers two rcs the resolver has never seen:
#   rc 6 — a pool machine HAS the rebase. The rung RAN (a queue row exists), so
#          it counts against MAX_MECHANICAL, and the conductor row must LEAVE
#          the park for REBASING. A row left BLOCKED_HUMAN has the next tick of
#          this lane start a fix round on top of a branch a machine is rebasing.
#   rc 7 — the queue refused it and NOTHING was spent. That is the rc-3 shape:
#          no rung, no state, the park simply re-offered next tick.
# Without these arms both fall into the `*)` setup arm: br_setup_blocked, an
# alert, and a park that never moves.
#
# WHY A PER-TICKET FILE. tests/blocked-resolver-test.sh is the shared suite and
# PR #831 is editing it; two builds appending to one file is a guaranteed
# conflict on a hunk neither ticket is about. The cases move into it verbatim
# under its own mc_rebase override if a reviewer prefers that.
#
# The fixture is the shared suite's, trimmed: arms 6 and 7 return before any
# clone, so no git seed is needed — only a PR the resolver can read a branch and
# a head for, and an mc_rebase whose rc this file sets.
#
# MUTATION NOTES (D1 — each applied once during the build, the red observed, the
# product line restored):
#   - drop the mc_transition in arm 6      -> 8g-1 red ("got 'BLOCKED_HUMAN'")
#   - record the rung in arm 7             -> 8g-2 red ("got '1'")
#
# Run from anywhere: bash tests/blocked-resolver.bh-541-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read: the row's timestamp. Everything else is event-driven.
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$H/bin/lib/"
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
# One project, a GitHub-Issues lane (board prefix "-"), owned by a remote box.
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# The "agent" is RECORDED, never silent: "did the pool arm also buy a fix round"
# has to be a fact about the run.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/agent.txt"\nexit 0\n' "$T" > "$H/bin/agent-call.sh"
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# Every gh call is recorded, so "did anything close a PR / comment" is a fact
# about the run rather than a reading of the source. The PR under test is named
# by two files, so a scenario is one write.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  # bin/blocked-resolver.sh reads, comments and closes over REST (#783): the
  # gh-api-dash-i envelope is answered once, in tests/lib/gh-rest-stub.sh.
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*) printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) printf '%s\n' "\$*" >> "$T/comments.txt"; exit 0 ;;
  *"/pulls/"*) _h=\$(<"$T/prhead"); _b=\$(<"$T/prbranch"); echo "\${_h:-null} \${_b:-null}" ;;
  *"--json headRefOid,headRefName"*) echo "\$(cat "$T/prhead") \$(cat "$T/prbranch")" ;;
  *"--json headRefName"*) cat "$T/prbranch" ;;
  *"--json headRefOid"*)  cat "$T/prhead" ;;
  *"--json state"*)       echo OPEN ;;
  *"pr list"*"--state merged"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
cat > "$T/fakebin/br-ssh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/ssh.txt"
exit 0
EOF
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN.
export GH_TOKEN=""
: > "$T/closed.txt"; : > "$T/comments.txt"; : > "$T/gh.txt"

# The mechanical rung's own body, to its documented rc contract — the one thing
# stubbed, because running it for real would need a credential and somebody's
# repo. The rcs this file drives (6, 7) are the pool arms.
cat >> "$H/bin/lib/merge-conductor-lib.sh" <<EOF
# --- fixture override: mc_rebase to its documented rc contract ---------------
mc_rebase() {
  printf '%s\n' "\$*" >> "$T/rebase.txt"
  local out; out=\$(cat "$T/rebase-out" 2>/dev/null)
  [ -n "\$out" ] && printf '%s' "\$out"
  return "\$(cat "$T/rebase-rc" 2>/dev/null || echo 4)"
}
EOF
: > "$T/rebase.txt"; : > "$T/rebase-out"; echo 4 > "$T/rebase-rc"

HEAD95=9595959595959595959595959595959595959595
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
# ROW <conductor key> <reason> <head> <url> — the park the drain reads, in
# pr-state.tsv's own field order (key, state, ts, head, reviewed, -, reason, url).
ROW() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" "$3" "$3" "$2" "$4" \
          > "$H/state/merge-conductor/pr-state.tsv"; }
row_state() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$H/state/merge-conductor/pr-state.tsv"; }
# The ladder state file is named by br_cap_key, which derives from the ticket
# key — so it is READ off disk rather than re-derived here, and "no file at all"
# is a legible answer (that is what rc 7 must produce).
statejson() { cat "$H/state/blocked-resolver/tproj/"*.json 2>/dev/null; }
reset_case() {
  scratch_rm "$H/state/blocked-resolver"
  : > "$T/closed.txt"; : > "$T/rebase.txt"; : > "$T/agent.txt"
  : > "$H/logs/blocked-resolver.log"; : > "$T/run.log"
}

# ---- 8g-1. THE POOL TOOK IT (rc 6). The rung RAN, so it counts; and the row
#            must leave the park, or the next tick buys a fix round on a branch
#            a pool machine is rebasing right now.
reset_case
printf 'ticket/TK-95\n' > "$T/prbranch"; printf '%s\n' "$HEAD95" > "$T/prhead"
echo 6 > "$T/rebase-rc"; : > "$T/rebase-out"
ROW "o/tproj#95" "conflict-unresolvable: CONFLICT (content): a.txt" "$HEAD95" "https://github.com/o/tproj/pull/95"
RUN
[ "$(statejson | jq -r '.mechanicals // 0')" = 1 ] && ok \
  || bad "a rebase the pool took is a rung that RAN and must be counted (got $(statejson | jq -r '.mechanicals // 0'))"
grep -q 'queued a pool rebase' <<<"$(statejson | jq -r '.attempts[].detail')" && ok \
  || bad "the recorded attempt must say the rebase went to the pool (got $(statejson | jq -r '.attempts[].detail'))"
grep -q 'mechanical' <<<"$(statejson | jq -r '.attempts[].action')" && ok \
  || bad "the attempt is a mechanical rung, not a mechanical-failed one (got $(statejson | jq -r '.attempts[].action'))"
[ "$(row_state "o/tproj#95")" = REBASING ] && ok \
  || bad "the conductor row must leave the park for REBASING (got '$(row_state "o/tproj#95")')"
[ "$(wc -l < "$T/rebase.txt")" = 1 ] && ok \
  || bad "the pool arm must ask for exactly one rebase (got $(wc -l < "$T/rebase.txt"))"
[ -s "$T/closed.txt" ] && bad "a queued pool rebase must not close the PR: $(cat "$T/closed.txt")" || ok
[ -s "$T/agent.txt" ] && bad "a queued pool rebase must not also buy a fix round: $(cat "$T/agent.txt")" || ok
grep -q 'pool rebase queued' "$H/logs/blocked-resolver.log" && ok \
  || bad "the lane must say the rebase went to the pool (log: $(tail -3 "$H/logs/blocked-resolver.log"))"
[ -s "$T/lane-alert.txt" ] && bad "a rung that ran must not page: $(cat "$T/lane-alert.txt")" || ok

# ---- 8g-2. THE QUEUE REFUSED IT (rc 7). Nothing spent: no rung, no state, the
#            row exactly where it was, and the park re-offered next tick.
reset_case
printf 'ticket/TK-96\n' > "$T/prbranch"; printf '%s\n' "$HEAD95" > "$T/prhead"
echo 7 > "$T/rebase-rc"; : > "$T/rebase-out"
ROW "o/tproj#96" "conflict-unresolvable: CONFLICT (content): a.txt" "$HEAD95" "https://github.com/o/tproj/pull/96"
RUN
# Nothing was recorded at all, so the state file may not even exist — "no rung"
# is either shape, and an empty read must not pass for a zero by accident.
MECH96=$(statejson | jq -r '.mechanicals // 0' 2>/dev/null)
[ "${MECH96:-0}" = 0 ] && ok || bad "an unreachable pool queue spends no rung (got '$MECH96')"
[ "$(row_state "o/tproj#96")" = BLOCKED_HUMAN ] && ok \
  || bad "nothing happened, so the row is where it was (got '$(row_state "o/tproj#96")')"
grep -q 'pool queue unreachable' "$H/logs/blocked-resolver.log" && ok \
  || bad "the lane must say the queue was unreachable (log: $(tail -3 "$H/logs/blocked-resolver.log"))"
[ -s "$T/closed.txt" ] && bad "an unreachable queue must not close the PR: $(cat "$T/closed.txt")" || ok
[ -s "$T/agent.txt" ] && bad "an unreachable queue must not buy a fix round: $(cat "$T/agent.txt")" || ok
[ "$(wc -l < "$T/rebase.txt")" = 1 ] && ok \
  || bad "the rung is asked exactly once per tick (got $(wc -l < "$T/rebase.txt"))"

echo "blocked-resolver.bh-541-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
