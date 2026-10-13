#!/bin/bash
# tests/switch-migrate-bare-reader.bh-2412-test.sh — bin/switch-migrate.sh never
# writes a row for a switch some script still reads as a bare file (BH-2412).
#
# lane_switch lets a row beat the file, a bare `[ -f flags/<name> ]` reader does
# not see the row: migrating such a switch splits it the moment the operator
# removes the file (the bare reader re-arms, the lane_switch readers stay off).
#   B1 the REAL tree: cost-autohalt-off is not migrated while
#      bin/pipeline-health.sh reads it bare, and is once that reader is gone
#   B2 a scratch tree with one bare reader added -> `bare <name> <file:line>`,
#      no PUT, rc 0; --dry-run says the same
#   B3 a bare read in a comment, or of a longer name, does not hold a switch back
#   B4 the reader removed -> the next run writes the row
#   B5 the REAL tree, every registered switch's file present, --dry-run: no
#      switch is offered for a row while one of its catalog readers does not
#      call `lane_switch <name>` (alert-quarantine-disabled, batch-resolve-off
#      and blocked-resolver-disabled were, through `[ ! -f` and `flag_on`)
#   B6 a catalog reader that reads the switch with `flag_on`, and a registry
#      entry with no readers, hold the switch back
# Run from anywhere: tests/switch-migrate-bare-reader.bh-2412-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

mkdir -p "$T/h/bin" "$T/h/flags" "$T/h/state" "$T/h/logs" "$T/h/catalog/switches.d"
cp "$DIR/catalog/switches.d/cost-autohalt-off.json" "$DIR/catalog/switches.d/dora-digest-off.json" \
  "$T/h/catalog/switches.d/"
# The switch-migrate suite's stub worker: GET returns $ROWS_FILE, a PUT is
# recorded in $PUTS and appended to the rows.
cat > "$T/h/bin/jobs-client.sh" <<'SH'
_jobs_req() {
  JOBS_HTTP=""
  case "$1 $2" in
    "GET /api/settings") JOBS_HTTP=200; printf '{"settings":%s}' "$(cat "$ROWS_FILE")" ;;
    "PUT /api/settings")
      printf '%s\n' "$3" >> "$PUTS"
      jq -c --argjson b "$3" '. + [$b]' "$ROWS_FILE" > "$ROWS_FILE.new" && mv "$ROWS_FILE.new" "$ROWS_FILE"
      JOBS_HTTP=200; printf '{"setting":%s}' "$3" ;;
    *) return 1 ;;
  esac
}
SH
reset() { printf '[]' > "$T/rows.json"; : > "$T/puts"; }
# mig <switch-migrate> [args] — rc in $RC, output in $T/out.
mig() {
  local s="$1"; shift
  env HARNESS="$T/h" JOBS_BOX=hub-1 ROWS_FILE="$T/rows.json" PUTS="$T/puts" "$s" "$@" > "$T/out" 2>&1
  RC=$?
}
puts() { grep -c . "$T/puts" | tr -d ' '; }
key_put() { grep -c "\"key\":\"switch.$1.hub-1\"" "$T/puts" | tr -d ' '; }

# B1 — the real tree, with both registered switches' files on this box.
touch "$T/h/flags/cost-autohalt-off" "$T/h/flags/dora-digest-off"
reset; mig "$DIR/bin/switch-migrate.sh"
eq "B1 rc" "$RC" "0"
BARE=$(grep -rnE '\[ -[ef] [^]]*flags/cost-autohalt-off([^a-z0-9_-]|$)' "$DIR/bin" "$DIR/fly" 2>/dev/null \
  | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' | head -1)
if [ -n "$BARE" ]; then
  eq "B1 cost-autohalt-off not migrated while it is read bare ($BARE)" "$(key_put cost-autohalt-off)" "0"
  grep -qE '^bare cost-autohalt-off bin/[^ ]+:[0-9]+$' "$T/out" && ok \
    || bad "B1 must print the bare line naming the reader: '$(cat "$T/out")'"
else
  eq "B1 cost-autohalt-off migrates once no bare reader is left" "$(key_put cost-autohalt-off)" "1"
fi
# dora-digest-off's only reader is lane_switch: it migrates in the same run.
eq "B1 dora-digest-off migrated" "$(key_put dora-digest-off)" "1"

# B2 — a scratch tree: the real bin/ with one bare reader of dora-digest-off added.
mkdir -p "$T/r"; cp -r "$DIR/bin" "$T/r/"
# shellcheck disable=SC2016
printf '#!/bin/bash\n[ -f "$H/flags/dora-digest-off" ] && exit 0\n' > "$T/r/bin/old-digest.sh"
SM="$T/r/bin/switch-migrate.sh"
reset; mig "$SM"
eq "B2 rc" "$RC" "0"
eq "B2 no row for a switch read bare" "$(key_put dora-digest-off)" "0"
grep -qxF 'bare dora-digest-off bin/old-digest.sh:2' "$T/out" && ok || bad "B2 bare line: '$(cat "$T/out")'"
reset; mig "$SM" --dry-run
grep -qxF 'bare dora-digest-off bin/old-digest.sh:2' "$T/out" && ok || bad "B2 --dry-run bare line: '$(cat "$T/out")'"
grep -q 'would-write dora-digest-off' "$T/out" && bad "B2 --dry-run must not offer to write it" || ok
[ -f "$T/h/flags/dora-digest-off" ] && ok || bad "B2 the file must be left in place"

# B3 — a comment, and a longer name, are not bare reads of this switch.
# shellcheck disable=SC2016
printf '#!/bin/bash\n  # was: [ -f "$H/flags/dora-digest-off" ]\n[ -f "$H/flags/dora-digest-off-x" ] && exit 0\n' > "$T/r/bin/old-digest.sh"
reset; mig "$SM"
eq "B3 rc" "$RC" "0"
eq "B3 a comment or a longer name holds nothing back" "$(key_put dora-digest-off)" "1"

# B4 — the reader converted: the next run writes the row.
# shellcheck disable=SC2016
printf '#!/bin/bash\n[ -f "$H/flags/dora-digest-off" ] && exit 0\n' > "$T/r/bin/old-digest.sh"
reset; mig "$SM"; eq "B4 held back while read bare" "$(key_put dora-digest-off)" "0"
rm -f "$T/r/bin/old-digest.sh"
mig "$SM"
eq "B4 rc" "$RC" "0"
eq "B4 written once the reader is gone" "$(key_put dora-digest-off)" "1"
grep -qxF 'wrote dora-digest-off switch.dora-digest-off.hub-1' "$T/out" && ok || bad "B4 wrote line: '$(cat "$T/out")'"

# B5 — the real tree against the whole registry.
mkdir -p "$T/h5/bin" "$T/h5/flags" "$T/h5/catalog/switches.d"
# The STUB client written above, not the real one (so no modules to carry);
# copied by content so the fixture rule in jobs-client-modules.bh-1194 does not
# mistake it for a copy of bin/jobs-client.sh.
cat "$T/h/bin/jobs-client.sh" > "$T/h5/bin/jobs-client.sh"
cp "$DIR"/catalog/switches.d/*.json "$T/h5/catalog/switches.d/"
for f in "$T"/h5/catalog/switches.d/*.json; do touch "$T/h5/flags/$(basename "$f" .json)"; done
printf '[]' > "$T/rows.json"; : > "$T/puts"
env HARNESS="$T/h5" JOBS_BOX=hub-1 ROWS_FILE="$T/rows.json" PUTS="$T/puts" \
  "$DIR/bin/switch-migrate.sh" --dry-run > "$T/out" 2>&1
eq "B5 rc" "$?" "0"
eq "B5 --dry-run writes nothing" "$(puts)" "0"
# Which switches are still read bare drifts as the C1-C5 children convert their
# readers, so B5 derives it from the tree instead of naming switches: every
# `bare` line names a reader that really is unconverted, and no switch offered a
# row still has a bare `[ -f .../flags/<name> ]` code line in bin/ or fly/.
while read -r _ n loc; do
  f="${loc%%:*}"
  if [ "$f" != "$loc" ]; then
    grep -E "flags/$n([^a-z0-9_-]|\$)" "$DIR/$f" >/dev/null && ok || bad "B5 bare $n names $loc, which does not read flags/$n"
  elif grep -E "lane_switch[[:space:]]+['\"]?$n(['\"]|[^a-z0-9_-]|\$)" "$DIR/$f" 2>/dev/null | grep -vE '^[[:space:]]*#' >/dev/null; then
    bad "B5 bare $n names $f, which does call lane_switch $n"
  else ok; fi
done < <(grep '^bare ' "$T/out")
while read -r _ n _; do
  if grep -rnE "\[ -[ef] [^]]*flags/$n([^a-z0-9_-]|\$)" "$DIR/bin" "$DIR/fly" 2>/dev/null \
       | awk -F: '$3 !~ /^[[:space:]]*#/ { f = 1 } END { exit !f }'; then
    bad "B5 $n must not be offered while bin/ or fly/ still reads flags/$n bare"
  else ok; fi
done < <(grep '^would-write ' "$T/out")
# Every switch offered a row has lane_switch in every reader the catalog lists.
while read -r _ n _; do
  while IFS= read -r r; do
    grep -E "lane_switch[[:space:]]+['\"]?$n(['\"]|[^a-z0-9_-]|\$)" "$DIR/$r" 2>/dev/null \
      | grep -vE '^[[:space:]]*#' >/dev/null && ok || bad "B5 $n offered a row, but $r never calls lane_switch $n"
  done < <(jq -r '.readers[]' "$DIR/catalog/switches.d/$n.json")
done < <(grep '^would-write ' "$T/out")
grep -q '^would-write dora-digest-off ' "$T/out" && ok || bad "B5 dora-digest-off (lane_switch only) is offered: '$(cat "$T/out")'"

# B6 — a registered reader using flag_on, then a registry entry with no readers.
# shellcheck disable=SC2016
printf '#!/bin/bash
flag_on dora-digest-off && exit 0
' > "$T/r/bin/old-digest.sh"
cp "$T/h/catalog/switches.d/dora-digest-off.json" "$T/dora.json"
jq -c '.readers += ["bin/old-digest.sh"]' "$T/dora.json" > "$T/h/catalog/switches.d/dora-digest-off.json"
reset; mig "$SM"
eq "B6 rc" "$RC" "0"
eq "B6 no row while a catalog reader uses flag_on" "$(key_put dora-digest-off)" "0"
grep -qxF 'bare dora-digest-off bin/old-digest.sh' "$T/out" && ok || bad "B6 flag_on bare line: '$(cat "$T/out")'"
jq -c '.readers = []' "$T/dora.json" > "$T/h/catalog/switches.d/dora-digest-off.json"
reset; mig "$SM"
eq "B6 no row for a switch with no readers" "$(key_put dora-digest-off)" "0"
grep -qxF 'bare dora-digest-off catalog/switches.d/dora-digest-off.json' "$T/out" && ok \
  || bad "B6 no-readers bare line: '$(cat "$T/out")'"
cp "$T/dora.json" "$T/h/catalog/switches.d/dora-digest-off.json"; rm -f "$T/r/bin/old-digest.sh"

echo "switch-migrate-bare-reader.bh-2412: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
