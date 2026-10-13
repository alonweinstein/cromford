#!/bin/bash
# tests/review-record-integrity-test.sh — the posted review carries its own
# findings, and the build record has a copy BEFORE the network call.
#
# THE INCIDENT (BH-641). The conductor's head-bound re-review BLOCKed a PR. The
# comment it posted was the verdict paragraph alone — "finding #1 is a fail-open
# authz check, finding #2 weakens a test, finding #3 is scope creep" — with no
# findings in it, and the build record kept nothing at all. The review existed
# once, in a comment that had already lost it.
#
# Five sections, each driving the REAL block by its `# >>> name` markers rather
# than a paraphrase of it (docs/verification-map/README.md, driving conventions):
#   1. bin/lib/mc/classify.sh   headbound_review's done branch
#   2. bin/blocked-resolver.sh  br_rereview's post chain
#   3. bin/run-build.sh         the GUARD_SILENCED gate on the merged fix round
#   4. bin/lib/mc/rebase.sh     the re-review prompt's reject list
#   5. bin/blocked-resolver.sh  the GUARD_SILENCED gate on the fix round it
#      pushes, with origin/main already merged into the worktree as br_fix_round
#      merges it — the shape that made a "$lease"..HEAD diff answer CODE_CHANGED
#      on every park where main had moved
#
# The `gh` stub is the witness: it records the body it was handed AND whether
# the build record already held the review at the moment it was called. A poster
# that writes the record after the post reads PERSISTED=no here.
#
# Run from anywhere: tests/review-record-integrity-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-568 seam: bin/run-build.sh is being split into bin/lib/rb/<stage>.sh, so
# section 3 and the source pins below read the FLATTENED pipeline — the same
# text in the same order at every state of the split — never the driver file.
# shellcheck source=tests/lib/rb-all.sh
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all could not flatten bin/run-build.sh"; exit 1; }

HEAD_SHA=abcd1234deadbeefcafe0000111122223333
HEAD8=abcd1234
URL="https://github.com/acme/widgets/pull/7"

mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
# The witness. Records the body a poster handed us and whether the build record
# already held the review AT CALL TIME — which is the whole ordering claim.
if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then
  BODY=""; BF=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --body-file) BF="${2:-}"; shift 2 ;;
      --body)      BODY="${2:-}"; shift 2 ;;
      *)           shift ;;
    esac
  done
  if [ -n "$BF" ]; then cat "$BF" > "$GH_OUT.body"; else printf '%s\n' "$BODY" > "$GH_OUT.body"; fi
  if [ -s "$GH_REC/rereview-$GH_HEAD8.md" ] && [ -s "$GH_REC/rereview-$GH_HEAD8.json" ]; then
    echo PERSISTED=yes > "$GH_OUT.persisted"
  else
    echo PERSISTED=no > "$GH_OUT.persisted"
  fi
  exit "${GH_RC:-0}"
fi
# The same witness for the REST post bin/lib/gh-rest.sh makes (BH-783):
# `gh api -i -X POST repos/<slug>/issues/<n>/comments -F body=@<file>`.
if [ "${1:-}" = api ]; then
  BF=""
  for A in "$@"; do case "$A" in body=@*) BF="${A#body=@}" ;; esac; done
  if [ -n "$BF" ]; then
    cat "$BF" > "$GH_OUT.body"
    if [ -s "$GH_REC/rereview-$GH_HEAD8.md" ] && [ -s "$GH_REC/rereview-$GH_HEAD8.json" ]; then
      echo PERSISTED=yes > "$GH_OUT.persisted"
    else
      echo PERSISTED=no > "$GH_OUT.persisted"
    fi
    # A non-zero GH_RC answers with no status line at all, which is what a dead
    # network looks like to gh_rest: rc 75, and the caller must log it.
    [ "${GH_RC:-0}" = 0 ] || exit "${GH_RC}"
    printf 'HTTP/2.0 201 Created\r\n\r\n{"id":1}\n'
    exit 0
  fi
  # BH-784 moved the diff read onto REST too: mc_pr_diff calls
  # `gh api -i -X GET repos/<slug>/pulls/<n> -H "Accept: application/vnd.github.v3.diff"`.
  # Same body the old `gh pr diff` case below returns, through the REST
  # envelope gh_rest expects (a status line, a blank line, then the body).
  case " $* " in
    *'application/vnd.github.v3.diff'*)
      printf 'HTTP/2.0 200 OK\r\n\r\ndiff --git a/src/a.ts b/src/a.ts\n--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1 +1 @@\n-old\n+new\n'
      exit 0 ;;
  esac
  exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = diff ]; then
  printf 'diff --git a/src/a.ts b/src/a.ts\n--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1 +1 @@\n-old\n+new\n'
  exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  case " $* " in *headRefOid*) printf '%s\n' "${GH_HEAD_SHA:-}" ;; *) printf 'the PR body\n' ;; esac
  exit 0
fi
exit 0
STUB
chmod +x "$T/fakebin/gh"

# The review fixtures, in the shapes the re-review prompt elicits.
mkfix() { # mkfix <path> ; reads the review text on stdin, writes the envelope too
  cat > "$1"
  printf '{"is_error":false,"result":"review complete","duration_ms":41000}\n' > "$1.json"
}
mkfix "$T/full.md" <<'EOF'
Static review of the current diff. No build was run.

1. **[HIGH]** `src/lib/authz.ts:41` — the role check returns true when the caller id is blank
   Scenario: a request with no session posts to /api/settings and is served as an admin.
2. **[MED]** `tests/authz-test.ts:88` — the assertion was softened to `toBeTruthy()`
   Scenario: the fix round answered the first finding by weakening its own test.
3. **[LOW]** `src/ui/table.tsx:12` — a new data table ships with no sortable headers
   Scenario: the client sorts a 900-row list by hand.

Why this blocks: finding #1 is a fail-open authz check, finding #2 weakens a test, finding #3 is scope creep.

TIER: 2
VERDICT: BLOCK
EOF
# THE INCIDENT'S OWN OUT FILE: the verdict paragraph, and not one finding.
mkfix "$T/incident.md" <<'EOF'
Static review, no build run.

Why this blocks: finding #1 is a fail-open authz check, finding #2 weakens a test, finding #3 is scope creep.

VERDICT: BLOCK
EOF
mkfix "$T/approve.md" <<'EOF'
Static review of the current diff. No build was run.

Nothing to raise. The diff matches the plan and no test was weakened.

TIER: 1
VERDICT: APPROVE
EOF

# ============================================================================
# 1. bin/lib/mc/classify.sh — headbound_review's done branch
# ============================================================================
awk '/^ *# >>> rereview helpers/{f=1;next} /^ *# <<< rereview helpers/{exit} f' \
  "$DIR/bin/lib/mc/classify.sh" > "$T/mc-helpers.sh"
awk '/^ *# >>> rereview post \(/{f=1;next} /^ *# <<< rereview post/{exit} f' \
  "$DIR/bin/lib/mc/classify.sh" > "$T/mc-post.sh"
[ -s "$T/mc-post.sh" ] \
  && ok || bad "section 1: no '# >>> rereview post' block in bin/lib/mc/classify.sh — nothing to drive"
# hb_post, hb_approve_bind and hb_block_park are what that block calls (BH-764
# lifted them out of it); the REAL ones are sourced, never stubbed, so the
# persistence, transition and refusal assertions below judge production code.
[ -s "$T/mc-helpers.sh" ] \
  && ok || bad "section 1: no '# >>> rereview helpers' block in bin/lib/mc/classify.sh — the poster helpers could not be sourced"

mc_drive() { # mc_drive <tag> <verdict> <out-file>
  local tag="$1" verdict="$2" out="$3"
  export GH_OUT="$T/gh-$tag" GH_REC="$T/rec-$tag" GH_HEAD8="$HEAD8"
  mkdir -p "$GH_REC"
  ( export PATH="$T/fakebin:$PATH"
    # shellcheck source=/dev/null
    [ -r "$DIR/bin/lib/gh-rest.sh" ] && . "$DIR/bin/lib/gh-rest.sh"
    # shellcheck source=/dev/null
    [ -r "$DIR/bin/lib/review-post.sh" ] && . "$DIR/bin/lib/review-post.sh"
    mc_log()               { printf '%s\n' "$*" >> "$T/log-$tag.txt"; }
    mc_transition()        { printf '%s\n' "$*" >> "$T/tr-$tag.txt"; }
    mc_hb_refuse()         { printf 'mc_hb_refuse %s\n' "$*" >> "$T/tr-$tag.txt"; }
    mc_prov_clear()        { printf 'mc_prov_clear %s\n' "$*" >> "$T/tr-$tag.txt"; }
    mc_patch_id_remember() { return 0; }
    mc_rr_noci_why()       { printf ''; }
    # shellcheck source=/dev/null
    . "$T/mc-helpers.sh"
    v="$verdict"; outf="$out"; rec="$GH_REC"; head="$HEAD_SHA"; url="$URL"
    key="acme/widgets#7"; slug="acme/widgets"; num=7; proj=widgets
    rrwhat="Head-bound harness re-review"; mode=normal
    reviewed=0000111122223333; mstate=UNKNOWN
    # shellcheck source=/dev/null
    . "$T/mc-post.sh"
  )
}

mc_drive block-full BLOCK "$T/full.md"
[ "$(cat "$T/gh-block-full.persisted" 2>/dev/null)" = PERSISTED=yes ] \
  && ok || bad "section 1: the review and its envelope must be in the build record BEFORE gh is called (got $(cat "$T/gh-block-full.persisted" 2>/dev/null))"
[ -s "$T/rec-block-full/rereview-$HEAD8.md" ] \
  && ok || bad "section 1: \$rec/rereview-<head8>.md must exist after the run"
[ -s "$T/rec-block-full/rereview-$HEAD8.json" ] \
  && ok || bad "section 1: \$rec/rereview-<head8>.json must exist after the run"
cmp -s "$T/full.md" "$T/rec-block-full/rereview-$HEAD8.md" \
  && ok || bad "section 1: the persisted review must be the review the lane produced, byte for byte"
[ "$(awk '/findings returned,/{f=1;next} f&&/^$/{exit} f' "$T/gh-block-full.body" | wc -l)" = 3 ] \
  && ok || bad "section 1: the posted body must carry a three-line findings index (got $(awk '/findings returned,/{f=1;next} f&&/^$/{exit} f' "$T/gh-block-full.body" | wc -l))"
grep -q '3 findings returned, 3 rendered' "$T/gh-block-full.body" \
  && ok || bad "section 1: the posted body must count the findings out loud"
grep -q 'table.tsx:12' "$T/gh-block-full.body" \
  && ok || bad "section 1: finding #3 must be IN the comment — this is the incident"
grep -q 'Push fixes; the conductor reviews the next head' "$T/gh-block-full.body" \
  && ok || bad "section 1: the lane's own footer must still ride at the end of the body"
grep -q 'head-not-reapproved' "$T/tr-block-full.txt" \
  && ok || bad "section 1: the BLOCK transition must be unchanged by this fix"
grep -q 'mc_hb_refuse' "$T/tr-block-full.txt" \
  && ok || bad "section 1: the head refusal must still be recorded"

# THE REPRO. The incident's own out file: a verdict paragraph that references
# finding #3 and carries no findings at all.
mc_drive block-incident BLOCK "$T/incident.md"
# TEST CHANGED BY BH-1625, deliberately, and made STRICTER: every body now leads
# with `**Verdict:** <v>` (the verdict is what the gate acted on, and a
# PARSE_INCOMPLETE that hid it left GitHub no record of it), so the
# PARSE_INCOMPLETE line this pinned as line 1 is pinned, unchanged, as line 2
# and line 1 is pinned too.
[ "$(head -1 "$T/gh-block-incident.body")" = '**Verdict:** BLOCK' ] \
  && ok || bad "section 1 REPRO: the body leads with the verdict it failed to render around (got '$(head -1 "$T/gh-block-incident.body")')"
[ "$(sed -n 2p "$T/gh-block-incident.body")" = 'PARSE_INCOMPLETE: the verdict references finding #3 but only 0 findings could be rendered' ] \
  && ok || bad "section 1 REPRO: a verdict referencing findings the body does not carry must post PARSE_INCOMPLETE right under the verdict (got '$(sed -n 2p "$T/gh-block-incident.body")')"
[ "$(cat "$T/gh-block-incident.persisted" 2>/dev/null)" = PERSISTED=yes ] \
  && ok || bad "section 1 REPRO: the build record must hold the review before the post (got $(cat "$T/gh-block-incident.persisted" 2>/dev/null))"
grep -qx '```json' "$T/gh-block-incident.body" \
  && ok || bad "section 1 REPRO: the raw agent envelope must be fenced into the body"
grep -q 'review complete' "$T/gh-block-incident.body" \
  && ok || bad "section 1 REPRO: the fenced envelope must be the real \$out.json"

# The APPROVE twin persists and renders too.
mc_drive approve APPROVE "$T/approve.md"
[ "$(cat "$T/gh-approve.persisted" 2>/dev/null)" = PERSISTED=yes ] \
  && ok || bad "section 1: the APPROVE branch persists before it posts too (got $(cat "$T/gh-approve.persisted" 2>/dev/null))"
grep -q '0 findings returned, 0 rendered' "$T/gh-approve.body" \
  && ok || bad "section 1: an APPROVE with nothing to list says so"
grep -q 'approval rebound to this head' "$T/gh-approve.body" \
  && ok || bad "section 1: the APPROVE footer must still ride"
[ -s "$T/rec-approve/reviewed-sha" ] \
  && ok || bad "section 1: the APPROVE branch must still write reviewed-sha"

# A POST THAT DID NOT LAND IS NEVER RECORDED AS POSTED (D9).
export GH_RC=1
mc_drive ghfail BLOCK "$T/full.md"
unset GH_RC
[ -s "$T/rec-ghfail/rereview-$HEAD8.md" ] \
  && ok || bad "section 1: a failed post still leaves the findings in the build record"
grep -q 'did NOT post' "$T/log-ghfail.txt" 2>/dev/null \
  && ok || bad "section 1: a failed gh pr comment must be logged, not swallowed by || true"
grep -q "rereview-$HEAD8.md" "$T/log-ghfail.txt" 2>/dev/null \
  && ok || bad "section 1: the failed-post log line must name where the findings were kept"

# A PR WITH NO BUILD RECORD STILL GETS ITS COMMENT (#630 in reverse).
export GH_OUT="$T/gh-norec" GH_REC="$T/rec-norec" GH_HEAD8="$HEAD8"
mkdir -p "$GH_REC"
( export PATH="$T/fakebin:$PATH"
  # shellcheck source=/dev/null
  [ -r "$DIR/bin/lib/gh-rest.sh" ] && . "$DIR/bin/lib/gh-rest.sh"
  # shellcheck source=/dev/null
  [ -r "$DIR/bin/lib/review-post.sh" ] && . "$DIR/bin/lib/review-post.sh"
  mc_log() { printf '%s\n' "$*" >> "$T/log-norec.txt"; }
  mc_transition() { :; }; mc_hb_refuse() { :; }; mc_prov_clear() { :; }
  mc_patch_id_remember() { return 0; }
  mc_rr_noci_why()       { printf ''; }
  # shellcheck source=/dev/null
  . "$T/mc-helpers.sh"
  v=BLOCK; outf="$T/full.md"; rec=-; head="$HEAD_SHA"; url="$URL"
  key="acme/widgets#7"; slug="acme/widgets"; num=7; proj=widgets
  rrwhat="Head-bound harness re-review"; mode=normal
  reviewed=0000111122223333; mstate=UNKNOWN
  # shellcheck source=/dev/null
  . "$T/mc-post.sh"
) >/dev/null 2>&1
[ -s "$T/gh-norec.body" ] \
  && ok || bad "section 1: a PR with rec='-' must still get its comment — losing it to a missing record is the failure in reverse"
grep -q '3 findings returned, 3 rendered' "$T/gh-norec.body" \
  && ok || bad "section 1: the body is rendered whether or not there is a record to keep it in"

# A NAMED OUT FILE THAT IS GONE IS NOT "no review" (I2). The footer alone is
# "BLOCK. Push fixes." with no findings in it — the incident's own artifact.
mkdir -p "$T/rec-missing"
cp "$T/full.md" "$T/rec-missing/rereview-$HEAD8.md"   # an earlier tick's copy
mc_drive missing BLOCK "$T/no-such-out-file.md"
[ "$(sed -n 2p "$T/gh-missing.body" 2>/dev/null)" = 'PARSE_INCOMPLETE: the review file is empty or missing — this lane produced no review text at all' ] \
  && ok || bad "section 1: an out file that is named and unreadable must post PARSE_INCOMPLETE (under the verdict line, BH-1625), never the footer alone (got '$(sed -n 2p "$T/gh-missing.body" 2>/dev/null)')"
grep -q 'Push fixes; the conductor reviews the next head' "$T/gh-missing.body" 2>/dev/null \
  && ok || bad "section 1: the lane's footer still rides under the PARSE_INCOMPLETE body"
grep -q 'is missing or unreadable' "$T/log-missing.txt" 2>/dev/null \
  && ok || bad "section 1: a missing out file must be LOGGED, naming the file — silence is how the incident stayed invisible"
cmp -s "$T/full.md" "$T/rec-missing/rereview-$HEAD8.md" \
  && ok || bad "section 1: an unreadable out file must never overwrite the review already in the build record"

# THE ENVELOPE BESIDE A MISSING .md IS EVIDENCE, NOT NOTHING (BH-1320). The
# lane wrote <outf>.json and no <outf>.md. The stub hb_post swaps in has no
# .json sibling, so the renderer used to read the envelope from beside the STUB,
# find nothing, and post "(no raw JSON envelope was written by the review lane)"
# while the real envelope sat on disk.
printf '{"is_error":false,"result":"envelope-only-1320","duration_ms":7}\n' > "$T/gone.md.json"
rm -f "$T/gone.md"
mkdir -p "$T/rec-envonly"
cp "$T/full.md" "$T/rec-envonly/rereview-$HEAD8.md"        # an earlier tick's pair
cp "$T/full.md.json" "$T/rec-envonly/rereview-$HEAD8.json"
mc_drive envonly BLOCK "$T/gone.md"
grep -q 'envelope-only-1320' "$T/gh-envonly.body" 2>/dev/null \
  && ok || bad "section 1 BH-1320: the envelope beside a missing .md must be fenced into the posted body — dropping it is the incident"
! grep -q 'no raw JSON envelope was written' "$T/gh-envonly.body" 2>/dev/null \
  && ok || bad "section 1 BH-1320: the body must not claim there was no envelope while one sits at <outf>.json"
[ "$(sed -n 2p "$T/gh-envonly.body" 2>/dev/null)" = 'PARSE_INCOMPLETE: the review file is empty or missing — this lane produced no review text at all' ] \
  && ok || bad "section 1 BH-1320: the fail-closed line under the verdict is unchanged (got '$(sed -n 2p "$T/gh-envonly.body" 2>/dev/null)')"
grep -q 'Push fixes; the conductor reviews the next head' "$T/gh-envonly.body" 2>/dev/null \
  && ok || bad "section 1 BH-1320: the lane's footer still rides under the PARSE_INCOMPLETE body"
grep -q 'is missing or unreadable' "$T/log-envonly.txt" 2>/dev/null \
  && ok || bad "section 1 BH-1320: the missing .md must still be logged as missing or unreadable"
grep -q 'gone.md.json' "$T/log-envonly.txt" 2>/dev/null \
  && ok || bad "section 1 BH-1320: the log line must name the envelope path too, not the .md alone (got '$(cat "$T/log-envonly.txt" 2>/dev/null)')"
cmp -s "$T/full.md" "$T/rec-envonly/rereview-$HEAD8.md" \
  && ok || bad "section 1 BH-1320: an earlier tick's review in the record must not be overwritten by this path"
cmp -s "$T/full.md.json" "$T/rec-envonly/rereview-$HEAD8.json" \
  && ok || bad "section 1 BH-1320: an earlier tick's envelope in the record must not be overwritten either — the pair is never split"

# ============================================================================
# 2. bin/blocked-resolver.sh — br_rereview's post chain
# ============================================================================
awk '/^ *# >>> br rereview post/{f=1;next} /^ *# <<< br rereview post/{exit} f' \
  "$DIR/bin/blocked-resolver.sh" > "$T/br-post.sh"
[ -s "$T/br-post.sh" ] \
  && ok || bad "section 2: no '# >>> br rereview post' block in bin/blocked-resolver.sh — nothing to drive"

br_drive() { # br_drive <tag> <verdict> <fixture>
  # dtag, not tag: the block reads br_rereview's own $tag, and a test local of
  # that name would shadow it (BH-1992).
  local dtag="$1" verdict="$2" fix="$3"
  export GH_OUT="$T/gh-$dtag" GH_REC="$T/rec-$dtag" GH_HEAD8="$HEAD8" GH_HEAD_SHA="$HEAD_SHA"
  mkdir -p "$GH_REC"
  ( export PATH="$T/fakebin:$PATH"
    # shellcheck source=/dev/null
    [ -r "$DIR/bin/lib/gh-rest.sh" ] && . "$DIR/bin/lib/gh-rest.sh"
    # shellcheck source=/dev/null
    [ -r "$DIR/bin/lib/review-post.sh" ] && . "$DIR/bin/lib/review-post.sh"
    # mc_rereview writes the agent's stdout to the out file the caller handed it
    # and answers with the verdict word, exactly as the real one does.
    # RR_RC (K3) lets a drive answer with another rc; the default is 0, as before.
    mc_rereview() { cp "$fix" "${8}"; cp "$fix.json" "${8}.json" 2>/dev/null
      [ "${RR_RC:-0}" = 3 ] && head -1 "$fix" > "${8}.lanefail"
      printf '%s' "$verdict"; return "${RR_RC:-0}"; }
    mc_transition() { printf '%s\n' "$*" >> "$T/tr-$dtag.txt"; }
    mc_slug_of_url() { printf 'acme/widgets'; }
    mc_num_of_url()  { printf '7'; }
    mc_row_field()   { printf '0000111122223333'; }
    # BH-783 moved the resolver's head read onto the REST helper; the fixture
    # answers it with the same sha the gh stub used to serve.
    br_pr_field()    { printf '%s' "$GH_HEAD_SHA"; return 0; }
    br_record()      { printf '%s\n' "$*" >> "$T/rec-log-$dtag.txt"; }
    say()            { printf '%s\n' "$*" >> "$T/say-$dtag.txt"; }
    p=widgets; rkey=WI-1; url="$URL"; rec="$GH_REC"
    BR_NOVERDICT_MAX=5; n=0
    # The locals br_rereview sets above the block for the no-verdict kind.
    tag=no-verdict ctr=rereviews lfctr=lanefails nth='read 1 of 5'
    bought='after the conductor got no verdict'
    br_count() { :; }
    # shellcheck source=/dev/null
    . "$T/br-post.sh"
  ) 2> "$T/br-err-$dtag.txt"
}

br_drive br-block BLOCK "$T/full.md"
[ "$(cat "$T/gh-br-block.persisted" 2>/dev/null)" = PERSISTED=yes ] \
  && ok || bad "section 2: the resolver must persist the review before it posts (got $(cat "$T/gh-br-block.persisted" 2>/dev/null))"
[ "$(awk '/findings returned,/{f=1;next} f&&/^$/{exit} f' "$T/gh-br-block.body" | wc -l)" = 3 ] \
  && ok || bad "section 2: the resolver's BLOCK comment must carry the findings index — the fix round it triggers is briefed from this comment"
grep -q 'The resolver runs an agent fix round against these findings next' "$T/gh-br-block.body" \
  && ok || bad "section 2: the resolver's own footer must still ride"
grep -q 'head-not-reapproved' "$T/tr-br-block.txt" \
  && ok || bad "section 2: the BLOCK transition must be unchanged"
[ -s "$T/rec-br-block/rereview-$HEAD8.md" ] \
  && ok || bad "section 2: the resolver's mktemp review must be copied into the build record"

br_drive br-incident BLOCK "$T/incident.md"
[ "$(head -1 "$T/gh-br-incident.body")" = '**Verdict:** BLOCK' ] \
  && ok || bad "section 2: the resolver's body leads with the verdict (got '$(head -1 "$T/gh-br-incident.body")')"
[ "$(sed -n 2p "$T/gh-br-incident.body")" = 'PARSE_INCOMPLETE: the verdict references finding #3 but only 0 findings could be rendered' ] \
  && ok || bad "section 2: the resolver fails closed on a short findings count too (got '$(sed -n 2p "$T/gh-br-incident.body")')"

br_drive br-approve APPROVE "$T/approve.md"
[ "$(cat "$T/gh-br-approve.persisted" 2>/dev/null)" = PERSISTED=yes ] \
  && ok || bad "section 2: the resolver's APPROVE branch persists first as well"
grep -q 'WAIT_REVIEW' "$T/tr-br-approve.txt" \
  && ok || bad "section 2: the APPROVE transition must be unchanged"
grep -q 'after the conductor got no verdict: APPROVE' "$T/gh-br-approve.body" \
  && ok || bad "section 2: the APPROVE comment must carry the resolver's footer with the reason it bought the read"
# The block must run to its END, not abort partway on an unset local (BH-1992):
# every drive records its re-review row against the counter it spends.
for d in br-block br-incident br-approve; do
  grep -q 're-review no-verdict .* rereviews$' "$T/rec-log-$d.txt" 2>/dev/null \
    && ok || bad "section 2 ($d): the block never reached its br_record line (got '$(cat "$T/rec-log-$d.txt" 2>/dev/null)')"
  ! grep -q 'unbound variable' "$T/br-err-$d.txt" 2>/dev/null \
    && ok || bad "section 2 ($d): the block hit an unset variable: $(grep 'unbound variable' "$T/br-err-$d.txt")"
done

# K3: a re-review the call-guard DEFERRED (mc_rereview rc 3, nothing called)
# spends no counter — neither the read counter nor the lane-failure one — and
# moves nothing: no transition, no lane-down alert.
printf 'AGENT_CALL_REFUSED call-guard repeat mc-rereview paid=5/5 fp=mc-rereview:acme/widgets#7@x\n' > "$T/guard.md"
RR_RC=3 br_drive br-guard "" "$T/guard.md"
grep -q 'deferred by the call-guard' "$T/say-br-guard.txt" 2>/dev/null \
  && ok || bad "section 2 (k3): the deferral left no line (got '$(cat "$T/say-br-guard.txt" 2>/dev/null)')"
[ ! -s "$T/rec-log-br-guard.txt" ] && ok \
  || bad "section 2 (k3): a call-guard deferral spent a counter: $(cat "$T/rec-log-br-guard.txt")"
[ ! -s "$T/tr-br-guard.txt" ] && ok || bad "section 2 (k3): a call-guard deferral moved the PR: $(cat "$T/tr-br-guard.txt")"
! grep -q 'unbound variable' "$T/br-err-br-guard.txt" 2>/dev/null \
  && ok || bad "section 2 (k3): the block hit an unset variable: $(grep 'unbound variable' "$T/br-err-br-guard.txt")"

# ============================================================================
# 3. bin/run-build.sh — the GUARD_SILENCED gate on the merged fix round
# ============================================================================
awk '/^ *# >>> guard-silenced gate/{f=1;next} /^ *# <<< guard-silenced gate/{exit} f' \
  "$RB_ALL" > "$T/gs-gate.sh"
[ -s "$T/gs-gate.sh" ] \
  && ok || bad "section 3: no '# >>> guard-silenced gate' block in bin/run-build.sh — nothing to drive"

gs_repo() { # gs_repo <dir> — a scratch repo with one commit; prints the base sha
  local r="$1"
  mkdir -p "$r/src"
  git -C "$r" init -q 2>/dev/null
  git -C "$r" config user.email harness@example.com
  git -C "$r" config user.name harness
  printf 'export const a = 1\n' > "$r/src/x.ts"
  printf 'dist/\n' > "$r/.eslintignore"
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -qm base >/dev/null 2>&1
  git -C "$r" rev-parse HEAD
}
gs_run() { # gs_run <tag> <repo> <base-sha>
  local tag="$1" r="$2" base="$3"
  ( cd "$r" || exit 9
    # shellcheck source=/dev/null
    [ -r "$DIR/bin/lib/guard-silenced.sh" ] && . "$DIR/bin/lib/guard-silenced.sh"
    BUILD="$T/build-$tag"; ALERTS="$T/alerts-$tag.log"; PROJECT=widgets; KEY=WI-1
    mkdir -p "$BUILD"; : > "$ALERTS"
    STAMP()          { printf '2026-09-17T00:00:00Z'; }
    RESULT()         { printf '%s\n' "$*" > "$BUILD/RESULT"; }
    escalate_block() { printf '%s\n' "$*" > "$BUILD/escalated"; }
    FIX_FROM="$base"
    # shellcheck source=/dev/null
    . "$T/gs-gate.sh"
  )
}

# (a) the fix round edited ONLY the guard's ignore file
GS_A="$T/gsrepo-a"; BASE_A=$(gs_repo "$GS_A")
printf 'dist/\nsrc/x.ts\n' > "$GS_A/.eslintignore"
git -C "$GS_A" commit -qam "quiet the lint guard" >/dev/null 2>&1
gs_run a "$GS_A" "$BASE_A"; RC=$?
[ "$RC" = 6 ] \
  && ok || bad "section 3: a guard-silencing fix round must exit 6 (got $RC)"
grep -q '^REVIEW_BLOCKED guard-silenced:' "$T/build-a/RESULT" 2>/dev/null \
  && ok || bad "section 3: RESULT must be the literal REVIEW_BLOCKED guard-silenced: terminal (got '$(cat "$T/build-a/RESULT" 2>/dev/null)')"
grep -qx '.eslintignore' "$T/build-a/guard-silenced.txt" 2>/dev/null \
  && ok || bad "section 3: guard-silenced.txt must list the files the fix round touched"
grep -q 'GUARD_SILENCED' "$T/alerts-a.log" \
  && ok || bad "section 3: stopping is an alert — one ALERTS line naming what happened"
[ -s "$T/build-a/escalated" ] \
  && ok || bad "section 3: the block must escalate like every other mechanical gate"

# (b) real code changed alongside the guard file — never blocked
GS_B="$T/gsrepo-b"; BASE_B=$(gs_repo "$GS_B")
printf 'export const a = 2\n' > "$GS_B/src/x.ts"
printf 'dist/\nsrc/x.ts\n' > "$GS_B/.eslintignore"
git -C "$GS_B" commit -qam "fix the finding, and ignore the build output" >/dev/null 2>&1
gs_run b "$GS_B" "$BASE_B"; RC=$?
[ "$RC" = 0 ] \
  && ok || bad "section 3: a fix round that changed real code must pass the gate (got $RC)"
[ ! -e "$T/build-b/RESULT" ] \
  && ok || bad "section 3: no RESULT may be written when the gate passes"
[ ! -e "$T/build-b/guard-silenced.txt" ] \
  && ok || bad "section 3: no guard-silenced.txt when the gate passes"
[ ! -s "$T/alerts-b.log" ] \
  && ok || bad "section 3: a passing gate pages nobody"

# (c) the fix round produced no commit at all — EMPTY never blocks
GS_C="$T/gsrepo-c"; BASE_C=$(gs_repo "$GS_C")
gs_run c "$GS_C" "$BASE_C"; RC=$?
[ "$RC" = 0 ] \
  && ok || bad "section 3: an empty fix diff must not block — the no-commit path already owns it (got $RC)"
[ ! -e "$T/build-c/RESULT" ] \
  && ok || bad "section 3: an empty fix diff writes no RESULT"

# (d) the gate's own absence fails OPEN, like every other mechanical gate here
GS_D="$T/gsrepo-d"; BASE_D=$(gs_repo "$GS_D")
printf 'dist/\nsrc/x.ts\n' > "$GS_D/.eslintignore"
git -C "$GS_D" commit -qam "quiet the lint guard" >/dev/null 2>&1
( cd "$GS_D" || exit 9
  BUILD="$T/build-d"; ALERTS="$T/alerts-d.log"; PROJECT=widgets; KEY=WI-1
  mkdir -p "$BUILD"; : > "$ALERTS"
  STAMP()          { printf '2026-09-17T00:00:00Z'; }
  RESULT()         { printf '%s\n' "$*" > "$BUILD/RESULT"; }
  escalate_block() { printf '%s\n' "$*" > "$BUILD/escalated"; }
  FIX_FROM="$BASE_D"
  # no guard-silenced.sh sourced: a box mid-sync that carries the new
  # run-build.sh and the old bin/lib
  # shellcheck source=/dev/null
  . "$T/gs-gate.sh"
); RC=$?
[ "$RC" = 0 ] \
  && ok || bad "section 3: with gs_classify absent the gate must classify nothing and block nothing (got $RC)"
[ ! -e "$T/build-d/RESULT" ] \
  && ok || bad "section 3: a gate that could not run writes no verdict it never reached"

# ============================================================================
# 4. The rule in the re-review prompts
# ============================================================================
# The artifact, not the source: mc_rereview WRITES its prompt to a file and
# hands it to agent-call.sh, so the stub keeps a copy and the clause is asserted
# on what the lane actually sent.
(
  export HARNESS="$T/h4"
  mkdir -p "$HARNESS/bin/lib" "$HARNESS/logs" "$HARNESS/state" "$HARNESS/locks"
  for L in merge-conductor-lib.sh review-provenance.sh gh-pr-list.sh flaky.sh gh-budget.sh gh-rest.sh; do
    [ -r "$DIR/bin/lib/$L" ] && cp "$DIR/bin/lib/$L" "$HARNESS/bin/lib/"
  done
  # BH-680 carved the lib into bin/lib/mc/<name>.sh and its own source loop
  # pulls them in: a fixture that copies the lib without them runs a lib whose
  # logic is missing.
  mkdir -p "$HARNESS/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$HARNESS/bin/lib/mc/"
  cat > "$HARNESS/bin/agent-call.sh" <<'AC'
#!/bin/bash
# $5 = out file, $6 = @prompt-file
cp "${6#@}" "$PROMPT_COPY"
printf 'Static review.\n\n1. **[HIGH]** `src/a.ts:1` — a finding\n\nVERDICT: BLOCK\n' > "$5"
printf 'claude\n' > "$5.runner"
printf 'claude-fable-5-1\n' > "$5.model"
printf '{"is_error":false,"result":"ok"}\n' > "$5.json"
exit 0
AC
  chmod +x "$HARNESS/bin/agent-call.sh"
  export PATH="$T/fakebin:$PATH" PROMPT_COPY="$T/prompt4.txt"
  # shellcheck source=/dev/null
  . "$HARNESS/bin/lib/merge-conductor-lib.sh"; mc_init
  mc_rereview acme/widgets 7 widgets "$URL" - "$HEAD_SHA" - "$T/out4" >/dev/null 2>&1
) >/dev/null 2>&1
[ -s "$T/prompt4.txt" ] \
  && ok || bad "section 4: mc_rereview wrote no prompt file — the lane could not be driven"
grep -q 'GUARD_SILENCED' "$T/prompt4.txt" \
  && ok || bad "section 4: the prompt mc_rereview actually sends must carry the GUARD_SILENCED reject clause"
grep -q "guard's own rule module" "$T/prompt4.txt" \
  && ok || bad "section 4: the clause must say what the reviewer is looking for, not just name it"

# run-build.sh builds its two re-review prompts as inline strings and never
# writes them to disk before the agent call, so there is no artifact to read
# here. These two are SOURCE PINS, and they are written so an absent clause
# fails rather than passing on an empty grep (D3).
[ "$(grep -c 'GUARD_SILENCED' "$RB_ALL")" -ge 2 ] \
  && ok || bad "section 4: the merged re-review prompt and HB_PROMPT in bin/run-build.sh must both carry the clause (found $(grep -c 'GUARD_SILENCED' "$RB_ALL"))"
# BH-477.3: mc_rereview is defined by bin/lib/mc/rebase.sh — the lib is a
# 20-line shim that sources it, so the clause's source pin reads the module.
[ "$(grep -c 'GUARD_SILENCED' "$DIR/bin/lib/mc/rebase.sh")" -ge 1 ] \
  && ok || bad "section 4: mc_rereview's prompt source must carry the clause"

# ============================================================================
# 5. bin/blocked-resolver.sh — the GUARD_SILENCED gate on the fix round
# ============================================================================
# THE PARK THIS GATE SERVES HAS MAIN MOVING UNDER IT BY DEFINITION. br_fix_round
# merges origin/main into the worktree BEFORE the agent runs, so a gate that
# diffed "$lease"..HEAD read every file main had changed since the branch
# diverged, answered CODE_CHANGED, and pushed the guard-silencing round anyway.
# Every fixture below has that merge in it, because without it the gate passes
# on a repo shape production never sees.
awk '/^ *# >>> br guard-silenced gate/{f=1;next} /^ *# <<< br guard-silenced gate/{exit} f' \
  "$DIR/bin/blocked-resolver.sh" > "$T/br-gs-gate.sh"
[ -s "$T/br-gs-gate.sh" ] \
  && ok || bad "section 5: no '# >>> br guard-silenced gate' block in bin/blocked-resolver.sh — nothing to drive"

brgs_repo() { # brgs_repo <dir> [conflict] — prints the lease (the PR head)
  local r="$1" conflict="${2:-}" lease
  mkdir -p "$r/src"
  git -C "$r" init -q >/dev/null 2>&1
  git -C "$r" config user.email harness@example.com
  git -C "$r" config user.name harness
  git -C "$r" symbolic-ref HEAD refs/heads/main
  printf 'export const a = 1\n' > "$r/src/x.ts"
  printf 'dist/\n' > "$r/.eslintignore"
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -qm base >/dev/null 2>&1
  # The branch the PR is on, and the lease the resolver reads from origin/<br>.
  git -C "$r" checkout -q -b feature
  printf 'export const f = 1\n' > "$r/src/feature.ts"
  [ -n "$conflict" ] && printf 'export const a = 9\n' > "$r/src/x.ts"
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -qm "the ticket's own work" >/dev/null 2>&1
  lease=$(git -C "$r" rev-parse HEAD)
  # main moves while the PR sits parked, and the resolver merges it in.
  git -C "$r" checkout -q main
  printf 'export const m = 1\n' > "$r/src/main.ts"
  [ -n "$conflict" ] && printf 'export const a = 3\n' > "$r/src/x.ts"
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -qm "main moved" >/dev/null 2>&1
  git -C "$r" update-ref refs/remotes/origin/main refs/heads/main
  git -C "$r" checkout -q feature
  if ! git -C "$r" merge --no-edit origin/main >/dev/null 2>&1; then
    # The conflict class: the round resolves it INSIDE the merge commit, which
    # is not its own work and must not be classified as such.
    printf 'export const a = 9\n' > "$r/src/x.ts"
    git -C "$r" add -A >/dev/null 2>&1
    git -C "$r" commit -qm "merge origin/main, keeping both sides" >/dev/null 2>&1
  fi
  printf '%s\n' "$lease"
}
brgs_run() { # brgs_run <tag> <wt> <lease> [nolib]
  local tag="$1" r="$2" lease="$3" nolib="${4:-}"
  ( if [ -z "$nolib" ]; then
      # shellcheck source=/dev/null
      [ -r "$DIR/bin/lib/guard-silenced.sh" ] && . "$DIR/bin/lib/guard-silenced.sh"
    fi
    wt="$r"; p=widgets; rkey=WI-1; reason="review blocked"; url="$URL"
    rec="-"; ck=WI-1; tkey=WI-1; br=feature
    REPOS="$T/repos"; mkdir -p "$REPOS/$p"
    say()               { printf '%s\n' "$*" >> "$T/brgs-say-$tag.txt"; }
    br_record()         { printf '%s\n' "$*" >> "$T/brgs-rec-$tag.txt"; }
    br_rebuild_fresh()  { printf 'REBUILD_FRESH %s\n' "$*" >> "$T/brgs-rebuild-$tag.txt"; }
    mc_git_auth_clear() { :; }
    # shellcheck source=/dev/null
    . "$T/br-gs-gate.sh"
  ) >/dev/null 2>&1
}

# (a) THE REPRO: main moved, was merged, and the round edited only the guard.
BRGS_A="$T/brgs-a"; LEASE_A=$(brgs_repo "$BRGS_A")
printf 'dist/\nsrc/x.ts\n' > "$BRGS_A/.eslintignore"
git -C "$BRGS_A" commit -qam "quiet the lint guard" >/dev/null 2>&1
brgs_a_names=$(git -C "$BRGS_A" diff --name-only "$LEASE_A"..HEAD)
grep -qx 'src/main.ts' <<<"$brgs_a_names" \
  && ok || bad "section 5: the fixture must carry main's own file in \$lease..HEAD — that is what made the old gate answer CODE_CHANGED"
brgs_run a "$BRGS_A" "$LEASE_A"
grep -q 'guard-silenced — not pushed' "$T/brgs-rec-a.txt" 2>/dev/null \
  && ok || bad "section 5 REPRO: a round that edited only the guard must be refused even though origin/main was merged first (rec: $(cat "$T/brgs-rec-a.txt" 2>/dev/null))"
grep -q 'GUARD_SILENCED' "$T/brgs-say-a.txt" 2>/dev/null \
  && ok || bad "section 5: the refusal must say why in the resolver's own log line"
[ -s "$T/brgs-rebuild-a.txt" ] \
  && ok || bad "section 5: a refused round drops to REBUILD FRESH, like every other round that produced nothing usable"

# (b) the round changed real code as well — never refused
BRGS_B="$T/brgs-b"; LEASE_B=$(brgs_repo "$BRGS_B")
printf 'export const a = 2\n' > "$BRGS_B/src/x.ts"
printf 'dist/\nsrc/x.ts\n' > "$BRGS_B/.eslintignore"
git -C "$BRGS_B" commit -qam "fix the finding, and ignore the build output" >/dev/null 2>&1
brgs_run b "$BRGS_B" "$LEASE_B"
[ ! -e "$T/brgs-rec-b.txt" ] \
  && ok || bad "section 5: a round that changed real code must pass the gate (rec: $(cat "$T/brgs-rec-b.txt" 2>/dev/null))"
[ ! -e "$T/brgs-rebuild-b.txt" ] \
  && ok || bad "section 5: a passing gate never sends the ticket to REBUILD FRESH"

# (c) the merge itself carried a conflict resolution; the round then silenced a
#     guard. The merge commit is not the round's work, so this is still refused.
BRGS_C="$T/brgs-c"; LEASE_C=$(brgs_repo "$BRGS_C" conflict)
[ "$(git -C "$BRGS_C" rev-list --count --merges HEAD)" -ge 1 ] \
  && ok || bad "section 5: the conflict fixture must actually produce a merge commit"
printf 'dist/\nsrc/x.ts\n' > "$BRGS_C/.eslintignore"
git -C "$BRGS_C" commit -qam "quiet the lint guard" >/dev/null 2>&1
brgs_run c "$BRGS_C" "$LEASE_C"
grep -q 'guard-silenced — not pushed' "$T/brgs-rec-c.txt" 2>/dev/null \
  && ok || bad "section 5: a conflict resolved inside the merge commit is not the round's own work — the guard-only round is still refused"

# (d) the round produced only the merge of origin/main — EMPTY never refuses
BRGS_D="$T/brgs-d"; LEASE_D=$(brgs_repo "$BRGS_D")
brgs_run d "$BRGS_D" "$LEASE_D"
[ ! -e "$T/brgs-rec-d.txt" ] \
  && ok || bad "section 5: a round with no commits of its own classifies EMPTY and refuses nothing"

# (e) the gate's own absence fails OPEN, like every other mechanical gate here
BRGS_E="$T/brgs-e"; LEASE_E=$(brgs_repo "$BRGS_E")
printf 'dist/\nsrc/x.ts\n' > "$BRGS_E/.eslintignore"
git -C "$BRGS_E" commit -qam "quiet the lint guard" >/dev/null 2>&1
brgs_run e "$BRGS_E" "$LEASE_E" nolib
[ ! -e "$T/brgs-rec-e.txt" ] \
  && ok || bad "section 5: with gs_classify absent the gate must classify nothing and refuse nothing"

echo "review-record-integrity: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
