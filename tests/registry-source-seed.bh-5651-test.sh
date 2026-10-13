#!/bin/bash
# tests/registry-source-seed.bh-5651-test.sh — BH-5651: the fleet switch.
# bin/lib/registry-source-seed.sh registry_source_seed, driven through the
# block of bin/harness-sync.sh that calls it (extracted and run as written),
# against the REAL harness-jobs worker over SQLite
# (tests/lib/registry-fixture.bh-5650.sh) seeded from this tree's files.
# Every case asserts the count and value of the ^REGISTRY_SOURCE= lines in
# env/global.env and the ALERTS.log line count.
#
#   F1 FLIP: no line, registry v>=1 with the checkout's project set
#   F2 FLIP (edge): only a commented `# REGISTRY_SOURCE=file` line
#   N1 NO FLIP: REGISTRY_SOURCE=file          N2 NO FLIP: REGISTRY_SOURCE=db
#   N3 NO FLIP: the registry is unreachable (one log line a day, no cache left)
#   N4 NO FLIP: the registry lacks one checkout project
#   N5 NO FLIP (edge): the registry answers {}
#   N6 NO FLIP: REGISTRY_SOURCE=DB and REGISTRY_SOURCE= (empty) are operator lines
#   N7 no global.env: rc 0, nothing created
#   A1 a failed append: rc 1 and exactly ONE ALERTS line
#   D1 an unset REGISTRY_SOURCE still means file for bin/fleet-conf.sh
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
. "$DIR/tests/lib/registry-fixture.bh-5650.sh" || exit 1
LIB="$DIR/bin/lib/registry-source-seed.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

rfx_setup; R=$?
[ "$R" -ne 3 ] || { echo "SKIP: node:sqlite is not available"; exit 0; }
[ "$R" -eq 0 ] || { echo "FAIL: the fixture registry could not be seeded"; exit 1; }
[ -r "$LIB" ] && ok || bad "no $LIB"

# The seed block of bin/harness-sync.sh, run exactly as written.
sed -n '/^if \[ -r "\$CHECKOUT\/bin\/lib\/registry-source-seed.sh" \]/,/^fi$/p' "$DIR/bin/harness-sync.sh" > "$T/seed-block.sh"
[ "$(wc -l < "$T/seed-block.sh")" = 3 ] && grep -q 'registry_source_seed "\$CHECKOUT" "\$HENV/global.env" "\$HARNESS"' "$T/seed-block.sh" \
  && ok || bad "could not extract the harness-sync seed block: $(cat "$T/seed-block.sh")"

# box <name> <global.env content> — a scratch harness root with that env file.
box() {
  local r="$T/$1"
  mkdir -p "$r/env" "$r/logs" "$r/locks"
  printf '%s' "$2" > "$r/env/global.env"
  printf '%s\n' "$r"
}
GENV_BASE=$'JOBS_URL=https://jobs.test\nHARNESS_SECRET=fixture-secret\n'
# run_block <root> [checkout] [PATH prefix] — the harness-sync block for that root.
run_block() {
  env -u REGISTRY_SOURCE -u JOBS_URL -u HARNESS_SECRET PATH="${3:-$T/bin}:$PATH" \
    CHECKOUT="${2:-$DIR}" HENV="$1/env" HARNESS="$1" bash -c '. "$1"' _ "$T/seed-block.sh"
}
lines()  { grep -c '^REGISTRY_SOURCE=' "$1/env/global.env" 2>/dev/null || true; }
value()  { grep '^REGISTRY_SOURCE=' "$1/env/global.env" 2>/dev/null | tr '\n' ' '; }
alerts() { cat "$1/logs/ALERTS.log" 2>/dev/null | grep -c . ; }
waits()  { cat "$1/logs/update-runners.log" 2>/dev/null | grep -c 'NOT seeded'; }

# ---- F1 ----------------------------------------------------------------------
R1=$(box f1 "$GENV_BASE")
run_block "$R1"; R=$?
[ "$R" = 0 ] && [ "$(lines "$R1")" = 1 ] && [ "$(value "$R1")" = "REGISTRY_SOURCE=db " ] && ok || bad "F1 rc $R lines $(lines "$R1") '$(value "$R1")'"
[ "$(alerts "$R1")" = 0 ] && ok || bad "F1 wrote $(alerts "$R1") ALERTS lines"
grep -q 'REGISTRY_SOURCE=db seeded' "$R1/logs/update-runners.log" && ok || bad "F1 no update-runners.log line"
[ ! -e "$R1/state/registry" ] && ok || bad "F1 the probe left a registry cache in the box root"
run_block "$R1"
[ "$(lines "$R1")" = 1 ] && ok || bad "F1 a second sync appended a second line"

# ---- F2 ----------------------------------------------------------------------
R2=$(box f2 "$GENV_BASE# REGISTRY_SOURCE=file"$'\n')
run_block "$R2"
[ "$(lines "$R2")" = 1 ] && [ "$(value "$R2")" = "REGISTRY_SOURCE=db " ] && [ "$(alerts "$R2")" = 0 ] && ok || bad "F2 a commented line blocked the flip: lines $(lines "$R2")"

# ---- N1 / N2 / N6 ------------------------------------------------------------
for C in "file:REGISTRY_SOURCE=file" "db:REGISTRY_SOURCE=db" "DB:REGISTRY_SOURCE=DB" "empty:REGISTRY_SOURCE="; do
  N="${C%%:*}"; L="${C#*:}"
  RN=$(box "n-$N" "$GENV_BASE$L"$'\n')
  C0=$(rfx_calls)
  run_block "$RN"; R=$?
  [ "$R" = 0 ] && [ "$(lines "$RN")" = 1 ] && [ "$(value "$RN")" = "$L " ] && [ "$(alerts "$RN")" = 0 ] && ok || bad "N $N: rc $R '$(value "$RN")'"
  [ "$(rfx_calls)" = "$C0" ] && ok || bad "N $N: an operator line still asked the registry"
done

# ---- N3 ----------------------------------------------------------------------
R3=$(box n3 "$GENV_BASE")
rfx_down 1
run_block "$R3"; R=$?; run_block "$R3"
rfx_down 0
[ "$R" = 0 ] && [ "$(lines "$R3")" = 0 ] && [ "$(alerts "$R3")" = 0 ] && ok || bad "N3 unreachable: rc $R lines $(lines "$R3") alerts $(alerts "$R3")"
[ "$(waits "$R3")" = 1 ] && ok || bad "N3 $(waits "$R3") wait lines after two syncs on one day, want 1"
[ ! -e "$R3/state/registry" ] && ok || bad "N3 the probe left a registry cache in the box root"

# ---- N4 ----------------------------------------------------------------------
mkdir -p "$T/co4"; cp "$DIR/fleet.conf" "$T/co4/fleet.conf"; ln -s "$DIR/bin" "$T/co4/bin"
echo 'extra-os Fixture/extra - - 4 box-small' >> "$T/co4/fleet.conf"
R4=$(box n4 "$GENV_BASE")
run_block "$R4" "$T/co4"; R=$?
[ "$R" = 0 ] && [ "$(lines "$R4")" = 0 ] && [ "$(alerts "$R4")" = 0 ] && [ "$(waits "$R4")" = 1 ] && ok || bad "N4 a missing project: rc $R lines $(lines "$R4") waits $(waits "$R4")"
grep -q "not the checkout fleet.conf's" "$R4/logs/update-runners.log" && ok || bad "N4 the wait line does not name the set mismatch"

# ---- N5 ----------------------------------------------------------------------
mkdir -p "$T/bin5"
cat > "$T/bin5/curl" <<'SH'
#!/bin/bash
fmt=""; prev=""
for a in "$@"; do [ "$prev" = -w ] && fmt="$a"; prev="$a"; done
printf '{}'; printf '%s' "${fmt//%\{http_code\}/200}"
SH
chmod +x "$T/bin5/curl"
R5=$(box n5 "$GENV_BASE")
run_block "$R5" "$DIR" "$T/bin5"; R=$?
[ "$R" = 0 ] && [ "$(lines "$R5")" = 0 ] && [ "$(alerts "$R5")" = 0 ] && ok || bad "N5 {}: rc $R lines $(lines "$R5") alerts $(alerts "$R5")"

# ---- N7 ----------------------------------------------------------------------
mkdir -p "$T/n7/logs"
run_block "$T/n7"; R=$?
[ "$R" = 0 ] && [ ! -e "$T/n7/env/global.env" ] && ok || bad "N7 no global.env: rc $R"

# ---- A1 ----------------------------------------------------------------------
RA=$(box a1 "$GENV_BASE"); rmdir "$RA/locks"   # the harden-state lock cannot open: the append fails
( . "$LIB" && env -u REGISTRY_SOURCE PATH="$T/bin:$PATH" bash -c '. "$1"; registry_source_seed "$2" "$3/env/global.env" "$3"' _ "$LIB" "$DIR" "$RA" ); R=$?
[ "$R" = 1 ] && [ "$(lines "$RA")" = 0 ] && ok || bad "A1 a failed append: rc $R lines $(lines "$RA")"
[ "$(alerts "$RA")" = 1 ] && grep -q 'could not append REGISTRY_SOURCE=db' "$RA/logs/ALERTS.log" && ok || bad "A1 $(alerts "$RA") ALERTS lines, want 1"
run_block "$RA"; R=$?
[ "$R" = 0 ] && ok || bad "A1 the harness-sync block failed the deploy: rc $R"

# ---- D1 ----------------------------------------------------------------------
mkdir -p "$T/d1/state/registry"
printf 'onlyfile-os Fixture/only - - 1\n' > "$T/d1/fleet.conf"
printf 'onlyreg-os Fixture/reg - - 2\n' > "$T/d1/state/registry/fleet.conf"
echo '{}' > "$T/d1/state/registry/registry.json"
OUT=$(env -u REGISTRY_SOURCE HARNESS="$T/d1" FLEET_CONF="$T/d1/fleet.conf" "$DIR/bin/fleet-conf.sh" --projects)
[ "$OUT" = onlyfile-os ] && ok || bad "D1 unset REGISTRY_SOURCE read '$OUT', want the file's onlyfile-os"

echo "registry-source-seed: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
