#!/bin/bash
# tests/merge-method-rungs.bh-1428-test.sh — THE THREE NOTES FROM THE REVIEW OF
# #1422 (BH-1313 shipped the merge method; this is what that review asked for).
#
# 1. A NON-200 SETTINGS READ MUST NOT BE CACHED. `_gpm_method` cached whatever
#    the FIRST identity's `GET repos/<slug>` answered. A rate-limited (403/429)
#    or blind (404) identity therefore pinned `squash` for the whole process, the
#    next identity's PUT 405-parked on a merge-commit-only repo, and two
#    conductor ticks later the wave was BLOCKED_HUMAN. Only a 200 is cached now,
#    and each rung reads the settings with its OWN identity before its PUT.
# 2. THE TRAIN RULE MISSED bin/batch-resolve.sh's SHAPE. Its trains live on
#    `batch/<project>/…` branches with `batch(<project>): land N approved
#    siblings as one train` titles — the two spellings bin/test-impact.sh
#    already recognised. There is now ONE recogniser, bin/lib/train-shape.sh,
#    and both call it.
# 3. bin/review-prs.sh AND bin/run-build.sh still sent `--squash`. cromford
#    has no .mergify.yml, so the conductor-only gate does not hold those PRs:
#    every APPROVE + tier-1 external PR and every tier-1 build merge 405'd there,
#    self-healed later through the box queue, and logged nothing.
#
# Both production blocks are extracted VERBATIM by their own `# >>>` markers and
# RUN, the way tests/block-gate-lanes-test.sh drives them, so deleting a marker
# or the flag fails here rather than passing.
#
# Assertions are on artifacts: the rc, the stub gh's call log, the lane log.
# No network, no real token, no clock, no real sleep.
# Run from anywhere: bash tests/merge-method-rungs.bh-1428-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# THE PIPELINE AS ONE TEXT (BH-478). bin/run-build.sh is being split into stage
# modules under bin/lib/rb/, so a suite that reads the driver RAW sees whatever
# half of the split has landed — tests/rb-modules-source-test.sh is the guard
# that says so. rb_all flattens every moved body back to its call site, exactly
# as tests/conductor-owns-merges-test.sh does for the same block.
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR
ETC_HARNESS_ENV="$T/no-such-etc"; export ETC_HARNESS_ENV

SLUG="example-org/cromford"
RSHA="1111bbbb1111"
MSHA="9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f"
RL='API rate limit already exceeded for installation ID 161623167'

# ── the stub gh ──────────────────────────────────────────────────────────────
# Fixtures are per CALL KIND and per IDENTITY WORD, so a case says "this token
# cannot read the settings and that one can" without ordering anything.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
W=none
case "${GH_TOKEN:-}" in
  ghp_pat_FIXTURE)   W=pat ;;
  ghp_admin_FIXTURE) W=admin ;;
  "")                W=none ;;
  *)                 W=other ;;
esac
printf 'token=%s %s\n' "$W" "$*" >> "$CASE/gh-calls.log"
case "$*" in
  *"pr merge"*)      touch "$CASE/merged"; exit 0 ;;
  *"--json state"*)  [ -f "$CASE/merged" ] && echo MERGED || echo OPEN; exit 0 ;;
  *"pr view"*)       [ -f "$CASE/merged" ] && echo '{"state":"MERGED"}' || echo '{"state":"OPEN"}'; exit 0 ;;
  *"pr comment"*|*"issue "*) exit 0 ;;
esac
KIND=""
case "$*" in
  *"-X PUT repos/"*"/merge"*)  KIND=put ;;
  *"api -i repos/"*"/pulls/"*) KIND=pull ;;
  *"api -i repos/"*)           KIND=repo ;;
esac
[ -n "$KIND" ] || { echo "stub gh: unexpected call: $*" >&2; exit 1; }
for F in "$CASE/$KIND.$W" "$CASE/$KIND"; do [ -f "$F" ] && { cat "$F"; exit 0; }; done
echo "stub gh: no fixture for $KIND (token=$W)" >&2
exit 1
STUB
chmod +x "$T/bin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"; chmod +x "$T/bin/sleep"
PATH="$T/bin:$PATH"

HARNESS="$T/h"; export HARNESS
mkdir -p "$HARNESS/bin/lib" "$HARNESS/flags" "$HARNESS/logs" "$HARNESS/env" "$T/envdir"
for L in gh-pr-merge.sh gh-pr-create.sh env-path.sh; do
  cp "$DIR/bin/lib/$L" "$HARNESS/bin/lib/" 2>/dev/null || {
    echo "FAIL: bin/lib/$L does not exist"; exit 1; }
done
# The train recogniser is OPTIONAL to the ladder (without it a PR is simply not
# a train), so its absence is a FAILED ASSERTION below, never a dead suite.
cp "$DIR/bin/lib/train-shape.sh" "$HARNESS/bin/lib/" 2>/dev/null || true

new_case() { CASE="$T/case-$1"; export CASE; scratch_rm "$CASE"; mkdir -p "$CASE"; : > "$CASE/gh-calls.log"; }
resp() { printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$2" "$3" > "$CASE/$1"; }
countof() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
ncalls() { countof "$1" "$CASE/gh-calls.log"; }
nrepo()  { countof "api -i repos/$SLUG$" "$CASE/gh-calls.log"; }
calls()  { cat "$CASE/gh-calls.log" 2>/dev/null; }
plog()   { cat "$CASE/pipeline.log" 2>/dev/null; }
methods() { grep -o -- '-f merge_method=[a-z]*' "$CASE/gh-calls.log" 2>/dev/null | sed 's/.*=//'; }
admin_env() { printf 'export GH_ADMIN_TOKEN="ghp_admin_FIXTURE"\n' > "$T/envdir/github-admin.env"; }
no_admin()  { rm -f "$T/envdir/github-admin.env"; }

REPO_MERGE_ONLY='{"allow_squash_merge":false,"allow_merge_commit":true,"allow_rebase_merge":false}'
REPO_ALL='{"allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":true}'

merge() { # merge <pr-number> <sha>
  ( . "$HARNESS/bin/lib/gh-pr-merge.sh"
    gh_pr_merge_rest "$SLUG" "$1" "${2:-}" "$CASE/gh-stderr.log" "$CASE/pipeline.log" "m #$1" 0
    printf '\nRC=%s\n' "$?" )
}
rcof() { sed -n 's/^RC=//p' <<<"$1"; }

# ══ 1. A CAPPED IDENTITY MUST NOT PIN squash FOR THE NEXT ONE ═══════════════
# The incident shape: identity 1 cannot read the settings AND cannot merge;
# identity 2 can do both, and the repo refuses squash.
new_case rung-reread
admin_env
resp repo.pat   '429 Too Many Requests' "{\"message\":\"$RL\"}"
resp put.pat    '429 Too Many Requests' "{\"message\":\"$RL\"}"
resp repo.admin '200 OK' "$REPO_MERGE_ONLY"
resp put.admin  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
OUT=$( GH_TOKEN=ghp_pat_FIXTURE; HARNESS_ENV_DIR="$T/envdir"; export GH_TOKEN HARNESS_ENV_DIR
       merge 1428 "$RSHA" )
no_admin
[ "$(rcof "$OUT")" = 0 ] && ok || bad "block 1: the admin rung must merge, got rc $(rcof "$OUT") — log: $(plog)"
[ "$(grep -c '^token=admin .*merge_method=merge' "$CASE/gh-calls.log")" = 1 ] \
  && ok || bad "block 1: the SECOND identity's PUT must carry merge_method=merge, got: $(calls)"
[ "$(nrepo)" = 2 ] \
  && ok || bad "block 1: each identity must read the settings with its OWN token — expected 2 reads, got $(nrepo): $(calls)"
grep -q '^token=admin api -i repos/example-org/cromford$' "$CASE/gh-calls.log" \
  && ok || bad "block 1: the admin rung's settings read must go out on the admin token, got: $(calls)"

# ══ 2. every identity unread → today's squash, and the log says so ══════════
new_case rung-all-unread
admin_env
resp repo '429 Too Many Requests' "{\"message\":\"$RL\"}"
resp put  '403 Forbidden' "{\"message\":\"$RL\"}"
OUT=$( GH_TOKEN=ghp_pat_FIXTURE; HARNESS_ENV_DIR="$T/envdir"; export GH_TOKEN HARNESS_ENV_DIR
       merge 1428 "$RSHA" )
no_admin
[ "$(rcof "$OUT")" = 2 ] && ok || bad "block 2: no verdict must rc 2, got $(rcof "$OUT")"
[ "$(methods | sort -u | tr '\n' ' ')" = "squash " ] \
  && ok || bad "block 2: with the settings unread every PUT keeps today's squash, got '$(methods | tr '\n' ' ')'"
[ "$(countof 'could not be read' "$CASE/pipeline.log")" = 2 ] \
  && ok || bad "block 2: each rung's unread settings is its own line, got: $(plog)"

# ══ 3. a 200 IS still cached — one read for two merges in one process ═══════
new_case cache-200
resp repo '200 OK' "$REPO_MERGE_ONLY"
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
( . "$HARNESS/bin/lib/gh-pr-merge.sh"
  gh_pr_merge_rest "$SLUG" 1428 "$RSHA" "$CASE/e.log" "$CASE/pipeline.log" a 0 >/dev/null
  gh_pr_merge_rest "$SLUG" 1429 "$RSHA" "$CASE/e.log" "$CASE/pipeline.log" b 0 >/dev/null ) >/dev/null 2>&1
[ "$(nrepo)" = 1 ] \
  && ok || bad "block 3: a 200 must still be cached for the process, got $(nrepo) reads: $(calls)"
[ "$(methods | sort -u | tr '\n' ' ')" = "merge " ] \
  && ok || bad "block 3: both merges must use the cached method, got '$(methods | tr '\n' ' ')'"

# ══ 4. a NON-200 is never cached — two merges, two reads ════════════════════
new_case cache-never-on-failure
resp repo '404 Not Found' '{"message":"Not Found"}'
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
( . "$HARNESS/bin/lib/gh-pr-merge.sh"
  gh_pr_merge_rest "$SLUG" 1428 "$RSHA" "$CASE/e.log" "$CASE/pipeline.log" a 0 >/dev/null
  gh_pr_merge_rest "$SLUG" 1429 "$RSHA" "$CASE/e.log" "$CASE/pipeline.log" b 0 >/dev/null ) >/dev/null 2>&1
[ "$(nrepo)" = 2 ] \
  && ok || bad "block 4: a failed settings read must NEVER be cached — expected 2 reads, got $(nrepo): $(calls)"

# ══ 5-8. THE TRAIN SHAPES, including bin/batch-resolve.sh's ════════════════
train_case() { # train_case <name> <head-ref> <title> -> the method the PUT used
  new_case "train-$1"
  resp repo '200 OK' "$REPO_ALL"
  resp pull '200 OK' "$(jq -nc --arg r "$2" --arg t "$3" '{title:$t,head:{ref:$r}}')"
  resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
  merge 1428 "$RSHA" >/dev/null
  methods | head -n 1
}
M=$(train_case batch-branch "batch/demo-os/20260922T041000Z-1-1" "batch(demo-os): land 4 approved siblings as one train")
[ "$M" = merge ] && ok || bad "block 5: a batch-resolve train (batch/ branch) must merge by merge commit, got '$M'"
M=$(train_case batch-title "feature/whatever" "batch(demo-os): land 4 approved siblings as one train")
[ "$M" = merge ] && ok || bad "block 6: a 'batch(' title must merge by merge commit, got '$M'"
M=$(train_case mq-title "queue/union" "merge train: 1 approved PRs")
[ "$M" = merge ] && ok || bad "block 7: BH-1313's 'merge train:' title must still be a train, got '$M'"
M=$(train_case mq-branch "train/tier2-20260922" "land the tier-2 queue")
[ "$M" = merge ] && ok || bad "block 7: BH-1313's train/ head ref must still be a train, got '$M'"
M=$(train_case plain "ticket/bh-1428" "BH-1428: the three notes")
[ "$M" = squash ] && ok || bad "block 8: an ordinary PR must stay squash, got '$M'"

# ══ 9. ONE recogniser, and it matches by PREFIX, not substring ══════════════
is_train() { ( . "$DIR/bin/lib/train-shape.sh" 2>/dev/null || { echo "no-lib"; exit 0; }
              train_is_train "$1" "$2" && echo yes || echo no ) }
[ "$(is_train 'batch(demo-os): land 4 approved siblings as one train' '')" = yes ] && ok \
  || bad "block 9: a batch( title is a train"
[ "$(is_train 'merge train: 1 approved PRs' '')" = yes ] && ok || bad "block 9: a merge train title is a train"
[ "$(is_train 'MERGE TRAIN: shouty' '')" = yes ] && ok || bad "block 9: the title test is case-insensitive"
[ "$(is_train '' 'batch/demo-os/20260922T041000Z')" = yes ] && ok || bad "block 9: a batch/ head ref is a train"
[ "$(is_train '' 'train/tier2')" = yes ] && ok || bad "block 9: a train/ head ref is a train"
[ "$(is_train 'Revert "merge train: 1 approved PRs"' '')" = no ] && ok \
  || bad "block 9: a REVERT of a train is not a train — the title test is a PREFIX match"
[ "$(is_train 'retrain: the classifier' '')" = no ] && ok || bad "block 9: 'retrain:' is not a train"
[ "$(is_train '' 'feature/train-schedule')" = no ] && ok || bad "block 9: 'train' inside a ref is not a train"
[ "$(is_train 'BH-1428: the three notes' 'ticket/bh-1428')" = no ] && ok || bad "block 9: an ordinary PR is not a train"

# ══ 10. bin/test-impact.sh calls the SAME recogniser ════════════════════════
new_case impact
IMP=$( cd "$DIR" && TI_EVENT=pull_request TI_BASE= TI_HEAD=HEAD \
        TI_PR_TITLE='batch(demo-os): land 4 approved siblings as one train' TI_PR_LABELS= \
        bash bin/test-impact.sh ci-select 2>&1 >/dev/null )
grep -q 'merge train' <<<"$IMP" \
  && ok || bad "block 10: test-impact must still call a batch( title a train (through the shared recogniser), got: $IMP"

# ══ 11-13. THE TWO POOL-SIDE MERGES, extracted by their markers and RUN ═════
# A scratch pool tree: the real blocks, a stub gh that records every merge verb,
# and the settings fixture that decides the flag.
POOL="$T/pool"
pool_tree() { # pool_tree <with-lib|no-lib>
  scratch_rm "$POOL"
  mkdir -p "$POOL/bin/lib" "$POOL/logs" "$POOL/state" "$POOL/flags" "$POOL/builds/gate" "$POOL/env"
  if [ "$1" = with-lib ]; then
    cp "$DIR/bin/lib/gh-pr-merge.sh" "$DIR/bin/lib/gh-pr-create.sh" \
       "$DIR/bin/lib/env-path.sh" "$POOL/bin/lib/"
    cp "$DIR/bin/lib/train-shape.sh" "$POOL/bin/lib/" 2>/dev/null || true
  fi
  local s
  for s in deploy-request.sh beat.sh lander.sh codegraph-ensure.sh fleet-conf.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$POOL/bin/$s"; chmod +x "$POOL/bin/$s"; done
  printf 'plan\n' > "$POOL/builds/gate/plan.md"
}
# The review-prs merge step.
run_review_merge() { # run_review_merge -> nothing; the stub log carries the verb
  awk '/^# >>> review-prs merge/{f=1;next} /^# <<< review-prs merge/{exit} f' \
    "$DIR/bin/review-prs.sh" > "$CASE/rmerge.sh"
  [ -s "$CASE/rmerge.sh" ] || { bad "the review-prs merge markers are missing"; return 1; }
  ( export PATH="$T/bin:$PATH" HARNESS="$POOL" CASE="$CASE" PROJECT=demo-os SLUG="$SLUG" \
           LOG="$CASE/pr-reviews.log"
    bash -c 'set -uo pipefail
      STAMP() { echo TS; }
      rp_prov_is_claude() { [ "${1:-}" = claude ]; }
      mc_queue_conductor_only() { return 1; }
      mc_pr_queued() { return 1; }
      bg_review_hold() { return 1; }
      hold_main_red() { return 1; }
      hold_automerge_disabled() { return 1; }
      bg_block_hold() { return 1; }
      . "$0"
      # TEST-CHANGE (BH-1285): merge_step reads .base.ref before the direct
      # merge (a stacked PR is held). Answer main for that read only; every
      # other read stays unanswered, exactly as it was with no reader here.
      mc_pr_view() { [ "${2:-}" = .base.ref ] && { echo main; return 0; }; return 75; }
      merge_step 41 '"$RSHA"' claude' "$CASE/rmerge.sh" ) >/dev/null 2>>"$CASE/rp-err.log"
}
new_case review-prs-merge
pool_tree with-lib
resp repo '200 OK' "$REPO_MERGE_ONLY"
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
run_review_merge
grep -q 'pr merge 41 .*--merge' "$CASE/gh-calls.log" \
  && ok || bad "block 11: review-prs on a squash-refusing repo must merge with --merge, got: $(calls) err=$(cat "$CASE/rp-err.log" 2>/dev/null | tail -3)"
grep -q 'pr merge 41 .*--squash' "$CASE/gh-calls.log" \
  && bad "block 11: --squash must never go to a repo that refuses it: $(calls)" || ok
new_case review-prs-no-lib
pool_tree no-lib
run_review_merge
grep -q 'pr merge 41 .*--squash' "$CASE/gh-calls.log" \
  && ok || bad "block 13: without the lib review-prs keeps today's --squash, got: $(calls)"

# The run-build tier-1 merge gate.
run_tier1() {
  awk '/^# >>> tier-1 merge gate/{f=1;next} /^# <<< tier-1 merge gate/{exit} f' \
    "$RB_ALL" > "$CASE/gate.sh"
  [ -s "$CASE/gate.sh" ] || { bad "the tier-1 merge gate markers are missing"; return 1; }
  : > "$POOL/builds/gate/pipeline.log"
  printf 'VERDICT: APPROVE\n' > "$POOL/builds/gate/review.md"
  ( export PATH="$T/bin:$PATH" HARNESS="$POOL" CASE="$CASE" BUILD="$POOL/builds/gate" \
           ALERTS="$POOL/logs/ALERTS.log" PROJECT=demo-os KEY=BH-1428 SLUG="$SLUG" TIER=1 \
           PR_URL="https://github.com/$SLUG/pull/41" QA_NOTE="" MIG_NOTE="" REBASE_NOTE="" \
           CLOSES_LINE="Closes #41" HEADBOUND_SHA="$RSHA" BUILDER_NO_MERGE=
    bash -c 'set -uo pipefail
      STAMP() { echo TS; }
      RESULT() { echo "$*" > '"$CASE"'/RESULT; }
      BB() { :; }
      CLOSE_ISSUE_AFTER_MERGE() { :; }
      mc_queue_conductor_only() { return 1; }
      mc_pr_queued() { return 1; }
      main_red_hold() { return 1; }
      [ -r "$HARNESS/bin/lib/block-gate.sh" ] && . "$HARNESS/bin/lib/block-gate.sh"
      . "$0"' "$CASE/gate.sh" ) >/dev/null 2>>"$CASE/rb-err.log"
}
new_case tier1-merge
pool_tree with-lib
resp repo '200 OK' "$REPO_MERGE_ONLY"
resp put  '200 OK' "{\"sha\":\"$MSHA\",\"merged\":true}"
run_tier1
grep -q 'pr merge https://github.com/.*--merge' "$CASE/gh-calls.log" \
  && ok || bad "block 12: a tier-1 merge on a squash-refusing repo must send --merge, got: $(calls) err=$(tail -3 "$CASE/rb-err.log" 2>/dev/null)"
grep -q 'pr merge https://github.com/.*--squash' "$CASE/gh-calls.log" \
  && bad "block 12: --squash must never go to a repo that refuses it: $(calls)" || ok
new_case tier1-no-lib
pool_tree no-lib
run_tier1
grep -q 'pr merge https://github.com/.*--squash' "$CASE/gh-calls.log" \
  && ok || bad "block 13: without the lib the tier-1 merge keeps today's --squash, got: $(calls)"

echo "merge-method-rungs.bh-1428-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
