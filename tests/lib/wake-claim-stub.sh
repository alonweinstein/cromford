#!/bin/bash
# tests/lib/wake-claim-stub.sh — the harness-jobs wake routes as a file of JSON,
# for every suite that drives bin/wake-loop.sh (BH-2637). Sourced, never
# executed: `. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1`.
#
# WHAT IT STANDS IN FOR. bin/wake-loop.sh no longer polls GET /api/wakes. Each
# box claims its own rows (POST /api/wakes/claim), keeps its watermark in the
# wake_cursors row (GET|PUT /api/wakes/cursor) and takes launch cooldowns from
# wake_cooldowns (POST /api/wakes/cooldown/take). `wcs_routes` answers all four
# the way worker/jobs/src/routes/wakes.js does — the claim scans ONLY eligible
# rows (lowercased repo in `repos`, or kind in `kinds_all_repos`) above this
# box's cursor, caps the scan at `limit`, returns the rows not yet claimed BY
# THIS BOX, and reports `scanned_top`; the cursor PUT is MAX; a take is granted
# when the (kind, project) stamp is older than window_s — so a suite asserts the
# loop's behaviour against the worker's semantics, not against a stub's luck.
#
# WHERE ITS STATE LIVES: $WCS_DIR, default $HARNESS/state/wcs. Inside the loop's
# own state/ on purpose: a suite whose reset() wipes state/ between cases gets a
# fresh worker too, exactly as the old state/wake-cursor and
# state/wake-cooldown/ files were wiped with it.
#   $WCS_WAKES (default $HARNESS/wakes.json)  {"wakes":[...]} the table
#   $WCS_DIR/claimed.<box>                    ids this box already claimed
#   $WCS_DIR/cursor.<box>                     this box's cursor row
#   $WCS_DIR/cool/<kind>-<project>            cooldown stamp (epoch)
#   $WCS_DIR/curl.log                         `<METHOD> <path> <body>` per request
# Per-case modes (a file in $WCS_DIR, or the env var of the same name):
#   COOL_MODE=false|500   every take answers taken:false, or HTTP 500
#   CLAIM_MODE=500        the claim answers HTTP 500
#   CURSOR_PUT_MODE=500   the cursor PUT answers HTTP 500
#   CURSOR_GET_MODE=500   the cursor GET answers HTTP 500
#   CLAIM_ALL=1           a MIS-FILTERING worker: the claim ignores repos and
#                         kinds_all_repos, so a suite can prove the loop's own
#                         ownership guard rather than the worker's
#
# wcs_install <bindir>  writes <bindir>/wcs-routes (the route handler every curl
#                       stub delegates to: rc 0 = answered, rc 1 = not a wake
#                       route), a plain <bindir>/curl that answers `{}` 200 for
#                       everything else, an argv-recording <bindir>/ssh (to $WCS_SSH_LOG,
#                       default $HARNESS/ssh.log), and a
#                       <bindir>/crontab that answers from $WCS_DIR/crontab
#                       (absent = no crontab installed). A suite with its own
#                       curl writes it AFTER this and starts it with
#                       `"$(dirname "$0")/wcs-routes" "$@" && exit 0`.
# wcs_identity <treebin> copies the REAL bin/box-name.sh, bin/box-for.sh and
#                       bin/lib/hub-box.sh into the tree the loop runs out of, and
#                       points LANE_REGISTRY at tests/lib/rendered.sh's registry,
#                       composed from the real catalog/lanes.d. BOX_NAME (bin/box-name.sh's operator
#                       override) says which box the loop is; HUB_BOX_NAME
#                       defaults to box-hub as in production.
: "${DIR:?wake-claim-stub.sh needs DIR (the repo root)}"
: "${T:?wake-claim-stub.sh needs T (source tests/lib/scratch.sh first)}"

wcs_install() {
  local bin="${1:-$T/bin}"
  mkdir -p "$bin"
  cat > "$bin/wcs-routes" <<'SH'
#!/bin/bash
# The wake routes of worker/jobs/src/routes/wakes.js, over files. rc 1 = not ours.
D="${WCS_DIR:-${HARNESS:?}/state/wcs}"
W="${WCS_WAKES:-$HARNESS/wakes.json}"
method=GET body="" url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --data-binary) body="$2"; case "$body" in @*) body=$(cat "${body#@}") ;; esac; shift ;;
    http*://*) url="$1" ;;
  esac
  shift
done
path="/${url#*://*/}"
case "$path" in /api/wakes/claim|/api/wakes/cursor*|/api/wakes/cooldown/take|/api/wakes/ack|/api/wakes|/api/wakes\?*) ;; *) exit 1 ;; esac
mkdir -p "$D/cool"
printf '%s %s %s\n' "$method" "$path" "$body" >> "$D/curl.log"
mode() { [ -n "${!1:-}" ] && { printf %s "${!1}"; return; }; cat "$D/$1" 2>/dev/null; }
fail() { printf '{"error":"stub"}\n%s' "$1"; exit 0; }
case "$method $path" in
  "POST /api/wakes/claim")
    [ "$(mode CLAIM_MODE)" = 500 ] && fail 500
    box=$(jq -r .box <<<"$body")
    cur=$(cat "$D/cursor.$box" 2>/dev/null); cur=${cur:-0}
    touch "$D/claimed.$box"
    all=false; [ "$(mode CLAIM_ALL)" = 1 ] && all=true
    out=$(jq -c --argjson req "$body" --argjson cur "$cur" --argjson all "$all" --rawfile claimed "$D/claimed.$box" '
      ($claimed | split("\n") | map(select(. != "") | tonumber)) as $mine
      | [ (.wakes // [])[] | select(.id > $cur)
          | select($all or ((.repo | ascii_downcase) as $r | $req.repos | index($r))
                   or (.kind as $k | $req.kinds_all_repos | index($k))) ]
      | sort_by(.id) | .[:$req.limit] as $scanned
      | { wakes: [ $scanned[] | select(.id as $i | $mine | index($i) | not) ],
          cursor: $cur,
          scanned_top: (if ($scanned | length) > 0 then $scanned[-1].id else $cur end) }' \
      "$W" 2>/dev/null) || out=$(jq -nc --argjson cur "$cur" '{wakes:[],cursor:$cur,scanned_top:$cur}')
    jq -r '.wakes[].id' <<<"$out" >> "$D/claimed.$box"
    printf '%s\n200' "$out" ;;
  "GET /api/wakes/cursor"*)
    [ "$(mode CURSOR_GET_MODE)" = 500 ] && fail 500
    box="${path#*box=}"
    c=$(cat "$D/cursor.$box" 2>/dev/null)
    printf '{"box":"%s","cursor":%s}\n200' "$box" "${c:-null}" ;;
  "PUT /api/wakes/cursor")
    [ "$(mode CURSOR_PUT_MODE)" = 500 ] && fail 500
    box=$(jq -r .box <<<"$body"); n=$(jq -r .cursor <<<"$body")
    c=$(cat "$D/cursor.$box" 2>/dev/null); c=${c:-0}
    [ "$n" -gt "$c" ] && c="$n"
    printf '%s' "$c" > "$D/cursor.$box"
    printf '{"box":"%s","cursor":%s}\n200' "$box" "$c" ;;
  "POST /api/wakes/cooldown/take")
    case "$(mode COOL_MODE)" in 500) fail 500 ;; false) printf '{"taken":false}\n200'; exit 0 ;; esac
    k=$(jq -r .kind <<<"$body"); p=$(jq -r .project <<<"$body"); win=$(jq -r .window_s <<<"$body")
    f="$D/cool/$k-$p"; now=$(date +%s); last=$(cat "$f" 2>/dev/null); last=${last:-0}
    if [ $(( now - last )) -ge "$win" ]; then printf '%s' "$now" > "$f"; printf '{"taken":true}\n200'
    else printf '{"taken":false}\n200'; fi ;;
  "POST /api/wakes/ack") printf '{"acked":1}\n200' ;;
  *) printf '{"error":"not found"}\n404' ;;
esac
exit 0
SH
  cat > "$bin/curl" <<'SH'
#!/bin/bash
"$(dirname "$0")/wcs-routes" "$@" && exit 0
printf '{}\n200'
SH
  cat > "$bin/ssh" <<'SH'
#!/bin/bash
echo "$*" >> "${WCS_SSH_LOG:-$HARNESS/ssh.log}"
SH
  cat > "$bin/crontab" <<'SH'
#!/bin/bash
f="${WCS_DIR:-$HARNESS/state/wcs}/crontab"
[ "${1:-}" = -l ] && [ -r "$f" ] && { cat "$f"; exit 0; }
exit 1
SH
  chmod +x "$bin/wcs-routes" "$bin/curl" "$bin/ssh" "$bin/crontab"
}

wcs_identity() {
  local tb="${1:-$T/bin}"
  mkdir -p "$tb/lib"
  cp "$DIR/bin/box-name.sh" "$DIR/bin/box-for.sh" "$tb/"
  cp "$DIR/bin/lib/hub-box.sh" "$tb/lib/"
  chmod +x "$tb/box-name.sh" "$tb/box-for.sh"
  command -v rendered_registry >/dev/null 2>&1 || { . "$DIR/tests/lib/rendered.sh" || return 1; }
  LANE_REGISTRY=$(rendered_registry) || return 1
  export LANE_REGISTRY
}

# wcs_log — the request log of the stub worker (empty when nothing was asked).
wcs_log() { cat "${WCS_DIR:-$HARNESS/state/wcs}/curl.log" 2>/dev/null; }
