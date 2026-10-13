#!/bin/bash
# tests/mc-rereview-model.bh-998-test.sh — BH-998: the conductor's head-bound
# re-review resolves its review model instead of hardcoding one.
#
# WHY THIS EXISTS. bin/lib/merge-conductor-lib.sh's mc_rereview called
# `agent-call.sh review "$project" claude-fable-5-1 1200 ...` with the model as a
# literal, so a box that set REVIEW_MODEL in env/global.env still bought the
# hardcoded model for every HEAD_MOVED re-review — the one review call in the
# fleet that ignored the operator's setting. rules/CLAUDE.md "AI model config":
# agents never hardcode claude-* model strings.
#
# Run from anywhere: bash tests/mc-rereview-model.bh-998-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ============================================================================
# A1 — the literal is gone from both files (the reproduction)
# ============================================================================
if grep -qE 'claude-[a-z0-9-]*-[0-9]' "$DIR/bin/lib/merge-conductor-lib.sh"; then
  bad "bin/lib/merge-conductor-lib.sh still hardcodes a claude-* model: $(grep -nE 'claude-[a-z0-9-]*-[0-9]' "$DIR/bin/lib/merge-conductor-lib.sh" | head -3)"
else ok; fi
if [ -f "$DIR/bin/lib/mc/rebase.sh" ]; then
  if grep -qE 'claude-[a-z0-9-]*-[0-9]' "$DIR/bin/lib/mc/rebase.sh"; then
    bad "bin/lib/mc/rebase.sh still hardcodes a claude-* model"
  else ok; fi
  # A5 — the split layout map stays green when the module dir exists.
  ( cd "$DIR" && bash tests/mc-split-layout-test.sh >/dev/null 2>&1 ) && ok \
    || bad "tests/mc-split-layout-test.sh went red with the module copy edited"
else
  echo "note: bin/lib/mc/rebase.sh absent on this base — A1/A5 module-copy cases skipped"
fi

# ============================================================================
# the harness fixture: mc_rereview with agent-call.sh and gh stubbed
# ============================================================================
H="$T/h"; export HARNESS="$H"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/env" "$T/fakebin"
cp "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/review-provenance.sh" "$DIR/bin/lib/gh-pr-list.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/" 2>/dev/null
# BH-784: mc_rereview's diff and body reads go through bin/lib/gh-rest.sh, and
# the lib sources it off its own BASH_SOURCE, so the contract travels with the
# lib copy. Without it mc_rereview exits at its "REST diff read failed" arm
# before bin/agent-call.sh runs and every assertion below reads an empty sink.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
# The shared REST answer emitter (tests/lib/rest-emit.sh documents the shapes):
# gh-rest.sh judges the HTTP STATUS LINE, so a stub arm prints a whole response.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# BH-680 (#929): merge-conductor-lib.sh sources bin/lib/mc/*.sh off its own
# BASH_SOURCE and EXITS the caller when a module is missing, so a fixture that
# copies the lib has to copy the modules with it or nothing below runs.
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
export PATH="$T/fakebin:$PATH"
# BH-1510.1: with no REVIEW_MODEL anywhere, review_model answers the build.review
# model_routes row. This box has no worker, so it carries the resolver's cache of
# #1507's table — what a real box whose worker is down would have.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" demo-os

# The stub records exactly what the conductor asked for: the model is argv[3].
cat > "$H/bin/agent-call.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$3" > "$MODEL_SEEN"
printf '%s %s %s\n' "$1" "$2" "$4" > "$MODEL_SEEN.shape"
OUT="$5"
printf 'VERDICT: APPROVE\n' > "$OUT"
printf 'claude\n' > "$OUT.runner"
printf '%s\n' "$3" > "$OUT.model"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
# The diff and the PR object share the pulls/1 path and differ only by the
# v3.diff media type, so the diff arm is matched FIRST.
case "$*" in
  *"v3.diff"*) restpr --diff '--- a/x.sh
+++ b/x.sh
+echo hi
' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/1"*)
    restpr OPEN deadbeef ticket/x main "" MERGEABLE CLEAN operator "" 'a PR body' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export MODEL_SEEN="$T/model.seen"
URL=https://github.com/example-org/demo-os/pull/1

# A2 — env wins. Driven through the production entry point: the lib is sourced
# from the harness root the conductor uses, and mc_rereview is the real function.
V=$(env -u REVIEW_MODEL REVIEW_MODEL=env-model-9 bash -c '
  set -uo pipefail
  # shellcheck source=/dev/null
  . "$HARNESS/bin/lib/merge-conductor-lib.sh"
  mc_rereview example-org/demo-os 1 demo-os '"$URL"' oldsha newsha "" "$0.out"' "$T/rr"); RC=$?
[ "$RC" = 0 ] && [ "$V" = APPROVE ] && ok || bad "A2: mc_rereview must still answer APPROVE (rc=$RC v='$V')"
[ "$(cat "$MODEL_SEEN" 2>/dev/null)" = env-model-9 ] && ok \
  || bad "A2: REVIEW_MODEL from the environment must reach agent-call.sh argv[3] (got '$(cat "$MODEL_SEEN" 2>/dev/null)')"

# A6 — nothing else about the call changed: stage, project, timeout, no lanefail.
[ "$(cat "$MODEL_SEEN.shape" 2>/dev/null)" = "review demo-os 1200" ] && ok \
  || bad "A6: the call shape must stay 'review <project> … 1200' (got '$(cat "$MODEL_SEEN.shape" 2>/dev/null)')"
[ -f "$T/rr.out.lanefail" ] && bad "A6: a successful re-review leaves no lanefail sidecar" || ok

# A3 — REVIEW_MODEL unset: the operator-editable env/global.env is the source.
printf 'REVIEW_MODEL="file-model-7"\n' > "$H/env/global.env"
: > "$MODEL_SEEN"
V=$(env -u REVIEW_MODEL bash -c '
  set -uo pipefail
  # shellcheck source=/dev/null
  . "$HARNESS/bin/lib/merge-conductor-lib.sh"
  mc_rereview example-org/demo-os 1 demo-os '"$URL"' oldsha newsha "" "$0.out"' "$T/rr")
[ "$(cat "$MODEL_SEEN")" = file-model-7 ] && ok \
  || bad "A3: env/global.env's REVIEW_MODEL must be read when the variable is unset (got '$(cat "$MODEL_SEEN")')"

# A4 — neither set: the build.review route (BH-1510.1; it was a literal
# fallback in review-model.sh), never an empty model string.
printf 'REVIEW_MODEL=\n' > "$H/env/global.env"
: > "$MODEL_SEEN"
env -u REVIEW_MODEL bash -c '
  set -uo pipefail
  # shellcheck source=/dev/null
  . "$HARNESS/bin/lib/merge-conductor-lib.sh"
  mc_rereview example-org/demo-os 1 demo-os '"$URL"' oldsha newsha "" "$0.out"' "$T/rr" >/dev/null
SEEN=$(cat "$MODEL_SEEN")
[ "$SEEN" = claude-opus-5-5 ] && ok || bad "A4: a blank REVIEW_MODEL= line must fall back to the build.review route, never pass an empty model (got '$SEEN')"
FB=$(env -u REVIEW_MODEL bash -c '. "$HARNESS/bin/lib/review-model.sh"; review_model "$HARNESS"')
[ "$SEEN" = "$FB" ] && ok || bad "A4: the fallback the conductor passes must be review_model's own answer (seen '$SEEN' vs '$FB')"

# the resolver, directly. TEST CHANGED BY BH-1510.1, deliberately: this used to
# pin "never empty" because review-model.sh carried a literal fallback. The
# directive (#1510) deletes that literal, so on a box with no REVIEW_MODEL, no
# route and no cached answer the honest answer is NOTHING, rc 75 — the resolver
# fails closed and alerts rather than guess. Pinned both ways.
FB2=$(env -u REVIEW_MODEL bash -c '. "$HARNESS/bin/lib/review-model.sh"; review_model "$0"; echo "rc=$?"' "$T/nowhere")
[ "$FB2" = "rc=75" ] && ok || bad "review_model with nothing configured and no route must answer nothing, rc 75 (got '$FB2')"
FB3=$(env -u REVIEW_MODEL bash -c '. "$HARNESS/bin/lib/review-model.sh"; review_model "$HARNESS"')
[ "$FB3" = claude-opus-5-5 ] && ok || bad "review_model with nothing configured must answer the build.review route (got '$FB3')"
[ "$(REVIEW_MODEL=x-1 bash -c '. "$HARNESS/bin/lib/review-model.sh"; review_model "$HARNESS"')" = x-1 ] && ok \
  || bad "review_model: the environment wins over the file"

echo "mc-rereview-model.bh-998: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
