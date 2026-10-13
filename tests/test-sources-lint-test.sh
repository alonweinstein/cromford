#!/bin/bash
# tests/test-sources-lint-test.sh — bin/test-sources-lint.sh is the prevention
# half of the 2026-09-17 incident: a suite that sources a tests/lib/ helper with
# a CWD-relative path, or with no failure handler at all, dies in a way that
# reads as an ordinary test failure.
#
# Every case drives the REAL bin/test-sources-lint.sh over a scratch checkout
# and asserts on its stdout and exit code. The negatives matter as much as the
# hits: a rule that also drags in every bin/lib/ source, or the fixture text
# inside a heredoc, is the wrong rule — it turns one incident into a two-dozen
# file diff nobody reviews.
#
# Self-contained: no network, no secrets, no $HARNESS, no clock read.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/test-sources-lint.sh"
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

OUT=""; RC=0

# fixture <name> — a fresh scratch checkout with a real tests/lib/scratch.sh
# (the lint resolves "a path under tests/lib/" against the helpers that exist)
# and one suite, whose body is read from stdin.
fixture() {
  rm -rf "$T/c"
  mkdir -p "$T/c/tests/lib"
  printf '#!/bin/bash\n' > "$T/c/tests/lib/scratch.sh"
  cat > "$T/c/tests/$1"
}

run() { OUT=$(bash "$LINT" "$T/c" 2>&1); RC=$?; }

# ── 1. the two shapes it must refuse ────────────────────────────────────────
# cwd-relative-path: only resolves when the suite is run from the repo root.
fixture x-test.sh <<'EOF'
#!/bin/bash
set -uo pipefail
. tests/lib/scratch.sh || exit 1
EOF
run
[ "$RC" -eq 1 ] && ok || bad "cwd-relative-path: rc was $RC, expected 1"
grep -qE '^tests/x-test\.sh:3: cwd-relative' <<<"$OUT" \
  && ok || bad "cwd-relative-path: expected a cwd-relative reason on line 3, got: $OUT"

# no-handler: the incident's own shape — the source fails, set -u does the rest.
fixture x-test.sh <<'EOF'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh"
EOF
run
[ "$RC" -eq 1 ] && ok || bad "no-handler: rc was $RC, expected 1"
grep -qE '^tests/x-test\.sh:3: no failure handler' <<<"$OUT" \
  && ok || bad "no-handler: expected a no-failure-handler reason on line 3, got: $OUT"

# ── 2. what it must accept ──────────────────────────────────────────────────
# dirname-anchored-with-guard: the shape this ticket converts the repo to.
fixture x-test.sh <<'EOF'
#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
EOF
run
[ "$RC" -eq 0 ] && ok || bad "dirname-anchored-with-guard: rc was $RC, expected 0"
[ -z "$OUT" ] && ok || bad "dirname-anchored-with-guard: expected silence, got: $OUT"

# dirname-anchored-with-fallback: ~28 suites deliberately degrade instead of
# exiting. Any || is a handled failure; the lint has no opinion on which.
fixture x-test.sh <<'EOF'
#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || SCRATCH_FALLBACK=1
EOF
run
[ "$RC" -eq 0 ] && ok || bad "dirname-anchored-with-fallback: rc was $RC, expected 0 (got: $OUT)"

# bash-source-anchored
fixture x-test.sh <<'EOF'
#!/bin/bash
. "${BASH_SOURCE[0]%/*}/lib/scratch.sh" || exit 1
EOF
run
[ "$RC" -eq 0 ] && ok || bad "bash-source-anchored: rc was $RC, expected 0 (got: $OUT)"

# absolute-dir-var: tests/lib/ in the path, but anchored on an absolute $DIR.
fixture x-test.sh <<'EOF'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/scratch.sh" || exit 1
EOF
run
[ "$RC" -eq 0 ] && ok || bad "absolute-dir-var: rc was $RC, expected 0 (got: $OUT)"

# clean-tree-silent-0: no source lines at all.
fixture x-test.sh <<'EOF'
#!/bin/bash
echo hello
EOF
run
[ "$RC" -eq 0 ] && ok || bad "clean-tree-silent-0: rc was $RC, expected 0"
[ -z "$OUT" ] && ok || bad "clean-tree-silent-0: expected silence, got: $OUT"

# ── 3. the rule stays narrow ────────────────────────────────────────────────
# bin-lib-source-ignored: bin/lib/ helpers are not this rule's business, and
# several are sourced with no handler on purpose.
fixture x-test.sh <<'EOF'
#!/bin/bash
. "$T/h/bin/lib/merge-conductor-lib.sh"
EOF
run
[ "$RC" -eq 0 ] && ok || bad "bin-lib-source-ignored: a bin/lib source was flagged (rc $RC): $OUT"

# variable-source-ignored: the lint cannot know what "$1" holds, so it says
# nothing rather than guessing.
fixture x-test.sh <<'EOF'
#!/bin/bash
. "$1"
EOF
run
[ "$RC" -eq 0 ] && ok || bad "variable-source-ignored: a variable source was flagged (rc $RC): $OUT"

# heredoc-body-ignored: fixture data is data. Several suites WRITE a broken
# source line into a temp file on purpose to prove a guard fires on it.
fixture x-test.sh <<'FIXEOF'
#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
cat > "$T/probe.sh" <<'EOF'
. tests/lib/scratch.sh
EOF
FIXEOF
run
[ "$RC" -eq 0 ] && ok || bad "heredoc-body-ignored: a source inside a heredoc body was flagged (rc $RC): $OUT"

# heredoc-tag-any-token: the repo opens Python bodies with <<'@PY@'-style
# tags. A tag the header regex cannot read leaves that body scanned as shell,
# so the skip rule above would silently not apply where the header says it does.
fixture x-test.sh <<'FIXEOF'
#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
cat > "$T/probe.sh" <<'@PY@'
. tests/lib/scratch.sh
@PY@
FIXEOF
run
[ "$RC" -eq 0 ] && ok || bad "heredoc-tag-any-token: a source inside a <<'@PY@' body was flagged (rc $RC): $OUT"

# ── 4. output shape ─────────────────────────────────────────────────────────
# offender-line-format: <file>:<line>: <reason>, one per offending line, sorted.
fixture x-test.sh <<'EOF'
#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh"
echo between
. tests/lib/scratch.sh || exit 1
EOF
run
[ "$RC" -eq 1 ] && ok || bad "offender-line-format: rc was $RC, expected 1"
[ "$(grep -c . <<<"$OUT")" -eq 2 ] && ok || bad "offender-line-format: expected 2 offender lines, got: $OUT"
[ "$(grep -cE '^tests/[^:]+:[0-9]+: .+$' <<<"$OUT")" -eq 2 ] \
  && ok || bad "offender-line-format: lines are not <file>:<line>: <reason>: $OUT"
[ "$(sed -n 1p <<<"$OUT")" = "$(printf '%s\n' "$OUT" | sort -t: -k1,1 -k2,2n | sed -n 1p)" ] \
  && ok || bad "offender-line-format: offenders are not sorted: $OUT"

# ── 4b. the other suite dir ─────────────────────────────────────────────────
# mc-suites-are-scanned: tests/mc/*.sh is a suite dir CI runs (#929), so a
# suite that lands there is held to the same rule as one under tests/.
fixture x-test.sh <<'EOF'
#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
EOF
mkdir -p "$T/c/tests/mc"
cat > "$T/c/tests/mc/y-test.sh" <<'EOF'
#!/bin/bash
. "$(dirname "$0")/../lib/scratch.sh"
EOF
run
[ "$RC" -eq 1 ] && ok || bad "mc-suites-are-scanned: rc was $RC, expected 1"
grep -qE '^tests/mc/y-test\.sh:2: no failure handler' <<<"$OUT" \
  && ok || bad "mc-suites-are-scanned: expected the tests/mc/ offender on line 2, got: $OUT"

# ── 4c. a << that is prose, not an opener ────────────────────────
# A heredoc open that is really a quoted example in a comment or inside a
# string used to set the skip flag with a tag no line ever closes, and every
# line after it in that file was read as heredoc body — silently, with rc 0.
# Four suites at head ended mid-phantom-body this way, including this one.
#
# comment-heredoc-is-not-an-open
fixture x-test.sh <<'FIXEOF'
#!/bin/bash
# the runner used to deliver its script on the container stdin (bash -s <<'INNER')
# and then ran every suite without closing it.
. "$(dirname "$0")/lib/scratch.sh"
FIXEOF
run
[ "$RC" -eq 1 ] && ok || bad "comment-heredoc-is-not-an-open: rc was $RC, expected 1 (got: $OUT)"
grep -qE '^tests/x-test\.sh:4: no failure handler' <<<"$OUT" \
  && ok || bad "comment-heredoc-is-not-an-open: the line after a << in a comment was not scanned: $OUT"

# quoted-heredoc-is-not-an-open: the same shape inside a double-quoted string,
# which is how tests/auth-probe-classify-test.sh prints a probe body.
fixture x-test.sh <<'FIXEOF'
#!/bin/bash
bad() { echo "$1: expected $2, got $3  <<$4>>"; }
. "$(dirname "$0")/lib/scratch.sh"
FIXEOF
run
[ "$RC" -eq 1 ] && ok || bad "quoted-heredoc-is-not-an-open: rc was $RC, expected 1 (got: $OUT)"
grep -qE '^tests/x-test\.sh:3: no failure handler' <<<"$OUT" \
  && ok || bad "quoted-heredoc-is-not-an-open: the line after a << inside a string was not scanned: $OUT"

# unterminated-heredoc-is-rc-2: when the open IS real and no closer ever
# arrives, the tail of that file genuinely was not scanned. Same doctrine as a
# missing tests/ dir — an empty answer from a scan that never happened is not a
# clean tree — so it fails closed and names the tag.
fixture x-test.sh <<'FIXEOF'
#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
cat > "$T/probe.sh" <<'NOPE'
a body whose closer never arrives
FIXEOF
run
[ "$RC" -eq 2 ] && ok || bad "unterminated-heredoc-is-rc-2: rc was $RC, expected 2 (got: $OUT)"
grep -qE 'x-test\.sh:3: unterminated heredoc tag NOPE' <<<"$OUT" \
  && ok || bad "unterminated-heredoc-is-rc-2: rc 2 must name the file, line and tag: $OUT"

# ── 4d. the argument is cut at a real delimiter ─────────────────────
# cd-pwd-anchored-no-handler: $(cd "$(dirname "$0")" && pwd) is this repo's
# standard absolute-path idiom. Cutting the argument at the first && threw the
# path away mid-expression, so the source read as something else entirely and
# an unguarded one was never flagged.
fixture x-test.sh <<'FIXEOF'
#!/bin/bash
. "$(cd "$(dirname "$0")" && pwd)/lib/scratch.sh"
FIXEOF
run
[ "$RC" -eq 1 ] && ok || bad "cd-pwd-anchored-no-handler: rc was $RC, expected 1 (got: $OUT)"
grep -qE '^tests/x-test\.sh:2: no failure handler' <<<"$OUT" \
  && ok || bad "cd-pwd-anchored-no-handler: the cd-pwd path idiom was not flagged: $OUT"

# cd-pwd-anchored-with-guard: and the guarded one stays clean — the && inside
# the command substitution is not the handler delimiter.
fixture x-test.sh <<'FIXEOF'
#!/bin/bash
. "$(cd "$(dirname "$0")" && pwd)/lib/scratch.sh" || exit 1
FIXEOF
run
[ "$RC" -eq 0 ] && ok || bad "cd-pwd-anchored-with-guard: rc was $RC, expected 0 (got: $OUT)"

# ── 4e. a source line continued with a trailing backslash ───────────────────
# The handler, if there is one, sits on the NEXT line, which this line-at-a-time
# pass never sees. The ticket's rule is a SAME-line handler, so the plan's
# decision is to treat a continuation as no handler. What must not happen is
# what used to: `arg` ended in "\", so it matched no tests/lib/ shape at all and
# the line was not examined by either rule — silently, rc 0.
#
# continued-source-is-unhandled
fixture x-test.sh <<'FIXEOF'
#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" \
  || exit 1
FIXEOF
run
[ "$RC" -eq 1 ] && ok || bad "continued-source-is-unhandled: rc was $RC, expected 1 (got: $OUT)"
grep -qE '^tests/x-test\.sh:2: no failure handler' <<<"$OUT" \
  && ok || bad "continued-source-is-unhandled: a backslash-continued source line was not examined: $OUT"

# continued-source-with-no-handler-at-all: the same shape without a handler
# anywhere is the incident itself, and it was equally invisible.
fixture x-test.sh <<'FIXEOF'
#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" \
  2>/dev/null
FIXEOF
run
[ "$RC" -eq 1 ] && ok || bad "continued-source-with-no-handler-at-all: rc was $RC, expected 1 (got: $OUT)"
grep -qE '^tests/x-test\.sh:2: no failure handler' <<<"$OUT" \
  && ok || bad "continued-source-with-no-handler-at-all: expected a no-failure-handler reason on line 2, got: $OUT"

# continued-cwd-relative-reason-is-the-path: a continued CWD-relative source was
# already flagged, but the reason quoted the continuation too — the printed path
# has to be the path, or the reader cannot grep for it.
fixture x-test.sh <<'FIXEOF'
#!/bin/bash
. tests/lib/scratch.sh \
  || exit 1
FIXEOF
run
[ "$RC" -eq 1 ] && ok || bad "continued-cwd-relative-reason-is-the-path: rc was $RC, expected 1 (got: $OUT)"
grep -qE '^tests/x-test\.sh:2: cwd-relative path: tests/lib/scratch\.sh$' <<<"$OUT" \
  && ok || bad "continued-cwd-relative-reason-is-the-path: the reason must end at the path, got: $OUT"

# ── 5. could-not-scan fails closed ──────────────────────────────────────────
# missing-tests-dir-is-rc-2: an empty answer from a scan that never happened is
# not a clean tree.
OUT=$(bash "$LINT" "$T/nowhere" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok || bad "missing-tests-dir-is-rc-2: rc was $RC, expected 2"
[ -n "$OUT" ] && ok || bad "missing-tests-dir-is-rc-2: rc 2 must say why it could not scan"

# empty-tests-dir-is-rc-2: a tests/ that exists but holds no suite is the same
# sweep-over-nothing the runner half of this ticket calls rc 2. The two halves
# must not answer one question two ways.
rm -rf "$T/c"
mkdir -p "$T/c/tests/lib"
printf '#!/bin/bash\n' > "$T/c/tests/lib/scratch.sh"
run
[ "$RC" -eq 2 ] && ok || bad "empty-tests-dir-is-rc-2: rc was $RC, expected 2 (got: $OUT)"
[ -n "$OUT" ] && ok || bad "empty-tests-dir-is-rc-2: rc 2 must say why it could not scan"

# ── 6. the convention is written where the builders read it ────────────
# This lint kept landing red on main drift: four times on this PR alone a suite
# merged from main carrying an unhandled tests/lib/ source, because nothing a
# build box reads says what the handled form is. rules/CLAUDE.md is that file —
# bin/context-signature.sh renders it onto every box as ~/.claude/CLAUDE.md — so
# the convention has to be IN it, not only in tests/README.md which no build reads.
RULES="$DIR/rules/CLAUDE.md"
[ -f "$RULES" ] && ok || bad "rules-canon-exists: $RULES is missing"
# convention-is-in-the-canon-rules: one line that names both the helper dir and
# the handled form, so a builder writing a new suite copies the right shape.
grep -qE 'tests/lib/.*\|\| exit 1|\|\| exit 1.*tests/lib/' "$RULES" \
  && ok || bad "convention-is-in-the-canon-rules: rules/CLAUDE.md must carry the tests/lib/ sourcing convention with its || exit 1 handler"
# cwd-relative-is-named: the other half of the rule the lint enforces.
grep -qF 'dirname "$0"' "$RULES" \
  && ok || bad "cwd-relative-is-named: rules/CLAUDE.md must show the \$(dirname \"\$0\")-anchored form the lint requires"

rm -rf "$T/c"
echo "test-sources-lint: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
