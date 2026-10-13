#!/bin/bash
# tests/issue-state-lib.bh-637-test.sh — bin/lib/issue-state-lib.sh (BH-637 §3,
# updated for BH-1424 REST close-out reads).
#
# WHAT THIS PINS AND WHY. `ai-build` is the handoff label every selector in the
# fleet reads, and nothing took it off when a merge closed the issue — so the
# label outlived the work and kept offering it, and each re-offer was a full
# build on a pool machine rebuilding something already shipped. The ticket asks
# for two halves and says one is not enough:
#   (a) the enqueue reads the issue's LIVE state and refuses a closed one
#       (humans close issues by hand too, and that close strips nothing);
#   (b) the merge paths take the label off as they close.
# This suite drives both functions against a RECORDING gh stub, so what is
# asserted is the REST argv that reached GitHub and the word on stdout — never
# the shape of the source.
#
# THE NEGATIVES CARRY THE WEIGHT. A label strip is irreversible-ish and a build
# refusal is terminal, so the cases that matter are the ones where this must NOT
# act: a gh that returned a 2xx payload and still exited nonzero, a close that
# was refused (nothing may be stripped after it), a split child, `ai-build-later`
# (a different label), and both kill switches.
#
# Run from anywhere: tests/issue-state-lib.bh-637-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/issue-state-lib.sh"
if [ ! -r "$LIB" ]; then
  echo "FAIL: bin/lib/issue-state-lib.sh does not exist — every assertion below depends on it"
  exit 1
fi

mkdir -p "$T/h/bin/lib" "$T/h/env" "$T/h/flags" "$T/bin"
cp "$LIB" "$T/h/bin/lib/"
[ -r "$DIR/bin/lib/gh-app-auth.sh" ] && cp "$DIR/bin/lib/gh-app-auth.sh" "$T/h/bin/lib/"
[ -r "$DIR/bin/lib/gh-rest.sh" ] && cp "$DIR/bin/lib/gh-rest.sh" "$T/h/bin/lib/"
: > "$T/h/env/global.env"

export GH_ARGS="$T/gh-args.txt"; : > "$GH_ARGS"
export ISSUE_JSON="$T/issue.json"
export COMMENT_BODY="$T/comment-body.txt"; : > "$COMMENT_BODY"
printf '{"state":"closed","body":"plain body","labels":[{"name":"ai-build"}]}' > "$ISSUE_JSON"

cat > "$T/bin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_ARGS"
case "$*" in
  *"api -i -X GET"*"issues"*)
    GHC="${GH_ARGS%/*}/gh-get-cnt"
    cnt=$(cat "$GHC" 2>/dev/null || echo 0)
    if [ "${GH_VIEW_RC:-0}" != 0 ] && [ "$cnt" -ge 1 ]; then
      printf 'HTTP/1.1 403 Forbidden\r\n\r\n{"message":"view refused"}\n'
      exit "$GH_VIEW_RC"
    fi
    if [ "${GH_STATE_RC:-0}" != 0 ]; then
      printf 'HTTP/1.1 403 Forbidden\r\n\r\n{"message":"state refused"}\n'
      exit "$GH_STATE_RC"
    fi
    printf 'HTTP/1.1 200 OK\r\n\r\n'
    cat "$ISSUE_JSON"
    printf '%s' $((cnt+1)) > "$GHC" ;;
  *"api -i -X POST"*"comments"*)
    bodyfile=""
    for a in "$@"; do case "$a" in body=@*) bodyfile="${a#*@}" ;; -Fbody=@*) bodyfile="${a#*@}" ;; esac; done
    [ -n "$bodyfile" ] && [ -r "$bodyfile" ] && cat "$bodyfile" > "$COMMENT_BODY"
    [ "${GH_COMMENT_RC:-0}" != 0 ] && { printf 'HTTP/1.1 403 Forbidden\r\n\r\n{"message":"comment refused"}\n'; exit "$GH_COMMENT_RC"; }
    printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n' ;;
  *"api -i -X PATCH"*"issues"*)
    [ "${GH_CLOSE_RC:-0}" != 0 ] && { printf 'HTTP/1.1 403 Forbidden\r\n\r\n{"message":"close refused"}\n'; exit "$GH_CLOSE_RC"; }
    printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"closed"}\n' ;;
  *"api -i -X DELETE"*"labels/ai-build"*)
    [ "${GH_EDIT_RC:-0}" != 0 ] && { printf 'HTTP/1.1 403 Forbidden\r\n\r\n{"message":"edit refused"}\n'; exit "$GH_EDIT_RC"; }
    printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
esac
exit 0
SH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

export HARNESS="$T/h"
# shellcheck source=bin/lib/issue-state-lib.sh
. "$T/h/bin/lib/issue-state-lib.sh" || { echo "FAIL: the lib could not be sourced"; exit 1; }
command -v issue_state >/dev/null 2>&1 && ok || bad "issue_state is not defined after sourcing the lib"
command -v issue_is_closed >/dev/null 2>&1 && ok || bad "issue_is_closed is not defined after sourcing the lib"
command -v issue_close_shipped >/dev/null 2>&1 && ok || bad "issue_close_shipped is not defined after sourcing the lib"

reset() {
  : > "$GH_ARGS"
  : > "$COMMENT_BODY"
  unset GH_STATE_RC GH_VIEW_RC GH_COMMENT_RC GH_CLOSE_RC GH_EDIT_RC
  rm -f "$T/h/flags/"*
  rm -f "${GH_ARGS%/*}/gh-get-cnt"
  : > "$T/h/env/global.env"
  printf '{"state":"closed","body":"plain body","labels":[{"name":"ai-build"}]}' > "$ISSUE_JSON"
}

# ════════════════════════════════════════════════════════════════════════════
# 1. issue_state — the word, normalised, or UNKNOWN. Never a guess.
# ════════════════════════════════════════════════════════════════════════════
reset
OUT=$(issue_state example-org/proj 2066 "$T/h"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = CLOSED ] && ok || bad "a CLOSED issue must print CLOSED at rc 0 (rc=$RC out=$OUT)"
printf '{"state":"open","body":"b","labels":[]}' > "$ISSUE_JSON"
OUT=$(issue_state example-org/proj 2066 "$T/h"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = OPEN ] && ok || bad "an OPEN issue must print OPEN at rc 0 (rc=$RC out=$OUT)"

# a padded state word still normalises (the lib trims before it compares)
printf '{"state":" closed ","body":"b","labels":[]}' > "$ISSUE_JSON"
OUT=$(issue_state example-org/proj 2066 "$T/h"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = CLOSED ] && ok || bad "a padded ' closed ' must normalise to CLOSED at rc 0 (rc=$RC out=$OUT)"

# a word that is neither OPEN nor CLOSED is UNKNOWN
printf '{"state":"merged_somehow","body":"b","labels":[]}' > "$ISSUE_JSON"
issue_state example-org/proj 2066 "$T/h" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "a word that is neither OPEN nor CLOSED must be UNKNOWN rc 2 (rc=$RC)"

# uncertain answers are UNKNOWN (rc 2)
reset
OUT=$(GH_STATE_RC=1 issue_state example-org/proj 2066 "$T/h"); RC=$?
[ "$RC" = 2 ] && ok || bad "a failed state read must be UNKNOWN rc 2 (rc=$RC out=$OUT)"
reset
OUT=$(GH_STATE_RC=2 issue_state example-org/proj 2066 "$T/h"); RC=$?
[ "$RC" = 2 ] && ok || bad "a payload-and-nonzero response must be UNKNOWN rc 2 (rc=$RC out=$OUT)"

# empty / bad args never call gh
reset
OUT=$(issue_state "" 2066 "$T/h"); RC=$?
[ "$RC" = 2 ] && [ ! -s "$GH_ARGS" ] && ok || bad "an empty repo must be UNKNOWN with no gh call (rc=$RC out=$OUT args=$(cat "$GH_ARGS"))"
reset
OUT=$(issue_state example-org/proj abc "$T/h"); RC=$?
[ "$RC" = 2 ] && [ ! -s "$GH_ARGS" ] && ok || bad "a non-numeric issue must be UNKNOWN with no gh call (rc=$RC out=$OUT)"

# an empty issue number is UNKNOWN and makes no call
reset
issue_state example-org/proj "" "$T/h" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "an empty number must be UNKNOWN rc 2 (rc=$RC)"
[ ! -s "$GH_ARGS" ] && ok || bad "an empty number must make no gh call at all (got: $(cat "$GH_ARGS"))"

# the shape that reached GitHub
reset
issue_state example-org/proj 2066 "$T/h" >/dev/null
grep -q 'api -i -X GET repos/example-org/proj/issues/2066' "$GH_ARGS" \
  && ok || bad "state read must be a GET on repos/<slug>/issues/<n> (got: $(cat "$GH_ARGS"))"

# no gh on PATH at all
BASH_BIN=$(command -v bash)
RC=$( PATH=/nonexistent-dir "$BASH_BIN" -c '. "$1" >/dev/null 2>&1; issue_state example-org/proj 2066 "$2" >/dev/null 2>&1; echo $?' _ "$T/h/bin/lib/issue-state-lib.sh" "$T/h" )
[ "$RC" = 2 ] && ok || bad "with no gh on PATH the answer must be UNKNOWN rc 2 (rc=$RC)"

# ════════════════════════════════════════════════════════════════════════════
# 2. issue_is_closed — CLOSED refuses, OPEN or switched-off builds, UNKNOWN builds.
# ════════════════════════════════════════════════════════════════════════════
reset
printf '{"state":"closed","body":"b","labels":[]}' > "$ISSUE_JSON"
issue_is_closed example-org/proj 2066 "$T/h"; RC=$?
[ "$RC" = 0 ] && ok || bad "a CLOSED issue must return rc 0 (rc=$RC)"

reset
printf '{"state":"open","body":"b","labels":[]}' > "$ISSUE_JSON"
issue_is_closed example-org/proj 2066 "$T/h"; RC=$?
[ "$RC" = 1 ] && ok || bad "an OPEN issue must return rc 1 (rc=$RC)"

reset
printf 'CLOSE_STRIP_AI_BUILD=0\n' > "$T/h/env/global.env"
issue_is_closed example-org/proj 2066 "$T/h"; RC=$?
[ "$RC" = 0 ] && ok || bad "an unrelated knob must not switch off the closed check (rc=$RC)"
: > "$T/h/env/global.env"

reset
printf 'SKIP_CLOSED=0\n' > "$T/h/env/global.env"
issue_is_closed example-org/proj 2066 "$T/h"; RC=$?
[ "$RC" = 1 ] && ok || bad "SKIP_CLOSED=0 must short-circuit to rc 1 (rc=$RC)"
[ ! -s "$GH_ARGS" ] && ok || bad "SKIP_CLOSED=0 must make no gh call (got: $(cat "$GH_ARGS"))"
: > "$T/h/env/global.env"

reset
touch "$T/h/flags/skip-closed-off"
issue_is_closed example-org/proj 2066 "$T/h"; RC=$?
[ "$RC" = 1 ] && ok || bad "flags/skip-closed-off must short-circuit to rc 1 (rc=$RC)"
[ ! -s "$GH_ARGS" ] && ok || bad "flags/skip-closed-off must make no gh call (got: $(cat "$GH_ARGS"))"

# UNKNOWN builds: a failed state read is rc 2, never rc 0 (refuse) or rc 1
reset
OUT=$(GH_STATE_RC=1 issue_is_closed example-org/proj 2066 "$T/h"); RC=$?
[ "$RC" = 2 ] && ok || bad "a failed read must be rc 2 UNKNOWN so the caller builds as today (rc=$RC)"
reset
OUT=$(GH_STATE_RC=2 issue_is_closed example-org/proj 2066 "$T/h"); RC=$?
[ "$RC" = 2 ] && ok || bad "a payload-and-nonzero read must be rc 2 UNKNOWN so the caller builds as today (rc=$RC)"

# ════════════════════════════════════════════════════════════════════════════
# 3. issue_close_shipped — comment, close, read back, then strip. ORDER.
# ════════════════════════════════════════════════════════════════════════════
reset
W=$(issue_close_shipped example-org/proj 556 "Merged in X. Closing this issue." "$T/h"); RC=$?
[ "$RC" = 0 ] && [ "$W" = stripped ] && ok || bad "happy path must answer stripped at rc 0 (rc=$RC w=$W)"
grep -q 'api -i -X POST repos/example-org/proj/issues/556/comments' "$GH_ARGS" \
  && ok || bad "happy path must POST a comment first (got: $(cat "$GH_ARGS"))"
grep -q 'Merged in X. Closing this issue.' "$COMMENT_BODY" \
  && ok || bad "the comment body must reach gh verbatim (got: $(cat "$COMMENT_BODY"))"
[ "$(grep -c 'api -i -X PATCH repos/example-org/proj/issues/556' "$GH_ARGS")" = 1 ] \
  && ok || bad "exactly ONE PATCH close per invocation (got: $(cat "$GH_ARGS"))"
grep -q 'api -i -X PATCH repos/example-org/proj/issues/556' "$GH_ARGS" \
  && ok || bad "happy path must PATCH close second (got: $(cat "$GH_ARGS"))"
grep -q 'api -i -X GET repos/example-org/proj/issues/556' "$GH_ARGS" \
  && ok || bad "happy path must GET read-back third (got: $(cat "$GH_ARGS"))"
grep -q 'api -i -X DELETE repos/example-org/proj/issues/556/labels/ai-build' "$GH_ARGS" \
  && ok || bad "happy path must DELETE ai-build last (got: $(cat "$GH_ARGS"))"
ORDER=$(awk '/POST .*comments/{print "comment"} /PATCH .*issues/{print "close"} /GET .*issues/{print "view"} /DELETE .*labels\/ai-build/{print "edit"}' "$GH_ARGS" | paste -sd, -)
[ "$ORDER" = "comment,close,view,view,edit" ] \
  && ok || bad "order must be comment,close,view,edit — the label may only come off a verified close (got: $ORDER)"

# a close refusal is terminal — no read-back and no strip
reset
W=$(GH_CLOSE_RC=1 issue_close_shipped example-org/proj 557 "body" "$T/h"); RC=$?
[ "$RC" = 1 ] && [ "$W" = close-failed ] && ok || bad "a refused close must be rc 1 close-failed (rc=$RC w=$W)"
[ "$(grep -c 'api -i -X DELETE' "$GH_ARGS")" = 0 ] && ok || bad "a failed close must make no DELETE call (got: $(cat "$GH_ARGS"))"
grep -q 'api -i -X PATCH repos/example-org/proj/issues/557' "$GH_ARGS" \
  && ok || bad "the refused-close case must actually have attempted the PATCH (got: $(cat "$GH_ARGS"))"
AFTER=$(awk '/api -i -X PATCH repos\/example-org\/proj\/issues\/557/{f=1; next} f' "$GH_ARGS")
grep -q 'api -i -X GET' <<<"$(printf '%s\n' "$AFTER")" \
  && bad "a refused close must not read the issue back (after PATCH: $AFTER)" || ok

# `ai-build-later` is a DIFFERENT label — it must be a strip-noop
reset
printf '{"state":"closed","body":"b","labels":[{"name":"ai-build-later"}]}' > "$ISSUE_JSON"
W=$(issue_close_shipped example-org/proj 557 "body" "$T/h"); RC=$?
[ "$RC" = 0 ] && [ "$W" = strip-noop ] && ok || bad "'ai-build-later' is a DIFFERENT label — it must be a strip-noop (w=$W)"
grep -q 'api -i -X DELETE' "$GH_ARGS" && bad "strip-noop must make no DELETE call (got: $(cat "$GH_ARGS"))" || ok

# the strip kill switch; the close still happens
reset; printf '{"state":"closed","body":"b","labels":[{"name":"ai-build"}]}' > "$ISSUE_JSON"
printf 'CLOSE_STRIP_AI_BUILD=0\n' > "$T/h/env/global.env"
W=$(issue_close_shipped example-org/proj 557 "body" "$T/h"); RC=$?
[ "$RC" = 0 ] && [ "$W" = strip-off ] && ok || bad "CLOSE_STRIP_AI_BUILD=0 must answer strip-off at rc 0 (rc=$RC w=$W)"
[ "$(grep -c 'api -i -X PATCH repos/example-org/proj/issues/557' "$GH_ARGS")" = 1 ] \
  && ok || bad "strip-off must still close the issue (got: $(cat "$GH_ARGS"))"
grep -q 'api -i -X DELETE' "$GH_ARGS" && bad "strip-off must make no DELETE call (got: $(cat "$GH_ARGS"))" || ok
reset; touch "$T/h/flags/close-strip-ai-build-off"
W=$(issue_close_shipped example-org/proj 558 "body" "$T/h")
[ "$W" = strip-off ] && ok || bad "flags/close-strip-ai-build-off must answer strip-off (w=$W)"
reset

# an unreadable read-back: the close stands, the word is honest
W=$(GH_VIEW_RC=1 issue_close_shipped example-org/proj 559 "body" "$T/h" ); RC=$?
[ "$RC" = 0 ] && [ "$W" = strip-skipped-unreadable ] && ok \
  || bad "a failed read-back must answer strip-skipped-unreadable at rc 0 — the close stands (rc=$RC w=$W)"
grep -q 'api -i -X DELETE' "$GH_ARGS" && bad "an unreadable read-back must make no DELETE call (got: $(cat "$GH_ARGS"))" || ok

# a refused COMMENT never suppresses the close or the strip
reset
W=$(GH_COMMENT_RC=1 issue_close_shipped example-org/proj 560 "body" "$T/h" ); RC=$?
[ "$RC" = 0 ] && [ "$W" = "stripped,comment-failed" ] && ok \
  || bad "a refused comment must append ,comment-failed and change nothing else (rc=$RC w=$W)"
[ "$(grep -c 'api -i -X PATCH repos/example-org/proj/issues/560' "$GH_ARGS")" = 1 ] \
  && ok || bad "a refused comment must not stop the close (got: $(cat "$GH_ARGS"))"
grep -q 'api -i -X DELETE repos/example-org/proj/issues/560/labels/ai-build' "$GH_ARGS" \
  && ok || bad "a refused comment must not stop the strip (got: $(cat "$GH_ARGS"))"

# a refused EDIT: the close stands, and the word is greppable on a box
reset
W=$(GH_EDIT_RC=1 issue_close_shipped example-org/proj 561 "body" "$T/h" ); RC=$?
[ "$RC" = 0 ] && [ "$W" = strip-failed ] && ok || bad "a refused edit must answer strip-failed at rc 0 (rc=$RC w=$W)"

# split-child exemption: a body line "^Part of #<n>" keeps the label on
reset
printf '{"state":"closed","body":"Part of #42\\nmore","labels":[{"name":"ai-build"}]}' > "$ISSUE_JSON"
W=$(issue_close_shipped example-org/proj 562 "" "$T/h"); RC=$?
[ "$RC" = 0 ] && [ "$W" = kept-split-child ] && ok || bad "a split child must answer kept-split-child (rc=$RC w=$W)"
[ "$(grep -c 'api -i -X DELETE' "$GH_ARGS")" = 0 ] \
  && ok || bad "a split child must make no DELETE call (got: $(cat "$GH_ARGS"))"

# whole-name matching, the hotfix-lib rule
reset; printf '{"state":"closed","body":"b","labels":[{"name":"AI-BUILD "}]}' > "$ISSUE_JSON"
W=$(issue_close_shipped example-org/proj 555 "body" "$T/h")
[ "$W" = stripped ] && ok || bad "'AI-BUILD ' is the same label trimmed and lowercased — it must strip (w=$W)"

# and PROSE about being part of something is not the exemption
reset; printf '{"state":"closed","body":"this is part of the onboarding plan","labels":[{"name":"ai-build"}]}' > "$ISSUE_JSON"
W=$(issue_close_shipped example-org/proj 554 "body" "$T/h")
[ "$W" = stripped ] && ok || bad "prose 'part of the onboarding plan' is not the exemption — it must strip (w=$W)"

# empty arguments never reach gh
reset
W=$(issue_close_shipped "" 562 "body" "$T/h"); RC=$?
[ "$RC" = 1 ] && [ "$W" = close-failed ] && ok || bad "an empty repo must be close-failed rc 1 (rc=$RC w=$W)"
[ ! -s "$GH_ARGS" ] && ok || bad "an empty repo must make no gh call (got: $(cat "$GH_ARGS"))"
reset

# gh-rest.sh not loaded: nothing was closed, so the answer is close-failed rc 1
# (never a success word a caller would log as "closed issue #n")
for FN in gh_rest_close gh_rest_comment; do
  reset
  R=$( unset -f "$FN"; W=$(issue_close_shipped example-org/proj 563 "body" "$T/h"); RC=$?
       ERR=$( unset -f "$FN"; issue_close_shipped example-org/proj 563 "body" "$T/h" >/dev/null; printf '%s' "${ISSUE_CLOSE_ERR:-}" )
       echo "$RC:$W:$ERR" )
  case "$R" in
    1:close-failed:?*) ok ;;
    *) bad "with $FN missing the answer must be close-failed rc 1 with ISSUE_CLOSE_ERR set (got: $R)" ;;
  esac
  [ ! -s "$GH_ARGS" ] && ok || bad "with $FN missing no gh call may be made (got: $(cat "$GH_ARGS"))"
done

# a DIRECT call (not in $(...)) must leave no RETURN trap behind in the caller
reset
( issue_close_shipped example-org/proj 564 "body" "$T/h" >/dev/null
  trap -p RETURN > "$T/ret-trap.txt"; [ ! -s "$T/ret-trap.txt" ] ) && ok \
  || bad "issue_close_shipped must not leak a RETURN trap into the calling shell"
reset

# ════════════════════════════════════════════════════════════════════════════
# 4. THE CALLERS. A correct helper behind zero call sites is a dead feature.
# ════════════════════════════════════════════════════════════════════════════
# run-build.sh is read through the flatten (tests/lib/rb-all.sh): since the
# BH-572 cut its close-out lives in a stage module under bin/lib/rb/.
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all could not flatten bin/run-build.sh"; exit 1; }
for F in bin/run-build.sh bin/lib/mc/classify.sh bin/merge-sweep.sh bin/batch-resolve.sh; do
  SRC="$DIR/$F"; [ "$F" = bin/run-build.sh ] && SRC="$RB_ALL"
  C=$(grep -cE 'issue_close_shipped|mc_close_shipped' "$SRC" 2>/dev/null || echo 0)
  [ "${C:-0}" -ge 1 ] && ok || bad "$F must close its issue through issue_close_shipped (found $C references)"
done
awk '/^mc_close_shipped\(\)/{f=1} f{print} f&&/^}/{exit}' "$DIR/bin/lib/mc/classify.sh" \
  | grep -q 'issue_close_shipped' && ok \
  || bad "mc_close_shipped must delegate the ai-build strip to issue_close_shipped"

echo "issue-state-lib.bh-637: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
