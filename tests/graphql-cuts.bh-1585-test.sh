#!/bin/bash
# tests/graphql-cuts.bh-1585-test.sh — BH-1585: the GraphQL bucket (a separate
# 6,600/h budget nobody watched) ran at ~4,700/h. The three biggest spenders
# were per-record `gh pr view` reads in bin/rebase-train.sh and
# bin/pipeline-health.sh — over every approved build record, PRs merged weeks
# ago included — and bin/lib/gh-pr-list.sh falling back to one GraphQL
# `gh pr list --author` per author whenever merge-conductor asked for
# mergeStateStatus / mergeable / isCrossRepository.
#
# Every section drives the REAL script or library against a gh stub that
# records every invocation, and counts them by transport:
#   GraphQL  `gh pr …`, `gh issue …`, `gh api graphql`
#   REST     every other `gh api …`
#
#   1. rebase-train over 40 approved records, 35 of them merged: the first run
#      reads each record once over REST and writes the merged ones' terminal
#      state onto the record; the second run makes 0 GraphQL calls and at most
#      5 REST reads (the five open PRs). A DIRTY one is still found DIRTY.
#   2. pipeline-health "sweep should have landed" over the same 40 records:
#      0 GraphQL, and the warm run reads only the open PRs.
#   3. merge-conductor's open list (the field set is read out of
#      bin/merge-conductor.sh, not copied) makes 0 GraphQL calls; the REST
#      mergeable_state/mergeable map to the GraphQL words, drafts cost no
#      per-PR read, a failed per-PR read makes the whole list unavailable, a
#      field REST cannot carry (isInMergeQueue) is refused with ZERO calls
#      unless the GH_PR_LIST_GRAPHQL_FALLBACK knob is on, and `files` is a
#      REST read too (rebase-train-ahead / overlap-guard).
#
# Run from anywhere: tests/graphql-cuts.bh-1585-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/proj
mkdir -p "$T/fakebin" "$T/pr" "$T/files"
# A box without flock still has to run the lane here; the lock is not under test.
command -v flock >/dev/null 2>&1 || { printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }

# --- the counting gh ----------------------------------------------------------
# REST answers come from files: $T/pr/<n>.json (GET pulls/<n>), $T/files/<n>.json
# (GET pulls/<n>/files), $T/list.json (GET pulls?state=…). $T/limited/<n> makes
# that PR's single read a 403 rate limit. Anything GraphQL-shaped answers
# something plausible, so a lane still on GraphQL runs — and is counted.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
hdr() { printf 'HTTP/2.0 %s\r\ncontent-type: application/json\r\n\r\n' "$1"; }
case "$1" in
  pr|issue)
    case "$*" in
      *"pr list"*) echo '[]' ;;
      *"pr view"*) echo 'MERGED UNKNOWN operator b sha' ;;
    esac
    exit 0 ;;
esac
[ "$1 $2" = "api graphql" ] && { echo '{}'; exit 0; }
# The mergeQueue read (gh_rest POST graphql): $T/mq.json, or an empty queue.
case " $* " in *" graphql "*)
  if [ -f "$T/mq-500" ]; then printf 'HTTP/2.0 502\r\n\r\n{"message":"Server Error"}\n'; exit 1; fi
  printf 'HTTP/2.0 200\r\nx-ratelimit-resource: graphql\r\nx-ratelimit-remaining: 4999\r\n\r\n'
  cat "$T/mq.json" 2>/dev/null || echo '{"data":{"repository":{"mergeQueue":null}}}'; exit 0 ;;
esac
p=""
for a in "$@"; do case "$a" in repos/*) p="$a" ;; esac; done
case "$p" in
  */pulls/*/files*)
    n=${p#*/pulls/}; n=${n%%/*}
    if [ -f "$T/limited/$n" ]; then hdr 403; echo '{"message":"API rate limit exceeded"}'; exit 1; fi
    if [ -f "$T/broken/$n" ]; then hdr 502; echo '{"message":"Server Error"}'; exit 1; fi
    [ -f "$T/files/$n.json" ] || { hdr 404; echo '{}'; exit 1; }
    hdr 200; cat "$T/files/$n.json" ;;
  */pulls\?*)
    hdr 200; cat "$T/list.json" 2>/dev/null || echo '[]' ;;
  */pulls/*)
    n=${p##*/pulls/}; n=${n%%[!0-9]*}
    if [ -f "$T/limited/$n" ]; then hdr 403; echo '{"message":"API rate limit exceeded"}'; exit 1; fi
    if [ -f "$T/broken/$n" ]; then hdr 502; echo '{"message":"Server Error"}'; exit 1; fi
    [ -f "$T/pr/$n.json" ] || { hdr 404; echo '{"message":"Not Found"}'; exit 1; }
    hdr 200; cat "$T/pr/$n.json" ;;
  *) hdr 404; echo '{}'; exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

graphql() { grep -cE '^(pr|issue) |^api (.* )?graphql( |$)' "$1" 2>/dev/null || true; }
restn()   { grep -E '^api ' "$1" 2>/dev/null | grep -vcE '^api (.* )?graphql( |$)' || true; }
pullreads() { grep -cE "repos/$SLUG/pulls/[0-9]+( |$)" "$1" 2>/dev/null || true; }

# mkpr <n> <open|merged|closed> [mergeable_state] [draft] [cross] [login]
mkpr() {
  local n=$1 st=$2 ms=${3:-clean} d=${4:-false} x=${5:-false} who=${6:-operator}
  jq -nc --argjson n "$n" --arg st "$st" --arg ms "$ms" --argjson d "$d" --argjson x "$x" \
     --arg who "$who" --arg slug "$SLUG" '
    {number: $n, html_url: ("https://github.com/"+$slug+"/pull/"+($n|tostring)),
     title: ("t"+($n|tostring)), body: "b", draft: $d,
     state: (if $st == "open" then "open" else "closed" end),
     merged: ($st == "merged"),
     merged_at: (if $st == "merged" then "2026-09-01T00:00:00Z" else null end),
     closed_at: (if $st == "open" then null else "2026-09-01T00:00:00Z" end),
     mergeable: (if $ms == "dirty" then false elif $ms == "unknown" then null else true end),
     mergeable_state: $ms,
     user: {login: $who, type: "User"}, labels: [],
     created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-02T00:00:00Z",
     head: {ref: ("br"+($n|tostring)), sha: ("head"+($n|tostring)),
            repo: {full_name: (if $x then "fork/proj" else $slug end)}},
     base: {ref: "main", repo: {full_name: $slug}}}' > "$T/pr/$n.json"
}

# 40 approved records: #101..#135 merged, #136..#140 open (CLEAN; #140 DIRTY).
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/state" "$H/builds" "$T/repos/proj"
: > "$H/env/global.env"
for n in $(seq 101 140); do
  st=merged; [ "$n" -gt 135 ] && st=open
  ms=clean; [ "$n" = 140 ] && ms=dirty
  mkpr "$n" "$st" "$ms"
  R="$H/builds/pool-proj-P-$n-202609010000"; mkdir -p "$R"
  echo "PR_CREATED https://github.com/$SLUG/pull/$n" > "$R/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$R/review.md"
done
cp "$DIR/bin/rebase-train.sh" "$H/bin/"
for l in env-path.sh gh-pr-list.sh gh-rest.sh gh-rest-var.sh gh-rest-etag.sh pr-terminal.sh; do
  [ -f "$DIR/bin/lib/$l" ] && cp "$DIR/bin/lib/$l" "$H/bin/lib/"
done
markers() { find "$H/builds" -name pr-terminal 2>/dev/null | wc -l | tr -d ' '; }

train() { : > "$T/gh.txt"
  ( export HARNESS="$H" REPOS_ROOT="$T/repos" GH_SINK="$T/gh.txt" T="$T"; unset GH_TOKEN
    bash "$H/bin/rebase-train.sh" proj >/dev/null 2>"$T/train.err" ) ; }

# ============================================================================
# 1. rebase-train
# ============================================================================
train
G=$(graphql "$T/gh.txt"); R=$(pullreads "$T/gh.txt")
[ "$G" = 0 ] && ok || bad "1a cold rebase-train made $G GraphQL call(s): $(grep -E '^(pr|issue) ' "$T/gh.txt" | head -3)"
[ "$R" -ge 1 ] && [ "$R" -le 40 ] && ok || bad "1b cold rebase-train read $R PR(s) over REST (want 1..40, one per record at most)"
[ "$(markers)" = 35 ] && ok || bad "1c the 35 merged records carry a persisted terminal state (found $(markers)); err=$(head -c 300 "$T/train.err")"
[ ! -f "$H/builds/pool-proj-P-136-202609010000/pr-terminal" ] && ok || bad "1d an OPEN PR's record was marked terminal"
grep -q "pull/140 rebasing" "$H/logs/rebase-train.log" 2>/dev/null \
  && ok || bad "1e the DIRTY open PR #140 was not taken up (the REST mergeable_state must read as DIRTY): $(tail -3 "$H/logs/rebase-train.log" 2>/dev/null)"

train
G=$(graphql "$T/gh.txt"); N=$(restn "$T/gh.txt"); R=$(pullreads "$T/gh.txt")
[ "$G" = 0 ] && ok || bad "1f warm rebase-train made $G GraphQL call(s)"
[ "$N" -le 5 ] && ok || bad "1g warm rebase-train over 40 records (35 merged) made $N REST reads (want <= 5): $(cat "$T/gh.txt" | head -8)"
[ "$R" -ge 1 ] && ok || bad "1h warm rebase-train read no open PR at all — a lane that reads nothing passes 1f/1g trivially"
grep -qE "pulls/10[1-9]( |$)|pulls/1[1-2][0-9]( |$)|pulls/13[0-5]( |$)" "$T/gh.txt" \
  && bad "1i a merged record was read again: $(grep -E 'pulls/1[0-3][0-9]' "$T/gh.txt" | head -2)" || ok

# A rate-limited read is not a state: no marker, and the next run asks again.
mkdir -p "$T/limited"; touch "$T/limited/137"
train
[ ! -f "$H/builds/pool-proj-P-137-202609010000/pr-terminal" ] && ok || bad "1j a 403 rate-limit read was persisted as terminal"
rm -f "$T/limited/137"

# A CLOSED (not merged) PR is terminal for the recheck window, then read again —
# a reopen must not be missed for ever.
mkpr 138 closed
train
[ "$(awk '{print $1}' "$H/builds/pool-proj-P-138-202609010000/pr-terminal" 2>/dev/null)" = closed ] \
  && ok || bad "1k a closed PR was not recorded closed: $(cat "$H/builds/pool-proj-P-138-202609010000/pr-terminal" 2>/dev/null)"
( export PR_TERMINAL_CLOSED_RECHECK_S=86400; train )
grep -qE "pulls/138( |$)" "$T/gh.txt" \
  && bad "1k2 a closed marker inside the recheck window must skip the read: $(grep pulls/138 "$T/gh.txt")" || ok
echo "closed 1000 https://github.com/$SLUG/pull/138" > "$H/builds/pool-proj-P-138-202609010000/pr-terminal"
mkpr 138 open
( export PR_TERMINAL_CLOSED_RECHECK_S=60; train )
grep -qE "pulls/138( |$)" "$T/gh.txt" && [ ! -f "$H/builds/pool-proj-P-138-202609010000/pr-terminal" ] \
  && ok || bad "1l a closed marker older than the recheck window must be read again, and a reopened PR unmarked"

# ============================================================================
# 2. pipeline-health: sweep should have landed
# ============================================================================
awk '/^# >>> sweep should have landed/{f=1;next} /^# <<< sweep should have landed/{exit} f' \
  "$DIR/bin/pipeline-health.sh" > "$T/c1.sh"
[ -s "$T/c1.sh" ] && ok || bad "2a the sweep-should-have-landed block markers are gone"
rm -f "$H"/builds/*/pr-terminal
for n in $(seq 101 140); do st=merged; [ "$n" -gt 135 ] && st=open; mkpr "$n" "$st"; done
: > "$H/state/merge-sweep-done.txt"; : > "$H/logs/merge-sweep.log"
health() { : > "$T/gh.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" GH_SINK="$T/gh.txt" T="$T"; unset GH_TOKEN
    bash -c '
      set -uo pipefail
      H="$HARNESS"; NOW=$(date +%s)
      alert() { :; }
      job_verdict() { return 2; }
      [ -r "$H/bin/lib/pr-terminal.sh" ] && . "$H/bin/lib/pr-terminal.sh"
      . "$0"' "$T/c1.sh" 2>"$T/health.err" ) ; }
health
G=$(graphql "$T/gh.txt")
[ "$G" = 0 ] && ok || bad "2b cold sweep-landed check made $G GraphQL call(s)"
[ "$(markers)" = 35 ] && ok || bad "2c pipeline-health did not persist the 35 merged records (found $(markers)); err=$(head -c 300 "$T/health.err")"
[ -n "$(awk '{print $1}' "$H/state/sweep-clean-seen.txt" 2>/dev/null | grep pull/136)" ] \
  && ok || bad "2d the open CLEAN PR was not stamped first-seen — the check read nothing: $(cat "$H/state/sweep-clean-seen.txt" 2>/dev/null)"
health
G=$(graphql "$T/gh.txt"); R=$(pullreads "$T/gh.txt")
[ "$G" = 0 ] && [ "$R" -le 5 ] && ok || bad "2e warm sweep-landed check: $G GraphQL, $R PR reads (want 0 and <= 5)"

# ============================================================================
# 3. harness_pr_list — merge-conductor's open list
# ============================================================================
H3="$T/h3"; mkdir -p "$H3/logs" "$H3/state"
# The field sets are READ OUT OF THE LANES, so a lane that grows a field is
# tested with it rather than with a copy that went stale.
MC_FIELDS=$(grep -oE 'harness_pr_list "\$SLUG" open [A-Za-z,]+' "$DIR/bin/merge-conductor.sh" | awk '{print $4}' | grep -v isInMergeQueue | head -1)
MC_INQ=$(grep -oE 'harness_pr_list "\$SLUG" open [A-Za-z,]+' "$DIR/bin/merge-conductor.sh" | awk '{print $4}' | grep isInMergeQueue | head -1)
RTA_FIELDS=$(grep -oE 'harness_pr_list "\$SLUG" open "[A-Za-z,]+"' "$DIR/bin/rebase-train-ahead.sh" | awk '{print $4}' | tr -d '"' | head -1)
[ -n "$MC_FIELDS" ] && [ -n "$MC_INQ" ] && [ -n "$RTA_FIELDS" ] && ok || bad "3a could not read the lanes' field sets: mc=$MC_FIELDS inq=$MC_INQ rta=$RTA_FIELDS"

rm -f "$T"/pr/*.json
mkpr 1 open clean; mkpr 2 open dirty; mkpr 3 open clean true; mkpr 4 open clean false false someone-else
mkpr 5 open unknown false true; mkpr 6 open behind false false cromford[bot]
jq -s '.' "$T"/pr/1.json "$T"/pr/2.json "$T"/pr/3.json "$T"/pr/4.json "$T"/pr/5.json "$T"/pr/6.json > "$T/list.json"
printf '[{"filename":"src/a.ts","additions":1,"deletions":0},{"filename":"src/b.ts","additions":2,"deletions":1}]\n' > "$T/files/1.json"
for n in 2 3 5 6; do echo '[]' > "$T/files/$n.json"; done

hpl() { # hpl <fields> [env...] -> $T/out.json, rc in $T/rc
  local f=$1; shift
  : > "$T/gh.txt"
  ( export HARNESS="$H3" GH_SINK="$T/gh.txt" T="$T"; unset GH_TOKEN GH_PR_LIST_GRAPHQL_FALLBACK
    env "$@" bash -c '. "$1"; harness_pr_list "$2" open "$3" 100' _ "$DIR/bin/lib/gh-pr-list.sh" "$SLUG" "$f" \
      > "$T/out.json" 2>/dev/null; echo $? > "$T/rc" )
}
q() { jq -r "$1" "$T/out.json" 2>/dev/null; }

hpl "$MC_FIELDS"
G=$(graphql "$T/gh.txt")
[ "$(cat "$T/rc")" = 0 ] && ok || bad "3b merge-conductor's list failed (rc $(cat "$T/rc")): $(cat "$H3/logs/gh-pr-list.log" 2>/dev/null | tail -2)"
[ "$G" = 0 ] && ok || bad "3c merge-conductor's open list made $G GraphQL call(s): $(grep -E '^(pr|issue) ' "$T/gh.txt" | head -2)"
[ "$(q '[.[].number]|sort|join(",")')" = "1,2,3,5,6" ] && ok || bad "3d author filter: $(q '[.[].number]|sort|join(",")')"
[ "$(q '.[]|select(.number==1)|"\(.mergeStateStatus) \(.mergeable) \(.isCrossRepository)"')" = "CLEAN MERGEABLE false" ] \
  && ok || bad "3e #1: $(q '.[]|select(.number==1)')"
[ "$(q '.[]|select(.number==2)|"\(.mergeStateStatus) \(.mergeable)"')" = "DIRTY CONFLICTING" ] && ok || bad "3f #2: $(q '.[]|select(.number==2)')"
[ "$(q '.[]|select(.number==5)|"\(.mergeStateStatus) \(.mergeable) \(.isCrossRepository)"')" = "UNKNOWN UNKNOWN true" ] \
  && ok || bad "3g #5 (fork, not yet computed): $(q '.[]|select(.number==5)')"
[ "$(q '.[]|select(.number==6)|.mergeStateStatus')" = BEHIND ] && ok || bad "3h #6 (App-authored, REST spelling): $(q '.[]|select(.number==6)')"
[ "$(q '.[]|select(.number==3)|.mergeStateStatus')" = DRAFT ] && ! grep -qE "pulls/3( |$)" "$T/gh.txt" \
  && ok || bad "3i a draft costs no per-PR read and reads DRAFT: $(q '.[]|select(.number==3)') calls=$(grep -c . "$T/gh.txt")"
WANT=$(printf '%s' "$MC_FIELDS" | tr ',' '\n' | sort | paste -sd, -)
[ "$(q '.[0]|keys|join(",")')" = "$WANT" ] && ok || bad "3j keys are exactly the requested set: $(q '.[0]|keys|join(",")') want $WANT"

# A per-PR merge-state read that fails degrades THAT PR, never the repo (review
# round 1, Q1): the list still answers, the failed row says UNVERIFIABLE (never
# UNKNOWN, which is GitHub's "not computed yet"), every other row is intact.
# $T/broken/<n> is a plain 502 — one PR's fault, not the token's bucket.
mkdir -p "$T/broken" "$T/limited"; touch "$T/broken/2"
hpl "$MC_FIELDS"
[ "$(cat "$T/rc")" = 0 ] && ok || bad "3k one failed per-PR read must not make the repo's list unavailable (rc $(cat "$T/rc"))"
[ "$(q '.[]|select(.number==2)|"\(.mergeStateStatus) \(.mergeable)"')" = "UNVERIFIABLE UNKNOWN" ] \
  && ok || bad "3k2 the failed PR reads UNVERIFIABLE: $(q '.[]|select(.number==2)')"
[ "$(q '.[]|select(.number==1)|.mergeStateStatus')" = CLEAN ] && [ "$(q '[.[].number]|sort|join(",")')" = "1,2,3,5,6" ] \
  && ok || bad "3k3 the other rows are intact: $(q '[.[]|{number,mergeStateStatus}]')"
# A FAILED FILES READ FAILS THE LIST (review round 2, B2): a null files list
# reads as "touches nothing" to every consumer, which fails open.
hpl "$RTA_FIELDS"
[ "$(cat "$T/rc")" = 75 ] && [ ! -s "$T/out.json" ] \
  && ok || bad "3k4 a failed files read must make the list unavailable (rc $(cat "$T/rc")): $(head -c 200 "$T/out.json")"
rm -f "$T/broken/2"
# A RATE-LIMITED per-PR read is the bucket, not the PR (review round 2): the
# list fails 75 and arms the rung retry — a second attempt on the next rung.
touch "$T/limited/2"
hpl "$MC_FIELDS"
[ "$(cat "$T/rc")" = 75 ] && ok || bad "3k5 a rate-limited per-PR read must fail the list for the rung retry (rc $(cat "$T/rc"))"
grep -q "rate-limited) — the list is unavailable" "$H3/logs/gh-pr-list.log" \
  && ok || bad "3k6 the rate-limited degradation must be logged: $(tail -2 "$H3/logs/gh-pr-list.log")"
rm -f "$T/limited/2"
# EVERY row degraded is not a list: it must not close a blind streak.
for n in 1 2 5 6; do touch "$T/broken/$n"; done
hpl "$MC_FIELDS"
[ "$(cat "$T/rc")" = 75 ] && ok || bad "3k7 a list whose every non-draft row degraded must be unavailable (rc $(cat "$T/rc")): $(head -c 200 "$T/out.json")"
rm -f "$T"/broken/*

# isInMergeQueue has no REST field: a native-queue repo's list pays EXACTLY ONE
# GraphQL read (repository.mergeQueue), and a queued PR reads true.
printf '{"data":{"repository":{"mergeQueue":{"entries":{"nodes":[{"pullRequest":{"number":2}}]}}}}}\n' > "$T/mq.json"
hpl "$MC_INQ"
[ "$(cat "$T/rc")" = 0 ] && [ "$(graphql "$T/gh.txt")" = 1 ] \
  && ok || bad "3l a queue repo's list must make exactly 1 GraphQL call (rc $(cat "$T/rc"), graphql $(graphql "$T/gh.txt"))"
grep -qE '^api .*graphql .*mergeQueue' "$T/gh.txt" && ok || bad "3l2 the one GraphQL call must be the mergeQueue read: $(grep graphql "$T/gh.txt")"
# ... ledgered, and under the graphql bucket, never the REST one.
awk -F'\t' '$5 == "graphql" && $10 ~ /^graphql-/ {f=1} END {exit !f}' "$H3"/state/gh-rest-ledger/*.tsv 2>/dev/null \
  && ok || bad "3l5 the mergeQueue read must be ledgered in a graphql- bucket: $(cat "$H3"/state/gh-rest-ledger/*.tsv 2>/dev/null | grep graphql | head -2)"
awk -F'\t' '$5 != "graphql" && $10 ~ /^graphql-/ {f=1} END {exit f}' "$H3"/state/gh-rest-ledger/*.tsv 2>/dev/null \
  && ok || bad "3l6 a REST read was ledgered in the graphql bucket"
[ "$(q '[.[] | select(.isInMergeQueue == true) | .number] | join(",")')" = 2 ] \
  && [ "$(q '[.[] | select(.isInMergeQueue == false)] | length')" = 4 ] \
  && ok || bad "3l3 isInMergeQueue from the queue's entries: $(q '[.[] | {number, isInMergeQueue}]')"
# A GraphQL answer carrying errors is not "nothing queued": the list is unavailable.
echo '{"errors":[{"message":"nope"}]}' > "$T/mq.json"
hpl "$MC_INQ"
[ "$(cat "$T/rc")" != 0 ] && [ ! -s "$T/out.json" ] && ok || bad "3l4 a mergeQueue answer with errors must fail the list (rc $(cat "$T/rc"))"
# ... and it says WHICH failure (review round 1, Q2): a GraphQL refusal is rc 65,
# the only answer merge-conductor may remember as "this repo refuses the field";
# a transport failure is 75, which it must never remember.
[ "$(cat "$T/rc")" = 65 ] && ok || bad "3l7 a mergeQueue refusal (errors) must be rc 65, got $(cat "$T/rc")"
rm -f "$T/mq.json"; touch "$T/mq-500"
hpl "$MC_INQ"
[ "$(cat "$T/rc")" = 75 ] && ok || bad "3l8 a mergeQueue transport failure must be rc 75 (not a refusal), got $(cat "$T/rc")"
rm -f "$T/mq-500"
# A field nothing can carry is refused before any call ...
hpl "number,potentialMergeCommit"
[ "$(cat "$T/rc")" != 0 ] && [ "$(grep -c . "$T/gh.txt")" = 0 ] \
  && ok || bad "3m an unmappable field must be refused with zero calls (rc $(cat "$T/rc"), calls: $(head -3 "$T/gh.txt"))"
# ... unless the operator turns the per-author GraphQL fallback back on.
hpl "number,potentialMergeCommit" GH_PR_LIST_GRAPHQL_FALLBACK=1
[ "$(graphql "$T/gh.txt")" -ge 1 ] && ok || bad "3m2 GH_PR_LIST_GRAPHQL_FALLBACK=1 did not restore the per-author fallback"

# files — rebase-train-ahead's set, all REST.
hpl "$RTA_FIELDS"
[ "$(cat "$T/rc")" = 0 ] && [ "$(graphql "$T/gh.txt")" = 0 ] && ok || bad "3n rebase-train-ahead's list: rc $(cat "$T/rc"), $(graphql "$T/gh.txt") GraphQL"
[ "$(q '.[]|select(.number==1)|[.files[].path]|join(",")')" = "src/a.ts,src/b.ts" ] && ok || bad "3o files mapped to .path: $(q '.[]|select(.number==1)|.files')"

# ============================================================================
# 4. A torn ETag entry clears itself (review round 1, Q1)
#    An entry holding an ETag and no body answers every conditional read 304
#    -> cache-miss -> 75. Left in place it sends the same If-None-Match on the
#    next read, gets the same 304, and fails again until the 48h sweep: one PR
#    blind for two days. The miss must delete the entry, so the next read is a
#    plain 200.
# ============================================================================
H4="$T/h4"; mkdir -p "$H4/state" "$T/fb4"
cat > "$T/fb4/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  *If-None-Match*) printf 'HTTP/2.0 304\r\netag: "e1"\r\n\r\n' ;;
  *) printf 'HTTP/2.0 200\r\netag: "e1"\r\ncontent-type: application/json\r\n\r\n{"number":9,"state":"open"}\n' ;;
esac
SH
chmod +x "$T/fb4/gh"
etag_read() { : > "$T/gh4.txt"
  ( export PATH="$T/fb4:$PATH" HARNESS="$H4" GH_SINK="$T/gh4.txt"; unset GH_TOKEN
    bash -c '. "$1"; gh_rest GET repos/o/r/pulls/9 >/dev/null; echo $?' _ "$DIR/bin/lib/gh-rest.sh" ) ; }
[ "$(etag_read)" = 0 ] && ok || bad "4a the first read must answer 200"
ENTRY=$(find "$H4/state/gh-etag" -type f ! -path '*/counts/*' ! -name '.*' 2>/dev/null | head -1)
[ -n "$ENTRY" ] && ok || bad "4b the 200 must have stored an ETag entry"
[ -n "$ENTRY" ] && head -1 "$ENTRY" > "$ENTRY.t" && mv -f "$ENTRY.t" "$ENTRY"   # torn: etag line, no body
[ "$(etag_read)" = 75 ] && ok || bad "4c a 304 onto a torn entry is unverifiable (75), never an empty answer"
[ ! -e "${ENTRY:-/nonexistent}" ] && ok || bad "4d the cache-miss must delete the torn entry"
[ "$(etag_read)" = 0 ] && ! grep -q If-None-Match "$T/gh4.txt" \
  && ok || bad "4e the next read must be a plain 200, not the same 304 again: $(cat "$T/gh4.txt")"

# ============================================================================
# 5. A terminal marker belongs to ONE PR (review round 1, nit on finding 3)
#    A record whose RESULT is rewritten to another PR must not inherit the old
#    PR's `merged`.
# ============================================================================
R5="$H/builds/pool-proj-P-101-202609010000"
( export HARNESS="$H"; . "$DIR/bin/lib/pr-terminal.sh"
  printf 'merged 1000 https://github.com/%s/pull/101\n' "$SLUG" > "$R5/pr-terminal"
  prt_known_terminal "$R5" "https://github.com/$SLUG/pull/101" && echo same
  prt_known_terminal "$R5" "https://github.com/$SLUG/pull/999" && echo other ) > "$T/p5.txt" 2>&1
[ "$(cat "$T/p5.txt")" = same ] && ok || bad "5a a marker must only skip the PR it was written for (got: $(cat "$T/p5.txt"))"

echo "graphql-cuts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
