#!/bin/bash
# tests/registry-db-read.bh-5649-test.sh — BH-5649 (the ticket's
# tests/registry-db-read-test.sh): with REGISTRY_SOURCE=db and a fixture
# /api/registry answer, bin/fleet-conf.sh, bin/box-for.sh and bin/render-cron.sh
# print exactly what the committed files print, for every row of today's
# fleet.conf; and the db path is really the one answering (P5, P8, R2).
#
#   P1 every project x repo|prod|board_prefix|offset|box|tailnet_ip, --tailnet-ip
#      and box-for.sh: stdout and rc equal between modes (seeder fixture)
#   P2 --projects, --projects-with-board, --tailnet-ips, --projects-on-box,
#      --tailnet-ip-of-box: byte-identical
#   P3 hand fixture: a legacy row with no box, a box with no IP
#   P4 --standby, --standby-of, --retired survive the round trip
#   P5 non-vacuity: a repo changed in the registry is what db mode prints
#   P6 the TTL: a fresh cache makes no call, TTL 0 makes exactly one
#   P7 file mode (the default) makes no call and writes no state
#   P8 FLEET_CONF does not mask db mode
#   R1 render-cron.sh parity for every box; R2 a (lane, box) pair the registry
#      drops is gone from that box only; R3 a lane the registry never heard of
#      keeps its file .boxes
#
# The curl stub on PATH reads $T/stub/{rc,http,body} and logs one line a call.
# db-mode runs point FLEET_CONF at a DECOY registry, so a db answer that fell
# back to a file could never pass a parity check by accident.
# Run from anywhere: tests/registry-db-read.bh-5649-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FC="$DIR/bin/fleet-conf.sh"
BF="$DIR/bin/box-for.sh"
RC="$DIR/bin/render-cron.sh"
SEED="$DIR/bin/registry-seed.sh"
RLIB="$DIR/bin/lib/registry.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -f "$RLIB" ] && bash -n "$RLIB" && ok || bad "bin/lib/registry.sh missing or does not parse"

mkdir -p "$T/bin" "$T/stub"
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
S="${CURL_STUB_DIR:?}"
{ printf '%s ' "$@" | tr '\n' ' '; echo; } >> "$S/calls"
rc=$(cat "$S/rc" 2>/dev/null); rc=${rc:-0}
[ "$rc" = 0 ] || exit "$rc"
cat "$S/body" 2>/dev/null
printf '\n%s' "$(cat "$S/http" 2>/dev/null || echo 200)"
SH
chmod +x "$T/bin/curl"
: > "$T/stub/calls"; echo 0 > "$T/stub/rc"; echo 200 > "$T/stub/http"
calls() { wc -l < "$T/stub/calls" | tr -d ' '; }

printf 'decoy Acme/decoy - - 0 box-decoy 10.0.0.9\n' > "$T/decoy.conf"
HH="$T/h"
# db <cmd...> — the command in db mode against the stub and $HH.
db() {
  env PATH="$T/bin:$PATH" HARNESS="$HH" JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret \
    REGISTRY_SOURCE=db CURL_STUB_DIR="$T/stub" FLEET_CONF="${DBCONF:-$T/decoy.conf}" "$@" 2>/dev/null
}
# fm <conf> <cmd...> — the same command in file mode on <conf>.
fm() { local c="$1"; shift; env PATH="$T/bin:$PATH" HARNESS="$T/hf" CURL_STUB_DIR="$T/stub" FLEET_CONF="$c" "$@" 2>/dev/null; }
both() { # both <label> <conf> <cmd...> — stdout+rc equal between modes
  local l="$1" c="$2" a b; shift 2
  a=$(fm "$c" "$@"; echo "rc=$?"); b=$(db "$@"; echo "rc=$?")
  if [ "$a" = "$b" ]; then ok; else bad "$l: file [$a] db [$b]"; fi
}
serve() { cp "$1" "$T/stub/body"; scratch_rm "$HH/state/registry"; }

# ---- the full registry, built by the seeder from today's files ---------------
if ! "$SEED" --emit --root "$DIR" > "$T/payload.json" 2>"$T/seed.err"; then
  bad "seeder --emit failed: $(head -c 300 "$T/seed.err")"
fi
jq '. + {version: 7, updated_at: "2026-10-09T00:00:00Z"} | del(.actor)' "$T/payload.json" > "$T/real.json" 2>/dev/null \
  || bad "could not build the real-registry fixture"
REAL="$DIR/fleet.conf"
serve "$T/real.json"

# ---- P1 every row, every field ----------------------------------------------
NP=0
while read -r P; do
  [ -n "$P" ] || continue; NP=$((NP+1))
  for F in repo prod board_prefix offset box tailnet_ip; do both "P1 $P $F" "$REAL" "$FC" "$P" "$F"; done
  both "P1 --tailnet-ip $P" "$REAL" "$FC" --tailnet-ip "$P"
  both "P1 box-for $P" "$REAL" "$BF" "$P"
done < <(fm "$REAL" "$FC" --projects)
[ "$NP" -ge 10 ] && ok || bad "P1 walked only $NP projects of today's fleet.conf"
both "P1 unknown project" "$REAL" "$FC" no-such-project repo
[ "$(calls)" -ge 1 ] && ok || bad "P1 db mode made no call to the stub"

# ---- P2 list verbs -----------------------------------------------------------
for V in --projects --projects-with-board --tailnet-ips; do both "P2 $V" "$REAL" "$FC" "$V"; done
for B in $(awk '!/^[[:space:]]*(#|$)/ && $6 != "" {print $6}' "$REAL" | sort -u) local no-such-box; do
  both "P2 --projects-on-box $B" "$REAL" "$FC" --projects-on-box "$B"
  both "P2 --tailnet-ip-of-box $B" "$REAL" "$FC" --tailnet-ip-of-box "$B"
done

# ---- P4 directives -----------------------------------------------------------
both "P4 --standby" "$REAL" "$FC" --standby
both "P4 --standby-of" "$REAL" "$FC" --standby-of box-small
both "P4 --standby-of none" "$REAL" "$FC" --standby-of box-project-4-1
both "P4 --retired" "$REAL" "$FC" --retired
[ -n "$(fm "$REAL" "$FC" --retired)" ] && ok || bad "P4 is vacuous: today's fleet.conf has no @retired line"

# ---- P3 hand fixture: legacy row with no box, a box with no IP ----------------
cat > "$T/hand.conf" <<'EOF'
alpha-os Acme/alpha-os https://alpha.example /api/board 2 box-alpha 10.9.9.1
delta    Acme/delta    -                     -          8 box-small 10.9.9.3
zeta-os  Acme/zeta-os  https://zeta.example  /api/board 1
nip      Acme/nip      -                     -          4 box-noip
EOF
cat > "$T/hand.json" <<'EOF'
{"version": 3, "updated_at": "2026-10-09T00:00:00Z",
 "projects": [
  {"project":"alpha-os","repo":"Acme/alpha-os","prod":"https://alpha.example","board_prefix":"/api/board","cron_offset":2,"box":"box-alpha","position":0,"status":"active"},
  {"project":"delta","repo":"Acme/delta","prod":"-","board_prefix":"-","cron_offset":8,"box":"box-small","position":1,"status":"active"},
  {"project":"zeta-os","repo":"Acme/zeta-os","prod":"https://zeta.example","board_prefix":"/api/board","cron_offset":1,"box":null,"position":2,"status":"active"},
  {"project":"nip","repo":"Acme/nip","prod":"-","board_prefix":"-","cron_offset":4,"box":"box-noip","position":3,"status":"active"}],
 "boxes": [
  {"box":"box-alpha","box_id":"alpha","tailnet_ip":"10.9.9.1","cost_box":null,"standby_hub_name":null,"standby_hub_id":null},
  {"box":"box-noip","box_id":"noip","tailnet_ip":null,"cost_box":null,"standby_hub_name":null,"standby_hub_id":null},
  {"box":"box-small","box_id":"small","tailnet_ip":"10.9.9.3","cost_box":"small","standby_hub_name":null,"standby_hub_id":null}],
 "lane_boxes": [], "box_accounts": []}
EOF
serve "$T/hand.json"
for P in alpha-os delta zeta-os nip; do
  for F in repo box tailnet_ip; do both "P3 $P $F" "$T/hand.conf" "$FC" "$P" "$F"; done
  both "P3 box-for $P" "$T/hand.conf" "$BF" "$P"
done
[ "$(db "$BF" zeta-os)" = box-zeta ] && ok || bad "P3 legacy row: box-for.sh zeta-os in db mode = '$(db "$BF" zeta-os)'"
OUT=$(db "$FC" nip tailnet_ip); R=$?
[ "$R" = 1 ] && [ -z "$OUT" ] && ok || bad "P3 a box with no IP must be rc 1 and empty, got rc $R '$OUT'"
OUT=$(db "$FC" --tailnet-ip nip); R=$?
[ "$R" = 1 ] && [ -z "$OUT" ] && ok || bad "P3 --tailnet-ip nip must be rc 1 and empty, got rc $R '$OUT'"

# ---- P5 non-vacuity ------------------------------------------------------------
jq '(.projects[] | select(.project == "alpha-os") | .repo) = "Acme/from-db"' "$T/hand.json" > "$T/fromdb.json"
serve "$T/fromdb.json"; : > "$T/stub/calls"
OUT=$(DBCONF="$T/hand.conf" db "$FC" alpha-os repo)
[ "$OUT" = "Acme/from-db" ] && ok || bad "P5 db mode printed '$OUT', want Acme/from-db"
[ "$(calls)" -ge 1 ] && ok || bad "P5 no call reached the stub"
grep -q 'jobs.test/api/registry' "$T/stub/calls" && ok || bad "P5 the call was not GET /api/registry: $(cat "$T/stub/calls")"

# ---- P6 TTL --------------------------------------------------------------------
: > "$T/stub/calls"
REGISTRY_CACHE_TTL_S=3600 db "$FC" alpha-os repo >/dev/null
[ "$(calls)" = 0 ] && ok || bad "P6 a fresh cache made $(calls) call(s)"
REGISTRY_CACHE_TTL_S=0 db "$FC" alpha-os repo >/dev/null
[ "$(calls)" = 1 ] && ok || bad "P6 TTL 0 made $(calls) call(s), want 1"

# ---- P7 file mode costs nothing ------------------------------------------------
: > "$T/stub/calls"
for _ in $(seq 20); do
  env PATH="$T/bin:$PATH" HARNESS="$T/h7" JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret \
    CURL_STUB_DIR="$T/stub" FLEET_CONF="$T/hand.conf" "$FC" alpha-os repo >/dev/null 2>&1
done
[ "$(calls)" = 0 ] && ok || bad "P7 file mode made $(calls) call(s)"
[ ! -e "$T/h7/state/registry" ] && ok || bad "P7 file mode created $T/h7/state/registry"
[ "$(env FLEET_CONF="$T/hand.conf" "$FC" alpha-os repo)" = Acme/alpha-os ] && ok || bad "P7 file mode answer changed"

# ---- P8 FLEET_CONF does not mask db --------------------------------------------
serve "$T/fromdb.json"
OUT=$(DBCONF="$DIR/fleet.conf" db "$FC" alpha-os repo)
[ "$OUT" = "Acme/from-db" ] && ok || bad "P8 with FLEET_CONF set, db mode printed '$OUT'"

# ---- R1-R3 render-cron.sh ------------------------------------------------------
serve "$T/real.json"
BOXES=$( { ls "$DIR/cron/boxes" | sed -n 's/\.d$//p'; jq -r '.lane_boxes[].box_id' "$T/real.json"; } | sort -u)
render_fm() { env HARNESS="$T/hf" FLEET_CONF="$DIR/fleet.conf" "$RC" --root "$DIR" "$1" 2>&1; echo "rc=$?"; }
render_db() { env PATH="$T/bin:$PATH" HARNESS="$HH" JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret \
  REGISTRY_SOURCE=db CURL_STUB_DIR="$T/stub" "$RC" --root "$DIR" "$1" 2>&1; echo "rc=$?"; }
NB=0
for B in $BOXES; do
  NB=$((NB+1))
  render_fm "$B" > "$T/r-fm-$B"
  render_db "$B" > "$T/r-db-$B"
  cmp -s "$T/r-fm-$B" "$T/r-db-$B" && ok || bad "R1 render of $B differs between modes: $(diff "$T/r-fm-$B" "$T/r-db-$B" | head -5)"
done
[ "$NB" -ge 8 ] && ok || bad "R1 rendered only $NB boxes"

# Pick a lane on >=2 boxes whose fragment renders a plain line on box "small".
. "$DIR/bin/lib/lanes-registry.sh"
LJ=$(lanes_json_path "$DIR")
LANE=""; LINE=""
for L in $(jq -r '.lanes[] | select((.boxes // []) | (index("small") != null) and (length >= 2)) | .id' "$LJ"); do
  for F in "$DIR"/cron/lanes/[0-9][0-9][0-9]-"$L".cron; do
    [ -f "$F" ] || continue
    C=$(grep -v '^#' "$F" | grep -v '@' | grep -m1 '[^[:space:]]') || continue
    grep -qxF "$C" "$T/r-fm-small" || continue
    LANE="$L"; LINE="$C"; break 2
  done
done
if [ -z "$LANE" ]; then
  bad "R2 found no lane on small (and another box) with a plain fragment line"
else
  OTHER=$(jq -r --arg l "$LANE" '[.lanes[] | select(.id == $l) | .boxes[] | select(. != "small")][0]' "$LJ")
  jq --arg l "$LANE" '.lane_boxes |= map(select(.lane != $l or .box_id != "small"))' "$T/real.json" > "$T/r2.json"
  serve "$T/r2.json"
  render_db small > "$T/r2-small"
  grep -qxF "$LINE" "$T/r2-small" && bad "R2 db render of small still carries lane $LANE: $LINE" || ok
  render_db "$OTHER" > "$T/r2-other"
  cmp -s "$T/r-fm-$OTHER" "$T/r2-other" && ok || bad "R2 render of $OTHER changed when only small lost $LANE"
  # R3: no registry row at all for the lane = the file's .boxes stand.
  jq --arg l "$LANE" '.lane_boxes |= map(select(.lane != $l))' "$T/real.json" > "$T/r3.json"
  serve "$T/r3.json"
  render_db small > "$T/r3-small"
  cmp -s "$T/r-fm-small" "$T/r3-small" && ok || bad "R3 a lane absent from the registry changed the render of small"
fi

echo "registry-db-read: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
