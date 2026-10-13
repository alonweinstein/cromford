#!/bin/bash
# tests/decompose-parent-close.bh-949-test.sh — BH-949: the parent close must
# not close what it cannot verify.
#
# #594 was closed three times (2026-09-16 23:43Z, 09-17 01:23Z, 09-19 01:23Z) by
# bin/decompose-parent-close.sh with a comment listing four children as "closed
# without a PR". It still carried ai-build, but it sat past the 100-row issue
# list, so the only label check the pass had could not see it; and its four
# children were closed NOT_PLANNED, which the pass read as delivered.
#
# WHAT IS UNDER TEST. The REAL script, run as its callers run it
# (`decompose-parent-close.sh <project>` with GH_ISSUES_REPO set), against a
# file-backed `gh` that logs every call. Each case asserts stdout (the contract
# bin/unblocked-children.sh and bin/wake-loop.sh fold into their closure sets),
# the call log (no `-X POST …/comments`, no `-X PATCH …/issues/N`) and the
# project log.
#
# Run from anywhere: tests/decompose-parent-close.bh-949-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }

REPO="example-org/cromford"
mkdir -p "$T/bin/lib" "$T/stub"
cp "$DIR/bin/decompose-parent-close.sh" "$T/bin/"
for l in revdep-lib dep-verify-lib gh-rest gh-rest-var gh-rest-list env-path; do
  [ -f "$DIR/bin/lib/$l.sh" ] && cp "$DIR/bin/lib/$l.sh" "$T/bin/lib/"
done
chmod +x "$T/bin/"*.sh

# gh: every shape the script asks for, answered from $CASE. A PATCH close
# WRITES, so a second run reads the parent CLOSED — idempotence is a fact about
# state, not about a marker.
#
# REST only (BH-1650): the two lists are served a real 100-row page at a time
# in REST's shape (lower-case state, state_reason, html_url, head.ref,
# merged_at), and the parent is read by number on `api repos/S/issues/N`. The
# GraphQL verbs are not answered at all, so a regression to one reads as an
# unreadable list and W1 names it.
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE/calls"
M=""; P=""; prev=""; page=1
for a in "$@"; do
  [ "$prev" = -X ] && M="$a"
  case "$a" in repos/*) P="$a" ;; page=*) page="${a#page=}" ;; esac
  prev="$a"
done
pg() { # pg <file> <jq map> -> this page of the file, REST-shaped, with headers
  printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n%s\n' \
    "$(jq -c --argjson p "$page" "$2 | .[(\$p-1)*100:\$p*100]" "$1" 2>/dev/null || echo '[]')"
}
case "$M $P" in
  "GET repos/$GH_ISSUES_REPO/issues")
    pg "$CASE/issues.json" 'map(.state |= ascii_downcase
      | .state_reason = ((.stateReason // null) | if . == null then null else ascii_downcase end)
      | del(.stateReason))'; exit 0 ;;
  "GET repos/$GH_ISSUES_REPO/pulls")
    pg "$CASE/prs.json" 'map({number, html_url:.url, title, head:{ref:.headRefName},
      state:(if .state == "OPEN" then "open" else "closed" end),
      merged_at:(if .state == "MERGED" then "2026-09-20T10:00:00Z" else null end)})'; exit 0 ;;
esac
if [ "$#" = 2 ] && [ "$1" = api ]; then
  case "$2" in
    repos/"$GH_ISSUES_REPO"/issues/[0-9]*)
      n="${2##*/issues/}"
      case "$n" in *[!0-9]*) ;; *)
        [ -f "$CASE/issue-$n.json" ] || { echo '{"message":"Not Found"}'; exit 1; }
        jq -c '.state |= ascii_downcase' "$CASE/issue-$n.json"; exit 0 ;;
      esac ;;
  esac
fi
case "$*" in
  *"-X POST"*"/comments"*)
    n=$(printf '%s' "$*" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    bf=$(printf '%s' "$*" | sed -nE 's/.*-F body=@([^ ]+).*/\1/p')
    cat "$bf" > "$CASE/comment-$n" 2>/dev/null
    printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n' ;;
  *"-X PATCH"*"/issues/"*)
    n=$(printf '%s' "$*" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    echo "$n" >> "$CASE/closed"
    jq -c '.state="CLOSED"' "$CASE/issue-$n.json" > "$CASE/issue-$n.tmp" && mv "$CASE/issue-$n.tmp" "$CASE/issue-$n.json"
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed"}\n' ;;
  *"-X GET"*"/issues/"*)
    n=$(printf '%s' "$*" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    if [ -f "$CASE/issue-$n.json" ]; then
      printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"%s"}\n' "$(jq -r '.state | ascii_downcase' "$CASE/issue-$n.json")"
    else
      printf 'HTTP/2.0 404 Not Found\nx-stub: 1\n\n{"message":"Not Found"}\n'; exit 1
    fi ;;
  "api "*"/issues/"*"/comments"*)
    n=$(printf '%s' "$*" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    cat "$CASE/comments-$n.json" 2>/dev/null || echo '[]' ;;
  "api "*"/pulls/"*)
    n=$(printf '%s' "$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
    [ -f "$CASE/pull-$n.json" ] || { echo '{"message":"Not Found"}'; exit 1; }
    cat "$CASE/pull-$n.json" ;;
  *) echo '[]' ;;
esac
SH
chmod +x "$T/stub/gh"
export PATH="$T/stub:$PATH" PARENT_CLOSE_COOLDOWN_S=0 GH_ISSUES_REPO="$REPO"

newcase() { # newcase <name> -> a fresh $CASE that is also this run's $HARNESS
  CASE="$T/cases/$1"; mkdir -p "$CASE/logs" "$CASE/state" "$CASE/env"
  export CASE
  echo '[]' > "$CASE/prs.json"
}
dp()     { HARNESS="$CASE" "$T/bin/decompose-parent-close.sh" cromford 2>/dev/null; }
plog()   { cat "$CASE/logs/cromford.log" 2>/dev/null; }
calls()  { cat "$CASE/calls" 2>/dev/null; }
posted() { grep -c -- '-X POST.*/comments' "$CASE/calls" 2>/dev/null; }
patched(){ grep -c -- '-X PATCH.*/issues/' "$CASE/calls" 2>/dev/null; }
# kid <n> <parent> <k> <of> <stateReason|-> -> one issue-list row. `-` omits the
# field entirely, which is what an unknown looks like on the wire.
kid() {
  if [ "$5" = - ]; then
    printf '{"number":%s,"state":"CLOSED","title":"BH-%s.%s part","body":"Part of #%s\\nOrder: %s of %s"}' "$1" "$2" "$3" "$2" "$3" "$4"
  else
    printf '{"number":%s,"state":"CLOSED","stateReason":"%s","title":"BH-%s.%s part","body":"Part of #%s\\nOrder: %s of %s"}' "$1" "$5" "$2" "$3" "$2" "$3" "$4"
  fi
}
mpr() { # mpr <issue> <pr> [state] -> a PR-list row named the way run-build.sh names it
  printf '{"number":%s,"url":"https://github.com/%s/pull/%s","title":"BH-%s: part","headRefName":"ticket/bh-%s","state":"%s"}' \
    "$2" "$REPO" "$2" "$1" "$1" "${3:-MERGED}"
}
parent() { # parent <n> <labels-json|-> -> the by-number view; `-` omits labels
  if [ "$2" = - ]; then
    printf '{"number":%s,"state":"OPEN","title":"the parent"}\n' "$1" > "$CASE/issue-$1.json"
  else
    printf '{"number":%s,"state":"OPEN","title":"the parent","labels":%s}\n' "$1" "$2" > "$CASE/issue-$1.json"
  fi
}
noclose() { # noclose <case-label> <parent>
  local out="$1"
  [ -z "$OUT" ] && ok || bad "$out: nothing may be announced closed (stdout '$OUT')"
  [ "$(posted)" = 0 ] && ok || bad "$out: no close comment may be posted: $(calls)"
  [ "$(patched)" = 0 ] && ok || bad "$out: no close may be made: $(calls)"
  grep -q "PARENT_CLOSED #$2" <<<"$(plog)" && bad "$out: PARENT_CLOSED must not be logged" || ok
}

# ── N1: the #594 shape ──────────────────────────────────────────────────────
# Labelled parent absent from the list; four NOT_PLANNED kids; no PRs.
newcase n1
printf '[%s,%s,%s,%s]\n' "$(kid 598 594 1 4 NOT_PLANNED)" "$(kid 599 594 2 4 NOT_PLANNED)" \
  "$(kid 600 594 3 4 NOT_PLANNED)" "$(kid 601 594 4 4 NOT_PLANNED)" > "$CASE/issues.json"
parent 594 '[{"name":"ai-build"}]'
OUT=$(dp)
noclose N1 594
[ "$(plog | grep -c 'PARENT_CLOSE_SKIPPED #594')" = 1 ] && ok \
  || bad "N1/S1: exactly one skip line for #594: $(plog)"
# …and without the label it is still not a delivered split: the reason is the kids.
parent 594 '[]'
rm -f "$CASE/calls"
OUT=$(dp)
noclose N1b 594
plog | grep 'PARENT_CLOSE_SKIPPED #594' | tail -1 | grep -q 'NOT_PLANNED' && ok \
  || bad "N1b: the skip reason must name NOT_PLANNED: $(plog)"

# ── L1: labelled on its own view, all kids COMPLETED + merged ────────────────
newcase l1
printf '[%s,%s]\n' "$(kid 11 9 1 2 COMPLETED)" "$(kid 12 9 2 2 COMPLETED)" > "$CASE/issues.json"
printf '[%s,%s]\n' "$(mpr 11 21)" "$(mpr 12 22)" > "$CASE/prs.json"
parent 9 '[{"name":"ai-build"},{"name":"bug"}]'
OUT=$(dp)
noclose L1 9
plog | grep 'PARENT_CLOSE_SKIPPED #9' | grep -q 'ai-build' && ok || bad "L1: the skip must name ai-build: $(plog)"

# ── L2: the view carries no labels field — unknown, not unlabelled ───────────
newcase l2
printf '[%s,%s]\n' "$(kid 11 9 1 2 COMPLETED)" "$(kid 12 9 2 2 COMPLETED)" > "$CASE/issues.json"
printf '[%s,%s]\n' "$(mpr 11 21)" "$(mpr 12 22)" > "$CASE/prs.json"
parent 9 -
OUT=$(dp)
noclose L2 9

# ── L3: the label in mixed case is still the label ──────────────────────────
newcase l3
printf '[%s,%s]\n' "$(kid 11 9 1 2 COMPLETED)" "$(kid 12 9 2 2 COMPLETED)" > "$CASE/issues.json"
printf '[%s,%s]\n' "$(mpr 11 21)" "$(mpr 12 22)" > "$CASE/prs.json"
parent 9 '[{"name":"AI-Build"}]'
OUT=$(dp)
noclose L3 9

# ── N2: one NOT_PLANNED among merged siblings ───────────────────────────────
newcase n2
printf '[%s,%s,%s]\n' "$(kid 11 9 1 3 COMPLETED)" "$(kid 12 9 2 3 NOT_PLANNED)" "$(kid 13 9 3 3 COMPLETED)" > "$CASE/issues.json"
printf '[%s,%s]\n' "$(mpr 11 21)" "$(mpr 13 23)" > "$CASE/prs.json"
parent 9 '[]'
OUT=$(dp)
noclose N2 9
plog | grep 'PARENT_CLOSE_SKIPPED #9' | grep -q '#12 closed NOT_PLANNED' && ok || bad "N2: the skip must name the kid: $(plog)"

# ── N4: NOT_PLANNED is refused on its own, even with a merged PR ─────────────
# The PR check alone would stop N1/N2 (their dropped kids have no PR); this one
# has one, so only the stateReason check stands between it and a close.
newcase n4
printf '[%s,%s]\n' "$(kid 11 9 1 2 COMPLETED)" "$(kid 12 9 2 2 NOT_PLANNED)" > "$CASE/issues.json"
printf '[%s,%s]\n' "$(mpr 11 21)" "$(mpr 12 22)" > "$CASE/prs.json"
parent 9 '[]'
OUT=$(dp)
noclose N4 9

# ── N3: a kid whose stateReason is missing ──────────────────────────────────
newcase n3
printf '[%s,%s]\n' "$(kid 11 9 1 2 COMPLETED)" "$(kid 12 9 2 2 -)" > "$CASE/issues.json"
printf '[%s,%s]\n' "$(mpr 11 21)" "$(mpr 12 22)" > "$CASE/prs.json"
parent 9 '[]'
OUT=$(dp)
noclose N3 9

# ── P1: COMPLETED, no PR anywhere ───────────────────────────────────────────
newcase p1
printf '[%s]\n' "$(kid 11 9 1 1 COMPLETED)" > "$CASE/issues.json"
parent 9 '[]'
echo '[]' > "$CASE/comments-11.json"
OUT=$(dp)
noclose P1 9
plog | grep 'PARENT_CLOSE_SKIPPED #9' | grep -q 'has no merged PR' && ok || bad "P1: the skip must say no merged PR: $(plog)"

# ── S2: the same reason is logged once; a new reason is logged again ─────────
# (continues P1's state) a second identical run adds no line…
OUT=$(dp)
[ "$(plog | grep -c 'PARENT_CLOSE_SKIPPED #9')" = 1 ] && ok || bad "S2: an unchanged reason must not be re-logged: $(plog)"
# …and a changed reason is.
printf '[%s]\n' "$(kid 11 9 1 1 NOT_PLANNED)" > "$CASE/issues.json"
OUT=$(dp)
[ "$(plog | grep -c 'PARENT_CLOSE_SKIPPED #9')" = 2 ] && ok || bad "S2: a changed reason must be logged once more: $(plog)"

# ── P2 (#935): the PR is named only on the kid's own thread; 150 rows ahead ──
newcase p2
{ printf '['
  for i in $(seq 2001 2150); do printf '{"number":%s,"state":"OPEN","stateReason":null,"title":"filler","body":""},' "$i"; done
  printf '%s]\n' "$(kid 1030 1029 1 1 COMPLETED)"; } > "$CASE/issues.json"
parent 1029 '[]'
printf '[{"body":"Merged in https://github.com/%s/pull/1066"}]\n' "$REPO" > "$CASE/comments-1030.json"
echo '{"number":1066,"merged_at":"2026-09-20T10:00:00Z","state":"closed"}' > "$CASE/pull-1066.json"
OUT=$(dp)
[ "$OUT" = 1029 ] && ok || bad "P2: a kid whose thread names a merged PR must let the parent close (stdout '$OUT'): $(plog)"
# The kid is row 151, so it is only there because the list read page 2.
grep -q -- "-X GET repos/$REPO/issues .*page=2" "$CASE/calls" && ok \
  || bad "P2: the issue list must page past 100 rows: $(grep "repos/$REPO/issues " "$CASE/calls")"
grep -q '#1030' "$CASE/comment-1029" 2>/dev/null && grep -q "merged in https://github.com/$REPO/pull/1066" "$CASE/comment-1029" 2>/dev/null && ok \
  || bad "P2: the comment must say merged in <url>: $(cat "$CASE/comment-1029" 2>/dev/null)"

# ── P3: the thread's PR was closed without merging ──────────────────────────
newcase p3
printf '[%s]\n' "$(kid 1030 1029 1 1 COMPLETED)" > "$CASE/issues.json"
parent 1029 '[]'
printf '[{"body":"Merged in https://github.com/%s/pull/1066"}]\n' "$REPO" > "$CASE/comments-1030.json"
echo '{"number":1066,"merged_at":null,"state":"closed"}' > "$CASE/pull-1066.json"
OUT=$(dp)
noclose P3 1029

# ── P4: the thread names ANOTHER repo's PR ──────────────────────────────────
newcase p4
printf '[%s]\n' "$(kid 1030 1029 1 1 COMPLETED)" > "$CASE/issues.json"
parent 1029 '[]'
echo '[{"body":"Merged in https://github.com/Other/repo/pull/5"}]' > "$CASE/comments-1030.json"
echo '{"number":5,"merged_at":"2026-09-20T10:00:00Z"}' > "$CASE/pull-5.json"
OUT=$(dp)
noclose P4 1029
grep -q 'pulls/5' "$CASE/calls" && bad "P4: another repo's PR number must never be read here: $(calls)" || ok

# ── P5: the only PR the list carries for the kid is still OPEN ──────────────
newcase p5
printf '[%s]\n' "$(kid 11 9 1 1 COMPLETED)" > "$CASE/issues.json"
printf '[%s]\n' "$(mpr 11 21 OPEN)" > "$CASE/prs.json"
parent 9 '[]'
OUT=$(dp)
noclose P5 9

# ── H1: the happy path still closes, once ───────────────────────────────────
newcase h1
printf '[%s,%s]\n' "$(kid 11 9 1 2 COMPLETED)" "$(kid 12 9 2 2 COMPLETED)" > "$CASE/issues.json"
printf '[%s,%s]\n' "$(mpr 11 21)" "$(mpr 12 22)" > "$CASE/prs.json"
parent 9 '[]'
OUT=$(dp)
[ "$OUT" = 9 ] && ok || bad "H1: a verified split must close and print the parent (stdout '$OUT'): $(plog)"
CN=$(grep -n -- '-X POST.*issues/9/comments' "$CASE/calls" | head -1 | cut -d: -f1)
PN=$(grep -n -- '-X PATCH.*issues/9' "$CASE/calls" | head -1 | cut -d: -f1)
[ -n "$CN" ] && [ -n "$PN" ] && [ "$CN" -lt "$PN" ] && ok || bad "H1: comment before close (comment=$CN close=$PN)"
C=$(cat "$CASE/comment-9" 2>/dev/null)
grep -q "merged in https://github.com/$REPO/pull/21" <<<"$C" && grep -q "pull/22" <<<"$C" && ok || bad "H1: each kid's merged PR: $C"
grep -q 'closed without a PR' <<<"$C" && bad "H1: 'closed without a PR' is not a delivered part: $C" || ok
OUT=$(dp)
[ -z "$OUT" ] && [ "$(patched)" = 1 ] && ok || bad "H1: a second run closes nothing (stdout '$OUT', patches $(patched))"
grep -q 'PARENT_CLOSE_SKIPPED #9' <<<"$(plog)" && bad "H1: a closed parent is not a skip: $(plog)" || ok

# ── R1: a 1000-row list must not starve the newest split ────────────────────
# Found on the live dry run: the wider list carries dozens of masters closed long
# ago, each a lookup to find out, and a pass that always starts at the lowest
# number spent PARENT_CLOSE_MAX on the same closed ones every tick and never
# reached #594 at all. Twelve closed masters, one labelled in-list parent and one
# closable split, MAX=10: the labelled refusal is free and logged on pass one,
# and the closable split is reached by pass two because the lookups rotate.
newcase r1
{ printf '['
  for p in $(seq 100 111); do printf '%s,' "$(kid $((p + 1000)) "$p" 1 1 COMPLETED)"
    printf '{"number":%s,"state":"CLOSED","title":"old master","labels":[]}\n' "$p" > "$CASE/issue-$p.json"; done
  printf '{"number":900,"state":"OPEN","stateReason":null,"title":"labelled","body":""},%s,%s]\n' \
    "$(kid 901 900 1 1 COMPLETED)" "$(kid 951 950 1 1 COMPLETED)"; } > "$CASE/issues.json"
{ printf '['; for p in $(seq 100 111); do printf '%s,' "$(mpr $((p + 1000)) $((p + 2000)))"; done
  printf '%s]\n' "$(mpr 951 3951)"; } > "$CASE/prs.json"
parent 950 '[]'
OUT=$(PARENT_CLOSE_MAX=10 dp)
[ -z "$OUT" ] && ok || bad "R1: pass one spends its ten lookups on the closed masters (stdout '$OUT')"
plog | grep -q 'PARENT_CLOSE_SKIPPED #900 — parent carries ai-build' && ok \
  || bad "R1: a free refusal must not wait behind the lookup bound: $(plog)"
OUT=$(PARENT_CLOSE_MAX=10 dp)
[ "$OUT" = 950 ] && ok || bad "R1: the next pass must rotate on to the newest split (stdout '$OUT'): $(plog)"

# ── W1: every read is REST, and neither list is a 100-row window ────────────
# BH-1650 moved this script off GraphQL; BH-949 must not bring `gh issue list`,
# `gh pr list` or `gh issue view` back (tests/gh-graphql-reads-lint.bh-1585-test.sh
# is the fleet-wide guard; this is the one for the python half it cannot see).
ALLC=$(cat "$T"/cases/*/calls 2>/dev/null)
grep -Eq '^(issue (list|view)|pr (list|view)) ' <<<"$ALLC" \
  && bad "W1: no GraphQL verb may be called: $(grep -E '^(issue|pr) ' <<<"$ALLC" | sort -u | head -3)" || ok
grep -q -- "-X GET repos/$REPO/pulls .*state=all" <<<"$ALLC" && ok || bad "W1: the PR list must be the REST pulls list"
grep -q "^api repos/$REPO/issues/[0-9]*$" <<<"$ALLC" && ok || bad "W1: the parent must be read by number over REST"

# ── D1: the cursor and the skip watermark are D1 ledger rows ────────────────
# bin/jobs-client.sh's job_ledger_get/put, modelled on disk: rc 2 = no row,
# rc 1 = outage. The file is the fallback, never the first answer.
newcase d1
mkdir -p "$CASE/bin" "$CASE/db"
cat > "$CASE/bin/jobs-client.sh" <<'JC'
_db() { printf '%s/db/%s--%s' "$CASE" "$1" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' _)"; }
job_ledger_get() { [ -e "$CASE/db-down" ] && return 1; [ -f "$(_db "$1" "$2")" ] || return 2; cat "$(_db "$1" "$2")"; }
job_ledger_put() { [ -e "$CASE/db-down" ] && return 1; printf '%s' "$3" > "$(_db "$1" "$2")"; }
JC
printf '[%s]\n' "$(kid 11 9 1 1 COMPLETED)" > "$CASE/issues.json"
parent 9 '[]'
echo '[]' > "$CASE/comments-11.json"
OUT=$(dp)
noclose D1 9
[ "$(cat "$CASE/db/parent-close-skip--cromford_9" 2>/dev/null)" = "child #11 has no merged PR" ] && ok \
  || bad "D1: the skip reason must be a ledger row: $(ls "$CASE/db")"
[ "$(cat "$CASE/db/parent-close-cursor--cromford" 2>/dev/null)" = 9 ] && ok \
  || bad "D1: the cursor must be a ledger row: $(ls "$CASE/db")"
# The row answers even when the files are gone (a rebuilt hub, another box)…
rm -f "$CASE/state/parent-close-skip-cromford-9" "$CASE/state/parent-close-cursor-cromford"
OUT=$(dp)
[ "$(plog | grep -c 'PARENT_CLOSE_SKIPPED #9')" = 1 ] && ok || bad "D1: the ledger row must hold the watermark: $(plog)"
# …and the file answers when the DB does not.
touch "$CASE/db-down"
OUT=$(dp)
[ "$(plog | grep -c 'PARENT_CLOSE_SKIPPED #9')" = 2 ] && ok \
  || bad "D1: with the DB down and no file the reason is logged again (one line): $(plog)"
OUT=$(dp)
[ "$(plog | grep -c 'PARENT_CLOSE_SKIPPED #9')" = 2 ] && ok \
  || bad "D1: with the DB down the file is the watermark: $(plog)"

echo "decompose-parent-close.bh-949: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
