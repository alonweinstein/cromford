#!/bin/bash
# bin/dns-guard.sh — keep a box's DNS alive across a reboot (BH-5337).
#
# WHY. The fleet boxes run no systemd, but their image ships /etc/resolv.conf as
# the symlink ../run/systemd/resolve/stub-resolv.conf. /run is empty after a
# reboot, so the link dangles and the box has no DNS at all: no GitHub, no jobs
# worker, no tailscale login. The project-2 box went dark this way on 2026-10-03 and
# box-small on 2026-10-08.
#
# WHAT IT DOES.
#   1. Fix. If /etc/resolv.conf is a DANGLING symlink whose link text names
#      systemd/resolve, and /run/systemd/resolve is not a directory, it writes
#      a static file (one `nameserver` line a server) to a temp file in the same
#      directory and renames it over the link. It prints `dns: replaced ...`
#      only after the file reads back with every nameserver. Any other state
#      (a regular file, a live systemd-resolved, another resolver's link, no
#      file) is never written.
#   2. Canary. `getent hosts api.github.com`. On success it prints `dns: ok`.
#      On failure it writes ONE `dns: dead` line through bin/alert-line.sh
#      (id dns-dead-<box>) and prints it.
# It always exits 0: callers (bin/update-runners.sh, bin/bootstrap-machine.sh)
# must not stop on it.
#
# Knobs (all test seams): DNS_GUARD_RESOLV (/etc/resolv.conf),
# DNS_GUARD_SYSTEMD_DIR (/run/systemd/resolve), DNS_GUARD_HOST
# (api.github.com), DNS_GUARD_NAMESERVERS ("1.1.1.1 8.8.8.8"). The alert goes
# to $HARNESS/logs/ALERTS.log, through $HARNESS/bin/alert-line.sh, else the
# alert-line.sh beside this script (a first bootstrap has no $HARNESS/bin yet).
# Usage: bin/dns-guard.sh
set -uo pipefail
H="${HARNESS:-${H:-/root/harness}}"
RESOLV="${DNS_GUARD_RESOLV:-/etc/resolv.conf}"
SD_DIR="${DNS_GUARD_SYSTEMD_DIR:-/run/systemd/resolve}"
HOST="${DNS_GUARD_HOST:-api.github.com}"
NS="${DNS_GUARD_NAMESERVERS:-1.1.1.1 8.8.8.8}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
BOX=$(tr -dc 'a-z0-9-' 2>/dev/null < "$H/state/box-id"); BOX="${BOX:-$(hostname 2>/dev/null)}"

describe() {
  if [ -L "$RESOLV" ]; then
    if [ -e "$RESOLV" ]; then printf 'a symlink to %s' "$(readlink "$RESOLV")"
    else printf 'a dangling symlink to %s' "$(readlink "$RESOLV")"; fi
  elif [ -f "$RESOLV" ]; then printf 'a regular file'
  else printf 'missing'; fi
}

# --- 1. fix --------------------------------------------------------------------
if [ -L "$RESOLV" ] && [ ! -e "$RESOLV" ] && [ ! -d "$SD_DIR" ]; then
  link=$(readlink "$RESOLV")
  case "$link" in
    *systemd/resolve*)
      tmp=$(mktemp "$(dirname "$RESOLV")/.resolv.conf.XXXXXX" 2>/dev/null) || tmp=""
      if [ -n "$tmp" ]; then
        {
          printf '# static resolv.conf (BH-5337): written by bin/dns-guard.sh at %s.\n' "$(STAMP)"
          printf '# It replaced a dangling symlink to %s (no systemd-resolved on this box).\n' "$link"
          for s in $NS; do printf 'nameserver %s\n' "$s"; done
        } > "$tmp" 2>/dev/null && chmod 644 "$tmp" 2>/dev/null && mv -f "$tmp" "$RESOLV" 2>/dev/null
        rm -f "$tmp" 2>/dev/null
      fi
      good=1
      [ -f "$RESOLV" ] && [ ! -L "$RESOLV" ] || good=""
      for s in $NS; do grep -qx "nameserver $s" "$RESOLV" 2>/dev/null || good=""; done
      if [ -n "$good" ]; then
        echo "dns: replaced dangling stub symlink with static nameservers ($NS) at $RESOLV"
      else
        echo "dns: could not replace the dangling symlink $RESOLV -> $link"
      fi
      ;;
  esac
fi

# --- 2. canary -----------------------------------------------------------------
if timeout 20 getent hosts "$HOST" >/dev/null 2>&1; then
  echo "dns: ok ($HOST resolves)"
else
  if [ -f "$RESOLV" ] && [ ! -L "$RESOLV" ]; then fix="check its nameservers and the box's network"
  else fix="write a static $RESOLV by hand (nameserver 1.1.1.1, nameserver 8.8.8.8)"; fi
  line="[$BOX] dns: dead — getent hosts $HOST failed; $RESOLV is $(describe): $fix (BH-5337)"
  al="$H/bin/alert-line.sh"; [ -x "$al" ] || al="$(dirname "$0")/alert-line.sh"
  mkdir -p "$H/logs" 2>/dev/null
  [ -x "$al" ] && HARNESS="$H" "$al" --id "dns-dead-$BOX" "$line"
  printf '%s\n' "$line"
fi
exit 0
