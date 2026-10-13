#!/bin/bash
# bin/standby-install.sh <box> [--hub-name <n>] [--hub-id <id>] [--apply]
#     [--root <checkout>] [--cron-file <path>] [--conf <fleet.conf>]
#     [--hub-crontab <file> --own-crontab <file>]
#
# Turn a registered box into a warm standby hub (#401). The standby runs every
# hub lane behind `/root/harness/bin/hub-lease.sh check && `, so each one is
# inert while the hub holds the lease and fires on the standby once the hub's
# lease lapses, plus one stream line that keeps pulling the hub's latest state
# snapshot while `check` is false:
#   10,25,40,55 * * * * root .../hub-lease.sh check || .../state-restore.sh <hub-id> latest --apply --standby
# and, just before it, the verify lane (BH-2640) that runs a hub-requested
# scratch restore on this standby, inert on the same `check ||` polarity:
#   */5 * * * * root .../hub-lease.sh check || .../standby-verify.sh
# The stream line is always the last line.
#
# Dry run (the default) prints the cron.d file and writes nothing. --apply
# installs it atomically (tmp in the same dir + mv, mode 644) and then writes
# $HARNESS/state/standby-of = "<hub-name> <hub-id>". --conf <file> also puts
# `# @standby <box> <hub-name> <hub-id>` into that fleet.conf, replacing any
# line for <box>, in dry run too.
#
# The file goes to /etc/cron.d, NOT the user crontab: bin/update-runners.sh
# reinstalls the user crontab daily and would wipe a standby block.
#
# Transform, one pass in hub order: env lines verbatim; comments, blanks and
# @reboot dropped; watchdog-ping.sh and /api/ping/ lines dropped (they would
# ping AS the hub); a line whose command (gate stripped) byte-equals a command
# this box already runs is dropped; every other line gets the gate exactly once
# and the `root` user field. The hub's ungated `renew` therefore becomes
# `check && renew`: the standby never takes the lease on its own. Like
# render-crontab.sh this does not parse shell, so on a line with a top-level
# `;` or `||` the gate covers only the first command.
#
# Refusals exit 1 with one stderr line naming what is missing, and with --apply
# one ALERTS.log line; nothing is written. Usage errors exit 2.
set -uo pipefail
SELF=standby-install
HERE="$(cd "$(dirname "$0")" && pwd)"
HARNESS="${HARNESS:-/root/harness}"
# shellcheck source=lib/hub-box.sh
. "$HERE/lib/hub-box.sh" || exit 2
G='/root/harness/bin/hub-lease.sh check && '

usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" >&2; exit 2; }
BOX=""; HUB_NAME="$(hub_box_name)"; HUB_ID=hub; APPLY=0
ROOT=/root/harness-checkout; CRON=/etc/cron.d/harness-standby; CONF=""; HUBF=""; OWNF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hub-name)    HUB_NAME="${2:?}"; shift 2 ;;
    --hub-id)      HUB_ID="${2:?}"; shift 2 ;;
    --apply)       APPLY=1; shift ;;
    --root)        ROOT="${2:?}"; shift 2 ;;
    --cron-file)   CRON="${2:?}"; shift 2 ;;
    --conf)        CONF="${2:?}"; shift 2 ;;
    --hub-crontab) HUBF="${2:?}"; shift 2 ;;
    --own-crontab) OWNF="${2:?}"; shift 2 ;;
    -h|--help)     usage ;;
    -*)            echo "$SELF: unknown flag $1" >&2; usage ;;
    *)             [ -z "$BOX" ] || { echo "$SELF: unexpected argument $1" >&2; usage; }; BOX="$1"; shift ;;
  esac
done
[ -n "$BOX" ] || usage
if { [ -n "$HUBF" ] && [ -z "$OWNF" ]; } || { [ -z "$HUBF" ] && [ -n "$OWNF" ]; }; then
  echo "$SELF: --hub-crontab and --own-crontab go together" >&2; exit 2
fi

refuse() {  # refuse <what> <needs>
  echo "$SELF: refused: $1" >&2
  if [ "$APPLY" = 1 ]; then
    mkdir -p "$HARNESS/logs"
    printf '%s [%s] REFUSED %s: %s — needs %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$SELF" "$BOX" "$1" "$2" >> "$HARNESS/logs/ALERTS.log"
  fi
  exit 1
}

# shellcheck source=lib/env-path.sh
. "$HERE/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s/env\n' "$HARNESS"; }
HENV=$(harness_env_dir "$HARNESS")
if [ -f "$HENV/global.env" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$HENV/global.env" 2>/dev/null
  set +a
fi

# The hub check goes first: the hub has no fleet.conf row of its own, so the
# registration lookup would otherwise answer "not registered" for it.
[ "$BOX" = "$HUB_NAME" ] && refuse "$BOX is the hub" "a box other than $HUB_NAME"
LOOKUP="${CONF:-$ROOT/fleet.conf}"
FLEET_CONF="$LOOKUP" "$HERE/fleet-conf.sh" --tailnet-ip-of-box "$BOX" >/dev/null 2>&1 \
  || refuse "$BOX not registered in fleet.conf" "a row for $BOX with a tailnet_ip in $LOOKUP (operator)"
if [ "$APPLY" = 1 ]; then
  ME=$("$HERE/box-name.sh" 2>/dev/null)
  [ "$ME" = "$BOX" ] || refuse "this box is ${ME:-unnamed}, not $BOX" "the installer run on $BOX itself"
fi
MISSING=""
for V in BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
  [ -n "${!V:-}" ] || MISSING="$MISSING $V"
done
[ -n "${BACKUP_AGE_IDENTITY_FILE:-}" ] && [ -r "$BACKUP_AGE_IDENTITY_FILE" ] || MISSING="$MISSING BACKUP_AGE_IDENTITY_FILE"
[ -z "$MISSING" ] || refuse "missing:$MISSING" "those set in $HENV/global.env on $BOX (operator)"
[ -d "$(dirname "$CRON")" ] || refuse "no cron.d dir ($(dirname "$CRON"))" "cron installed on $BOX (operator)"
pgrep -x cron >/dev/null 2>&1 || refuse "cron not running" "the cron daemon started on $BOX (operator)"

# ---- render ------------------------------------------------------------------
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
if [ -n "$HUBF" ]; then
  cp "$HUBF" "$WORK/hub" && cp "$OWNF" "$WORK/own" || refuse "cannot read $HUBF / $OWNF" "readable crontab fixtures"
else
  "$ROOT/bin/render-crontab.sh" --root "$ROOT" "$HUB_ID" > "$WORK/hub" 2>"$WORK/err" \
    || refuse "render of hub crontab '$HUB_ID' failed" "a working render-crontab.sh in $ROOT"
  OWN_ID=$(cat "$HARNESS/state/box-id" 2>/dev/null)
  [ -n "$OWN_ID" ] || refuse "empty $HARNESS/state/box-id" "state/box-id written on $BOX (bootstrap-machine.sh)"
  "$ROOT/bin/render-crontab.sh" --root "$ROOT" "$OWN_ID" > "$WORK/own" 2>"$WORK/err" \
    || refuse "render of own crontab '$OWN_ID' failed" "a working render-crontab.sh in $ROOT"
fi

{
  printf '# generated by bin/standby-install.sh for %s — standby of %s (%s). Do not edit; re-run the installer.\n' "$BOX" "$HUB_NAME" "$HUB_ID"
  awk -v G="$G" '
    # split(line) -> sched, cmd (gate stripped); returns 0 for a non-schedule line
    function split_line(line,   n, i) {
      if (line ~ /^[ \t]*(#|$)/ || line ~ /^[A-Za-z_][A-Za-z0-9_]*=/) return 0
      n = (line ~ /^[ \t]*@/) ? 1 : 5
      sched = ""; cmd = line
      for (i = 1; i <= n; i++) {
        sub(/^[ \t]+/, "", cmd)
        if (!match(cmd, /^[^ \t]+/)) return 0
        sched = sched (i > 1 ? " " : "") substr(cmd, 1, RLENGTH)
        cmd = substr(cmd, RLENGTH + 1)
      }
      sub(/^[ \t]+/, "", cmd)
      if (cmd == "") return 0
      if (index(cmd, G) == 1) cmd = substr(cmd, length(G) + 1)
      return 1
    }
    FILENAME == ARGV[1] { if (split_line($0)) own[cmd] = 1; next }
    /^[A-Za-z_][A-Za-z0-9_]*=/ { print; next }
    /^[ \t]*(#|$)/ || /^[ \t]*@reboot/ { next }
    /watchdog-ping\.sh/ || /\/api\/ping\// { next }
    split_line($0) && !(cmd in own) { print sched " root " G cmd }
  ' "$WORK/own" "$WORK/hub"
  printf '%s\n' '*/5 * * * * root /root/harness/bin/hub-lease.sh check || /root/harness/bin/standby-verify.sh >> /root/harness/logs/standby-verify.log 2>&1'
  printf '10,25,40,55 * * * * root /root/harness/bin/hub-lease.sh check || /root/harness/bin/state-restore.sh %s latest --apply --standby >> /root/harness/logs/standby-stream.log 2>&1\n' "$HUB_ID"
} > "$WORK/out"

# ---- write -------------------------------------------------------------------
if [ -n "$CONF" ]; then
  TMPC=$(mktemp "$(dirname "$CONF")/.fleet.conf.XXXXXX") || exit 1
  awk -v b="$BOX" -v line="# @standby $BOX $HUB_NAME $HUB_ID" '
    $1 == "#" && $2 == "@standby" && $3 == b { if (!done) print line; done = 1; next }
    { print }
    END { if (!done) print line }
  ' "$CONF" > "$TMPC" && chmod --reference="$CONF" "$TMPC" && mv -f "$TMPC" "$CONF" \
    || { rm -f "$TMPC"; echo "$SELF: could not rewrite $CONF" >&2; exit 1; }
fi

if [ "$APPLY" != 1 ]; then
  cat "$WORK/out"
  exit 0
fi
TMP=$(mktemp "$(dirname "$CRON")/.harness-standby.XXXXXX") || exit 1
if ! { cat "$WORK/out" > "$TMP" && chmod 644 "$TMP" && mv -f "$TMP" "$CRON"; }; then
  rm -f "$TMP"; echo "$SELF: could not install $CRON" >&2; exit 1
fi
mkdir -p "$HARNESS/state" || exit 1
TMPS=$(mktemp "$HARNESS/state/.standby-of.XXXXXX") || exit 1
printf '%s %s\n' "$HUB_NAME" "$HUB_ID" > "$TMPS" && mv -f "$TMPS" "$HARNESS/state/standby-of" \
  || { rm -f "$TMPS"; echo "$SELF: could not write state/standby-of" >&2; exit 1; }
echo "$SELF: installed $CRON ($(grep -c "root $G" "$CRON") gated lines) — standby of $HUB_NAME ($HUB_ID)" >&2
