#!/bin/bash
# tests/lib/served-sha-fixture.sh — the shared fixture for bin/served-sha-watch.sh
# (BH-4936, the tracer of #4916) and the sibling suites that plug hooks into it
# (#4937 alert, #4938 autodeploy). Sourced AFTER tests/lib/scratch.sh, never
# executed:
#   . "$(dirname "$0")/lib/scratch.sh" || exit 1
#   . "$(dirname "$0")/lib/served-sha-fixture.sh" || exit 1
#
#   ssw_fx_setup     build $T/h as a scratch $HARNESS (the lane and its lib
#                    COPIED, so a suite may mutate them; the rest of the lane's
#                    source closure installed by scratch_install_closure),
#                    fleet.conf with demo-os -> example-org/demo-os, vercel.conf
#                    `demo-os team_x prj_x demo.example.com`, the auth file
#                    $T/auth.json holding fixture-token-1, stub curl/gh on PATH
#                    and bin/lane-alert.sh replaced by a recorder ($T/alerts.txt).
#   ssw_fx_run       one tick of the REAL $T/h/bin/served-sha-watch.sh with
#                    SERVED_SHA_NOW=$NOW; rc in SSW_RC, stdout+stderr in $T/out.
#   ssw_fx_reset     empty fixtures, requests, state, logs and hooks.
#   ssw_fx_head <sha> [iso-date|-]   commits/main answer (- = no committer date)
#   ssw_fx_served <sha|->            alias -> deployment answer (- = no git sha)
#   ssw_fx_list <json>               /v6/deployments answer
#   ssw_fx_compare <status>          compare/<served>...<head> answer
#
# Fixture files ($T/fx): alias, dep, list, post, head, compare — each <x>.json
# plus an optional <x>.code (default 200). Requests the stubs saw: curl ->
# $T/req/argv.lines (`METHOD URL BODY`, Bearer values redacted, plus the
# --max-time value) and $T/req/stdin.lines (the -K config, Bearer redacted);
# gh -> $T/req/gh.lines. Nothing leaves the box: the curl stub answers every
# host from these files.
SSW_FX_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NOW=1790000000  # determinism: ok pinned
SSW_FX_TOKEN=fixture-token-1

ssw_fx_setup() {
  [ -n "${T:-}" ] || { echo "ssw_fx_setup: source tests/lib/scratch.sh first" >&2; return 1; }
  local h="$T/h"
  mkdir -p "$h/bin/lib" "$h/logs" "$h/state" "$h/flags" "$h/locks" "$h/env" \
           "$T/fake" "$T/fx" "$T/req" "$T/tmp" || return 1
  cp "$SSW_FX_REPO/bin/served-sha-watch.sh" "$h/bin/served-sha-watch.sh" || return 1
  scratch_install_closure bin/served-sha-watch.sh "$h" >/dev/null || return 1
  cp "$SSW_FX_REPO/bin/fleet-conf.sh" "$h/bin/fleet-conf.sh" || return 1
  chmod +x "$h/bin/served-sha-watch.sh" "$h/bin/fleet-conf.sh"
  printf 'demo-os example-org/demo-os https://demo.example.com - 0 hub\n' > "$h/fleet.conf"
  printf '# project team project-id domain\ndemo-os team_x prj_x demo.example.com\n' > "$h/vercel.conf"
  printf '{"token":"%s"}\n' "$SSW_FX_TOKEN" > "$T/auth.json"
  : > "$h/env/global.env"
  cat > "$h/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$SSW_FX_T/alerts.txt"
SH
  chmod +x "$h/bin/lane-alert.sh"
  "$SSW_FX_REPO/bin/lanes-build.sh" --root "$SSW_FX_REPO" --to "$T/lanes.json" >/dev/null 2>&1 \
    || { echo "ssw_fx_setup: lanes-build could not compose the registry" >&2; return 1; }

  cat > "$T/fake/curl" <<'SH'
#!/bin/bash
D="$SSW_FX_T"; M=GET; URL=""; BODY=""; MT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M="$2"; shift 2 ;;
    --data-binary|-d) BODY="$2"; shift 2 ;;
    --max-time) MT="$2"; shift 2 ;;
    -w|-K|-H) shift 2 ;;
    http*) URL="$1"; shift ;;
    *) shift ;;
  esac
done
sed 's/Bearer [^"]*/Bearer <redacted>/' >> "$D/req/stdin.lines"
printf '%s %s %s max-time=%s\n' "$M" "$URL" "$BODY" "$MT" | sed 's/Bearer [^ ]*/Bearer <redacted>/' >> "$D/req/argv.lines"
f=""
case "$M $URL" in
  POST*) f=post ;;
  *"/v4/aliases/"*) f=alias ;;
  *"/v13/deployments/"*) f=dep ;;
  *"/v6/deployments"*) f=list ;;
esac
if [ -n "$f" ] && [ -f "$D/fx/$f.json" ]; then cat "$D/fx/$f.json"; fi
printf '\n%s' "$(cat "$D/fx/$f.code" 2>/dev/null || echo 200)"
SH
  cat > "$T/fake/gh" <<'SH'
#!/bin/bash
D="$SSW_FX_T"
printf '%s\n' "$*" >> "$D/req/gh.lines"
f=""
case "$*" in
  *"/commits/main"*) f=head ;;
  *"/compare/"*) f=compare ;;
esac
[ -n "$f" ] || { printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; exit 1; }
code=$(cat "$D/fx/$f.code" 2>/dev/null || echo 200)
printf 'HTTP/2 %s\r\ncontent-type: application/json\r\n\r\n' "$code"
[ -f "$D/fx/$f.json" ] && cat "$D/fx/$f.json"
case "$code" in 2*) exit 0 ;; *) exit 1 ;; esac
SH
  chmod +x "$T/fake/curl" "$T/fake/gh"

  export SSW_FX_T="$T" HARNESS="$h" HARNESS_ENV_DIR="$h/env" FLEET_CONF="$h/fleet.conf" \
         SERVED_SHA_VERCEL_AUTH="$T/auth.json" ENDPOINT_VERCEL=https://vercel.stub \
         GH_APP_TOKENS=0 GH_ETAG=0 LANE_REGISTRY="$T/lanes.json" TMPDIR="$T/tmp" \
         PATH="$T/fake:$PATH"
  unset SERVED_SHA_CONF SERVED_SHA_LAG_MIN SERVED_SHA_AUTODEPLOY SERVED_SHA_HTTP_TIMEOUT \
        SERVED_SHA_NOW GH_TOKEN
  ssw_fx_reset
}

ssw_fx_reset() {
  local d
  for d in "$T/fx" "$T/req" "$T/h/state" "$T/h/logs" "$T/h/bin/lib/served-sha-watch.d"; do
    [ -e "$d" ] && { scratch_rm "$d" || return 1; }
  done
  mkdir -p "$T/fx" "$T/req" "$T/h/state" "$T/h/logs" || return 1
  : > "$T/req/argv.lines"; : > "$T/req/gh.lines"; : > "$T/req/stdin.lines"
  rm -f "$T/alerts.txt" "$T/probe.txt"
}

ssw_fx_head() { # <sha> [iso-date|-]
  local iso="${2:-2026-09-10T00:00:00Z}"
  if [ "$iso" = - ]; then
    jq -nc --arg s "$1" '{sha:$s, commit:{committer:{name:"x"}}}' > "$T/fx/head.json"
  else
    jq -nc --arg s "$1" --arg d "$iso" '{sha:$s, commit:{committer:{name:"x", date:$d}}}' > "$T/fx/head.json"
  fi
}

ssw_fx_served() { # <sha|-> — the alias answer and the deployment it points at
  printf '{"alias":"demo.example.com","deploymentId":"dpl_fx1","uid":"al_1"}' > "$T/fx/alias.json"
  if [ "$1" = - ]; then
    printf '{"id":"dpl_fx1","name":"demo-os","target":"production","meta":{}}' > "$T/fx/dep.json"
  else
    jq -nc --arg s "$1" '{id:"dpl_fx1", name:"demo-os", target:"production",
      gitSource:{type:"github", sha:$s}, meta:{githubCommitSha:$s}}' > "$T/fx/dep.json"
  fi
}

ssw_fx_list() { printf '%s' "$1" > "$T/fx/list.json"; }
ssw_fx_compare() { jq -nc --arg s "$1" '{status:$s, ahead_by:1, behind_by:0}' > "$T/fx/compare.json"; }

ssw_fx_run() {
  SERVED_SHA_NOW="${SERVED_SHA_NOW:-$NOW}" bash "$T/h/bin/served-sha-watch.sh" > "$T/out" 2>&1
  SSW_RC=$?
}
