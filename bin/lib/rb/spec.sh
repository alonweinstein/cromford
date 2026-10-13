# bin/lib/rb/spec.sh — the spec artifact block.
# The body is the VERBATIM text of its former slice of bin/run-build.sh. Since the
# BH-572 cut the driver runs it as a bare `rb_<name>` call, in pipeline order.
# The slice starts and ends exactly on the markers #478 named, byte-verbatim.
# Entry functions, pipeline order: rb_spec_artifact
# Reads: BASE BUILD KEY PROJECT SPEC_DIR SPEC_ID SPEC_LINE
# Writes: SPEC_DIR SPEC_ID SPEC_LINE
# shellcheck shell=bash

rb_spec_artifact() {
# >>> spec artifact
# --- SPEC ARTIFACT (SDLC playbook item 3, 2026-08-29) -------------------------
# Until now the plan a diff was built from lived ONLY in the build dir on the
# box that ran it: whoever opened the PR saw code and had to take the spec on
# trust, and when the machine was reaped the spec went with it. So the plan
# rides INTO the branch as .harness/specs/<ticket>/plan.md, in the same commit
# stream as the build — the PR diff now shows the spec beside the code it
# produced, and the spec survives in git as long as the code does.
#
# AFTER execute, deliberately. The EXECUTE checkpoint above decides "does this
# branch already carry work?" from `git diff $BASE...HEAD`, so a spec commit
# landing before that test would make every resumed build skip the stage that
# writes the actual code. Landing it here also means the file in the PR is the
# plan that really governed this diff, not one the reviewer has to trust.
#
# IDEMPOTENT BY CONSTRUCTION: one fixed path per ticket, rewritten every time
# and committed ONLY when the bytes changed. A fix round, a re-run, or a
# checkpoint-resume updates the same file — it never stacks a second copy and
# never makes an empty commit.
SPEC_ID=$(printf '%s' "$KEY" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[.-]*//' | cut -c1-64)
SPEC_DIR=".harness/specs/${SPEC_ID:-ticket}"
SPEC_LINE=""
if [ -s "$BUILD/plan.md" ]; then
  mkdir -p "$SPEC_DIR"
  cp "$BUILD/plan.md" "$SPEC_DIR/plan.md"
  [ -s "$BUILD/requirements.md" ] && cp "$BUILD/requirements.md" "$SPEC_DIR/requirements.md"
  # -f because a repo whose .gitignore swallows dotted directories would
  # otherwise drop the spec silently, which is the exact failure this stage
  # exists to end: a PR that looks like it carries its spec and does not.
  git add -f -- "$SPEC_DIR" 2>>"$BUILD/pipeline.log"
  if git diff --cached --quiet -- "$SPEC_DIR"; then
    echo "$(STAMP) [$PROJECT/$KEY] spec artifact unchanged at $SPEC_DIR — no new commit" >> "$BUILD/pipeline.log"
  elif git commit -q -m "spec($KEY): the plan this build was executed from" -- "$SPEC_DIR" 2>>"$BUILD/pipeline.log"; then
    echo "$(STAMP) [$PROJECT/$KEY] spec artifact committed: $SPEC_DIR/plan.md" >> "$BUILD/pipeline.log"
  else
    # Never fatal: a PR carrying no spec is still worth far more than no PR,
    # and a repo-side pre-commit hook is the realistic way this lands here.
    # Said out loud in the log so it is never mistaken for shipped.
    echo "$(STAMP) [$PROJECT/$KEY] spec artifact commit FAILED — this PR ships WITHOUT its spec" >> "$BUILD/pipeline.log"
  fi
  # The PR body claims the spec only when it is really in the COMMITTED tree.
  # Reading the index instead would let a failed commit still advertise a spec
  # the PR does not contain — `git add` alone puts the file in the index.
  if git cat-file -e "HEAD:$SPEC_DIR/plan.md" 2>/dev/null; then
    SPEC_LINE="Spec: the plan this build executed is in this PR at \`$SPEC_DIR/plan.md\`"
    git cat-file -e "HEAD:$SPEC_DIR/requirements.md" 2>/dev/null \
      && SPEC_LINE="$SPEC_LINE (with \`requirements.md\` beside it)"
    SPEC_LINE="$SPEC_LINE — spec text, excluded from the added-line iron-law scans."
  fi
fi
# <<< spec artifact
} # end rb_spec_artifact
