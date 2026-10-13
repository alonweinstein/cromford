#!/bin/bash
# tests/jobs-client-body.bh-1000-test.sh — the worker's REASON survives the call.
#
# BH-1000. When `hub_lease` was missing, the worker threw and Cloudflare turned
# that into a bodiless 500; bin/hub-lease.sh logged "worker unreachable" and an
# operator spent the outage looking for a network problem. The worker now
# answers `503 {"error":"hub_lease schema not applied"}` (worker/jobs, T1), and
# a reason nobody can read is the same silence one status code later — so
# _jobs_req hands the non-2xx payload back through JOBS_BODY, beside JOBS_HTTP.
#
# THE CONTRACT THAT MUST NOT MOVE: rcs. Every verb in this file's parent is
# built on "0 = answer, 9 = 409, 2 = 404, 1 = anything else", and dozens of
# callers branch on it. JOBS_BODY is additive; this suite pins both halves.
#
# Driven, not grepped: the REAL bin/jobs-client.sh is sourced against a stubbed
# curl, and the assertions are on rcs, stdout, the variables and the log file.
# Run from anywhere: tests/jobs-client-body.bh-1000-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/state" "$T/bin" "$T/env" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The shapes the worker really answers with. No trailing newline after the code:
# that is what real `curl -w $'\n%{http_code}'` writes and what _jobs_req parses.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
case "${CURL_MODE:-schema}" in
  schema)  printf '{"error":"settings schema not applied","detail":"D1_ERROR: no such table: settings"}\n503' ;;
  lease)   printf '{"error":"hub_lease schema not applied","detail":"D1_ERROR: no such table: hub_lease"}\n503' ;;
  ok)      printf '{"setting":{"key":"gh_budget_min_remaining","value":"800"}}\n200' ;;
  conflict) printf '{"error":"lease held"}\n409' ;;
  missing) printf '{"error":"not found"}\n404' ;;
  down)    exit 7 ;;
esac
exit 0
CURL
chmod +x "$T/fakebin/curl"

# One subshell per call, so a variable that survives here survived the FUNCTION
# and not merely the file. `. jobs-client.sh` is how every consumer loads it.
probe() { # probe <curl-mode> <shell-snippet>
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 CURL_MODE="$1"
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh" 2>/dev/null
    eval "$2" )
}
logfile="$T/logs/jobs-client.log"

# ── 1. A 503 with a reason: rc 1, nothing on stdout, the body in JOBS_BODY ───
: > "$logfile"
OUT=$(probe schema '_jobs_req GET /api/settings/gh_budget_min_remaining >"'"$T"'/stdout.txt"; rc=$?; printf "%s|%s|%s" "$rc" "$JOBS_HTTP" "$JOBS_BODY"')
RC=${OUT%%|*}; REST=${OUT#*|}; HTTP=${REST%%|*}; BODY=${REST#*|}
[ "$RC" = 1 ] && ok || bad "a 503 must still be rc 1 (got: $RC)"
[ "$HTTP" = 503 ] && ok || bad "JOBS_HTTP must be 503 (got: $HTTP)"
[ "$BODY" = '{"error":"settings schema not applied","detail":"D1_ERROR: no such table: settings"}' ] \
  && ok || bad "JOBS_BODY must be the payload verbatim (got: $BODY)"
[ ! -s "$T/stdout.txt" ] && ok || bad "a non-2xx must print nothing on stdout (got: $(cat "$T/stdout.txt"))"
grep -q 'http=503 {"error":"settings schema not applied"' "$logfile" \
  && ok || bad "jobs-client.log must carry the reason verbatim (got: $(cat "$logfile"))"

# ── 2. The REAL consumer of that route still answers the way callers expect ──
# bin/lib/gh-budget.sh reads this knob every tick. rc 1 = "use your fallback",
# and a missing table must not read as an operator lowering a threshold.
OUT=$(probe schema 'v=$(setting_get gh_budget_min_remaining); printf "%s|%s" "$?" "$v"')
[ "${OUT%%|*}" = 1 ] && ok || bad "setting_get on a 503 must return 1 (got: ${OUT%%|*})"
[ -z "${OUT#*|}" ] && ok || bad "setting_get must print nothing on a 503 (got: ${OUT#*|})"

# ── 3. The rc contract is UNCHANGED on every other answer ────────────────────
OUT=$(probe ok '_jobs_req GET /api/settings/k >/dev/null; printf "%s|%s|%s" "$?" "$JOBS_HTTP" "$JOBS_BODY"')
[ "${OUT%%|*}" = 0 ] && ok || bad "a 200 must stay rc 0 (got: ${OUT%%|*})"
RESTOK=${OUT#*|}; [ "${RESTOK%%|*}" = 200 ] && ok || bad "JOBS_HTTP on a 200 must be 200 (got: ${RESTOK%%|*})"
[ -n "${RESTOK#*|}" ] && ok || bad "JOBS_BODY must carry the 2xx payload too (got empty)"

OUT=$(probe conflict '_jobs_req POST /api/hub-lease "{}" >/dev/null; printf "%s|%s|%s" "$?" "$JOBS_HTTP" "$JOBS_BODY"')
[ "${OUT%%|*}" = 9 ] && ok || bad "a 409 must stay rc 9 (got: ${OUT%%|*})"
[ "${OUT#*|}" = '409|{"error":"lease held"}' ] && ok || bad "409 must expose http+body (got: ${OUT#*|})"

OUT=$(probe missing '_jobs_req GET /api/whatever >/dev/null; printf "%s|%s" "$?" "$JOBS_HTTP"')
[ "$OUT" = "2|404" ] && ok || bad "a 404 must stay rc 2 with JOBS_HTTP=404 (got: $OUT)"

# ── 4. A TRANSPORT failure is NOT a 503, and must not look like one ──────────
# The whole point of the reason is telling these two apart. An empty JOBS_HTTP
# is what "the worker never answered" looks like, and JOBS_BODY must not be a
# leftover from the previous call.
OUT=$(probe down '_jobs_req GET /api/settings/k >/dev/null; printf "%s|%s|%s" "$?" "$JOBS_HTTP" "$JOBS_BODY"')
[ "$OUT" = "1|||" ] || [ "$OUT" = "1||" ] && ok || bad "a transport failure must be rc 1 with empty http/body (got: $OUT)"

OUT=$(probe ok 'CURL_MODE=schema _jobs_req GET /api/a >/dev/null; CURL_MODE=down _jobs_req GET /api/b >/dev/null; printf "%s|%s" "$JOBS_HTTP" "$JOBS_BODY"')
[ "$OUT" = "|" ] && ok || bad "JOBS_BODY must be RESET per request, never a stale answer (got: $OUT)"

# ── 5. _jobs_req_file carries the same reason ────────────────────────────────
# The large-body path is a second door to the same contract (D15): a transcript
# push that fails on an unapplied table must say so, not "unreachable".
printf '{"a":1}' > "$T/body.json"
OUT=$(probe lease '_jobs_req_file POST /api/artifacts "'"$T"'/body.json" >/dev/null; printf "%s|%s|%s" "$?" "$JOBS_HTTP" "$JOBS_BODY"')
[ "${OUT%%|*}" = 1 ] && ok || bad "_jobs_req_file on a 503 must be rc 1 (got: ${OUT%%|*})"
case "${OUT#*|}" in
  '503|{"error":"hub_lease schema not applied"'*) ok ;;
  *) bad "_jobs_req_file must expose http+body (got: ${OUT#*|})" ;;
esac

echo "jobs-client-body.bh-1000-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
