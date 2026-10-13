#!/bin/bash
# tests/review-rescue-reaped-box.bh-4437-test.sh — A REVIEW_BLOCKED BUILD WHOSE
# POOL BOX WAS REAPED.
#
# THE DEFECT (BH-4437). bin/review-rescue.sh found its candidates only on the
# hub's filesystem (`find $H/builds -maxdepth 2 -name RESULT`). A pool build
# whose review died, on a machine reaped before its result was relayed, never
# got a dir there, so the lane never offered it. The jobs ledger still had the
# record (the `result` artifact row: build_dir, key, box, job) and the branch was
# still on origin. project-3 TK-209 (2026-10-03) and TK-251 (2026-10-04) sat with
# no verdict until somebody noticed.
#
# WHAT THIS SUITE PINS — the REAL lane, the REAL bin/lib/builds-of-record.sh and
# bin/lib/jobs/*.sh, against a scratch hub, a stub worker, a stub gh, a stub
# review agent and a REAL bare origin + clone:
#   R1  a ledger REVIEW_BLOCKED row with no hub dir and no verdict artifact, with
#       an open PR -> builds/pool-<build_dir>/ is materialized from the ledger
#       (JOB_ID:, BUILT_AS:, plan.md from the ledger transcript), the review runs
#       ONCE on the pushed head of the branch, and RESULT becomes PR_CREATED <url>;
#   R2  a second tick: no second review, no second dir, no second materialize;
#   R3  same row, no PR and no pushed branch -> one RESCUE_OUTCOME: no-branch
#       record, one ALERTS line, .review-rescued, no review; R3b a second tick
#       changes none of that;
#   N1-N8 the rows that must NOT materialize (wrong line 1, verdict present, a
#       dir already on the hub, too young, too old, a hostile build_dir, a
#       worker outage — which must come back once the worker answers);
#   N9  a hub-local REVIEW_BLOCKED dir with no branch keeps today's behaviour
#       (retired, no ALERTS line) — the alert is for materialized records only;
#   N10 the per-tick cap (RESCUE_PER_TICK) bounds materialization too, logs a
#       `capped` line, and the next tick picks up the rest;
#   N11 a build bin/blocked-resolver.sh already acted on (its state file has the
#       build in rebuild_seen, or a ladder attempt after the row; an unreadable
#       state file fails closed) is not materialized and buys no review — while
#       an attempt OLDER than the row, or a hold, does not stop it;
#   N12 a row superseded by a newer ledger build of the same ticket is not
#       materialized (rescue_one's KEY search would review the newer build's PR);
#   N13 a tmp record left by a crashed pass is never a walk candidate, and is
#       swept once it is an hour old.
#
# Run from anywhere: bash tests/review-rescue-reaped-box.bh-4437-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git is required"; exit 1; }
unset JOB_ID JOB_PHASE_ID REVIEW_MODEL RESCUE_ONLY RESCUE_PER_TICK RESCUE_LEDGER_LOOKBACK_H

LANE="$DIR/bin/review-rescue.sh"
[ -x "$LANE" ] || { echo "FAIL: bin/review-rescue.sh does not exist or is not executable"; exit 1; }

mkdir -p "$T/fakebin"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in -k) shift 2 ;; -*) shift ;; [0-9]*) shift; break ;; *) break ;; esac
done
exec "$@"
EOF
# The stub gh: `pr list --search` answers $STUBHUB/prlist.out (empty = no PR).
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUBHUB/gh-calls.log"
case "$*" in
  *"pr list"*"--search"*) cat "$STUBHUB/prlist.out" 2>/dev/null ;;
esac
exit 0
EOF
# The stub worker. Feeds per kind, per-job artifacts, and the plan_md transcript.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s %s\n' "$METHOD" "$URL" >> "$STUBHUB/req.txt"
case "$URL" in
  */api/artifacts*kind=result*) printf '%s\n200\n' "$(cat "$STUBHUB/feed.result")"; exit 0 ;;
  */api/artifacts*kind=pr_url*) printf '{"artifacts":[]}\n200\n'; exit 0 ;;
  */api/jobs/*/artifacts)
    [ -f "$STUBHUB/jobs-down" ] && { printf 'boom\n500\n'; exit 0; }
    J="${URL%/artifacts}"; J="${J##*/}"
    if [ -f "$STUBHUB/jobart.$J" ]; then printf '%s\n200\n' "$(cat "$STUBHUB/jobart.$J")"
    else printf '{"artifacts":[{"artifact_kind":"result","artifact_ref":"x"}]}\n200\n'; fi
    exit 0 ;;
  */api/jobs/*/transcripts)
    J="${URL%/transcripts}"; J="${J##*/}"
    if [ -f "$STUBHUB/plan.$J" ]; then
      printf '{"transcripts":[{"phase_id":0,"attempt":1,"stage":"plan","runner":"claude","source":"plan_md","bytes":9}]}\n200\n'
    else printf '{"transcripts":[]}\n200\n'; fi
    exit 0 ;;
  */api/jobs/*/transcript\?*)
    J="${URL%/transcript\?*}"; J="${J##*/}"
    [ -f "$STUBHUB/plan.$J" ] && { printf '%s\n200\n' "$(jq -nc --rawfile b "$STUBHUB/plan.$J" '{transcript:{body:$b}}')"; exit 0; }
    printf '{}\n404\n'; exit 0 ;;
esac
printf '{}\n404\n'
EOF
chmod +x "$T/fakebin/flock" "$T/fakebin/timeout" "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

# ── two origins: one where the ticket's branch was pushed, one where it never was
mkorigin() { # mkorigin <name> [branch]
  local o="$T/$1.git" w="$T/$1-work"
  git init -q --bare "$o"
  mkdir -p "$w"
  (
    cd "$w" || exit 1
    git -c init.defaultBranch=main init -q .
    git config user.email t@t; git config user.name t
    echo src > app.js; git add -A; git commit -qm init; git branch -M main
    git remote add origin "$o"; git push -q -u origin main
    if [ -n "${2:-}" ]; then
      git checkout -q -b "$2"; echo feature >> app.js; git add -A
      git commit -qm "TK-7: the feature"; git push -q -u origin "$2"
    fi
  ) >/dev/null 2>&1
  git -C "$o" symbolic-ref HEAD refs/heads/main
  mkdir -p "$T/repos-$1"
  git clone -q "$o" "$T/repos-$1/project-4"
}
mkorigin pushed ticket/TK-7
mkorigin bare
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
HEAD_AR7=$(git -C "$T/pushed.git" rev-parse refs/heads/ticket/TK-7)

# ── a scratch hub per case, never reused ─────────────────────────────────────
mkhub() { # mkhub <name>
  H="$T/$1"
  mkdir -p "$H/bin/lib/jobs" "$H/builds" "$H/logs" "$H/flags" "$H/locks" "$H/env"
  cp "$DIR/bin/project-of.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-projects-or-alert.sh" \
     "$DIR/bin/test-tamper-scan.sh" "$DIR/bin/alert-line.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  cp "$DIR/bin/lib/builds-of-record.sh" "$H/bin/lib/"
  printf 'project-4 example-org/project-4 - - 2 box-project-4\n' > "$H/fleet.conf"
  : > "$H/env/global.env"; : > "$H/req.txt"; : > "$H/gh-calls.log"; : > "$H/prlist.out"
  printf '{"artifacts":[]}' > "$H/feed.result"
  # The review agent: counts its calls, records the HEAD it was run on (its cwd
  # is the rescue's worktree), and writes the review.md the prompt names.
  cat > "$H/bin/agent-call.sh" <<'EOF'
#!/bin/bash
printf '%s %s\n' "$1" "$(git rev-parse HEAD 2>/dev/null)" >> "$HARNESS/agent-calls.log"
RM=$(printf '%s' "${6:-}" | grep -oE '/[^ ]*/review\.md' | head -1)
[ -n "$RM" ] && printf 'rescued findings\nTIER: 2\nVERDICT: APPROVE\n' > "$RM"
[ -n "${5:-}" ] && : > "$5"
exit 0
EOF
  chmod +x "$H/bin/agent-call.sh"
}
iso_ago() { date -u -d "@$(( NOW - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
# feed <job> <result line> <build_dir> <key> <age seconds> — one ledger result row, appended.
feed() {
  local f="$H/feed.result" det
  det=$(jq -nc --arg b "$3" --arg k "$4" '{build_dir:$b,key:$k}')
  jq -c --arg j "$1" --arg r "$2" --arg u "$(iso_ago "$5")" --arg d "$det" --arg k "$4" \
    '.artifacts += [{job_id:$j,artifact_ref:$r,box:"pool-dead",ticket_id:$k,updated_at:$u,detail:$d}]' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
run_lane() { # run_lane <origin name>
  ( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUBHUB="$H" REPOS_ROOT="$T/repos-$1" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_BOX=test-box \
           REVIEW_MODEL=stub RESCUE_PER_TICK="${PER_TICK:-3}"
    bash "$LANE" ) >>"$H/stdout.txt" 2>&1
}
cnt() { local n; n=$(grep -c "$1" "$2" 2>/dev/null) || n=0; printf '%s' "$n"; }
calls() { cnt . "$H/agent-calls.log"; }
pooldirs() { find "$H/builds" -maxdepth 1 -name "pool-$1*" -type d | wc -l | tr -d ' '; }
RB="REVIEW_BLOCKED: review died mid-run (no VERDICT)"
BD="project-4-TK-7-202610030101"
PRURL="https://github.com/example-org/project-4/pull/397"

# ══ R1 — materialize from the ledger, re-review the pushed head once ═══════
mkhub r1
feed job-r1 "$RB" "$BD" TK-7 10800
printf '# TK-7 plan from the ledger\n' > "$H/plan.job-r1"
printf '397 ticket/TK-7 %s\n' "$PRURL" > "$H/prlist.out"
run_lane pushed
RC=$?
P="$H/builds/pool-$BD"
[ "$RC" = 0 ] && ok || bad "R1 the lane must exit 0, got $RC: $(tail -5 "$H/stdout.txt")"
[ -d "$P" ] && ok || bad "R1 builds/pool-$BD must be materialized from the ledger row (no hub dir existed). builds/: $(ls "$H/builds")"
grep -qx 'JOB_ID: job-r1' "$P/RESULT" 2>/dev/null && ok || bad "R1 RESULT must carry JOB_ID: job-r1, got: $(cat "$P/RESULT" 2>/dev/null)"
grep -qx "BUILT_AS: $BD" "$P/RESULT" 2>/dev/null && ok || bad "R1 RESULT must carry BUILT_AS: $BD"
[ -f "$P/.rescue-materialized" ] && ok || bad "R1 the materialized dir must carry .rescue-materialized"
[ -f "$P/.stale-flagged" ] && ok || bad "R1 the materialized dir must carry .stale-flagged (stale-owed must not page it a second time)"
grep -q 'TK-7 plan from the ledger' "$P/plan.md" 2>/dev/null && ok || bad "R1 plan.md must come from the ledger's plan_md transcript, got: $(cat "$P/plan.md" 2>/dev/null)"
[ "$(calls)" = 1 ] && ok || bad "R1 the review must run exactly once, got $(calls): $(cat "$H/agent-calls.log" 2>/dev/null)"
GOT=$(awk '{print $2}' "$H/agent-calls.log" 2>/dev/null | head -1)
[ "$(awk '{print $1}' "$H/agent-calls.log" 2>/dev/null | head -1)" = review ] && ok || bad "R1 the agent call must be the review stage"
[ "$GOT" = "$HEAD_AR7" ] && ok || bad "R1 the review must run on origin/ticket/TK-7 ($HEAD_AR7), ran on '$GOT'"
[ "$(head -1 "$P/RESULT" 2>/dev/null)" = "PR_CREATED $PRURL" ] && ok || bad "R1 RESULT line 1 must become PR_CREATED $PRURL, got: $(head -1 "$P/RESULT" 2>/dev/null)"
grep -qx 'JOB_ID: job-r1' "$P/RESULT" 2>/dev/null && ok || bad "R1 the APPROVE rewrite must keep JOB_ID:"
[ "$(cnt 'materialized pool-' "$H/logs/review-rescue.log")" = 1 ] && ok || bad "R1 one materialized line, got: $(cat "$H/logs/review-rescue.log" 2>/dev/null)"
grep -q . <<<"$(find "$H/builds" -maxdepth 1 -name '.pool-*')" && bad "R1 no tmp dir may be left behind: $(ls -a "$H/builds")" || ok

# ══ R2 — a second tick buys nothing and makes nothing ══════════════════════
run_lane pushed
[ "$(calls)" = 1 ] && ok || bad "R2 a second tick must not review again, got $(calls) calls"
[ "$(pooldirs project-4-TK-7-)" = 1 ] && ok || bad "R2 exactly one pool-project-4-TK-7-* dir, got $(pooldirs project-4-TK-7-)"
[ "$(cnt 'materialized pool-' "$H/logs/review-rescue.log")" = 1 ] && ok || bad "R2 still one materialized line, got $(cnt 'materialized pool-' "$H/logs/review-rescue.log")"

# ══ R3 — no PR, no pushed branch: one terminal record + one alert ═════════
mkhub r3
feed job-r3 "$RB" "$BD" TK-7 10800
run_lane bare
P="$H/builds/pool-$BD"
[ -d "$P" ] && ok || bad "R3 the record must still be materialized"
[ "$(cnt '^RESCUE_OUTCOME: no-branch' "$P/RESULT")" = 1 ] && ok || bad "R3 exactly one RESCUE_OUTCOME: no-branch line, got: $(cat "$P/RESULT" 2>/dev/null)"
[ "$(head -1 "$P/RESULT" 2>/dev/null)" = "$RB" ] && ok || bad "R3 line 1 stays REVIEW_BLOCKED (the resolver's rescue-giving-up rung reads it)"
[ "$(grep '\[review-rescue\]' "$H/logs/ALERTS.log" 2>/dev/null | grep -c "pool-$BD")" = 1 ] && ok \
  || bad "R3 exactly one [review-rescue] ALERTS line naming the dir — never a silent skip. Got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'job-r3' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "R3 the alert must name the job"
[ -f "$P/.review-rescued" ] && ok || bad "R3 .review-rescued must be stamped"
[ "$(calls)" = 0 ] && ok || bad "R3 nothing to review, got $(calls) agent calls"
# R3b
run_lane bare
[ "$(cnt '^RESCUE_OUTCOME: no-branch' "$P/RESULT")" = 1 ] && ok || bad "R3b a second tick must add no second record"
[ "$(grep -c '\[review-rescue\]' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "R3b a second tick must add no second alert: $(cat "$H/logs/ALERTS.log")"
[ "$(calls)" = 0 ] && ok || bad "R3b still no review"
[ "$(pooldirs project-4-TK-7-)" = 1 ] && ok || bad "R3b still one dir"
# R3c — a crash between the record and the marker: the tick re-enters, and the
# RESCUE_OUTCOME line is what stops a second record and a second page.
# (The append moved RESULT's mtime, so the walk re-offers it 90 minutes later:
# age it to stand for that later tick.)
rm -f "$P/.review-rescued"; touch -d "@$(( NOW - 10800 ))" "$P/RESULT"
run_lane bare
[ "$(cnt '^RESCUE_OUTCOME: no-branch' "$P/RESULT")" = 1 ] && ok || bad "R3c a re-entry after a crash must not write a second record"
[ "$(grep -c '\[review-rescue\]' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "R3c ...nor a second alert: $(cat "$H/logs/ALERTS.log")"
[ -f "$P/.review-rescued" ] && ok || bad "R3c the marker is stamped on the re-entry"

# ══ N1-N7 — rows that must not materialize ════════════════════════════════
nocase() { # nocase <name> <why>   (the hub is already fed)
  run_lane pushed
  [ "$(find "$H/builds" -mindepth 1 -maxdepth 1 -name '*pool-*' | wc -l | tr -d ' ')" = 0 ] \
    && [ "$(cnt 'materialized pool-' "$H/logs/review-rescue.log")" = 0 ] \
    && ok || bad "$1 must not materialize ($2): builds/=$(ls -a "$H/builds" | tr '\n' ' ') log=$(cat "$H/logs/review-rescue.log" 2>/dev/null)"
  [ "$(calls)" = 0 ] && ok || bad "$1 must buy no review, got $(calls)"
}
printf '397 ticket/TK-7 %s\n' "$PRURL" > "$T/pr.out"
mkhub n1; cp "$T/pr.out" "$H/prlist.out"; feed job-n1 "PR_CREATED $PRURL" "$BD" TK-7 10800; nocase N1 "line 1 PR_CREATED"
mkhub n2; cp "$T/pr.out" "$H/prlist.out"; feed job-n2 "PLAN_BLOCKED: ambiguous" "$BD" TK-7 10800; nocase N2 "line 1 PLAN_BLOCKED"
mkhub n3; cp "$T/pr.out" "$H/prlist.out"; feed job-n3 "$RB" "$BD" TK-7 10800
printf '%s' '{"artifacts":[{"artifact_kind":"verdict","artifact_ref":"BLOCK","detail":"{\"settled\":true}"}]}' > "$H/jobart.job-n3"
nocase N3 "the job carries a verdict artifact"
for PFX in pool- fly- ""; do
  mkhub "n4${PFX:-exact}"; cp "$T/pr.out" "$H/prlist.out"; feed job-n4 "$RB" "$BD" TK-7 10800
  mkdir -p "$H/builds/$PFX$BD"; printf 'PR_CREATED %s\n' "$PRURL" > "$H/builds/$PFX$BD/RESULT"
  run_lane pushed
  [ "$(find "$H/builds" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 1 ] && [ "$(cnt 'materialized pool-' "$H/logs/review-rescue.log")" = 0 ] \
    && ok || bad "N4 (${PFX:-exact}) a dir already on the hub must not get a second one: $(ls -a "$H/builds" | tr '\n' ' ')"
done
mkhub n4staged; cp "$T/pr.out" "$H/prlist.out"; feed job-n4s "$RB" "$BD" TK-7 10800
mkdir -p "$H/builds/project-4-TK-7-remote202610030300"
printf 'PR_CREATED %s\nJOB_ID: job-n4s\n' "$PRURL" > "$H/builds/project-4-TK-7-remote202610030300/RESULT"
nocase N4s "the job is already staged on the hub as a -remote copy"
mkhub n5; cp "$T/pr.out" "$H/prlist.out"; feed job-n5 "$RB" "$BD" TK-7 1800; nocase N5 "30 minutes old"
mkhub n6; cp "$T/pr.out" "$H/prlist.out"; feed job-n6 "$RB" "$BD" TK-7 $(( 169 * 3600 )); nocase N6 "older than RESCUE_LEDGER_LOOKBACK_H (168 h)"
mkhub n7; cp "$T/pr.out" "$H/prlist.out"; feed job-n7 "$RB" "../evil" TK-7 10800; feed job-n7b "$RB" ".hidden" TK-7 10800
nocase N7 "a build_dir that is not a plain name"
[ -e "$H/evil" ] || [ -e "$T/evil" ] || [ -e "$H/builds/pool-.." ] && bad "N7 nothing may be created outside builds/" || ok
[ "$(cnt 'refused' "$H/logs/review-rescue.log")" -ge 1 ] && ok || bad "N7 the refusal must be logged: $(cat "$H/logs/review-rescue.log" 2>/dev/null)"
mkhub n7j; cp "$T/pr.out" "$H/prlist.out"; feed - "$RB" "$BD" TK-7 10800; nocase N7j "job id '-'"

# ══ N8 — a worker outage on the verdict read writes nothing, then recovers ═══
mkhub n8; cp "$T/pr.out" "$H/prlist.out"; feed job-n8 "$RB" "$BD" TK-7 10800
touch "$H/jobs-down"
nocase N8 "the verdict read is an outage, not 'no verdict'"
grep -q '\[review-rescue\]' "$H/logs/ALERTS.log" 2>/dev/null && bad "N8 an outage must not page from this lane: $(cat "$H/logs/ALERTS.log")" || ok
rm -f "$H/jobs-down"
run_lane pushed
[ -d "$H/builds/pool-$BD" ] && ok || bad "N8 with the worker back the next tick must materialize (no permanent skip)"
[ "$(calls)" = 1 ] && ok || bad "N8 ...and re-review it once, got $(calls)"

# ══ N9 — a hub-local dir with no branch keeps today's behaviour ═══════════
mkhub n9
L="$H/builds/project-4-TK-7-202610030101"
mkdir -p "$L"; printf '%s\n' "$RB" > "$L/RESULT"
touch -d "@$(( NOW - 10800 ))" "$L/RESULT"
run_lane bare
[ -f "$L/.review-rescued" ] && ok || bad "N9 a local no-branch dir is retired as before"
grep -q '\[review-rescue\]' "$H/logs/ALERTS.log" 2>/dev/null && bad "N9 a local (non-materialized) dir must not page: $(cat "$H/logs/ALERTS.log")" || ok
grep -q '^RESCUE_OUTCOME' "$L/RESULT" && bad "N9 a local dir gets no RESCUE_OUTCOME line" || ok

# ══ N10 — the per-tick cap bounds materialization, and the rest come back ══
mkhub n10
feed job-a "$RB" project-4-TK-7-202610030101 TK-7 14400
feed job-b "$RB" project-4-TK-8-202610030101 TK-8 12600
feed job-c "$RB" project-4-TK-9-202610030101 TK-9 10800
PER_TICK=1 run_lane bare
[ "$(pooldirs project-4-TK-)" = 1 ] && ok || bad "N10 RESCUE_PER_TICK=1 must materialize one record, got $(pooldirs project-4-TK-)"
[ -d "$H/builds/pool-project-4-TK-7-202610030101" ] && ok || bad "N10 the OLDEST row goes first"
[ "$(cnt 'capped' "$H/logs/review-rescue.log")" = 1 ] && ok || bad "N10 the cap must say so in the log: $(cat "$H/logs/review-rescue.log")"
PER_TICK=1 run_lane bare
[ "$(pooldirs project-4-TK-)" = 2 ] && ok || bad "N10 the next tick picks up the next row, got $(pooldirs project-4-TK-)"

# ══ N11 — a build the resolver already acted on is not brought back ═══════
# The resolver's ledger-only branch rebuilt the ticket at hour 6 and recorded it
# only in its state file; materializing the old build would hand it to the
# resolver's glob branch, which has no rebuild_seen check, and buy a second review.
rstate() { # rstate <json> — the ticket's resolver state, as bin/blocked-resolver.sh names it
  mkdir -p "$H/state/blocked-resolver/project-4"; printf '%s\n' "$1" > "$H/state/blocked-resolver/project-4/project-4-TK-7.json"
}
for SEEN in "$BD" "pool-$BD" "fly-$BD"; do
  mkhub "n11-$SEEN"; cp "$T/pr.out" "$H/prlist.out"; feed job-n11 "$RB" "$BD" TK-7 30000
  rstate "$(jq -nc --arg b "$SEEN" '{rebuild_seen:[$b],attempts:[]}')"
  nocase "N11 (rebuild_seen $SEEN)" "the resolver already consumed this build"
done
mkhub n11att; cp "$T/pr.out" "$H/prlist.out"; feed job-n11 "$RB" "$BD" TK-7 30000
rstate "$(jq -nc --arg a "$(iso_ago 8400)" '{rebuild_seen:[],attempts:[{action:"rebuild",at:$a}]}')"
nocase "N11 (attempt after the row)" "a ladder attempt at or after the record"
mkhub n11bad; cp "$T/pr.out" "$H/prlist.out"; feed job-n11 "$RB" "$BD" TK-7 30000
rstate '{not json'
nocase "N11 (unreadable state)" "an unreadable resolver state fails closed"
# The negatives of the guard: an attempt from BEFORE this build, or a hold, is
# not the resolver acting on it.
mkhub n11old; cp "$T/pr.out" "$H/prlist.out"; feed job-n11 "$RB" "$BD" TK-7 30000
rstate "$(jq -nc --arg a "$(iso_ago 40000)" --arg h "$(iso_ago 8400)" '{rebuild_seen:["project-4-TK-7-202609300000"],attempts:[{action:"rebuild",at:$a},{action:"held",at:$h}]}')"
run_lane pushed
[ -d "$H/builds/pool-$BD" ] && ok || bad "N11 an older attempt or a hold must not block materialization: $(cat "$H/logs/review-rescue.log" 2>/dev/null)"
[ "$(calls)" = 1 ] && ok || bad "N11 ...and the review runs once, got $(calls)"

# ══ N12 — a row superseded by a newer build of the same ticket ═════════════
mkhub n12; cp "$T/pr.out" "$H/prlist.out"
feed job-n12old "$RB" "$BD" TK-7 30000
feed job-n12new "PR_CREATED $PRURL" project-4-TK-7-202610031200 TK-7 10800
nocase N12 "the ledger holds a newer build of TK-7"
grep -q 'superseded' "$H/logs/review-rescue.log" 2>/dev/null && ok || bad "N12 the skip must say why: $(cat "$H/logs/review-rescue.log" 2>/dev/null)"
# ...and a newer build of ANOTHER ticket supersedes nothing.
mkhub n12other; cp "$T/pr.out" "$H/prlist.out"
feed job-n12a "$RB" "$BD" TK-7 30000
feed job-n12b "PR_CREATED https://github.com/example-org/project-4/pull/398" project-4-TK-70-202610031200 TK-70 10800
run_lane pushed
[ -d "$H/builds/pool-$BD" ] && ok || bad "N12 a newer build of a different ticket (TK-70) must not supersede TK-7"

# ══ N13 — a crashed pass's tmp record ══════════════════════════════════════
mkhub n13
TD="$H/builds/.pool-$BD.tmp.99999"
mkdir -p "$TD"; printf '%s\nJOB_ID: job-n13\n' "$RB" > "$TD/RESULT"
touch -d "@$(( NOW - 10800 ))" "$TD/RESULT"
run_lane bare
[ -e "$TD/.review-rescued" ] && bad "N13 the walk must never take a tmp record as a candidate" || ok
grep -q '\[review-rescue\]' "$H/logs/ALERTS.log" 2>/dev/null && bad "N13 a tmp record must not page: $(cat "$H/logs/ALERTS.log")" || ok
[ -d "$TD" ] && ok || bad "N13 a tmp record under an hour old is left alone (a live run may own it)"
touch -d "@$(( NOW - 7200 ))" "$TD"
run_lane bare
[ -e "$TD" ] && bad "N13 an hour-old tmp record must be swept: $(ls -a "$H/builds")" || ok

echo "review-rescue-reaped-box.bh-4437-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
