#!/bin/bash
# tests/bh-1956-fleet-conf-tailnet-test.sh — bin/fleet-conf.sh's tailnet_ip FIELD
# form fails closed on a 6-column row, the same way --tailnet-ip does (BH-1956,
# item 7 of #232).
#
# WHY THIS EXISTS. fleet-conf-helpers-test.sh pins --tailnet-ip on a row with no
# address, but never the field form `<project> tailnet_ip`. That form used to be
# `echo "${7:-}"`: a 6-column row printed an empty line and exited 0, and a
# caller doing `IP=$(fleet-conf.sh p tailnet_ip)` sshed to `root@` — a hang, not
# an error. The fix (bin/fleet-conf.sh:91) had no test, so nothing stopped a
# refactor from putting the old line back.
#
# THE RED LEG IS BUILT IN. Run bare, the suite rebuilds that pre-fix line into a
# scratch copy of fleet-conf.sh (the original commit is not in a shallow clone),
# runs ITSELF against the copy through FLEET_CONF_SH, and requires that run to
# fail. A suite that stayed green on the old code would be proving nothing.
#
# Run from anywhere: tests/bh-1956-fleet-conf-tailnet-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FC="${FLEET_CONF_SH:-$DIR/bin/fleet-conf.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/fleet.conf" <<'EOF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [tailnet_ip]
alpha-os   Acme/alpha-os   https://alpha.example  /api/board  2 box-alpha 10.9.9.1
# 6 columns: a box, but no address yet
zeta-os    Acme/zeta-os    https://zeta.example   /api/board  4 box-zeta
EOF
run() { FLEET_CONF="$T/fleet.conf" "$FC" "$@" 2>/dev/null; }

# --- the 6-column row fails closed through BOTH accessors -------------------
OUT=$(run zeta-os tailnet_ip); RC=$?
[ "$RC" = 1 ] && ok || bad "field form on a 6-column row must exit 1 (rc=$RC)"
[ -z "$OUT" ] && ok || bad "field form on a 6-column row must print nothing, got '$OUT'"
OUT=$(run zeta-os tailnet_ip | od -An -c); [ -z "$OUT" ] && ok || bad "field form must not even print a newline, got bytes '$OUT'"
OUT=$(run --tailnet-ip zeta-os); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "--tailnet-ip on a 6-column row must exit 1 with no output (rc=$RC out='$OUT')"

# --- the list form: no blank line, nothing for zeta, the real address listed --
OUT=$(run --tailnet-ips); RC=$?
[ "$RC" = 0 ] && ok || bad "--tailnet-ips exits 0 by design (rc=$RC)"
grep -q '^[[:space:]]*$' <<<"$OUT" && bad "--tailnet-ips printed an empty line: '$OUT'" || ok
[ "$OUT" = "10.9.9.1" ] && ok || bad "--tailnet-ips must list exactly the 7-column row's address, got '$OUT'"

# --- the 7-column row still answers through both forms ----------------------
[ "$(run alpha-os tailnet_ip)" = "10.9.9.1" ] && ok || bad "field form lost the 7-column row's address"
[ "$(run --tailnet-ip alpha-os)" = "10.9.9.1" ] && ok || bad "--tailnet-ip lost the 7-column row's address"

# --- mutation leg: the pre-fix line must turn this suite red -----------------
if [ -z "${FLEET_CONF_SH:-}" ]; then
  PRE="$T/prefix/fleet-conf.sh"; mkdir -p "$T/prefix"
  sed 's/tailnet_ip) \[ -n "\${7:-}" \] || exit 1; echo "\$7" ;;/tailnet_ip) echo "${7:-}" ;;/' \
    "$DIR/bin/fleet-conf.sh" > "$PRE"; chmod +x "$PRE"
  if cmp -s "$PRE" "$DIR/bin/fleet-conf.sh"; then
    bad "mutation leg: the sed matched nothing — the fixed line moved, rewrite the pre-fix copy"
  else
    FLEET_CONF_SH="$PRE" HARNESS_TEST_SANDBOX=1 bash "$0" >/dev/null 2>&1; MRC=$?
    [ "$MRC" != 0 ] && ok || bad "mutation leg: the suite stayed GREEN against the pre-fix fleet-conf.sh"
  fi
fi

echo "bh-1956-fleet-conf-tailnet: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
