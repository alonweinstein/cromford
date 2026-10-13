#!/bin/bash
# bin/fly-sync-harness.sh <project> — sync the harness runtime (bin/, prompts/,
# fleet.conf, fly/) onto the builder's volume at /data/harness. Builders run
# run-build.sh + agent-call.sh from the volume; without this sync the first real
# job dies No-such-file (medic finding, TK-41 2026-07-31). Idempotent + cheap:
# tarball over fly sftp (staged path, then extract via console), stamped with
# the harness-repo git sha; the dispatcher calls us only when the stamp differs.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
# The checkout to tar. HARNESS_REPO is the harness's owner/name SLUG since
# BH-4080 (bin/lib/deployment.sh), and global.env may set it, so only a PATH
# spelling of it (the older use here) still names the checkout.
REPO="${HARNESS_CHECKOUT:-/root/harness-checkout}"
case "${HARNESS_REPO:-}" in /*) REPO="$HARNESS_REPO" ;; esac
export PATH="/root/.fly/bin:$PATH"
P="${1:?project}"
set -a; . "$HENV/fly.env"; set +a
TV="FLY_API_TOKEN_$(echo "$P" | tr '[:lower:].-' '[:upper:]__')"
APP=$(jq -r '.app // ""' "$HARNESS/state/fly/$P.json" 2>/dev/null)
export FLY_ACCESS_TOKEN="${!TV:-}"
[ -n "$APP" ] && [ -n "$FLY_ACCESS_TOKEN" ] || { echo "missing app/token for $P" >&2; exit 1; }
FLY=$(command -v fly || command -v flyctl)
SHA=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)

REMOTE_SHA=$("$FLY" ssh console -a "$APP" -C "/bin/sh -c 'cat /data/harness/.sync-sha 2>/dev/null'" 2>/dev/null | tr -dc 'a-f0-9' | head -c 12)
[ "$REMOTE_SHA" = "$SHA" ] && { echo "already synced ($SHA)"; exit 0; }

TB=$(mktemp /tmp/hsync-XXXX.tgz)
# catalog/ ships too: agent-call derives each lane's dollar bound from
# catalog/context-budgets.json, and without it a BUILDER — the machine that
# runs exactly the plan/execute/review lanes with the largest budgets — falls
# back to a tier default instead of its declared ceiling.
# vercel.conf: the e2e smoke stage reads it to decide whether a project has
# preview deployments at all. Registry only — no Vercel token ever leaves the hub.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness-tarball.sh" || { echo "harness-tarball.sh missing" >&2; rm -f "$TB"; exit 1; }
harness_tarball "$TB" "$REPO" bin prompts rules catalog fleet.conf vercel.conf fly
[ $? = 2 ] && echo "no git HEAD in $REPO — tarball carries no HARNESS_COMMIT stamp" >&2
STAGE="/run/harness/.hsync.$$.tgz"
"$FLY" ssh sftp put -a "$APP" "$TB" "$STAGE" >/dev/null 2>&1 || { echo "sftp put failed" >&2; rm -f "$TB"; exit 1; }
"$FLY" ssh console -a "$APP" -C "/bin/sh -c 'mkdir -p /data/harness && tar xzf $STAGE -C /data/harness && echo $SHA > /data/harness/.sync-sha && mkdir -p /data/harness/logs /data/harness/state /data/harness/locks /data/harness/builds && rm -f $STAGE'" >/dev/null 2>&1 || { echo "remote extract failed" >&2; rm -f "$TB"; exit 1; }
rm -f "$TB"
echo "synced harness@$SHA to $APP:/data/harness"
