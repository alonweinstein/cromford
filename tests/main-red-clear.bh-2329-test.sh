#!/bin/bash
# tests/main-red-clear.bh-2329-test.sh — BH-2373 (BH-2329.2): the main-red
# detector publishes the main_red DETAIL row and honours an operator clear.
#
# WHY THE HONOUR EXISTS. A pause_flags row an operator turned off was re-raised
# within five minutes by the still-red path's `mr_publish on`, or re-paged
# --critical by the first-red path. A clear that re-raises on the next tick is
# not a clear. So the detector reads the worker's main_red rows once per run and
# stands down for a row that is active=0 with cleared_sha EXACTLY equal to the
# sha it would raise on — never a prefix, never another flag's clear.
#
# Driven, not grepped: bin/main-red-detector.sh runs WHOLE against a scratch
# $HARNESS, with a gh shim serving the runs page and a curl shim standing in for
# the jobs worker. Every assertion is on an artifact — the flag file, the
# published marker, the verdict file, the recorded HTTP requests, the alert
# sink, the log — never on source text.
#
# Every fixture value is a literal. Nothing here reads the wall clock.
# Run from anywhere: tests/main-red-clear.bh-2329-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

SLUG=example-org/demo-os
FLAGNAME=main-red-example-org-demo-os
D="$T/d"
DFLAG="$D/flags/$FLAGNAME"
DMARK="$D/state/main-red/$FLAGNAME.published"
VERDICT="$D/state/main-red/example-org-demo-os.verdict"
LOGF="$D/logs/main-red.log"
CI=".github/workflows/harness-ci.yml"

mkdir -p "$D/bin/lib/jobs" "$D/logs" "$D/flags" "$D/locks" "$D/env" "$D/state" "$T/fakebin" "$T/fix"
cp "$DIR/bin/main-red-detector.sh" "$DIR/bin/jobs-client.sh" "$D/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$D/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$D/bin/lib/"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\n' > "$D/env/global.env"
printf 'demo-os %s - - 2 box-demo\n' "$SLUG" > "$D/fleet.conf"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "${ALERT_SINK:-/dev/null}"\nexit 0\n' > "$D/bin/lane-alert.sh"
chmod +x "$D/bin/lane-alert.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"; chmod +x "$T/fakebin/sleep"

FIX="$T/fix"; REQ_SINK="$T/req.log"; ALERT_SINK="$T/alerts.txt"
# One failed job with an ordinary (non-infra) failed step: the BH-2165 check
# reads it, finds a real test failure, and names the job from it.
JOBS_ANSWER='{"total_count":1,"jobs":[{"name":"decisions","conclusion":"failure","run_attempt":1,"steps":[{"name":"run suites","conclusion":"failure"}]}]}'
export FIX REQ_SINK ALERT_SINK JOBS_ANSWER

cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
case "$*" in
  *"/actions/runs/"*"/jobs"*) printf '%s\n' "${JOBS_ANSWER:-}" ;;
  *"actions/runs"*)
      [ -s "$FIX/runs.json" ] || exit 1
      jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id}]' "$FIX/runs.json" ;;
  *) printf '\n' ;;
esac
exit 0
SHIM
chmod +x "$T/fakebin/gh"

# curl: the fake jobs worker. Every request lands in REQ_SINK as
# "METHOD URL BODY". MR_GET=down|junk|404 breaks the main-red read three ways;
# MR_PUT=fail answers the detail-row PUT 500, FLAGS_PUT=fail the flag row PUT.
cat > "$T/fakebin/curl" <<'SHIM'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "${REQ_SINK:-/dev/null}"
case "$METHOD $URL" in
  "GET "*"/api/main-red?all=1")
      case "${MR_GET:-ok}" in
        down) exit 7 ;;
        junk) printf 'not json\n200\n' ;;
        404)  printf '{"error":"not found"}\n404\n' ;;
        *)    if [ -s "$FIX/main-red.json" ]; then printf '%s\n200\n' "$(cat "$FIX/main-red.json")"
              else printf '{"main_red":[],"truncated":false}\n200\n'; fi ;;
      esac ;;
  "PUT "*"/api/main-red")
      if [ "${MR_PUT:-ok}" = fail ]; then printf '{"error":"boom"}\n500\n'
      else printf '{"ok":true}\n200\n'; fi ;;
  "PUT "*"/api/flags")
      if [ "${FLAGS_PUT:-ok}" = fail ]; then printf '{"error":"boom"}\n500\n'
      else printf '{"flag":{"name":"x","active":1,"updated_at":"2026-09-19T01:00:00Z"}}\n200\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
SHIM
chmod +x "$T/fakebin/curl"

runs() { # runs <name|path|conclusion|created_at|sha[|status]>...
  local out='{"workflow_runs":[' first=1 spec n p c t s sha
  for spec in "$@"; do
    IFS='|' read -r n p c t sha s <<<"$spec"; s=${s:-completed}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg p "$p" --arg s "$s" --arg t "$t" --arg sha "$sha" --arg c "$c" \
      --arg u "https://github.com/o/r/actions/runs/${t//[^0-9]/}" \
      '{name:$n, path:$p, status:$s, conclusion:$c, created_at:$t, head_sha:$sha, html_url:$u,
        id:($t|gsub("[^0-9]";"")|tonumber)}')
  done
  printf '%s]}' "$out" > "$FIX/runs.json"
}
red_on() { # red_on <sha> — two consecutive reds of Harness CI, newest on <sha>
  runs "Harness CI|$CI|failure|2026-09-18T20:41:00Z|$1" \
       "Harness CI|$CI|failure|2026-09-18T20:10:00Z|cccc3333" \
       "Harness CI|$CI|success|2026-09-18T19:00:00Z|dddd4444"
}
green() {
  runs "Harness CI|$CI|success|2026-09-18T23:10:00Z|eeee5555" \
       "Harness CI|$CI|failure|2026-09-18T20:41:00Z|aaaa1111"
}
cleared() { # cleared <name> <active> <cleared_sha> — the worker's main_red rows
  jq -nc --arg n "$1" --argjson a "$2" --arg s "$3" \
    '{main_red:[{name:$n, active:$a, cleared_sha:$s, project:"demo-os", slug:"example-org/demo-os"}], truncated:false}' \
    > "$FIX/main-red.json"
}
no_clears() { rm -f "$FIX/main-red.json"; }
fresh() { # a tree with no flag, no marker, no verdict, no ledger memory
  rm -f "$D"/flags/main-red-* ; scratch_rm "$D/state/main-red"; : > "$LOGF"
}
DRC=0
detect() { # detect [--explain] [slug ...] — env MR_GET / MR_PUT / FLAGS_PUT pass through
  : > "$REQ_SINK"; : > "$ALERT_SINK"
  [ $# -gt 0 ] || set -- "$SLUG"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$D" \
      bash "$D/bin/main-red-detector.sh" "$@" >"$T/det.out" 2>"$T/det.err" )
  DRC=$?
}
mr_body() { # the body of the last PUT /api/main-red, or nothing
  grep '^PUT [^ ]*/api/main-red ' "$REQ_SINK" | tail -1 | sed 's/^PUT [^ ]* //'
}
field() { jq -c ".$1" <<<"$(mr_body)" 2>/dev/null; }
critical() { grep -q -- '--critical' "$ALERT_SINK"; }
gets() { grep -c '^GET [^ ]*/api/main-red?all=1' "$REQ_SINK"; }
ctx() { printf 'requests: %s | alerts: %s | log: %s | err: %s' \
  "$(cat "$REQ_SINK")" "$(cat "$ALERT_SINK")" "$(cat "$LOGF")" "$(cat "$T/det.err")"; }

# ============================================================================
# 1. A red tick publishes the detail row with the flag's own fields.
# ============================================================================
fresh; no_clears; red_on aaaa1111
detect
[ -f "$DFLAG" ] && ok || bad "1: the red tick must write the flag ($(ctx))"
[ -n "$(mr_body)" ] && ok || bad "1: THE DEFECT — a red tick sends no PUT /api/main-red ($(ctx))"
[ "$(field name)" = "\"$FLAGNAME\"" ] && ok || bad "1: name ($(mr_body))"
[ "$(field active)" = 1 ]            && ok || bad "1: active must be 1 ($(mr_body))"
[ "$(field sha)" = '"aaaa1111"' ]    && ok || bad "1: sha ($(mr_body))"
[ "$(field workflow)" = '"Harness CI"' ] && ok || bad "1: workflow ($(mr_body))"
[ "$(field job)" = '"decisions"' ]   && ok || bad "1: job ($(mr_body))"
[ "$(field run_url)" = '"https://github.com/o/r/actions/runs/20260918204100"' ] \
  && ok || bad "1: run_url must be the run's html_url ($(mr_body))"
[ "$(field project)" = '"demo-os"' ] && ok || bad "1: project must come from fleet.conf ($(mr_body))"
[ "$(field slug)" = "\"$SLUG\"" ]    && ok || bad "1: slug ($(mr_body))"
SINCE=$(sed -n 's/^since=//p' "$DFLAG" 2>/dev/null | head -1)
[ -n "$SINCE" ] && [ "$(field since)" = "\"$SINCE\"" ] && ok || bad "1: since must be the flag's since= ($(mr_body))"
# ORDER: file -> flag row -> detail row.
awk '/^PUT [^ ]*\/api\/flags /{f=NR} /^PUT [^ ]*\/api\/main-red /{m=NR} END{exit !(f && m && f<m)}' "$REQ_SINK" \
  && ok || bad "1: the detail row goes AFTER the pause_flags PUT ($(cat "$REQ_SINK"))"
critical && ok || bad "1: a first red still pages --critical ($(ctx))"
[ "$DRC" = 0 ] && ok || bad "1: detector rc=$DRC"

# 1-still. The still-red tick republishes the detail row too (self-heal).
detect
[ "$(field active)" = 1 ] && ok || bad "1-still: a still-red tick must republish the detail row ($(ctx))"

# 1b. Green again: the detail row goes out active=0, with no fabricated sha.
green
detect
[ -f "$DFLAG" ] && bad "1b: green must clear the flag" || ok
[ "$(field active)" = 0 ] && ok || bad "1b: a green tick must PUT active:0 ($(ctx))"
[ "$(field name)" = "\"$FLAGNAME\"" ] && ok || bad "1b: off body name ($(mr_body))"
[ "$(field sha)" = null ] && ok || bad "1b: an off body carries no sha, not a made-up one ($(mr_body))"

# 1-null. A slug no fleet.conf row names publishes project:null.
fresh; red_on aaaa1111
detect o/r
[ -f "$D/flags/main-red-o-r" ] && ok || bad "1-null: flag for o/r ($(ctx))"
[ "$(field name)" = '"main-red-o-r"' ] && [ "$(field project)" = null ] \
  && ok || bad "1-null: a repo with no fleet.conf row must publish project:null ($(mr_body))"

# 1c. Both PUTs dead: the flag is still written, the detail row is still TRIED
#     after the dead flag PUT, one honest line is logged, and the run exits 0.
fresh; red_on aaaa1111
MR_PUT=fail FLAGS_PUT=fail detect
[ -f "$DFLAG" ] && ok || bad "1c: a dead PUT must never stop the flag file ($(ctx))"
grep -q '^PUT [^ ]*/api/main-red ' "$REQ_SINK" \
  && ok || bad "1c: the detail row must be attempted even when flag_set failed ($(ctx))"
grep -q "$FLAGNAME: detail row not published" "$LOGF" \
  && ok || bad "1c: a failed detail PUT logs 'detail row not published' ($(ctx))"
grep -qi "detail row published" "$LOGF" && bad "1c: a failed PUT must never be logged as published" || ok
[ "$DRC" = 0 ] && ok || bad "1c: detector rc=$DRC, want 0"
critical && ok || bad "1c: the page still goes out ($(ctx))"

# ============================================================================
# 2. The operator cleared THIS sha: no flag, no marker, no re-raise, no page.
# ============================================================================
fresh; no_clears; red_on aaaa1111
detect
[ -f "$DFLAG" ] && [ -f "$DMARK" ] && ok || bad "2-setup: a red tick must leave flag + published marker ($(ctx))"
cleared "$FLAGNAME" 0 aaaa1111
detect
[ -f "$DFLAG" ] && bad "2: THE DEFECT — a cleared sha re-raised the flag ($(ctx))" || ok
[ -f "$DMARK" ] && bad "2: the published marker must go with the flag" || ok
critical && bad "2: a cleared sha must not page --critical ($(cat "$ALERT_SINK"))" || ok
[ -s "$ALERT_SINK" ] && bad "2: a cleared sha sends no alert at all ($(cat "$ALERT_SINK"))" || ok
grep -q 'PUT [^ ]*/api/flags .*"active":1' "$REQ_SINK" \
  && bad "2: a cleared sha must not re-publish pause_flags ON ($(cat "$REQ_SINK"))" || ok
grep -qE '^PUT [^ ]*/api/(flags|main-red) ' "$REQ_SINK" && bad "2: the honour path publishes nothing ($(cat "$REQ_SINK"))" || ok
grep -qx 'decision=red' "$VERDICT" && grep -qx 'reason=operator-cleared' "$VERDICT" \
  && grep -qx 'sha=aaaa1111' "$VERDICT" && ok || bad "2: verdict must be red/operator-cleared/aaaa1111 ($(cat "$VERDICT" 2>/dev/null))"
grep -q "$SLUG: main still red on aaaa1111 but an operator cleared this sha — no freeze, no page" "$LOGF" \
  && ok || bad "2: the honour must be logged ($(ctx))"
[ "$(gets)" = 1 ] && ok || bad "2: exactly one GET of the clears per run ($(cat "$REQ_SINK"))"

# 2-again. The next tick on the same red still honours (nothing re-raises).
detect
[ -f "$DFLAG" ] && bad "2-again: the tick after a clear must not re-raise ($(ctx))" || ok
critical && bad "2-again: the tick after a clear must not page" || ok

# 2b. First-red path: no prior flag at all, same cleared row.
fresh; cleared "$FLAGNAME" 0 aaaa1111; red_on aaaa1111
detect
[ -f "$DFLAG" ] && bad "2b: a cleared sha must not raise on the first-red path ($(ctx))" || ok
critical && bad "2b: a cleared sha must not page on the first-red path ($(cat "$ALERT_SINK"))" || ok
grep -qx 'reason=operator-cleared' "$VERDICT" && ok || bad "2b: verdict ($(cat "$VERDICT" 2>/dev/null))"

# ============================================================================
# 3. A NEW red sha after a clear of the old one raises and pages as always.
# ============================================================================
fresh; cleared "$FLAGNAME" 0 aaaa1111; red_on bbbb2222
detect
grep -qx 'sha=bbbb2222' "$DFLAG" 2>/dev/null && ok || bad "3: a new red sha must raise ($(ctx))"
critical && ok || bad "3: a new red sha must page --critical ($(ctx))"
grep -q 'operator cleared' "$LOGF" && bad "3: a different sha is not honoured" || ok

# ============================================================================
# 4. An unreadable clear list fails TOWARD the freeze, logged once.
# ============================================================================
for mode in down junk 404; do
  fresh; cleared "$FLAGNAME" 0 aaaa1111; red_on aaaa1111
  MR_GET=$mode detect
  [ -f "$DFLAG" ] && ok || bad "4/$mode: an unreadable clear list must still raise ($(ctx))"
  critical && ok || bad "4/$mode: an unreadable clear list must still page ($(ctx))"
  [ "$(grep -c 'main-red clears unreadable — no operator clear honoured this run' "$LOGF")" = 1 ] \
    && ok || bad "4/$mode: exactly one 'clears unreadable' line ($(ctx))"
  [ "$DRC" = 0 ] && ok || bad "4/$mode: detector rc=$DRC"
done
# One GET per RUN, not per repo.
fresh; no_clears; red_on aaaa1111
detect "$SLUG" o/r
[ "$(gets)" = 1 ] && ok || bad "4-count: two repos, one run, must read the clears once ($(cat "$REQ_SINK"))"
MR_GET=404 detect "$SLUG" o/r
[ "$(gets)" = 1 ] && ok || bad "4-count/404: one GET per run on the 404 path too ($(cat "$REQ_SINK"))"

# ============================================================================
# 5. Negatives: none of these is a clear of the sha being raised.
# ============================================================================
neg() { # neg <label> <red-sha> <row-name> <row-active> <row-cleared-sha>
  fresh; cleared "$3" "$4" "$5"; red_on "$2"
  detect
  if [ -f "$DFLAG" ] && critical; then ok; else bad "5/$1: must still raise and page ($(ctx))"; fi
  grep -q 'operator cleared' "$LOGF" && bad "5/$1: must not be honoured" || ok
}
neg prefix-of-red     aaaa1111 "$FLAGNAME" 0 aaaa
neg red-is-prefix     aaaa     "$FLAGNAME" 0 aaaa1111
neg glob-in-clear     aaaa1111 "$FLAGNAME" 0 'aaaa*'
neg other-flag        aaaa1111 main-red-example-org-other-os 0 aaaa1111
neg still-active      aaaa1111 "$FLAGNAME" 1 aaaa1111
neg empty-cleared-sha aaaa1111 "$FLAGNAME" 0 ""

# ============================================================================
# 6. --explain names the honour and touches nothing.
# ============================================================================
fresh; no_clears; red_on aaaa1111
detect
[ -f "$DFLAG" ] && [ -f "$DMARK" ] && ok || bad "6-setup: flag + marker ($(ctx))"
cleared "$FLAGNAME" 0 aaaa1111
BEFORE=$(cd "$D" && find flags state -type f | sort | xargs md5sum 2>/dev/null)
detect --explain "$SLUG"
AFTER=$(cd "$D" && find flags state -type f | sort | xargs md5sum 2>/dev/null)
grep -q 'WOULD HONOUR CLEAR' "$T/det.out" && ok || bad "6: --explain must say WOULD HONOUR CLEAR (out: $(cat "$T/det.out"))"
[ "$BEFORE" = "$AFTER" ] && ok || bad "6: --explain changed files (before: $BEFORE | after: $AFTER)"
grep -qE '^(PUT|POST) ' "$REQ_SINK" && bad "6: --explain must send no PUT ($(cat "$REQ_SINK"))" || ok
[ "$(gets)" = 1 ] && ok || bad "6: --explain still reads the clears ($(cat "$REQ_SINK"))"

# 6b. --explain on a plain red names the detail row and sends nothing.
fresh; no_clears; red_on aaaa1111
detect --explain "$SLUG"
grep -q "WOULD PUBLISH detail $FLAGNAME=on" "$T/det.out" && ok || bad "6b: --explain must log WOULD PUBLISH detail (out: $(cat "$T/det.out"))"
grep -qE '^(PUT|POST) ' "$REQ_SINK" && bad "6b: --explain must send no PUT ($(cat "$REQ_SINK"))" || ok

echo "main-red-clear.bh-2329: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
