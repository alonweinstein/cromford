#!/bin/bash
# tests/remote-gate.bh-1527-test.sh — the Fly test host sees the git context CI
# sees (BH-1527).
#
# THE BUG. bin/remote-gate.sh uploaded the worktree without .git and snapshotted
# it on the host as a fresh one-commit repo: no origin/main, no merge base. Every
# test arm that diffs the branch against main then either printed "note: no merge
# base" or diffed against nothing, and exited 0. Twice on 2026-09-22 the host said
# green while CI was red (#1496: tests/priority-rank-test.sh A10), and a reviewer
# waited ~20 minutes for CI to learn what the host should have said.
#
# WHAT THIS PINS, all through the REAL composed job (the ssh shim captures it,
# the rsync shim copies the upload into a fixture "host" tree, and the job runs
# there — the same seam tests/remote-gate-test.sh uses):
#   1. a branch shaped like #1496's (triage-hotfix-lib.sh plus unrelated bin/
#      files) under the pre-#1496 A10 trigger is RED on the host exactly as it
#      is red on CI; the live A10 is quiet on both.
#   2. a branch that IS BH-644's slice plus a stray is red on both under the live
#      A10, and a BH-984-shaped branch is red on both under the live A15.
#   3. the host's `git merge-base HEAD origin/main` and
#      `git diff --name-only origin/main...HEAD` equal CI's, and the gate prints
#      the base sha and merge base it used.
#   4. a suite that prints "no merge base" FAILS the run (it passed silently
#      before), in suites mode and in -- mode.
# The live A10 and A15 blocks are CUT from tests/priority-rank-test.sh and
# tests/run-rollout.bh-984-test.sh at run time, so this follows them; only the
# pre-#1496 trigger is frozen here, as the historical fixture it is.
#
# Nothing here talks to Fly: flyctl, ssh, rsync, nc and ssh-keygen are PATH shims.
#
# Run from anywhere: tests/remote-gate.bh-1527-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GATE="$DIR/bin/remote-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$GATE" ] || { echo "FAIL: bin/remote-gate.sh does not exist"; exit 1; }

FIX="$T/fix"; mkdir -p "$FIX" "$T/fakebin" "$T/h/flags" "$T/h/logs" "$T/home"
: > "$T/h/flags/lane-off-testhost-tick"
# git from PATH first: /usr/bin/git on a Mac is an xcrun shim that may refuse to run.
JOBPATH="$(dirname "$(command -v git)"):/usr/bin:/bin:/usr/sbin:/sbin"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/home/.gitconfig"
git config --global init.defaultBranch main
git config --global advice.detachedHead false

# ── the shims ────────────────────────────────────────────────────────────────
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$1 ${2:-}" in
  "proxy "*|"proxy") : > "$FIX/proxy-up"; exit 0 ;;
  "ssh issue") shift 3; printf 'k\n' > "$1"; printf 'c\n' > "$1-cert.pub"; exit 0 ;;
esac
exit 0
STUB
cat > "$T/fakebin/nc" <<'STUB'
#!/bin/bash
[ -f "$FIX/proxy-up" ] && exit 0
exit 1
STUB
# The upload is REAL here: it lands under $FIX/host/<remote path>, minus the
# directories bin/remote-gate.sh excludes, so the job runs against what was sent.
cat > "$T/fakebin/rsync" <<'STUB'
#!/bin/bash
src="${*: -2:1}"; dst="${*: -1}"; dst="$FIX/host${dst#root@localhost:}"
echo "$dst" >> "$FIX/uploads"
mkdir -p "$dst" || exit 23
( cd "$src" && tar cf - --exclude ./.git --exclude ./node_modules --exclude ./.claude \
    --exclude ./.codegraph . ) | ( cd "$dst" && tar xf - ) || exit 23
STUB
cat > "$T/fakebin/ssh" <<'STUB'
#!/bin/bash
case "$*" in *"bash -s"*) cat > "$FIX/job"; exit 0 ;; esac
exit 0
STUB
printf '#!/bin/bash\necho "        Valid: from 2026-01-01T00:00:00 to 2099-01-01T00:00:00"\n' > "$T/fakebin/ssh-keygen"
chmod +x "$T/fakebin"/*
export FIX

# gate <args...> — compose (and "send") a job; GOUT/GRC are the client's output.
gate() {
  # Every run uploads under its own run id, so the host tree needs no clearing.
  rm -f "$FIX/job" "$FIX/uploads"
  GOUT=$(env PATH="$T/fakebin:$PATH" HOME="$T/home" HARNESS="$T/h" \
    TESTHOST_APP=fixture TESTHOST_PORT=10022 TESTHOST_ORG=fixture-org \
    TESTHOST_KEY="$T/key" REMOTE_GATE_PROXY_WAIT_S=2 bash "$GATE" "$@" 2>&1); GRC=$?
}
# host — run the captured job against the uploaded tree; JOUT/JRC.
host() {
  local root
  root=$(head -1 "$FIX/uploads" 2>/dev/null); root="${root%/base/}"; root="${root%/base}"
  JOUT=$(cd / && env -i PATH="$JOBPATH" HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig" \
    GIT_CONFIG_NOSYSTEM=1 RG_RUN_DIR="$root" bash "$FIX/job" 2>&1); JRC=$?
}

# ── the fixture repo ─────────────────────────────────────────────────────────
# The live A10 arm, cut from the real suite, wrapped so it runs on its own.
wrap() { # wrap <body-file> <out> — a runnable suite around a cut block
  { echo '#!/bin/bash'; echo 'set -uo pipefail'
    echo 'DIR=$(cd "$(dirname "$0")/.." && pwd); FAIL=0'
    echo 'ok() { :; }; bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }'
    cat "$1"; echo '[ "$FAIL" -eq 0 ]'; } > "$2"
}
awk '/^# ---------- A10\./{f=1} /^# ---------- A11\./{exit} f' "$DIR/tests/priority-rank-test.sh" > "$T/a10.body"
grep -q 'a10_own_slice' "$T/a10.body" && grep -q 'STRAY=' "$T/a10.body" && ok \
  || bad "could not cut the live A10 block out of tests/priority-rank-test.sh"
awk '/^a15_untouched\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$DIR/tests/run-rollout.bh-984-test.sh" > "$T/a15.body"
echo 'a15_untouched' >> "$T/a15.body"
grep -q 'FORBIDDEN=' "$T/a15.body" && ok || bad "could not cut a15_untouched out of tests/run-rollout.bh-984-test.sh"
# The pre-#1496 A10 trigger, frozen: it fired on ANY branch touching either lib.
cat > "$T/a10pre.body" <<'PRE'
B=main; git -C "$DIR" rev-parse --verify -q main >/dev/null || B=origin/main
OWN=$(git -C "$DIR" diff --name-only "$B" 2>/dev/null; git -C "$DIR" diff --name-only 2>/dev/null)
if ! grep -qE '^(\.harness/specs/BH-64[45]/|bin/lib/hotfix-lib\.sh$|bin/lib/triage-hotfix-lib\.sh$)' <<<"$(printf '%s\n' "$OWN")"; then
  echo "note: this branch is not BH-644/BH-645's slice — the A10 untouched-files arm judges only those tickets' own branches"
elif git -C "$DIR" rev-parse --verify -q "$B" >/dev/null; then
  STRAY=$(git -C "$DIR" diff --name-only "$B" -- bin/ \
          | grep -v -e '^bin/lib/hotfix-lib.sh$' -e '^bin/run-build.sh$' \
                    -e '^bin/run-triage.sh$' -e '^bin/merge-conductor.sh$' \
                    -e '^bin/lib/rt/scope.sh$' -e '^bin/lib/rt/shards.sh$' \
                    -e '^bin/lib/triage-hotfix-lib.sh$' | head -5)
  [ -z "$STRAY" ] && ok || bad "the slices on this branch may touch only ...: $STRAY"
fi
PRE
printf 'git merge-base HEAD origin/main || echo "note: no merge base"\ngit diff --name-only origin/main...HEAD | sort\n' > "$T/probe.body"

S="$T/seed"; mkdir -p "$S/bin/lib" "$S/tests" "$S/.claude"
for f in bin/lib/triage-hotfix-lib.sh bin/lib/gh-rest-var.sh bin/fly-pool.sh bin/run-build.sh bin/run-rollout.sh; do
  printf '#!/bin/bash\n# %s\n' "$f" > "$S/$f"
done
echo "tracked, and excluded from the upload" > "$S/.claude/keep.md"
wrap "$T/a10.body" "$S/tests/a10-live.sh"; wrap "$T/a10pre.body" "$S/tests/a10-pre1496.sh"
wrap "$T/a15.body" "$S/tests/a15-live.sh"; wrap "$T/probe.body" "$S/tests/probe.sh"
printf '#!/bin/bash\necho "note: no merge base — the untouched-files assertion did not run"\nexit 0\n' > "$S/tests/blind.sh"
git -C "$S" init -q && git -C "$S" add -A && git -C "$S" commit -qm seed
git clone -q --bare "$S" "$T/origin.git"

# branch <name> <path...> — a branch off main touching those paths, pushed; main
# then moves on (a non-bin/ file) so the merge base is NOT main's tip.
branch() {
  local b="$1" w="$T/w-$1"; shift
  git clone -q "$T/origin.git" "$w" && git -C "$w" checkout -q -b "$b"
  for p in "$@"; do mkdir -p "$w/$(dirname "$p")"; echo "# $b" >> "$w/$p"; done
  git -C "$w" add -A && git -C "$w" commit -qm "$b" && git -C "$w" push -q origin "$b"
}
move_main() {
  local m="$T/mainmove-$1"; git clone -q "$T/origin.git" "$m"
  echo "main moved $1" >> "$m/README.md"
  git -C "$m" add -A && git -C "$m" commit -qm "main moves $1" && git -C "$m" push -q origin main
}
branch b1496 bin/lib/triage-hotfix-lib.sh bin/lib/gh-rest-var.sh bin/fly-pool.sh
branch b644 .harness/specs/BH-644/plan.md bin/lib/triage-hotfix-lib.sh bin/fly-pool.sh
branch b984 bin/run-rollout.sh bin/run-build.sh
move_main 1
for b in b1496 b644 b984; do git -C "$T/w-$b" fetch -q origin; done

# ci <branch> <suite> — what CI runs: a full clone, detached at the PR's merge
# commit (actions/checkout, fetch-depth 0). Prints "rc <n>" then the output.
ci() {
  local c="$T/ci-$1"
  [ -d "$c" ] || { git clone -q "$T/origin.git" "$c" && git -C "$c" checkout -q --detach origin/main \
    && git -C "$c" merge -q --no-edit "origin/$1" >/dev/null && git -C "$c" branch -q -D main; }
  local out; out=$(cd "$c" && bash "$2" 2>&1); echo "rc $?"; printf '%s\n' "$out"
}
# on_host <branch> <suite> — the same suite through bin/remote-gate.sh's job.
on_host() { gate "$T/w-$1" "$2"; host; }

# ── 1. #1496's shape: the host is red exactly where CI is red ────────────────
CI=$(ci b1496 tests/a10-pre1496.sh)
case "$CI" in "rc 1"*) ok ;; *) bad "1a fixture: CI must be red for #1496's shape under the pre-#1496 A10: $CI" ;; esac
on_host b1496 tests/a10-pre1496.sh
[ "$JRC" = 1 ] && ok || bad "1b the host went blind on #1496's shape under the pre-#1496 A10 (CI red, host exit $JRC): $JOUT"
case "$JOUT" in *"bin/fly-pool.sh"*) ok ;; *) bad "1c the host's A10 did not name the stray CI names (bin/fly-pool.sh): $JOUT" ;; esac
CI=$(ci b1496 tests/a10-live.sh)
case "$CI" in "rc 0"*"not BH-644/BH-645's slice"*) ok ;; *) bad "1d fixture: the live A10 must be quiet on CI for #1496's shape: $CI" ;; esac
on_host b1496 tests/a10-live.sh
[ "$JRC" = 0 ] && ok || bad "1e the live A10 on the host disagrees with CI for #1496's shape (exit $JRC): $JOUT"

# ── 2. the live arms bite on the host where they bite on CI ─────────────────
CI=$(ci b644 tests/a10-live.sh)
case "$CI" in "rc 1"*"bin/fly-pool.sh"*) ok ;; *) bad "2a fixture: the live A10 must be red on CI for BH-644's slice plus a stray: $CI" ;; esac
on_host b644 tests/a10-live.sh
[ "$JRC" = 1 ] && ok || bad "2b the live A10 on the host missed what CI catches (BH-644 + stray, exit $JRC): $JOUT"
CI=$(ci b984 tests/a15-live.sh)
case "$CI" in "rc 1"*"bin/run-build.sh"*) ok ;; *) bad "2c fixture: the live A15 must be red on CI for a BH-984 branch touching run-build.sh: $CI" ;; esac
on_host b984 tests/a15-live.sh
[ "$JRC" = 1 ] && ok || bad "2d the live A15 on the host missed what CI catches (exit $JRC): $JOUT"
case "$JOUT" in *"bin/run-build.sh"*) ok ;; *) bad "2e the host's A15 did not name the forbidden file: $JOUT" ;; esac

# ── 3. the same merge base and the same three-dot diff; the shas are printed ─
CIMB=$(git -C "$T/w-b1496" merge-base HEAD origin/main)
BASE=$(git -C "$T/w-b1496" rev-parse origin/main)
gate --full "$T/w-b1496" tests/probe.sh; host
WANT=$(printf '%s\n' "$CIMB" bin/fly-pool.sh bin/lib/gh-rest-var.sh bin/lib/triage-hotfix-lib.sh)
case "$JOUT" in *"$WANT"*) ok ;; *) bad "3a the host's merge base / three-dot diff is not CI's (want $WANT): $JOUT" ;; esac
case "$JOUT" in *".claude/keep.md"*) bad "3b a tracked file the upload excludes read as a change on the host: $JOUT" ;; *) ok ;; esac
case "$GOUT" in *"$BASE"*) ok ;; *) bad "3c the gate did not print the base sha it used ($BASE): $GOUT" ;; esac
case "$GOUT$JOUT" in *"merge base $CIMB"*) ok ;; *) bad "3d the run did not print the merge base it used ($CIMB): $GOUT $JOUT" ;; esac
# Uncommitted work is still part of what the host tests, as it always was.
echo "# dirty" >> "$T/w-b1496/bin/run-rollout.sh"
gate --full "$T/w-b1496" tests/probe.sh; host
case "$JOUT" in *"bin/run-rollout.sh"*) ok ;; *) bad "3e an uncommitted edit did not reach the host's diff: $JOUT" ;; esac
git -C "$T/w-b1496" checkout -q -- bin/run-rollout.sh

# ── 4. a suite that prints "no merge base" fails the run ─────────────────────
on_host b1496 tests/blind.sh
[ "$JRC" = 1 ] && ok || bad "4a a suite that printed 'no merge base' and exited 0 did not fail the run (exit $JRC): $JOUT"
case "$JOUT" in *"no merge base"*"1 failing"*) ok ;; *) bad "4b the run did not say why it failed a green suite: $JOUT" ;; esac
gate "$T/w-b1496" -- bash tests/blind.sh; host
[ "$JRC" != 0 ] && ok || bad "4c -- mode passed a command that printed 'no merge base': $JOUT"
# A plain directory has no base at all: an arm that looks for one is blind, and
# the run says so instead of passing.
mkdir -p "$T/plain/tests"; cp "$S/tests/probe.sh" "$T/plain/tests/"
gate "$T/plain" tests/probe.sh; host
[ "$JRC" = 1 ] && ok || bad "4d a non-git upload let a merge-base arm pass blind (exit $JRC): $JOUT"

# ── 5. the Mac path: one machine of several, by its 6PN address ─────────────
# The lead's Mac wrapper proxied each local port to one named machine; the gate
# takes the same address as TESTHOST_TARGET so that wrapper can retire.
rm -f "$FIX/proxy-up" "$FIX/fly-calls"
GOUT=$(env PATH="$T/fakebin:$PATH" HOME="$T/home" HARNESS="$T/h" TESTHOST_APP=fixture \
  TESTHOST_PORT=10023 TESTHOST_TARGET=fdaa:0:1::2 TESTHOST_KEY="$T/key" REMOTE_GATE_PROXY_WAIT_S=2 \
  bash "$GATE" "$T/plain" tests/probe.sh 2>&1)
grep -q "^proxy 10023:22 fdaa:0:1::2 -a fixture" "$FIX/fly-calls" 2>/dev/null && ok \
  || bad "5 TESTHOST_TARGET did not reach the proxy as its remote host: $(cat "$FIX/fly-calls" 2>/dev/null)"

echo "remote-gate bh-1527: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
