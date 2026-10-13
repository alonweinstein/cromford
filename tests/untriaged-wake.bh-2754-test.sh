#!/bin/bash
# tests/untriaged-wake.bh-2754-test.sh — the SHIPPED bin/untriaged-wake.sh
# (BH-2754, Ask 2 of #2751) against a scratch harness.
#
# The lane is the only producer of a `wakes` row for a ticket nobody touched on
# GitHub, so what matters is exactly which tickets it POSTs and that nothing
# is counted as nudged unless the worker said inserted:1. Everything runs for
# real underneath: bin/lib/untriaged-lib.sh, gh_rest and its list pager,
# bin/jobs-client.sh's _jobs_req, and the REAL bin/unblocked-children.sh for
# the dep-release class. Only `gh` and `curl` are stubs on PATH:
#   gh    answers REST issue reads from $T/issues.json, honouring state=,
#         labels= and since= (on updated_at, as GitHub does);
#   curl  records every POST /api/wakes/nudge body in $T/posts.jsonl and
#         answers inserted ${STUB_INSERTED:-1}, or HTTP $STUB_STATUS.
#
# Run from anywhere: bash tests/untriaged-wake.bh-2754-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/rendered.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/state" "$H/catalog" "$T/shim" "$T/tmp"
cp "$DIR/bin/untriaged-wake.sh" "$DIR/bin/unblocked-children.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp -R "$DIR/bin/lib/." "$H/bin/lib/"
# bin/jobs-client.sh refuses to load without its modules beside it.
[ -r "$H/bin/lib/jobs/req.sh" ] || { echo "FAIL: bin/lib/jobs/*.sh missing from the scratch tree"; exit 1; }
cp "$(rendered_registry)" "$H/catalog/lanes.json"
chmod +x "$H/bin/untriaged-wake.sh" "$H/bin/unblocked-children.sh"
SECRET=s3cr3t-test
cat > "$H/env/global.env" <<E
JOBS_URL=http://stub
HARNESS_SECRET=$SECRET
JOBS_BOX=probe-box
JOBS_RETRY_SLEEP=0
E
echo 'proj Org/repo - - 3 box-small' > "$H/fleet.conf"
# NO MODEL, EVER: a call to the model wrapper would leave this marker.
printf '#!/bin/bash\ntouch "%s/agent-called"\n' "$T" > "$H/bin/agent-call.sh"
chmod +x "$H/bin/agent-call.sh"

cat > "$T/shim/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/gh-calls.log"
case "$*" in
  "api repos/"*" -q .id") echo 1; exit 0 ;;          # gh-repo-token.sh's probe
esac
[ "${STUB_GH_DEAD:-}" = 1 ] && exit 1               # every read after it: no status line
case "$*" in
  *"pr list"*) echo '[]'; exit 0 ;;
  *"issue view"*)
    n=$(printf '%s' "$*" | sed -nE 's/.*issue view ([0-9]+).*/\1/p')
    jq -c --argjson n "$n" '.[] | select(.number == $n) | {number, state:(.state|ascii_upcase), title}' \
      "$STUB_DIR/issues.json"; exit 0 ;;
esac
st="" lbl="" since="" page=1 path=""
for a in "$@"; do
  case "$a" in state=*) st="${a#state=}" ;; labels=*) lbl="${a#labels=}" ;;
               since=*) since="${a#since=}" ;; page=*) page="${a#page=}" ;; repos/*) path="$a" ;; esac
done
case "$path" in repos/*/issues) ;; *) exit 1 ;; esac
code="${STUB_GH_STATUS:-200}"
[ "$st" = closed ] && [ -n "${STUB_GH_CLOSED_STATUS:-}" ] && code="$STUB_GH_CLOSED_STATUS"
if [ "$code" != 200 ]; then
  printf 'HTTP/2 %s\r\nx: 1\r\n\r\n{"message":"API rate limit exceeded"}' "$code"; exit 1
fi
[ "$page" = 1 ] || { printf 'HTTP/2 200\r\nx: 1\r\n\r\n[]'; exit 0; }
body=$(jq -c --arg st "$st" --arg l "$lbl" --arg since "$since" '
  map(select($st == "all" or .state == $st)
      | select($l == "" or ([.labels[].name] | index($l)))
      | select($since == "" or .updated_at >= $since))' "$STUB_DIR/issues.json")
printf 'HTTP/2 200\r\nx: 1\r\n\r\n%s' "$body"
SH

cat > "$T/shim/curl" <<'SH'
#!/bin/bash
url="" body="" prev=""
for a in "$@"; do
  [ "$prev" = --data-binary ] && body="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
case "$url" in
  */api/wakes/nudge)
    printf '%s\n' "$body" >> "$STUB_DIR/attempts.jsonl"
    if [ -n "${STUB_STATUS:-}" ]; then printf '{"error":"unknown endpoint"}\n%s' "$STUB_STATUS"; exit 0; fi
    printf '%s\n' "$body" >> "$STUB_DIR/posts.jsonl"
    printf '{"inserted":%s,"as_of":"x"}\n200' "${STUB_INSERTED:-1}" ;;
  *) printf '%s\n' "$url" >> "$STUB_DIR/curl-other.log"; printf '{}\n404' ;;
esac
SH
chmod +x "$T/shim/gh" "$T/shim/curl"
export PATH="$T/shim:$PATH" STUB_DIR="$T" TMPDIR="$T/tmp" GH_ETAG=0

NOW=1790000000
iso() { date -u -d "@$((NOW - $1 * 60))" '+%Y-%m-%dT%H:%M:%SZ'; }
# issue <num> <open|closed> <comments> <created min ago> [closed min ago|-] [label|-] [body] [pr] [updated min ago]
issue() {
  local closed=null upd
  upd=$(iso "$4")
  if [ "${5:--}" != - ]; then closed="\"$(iso "$5")\""; upd=$(iso "$5"); fi
  if [ -n "${9:-}" ]; then upd=$(iso "$9"); fi
  jq -nc --argjson n "$1" --arg s "$2" --argjson c "$3" --arg cr "$(iso "$4")" --argjson cl "$closed" \
    --arg up "$upd" --arg l "${6:-ai-build}" --arg b "${7:-}" --arg pr "${8:-}" '
    {number:$n, state:$s, comments:$c, created_at:$cr, updated_at:$up, closed_at:$cl,
     title:"t\($n)", body:$b, labels:(if $l == "-" then [] else [{name:$l}] end)}
    | if $pr == "pr" then . + {pull_request:{url:"u"}} else . end'
}
fixture() { jq -s '.' > "$T/issues.json"; }
reset() {
  rm -f "$T"/posts.jsonl "$T"/attempts.jsonl "$T"/gh-calls.log "$H"/flags/* "$H/logs/untriaged-wake.log"
  scratch_rm "$H/state/dep-verify"
}
run() { # run [VAR=val ...] — the shipped script, the clock pinned
  env HARNESS="$H" UNTRIAGED_WAKE_NOW="$NOW" "$@" "$H/bin/untriaged-wake.sh" >/dev/null 2>&1
}
posts()   { [ -s "$T/posts.jsonl" ] && grep -c . "$T/posts.jsonl" || echo 0; }
ghcalls() { [ -s "$T/gh-calls.log" ] && grep -c . "$T/gh-calls.log" || echo 0; }
logl()    { tail -1 "$H/logs/untriaged-wake.log" 2>/dev/null; }

# ══ A1. untriaged: 40 min old, 0 comments → exactly one POST, key a number ══
reset; issue 5 open 0 40 | fixture
run; RC=$?
[ "$RC" = 0 ] && ok || bad "A1: rc must be 0, got $RC"
[ "$(posts)" = 1 ] && ok || bad "A1: exactly one POST expected, got $(posts): $(cat "$T/posts.jsonl" 2>/dev/null)"
jq -e '.repo == "Org/repo" and .key == 5 and (.key|type) == "number" and .reason == "untriaged" and .dedupe == "untriaged:5"' \
  "$T/posts.jsonl" >/dev/null 2>&1 && ok || bad "A1: POST body wrong: $(cat "$T/posts.jsonl" 2>/dev/null)"
grep -q 'seen=1 candidates=1 nudged=1 already=0 left=0$' <<<"$(logl)" && ok || bad "A1: log line wrong: $(logl)"

# ══ second run, the worker already has it → already=1, nothing nudged ══════
run STUB_INSERTED=0
grep -q 'nudged=0 already=1 left=0$' <<<"$(logl)" && ok || bad "replay: expected already=1 nudged=0, got: $(logl)"

# ══ A2. unblocked: #10 closed 5 min ago releases #20 through the real
#       bin/unblocked-children.sh → one POST unblocked:20:10 ═══════════════════
reset
{ issue 10 closed 1 3000 5; issue 20 open 1 3000 - ai-build 'Blocked-by: #10 (hard)'; } | fixture
run
[ "$(posts)" = 1 ] && ok || bad "A2: one POST expected, got $(posts): $(cat "$T/posts.jsonl" 2>/dev/null)"
jq -e '.key == 20 and .reason == "unblocked" and .dedupe == "unblocked:20:10"' "$T/posts.jsonl" >/dev/null 2>&1 \
  && ok || bad "A2: POST body wrong: $(cat "$T/posts.jsonl" 2>/dev/null)"
grep -q 'CHANGED 10\|repos/Org/repo/issues' "$T/gh-calls.log" && ok || bad "A2: the closed read never happened"

# lastdep is the blocker that closed LATEST, not the highest number.
reset
{ issue 30 closed 1 3000 4; issue 31 closed 1 3000 20; issue 40 open 1 3000 - ai-build 'Blocked-by: #31, #30'; } | fixture
run
jq -e '.dedupe == "unblocked:40:30"' "$T/posts.jsonl" >/dev/null 2>&1 \
  && ok || bad "A2: lastdep must be the latest close (#30 at 4 min), got: $(cat "$T/posts.jsonl" 2>/dev/null)"

# ══ F1: a child whose blocker is still OPEN never reaches bin/dep-verify.sh,
#       so no "Building this now" comment goes on a ticket the lane won't wake.
#       The stub answers SOFT, which is exactly the verdict that comments. ════
printf '#!/bin/bash\ntouch "%s/dep-verify-called"\necho "SOFT disjoint files"\n' "$T" > "$H/bin/dep-verify.sh"
chmod +x "$H/bin/dep-verify.sh"
# #10 closed 5 min ago puts the lane into unblocked-children; #20 waits on #11,
# still open, which is the soft class's only candidate.
{ issue 10 closed 1 3000 5; issue 11 open 1 3000 - -; issue 20 open 1 3000 - ai-build 'Blocked-by: #11'; } | fixture
# Control: the same tree driven straight through the script with the soft class
# on does reach the stub and does comment, so the case below is probative.
reset; rm -f "$T/dep-verify-called"
printf 'board issues: CHANGED 10 "" (state: open -> closed)\n' \
  | env HARNESS="$H" REVDEP_TAKE=0 GH_ISSUES_REPO=Org/repo "$H/bin/unblocked-children.sh" proj >/dev/null 2>&1
[ -e "$T/dep-verify-called" ] && grep -q 'issues/20/comments' "$T/gh-calls.log" 2>/dev/null && ok \
  || bad "F1 control: unblocked-children with DEP_VERIFY on must reach the stub and comment on #20 (gh: $(cat "$T/gh-calls.log" 2>/dev/null))"
reset; rm -f "$T/dep-verify-called"
run
[ ! -e "$T/dep-verify-called" ] && ok || bad "F1: the lane's call reached bin/dep-verify.sh"
grep -q '/comments' "$T/gh-calls.log" 2>/dev/null && bad "F1: the lane posted a comment: $(grep '/comments' "$T/gh-calls.log")" || ok
[ "$(posts)" = 0 ] && ok || bad "F1: no nudge expected for a child with an open blocker, got $(posts)"
rm -f "$H/bin/dep-verify.sh" "$T/dep-verify-called"

# ══ negatives: none of these may POST ═══════════════════════════════════════
neg() { # neg <label> — fixture already written
  reset; run; RC=$?
  [ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "$1: expected rc 0 and no POST, got rc=$RC posts=$(posts): $(cat "$T/posts.jsonl" 2>/dev/null)"
}
issue 6 closed 0 3000 5 | fixture;                  neg "closed issue with 0 comments"
issue 7 open 0 40 - bug | fixture;                  neg "open issue without ai-build"
issue 8 open 0 5 | fixture;                         neg "ai-build issue 5 min old"
issue 9 open 1 40 | fixture;                        neg "issue with 1 comment"
issue 11 open 0 40 - ai-build '' pr | fixture;      neg "a PR in the issues list"
{ issue 10 open 1 3000; issue 20 open 1 3000 - ai-build 'Blocked-by: #10 (hard)'; } | fixture
neg "child whose one hard blocker is still open"
{ issue 10 closed 1 9000 4320; issue 20 open 1 3000 - ai-build 'Blocked-by: #10 (hard)'; } | fixture
neg "blocker closed 3 days ago (outside the lookback)"
# GitHub's since= is on updated_at: a comment 2 min ago on a blocker closed 3
# days ago puts it in the read, and closed_at is what must keep it out.
{ issue 10 closed 1 9000 4320 ai-build '' '' 2; issue 20 open 1 3000 - ai-build 'Blocked-by: #10 (hard)'; } | fixture
neg "blocker closed 3 days ago, commented 2 min ago"

# ══ a failed GitHub read is could-not-run, never "no candidates" ═══════════
issue 5 open 0 40 | fixture
reset; run STUB_GH_STATUS=403; RC=$?
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "403: rc 0 and no POST expected (rc=$RC posts=$(posts))"
grep -q 'nudged=0 .*could-not-run 403@proj' <<<"$(logl)" && ok || bad "403: log must say could-not-run 403@proj, got: $(logl)"
reset; run STUB_GH_DEAD=1; RC=$?
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "rc 75: rc 0 and no POST expected (rc=$RC posts=$(posts))"
grep -q 'nudged=0 .*could-not-run 000@proj' <<<"$(logl)" && ok || bad "rc 75: log must say could-not-run 000@proj, got: $(logl)"
# Only the CLOSED read failing keeps the untriaged candidates it already found.
reset; run STUB_GH_CLOSED_STATUS=403
[ "$(posts)" = 1 ] && grep -q 'nudged=1 .*could-not-run 403@proj' <<<"$(logl)" && ok \
  || bad "closed-read 403: the untriaged nudge must still go and the failure be logged (posts=$(posts)): $(logl)"

# ══ worker answers 404 (route not deployed) → could-not-run 404, nothing nudged
reset; run STUB_STATUS=404; RC=$?
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "404: rc 0 expected (rc=$RC)"
grep -q 'nudged=0 already=0 left=1 (#5) could-not-run 404$' <<<"$(logl)" && ok || bad "404: log wrong: $(logl)"
# The run stops posting at the first failure: two candidates, one attempt.
{ issue 5 open 0 40; issue 6 open 0 50; } | fixture
reset; run STUB_STATUS=500
[ "$(grep -c . "$T/attempts.jsonl")" = 1 ] && ok || bad "500: must stop after the first failed POST, attempts=$(grep -c . "$T/attempts.jsonl")"
grep -q 'nudged=0 already=0 left=2 (#6 #5) could-not-run 500$' <<<"$(logl)" && ok || bad "500: log wrong: $(logl)"

# ══ cap: 30 candidates, MAX=25 → 25 POSTs, the 5 newest left and named ═════
reset
for i in $(seq 1 30); do issue "$((100 + i))" open 0 "$((200 - i))"; done | fixture
run UNTRIAGED_WAKE_MAX=25
[ "$(posts)" = 25 ] && ok || bad "cap: 25 POSTs expected, got $(posts)"
grep -q 'candidates=30 nudged=25 already=0 left=5 (#126 #127 #128 #129 #130)$' <<<"$(logl)" \
  && ok || bad "cap: log must name the 5 left, got: $(logl)"
jq -s -e 'map(.key) == [range(101;126)]' "$T/posts.jsonl" >/dev/null && ok || bad "cap: must post oldest first"
reset; run UNTRIAGED_WAKE_MAX=0
[ "$(posts)" = 0 ] && grep -q 'nudged=0 already=0 left=30' <<<"$(logl)" && ok || bad "MAX=0 posts nothing: $(logl)"

# A closed read that fills its 300-row cap says so rather than implying it saw
# every closure in the window (D12).
reset
for i in $(seq 1 300); do issue "$((1000 + i))" closed 1 3000 5; done | fixture
run
grep -q 'capped-closed@proj' <<<"$(logl)" && ok || bad "closed cap: log must say capped-closed@proj, got: $(logl)"

# ══ a knob that is not a whole number is could-not-run, before any read ════
reset; run UNTRIAGED_WAKE_AFTER_MIN=1.5
[ "$(posts)" = 0 ] && [ "$(ghcalls)" = 0 ] && grep -q 'could-not-run knob AFTER' <<<"$(logl)" && ok \
  || bad "bad knob: expected no read and could-not-run knob (gh=$(ghcalls)): $(logl)"

# ══ the off switches stop the lane before any GitHub read ══════════════════
issue 5 open 0 40 | fixture
for f in lane-off-untriaged-wake all-off; do
  reset; touch "$H/flags/$f"; run; RC=$?
  [ "$RC" = 0 ] && [ "$(posts)" = 0 ] && [ "$(ghcalls)" = 0 ] && ok \
    || bad "flags/$f: no POST and no GitHub call expected (rc=$RC posts=$(posts) gh=$(ghcalls))"
done
# Control: the same fixture with no flag does post, so the two above are real.
reset; run
[ "$(posts)" = 1 ] && ok || bad "control: with no flag the lane must post"

# ══ no model was ever called; the secret never reached a log ═══════════════
[ ! -e "$T/agent-called" ] && ok || bad "bin/agent-call.sh was called"
grep -rq "$SECRET" "$H/logs" && bad "HARNESS_SECRET found in logs/" || ok

echo "untriaged-wake.bh-2754: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
