#!/bin/bash
# push-proposal-assets.sh <pkey> <idea-dir> — upload desktop/mobile screenshots
# to the console's proposal-asset store. b64 goes through a temp FILE + jq
# --rawfile: a 200KB+ screenshot as a single argv argument blows Linux's
# 128KB-per-arg limit (MAX_ARG_STRLEN) and silently killed the first uploads.
set -uo pipefail
PKEY="${1:?pkey}"; IDIR="${2:?idea-dir}"
HARNESS=/root/harness
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a
[ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || exit 0
RC=0
for KIND in desktop mobile; do
  [ -s "$IDIR/$KIND.png" ] || continue
  base64 -w0 "$IDIR/$KIND.png" > "$IDIR/$KIND.b64"
  jq -nc --arg pkey "$PKEY" --arg kind "$KIND" --rawfile b64 "$IDIR/$KIND.b64" \
    '{pkey:$pkey,kind:$kind,b64:$b64}' > "$IDIR/$KIND.payload.json"
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST \
    -H "Authorization: Bearer $HARNESS_SECRET" -H 'Content-Type: application/json' \
    --data-binary @"$IDIR/$KIND.payload.json" "$CONSOLE_URL/api/proposal-asset")
  rm -f "$IDIR/$KIND.b64" "$IDIR/$KIND.payload.json"
  if [ "$HTTP" != "200" ]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [product] asset upload $KIND for $PKEY -> HTTP $HTTP" >&2
    RC=1
  fi
done
exit $RC
