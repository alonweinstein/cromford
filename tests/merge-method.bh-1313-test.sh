#!/bin/bash
# tests/merge-method.bh-1313-test.sh — THE MERGE METHOD COMES FROM THE REPO.
#
# THE DEFECT (BH-1313, 2026-09-22). example-org/cromford was switched to
# `allow_squash_merge=false`, `allow_rebase_merge=false`, `allow_merge_commit=true`
# at ~04:10Z after an App-identity actor squash-merged three merge trains and
# #1191 within a minute of CI going green, once while the run was red. A squash
# breaks merged-by-ancestry for a train's members — the train's commits never
# reach main, so every member has to be closed by hand.
#
# Every merge write in the fleet was hard-coded to squash: `_gpm_put` in
# bin/lib/gh-pr-merge.sh sent `-f merge_method=squash`, and the four lanes'
# fallback lines ran `gh pr merge … --squash`. Under the new setting every
# cromford merge from a hub lane answers HTTP 405.
#
# WHAT THIS SUITE PINS. The method is READ from `GET repos/<slug>` once per
# process per slug and cached: squash refused + merge allowed is a MERGE COMMIT,
# rebase-only is a REBASE, a repo that allows both squash and merge keeps
# today's squash UNLESS the PR is a train, and a read that does not answer keeps
# today's squash with one honest log line. A 405 is ONE loud line naming the
# repo, the method tried and the repo's allowed methods — never a retry. And
# `gh_pr_merge_flag` gives the four lanes' own fallback lines the same answer,
# defaulting to `--squash` on a box whose harness sync has not landed the lib.
#
# Assertions are on artifacts: the rc, stdout, the pipeline log and the stub
# gh's call log. No network, no real token, no clock, no real sleep.
# Run from anywhere: bash tests/merge-method.bh-1313-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to read the repo's settings"; exit 1; }
# A real credential in the runner's environment must never reach a fixture or a
# rung, and HARNESS_ENV_DIR goes with it: bin/lib/env-path.sh honours it FIRST,
# so a pool box's value would point the admin rung at the live env bundle.
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR
ETC_HARNESS_ENV="$T/no-such-etc"; export ETC_HARNESS_ENV

SLUG="example-org/cromford"
RSHA="1111bbbb1111"
MSHA="9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f"
M405='Merge commits are not allowed on this repository.'

# ── the stub gh ──────────────────────────────────────────────────────────────
# Three calls matter here and each has its own fixture file, so a case says
# exactly what the repo answers and what the PUT answers without ordering
# anything: `repo` (GET repos/<slug>), `pull` (GET repos/<slug>/pulls/<n>) and
# `put` (the merge PUT). Every call is recorded with the WORD for the identity
# it went out on, never the value.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
W=none
case "${GH_TOKEN:-}" in
  ghp_pat_FIXTURE) W=pat ;;
  "")              W=none ;;
  *)               W=other ;;
esac
printf 'token=%s %s\n' "$W" "$*" >> "$CASE/gh-calls.log"
KIND=""
case "$*" in
  *"-X PUT repos/"*"/merge"*) KIND=put ;;
  *"api -i repos/"*"/pulls/"*) KIND=pull ;;
  *"api -i repos/"*)          KIND=repo ;;
esac
[ -n "$KIND" ] || { echo "stub gh: unexpected call: $*" >&2; exit 1; }
[ -f "$CASE/$KIND" ] || { echo "stub gh: no fixture for $KIND" >&2; exit 1; }
cat "$CASE/$KIND"
exit 0
STUB
chmod +x "$T/bin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"; chmod +x "$T/bin/sleep"
PATH="$T/bin:$PATH"

# A scratch $HARNESS so the lib's flag and env lookups never touch a live tree.
HARNESS="$T/h"; export HARNESS
mkdir -p "$HARNESS/bin/lib" "$HARNESS/flags" "$HARNESS/logs" "$HARNESS/env"
# train-shape.sh joined the list with BH-1428: WHAT a train looks like moved out
# of the ladder into one shared recogniser, and a scratch $HARNESS without it
# answers "not a train" for every PR.
for L in gh-pr-merge.sh gh-pr-create.sh env-path.sh train-shape.sh; do
  cp "$DIR/bin/lib/$L" "$HARNESS/bin/lib/" 2>/dev/null || {
    echo "FAIL: bin/lib/$L does not exist — the REST merge ladder has not been built"; exit 1; }
done

new_case() { CASE="$T/case-$1"; export CASE; scratch_rm "$CASE"; mkdir -p "$CASE"; : > "$CASE/gh-calls.log"; }
resp() { printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$2" "$3" > "$CASE/$1"; }
raw()  { printf 'HTTP/2.0 %s\r\nContent-Type: text/html\r\n\r\n%s\n' "$2" "$3" > "$CASE/$1"; }
countof() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
ncalls() { countof "$1" "$CASE/gh-calls.log"; }
nputs()  { countof '-X PUT' "$CASE/gh-calls.log"; }
nrepo()  { countof "api -i repos/$SLUG$" "$CASE/gh-calls.log"; }
calls()  { cat "$CASE/gh-calls.log" 2>/dev/null; }
plog()   { cat "$CASE/pipeline.log" 2>/dev/null; }
method_of() { grep -o -- '-f merge_method=[a-z]*' "$CASE/gh-calls.log" 2>/dev/null | head -n 1 | sed 's/.*=//'; }

# The settings answers, by name.
REPO_MERGE_ONLY='{"full_name":"example-org/cromford","allow_squash_merge":false,"allow_merge_commit":true,"allow_rebase_merge":false}'
REPO_ALL='{"full_name":"example-org/cromford","allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":true}'
REPO_REBASE_ONLY='{"full_name":"example-org/cromford","allow_squash_merge":false,"allow_merge_commit":false,"allow_rebase_merge":true}'
PULL_TRAIN='{"number":1313,"title":"merge train: 4 approved siblings","head":{"ref":"train/tier2-20260922","repo":{"full_name":"example-org/cromford"}}}'
PULL_PLAIN='{"number":1313,"title":"BH-1313: pick the merge method","head":{"ref":"ticket/bh-1313","repo":{"full_name":"example-org/cromford"}}}'

# The ladder under test, in a subshell so nothing it sources leaks between cases.
merge() { # merge <pr-number> <sha>
  ( . "$HARNESS/bin/lib/gh-pr-merge.sh"
    gh_pr_merge_rest "$SLUG" "$1" "${2:-}" "$CASE/gh-stderr.log" "$CASE/pipeline.log" "merge-method #$1" 0
    printf '\nRC=%s\n' "$?" )
}
rcof() { sed -n 's/^RC=//p' <<<"$1"; }
outof() { sed -n '1p' <<<"$1"; }
# The flag helper, the way a caller asks for it.
flag() { ( . "$HARNESS/bin/lib/gh-pr-merge.sh"; gh_pr_merge_flag "$SLUG" ) }

# ══ 1. squash REFUSED, merge allowed → the PUT is a MERGE COMMIT ═════════════
new_case merge-only
resp repo '200 OK' "$REPO_MERGE_ONLY"
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$(merge 1313 "$RSHA")
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 1: the merge must rc 0, got $(rcof "$OUT") — log: $(plog)"
[ "$(method_of)" = merge ] \
  && ok || bad "block 1: a repo that refuses squash must be merged with merge_method=merge, got '$(method_of)': $(calls)"
grep -q -- '-f merge_method=squash' "$CASE/gh-calls.log" \
  && bad "block 1: squash must NEVER be sent to a repo that refuses it: $(calls)" || ok
[ "$(nrepo)" = 1 ] && ok || bad "block 1: exactly one settings read, got $(nrepo): $(calls)"
grep -q 'merge_method=merge' "$CASE/pipeline.log" \
  && ok || bad "block 1: the log must name the method the merge went out on, got: $(plog)"
grep -q 'rung rest' "$CASE/pipeline.log" \
  && ok || bad "block 1: the log must name the identity rung that merged, got: $(plog)"

# ══ 2. a repo that allows everything keeps TODAY's squash ════════════════════
new_case all-allowed
resp repo '200 OK' "$REPO_ALL"
resp pull '200 OK' "$PULL_PLAIN"
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$(merge 1313 "$RSHA")
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 2: the merge must rc 0, got $(rcof "$OUT") — log: $(plog)"
[ "$(method_of)" = squash ] \
  && ok || bad "block 2: a repo that allows squash keeps squash, got '$(method_of)': $(calls)"

# ══ 3. rebase-only repo → the PUT is a REBASE ═══════════════════════════════
new_case rebase-only
resp repo '200 OK' "$REPO_REBASE_ONLY"
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$(merge 1313 "$RSHA")
[ "$(method_of)" = rebase ] \
  && ok || bad "block 3: a rebase-only repo must be merged with merge_method=rebase, got '$(method_of)': $(calls)"
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 3: the merge must rc 0, got $(rcof "$OUT")"

# ══ 4. the settings read FAILS → today's squash, and the log says so ════════
new_case read-404
resp repo '404 Not Found' '{"message":"Not Found"}'
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$(merge 1313 "$RSHA")
[ "$(method_of)" = squash ] \
  && ok || bad "block 4: an unreadable repo keeps TODAY's squash, got '$(method_of)': $(calls)"
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 4: the merge must still go out, got rc $(rcof "$OUT")"
[ "$(countof 'could not be read' "$CASE/pipeline.log")" = 1 ] \
  && ok || bad "block 4: exactly ONE line must say the repo's settings could not be read, got: $(plog)"

# 4b. a 200 whose body is not JSON is the same case, never a crash.
new_case read-garbage
raw  repo '200 OK' '<html>we are down</html>'
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$(merge 1313 "$RSHA")
{ [ "$(method_of)" = squash ] && [ "$(rcof "$OUT")" = 0 ]; } \
  && ok || bad "block 4b: an unparseable settings answer must fall back to squash and still merge, got '$(method_of)' rc $(rcof "$OUT")"

# ══ 5. HTTP 405 is ONE loud line naming repo, method and allowed set ════════
new_case park-405
resp repo '200 OK' "$REPO_MERGE_ONLY"
resp put  '405 Method Not Allowed' "{\"message\":\"$M405\"}"
OUT=$(merge 1313 "$RSHA")
[ "$(rcof "$OUT")" = 3 ] && ok || bad "block 5: a 405 must rc 3, got $(rcof "$OUT") — log: $(plog)"
[ "$(nputs)" = 1 ] && ok || bad "block 5: a 405 must NOT be retried, got $(nputs) PUTs: $(calls)"
[ "$(countof 'HTTP 405' "$CASE/pipeline.log")" = 1 ] \
  && ok || bad "block 5: exactly ONE 405 line, got: $(plog)"
A405=$(grep 'HTTP 405' "$CASE/pipeline.log")
grep -qF "$SLUG" <<<"$A405" && ok || bad "block 5: the 405 line must name the repo, got: $A405"
grep -q 'merge_method=merge' <<<"$A405" && ok || bad "block 5: the 405 line must name the method TRIED, got: $A405"
grep -q 'allows' <<<"$A405" && grep -q 'merge' <<<"$A405" \
  && ok || bad "block 5: the 405 line must name the repo's ALLOWED methods, got: $A405"
grep -qF "$M405" <<<"$(outof "$OUT")" \
  && ok || bad "block 5: GitHub's own message stays on stdout, got '$(outof "$OUT")'"

# ══ 6. the settings read is CACHED: two merges, one read ════════════════════
new_case cached
resp repo '200 OK' "$REPO_MERGE_ONLY"
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
( . "$HARNESS/bin/lib/gh-pr-merge.sh"
  gh_pr_merge_rest "$SLUG" 1313 "$RSHA" "$CASE/gh-stderr.log" "$CASE/pipeline.log" a 0 >/dev/null
  gh_pr_merge_rest "$SLUG" 1314 "$RSHA" "$CASE/gh-stderr.log" "$CASE/pipeline.log" b 0 >/dev/null ) >/dev/null 2>&1
[ "$(nrepo)" = 1 ] \
  && ok || bad "block 6: the settings read must happen ONCE per process per slug, got $(nrepo): $(calls)"
[ "$(nputs)" = 2 ] && ok || bad "block 6: both merges must go out, got $(nputs) PUTs"

# ══ 7. gh_pr_merge_flag — the four lanes' own fallback lines ════════════════
new_case flag-merge
resp repo '200 OK' "$REPO_MERGE_ONLY"
F=$(flag)
[ "$F" = "--merge" ] && ok || bad "block 7: a squash-refusing repo's fallback flag must be --merge, got '$F'"

new_case flag-squash
resp repo '200 OK' "$REPO_ALL"
resp pull '200 OK' "$PULL_PLAIN"
[ "$(flag)" = "--squash" ] && ok || bad "block 7: a repo that allows squash keeps --squash, got '$(flag)'"
new_case flag-rebase
resp repo '200 OK' "$REPO_REBASE_ONLY"
[ "$(flag)" = "--rebase" ] && ok || bad "block 7: a rebase-only repo's flag must be --rebase, got '$(flag)'"
new_case flag-unreadable
resp repo '500 Internal Server Error' '{"message":"boom"}'
[ "$(flag)" = "--squash" ] && ok || bad "block 7: an unreadable repo's flag must stay --squash, got '$(flag)'"

# 7b. THE LIB IS ABSENT: the caller pattern resolves --squash and makes no call.
new_case flag-no-lib
F=$( MF=--squash
     command -v gh_pr_merge_flag >/dev/null 2>&1 && MF=$(gh_pr_merge_flag "$SLUG")
     printf '%s' "$MF" )
{ [ "$F" = "--squash" ] && [ "$(ncalls 'api')" = 0 ]; } \
  && ok || bad "block 7b: without the lib the fallback flag is --squash and spends no call, got '$F': $(calls)"

# ══ 8. the kill flag: no settings read, and the old flag ════════════════════
new_case killflag
resp repo '200 OK' "$REPO_MERGE_ONLY"
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$( PR_MERGE_REST=0; export PR_MERGE_REST; merge 1313 "$RSHA" )
[ "$(rcof "$OUT")" = 2 ] && ok || bad "block 8: PR_MERGE_REST=0 must rc 2, got $(rcof "$OUT")"
[ "$(ncalls 'api')" = 0 ] \
  && ok || bad "block 8: the kill flag must spend ZERO REST calls, got: $(calls)"
FK=$( PR_MERGE_REST=0; export PR_MERGE_REST; flag )
{ [ "$FK" = "--squash" ] && [ "$(ncalls 'api')" = 0 ]; } \
  && ok || bad "block 8: with the ladder off the flag is today's --squash and reads nothing, got '$FK': $(calls)"

# ══ 9. A TRAIN merges by MERGE COMMIT even where squash is allowed ══════════
# A squash strands a train's members: their commits never reach main, so
# merged-by-ancestry never becomes true and each member is closed by hand.
new_case train-head
resp repo '200 OK' "$REPO_ALL"
resp pull '200 OK' "$PULL_TRAIN"
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$(merge 1313 "$RSHA")
[ "$(method_of)" = merge ] \
  && ok || bad "block 9: a train must land as a merge commit, got '$(method_of)': $(calls)"
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 9: the train merge must rc 0, got $(rcof "$OUT")"
grep -q 'train' "$CASE/pipeline.log" \
  && ok || bad "block 9: the log must say WHY the method was raised to a merge commit, got: $(plog)"
# …and an ordinary PR on the same repo is untouched: the read happened and the
# answer is still squash.
new_case train-plain
resp repo '200 OK' "$REPO_ALL"
resp pull '200 OK' "$PULL_PLAIN"
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$(merge 1313 "$RSHA")
{ [ "$(method_of)" = squash ] && [ "$(ncalls "api -i repos/$SLUG/pulls/1313")" = 1 ]; } \
  && ok || bad "block 9: an ordinary PR on a squash repo stays squash after one pull read, got '$(method_of)': $(calls)"
# A repo that REFUSES squash never spends the train read at all — rule 1 already
# decided, and a read nobody needs is a call nobody should pay for.
new_case train-no-read
resp repo '200 OK' "$REPO_MERGE_ONLY"
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
merge 1313 "$RSHA" >/dev/null
[ "$(ncalls "api -i repos/$SLUG/pulls/1313")" = 0 ] \
  && ok || bad "block 9: no train read when the repo's settings already decide, got: $(calls)"
# An unreadable pull object is not a train — the repo's own default stands.
new_case train-unreadable
resp repo '200 OK' "$REPO_ALL"
resp pull '502 Bad Gateway' '{"message":"boom"}'
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
merge 1313 "$RSHA" >/dev/null
[ "$(method_of)" = squash ] \
  && ok || bad "block 9: an unreadable pull object must not be guessed into a train, got '$(method_of)': $(calls)"

# ══ 10. NO TOKEN VALUE may reach a log ══════════════════════════════════════
new_case no-leak
resp repo '200 OK' "$REPO_MERGE_ONLY"
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$( GH_TOKEN=ghp_pat_FIXTURE; export GH_TOKEN; merge 1313 "$RSHA" )
[ -z "$(grep -rlE 'ghp_pat_FIXTURE' "$CASE" 2>/dev/null | tr '\n' ' ')" ] \
  && ok || bad "block 10: a token VALUE reached a log"
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 10: the merge on a held identity must rc 0, got $(rcof "$OUT")"

echo "merge-method.bh-1313-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
