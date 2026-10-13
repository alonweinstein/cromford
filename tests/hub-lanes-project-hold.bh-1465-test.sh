#!/bin/bash
# tests/hub-lanes-project-hold.bh-1465-test.sh — BH-1465 (BH-1419.2): the five
# hub lanes HONOUR the per-project hold that BH-1463 shipped as a dark contract.
#
# WHY. A hub lane could only be stopped fleet-wide. The concrete case: a local
# Mac drain holds an unpushed force-with-lease commit on a project-5 branch, and
# a hub fix round would collide — so fix rounds and re-reviews have to stop on
# project-5 ALONE while project-5 BUILDS and every other project's fix rounds
# keep running. lane_project_held is the row that says so; this ticket is the
# five lanes asking it, each BEFORE its first spend for that project.
#
# What this file pins:
#   1. THE REAL RESOLVER. bin/blocked-resolver.sh, run in a scratch $HARNESS:
#      one park per project, flags/lane-off-blocked-resolver-projb set. proja's
#      rung is spent, projb's never is, exactly one log line names the flag, no
#      STARVED/SATURATED alert names projb, no visit is stamped for it, and the
#      tick line does not name it as skipped. Flag removed -> the next tick
#      dispatches projb. A lane-off-blocked-resolver-proja-x file is set for the
#      whole section, so the prefix negative (contract section 5) is proved
#      through the production lane rather than through the library again.
#   2-5. THE OTHER FOUR LANES, each driven by EXTRACTING its
#      `# >>> project hold` / `# <<< project hold` block VERBATIM by the markers
#      and pasting it into a driver with that lane's real stamp/logger and a
#      stub lane_project_held. The block is never retyped here, so a block that
#      drifts is a red test rather than a test that checks a copy. Concatenated
#      rather than sourced on purpose: `return` inside a sourced file returns
#      from the source, not from the enclosing function, and the conductor's
#      block ends in `return 0`.
#   6. INDEPENDENCE, both directions, against the REAL library: a merge-conductor
#      hold on projb does not stop the resolver on projb, and a resolver hold on
#      projb does not stop the conductor on projb.
#   7. MARKER RATCHET: each of the five lanes carries exactly one of each marker,
#      asserted so a MISSING marker fails (never a match that quietly passes).
#   8. MUTATION (D1), a PROCEDURE, not an automated section. Before claiming this
#      suite, for each lane in turn delete the `continue` (`return 0` for the
#      conductor) inside its `# >>> project hold` block, run this file, confirm
#      THAT lane's section goes red, then `git checkout -- <file>`:
#        bin/blocked-resolver.sh -> section 1   bin/review-autopilot.sh -> 2
#        bin/merge-conductor.sh  -> section 3   bin/merge-sweep.sh      -> 4
#        bin/main-red-pr-pair.sh -> section 5
#
# The resolver's tick line is deliberately NOT given a `held=[…]` field: four
# assertions in tests/blocked-resolver.bh-1122-test.sh and two in
# tests/blocked-resolver.bh-980-test.sh compare that line with `=` or anchor its
# last character, the ticket does not ask for the field, and the per-(tick,
# project) log line already answers "what did this tick hold". merge-sweep's
# `tick TOTAL:` line does gain one, because the ticket asks for it there and
# every existing reader of that line matches it by prefix.
# Run from anywhere: tests/hub-lanes-project-hold.bh-1465-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json is GENERATED and not committed; the gate library
# resolves it per tick.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh); every
# timestamp and every LANE_GATE_NOW below is derived from it.
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

# EXTRACT <script> <outfile> — the lane's hold block, verbatim, markers dropped.
EXTRACT() {
  awk '/# >>> project hold/{f=1;next} /# <<< project hold/{exit} f' "$1" > "$2"
  [ -s "$2" ]
}

# ============================================================================
# The scratch harness, in tests/blocked-resolver.bh-980-test.sh's shape, cut to
# TWO projects. Section 1 and section 6 both run the real lane against it.
# ============================================================================
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/catalog" "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/gh-rest.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/" 2>/dev/null || true
# THE SUBJECT OF THIS TICKET travels with the fixture: without the gate library
# the lanes fail open and run every project, which is the mid-sync behaviour and
# not what section 1 is measuring.
cp "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
cp "$(rendered_registry)" "$H/catalog/lanes.json"
chmod +x "$H/bin/"*.sh
{ printf 'proja o/proja - - 2 box-proja 192.0.2.1\n'
  printf 'projb o/projb - - 2 box-projb 192.0.2.2\n'; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh agent-call.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# Every alert argument on disk, so "no STARVED line named projb" is a fact about
# the run rather than a reading of a log.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
: > "$T/alerts.txt"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) cat "$T/comments-\$N.json" 2>/dev/null || echo '[]' ;;
  *"repos/"*"/issues/"*)
    cat "$T/issue-\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*)        echo OPEN ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *"--json headRefOid,headRefName"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *"--json headRefName"*)  echo "ticket/ts-\$N" ;;
  *"--json headRefOid"*)   echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
  *"pr list"*"--state merged"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/ssh.txt"; : > "$T/run.log"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
# The jobs client the lane sources: queue_put recorded rather than sent, and
# flag_sync DRIVING flags/<name> from "the row" — here the file itself is the
# row, which is the rc 0 / rc 2 pair bin/lib/lane-gate.sh reconciles against.
# _jobs_req answers `{}` so no liveness post reaches a network.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
flag_sync() { [ -f "\${HARNESS:-/root/harness}/flags/\$1" ] && return 0; return 2; }
flag_active() { [ -f "\${HARNESS:-/root/harness}/flags/\$1" ]; }
_jobs_req() { JOBS_HTTP=""; printf '{}'; }
EOF
touch "$H/flags/fly-pool-proja" "$H/flags/fly-pool-projb"

LEDGER="$H/state/blocked-resolver/.last-visited.tsv"
BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
ROWADD() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" abc123 abc123 "$2" "$3" \
          >> "$H/state/merge-conductor/pr-state.tsv"; }
CLEAN() { scratch_rm "$H/state/blocked-resolver"
          scratch_rm "$H/state/lane-gate"
          scratch_rm "$H/state/merge-conductor/handoff-released"
          : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/gh.txt"; : > "$T/ssh.txt"
          : > "$T/alerts.txt"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log"
          : > "$H/state/merge-conductor/pr-state.tsv"; }
WHY="merge-failed-twice: gh pr merge refused"
ISSUE() {
  local labels="[]"
  [ -n "${2:-}" ] && labels=$(printf '%s' "$2" | jq -Rc 'split(",")|map({name:.})')
  jq -nc --argjson n "$1" --argjson l "$labels" --arg t "TK-$1: a parked ticket" \
         --arg c "$(ISO 604800)" \
         '{number:$n,state:"open",labels:$l,title:$t,body:"## Scope",created_at:$c}'
}
for N in 1 2; do ISSUE "$N" ai-build > "$T/issue-$N.json"; echo '[]' > "$T/comments-$N.json"; done
SEED2() { ROWADD "o/proja#1" "$WHY" "https://github.com/o/proja/pull/1"
          ROWADD "o/projb#2" "$WHY" "https://github.com/o/projb/pull/2"; }
QROWS() { grep -c "^$1 " "$T/queue.txt"; }
TICKLINE() { grep 'tick: candidates=' "$H/logs/blocked-resolver.log" \
             | sed -n "${1}p" | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }

# ============================================================================
# 1. THE REAL LANE. One park per project, a budget of four (so the budget can
#    never be what stopped projb), and one flag.
# ============================================================================
CLEAN
SEED2
# The PREFIX NEGATIVE, live: this name holds "proja-x" and nothing else, so a
# gate that compared by prefix would silence proja here.
touch "$H/flags/lane-off-blocked-resolver-proja-x"
touch "$H/flags/lane-off-blocked-resolver-projb"
BRENV=(BR_PER_TICK=4 LANE_GATE_NOW="$NOW")
RUN
[ "$(QROWS proja)" -ge 1 ] && ok \
  || bad "1a proja is not held and must be dispatched (queue: $(cat "$T/queue.txt"))"
[ "$(QROWS projb)" = 0 ] && ok \
  || bad "1b a held project must not be dispatched (queue: $(cat "$T/queue.txt"))"
[ "$(grep -c 'flags/lane-off-blocked-resolver-projb' "$H/logs/blocked-resolver.log")" = 1 ] && ok \
  || bad "1c exactly one line must name the flag, got $(grep -c 'flags/lane-off-blocked-resolver-projb' "$H/logs/blocked-resolver.log"): $(grep 'held' "$H/logs/blocked-resolver.log")"
[ "$(grep -c 'projb' "$T/alerts.txt")" = 0 ] && ok \
  || bad "1d a deliberately held project must never page: $(cat "$T/alerts.txt")"
case "$(TICKLINE 1)" in
  *projb*) bad "1e the tick line must not name a held project as skipped: '$(TICKLINE 1)'" ;;
  '')      bad "1e no tick line was written: $(cat "$H/logs/blocked-resolver.log")" ;;
  *)       ok ;;
esac
case "$(TICKLINE 1)" in *"visited=[proja]"*) ok ;; *) bad "1f proja must be recorded as visited: '$(TICKLINE 1)'" ;; esac
[ -z "$(awk -F'\t' '$1 == "projb" { print $1 }' "$LEDGER" 2>/dev/null)" ] && ok \
  || bad "1g a hold is not a visit — the ledger must carry no projb row: $(cat "$LEDGER" 2>/dev/null)"
# THE ROW OFF AGAIN. The 60s gate cache is why the clock moves: a hold lifted
# mid-tick is seen on the NEXT tick, which is the contract, not a defect.
rm -f "$H/flags/lane-off-blocked-resolver-projb"
BRENV=(BR_PER_TICK=4 LANE_GATE_NOW="$((NOW + 120))")
RUN
BRENV=()
[ "$(QROWS projb)" -ge 1 ] && ok \
  || bad "1h with the flag removed the next tick must dispatch projb (queue: $(cat "$T/queue.txt"))"

# ============================================================================
# 2. bin/review-autopilot.sh — the block, verbatim, before the first GitHub read.
# ============================================================================
EXTRACT "$DIR/bin/review-autopilot.sh" "$T/ap-block.sh" && ok \
  || bad "2a bin/review-autopilot.sh has no # >>> project hold block"
{ cat <<'SH'
#!/bin/bash
set -uo pipefail
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$AP_LOG"
lane_project_held() { LANE_HELD_FLAG="lane-off-review-autopilot-$2"; [ "${HELD:-}" = "$2" ]; }
for P in proja projb; do
  SLUG="o/$P"
  [ -n "$SLUG" ] && [ "$SLUG" != "-" ] || continue
SH
  cat "$T/ap-block.sh"
  cat <<'SH'
  echo "BODY $P"
done
SH
} > "$T/ap-driver.sh"
: > "$T/ap.log"
OUT=$(HELD=projb AP_LOG="$T/ap.log" bash "$T/ap-driver.sh" 2>&1)
[ "$OUT" = "BODY proja" ] && ok \
  || bad "2b a held project must not reach the body, an unheld one must: '$OUT'"
[ "$(grep -c 'flags/lane-off-review-autopilot-projb' "$T/ap.log")" = 1 ] && ok \
  || bad "2c exactly one \$LOG line must name the flag: $(cat "$T/ap.log")"
: > "$T/ap.log"
OUT=$(AP_LOG="$T/ap.log" bash "$T/ap-driver.sh" 2>&1)
[ "$OUT" = "BODY proja
BODY projb" ] && ok || bad "2d with nothing held both projects must run: '$OUT'"
[ ! -s "$T/ap.log" ] && ok || bad "2e nothing held must write no line: $(cat "$T/ap.log")"

# ============================================================================
# 3. bin/merge-conductor.sh — the block at the top of tick_project(), above
#    use_token, below hb_tick.
# ============================================================================
EXTRACT "$DIR/bin/merge-conductor.sh" "$T/mc-block.sh" && ok \
  || bad "3a bin/merge-conductor.sh has no # >>> project hold block"
# The lane's REAL logger and stamp, lifted rather than retyped.
grep -E '^mc_(stamp|log)\(\)' "$DIR/bin/lib/mc/log.sh" > "$T/mc-logfns.sh"
[ "$(wc -l < "$T/mc-logfns.sh")" = 2 ] && ok \
  || bad "3b mc_stamp/mc_log were not found in bin/lib/mc/log.sh: $(cat "$T/mc-logfns.sh")"
MC_DRIVER() {  # MC_DRIVER <outfile> <preamble-file>
  { cat "$2"
    cat <<'SH'
tick_project() {
  local P="$1"
  hb_tick merge-conductor "tick $P"
SH
    cat "$T/mc-block.sh"
    cat <<'SH'
  use_token "o/$P"
  echo "BODY $P"
}
for MCP in proja projb; do tick_project "$MCP"; done
SH
  } > "$1"
}
cat > "$T/mc-pre-stub.sh" <<'SH'
#!/bin/bash
set -uo pipefail
MC_LOG="$MCLOGFILE"
. "$MCFNS"
hb_tick() { printf '%s\n' "$*" >> "$HBF"; }
use_token() { printf '%s\n' "$1" >> "$UTF"; return 0; }
lane_project_held() { LANE_HELD_FLAG="lane-off-merge-conductor-$2"; [ "${HELD:-}" = "$2" ]; }
SH
MC_DRIVER "$T/mc-driver.sh" "$T/mc-pre-stub.sh"
: > "$T/mc.log"; : > "$T/hb"; : > "$T/ut"
OUT=$(HELD=projb MCLOGFILE="$T/mc.log" MCFNS="$T/mc-logfns.sh" HBF="$T/hb" UTF="$T/ut" \
      bash "$T/mc-driver.sh" 2>&1)
[ "$OUT" = "BODY proja" ] && ok \
  || bad "3c a held project must return before the body: '$OUT'"
[ "$(cat "$T/ut")" = "o/proja" ] && ok \
  || bad "3d use_token must not be called for a held project: '$(cat "$T/ut")'"
[ "$(wc -l < "$T/hb")" = 2 ] && ok \
  || bad "3e hb_tick must still fire for a held project: $(cat "$T/hb")"
[ "$(grep -c 'flags/lane-off-merge-conductor-projb' "$T/mc.log")" = 1 ] && ok \
  || bad "3f exactly one mc_log line must name the flag: $(cat "$T/mc.log")"
: > "$T/mc.log"; : > "$T/hb"; : > "$T/ut"
OUT=$(MCLOGFILE="$T/mc.log" MCFNS="$T/mc-logfns.sh" HBF="$T/hb" UTF="$T/ut" \
      bash "$T/mc-driver.sh" 2>&1)
[ "$OUT" = "BODY proja
BODY projb" ] && ok || bad "3g with nothing held both projects must tick: '$OUT'"
[ ! -s "$T/mc.log" ] && ok || bad "3h nothing held must write no line: $(cat "$T/mc.log")"

# ============================================================================
# 4. bin/merge-sweep.sh — the block in the record loop: a held record is neither
#    evaluated nor counted as unseen, and the `-` bucket is never held.
# ============================================================================
SWEEP="$DIR/bin/merge-sweep.sh"
EXTRACT "$SWEEP" "$T/sw-block.sh" && ok \
  || bad "4a the sweep has no # >>> project hold block"
sed -n '/^sweep_tally_prev() {/,/^}/p' "$SWEEP" > "$T/sw-tally.sh"
[ -s "$T/sw-tally.sh" ] && ok || bad "4b sweep_tally_prev was not found in the sweep"
{ cat <<'SH'
#!/bin/bash
set -uo pipefail
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$SWLOG"
declare -A T_SEEN T_MERGED T_RETRY T_TERMNEW T_TERMCACHED
SWEEP_PROJ_ORDER=""; _ITER_PROJ=""; _ITER_CLASS=""
SWEEP_DEADLINE_HIT=no; SWEEP_UNSEEN=0
SWEEP_HELD_SAID=" "; SWEEP_HELD_LIST=""
lane_project_held() { LANE_HELD_FLAG="lane-off-merge-sweep-$2"; [ "${HELD:-}" = "$2" ]; }
SH
  cat "$T/sw-tally.sh"
  cat <<'SH'
while IFS=$'\t' read -r PROJ D; do
  sweep_tally_prev
SH
  cat "$T/sw-block.sh"
  cat <<'SH'
  _ITER_PROJ="$PROJ"; _ITER_CLASS=retryable
  T_SEEN[$PROJ]=$(( ${T_SEEN[$PROJ]:-0} + 1 ))
  echo "BODY $PROJ"
done < <(printf 'proja\tD1\nprojb\tD2\n-\tD3\n')
sweep_tally_prev
echo "SEEN proja=${T_SEEN[proja]:-0} projb=${T_SEEN[projb]:-0} dash=${T_SEEN[-]:-0} unseen=$SWEEP_UNSEEN held=[$SWEEP_HELD_LIST]"
SH
} > "$T/sw-driver.sh"
: > "$T/sw.log"
OUT=$(HELD=projb SWLOG="$T/sw.log" bash "$T/sw-driver.sh" 2>&1)
[ "$OUT" = "BODY proja
BODY -
SEEN proja=1 projb=0 dash=1 unseen=0 held=[projb]" ] && ok \
  || bad "4c a held record must be skipped, untallied and uncounted, and the \`-\` bucket must run: '$OUT'"
[ "$(grep -c 'flags/lane-off-merge-sweep-projb' "$T/sw.log")" = 1 ] && ok \
  || bad "4d exactly one \$LOG line must name the flag: $(cat "$T/sw.log")"
: > "$T/sw.log"
OUT=$(SWLOG="$T/sw.log" bash "$T/sw-driver.sh" 2>&1)
[ "$OUT" = "BODY proja
BODY projb
BODY -
SEEN proja=1 projb=1 dash=1 unseen=0 held=[]" ] && ok \
  || bad "4e with nothing held every record must be walked and tallied: '$OUT'"
[ ! -s "$T/sw.log" ] && ok || bad "4f nothing held must write no line: $(cat "$T/sw.log")"

# ============================================================================
# 5. bin/main-red-pr-pair.sh — a held repo costs no gh call, an unresolvable
#    slug runs unchanged.
# ============================================================================
EXTRACT "$DIR/bin/main-red-pr-pair.sh" "$T/mr-block.sh" && ok \
  || bad "5a bin/main-red-pr-pair.sh has no # >>> project hold block"
{ cat <<'SH'
#!/bin/bash
set -uo pipefail
H="$MRH"
LOG="$MRLOG"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { echo "$(STAMP) $*" >> "$LOG"; return 0; }
pr_pair_signal() { printf '%s\n' "$1" >> "$PPS"; }
lane_project_held() { LANE_HELD_FLAG="lane-off-main-red-pr-pair-$2"; [ "${HELD:-}" = "$2" ]; }
for SLUG in o/proja o/projb o/unknown; do
  [ -n "$SLUG" ] && [ "$SLUG" != "-" ] || continue
SH
  cat "$T/mr-block.sh"
  cat <<'SH'
  pr_pair_signal "$SLUG"
done
SH
} > "$T/mr-driver.sh"
: > "$T/mr.log"; : > "$T/pps"
HELD=projb MRH="$H" MRLOG="$T/mr.log" PPS="$T/pps" bash "$T/mr-driver.sh" >/dev/null 2>&1
[ "$(cat "$T/pps")" = "o/proja
o/unknown" ] && ok \
  || bad "5b a held repo must be skipped and an unresolvable slug must run: '$(cat "$T/pps")'"
[ "$(grep -c 'flags/lane-off-main-red-pr-pair-projb' "$T/mr.log")" = 1 ] && ok \
  || bad "5c exactly one log line must name the flag: $(cat "$T/mr.log")"
: > "$T/mr.log"; : > "$T/pps"
MRH="$H" MRLOG="$T/mr.log" PPS="$T/pps" bash "$T/mr-driver.sh" >/dev/null 2>&1
[ "$(cat "$T/pps")" = "o/proja
o/projb
o/unknown" ] && ok || bad "5d with nothing held every repo must be read: '$(cat "$T/pps")'"
[ ! -s "$T/mr.log" ] && ok || bad "5e nothing held must write no line: $(cat "$T/mr.log")"

# ============================================================================
# 6. THE HOLDS ARE INDEPENDENT, against the REAL lane_project_held. Holding one
#    lane on a project must leave every other lane's work on that project alone
#    — that is the whole point of a per-(lane, project) row.
# ============================================================================
CLEAN
SEED2
rm -f "$H/flags/lane-off-blocked-resolver-projb"
touch "$H/flags/lane-off-merge-conductor-projb"
BRENV=(BR_PER_TICK=4 LANE_GATE_NOW="$((NOW + 240))")
RUN
BRENV=()
[ "$(QROWS projb)" -ge 1 ] && ok \
  || bad "6a a merge-conductor hold must not stop the resolver on that project (queue: $(cat "$T/queue.txt"))"
[ "$(grep -c 'held' "$H/logs/blocked-resolver.log")" = 0 ] && ok \
  || bad "6b the resolver must write no held line for another lane's hold: $(grep 'held' "$H/logs/blocked-resolver.log")"
# ...and the reverse, through the conductor's own block with the real library.
rm -f "$H/flags/lane-off-merge-conductor-projb"
touch "$H/flags/lane-off-blocked-resolver-projb"
scratch_rm "$H/state/lane-gate"
cat > "$T/mc-pre-real.sh" <<'SH'
#!/bin/bash
set -uo pipefail
HARNESS="$MCH"
MC_LOG="$MCLOGFILE"
. "$MCFNS"
. "$HARNESS/bin/jobs-client.sh"
. "$HARNESS/bin/lib/lane-gate.sh"
hb_tick() { printf '%s\n' "$*" >> "$HBF"; }
use_token() { printf '%s\n' "$1" >> "$UTF"; return 0; }
SH
MC_DRIVER "$T/mc-driver-real.sh" "$T/mc-pre-real.sh"
: > "$T/mc.log"; : > "$T/hb"; : > "$T/ut"
OUT=$(MCH="$H" LANE_GATE_NOW="$((NOW + 360))" MCLOGFILE="$T/mc.log" MCFNS="$T/mc-logfns.sh" \
      HBF="$T/hb" UTF="$T/ut" bash "$T/mc-driver-real.sh" 2>&1)
[ "$OUT" = "BODY proja
BODY projb" ] && ok \
  || bad "6c a blocked-resolver hold must not stop the conductor on that project: '$OUT'"
[ "$(cat "$T/ut")" = "o/proja
o/projb" ] && ok || bad "6d the conductor must still spend its token: '$(cat "$T/ut")'"
# ...and the same driver against the conductor's OWN row does hold, which is what
# makes 6c a statement about the row name rather than about a gate that never fired.
touch "$H/flags/lane-off-merge-conductor-projb"
scratch_rm "$H/state/lane-gate"
: > "$T/mc.log"; : > "$T/ut"
OUT=$(MCH="$H" LANE_GATE_NOW="$((NOW + 480))" MCLOGFILE="$T/mc.log" MCFNS="$T/mc-logfns.sh" \
      HBF="$T/hb" UTF="$T/ut" bash "$T/mc-driver-real.sh" 2>&1)
[ "$OUT" = "BODY proja" ] && ok \
  || bad "6e the conductor's own row must hold it, read through the real library: '$OUT'"
[ "$(grep -c 'flags/lane-off-merge-conductor-projb' "$T/mc.log")" = 1 ] && ok \
  || bad "6f the real library must publish the flag name it found: $(cat "$T/mc.log")"

# ============================================================================
# 7. MARKER RATCHET. Exactly one open and one close marker per lane — asserted
#    as a count, so a missing marker is red rather than a match that is absent.
# ============================================================================
for F in bin/blocked-resolver.sh bin/review-autopilot.sh bin/merge-conductor.sh \
         bin/merge-sweep.sh bin/main-red-pr-pair.sh; do
  NOPEN=$(grep -c '^ *# >>> project hold$' "$DIR/$F")
  NCLOSE=$(grep -c '^ *# <<< project hold$' "$DIR/$F")
  [ "$NOPEN" = 1 ] && ok || bad "7 $F must carry exactly one '# >>> project hold' marker, has $NOPEN"
  [ "$NCLOSE" = 1 ] && ok || bad "7 $F must carry exactly one '# <<< project hold' marker, has $NCLOSE"
done

echo "hub-lanes-project-hold: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
