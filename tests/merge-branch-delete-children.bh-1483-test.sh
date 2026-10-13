#!/bin/bash
# tests/merge-branch-delete-children.bh-1483-test.sh — THE BRANCH DELETE MUST
# NOT CLOSE A STACKED CHILD.
#
# THE DEFECT (BH-1483, 2026-09-22). `bin/lib/gh-pr-merge.sh` `_gpm_delete_branch`
# read the merged PR's head ref and issued
# `DELETE repos/<slug>/git/refs/heads/<ref>` with no look at the open PRs whose
# `base` is that ref. `delete_branch_on_merge` is false on this repo, so
# GitHub's own retarget-on-delete never runs — it just closes every stacked
# child. From example-org/cromford#1453's own event log:
#
#   14:27:13  #1441 (ticket/bh-1385 -> main) merged   cromford[bot]
#   14:27:15  base_ref_deleted on #1453               cromford[bot]
#   14:27:16  closed on #1453                         (GitHub's auto-close)
#   14:48:57  reopened + base_ref_changed             operator, by hand
#
# WHAT THIS SUITE PINS. Before the DELETE the lib lists
# `pulls?state=open&base=<ref>`; every child it finds is PATCHed to the merged
# PR's OWN base first, and only then is the ref deleted. Anything that leaves
# the list unproven — a non-200, a body that is not a JSON array, a full page of
# 100, a PATCH that was refused, a base ref that did not read — KEEPS the
# branch and says so in one log line. An empty list deletes exactly as it did
# before this shipped. The merge verdict is never touched in any arm.
#
# Assertions are on artifacts: the rc, the stub gh's call log (including the
# ORDER of the PATCH and the DELETE) and the pipeline log. No network, no real
# token, no clock, no real sleep.
# Run from anywhere: bash tests/merge-branch-delete-children.bh-1483-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to read the children list"; exit 1; }
# A real credential in the runner's environment must never reach a fixture or a
# rung, and HARNESS_ENV_DIR goes with it: bin/lib/env-path.sh honours it FIRST,
# so a pool box's value would point the admin rung at the live env bundle.
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR
ETC_HARNESS_ENV="$T/no-such-etc"; export ETC_HARNESS_ENV

SLUG="example-org/project-4"
REF="ticket/bh-1385"          # the incident's own head ref: it has a slash
ENC="ticket%2Fbh-1385"        # …so the query value is percent-encoded
PBASE="main"                  # the merged PR's OWN base — where children go
RSHA="1111bbbb1111"
MSHA="9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f"

# ── the stub gh ──────────────────────────────────────────────────────────────
# Six calls matter and each has its own fixture file, so a case says exactly what
# every leg answers without ordering anything: `repo` (GET repos/<slug>), `pull`
# (GET repos/<slug>/pulls/<n>), `children` (GET repos/<slug>/pulls?state=open&…),
# `put` (the merge PUT), `patch` (the child retarget) and `del` (the ref DELETE).
# The `children` and `patch` arms come FIRST: the children query is
# `…/pulls?state=open…` and the retarget is `-X PATCH …/pulls/<n>`, and a looser
# pull arm placed above them would serve both the pull-object fixture.
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
  *"-X PATCH repos/"*"/pulls/"*)  KIND=patch ;;
  *"api -i repos/"*"/pulls?"*)    KIND=children ;;
  *"-X PUT repos/"*"/merge"*)     KIND=put ;;
  *"-X DELETE repos/"*"/git/refs/"*) KIND=del ;;
  *"api -i repos/"*"/pulls/"*)    KIND=pull ;;
  *"api -i repos/"*)              KIND=repo ;;
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
for L in gh-pr-merge.sh gh-pr-create.sh env-path.sh train-shape.sh; do
  cp "$DIR/bin/lib/$L" "$HARNESS/bin/lib/" 2>/dev/null || {
    echo "FAIL: bin/lib/$L does not exist — the REST merge ladder has not been built"; exit 1; }
done

new_case() { CASE="$T/case-$1"; export CASE; scratch_rm "$CASE"; mkdir -p "$CASE"; : > "$CASE/gh-calls.log"; }
resp() { printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$2" "$3" > "$CASE/$1"; }
countof() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
ncalls() { countof "$1" "$CASE/gh-calls.log"; }
calls()  { cat "$CASE/gh-calls.log" 2>/dev/null; }
plog()   { cat "$CASE/pipeline.log" 2>/dev/null; }
# The 1-based line number of the FIRST call that matches, or nothing. Ordering
# is the whole ticket, so it is asserted on the log the stub actually wrote.
lineof() { grep -n -- "$1" "$CASE/gh-calls.log" 2>/dev/null | head -n 1 | cut -d: -f1; }

# The repo answers "squash refused, merge commits allowed", which decides the
# method on rule 1 and spends no train read — so every call in the log below
# belongs to the delete path this suite is about.
REPO='{"full_name":"example-org/project-4","allow_squash_merge":false,"allow_merge_commit":true,"allow_rebase_merge":false}'
PULL="{\"number\":1441,\"merged\":true,\"head\":{\"ref\":\"$REF\",\"repo\":{\"full_name\":\"$SLUG\"}},\"base\":{\"ref\":\"$PBASE\"}}"
PULL_NO_BASE="{\"number\":1441,\"merged\":true,\"head\":{\"ref\":\"$REF\",\"repo\":{\"full_name\":\"$SLUG\"}}}"
PULL_FORK="{\"number\":1441,\"merged\":true,\"head\":{\"ref\":\"$REF\",\"repo\":{\"full_name\":\"someone/project-4-fork\"}},\"base\":{\"ref\":\"$PBASE\"}}"
ONE_CHILD='[{"number":1453,"base":{"ref":"ticket/bh-1385"}}]'
TWO_CHILDREN='[{"number":1453},{"number":1460}]'
FULL_PAGE=$(jq -cn '[range(100)|{number:(2000+.)}]')

# The merged PR, with the branch delete asked for, in a subshell so nothing the
# lib sources leaks between cases.
merge() { # merge <pr-number>
  ( . "$HARNESS/bin/lib/gh-pr-merge.sh"
    gh_pr_merge_rest "$SLUG" "$1" "$RSHA" "$CASE/gh-stderr.log" "$CASE/pipeline.log" "bh-1483 #$1" 1
    printf '\nRC=%s\n' "$?" )
}
rcof() { sed -n 's/^RC=//p' <<<"$1"; }
# The delete alone, for the rc the ticket's test (c) asks for.
del_rc() { # del_rc <pr-number>
  ( . "$HARNESS/bin/lib/gh-pr-merge.sh"
    _gpm_delete_branch "$SLUG" "$1" "" "$CASE/pipeline.log" "bh-1483 #$1"
    printf '%s' "$?" ) 2>/dev/null
}

# ══ 1. ONE OPEN CHILD: retargeted FIRST, then the branch is deleted ══════════
new_case one-child
resp repo     '200 OK' "$REPO"
resp put      '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp pull     '200 OK' "$PULL"
resp children '200 OK' "$ONE_CHILD"
resp patch    '200 OK' '{"number":1453,"base":{"ref":"main"}}'
resp del      '204 No Content' ''
OUT=$(merge 1441)
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 1: the merge must rc 0, got $(rcof "$OUT") — log: $(plog)"
grep -q -- "api -i repos/$SLUG/pulls?state=open&base=$ENC" "$CASE/gh-calls.log" \
  && ok || bad "block 1: the open children must be listed with the ref URL-encoded, got: $(calls)"
grep -q -- "-X PATCH repos/$SLUG/pulls/1453" "$CASE/gh-calls.log" \
  && ok || bad "block 1: the stacked child must be retargeted over REST, got: $(calls)"
grep -q -- "-f base=$PBASE" "$CASE/gh-calls.log" \
  && ok || bad "block 1: the child must be retargeted to the MERGED PR's own base, got: $(calls)"
LP=$(lineof "-X PATCH repos/$SLUG/pulls/1453"); LD=$(lineof '-X DELETE')
{ [ -n "$LP" ] && [ -n "$LD" ] && [ "$LP" -lt "$LD" ]; } \
  && ok || bad "block 1: the PATCH must be sent BEFORE the DELETE (patch line '$LP', delete line '$LD'): $(calls)"
[ "$(ncalls "-X DELETE repos/$SLUG/git/refs/heads/$REF")" = 1 ] \
  && ok || bad "block 1: exactly one DELETE, naming the merged head ref, got: $(calls)"
grep -q '1453' "$CASE/pipeline.log" \
  && ok || bad "block 1: the retarget must be logged by PR number, never a silent skip, got: $(plog)"

# 1b. TWO children: two PATCHes, two log lines, one DELETE.
new_case two-children
resp repo     '200 OK' "$REPO"
resp put      '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp pull     '200 OK' "$PULL"
resp children '200 OK' "$TWO_CHILDREN"
resp patch    '200 OK' '{"number":0}'
resp del      '204 No Content' ''
OUT=$(merge 1441)
[ "$(ncalls '-X PATCH')" = 2 ] && ok || bad "block 1b: both children must be retargeted, got $(ncalls '-X PATCH'): $(calls)"
{ grep -q "$SLUG#1453" "$CASE/pipeline.log" && grep -q "$SLUG#1460" "$CASE/pipeline.log"; } \
  && ok || bad "block 1b: one log line PER retargeted child, got: $(plog)"
{ [ "$(ncalls '-X DELETE')" = 1 ] && [ "$(rcof "$OUT")" = 0 ]; } \
  && ok || bad "block 1b: exactly one DELETE and rc 0, got $(ncalls '-X DELETE') / $(rcof "$OUT"): $(calls)"

# ══ 2. NO children: the delete is byte-for-byte what it was ══════════════════
new_case no-children
resp repo     '200 OK' "$REPO"
resp put      '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp pull     '200 OK' "$PULL"
resp children '200 OK' '[]'
resp del      '204 No Content' ''
OUT=$(merge 1441)
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 2: the merge must rc 0, got $(rcof "$OUT") — log: $(plog)"
[ "$(ncalls "-X DELETE repos/$SLUG/git/refs/heads/$REF")" = 1 ] \
  && ok || bad "block 2: an empty list deletes the ref exactly as before, got: $(calls)"
[ "$(ncalls '-X PATCH')" = 0 ] && ok || bad "block 2: nothing to retarget means no PATCH, got: $(calls)"
grep -q "deleted the merged branch $REF" "$CASE/pipeline.log" \
  && ok || bad "block 2: the delete line is unchanged, got: $(plog)"

# 2b. A branch whose name merely has the merged ref as a PREFIX is NOT a child.
# GitHub's `base=` filter is exact, so the answer is `[]` and the DELETE fires:
# the lib must never do prefix matching of its own over branch names.
new_case prefix-only
resp repo     '200 OK' "$REPO"
resp put      '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp pull     '200 OK' "$PULL"
resp children '200 OK' '[]'
resp del      '204 No Content' ''
merge 1441 >/dev/null
{ [ "$(ncalls "-X DELETE repos/$SLUG/git/refs/heads/$REF")" = 1 ] \
  && [ "$(ncalls "$REF-followup")" = 0 ]; } \
  && ok || bad "block 2b: an exact-base answer of [] must still delete, and nothing may go looking for $REF-followup: $(calls)"

# ══ 3. THE LIST DID NOT ANSWER → the branch is KEPT (fail closed) ════════════
new_case list-fails
resp repo     '200 OK' "$REPO"
resp put      '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp pull     '200 OK' "$PULL"
resp children '500 Internal Server Error' '{"message":"boom"}'
resp del      '204 No Content' ''
OUT=$(merge 1441)
[ "$(ncalls '-X DELETE')" = 0 ] \
  && ok || bad "block 3: a list read that did not answer is NOT 'no children' — the ref must stay, got: $(calls)"
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 3: a withheld delete must NOT change the merge verdict, got rc $(rcof "$OUT")"
NL=$(grep 'NOT deleted' "$CASE/pipeline.log")
{ grep -qF "$REF" <<<"$NL" && grep -q '500' <<<"$NL"; } \
  && ok || bad "block 3: one line must name the ref kept and the status that kept it, got: $(plog)"
[ "$(del_rc 1441)" != 0 ] \
  && ok || bad "block 3: _gpm_delete_branch itself must answer non-zero when it withheld the delete"

# 3b. A 200 whose body is not a JSON array is the same case, never "none".
new_case list-not-array
resp repo     '200 OK' "$REPO"
resp put      '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp pull     '200 OK' "$PULL"
resp children '200 OK' '{"message":"Moved Permanently"}'
resp del      '204 No Content' ''
OUT=$(merge 1441)
{ [ "$(ncalls '-X DELETE')" = 0 ] && [ "$(rcof "$OUT")" = 0 ] && grep -q 'NOT deleted' "$CASE/pipeline.log"; } \
  && ok || bad "block 3b: a 200 that is not an array must keep the ref and log one line, got: $(calls) / $(plog)"

# 3c. A FULL page of 100 is "there may be more", not a complete list. _gpc_split
# drops the Link header, so a second page cannot be proven absent.
new_case list-full-page
resp repo     '200 OK' "$REPO"
resp put      '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp pull     '200 OK' "$PULL"
resp children '200 OK' "$FULL_PAGE"
resp patch    '200 OK' '{"number":0}'
resp del      '204 No Content' ''
OUT=$(merge 1441)
{ [ "$(ncalls '-X DELETE')" = 0 ] && [ "$(ncalls '-X PATCH')" = 0 ]; } \
  && ok || bad "block 3c: a capped page is incomplete — no PATCH, no DELETE, got: $(calls)"
grep -qi 'full page' "$CASE/pipeline.log" \
  && ok || bad "block 3c: the line must say the page came back full, got: $(plog)"
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 3c: the merge verdict is untouched, got rc $(rcof "$OUT")"

# ══ 4. A REFUSED RETARGET keeps the branch, and names the child ══════════════
new_case patch-refused
resp repo     '200 OK' "$REPO"
resp put      '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp pull     '200 OK' "$PULL"
resp children '200 OK' "$ONE_CHILD"
resp patch    '422 Unprocessable Entity' '{"message":"Base branch cannot be modified"}'
resp del      '204 No Content' ''
OUT=$(merge 1441)
[ "$(ncalls '-X DELETE')" = 0 ] \
  && ok || bad "block 4: a child that could not be retargeted must not be closed by our delete, got: $(calls)"
grep -q '1453' "$CASE/pipeline.log" \
  && ok || bad "block 4: the line must name the child still based on the ref, got: $(plog)"
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 4: the merge verdict is untouched, got rc $(rcof "$OUT")"

# ══ 5. THE MERGED PR'S OWN BASE DID NOT READ → nowhere to retarget to ════════
new_case base-unreadable
resp repo     '200 OK' "$REPO"
resp put      '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp pull     '200 OK' "$PULL_NO_BASE"
resp del      '204 No Content' ''
OUT=$(merge 1441)
{ [ "$(ncalls '/pulls?state=open')" = 0 ] && [ "$(ncalls '-X DELETE')" = 0 ]; } \
  && ok || bad "block 5: with no base to retarget to, the ref stays and nothing is listed, got: $(calls)"
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 5: the merge verdict is untouched, got rc $(rcof "$OUT")"

# ══ 6. A FORK HEAD returns before the list — today's behaviour, unchanged ════
new_case fork-head
resp repo     '200 OK' "$REPO"
resp put      '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp pull     '200 OK' "$PULL_FORK"
resp del      '204 No Content' ''
OUT=$(merge 1441)
{ [ "$(ncalls '/pulls?state=open')" = 0 ] && [ "$(ncalls '-X DELETE')" = 0 ] && [ "$(rcof "$OUT")" = 0 ]; } \
  && ok || bad "block 6: a fork head spends no list call and deletes nothing, got: $(calls)"

# ══ 7. NO TOKEN VALUE may reach any artifact ════════════════════════════════
new_case no-leak
resp repo     '200 OK' "$REPO"
resp put      '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp pull     '200 OK' "$PULL"
resp children '200 OK' "$ONE_CHILD"
resp patch    '200 OK' '{"number":1453}'
resp del      '204 No Content' ''
OUT=$( GH_TOKEN=ghp_pat_FIXTURE; export GH_TOKEN; merge 1441 )
[ -z "$(grep -rlE 'ghp_pat_FIXTURE' "$CASE" 2>/dev/null | tr '\n' ' ')" ] \
  && ok || bad "block 7: a token VALUE reached a log"
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 7: the merge on a held identity must rc 0, got $(rcof "$OUT")"

# ══ 8. MUTATION CHECK (D1) — drop the child lookup and block 1 goes red ═════
# The lookup is redefined away AFTER the lib is sourced, which is exactly the
# pre-BH-1483 code path: no list, no PATCH, straight to the DELETE. If block 1's
# assertions still held here they would be proving nothing.
new_case mutation
resp repo     '200 OK' "$REPO"
resp put      '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
resp pull     '200 OK' "$PULL"
resp children '200 OK' "$ONE_CHILD"
resp patch    '200 OK' '{"number":1453}'
resp del      '204 No Content' ''
MOUT=$( . "$HARNESS/bin/lib/gh-pr-merge.sh"
        _gpm_open_children() { return 0; }
        gh_pr_merge_rest "$SLUG" 1441 "$RSHA" "$CASE/gh-stderr.log" "$CASE/pipeline.log" mut 1
        printf '\nRC=%s\n' "$?" )
{ [ "$(ncalls '-X PATCH')" = 0 ] && [ "$(ncalls '-X DELETE')" = 1 ]; } \
  && ok || bad "block 8: with the child lookup dropped the lib must do what it did BEFORE this fix (no PATCH, a DELETE), got: $(calls)"
[ "$(rcof "$MOUT")" = 0 ] \
  && ok || bad "block 8: the mutated lib still merges — the mutation is about the delete, got rc $(rcof "$MOUT")"

echo "merge-branch-delete-children.bh-1483-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
