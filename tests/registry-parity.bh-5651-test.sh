#!/bin/bash
# tests/registry-parity.bh-5651-test.sh — BH-5651: the four parity suites pass
# against the registry with NO fleet.conf present.
#
# After the switch a box reads the fleet from the registry (bin/lib/registry.sh)
# and the committed fleet.conf is an export, never an input. The four suites
# that pin the fleet's shape (lane-liveness, overage-per-box, cost-rows-db,
# account-routing) read it through tests/lib/registry-cache.bh-5651.sh. This
# suite proves that they need no fleet.conf to do so:
#
#   1. It copies this working tree (tracked files plus the untracked ones the
#      build added, as they are on disk) into a scratch dir and deletes
#      fleet.conf from the copy.
#   2. It runs each suite from the copy and asserts rc 0. The registry they
#      read is this tree's own, emitted once by bin/registry-seed.sh --emit
#      from the ORIGINAL tree and handed in as RCACHE_REGISTRY_JSON.
#   3. SENTINEL. A registry cache built from fixture rows that hold a project
#      no fleet.conf names (parityonly-fixture). In db mode the copy's
#      bin/fleet-conf.sh --projects lists it, so the registry answered and not
#      /root/harness/fleet.conf (bin/fleet-conf.sh falls back to that file).
#      In file mode it does not list it, so the sentinel can tell the two apart.
#
# Run from anywhere: tests/registry-parity.bh-5651-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/registry-cache.bh-5651.sh" || exit 1
command -v jq >/dev/null 2>&1 || { echo "registry-parity: SKIPPED — jq is not installed"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SUITES="lane-liveness-test.sh overage-per-box-test.sh cost-rows-db-test.sh account-routing-test.sh"

# --- 1. the working tree, with no fleet.conf ---------------------------------
TREE="$T/tree"
mkdir -p "$TREE"
{ git -C "$DIR" ls-files -z; git -C "$DIR" ls-files -z --others --exclude-standard; } > "$T/all.lst"
: > "$T/files.lst"
while IFS= read -r -d '' F; do
  [ -e "$DIR/$F" ] || [ -L "$DIR/$F" ] || continue   # a tracked file this build deleted
  printf '%s\0' "$F" >> "$T/files.lst"
done < "$T/all.lst"
[ -s "$T/files.lst" ] || { echo "FAIL: git ls-files listed nothing in $DIR — nothing to copy"; exit 1; }
tar -C "$DIR" --null -T "$T/files.lst" -cf - 2>"$T/tar.err" | tar -C "$TREE" -xf - \
  || { echo "FAIL: could not copy the tree: $(head -3 "$T/tar.err")"; exit 1; }
for S in $SUITES; do
  [ -f "$TREE/tests/$S" ] && ok || bad "the copy has no tests/$S"
done
[ -f "$TREE/fleet.conf" ] && ok || bad "the copy did not take fleet.conf, so deleting it below proves nothing"
rm -f "$TREE/fleet.conf"
[ ! -e "$TREE/fleet.conf" ] && ok || bad "the copy still has a fleet.conf"

# This tree's registry, from the ORIGINAL tree's files (the copy has none to emit from).
"$DIR/bin/registry-seed.sh" --emit --root "$DIR" > "$T/registry.json" 2>"$T/seed.err" \
  && jq -e '.projects | length > 0' "$T/registry.json" >/dev/null \
  && ok || bad "bin/registry-seed.sh --emit gave no registry: $(head -3 "$T/seed.err")"

# --- 2. the four suites, from the copy ----------------------------------------
for S in $SUITES; do
  env HARNESS_TEST_SANDBOX=1 RCACHE_REGISTRY_JSON="$T/registry.json" \
    bash "$TREE/tests/$S" > "$T/$S.out" 2>&1
  RC=$?
  [ "$RC" = 0 ] && ok || bad "tests/$S exited $RC with no fleet.conf: $(grep -m5 FAIL "$T/$S.out" | tr '\n' ' ')"
  # A suite that died before it asserted anything also exits; its summary line is the proof it ran.
  grep -Eq "^${S%.sh}: [0-9]+ pass, 0 fail$" "$T/$S.out" \
    && ok || bad "tests/$S printed no clean summary: $(tail -2 "$T/$S.out" | tr '\n' ' ')"
done

# --- 3. the sentinel: the registry answered, not a fleet.conf -------------------
cat > "$T/parity-rows.conf" <<'EOF'
# a registry-only project: no fleet.conf anywhere names it
parityonly-fixture Org/parity https://parity.example /api/board 4 parity-box-fixture 192.0.2.10
EOF
GOT=$( rcache_install "$T/sh" "$T/parity-rows.conf" >/dev/null || exit 1
       env HARNESS="$T/sh" FLEET_CONF="$T/no-such-fleet.conf" "$TREE/bin/fleet-conf.sh" --projects 2>/dev/null )
grep -qx parityonly-fixture <<<"$GOT" \
  && ok || bad "db mode: the copy's bin/fleet-conf.sh --projects did not list the registry-only project (got: ${GOT//$'\n'/ })"
[ "$(rcache_run "$T/sh" "$TREE/bin/fleet-conf.sh" --tailnet-ip parityonly-fixture 2>/dev/null)" = 192.0.2.10 ] \
  && ok || bad "db mode: the registry-only project's box address did not come from the registry"
# The other side: file mode never reads the registry, so the fixture project is absent.
GOT=$(env REGISTRY_SOURCE=file HARNESS="$T/sh" FLEET_CONF="$T/no-such-fleet.conf" "$TREE/bin/fleet-conf.sh" --projects 2>/dev/null)
grep -qx parityonly-fixture <<<"$GOT" \
  && bad "file mode listed the registry-only project, so the sentinel cannot tell the registry from a file" || ok

echo "registry-parity.bh-5651-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
