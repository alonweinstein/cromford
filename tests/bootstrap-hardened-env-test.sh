#!/bin/bash
# tests/bootstrap-hardened-env-test.sh — the bootstrap preflight on a HARDENED
# box: never chmod a file that is already 600, go through harden-state.sh when
# one is immutable and wrong, and name every failure out loud.
#
# THE INCIDENT THIS PINS (box-small, 2026-09-16). The preflight ran
# `chmod 600 env/*.env` unconditionally, and chmod on a `chattr +i` file returns
# EPERM even when the mode is ALREADY 600. Under `set -e` the script died one
# line after printing "== preflight ==", with no FATAL of its own: no crons were
# installed, the box was never set up, and the loader that called it had nothing
# to report. Every new project loaded onto a hardened box hit it.
#
# The block is extracted VERBATIM from bin/bootstrap-machine.sh by its
# `# >>> preflight` / `# <<< preflight` markers (the same way
# tests/cron-fleet-parity-test.sh drives the crontab block) and run against a
# scratch env dir. chmod, chattr, harden-state.sh, node, claude and gh are stubs
# that LOG what they were asked to do, so the assertions are about calls and
# file modes, never about the text of the script.
#
# Run from anywhere: tests/bootstrap-hardened-env-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

# ── the production block, verbatim ──────────────────────────────────────────
awk '/^# >>> preflight/{f=1;next} /^# <<< preflight/{exit} f' \
  "$DIR/bin/bootstrap-machine.sh" > "$T/preflight.sh"
[ -s "$T/preflight.sh" ] && ok \
  || bad "could not extract the preflight block from bin/bootstrap-machine.sh — markers missing?"

# ── the stub box ────────────────────────────────────────────────────────────
mkdir -p "$T/bin" "$T/env"
export REAL_CHMOD; REAL_CHMOD=$(command -v chmod)
export CHMOD_LOG="$T/chmod.log" CHATTR_LOG="$T/chattr.log" HS_LOG="$T/hs.log"
export HS_FAIL="$T/hs-fail" CLAUDE_FAIL="$T/claude-fail" IMM="$T/immutable.list"

cat > "$T/bin/node" <<'STUB'
#!/bin/bash
echo "v22.0.0"
STUB
cat > "$T/bin/claude" <<'STUB'
#!/bin/bash
[ -f "${CLAUDE_FAIL:-/nonexistent}" ] && { echo "claude: not found" >&2; exit 1; }
echo "1.0.0 (Claude Code)"
exit 0
STUB
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
exit 0
STUB
# chattr must NEVER be called: the flag comes off and goes back on through
# harden-state.sh or not at all. A call here is a failure, logged and refused.
cat > "$T/bin/chattr" <<'STUB'
#!/bin/bash
echo "$*" >> "$CHATTR_LOG"
exit 1
STUB
# An immutable file answers EPERM to chmod whatever the mode already is.
cat > "$T/bin/chmod" <<'STUB'
#!/bin/bash
echo "$*" >> "$CHMOD_LOG"
for LAST; do :; done
if grep -qxF "$LAST" "${IMM:-/nonexistent}" 2>/dev/null; then
  echo "chmod: changing permissions of '$LAST': Operation not permitted" >&2
  exit 1
fi
exec "$REAL_CHMOD" "$@"
STUB
cat > "$T/bin/harden-state.sh" <<'STUB'
#!/bin/bash
echo "$1 $2" >> "$HS_LOG"
[ -f "${HS_FAIL:-/nonexistent}" ] && exit 2
case "$1" in
  --release) grep -vxF "$2" "$IMM" > "$IMM.tmp" 2>/dev/null || true; mv "$IMM.tmp" "$IMM" ;;
  --rearm)   grep -qxF "$2" "$IMM" 2>/dev/null || echo "$2" >> "$IMM" ;;
esac
exit 0
STUB
chmod +x "$T/bin/node" "$T/bin/claude" "$T/bin/gh" "$T/bin/chattr" \
         "$T/bin/chmod" "$T/bin/harden-state.sh"

reset() { # a box whose env files are both present and both 600
  rm -f "$CHMOD_LOG" "$CHATTR_LOG" "$HS_LOG" "$HS_FAIL" "$CLAUDE_FAIL" "$T/out"
  printf 'X=1\n' > "$T/env/global.env"
  printf 'X=1\n' > "$T/env/proj.env"
  "$REAL_CHMOD" 600 "$T/env/global.env" "$T/env/proj.env"
  : > "$IMM"
}
immutable() { printf '%s\n' "$@" > "$IMM"; }
lines()    { [ -f "$1" ] && grep -c '' "$1" || echo 0; }
mode()     { stat -c '%a' "$1"; }

run_preflight() { # -> rc, with the run's output in $T/out
  (
    cd "$T" || exit 1
    PATH="$T/bin:$PATH" HERE="$T/bin" HENV="$T/env" PROJECT=proj \
      bash -c 'set -euo pipefail; . ./preflight.sh'
  ) >"$T/out" 2>&1
  echo $?
}

# ── a. every env file is already 600 (and immutable): touch nothing ─────────
reset
immutable "$T/env/global.env" "$T/env/proj.env"
RC=$(run_preflight)
eq "a rc" "$RC" "0"
eq "a no chmod was attempted" "$(lines "$CHMOD_LOG")" "0"
eq "a harden-state was not called" "$(lines "$HS_LOG")" "0"

# ── b. a wrong mode on an IMMUTABLE file: release -> chmod -> rearm ─────────
reset
"$REAL_CHMOD" 644 "$T/env/proj.env"
immutable "$T/env/global.env" "$T/env/proj.env"
RC=$(run_preflight)
eq "b rc" "$RC" "0"
eq "b the file ends up at 600" "$(mode "$T/env/proj.env")" "600"
eq "b harden-state call 1" "$(sed -n 1p "$HS_LOG" 2>/dev/null)" "--release $T/env/proj.env"
eq "b harden-state call 2" "$(sed -n 2p "$HS_LOG" 2>/dev/null)" "--rearm $T/env/proj.env"
eq "b harden-state was called exactly twice" "$(lines "$HS_LOG")" "2"
eq "b the flag went back on" "$(grep -cxF "$T/env/proj.env" "$IMM")" "1"
grep -q 'global.env' "$CHMOD_LOG" 2>/dev/null \
  && bad "b the already-600 global.env must not be chmod'ed" || ok
eq "b chattr was never called" "$(lines "$CHATTR_LOG")" "0"

# ── c. a wrong mode on a plain file: the ordinary chmod path ────────────────
reset
"$REAL_CHMOD" 644 "$T/env/proj.env"
RC=$(run_preflight)
eq "c rc" "$RC" "0"
eq "c the file ends up at 600" "$(mode "$T/env/proj.env")" "600"
eq "c harden-state was not called" "$(lines "$HS_LOG")" "0"
eq "c chattr was never called" "$(lines "$CHATTR_LOG")" "0"

# ── d. harden-state refuses: FATAL, non-zero, nothing half-done ─────────────
reset
"$REAL_CHMOD" 644 "$T/env/proj.env"
immutable "$T/env/proj.env"
: > "$HS_FAIL"
RC=$(run_preflight)
[ "$RC" -ne 0 ] && ok || bad "d a preflight that cannot fix the mode must fail (rc=$RC)"
grep -q '^FATAL: preflight:' "$T/out" && ok || bad "d the failure must name itself: $(cat "$T/out")"
eq "d the mode is left as it was" "$(mode "$T/env/proj.env")" "644"
eq "d it stopped at the release" "$(lines "$HS_LOG")" "1"

# ── e. a missing tool fails BEFORE anything is touched ─────────────────────
reset
: > "$CLAUDE_FAIL"
RC=$(run_preflight)
[ "$RC" -ne 0 ] && ok || bad "e a missing claude CLI must fail the preflight (rc=$RC)"
grep -q '^FATAL: preflight:' "$T/out" && ok || bad "e the failure must name itself: $(cat "$T/out")"
eq "e it failed before the chmod loop" "$(lines "$CHMOD_LOG")" "0"

# ── f. a missing project env file ──────────────────────────────────────────
reset
rm -f "$T/env/proj.env"
RC=$(run_preflight)
[ "$RC" -ne 0 ] && ok || bad "f a missing env file must fail the preflight (rc=$RC)"
grep -q '^FATAL: preflight:' "$T/out" && ok || bad "f the failure must name itself: $(cat "$T/out")"

echo "bootstrap-hardened-env-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
