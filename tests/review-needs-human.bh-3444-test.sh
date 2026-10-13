#!/bin/bash
# tests/review-needs-human.bh-3444-test.sh — the needs-human review hook, driven
# (BH-3444): LENS_REFUSE cut from the flattened pipeline, exactly as
# tests/needs-human-contract.bh-3442-test.sh DRIVEs it, with the REAL
# bin/lib/needs-human.sh (and so the real classify.sh) sourced and a placer stub
# at $HARNESS/bin/needs-human-hold.sh that records its argv and prints JUNK.
#   V1  a merged re-review asking for a hub run: RESULT gains
#       " NEEDS_HUMAN:<fp>:<action>", needs-human.txt is written, the placer is
#       called once with source `review`, pipeline.log says placer rc=0
#   V2  a structured NEEDS_HUMAN: field is the action
#   V3  an APPROVE review: RESULT unchanged, no call, no file
#   V4  no issue number (a product board): RESULT unchanged, no call, no file
#   V5  the placer fails: same suffix, pipeline.log says placer rc=1
#   V6  the placer's stdout never reaches RESULT
#   V7  the security lens never takes the suffix
#   V8  no placer on the box: suffix kept, pipeline.log says placer rc=127
#
# MUTATION (D1), run by hand in the build: make nh_on_block return before its
# printf -> V1 red.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/needs-human.sh"
CLASSIFY="$DIR/bin/lib/needs-human/classify.sh"
[ -r "$LIB" ] && [ -r "$CLASSIFY" ] && ok || bad "D41: the lib or $CLASSIFY is missing"

mkdir -p "$T/bin" "$T/h/bin" "$T/bare/bin"
for s in gh gh_rest alert-line jobs; do
  printf '#!/bin/bash\n: > "%s/called.%s"\nexit 0\n' "$T" "$s" > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
export PATH="$T/bin:$PATH"
cat > "$T/h/bin/needs-human-hold.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/h/placer.calls"
echo JUNK
exit \${PLACER_RC:-0}
EOF
chmod +x "$T/h/bin/needs-human-hold.sh"

RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
cut_block() { awk -v n="$1" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' "$RB_ALL" > "$2"; }
cut_fn() { awk -v f="$1" 'index($0, f "() {")==1{p=1} p{print} p&&/^}/{exit}' "$RB_ALL"; }
cut_block "stage lane verdict" "$T/lane.sh"
{ cut_fn LENS_ART; cut_fn LENS_VARS; cut_fn LENS_REFUSE; } > "$T/lens.sh"
for B in lane lens; do [ -s "$T/$B.sh" ] && ok || bad "could not extract '$B' from the pipeline text"; done

# The BH-3348 r1 shape: round 1, review.sh's merged re-review header, the final
# round with its VERDICT-REVIEW tag line, TIER, VERDICT.
cat > "$T/r1.md" <<'EOF'
## Review — BH-3348

F1. The lead-verdict gate has no probe evidence in validate.txt (D6).

TIER: 2
VERDICT: BLOCK

=== MERGED RE-REVIEW after the single fix round (head 5b35bacc) ===
F1 stands. The builder cannot run this probe from a pool box.
- **To clear it:** the hub runs `bin/vs-publish.sh --dry-run` and `gh api repos/example-org/cromford/commits/HEAD/status`, and both commands and their outputs go into the PR body.

VERDICT-REVIEW BLOCK
TIER: 2
VERDICT: BLOCK
EOF
printf '%s\n' "F1. The gate has no probe evidence." "NEEDS_HUMAN: run the lead-verdict probe from the hub" \
  "TIER: 2" "VERDICT: BLOCK" > "$T/r2.md"
printf '%s\n' "Looks fine; nothing here needs a human from the hub." "TIER: 1" "VERDICT: APPROVE" > "$T/r3.md"

NB=0
fresh() { NB=$((NB+1)); B="$T/lb$NB"; mkdir -p "$B"; }
DRIVE() { # DRIVE <fixture> <issue> <harness> <lens>  -> "<rc> <RESULT>" in the build dir $B (call fresh first)
  cp "$1" "$B/review.md"
  ( BUILD="$B"; PROJECT=project-5; KEY=BH-3348; BASE=main; BRANCH=ticket/bh-3348
    REVIEW_MODEL=m; FIX_MODEL=m; RISKY=1; HIGHRISK=1; NH_ISSUE="$2"; HARNESS="$3"
    STAMP() { echo 2026-09-29T00:00:00Z; }
    RESULT() { echo "$*" > "$B/RESULT"; }
    BB() { :; }
    # shellcheck disable=SC1090
    . "$LIB"; . "$T/lane.sh"; . "$T/lens.sh"
    LENS_REFUSE "$4" ) >/dev/null 2>"$B/stderr"
  echo "$? $(cat "$B/RESULT" 2>/dev/null || echo none)"
}
calls() { [ -f "$T/h/placer.calls" ] && wc -l < "$T/h/placer.calls" | tr -d ' ' || echo 0; }

# The expected action is what the classifier itself reads off the final round.
# shellcheck disable=SC1090
EXP=$( . "$LIB"; nh_classify "$T/r1.md" ); EXP=${EXP#*$'\t'}
FP=$( . "$LIB"; nh_fingerprint "$EXP" )
[[ "$EXP" == "- To clear it:"* ]] && [[ "$FP" =~ ^[0-9a-f]{12}$ ]] && ok || bad "V1: fixture action '$EXP' fp '$FP'"

# V1 / V6
fresh; OUT=$(DRIVE "$T/r1.md" 3348 "$T/h" review)
[ "$OUT" = "6 REVIEW_BLOCKED $B/review.md NEEDS_HUMAN:$FP:$EXP" ] && ok || bad "V1: RESULT '$OUT'"
[ "$(cat "$B/needs-human.txt" 2>/dev/null)" = "$(printf 'action: %s\nfp: %s' "$EXP" "$FP")" ] && ok \
  || bad "V1: needs-human.txt is '$(cat "$B/needs-human.txt" 2>/dev/null)'"
[ "$(calls)" = 1 ] && [ "$(cat "$T/h/placer.calls")" = "project-5 3348 $FP $EXP review" ] && ok \
  || bad "V1: placer calls '$(cat "$T/h/placer.calls" 2>/dev/null)'"
grep -q "needs-human: $FP .*placer rc=0" "$B/pipeline.log" 2>/dev/null && ok || bad "V1: pipeline.log lacks placer rc=0"
[[ "$OUT" != *JUNK* ]] && ok || bad "V6: the placer's stdout reached RESULT: '$OUT'"
rm -f "$T/h/placer.calls"

# V2
fresh; OUT=$(DRIVE "$T/r2.md" 3348 "$T/h" review)
FP2=$( . "$LIB"; nh_fingerprint "run the lead-verdict probe from the hub" )
[ "$OUT" = "6 REVIEW_BLOCKED $B/review.md NEEDS_HUMAN:$FP2:run the lead-verdict probe from the hub" ] && ok || bad "V2: RESULT '$OUT'"
rm -f "$T/h/placer.calls"

# V3
fresh; OUT=$(DRIVE "$T/r3.md" 3348 "$T/h" review)
[ "$OUT" = "6 REVIEW_BLOCKED $B/review.md" ] && [ "$(calls)" = 0 ] && [ ! -e "$B/needs-human.txt" ] \
  && ok || bad "V3: APPROVE review gave '$OUT', calls $(calls)"

# V4
fresh; OUT=$(DRIVE "$T/r1.md" "" "$T/h" review)
[ "$OUT" = "6 REVIEW_BLOCKED $B/review.md" ] && [ "$(calls)" = 0 ] && [ ! -e "$B/needs-human.txt" ] \
  && ok || bad "V4: no issue gave '$OUT', calls $(calls)"

# V5
fresh; OUT=$(PLACER_RC=1 DRIVE "$T/r1.md" 3348 "$T/h" review)
[ "$OUT" = "6 REVIEW_BLOCKED $B/review.md NEEDS_HUMAN:$FP:$EXP" ] && grep -q 'placer rc=1' "$B/pipeline.log" 2>/dev/null \
  && ok || bad "V5: failing placer gave '$OUT', log '$(cat "$B/pipeline.log" 2>/dev/null)'"
rm -f "$T/h/placer.calls"

# V7
fresh; OUT=$(DRIVE "$T/r1.md" 3348 "$T/h" security)
[ "$OUT" = "6 SECURITY_BLOCKED $B/security-review.md" ] && [ "$(calls)" = 0 ] && ok || bad "V7: security lens gave '$OUT', calls $(calls)"

# V8
fresh; OUT=$(DRIVE "$T/r1.md" 3348 "$T/bare" review)
[ "$OUT" = "6 REVIEW_BLOCKED $B/review.md NEEDS_HUMAN:$FP:$EXP" ] && grep -q 'placer rc=127' "$B/pipeline.log" 2>/dev/null \
  && ok || bad "V8: no placer gave '$OUT', log '$(cat "$B/pipeline.log" 2>/dev/null)'"

[ -z "$(find "$T" -maxdepth 1 -name 'called.*')" ] && ok || bad "a gh/alert stub was called: $(ls "$T"/called.* 2>/dev/null)"
[ -z "$(find "$T" -name ALERTS.log)" ] && ok || bad "an ALERTS.log was written"

echo "review-needs-human.bh-3444: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
