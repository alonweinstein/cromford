#!/bin/bash
# tests/overlap-guard-test.sh — bin/overlap-guard.sh: the launch-time answer to
# "would this build land on files something else is already holding?"
#
# WHAT THIS PINS AND WHY. The guard is the ONE thing standing between a hot repo
# and the 144 DIRTY/conflict events a day that made it worth writing, and it is
# a gate that fails OPEN — which means every one of its bugs is silent. A guard
# that stopped consulting the ledger, stopped reading open PRs, or started
# deferring on package.json would all look identical in production: builds keep
# running, or quietly stop, and nothing says which.
#
# So every claim here is DRIVEN, never grepped: a fake jobs ledger, a fake gh
# with real `gh pr list --json` shapes, real files-to-touch lists on disk, and
# the assertions are on the guard's exit code and its stdout contract
# (LAUNCH rc 0 / DEFER rc 1), because that contract is what bin/fly-dispatch.sh
# and the triage SOP act on.
#
# Run from anywhere: tests/overlap-guard-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/proj
export HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/flags" "$T/h/state" "$T/h/plans" \
         "$T/h/builds" "$T/h/env" "$T/h/locks" "$T/fakebin"
cp "$DIR/bin/overlap-guard.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/planned-files.sh" "$T/h/bin/"
cp "$DIR/bin/lib/scheduler-conf.sh" "$DIR/bin/lib/gh-pr-list.sh" "$T/h/bin/lib/"
# TEST-CHANGE (BH-1585): the list is REST, which needs the contract lib beside it.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
printf 'proj %s https://proj.example /api/board 0 local -\n' "$SLUG" > "$T/h/fleet.conf"

# --- the fake jobs ledger ----------------------------------------------------
# $T/ledger.json is what /api/jobs answers; $T/ledger.rc is whether it answers
# at all, so the outage path is driven rather than assumed.
cat > "$T/h/bin/jobs-client.sh" <<EOF
_jobs_req() {
  printf '%s\n' "\$*" >> "$T/jobs-calls.txt"
  [ "\$(cat "$T/ledger.rc" 2>/dev/null || echo 0)" = 0 ] || return 1
  cat "$T/ledger.json" 2>/dev/null
}
EOF
echo 0 > "$T/ledger.rc"
echo '{"jobs":[]}' > "$T/ledger.json"

# --- the fake gh -------------------------------------------------------------
# Real `gh pr list --json number,url,headRefName,isDraft,files` shape: files is
# an array of objects with a `path`. $T/prs.json is the answer for the PAT
# author; every other author lists empty, which is the production shape too.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
[ -f "$T/gh-broken" ] && exit 1
case "\$*" in
  # TEST-CHANGE (BH-1585): \`files\` is a REST read now — the open page, then
  # pulls/N/files per PR. Same \$T/prs.json, answered in the REST shape.
  *"repos/$SLUG/pulls?"*)
    printf 'HTTP/2.0 200\r\n\r\n'
    jq -c --arg s "$SLUG" '[.[] | {number, html_url: .url, draft: (.isDraft // false), state: "open",
      user: {login: "operator", type: "User"}, labels: [], title: "t", body: "",
      created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z", merged_at: null, closed_at: null,
      head: {ref: .headRefName, sha: "x", repo: {full_name: \$s}}, base: {ref: "main", repo: {full_name: \$s}}}]' "$T/prs.json" ;;
  *"repos/$SLUG/pulls/"*"/files"*)
    [ -f "$T/files-broken" ] && { printf 'HTTP/2.0 502\r\n\r\n{"message":"Server Error"}\n'; exit 1; }
    n=\$(printf '%s\n' "\$*" | sed -nE 's#.*/pulls/([0-9]+)/files.*#\1#p')
    printf 'HTTP/2.0 200\r\n\r\n'
    jq -c --argjson n "\$n" '[.[] | select(.number == \$n) | .files[]? | {filename: .path}]' "$T/prs.json" ;;
  *"pr list -R $SLUG --state open --author operator"*) cat "$T/prs.json" ;;
  *"pr list"*) echo '[]' ;;
  *) echo '' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
echo '[]' > "$T/prs.json"

G="$T/h/bin/overlap-guard.sh"
plan() { mkdir -p "$T/h/plans/proj-$1"; shift; printf '%s\n' "$@"; }
setplan() { local k="$1"; shift; mkdir -p "$T/h/plans/proj-$k"; printf '%s\n' "$@" > "$T/h/plans/proj-$k/planned-files.txt"; }
reset() { rm -rf "$T/h/state/overlap-guard"; : > "$T/gh-calls.txt"; : > "$T/jobs-calls.txt"; : > "$T/h/logs/overlap-guard.log"; }
run() { OUT=$("$G" proj "$1" 2>/dev/null); RC=$?; }

setplan AB-1 src/lib/pay.ts src/ui/card.tsx

# ============================================================================
# 1. The kill flags stop it before it reads ANYTHING
# ============================================================================
reset
echo '{"jobs":[{"kind":"build","ticket_id":"AB-2"}]}' > "$T/ledger.json"
setplan AB-2 src/lib/pay.ts
touch "$T/h/flags/overlap-guard-off"
run AB-1
[ "$RC" = 0 ] && ok || bad "flags/overlap-guard-off must exit 0 (got rc $RC)"
[ ! -s "$T/jobs-calls.txt" ] && ok || bad "the kill flag must stop it BEFORE the ledger read"
rm -f "$T/h/flags/overlap-guard-off"
reset
OUT=$(OVERLAP_GUARD=0 "$G" proj AB-1 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "OVERLAP_GUARD=0 must exit 0 (got rc $RC)"
[ ! -s "$T/jobs-calls.txt" ] && ok || bad "OVERLAP_GUARD=0 must stop it before the ledger read"

# ============================================================================
# 2. The in-flight ledger: a running sibling on the same file DEFERS
# ============================================================================
reset
run AB-1
[ "$RC" = 1 ] && ok || bad "a running sibling sharing src/lib/pay.ts must DEFER (rc $RC, out: $OUT)"
grep -q '^DEFER AB-1 vs AB-2' <<<"$OUT" && ok || bad "DEFER must name the colliding key (got: $OUT)"
grep -q 'src/lib/pay.ts' <<<"$OUT" && ok || bad "DEFER must name the colliding file (got: $OUT)"
grep -q 'jaccard=' <<<"$OUT" && ok || bad "DEFER must report the jaccard it judged on (got: $OUT)"
grep -q 'DEFER vs AB-2' "$T/h/logs/overlap-guard.log" && ok || bad "one log line per decision, naming the files"

# a DISJOINT sibling launches
reset
setplan AB-2 src/other/thing.ts
run AB-1
[ "$RC" = 0 ] && ok || bad "a running sibling on other files must LAUNCH (rc $RC, out: $OUT)"
grep -q '^LAUNCH AB-1' <<<"$OUT" && ok || bad "LAUNCH must be printed on stdout (got: $OUT)"

# the candidate's OWN running row is never a collision with itself
reset
echo '{"jobs":[{"kind":"build","ticket_id":"AB-1"}]}' > "$T/ledger.json"
run AB-1
[ "$RC" = 0 ] && ok || bad "a ticket must never collide with its own running row (rc $RC)"

# a running key with NO file list is unjudged, said out loud, never a defer
reset
echo '{"jobs":[{"kind":"build","ticket_id":"AB-9"}]}' > "$T/ledger.json"
run AB-1
[ "$RC" = 0 ] && ok || bad "a running key with no plan must not DEFER (rc $RC)"
grep -q 'unjudged=AB-9' "$T/h/logs/overlap-guard.log" && ok \
  || bad "a key we could not judge must be named in the log, not silently treated as disjoint"

# ============================================================================
# 3. Fail-open: an unreadable ledger, an unreadable gh, an absent plan
# ============================================================================
reset
echo 1 > "$T/ledger.rc"
run AB-1
[ "$RC" = 0 ] && ok || bad "a ledger outage must LAUNCH, never hold (rc $RC)"
grep -q 'ledger=outage' "$T/h/logs/overlap-guard.log" && ok || bad "the outage must be named in the log"
echo 0 > "$T/ledger.rc"; echo '{"jobs":[]}' > "$T/ledger.json"

# TEST-CHANGE (BH-782): this case asserted the DEFECT. A `gh` that cannot answer
# the open-PR list used to LAUNCH, because an empty list read as "no overlap" —
# which is exactly how #768 launched builds on top of five live PRs. With no
# cached copy to fall back on, an unreadable list now DEFERs and the ticket is
# re-offered next tick. The fixture is unchanged; the assertion is inverted on
# purpose, and the two cases below pin the halves that did NOT change (a cache
# is still authoritative, and a missing gh BINARY still fails open).
reset
touch "$T/gh-broken"
run AB-1
[ "$RC" = 1 ] && ok || bad "an unreadable PR list with no cache must DEFER (rc $RC, out: $OUT)"
grep -q '^DEFER AB-1 gh unknown' <<<"$OUT" && ok || bad "and must say so on stdout (got: $OUT)"
grep -q 'gh unknown' "$T/h/logs/overlap-guard.log" && ok || bad "and must log the reason"

# ...but a CACHE, even one written by an earlier tick, is still authoritative:
# stale-but-real beats none, and the outage must never overwrite it.
reset
mkdir -p "$T/h/state/overlap-guard"
printf '[{"number":61,"url":"u","headRefName":"ticket/ab-61","isDraft":false,"files":[{"path":"src/far/away.ts"}]}]' \
  > "$T/h/state/overlap-guard/proj-prs.json"
CBEFORE=$(sha256sum < "$T/h/state/overlap-guard/proj-prs.json")
run AB-1
[ "$RC" = 0 ] && ok || bad "a disjoint cache must still LAUNCH under a gh outage (rc $RC, out: $OUT)"
! grep -q 'gh unknown' <<<"$OUT" && ok || bad "a present cache must not answer gh unknown (got: $OUT)"
[ "$CBEFORE" = "$(sha256sum < "$T/h/state/overlap-guard/proj-prs.json")" ] && ok \
  || bad "a failed read overwrote the PR cache"
rm -f "$T/gh-broken"

# The pre-existing fail-open for a missing gh BINARY is untouched: the new DEFER
# is only for "we asked and could not read the answer".
# A PATH with every /usr/bin and /bin command EXCEPT gh. `command -v gh` is what
# the guard checks, and this box has a real gh installed — so simply trimming
# PATH to /usr/bin:/bin would still find one and this case would silently test
# "a real gh that failed" instead of "no gh at all".
nogh_path() {
  local d="$T/nogh"
  if [ ! -d "$d" ]; then
    mkdir -p "$d"
    find /usr/bin /bin -maxdepth 1 \( -type f -o -type l \) ! -name gh -print0 2>/dev/null \
      | xargs -0 -r ln -sf -t "$d"
  fi
  printf '%s' "$d"
}
reset
OUT=$(PATH="$(nogh_path)" "$G" proj AB-1 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "no gh binary must still LAUNCH (rc $RC, out: $OUT)"
grep -q '^LAUNCH AB-1' <<<"$OUT" && ok || bad "no gh binary must print LAUNCH (got: $OUT)"

reset
run ZZ-99
[ "$RC" = 0 ] && ok || bad "a ticket with no files-to-touch list must LAUNCH (rc $RC)"
grep -q 'cannot judge' <<<"$OUT" && ok || bad "and must say it could not judge (got: $OUT)"

# ============================================================================
# 4. Open harness PRs — the half nothing had before
# ============================================================================
mkpr() { # mkpr <num> <branch> <draft> <file>...
  local n="$1" br="$2" d="$3"; shift 3
  jq -nc --arg n "$n" --arg br "$br" --argjson d "$d" --args '
    [{number: ($n|tonumber), url: ("https://github.com/o/r/pull/"+$n),
      headRefName: $br, isDraft: $d, files: [$ARGS.positional[] | {path: .}]}]' "$@"
}
reset
mkpr 41 ticket/ab-7-something false src/lib/pay.ts src/lib/project-2.ts > "$T/prs.json"
run AB-1
[ "$RC" = 1 ] && ok || bad "an OPEN harness PR that already changed src/lib/pay.ts must DEFER (rc $RC, out: $OUT)"
grep -q 'vs PR#41' <<<"$OUT" && ok || bad "DEFER must name the PR (got: $OUT)"

# our OWN ticket's PR is the same work, not a collision
reset
mkpr 42 ticket/ab-1-repair false src/lib/pay.ts > "$T/prs.json"
run AB-1
[ "$RC" = 0 ] && ok || bad "a PR on this ticket's own branch must not defer its own build (rc $RC, out: $OUT)"

# drafts are not in flight
reset
mkpr 43 ticket/ab-8 true src/lib/pay.ts > "$T/prs.json"
run AB-1
[ "$RC" = 0 ] && ok || bad "a DRAFT PR must not defer a build (rc $RC, out: $OUT)"

# ============================================================================
# 5. The classes the conductor already union-resolves are NOT a conflict
# ============================================================================
reset
setplan AB-1 package.json docs/NOTES.md src/lib/pay.ts
mkpr 44 ticket/ab-9 false package.json docs/NOTES.md README.md > "$T/prs.json"
echo '{"jobs":[]}' > "$T/ledger.json"
run AB-1
[ "$RC" = 0 ] && ok \
  || bad "sharing only package.json/*.md must LAUNCH — deferring on them serializes the repo behind its most boring file (rc $RC, out: $OUT)"
# and the real source file still counts
reset
mkpr 45 ticket/ab-9 false package.json src/lib/pay.ts > "$T/prs.json"
run AB-1
[ "$RC" = 1 ] && ok || bad "a real source file shared alongside package.json must still DEFER (rc $RC)"

# OVERLAP_IGNORE is configurable
reset
printf 'OVERLAP_IGNORE=package.json src/lib/pay.ts\n' > "$T/h/flags/scheduler.conf"
run AB-1
[ "$RC" = 0 ] && ok || bad "flags/scheduler.conf must be able to widen OVERLAP_IGNORE (rc $RC)"
rm -f "$T/h/flags/scheduler.conf"

# ============================================================================
# 6. OVERLAP_THRESHOLD: 0 (default) is any-overlap; a raised one lets it through
# ============================================================================
reset
setplan AB-1 src/a1.ts src/a2.ts src/a3.ts src/a4.ts src/shared.ts
mkpr 46 ticket/ab-9 false src/b1.ts src/b2.ts src/b3.ts src/b4.ts src/shared.ts > "$T/prs.json"
run AB-1
[ "$RC" = 1 ] && ok || bad "the DEFAULT threshold of 0 must defer on ANY shared file (rc $RC)"
J=$(sed -n 's/.*jaccard=\([0-9.]*\).*/\1/p' <<<"$OUT")
[ "$J" = "0.11" ] && ok || bad "1 hit over a union of 9 must report jaccard 0.11 (got '$J' — out: $OUT)"
reset
printf 'OVERLAP_THRESHOLD=0.5\n' > "$T/h/flags/scheduler.conf"
run AB-1
[ "$RC" = 0 ] && ok || bad "OVERLAP_THRESHOLD=0.5 must let a 0.11 overlap through (rc $RC, out: $OUT)"
grep -q 'allowed past PR#46' "$T/h/logs/overlap-guard.log" && ok \
  || bad "an allowed-past decision must still be logged with its jaccard"
printf 'OVERLAP_THRESHOLD=banana\n' > "$T/h/flags/scheduler.conf"
run AB-1
[ "$RC" = 1 ] && ok || bad "an unparseable threshold must fall back to the DEFAULT (0), never to 'never fires' (rc $RC)"
rm -f "$T/h/flags/scheduler.conf"

# ============================================================================
# 7. A live build dir's own list is the fallback when there is no pre-plan
# ============================================================================
reset
rm -rf "$T/h/plans/proj-AB-1"
mkdir -p "$T/h/builds/proj-AB-1-202609151200"
printf 'src/lib/pay.ts\n' > "$T/h/builds/proj-AB-1-202609151200/planned-files.txt"
mkpr 47 ticket/ab-9 false src/lib/pay.ts > "$T/prs.json"
run AB-1
[ "$RC" = 1 ] && ok || bad "a build dir's planned-files.txt must be used when no pre-plan exists (rc $RC, out: $OUT)"

# ============================================================================
# 8. The PR read is cached, so a per-ticket guard is not a gh call per ticket
# ============================================================================
reset
setplan AB-1 src/lib/pay.ts
run AB-1
# TEST-CHANGE (BH-1585): the list read is the REST open page now, so that is
# what is counted (it was `pr list`); the three claims are unchanged.
N1=$(grep -c 'pulls?state=open' "$T/gh-calls.txt")
[ "$N1" -ge 1 ] && ok || bad "the first run must actually list PRs"
: > "$T/gh-calls.txt"
run AB-1
[ "$(grep -c 'pulls?state=open' "$T/gh-calls.txt")" = 0 ] && ok \
  || bad "within OVERLAP_PR_CACHE_SECS the PR list must come from the cache"
[ "$RC" = 1 ] && ok || bad "the cached answer must still DEFER (rc $RC)"
: > "$T/gh-calls.txt"
OUT=$(OVERLAP_PR_CACHE_SECS=0 "$G" proj AB-1 2>/dev/null); RC=$?
[ "$(grep -c 'pulls?state=open' "$T/gh-calls.txt")" -ge 1 ] && ok || bad "OVERLAP_PR_CACHE_SECS=0 must re-read"
# 8b. BH-1585 review round 2 (B2): a PR's FILES read that fails must never read
#     as "touches nothing". The colliding PR stays a collision — from the last
#     good cache, or as an unreadable list — and the last good cache is not
#     overwritten with a list that has a hole where that PR's files were.
touch "$T/files-broken"
OUT=$(OVERLAP_PR_CACHE_SECS=0 "$G" proj AB-1 2>/dev/null); RC=$?
rm -f "$T/files-broken"
grep -qE 'pulls/[0-9]+/files' "$T/gh-calls.txt" && ok || bad "8b: the files read must actually have been asked (this case would otherwise prove nothing)"
[ "$RC" = 1 ] && ! grep -q '^LAUNCH' <<<"$OUT" \
  && ok || bad "8b: a failed files read must not let a colliding build LAUNCH (rc $RC, out: $OUT)"
OUT=$("$G" proj AB-1 2>/dev/null); RC=$?
[ "$RC" = 1 ] && ok || bad "8b: the next run (cache) must still DEFER — the cache was overwritten by a list with a hole (rc $RC, out: $OUT)"

# ============================================================================
# 9. THE HOOK. bin/fly-dispatch.sh must ask the guard BEFORE it claims a queued
#    job, and a DEFER must leave the job file exactly where it was — the queue
#    is re-offered next tick, never drained into a build that will conflict.
#
#    Driven, not grepped: the real dispatcher runs against a fixture harness
#    with its fly plumbing shimmed, and the assertion is on what happened to the
#    QUEUE FILE and on the one line the claim path logs.
# ============================================================================
mkdir -p "$T/h/state/fly" "$T/h/state/build-queue/proj"
cp "$DIR/bin/fly-dispatch.sh" "$T/h/bin/"
: > "$T/h/env/fly.env"
touch "$T/h/flags/builder-fly-proj"
printf '{"app":"builder-proj"}
' > "$T/h/state/fly/proj.json"
for stub in fly-lock-guard.sh fly-sync-harness.sh fly-envbundle.sh beat.sh; do
  printf '#!/bin/bash
exit 0
' > "$T/h/bin/$stub"; chmod +x "$T/h/bin/$stub"
done
printf '#!/bin/bash
echo started
' > "$T/h/bin/fly-api.sh"; chmod +x "$T/h/bin/fly-api.sh"
export FLY_API_TOKEN_PROJ=tok

dispatch() {
  rm -f "$T/h/state/fly/proj-active.json" "$T/h/logs/fly-dispatch.log"
  printf '{"ticket_id":"101","key":"AB-1","attempt":0}
' > "$T/h/state/build-queue/proj/AB-1.json"
  ( cd "$T" && HARNESS="$T/h" bash "$T/h/bin/fly-dispatch.sh" >/dev/null 2>&1 )
}

reset
setplan AB-1 src/lib/pay.ts
mkpr 48 ticket/ab-9 false src/lib/pay.ts > "$T/prs.json"
dispatch
[ -f "$T/h/state/build-queue/proj/AB-1.json" ] && ok   || bad "a DEFER must leave the queued job file in place for the next tick"
[ ! -f "$T/h/state/fly/proj-active.json" ] && ok || bad "a DEFER must not claim the job"
grep -q 'overlap guard' "$T/h/logs/fly-dispatch.log" && ok   || bad "the dispatcher must say why it stood down (log: $(tail -2 "$T/h/logs/fly-dispatch.log" 2>/dev/null))"
grep -q 'claiming job AB-1' "$T/h/logs/fly-dispatch.log" && bad "a DEFER must happen BEFORE the claim" || ok

reset
echo '[]' > "$T/prs.json"
dispatch
grep -q 'claiming job AB-1' "$T/h/logs/fly-dispatch.log" && ok   || bad "with no collision the dispatcher must claim as before (log: $(tail -3 "$T/h/logs/fly-dispatch.log" 2>/dev/null))"

reset
mkpr 49 ticket/ab-9 false src/lib/pay.ts > "$T/prs.json"
touch "$T/h/flags/overlap-guard-off"
dispatch
grep -q 'claiming job AB-1' "$T/h/logs/fly-dispatch.log" && ok   || bad "the kill flag must restore the pre-guard dispatcher exactly"
rm -f "$T/h/flags/overlap-guard-off"

# --- the cheap list's SOURCE: header is not a path (BH-499) ------------------
# bin/planned-files-cheap.sh writes which tier produced a list as its first
# line, into the same plans/<project>-<KEY>/planned-files.txt this guard reads.
# That header is an entry two cheap lists SHARE, so left in the comparison it
# makes every pair of unrelated children collide on `SOURCE: ticket-body` — and
# this guard fails open, so the only symptom would be builds quietly standing
# down for a reason nobody can find. Two children, genuinely disjoint files,
# both carrying the header: the answer must be LAUNCH.
# The two lists are compared through files_of() on BOTH sides, so the ledger
# half is where it bites: a sibling that is already building, its own cheap list
# on disk, and the only line the two share is the header.
reset
echo '[]' > "$T/prs.json"
echo '{"jobs":[{"ticket_id":"AB-9","kind":"build"}]}' > "$T/ledger.json"
mkdir -p "$T/h/plans/proj-AB-1" "$T/h/plans/proj-AB-9"
printf 'SOURCE: ticket-body\nsrc/lib/pay.ts\n'   > "$T/h/plans/proj-AB-1/planned-files.txt"
printf 'SOURCE: ticket-body\nsrc/lib/brain.ts\n' > "$T/h/plans/proj-AB-9/planned-files.txt"
OUT=$("$G" proj AB-1 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "two cheap lists sharing only their SOURCE: header must not collide (got rc=$RC: $OUT)"
grep -q 'SOURCE' <<<"$OUT" && bad "the SOURCE header was compared as a path (got: $OUT)" || ok
# ...and a real collision still defers, so the strip did not blind the guard
reset
printf 'SOURCE: ticket-body\nsrc/lib/pay.ts\n' > "$T/h/plans/proj-AB-9/planned-files.txt"
"$G" proj AB-1 >/dev/null 2>&1 && bad "a real overlap under a SOURCE: header must still DEFER" || ok
echo '{"jobs":[]}' > "$T/ledger.json"

echo "overlap-guard-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
