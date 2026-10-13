#!/bin/bash
# tests/pipeline-health-console-drift.bh-3554-test.sh — "Mission Control is
# behind main", the console pages drift block extracted VERBATIM from
# bin/pipeline-health.sh by its markers and driven against a scratch tree with
# a pinned clock, a scratch hub checkout with a fake origin/main, and a curl
# stub standing in for the Cloudflare Pages API.
#
# WHY IT EXISTS (BH-3554, BH-3564). The live console sat 15 days on dee684a1
# while about 230 console-ui commits merged, and nothing paged. The block
# compares the Pages PRODUCTION deployment's commit hash with main's newest
# first-parent console-ui commit (bin/lib/console-pages.sh's console_pages_want)
# and pages once Pages is CONSOLE_PAGES_DRIFT_S behind.
#
# FAIL-OPEN IS UNDER TEST TOO: a Cloudflare answer the block cannot read
# (curl failure, success=false, no production commit hash) pages after
# CONSOLE_PAGES_DRIFT_UNREADABLE_N ticks instead of going quiet. And the token
# never lands in a log, an alert, a state file, or curl's argv (D9).
#
# Run from anywhere: tests/pipeline-health-console-drift.bh-3554-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/env" "$T/stub"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

# ONE clock read; every fixture age is derived from it.
NOW=$(date +%s)
TOKEN=cf-TOKEN-SENTINEL-3564

awk '/^# >>> console pages drift/{f=1;next} /^# <<< console pages drift/{exit} f' \
  "$DIR/bin/pipeline-health.sh" > "$T/block.sh"

# --- D12: the block exists and sits after the freshness block, where HCO is set
[ -s "$T/block.sh" ] && ok || bad "D12 could not extract the console pages drift block — markers missing?"
FRESH_END=$(awk '/^# <<< fleet checkout freshness/{print NR; exit}' "$DIR/bin/pipeline-health.sh")
CPD_BEGIN=$(awk '/^# >>> console pages drift/{print NR; exit}' "$DIR/bin/pipeline-health.sh")
HCO_SET=$(awk '/^HCO=/{print NR; exit}' "$DIR/bin/pipeline-health.sh")
[ -n "$FRESH_END" ] && [ -n "$CPD_BEGIN" ] && [ -n "$HCO_SET" ] && [ "$CPD_BEGIN" -gt "$FRESH_END" ] && [ "$CPD_BEGIN" -gt "$HCO_SET" ] \
  && ok || bad "D12 the block must start after '# <<< fleet checkout freshness' ($FRESH_END) and after HCO= ($HCO_SET), starts at ${CPD_BEGIN:-missing}"

# The contract (#3561). Absent means this suite cannot say anything: fail, never skip.
if [ -f "$DIR/bin/lib/console-pages.sh" ]; then
  cp "$DIR/bin/lib/console-pages.sh" "$T/bin/lib/"; ok
else
  bad "bin/lib/console-pages.sh is missing — the block's contract"
fi

cat > "$T/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$BEAT_SINK"
exit 0
SH
chmod +x "$T/bin/beat.sh"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/bin/"
awk '/^# >>> alert emit cap/{f=1;next} /^# <<< alert emit cap/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/cap.sh"
cat > "$T/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$LANE_SINK"
exit 0
SH
chmod +x "$T/bin/lane-alert.sh"
export LANE_SINK="$T/lane.txt" BEAT_SINK="$T/beat.txt"

# curl stub: one line of argv per call, stdin kept, a canned body and rc.
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/curl.calls"
cat >> "$STUB_DIR/curl.stdin"
[ "${CURL_RC:-0}" = 0 ] || exit "$CURL_RC"
cat "$CURL_BODY_FILE"
SH
chmod +x "$T/stub/curl"

# --- scratch hub checkout ----------------------------------------------------
# C0 --- C1 ------------- M (--no-ff merge of BR) --- X (docs only)
#          \             /
#           BR (console-ui)
# origin/main = X. WANT (main's newest first-parent console-ui commit) = M.
HCO="$T/hco"
gc() { # gc <age-secs> <msg> — commit everything staged, dated NOW-age
  GIT_AUTHOR_DATE="$(( NOW - $1 )) +0000" GIT_COMMITTER_DATE="$(( NOW - $1 )) +0000" \
    git -C "$HCO" -c user.name=t -c user.email=t@t commit -q -m "$2"
}
mkrepo() { # mkrepo <merge-age-secs> [mainside] — mainside: main also changes console-ui while BR is open
  scratch_rm "$HCO"; mkdir -p "$HCO/console-ui" "$HCO/worker/jobs" "$HCO/docs"
  git -C "$HCO" init -q -b main
  echo a > "$HCO/console-ui/a.txt"
  cat > "$HCO/worker/jobs/wrangler.jsonc" <<'J'
{
  // "account_id": "acct-commented-out",
  "name": "jobs",
  "account_id": "acct-fixture"
}
J
  git -C "$HCO" add -A; gc 90000 C0
  echo a2 > "$HCO/console-ui/a.txt"; git -C "$HCO" add -A; gc 86400 C1
  C1=$(git -C "$HCO" rev-parse HEAD)
  git -C "$HCO" checkout -q -b feat
  echo b > "$HCO/console-ui/b.txt"; git -C "$HCO" add -A; gc 50000 BR
  BR=$(git -C "$HCO" rev-parse HEAD)
  git -C "$HCO" checkout -q main
  if [ "${2:-}" = mainside ]; then
    echo c > "$HCO/console-ui/c.txt"; git -C "$HCO" add -A; gc 40000 C2
  fi
  GIT_AUTHOR_DATE="$(( NOW - $1 )) +0000" GIT_COMMITTER_DATE="$(( NOW - $1 )) +0000" \
    git -C "$HCO" -c user.name=t -c user.email=t@t merge -q --no-ff -m M feat
  M=$(git -C "$HCO" rev-parse HEAD)
  echo d > "$HCO/docs/d.md"; git -C "$HCO" add -A; gc 60 X
  git -C "$HCO" update-ref refs/remotes/origin/main HEAD
}

body() { # body <canonical-hash|null> [latest-env latest-hash] — a success:true Pages project
  local can=$1 lenv=${2:-} lh=${3:-}
  jq -n --arg c "$can" --arg le "$lenv" --arg lh "$lh" '{success:true,errors:[],result:{
    name:"mission-control",
    canonical_deployment:(if $c == "null" then null else {environment:"production",deployment_trigger:{metadata:{commit_hash:$c}}} end),
    latest_deployment:(if $le == "" then null else {environment:$le,deployment_trigger:{metadata:{commit_hash:$lh}}} end)}}' \
    > "$T/body.json"
}

reset() { rm -f "$T/state/console-pages-drift" "$T/state/console-pages-drift.unreadable"
          : > "$T/lane.txt"; : > "$T/beat.txt"; : > "$T/logs/ALERTS.log"; : > "$T/logs/pipeline-health.log"
          : > "$T/curl.calls"; : > "$T/curl.stdin"
          echo '{}' > "$T/state/health-alerted.json"
          printf 'CLOUDFLARE_API_TOKEN=%s\n' "$TOKEN" > "$T/env/cloudflare.env"; }
drive() { # drive [VAR=val ...] — runs the block with a recording alert()
  : > "$T/alerts.txt"
  ( export HARNESS="$T" T="$T" H="$T" HCO="$HCO" HENV="$T/env" NOW="$NOW" \
      DEDUP="$T/state/health-alerted.json" PATH="$T/stub:$PATH" STUB_DIR="$T" \
      CURL_BODY_FILE="$T/body.json" CURL_RC=0 "$@"
    bash -c '
      set -uo pipefail
      STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      . "$T/cap.sh"; . "$0"' "$T/block.sh" </dev/null >/dev/null 2>"$T/err.txt" )
}
nalerts() { grep -c . "$T/alerts.txt"; }
UNR="$T/state/console-pages-drift.unreadable"
MARK="$T/state/console-pages-drift"

# ============================================================================
# D1 in sync: canonical production hash == WANT
# ============================================================================
mkrepo 10800; reset; body "$M"; drive
[ ! -s "$T/alerts.txt" ] && ok || bad "D1 in sync must not page: $(cat "$T/alerts.txt") err=$(cat "$T/err.txt")"
[ ! -f "$MARK" ] && ok || bad "D1 in sync must leave no drift mark"
[ "$(grep -c . "$T/curl.calls")" = 1 ] && ok || bad "D1 expected exactly one curl call: $(cat "$T/curl.calls")"
grep -q 'https://api.cloudflare.com/client/v4/accounts/acct-fixture/pages/projects/mission-control' "$T/curl.calls" \
  && ok || bad "D1 the call must read the mission-control project on the wrangler.jsonc account: $(cat "$T/curl.calls")"

# ============================================================================
# D2 behind by one first-parent console-ui merge, 3h old: one page
# ============================================================================
mkrepo 10800; reset; body "$C1"; drive
[ "$(nalerts)" = 1 ] && ok || bad "D2 expected exactly one alert, got: $(cat "$T/alerts.txt") err=$(cat "$T/err.txt")"
L=$(head -1 "$T/alerts.txt")
grep -q '^3600|consolepagesdrift:hub|' <<<"$L" && ok || bad "D2 hourly page under consolepagesdrift:hub: $L"
grep -qF "${C1:0:7}" <<<"$L" && ok || bad "D2 the line must name the deployed sha7: $L"
grep -qF "${M:0:7}" <<<"$L" && ok || bad "D2 the line must name main's console-ui sha7: $L"
grep -q '1 undeployed' <<<"$L" && ok || bad "D2 the line must count the undeployed merges: $L"
grep -q '3h old' <<<"$L" && ok || bad "D2 the line must age the oldest: $L"
grep -qF 'bin/console-pages-deploy.sh' <<<"$L" && ok || bad "D2 the line must name the deployer: $L"
[ -f "$MARK" ] && ok || bad "D2 the drift mark must be written so the resolve can fire once"

# ============================================================================
# D3 behind but young: no page; the knob moves the threshold; garbage falls back
# ============================================================================
mkrepo 1800; reset; body "$C1"; drive
[ ! -s "$T/alerts.txt" ] && ok || bad "D3 30m behind is under the 2h default: $(cat "$T/alerts.txt")"
[ ! -f "$MARK" ] && ok || bad "D3 young drift must not write the mark"
reset; drive CONSOLE_PAGES_DRIFT_S=900
grep -q '|consolepagesdrift:hub|' "$T/alerts.txt" && ok || bad "D3 CONSOLE_PAGES_DRIFT_S=900 must be read: $(cat "$T/alerts.txt")"
reset; drive CONSOLE_PAGES_DRIFT_S=abc
[ ! -s "$T/alerts.txt" ] && ok || bad "D3 CONSOLE_PAGES_DRIFT_S=abc must fall back to 7200: $(cat "$T/alerts.txt")"

# ============================================================================
# D4 unreadable: counts ticks, pages at N with its own reason, resolves on a good read
# ============================================================================
mkrepo 10800; reset; body "$M"
drive CURL_RC=7
[ ! -s "$T/alerts.txt" ] && ok || bad "D4 run 1 must not page: $(cat "$T/alerts.txt")"
[ "$(cat "$UNR" 2>/dev/null)" = 1 ] && ok || bad "D4 run 1 counter must read 1: $(cat "$UNR" 2>/dev/null)"
drive CURL_RC=7
[ ! -s "$T/alerts.txt" ] && ok || bad "D4 run 2 must not page: $(cat "$T/alerts.txt")"
[ "$(cat "$UNR" 2>/dev/null)" = 2 ] && ok || bad "D4 run 2 counter must read 2: $(cat "$UNR" 2>/dev/null)"
drive CURL_RC=7
[ "$(nalerts)" = 1 ] && grep -q '^3600|consolepagesdrift:unreadable|' "$T/alerts.txt" \
  && ok || bad "D4 run 3 must page consolepagesdrift:unreadable once: $(cat "$T/alerts.txt")"
grep -q 'curl failed' "$T/alerts.txt" && ok || bad "D4 the reason must say curl failed: $(cat "$T/alerts.txt")"
grep -q 'for 3 ticks' "$T/alerts.txt" && ok || bad "D4 the line must carry the tick count: $(cat "$T/alerts.txt")"
# success:false
reset; jq -n '{success:false,errors:[{code:10000,message:"Authentication error"}],result:null}' > "$T/body.json"
drive; drive; [ ! -s "$T/alerts.txt" ] && ok || bad "D4 success=false must not page before run 3"
drive
grep -q '|consolepagesdrift:unreadable|.*success=false.*10000.*Authentication error' "$T/alerts.txt" \
  && ok || bad "D4 success=false pages at run 3 with the CF error: $(cat "$T/alerts.txt")"
# production deployment with no commit hash
reset; body ""; drive; drive; drive
grep -q '|consolepagesdrift:unreadable|.*no usable commit hash' "$T/alerts.txt" \
  && ok || bad "D4 an empty production commit_hash pages at run 3 with its own reason: $(cat "$T/alerts.txt")"
# N=1 pages on run 1
reset; drive CURL_RC=7 CONSOLE_PAGES_DRIFT_UNREADABLE_N=1
grep -q '|consolepagesdrift:unreadable|' "$T/alerts.txt" && ok || bad "D4 CONSOLE_PAGES_DRIFT_UNREADABLE_N=1 must page on run 1: $(cat "$T/alerts.txt")"
# a good read afterwards resolves once
reset; printf '3\n' > "$UNR"; jq -n '{"consolepagesdrift:unreadable": 1}' > "$T/state/health-alerted.json"; body "$M"
drive
[ ! -f "$UNR" ] && ok || bad "D4 a good read must remove the counter"
[ "$(grep -c 'RESOLVED consolepagesdrift:unreadable' "$T/logs/ALERTS.log")" = 1 ] \
  && ok || bad "D4 exactly one RESOLVED consolepagesdrift:unreadable in ALERTS.log: $(cat "$T/logs/ALERTS.log") err=$(cat "$T/err.txt")"
grep -q 'RESOLVED consolepagesdrift:unreadable' "$T/logs/pipeline-health.log" \
  && ok || bad "D4 the resolve must reach pipeline-health.log: $(cat "$T/logs/pipeline-health.log")"
[ "$(jq -r 'has("consolepagesdrift:unreadable")' "$T/state/health-alerted.json")" = false ] \
  && ok || bad "D4 the resolve must clear the dedupe key"
# a good read after fewer than N failures never paged, so it must not resolve
reset; printf '1\n' > "$UNR"; drive
[ ! -f "$UNR" ] && ! grep -q RESOLVED "$T/logs/ALERTS.log" \
  && ok || bad "D4 a sub-threshold counter clears silently: $(cat "$T/logs/ALERTS.log")"

# ============================================================================
# D5 resolve the drift page: mark present + in sync
# ============================================================================
mkrepo 10800; reset; touch "$MARK"; jq -n '{"consolepagesdrift:hub": 1}' > "$T/state/health-alerted.json"; body "$M"
drive
[ ! -s "$T/alerts.txt" ] && ok || bad "D5 in sync must not page: $(cat "$T/alerts.txt")"
[ "$(grep -c 'RESOLVED consolepagesdrift:hub' "$T/logs/pipeline-health.log")" = 1 ] \
  && ok || bad "D5 exactly one RESOLVED line in pipeline-health.log: $(cat "$T/logs/pipeline-health.log") err=$(cat "$T/err.txt")"
grep -q 'RESOLVED consolepagesdrift:hub' "$T/logs/ALERTS.log" && ok || bad "D5 the resolve must reach ALERTS.log"
[ "$(jq -r 'has("consolepagesdrift:hub")' "$T/state/health-alerted.json")" = false ] \
  && ok || bad "D5 the resolve must clear the dedupe key"
# The block pages through alert() only, never lane-alert.sh (the BH-2314 E4
# ratchet), so there is no lane-alert id for the resolve to close.
[ ! -s "$T/lane.txt" ] && ok || bad "D5 the block must not call lane-alert.sh: $(cat "$T/lane.txt")"
grep -q '"resolved":true' "$T/beat.txt" && ok || bad "D5 a resolved:true beat: $(cat "$T/beat.txt")"
[ ! -f "$MARK" ] && ok || bad "D5 the mark must be removed"
: > "$T/logs/pipeline-health.log"; : > "$T/logs/ALERTS.log"; drive
! grep -q RESOLVED "$T/logs/pipeline-health.log" "$T/logs/ALERTS.log" \
  && ok || bad "D5 in sync with no mark must not RESOLVE again"

# ============================================================================
# D6 off switch: no Cloudflare call at all
# ============================================================================
mkrepo 10800; reset; body "$C1"; drive CONSOLE_PAGES_DRIFT_S=0
[ ! -s "$T/curl.calls" ] && ok || bad "D6 CONSOLE_PAGES_DRIFT_S=0 must not call curl: $(cat "$T/curl.calls")"
[ ! -s "$T/alerts.txt" ] && ok || bad "D6 off must not page"

# ============================================================================
# D7 Pages serves a sha the checkout never saw: behind, count "?"
# ============================================================================
mkrepo 10800; reset; body "0123456789abcdef0123456789abcdef01234567"; drive
[ "$(nalerts)" = 1 ] && grep -q '^3600|consolepagesdrift:hub|' "$T/alerts.txt" \
  && ok || bad "D7 an unknown deployed sha must page: $(cat "$T/alerts.txt") err=$(cat "$T/err.txt")"
grep -q '(? undeployed' "$T/alerts.txt" && ok || bad "D7 the count must be '?': $(cat "$T/alerts.txt")"

# ============================================================================
# D8 no token file / no console-ui: silent, no call
# ============================================================================
mkrepo 10800; reset; body "$C1"; rm -f "$T/env/cloudflare.env"; drive
[ ! -s "$T/curl.calls" ] && [ ! -s "$T/alerts.txt" ] && [ ! -f "$UNR" ] \
  && ok || bad "D8 no cloudflare.env must be silent: calls=$(cat "$T/curl.calls") alerts=$(cat "$T/alerts.txt")"
reset; body "$C1"; scratch_rm "$HCO/console-ui"; drive
[ ! -s "$T/curl.calls" ] && [ ! -s "$T/alerts.txt" ] && [ ! -f "$UNR" ] \
  && ok || bad "D8 a checkout without console-ui/ must be silent: calls=$(cat "$T/curl.calls")"
# the contract missing: one log line, no call, no page
mkrepo 10800; reset; body "$C1"; mv "$T/bin/lib/console-pages.sh" "$T/cp.bak"; drive
[ ! -s "$T/curl.calls" ] && [ ! -s "$T/alerts.txt" ] && grep -q 'console-pages.sh missing' "$T/logs/pipeline-health.log" \
  && ok || bad "D8 a missing contract lib must log and skip: $(cat "$T/logs/pipeline-health.log")"
mv "$T/cp.bak" "$T/bin/lib/console-pages.sh"

# ============================================================================
# D9 the token: only ever on curl's stdin
# ============================================================================
mkrepo 10800; reset; body "$C1"; drive
drive CURL_RC=7; drive CURL_RC=7; drive CURL_RC=7
jq -n '{success:false,errors:[{code:10000,message:"Authentication error"}]}' > "$T/body.json"; rm -f "$UNR"
drive CONSOLE_PAGES_DRIFT_UNREADABLE_N=1
LEAK=$(grep -rlF "$TOKEN" "$T/logs" "$T/state" "$T/alerts.txt" "$T/lane.txt" "$T/beat.txt" "$T/err.txt" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "D9 the token leaked into: $LEAK"
grep -qF "Authorization: Bearer $TOKEN" "$T/curl.stdin" && ok || bad "D9 the token must reach curl on stdin: $(cat "$T/curl.stdin")"
! grep -qF "$TOKEN" "$T/curl.calls" && ok || bad "D9 the token must not be in curl's argv"
grep -qF -- '-H @-' "$T/curl.calls" && ok || bad "D9 the header must be read from stdin: $(cat "$T/curl.calls")"
[ -s "$T/alerts.txt" ] && ok || bad "D9 the leak check needs the runs to have paged"

# ============================================================================
# D10 production, never preview
# ============================================================================
mkrepo 10800; reset; body "$M" preview "$C1"; drive
[ ! -s "$T/alerts.txt" ] && ok || bad "D10 a stale PREVIEW must not page while production is current: $(cat "$T/alerts.txt")"
reset; body null production "$C1"; drive
grep -q '|consolepagesdrift:hub|' "$T/alerts.txt" && ok || bad "D10 null canonical falls back to a production latest_deployment: $(cat "$T/alerts.txt") err=$(cat "$T/err.txt")"
reset; body null preview "$M"; drive
[ ! -s "$T/alerts.txt" ] && [ "$(cat "$UNR" 2>/dev/null)" = 1 ] \
  && ok || bad "D10 a preview-only answer is unreadable, never compared: alerts=$(cat "$T/alerts.txt") counter=$(cat "$UNR" 2>/dev/null)"

# ============================================================================
# D11 first-parent: judged strictly per rev-list --first-parent DEP..origin/main
#     -- console-ui, never by string-comparing a branch sha
# ============================================================================
# (a) Pages on the BRANCH commit, main changed console-ui on its own line too:
#     the merge and C2 are undeployed, so it pages.
mkrepo 10800 mainside; reset; body "$BR"; drive
PEND=$(git -C "$HCO" rev-list --first-parent "$BR..origin/main" -- console-ui)
[ -n "$PEND" ] && [ "$(nalerts)" = 1 ] && grep -q '|consolepagesdrift:hub|.*2 undeployed' "$T/alerts.txt" \
  && ok || bad "D11 Pages on the branch commit is behind main's merge: pend=$PEND alerts=$(cat "$T/alerts.txt") err=$(cat "$T/err.txt")"
grep -q '11h old' "$T/alerts.txt" && ok || bad "D11 the oldest undeployed is C2 (40000s = 11h): $(cat "$T/alerts.txt")"
reset; body "$M"; drive
[ ! -s "$T/alerts.txt" ] && ok || bad "D11 Pages on the merge is in sync: $(cat "$T/alerts.txt")"
# (b) Pages on the branch commit and main's merge brought nothing else into
#     console-ui: rev-list is empty (the merge is TREESAME to BR there), so the
#     same console-ui is deployed and nothing pages, even though BR != WANT.
mkrepo 10800; reset; body "$BR"; drive
PEND=$(git -C "$HCO" rev-list --first-parent "$BR..origin/main" -- console-ui)
[ "$BR" != "$M" ] && [ -z "$PEND" ] && [ ! -s "$T/alerts.txt" ] \
  && ok || bad "D11 an empty rev-list is in sync: pend=$PEND alerts=$(cat "$T/alerts.txt")"
# a short hash from Cloudflare resolves to the same commit
reset; body "${M:0:12}"; drive
[ ! -s "$T/alerts.txt" ] && [ ! -f "$UNR" ] && ok || bad "D11 a short production hash of WANT is in sync: $(cat "$T/alerts.txt")"

echo "pipeline-health-console-drift.bh-3554-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
