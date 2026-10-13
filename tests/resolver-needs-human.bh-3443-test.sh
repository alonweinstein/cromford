#!/bin/bash
# tests/resolver-needs-human.bh-3443-test.sh — bin/blocked-resolver.sh parks a
# review block that only a human can clear instead of buying a rebuild of it
# (BH-3443 T2.3, T0.3). A RESULT line carrying ` NEEDS_HUMAN:<fp>:<action>`
# calls bin/needs-human-hold.sh (stubbed here: it records its argv and appends
# the tagged marker to the fixture thread), and the row parks HELD with no rung
# spent. BH-3348 paid $6.53 in rebuilds of a block only the hub could clear.
#   §A  the placer is called once, nothing enqueued, HELD + nh_placed + hold-needs-human
#   §S  the skip line and the respected line
#   §B  the next tick: still held, no second placer call, no enqueue
#   §C  HUMAN-STEP-DONE: releases it, and the rebuild runs exactly once
#   §R  a rebuild-review-blocked outcome parks the same way and, released,
#       rebuilds fresh instead of abandoning
#   §U  the placer's rc 75: no rung, retried next tick
#   §W  the switch is on (the placer placed nothing): today's rung
#   §N  no suffix: the placer is never called, today's rung
#   §O  observe mode: a WOULD line, no placer call
# The fixture is tests/resolver-hold-test.sh's.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): every
# created_at below is derived from it, so the fixture thread is internally
# ordered whatever the wall clock says.
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

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
LIB="$H/bin/lib/hold.sh"
cp "$DIR/bin/lib/hold.sh" "$LIB" 2>/dev/null || true
# The fix round's push goes through it (BH-2504); absent on main, hence the || true.
cp "$DIR/bin/lib/hold-push.sh" "$H/bin/lib/" 2>/dev/null || true
chmod +x "$H/bin/"*.sh
# Two projects: tproj is a GitHub-Issues lane (board prefix "-"), iproj is an
# in-app product board, which has no GitHub issue to read (section 9).
{ printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n'
  printf 'iproj o/iproj https://iproj.test /api/internal 3 box-iproj 100.0.0.8\n'; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
# BH-1510.1: the resolver's models are model_routes rows; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj iproj
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# run-build.sh is the RESUME launch (section 8). Recorded, never run: "did the
# resume fire" is the whole question there.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/run-build.txt"\nexit 0\n' "$T" > "$H/bin/run-build.sh"
# agent-call.sh is the adjudicator. Its answer goes in the OUT file (arg 5), the
# way bin/agent-call.sh writes it.
printf '#!/bin/bash\nprintf "ACCEPT\\n" > "$5"\nexit 0\n' > "$H/bin/agent-call.sh"
# lane-alert is RECORDED, never stubbed silent: a respected hold must not page,
# and "it went quiet" is only provable against a recorder.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/run-build.sh" "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh"

# Every gh call is recorded, so "did anything close a PR / reopen one / comment
# on the issue / read the issue at all" is a fact about the run.
# GH_ISSUE_FAIL=1 makes both ISSUE reads fail the way the real outage did.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  # bin/blocked-resolver.sh decides over REST now (#783). This fixture names its
  # PR fields off the NUMBER in the path, so they are written where the shared
  # REST stub reads them and the envelope is answered there.
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*)
    [ "\${GH_ISSUE_FAIL:-}" = 1 ] && { echo "API rate limit already exceeded for user ID 2220366" >&2; exit 1; }
    cat "$T/comments-\$N.json" 2>/dev/null || echo '[]' ;;
  *"repos/"*"/issues/"*)
    [ "\${GH_ISSUE_FAIL:-}" = 1 ] && { echo "API rate limit already exceeded for user ID 2220366" >&2; exit 1; }
    cat "$T/issue-\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*)        cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  # The resolver reads PR state over REST since BH-597 (one gh api
  # repos/O/R/pulls/N for the whole object). Same facts this stub has always
  # answered: the state from $T/prstate, the head sha and branch below it.
  "api repos/"*"/pulls/\$N")
    PST=\$(cat "$T/prstate" 2>/dev/null || echo OPEN)
    if [ "\$PST" = MERGED ]; then
      printf '{"number":%s,"html_url":"https://github.com/o/tproj/pull/%s","title":"t","body":"","state":"closed","merged_at":"2026-09-12T01:00:00Z","merge_commit_sha":"deadbeefcafe","mergeable_state":"clean","draft":false,"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ref":"ticket/ts-%s"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T01:00:00Z","closed_at":"2026-09-12T01:00:00Z"}\n' "\$N" "\$N" "\$N"
    else
      CL=null; [ "\$PST" = CLOSED ] && CL='"2026-09-12T01:00:00Z"'
      LOWST=\$(printf '%s' "\$PST" | tr 'A-Z' 'a-z')
      printf '{"number":%s,"html_url":"https://github.com/o/tproj/pull/%s","title":"t","body":"","state":"%s","merged_at":null,"merge_commit_sha":null,"mergeable_state":"clean","draft":false,"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ref":"ticket/ts-%s"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T00:00:00Z","closed_at":%s}\n' "\$N" "\$N" "\$LOWST" "\$N" "\$CL"
    fi ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *"--json headRefOid,headRefName"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *"--json headRefName"*)  echo "ticket/ts-\$N" ;;
  *"--json headRefOid"*)   echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
  *"pr list"*"--state merged"*) cat "$T/mergedprs" 2>/dev/null ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/mergedprs"; : > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"
: > "$T/ssh.txt"; : > "$T/lane-alert.txt"; : > "$T/run-build.txt"
echo OPEN > "$T/prstate"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN (same rule as tests/blocked-resolver-test.sh).
export GH_TOKEN=""
# A jobs client whose queue_put is recorded rather than sent.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj"   # pool project: the enqueue is a queue row

BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
# The conductor hand-off row this lane drains: key, state, since, head, rev,
# alerted, why, url.
ROW() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" abc123 abc123 "$2" "$3" \
          > "$H/state/merge-conductor/pr-state.tsv"; }
ROWADD() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" abc123 abc123 "$2" "$3" \
          >> "$H/state/merge-conductor/pr-state.tsv"; }
STATEJSON() { cat "$H/state/blocked-resolver/tproj/$1.json" 2>/dev/null; }
CLEAN() { scratch_rm "$H/state/blocked-resolver"
          scratch_rm "$H/state/merge-conductor/handoff-released"
          : > "$T/closed.txt"; : > "$T/queue.txt"
          : > "$T/gh.txt"; : > "$T/ssh.txt"; : > "$T/lane-alert.txt"; : > "$T/run-build.txt"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log"; }

ISSUE() {
  jq -nc --arg c "$(ISO 604800)" \
    '{number:9,state:"open",labels:[{name:"ai-build"}],title:"TK-9: the report rebuilt email",body:"## Scope",created_at:$c}'
}
CMT() { jq -nc --arg b "$1" --arg c "$(ISO "$2")" --arg u "${3:-User}" '{body:$b,created_at:$c,user:{type:$u}}'; }
printf '%s\n' "$(ISSUE)" > "$T/issue-9.json"

ACT='run vs_publish probe from the hub'
FP=abc123def456
RESLINE="REVIEW_BLOCKED review.md NEEDS_HUMAN:$FP:$ACT"
# The placer stub: its argv to calls.placer; the tagged Bot marker appended to
# the thread (unless PLACER_RC is not 0, or PLACER_NOPOST=1 — the switch-on
# answer); exits ${PLACER_RC:-0}.
cat > "$H/bin/needs-human-hold.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.placer"
rc=\$(cat "$T/placer-rc" 2>/dev/null || echo 0)
if [ "\$rc" = 0 ] && [ ! -e "$T/placer-nopost" ]; then
  jq -c --arg b "NEEDS-HUMAN: \$4

Builds of this ticket are paused until a person does the step above.
<!-- nh-fp:\$3 -->" --arg c "$(ISO 1800)" '. + [{body:\$b, created_at:\$c, user:{type:"Bot"}}]' \
    "$T/comments-9.json" > "$T/c.tmp" && mv "$T/c.tmp" "$T/comments-9.json"
fi
exit "\$rc"
SH
chmod +x "$H/bin/needs-human-hold.sh"
DONE_CMT() { jq -c --argjson d "$(CMT 'HUMAN-STEP-DONE: ran it on the hub, it printed PASS' 60)" '. + [$d]' \
               "$T/comments-9.json" > "$T/c.tmp" && mv "$T/c.tmp" "$T/comments-9.json"; }
placer_calls() { cat "$T/calls.placer" 2>/dev/null | grep -c .; }
enqueues() { grep -v '^done ' "$T/queue.txt" 2>/dev/null | grep -c .; }
# RECORD <stamp> <result-line> <age> — a build record of TK-9, finished with the
# review rescue lane (.review-rescued), its RESULT aged <age>.
RECORD() {
  local r="$H/builds/tproj-TK-9-$1"
  scratch_rm "$r"; mkdir -p "$r"
  printf '%s\nTICKET_ID: 9\n' "$2" > "$r/RESULT"
  echo "BLOCK: the hub probe must be run by a person" > "$r/review.md"
  : > "$r/.review-rescued"
  touch -d "@$((NOW - $3))" "$r/RESULT"
  printf '%s' "$r"
}
FRESH() { CLEAN; : > "$H/state/merge-conductor/pr-state.tsv"; rm -f "$T/calls.placer" "$T/placer-rc" "$T/placer-nopost"
          scratch_rm "$H/builds"; mkdir -p "$H/builds"; echo '[]' > "$T/comments-9.json"; }

# ── §A / §S: the first block parks, it does not rebuild ────────────────────
FRESH
REC=$(RECORD 202609290001 "$RESLINE" 10800)
RUN
[ "$(placer_calls)" = 1 ] && ok || bad "A: the placer must be called once, got $(placer_calls)"
[ "$(cat "$T/calls.placer" 2>/dev/null)" = "tproj 9 $FP $ACT resolver" ] && ok \
  || bad "A: placer argv '$(cat "$T/calls.placer" 2>/dev/null)'"
[ "$(enqueues)" = 0 ] && ok || bad "A: a needs-human block must not be enqueued: $(cat "$T/queue.txt")"
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = HELD ] && ok || bad "A: the row must park HELD, got '$(STATEJSON tproj-TK-9 | jq -r .outcome)'"
[[ "$(STATEJSON tproj-TK-9 | jq -r '.nh_placed // ""')" == "$FP "* ]] && ok \
  || bad "A: nh_placed must start with the fp: '$(STATEJSON tproj-TK-9 | jq -r '.nh_placed // ""')'"
STATEJSON tproj-TK-9 | jq -e '[.attempts[].action] | index("hold-needs-human")' >/dev/null && ok \
  || bad "A: the attempts must name hold-needs-human: $(STATEJSON tproj-TK-9 | jq -c '[.attempts[].action]')"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 0 ] && ok || bad "A: no rung spent"
grep -q "#9 skip :: waiting on human: $ACT" "$H/logs/blocked-resolver.log" && ok \
  || bad "S: the skip line: $(grep -i 'human\|HOLD' "$H/logs/blocked-resolver.log")"
grep -q 'HOLD respected TK-9' "$H/logs/blocked-resolver.log" && ok || bad "S: the respected line"
[ -s "$T/closed.txt" ] && bad "A: nothing may be closed" || ok

# ── §B: the next tick is free ──────────────────────────────────────────────
RUN
[ "$(placer_calls)" = 1 ] && ok || bad "B: no second placer call, got $(placer_calls)"
[ "$(enqueues)" = 0 ] && ok || bad "B: still no enqueue: $(cat "$T/queue.txt")"
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = HELD ] && ok || bad "B: still HELD"

# ── §C: the human step is done ─────────────────────────────────────────────
DONE_CMT
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = "" ] && ok || bad "C: the release must clear HELD, got '$(STATEJSON tproj-TK-9 | jq -r .outcome)'"
[ "$(enqueues)" = 1 ] && grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "C: exactly one rebuild enqueued after the release: $(cat "$T/queue.txt")"
[ "$(placer_calls)" = 1 ] && ok || bad "C: the placer is not called again, got $(placer_calls)"
STATEJSON tproj-TK-9 | jq -e '[.attempts[].action] | index("hold-lifted")' >/dev/null && ok \
  || bad "C: hold-lifted must be recorded: $(STATEJSON tproj-TK-9 | jq -c '[.attempts[].action]')"

# ── §R: a rebuild that ended REVIEW_BLOCKED on a human step ────────────────
FRESH
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --arg at "$(ISO 7200)" '{attempts:[{at:$at,action:"rebuild-fresh",reason:"rescue-giving-up",detail:"x"}],
       rebuilds:1, mechanicals:0, fixrounds:0, outcome:"", parked_url:"-"}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
# Ten minutes old: inside br_from_builds' 90-minute floor, so the only source
# that can offer it is the rebuild-outcome one.
REC=$(RECORD 202609290002 "$RESLINE" 600)
RUN
[ "$(placer_calls)" = 1 ] && ok || bad "R: the rebuild's needs-human block calls the placer once, got $(placer_calls)"
grep -q 'rebuild-review-blocked' "$H/logs/blocked-resolver.log" && ok || bad "R: the park must arrive as rebuild-review-blocked"
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = HELD ] && ok || bad "R: parks HELD, got '$(STATEJSON tproj-TK-9 | jq -r .outcome)'"
grep -q -- '-> abandon-rebuild' "$H/logs/blocked-resolver.log" && bad "R: a needs-human block is not abandoned" || ok
RUN
[ "$(placer_calls)" = 1 ] && [ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = HELD ] && ok \
  || bad "R: the next tick re-reads it and stays HELD with no second placer call"
DONE_CMT
: > "$H/logs/blocked-resolver.log"
RUN
grep -q 'rebuild-review-blocked\] -> rebuild-fresh' "$H/logs/blocked-resolver.log" && ok \
  || bad "R: released, the action must be rebuild-fresh: $(grep -- '->' "$H/logs/blocked-resolver.log")"
grep -q -- '-> abandon-rebuild' "$H/logs/blocked-resolver.log" && bad "R: …never abandon-rebuild" || ok
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" != ABANDONED ] && ok || bad "R: the ticket must not be ABANDONED"
[ "$(placer_calls)" = 1 ] && ok || bad "R: no marker re-posted after the lift"

# ── §U: the placer could not read the thread ───────────────────────────────
FRESH
echo 75 > "$T/placer-rc"
REC=$(RECORD 202609290003 "$RESLINE" 10800)
RUN
[ "$(enqueues)" = 0 ] && ok || bad "U: rc 75 spends no rung: $(cat "$T/queue.txt")"
grep -q 'thread unreadable' "$H/logs/blocked-resolver.log" && ok || bad "U: the log must say thread unreadable"
UR=$(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0')
[ "${UR:-0}" = 0 ] && ok || bad "U: no rebuild counted (rebuilds=$UR)"
RUN
[ "$(placer_calls)" = 2 ] && ok || bad "U: the next tick asks the placer again, got $(placer_calls)"

# ── §W: the switch is on, the placer placed nothing ────────────────────────
FRESH
: > "$T/placer-nopost"
REC=$(RECORD 202609290004 "$RESLINE" 10800)
RUN
[ "$(placer_calls)" = 1 ] && ok || bad "W: the placer is asked, got $(placer_calls)"
[ "$(enqueues)" = 1 ] && grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "W: with nothing placed the rung runs as before (one enqueue): $(cat "$T/queue.txt")"
[ "$(STATEJSON tproj-TK-9 | jq -r '.nh_placed // ""')" = "" ] && ok || bad "W: nothing placed, nothing recorded as placed"

# ── §N: no suffix ──────────────────────────────────────────────────────────
FRESH
REC=$(RECORD 202609290005 "REVIEW_BLOCKED review.md" 10800)
RUN
[ "$(placer_calls)" = 0 ] && ok || bad "N: no NEEDS_HUMAN suffix, no placer call"
[ "$(enqueues)" = 1 ] && ok || bad "N: today's rung, one enqueue: $(cat "$T/queue.txt")"

# ── §O: observe mode ───────────────────────────────────────────────────────
FRESH
touch "$H/flags/blocked-resolver-observe"
REC=$(RECORD 202609290006 "$RESLINE" 10800)
RUN
rm -f "$H/flags/blocked-resolver-observe"
[ "$(placer_calls)" = 0 ] && ok || bad "O: observe mode never calls the placer"
grep -q 'WOULD place a needs-human hold' "$H/logs/blocked-resolver.log" && ok \
  || bad "O: observe mode says WOULD place: $(tail -3 "$H/logs/blocked-resolver.log")"
[ "$(enqueues)" = 0 ] && ok || bad "O: …and enqueues nothing"

echo "resolver-needs-human.bh-3443: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
