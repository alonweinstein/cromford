#!/bin/bash
# bin/tmpfs-ensure.sh [--dry-run] — the one place a box's /tmp tmpfs size is
# declared: TMPFS_RAM_PCT (default 50) percent of MemTotal, rounded down to
# whole GB, never below 4G. Run by bin/bootstrap-machine.sh on first boot and
# by bin/update-runners.sh every day, so the size follows the box's RAM and
# survives a reboot.
#
# WHY. On 2026-10-11 the lead-review pool on box-small ran 1 worker
# for hours: /tmp was a 4 GB tmpfs. An operator raised /tmp to 8 GB by hand on
# two review boxes; on one of them nothing persisted it (no fstab line, no
# tmp.mount), so a reboot would put it back to 4 GB (BH-6041).
#
# WHAT. It acts only when /tmp is ALREADY a tmpfs (findmnt), and it only grows:
#   - live size below the computed size: `mount -o remount,size=<N>G /tmp`,
#     then findmnt is read again; remount=done only when it reads the new size,
#     else remount=failed. A live size at or above it: remount=not-needed.
#   - fstab: no /tmp line -> append `tmpfs /tmp tmpfs
#     rw,nosuid,nodev,size=<N>G 0 0`; one tmpfs line with a smaller (or no)
#     size= -> that line's size= is set in place, after a copy to <fstab>.bak;
#     one line at or above it -> fstab=ok; two or more /tmp lines, a line that
#     is not tmpfs, or a size it cannot read -> nothing is written, and the log
#     says why. fstab=written only after a re-read finds the line. The write is
#     a tmp file + mv beside the fstab, so a failed write (chattr +i) changes
#     nothing.
# It never turns a disk /tmp into a tmpfs and never shrinks one.
#
# One line in logs/tmpfs-ensure.log per run (and on stdout):
#   tmpfs-ensure mem_mb=<n> pct=<p> size=<N>G live=<bytes> remount=<..> fstab=<..>
# Exit 0 after any attempt; 2 on a usage error.
#
# Knob: TMPFS_RAM_PCT on the update-runners lane (catalog/lanes.d/update-runners.json,
# 10-75; outside that, 50 and a log line). Test seams: HARNESS_ROOT, TMPFS_FSTAB,
# TMPFS_MEMINFO, TMPFS_FINDMNT, TMPFS_MOUNT. Under HARNESS_TEST_SANDBOX=1 with no
# TMPFS_FSTAB it skips, so a suite never touches the real /etc/fstab or /tmp.
set -u
H="${HARNESS_ROOT:-${HARNESS:-/root/harness}}"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  '') ;;
  *) echo "usage: bin/tmpfs-ensure.sh [--dry-run]" >&2; exit 2 ;;
esac

FSTAB="${TMPFS_FSTAB:-/etc/fstab}"
MEMINFO="${TMPFS_MEMINFO:-/proc/meminfo}"
FINDMNT="${TMPFS_FINDMNT:-findmnt}"
MOUNT="${TMPFS_MOUNT:-mount}"
G=1073741824

mkdir -p "$H/logs" 2>/dev/null
LOG="$H/logs/tmpfs-ensure.log"
say() {
  local l
  l="$(date -u +%Y-%m-%dT%H:%M:%SZ) tmpfs-ensure$([ "$DRY" = 1 ] && printf ': dry-run') $*"
  printf '%s\n' "$l" >> "$LOG" 2>/dev/null
  printf '%s\n' "$l"
}

if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -z "${TMPFS_FSTAB:-}" ]; then
  say "TMPFS_FSTAB unset under HARNESS_TEST_SANDBOX - skipped"; exit 0
fi

PCT="${TMPFS_RAM_PCT:-50}"
case "$PCT" in
  ''|*[!0-9]*) say "TMPFS_RAM_PCT='$PCT' is not a whole number in 10-75; using 50"; PCT=50 ;;
  *) if [ "$((10#$PCT))" -lt 10 ] || [ "$((10#$PCT))" -gt 75 ]; then
       say "TMPFS_RAM_PCT='$PCT' is not a whole number in 10-75; using 50"; PCT=50
     else PCT=$((10#$PCT)); fi ;;
esac

MEM_KB=$(awk '/^MemTotal:/ { print $2; exit }' "$MEMINFO" 2>/dev/null)
case "$MEM_KB" in ''|*[!0-9]*) say "MemTotal unreadable in $MEMINFO; no change"; exit 0 ;; esac
N=$(( MEM_KB * PCT / 100 / 1048576 ))
[ "$N" -lt 4 ] && N=4
WANT=$((N * G))
HEAD="mem_mb=$((MEM_KB / 1024)) pct=$PCT size=${N}G"

FST=$("$FINDMNT" -n -o FSTYPE /tmp 2>/dev/null)
if [ "$FST" != tmpfs ]; then
  say "$HEAD skipped: /tmp is not a tmpfs (${FST:-not a mount point})"; exit 0
fi

# live_bytes — the size findmnt reports for /tmp; empty when unreadable
live_bytes() {
  local b
  b=$("$FINDMNT" -n -b -o SIZE /tmp 2>/dev/null | tr -d ' ')
  case "$b" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$b"
}

# ── the live size ────────────────────────────────────────────────────────────
LIVE=$(live_bytes) || LIVE=""
if [ -z "$LIVE" ]; then
  RM="unknown"
elif [ "$LIVE" -ge "$WANT" ]; then
  RM="not-needed"
elif [ "$DRY" = 1 ]; then
  RM="would"
else
  "$MOUNT" -o "remount,size=${N}G" /tmp >/dev/null 2>&1
  NOWB=$(live_bytes) || NOWB=""
  if [ -n "$NOWB" ] && [ "$NOWB" -ge "$WANT" ]; then RM="done"; else RM="failed"; fi
fi

# ── fstab ────────────────────────────────────────────────────────────────────
# to_bytes <size= value> — bytes for <n>, <n>k, <n>m, <n>g; rc 1 otherwise (%, junk)
to_bytes() {
  local v="${1,,}" n m=1
  case "$v" in
    *k) n="${v%k}"; m=1024 ;;
    *m) n="${v%m}"; m=1048576 ;;
    *g) n="${v%g}"; m=$G ;;
    *) n="$v" ;;
  esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$n * m))"
}
# the non-comment lines whose mount point is /tmp
mapfile -t TL < <(awk '$1 !~ /^#/ && $2 == "/tmp" { print NR }' "$FSTAB" 2>/dev/null)
FS_OUT=""
if [ ! -r "$FSTAB" ]; then
  FS_OUT="unreadable"
elif [ "${#TL[@]}" -ge 2 ]; then
  FS_OUT="ambiguous (${#TL[@]} /tmp lines; none changed)"
elif [ "${#TL[@]}" = 0 ]; then
  LINE="tmpfs /tmp tmpfs rw,nosuid,nodev,size=${N}G 0 0"
  if [ "$DRY" = 1 ]; then FS_OUT="would-write"
  else
    { cat "$FSTAB"; [ -n "$(tail -c1 "$FSTAB")" ] && echo; printf '%s\n' "$LINE"; } > "$FSTAB.tmp.$$" 2>/dev/null \
      && mv -f "$FSTAB.tmp.$$" "$FSTAB" 2>/dev/null
    rm -f "$FSTAB.tmp.$$" 2>/dev/null
    if grep -qxF "$LINE" "$FSTAB" 2>/dev/null; then FS_OUT="written"; else FS_OUT="failed"; fi
  fi
else
  NR_T="${TL[0]}"
  read -r f1 f2 f3 f4 f5 f6 < <(sed -n "${NR_T}p" "$FSTAB")
  cur=""
  IFS=, read -r -a OPTS <<< "${f4:-}"
  for o in "${OPTS[@]}"; do case "$o" in size=*) cur="${o#size=}" ;; esac; done
  if [ "${f3:-}" != tmpfs ]; then
    FS_OUT="kept (the /tmp line is ${f3:-unreadable}, not tmpfs)"
  elif [ -n "$cur" ] && ! CURB=$(to_bytes "$cur"); then
    FS_OUT="kept (size=$cur is not a size this script reads)"
  elif [ -n "$cur" ] && [ "$CURB" -ge "$WANT" ]; then
    FS_OUT="ok"
  elif [ "$DRY" = 1 ]; then
    FS_OUT="would-write"
  else
    NEWO=""
    for o in "${OPTS[@]}"; do
      case "$o" in size=*) o="size=${N}G" ;; esac
      NEWO="${NEWO:+$NEWO,}$o"
    done
    [ -n "$cur" ] || NEWO="${NEWO:+$NEWO,}size=${N}G"
    LINE="$f1 $f2 $f3 $NEWO ${f5:-0} ${f6:-0}"
    if cp -p "$FSTAB" "$FSTAB.bak" 2>/dev/null \
       && awk -v n="$NR_T" -v l="$LINE" 'NR == n { print l; next } { print }' "$FSTAB" > "$FSTAB.tmp.$$" 2>/dev/null \
       && mv -f "$FSTAB.tmp.$$" "$FSTAB" 2>/dev/null; then :; fi
    rm -f "$FSTAB.tmp.$$" 2>/dev/null
    if grep -qxF "$LINE" "$FSTAB" 2>/dev/null; then FS_OUT="written"; else FS_OUT="failed"; fi
  fi
fi

say "$HEAD live=${LIVE:-unknown} remount=$RM fstab=$FS_OUT"
exit 0
