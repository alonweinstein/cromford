#!/bin/bash
# tests/skills-sync-test.sh — self-contained assertions for bin/sync-skills.sh
# and for the shape of the repo's own skills/ (SDLC item 6).
# Run from anywhere: tests/skills-sync-test.sh   (exit 0 = all pass)
#
# The deploy path is DRIVEN against a scratch checkout + scratch destination,
# never the box's real ~/.claude/skills — the env overrides exist for exactly
# this. The repo-shape assertions are static: a SKILL.md whose frontmatter name
# does not match its directory installs as a skill that can never be selected.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- scratch fixture --------------------------------------------------------
mkdir -p "$T/checkout/skills/good" "$T/checkout/skills/nameless" "$T/checkout/skills/linked" \
         "$T/dest/preexisting" "$T/elsewhere"
printf -- '---\nname: good\ndescription: a real one\n---\n\nbody\n' > "$T/checkout/skills/good/SKILL.md"
printf -- '---\ndescription: no name line\n---\n\nbody\n' > "$T/checkout/skills/nameless/SKILL.md"
printf -- '---\nname: linked\ndescription: owned elsewhere\n---\n\nbody\n' > "$T/checkout/skills/linked/SKILL.md"
echo "someone else's skill" > "$T/dest/preexisting/SKILL.md"
ln -s "$T/elsewhere" "$T/dest/linked"

run() { HARNESS_CHECKOUT="$T/checkout" CLAUDE_SKILLS_DIR="$T/dest" HARNESS_LOG_DIR="$T" \
        "$DIR/bin/sync-skills.sh" "$@" 2>/dev/null; }

# 1. --check writes nothing at all
OUT=$(run --check)
grep -q 'would deploy: good' <<<"$OUT" && [ ! -e "$T/dest/good" ] \
  && ok || bad "--check must report and write nothing (got: $OUT)"

# 2. deploy copies a well-formed skill
OUT=$(run)
[ -f "$T/dest/good/SKILL.md" ] && grep -q '^name: good$' "$T/dest/good/SKILL.md" \
  && ok || bad "deploy should install good/SKILL.md (got: $OUT)"

# 3. a SKILL.md with no name: frontmatter is skipped, not installed half-broken
[ ! -e "$T/dest/nameless" ] && grep -q 'skip (no name: frontmatter): nameless' <<<"$OUT" \
  && ok || bad "nameless skill must be skipped (got: $OUT)"

# 4. a symlinked destination is never written through
[ -L "$T/dest/linked" ] && [ ! -e "$T/elsewhere/SKILL.md" ] \
  && grep -q 'skip (symlink, not ours): linked' <<<"$OUT" \
  && ok || bad "symlink destination must be left alone (got: $OUT)"

# 5. no --delete: a destination entry this repo does not own survives
[ -f "$T/dest/preexisting/SKILL.md" ] && ok || bad "sync must never delete unowned skills"

# 6. re-running is a no-op that still reports honestly (idempotent)
OUT2=$(run)
grep -q 'deployed: good' <<<"$OUT2" && ok || bad "second run should still deploy/reconcile (got: $OUT2)"

# 7. an edit in the checkout reaches the destination
printf -- '---\nname: good\ndescription: a real one\n---\n\nEDITED\n' > "$T/checkout/skills/good/SKILL.md"
run >/dev/null
grep -q EDITED "$T/dest/good/SKILL.md" && ok || bad "checkout edits must propagate"

# 8. missing skills/ dir is a quiet exit 0, not an error
OUT=$(HARNESS_CHECKOUT="$T/empty" CLAUDE_SKILLS_DIR="$T/dest" HARNESS_LOG_DIR="$T" \
      "$DIR/bin/sync-skills.sh" 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && ok || bad "absent skills/ should exit 0 (rc=$RC)"

# --- the repo's own skills --------------------------------------------------
COUNT=0
for D in "$DIR"/skills/*/; do
  [ -d "$D" ] || continue
  NAME=$(basename "$D"); COUNT=$((COUNT+1))
  F="$D/SKILL.md"
  [ -f "$F" ] || { bad "skills/$NAME has no SKILL.md"; continue; }
  head -1 "$F" | grep -qx -- '---' || { bad "skills/$NAME: SKILL.md must open with frontmatter"; continue; }
  FM=$(sed -n '2,/^---$/p' "$F")
  FMNAME=$(grep -m1 '^name: ' <<<"$FM" | sed 's/^name: *//')
  [ "$FMNAME" = "$NAME" ] && ok || bad "skills/$NAME: frontmatter name is '$FMNAME', must match the directory"
  grep -q '^description: .\{40,\}' <<<"$FM" && ok \
    || bad "skills/$NAME: needs a description long enough to select on"
  grep -q '^# ' "$F" && ok || bad "skills/$NAME: needs a body heading"
done
[ "$COUNT" -ge 4 ] && ok || bad "expected at least 4 skills in the repo, found $COUNT"

# 9. no secrets in any skill file. Tokens, keys and bearer values are referenced
#    by ENV NAME or file path, never by value — a skill deploys to every box.
LEAK=$(grep -rInE '(sk_(live|test)_[A-Za-z0-9]{12,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xoxb-[A-Za-z0-9-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' \
       "$DIR"/skills/ 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "secret-shaped literal in a skill file: $LEAK"
# An env var assigned a literal value (FOO_TOKEN=abc...) is the other shape.
LEAK2=$(grep -rInE '^[^#]*[A-Z_]*(TOKEN|SECRET|KEY|PASSWORD)=["'"'"']?[A-Za-z0-9_/+.-]{16,}' "$DIR"/skills/ 2>/dev/null \
        | grep -vE '=\$|=<|=\.\.\.|=$')
[ -z "$LEAK2" ] && ok || bad "hardcoded secret value in a skill file: $LEAK2"

# 10. the sync path is actually wired: harness-sync.sh must invoke sync-skills.sh
grep -q 'sync-skills.sh' "$DIR/bin/harness-sync.sh" \
  && ok || bad "bin/harness-sync.sh does not deploy skills — a repo-managed skill would never reach a box"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
