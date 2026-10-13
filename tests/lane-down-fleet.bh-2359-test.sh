#!/bin/bash
# tests/lane-down-fleet.bh-2359-test.sh — BH-2359 (BH-2319.4): the lane-down
# writers stamp and clear `lane` rows through bin/lib/fleet-cooldown.sh, and
# bin/lane-reprobe.sh reseeds hub records from them. FLEET_COOLDOWN_STORE (the
# contract's file backend) stands in for the fleet in every case.
#   F1  ld_mark puts lane openrouter hub with until = now+TTL, since, error; a
#       second mark refreshes the until and keeps the since. F1b: the TTL knob.
#   F2  that row does not make lane codex hub or lane openrouter small live
#   F3  empty hub state + a live row: one real lane-reprobe.sh tick seeds the
#       record with the row's since. F3b claude row seeds nothing, F3c an
#       existing record is untouched, F3d an expired row seeds nothing.
#   F4a ld_clear clears the row while the record still exists (before removal)
#   F4b a failing clear still removes local state and logs its rc
#   F5  the real claude-auth-check.sh puts/clears lane claude hub with the
#       hub STATE line; project-1-lane never gets a row
#   F6  mutation: a copy of lane-reprobe.sh without the seed_fleet call turns F3 red
# Run from anywhere: tests/lane-down-fleet.bh-2359-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
REAL_DATE=$(command -v date)

# row <store> <kind> <vendor> <subject> -> the store line's fields, tab separated
row() { awk -F'\t' -v k="$2" -v v="$3" -v s="$4" '$1==k && $2==v && $3==s' "$1" 2>/dev/null; }
field() { cut -f"$1"; }

# ---- F1 / F1b / F2: the lib, sourced -----------------------------------------
L=$T/lib; scratch_rm "$L"; mkdir -p "$L/h"
S=$L/store.tsv
now=$("$REAL_DATE" +%s)
(
  export FLEET_COOLDOWN_STORE=$S
  unset LANE_DOWN_TTL_S FLEET_COOLDOWN_DB
  . "$DIR/bin/lib/lane-down.sh"
  ld_mark "$L/h" hub-openrouter "" "401 bad key" "$now"
) ; rc=$?
[ "$rc" = 0 ] && ok || bad "F1 ld_mark rc=$rc"
r1=$(row "$S" lane openrouter hub)
[ -n "$r1" ] && ok || bad "F1 no lane openrouter hub row: $(cat "$S" 2>/dev/null)"
u1=$(field 4 <<<"$r1"); s1=$(field 5 <<<"$r1")
[ "$u1" = "$((now + 7200))" ] && ok || bad "F1 until=$u1, want $((now + 7200))"
[ "$s1" = "$now" ] && ok || bad "F1 since=$s1, want $now"
[ "$(field 6 <<<"$r1")" = "401 bad key" ] && ok || bad "F1 reason='$(field 6 <<<"$r1")'"
(
  export FLEET_COOLDOWN_STORE=$S; unset LANE_DOWN_TTL_S FLEET_COOLDOWN_DB
  . "$DIR/bin/lib/lane-down.sh"
  ld_mark "$L/h" hub-openrouter "" "still 401" "$((now + 60))"
)
r2=$(row "$S" lane openrouter hub)
u2=$(field 4 <<<"$r2"); s2=$(field 5 <<<"$r2")
[ "${u2:-0}" -gt "${u1:-0}" ] && ok || bad "F1 second mark until=$u2 not later than $u1"
[ "$s2" = "$now" ] && ok || bad "F1 second mark moved since to $s2"
[ "$(grep -c . "$S" 2>/dev/null)" = 1 ] && ok || bad "F1 want one store row, got $(grep -c . "$S" 2>/dev/null)"
# F1b: the knob, and a non-numeric knob is its default
for ttl in 60 abc; do
  S2=$L/store-$ttl.tsv
  (
    export FLEET_COOLDOWN_STORE=$S2 LANE_DOWN_TTL_S=$ttl; unset FLEET_COOLDOWN_DB
    . "$DIR/bin/lib/lane-down.sh"
    ld_mark "$L/h$ttl" hub-openrouter "" "x" "$now"
  )
  want=$((now + 7200)); [ "$ttl" = 60 ] && want=$((now + 60))
  got=$(row "$S2" lane openrouter hub | field 4)
  [ "$got" = "$want" ] && ok || bad "F1b LANE_DOWN_TTL_S=$ttl until=$got, want $want"
done
# F2: exact key match, never a neighbour
(
  export FLEET_COOLDOWN_STORE=$S HARNESS=$L/h; . "$DIR/bin/lib/fleet-cooldown.sh"
  fcd_live lane openrouter hub; a=$?
  fcd_live lane codex hub; b=$?
  fcd_live lane openrouter small; c=$?
  echo "$a $b $c"
) > "$L/f2.txt"
[ "$(cat "$L/f2.txt")" = "0 1 1" ] && ok || bad "F2 live rc (openrouter/hub codex/hub openrouter/small) = $(cat "$L/f2.txt"), want 0 1 1"

# ---- F3 / F6: the real lane-reprobe.sh -----------------------------------------
# reprobe_tree <root> [script]: scratch harness, lane-probe answers a failure
reprobe_tree() {
  local R=$1
  scratch_rm "$R"; mkdir -p "$R/bin/lib" "$R/env" "$R/state" "$R/flags" "$R/logs" "$R/locks" "$R/fakebin"
  cp "${2:-$DIR/bin/lane-reprobe.sh}" "$R/bin/lane-reprobe.sh"
  cp "$DIR/bin/lib/lane-down.sh" "$DIR/bin/lib/fleet-cooldown.sh" "$R/bin/lib/"
  : > "$R/env/global.env"; : > "$R/state/claude-auth-down.txt"
  printf '#!/bin/bash\necho "local $1" >> "$(dirname "$0")/../calls.txt"\necho "401 unauthorized"\nexit 1\n' > "$R/bin/lane-probe.sh"
  printf '#!/bin/bash\necho "$*" >> "$(dirname "$0")/../calls.txt"\necho "401 unauthorized"\nexit 1\n' > "$R/fakebin/ssh"
  printf '#!/bin/bash\nexit 0\n' > "$R/bin/lane-alert.sh"
  cat > "$R/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
[ "$1" = --tailnet-ip-of-box ] || exit 1
case "$2" in box-project-3-2) echo 192.0.2.2 ;; *) exit 1 ;; esac
EOF
  chmod +x "$R"/bin/*.sh "$R"/fakebin/*
}
run_reprobe() { HARNESS=$1 FLEET_COOLDOWN_STORE=$1/store.tsv PATH="$1/fakebin:$PATH" bash "$1/bin/lane-reprobe.sh"; }
now=$("$REAL_DATE" +%s)
fleet_row() { printf 'lane\t%s\t%s\t%s\t%s\t%s\tsomebox\t%s\n' "$2" "$3" "$4" "$5" "$6" "$now" >> "$1/store.tsv"; }

R=$T/f3; reprobe_tree "$R"
fleet_row "$R" openrouter project-3-2 "$((now + 3600))" "$((now - 5000))" "402 no credits"
fleet_row "$R" claude hub "$((now + 3600))" "$((now - 4000))" "not logged in"
fleet_row "$R" codex project-3-2 "$((now - 10))" "$((now - 9000))" "expired row"
run_reprobe "$R"; rc=$?
[ "$rc" = 0 ] && ok || bad "F3 lane-reprobe rc=$rc"
REC=$R/state/lane-down/project-3-2-openrouter
[ -f "$REC" ] && ok || bad "F3 no record seeded from the fleet row: $(cat "$R/logs/lane-reprobe.log" 2>/dev/null)"
[ "$(awk -F= '$1=="since"{print $2}' "$REC" 2>/dev/null)" = "$((now - 5000))" ] && ok \
  || bad "F3 since=$(awk -F= '$1=="since"{print $2}' "$REC" 2>/dev/null), want the row's $((now - 5000))"
grep -qxF project-3-2-openrouter "$R/state/claude-auth-down.txt" && ok || bad "F3 no STATE line"
grep -q 'seeded project-3-2-openrouter from fleet row' "$R/logs/lane-reprobe.log" 2>/dev/null && ok || bad "F3 no seeded log line"
[ ! -e "$R/state/lane-down/hub-claude" ] && ! grep -qx 'hub' "$R/state/claude-auth-down.txt" && ok || bad "F3b claude row seeded hub state"
[ ! -e "$R/state/lane-down/project-3-2-codex" ] && ok || bad "F3d expired row seeded a record"
# F3c: an existing record keeps its own since, no seeded line
R=$T/f3c; reprobe_tree "$R"
mkdir -p "$R/state/lane-down"
printf 'box=project-3-2\nlane=openrouter\naddr=\nsince=%s\nlast_probe=%s\nlast_error=x\nstanding_at=\n' \
  "$((now - 100))" "$now" > "$R/state/lane-down/project-3-2-openrouter"
fleet_row "$R" openrouter project-3-2 "$((now + 3600))" "$((now - 5000))" "402"
run_reprobe "$R"
[ "$(awk -F= '$1=="since"{print $2}' "$R/state/lane-down/project-3-2-openrouter")" = "$((now - 100))" ] && ok || bad "F3c existing record's since moved"
grep -q seeded "$R/logs/lane-reprobe.log" 2>/dev/null && bad "F3c existing record was re-seeded" || ok

# F6: mutation — the reprobe without its seed_fleet call must not seed
M=$T/lane-reprobe.mut.sh
sed '/^seed_fleet "\$start"$/d' "$DIR/bin/lane-reprobe.sh" > "$M"
cmp -s "$M" "$DIR/bin/lane-reprobe.sh" && bad "F6 mutation was a no-op (no seed_fleet \"\$start\" line)" || ok
R=$T/f6; reprobe_tree "$R" "$M"
fleet_row "$R" openrouter project-3-2 "$((now + 3600))" "$((now - 5000))" "402"
run_reprobe "$R"
[ ! -e "$R/state/lane-down/project-3-2-openrouter" ] && ok || bad "F6 mutated reprobe still seeded (F3 would stay green)"

# ---- F4a / F4b: ld_clear ordering and fail-open --------------------------------
clear_tree() {
  local R=$1
  scratch_rm "$R"; mkdir -p "$R/state/lane-down" "$R/flags" "$R/logs"
  printf 'box=hub\nlane=openrouter\naddr=local\nsince=%s\nlast_probe=%s\nlast_error=x\nstanding_at=\n' \
    "$((now - 600))" "$now" > "$R/state/lane-down/hub-openrouter"
  printf 'hub\nhub-openrouter\n' > "$R/state/claude-auth-down.txt"
  touch "$R/flags/lanedown-hub-openrouter-$("$REAL_DATE" -u -d "@$now" +%Y%m%d)"
  printf 'lane\topenrouter\thub\t%s\t%s\tx\thub\t%s\n' "$((now + 3600))" "$((now - 600))" "$now" > "$R/store.tsv"
}
R=$T/f4a; clear_tree "$R"
out=$(
  export FLEET_COOLDOWN_STORE=$R/store.tsv
  . "$DIR/bin/lib/lane-down.sh"
  eval "_real_$(declare -f fcd_clear)"
  fcd_clear() { [ -e "$R/state/lane-down/hub-openrouter" ] && echo exists > "$R/seen" || echo gone > "$R/seen"; _real_fcd_clear "$@"; }
  ld_clear "$R" hub-openrouter "$now"
)
[ "$(cat "$R/seen" 2>/dev/null)" = exists ] && ok || bad "F4a fcd_clear saw the record '$(cat "$R/seen" 2>/dev/null)', want exists (clear BEFORE removal)"
[ -z "$(row "$R/store.tsv" lane openrouter hub)" ] && ok || bad "F4a row survived ld_clear"
[ ! -e "$R/state/lane-down/hub-openrouter" ] && ok || bad "F4a record survived"
grep -qxF hub-openrouter "$R/state/claude-auth-down.txt" && bad "F4a STATE line survived" || ok
[ "$out" = 10m ] && ok || bad "F4a stdout '$out', want 10m"
[ ! -s "$R/logs/agent-rules.log" ] && ok || bad "F4a a successful clear logged: $(cat "$R/logs/agent-rules.log")"

R=$T/f4b; clear_tree "$R"
out=$(
  export FLEET_COOLDOWN_STORE=$R/store.tsv
  . "$DIR/bin/lib/lane-down.sh"
  fcd_clear() { return 2; }
  ld_clear "$R" hub-openrouter "$now"
); rc=$?
[ "$rc" = 0 ] && ok || bad "F4b ld_clear rc=$rc with a failing fcd_clear"
[ "$out" = 10m ] && ok || bad "F4b stdout '$out', want 10m"
[ ! -e "$R/state/lane-down/hub-openrouter" ] && ok || bad "F4b record survived a failed clear"
grep -qxF hub-openrouter "$R/state/claude-auth-down.txt" && bad "F4b STATE line survived" || ok
grep -q . <<<"$(ls "$R/flags")" && bad "F4b flag survived" || ok
[ "$(grep -c 'fcd_clear lane openrouter hub rc 2' "$R/logs/agent-rules.log" 2>/dev/null)" = 1 ] && ok \
  || bad "F4b want one rc 2 line in agent-rules.log: $(cat "$R/logs/agent-rules.log" 2>/dev/null)"

# ---- F5: the real claude-auth-check.sh ---------------------------------------
auth_tree() {
  local R=$1
  scratch_rm "$R"; mkdir -p "$R/bin/lib" "$R/fakebin" "$R/state" "$R/flags" "$R/logs" "$R/locks"
  cp "$DIR/bin/lib/lane-down.sh" "$DIR/bin/lib/fleet-cooldown.sh" "$R/bin/lib/"
  cp "$DIR/bin/claude-auth-check.sh" "$R/bin/"
  echo 'lane_role_model() { echo m-test; }' > "$R/bin/lib/lane-model.sh"
  printf '#!/bin/bash\nexit 0\n' > "$R/bin/fleet-conf.sh"
  printf '#!/bin/bash\nexit 0\n' > "$R/bin/box-for.sh"
  printf '#!/bin/bash\nexit 0\n' > "$R/bin/beat.sh"
  printf '#!/bin/bash\nexit 0\n' > "$R/bin/lane-alert.sh"
  printf '#!/bin/bash\necho ok\n' > "$R/bin/lane-probe.sh"
  printf '#!/bin/bash\n# BH-2560: the probe now calls agent-call.sh; forward it to the stub claude on PATH\nclaude -p "$6" --model "$3" >"$5" 2>"$5.err"; exit $?\n' > "$R/bin/agent-call.sh"; chmod +x "$R/bin/agent-call.sh"
  # hour 01: the 6h runner canary stays out of this case
  cat > "$R/fakebin/date" <<SH
#!/bin/bash
for a in "\$@"; do [ "\$a" = "+%H" ] && { echo 01; exit 0; }; done
exec $REAL_DATE "\$@"
SH
  printf '#!/bin/bash\nexit 1\n' > "$R/fakebin/ssh"
  : > "$R/state/claude-auth-down.txt"
  chmod +x "$R"/bin/*.sh "$R"/fakebin/*
}
run_auth() { HARNESS=$1 FLEET_COOLDOWN_STORE=$1/store.tsv PATH="$1/fakebin:$PATH" bash "$1/bin/claude-auth-check.sh" >"$1/out.txt" 2>&1; }
R=$T/f5; auth_tree "$R"
printf '#!/bin/bash\necho "Not logged in · Please run /login"\n' > "$R/fakebin/claude"; chmod +x "$R/fakebin/claude"
run_auth "$R"; rc=$?
[ "$rc" = 0 ] && ok || bad "F5a rc=$rc: $(cat "$R/out.txt")"
grep -qx hub "$R/state/claude-auth-down.txt" && ok || bad "F5a no hub STATE line: $(cat "$R/state/claude-auth-down.txt")"
( export FLEET_COOLDOWN_STORE=$R/store.tsv HARNESS=$R; . "$DIR/bin/lib/fleet-cooldown.sh"; fcd_live lane claude hub ); rc=$?
[ "$rc" = 0 ] && ok || bad "F5a lane claude hub not live (rc $rc): $(cat "$R/store.tsv" 2>/dev/null)"
[ -z "$(row "$R/store.tsv" lane claude project-1-lane)" ] && ok || bad "F5c project-1-lane got a row"
# the probe asks for AUTHPROBE-<code>; answering it is PROBE_OK
printf '#!/bin/bash\nprintf "AUTHPROBE-%%s\\n" "$(printf "%%s" "$2" | grep -oE "code [0-9a-f]+" | awk "{print \\$2}" | head -1)"\n' > "$R/fakebin/claude"
run_auth "$R"; rc=$?
[ "$rc" = 0 ] && ok || bad "F5b rc=$rc: $(cat "$R/out.txt")"
grep -qx hub "$R/state/claude-auth-down.txt" && bad "F5b hub STATE line survived an ok probe" || ok
[ -z "$(row "$R/store.tsv" lane claude hub)" ] && ok || bad "F5b lane claude hub row survived recovery"
[ -z "$(row "$R/store.tsv" lane claude project-1-lane)" ] && ok || bad "F5c project-1-lane got a row"

echo "lane-down-fleet: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
