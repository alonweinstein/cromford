#!/bin/bash
# tests/fleet-status-fly-test.sh — self-contained assertions for
# bin/fleet-fly-block.sh, the `fly` section of the fleet-status snapshot.
# The invariant that matters: a project with no pool dir, no builder state and
# no pool-app flag must still appear with EMPTY arrays. Mission Control reading
# "no machines" is truth; a missing key or a jq error is a blank pane that looks
# identical to a dead fleet.
# Run from anywhere: tests/fleet-status-fly-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS="$T"

cat > "$T/fleet.conf" <<'EOF'
# fixture registry
alpha-os  Org/alpha  https://alpha.example  /api/board  2 box-alpha
beta-os   Org/beta   https://beta.example   /api/board  4 box-beta
gamma-os  Org/gamma  -                      -           6 box-gamma
EOF
export FLEET_CONF="$T/fleet.conf"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
run() { "$DIR/bin/fleet-fly-block.sh" 2>/dev/null; }

# ---------- 1. nothing on disk at all ----------
OUT=$(run); RC=$?
[ "$RC" -eq 0 ] && jq -e . >/dev/null 2>&1 <<<"$OUT" || bad "bare harness should still emit JSON (rc=$RC out=$OUT)"
[ "$(jq -r 'keys | join(",")' <<<"$OUT")" = "alpha-os,beta-os,gamma-os" ] \
  && ok || bad "every fleet.conf project must appear (got: $(jq -c 'keys' <<<"$OUT"))"
[ "$(jq -c '."alpha-os"' <<<"$OUT")" = '{"pool_app":"","builder":null,"machines":[]}' ] \
  && ok || bad "empty project shape (got: $(jq -c '."alpha-os"' <<<"$OUT"))"

# ---------- 2. a populated pool ----------
mkdir -p "$T/state/fly-pool/alpha-os" "$T/state/fly" "$T/flags"
cat > "$T/state/fly-pool/alpha-os/148e2.json" <<'EOF'
{"machine":"148e2","key":"TK-11","ticket_id":"tk-11","attempt":0,"spawned_at":"2026-08-23 09:00:00Z"}
EOF
cat > "$T/state/fly-pool/alpha-os/329f7.json" <<'EOF'
{"machine":"329f7","key":"TK-12","ticket_id":"tk-12","attempt":1,"spawned_at":"2026-08-23 09:20:00Z","reused_from":"148e2"}
EOF
cat > "$T/state/fly/alpha-os.json" <<'EOF'
{"app":"builder-alpha-os","machine_id":"9080ee","volume_id":"vol_1","size":"performance-2x","region":"iad"}
EOF
echo 'pool-alpha-os' > "$T/flags/fly-pool-app-alpha-os"

OUT=$(run)
[ "$(jq -r '."alpha-os".pool_app' <<<"$OUT")" = "pool-alpha-os" ] \
  && ok || bad "pool_app read from flags/fly-pool-app-<project>"
[ "$(jq -c '."alpha-os".builder' <<<"$OUT")" = '{"app":"builder-alpha-os","machine_id":"9080ee"}' ] \
  && ok || bad "builder is {app,machine_id} only (got: $(jq -c '."alpha-os".builder' <<<"$OUT"))"
[ "$(jq -r '."alpha-os".machines | length' <<<"$OUT")" = 2 ] \
  && ok || bad "both pool machines listed"
# Sorted by machine id so the pane does not reshuffle between polls.
[ "$(jq -r '[."alpha-os".machines[].machine] | join(",")' <<<"$OUT")" = "148e2,329f7" ] \
  && ok || bad "machines sorted by id"
[ "$(jq -c '."alpha-os".machines[0]' <<<"$OUT")" \
  = '{"machine":"148e2","key":"TK-11","ticket_id":"tk-11","attempt":0,"spawned_at":"2026-08-23 09:00:00Z"}' ] \
  && ok || bad "machine shape (got: $(jq -c '."alpha-os".machines[0]' <<<"$OUT"))"
# The other projects are untouched by alpha's state.
[ "$(jq -c '."beta-os"' <<<"$OUT")" = '{"pool_app":"","builder":null,"machines":[]}' ] \
  && ok || bad "sibling project must stay empty"

# ---------- 3. junk on disk must not take the snapshot down ----------
# fly-pool.sh writes .<machine>.snapmt sidecars next to the json, and a machine
# file can be caught half-written between the jq and the mv.
echo 'not json at all' > "$T/state/fly-pool/alpha-os/broken.json"
: > "$T/state/fly-pool/alpha-os/empty.json"
echo '1755940000' > "$T/state/fly-pool/alpha-os/.148e2.snapmt"
OUT=$(run); RC=$?
[ "$RC" -eq 0 ] && jq -e . >/dev/null 2>&1 <<<"$OUT" \
  && ok || bad "unparseable pool file must not break the snapshot (rc=$RC)"
[ "$(jq -r '."alpha-os".machines | length' <<<"$OUT")" = 2 ] \
  && ok || bad "junk files are skipped, real machines still reported"

# ---------- 4. builder state present but pool state absent ----------
cat > "$T/state/fly/beta-os.json" <<'EOF'
{"app":"builder-beta-os","machine_id":"77aa11"}
EOF
OUT=$(run)
[ "$(jq -c '."beta-os"' <<<"$OUT")" \
  = '{"pool_app":"","builder":{"app":"builder-beta-os","machine_id":"77aa11"},"machines":[]}' ] \
  && ok || bad "builder without pool (got: $(jq -c '."beta-os"' <<<"$OUT"))"

# ---------- 5. an unreadable builder file is null, not a crash ----------
echo '{oops' > "$T/state/fly/gamma-os.json"
OUT=$(run); RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r '."gamma-os".builder' <<<"$OUT")" = null ] \
  && ok || bad "unparseable builder state -> null (rc=$RC)"

echo "fleet-status-fly-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
