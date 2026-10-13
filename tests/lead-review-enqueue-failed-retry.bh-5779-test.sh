#!/bin/bash
# tests/lead-review-enqueue-failed-retry.bh-5779-test.sh — BH-5779: the
# `failed` rung and the stale-running reclaim of the hub trigger lane. The
# failure details are non-environment ones (`stale: ...`, which the worker's
# reclaim writes on a second stale run); environment failures are F4.
# "$DIR/bin/lead-review-enqueue.sh" runs WHOLE (`tick`) against a scratch
# harness carrying its real bin closure (scratch_install_closure). Stubbed:
#   * curl — the tests/lead-review-enqueue.bh-3545-test.sh STATEFUL jobs worker,
#            plus a status/detail on every lead row ($T/lrrows.json, setrow),
#            POST /api/lead-reviews/<id>/reset (409 on $T/reset409, else the
#            row goes back to requested) and POST /api/lead-reviews/reclaim-stale
#            ($T/reclaim.json, a 404 unknown endpoint on $T/reclaim404, else an
#            empty answer).
#   * gh   — the PR list, the head read, the compare and a healthy rate_limit.
#   * bin/lane-alert.sh, bin/agent-call.sh and bin/lead-verdict.sh — record argv.
#   F1  a recorded head whose row is failed: one reset with the lead token, a
#       failed-retry.tsv reset row, a second requested.tsv line, failed_reset=1.
#   F2  failed again: the second reset (2/2).
#   F3  failed a third time, two ticks: no third reset, ONE lead-failed alert
#       that says `failed 3 times` and names the reason; failed_alerted=1.
#   F4  an environment failure (empty, checkout, no-checkout, review-failed:
#       env:) while bin/lead-review-land.sh owns environment retries (its lane
#       registers LEAD_REVIEW_ENV_RETRY_MAX, BH-5793 / #5809): no reset and no
#       alert here, one [skip env-failed] line
#   F4b the same failures while the land lane does NOT own them (main before
#       #5809): reset here like any failure, within the same budget; a detail
#       that only starts with an environment word (`checkout: merge conflict`)
#       is a real failure either way
#   F5  the reset answers 409: no reset row, no ledger line, [skip reset-refused].
#   F6  LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=1 and two failed heads: one reset, one
#       [skip deferred].
#   F7  a head not in requested.tsv whose POST answers existing:true with a
#       failed row (a hand-made request): reset once.
#   F8  one POST /api/lead-reviews/reclaim-stale a tick, its reclaimed rows
#       logged; a 404 is one line and the tick still requests.
#   F9  LEAD_REVIEW_FAILED_RETRY_MAX=0: no reset, the first failure alerts.
#   F10 no secret and no planted token reaches the log or an alert.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-enqueue-failed-retry.bh-5779-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg"
# The stubs go first: scratch_install_closure never clobbers a file already there.
mkdir -p "$H/bin"
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/alerts"
exit 0
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/agent"
exit 0
EOF
cat > "$H/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/lv"
exit 0
EOF
chmod +x "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh" "$H/bin/lead-verdict.sh"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lead-review-enqueue.sh "$H" >/dev/null || exit 1
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$H/fleet.conf"

NOW=$(date +%s)
SHA=$(printf 'a%.0s' {1..40}); SHA12=${SHA:0:12}
S42=$(printf 'd%.0s' {1..40})
TOK1=ghs_FIXTUREFIXTUREFIXTURE12; TOK2=ghs_FIXTUREFIXTUREFIXTURE34

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/worker"
[ -f "$T/lrrows.json" ] || echo '[]' > "$T/lrrows.json"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
code=200; out='{}'
case "\$m \$p" in
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*)
    n=\$(qp pr)
    if [ -f "$T/standing/\$n" ]; then st=\$(cat "$T/standing/\$n"); else st=null; fi
    out=\$(jq -nc --argjson s "\$st" '{standing:\$s, rows:[], truncated:false}') ;;
  "GET /api/settings/"*)
    code=404; out='{"error":"no such setting"}' ;;
  "POST /api/lead-reviews/reclaim-stale")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    elif [ -e "$T/reclaim404" ]; then code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}'
    elif [ -f "$T/reclaim.json" ]; then out=\$(cat "$T/reclaim.json")
    else out='{"reclaimed":[],"deadline_s":3600,"as_of":"2026-10-09T00:00:00Z","truncated":false}'; fi ;;
  "POST /api/lead-reviews/"*"/reset")
    id="\${p#/api/lead-reviews/}"; id="\${id%/reset}"
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    elif [ -e "$T/reset409" ]; then code=409; out=\$(jq -nc --arg i "\$id" '{error:("lead review "+\$i+" is running; only a finished request can be reset")}')
    else
      jq -c --arg i "\$id" 'map(if .id == \$i then .status = "requested" | .detail = null | .reset_count = ((.reset_count // 0) + 1) else . end)' "$T/lrrows.json" > "$T/lrrows.tmp" && mv "$T/lrrows.tmp" "$T/lrrows.json"
      row=\$(jq -c --arg i "\$id" '[.[] | select(.id == \$i)] | first // empty' "$T/lrrows.json")
      if [ -n "\$row" ]; then out=\$(jq -c '{request:.}' <<<"\$row"); else code=404; out='{"error":"no such lead review"}'; fi
    fi ;;
  "POST /api/lead-reviews")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else
      r=\$(jq -r .repo <<<"\$body"); pr=\$(jq -r .pr <<<"\$body"); h=\$(jq -r .head_sha <<<"\$body"); nt=\$(jq -r '.scope_notes // ""' <<<"\$body")
      have=\$(jq -c --arg r "\$r" --argjson p "\$pr" --arg h "\$h" '[.[] | select(.repo == \$r and .pr == \$p and .head_sha == \$h)] | first // empty' "$T/lrrows.json")
      if [ -n "\$have" ]; then
        if [ "\$(jq -r '.scope_notes // ""' <<<"\$have")" = "\$nt" ]; then out=\$(jq -c '{request:., existing:true}' <<<"\$have")
        else code=409; out=\$(jq -c '{error:"a request for this head exists with other notes", request:.}' <<<"\$have"); fi
      else
        n=\$(jq length "$T/lrrows.json")
        row=\$(jq -c --arg id "lr-\$((n + 1))" '. + {id:\$id, status:"requested"}' <<<"\$body")
        jq -c --argjson r "\$row" '. + [\$r]' "$T/lrrows.json" > "$T/lrrows.tmp" && mv "$T/lrrows.tmp" "$T/lrrows.json"
        code=201; out=\$(jq -c '{request:.}' <<<"\$row")
      fi
    fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/demo-os/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json" ;;
  *"-X GET repos/example-org/demo-os/pulls/"*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%% *}"
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/head/\$n")" '{head:{sha:\$s},base:{ref:"main"},user:{login:"cromford[bot]"}}' ;;
  *"-X GET repos/example-org/demo-os/compare/"*)
    printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"feat: the thing"}}]}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" \
  FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LEAD_REVIEW_AUTO_REPOS=example-org/demo-os \
  LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 REPOS_ROOT="$T/norepos"
unset BOX_NAME JOBS_BOX HUB_BOX_NAME LEAD_REVIEW_FAILED_RETRY_MAX LEAD_REVIEW_REQUIRE_BUILDER_APPROVE

pr() {
  jq -c --argjson n "$1" --arg h "$2" '. + [{number:$n, html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)),
    title:"t", draft:false, state:"open", user:{login:"cromford[bot]",type:"Bot"}, head:{sha:$h,ref:("ticket/bh-"+($n|tostring))}, base:{ref:"main"}}]' \
    "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  echo "$2" > "$T/head/$1"
}
approve() {
  jq -nc --arg s "$2" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", headbound:"n/a", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/$1.json"
}
# setrow <id> <status> <detail> — the owning box finished the row that way
setrow() {
  jq -c --arg i "$1" --arg s "$2" --arg d "$3" 'map(if .id == $i then .status = $s | .detail = $d else . end)' "$T/lrrows.json" > "$T/lrrows.tmp" \
    && mv "$T/lrrows.tmp" "$T/lrrows.json"
}
rowstatus() { jq -r --arg i "$1" '.[] | select(.id == $i) | .status' "$T/lrrows.json" 2>/dev/null; }
reset() {
  rm -f "$T/log"/* "$T"/{lrrows.json,reset409,reclaim404,reclaim.json} "$H/logs"/*
  scratch_rm "$H/state"; mkdir -p "$H/state"
  for d in jv standing head; do scratch_rm "$T/$d"; mkdir -p "$T/$d"; done
  echo box-hub > "$H/state/box-name"
  echo '[]' > "$T/prs.json"
}
happy() { reset; pr 41 "$SHA"; approve 41 "$SHA"; }
tick() { ( cd "$T" && bash "$H/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?; }
LOGF="$H/logs/lead-review-enqueue.log"
wlog() { cat "$T/log/worker" 2>/dev/null; }
posts() { wlog | grep -c '^POST /api/lead-reviews ' ; }
resets() { wlog | grep -c "^POST /api/lead-reviews/${1:-[^ ]*}/reset .* lead=1\$"; }
summ() { grep ' tick repos=' "$LOGF" 2>/dev/null | tail -1; }
has() { summ | grep -qw -- "$1"; }
alines() { cat "$T/log/alerts" 2>/dev/null; }
acount() { alines | grep -c -- "$1"; }
ST="$H/state/lead-review-enqueue"
LEDGER="$ST/requested.tsv"; FR="$ST/failed-retry.tsv"
nlines() { [ -f "$1" ] || { echo 0; return; }; grep -c -- "${2:-.}" "$1"; }
ALID="lead-failed-example-org_demo-os-41-$SHA12"
# first: one tick that requests #41 (lr-1) and records it
first() { happy; tick; rm -f "$T/log/worker"; }

# ── F1 (red): a recorded head whose row came back failed -> one reset ──
first; setrow lr-1 failed "stale: no heartbeat x"; tick
[ "$RC" -eq 0 ] && ok || bad "F1 rc=$RC out=$(cat "$T/out")"
[ "$(resets lr-1)" = 1 ] && ok || bad "F1 want one lead-token reset of lr-1, got $(resets lr-1): $(wlog)"
[ "$(rowstatus lr-1)" = requested ] && ok || bad "F1 the row is $(rowstatus lr-1), want requested"
[ "$(nlines "$FR" '	reset	')" = 1 ] && ok || bad "F1 failed-retry.tsv: $(cat "$FR" 2>/dev/null)"
[ "$(nlines "$LEDGER" "	$SHA	")" = 2 ] && ok || bad "F1 requested.tsv want 2 lines for the head: $(cat "$LEDGER" 2>/dev/null)"
has failed_reset=1 && ok || bad "F1 summary: $(summ)"
grep -q 'reset 1/2' <<<"$(grep "#41 @$SHA12" "$LOGF" 2>/dev/null | grep -F 'stale: no heartbeat x')" && ok || bad "F1 no reset line naming #41, the head and the reason: $(cat "$LOGF" 2>/dev/null)"

# ── F2 (red): failed again -> the second reset ──
rm -f "$T/log/worker"; setrow lr-1 failed "stale: no heartbeat y"; tick
[ "$(resets lr-1)" = 1 ] && ok || bad "F2 want the second reset, got $(resets lr-1)"
[ "$(nlines "$FR" '	reset	')" = 2 ] && ok || bad "F2 failed-retry.tsv: $(cat "$FR" 2>/dev/null)"
grep -q 'reset 2/2' <<<"$(grep "#41 @$SHA12" "$LOGF")" && ok || bad "F2 no 2/2 line"

# ── F3 (red): failed a third time, two ticks -> no reset, one alert ──
rm -f "$T/log/worker"; setrow lr-1 failed "stale: no heartbeat z"; tick
has failed_alerted=1 && ok || bad "F3 tick 1 summary: $(summ)"
tick
[ "$(resets)" = 0 ] && ok || bad "F3 a third reset was sent: $(wlog)"
[ "$(rowstatus lr-1)" = failed ] && ok || bad "F3 the row is $(rowstatus lr-1), want failed"
[ "$(acount "--id $ALID ")" = 1 ] && ok || bad "F3 want exactly one $ALID alert over two ticks: $(alines)"
grep -q 'failed 3 times' <<<"$(alines | grep -- "$ALID")" && ok || bad "F3 the alert lacks 'failed 3 times': $(alines)"
grep -qF 'stale: no heartbeat z' <<<"$(alines | grep -- "$ALID")" && ok || bad "F3 the alert lacks the reason: $(alines)"
grep -q -- '--severity warn' <<<"$(alines | grep -- "$ALID")" && ok || bad "F3 the alert is not warn"
has failed_alerted=1 && ok || bad "F3 tick 2 summary: $(summ)"
grep -q '\[skip failed-exhausted\]' <<<"$(grep "#41 @$SHA12" "$LOGF")" && ok || bad "F3 no [skip failed-exhausted] line"
[ "$(nlines "$FR" '	alerted	')" = 1 ] && ok || bad "F3 failed-retry.tsv alerted rows: $(cat "$FR")"

# ── F4: an environment failure is the land lane's (BH-5793, #5809) ──
# TEST-CHANGE (Mac takeover of the stalled pool build): F4 asserted that the
# enqueue alerts on detail `empty`. #5809's bin/lead-review-land.sh now requeues
# every environment failure (checkout, no-checkout, empty, review-failed:
# env:), so the enqueue neither resets nor alerts on them: one skip line. Only
# while the land lane owns them (lead review of abc4e89a): its lane file
# registers LEAD_REVIEW_ENV_RETRY_MAX.
LANDJ="$H/catalog/lanes.d/lead-review-land.json"
land_owns() { mkdir -p "${LANDJ%/*}"; printf '{"lane":"lead-review-land","knobs":[{"env":"LEAD_REVIEW_ENV_RETRY_MAX","type":"int","default":3}]}\n' > "$LANDJ"; }
land_plain() { mkdir -p "${LANDJ%/*}"; printf '{"lane":"lead-review-land","knobs":[{"env":"LEAD_REVIEW_OVERDUE_MIN","type":"int","default":120}]}\n' > "$LANDJ"; }
land_owns
for envd in empty checkout no-checkout "review-failed: env: repo setup failed"; do
  first; setrow lr-1 failed "$envd"; tick; tick
  [ "$(resets)" = 0 ] && ok || bad "F4 an environment failure ($envd) was reset here: $(wlog)"
  [ "$(acount "--id $ALID ")" = 0 ] && ok || bad "F4 an environment failure ($envd) alerted here: $(alines)"
  grep -q '\[skip env-failed\]' <<<"$(grep "#41 @$SHA12" "$LOGF")" && ok || bad "F4 no [skip env-failed] line for $envd: $(tail -3 "$LOGF")"
done

# ── F4b: no land-lane owner -> an environment failure is reset here ──
for own in plain absent; do
  for envd in empty checkout "review-failed: env: repo setup failed"; do
    if [ "$own" = plain ]; then land_plain; else rm -f "$LANDJ"; fi
    first; setrow lr-1 failed "$envd"; tick
    [ "$(resets lr-1)" = 1 ] && ok || bad "F4b ($own) an environment failure ($envd) with no land-lane owner is not reset: $(wlog)"
    grep -q '\[skip env-failed\]' <<<"$(grep "#41 @$SHA12" "$LOGF")" && bad "F4b ($own) $envd still skipped as env-failed" || ok
    grep -q 'reset 1/2' <<<"$(grep "#41 @$SHA12" "$LOGF")" && ok || bad "F4b ($own) $envd: no reset 1/2 line: $(tail -3 "$LOGF")"
  done
done
# Budget: the same cap as any failure. Two resets, then one alert.
land_plain; first
for envd in empty empty empty; do rm -f "$T/log/worker"; setrow lr-1 failed "$envd"; tick; done
[ "$(nlines "$FR" '	reset	')" = 2 ] && ok || bad "F4b an environment failure is reset at most LEAD_REVIEW_FAILED_RETRY_MAX times: $(cat "$FR" 2>/dev/null)"
[ "$(acount "--id $ALID ")" = 1 ] && ok || bad "F4b the third environment failure alerts once: $(alines)"
# The land lane's exact shapes: `checkout: merge conflict` is a real failure
# even when the land lane owns environment retries.
land_owns; first; setrow lr-1 failed "checkout: merge conflict"; tick
[ "$(resets lr-1)" = 1 ] && ok || bad "F4b 'checkout: merge conflict' is not an environment failure; want a reset: $(wlog)"
land_owns

# ── F5: the reset answers 409 -> nothing spent, one reset-refused line ──
first; setrow lr-1 failed "stale: no heartbeat x"; : > "$T/reset409"; tick
[ "$(resets lr-1)" = 1 ] && ok || bad "F5 want the one refused reset POST, got $(resets lr-1)"
[ "$(nlines "$FR" '	reset	')" = 0 ] && ok || bad "F5 a refused reset spent budget: $(cat "$FR")"
[ "$(nlines "$LEDGER" "	$SHA	")" = 1 ] && ok || bad "F5 a refused reset wrote a ledger line: $(cat "$LEDGER")"
[ "$(grep -c "#41 @$SHA12.*\[skip reset-refused\]" "$LOGF")" = 1 ] && ok || bad "F5 want one [skip reset-refused] line: $(cat "$LOGF")"
has failed_reset=0 && ok || bad "F5 summary: $(summ)"

# ── F6: cap 1, two failed heads -> one reset, one deferred ──
happy; pr 42 "$S42"; approve 42 "$S42"; tick; rm -f "$T/log/worker"
setrow lr-1 failed "stale: no heartbeat x"; setrow lr-2 failed "stale: no heartbeat x"
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=1 tick
[ "$(resets)" = 1 ] && ok || bad "F6 want exactly one reset under cap 1, got $(resets): $(wlog)"
[ "$(grep -c '\[skip deferred\]' "$LOGF")" = 1 ] && ok || bad "F6 want one [skip deferred] line: $(cat "$LOGF")"
has failed_reset=1 && has deferred=1 && ok || bad "F6 summary: $(summ)"

# ── F7 (red): not in requested.tsv, POST answers existing with a failed row ──
happy
jq -nc --arg h "$SHA" --arg n "auto: builder APPROVE on $SHA12" '[{id:"lr-1", repo:"example-org/demo-os", pr:41, head_sha:$h,
  scope_notes:$n, requested_by:"lead-verdict:mac", status:"failed", detail:"stale: no heartbeat hand"}]' > "$T/lrrows.json"
tick
[ "$(resets lr-1)" = 1 ] && ok || bad "F7 want one reset of the hand-made failed row, got $(resets lr-1): $(wlog)"
[ "$(rowstatus lr-1)" = requested ] && ok || bad "F7 the row is $(rowstatus lr-1)"
has failed_reset=1 && ok || bad "F7 summary: $(summ)"

# ── F8 (red): one reclaim-stale POST a tick; rows logged; a 404 is fail-open ──
happy
jq -nc --arg h "$S42" '{reclaimed:[{id:"lr-9", repo:"example-org/demo-os", pr:42, head_sha:$h, to:"requested",
  last_beat:"2026-10-09T01:00:00Z", job_id:"job-9"}], deadline_s:3600, as_of:"2026-10-09T03:00:00Z", truncated:false}' > "$T/reclaim.json"
tick
[ "$(wlog | grep -c '^POST /api/lead-reviews/reclaim-stale .* lead=1$')" = 1 ] && ok || bad "F8 want one lead-token reclaim-stale POST: $(wlog)"
grep -q 'reclaimed to requested' <<<"$(grep 'example-org/demo-os#42' "$LOGF" | grep -F "${S42:0:12}")" && ok || bad "F8 no reclaim line: $(cat "$LOGF")"
has reclaimed=1 && ok || bad "F8 summary: $(summ)"
happy; : > "$T/reclaim404"; tick
[ "$(wlog | grep -c '^POST /api/lead-reviews/reclaim-stale ')" = 1 ] && ok || bad "F8 404: want one reclaim POST: $(wlog)"
[ "$(grep -c 'reclaim-stale not answered (HTTP 404)' "$LOGF")" = 1 ] && ok || bad "F8 no 404 line: $(cat "$LOGF")"
[ "$(posts)" = 1 ] && has requested=1 && ok || bad "F8 a 404 stopped the tick: posts=$(posts) $(summ)"
has reclaimed=0 && ok || bad "F8 404 summary: $(summ)"

# ── F9: LEAD_REVIEW_FAILED_RETRY_MAX=0 -> no reset, the first failure alerts ──
first; setrow lr-1 failed "stale: no heartbeat x"; LEAD_REVIEW_FAILED_RETRY_MAX=0 tick
[ "$(resets)" = 0 ] && ok || bad "F9 reset at max 0: $(wlog)"
[ "$(acount "--id $ALID ")" = 1 ] && ok || bad "F9 want one alert: $(alines)"
has failed_alerted=1 && ok || bad "F9 summary: $(summ)"

# ── F10: secrets and planted tokens never reach the log or an alert ──
LEAK="clone https://x:$TOK2@github.com/example-org/demo-os.git failed; token $TOK1"
first; setrow lr-1 failed "$LEAK"; tick
[ "$(resets lr-1)" = 1 ] && ok || bad "F10 the reset did not run: $(wlog)"
first; setrow lr-1 failed "$LEAK"; LEAD_REVIEW_FAILED_RETRY_MAX=0 tick
[ "$(acount "--id $ALID ")" = 1 ] && ok || bad "F10 no alert to check: $(alines)"
for s in test-secret lead-test-token ghs_FIXTURE; do
  grep -q -- "$s" "$LOGF" && bad "F10 $s reached the log: $(grep -- "$s" "$LOGF")" || ok
  grep -q -- "$s" <<<"$(alines)" && bad "F10 $s reached an alert: $(alines)" || ok
done
grep -qF '://***@' "$LOGF" && ok || bad "F10 the URL credential was not masked in the log: $(cat "$LOGF")"

[ -s "$T/log/agent" ] && bad "agent-call.sh ran: $(cat "$T/log/agent")" || ok
echo "lead-review-enqueue-failed-retry.bh-5779: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
