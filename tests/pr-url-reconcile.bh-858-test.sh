#!/bin/bash
# tests/pr-url-reconcile.bh-858-test.sh — THE LEDGER'S HALF OF THE RE-LINK.
#
# THE DEFECT (BH-858). bin/pr-url-reconcile.sh rewrites line 1 of a build record
# so bin/merge-sweep.sh can see the PR again. That fixes the FILE readers and
# nothing else: `/api/verdict?pr=` resolves through the `pr_url` artifact, and a
# build whose `gh pr create` died never wrote one — so the conductor, the merge
# queue and every other ledger-driven lane are still blind to that PR, and the
# verdict its reviewer wrote is bound to nothing anybody can look up.
#
# WHAT THIS SUITE PINS (the real lane, a scratch $HARNESS, a stub `gh` and a stub
# worker that records every request):
#   (a) relink + `pr_url` bound on the job + a hand-off to the conductor's
#       head-bound re-review path, recorded ONCE; a second run is a no-op;
#   (b) the same record when the job already owns a verdict: `pr_url` bound,
#       nothing handed off, nothing paged;
#   (c) no verdict AND the conductor unarmed: exactly one ALERTS line, once —
#       a PR that owes a verdict no path can produce is not allowed to be silent;
#   (d) a worker outage marks NOTHING (D11: an outage is not "no verdict"), and a
#       later tick with the worker back finishes the hand-off exactly once;
#   (e) a box with no jobs-client: byte-identical to the pre-BH-858 lane;
#   (f) no verdict, conductor unarmed, but the record's own review.md ends
#       APPROVE and a job owns it: NO page. bin/review-rescue.sh's backfill
#       settles exactly that shape, so "nothing can produce one" would be a
#       false sentence about a record carrying a real judgement;
#   (g) the retry arm meeting a PR that has since MERGED: no page either. The
#       first-tick path reads state=open before it links, so only this arm can
#       be looking at a PR that has moved on, and a PR in main owes nothing.
#
# Run from anywhere: bash tests/pr-url-reconcile.bh-858-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || { T=$(mktemp -d) && trap 'rm -rf "$T"' EXIT; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
# ONE clock read for the whole file (bin/test-determinism-lint.sh); it only keeps
# the fixture record names unique.
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive the reconciler"; exit 1; }
unset JOB_ID JOB_PHASE_ID

LANE="$DIR/bin/pr-url-reconcile.sh"
[ -x "$LANE" ] || { echo "FAIL: bin/pr-url-reconcile.sh does not exist or is not executable"; exit 1; }
U834="https://github.com/example-org/cromford/pull/834"

# ── the stub gh (same shape as the #857 suite: status line before body) ──────
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUBHUB/gh-calls.log"
[ "${1:-}" = api ] || exit 1
case "$*" in
  # the single-PR read pr_finished makes: repos/<slug>/pulls/<number>
  */pulls/[0-9]*) [ -f "$STUBHUB/gh-response.one" ] && { cat "$STUBHUB/gh-response.one"; exit 0; } ;;
  *state=all*) [ -f "$STUBHUB/gh-response.all" ] && { cat "$STUBHUB/gh-response.all"; exit 0; } ;;
esac
[ -f "$STUBHUB/gh-response" ] || { echo "stub gh: no fixture" >&2; exit 1; }
cat "$STUBHUB/gh-response"
STUB
chmod +x "$T/bin/gh"

# ── the stub worker ─────────────────────────────────────────────────────────
# Every request is appended to $REQ_SINK, so "exactly one PUT" and "a second run
# costs nothing" are assertions about TRAFFIC. $STUBHUB/worker-down makes the
# result feed fail without touching anything else.
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$STUBHUB/req.txt"
case "$URL" in
  */api/artifacts*)
    [ -f "$STUBHUB/worker-down" ] && { printf 'boom\n500\n'; exit 0; }
    printf '%s\n200\n' "$(cat "$STUBHUB/feed")" ; exit 0 ;;
esac
case "$METHOD $URL" in
  "PUT "*/artifacts) printf '{"ok":true}\n200\n'; exit 0 ;;
  "GET "*/artifacts) printf '%s\n200\n' "$(cat "$STUBHUB/jobartifacts")"; exit 0 ;;
esac
printf '{}\n404\n'
STUB
chmod +x "$T/bin/curl"
PATH="$T/bin:$PATH"

# ── a scratch hub ───────────────────────────────────────────────────────────
mkhub() { # mkhub <name> [no-client] -> H is the scratch $HARNESS
  # One directory per case, never reused, so this lane needs no recursive rm —
  # tests/lib/scratch.sh owns the removal of $T and everything under it.
  H="$T/$1"
  mkdir -p "$H/bin/lib" "$H/builds" "$H/logs" "$H/locks" "$H/flags"
  cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
  cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-pr-create.sh" "$DIR/bin/lib/result-pr-url.sh" "$H/bin/lib/" 2>/dev/null
  [ "${2:-}" = no-client ] || { cp "$DIR/bin/jobs-client.sh" "$H/bin/jobs-client.sh"
    mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"; }
  printf 'cromford example-org/cromford - - 3 box-small 10.0.0.7\n' > "$H/fleet.conf"
  : > "$H/gh-calls.log"; : > "$H/req.txt"
  # The ledger's default answers: the feed names this build dir, the job owns no
  # verdict artifact. Each case overrides what it is about.
  feed_names "$REC"
  printf '%s' '{"artifacts":[{"artifact_kind":"result","artifact_ref":"ok"}]}' > "$H/jobartifacts"
  touch "$H/flags/merge-conductor-actions"
}
feed_names() { # feed_names <build dir basename>
  printf '{"artifacts":[{"job_id":"build-bh-858-1","artifact_ref":"ok","box":"pool-1","ticket_id":"BH-858","updated_at":"u","detail":"{\\"build_dir\\":\\"%s\\"}"}]}' \
    "${1#pool-}" > "$H/feed"
}
record() { # record <dir suffix> <RESULT line 1> [extra lines...]
  local d="$H/builds/$1"; mkdir -p "$d"
  shift
  printf '%s\n' "$@" > "$d/RESULT"
  printf 'VERDICT: APPROVE\nTIER: 2\n' > "$d/review.md"
  echo "$d"
}
resp() { printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$1" "$2" > "$H/gh-response"; }
run_lane() {
  ( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUBHUB="$H" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_BOX=test-box
    bash "$LANE" ) >"$H/stdout.txt" 2>&1
}
nreq() { grep -c "$1" "$H/req.txt" 2>/dev/null || true; }
FAILLINE="PR_CREATE_FAILED: GraphQL: API rate limit already exceeded for installation ID 161623167. — refused a url-less create claim carrying ''"

# ══ (a) relink, bind pr_url, hand off once ══════════════════════════════════
REC="pool-cromford-BH-858-2026091816$NOW"
mkhub a
D=$(record "$REC" "$FAILLINE" "TIER: 2")
resp '200 OK' "[{\"html_url\":\"$U834\"}]"
run_lane
RC=$?
[ "$RC" = 0 ] && ok || bad "(a) the lane must exit 0, got $RC: $(cat "$H/stdout.txt")"
head -1 "$D/RESULT" | grep -qE "^PR_CREATED $U834 \| RECONCILED " \
  && ok || bad "(a) line 1 must be relinked, got: $(head -1 "$D/RESULT")"
[ "$(grep -c '^PUT .*/api/jobs/build-bh-858-1/artifacts' "$H/req.txt")" = 1 ] \
  && ok || bad "(a) exactly one artifact PUT on the job that wrote this record, got: $(grep '^PUT' "$H/req.txt")"
grep '^PUT .*/api/jobs/build-bh-858-1/artifacts' "$H/req.txt" | grep -q '"artifact_kind":"pr_url"' \
  && ok || bad "(a) the PUT must bind pr_url — it is what /api/verdict?pr= resolves through. Got: $(grep '^PUT' "$H/req.txt")"
grep '^PUT .*/artifacts' "$H/req.txt" | grep -q "$U834" \
  && ok || bad "(a) the pr_url row must carry the PR url, got: $(grep '^PUT' "$H/req.txt")"
grep -q 'head-bound re-review' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(a) the log must record the hand-off, got: $(cat "$H/logs/pr-url-reconcile.log" 2>/dev/null)"
[ -f "$D/.verdict-handoff-done" ] \
  && ok || bad "(a) the record must carry the hand-off marker once the ledger write landed"
[ -f "$H/logs/ALERTS.log" ] \
  && bad "(a) a hand-off the conductor can act on must not page: $(cat "$H/logs/ALERTS.log")" || ok
# THIS LANE SPAWNS NOTHING. The conductor buys the read under its own budget,
# daily cap, CI-green debounce and per-(PR, head) dedupe.
grep -q 'agent-call\|rereview_spawn' "$H/logs/pr-url-reconcile.log" \
  && bad "(a) the reconciler must never buy a review itself" || ok

# a second run changes nothing, and costs the worker nothing
SHA1=$(sha256sum "$D/RESULT" | awk '{print $1}')
REQ1=$(wc -l < "$H/req.txt")
run_lane
[ "$(sha256sum "$D/RESULT" | awk '{print $1}')" = "$SHA1" ] \
  && ok || bad "(a) a second run must leave the RESULT byte-identical"
[ "$(wc -l < "$H/req.txt")" = "$REQ1" ] \
  && ok || bad "(a) a second run must cost ZERO worker requests, got $(( $(wc -l < "$H/req.txt") - REQ1 )) new"
[ "$(grep -c 'head-bound re-review' "$H/logs/pr-url-reconcile.log")" = 1 ] \
  && ok || bad "(a) the hand-off is recorded exactly once, got $(grep -c 'head-bound re-review' "$H/logs/pr-url-reconcile.log")"

# ══ (b) the job already carries a verdict: nothing more is owed ═════════════
REC="pool-cromford-BH-859-2026091816$NOW"
mkhub b
printf '%s' '{"artifacts":[{"artifact_kind":"verdict","artifact_ref":"APPROVE","detail":"{\"settled\":false,\"reviewed_sha\":\"abc123\"}"}]}' > "$H/jobartifacts"
D=$(record "$REC" "$FAILLINE")
resp '200 OK' "[{\"html_url\":\"$U834\"}]"
run_lane
grep '^PUT .*/artifacts' "$H/req.txt" | grep -q '"artifact_kind":"pr_url"' \
  && ok || bad "(b) pr_url must be bound even when a verdict already exists — the PR still has to be resolvable"
grep -q 'already carries a verdict' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(b) the log must say the job already carries a verdict, got: $(cat "$H/logs/pr-url-reconcile.log" 2>/dev/null)"
grep -q 'head-bound re-review' "$H/logs/pr-url-reconcile.log" \
  && bad "(b) a job that owns a verdict must NOT be handed to re-review — that is a Fable read bought for a judgement the ledger already holds" || ok
[ -f "$H/logs/ALERTS.log" ] && bad "(b) nothing to page about: $(cat "$H/logs/ALERTS.log")" || ok

# ══ (c) no verdict and the conductor is NOT armed: one alert, once ══════════
# NOTHING can produce a verdict for this one: the ledger has no row, the
# conductor is unarmed, and the record's own review.md never got its verdict line
# across, so bin/review-rescue.sh's backfill has nothing to read either. That is
# when the page is TRUE — see (f) for the record where it would be a lie.
REC="pool-cromford-BH-860-2026091816$NOW"
mkhub c
rm -f "$H/flags/merge-conductor-actions"
D=$(record "$REC" "$FAILLINE")
printf 'findings, and the verdict line never made it across the relay\n' > "$D/review.md"
resp '200 OK' "[{\"html_url\":\"$U834\"}]"
run_lane
[ "$(wc -l < "$H/logs/ALERTS.log" 2>/dev/null || echo 0)" = 1 ] \
  && ok || bad "(c) exactly one ALERTS line when a PR owes a verdict and no path can produce one, got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q "$U834" "$H/logs/ALERTS.log" \
  && ok || bad "(c) the alert must name the PR, got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'merge-conductor-actions' "$H/logs/ALERTS.log" \
  && ok || bad "(c) the alert must name the fix (arm the conductor), got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
run_lane
[ "$(wc -l < "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "(c) a second run must add no second alert, got: $(cat "$H/logs/ALERTS.log")"

# ══ (d) a worker outage marks nothing, and the next tick finishes the job ═══
REC="pool-cromford-BH-861-2026091816$NOW"
mkhub d
touch "$H/worker-down"
D=$(record "$REC" "$FAILLINE")
resp '200 OK' "[{\"html_url\":\"$U834\"}]"
run_lane
head -1 "$D/RESULT" | grep -qE "^PR_CREATED $U834 \| RECONCILED " \
  && ok || bad "(d) the RECORD half must still land during a worker outage, got: $(head -1 "$D/RESULT")"
[ -f "$D/.verdict-handoff-done" ] \
  && bad "(d) an outage must mark NOTHING — the record has to come back round next tick" || ok
# The jobs-client writes its OWN once-a-day "worker unreachable" line; what must
# not appear is a verdict page from THIS lane.
grep -q '\[pr-url-reconcile\]' "$H/logs/ALERTS.log" 2>/dev/null \
  && bad "(d) an outage is not 'no verdict' and must not page (D11): $(grep '\[pr-url-reconcile\]' "$H/logs/ALERTS.log")" || ok
grep -q 'ledger did not answer' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(d) the log must say the ledger did not answer, got: $(cat "$H/logs/pr-url-reconcile.log" 2>/dev/null)"
# The worker comes back. Line 1 now says RECONCILED, so only the new arm can
# reach this record at all — which is the whole reason it exists.
rm -f "$H/worker-down"
run_lane
[ -f "$D/.verdict-handoff-done" ] \
  && ok || bad "(d) the next tick with the worker back must finish the hand-off"
[ "$(grep -c '^PUT .*/artifacts' "$H/req.txt")" = 1 ] \
  && ok || bad "(d) exactly one pr_url PUT across both ticks, got: $(grep -c '^PUT .*/artifacts' "$H/req.txt")"
[ "$(grep -c 'head-bound re-review' "$H/logs/pr-url-reconcile.log")" = 1 ] \
  && ok || bad "(d) the hand-off is recorded once, got $(grep -c 'head-bound re-review' "$H/logs/pr-url-reconcile.log")"
run_lane
[ "$(grep -c '^PUT .*/artifacts' "$H/req.txt")" = 1 ] \
  && ok || bad "(d) a third run must cost nothing more"

# ══ (e) no jobs-client on the box: byte-identical to the pre-BH-858 lane ════
REC="pool-cromford-BH-862-2026091816$NOW"
mkhub e no-client
D=$(record "$REC" "$FAILLINE" "TIER: 2")
resp '200 OK' "[{\"html_url\":\"$U834\"}]"
run_lane
RC=$?
[ "$RC" = 0 ] && ok || bad "(e) the lane must exit 0 with no ledger client, got $RC"
head -1 "$D/RESULT" | grep -qE "^PR_CREATED $U834 \| RECONCILED " \
  && ok || bad "(e) the relink must be unchanged, got: $(head -1 "$D/RESULT")"
[ "$(grep -c "^PR: $U834$" "$D/RESULT")" = 1 ] \
  && ok || bad "(e) exactly one PR: line, got: $(cat "$D/RESULT")"
[ "$(wc -l < "$H/req.txt")" = 0 ] \
  && ok || bad "(e) a box with no client must make no worker request, got: $(cat "$H/req.txt")"
[ -f "$D/.verdict-handoff-done" ] \
  && bad "(e) nothing may be marked when there is no ledger to write to" || ok
[ -f "$H/logs/ALERTS.log" ] \
  && bad "(e) and nothing may page: $(cat "$H/logs/ALERTS.log")" || ok
run_lane
[ "$(grep -c 'linked' "$H/logs/pr-url-reconcile.log")" = 1 ] \
  && ok || bad "(e) a second run must still be a no-op, got $(grep -c 'linked' "$H/logs/pr-url-reconcile.log") link lines"

# ══ (f) the backfill can settle this one, so the page would be a lie ════════
REC="pool-cromford-BH-863-2026091816$NOW"
mkhub f
rm -f "$H/flags/merge-conductor-actions"
D=$(record "$REC" "$FAILLINE")   # record() writes review.md ending VERDICT: APPROVE
resp '200 OK' "[{\"html_url\":\"$U834\"}]"
run_lane
grep '^PUT .*/artifacts' "$H/req.txt" | grep -q '"artifact_kind":"pr_url"' \
  && ok || bad "(f) pr_url must still be bound — the PR has to be resolvable either way"
[ -f "$H/logs/ALERTS.log" ] \
  && bad "(f) a record whose review.md ends APPROVE is one bin/review-rescue.sh's backfill settles; paging 'nothing can produce one' about it is a false page: $(cat "$H/logs/ALERTS.log")" || ok
grep -q "backfill settles it" "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(f) the log must say who settles it, got: $(cat "$H/logs/pr-url-reconcile.log" 2>/dev/null)"
grep -q 'head-bound re-review' "$H/logs/pr-url-reconcile.log" \
  && bad "(f) and nothing is handed to re-review — the judgement already exists on disk" || ok
[ -f "$D/.verdict-handoff-done" ] \
  && ok || bad "(f) the reconciler's half is finished, so the record is marked and not re-walked"

# ══ (g) the retry arm on a PR that has since merged: no page ════════════════
REC="pool-cromford-BH-864-2026091816$NOW"
mkhub g
rm -f "$H/flags/merge-conductor-actions"
D=$(record "$REC" \
  "PR_CREATED $U834 | RECONCILED 2026-09-18T08:03:00Z by pr-url-reconcile: the create had failed on the builder" \
  "RECONCILED_FROM: $FAILLINE" "PR: $U834")
touch "$D/.pr-url-reconciled"
# Nothing on disk can produce a verdict for it either, so without the state read
# this is exactly case (c) and it WOULD page.
printf 'findings, and the verdict line never made it across the relay\n' > "$D/review.md"
printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n{"html_url":"%s","state":"closed","merged_at":"2026-09-18T12:00:00Z"}\n' \
  "$U834" > "$H/gh-response.one"
run_lane
[ -f "$H/logs/ALERTS.log" ] \
  && bad "(g) a PR already in main owes no verdict, and telling an operator it does is noise: $(cat "$H/logs/ALERTS.log")" || ok
grep -q 'merged or closed' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(g) the log must say why nothing is owed, got: $(cat "$H/logs/pr-url-reconcile.log" 2>/dev/null)"
[ -f "$D/.verdict-handoff-done" ] \
  && ok || bad "(g) the record is finished business and must be marked"
[ "$(grep -c 'pulls/834' "$H/gh-calls.log")" = 1 ] \
  && ok || bad "(g) exactly one PR-state read, only on the path that would page. Got: $(cat "$H/gh-calls.log")"
run_lane
[ "$(grep -c 'pulls/834' "$H/gh-calls.log")" = 1 ] \
  && ok || bad "(g) a second run must cost no second read, got $(grep -c 'pulls/834' "$H/gh-calls.log")"

echo "pr-url-reconcile.bh-858-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
