#!/bin/bash
# tests/review-rescue.bh-858-test.sh — THE STRANDEE WHOSE VERDICT WAS NEVER
# RECORDED.
#
# THE DEFECT (BH-858). A record whose terminal is `PR_CREATE_FAILED` but whose
# review.md ends in `VERDICT: APPROVE` is not a build waiting for a review — a
# reviewer read the diff and answered, and the only thing that died was `gh pr
# create`. Until BH-858 the verdict row needed a PR to exist first, so those
# judgements are in no ledger at all; and bin/review-rescue.sh walked straight
# past them because its candidate filter keys on `REVIEW_BLOCKED`.
#
# WHAT THIS SUITE PINS — the `verdict_backfill` pass of the REAL lane, against a
# scratch hub and a stub worker that records every request. The pass opens no PR,
# buys no review, takes no worktree and makes no `gh` call:
#   (a) APPROVE + a job row -> ONE settled tier-2 verdict row bound to the review
#       sha; the marker; no alert; a second run costs the worker nothing;
#   (b) no review.md at all -> no row, exactly one ALERTS line, once;
#   (c) VERDICT: BLOCK -> nothing owed, nothing written, nothing paged;
#   (d) no sha files but a provisional row that names one -> that sha is kept;
#   (e) a row that is already settled -> no write;
#   (f) a worker outage -> no row, NO MARKER, no alert (D11);
#   (g) a review served by a fallback runner -> provenance `fallback`, so a
#       cheap-lane APPROVE can never be mistaken for a Claude one;
#   (h) the cap is honoured and the rest come back next tick (D12);
#   (i) the REVIEW_BLOCKED candidate walk is untouched;
#   (k) THE SHAPE THE FIELD ACTUALLY HAS: bin/pr-url-reconcile.sh ticks every 10
#       minutes and this lane every 30, so a strandee whose PR exists on the
#       branch has had line 1 rewritten to `PR_CREATED … | RECONCILED …` long
#       before the backfill sees it. That record is still a strandee — the
#       create failure is one line down as `RECONCILED_FROM:` — and it must be
#       backfilled, or Ask 3 delivers nothing for the population it was filed
#       about;
#   (l) the negatives around it: a build that linked its OWN PR (no
#       RECONCILED_FROM) is never walked, and a review.md whose only APPROVE is
#       quoted inside a finding is not a judgement.
#
# Run from anywhere: bash tests/review-rescue.bh-858-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive the backfill"; exit 1; }
unset JOB_ID JOB_PHASE_ID

LANE="$DIR/bin/review-rescue.sh"
[ -x "$LANE" ] || { echo "FAIL: bin/review-rescue.sh does not exist or is not executable"; exit 1; }

mkdir -p "$T/fakebin"
# flock and timeout are util-linux on the hub; the backfill uses neither, and the
# candidate walk's use of both is incidental to everything asserted here.
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in -k) shift 2 ;; -*) shift ;; [0-9]*) shift; break ;; *) break ;; esac
done
exec "$@"
EOF
# A `gh` that answers nothing: the backfill must call it ZERO times, and the
# candidate walk in case (i) needs it to be harmless.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUBHUB/gh-calls.log"
exit 0
EOF
# The stub worker. Every request is recorded, so "exactly one PUT" is an
# assertion about traffic.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$STUBHUB/req.txt"
case "$URL" in
  */api/artifacts*)
    [ -f "$STUBHUB/worker-down" ] && { printf 'boom\n500\n'; exit 0; }
    printf '%s\n200\n' "$(cat "$STUBHUB/feed")"; exit 0 ;;
esac
case "$METHOD $URL" in
  "PUT "*/artifacts) printf '{"ok":true}\n200\n'; exit 0 ;;
  "GET "*/artifacts)
    J="${URL%/artifacts}"; J="${J##*/}"
    [ -f "$STUBHUB/jobartifacts.$J" ] && { printf '%s\n200\n' "$(cat "$STUBHUB/jobartifacts.$J")"; exit 0; }
    printf '%s\n200\n' "$(cat "$STUBHUB/jobartifacts")"; exit 0 ;;
esac
printf '{}\n404\n'
EOF
chmod +x "$T/fakebin/flock" "$T/fakebin/timeout" "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

# ── a scratch hub ───────────────────────────────────────────────────────────
mkhub() { # mkhub <name> [no-client]
  # One directory per case, never reused: nothing here removes a tree.
  H="$T/$1"
  mkdir -p "$H/bin/lib" "$H/builds" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$T/repos"
  cp "$DIR/bin/review-rescue.sh" "$DIR/bin/project-of.sh" "$DIR/bin/fleet-conf.sh" \
     "$DIR/bin/fleet-projects-or-alert.sh" "$DIR/bin/test-tamper-scan.sh" "$H/bin/"
  cp "$DIR/bin/alert-line.sh" "$H/bin/"
  [ "${2:-}" = no-client ] || { cp "$DIR/bin/jobs-client.sh" "$H/bin/jobs-client.sh"
    mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"; }
  printf 'project-4 example-org/project-4 - - 2 box-project-4\n' > "$H/fleet.conf"
  : > "$H/env/global.env"; : > "$H/req.txt"; : > "$H/gh-calls.log"
  : > "$H/feed"
  printf '%s' '{"artifacts":[{"artifact_kind":"result","artifact_ref":"ok"}]}' > "$H/jobartifacts"
}
feed_names() { # feed_names <build dir basename> [job id]
  printf '{"artifacts":[{"job_id":"%s","artifact_ref":"ok","box":"pool-1","ticket_id":"TK-1","updated_at":"u","detail":"{\\"build_dir\\":\\"%s\\"}"}]}' \
    "${2:-build-project-4-1}" "${1#pool-}" > "$H/feed"
}
feed_names2() { # feed_names2 <dir1> <job1> <dir2> <job2>
  printf '{"artifacts":[{"job_id":"%s","artifact_ref":"ok","box":"p","ticket_id":"t","updated_at":"u","detail":"{\\"build_dir\\":\\"%s\\"}"},{"job_id":"%s","artifact_ref":"ok","box":"p","ticket_id":"t","updated_at":"u","detail":"{\\"build_dir\\":\\"%s\\"}"}]}' \
    "$2" "${1#pool-}" "$4" "${3#pool-}" > "$H/feed"
}
record() { # record <dir> <RESULT line 1>
  local d="$H/builds/$1"; mkdir -p "$d"
  printf '%s\n' "$2" > "$d/RESULT"
  # The candidate walk only looks at RESULTs older than 90 minutes; the backfill
  # has no such bound, and both are driven from the same tree below.
  touch -d '1970-01-01' "$d/RESULT" 2>/dev/null || touch -t 197001010000 "$d/RESULT"
  echo "$d"
}
run_lane() {
  ( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUBHUB="$H" REPOS_ROOT="$T/repos" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_BOX=test-box \
           VERDICT_BACKFILL_MAX="${VBMAX:-25}"
    bash "$LANE" ) >"$H/stdout.txt" 2>&1
}
puts() { grep -c '^PUT .*/artifacts' "$H/req.txt" 2>/dev/null || true; }
FAILLINE="PR_CREATE_FAILED: GraphQL: API rate limit already exceeded for installation ID 161623167. — refused a url-less create claim carrying ''"
BLOCKLINE="REVIEW_BLOCKED: the review found real problems"
# One of the PRs the ticket names: hand-opened over REST after the create died,
# which is how these records come to wear the RECONCILED shape.
U1591="https://github.com/example-org/project-4/pull/1591"

# ══ (a) APPROVE + a job row -> one settled tier-2 row, bound to the sha ═════
mkhub a
REC="pool-project-4-TK-1-1"
D=$(record "$REC" "$FAILLINE")
printf 'findings\nTIER: 1\nVERDICT: APPROVE\n' > "$D/review.md"
echo abc123 > "$D/reviewed-sha"
feed_names "$REC"
run_lane
RC=$?
[ "$RC" = 0 ] && ok || bad "(a) the lane must exit 0, got $RC: $(tail -5 "$H/stdout.txt")"
[ "$(puts)" = 1 ] && ok || bad "(a) exactly one artifact PUT, got $(puts): $(grep '^PUT' "$H/req.txt")"
BODY=$(grep '^PUT ' "$H/req.txt" | head -1 | cut -d' ' -f3-)
[ "$(jq -r '.artifact_kind' <<<"$BODY" 2>/dev/null)" = verdict ] \
  && ok || bad "(a) the row must be a verdict artifact, got: $BODY"
[ "$(jq -r '.artifact_ref' <<<"$BODY" 2>/dev/null)" = APPROVE ] \
  && ok || bad "(a) the word must be APPROVE, got: $BODY"
DET=$(jq -r '.detail' <<<"$BODY" 2>/dev/null)
[ "$(jq -r '.tier' <<<"$DET" 2>/dev/null)" = 2 ] \
  && ok || bad "(a) a backfilled row is ALWAYS tier 2 — QA, E2E, scope, kind and the head-bound gate never ran on this build, and tier 1 means auto-merge. Got: $DET"
[ "$(jq -r '.settled' <<<"$DET" 2>/dev/null)" = true ] \
  && ok || bad "(a) the backfilled row is settled — the merge lanes must be able to act on it. Got: $DET"
[ "$(jq -r '.reviewed_sha' <<<"$DET" 2>/dev/null)" = abc123 ] \
  && ok || bad "(a) the row must be bound to the sha the review ran on, got: $DET"
[ "$(jq -r '.source' <<<"$DET" 2>/dev/null)" = review-rescue-backfill ] \
  && ok || bad "(a) the row must say where it came from, got: $DET"
[ -f "$D/.verdict-backfilled" ] \
  && ok || bad "(a) the record must be marked once the row landed"
[ -f "$H/logs/ALERTS.log" ] \
  && bad "(a) a backfill that worked must not page: $(cat "$H/logs/ALERTS.log")" || ok
[ "$(wc -c < "$H/gh-calls.log")" = 0 ] \
  && ok || bad "(a) the backfill must make no gh call at all, got: $(cat "$H/gh-calls.log")"
run_lane
[ "$(puts)" = 1 ] \
  && ok || bad "(a) a second run must write no second row, got $(puts)"

# ══ (b) no review.md: nothing to backfill, and exactly one alert ════════════
mkhub b
REC="pool-project-4-TK-2-1"
D=$(record "$REC" "$FAILLINE")
feed_names "$REC"
run_lane
[ "$(puts)" = 0 ] && ok || bad "(b) a record with no review.md has no verdict to backfill, got: $(grep '^PUT' "$H/req.txt")"
[ "$(grep -c 'owes a verdict' "$H/logs/ALERTS.log" 2>/dev/null || echo 0)" = 1 ] \
  && ok || bad "(b) exactly one ALERTS line, got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'no VERDICT line in review.md' "$H/logs/ALERTS.log" \
  && ok || bad "(b) the alert must say WHY it cannot backfill, got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'head-bound re-review' "$H/logs/ALERTS.log" \
  && ok || bad "(b) the alert must name the remaining path, got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
run_lane
[ "$(grep -c 'owes a verdict' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "(b) a second run must add no second alert, got: $(cat "$H/logs/ALERTS.log")"

# ══ (c) VERDICT: BLOCK is not a strandee with a verdict ════════════════════
# The LAST verdict line decides: a review that quotes APPROVE in its findings and
# ends BLOCK is a BLOCK.
mkhub c
REC="pool-project-4-TK-3-1"
D=$(record "$REC" "$FAILLINE")
printf 'one lens said VERDICT: APPROVE\nTIER: 2\nVERDICT: BLOCK\n' > "$D/review.md"
feed_names "$REC"
run_lane
[ "$(puts)" = 0 ] && ok || bad "(c) a BLOCKed build owes no verdict row, got: $(grep '^PUT' "$H/req.txt")"
[ -f "$H/logs/ALERTS.log" ] && bad "(c) and it must not page: $(cat "$H/logs/ALERTS.log")" || ok
[ -f "$D/.verdict-backfilled" ] \
  && ok || bad "(c) a BLOCKed strandee is settled business and must be marked, or it is re-walked forever"

# ══ (d) no sha files: the provisional row's own sha is kept ════════════════
mkhub d
REC="pool-project-4-TK-4-1"
D=$(record "$REC" "$FAILLINE")
printf 'findings\nVERDICT: APPROVE\n' > "$D/review.md"
feed_names "$REC"
printf '%s' '{"artifacts":[{"artifact_kind":"verdict","artifact_ref":"APPROVE","detail":"{\"settled\":false,\"reviewed_sha\":\"def456\"}"}]}' > "$H/jobartifacts"
run_lane
BODY=$(grep '^PUT ' "$H/req.txt" | head -1 | cut -d' ' -f3-)
DET=$(jq -r '.detail' <<<"$BODY" 2>/dev/null)
[ "$(jq -r '.reviewed_sha' <<<"$DET" 2>/dev/null)" = def456 ] \
  && ok || bad "(d) with no sha file the provisional row's own reviewed_sha must be kept, got: $DET"
[ "$(jq -r '.settled' <<<"$DET" 2>/dev/null)" = true ] \
  && ok || bad "(d) the backfill SETTLES the provisional row, got: $DET"

# ══ (e) an already settled row is left alone ══════════════════════════════
mkhub e
REC="pool-project-4-TK-5-1"
D=$(record "$REC" "$FAILLINE")
printf 'findings\nVERDICT: APPROVE\n' > "$D/review.md"
feed_names "$REC"
printf '%s' '{"artifacts":[{"artifact_kind":"verdict","artifact_ref":"APPROVE","detail":"{\"settled\":true}"}]}' > "$H/jobartifacts"
run_lane
[ "$(puts)" = 0 ] && ok || bad "(e) a settled row must never be overwritten, got: $(grep '^PUT' "$H/req.txt")"
[ -f "$D/.verdict-backfilled" ] \
  && ok || bad "(e) a record whose ledger row is settled is finished business and must be marked"

# ══ (f) a worker outage writes nothing and marks nothing ══════════════════
mkhub f
REC="pool-project-4-TK-6-1"
D=$(record "$REC" "$FAILLINE")
printf 'findings\nVERDICT: APPROVE\n' > "$D/review.md"
echo abc123 > "$D/reviewed-sha"
feed_names "$REC"
touch "$H/worker-down"
run_lane
[ "$(puts)" = 0 ] && ok || bad "(f) an outage must write no row, got: $(grep '^PUT' "$H/req.txt")"
[ -f "$D/.verdict-backfilled" ] \
  && bad "(f) an outage must mark NOTHING — the record has to come back next tick (D11)" || ok
# The jobs-client writes its OWN once-a-day "worker unreachable" line; what must
# not appear is a verdict page from THIS lane.
grep -q '\[review-rescue\]' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "(f) an outage is not 'no verdict' and must not page: $(grep '\[review-rescue\]' "$H/logs/ALERTS.log")" || ok
rm -f "$H/worker-down"
run_lane
[ "$(puts)" = 1 ] && ok || bad "(f) the next tick with the worker back must backfill it, got $(puts)"

# ══ (g) a fallback-runner review is recorded as provenance fallback ═══════
mkhub g
REC="pool-project-4-TK-7-1"
D=$(record "$REC" "$FAILLINE")
printf 'findings\nVERDICT: APPROVE\n' > "$D/review.md"
echo abc123 > "$D/review-head"
printf 'review served by codex-cli — demoted to tier 2 (judge provenance)\n' > "$D/pipeline.log"
feed_names "$REC"
run_lane
DET=$(jq -r '.detail' <<<"$(grep '^PUT ' "$H/req.txt" | head -1 | cut -d' ' -f3-)" 2>/dev/null)
[ "$(jq -r '.provenance' <<<"$DET" 2>/dev/null)" = fallback ] \
  && ok || bad "(g) a review a cheap lane served must never be recorded as a Claude one, got: $DET"
[ "$(jq -r '.reviewed_sha' <<<"$DET" 2>/dev/null)" = abc123 ] \
  && ok || bad "(g) review-head is the fallback for the reviewed sha, got: $DET"

# ══ (h) the cap is honoured, and what it skips comes back ════════════════
mkhub h
R1="pool-project-4-TK-8-1"; R2="pool-project-4-TK-9-1"
D1=$(record "$R1" "$FAILLINE"); D2=$(record "$R2" "$FAILLINE")
printf 'findings\nVERDICT: APPROVE\n' > "$D1/review.md"
printf 'findings\nVERDICT: APPROVE\n' > "$D2/review.md"
feed_names2 "$R1" build-project-4-8 "$R2" build-project-4-9
VBMAX=1 run_lane
[ "$(puts)" = 1 ] && ok || bad "(h) VERDICT_BACKFILL_MAX=1 must write exactly one row, got $(puts)"
N=0; [ -f "$D1/.verdict-backfilled" ] && N=$((N+1)); [ -f "$D2/.verdict-backfilled" ] && N=$((N+1))
[ "$N" = 1 ] && ok || bad "(h) exactly one record marked under the cap, got $N"
VBMAX=1 run_lane
[ "$(puts)" = 2 ] && ok || bad "(h) the capped-out record must be walked on the next tick, got $(puts) rows total"
N=0; [ -f "$D1/.verdict-backfilled" ] && N=$((N+1)); [ -f "$D2/.verdict-backfilled" ] && N=$((N+1))
[ "$N" = 2 ] && ok || bad "(h) both records end up backfilled, got $N"

# ══ (i) the REVIEW_BLOCKED candidate walk is untouched ═══════════════════
mkhub i
REC="pool-project-4-TK-10-1"; RB="pool-project-4-TK-11-1"
D=$(record "$REC" "$FAILLINE")
DB=$(record "$RB" "$BLOCKLINE")
printf 'findings\nVERDICT: APPROVE\n' > "$D/review.md"
echo abc123 > "$D/reviewed-sha"
feed_names "$REC"
run_lane
[ "$(puts)" = 1 ] && ok || bad "(i) only the PR_CREATE_FAILED record is backfilled, got $(puts) rows"
[ -f "$DB/.verdict-backfilled" ] \
  && bad "(i) a REVIEW_BLOCKED record belongs to the rescue walk and must NOT be marked by the backfill" || ok
grep -q "$RB" "$H/logs/review-rescue.log" \
  && ok || bad "(i) the REVIEW_BLOCKED record must still reach the candidate walk, got: $(cat "$H/logs/review-rescue.log" 2>/dev/null)"

# ══ (j) no jobs-client on the box: the lane is byte-identical to before ══
mkhub j no-client
REC="pool-project-4-TK-12-1"
D=$(record "$REC" "$FAILLINE")
printf 'findings\nVERDICT: APPROVE\n' > "$D/review.md"
run_lane
RC=$?
[ "$RC" = 0 ] && ok || bad "(j) the lane must exit 0 with no ledger client, got $RC"
[ "$(wc -l < "$H/req.txt")" = 0 ] \
  && ok || bad "(j) no client means no worker request, got: $(cat "$H/req.txt")"
[ -f "$D/.verdict-backfilled" ] \
  && bad "(j) nothing may be marked when there is no ledger to write to" || ok

# ══ (k) the RECONCILED shape is still a strandee ═════════════════════════
# bin/pr-url-reconcile.sh got there first — line 1 is the relink, the create
# failure survives as RECONCILED_FROM, and a provisional row is already on the
# job. This is what the ticket's 15 field records look like RIGHT NOW.
mkhub k
REC="pool-project-4-TK-13-1"
D=$(record "$REC" "PR_CREATED $U1591 | RECONCILED 2026-09-18T08:03:00Z by pr-url-reconcile: the create had failed on the builder")
printf 'RECONCILED_FROM: %s\n' "$FAILLINE" >> "$D/RESULT"
printf 'PR: %s\n' "$U1591" >> "$D/RESULT"
printf 'findings\nTIER: 1\nVERDICT: APPROVE\n' > "$D/review.md"
echo abc123 > "$D/reviewed-sha"
feed_names "$REC"
printf '%s' '{"artifacts":[{"artifact_kind":"verdict","artifact_ref":"APPROVE","detail":"{\"settled\":false,\"reviewed_sha\":\"abc123\"}"}]}' > "$H/jobartifacts"
run_lane
[ "$(puts)" = 1 ] \
  && ok || bad "(k) a relinked strandee must still be backfilled — the reconciler wins the race to every one of them, so keying on PR_CREATE_FAILED alone delivers Ask 3 to nobody. Got $(puts) PUTs"
DET=$(jq -r '.detail' <<<"$(grep '^PUT ' "$H/req.txt" | head -1 | cut -d' ' -f3-)" 2>/dev/null)
[ "$(jq -r '.settled' <<<"$DET" 2>/dev/null)" = true ] \
  && ok || bad "(k) the row must be settled — a provisional row nothing ever settles is a PR the ledger lanes are blind to for good. Got: $DET"
[ "$(jq -r '.tier' <<<"$DET" 2>/dev/null)" = 2 ] \
  && ok || bad "(k) tier 2 always, got: $DET"
[ "$(jq -r '.reviewed_sha' <<<"$DET" 2>/dev/null)" = abc123 ] \
  && ok || bad "(k) bound to the sha the review ran on, got: $DET"
[ -f "$D/.verdict-backfilled" ] && ok || bad "(k) the record must be marked once the row landed"
[ -f "$H/logs/ALERTS.log" ] && bad "(k) nothing to page about: $(cat "$H/logs/ALERTS.log")" || ok
run_lane
[ "$(puts)" = 1 ] && ok || bad "(k) a second run must write no second row, got $(puts)"

# ══ (l) the negatives that keep (k) honest ═══════════════════════════════
mkhub l
# l1: a build that opened its OWN PR is not a strandee. No RECONCILED_FROM line,
# so nothing about it says the create ever failed.
OWN="pool-project-4-TK-14-1"
DOWN=$(record "$OWN" "PR_CREATED $U1591")
printf 'findings\nVERDICT: APPROVE\n' > "$DOWN/review.md"
# l2: RECONCILED line 1 but no preserved failure — not this lane's business.
NOF="pool-project-4-TK-15-1"
DNOF=$(record "$NOF" "PR_CREATED $U1591 | RECONCILED 2026-09-18T08:03:00Z by pr-url-reconcile: the create had failed on the builder")
printf 'findings\nVERDICT: APPROVE\n' > "$DNOF/review.md"
# l3: the only APPROVE in the file is quoted inside a finding — no judgement.
QUO="pool-project-4-TK-16-1"
DQUO=$(record "$QUO" "$FAILLINE")
printf 'the reviewer wrote VERDICT: APPROVE in an earlier round\nTIER: 2\n' > "$DQUO/review.md"
feed_names2 "$OWN" build-project-4-14 "$QUO" build-project-4-16
run_lane
[ "$(puts)" = 0 ] \
  && ok || bad "(l) none of these three is a strandee with a recordable verdict, got: $(grep '^PUT' "$H/req.txt")"
[ -f "$DOWN/.verdict-backfilled" ] \
  && bad "(l1) a record that carries no RECONCILED_FROM never failed its create and must not be walked" || ok
[ -f "$DNOF/.verdict-backfilled" ] \
  && bad "(l2) a RECONCILED line 1 with no preserved PR_CREATE_FAILED must not be walked" || ok
[ "$(grep -c 'owes a verdict' "$H/logs/ALERTS.log" 2>/dev/null || echo 0)" = 1 ] \
  && ok || bad "(l3) a quoted APPROVE is not a verdict — the record owes one and nobody here can write it, which is exactly one page. Got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'no VERDICT line in review.md' "$H/logs/ALERTS.log" \
  && ok || bad "(l3) and the page must say why, got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

echo "review-rescue.bh-858-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
