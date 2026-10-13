#!/bin/bash
# tests/registry-install.bh-5651-test.sh — BH-5651: on a box in
# REGISTRY_SOURCE=db the live $H/fleet.conf and the box maps of
# $H/catalog/cost-accounts.json are the registry export, never the committed
# copies. Drives bin/registry-export.sh --install, the fleet.conf line of
# bin/harness-sync.sh (extracted and run as written) and a bin/registry-sync.sh
# tick. The registry API is the REAL harness-jobs worker over SQLite
# (tests/lib/registry-fixture.bh-5650.sh), seeded from this tree's files.
#
#   I1 db mode, the registry moved cromford: $H/fleet.conf is the export, a
#      direct awk reader sees the new box, and "box switched" holds (one
#      REGISTRY_SOURCE=db line, $H/fleet.conf cmp-equal to --fleet-conf)
#   I2 file mode: --install rc 1, writes nothing; the harness-sync line then
#      copies the committed fleet.conf (cmp); in db mode the same line installs
#      the export
#   I3 an unchanged registry: a second --install keeps the inode and mtime
#   I4 cost-accounts: a registry cost_rows box reaches
#      .accounts[$a].boxes.cost_rows (the cost-reconcile path); an unchanged
#      registry is cmp-identical to the committed file
#   I5 refused renders (a registry with no active project, no usable registry):
#      rc 1, both files untouched, one registry.log line
#   I6 a registry-sync tick at the applied version repairs a stale
#      $H/fleet.conf, never calls crontab(1), and a second tick keeps the mtime
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
. "$DIR/tests/lib/registry-fixture.bh-5650.sh" || exit 1
EXP="$DIR/bin/registry-export.sh"
CLI="$DIR/bin/registry.sh"
SYNC="$DIR/bin/registry-sync.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

rfx_setup; R=$?
[ "$R" -ne 3 ] || { echo "SKIP: node:sqlite is not available"; exit 0; }
[ "$R" -eq 0 ] || { echo "FAIL: the fixture registry could not be seeded"; exit 1; }

H="$RFX_H"
mkdir -p "$T/env" "$H/catalog" "$H/logs"
printf 'REGISTRY_SOURCE=db\n' > "$T/env/global.env"
# install [VAR=value...] — --install of the fixture harness, env from $T/env.
install() { env -u REGISTRY_SOURCE PATH="$T/bin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$T/env" JOBS_URL=https://jobs.test \
  HARNESS_SECRET=fixture-secret REGISTRY_CACHE_TTL_S=0 "$@" "$EXP" --install "$H" --checkout "$DIR" 2>"$T/install.err"; }
export_conf() { REGISTRY_CACHE_TTL_S=0 rfx_db "$EXP" --fleet-conf --template "$DIR/fleet.conf" 2>/dev/null; }
# The fleet.conf line of bin/harness-sync.sh, run exactly as written.
sed -n '/^"\$CHECKOUT\/bin\/registry-export.sh" --install/,/fleet.conf"; }; }$/p' "$DIR/bin/harness-sync.sh" > "$T/sync-line.sh"
[ "$(wc -l < "$T/sync-line.sh")" = 2 ] && ok || bad "could not extract the harness-sync fleet.conf line: $(cat "$T/sync-line.sh")"
sync_line() { env -u REGISTRY_SOURCE PATH="$T/bin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$T/env" JOBS_URL=https://jobs.test \
  HARNESS_SECRET=fixture-secret REGISTRY_CACHE_TTL_S=0 CHECKOUT="$DIR" LOG="$T/sync.log" "$@" \
  bash "$T/sync-line.sh"; }
sig() { stat -c '%i %Y' "$1" 2>/dev/null; }

# ---- I4 (unchanged half first) -----------------------------------------------
install; R=$?
[ "$R" = 0 ] && ok || bad "I4 first install rc $R: $(cat "$T/install.err") $(tail -2 "$H/logs/registry.log" 2>/dev/null)"
cmp -s "$H/catalog/cost-accounts.json" "$DIR/catalog/cost-accounts.json" && ok || bad "I4 an unchanged registry did not give the committed cost-accounts.json"
cmp -s "$H/fleet.conf" "$DIR/fleet.conf" && ok || bad "I4 an unchanged registry did not give the committed fleet.conf"

# ---- I1 ----------------------------------------------------------------------
rfx_db "$CLI" move-project cromford --box box-project-6-1 >/dev/null 2>"$T/mv.err" || bad "I1 move-project: $(cat "$T/mv.err")"
install; R=$?
[ "$R" = 0 ] && ok || bad "I1 rc $R: $(cat "$T/install.err")"
[ "$(awk '$1 == "cromford" {print $6}' "$H/fleet.conf")" = box-project-6-1 ] && ok || bad "I1 a direct awk reader of \$H/fleet.conf sees '$(awk '$1 == "cromford" {print $6}' "$H/fleet.conf")'"
cmp -s "$H/fleet.conf" "$DIR/fleet.conf" && bad "I1 \$H/fleet.conf is still the committed copy" || ok
[ "$(grep -c '^REGISTRY_SOURCE=db' "$T/env/global.env")" = 1 ] && export_conf | cmp -s - "$H/fleet.conf" && ok || bad "I1 box switched: \$H/fleet.conf is not the export"
[ "$(env -u REGISTRY_SOURCE FLEET_CONF="$H/fleet.conf" HARNESS="$H" "$DIR/bin/fleet-conf.sh" cromford box)" = box-project-6-1 ] \
  && ok || bad "I1 fleet-conf.sh in file mode on the export does not see the move"

# ---- I3 ----------------------------------------------------------------------
touch -d '2026-01-01 00:00:00' "$H/fleet.conf" "$H/catalog/cost-accounts.json"
A=$(sig "$H/fleet.conf"); B=$(sig "$H/catalog/cost-accounts.json")
install; R=$?
[ "$R" = 0 ] && [ "$(sig "$H/fleet.conf")" = "$A" ] && [ "$(sig "$H/catalog/cost-accounts.json")" = "$B" ] && ok \
  || bad "I3 an unchanged registry rewrote a file (rc $R): $A -> $(sig "$H/fleet.conf")"

# ---- I4 (changed half) -------------------------------------------------------
# The import route needs one project row: project-1, unchanged, with its box.
jq '{actor: "i4-fixture", projects: [.projects[] | select(.project == "project-1")],
     boxes: [.boxes[] | select(.box == "box-project-1-1")], lane_boxes: [],
     box_accounts: [{account: "project-1", kind: "cost_rows", box: "small"}]}' "$T/seed.json" > "$T/i4.json"
"$T/bin/curl" -sS -w $'\n%{http_code}' -X POST -H "@$T/seed.headers" --data-binary "@$T/i4.json" https://jobs.test/api/registry/import > "$T/i4.out"
[ "$(tail -1 "$T/i4.out")" = 200 ] || bad "I4 import: $(cat "$T/i4.out")"
install; R=$?
[ "$(jq -c --arg a project-1 '.accounts[$a].boxes.cost_rows' "$H/catalog/cost-accounts.json")" = '["project-1","small"]' ] && ok \
  || bad "I4 cost_rows = $(jq -c '.accounts.project-1.boxes.cost_rows' "$H/catalog/cost-accounts.json")"
[ "$(jq -r '.box_aliases["box-small"]' "$H/catalog/cost-accounts.json")" = small ] \
  && [ "$(jq -r '.accounts["project-6-account"].login.box' "$H/catalog/cost-accounts.json")" = hub ] && ok || bad "I4 box_aliases or login.box lost"
[ "$(jq -S 'del(.accounts.project-1.boxes.cost_rows)' "$H/catalog/cost-accounts.json")" = "$(jq -S 'del(.accounts.project-1.boxes.cost_rows)' "$DIR/catalog/cost-accounts.json")" ] \
  && ok || bad "I4 the overlay changed a field the registry did not"

# ---- I5 ----------------------------------------------------------------------
A=$(sig "$H/fleet.conf"); B=$(sig "$H/catalog/cost-accounts.json"); L0=$(grep -c 'REFUSED' "$H/logs/registry.log" 2>/dev/null)
jq '.projects |= map(.status = "retired")' "$H/state/registry/registry.json" > "$T/retired.json"
env -u REGISTRY_SOURCE PATH="$T/bin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$T/env" "$EXP" --install "$H" --checkout "$DIR" --registry "$T/retired.json" 2>/dev/null; R=$?
[ "$R" = 1 ] && [ "$(sig "$H/fleet.conf")" = "$A" ] && [ "$(sig "$H/catalog/cost-accounts.json")" = "$B" ] && ok || bad "I5 a registry with no active project: rc $R, files touched"
[ "$(grep -c 'REFUSED' "$H/logs/registry.log" 2>/dev/null)" = $((L0 + 1)) ] && ok || bad "I5 no REFUSED line in registry.log"
echo '{}' > "$T/empty.json"
env -u REGISTRY_SOURCE PATH="$T/bin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$T/env" "$EXP" --install "$H" --checkout "$DIR" --registry "$T/empty.json" 2>/dev/null; R=$?
[ "$R" = 1 ] && [ "$(sig "$H/fleet.conf")" = "$A" ] && ok || bad "I5 an unusable registry: rc $R, fleet.conf touched"

# ---- I2 ----------------------------------------------------------------------
A=$(sig "$H/fleet.conf")
install REGISTRY_SOURCE=file; R=$?
[ "$R" = 1 ] && [ "$(sig "$H/fleet.conf")" = "$A" ] && ok || bad "I2 file mode: rc $R, fleet.conf touched"
printf 'REGISTRY_SOURCE=file\n' > "$T/env/global.env"
install; R=$?
[ "$R" = 1 ] && [ "$(sig "$H/fleet.conf")" = "$A" ] && ok || bad "I2 REGISTRY_SOURCE=file in global.env: rc $R"
sync_line; R=$?
[ "$R" = 0 ] && cmp -s "$H/fleet.conf" "$DIR/fleet.conf" && ok || bad "I2 the harness-sync line in file mode did not copy the committed fleet.conf (rc $R)"
printf 'REGISTRY_SOURCE=db\n' > "$T/env/global.env"
sync_line; R=$?
[ "$R" = 0 ] && export_conf | cmp -s - "$H/fleet.conf" && ok || bad "I2 the harness-sync line in db mode did not install the export (rc $R)"
rfx_down 1; scratch_rm "$H/state/registry"
sync_line; R=$?
[ "$R" = 0 ] && cmp -s "$H/fleet.conf" "$DIR/fleet.conf" && ok || bad "I2 db mode with no registry and no cache: the line did not fall back to the committed copy"
rfx_down 0

# ---- I6 ----------------------------------------------------------------------
cat > "$T/bin/crontab" <<SH
#!/bin/bash
echo "\$*" >> "$T/crontab.calls"
exit 1
SH
chmod +x "$T/bin/crontab"; : > "$T/crontab.calls"
mkdir -p "$T/co/bin"
echo project-6 > "$H/state/box-id"
tick() { env -u REGISTRY_SOURCE PATH="$T/bin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$T/env" JOBS_URL=https://jobs.test \
  HARNESS_SECRET=fixture-secret REGISTRY_SYNC_CHECKOUT="$T/co" "$SYNC" 2>"$T/tick.err"; }
cp "$DIR/fleet.conf" "$T/co/fleet.conf"; mkdir -p "$T/co/catalog"; cp "$DIR/catalog/cost-accounts.json" "$T/co/catalog/"
V=$(rfx_q 'SELECT version FROM registry_meta' | jq '.[0].version')
printf '%s\n' "$V" > "$H/state/registry/applied-version"
cp "$DIR/fleet.conf" "$H/fleet.conf"   # stale: box-launch.sh / load-project.sh copied a checkout
tick; R=$?
[ "$R" = 0 ] && export_conf | cmp -s - "$H/fleet.conf" && ok || bad "I6 the tick did not repair \$H/fleet.conf (rc $R): $(tail -2 "$H/logs/registry-sync.log")"
[ "$(awk '$1 == "cromford" {print $6}' "$H/fleet.conf")" = box-project-6-1 ] && ok || bad "I6 the repaired file lacks the registry's cromford box"
[ ! -s "$T/crontab.calls" ] && ok || bad "I6 crontab(1) was called at the applied version: $(cat "$T/crontab.calls")"
touch -d '2026-01-01 00:00:00' "$H/fleet.conf"; A=$(sig "$H/fleet.conf")
tick
[ "$(sig "$H/fleet.conf")" = "$A" ] && ok || bad "I6 a second tick rewrote an unchanged fleet.conf"

echo "registry-install: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
