#!/bin/bash
# tests/gh-shim-token-prefix.bh-789-test.sh — the REST shim's own identifiers
# must not be shaped like a GitHub credential.
#
# WHY THIS EXISTS. `ghs_` is GitHub's App INSTALLATION TOKEN prefix — the exact
# string bin/run-triage.sh matches on to tell an installation token from a box
# login. The shim borrowed it as its function/variable prefix, so every
# `ghs_passthru` / `ghs_paginate` / `ghs_fields_ok` call read to
# checks/secret-literals as `gh[pousr]_` + six alphanumerics, i.e. a credential
# pasted into source. PR #967 was parked BLOCKED_HUMAN on 13 such hits, none of
# them a secret. The fix was the prefix, not the scanner: a shim helper is now
# `gshim_*`, which cannot collide with ghp_/gho_/ghu_/ghs_/ghr_/github_pat_.
#
# WHAT IT PROVES, on the shipped shim sources (not on a fixture):
#   1. a positive control — the catalog check still fires on a full-length
#      credential carrying the OLD prefix, so a green run here is a real pass
#      and not a scanner that matches nothing;
#   2. bin/checks-run.sh over every shim source — the entry point plus every
#      handler present in bin/lib/gh-shim/, derived from disk, not a fixed
#      list — as added lines, reports no secret-literals hit;
#   3. no shim identifier matches a GitHub token prefix shape at all, stated
#      independently of the catalog so this survives a catalog rewrite.
#
# Self-contained: no network, no secrets, no $HARNESS.
# Run from anywhere:  bash tests/gh-shim-token-prefix.bh-789-test.sh (exit 0 = pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUN="$DIR/bin/checks-run.sh"
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The shim is one program spread over the entry point plus every handler in
# bin/lib/gh-shim/; all of them are scanned on any diff that touches them, so
# all of them are held to this. DERIVED from the filesystem, never a hand-kept
# list: a hard-coded list silently stops covering the next handler that lands
# (BH-788's four read handlers were invisible to this suite while it named only
# the three write handlers), and a guard that does not grow with the program is
# a guard that reports green on the file nobody added to it.
SHIM_FILES="bin/gh-rest-shim"
for F in "$DIR"/bin/lib/gh-shim/*.sh; do
  [ -e "$F" ] || continue
  SHIM_FILES="$SHIM_FILES bin/lib/gh-shim/$(basename "$F")"
done

# ── 0. the derived list really covers every handler on disk ──────────────────
# Without this the suite could pass by scanning nothing at all.
N_ON_DISK=$(find "$DIR/bin/lib/gh-shim" -maxdepth 1 -name '*.sh' -type f | wc -l | tr -d ' ')
N_LISTED=$(printf '%s\n' $SHIM_FILES | grep -c '^bin/lib/gh-shim/')
if [ "$N_ON_DISK" -ge 1 ] && [ "$N_LISTED" -eq "$N_ON_DISK" ]; then
  ok
else
  bad "SHIM_FILES covers $N_LISTED of $N_ON_DISK handler(s) in bin/lib/gh-shim/"
fi

# Render files as a unified diff in which every line is an addition — the shape
# bin/checks-run.sh normalizes, and the shape the merge conductor sees when
# these files first land.
as_added_diff() {
  local f n
  for f in "$@"; do
    [ -f "$DIR/$f" ] || { echo "MISSING $f" >&2; return 1; }
    n=$(wc -l <"$DIR/$f" | tr -d ' ')
    printf -- '--- /dev/null\n+++ b/%s\n@@ -0,0 +1,%s @@\n' "$f" "$n"
    sed 's/^/+/' "$DIR/$f"
  done
}

# ── 1. positive control: the check still fires on the old prefix ─────────────
# Assembled at run time so this line is not itself a token-shaped literal.
#
# THE CONTROL IS A REAL-LENGTH TOKEN, not a short identifier. An installation
# token is the prefix plus 36 characters, and that 40-character literal is the
# one shape checks/secret-literals must catch under ANY tightening of its
# heuristics — a control built from a 13-character identifier (`ghs_passthru
# untranslated`) instead measures whatever length floor the check happens to
# carry today, and goes red the moment the check stops flagging short
# identifiers rather than because the scanner died. The identifier half of that
# question is section 3's job, which is stated independently of the catalog and
# does not depend on the check at all. FIXTURE marker inside the literal so the
# mirror leak guard reads it as a fixture and not as a rotated credential.
OLD="gh""s_"
CTRL_TAIL="FIXTUREbh789CONTROLnotatoken00000000"
{
  printf -- '--- /dev/null\n+++ b/bin/lib/gh-shim/control.sh\n@@ -0,0 +1,1 @@\n'
  printf '+  TOKEN="%s%s"\n' "$OLD" "$CTRL_TAIL"
} >"$T/control.diff"
if [ "$(( ${#OLD} + ${#CTRL_TAIL} ))" -eq 40 ]; then
  ok
else
  bad "positive control literal is $(( ${#OLD} + ${#CTRL_TAIL} )) chars, not the 40 an installation token is — the control no longer stands in for a real credential"
fi
CTRL=$("$RUN" "$T/control.diff" 2>&1)
case "$CTRL" in
  *"CHECK-HIT secret-literals"*) ok ;;
  *) bad "positive control: secret-literals did not fire on a full-length ${OLD}token — this suite would pass vacuously. Got: $CTRL" ;;
esac

# ── 2. the shipped shim scans clean for secret-literals ──────────────────────
if as_added_diff $SHIM_FILES >"$T/shim.diff"; then
  ok
else
  bad "could not render the shim sources as a diff"
fi
OUT=$("$RUN" "$T/shim.diff" 2>&1)
HITS=$(printf '%s\n' "$OUT" | grep -c '^CHECK-HIT secret-literals ' )
if [ "$HITS" -eq 0 ]; then
  ok
else
  bad "shim sources report $HITS secret-literals hit(s):
$(printf '%s\n' "$OUT" | grep '^CHECK-HIT secret-literals ')"
fi

# ── 3. no shim identifier is shaped like a GitHub credential ─────────────────
# Stated here in full, not delegated to the catalog: ghp_ (classic PAT), gho_
# (OAuth), ghu_ (user-to-server), ghs_ (installation), ghr_ (refresh) and
# github_pat_ (fine-grained). Six trailing alphanumerics is what the catalog
# uses and what the real tokens have.
for F in $SHIM_FILES; do
  BADID=$(grep -nE 'gh[pousr]_[A-Za-z0-9]{6}|github_pat_[A-Za-z0-9_]' "$DIR/$F" || true)
  if [ -z "$BADID" ]; then
    ok
  else
    bad "$F carries a GitHub-token-shaped string:
$BADID"
  fi
done

echo "gh-shim-token-prefix: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
