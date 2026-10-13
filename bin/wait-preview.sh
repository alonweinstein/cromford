#!/bin/bash
# wait-preview.sh <repo-slug> <sha> [timeout-sec] — resolve the Vercel PREVIEW
# deployment URL for <sha> and echo it. Exit 0 + URL on success; exit 1 (silent
# stdout) when the deployment failed, never appeared, or the URL is protected
# and no bypass secret is available. Callers treat any failure as "QA skipped"
# (fail-open) — this script must never block a build on infra flakiness.
#
# Resolution order (2026-08-13 rework; the fleet PAT gets HTTP 403 from the
# GitHub Deployments API, which had been silently skipping QA fleet-wide):
#   1. Vercel snapshot relay, per-project file: state/vercel-deploys/<project>.json
#      (hub's vercel-deploy-snapshot.sh writes it; fly-pool.sh mputs it onto
#      live pool machines every tick). Combined state/vercel-deploy-status.json
#      (.projects[<p>].previews) is the fallback on watcher boxes.
#   2. Poll the snapshot until timeout — the relay refreshes it mid-build.
#   3. The old gh Deployments poll, LAST resort only (no snapshot source at
#      all), keeping the 403 fail-fast so a denied token never burns 10 min.
# Boxes and pool machines hold NO Vercel tokens; the snapshot is the only lane.
#
# Project name: PROJECT env override wins; else fleet.conf lookup by repo slug.
# Path overrides for tests: VERCEL_SNAPSHOT_DIR, VERCEL_SNAPSHOT_STATUS.
set -uo pipefail
SLUG="${1:?repo-slug}"; SHA="${2:?sha}"; TO="${3:-600}"
HARNESS="${HARNESS:-/root/harness}"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
SNAP_DIR="${VERCEL_SNAPSHOT_DIR:-$HARNESS/state/vercel-deploys}"
SNAP_STATUS="${VERCEL_SNAPSHOT_STATUS:-$HARNESS/state/vercel-deploy-status.json}"

# --- project name: PROJECT env override, else fleet.conf (match repo slug) ----
if [ -z "${PROJECT:-}" ]; then
  for CONF in "${FLEET_CONF:-}" "$HARNESS/fleet.conf" "$(cd "$(dirname "$0")" && pwd)/../fleet.conf"; do
    [ -n "$CONF" ] && [ -s "$CONF" ] || continue
    PROJECT=$(awk -v s="$SLUG" '$1 !~ /^#/ && $2 == s {print $1; exit}' "$CONF")
    [ -n "$PROJECT" ] && break
  done
fi
PROJECT="${PROJECT:-}"

# Protection probe (unchanged): a 401 preview is unusable without a bypass
# secret. Echoes URL + exit 0 when reachable; exit 1 when protected; returns 1
# (keep polling) while the app is still warming up.
probe() { # probe <url>
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 \
    ${VERCEL_AUTOMATION_BYPASS_SECRET:+-H "x-vercel-protection-bypass: $VERCEL_AUTOMATION_BYPASS_SECRET"} "$1")
  case "$code" in
    2*|3*) echo "$1"; exit 0 ;;
    401|403) echo "preview $1 protected (HTTP $code, no usable bypass)" >&2; exit 1 ;;
    *) return 1 ;;  # app still warming up — keep polling
  esac
}

# #425: one arm for this script's one repo, outside the poll loop — every arm is a fork.
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
END=$((SECONDS + TO))
while :; do
  # --- 1+2. snapshot relay ----------------------------------------------------
  SRC=""
  if [ -n "$PROJECT" ]; then
    if [ -s "$SNAP_DIR/$PROJECT.json" ]; then
      SRC=$(jq -c '.previews // []' "$SNAP_DIR/$PROJECT.json" 2>/dev/null) || SRC=""
    fi
    if [ -z "$SRC" ] && [ -s "$SNAP_STATUS" ]; then
      SRC=$(jq -c --arg p "$PROJECT" '.projects[$p].previews // empty' "$SNAP_STATUS" 2>/dev/null) || SRC=""
    fi
  fi
  if [ -n "$SRC" ]; then
    # Entries for this SHA (snapshot stores the full sha; tolerate either side
    # being abbreviated, prefix-match only at >=7 hex to avoid false joins).
    M=$(jq -c --arg sha "$SHA" '[ .[] | .sha as $es | select(
          ($es == $sha)
          or ( ($sha|length) >= 7 and ($es|length) >= 7
               and (($es|startswith($sha)) or ($sha|startswith($es))) ) ) ]' \
        <<<"$SRC" 2>/dev/null) || M='[]'
    URL=$(jq -r '[ .[] | select((.state|ascii_upcase) == "READY") ]
                 | sort_by(.createdAt) | (last // {}) | .url // empty' <<<"$M")
    if [ -n "$URL" ]; then
      probe "$URL" || true   # warming: fall through and poll again
    fi
    ALLBAD=$(jq -r '[ .[] | .state | ascii_upcase ]
                    | if length > 0 and all(. == "ERROR" or . == "CANCELED")
                      then "yes" else "no" end' <<<"$M")
    if [ "$ALLBAD" = "yes" ]; then
      echo "preview deployment failed for $SHA (snapshot: all entries ERROR/CANCELED)" >&2
      exit 1
    fi
    # no entry yet, or still BUILDING — the relay will refresh; keep polling.
  else
    # --- 3. last resort: gh Deployments API (no snapshot source available) ----
    GHERR=$(mktemp)
    DID=$(gh api "repos/$SLUG/deployments?sha=$SHA&per_page=10" \
          -q '[.[] | select(.environment | test("preview"; "i"))][0].id' 2>"$GHERR")
    # Fail FAST when the API is denied, not after the full timeout: a 403 here
    # means the token cannot read Deployments at all, and with no snapshot
    # source either, polling cannot fix that (2026-08-13 lesson).
    if [ -z "$DID" ] && grep -q "HTTP 403" "$GHERR"; then
      echo "deployments API denied (HTTP 403) and no Vercel snapshot for ${PROJECT:-$SLUG} — QA cannot see previews" >&2
      rm -f "$GHERR"; exit 1
    fi
    rm -f "$GHERR"
    if [ -n "$DID" ]; then
      STATUSES=$(gh api "repos/$SLUG/deployments/$DID/statuses?per_page=20" 2>/dev/null)
      URL=$(echo "$STATUSES" | jq -r '[.[] | select(.state == "success")][0].environment_url // empty')
      if [ -n "$URL" ]; then
        probe "$URL" || true
      fi
      echo "$STATUSES" | jq -e '[.[] | select(.state == "failure" or .state == "error")] | length > 0' >/dev/null 2>&1 \
        && { echo "preview deployment failed for $SHA" >&2; exit 1; }
    fi
  fi
  [ "$SECONDS" -lt "$END" ] || break
  REMAIN=$((END - SECONDS)); NAP=15; [ "$REMAIN" -lt "$NAP" ] && NAP="$REMAIN"
  sleep "$NAP"
done
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
echo "no preview deployment for $SHA within ${TO}s" >&2
exit 1
