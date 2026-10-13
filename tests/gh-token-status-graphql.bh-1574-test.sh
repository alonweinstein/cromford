#!/bin/bash
# tests/gh-token-status-graphql.bh-1574-test.sh — BH-1574: `gh-token.sh --status`
# reports GraphQL used/remaining from the X-RateLimit headers of a GraphQL
# response, not from /rate_limit.
#
# WHY. /rate_limit's `resources.graphql` answered used=0 remaining=5000 on the
# hub while a `gh pr list` on the SAME token, the same minute, came back with
# `X-RateLimit-Used: 80` (measured 2026-09-23). A gauge that reads 0 used while
# the bucket is spending is the gauge that told nobody the conductor's reads
# were about to fail. The GraphQL numbers now come from a GraphQL response's
# own headers (resource=graphql), with /rate_limit only as the fallback when no
# such header came back — and the line says which it used.
#
# The existing text shape is unchanged up to its last field (tests/gh-quota
# .bh-426-test.sh and tests/gh-default-auth-lanes-test.sh grep it); the new
# fields are appended.
#
# Run from anywhere: bash tests/gh-token-status-graphql.bh-1574-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=1790143200   # determinism: ok pinned; the reset headers are derived from it
RESET_R=$((NOW + 900)); RESET_G=$((NOW + 1146))
A="$T/a"
mkdir -p "$A/bin/lib" "$A/state/gh-app-tokens" "$A/env" "$A/logs" "$T/fakebin"
cp "$DIR/bin/gh-token.sh" "$A/bin/"; chmod +x "$A/bin/gh-token.sh"
cp "$DIR/bin/lib/env-path.sh" "$A/bin/lib/"

# The stubbed GitHub. /rate_limit answers the misleading used=0 body for every
# token. /graphql answers WITH the resource=graphql headers for ghs_alpha only;
# ghs_beta's /graphql answers no rate-limit headers at all (the fallback case).
cat > "$T/fakebin/curl" <<SH
#!/bin/bash
AUTH=""; URL=""; HDR=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -H) case "\$2" in Authorization:*) AUTH="\${2#Authorization: }" ;; esac; shift 2 ;;
    -D) HDR="\$2"; shift 2 ;;
    -m|-X|-d|--data|-o) shift 2 ;;
    http*) URL="\$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "\$URL" "\$AUTH" >> "$T/curl-calls.txt"
case "\$URL" in
  */graphql)
    if [ "\$AUTH" = "token ghs_alpha" ]; then
      H='HTTP/2 200\r\nx-ratelimit-limit: 5000\r\nx-ratelimit-remaining: 4920\r\nx-ratelimit-used: 80\r\nx-ratelimit-reset: $RESET_G\r\nX-RateLimit-Resource: graphql\r\n\r\n'
    else
      H='HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'
    fi
    if [ "\$HDR" = - ]; then printf "\$H"; elif [ -n "\$HDR" ]; then printf "\$H" > "\$HDR"; fi
    [ "\$HDR" = - ] || printf '{"data":{"rateLimit":{"used":80}}}'
    ;;
  *)
    printf '{"resources":{"core":{"remaining":6500,"limit":6600,"reset":$RESET_R},"graphql":{"remaining":5000,"limit":5000,"used":0,"reset":$RESET_G}}}'
    ;;
esac
exit 0
SH
chmod +x "$T/fakebin/curl"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"

cache() { # cache <slug> <token>
  jq -nc --arg s "$1" --arg t "$2" '{repo:$s,token:$t,expires_at:"2099-01-01T00:00:00Z",minted_at:"2026-09-23T00:00:00Z"}' \
    > "$A/state/gh-app-tokens/$(printf '%s' "$1" | tr / -).json"
}
cache Org/alpha ghs_alpha
cache Org/beta ghs_beta

status() {
  env -u GH_TOKEN PATH="$T/fakebin:$PATH" HARNESS="$A" HARNESS_ENV_DIR="$A/env" \
      GH_APP_API_BASE="http://api.test" "$A/bin/gh-token.sh" --status "$@" 2>"$A/err.txt"
}

S=$(status)
AL=$(grep '^Org/alpha ' <<<"$S")
grep -q 'graphql=4920/5000 ' <<<"$AL" && ok || bad "1a: graphql remaining/limit must come from the /graphql headers (4920/5000), got: $AL"
grep -q ' graphql_used=80' <<<"$AL" && ok || bad "1b: the text line prints graphql_used from X-RateLimit-Used, got: $AL"
grep -q ' graphql_source=headers' <<<"$AL" && ok || bad "1c: and says where the numbers came from, got: $AL"
grep -q '^Org/alpha remaining=6500/6600 expires_at=2099-01-01T00:00:00Z graphql=4920/5000 rest_resets_at=' <<<"$AL" && ok \
  || bad "1d: the pre-BH-1574 fields keep their order; the new ones are appended, got: $AL"
BL=$(grep '^Org/beta ' <<<"$S")
grep -q 'graphql=5000/5000 ' <<<"$BL" && grep -q ' graphql_source=rate_limit' <<<"$BL" && ok \
  || bad "1e: no graphql headers = /rate_limit fallback, labelled rate_limit, got: $BL"
[ "$(grep -c . <<<"$S")" = 2 ] && ok || bad "1f: still one line per token, got: $S"
grep -q '/graphql token ghs_alpha' "$T/curl-calls.txt" && ok || bad "1g: the headers come from a real /graphql request, got: $(cat "$T/curl-calls.txt")"

J=$(status --json)
R=$(jq -c '.[] | select(.identity=="Org/alpha")' <<<"$J")
[ "$(jq -r '[.graphql_remaining,.graphql_limit,.graphql_used,.graphql_source] | map(tostring) | join(" ")' <<<"$R")" = "4920 5000 80 headers" ] && ok \
  || bad "2a: --json carries graphql_used and graphql_source, got: $R"
R=$(jq -c '.[] | select(.identity=="Org/beta")' <<<"$J")
[ "$(jq -r '[.graphql_remaining,.graphql_used,.graphql_source] | map(tostring) | join(" ")' <<<"$R")" = "5000 null rate_limit" ] && ok \
  || bad "2b: an unknown used is null, never 0, got: $R"
grep -q 'ghs_' <<<"$S$J$(cat "$A/err.txt")" && bad "3: a token value reached the output" || ok

echo "gh-token-status-graphql.bh-1574: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
