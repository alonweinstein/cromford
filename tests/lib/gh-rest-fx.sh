#!/bin/bash
# tests/lib/gh-rest-fx.sh — a stub `gh` that answers bin/lib/gh-rest.sh.
# Sourced by a suite AFTER tests/lib/scratch.sh (it needs $T); never executed.
#
# WHY A SHARED ONE. Since BH-784 the merge family's decision reads go through
# `gh api -i -X <METHOD> <path>` and are judged on the HTTP STATUS LINE, not on
# gh's exit code — 200/404/403 are three different answers and a stub that only
# echoes JSON can express one of them. This gives a suite a routing table
# instead: every read is (method, path glob) -> (status, body), so "the PR read
# 403s while the list still answers" is one line.
#
#   ghfx_init                                     install the stub on $T/fakebin
#   ghfx_route <METHOD|DIFF> <path-glob> <status> [body]
#   ghfx_routes_reset / ghfx_log_reset
#   ghfx_extra <<'SH' ... SH                      non-REST gh argv (pr list, pr merge)
#
# First matching route wins, so a test adds the specific path before the broad
# glob. An UNROUTED read answers 404 on purpose: an unstubbed decision read must
# be loud (rc 44), never a silent 200 the assertions then read as real.
# DIFF is a pseudo-method: it matches the `Accept: …v3.diff` read, which shares
# its path with the JSON one.

ghfx_init() {
  mkdir -p "$T/fakebin" "$T/rest-bodies"
  : > "$T/routes"; : > "$T/gh-argv.log"; rm -f "$T/extra.sh"
  cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$GHFX/gh-argv.log"
A="$*"
[ -r "$GHFX/extra.sh" ] && . "$GHFX/extra.sh"
case "$A" in
  "auth token"*) echo faketoken; exit 0 ;;
  # bin/lib/gh-budget.sh caches this read; an EMPTY answer leaves a 0-byte cache
  # file that the next run's age arithmetic chokes on, and the tick dies without
  # a word. Every other suite answers it too.
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
esac
if [ "${1:-}" = api ] && [ "${2:-}" = -i ] && [ "${3:-}" = -X ]; then
  M="$4"; P="$5"
  case "$A" in *v3.diff*) M=DIFF ;; esac
  while IFS='|' read -r rm rg rst rbody rguard; do
    [ -n "${rm:-}" ] || continue
    [ "$rm" = "$M" ] || continue
    # shellcheck disable=SC2254  # the glob is the route
    case "$P" in $rg) ;; *) continue ;; esac
    # A guarded route is live only while its marker file exists — how a suite
    # says "after the merge verb ran, this PR reads merged".
    [ -n "${rguard:-}" ] && [ ! -e "$rguard" ] && continue
    printf 'HTTP/1.1 %s Something\r\nServer: x\r\n\r\n' "$rst"
    [ -n "${rbody:-}" ] && [ -r "$GHFX/rest-bodies/$rbody" ] && cat "$GHFX/rest-bodies/$rbody"
    exit 0
  done < "$GHFX/routes"
  printf 'HTTP/1.1 404 Not Found\r\nServer: x\r\n\r\n{"message":"gh-rest-fx: no route for %s %s"}' "$M" "$P"
  exit 0
fi
exit 0
GH
  chmod +x "$T/fakebin/gh"
  export GHFX="$T"
}

ghfx_route() { # ghfx_route <METHOD|DIFF> <path-glob> <status> [body] [guard-file]
  local n
  n=$(( $(cat "$T/rest-bodies/.n" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$T/rest-bodies/.n"
  printf '%s' "${4-}" > "$T/rest-bodies/b$n"
  printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "b$n" "${5-}" >> "$T/routes"
}

ghfx_routes_reset() { : > "$T/routes"; }
ghfx_log_reset()    { : > "$T/gh-argv.log"; }
ghfx_extra()        { cat > "$T/extra.sh"; }   # fed on stdin

# ghfx_pr <state> <merged_at|-> <head-sha> <head-ref> <base-ref> <labels-csv>
#         [mergeable true|false|null] [mergeable_state] [login] [merge_commit_sha]
# One REST pull object in the shape GitHub really answers, so the normalising jq
# under test sees REST field names and never GraphQL ones.
ghfx_pr() {
  jq -nc --arg st "$1" --arg m "$2" --arg sha "$3" --arg ref "$4" --arg base "$5" \
         --arg labels "$6" --arg mg "${7:-true}" --arg ms "${8:-clean}" \
         --arg login "${9:-app/cromford}" --arg msha "${10:-}" \
    '{state:$st,
      merged_at:(if $m=="-" then null else $m end),
      head:{sha:$sha,ref:$ref},
      base:{ref:$base},
      labels:(if $labels=="" then [] else ($labels|split(",")|map({name:.})) end),
      mergeable:(if $mg=="null" then null elif $mg=="true" then true else false end),
      mergeable_state:$ms,
      user:{login:$login,type:"Bot"},
      merge_commit_sha:(if $msha=="" then null else $msha end),
      body:"harness PR body",
      html_url:("https://github.com/o/r/pull/1")}'
}
