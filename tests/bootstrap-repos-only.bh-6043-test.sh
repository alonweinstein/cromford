#!/bin/bash
# tests/bootstrap-repos-only.bh-6043-test.sh — `bin/bootstrap-machine.sh
# <project> --repos-only` gives a fleet box a checkout of one more project and
# does nothing else.
#
# WHY (2026-10-11). Only one box held /root/repos/cromford, so one box ran
# every cromford lead review: spillover (LEAD_REVIEW_SPILLOVER=1) only
# lets a box with a clone take a request. The only fleet tool that clones was a
# full bootstrap, which also seeds env files and installs that project's
# crontab lanes on the box. --repos-only runs the clone block alone.
#
#   R1  --repos-only: rc 0, the clone and the preplan clone exist, the CodeGraph
#       index ran in the clone
#   R2  --repos-only writes no crontab entry: crontab is never called
#   R3  --repos-only writes no env file and no harness state (no env dir, no
#       box-id, no harness dirs), and installs no package
#   R1b the same with no codegraph on PATH: still rc 0 (#6168 review)
#   R4  an unknown second argument is rc 2 and touches nothing
#   R5  a project with no fleet.conf row is rc 1 before anything runs
#
# Driven, not grepped: the REAL script, copied into a scratch root with every
# `/root/` and `/etc/harness` path moved under it, runs against PATH stubs
# (gh, git clone via a local origin, npm, codegraph, crontab, apt-get, node,
# claude, supervisorctl) that LOG what they were asked.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/bootstrap-repos-only.bh-6043-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

R="$T/root"            # stands in for /root
E="$T/etc-harness"     # stands in for /etc/harness
mkdir -p "$R/harness/bin/lib" "$T/fakebin" "$T/origin"
# The script and its closure, then every /root/ and /etc/harness path moved
# under the scratch root, so nothing outside $T can be touched.
# The closure follows sourced libs, not "$HERE/<script>" calls, so the helpers
# the script runs before and inside the clone block are installed by name.
for f in bootstrap-machine.sh fleet-conf.sh gh-token.sh migrate-env-dir.sh box-for.sh harden-state.sh; do
  [ -f "$DIR/bin/$f" ] || continue
  scratch_install_closure "bin/$f" "$R/harness" >/dev/null || { echo "FAIL: closure install of bin/$f"; exit 1; }
done
find "$R/harness/bin" -type f -name '*.sh' -exec sed -i -e "s|/root/|$R/|g" -e "s|/etc/harness|$E|g" {} +
cp "$DIR/fleet.conf" "$R/harness/fleet.conf"
BM="$R/harness/bin/bootstrap-machine.sh"
grep -q "^# >>> repos only" "$BM" && ok || bad "setup: bin/bootstrap-machine.sh has no '# >>> repos only' block"

# A local origin for the clone, so no network is touched.
git init -q "$T/origin/cromford" && git -C "$T/origin/cromford" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init

# Stubs: every one logs its argv. gh repo clone clones the local origin.
for c in npm codegraph crontab apt-get node claude supervisorctl curl pip; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls.log"\nexit 0\n' "$c" "$T" > "$T/fakebin/$c"
done
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
echo "gh \$*" >> "$T/calls.log"
if [ "\$1 \$2" = "repo clone" ]; then git clone -q "$T/origin/\${3##*/}" "\$4"; exit \$?; fi
exit 0
EOF
chmod +x "$T"/fakebin/*

# root/harness/state/lane-gate is the settings read cache that gh-token.sh's
# normal reads fill on every box (bin/lib/lane-gate.sh); it is not setup.
snap() { ( cd "$T" && find root etc-harness -path root/repos -prune -o -path root/harness/state/lane-gate -prune -o -print 2>/dev/null \
           | grep -vxF root/harness/state | LC_ALL=C sort ); }
run() { ( export PATH="$T/fakebin:$PATH" HARNESS="$R/harness" HOME="$R"; unset GH_TOKEN
          bash "$BM" "$@" ) > "$T/out" 2>&1; echo $?; }

echo "== R1-R3: --repos-only =="
: > "$T/calls.log"; BEFORE=$(snap)
RC=$(run cromford --repos-only)
[ "$RC" = 0 ] && ok || bad "R1 rc $RC, want 0: $(tail -5 "$T/out")"
[ -d "$R/repos/cromford/.git" ] && ok || bad "R1 /root/repos/cromford was not cloned"
[ -d "$R/repos/.preplan-cromford/.git" ] && ok || bad "R1 the preplan clone is missing"
grep -q '^codegraph init' "$T/calls.log" && ok || bad "R1 codegraph init did not run: $(cat "$T/calls.log")"
grep -q '^crontab' "$T/calls.log" && bad "R2 crontab was called: $(grep '^crontab' "$T/calls.log")" || ok
AFTER=$(snap)
NEW=$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))
[ -z "$NEW" ] && ok || bad "R3 files outside /root/repos were created: $(printf '%s ' $NEW)"
[ ! -e "$E" ] && ok || bad "R3 the env dir $E was created"
[ ! -e "$R/harness/state/box-id" ] && ok || bad "R3 state/box-id was written"
grep -qE '^(apt-get|curl|pip|supervisorctl)' "$T/calls.log" && bad "R3 a package step ran: $(grep -E '^(apt-get|curl|pip|supervisorctl)' "$T/calls.log")" || ok

echo "== R1b: --repos-only on a box with no codegraph =="
# The clone block ends with the CodeGraph index. A box without codegraph must
# still finish rc 0: under set -e a function whose last command fails ends the
# whole script (lead review of #6168).
scratch_rm "$R/repos"; : > "$T/calls.log"
mv "$T/fakebin/codegraph" "$T/codegraph.off"
command -v codegraph >/dev/null 2>&1 && echo "note: R1b: a real codegraph is on PATH; R1b cannot prove the no-codegraph path here"
RC=$(run cromford --repos-only)
mv "$T/codegraph.off" "$T/fakebin/codegraph"
[ "$RC" = 0 ] && ok || bad "R1b no codegraph: rc $RC, want 0: $(tail -3 "$T/out")"
[ -d "$R/repos/cromford/.git" ] && ok || bad "R1b /root/repos/cromford was not cloned"
grep -q 'repos-only done' "$T/out" && ok || bad "R1b the run did not reach its last line: $(tail -3 "$T/out")"

echo "== R4: an unknown second argument =="
scratch_rm "$R/repos"; : > "$T/calls.log"; BEFORE=$(snap)
RC=$(run cromford --everything)
[ "$RC" = 2 ] && ok || bad "R4 rc $RC, want 2"
[ ! -s "$T/calls.log" ] && ok || bad "R4 something ran: $(cat "$T/calls.log")"
[ "$(snap)" = "$BEFORE" ] && [ ! -e "$R/repos" ] && ok || bad "R4 files changed"

echo "== R5: no fleet.conf row =="
: > "$T/calls.log"
RC=$(run no-such-project-x --repos-only)
[ "$RC" = 1 ] && ok || bad "R5 rc $RC, want 1"
[ ! -s "$T/calls.log" ] && ok || bad "R5 something ran: $(cat "$T/calls.log")"

echo "bootstrap-repos-only.bh-6043: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
