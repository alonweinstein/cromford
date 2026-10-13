#!/bin/bash
# tests/registry-export.bh-5651-test.sh — BH-5651 (the ticket's
# tests/registry-export-test.sh): bin/registry-export.sh renders fleet.conf and
# the cost-accounts box maps FROM the D1 registry, snapshots it nightly, and
# bin/registry-seed.sh restores from a snapshot and refuses to re-seed a
# seeded registry from the files. The registry API is the REAL harness-jobs
# worker over SQLite (tests/lib/registry-fixture.bh-5650.sh), seeded from this
# tree's files.
#
#   E1 # contract-test (E1 only): the export of the seeded registry with this
#      tree's fleet.conf as template is byte-for-byte this tree's fleet.conf;
#      the cost-accounts export is byte-for-byte catalog/cost-accounts.json
#   E2 move-project cromford: only the cromford row differs (2 diff lines)
#   E3 add-project: the new row is appended last
#   E4 retire a project: its row is dropped, its `# @retired` line appears
#   E5 `{}`, version 0, only-retired: rc 1 and no stdout; the row rules on a
#      hand template (odd spacing, a 5-token row, a changed offset, a PARKED
#      comment with project tokens)
#   E6 --snapshot: latest/{registry.json,import.json,fleet.conf,
#      cost-accounts.json}; .version = GET /api/registry/version; --keep 2
#      after 3 runs leaves 2; REGISTRY_EXPORT_KEEP=0 and =x keep 14; a fetch
#      failure is rc 1, latest kept, .fail-count 1; 0 alert lines after 2
#      failures, 1 after the third; success resets the count; the lane flag
#      stops it; the rendered hub crontab runs it once at 41 3 * * *
#   E7 restore round-trip: --from-export into a NEW empty registry, then the
#      export equals the snapshot's fleet.conf; lane_boxes and box_accounts equal
#   E8 seed guard: v>=1 without --force is rc 1 with no POST; --force posts;
#      v0 proceeds (E7); 503 schema-not-applied proceeds; transport down rc 1
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
. "$DIR/tests/lib/registry-fixture.bh-5650.sh" || exit 1
. "$DIR/tests/lib/rendered.sh" || exit 1
EXP="$DIR/bin/registry-export.sh"
SEED="$DIR/bin/registry-seed.sh"
CLI="$DIR/bin/registry.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

rfx_setup; R=$?
[ "$R" -ne 3 ] || { echo "SKIP: node:sqlite is not available"; exit 0; }
[ "$R" -eq 0 ] || { echo "FAIL: the fixture registry could not be seeded"; exit 1; }

ex() { REGISTRY_CACHE_TTL_S=0 rfx_db "$EXP" "$@"; }
import() { # import <payload-file> — a raw POST /api/registry/import to the fixture
  "$T/bin/curl" -sS -w $'\n%{http_code}' -X POST -H "@$T/seed.headers" --data-binary "@$1" https://jobs.test/api/registry/import > "$T/import.out"
  [ "$(tail -1 "$T/import.out")" = 200 ] || bad "import of $1: $(cat "$T/import.out")"
}
TPL="$DIR/fleet.conf"
CTPL="$DIR/catalog/cost-accounts.json"

# ---- E1 ----------------------------------------------------------------------
ex --fleet-conf --template "$TPL" > "$T/e1.conf" 2>"$T/e1.err"; R=$?
[ "$R" = 0 ] && ok || bad "E1 rc $R: $(cat "$T/e1.err")"
cmp -s "$T/e1.conf" "$TPL" && ok || bad "E1 the export is not byte-for-byte fleet.conf: $(diff "$TPL" "$T/e1.conf" | head -5)"
ex --cost-accounts --template "$CTPL" > "$T/e1.json" 2>"$T/e1.err"; R=$?
[ "$R" = 0 ] && cmp -s "$T/e1.json" "$CTPL" && ok || bad "E1 cost-accounts rc $R differs: $(diff "$CTPL" "$T/e1.json" | head -5)"
# No template: _rg_render's lines minus its GENERATED header.
ex --fleet-conf > "$T/e1.bare" 2>/dev/null
RJ="$RFX_H/state/registry/registry.json"
( . "$DIR/bin/lib/registry.sh" && _rg_render "$RJ" ) | tail -n +2 > "$T/e1.rg"
[ -s "$T/e1.bare" ] && cmp -s "$T/e1.bare" "$T/e1.rg" && ok || bad "E1 the template-less export is not _rg_render minus its header"

# ---- E2 ----------------------------------------------------------------------
rfx_db "$CLI" move-project cromford --box box-project-6-1 >/dev/null 2>"$T/e2.err" || bad "E2 move-project: $(cat "$T/e2.err")"
ex --fleet-conf --template "$TPL" > "$T/e2.conf" 2>/dev/null
N=$(diff "$TPL" "$T/e2.conf" | grep -c '^[<>]')
[ "$N" = 2 ] && ok || bad "E2 $N changed lines, want 2: $(diff "$TPL" "$T/e2.conf")"
WANT=$(awk '$1 == "cromford" {c = $1 " " $2 " " $3 " " $4 " " $5} $6 == "box-project-6-1" && $7 != "" {ip = $7}
  END {print c " box-project-6-1 " ip}' "$TPL")
grep -qxF "$WANT" "$T/e2.conf" && ok || bad "E2 the cromford row is not the registry's: $(grep '^cromford' "$T/e2.conf")"
[ "$(awk '$1 == "cromford" {print $6}' "$T/e2.conf")" = box-project-6-1 ] && ok || bad "E2 a direct awk reader sees the old box"

# ---- E3 ----------------------------------------------------------------------
rfx_db "$CLI" add-project parity-fixture --repo Fixture/parity --prod - --offset 2 --box box-small >/dev/null 2>"$T/e3.err" \
  || bad "E3 add-project: $(cat "$T/e3.err")"
ex --fleet-conf --template "$TPL" > "$T/e3.conf" 2>/dev/null
[ "$(tail -1 "$T/e3.conf" | awk '{print $1}')" = parity-fixture ] && ok || bad "E3 the new project is not appended last: $(tail -1 "$T/e3.conf")"
[ "$(diff "$T/e2.conf" "$T/e3.conf" | grep -c '^[<>]')" = 1 ] && ok || bad "E3 adding a project changed more than one line"

# ---- E4 ----------------------------------------------------------------------
jq '{actor: "e4-fixture", projects: [.projects[] | select(.project == "project-5") | .status = "retired"],
     boxes: [.boxes[] | select(.box == "box-project-5-1")], lane_boxes: [], box_accounts: []}' "$T/seed.json" > "$T/e4.json"
import "$T/e4.json"
ex --fleet-conf --template "$TPL" > "$T/e4.conf" 2>/dev/null
grep -q '^project-5 ' "$T/e4.conf" && bad "E4 the retired project's row is still there" || ok
grep -qx '# @retired project-5 box-project-5-1' "$T/e4.conf" && ok || bad "E4 no @retired directive for project-5"
grep -qx '# @retired project-10       box-project-10-1' "$T/e4.conf" && ok || bad "E4 an unchanged @retired line lost its spacing"
grep -qx '# @standby box-small box-hub hub' "$T/e4.conf" && ok || bad "E4 the @standby directive is gone"

# ---- E5 ----------------------------------------------------------------------
echo '{}' > "$T/empty.json"
jq '.version = 0' "$RJ" > "$T/v0.json"
jq '.projects |= map(.status = "retired")' "$RJ" > "$T/retired.json"
for F in empty v0 retired; do
  OUT=$("$EXP" --fleet-conf --template "$TPL" --registry "$T/$F.json" 2>/dev/null); R=$?
  [ "$R" = 1 ] && [ -z "$OUT" ] && ok || bad "E5 $F: rc $R, stdout ${#OUT} bytes"
done
# The row rules on a hand template and a hand registry.
cat > "$T/hand.conf" <<'EOF'
# header comment
alpha-os   Acme/alpha-os  https://alpha.example  /api/board  2  box-alpha  192.0.2.10
legacy-os Acme/legacy - - 7
beta-os Acme/beta - - 3 box-alpha 192.0.2.10
# PARKED: gone-os Acme/gone - - 0 box-alpha
gamma-os Acme/gamma - - 4 box-alpha 192.0.2.10
delta-os Acme/delta - - 5 box-alpha 192.0.2.10
EOF
cat > "$T/hand.json" <<'EOF'
{"version": 3, "lane_boxes": [], "box_accounts": [],
 "boxes": [{"box": "box-alpha", "tailnet_ip": "192.0.2.10"}, {"box": "box-beta", "tailnet_ip": "192.0.2.20"},
           {"box": "box-zeta", "tailnet_ip": "192.0.2.30"}],
 "projects": [
  {"project": "alpha-os", "repo": "Acme/alpha-os", "prod": "https://alpha.example", "board_prefix": "/api/board", "cron_offset": 2, "box": "box-alpha", "position": 0, "status": "active"},
  {"project": "legacy-os", "repo": "Acme/legacy", "prod": "-", "board_prefix": "-", "cron_offset": 7, "box": null, "position": 1, "status": "active"},
  {"project": "beta-os", "repo": "Acme/beta", "prod": "-", "board_prefix": "-", "cron_offset": 6, "box": "box-alpha", "position": 2, "status": "active"},
  {"project": "gamma-os", "repo": "Acme/gamma", "prod": "-", "board_prefix": "-", "cron_offset": 4, "box": "box-beta", "position": 3, "status": "active"},
  {"project": "eps-os", "repo": "Acme/eps", "prod": "-", "board_prefix": "-", "cron_offset": 1, "box": null, "position": 5, "status": "active"}]}
EOF
cat > "$T/hand.want" <<'EOF'
# header comment
alpha-os   Acme/alpha-os  https://alpha.example  /api/board  2  box-alpha  192.0.2.10
legacy-os Acme/legacy - - 7
beta-os Acme/beta - - 6 box-alpha 192.0.2.10
# PARKED: gone-os Acme/gone - - 0 box-alpha
gamma-os Acme/gamma - - 4 box-beta 192.0.2.20
# @box box-zeta 192.0.2.30
eps-os Acme/eps - - 1
EOF
"$EXP" --fleet-conf --template "$T/hand.conf" --registry "$T/hand.json" > "$T/hand.out" 2>"$T/hand.err"; R=$?
[ "$R" = 0 ] && cmp -s "$T/hand.out" "$T/hand.want" && ok || bad "E5 the row rules (verbatim odd spacing, 5-token row, changed offset, changed box, dropped, an unnamed @box and a new row appended): rc $R $(diff "$T/hand.want" "$T/hand.out")"

# ---- E6 ----------------------------------------------------------------------
SD="$T/exp"
snap() { REGISTRY_CACHE_TTL_S=0 rfx_db env REGISTRY_EXPORT_NOW="$1" "$EXP" --snapshot "$SD" --checkout "$DIR" "${@:2}" 2>"$T/snap.err"; }
snap_alerts() { grep -c 'registry-export:' "$RFX_H/logs/ALERTS.log" 2>/dev/null || true; }
snap 1760000000; R=$?
[ "$R" = 0 ] && ok || bad "E6 first snapshot rc $R: $(cat "$T/snap.err") $(tail -2 "$RFX_H/logs/registry-export.log" 2>/dev/null)"
for F in registry.json import.json fleet.conf cost-accounts.json; do
  [ -s "$SD/latest/$F" ] && ok || bad "E6 latest/$F missing or empty"
done
[ "$(readlink "$SD/latest")" = 20251009T085320Z ] && ok || bad "E6 latest -> $(readlink "$SD/latest")"
"$T/bin/curl" -sS -H "@$T/seed.headers" https://jobs.test/api/registry/version > "$T/ver.json"
[ "$(jq .version "$SD/latest/registry.json")" = "$(jq .version "$T/ver.json")" ] && ok || bad "E6 latest/registry.json .version is not GET /api/registry/version"
[ "$(jq -r .actor "$SD/latest/import.json")" = registry-restore ] && [ "$(jq '.projects | length' "$SD/latest/import.json")" = "$(jq '.projects | length' "$RJ")" ] \
  && ok || bad "E6 import.json is not the import payload"
jq -S .lane_boxes "$SD/latest/registry.json" > "$T/lb.a"; jq -S .lane_boxes "$T/seed.json" > "$T/lb.b"
[ -s "$T/lb.a" ] && cmp -s "$T/lb.a" "$T/lb.b" && ok || bad "E6 the snapshot's lane_boxes are not the registry's"
ex --fleet-conf --template "$TPL" > "$T/e6.conf" 2>/dev/null
cmp -s "$SD/latest/fleet.conf" "$T/e6.conf" && ok || bad "E6 the snapshot fleet.conf is not the export"
snap 1760000100 --keep 2; snap 1760000200 --keep 2
[ "$(ls -1 "$SD" | grep -cE '^[0-9]{8}T[0-9]{6}Z$')" = 2 ] && ok || bad "E6 --keep 2 after 3 runs left $(ls -1 "$SD" | grep -cE '^[0-9]{8}T')"
[ -e "$SD/20251009T085320Z" ] && bad "E6 the oldest snapshot survived --keep 2" || ok
for i in $(seq 10 25); do mkdir -p "$SD/202001${i}T000000Z"; done
REGISTRY_EXPORT_KEEP=0 snap 1760000300
[ "$(ls -1 "$SD" | grep -cE '^[0-9]{8}T[0-9]{6}Z$')" = 14 ] && ok || bad "E6 REGISTRY_EXPORT_KEEP=0 kept $(ls -1 "$SD" | grep -cE '^[0-9]{8}T'), want 14"
mkdir -p "$SD/20200101T000000Z"
REGISTRY_EXPORT_KEEP=x snap 1760000400
[ "$(ls -1 "$SD" | grep -cE '^[0-9]{8}T[0-9]{6}Z$')" = 14 ] && ok || bad "E6 REGISTRY_EXPORT_KEEP=x kept $(ls -1 "$SD" | grep -cE '^[0-9]{8}T'), want 14"
LATEST=$(readlink "$SD/latest")
rfx_down 1
snap 1760000500; R=$?
[ "$R" = 1 ] && ok || bad "E6 a fetch failure: rc $R, want 1"
[ "$(readlink "$SD/latest")" = "$LATEST" ] && ok || bad "E6 a failure moved latest"
[ "$(cat "$SD/.fail-count" 2>/dev/null)" = 1 ] && ok || bad "E6 .fail-count '$(cat "$SD/.fail-count" 2>/dev/null)', want 1"
[ -e "$SD/20251009T090140Z" ] && bad "E6 a failed run left a snapshot dir" || ok
grep -q '^\.tmp\.' <<<"$(ls -A "$SD")" && bad "E6 a failed run left a .tmp dir" || ok
snap 1760000600
[ "$(snap_alerts)" = 0 ] && ok || bad "E6 $(snap_alerts) alert lines after 2 failures, want 0"
snap 1760000700
[ "$(snap_alerts)" = 1 ] && ok || bad "E6 $(snap_alerts) alert lines after 3 failures, want 1"
snap 1760000800
[ "$(snap_alerts)" = 1 ] && ok || bad "E6 a 4th failure wrote another alert line"
rfx_down 0
snap 1760000900; R=$?
[ "$R" = 0 ] && [ ! -e "$SD/.fail-count" ] && ok || bad "E6 success did not reset .fail-count (rc $R)"
mkdir -p "$RFX_H/flags"; : > "$RFX_H/flags/lane-off-registry-export"
C0=$(rfx_calls); L0=$(readlink "$SD/latest")
snap 1760001000; R=$?
[ "$R" = 0 ] && [ "$(rfx_calls)" = "$C0" ] && [ "$(readlink "$SD/latest")" = "$L0" ] && ok || bad "E6 the lane flag did not stop the snapshot (rc $R)"
rm -f "$RFX_H/flags/lane-off-registry-export"
HUB=$(rendered_cron hub)
[ "$(grep -c 'registry-export.sh --snapshot' "$HUB")" = 1 ] && ok || bad "E6 the hub crontab runs registry-export $(grep -c 'registry-export.sh' "$HUB") times"
grep -q '^41 3 \* \* \* /root/harness/bin/registry-export.sh --snapshot /root/harness/state/registry/export ' "$HUB" && ok || bad "E6 the hub line is not 41 3 * * *"
[ "$(grep -l 'registry-export.sh' "$(dirname "$HUB")"/*.cron 2>/dev/null | wc -l)" -le 1 ] && ok || bad "E6 a box other than the hub runs registry-export"

# ---- E7 ----------------------------------------------------------------------
mkdir -p "$T/bin2" "$T/h2"
sed "s#$T/registry.db#$T/registry2.db#; s#$T/curl.log#$T/curl2.log#" "$T/bin/curl" > "$T/bin2/curl"; chmod +x "$T/bin2/curl"
db2() { env PATH="$T/bin2:$PATH" HARNESS="$T/h2" JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret \
  REGISTRY_ADMIN_TOKEN=fixture-admin-token REGISTRY_SOURCE=db REGISTRY_CACHE_TTL_S=0 "$@"; }
OUT=$(db2 "$SEED" --from-export "$SD" 2>&1); R=$?
[ "$R" = 0 ] && [[ "$OUT" == "registry-seed: changed="*" version=1 stale=0" ]] && ok || bad "E7 restore into an empty registry: rc $R '$OUT'"
db2 "$EXP" --fleet-conf --template "$TPL" > "$T/e7.conf" 2>/dev/null
cmp -s "$T/e7.conf" "$SD/latest/fleet.conf" && ok || bad "E7 the restored export differs from the snapshot: $(diff "$SD/latest/fleet.conf" "$T/e7.conf" | head -5)"
for K in lane_boxes box_accounts boxes; do
  [ "$(jq -S ".$K" "$T/h2/state/registry/registry.json")" = "$(jq -S ".$K" "$SD/latest/registry.json")" ] && ok || bad "E7 the restored .$K differ"
done
OUT=$(db2 "$SEED" --from-export "$T/nowhere" 2>&1); R=$?
[ "$R" = 2 ] && ok || bad "E7 a missing snapshot: rc $R '$OUT'"

# ---- E8 ----------------------------------------------------------------------
posts() { grep -c -- '-X POST' "$T/curl.log" 2>/dev/null || true; }
: > "$T/curl.log"
OUT=$(rfx_db "$SEED" 2>&1); R=$?
[ "$R" = 1 ] && [[ "$OUT" == *"already seeded (v"*"--force to overwrite from the files."* ]] && ok || bad "E8 v>=1 without --force: rc $R '$OUT'"
[ "$(posts)" = 0 ] && ok || bad "E8 the refused seed still POSTed"
grep -q 'api/registry/version' "$T/curl.log" && ok || bad "E8 the guard did not ask /api/registry/version"
OUT=$(rfx_db "$SEED" --from-export "$SD" 2>&1); R=$?
[ "$R" = 1 ] && [ "$(posts)" = 0 ] && ok || bad "E8 --from-export into a seeded registry without --force: rc $R posts $(posts)"
OUT=$(rfx_db "$SEED" --force 2>&1); R=$?
[ "$R" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "E8 --force: rc $R posts $(posts) '$OUT'"
rfx_down 1
OUT=$(rfx_db "$SEED" 2>&1); R=$?
[ "$R" = 1 ] && [[ "$OUT" == *"not proven empty"* ]] && ok || bad "E8 transport down: rc $R '$OUT'"
rfx_down 0
# 503 schema-not-applied proceeds; any other 503 refuses. A stub answers.
mkdir -p "$T/bin3"
cat > "$T/bin3/curl" <<SH
#!/bin/bash
echo "\$*" >> "$T/curl3.log"
case "\$*" in
  *registry/version*) cat "$T/v.body"; printf '\n503' ;;
  *) printf '{"ok":true,"changed":3,"version":1,"stale":[]}\n200' ;;
esac
SH
chmod +x "$T/bin3/curl"
s3() { env PATH="$T/bin3:$PATH" HARNESS="$T/h3" JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret REGISTRY_ADMIN_TOKEN=fixture-admin-token "$SEED" 2>&1; }
printf '{"error":"registry schema not applied","detail":"no such table"}' > "$T/v.body"
OUT=$(s3); R=$?
[ "$R" = 0 ] && grep -q 'registry/import' "$T/curl3.log" && ok || bad "E8 503 schema-not-applied: rc $R '$OUT'"
: > "$T/curl3.log"
printf '{"error":"registry unavailable"}' > "$T/v.body"
OUT=$(s3); R=$?
[ "$R" = 1 ] && ! grep -q 'registry/import' "$T/curl3.log" && ok || bad "E8 503 unavailable: rc $R '$OUT'"

echo "registry-export: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
