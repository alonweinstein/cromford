#!/bin/bash
# tests/lander-fixture-modules.bh-1330-test.sh — BH-1330 item 4: the blast
# radius of bin/jobs-client.sh's refuse-to-half-load, now that bin/lander.sh
# sources the client.
#
# WHAT CHANGED AND WHY THIS EXISTS. BH-1036 added `. "$HARNESS/bin/jobs-client.sh"`
# to bin/lander.sh for the `lander` row twin. bin/jobs-client.sh is a SHIM over
# bin/lib/jobs/*.sh (BH-1194) and it refuses to half-load: a copy of the client
# with no modules beside it writes one ALERTS line and `exit 1`s. A source runs
# in the SAME shell, so that exit is the LANE's exit — bin/lander.sh now dies at
# its source line, before the flags, before `gh pr view`, before any marker.
# That is correct behaviour (a client with a hole in it reads exactly like the
# degraded mode the lane is designed to have), but it means every fixture that
# copies the real bin/lander.sh into a scratch harness must copy bin/lib/jobs/*.sh
# beside the client or it tests nothing at all — the lane it thinks it is driving
# exited on line 24.
#
# The audit behind this suite (2026-09-22, main 42c0c7c): fourteen suites name
# bin/lander.sh; exactly ONE drives the real script — section C of
# tests/no-twin-ledgers.bh-1036-test.sh — and it already copies the modules. The
# other thirteen stub the lane with `printf '#!/bin/bash\nexit 0\n'`, extract a
# marker block, or read the file as text. So there was no missing copy to add.
# This suite is what turns "and keep copying them" from a sentence in a note
# into something that goes red: it drives the REAL bin/lander.sh three ways —
# client without modules, client with modules, no client at all — and pins which
# of them reaches `gh pr view` and which one dies on the source line.
#
# NOT A GREP OVER SOURCE. Every case runs the shipped script and asserts on
# artifacts: the exit code, the gh call sink, stderr, logs/ALERTS.log and
# state/lander/. L4 is the one source pin, and it guards its own absent-symbol
# case: if the literal JC_MODULES line ever goes, L4 goes red rather than L1
# quietly asserting on an empty module name.
#
# The lane is stopped early on purpose. The gh stub answers the
# `--json headRefName,headRefOid` query with an EMPTY line, so bin/lander.sh
# exits 1 at its own `[ -n "$BR" ] && [ -n "$HEAD" ] || exit 1` a few lines after
# the sources: no worktree, no agent session, no ledger traffic. Both L1 and L2
# therefore exit 1 — what separates them is WHERE, and the sinks say where.
#
# No network, no model call, no clock read, no secrets. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 tests/lander-fixture-modules.bh-1330-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

sink_lines() { # sink_lines <file> -> line count, 0 when the file was never written
  [ -f "$1" ] || { echo 0; return 0; }
  grep -c . "$1" 2>/dev/null || true
}

echo "== L4. the pin the other three cases read their module list off =="

# Read FIRST: L1 asserts that stderr names the first module on this line, and an
# empty module name would make that assertion pass against anything.
JC_LINES=$(grep -c '^JC_MODULES="' "$DIR/bin/jobs-client.sh")
[ "$JC_LINES" = 1 ] && ok \
  || bad "L4: bin/jobs-client.sh must carry exactly one literal JC_MODULES= line (got $JC_LINES) — the suites read the module list off it"
JC_MODS=$(sed -n 's/^JC_MODULES="\(.*\)"$/\1/p' "$DIR/bin/jobs-client.sh" | head -1)
FIRST_MOD=$(printf '%s\n' "$JC_MODS" | awk '{print $1}')
[ -n "$FIRST_MOD" ] && ok \
  || bad "L4: the JC_MODULES line named no module — L1's stderr assertion would be vacuous"

# ---------------------------------------------------------------------------
# The scratch harness. bin/lander.sh is on tests/env-path-allowlist.d/port-b.txt
# (not yet ported to the env-path idiom) and hardcodes two roots, so a scratch
# tree has no other way to be handed to it. Both rewrites are ASSERTED to have
# matched: a rename upstream must go red here, never silently drive /root/harness
# and /root/repos.
# ---------------------------------------------------------------------------
build_h() { # build_h <case dir> <label>
  local C="$1" L="$2" H="$1/h"
  mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/state" "$H/repos/project-3" "$C/fakebin"
  sed -e 's|^HARNESS=/root/harness$|HARNESS="${HARNESS:-/root/harness}"|' \
      -e 's|^REPO_DIR="/root/repos/\$PROJECT"$|REPO_DIR="$HARNESS/repos/$PROJECT"|' \
      "$DIR/bin/lander.sh" > "$H/bin/lander.sh"
  chmod +x "$H/bin/lander.sh"
  grep -qF 'HARNESS="${HARNESS:-/root/harness}"' "$H/bin/lander.sh" && ok \
    || bad "$L: the scratch-root rewrite did not match — this case would drive /root/harness"
  grep -qF 'REPO_DIR="$HARNESS/repos/$PROJECT"' "$H/bin/lander.sh" && ok \
    || bad "$L: the repo-root rewrite did not match — this case would drive /root/repos"
  cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/deployment.sh" "$H/bin/lib/"
  cp "$DIR/bin/lib/ledger-twin.sh" "$H/bin/lib/"
  # BH-4080: the lander reads the repo slug from fleet.conf (no literal table).
  cp "$DIR/bin/fleet-conf.sh" "$H/bin/" && printf 'project-3 example-org/project-3\n' > "$H/fleet.conf"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
  # The gh stub records every call and answers the head query with NOTHING, so
  # the lane stops at its own empty-head guard right after the source lines.
  cat > "$C/fakebin/gh" <<'GH'
#!/bin/bash
printf 'GH %s\n' "$*" >> "$GH_SINK"
exit 0
GH
  # git is a recorder that must never be reached: a worktree in these cases
  # would mean the lane ran past the guard. curl IS reached with a client on the
  # box: the kill switches read through flag_active (BH-1370), so it answers as
  # a live worker with no row (404) and the flag files alone decide.
  cat > "$C/fakebin/git" <<'GIT'
#!/bin/bash
printf 'GIT %s\n' "$*" >> "$GIT_SINK"
exit 0
GIT
  cat > "$C/fakebin/curl" <<'CURL'
#!/bin/bash
printf '{"error":"not found"}\n404\n'
CURL
  cat > "$H/bin/agent-call.sh" <<'AC'
#!/bin/bash
printf 'AGENT %s\n' "$1" >> "$AGENT_SINK"
exit 0
AC
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
  chmod +x "$C/fakebin/gh" "$C/fakebin/git" "$C/fakebin/curl" "$H/bin/agent-call.sh" "$H/bin/beat.sh"
}

run_lander() { # run_lander <case dir> -> rc; sinks at <dir>/{gh,git,agent}.txt, stderr at <dir>/err.txt
  local C="$1"
  : > "$C/gh.txt"; : > "$C/git.txt"; : > "$C/agent.txt"
  rm -f "$C/h/logs/ALERTS.log"
  env -i PATH="$C/fakebin:/usr/bin:/bin" HOME="$C" HARNESS="$C/h" JOBS_BOX=testbox \
      JOBS_RETRIES=0 GH_SINK="$C/gh.txt" GIT_SINK="$C/git.txt" AGENT_SINK="$C/agent.txt" \
      bash "$C/h/bin/lander.sh" project-3 7 >"$C/out.txt" 2>"$C/err.txt"
}

echo "== L1. the real lander with a client and NO bin/lib/jobs/: dies on the source line =="

L1="$T/L1"; build_h "$L1" L1
cp "$DIR/bin/jobs-client.sh" "$L1/h/bin/"
[ -d "$L1/h/bin/lib/jobs" ] && bad "L1: this case must have no modules beside the client" || ok
run_lander "$L1"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "L1: a half-loaded client must take the lane down with it (rc $RC)"
grep -q 'jobs-client: missing module' "$L1/err.txt" && ok \
  || bad "L1: the shim's refusal must reach the lane's stderr: $(head -2 "$L1/err.txt")"
grep -q "lib/jobs/$FIRST_MOD\.sh" "$L1/err.txt" && ok \
  || bad "L1: stderr must name the first missing module (lib/jobs/$FIRST_MOD.sh): $(head -2 "$L1/err.txt")"
[ "$(sink_lines "$L1/gh.txt")" = 0 ] && ok \
  || bad "L1: the lane must die BEFORE gh pr view: $(cat "$L1/gh.txt")"
[ "$(sink_lines "$L1/agent.txt")" = 0 ] && ok \
  || bad "L1: no resolution session may be bought by a half-loaded lane"
[ "$(sink_lines "$L1/h/logs/ALERTS.log")" = 1 ] && ok \
  || bad "L1: the half-load must leave exactly one ALERTS line (got $(sink_lines "$L1/h/logs/ALERTS.log"))"
grep -q 'missing module' "$L1/h/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "L1: the ALERTS line must say what is missing: $(cat "$L1/h/logs/ALERTS.log" 2>/dev/null)"
[ ! -e "$L1/h/state/lander/project-3-7" ] && ok \
  || bad "L1: no attempt marker may be written by a lane that never ran"

echo "== L2. the real lander with the client AND bin/lib/jobs/: gets past the source =="

L2="$T/L2"; build_h "$L2" L2
cp "$DIR/bin/jobs-client.sh" "$L2/h/bin/"
mkdir -p "$L2/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$L2/h/bin/lib/jobs/"
# The fixture is under test before the lane is: every module the shipped shim
# names has to be beside the copied client, or L2 is L1 wearing a different hat.
L2_MISS=""
for m in $JC_MODS; do [ -r "$L2/h/bin/lib/jobs/$m.sh" ] || L2_MISS="$L2_MISS $m"; done
[ -z "$L2_MISS" ] && ok || bad "L2: the fixture left modules behind:$L2_MISS"
run_lander "$L2"; RC=$?
[ "$RC" -eq 1 ] && ok \
  || bad "L2: the empty head answer is the lane's own exit 1 (rc $RC)"
grep -q 'missing module' "$L2/err.txt" && bad "L2: a complete client must not report a missing module: $(head -2 "$L2/err.txt")" || ok
grep -q 'pr view 7' "$L2/gh.txt" && ok \
  || bad "L2: the lane must reach gh pr view with the modules present: $(cat "$L2/gh.txt")"
[ "$(sink_lines "$L2/h/logs/ALERTS.log")" = 0 ] && ok \
  || bad "L2: a complete client writes no ALERTS line: $(cat "$L2/h/logs/ALERTS.log" 2>/dev/null)"
[ "$(sink_lines "$L2/agent.txt")" = 0 ] && ok \
  || bad "L2: the empty head must stop the lane before any session is bought"

echo "== L3. the real lander with NO client at all: today's fail-open path =="

# A box mid-sync carries bin/lander.sh without bin/jobs-client.sh. The lane's
# `[ -r … ] &&` guard skips the source, the lt_* fallbacks answer "no row", and
# the lane runs exactly as it did before BH-1036. This is the branch that must
# NOT change: the half-load exit is for a client that IS there and is broken.
L3="$T/L3"; build_h "$L3" L3
[ ! -e "$L3/h/bin/jobs-client.sh" ] && ok || bad "L3: this case must have no client at all"
run_lander "$L3"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "L3: the empty head answer is the lane's own exit 1 (rc $RC)"
grep -q 'missing module' "$L3/err.txt" && bad "L3: an absent client is not a half-load: $(head -2 "$L3/err.txt")" || ok
grep -q 'pr view 7' "$L3/gh.txt" && ok \
  || bad "L3: a box with no client must still run the lane: $(cat "$L3/gh.txt")"
[ "$(sink_lines "$L3/h/logs/ALERTS.log")" = 0 ] && ok \
  || bad "L3: an absent client must page nobody: $(cat "$L3/h/logs/ALERTS.log" 2>/dev/null)"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
