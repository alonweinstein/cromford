#!/bin/bash
# bin/box-name.sh [--write] — print THIS box's fleet name (box-*).
#
# `hostname` is not identity. Every Orgo box boots the image default
# "orgo-desktop", so five machines answer the same string: the console's JOBS
# box column could not tell them apart, and nothing keyed on the box column
# (the worker's paused-box-<box> flag, its scope=box concurrency rules, the
# claim-resume path) could either.
#
# The name is NOT kept in a new hand-typed registry. The box's own repo-managed
# crontab already carries it, as the argument to bin/watchdog-ping.sh, and
# tests/watchdog-boxes-test.sh holds that set identical to the watchdog
# worker's BOXES in both directions — so deriving it from there means there is
# still exactly ONE list of fleet box names and it cannot drift from this one.
#
# Resolution order, first hit wins:
#   1. $BOX_NAME              — an operator override, and how a box with no
#                               cron wiring (a fly builder, a laptop) names
#                               itself.
#   2. state/box-name         — what --write left here, read by bin/jobs-client.sh.
#   3. cron/<box-id>.cron     — derived from the checkout, keyed by state/box-id.
#   4. hostname               — the old behaviour, so an unprovisioned box or a
#                               checkout without cron wiring still works.
#
# --write persists the resolved name to state/box-name, and ONLY when it was
# derived from the repo (3) — writing back the hostname would freeze
# "orgo-desktop" into the file that exists to replace it, and a later sync that
# could resolve the real name would find the file already populated.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
CHECKOUT="${CHECKOUT:-/root/harness-checkout}"
STATE="$HARNESS/state/box-name"

# The same character class bin/watchdog-ping.sh sanitises its argument with, so
# a name that pings cannot be a name that fails to resolve.
clean() { printf %s "${1:-}" | tr -dc 'A-Za-z0-9._-'; }

WROTE=derived
NAME=$(clean "${BOX_NAME:-}")
if [ -z "$NAME" ] && [ -r "$STATE" ]; then
  NAME=$(clean "$(cat "$STATE" 2>/dev/null)")
fi
if [ -z "$NAME" ]; then
  BOX_ID=$(clean "$(cat "$HARNESS/state/box-id" 2>/dev/null)")
  CRONF="$CHECKOUT/cron/$BOX_ID.cron"
  # cron/<box>.cron is GENERATED and no longer committed (BH-1247), so a fresh
  # checkout has none and this resolution would fall through to the hostname —
  # which is the failure this whole script exists to end (every box reporting
  # the Orgo image default "orgo-desktop" into the jobs ledger's box column).
  # Render it, best-effort: a render that fails leaves the old fallbacks intact
  # rather than turning a naming miss into a sync failure.
  if [ -n "$BOX_ID" ] && [ ! -s "$CRONF" ] && [ -x "$CHECKOUT/bin/render-cron.sh" ]; then
    RENDERED_CRON=$(mktemp 2>/dev/null) && {
      trap 'rm -f "${RENDERED_CRON:-}"' EXIT INT TERM
      if "$CHECKOUT/bin/render-cron.sh" --root "$CHECKOUT" "$BOX_ID" > "$RENDERED_CRON" 2>/dev/null \
         && [ -s "$RENDERED_CRON" ]; then
        CRONF="$RENDERED_CRON"
      else
        rm -f "$RENDERED_CRON"
      fi
    }
  fi
  # A parked box's cron file keeps the harness lines but drops the ping (see
  # cron/project-10.cron), so "file exists" is not "file names the box" —
  # an empty match falls through to the hostname rather than writing a blank.
  if [ -n "$BOX_ID" ] && [ -s "$CRONF" ]; then
    NAME=$(clean "$(grep -o 'watchdog-ping\.sh[[:space:]]\{1,\}[A-Za-z0-9._-]\{1,\}' "$CRONF" 2>/dev/null \
                    | head -1 | awk '{print $2}')")
  fi
fi
if [ -z "$NAME" ]; then
  NAME=$(clean "$(hostname 2>/dev/null)")
  WROTE=hostname
fi
[ -n "$NAME" ] || exit 1

if [ "${1:-}" = "--write" ] && [ "$WROTE" = derived ]; then
  if [ "$NAME" != "$(cat "$STATE" 2>/dev/null)" ]; then
    mkdir -p "$HARNESS/state" 2>/dev/null
    printf '%s\n' "$NAME" > "$STATE" 2>/dev/null || true
  fi
fi
printf '%s\n' "$NAME"
