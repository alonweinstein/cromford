#!/bin/bash
# tests/jobs-contract.bh-2622-test.sh — BH-2532.0 contract: the three client
# helpers the #2532 siblings build on.
#
# Drives the REAL bin/jobs-client.sh (and so bin/lib/jobs/jobs.sh and
# bin/lib/jobs/boxes.sh through its JC_MODULES loop) against a stubbed curl.
# What is pinned is each helper's answer vocabulary: rc 0 = the thing, rc 3 =
# the worker answered and there is nothing there, rc 1 = the worker could not
# be asked. The negatives carry the weight — "could not ask" must never read
# as "nothing there".
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/state" "$T/bin/lib/jobs" "$T/env" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Fake curl: the response body for a 2xx comes from $T/resp.json, the status
# from CURL_MODE. Every request is logged as "METHOD URL" on one line and its
# body, verbatim, to $T/body.json.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2;;
    *) shift;;
  esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
[ -n "${BODY_SINK:-}" ] && printf '%s' "$BODY" > "$BODY_SINK"
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
  nf)   printf '{"error":"not found"}\n404\n'; exit 0 ;;
  junk) printf 'this is not json\n200\n'; exit 0 ;;
esac
cat "$RESP_FILE"; printf '\n200\n'
CURL
chmod +x "$T/fakebin/curl"

resp() { printf '%s' "$1" > "$T/resp.json"; }
fn() { # fn <function> [args...]
  ( unset JOB_ID
    export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=box-a RESP_FILE="$T/resp.json" \
           REQ_SINK="$T/req.log" BODY_SINK="$T/body.json" JOBS_RETRIES=0 ${EXTRA_ENV:-}
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh" >/dev/null 2>&1
    "$@" )
}

# ─── job_artifact_detail ───────────────────────────────────────────────────
# The detail carries a tab and escaped JSON on purpose: it must come back
# byte-for-byte, never re-parsed or reformatted.
resp '{"artifacts":[{"artifact_kind":"pr_url","artifact_ref":"x","detail":null},{"artifact_kind":"lead_review_report","artifact_ref":"r","detail":"{\"a\":1}\tx"}]}'
WANT=$(printf '{"a":1}\tx')

# A1: the row exists with a detail -> printed verbatim, rc 0, right route.
: > "$T/req.log"
OUT=$(fn job_artifact_detail lead_review_report J1); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$WANT" ] && grep -q '^GET https://jobs.invalid/api/jobs/J1/artifacts$' "$T/req.log" \
  && ok || bad "A1 detail: rc=$RC out='$OUT' req=$(cat "$T/req.log")"

# A1b: JOB_ID is the default job.
OUT=$(EXTRA_ENV="JOB_ID=J1" fn job_artifact_detail lead_review_report); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$WANT" ] && ok || bad "A1b JOB_ID default: rc=$RC out='$OUT'"

# A2: the kind is absent -> rc 3, nothing printed.
OUT=$(fn job_artifact_detail plan_md J1); RC=$?
[ "$RC" = 3 ] && [ -z "$OUT" ] && ok || bad "A2 absent kind: rc=$RC out='$OUT'"

# A3: the row exists but its detail is null -> rc 3, nothing printed.
OUT=$(fn job_artifact_detail pr_url J1); RC=$?
[ "$RC" = 3 ] && [ -z "$OUT" ] && ok || bad "A3 null detail: rc=$RC out='$OUT'"

# A3b: an empty-string detail is also "nothing there".
resp '{"artifacts":[{"artifact_kind":"pr_url","artifact_ref":"x","detail":""}]}'
OUT=$(fn job_artifact_detail pr_url J1); RC=$?
[ "$RC" = 3 ] && [ -z "$OUT" ] && ok || bad "A3b empty detail: rc=$RC out='$OUT'"

# A3c: an unknown job answers 200 with an empty list -> rc 3.
resp '{"artifacts":[]}'
OUT=$(fn job_artifact_detail pr_url J9); RC=$?
[ "$RC" = 3 ] && [ -z "$OUT" ] && ok || bad "A3c no artifacts: rc=$RC out='$OUT'"

# A3d: a 404 is the worker answering "no such" -> rc 3, not an outage.
OUT=$(EXTRA_ENV="CURL_MODE=nf" fn job_artifact_detail pr_url J1); RC=$?
[ "$RC" = 3 ] && [ -z "$OUT" ] && ok || bad "A3d 404: rc=$RC out='$OUT'"

# A4: the worker is unreachable -> rc 1, nothing printed.
OUT=$(EXTRA_ENV="CURL_MODE=down" fn job_artifact_detail lead_review_report J1); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "A4 down: rc=$RC out='$OUT'"

# A4b: a 2xx body that is not JSON -> rc 1: absence cannot be read from it.
OUT=$(EXTRA_ENV="CURL_MODE=junk" fn job_artifact_detail lead_review_report J1); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "A4b unparseable: rc=$RC out='$OUT'"

# A5: no job and JOB_ID unset -> rc 1, and nothing asked.
: > "$T/req.log"
OUT=$(fn job_artifact_detail lead_review_report); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ ! -s "$T/req.log" ] && ok || bad "A5 no job: rc=$RC out='$OUT'"

# A5b: no kind -> rc 1.
OUT=$(fn job_artifact_detail "" J1); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "A5b no kind: rc=$RC out='$OUT'"

# ─── box_self_report_set ───────────────────────────────────────────────────
# B1: POST /api/boxes/self-report with exactly the five keys.
resp '{"ok":true}'
: > "$T/req.log"; : > "$T/body.json"
OUT=$(fn box_self_report_set 2.1.0 0.9.0 abc123); RC=$?
KEYS=$(jq -c 'keys' "$T/body.json" 2>/dev/null)
VALS=$(jq -r '[.box,.cli_version,.codex_version,.rules_hash] | @tsv' "$T/body.json" 2>/dev/null)
AT=$(jq -r '.at' "$T/body.json" 2>/dev/null)
[ "$RC" = 0 ] && [ -z "$OUT" ] \
  && grep -q '^POST https://jobs.invalid/api/boxes/self-report$' "$T/req.log" \
  && [ "$KEYS" = '["at","box","cli_version","codex_version","rules_hash"]' ] \
  && [ "$VALS" = "$(printf 'box-a\t2.1.0\t0.9.0\tabc123')" ] \
  && [[ "$AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  && ok || bad "B1 payload: rc=$RC req=$(cat "$T/req.log") body=$(cat "$T/body.json")"

# B1b: empty args are sent as "" rather than dropped.
OUT=$(fn box_self_report_set "" "" abc123); RC=$?
[ "$RC" = 0 ] && [ "$(jq -r '.cli_version + "|" + .codex_version + "|" + .rules_hash' "$T/body.json")" = "||abc123" ] \
  && ok || bad "B1b empty args: rc=$RC body=$(cat "$T/body.json")"

# B2: the route is not deployed yet (404) -> nonzero.
OUT=$(EXTRA_ENV="CURL_MODE=nf" fn box_self_report_set 2.1.0 0.9.0 abc123); RC=$?
[ "$RC" != 0 ] && [ -z "$OUT" ] && ok || bad "B2 404: rc=$RC out='$OUT'"

# B2b: worker down -> nonzero.
OUT=$(EXTRA_ENV="CURL_MODE=down" fn box_self_report_set 2.1.0 0.9.0 abc123); RC=$?
[ "$RC" != 0 ] && ok || bad "B2b down: rc=$RC"

# ─── box_self_reports ──────────────────────────────────────────────────────
# C1: one box with only rules, one with only cli, one with neither (omitted),
# one with both keys present but empty (omitted).
resp '{"boxes":[
 {"box":"a","cli_version":null,"codex_version":null,"cli_checked_at":null,"rules_hash":"h1","rules_reported_at":"2026-09-26T10:00:00Z"},
 {"box":"b","cli_version":"2.1.0","codex_version":"0.9.0","cli_checked_at":"2026-09-26T09:00:00Z","rules_hash":null,"rules_reported_at":null},
 {"box":"c","cli_version":null,"codex_version":null,"cli_checked_at":null,"rules_hash":null,"rules_reported_at":null},
 {"box":"d","cli_version":"x","cli_checked_at":"","rules_hash":"h","rules_reported_at":""}]}'
: > "$T/req.log"
OUT=$(fn box_self_reports); RC=$?
WANT=$(printf 'a\t\t\t\th1\t2026-09-26T10:00:00Z\nb\t2.1.0\t0.9.0\t2026-09-26T09:00:00Z\t\t')
[ "$RC" = 0 ] && [ "$OUT" = "$WANT" ] && grep -q '^GET https://jobs.invalid/api/boxes$' "$T/req.log" \
  && [ "$(printf '%s\n' "$OUT" | awk -F'\t' '{print NF}' | sort -u)" = 6 ] \
  && ok || bad "C1 tsv: rc=$RC out=$(printf '%s' "$OUT" | od -c | head -8)"

# C2: worker down -> rc 1, nothing printed.
OUT=$(EXTRA_ENV="CURL_MODE=down" fn box_self_reports); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "C2 down: rc=$RC out='$OUT'"

# C2b: unparseable 2xx -> rc 1, not "no box reported".
OUT=$(EXTRA_ENV="CURL_MODE=junk" fn box_self_reports); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "C2b unparseable: rc=$RC out='$OUT'"

# C3: an empty fleet -> rc 0, nothing printed.
resp '{"boxes":[]}'
OUT=$(fn box_self_reports); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "C3 empty: rc=$RC out='$OUT'"

echo "jobs-contract.bh-2622: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
