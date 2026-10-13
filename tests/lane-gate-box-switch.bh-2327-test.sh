#!/bin/bash
# tests/lane-gate-box-switch.bh-2327-test.sh — the per-box lane switch (BH-2327).
#
# WHY. The 23 `scope: "box"` lanes (disk-clean, watchdog-ping, …) run on every
# box, and the only switches the gate read were all-off, lane-off-<id> (every
# box) and lane-off-<id>-<project>. Stopping disk-clean on ONE box meant ssh and
# a hand-touched file. The gate now also reads `lane-off-<id>.box.<box>` for a
# box-scope lane, where <box> is THIS box (JOBS_BOX, else `hostname -s`).
#
# What is proved here, through a real sourced lane calling lane_gate_or_exit:
#   A1 no rows -> a box lane runs;
#   A2 an active row for THIS box stops it, exit 0, the log names the switch;
#   A3 a row for another box (and orgo-2 vs orgo-20) does not stop it;
#   A4 the row flipped back to 0 resumes it (and the file goes away);
#   A5 a hub lane never reads a box switch; the project form on a box lane
#      is not the box switch;
#   A6 fail open: worker down with nothing cached runs; a cached paused
#      answer keeps it stopped;
#   A7 an unusable box name (JOBS_BOX unset, hostname with `:`) runs and
#      requests no malformed switch name.
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=1758300000
mkdir -p "$T/h/bin/lib" "$T/h/flags" "$T/h/state" "$T/h/logs" "$T/h/catalog" "$T/path"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/"
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"

# The switch name every layer agrees on (also pinned, verbatim, in
# worker/jobs/test/lanes-box-switch.bh-2327.test.js and
# console-ui/tests/settings-box-switch.bh-2327.test.js).
SW='lane-off-disk-clean.box.b'

cat > "$T/h/bin/fake-lane.sh" <<'SH'
#!/bin/bash
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
[ -r "$HARNESS/bin/stub-jobs-client.sh" ] && . "$HARNESS/bin/stub-jobs-client.sh"
. "$HARNESS/bin/lib/lane-gate.sh"
lane_gate_or_exit "${LANE_ID:-disk-clean}" "${LANE_PROJECT:-}"
echo WORKED
SH
chmod +x "$T/h/bin/fake-lane.sh"

# The real client's contract: flag_sync drives the file from the row, rc 0
# reconciled / rc 2 no row / rc 1 outage.
cat > "$T/h/bin/stub-jobs-client.sh" <<'SH'
flag_sync() {
  echo "$1" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  mkdir -p "$HARNESS/flags"
  case " ${PAUSED:-} " in *" $1 "*) touch "$HARNESS/flags/$1"; return 0 ;; esac
  case " ${CLEARED:-} " in *" $1 "*) rm -f "$HARNESS/flags/$1"; return 0 ;; esac
  return 2
}
flag_active() { flag_sync "$1" >/dev/null 2>&1 || true; [ -f "$HARNESS/flags/$1" ]; }
_jobs_req() { return 0; }
SH

run() { # run [env assignments...] -> stdout of the lane
  env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" \
      LANE_REGISTRY="$T/h/catalog/lanes.json" JOBS_BOX=b "$@" \
      "$T/h/bin/fake-lane.sh" 2>/dev/null
}
reset() { rm -rf "$T/h/state/lane-gate" "$T/h/logs/lane-gate.log"; rm -f "$T/h/flags"/*; : > "$T/calls"; }

# A1 — nothing set: the box lane runs, and it asked about its own box switch.
reset
[ "$(run)" = WORKED ] && ok || bad "A1 a box lane with no rows did not run"
grep -qx "$SW" "$T/calls" && ok || bad "A1 the gate never read $SW (calls: $(tr '\n' ' ' < "$T/calls"))"

# A2 — an active row for THIS box stops it, rc 0, log names the switch.
reset
OUT=$(run PAUSED="$SW"); RC=$?
[ -z "$OUT" ] && [ "$RC" -eq 0 ] && ok || bad "A2 box row: out='$OUT' rc=$RC (want empty, rc 0)"
grep -q "disk-clean SKIPPED — $SW (this box only)" "$T/h/logs/lane-gate.log" 2>/dev/null && ok \
  || bad "A2 lane-gate.log does not name the box switch: $(cat "$T/h/logs/lane-gate.log" 2>/dev/null)"
grep -q 'Settings → disk-clean → BOXES' "$T/h/logs/lane-gate.log" 2>/dev/null && ok \
  || bad "A2 the resume hint does not name the console path"

# A3 — another box's row does not stop this box; orgo-2 is not orgo-20.
reset
[ "$(run PAUSED=lane-off-disk-clean.box.other-box)" = WORKED ] && ok || bad "A3a another box's row stopped this box"
reset
[ "$(run JOBS_BOX=orgo-20 PAUSED=lane-off-disk-clean.box.orgo-2)" = WORKED ] && ok || bad "A3b orgo-2's row stopped orgo-20"
reset
[ -z "$(run JOBS_BOX=orgo-20 PAUSED=lane-off-disk-clean.box.orgo-20)" ] && ok || bad "A3c orgo-20's own row did not stop it"

# A4 — resume: the row flipped to 0, cache expired, the lane runs and the file is gone.
reset
run PAUSED="$SW" >/dev/null
[ -f "$T/h/flags/$SW" ] || bad "A4-setup the row never drove the file"
[ "$(run CLEARED="$SW" LANE_GATE_CACHE_S=0)" = WORKED ] && ok || bad "A4 the box row flipped back did not resume the lane"
[ ! -f "$T/h/flags/$SW" ] && ok || bad "A4 flags/$SW still on disk after resume"

# A5 — a hub lane never reads a box switch; the project form is not the box switch.
reset
[ "$(run LANE_ID=merge-conductor PAUSED=lane-off-merge-conductor.box.b)" = WORKED ] && ok \
  || bad "A5a a box row stopped a HUB lane"
grep -q '\.box\.' "$T/calls" && bad "A5a a hub lane requested a box switch: $(tr '\n' ' ' < "$T/calls")" || ok
reset
[ "$(run PAUSED=lane-off-disk-clean-b)" = WORKED ] && ok || bad "A5b the project-form name stopped a box lane"

# A6 — fail open, both directions.
reset
[ "$(run UNREACHABLE=1)" = WORKED ] && ok || bad "A6a worker down, nothing cached, the box lane was stopped"
reset
run PAUSED="$SW" >/dev/null
rm -f "$T/h/flags/$SW"
[ -z "$(run UNREACHABLE=1 LANE_GATE_CACHE_S=0)" ] && ok || bad "A6b worker down un-paused a box that was paused"

# A7 — no usable box name: runs, never asks for a malformed name.
cat > "$T/path/hostname" <<'SH'
#!/bin/sh
echo 'bad:name'
SH
chmod +x "$T/path/hostname"
reset
OUT=$(env -u JOBS_BOX HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" \
      LANE_REGISTRY="$T/h/catalog/lanes.json" PATH="$T/path:$PATH" \
      "$T/h/bin/fake-lane.sh" 2>/dev/null)
[ "$OUT" = WORKED ] && ok || bad "A7 an unusable hostname stopped the lane"
grep -q '\.box\.' "$T/calls" && bad "A7 requested a box switch with no valid box: $(tr '\n' ' ' < "$T/calls")" || ok
reset
[ "$(run JOBS_BOX=unknown PAUSED=lane-off-disk-clean.box.unknown)" = WORKED ] && ok || bad "A7b box 'unknown' read a switch"

# No registry lane id can contain the `.box.` separator's dot.
BAD=$(jq -r '.lanes[].id | select(test("[.]"))' "$T/h/catalog/lanes.json")
[ -z "$BAD" ] && ok || bad "a registry lane id contains '.': $BAD"

echo "lane-gate-box-switch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
