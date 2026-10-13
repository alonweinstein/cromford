#!/bin/bash
# tests/decompose-parent-close-inapp.bh-902-test.sh — BH-902 (BH-815.3): the
# in-app lane of bin/decompose-parent-close.sh.
#
# WHAT THIS PINS. On a GitHub-Issues board a decomposed master is found through
# `Part of #N` in a child's body. An in-app board has no such convention, so
# until now this script exited 0 for those projects and their masters stayed
# open forever. What those boards have instead is the dependency primitive
# (docs/BOARD-API-CONTRACT.md, "Dependencies"): `children: [{id,key,status}]` on
# the parent. This suite drives the REAL bin/decompose-parent-close.sh — the
# production entry point, argv and all — against a stubbed board API and asserts
# on what came out: the two POSTs and their bodies, stdout, stderr, and the
# project log. Nothing here greps the script's source (D3).
#
# WHAT IS STUBBED. `curl` only, at PATH, plus a `gh` that refuses (so the GitHub
# row in fleet.conf reaches its own lane and stops there). fleet-conf.sh,
# internal-token-for.sh, env-path.sh, revdep-lib.sh and dep-verify-lib.sh are
# the real files: which lane a project takes is exactly what is under test.
#
# THE NEGATIVES ARE THE POINT. A child the list calls done whose own record says
# otherwise, a record that 500s, a parent already done, a move that answered 200
# without moving anything — every one of those must leave the board untouched,
# and a "closed" the client can read over unfinished work is the failure this
# lane exists to not commit. Case 11 is the mutation check: with the lane split
# removed, case 1 goes red.
#
# Run from anywhere: tests/decompose-parent-close-inapp.bh-902-test.sh
# (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FIX="$DIR/tests/fixtures/triage-gate-dependencies"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "decompose-parent-close-inapp: jq is required"; exit 1; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/flags" "$T/fakebin"
cp "$DIR/bin/decompose-parent-close.sh" "$DIR/bin/internal-token-for.sh" "$H/bin/"
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/revdep-lib.sh" "$DIR/bin/lib/dep-verify-lib.sh" "$DIR/bin/lib/internal-token.sh" "$H/bin/lib/"
ln -s "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
chmod +x "$H/bin/"*.sh

# x-os is an in-app board (column 4 is a real API path); ghproj is the
# GitHub-Issues lane (`-`), and it is here so the split itself is asserted.
cat > "$H/fleet.conf" <<'CONF'
x-os    example-org/x-os    https://x.test  /api/board  3  local
ghproj  example-org/ghproj  -               -           5  local
CONF
: > "$H/env/global.env"
ENVSRC="$T/x-os.env.src"
printf 'X_API_BASE=https://x.test\nX_INTERNAL_API_TOKEN=tok-never-logged\n' > "$ENVSRC"

export HARNESS="$H" FLEET_CONF="$H/fleet.conf" REVDEP_WAKE=1 STUBDIR="$T"
export PATH="$T/fakebin:$PATH"
unset GH_ISSUES_REPO PARENT_CLOSE_MAX PARENT_CLOSE_COOLDOWN_S 2>/dev/null || true

# ── the board, as a file-backed API ──────────────────────────────────────────
# Records every POST as one JSON line (url, idempotency key, whether the bearer
# header was there, and the exact body), because those four are the whole
# client-visible contract of this lane.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
OUT=""; METHOD=GET; DATA=""; IDEM=""; AUTH=0; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift ;;
    -X) METHOD="$2"; shift ;;
    --data-binary) DATA="${2#@}"; shift ;;
    -H) case "$2" in
          Idempotency-Key:*) IDEM="${2#Idempotency-Key: }" ;;
          Authorization:*)   AUTH=1 ;;
        esac; shift ;;
    http*) URL="$1" ;;
    *) ;;
  esac
  shift
done
w() { if [ -n "$OUT" ]; then printf '%s' "$1" > "$OUT"; else printf '%s' "$1"; fi; }
CODE=200
if [ "$METHOD" = POST ]; then
  [ -r "$STUBDIR/POST_CODE" ] && CODE=$(cat "$STUBDIR/POST_CODE")
  jq -cn --arg u "$URL" --arg i "$IDEM" --argjson a "$AUTH" \
         --arg b "$(cat "$DATA" 2>/dev/null)" \
         '{url:$u, idem:$i, auth:$a, body:$b}' >> "$STUBDIR/POSTS.jsonl"
  case "$URL" in
    */move) w "$(cat "$STUBDIR/MOVE_RESP.json" 2>/dev/null)" ;;
    *)      w '{"id":1}' ;;
  esac
  printf '%s' "$CODE"; exit 0
fi
case "$URL" in
  */boards)           w "$(cat "$STUBDIR/boards.json")" ;;
  */boards/*/tickets) w "$(cat "$STUBDIR/LIST.json")" ;;
  */tickets/*)
    id="${URL##*/}"
    [ -r "$STUBDIR/rec-$id.code" ] && CODE=$(cat "$STUBDIR/rec-$id.code")
    w "$(cat "$STUBDIR/rec-$id.json" 2>/dev/null || printf '{}')" ;;
  *) CODE=404; w '{}' ;;
esac
printf '%s' "$CODE"
SH
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

# ── the board's contents, per case ───────────────────────────────────────────
# Derived from the shared BH-899 fixtures so the list shape stays the one the
# contract document describes and the other dependency suites read.
reset() {
  rm -f "$T/POSTS.jsonl" "$T/POST_CODE" "$T"/rec-*.json "$T"/rec-*.code "$T/err.txt"
  scratch_rm "$H/logs"; scratch_rm "$H/builds"; mkdir -p "$H/logs"
  : > "$T/POSTS.jsonl"
  cp "$FIX/boards-cap.json" "$T/boards.json"
  cp "$ENVSRC" "$H/env/x-os.env"
  jq '.tickets |= map(
        if .id == 1830 then .children |= map(.status = "done")
        elif .id == 1825 or .id == 1826 then .status = "done"
        else . end)' "$FIX/tickets-cap.json" > "$T/LIST.json"
  jq -n '{id:1825, key:"TK-1825", status:"done", title:"Rep-facing fee screen",
          comments:[{createdAt:"2026-09-10T00:00:00Z",
                     body:"Shipped in https://github.com/example-org/x-os/pull/77"}]}' \
     > "$T/rec-1825.json"
  jq -n '{id:1826, key:"TK-1826", status:"done", title:"Fee <b>&</b> audit log",
          comments:[]}' > "$T/rec-1826.json"
  jq -n '{id:1830, key:"TK-1830", status:"in_progress", title:"Fee handling, master",
          comments:[]}' > "$T/rec-1830.json"
  printf '{"id":1830,"status":"done"}' > "$T/MOVE_RESP.json"
}

run() { # run <project> [flags...] -> stdout on stdout, stderr in $T/err.txt
  "$H/bin/decompose-parent-close.sh" "$@" 2>"$T/err.txt"
}
posts()  { awk 'END{print NR}' "$T/POSTS.jsonl" 2>/dev/null; }
post_f() { sed -n "$2p" "$T/POSTS.jsonl" 2>/dev/null | jq -r ".$1" 2>/dev/null; }
plog()   { cat "$H/logs/x-os.log" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. the happy path: comment, then move, and the KEY on stdout
# ---------------------------------------------------------------------------
reset
OUT=$(run x-os); RC=$?
[ "$RC" = 0 ] && ok || bad "1: the lane must exit 0 (got $RC)"
[ "$(posts)" = 2 ] && ok || bad "1: exactly two POSTs, comment then move (got $(posts): $(cat "$T/POSTS.jsonl"))"
case "$(post_f url 1)" in
  */tickets/1830/comments) ok ;;
  *) bad "1: the FIRST write must be the comment (got $(post_f url 1))" ;;
esac
case "$(post_f url 2)" in
  */tickets/1830/move) ok ;;
  *) bad "1: the SECOND write must be the move (got $(post_f url 2))" ;;
esac
BODY=$(post_f body 1)
grep -q 'TK-1825' <<<"$BODY" && grep -q 'TK-1826' <<<"$BODY" && ok \
  || bad "1: the comment must name every part: $BODY"
[ "$(grep -o 'https://github.com/example-org/x-os/pull/77' <<<"$BODY" | grep -c .)" = 1 ] && ok \
  || bad "1: the child's own PR link must appear exactly once: $BODY"
grep -q '&lt;b&gt;&amp;' <<<"$BODY" && ok \
  || bad "1: a title carrying markup must be HTML-escaped: $BODY"
[ "$(grep -o '<a href=' <<<"$BODY" | grep -c .)" = 1 ] && ok \
  || bad "1: a child with no PR anywhere is listed by key alone, never given a plausible link: $BODY"
grep -q '—' <<<"$BODY" && bad "1: no em dashes in a client-facing comment: $BODY" || ok
[ "$(post_f idem 1)" = "parent-close-x-os-1830-comment" ] && ok \
  || bad "1: the comment POST must carry its own idempotency key (got '$(post_f idem 1)')"
[ "$(post_f idem 2)" = "parent-close-x-os-1830-move" ] && ok \
  || bad "1: the move POST must carry its own idempotency key (got '$(post_f idem 2)')"
[ "$(post_f auth 1)" = 1 ] && [ "$(post_f auth 2)" = 1 ] && ok \
  || bad "1: both writes must be authenticated"
[ "$(post_f body 2)" = '{"toStatus":"done","sortOrder":999999}' ] && ok \
  || bad "1: the move body is the contract's (got $(post_f body 2))"
[ "$OUT" = "TK-1830" ] && ok || bad "1: stdout must be the parent KEY (got '$OUT')"
case "$OUT" in
  [0-9]*) bad "1: stdout must never be a bare number — bin/unblocked-children.sh folds those into a GitHub closure set" ;;
  *) ok ;;
esac
grep -q 'PARENT_CLOSED TK-1830' <<<"$(plog)" && ok || bad "1: the close must leave a log line: $(plog)"
grep -rq 'tok-never-logged' "$H/logs" 2>/dev/null \
  && bad "1: the board token must never reach a log" || ok

# ---------------------------------------------------------------------------
# 2. one child still open in the list = the master stays open
# ---------------------------------------------------------------------------
reset
jq '.tickets |= map(if .id == 1830 then
      .children = [(.children[0] | .status = "done"), (.children[1] | .status = "review")]
    else . end)' "$T/LIST.json" > "$T/LIST.tmp" && mv "$T/LIST.tmp" "$T/LIST.json"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && [ -z "$OUT" ] && ok \
  || bad "2: a split with a slice still running must never be closed (posts=$(posts) out='$OUT')"

# ---------------------------------------------------------------------------
# 3. a child record this pass could not READ is an unknown, not a closure
# ---------------------------------------------------------------------------
reset
echo 500 > "$T/rec-1826.code"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && [ -z "$OUT" ] && ok \
  || bad "3: a 500 on a child record must stop the close (posts=$(posts) out='$OUT')"

# ---------------------------------------------------------------------------
# 4. …and a record that DISAGREES with the list is an unknown too
# ---------------------------------------------------------------------------
reset
jq '.status = "review"' "$T/rec-1826.json" > "$T/rec.tmp" && mv "$T/rec.tmp" "$T/rec-1826.json"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && [ -z "$OUT" ] && ok \
  || bad "4: list says done, record says review — that is not a closure (posts=$(posts) out='$OUT')"

# ---------------------------------------------------------------------------
# 5. a board that never adopted the primitive is silent, not broken
# ---------------------------------------------------------------------------
reset
jq 'del(.tickets[].children)' "$T/LIST.json" > "$T/LIST.tmp" && mv "$T/LIST.tmp" "$T/LIST.json"
OUT=$(run x-os); RC=$?
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && [ -z "$OUT" ] && ok \
  || bad "5: no children field anywhere must be rc 0 and no writes (rc=$RC posts=$(posts))"

# ---------------------------------------------------------------------------
# 6. a parent already done is nothing to do
# ---------------------------------------------------------------------------
reset
jq '.tickets |= map(if .id == 1830 then .status = "done" else . end)' "$T/LIST.json" \
  > "$T/LIST.tmp" && mv "$T/LIST.tmp" "$T/LIST.json"
jq '.status = "done"' "$T/rec-1830.json" > "$T/rec.tmp" && mv "$T/rec.tmp" "$T/rec-1830.json"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && [ -z "$OUT" ] && ok \
  || bad "6: a master already done must not be closed twice (posts=$(posts) out='$OUT')"
# …and the same again with only the RECORD done, so the list is not the authority.
reset
jq '.status = "done"' "$T/rec-1830.json" > "$T/rec.tmp" && mv "$T/rec.tmp" "$T/rec-1830.json"
OUT=$(run x-os)
[ "$(posts)" = 0 ] && [ -z "$OUT" ] && ok \
  || bad "6b: the parent's own record decides (posts=$(posts) out='$OUT')"

# ---------------------------------------------------------------------------
# 7. --dry-run says what it would send and sends nothing
# ---------------------------------------------------------------------------
reset
OUT=$(run x-os --dry-run); RC=$?
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok \
  || bad "7: --dry-run must write nothing (rc=$RC posts=$(posts))"
[ "$(grep -c '^DRYRUN POST https://x.test/api/board/tickets/1830/' "$T/err.txt")" = 2 ] && ok \
  || bad "7: --dry-run must name both calls on stderr: $(cat "$T/err.txt")"

# ---------------------------------------------------------------------------
# 8. a 200 that did not move the ticket is a failure wearing a success's clothes
# ---------------------------------------------------------------------------
reset
printf '{"ok":true}' > "$T/MOVE_RESP.json"
OUT=$(run x-os)
[ "$(posts)" = 2 ] && ok || bad "8: both calls are still attempted (posts=$(posts))"
[ -z "$OUT" ] && ok || bad "8: stdout must stay empty when the move did not land (got '$OUT')"
grep -q 'PARENT_CLOSE_FAILED TK-1830' <<<"$(plog)" && ok || bad "8: the failure must be logged: $(plog)"
grep -q 'comment is on the thread but the move did not land' <<<"$(plog)" && ok \
  || bad "8: the log must say which half landed: $(plog)"
grep -q 'PARENT_CLOSED TK-1830' <<<"$(plog)" \
  && bad "8: a failed move must never be logged as a close: $(plog)" || ok

# ---------------------------------------------------------------------------
# 8b. a comment that did not land means the move is not attempted at all
# ---------------------------------------------------------------------------
reset
echo 500 > "$T/POST_CODE"
OUT=$(run x-os)
[ "$(posts)" = 1 ] && ok || bad "8b: the move must not follow a failed comment (posts=$(posts))"
grep -q 'move was not attempted' <<<"$(plog)" && ok || bad "8b: say so in the log: $(plog)"
[ -z "$OUT" ] && ok || bad "8b: nothing on stdout (got '$OUT')"

# ---------------------------------------------------------------------------
# 9. a retry after a comment that landed finishes the move, and says nothing twice
# ---------------------------------------------------------------------------
reset
jq '.comments = [{createdAt:"2026-09-10T01:00:00Z",
                  body:"<p>All 2 parts of this one are in, so I am closing it.</p>"}]' \
   "$T/rec-1830.json" > "$T/rec.tmp" && mv "$T/rec.tmp" "$T/rec-1830.json"
OUT=$(run x-os)
[ "$(posts)" = 1 ] && ok || bad "9: exactly one call on a retry (posts=$(posts): $(cat "$T/POSTS.jsonl"))"
case "$(post_f url 1)" in
  */tickets/1830/move) ok ;;
  *) bad "9: …and it is the move (got $(post_f url 1))" ;;
esac
[ "$OUT" = "TK-1830" ] && ok || bad "9: the retry still reports the close (got '$OUT')"

# ---------------------------------------------------------------------------
# 10. a GitHub-Issues row never reaches the board API
# ---------------------------------------------------------------------------
reset
OUT=$(run ghproj); RC=$?
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && [ -z "$OUT" ] && ok \
  || bad "10: a board_prefix of - belongs to the GitHub lane (rc=$RC posts=$(posts) out='$OUT')"

# ---------------------------------------------------------------------------
# 10b. a project with no board credentials is silent, and logs nothing
# ---------------------------------------------------------------------------
reset
rm -f "$H/env/x-os.env"
OUT=$(run x-os); RC=$?
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok \
  || bad "10b: an unconfigured board must be a silent rc 0 (rc=$RC posts=$(posts))"
[ ! -s "$H/logs/x-os.log" ] && ok \
  || bad "10b: a board that has not adopted this must not write to the project log: $(plog)"

# ---------------------------------------------------------------------------
# 11. MUTATION: remove the lane split and case 1 goes red
# ---------------------------------------------------------------------------
# The proof that case 1 discriminates. Without `{ inapp_lane; exit 0; }` the
# in-app project falls out at the repo check exactly as it did before BH-902.
reset
sed 's@^\[ -n "\$repo" \] || { inapp_lane; exit 0; }$@[ -n "$repo" ] || exit 0@' \
  "$H/bin/decompose-parent-close.sh" > "$H/bin/mutant.sh"
chmod +x "$H/bin/mutant.sh"
if ! grep -qxF '[ -n "$repo" ] || exit 0' "$H/bin/mutant.sh"; then
  bad "11: the mutation did not apply — the lane split line is not where this test thinks it is"
else
  OUT=$("$H/bin/mutant.sh" x-os 2>/dev/null)
  if [ "$(posts)" = 0 ] && [ -z "$OUT" ]; then
    ok; echo "MUTATION: case 1 red under split removal"
  else
    bad "11: with the split removed the lane still ran (posts=$(posts) out='$OUT')"
  fi
fi
rm -f "$H/bin/mutant.sh"

echo "decompose-parent-close-inapp: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
