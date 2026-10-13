#!/bin/bash
# tests/prebuild-repro-self-comment.bh-2133-test.sh — the repro gate never pays
# twice for its own comment (BH-2133, blocker for #2040).
#
# THE LOOP THIS PINS. The repro_gate ledger key ends in thread_fp, and thread_fp
# counted the harness's OWN stop comment. On a GitHub-Issues board there is no
# turn flip, so the pool re-offered the stop's BUILD_DEFERRED; the fingerprint
# was new, the ledger missed, the drive paid again (up to $3) and the stop posted
# again. The fix: harness comments (normalized `harness: true`, or the stop's own
# `<!-- harness:repro-stop … -->` marker) are left out of thread_fp.
#
# Also pinned, from the ticket's metered and hygiene items:
#   M1 a failed ledger write after a paid drive raises an ALERT and keeps a
#      local record; the next offer on this box reuses it and pays nothing.
#   M2 a fresh claim on the thread (another build is driving it) means no spend;
#      the claim is written BEFORE the call and released after it.
#   M3 AGENT_CALL_LANE and the budget variable survive the project env load.
#   H1 GitHub markdown: model-supplied steps/observed are escaped (no live
#      @-mention, image or link) and the URL is a code span.
#   H2 in-app HTML: the origin-checked URL is a real link; a non-http URL is not.
#   H3 a post that was delivered but not confirmed is not posted again.
#
# Everything runs the SHIPPED runner (bin/prebuild-repro.sh) and the shipped
# drive and stop stages; only the thread fetch (not wired until #2040), the
# model call, the ledger store, prod-url, gh and curl are stubbed.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prebuild-repro-self-comment.bh-2133-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

REG="$T/lanes.json"
bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 \
  || bad "setup: bin/lanes-build.sh --to could not compose the registry"
export LANE_REGISTRY="$REG" LANE_GATE_NOW=""
unset QA_CLERK_SECRET_KEY QA_TEST_USER_ID LLM_LANE_ENABLED REPRO_GATE_MAX_USD HARNESS_ENV_DIR \
      AGENT_CALL_BUDGET_USD_REPRO AGENT_CALL_LANE 2>/dev/null
TOKEN="tok-fixture-SECRET-2133"; export TOKEN

# mkh <name> — a scratch HARNESS: shipped runner + stages, stubs around them.
mkh() {
  local h="$T/$1"
  mkdir -p "$h/bin/lib" "$h/logs" "$h/state" "$h/flags" "$h/env" "$h/ledger" "$h/calls" "$h/fakebin" "$h/locks"
  cp -p "$DIR/bin/prebuild-repro.sh" "$DIR/bin/kind-gate.sh" "$h/bin/"
  cp -p "$DIR/bin/lib/prebuild-repro.sh" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/gh-rest.sh" \
        "$DIR/bin/lib/harness-self.sh" "$h/bin/lib/"
  cp -rp "$DIR/bin/lib/prebuild-repro" "$h/bin/lib/"
  printf '%s\n' 'pr_fetch_thread() { printf "%s" "$THREAD_JSON"; }' > "$h/bin/lib/prebuild-repro/thread.sh"
  printf 'QA_CLERK_SECRET_KEY=sk_test_fake\nQA_TEST_USER_ID=user_fake\n' > "$h/env/p.env"
  printf '%s\n' "${GLOBAL_ENV:-}" > "$h/env/global.env"
  printf '#!/bin/bash\necho https://app.example\n' > "$h/bin/prod-url.sh"
  printf '#!/bin/bash\necho "$TOKEN"\n' > "$h/bin/internal-token-for.sh"
  cat > "$h/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${BOARD:-gh}:$2" in
  app:prod) echo https://app.example ;; app:board_prefix) echo /api/board ;; app:repo) echo acme/app ;;
  gh:prod) echo - ;; gh:board_prefix) echo - ;; gh:repo) echo acme/widgets ;;
  *) exit 1 ;;
esac
SH
  cat > "$h/bin/lib/lane-model.sh" <<'SH'
lane_role_model() { echo stub-model; }
SH
  # The model call: counts calls, writes one cost row per call (what agent-call.sh
  # bills), and a NOT_REPRODUCED final block on the prod origin.
  cat > "$h/bin/agent-call.sh" <<'SH'
#!/bin/bash
H="$HARNESS"; n=$(( $(cat "$H/calls/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$H/calls/count"
echo "call $n" >> "$H/order.log"
echo "cost lane=${AGENT_CALL_LANE-} usd=1.10" >> "$H/logs/cost.rows"
printf '%s|%s' "${AGENT_CALL_LANE-UNSET}" "${AGENT_CALL_BUDGET_USD_REPRO-UNSET}" > "$H/calls/$n.env"
printf 'Looked.\nREPRO_VERDICT: %s\nREPRO_ROLE: account manager\nREPRO_URL: %s\nREPRO_STEPS: %s\nREPRO_OBSERVED: %s\n' \
  "${VERDICT:-NOT_REPRODUCED}" "${URL:-https://app.example/clients/77}" "${STEPS:-opened the client; read the totals row}" \
  "${OBSERVED:-Totals row read 1,240.00, matching the three invoices}" > "$5"
printf '{"total_cost_usd":1.10}' > "$5.json"
exit 0
SH
  # One ledger store, two faces: sourced (drive: job_ledger_* + _jobs_req) and
  # executed (stop: ledger-get / ledger-put). PUT_FAIL is a regex on kind:status.
  cat > "$h/bin/jobs-client.sh" <<'SH'
_led() { printf '%s' "$1/$2" | sha256sum | cut -c1-16; }
job_ledger_get() {
  echo "get $1 $2" >> "$HARNESS/order.log"
  [ -n "${LEDGER_GET_RC:-}" ] && return "$LEDGER_GET_RC"
  local f="$HARNESS/ledger/$(_led "$1" "$2")"
  [ -f "$f.status" ] || return 2
  cat "$f.status"
}
job_ledger_put() {
  echo "put $1 $2 $3" >> "$HARNESS/order.log"
  if [ -n "${PUT_FAIL:-}" ] && [[ "$1:$3" =~ $PUT_FAIL ]]; then return 1; fi
  local f="$HARNESS/ledger/$(_led "$1" "$2")"
  printf '%s' "$3" > "$f.status"; [ -n "${4:-}" ] && printf '%s' "$4" > "$f.detail"
  return 0
}
_jobs_req() {
  local q="${2#*\?}" k v kind="" key=""
  for kv in ${q//&/ }; do k="${kv%%=*}"; v="${kv#*=}"; v=$(printf '%b' "${v//%/\\x}")
    case "$k" in kind) kind="$v" ;; key) key="$v" ;; esac; done
  local f="$HARNESS/ledger/$(_led "$kind" "$key")"
  [ -f "$f.status" ] || return 2
  jq -nc --arg s "$(cat "$f.status")" --arg d "$(cat "$f.detail" 2>/dev/null)" '{ledger:{status:$s,detail:$d}}'
}
[ "${BASH_SOURCE[0]}" != "$0" ] && return 0
case "$1" in
  ledger-get) job_ledger_get "$2" "$3"; rc=$?; echo; exit $rc ;;
  ledger-put) job_ledger_put "$2" "$3" "$4" "${5:-}"; exit $? ;;
esac
exit 1
SH
  # gh: POST .../comments appends to the issue's comment store; GET lists it.
  # GH_MODE=lost stores the comment and answers 500 (delivered, not confirmed).
  cat > "$h/fakebin/gh" <<SH
#!/bin/bash
H="$h"
echo "\$*" >> "\$H/gh.log"
m=GET; p=""; bodyf=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    api|-i) ;;
    -X) m="\$2"; shift ;;
    -F|-f) case "\$2" in body=@*) bodyf="\${2#body=@}" ;; esac; shift ;;
    -H) shift ;;
    *) [ -z "\$p" ] && p="\$1" ;;
  esac
  shift
done
store="\$H/issue-comments.json"; [ -f "\$store" ] || echo '[]' > "\$store"
if [ "\$m" = POST ]; then
  echo "POST \$p" >> "\$H/posts.log"
  n=\$(jq length "\$store"); id=\$((900 + n))
  jq -c --argjson id "\$id" --rawfile b "\$bodyf" '. + [{id:\$id, body:\$b, user:{login:"cromford-board[bot]",type:"Bot"}, created_at:"2026-09-24T20:00:00Z"}]' "\$store" > "\$store.t" && mv "\$store.t" "\$store"
  cp "\$bodyf" "\$H/gh-body.\$id"
  if [ "\${GH_MODE:-ok}" = ok ]; then printf 'HTTP/1.1 201 Created\r\n\r\n{"id":%s}\n' "\$id"; exit 0; fi
  printf 'HTTP/1.1 500 Internal Server Error\r\n\r\n{"message":"boom"}\n'; exit 1
fi
printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "\$store"; echo
SH
  # curl (in-app board): POST .../comments stores, GET .../tickets/42 lists.
  # CURL_MODE=lost stores the comment and answers an HTML 500.
  cat > "$h/fakebin/curl" <<SH
#!/bin/bash
H="$h"
url=""; body=""; m=GET
while [ \$# -gt 0 ]; do
  case "\$1" in -d) body="\$2"; m=POST; shift ;; -X) m="\$2"; shift ;; -H|--max-time|-m|-o) shift ;; http*) url="\$1" ;; esac
  shift
done
store="\$H/app-comments.json"; [ -f "\$store" ] || echo '[]' > "\$store"
echo "\$m \$url" >> "\$H/curl.log"
case "\$m:\$url" in
  POST:*/comments)
    echo "POST \$url" >> "\$H/posts.log"
    printf '%s' "\$body" > "\$H/curl-body.\$(jq length "\$store")"
    jq -c --arg b "\$(printf '%s' "\$body" | jq -r .body)" '. + [{id:"a\(length)", body:\$b, isInternal:true}]' "\$store" > "\$store.t" && mv "\$store.t" "\$store"
    [ "\${CURL_MODE:-ok}" = ok ] && printf '{"comment":{"id":"c9"}}' || printf '<html>500</html>' ;;
  POST:*/turn) printf '{"ok":true}' ;;
  GET:*/tickets/42) jq -c '{ticket:{id:"42"}, comments:.}' "\$store" ;;
  *) printf '<html>404</html>' ;;
esac
SH
  chmod +x "$h/bin/"*.sh "$h/fakebin/"*
  printf '%s' "$h"
}
meta() { mkdir -p "$1"; printf '{"title":"Totals are wrong","labels":[{"name":"bug"}],"body":""}\n' > "$1/ticket-meta.json"; }
run() { meta "$2"; PATH="$1/fakebin:$PATH" HARNESS="$1" bash "$1/bin/prebuild-repro.sh" p 42 BH-7 "$2" > "$2/runner.out" 2>&1; RC=$?; }
calls() { cat "$1/calls/count" 2>/dev/null || echo 0; }
posts() { grep -c '^POST .*/comments$' "$1/posts.log" 2>/dev/null || true; }
costs() { grep -c '^cost ' "$1/logs/cost.rows" 2>/dev/null || true; }
rline() { sed -n "s/^$2: //p" "$1/prebuild-repro.txt" 2>/dev/null; }
lkey()  { ( export HARNESS="$1"; . "$1/bin/lib/prebuild-repro.sh"; pr_ledger_key p BH-7 "$2" ); }
lstat() { cat "$1/ledger/$(printf '%s' "repro_gate/$(lkey "$1" "$2")" | sha256sum | cut -c1-16).status" 2>/dev/null; }
# with_comment <thread> <id> <createdAt> <body> <principal> [harness] [author] — the thread plus one comment.
with_comment() {
  jq -c --arg id "$2" --arg at "$3" --arg b "$4" --argjson pr "$5" --arg hz "${6:-}" --arg au "${7:-}" \
    '.comments += [{id:$id, createdAt:$at, body:$b, principal:$pr}
                   + (if $hz == "" then {} else {harness: ($hz == "true")} end)
                   + (if $au == "" then {} else {author: $au} end)]' <<<"$1"
}
export THREAD_JSON
TH='{"source":"gh","truncated":false,"body":"Totals are wrong on the client page","body_principal":false,"comments":[{"id":"c1","createdAt":"2026-09-20T00:00:00Z","body":"still wrong","principal":false}]}'

# ═══════════════════════════════════════════════════════════════════════════
# S1 — THE TICKET'S TEST. The stop comment lands; the ticket is re-offered with
# no human reply; 0 new drives, 0 new comments, 0 new cost rows.
# ═══════════════════════════════════════════════════════════════════════════
H=$(mkh s1); B="$T/s1a"
THREAD_JSON="$TH" run "$H" "$B"
[ "$RC" = 10 ] && [ "$(calls "$H")" = 1 ] && [ "$(posts "$H")" = 1 ] && [ "$(costs "$H")" = 1 ] && ok \
  || bad "S1 first offer: rc $RC calls $(calls "$H") posts $(posts "$H") costs $(costs "$H") ($(tr '\n' '|' < "$B/runner.out"))"
STOP_BODY=$(jq -r '.[-1].body' "$H/issue-comments.json" 2>/dev/null)
# (a) the fetcher flags the harness's own comment (#2040: a Bot on GitHub).
THA=$(with_comment "$TH" 900 2026-09-24T20:00:00Z "$STOP_BODY" true true)
B="$T/s1b"; THREAD_JSON="$THA" run "$H" "$B"
[ "$RC" = 10 ] && ok || bad "S1a re-offer: rc $RC, not 10 ($(tr '\n' '|' < "$B/runner.out"))"
[ "$(calls "$H")" = 1 ] && ok || bad "S1a: $(( $(calls "$H") - 1 )) new drive(s) on our own comment"
[ "$(posts "$H")" = 1 ] && ok || bad "S1a: $(( $(posts "$H") - 1 )) new comment(s) on our own comment"
[ "$(costs "$H")" = 1 ] && ok || bad "S1a: $(( $(costs "$H") - 1 )) new cost row(s) on our own comment"
[ "$(lkey "$H" "$THA")" = "$(lkey "$H" "$TH")" ] && ok || bad "S1a: the harness comment moved the ledger key"
# (b) no `harness` flag, but the stop's own marker AND an author that is one of
# the harness Apps (HARNESS_SELF_APPS): kept out of the key.
THB=$(with_comment "$TH" 900 2026-09-24T20:00:00Z "$STOP_BODY" true "" "cromford-board[bot]")
B="$T/s1c"; THREAD_JSON="$THB" run "$H" "$B"
[ "$RC" = 10 ] && [ "$(calls "$H")" = 1 ] && [ "$(posts "$H")" = 1 ] && [ "$(costs "$H")" = 1 ] && ok \
  || bad "S1b marker + App author: rc $RC calls $(calls "$H") posts $(posts "$H") costs $(costs "$H")"
grep -q '<!-- harness:repro-stop ' <<<"$STOP_BODY" && ok || bad "S1b: the stop comment carries no harness marker"
# (c) N2 (review of #2208): the marker ALONE is not enough. A client who quotes
# our comment back carries the marker in their own words, and a PAT-posted stop
# (author operator) cannot be told from the operator: both MOVE the key.
THQ=$(with_comment "$TH" c9 2026-09-24T20:30:00Z "> $STOP_BODY
Here are my steps, it is still wrong" false "" "acme-client")
[ "$(lkey "$H" "$THQ")" != "$(lkey "$H" "$TH")" ] && ok || bad "S1c N2: a client reply quoting the marker was dropped from the key"
THP=$(with_comment "$TH" c9 2026-09-24T20:30:00Z "$STOP_BODY" true "" "operator")
[ "$(lkey "$H" "$THP")" != "$(lkey "$H" "$TH")" ] && ok || bad "S1c N2: a marker under the PAT login was dropped from the key"
THI=$(with_comment "$TH" c9 2026-09-24T20:30:00Z "$STOP_BODY" false "" "intercom[bot]")
[ "$(lkey "$H" "$THI")" != "$(lkey "$H" "$TH")" ] && ok || bad "S1c N2: a marker under a third-party bot was dropped from the key"

# S2 — a human reply after the stop moves the key: exactly one more drive.
THC=$(with_comment "$THA" c3 2026-09-24T21:00:00Z "here is a screenshot, it is still wrong" false)
B="$T/s2"; THREAD_JSON="$THC" run "$H" "$B"
[ "$(calls "$H")" = 2 ] && ok || bad "S2: a human reply bought $(( $(calls "$H") - 1 )) drives, want exactly 1"
# S3 — a principal's own comment (not the harness) also moves the key.
THD=$(with_comment "$TH" c4 2026-09-24T21:00:00Z "please look at the March invoices" true false)
[ "$(lkey "$H" "$THD")" != "$(lkey "$H" "$TH")" ] && ok || bad "S3: a principal comment did not move the key"
# S4 — a harness-flagged comment that is NOT the stop is excluded too (a triage note).
THE=$(with_comment "$TH" c5 2026-09-24T21:00:00Z "Still blocked, nothing edited." true true)
[ "$(lkey "$H" "$THE")" = "$(lkey "$H" "$TH")" ] && ok || bad "S4: a harness triage note moved the key"

# ═══════════════════════════════════════════════════════════════════════════
# M1 — a failed ledger write after a paid drive: ALERT + local record, no re-pay.
# ═══════════════════════════════════════════════════════════════════════════
H=$(mkh m1); B="$T/m1a"
THREAD_JSON="$TH" VERDICT=REPRODUCED PUT_FAIL='^repro_gate:reproduced$' run "$H" "$B"
[ "$(calls "$H")" = 1 ] && [ "$RC" = 0 ] && ok || bad "M1: first offer rc $RC calls $(calls "$H")"
grep -q 'prebuild-repro: BH-7 drive ledger put' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "M1: no ALERT for the failed post-spend put: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ -n "$(ls "$H/state/repro-gate/" 2>/dev/null)" ] && ok || bad "M1: no local fallback record under state/repro-gate/"
B="$T/m1b"; THREAD_JSON="$TH" VERDICT=REPRODUCED run "$H" "$B"
[ "$(calls "$H")" = 1 ] && [ "$(costs "$H")" = 1 ] && ok || bad "M1: the next offer paid again (calls $(calls "$H"), costs $(costs "$H"))"
[ "$(rline "$B" REPRO_GATE)" = reproduced ] && ok || bad "M1: reuse verdict '$(rline "$B" REPRO_GATE)'"

# ═══════════════════════════════════════════════════════════════════════════
# M2 — claim before spend.
# ═══════════════════════════════════════════════════════════════════════════
claim() { # claim <harness> <thread> <status>
  ( export HARNESS="$1"; . "$1/bin/jobs-client.sh"; job_ledger_put repro_gate_claim "$(lkey "$1" "$2")" "$3" ) >/dev/null
}
H=$(mkh m2); B="$T/m2a"
claim "$H" "$TH" "driving:$(date +%s)"
THREAD_JSON="$TH" run "$H" "$B"
[ "$(calls "$H")" = 0 ] && ok || bad "M2: paid while another build holds a fresh claim"
[ "$(rline "$B" REPRO_REASON)" = drive-in-flight ] && [ "$RC" = 0 ] && ok || bad "M2: reason '$(rline "$B" REPRO_REASON)' rc $RC"
H=$(mkh m2s); B="$T/m2s"
claim "$H" "$TH" "driving:$(( $(date +%s) - 7200 ))"
: > "$H/order.log"   # the seeded stale claim is not the drive's own claim
THREAD_JSON="$TH" run "$H" "$B"
[ "$(calls "$H")" = 1 ] && ok || bad "M2: a stale claim blocked the drive"
cp=$(grep -n '^put repro_gate_claim .* driving:' "$H/order.log" | tail -1 | cut -d: -f1)
cc=$(grep -n '^call ' "$H/order.log" | head -1 | cut -d: -f1)
[ -n "$cp" ] && [ -n "$cc" ] && [ "$cp" -lt "$cc" ] && ok || bad "M2: claim put line '$cp' not before call line '$cc'"
grep -q '^put repro_gate_claim .* released$' "$H/order.log" && ok || bad "M2: the claim was not released after the call"
if command -v flock >/dev/null 2>&1; then
  H=$(mkh m2l); B="$T/m2l"; K=$(lkey "$H" "$TH"); KH=$(printf '%s' "$K" | sha256sum | cut -c1-16)
  ( exec 9>"$H/locks/repro-drive-$KH.lock"; flock -n 9; exec sleep 5 ) & LP=$!
  wait_holder "$LP"
  THREAD_JSON="$TH" run "$H" "$B"
  kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
  [ "$(calls "$H")" = 0 ] && [ "$(rline "$B" REPRO_REASON)" = drive-in-flight ] && ok || bad "M2: a held local drive lock did not stop the spend (calls $(calls "$H"))"
fi

# ═══════════════════════════════════════════════════════════════════════════
# M3 — the lane and budget env survive the project env load (BH-1165).
# ═══════════════════════════════════════════════════════════════════════════
H=$(GLOBAL_ENV=$'AGENT_CALL_LANE=wrong-lane\nAGENT_CALL_BUDGET_USD_REPRO=99' mkh m3); B="$T/m3"
THREAD_JSON="$TH" VERDICT=REPRODUCED run "$H" "$B"
[ "$(cat "$H/calls/1.env" 2>/dev/null)" = "prebuild-repro|3" ] && ok || bad "M3: the call saw '$(cat "$H/calls/1.env" 2>/dev/null)', want 'prebuild-repro|3'"

# ═══════════════════════════════════════════════════════════════════════════
# H1 — GitHub markdown hygiene.
# ═══════════════════════════════════════════════════════════════════════════
H=$(mkh h1); B="$T/h1"
THREAD_JSON="$TH" STEPS='open @octocat page; ![x](https://evil.example/x.png); [click](https://evil.example)' \
  OBSERVED='pinged @acme/team and saw ![y](https://evil.example/y.png) <img src=x>' run "$H" "$B"
b=$(jq -r '.[-1].body' "$H/issue-comments.json" 2>/dev/null)
[ "$RC" = 10 ] && [ -n "$b" ] && ok || bad "H1: rc $RC, no body"
grep -qE '(^|[^\\])@(octocat|acme)' <<<"$b" && bad "H1: a live @-mention survived: $(grep -oE '.{0,10}@(octocat|acme).{0,10}' <<<"$b" | head -2 | tr '\n' '|')" || ok
grep -qE '(^|[^\\])!\[' <<<"$b" && bad "H1: a live image survived" || ok
grep -qE '(^|[^\\])\[click\]\(' <<<"$b" && bad "H1: a live link survived" || ok
grep -q '<img' <<<"$b" && bad "H1: raw HTML survived" || ok
grep -qF '`https://app.example/clients/77`' <<<"$b" && ok || bad "H1: the URL is not a code span"
grep -q '^> ' <<<"$b" && ok || bad "H1: the observed text is no longer quoted"

# ═══════════════════════════════════════════════════════════════════════════
# H2 — in-app HTML: the origin-checked URL is a real link; nothing else is.
# ═══════════════════════════════════════════════════════════════════════════
H=$(mkh h2); B="$T/h2"
THREAD_JSON="$TH" BOARD=app run "$H" "$B"
b=$(jq -r '.[-1].body' "$H/app-comments.json" 2>/dev/null)
grep -qF '<a href="https://app.example/clients/77">' <<<"$b" && ok || bad "H2: the prod URL is not a link: ${b:0:300}"
Hx=$(mkh h2x); mkdir -p "$T/h2x"
printf 'REPRO_ROLE: r\nREPRO_URL: javascript:alert(1)\nREPRO_STEPS: s\nREPRO_OBSERVED: o\n' > "$T/h2x/prebuild-repro.md"
( export HARNESS="$Hx" PATH="$Hx/fakebin:$PATH" BOARD=app; . "$Hx/bin/lib/prebuild-repro.sh"; pr_stop p 42 BH-7 "$T/h2x" "$TH" NOT_REPRODUCED ) >/dev/null 2>&1
b=$(jq -r '.[-1].body' "$Hx/app-comments.json" 2>/dev/null)
[ -n "$b" ] && ! grep -q '<a href' <<<"$b" && ok || bad "H2: a non-http URL was linked: ${b:0:300}"

# ═══════════════════════════════════════════════════════════════════════════
# H3 — delivered but unconfirmed: the retry finds it and posts nothing.
# ═══════════════════════════════════════════════════════════════════════════
H=$(mkh h3); B="$T/h3a"
THREAD_JSON="$TH" GH_MODE=lost run "$H" "$B"
[ "$RC" = 11 ] && [ "$(posts "$H")" = 1 ] && [ "$(lstat "$H" "$TH")" = not_reproduced_uncommented ] && ok \
  || bad "H3 gh: lost post rc $RC posts $(posts "$H") ledger '$(lstat "$H" "$TH")'"
LOST=$(jq -r '.[-1].body' "$H/issue-comments.json")
B="$T/h3b"; THREAD_JSON=$(with_comment "$TH" 900 2026-09-24T20:00:00Z "$LOST" true true) GH_MODE=ok run "$H" "$B"
[ "$RC" = 10 ] && [ "$(posts "$H")" = 1 ] && ok || bad "H3 gh: the retry posted again (rc $RC, posts $(posts "$H"))"
[ "$(lstat "$H" "$TH")" = not_reproduced ] && ok || bad "H3 gh: ledger '$(lstat "$H" "$TH")' after the found comment"
[ "$(calls "$H")" = 1 ] && ok || bad "H3 gh: the retry drove again ($(calls "$H") calls)"
H=$(mkh h3app); B="$T/h3c"
THREAD_JSON="$TH" BOARD=app CURL_MODE=lost run "$H" "$B"
[ "$RC" = 11 ] && [ "$(posts "$H")" = 1 ] && ok || bad "H3 app: lost post rc $RC posts $(posts "$H")"
B="$T/h3d"; THREAD_JSON="$TH" BOARD=app CURL_MODE=ok run "$H" "$B"
[ "$RC" = 10 ] && [ "$(posts "$H")" = 1 ] && ok || bad "H3 app: the retry posted again (rc $RC, posts $(posts "$H"))"
# control: a retry after a post that really failed (nothing stored) posts once.
H=$(mkh h3n); B="$T/h3e"
THREAD_JSON="$TH" GH_MODE=lost run "$H" "$B"; echo '[]' > "$H/issue-comments.json"
B="$T/h3f"; THREAD_JSON="$TH" GH_MODE=ok run "$H" "$B"
[ "$RC" = 10 ] && [ "$(posts "$H")" = 2 ] && ok || bad "H3 control: a really-failed post was not retried (rc $RC, posts $(posts "$H"))"

# H3q — N2 on the retry: the only marker on the ticket is a CLIENT quoting it.
# That is not our delivered comment, so the retry posts.
H=$(mkh h3q); B="$T/h3g"
THREAD_JSON="$TH" GH_MODE=lost run "$H" "$B"
jq -c '[.[-1] | .user = {login: "acme-client", type: "User"} | .body = ("> " + .body)]' "$H/issue-comments.json" > "$H/ic.t" && mv "$H/ic.t" "$H/issue-comments.json"
B="$T/h3h"; THREAD_JSON="$TH" GH_MODE=ok run "$H" "$B"
[ "$RC" = 10 ] && [ "$(posts "$H")" = 2 ] && ok || bad "H3q N2: a client quoting the marker counted as our delivered post (rc $RC, posts $(posts "$H"))"

leak=$(grep -rlF "$TOKEN" "$T"/*/logs "$T"/*/runner.out 2>/dev/null)
[ -z "$leak" ] && ok || bad "secret: token found in $leak"

echo "prebuild-repro-self-comment: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
