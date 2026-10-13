#!/bin/bash
# tests/pr-title-backfill.bh-1415-test.sh — bin/pr-title-backfill.sh retitles the
# OPEN PRs still carrying the BH-1415 defect shape
# (`BH-<n>: spec(BH-<n>): the plan this build was executed from`) and nothing
# else. It writes to PRs a human may be reading, so the matcher's negatives are
# the bulk of this suite: every title a person could have written, every state
# that is not open, and every read that failed must produce ZERO PATCH calls.
#
# `gh` is stubbed on PATH in the wire shape bin/lib/gh-rest.sh parses (status
# line, blank line, body), logging every argv to a sink, as
# tests/pr-body-closes-test.sh does. The script under test is the real one, with
# the real gh-rest library behind it.
#
# Run from anywhere: tests/pr-title-backfill.bh-1415-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$DIR/bin/pr-title-backfill.sh"
mkdir -p "$T/fakebin" "$T/fx" "$T/state"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$SCRIPT" ] && ok || bad "bin/pr-title-backfill.sh is missing or not executable"

cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
method=GET; path=""; title=""; prev=""
for a in "$@"; do
  case "$prev" in
    -X) method=$a ;;
    -f) case "$a" in title=*) title=${a#title=} ;; esac ;;
  esac
  case "$a" in repos/*) [ -z "$path" ] && path=$a ;; esac
  prev=$a
done
emit() { printf 'HTTP/2.0 %s stub\nx-stub: 1\n\n%s\n' "$1" "$2"; }
case "$method/$path" in
  GET/repos/*/pulls/[0-9]*)
    n=${path##*/}
    if [ -f "$FX/pulls-$n.json" ]; then emit 200 "$(cat "$FX/pulls-$n.json")"
    else emit 404 '{"message":"Not Found"}'; fi ;;
  GET/repos/*/pulls)
    if [ -f "$FX/list.json" ]; then emit 200 "$(cat "$FX/list.json")"
    else emit 404 '{"message":"Not Found"}'; fi ;;
  GET/repos/*/issues/[0-9]*)
    n=${path##*/}
    if [ -f "$FX/issues-$n.json" ]; then emit 200 "$(cat "$FX/issues-$n.json")"
    else emit 404 '{"message":"Not Found"}'; fi ;;
  PATCH/repos/*/pulls/[0-9]*)
    st=$(cat "$FX/patch-status" 2>/dev/null || echo 200)
    if [ "$st" != 200 ]; then emit "$st" '{"message":"refused"}'; exit 0; fi
    if [ -f "$FX/patch-title" ]; then title=$(cat "$FX/patch-title"); fi
    emit 200 "$(jq -nc --arg t "$title" '{title:$t}')" ;;
  *) emit 404 '{"message":"Not Found"}' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"

SPEC_SHAPE='the plan this build was executed from'
pr_fx() { # pr_fx <num> <state> <title> [merged_at]
  jq -nc --arg s "$2" --arg t "$3" --arg m "${4:-}" \
    '{number:0,state:$s,title:$t,merged_at:(if $m=="" then null else $m end)}' > "$T/fx/pulls-$1.json"
}
issue_fx() { jq -nc --arg t "$2" '{title:$t}' > "$T/fx/issues-$1.json"; }

run() { # run <args...> -> rc in $RC, stdout in $T/out.txt, sink in $T/gh.txt
  : > "$T/gh.txt"
  env PATH="$T/fakebin:$PATH" HARNESS="$T" GH_SINK="$T/gh.txt" FX="$T/fx" \
    bash "$SCRIPT" "$@" > "$T/out.txt" 2> "$T/err.txt"
  RC=$?
}
patches() { grep -c -- "-X PATCH" "$T/gh.txt" 2>/dev/null | tr -d ' '; }

TICKET_TITLE='PR title/body generator: title is the spec commit and What lists main'"'"'s train commits (33-PR wave 2026-09-22)'
reset_fx() { rm -f "$T/fx"/*.json "$T/fx/patch-status" "$T/fx/patch-title"; }

# ── 1. dry run is the default: both reads happen, nothing is written ─────────
reset_fx
pr_fx 1521 open "BH-1415: spec(BH-1415): $SPEC_SHAPE"
issue_fx 1415 "$TICKET_TITLE"
run o/r 1521
[ "$RC" = 0 ] && ok || bad "1: dry run rc=$RC err=$(cat "$T/err.txt")"
grep -q "WOULD RETITLE #1521" "$T/out.txt" && ok || bad "1: no WOULD RETITLE line: $(cat "$T/out.txt")"
grep -q -- "-X GET repos/o/r/pulls/1521" "$T/gh.txt" && grep -q -- "-X GET repos/o/r/issues/1415" "$T/gh.txt" \
  && ok || bad "1: the dry run did not make both reads: $(cat "$T/gh.txt")"
[ "$(patches)" = 0 ] && ok || bad "1: a dry run issued a PATCH: $(cat "$T/gh.txt")"
grep -q "RETITLED #1521" "$T/out.txt" && bad "1: a dry run claimed RETITLED" || ok

# ── 2. --apply: exactly one PATCH, carrying the issue title ─────────────────
run --apply o/r 1521
[ "$RC" = 0 ] && ok || bad "2: apply rc=$RC err=$(cat "$T/err.txt")"
[ "$(patches)" = 1 ] && ok || bad "2: expected exactly one PATCH, got $(patches): $(cat "$T/gh.txt")"
grep -q -- "-X PATCH repos/o/r/pulls/1521" "$T/gh.txt" && ok || bad "2: the PATCH did not go to the PR: $(cat "$T/gh.txt")"
grep -qF "title=BH-1415: ${TICKET_TITLE:0:80}" "$T/gh.txt" \
  && ok || bad "2: the PATCH did not carry 'BH-1415: <issue title>' truncated to 80: $(cat "$T/gh.txt")"
grep -q "RETITLED #1521" "$T/out.txt" && ok || bad "2: no RETITLED line: $(cat "$T/out.txt")"

# ── 3. the PATCH is refused: FAILED with its status, never RETITLED, rc 1 ───
echo 403 > "$T/fx/patch-status"
run --apply o/r 1521
[ "$RC" = 1 ] && ok || bad "3: a refused PATCH must exit 1, got $RC"
grep -q "FAILED #1521 status=403" "$T/out.txt" && ok || bad "3: no FAILED line naming the status: $(cat "$T/out.txt")$(cat "$T/err.txt")"
grep -q "RETITLED #1521" "$T/out.txt" && bad "3: a refused PATCH was reported as RETITLED" || ok
rm -f "$T/fx/patch-status"

# ── 4. the PATCH answers 200 but reads back a different title (D9) ──────────
echo "something else entirely" > "$T/fx/patch-title"
run --apply o/r 1521
[ "$RC" = 1 ] && ok || bad "4: a PATCH that did not read back must exit 1, got $RC"
grep -q "FAILED #1521" "$T/out.txt" && ok || bad "4: no FAILED line for a title that did not read back: $(cat "$T/out.txt")"
grep -q "RETITLED #1521" "$T/out.txt" && bad "4: a title that did not read back was claimed RETITLED" || ok
rm -f "$T/fx/patch-title"

# ── 5-12. the negatives: not one of these may reach a PATCH ─────────────────
# EVERY issue a negative's title could resolve to is seeded, so the only thing
# that can stop the PATCH is the matcher itself. Without this, a negative whose
# key points at an issue the stub does not know would "pass" on the 404 —
# exactly the vacuous pass the mutation run of this suite caught.
neg() { # neg <label> <pr title> [issue title]
  reset_fx
  pr_fx 1521 "${STATE:-open}" "$2"
  issue_fx 1415 "${3-$TICKET_TITLE}"
  issue_fx 1400 "${3-$TICKET_TITLE}"
  issue_fx 1399 "${3-$TICKET_TITLE}"
  [ "${NOISSUE:-0}" = 1 ] && rm -f "$T/fx"/issues-*.json
  run --apply o/r 1521
  [ "$(patches)" = 0 ] && ok || bad "$1: a PATCH was issued: $(cat "$T/gh.txt")"
}
neg "5 (an ordinary pipeline title)" "BH-1400: fix the size gate tolerance band"
neg "6 (the word spec in a real subject)" "BH-1400: spec artifact commit ordering in run-build"
neg "7 (no key prefix)" "spec(BH-1400): $SPEC_SHAPE"
neg "8 (the two keys disagree)" "BH-1400: spec(BH-1399): $SPEC_SHAPE"
STATE=closed neg "9 (a closed PR)" "BH-1415: spec(BH-1415): $SPEC_SHAPE"
neg "10 (already retitled by an earlier run)" "BH-1415: ${TICKET_TITLE:0:80}"
NOISSUE=1 neg "11 (the issue read 404s)" "BH-1415: spec(BH-1415): $SPEC_SHAPE"
neg "11b (the issue title is empty)" "BH-1415: spec(BH-1415): $SPEC_SHAPE" ""
neg "12 (the issue title is itself the spec shape)" "BH-1415: spec(BH-1415): $SPEC_SHAPE" "spec(BH-1415): $SPEC_SHAPE"
# 12b is 12 with the issue title DIFFERENT from the PR's, so the no-op check
# cannot be what stops the write: only "the composed title is itself the shape"
# can. (12 alone left that guard untested — the mutation run proved it.)
neg "12b (a spec-shaped issue title that is not the PR's own)" "BH-1415: spec(BH-1415): $SPEC_SHAPE" "spec(BH-1415): the plan for this build"
# 11/11b must be a skip, not a failure: nothing was written, so nothing broke.
reset_fx; pr_fx 1521 open "BH-1415: spec(BH-1415): $SPEC_SHAPE"
run --apply o/r 1521
{ [ "$RC" = 0 ] && grep -q "SKIP #1521" "$T/out.txt"; } \
  && ok || bad "11: an unreadable issue must SKIP at rc 0, got rc=$RC out=$(cat "$T/out.txt")"

# ── 13. --all-open: one defect-shaped PR among three ordinary ones ──────────
reset_fx
jq -nc '[{number:1521},{number:1516},{number:1400},{number:1399}]' > "$T/fx/list.json"
pr_fx 1521 open "BH-1415: spec(BH-1415): $SPEC_SHAPE"
pr_fx 1516 open "BH-1313: gh-pr-merge picks the merge method from the repo's settings"
pr_fx 1400 open "BH-1400: fix the size gate tolerance band"
pr_fx 1399 open "Rollback: BH-1200"
issue_fx 1415 "$TICKET_TITLE"
run --apply --all-open o/r
[ "$RC" = 0 ] && ok || bad "13: --all-open rc=$RC err=$(cat "$T/err.txt")"
[ "$(patches)" = 1 ] && ok || bad "13: expected exactly one PATCH over four open PRs, got $(patches): $(cat "$T/gh.txt")"
grep -q -- "-X PATCH repos/o/r/pulls/1521" "$T/gh.txt" && ok || bad "13: the wrong PR was retitled: $(cat "$T/gh.txt")"

# ── 14. unusable arguments never reach the API (rc 3) ───────────────────────
run
[ "$RC" = 3 ] && [ ! -s "$T/gh.txt" ] && ok || bad "14: no arguments must exit 3 before any request, got rc=$RC"
run --apply "not a slug" 1521
[ "$RC" = 3 ] && [ ! -s "$T/gh.txt" ] && ok || bad "14: a malformed slug must exit 3 before any request, got rc=$RC"
run --apply o/r notanumber
[ "$RC" = 3 ] && [ ! -s "$T/gh.txt" ] && ok || bad "14: a non-numeric PR must exit 3 before any request, got rc=$RC"

echo "pr-title-backfill: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
