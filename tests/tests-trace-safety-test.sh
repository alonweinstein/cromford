#!/bin/bash
# tests/tests-trace-safety-test.sh — bin/test-trace-safety.sh must catch a
# deletion or a literal redirect that leaves the temp roots, and must never
# report a clean tree from a scan that did not happen.
#
# WHY (#388, root cause #404, scope #394). tests/auth-probe-classify-test.sh set
# `trap 'rm -rf "$H"'`, then sourced a bin/ script that reassigned H to the LIVE
# harness root. Nothing in the text of that test is wrong: the clobber happens at
# run time, one file away. The static check (checks/tests-scratch-only) reads the
# text; this lane runs the suite and reads what it actually did.
#
# Every fixture here is built from a heredoc under $T, never as a file in the
# repo, because bin/repro-gate.sh globs added test files and runs them. Every
# fixture that must be a HIT aims at /dev/null/no-such-harness… or
# /nonexistent-trace-safety/… — /dev/null is not a directory, so the deletion
# cannot reach anything even when something executes the fixture directly.
#
# The sections in order: A enumeration and refusals, B a clean tree (the
# negatives), C the #404 sourced-clobber shape, D cd-then-relative-rm, E a child
# bash, F a literal redirect, G find -delete / truncate / git clean, H the env
# hygiene the ticket names (HARNESS, H, HARNESS_CHECKOUT unset), I capture
# hygiene, J the inherited-SCRATCH guard, K nonzero exits and timeouts are
# counted and never judged, L fail-closed when the parser or the shell is dead,
# M the allow-list mutation the ticket asks for, N the live-harness guard.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUN="$DIR/bin/test-trace-safety.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# The runner mirrors scratch.sh's live-harness guard, so on a box it needs the
# same opt-in in this process's environment that the library already required
# before this line could run at all.
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi

mktree() { # <name> -> path of a fresh fixture tree with a tests/ dir
  mkdir -p "$T/$1/tests"
  printf '%s\n' "$T/$1"
}

# ── A. enumeration and the refusals ─────────────────────────────────────────
A=$(mktree enum)
for F in a-test.sh b-test.sh c-test.sh; do
  printf '#!/bin/bash\necho %s\n' "$F" > "$A/tests/$F"
done
mkdir -p "$A/tests/lib"
printf 'true\n' > "$A/tests/lib/helper.sh"
OUT=$("$RUN" --list "$A" 2>&1); RC=$?
EXPECT='tests/a-test.sh
tests/b-test.sh
tests/c-test.sh'
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXPECT" ]; then ok
else bad "A: --list should print the three tests and nothing under tests/lib (rc=$RC) [$OUT]"; fi

LIBONLY=$(mktree libonly)
mkdir -p "$LIBONLY/tests/lib"
printf 'true\n' > "$LIBONLY/tests/lib/x.sh"
OUT=$("$RUN" "$LIBONLY" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && has "CHECK-ERROR test-trace-safety:" "$OUT"; then ok
else bad "A: a tree with no tests/*.sh must refuse with rc 2 (rc=$RC) [$OUT]"; fi

OUT=$("$RUN" /nonexistent 2>&1); RC=$?
if [ "$RC" -eq 2 ] && has "CHECK-ERROR test-trace-safety:" "$OUT"; then ok
else bad "A: /nonexistent must exit 2 with a CHECK-ERROR line (rc=$RC) [$OUT]"; fi

OUT=$("$RUN" --nope "$A" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && has "CHECK-ERROR test-trace-safety:" "$OUT"; then ok
else bad "A: an unknown flag must exit 2 with a CHECK-ERROR line (rc=$RC) [$OUT]"; fi

OUT=$(TRACE_SAFETY_TEST_TIMEOUT=soon "$RUN" "$A" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && has "TRACE_SAFETY_TEST_TIMEOUT" "$OUT"; then ok
else bad "A: a non-numeric timeout must be refused, never clamped (rc=$RC) [$OUT]"; fi

# --help prints the header, and the header's LAST line is in it: the line range
# is hand-written, so a header that grows must not silently truncate the gaps
# and the rc table an operator came for.
OUT=$("$RUN" --help 2>&1); RC=$?
if [ "$RC" -eq 0 ] && has "KNOWN GAPS" "$OUT" && has "DELETES ONLY ITS OWN" "$OUT"; then ok
else bad "A: --help must print the whole header (rc=$RC) [$(printf '%s' "$OUT" | tail -2)]"; fi

# ── B. a clean tree: the negatives carry the weight ──────────────────────────
FINE=$(mktree fine)
cat > "$FINE/tests/fine-test.sh" <<'FIXEOF'
#!/bin/bash
set -uo pipefail
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/a" "$D/sub"
: > "$D/f"
rm -rf "$D/a"
truncate -s 0 "$D/f"
find "$D" -name nothing-here -delete
git -C "$D" clean -fdx 2>/dev/null
bash -c 'echo hi > /dev/null'
bash -c 'echo hi >&2' 2>/dev/null
bash -c 'echo hi 2>&1' >/dev/null
# The two shapes the first full-tree run flagged 106 times: a test that PRINTS a
# command string, and a branch name with angle brackets. Neither redirects
# anything, and neither may ever be a hit again.
echo 'FAIL: OVER-BLOCKED: cat >/root/harness/state/x.json'
echo 'the union branch must be batch/<project>/<stamp>'
printf '%s\n' 'rm -rf /root/harness is what the guard must refuse'
# A redirect inside an ssh argument names a path on another machine. The full
# tree run flagged bin/fly-results-ingest.sh's real ssh line this way; it is not
# a hit. (A function, so the fixture needs no ssh on PATH.)
ssh() { :; }
ssh -o BatchMode=yes root@10.0.0.9 'mkdir -p /root/harness/state; cat > /root/harness/state/x.json'
# xtrace spells an embedded single quote '\'' — close, escaped quote, reopen.
# Reading that as an opener left the rest of the string unquoted and turned
# these two real trace lines into deletions of /' and /root/harness/env.
OUT='queue-line-drop.sh: refusing key '\''TK-2; rm -rf /'\'' (not a ticket key)'
CMD='cat > /tmp/notes.md <<'\''EOF'\'' rm -rf /root/harness/env EOF'
printf '%s %s\n' "$OUT" "$CMD" > /dev/null
# /dev/shm is a temp root too: the harness keeps short-lived secrets there.
if [ -d /dev/shm ]; then S=$(mktemp -d /dev/shm/trace-safety-fixture.XXXXXX) && rm -rf "$S"; fi
cd "$D" || exit 1
bash -c 'echo hi > relative-unexpanded'
rm -rf sub
exit 0
FIXEOF
OUT=$("$RUN" "$FINE" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && has "TRACE: 1 tests, 0 nonzero exit(s), 0 hit(s)" "$OUT"; then ok
else bad "B: the clean fixture must pass with no hits (rc=$RC) [$OUT]"; fi

# B2. $TMPDIR is an allowed root even when it is nowhere near /tmp.
TD=$(mktree tmpdir-tree)
mkdir -p "$T/own-tmp"
cat > "$TD/tests/tmpdir-test.sh" <<'FIXEOF'
#!/bin/bash
set -uo pipefail
D=$(mktemp -d)
mkdir -p "$D/x"
rm -rf "$D/x"
rm -rf "$D"
exit 0
FIXEOF
OUT=$(TMPDIR="$T/own-tmp" "$RUN" "$TD" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && has "0 hit(s)" "$OUT"; then ok
else bad "B2: a deletion under \$TMPDIR must be allowed (rc=$RC) [$OUT]"; fi

# ── C-G. one tree of hit shapes, one run, one assertion per shape ────────────
HITS=$(mktree hits)
mkdir -p "$HITS/tests/lib"
printf 'H=/dev/null/no-such-harness\n' > "$HITS/tests/lib/clobber.sh"
cat > "$HITS/tests/sourced-clobber-test.sh" <<'FIXEOF'
#!/bin/bash
set -uo pipefail
H=$(mktemp -d)
trap 'rm -rf "$H"' EXIT
. "$(dirname "$0")/lib/clobber.sh"
exit 0
FIXEOF
cat > "$HITS/tests/cd-then-rm-test.sh" <<'FIXEOF'
#!/bin/bash
set -uo pipefail
cd / || exit 1
rm -rf ./trace-safety-fixture-does-not-exist
exit 0
FIXEOF
cat > "$HITS/tests/child-bash-test.sh" <<'FIXEOF'
#!/bin/bash
set -uo pipefail
bash -c 'rm -rf /dev/null/no-such-harness'
exit 0
FIXEOF
cat > "$HITS/tests/redirect-test.sh" <<'FIXEOF'
#!/bin/bash
set -uo pipefail
sh -c ': > /dev/null/no-such-harness/out' 2>/dev/null
exit 0
FIXEOF
cat > "$HITS/tests/find-delete-test.sh" <<'FIXEOF'
#!/bin/bash
set -uo pipefail
find /dev/null/no-such-harness -name x -delete 2>/dev/null
exit 0
FIXEOF
cat > "$HITS/tests/truncate-test.sh" <<'FIXEOF'
#!/bin/bash
set -uo pipefail
truncate -s 0 /dev/null/no-such-harness/f 2>/dev/null
exit 0
FIXEOF
cat > "$HITS/tests/git-clean-test.sh" <<'FIXEOF'
#!/bin/bash
set -uo pipefail
git -C /dev/null/no-such-harness clean -fdx 2>/dev/null
exit 0
FIXEOF
OUT=$("$RUN" "$HITS" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok || bad "C-G: a tree with hits must exit 1 (rc=$RC) [$OUT]"
has "HIT sourced-clobber-test.sh rm /dev/null/no-such-harness " "$OUT" && ok \
  || bad "C: the sourced helper reassigning the trap variable was not caught [$OUT]"
has "HIT cd-then-rm-test.sh rm /trace-safety-fixture-does-not-exist " "$OUT" && ok \
  || bad "D: a relative rm after cd / was not resolved against the traced cwd [$OUT]"
has "cwd /)" "$OUT" && ok || bad "D: the hit line must carry the cwd the rm ran in [$OUT]"
has "HIT child-bash-test.sh rm /dev/null/no-such-harness " "$OUT" && ok \
  || bad "E: a deletion inside a child bash -c was not traced [$OUT]"
has "HIT redirect-test.sh redirect /dev/null/no-such-harness/out " "$OUT" && ok \
  || bad "F: a literal redirect outside the temp roots was not caught [$OUT]"
has "HIT find-delete-test.sh find-delete /dev/null/no-such-harness " "$OUT" && ok \
  || bad "G: find … -delete outside the temp roots was not caught [$OUT]"
has "HIT truncate-test.sh truncate /dev/null/no-such-harness/f " "$OUT" && ok \
  || bad "G: truncate outside the temp roots was not caught [$OUT]"
has "HIT git-clean-test.sh git-clean /dev/null/no-such-harness " "$OUT" && ok \
  || bad "G: git -C … clean outside the temp roots was not caught [$OUT]"
has "TRACE: 7 tests, " "$OUT" && ok || bad "C-G: all seven fixtures must be traced [$OUT]"
has ", 7 hit(s)" "$OUT" && ok || bad "C-G: expected exactly seven hits, no more [$OUT]"

# ── H. the env the ticket names is not there for any test ────────────────────
ENVT=$(mktree envtree)
mkdir -p "$T/keep" "$T/hout"
cat > "$ENVT/tests/env-test.sh" <<'FIXEOF'
#!/bin/bash
printf '%s|%s|%s\n' "${HARNESS:-unset}" "${H:-unset}" "${HARNESS_CHECKOUT:-unset}" > "$FX_OUT/env.txt"
if [ -n "${H:-}" ]; then rm -rf "$H"; fi
exit 0
FIXEOF
OUT=$(HARNESS="$T/keep" H="$T/keep" HARNESS_CHECKOUT="$T/keep" FX_OUT="$T/hout" \
      "$RUN" "$ENVT" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$T/hout/env.txt" 2>/dev/null)" = "unset|unset|unset" ]; then ok
else bad "H: HARNESS/H/HARNESS_CHECKOUT reached the test (rc=$RC) [$(cat "$T/hout/env.txt" 2>/dev/null)] [$OUT]"; fi
[ -d "$T/keep" ] && ok || bad "H: the test deleted the directory those variables pointed at"

# ── I + J. captures stay clean; an inherited SCRATCH cannot be removed ───────
IJ=$(mktree capture)
mkdir -p "$T/fakescratch"
cat > "$IJ/tests/capture-test.sh" <<'FIXEOF'
#!/bin/bash
set -uo pipefail
OUT=$(bash -c 'echo clean' 2>&1)
[ "$OUT" = clean ] || exit 7
exit 0
FIXEOF
cat > "$IJ/tests/stale-scratch-test.sh" <<'FIXEOF'
#!/bin/bash
if [ -n "${SCRATCH:-}" ]; then rm -rf "$SCRATCH"; fi
if [ -n "${T:-}" ]; then rm -rf "$T"; fi
exit 0
FIXEOF
OUT=$(SCRATCH="$T/fakescratch" T="$T/fakescratch" "$RUN" "$IJ" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && has "TRACE: 2 tests, 0 nonzero exit(s), 0 hit(s)" "$OUT"; then ok
else bad "I: the trace must not pollute a \$(… 2>&1) capture (rc=$RC) [$OUT]"; fi
[ -d "$T/fakescratch" ] && ok || bad "J: an inherited SCRATCH/T reached the test and it removed the tree"

# ── K. nonzero exits and timeouts are counted and named, never judged ───────
SLOW=$(mktree slow)
printf '#!/bin/bash\nexit 3\n' > "$SLOW/tests/failing-test.sh"
cat > "$SLOW/tests/hang-test.sh" <<'FIXEOF'
#!/bin/bash
sleep 30  # determinism: ok the sleep IS the fixture here; the runner's 1s timeout is the assertion
FIXEOF
OUT=$(TRACE_SAFETY_TEST_TIMEOUT=1 "$RUN" "$SLOW" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && has "TRACE: 2 tests, 2 nonzero exit(s), 0 hit(s)" "$OUT"; then ok
else bad "K: failing tests are counted, not a hit, and do not set rc (rc=$RC) [$OUT]"; fi
has "EXIT 3 failing-test.sh" "$OUT" && ok || bad "K: a failing test must be named [$OUT]"
has "TIMEOUT hang-test.sh" "$OUT" && ok || bad "K: a timed-out test must be named [$OUT]"

# ── L. fail closed: a scan that did not happen is never a clean tree ────────
mkdir -p "$T/deadawk"
printf '#!/bin/bash\nexit 3\n' > "$T/deadawk/awk"; chmod 755 "$T/deadawk/awk"
OUT=$(PATH="$T/deadawk:$PATH" "$RUN" "$FINE" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && has "CHECK-ERROR test-trace-safety:" "$OUT" && ! has "TRACE:" "$OUT"; then ok
else bad "L: a dead awk stage must be rc 2 with no TRACE line (rc=$RC) [$OUT]"; fi

# /bin/true, not a bash one-liner: a `#!/bin/bash` stub would itself read
# BASH_ENV and trace its own `exit 0`, so it would not be the silent shell this
# section needs.
mkdir -p "$T/deadbash"
ln -sf /bin/true "$T/deadbash/bash"
OUT=$(PATH="$T/deadbash:$PATH" "$RUN" "$FINE" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && has "no trace" "$OUT" && ! has "TRACE:" "$OUT"; then ok
else bad "L: an empty trace must be rc 2, never 0 hits (rc=$RC) [$OUT]"; fi

# ── M. the mutation the ticket asks for: neuter an allow-list prefix ────────
mkdir -p "$T/mut"
sed 's#/tmp/\*#/nonexistent-mutated/*#' "$RUN" > "$T/mut/test-trace-safety.sh"
chmod 755 "$T/mut/test-trace-safety.sh"
if cmp -s "$RUN" "$T/mut/test-trace-safety.sh" \
   || [ ! -s "$T/mut/test-trace-safety.sh" ] \
   || ! grep -q '/nonexistent-mutated/' "$T/mut/test-trace-safety.sh"; then
  bad "M: the mutation sed changed nothing — the allow-list prefix moved, so this check proves nothing"
else
  ok
  OUT=$(env -u TMPDIR -u RUNNER_TEMP "$T/mut/test-trace-safety.sh" "$FINE" 2>&1); RC=$?
  if [ "$RC" -eq 1 ] && has "HIT fine-test.sh" "$OUT"; then ok
  else bad "M: with /tmp removed from the allow-list the clean fixture must go red (rc=$RC) [$OUT]"; fi
fi

# ── O. a runner run BY a runner ────────────────────────────────────────────
# This suite is one of the tests/*.sh the runner executes, so the runner ends up
# running under its own trace: fd 199 open, BASH_ENV set, xtrace on. Its own
# trace lines then landed in the file it was about to read as the test's, which
# disarmed the empty-trace guard — 0 hits from a shell that never ran.
# This file is one of the tests/*.sh the runner runs, so the check is literally
# "run this suite through the runner and it must still pass". Before the runner
# stopped tracing itself (`set +x` at the top), its own xtrace landed in the
# trace file it then read as the test's — non-empty from a shell that never ran,
# and section L above went green on a scan that had not happened. TRACE_SAFETY_NEST
# is how the copy knows to skip this section: the environment reaches the test,
# so without it this would recurse forever.
if [ -z "${TRACE_SAFETY_NEST:-}" ]; then
  NESTTREE=$(mktree nesttree)
  mkdir -p "$NESTTREE/tests/lib" "$NESTTREE/bin"
  cp "$0" "$NESTTREE/tests/"
  cp "$(dirname "$0")/lib/scratch.sh" "$NESTTREE/tests/lib/"
  cp "$RUN" "$NESTTREE/bin/"
  OUT=$(TRACE_SAFETY_NEST=1 "$RUN" "$NESTTREE" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && has "0 nonzero exit(s), 0 hit(s)" "$OUT"; then ok
  else bad "O: this suite does not pass when the runner runs it (rc=$RC) [$OUT]"; fi
fi

# ── N. the live-harness guard (root only) ──────────────────────────────────
if [ "$(id -u)" -eq 0 ]; then
  mkdir -p "$T/fake-root"
  OUT=$(env -u HARNESS_TEST_SANDBOX HARNESS_ROOT_OVERRIDE="$T/fake-root" \
        "$RUN" "$FINE" 2>&1); RC=$?
  if [ "$RC" -eq 2 ] && has "HARNESS_TEST_SANDBOX" "$OUT"; then ok
  else bad "N: as root next to a live harness the runner must refuse (rc=$RC) [$OUT]"; fi
  OUT=$(HARNESS_TEST_SANDBOX=1 HARNESS_ROOT_OVERRIDE="$T/fake-root" "$RUN" "$FINE" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && has "TRACE: 1 tests" "$OUT"; then ok
  else bad "N: HARNESS_TEST_SANDBOX=1 must let the run proceed (rc=$RC) [$OUT]"; fi
else
  echo "skip: guard needs root"
fi

echo "tests-trace-safety: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
