#!/bin/bash
# tests/fleet-conf-helpers-test.sh — bin/fleet-conf.sh's list helpers, against a
# fixture registry.
#
# These helpers exist so that no caller has a reason to keep its own copy of the
# project list (tests/fleet-projects-not-hardcoded-test.sh is the guard that
# says so). A helper that answers a slightly wrong list is worse than no helper
# at all — the caller stops looking, and the omission becomes invisible the way
# the 2026-09-10 tier-2 merge stall was — so the shapes worth pinning are the
# awkward ones: a "-" board prefix, a row with no box column, a commented-out
# row, and a project whose name is a prefix of another project's.
#
# Run from anywhere: tests/fleet-conf-helpers-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FC="$DIR/bin/fleet-conf.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/fleet.conf" <<'EOF'
# fixture registry — same columns as the live one:
#   <project> <github-repo-slug> <prod-base-url> <board-api-prefix> <cron-offset> [box]
alpha-os   Acme/alpha-os   https://alpha.example  /api/board          2 box-alpha 10.9.9.1
beta-os    Acme/beta-os    https://beta.example   /api/feature-board  4 box-beta  10.9.9.2
# gamma-os is PARKED: a commented row is not a project.
# gamma-os  Acme/gamma-os   https://gamma.example  /api/board          6 box-gamma
delta      Acme/delta      https://delta.example  -                   8 box-small 10.9.9.3
# epsilon shares delta's box but carries NO address of its own: the box lookup
# must still answer, from whichever row on that box does have one.
epsilon    Acme/epsilon    -                      -                   9 box-small
# a legacy row with NO box column — box-for.sh applies the naming convention
zeta-os    Acme/zeta-os    https://zeta.example   /api/board          1
# name-prefix collision: "sib" is a prefix of "sib-nav"
sib        Acme/sib        -                      -                   5 box-small
sib-nav    Acme/sib-nav    -                      -                   7 box-alpha
EOF
run() { FLEET_CONF="$T/fleet.conf" "$FC" "$@" 2>/dev/null; }
eq() { # eq <label> <got> <want>
  if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi
}

# --- --projects: every uncommented row, in file order ------------------------
eq "--projects" "$(run --projects | tr '\n' ' ')" "alpha-os beta-os delta epsilon zeta-os sib sib-nav "
grep -qx 'gamma-os' <<<"$(run --projects)" && bad "a commented-out row must not be a project" || ok

# --- --projects-with-board: col 4 is a real path -----------------------------
# The complement is the GitHub-Issues lane. A board sweep that iterates the
# wrong side of this split either misses boards or curls a "-" as a URL.
eq "--projects-with-board" "$(run --projects-with-board | tr '\n' ' ')" "alpha-os beta-os zeta-os "
grep -qx 'delta' <<<"$(run --projects-with-board)" && bad "a '-' board prefix is NOT an in-app board" || ok
# The two halves must partition the registry — no project in both, none in neither.
BOTH=$(comm -12 <(run --projects | sort) <(run --projects-with-board | sort) | wc -l | tr -d ' ')
ALLN=$(run --projects | wc -l | tr -d ' ')
WB=$(run --projects-with-board | wc -l | tr -d ' ')
eq "with-board is a subset of projects" "$BOTH" "$WB"
[ "$ALLN" -gt "$WB" ] && ok || bad "the fixture must have at least one non-board project or this test proves nothing"

# --- --projects-on-box: resolved through box-for.sh --------------------------
eq "on-box small"  "$(run --projects-on-box box-small | tr '\n' ' ')" "delta epsilon sib "
eq "on-box alpha"  "$(run --projects-on-box box-alpha | tr '\n' ' ')" "alpha-os sib-nav "
# The legacy row has no box column: box-for.sh's convention is
# box-<project minus "-os">, and the helper must honour it rather
# than dropping the project on the floor.
eq "on-box legacy" "$(run --projects-on-box box-zeta | tr '\n' ' ')" "zeta-os "
eq "on-box unknown" "$(run --projects-on-box box-nope | tr '\n' ' ')" ""
# Every project lands on exactly one box — a project owned by no box is a
# watcher nobody runs, which is the failure this whole wave is about.
TOTAL=0
for B in box-small box-alpha box-beta box-zeta; do
  TOTAL=$((TOTAL + $(run --projects-on-box "$B" | wc -l | tr -d ' ')))
done
eq "every fixture project is owned by exactly one box" "$TOTAL" "$ALLN"

# --- <project> <field> -------------------------------------------------------
eq "repo"          "$(run alpha-os repo)"         "Acme/alpha-os"
eq "prod"          "$(run beta-os prod)"          "https://beta.example"
eq "board_prefix"  "$(run beta-os board_prefix)"  "/api/feature-board"
eq "offset"        "$(run delta offset)"          "8"
eq "box"           "$(run delta box)"             "box-small"
eq "box (legacy row is EMPTY, not an error)" "$(run zeta-os box)" ""
# Name-prefix collision: `grep "^sib"` would return sib-nav's row first if the
# rows were ordered the other way. The lookup is whitespace-anchored.
eq "prefix collision: sib"     "$(run sib repo)"     "Acme/sib"
eq "prefix collision: sib-nav" "$(run sib-nav repo)" "Acme/sib-nav"
run gamma-os repo >/dev/null 2>&1 && bad "a commented-out project must not resolve" || ok
run nosuch repo   >/dev/null 2>&1 && bad "an unknown project must exit non-zero" || ok

# --- a missing registry is an error, not an empty list -----------------------
# Empty output with rc=0 reads to every caller as "the fleet has no projects",
# which is a whole lane doing nothing and reporting success — the exact shape
# the guard in this wave exists to stop. Isolated copy, because a FLEET_CONF
# that does not exist deliberately falls back to the checkout's own registry.
mkdir -p "$T/iso/bin"
cp "$FC" "$DIR/bin/box-for.sh" "$T/iso/bin/"
for SUB in "--projects" "--projects-with-board" "--projects-on-box box-small" "alpha-os repo"; do
  # shellcheck disable=SC2086
  FLEET_CONF="" "$T/iso/bin/fleet-conf.sh" $SUB >/dev/null 2>&1 \
    && bad "'$SUB' must exit non-zero when no registry can be found" || ok
done

# --- the LIVE registry answers all four, so callers can rely on them ---------
[ -n "$("$FC" --projects)" ] && ok || bad "the live fleet.conf yields no projects"
[ -n "$("$FC" --projects-with-board)" ] && ok || bad "the live fleet.conf yields no board projects"
for P in $("$FC" --projects); do
  [ -n "$("$FC" "$P" repo)" ] || bad "live registry: $P has no repo slug"
  [ -n "$("$DIR/bin/box-for.sh" "$P")" ] || bad "live registry: $P resolves to no box"
done
ok

# --- --tailnet-ip: the registry answers "where is this project's box" --------
# Nine scripts carried their own copy of this table because the registry could
# not answer it. The contract that matters is not the happy path: it is that an
# UNKNOWN address prints NOTHING and exits nonzero, so a caller fails closed
# instead of ssh-ing to `root@` — which hangs rather than erroring, and a hang
# is what every timeout in this fleet is already fighting.
eq "--tailnet-ip alpha-os" "$(run --tailnet-ip alpha-os)" "10.9.9.1"
eq "--tailnet-ip beta-os"  "$(run --tailnet-ip beta-os)"  "10.9.9.2"
eq "field form"            "$(run alpha-os tailnet_ip)"   "10.9.9.1"

# A row with no address: empty output AND a nonzero rc, so `IP=$(...) || skip`
# and `[ -n "$IP" ]` both work. Either alone would be enough; a caller gets to
# pick, and neither can be satisfied by a blank string that looks like success.
OUT=$(run --tailnet-ip epsilon); RC=$?
[ "$RC" != 0 ] && ok || bad "a row with no tailnet_ip must exit nonzero (rc=$RC)"
[ -z "$OUT" ] && ok || bad "a row with no tailnet_ip must print nothing, got '$OUT'"
OUT=$(run --tailnet-ip zeta-os); RC=$?
[ "$RC" != 0 ] && [ -z "$OUT" ] && ok || bad "a legacy row with no box column must fail closed too (rc=$RC out='$OUT')"
OUT=$(run --tailnet-ip nosuch-os); RC=$?
[ "$RC" != 0 ] && [ -z "$OUT" ] && ok || bad "an unknown project must fail closed (rc=$RC out='$OUT')"
OUT=$(run --tailnet-ip gamma-os); RC=$?
[ "$RC" != 0 ] && [ -z "$OUT" ] && ok || bad "a PARKED (commented) row must not resolve to an address"

# --- --tailnet-ip-of-box: the same fact, keyed on the box --------------------
# The box-keyed callers (auth probe, cost rollup, drift check) know a box name,
# not a project. Any row on that box answers, which is why epsilon needs none.
eq "--tailnet-ip-of-box alpha" "$(run --tailnet-ip-of-box box-alpha)" "10.9.9.1"
eq "--tailnet-ip-of-box small" "$(run --tailnet-ip-of-box box-small)" "10.9.9.3"
OUT=$(run --tailnet-ip-of-box box-nope); RC=$?
[ "$RC" != 0 ] && [ -z "$OUT" ] && ok || bad "an unknown box must fail closed (rc=$RC out='$OUT')"

# --- the LIVE registry: every project that owns a box has an address ---------
# The migration's own completeness check. A project whose box cannot be reached
# is a lane that silently stops being swept, probed or rolled up.
for P in $("$FC" --projects 2>/dev/null); do
  B=$("$DIR/bin/box-for.sh" "$P" 2>/dev/null)
  [ -n "$B" ] && [ "$B" != local ] || continue
  [ -n "$("$FC" --tailnet-ip "$P" 2>/dev/null)" ] \
    || bad "live registry: $P (box $B) has no tailnet_ip — every IP table that moved into fleet.conf now silently skips it"
done
ok

echo "fleet-conf-helpers-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
