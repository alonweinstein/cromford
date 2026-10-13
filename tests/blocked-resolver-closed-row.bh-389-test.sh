#!/bin/bash
# tests/blocked-resolver-closed-row.bh-389-test.sh — BH-389: a PR the
# blocked-resolver closes UNMERGED moves its console build row to a terminal,
# non-merged stage.
#
# THE BUG THIS PINS. The resolver closed project-5 #1237/#1239/#1242/#1220 and
# told the console only a `fleet_event`. No `kind:"build"` beat ever addressed
# the closed PR's build row, so it kept its last stage (pr_created, or
# pr_merged where pre-BH-866 reconcile-prs had stamped it) and nothing named
# the rebuild that replaced it. Now, after a VERIFIED close, the resolver sends
# one build beat: `superseded` (the successor job id in `detail`) for the
# rebuild rung, `abandoned` for the two abandon closes, and `merged:false`
# always.
#
# Driven end to end through the real script with a RECORDING beat.sh, so every
# assertion is about a beat the lane actually sent. Fixture from
# tests/blocked-resolver.bh-488-test.sh.
# Run from anywhere: tests/blocked-resolver-closed-row.bh-389-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/hold.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
for f in agent-call.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
# THE RECORDER. Every beat is appended as one JSON line, and a marker goes into
# the SAME sequence file the gh stub writes to, so "the close came before the
# beat" is an order in one file rather than a reading of the source.
cat > "$H/bin/beat.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$T/beats.jsonl"
printf '%s\n' "\$1" >> "$T/all-beats.jsonl"
printf 'BEAT %s\n' "\$(printf '%s' "\$1" | jq -r '.kind // "?"' 2>/dev/null)" >> "$T/seq.txt"
exit 0
EOF
chmod +x "$H/bin/beat.sh"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
printf 'GH %s\n' "\$*" >> "$T/seq.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) cat "$T/comments-\$N.json" 2>/dev/null || echo '[]' ;;
  *"repos/"*"/issues/"*)   cat "$T/issue-\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN.
export GH_TOKEN=""

URL="https://github.com/o/tproj/pull/9"
REC="$H/builds/tproj-TK-9-202609240600"
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
ROW()   { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "o/tproj#9" "$NOW" abc123 abc123 \
            "conflict-unresolvable: CONFLICT (content): src/a.ts" "$URL" > "$H/state/merge-conductor/pr-state.tsv"; }
ROWCLOSED() { printf '%s\tCLOSED\t%s\t%s\t%s\t-\t%s\t%s\n' "o/tproj#9" "$NOW" abc123 abc123 \
            "conflict-unresolvable: CONFLICT (content): src/a.ts" "$URL" > "$H/state/merge-conductor/pr-state.tsv"; }
STATEJSON() { cat "$H/state/blocked-resolver/tproj/$1.json" 2>/dev/null; }
LOG() { tail -5 "$H/logs/blocked-resolver.log" 2>/dev/null; }
# SPENT <rebuilds> — the two cheaper rungs already ran, so the next rung is the
# rebuild (or, at the cap, the abandon).
SPENT() {
  mkdir -p "$H/state/blocked-resolver/tproj"
  jq -nc --argjson r "${1:-0}" '{project:"tproj",rkey:"tproj-TK-9",mechanicals:1,fixrounds:1,rebuilds:$r,outcome:"",attempts:[]}' \
    > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
}
JOBS_OK() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
}
JOBS_FAIL() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf 'REFUSED %s\n' "\$*" >> "$T/queue-attempts.txt"; return 1; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
}
CLEAN() { scratch_rm "$H/state/blocked-resolver" 2>/dev/null
          mkdir -p "$H/state/blocked-resolver/tproj"
          : > "$H/state/merge-conductor/pr-state.tsv"
          : > "$T/queue.txt"; : > "$T/queue-attempts.txt"; : > "$T/closed.txt"
          : > "$T/lane-alert.txt"; : > "$T/comments.txt"; : > "$T/gh.txt"
          : > "$T/beats.jsonl"; : > "$T/seq.txt"; rm -f "$T"/st-*
          : > "$H/logs/blocked-resolver.log"; : > "$H/logs/ALERTS.log"
          rm -f "$H/flags/blocked-resolver-observe"
          scratch_rm "$REC" 2>/dev/null
          mkdir -p "$REC"; printf 'PR_CREATED %s\n' "$URL" > "$REC/RESULT"
          printf '[]\n' > "$T/comments-9.json"
          echo OPEN > "$T/prstate"; printf 'ticket/TK-9' > "$T/prbranch"; : > "$T/prtitle"; }
# BUILDS — every kind:"build" beat, one compact JSON per line.
BUILDS() { jq -c 'select(.kind=="build")' "$T/beats.jsonl" 2>/dev/null; }
NBUILDS() { BUILDS | grep -c . ; }
touch "$H/flags/fly-pool-tproj"
jq -nc --arg c "$(ISO 604800)" \
  '{number:9,state:"open",labels:[{name:"ai-build"}],title:"TK-9: the report nav",body:"## Scope",created_at:$c}' \
  > "$T/issue-9.json"

# ============================================================================
# 1. THE BUG: the rebuild rung closes the PR and the enqueue lands. The closed
#    PR's build row gets exactly one build beat: superseded, merged:false, the
#    row named by run-build's own bkey, and the successor job in the detail.
# ============================================================================
CLEAN; JOBS_OK; SPENT 0; ROW
RUN
[ "$(grep -c -- '-X PATCH' "$T/closed.txt")" = 1 ] && ok \
  || bad "1: the rebuild rung must close the PR once (closed: $(cat "$T/closed.txt"); log: $(LOG))"
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "1: the rebuild must be enqueued (queue: $(cat "$T/queue.txt"); log: $(LOG))"
[ "$(NBUILDS)" = 1 ] && ok \
  || bad "THE BUG: a PR the resolver closed must move its build row with ONE kind:build beat (got $(NBUILDS): $(BUILDS); log: $(LOG))"
B=$(BUILDS | head -1)
[ "$(printf '%s' "$B" | jq -r .stage)" = superseded ] && ok \
  || bad "1: the stage must be superseded (beat: $B)"
[ "$(printf '%s' "$B" | jq -r .merged)" = false ] && ok \
  || bad "1: merged must be literally false (beat: $B)"
[ "$(printf '%s' "$B" | jq -r .bkey)" = "build:tproj:TK-9:$(basename "$REC")" ] && ok \
  || bad "1: the bkey must be run-build's own (build:<p>:<key>:<record basename>) (beat: $B)"
[ "$(printf '%s' "$B" | jq -r .pr_url)" = "$URL" ] && ok \
  || bad "1: the beat must name the closed PR (beat: $B)"
[ "$(printf '%s' "$B" | jq -r .project)/$(printf '%s' "$B" | jq -r .ticket_key)" = "tproj/TK-9" ] && ok \
  || bad "1: project and ticket_key must be on the beat (beat: $B)"
JOB=$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].detail' | sed -nE 's/.*job (TK-9@[^)]*)\).*/\1/p')
[ -n "$JOB" ] && printf '%s' "$B" | jq -e --arg j "$JOB" '.detail | contains($j)' >/dev/null && ok \
  || bad "1: the detail must link the successor job '$JOB' (beat: $B)"
printf '%s' "$B" | jq -e 'has("tier") or has("verdict") | not' >/dev/null && ok \
  || bad "1: the beat must not rewrite tier/verdict (beat: $B)"
# ORDER: the verified close (the PATCH) comes before the build beat.
PATCH_LN=$(grep -n -- '^GH .*-X PATCH' "$T/seq.txt" | head -1 | cut -d: -f1)
BEAT_LN=$(grep -n '^BEAT build$' "$T/seq.txt" | head -1 | cut -d: -f1)
[ -n "$PATCH_LN" ] && [ -n "$BEAT_LN" ] && [ "$PATCH_LN" -lt "$BEAT_LN" ] && ok \
  || bad "1: the close must come before the build beat (patch line ${PATCH_LN:-none}, beat line ${BEAT_LN:-none})"

# ============================================================================
# 2. The ticket says ABANDON -> br_hold_abandon closes the PR -> abandoned.
# ============================================================================
CLEAN; JOBS_OK; SPENT 0; ROW
jq -nc --arg c "$(ISO 1800)" '[{body:"ABANDON — the operator: drop this one.",created_at:$c,user:{type:"User"}}]' \
  > "$T/comments-9.json"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "2: the ABANDON word must end the ladder (outcome '$(STATEJSON tproj-TK-9 | jq -r .outcome)'; log: $(LOG))"
[ "$(NBUILDS)" = 1 ] && ok \
  || bad "2: an ABANDON close must move the build row with one build beat (got $(NBUILDS): $(BUILDS))"
B=$(BUILDS | head -1)
[ "$(printf '%s' "$B" | jq -r '.stage + " " + (.merged|tostring)')" = "abandoned false" ] && ok \
  || bad "2: the stage must be abandoned and merged false (beat: $B)"
printf '%s' "$B" | jq -e '.detail | contains("ABANDON")' >/dev/null && ok \
  || bad "2: the detail must say why (beat: $B)"
grep -q '^tproj ' "$T/queue.txt" && bad "2: an abandoned ticket must not be enqueued: $(cat "$T/queue.txt")" || ok

# ============================================================================
# 3. The rebuild cap is reached -> br_abandon closes the PR -> abandoned.
# ============================================================================
CLEAN; JOBS_OK; SPENT 3; ROW
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "3: the cap must abandon (outcome '$(STATEJSON tproj-TK-9 | jq -r .outcome)'; log: $(LOG))"
[ "$(grep -c -- '-X PATCH' "$T/closed.txt")" = 1 ] && ok \
  || bad "3: the abandon must close the PR (closed: $(cat "$T/closed.txt"))"
[ "$(NBUILDS)" = 1 ] && ok \
  || bad "3: a ladder-exhausted close must move the build row with one build beat (got $(NBUILDS): $(BUILDS))"
B=$(BUILDS | head -1)
[ "$(printf '%s' "$B" | jq -r '.stage + " " + (.merged|tostring)')" = "abandoned false" ] && ok \
  || bad "3: the stage must be abandoned and merged false (beat: $B)"
[ "$(printf '%s' "$B" | jq -r .bkey)" = "build:tproj:TK-9:$(basename "$REC")" ] && ok \
  || bad "3: the abandoned beat must name the same row (beat: $B)"

# ============================================================================
# 4. THE NEGATIVES. No build beat without a verified close, without a
#    successor, or in observe mode.
# ============================================================================
# 4a. GitHub refuses the close: nothing is closed, so nothing may be beaten.
CLEAN; JOBS_OK; SPENT 0; ROW
echo 502 > "$T/st-patch"
RUN
grep -q '^tproj ' "$T/queue.txt" && bad "4a: a refused close must enqueue nothing: $(cat "$T/queue.txt")" || ok
[ "$(NBUILDS)" = 0 ] && ok \
  || bad "4a: a close GitHub refused must send NO build beat (got: $(BUILDS); log: $(LOG))"
# 4b. The close lands and the enqueue fails: no successor yet, so no beat...
CLEAN; JOBS_FAIL; SPENT 0; ROW
RUN
[ "$(grep -c -- '-X PATCH' "$T/closed.txt")" = 1 ] && ok \
  || bad "4b: the close must land before the failed enqueue (closed: $(cat "$T/closed.txt"))"
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action')" = rebuild-fresh-failed ] && ok \
  || bad "4b: the enqueue must have failed (attempts: $(STATEJSON tproj-TK-9 | jq -c '[.attempts[].action]'))"
[ "$(NBUILDS)" = 0 ] && ok \
  || bad "4b: a failed enqueue has no successor to link, so no build beat yet (got: $(BUILDS))"
# ...and the retry tick that lands the enqueue sends exactly one superseded.
ROWCLOSED; echo CLOSED > "$T/prstate"; JOBS_OK
RUN
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "4b: the retry must enqueue (queue: $(cat "$T/queue.txt"); log: $(LOG))"
[ "$(NBUILDS)" = 1 ] && [ "$(BUILDS | jq -r .stage)" = superseded ] && ok \
  || bad "4b: the retry that lands must send ONE superseded beat (got: $(BUILDS); log: $(LOG))"
# 4c. Observe mode takes no rung, so it moves no row.
CLEAN; JOBS_OK; SPENT 0; ROW
touch "$H/flags/blocked-resolver-observe"
RUN
rm -f "$H/flags/blocked-resolver-observe"
grep -q 'observe mode' "$H/logs/blocked-resolver.log" && ok \
  || bad "4c: the tick must have run in observe mode (log: $(LOG))"
[ "$(NBUILDS)" = 0 ] && ok \
  || bad "4c: observe mode must send no build beat (got: $(BUILDS))"
# 4d. Observe mode on an ABANDON ticket and at the cap: still nothing.
CLEAN; JOBS_OK; SPENT 3; ROW
touch "$H/flags/blocked-resolver-observe"
RUN
rm -f "$H/flags/blocked-resolver-observe"
[ "$(NBUILDS)" = 0 ] && ok || bad "4d: observe mode at the cap must send no build beat (got: $(BUILDS))"

# ============================================================================
# 6. REVIEW B1: a row from br_from_rebuilds pairs the REBUILD's record with the
#    OLD PR (parked_url), which rung 3 already closed and beat superseded. The
#    abandon-rebuild terminal and a build-dead re-rebuild must send no build
#    beat: none that hangs the old PR on the rebuild's row, none that says
#    "closed unmerged" about a build that never had a PR.
# ============================================================================
RREC="$H/builds/tproj-TK-9-202609240800"
REBUILT() { # REBUILT <RESULT line> — rung 3 ran an hour ago; the rebuild ended.
  ROWCLOSED; echo CLOSED > "$T/prstate"
  : > "$REC/.blocked-resolver-superseded"
  jq -nc --arg at "$(ISO 3600)" --arg u "$URL" --arg r "$REC" \
    '{project:"tproj",rkey:"tproj-TK-9",mechanicals:1,fixrounds:1,rebuilds:1,outcome:"",
      rebuild_jobs:[{id:"TK-9@E1~r1",enqueued_at:$at,at:$at}],
      attempts:[{at:$at,action:"rebuild-fresh",reason:"conflict-unresolvable",detail:"fresh build enqueued (rebuild 1 of 3)"}],
      parked_url:$u,parked_rec:$r}' > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
  scratch_rm "$RREC" 2>/dev/null; mkdir -p "$RREC"
  printf '%s\n' "$1" > "$RREC/RESULT"; touch -d "@$((NOW+60))" "$RREC/RESULT"
}
# 6a. The rebuild ended PLAN_BLOCKED -> abandon-rebuild -> br_abandon.
CLEAN; JOBS_OK; REBUILT "PLAN_BLOCKED the ticket does not say which rate applies, see $RREC/plan.md"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "6a: a PLAN_BLOCKED rebuild must abandon (outcome '$(STATEJSON tproj-TK-9 | jq -r .outcome)'; log: $(LOG))"
BUILDS | jq -e --arg b "build:tproj:TK-9:$(basename "$RREC")" --arg u "$URL" \
    'select(.bkey==$b and .pr_url==$u)' >/dev/null 2>&1 \
  && bad "6a: the rebuild's row must never be paired with the old PR (got: $(BUILDS))" || ok
[ "$(NBUILDS)" = 0 ] && ok \
  || bad "6a: abandon-rebuild closed nothing this tick, so it must send no build beat (got: $(BUILDS); log: $(LOG))"
# 6b. The rebuild died -> rebuild-fresh again; the enqueue lands, still no beat.
CLEAN; JOBS_OK; REBUILT "BUILD_DEAD the machine went away"
RUN
grep -q '^tproj TK-9 ' "$T/queue.txt" && ok \
  || bad "6b: a dead rebuild must be rebuilt (queue: $(cat "$T/queue.txt"); log: $(LOG))"
[ "$(NBUILDS)" = 0 ] && ok \
  || bad "6b: a re-rebuild after BUILD_DEAD closed nothing this tick, so it must send no build beat (got: $(BUILDS); log: $(LOG))"
scratch_rm "$RREC" 2>/dev/null

# ============================================================================
# 5. Across every scenario above, no build beat ever claimed a merge.
# ============================================================================
ALLB="$T/all-beats.jsonl"
[ -s "$ALLB" ] && ok || bad "5: the beat recorder captured nothing across the file"
jq -e 'select(.kind=="build") | select(.merged==true or .stage=="pr_merged")' "$ALLB" >/dev/null 2>&1 \
  && bad "5: a build beat claimed a merge: $(jq -c 'select(.kind=="build" and (.merged==true or .stage=="pr_merged"))' "$ALLB")" || ok

echo "blocked-resolver-closed-row.bh-389-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
