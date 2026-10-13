#!/bin/bash
# tests/tmpfs-ensure.bh-6041-test.sh — BH-6041: bin/tmpfs-ensure.sh declares
# the /tmp tmpfs size in one place, sized from box RAM (TMPFS_RAM_PCT of
# MemTotal, floor 4G), and persists it in fstab so a reboot keeps it. It only
# acts when /tmp is ALREADY a tmpfs and it only ever grows the size.
#
# The shipped script runs against a fixture fstab (TMPFS_FSTAB), meminfo
# (TMPFS_MEMINFO), a fake findmnt (TMPFS_FINDMNT, reads $T/fs-type and
# $T/fs-size) and a fake mount (TMPFS_MOUNT, records its argv; with
# $T/mount-works it also moves $T/fs-size). Nothing real is read or written.
#   T1  16 GB, empty fstab, live 4G: one `size=8G` line, remount=done; a second
#       run writes nothing and calls no mount (8G is live now).
#   T2  one smaller /tmp line (size=4G): replaced in place with size=8G, the
#       other options and lines kept, .bak written.
#   T3  the fake findmnt keeps the old size after the remount: remount=failed.
#   T4  live 10G, computed 8G: no mount call, and an fstab line at 10G is
#       kept: the size is never shrunk.
#   T5  /tmp not a tmpfs: no write, no mount, `skipped: /tmp is not a tmpfs`.
#   T6  two /tmp lines: fstab untouched, one log line.
#   T7  --dry-run: no write, no mount; prints size=8G and what it would do.
#   T8  sizing: 6 GB -> 4G (floor); 15.9 GB -> 7G; TMPFS_RAM_PCT=25 on 32 GB
#       -> 8G; an invalid TMPFS_RAM_PCT uses 50 and logs it.
#   T9  MemTotal unreadable: no change, one log line. A usage error is rc 2.
#   T10 under HARNESS_TEST_SANDBOX=1 with no TMPFS_FSTAB the script skips.
#   T11 the provisioning calls it: bin/bootstrap-machine.sh and
#       bin/update-runners.sh, and the TMPFS_RAM_PCT registry row.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/tmpfs-ensure.bh-6041-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset TMPFS_RAM_PCT TMPFS_FSTAB TMPFS_MEMINFO TMPFS_FINDMNT TMPFS_MOUNT 2>/dev/null || true

scratch_install_closure bin/tmpfs-ensure.sh "$T/h" >/dev/null || { echo "FAIL: cannot install bin/tmpfs-ensure.sh's closure"; exit 1; }
mkdir -p "$T/h/logs" "$T/fx"
G=1073741824
cat > "$T/fx/findmnt" <<EOF
#!/bin/bash
case " \$* " in
  *" FSTYPE "*) cat "$T/fs-type" 2>/dev/null ;;
  *" SIZE "*) cat "$T/fs-size" 2>/dev/null ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/fx/mount" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/mount.calls"
if [ -e "$T/mount-works" ]; then
  s=\$(printf '%s' "\$*" | sed -n 's/.*size=\([0-9]*\)G.*/\1/p')
  [ -n "\$s" ] && echo \$((s * $G)) > "$T/fs-size"
fi
exit 0
EOF
chmod +x "$T/fx/findmnt" "$T/fx/mount"
FS="$T/fx/fstab"
LOG="$T/h/logs/tmpfs-ensure.log"
BASE_FSTAB='# /etc/fstab
UUID=fixture-root / ext4 defaults 0 1'

mem() { printf 'MemTotal:       %s kB\nMemFree:        1000 kB\n' "$1" > "$T/fx/meminfo"; }
reset() { # reset <mem kB> <live G> [fstab body]
  mem "$1"; echo tmpfs > "$T/fs-type"; echo $(($2 * G)) > "$T/fs-size"
  printf '%s\n' "${3:-$BASE_FSTAB}" > "$FS"
  rm -f "$FS.bak" "$T/mount.calls" "$LOG"; : > "$T/mount-works"
}
run() {
  timeout 30 env HARNESS_ROOT="$T/h" HARNESS="$T/h" TMPFS_FSTAB="$FS" TMPFS_MEMINFO="$T/fx/meminfo" \
    TMPFS_FINDMNT="$T/fx/findmnt" TMPFS_MOUNT="$T/fx/mount" "$@" bash "$T/h/bin/tmpfs-ensure.sh" ${ARGS:-} > "$T/out" 2>&1
  RC=$?
}
tmplines() { grep -cE '^[^#[:space:]]+[[:space:]]+/tmp[[:space:]]' "$FS"; }
mcalls() { local n; n=$(grep -c . "$T/mount.calls" 2>/dev/null); echo "${n:-0}"; }
last() { tail -1 "$LOG" 2>/dev/null; }
GB16=$((16 * 1024 * 1024))   # MemTotal of a 16 GB box, in kB

# T1
reset $GB16 4
run
[ "$RC" = 0 ] && ok || bad "T1 rc 0 (got $RC: $(cat "$T/out"))"
[ "$(tmplines)" = 1 ] && grep -qxF 'tmpfs /tmp tmpfs rw,nosuid,nodev,size=8G 0 0' "$FS" && ok || bad "T1 one size=8G line ($(cat "$FS"))"
grep -qxF 'UUID=fixture-root / ext4 defaults 0 1' "$FS" && ok || bad "T1 the other fstab lines are kept"
[ "$(cat "$T/mount.calls" 2>/dev/null)" = "-o remount,size=8G /tmp" ] && ok || bad "T1 one remount to 8G ($(cat "$T/mount.calls" 2>/dev/null))"
[[ $(last) == *"size=8G"*"remount=done"*"fstab=written"* ]] && ok || bad "T1 the log says size=8G remount=done fstab=written ('$(last)')"
cp "$FS" "$T/fstab.after1"; rm -f "$T/mount.calls"
run
cmp -s "$FS" "$T/fstab.after1" && ok || bad "T1 a second run writes nothing"
[ "$(mcalls)" = 0 ] && ok || bad "T1 a second run calls no mount ($(cat "$T/mount.calls"))"
[[ $(last) == *"remount=not-needed"*"fstab=ok"* ]] && ok || bad "T1 the second run says remount=not-needed fstab=ok ('$(last)')"

# T2
reset $GB16 4 "$BASE_FSTAB
tmpfs /tmp tmpfs rw,nosuid,nodev,noexec,size=4G,mode=1777 0 0
/dev/vdb /data ext4 defaults 0 2"
run
grep -qxF 'tmpfs /tmp tmpfs rw,nosuid,nodev,noexec,size=8G,mode=1777 0 0' "$FS" && ok || bad "T2 the line is replaced in place with size=8G ($(cat "$FS"))"
[ "$(tmplines)" = 1 ] && grep -qxF '/dev/vdb /data ext4 defaults 0 2' "$FS" && ok || bad "T2 one /tmp line and the other lines kept ($(cat "$FS"))"
[ "$(sed -n 3p "$FS")" = 'tmpfs /tmp tmpfs rw,nosuid,nodev,noexec,size=8G,mode=1777 0 0' ] && ok || bad "T2 the line stays where it was"
grep -qF 'size=4G' "$FS.bak" 2>/dev/null && ok || bad "T2 the .bak holds the old line"
# a line with no size= gets one
reset $GB16 4 "$BASE_FSTAB
tmpfs /tmp tmpfs defaults 0 0"
run
grep -qxF 'tmpfs /tmp tmpfs defaults,size=8G 0 0' "$FS" && ok || bad "T2 a /tmp line with no size= gets size=8G ($(cat "$FS"))"

# T3
reset $GB16 4; rm -f "$T/mount-works"
run
[ "$RC" = 0 ] && [[ $(last) == *"remount=failed"* ]] && ok || bad "T3 findmnt still reads 4G after the remount: remount=failed, rc 0 ('$(last)')"
[[ $(last) != *"remount=done"* ]] && ok || bad "T3 never remount=done on an unproven remount"

# T4
reset $GB16 10 "$BASE_FSTAB
tmpfs /tmp tmpfs rw,size=10G 0 0"
run
[ "$(mcalls)" = 0 ] && ok || bad "T4 live 10G >= 8G: no mount call ($(cat "$T/mount.calls"))"
grep -qxF 'tmpfs /tmp tmpfs rw,size=10G 0 0' "$FS" && [ ! -e "$FS.bak" ] && ok || bad "T4 a 10G fstab line is never shrunk ($(cat "$FS"))"
[[ $(last) == *"remount=not-needed"*"fstab=ok"* ]] && ok || bad "T4 the log says not-needed and ok ('$(last)')"

# T5
reset $GB16 4; echo overlay > "$T/fs-type"
run
[ "$RC" = 0 ] && [ "$(mcalls)" = 0 ] && [ "$(tmplines)" = 0 ] && ok || bad "T5 /tmp not a tmpfs: no mount, no fstab line ($(cat "$FS"))"
grep -q 'skipped: /tmp is not a tmpfs' "$LOG" && ok || bad "T5 the log says skipped ($(cat "$LOG"))"
reset $GB16 4; : > "$T/fs-type"
run
[ "$(mcalls)" = 0 ] && [ "$(tmplines)" = 0 ] && grep -q 'skipped: /tmp is not a tmpfs' "$LOG" && ok || bad "T5 /tmp not a mount point at all: skipped"

# T6
reset $GB16 4 "$BASE_FSTAB
tmpfs /tmp tmpfs size=2G 0 0
tmpfs /tmp tmpfs size=3G 0 0"
cp "$FS" "$T/fstab.before"
run
cmp -s "$FS" "$T/fstab.before" && ok || bad "T6 two /tmp lines: fstab untouched"
[[ $(last) == *"fstab=ambiguous"* ]] && ok || bad "T6 the log says fstab=ambiguous ('$(last)')"

# T7
reset $GB16 4
ARGS=--dry-run run
[ "$RC" = 0 ] && [ "$(mcalls)" = 0 ] && [ "$(tmplines)" = 0 ] && ok || bad "T7 --dry-run: no mount, no write ($(cat "$T/mount.calls" "$FS" 2>/dev/null))"
grep -q 'size=8G' "$T/out" && grep -q 'remount=would' "$T/out" && grep -q 'fstab=would-write' "$T/out" && ok || bad "T7 --dry-run prints size=8G and what it would do ($(cat "$T/out"))"

# T8 sizing
reset $((6 * 1024 * 1024)) 2; run
[[ $(last) == *" size=4G "* ]] && ok || bad "T8 6 GB -> 4G, the floor ('$(last)')"
reset $((159 * 1024 * 1024 / 10)) 2; run
[[ $(last) == *" size=7G "* ]] && ok || bad "T8 15.9 GB -> 7G, rounded down ('$(last)')"
reset $((32 * 1024 * 1024)) 2; run TMPFS_RAM_PCT=25
[[ $(last) == *" pct=25 size=8G "* ]] && ok || bad "T8 TMPFS_RAM_PCT=25 on 32 GB -> 8G ('$(last)')"
reset $GB16 2; run TMPFS_RAM_PCT=90
grep -q "TMPFS_RAM_PCT='90'" "$LOG" && [[ $(last) == *" pct=50 size=8G "* ]] && ok || bad "T8 TMPFS_RAM_PCT=90 is out of range: 50 is used and logged ($(cat "$LOG"))"

# T9
reset $GB16 4; printf 'MemFree: 1 kB\n' > "$T/fx/meminfo"
run
[ "$RC" = 0 ] && [ "$(mcalls)" = 0 ] && [ "$(tmplines)" = 0 ] && grep -q 'MemTotal unreadable' "$LOG" && ok || bad "T9 MemTotal unreadable: no change, one log line ($(cat "$LOG"))"
ARGS=--bogus run
[ "$RC" = 2 ] && ok || bad "T9 an unknown argument is rc 2 (got $RC)"

# T10
reset $GB16 4
timeout 30 env -u TMPFS_FSTAB HARNESS_ROOT="$T/h" HARNESS_TEST_SANDBOX=1 TMPFS_MEMINFO="$T/fx/meminfo" \
  TMPFS_FINDMNT="$T/fx/findmnt" TMPFS_MOUNT="$T/fx/mount" bash "$T/h/bin/tmpfs-ensure.sh" >/dev/null 2>&1
[ "$(mcalls)" = 0 ] && grep -q 'TMPFS_FSTAB unset under HARNESS_TEST_SANDBOX' "$LOG" && ok || bad "T10 the sandbox guard skips ($(cat "$LOG" 2>/dev/null))"

# T11 the provisioning wiring and the registry row
grep -qE '^"\$HERE/tmpfs-ensure\.sh" \|\| echo "WARN: ' "$SRC/bin/bootstrap-machine.sh" && ok || bad "T11 bin/bootstrap-machine.sh runs tmpfs-ensure.sh, never fatal"
grep -qE '^\[ -x /root/harness/bin/tmpfs-ensure\.sh \] && /root/harness/bin/tmpfs-ensure\.sh >> "\$LOG" 2>&1 \|\| true$' "$SRC/bin/update-runners.sh" && ok \
  || bad "T11 bin/update-runners.sh runs tmpfs-ensure.sh daily"
[ "$(jq -r '.knobs[]|select(.env=="TMPFS_RAM_PCT")|"\(.default) \(.min) \(.max) \(.read_in)"' "$SRC/catalog/lanes.d/update-runners.json")" = "50 10 75 bin/tmpfs-ensure.sh" ] && ok \
  || bad "T11 the TMPFS_RAM_PCT row on update-runners: default 50, min 10, max 75"

echo "tmpfs-ensure.bh-6041: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
