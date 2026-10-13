#!/bin/bash
# bin/auth-label.sh <label> [runner] [envfile] — name the account the CURRENT
# credential env pays with.
#
# Fingerprints the credential in effect for <runner> (default claude) RIGHT
# NOW — after optionally sourcing <envfile> the way a lane would — and appends
# fp -> label to the box-local overlay (state/auth-accounts.local.json). This
# is the ONLY sanctioned way the map grows: from a live token an operator is
# holding, never from a guess about which token some provisioning record says
# a box should have. The repo catalog (catalog/auth-accounts.json) is seeded
# empty for exactly that reason.
#
#   auth-label.sh "client-project-2-max" claude /root/harness/env/project-2.env
#   auth-label.sh "operator-supergrok" grok
#
# Prints the fp and label it wrote; the raw secret is never echoed or stored.
set -uo pipefail
LABEL="${1:?usage: auth-label.sh <label> [runner] [envfile]}"
RUNNER="${2:-claude}"
ENVF="${3:-}"

case "$LABEL" in
  *,*|*$'\n'*) echo "auth-label: label must not contain commas or newlines (it rides a csv row)" >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "auth-label: jq is required" >&2; exit 2; }

if [ -n "$ENVF" ]; then
  [ -r "$ENVF" ] || { echo "auth-label: env file not readable: $ENVF" >&2; exit 2; }
  set -a
  # shellcheck source=/dev/null
  . "$ENVF"
  set +a
fi

# shellcheck source=bin/auth-fingerprint.sh
. "$(dirname "$0")/auth-fingerprint.sh"

FP=$(auth_fp_for_runner "$RUNNER")
if [ -z "$FP" ] || [ "$FP" = none ]; then
  echo "auth-label: no resolvable credential for runner '$RUNNER' in the current env — nothing to label" >&2
  exit 1
fi

LOCAL="${AUTH_ACCOUNTS_LOCAL:-${HARNESS:-/root/harness}/state/auth-accounts.local.json}"
mkdir -p "$(dirname "$LOCAL")"
TMP="$LOCAL.tmp.$$"
# Atomic temp+rename so a concurrent reader never sees a half-written map;
# merge-then-set so re-labelling an fp updates it instead of duplicating.
if { cat "$LOCAL" 2>/dev/null; echo '{}'; } \
  | jq -s --arg fp "$FP" --arg l "$LABEL" \
      '[.[] | select(type == "object")] | add | .[$fp] = $l' > "$TMP" \
  && [ -s "$TMP" ] && mv "$TMP" "$LOCAL"; then
  echo "auth-label: $RUNNER credential $FP -> '$LABEL' ($LOCAL)"
else
  rm -f "$TMP" 2>/dev/null
  echo "auth-label: failed to write $LOCAL" >&2
  exit 1
fi
