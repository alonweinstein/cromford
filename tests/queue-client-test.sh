#!/bin/bash
# tests/queue-client-test.sh — the build queue's SHELL side, driven.
#
# WHY DRIVEN AND NOT GREPPED. Every claim these helpers make is about behaviour
# under failure: an empty queue must be tellable from an unreachable worker (rc
# 2 vs rc 1), a lost claim race must be a clean skip rather than an error, and
# an outage must leave the caller free to keep using its directory. A grep for
# `queue_claim` in bin/jobs-client.sh would pass just as happily on a version
# that returned 1 for an empty queue — which would make every quiet project look
# like a broken coordination DB and burn the daily alert on it.
#
# curl is stubbed (no network in tests), so what is proven here is the request
# the client sends and the rc it derives from the answer. The worker's own
# behaviour is proven by worker/jobs/test/index.test.js.
# Run from anywhere: tests/queue-client-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/flags" "$T/state" "$T/bin" "$T/fakebin" "$T/env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# Fake curl: records METHOD, URL and body, answers per CURL_MODE.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET; AUTH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) BODY="$2"; shift 2 ;;
    -X) M="$2"; shift 2 ;;
    -H) case "$2" in authorization:*) AUTH="$2" ;; esac; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s | %s\n' "$M" "$URL" "$BODY" "$AUTH" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down)     exit 7 ;;
  err500)   printf 'boom\n500\n'; exit 0 ;;
  empty)    printf '{"error":"nothing queued"}\n404\n'; exit 0 ;;
  lost)     printf '{"error":"another claimant took this build","refused":true,"scope":"queue","reason":"another claimant took project-3/TK-109 first"}\n409\n'; exit 0 ;;
  dup)      printf '{"queued":{"project":"project-3","ticket_key":"TK-109","status":"claimed"},"duplicate":true}\n200\n'; exit 0 ;;
  *) case "$URL" in
       */api/queue/claim) printf '{"queued":{"project":"project-3","ticket_key":"TK-109","ticket_id":"109","target":"fly","attempt":1,"status":"claimed"},"claimed":true}\n200\n' ;;
       */api/queue\?*|*/api/queue)
         case "$M" in
           GET)   printf '{"queue":[{"project":"project-3","ticket_key":"TK-1","ticket_id":"1","status":"queued","target":"fly","attempt":0,"claimed_by":null,"enqueued_at":"2026-09-10T00:00:00Z","reason":"BUILD_DEFERRED REFUSED box ::\\nbox max 1 already running"}]}\n200\n' ;;
           PATCH) printf '{"queued":{"project":"project-3","ticket_key":"TK-109","status":"done"}}\n200\n' ;;
           *)     printf '{"queued":{"project":"project-3","ticket_key":"TK-109","status":"queued","target":"fly","attempt":0},"duplicate":false}\n201\n' ;;
         esac ;;
       *) printf '{}\n404\n' ;;
     esac ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# cl <curl-mode> <function> <args...> -> prints the function's stdout; rc in $RC_OUT
cl() {
  local mode="$1"; shift
  : > "$T/req.txt"
  local out rc
  out=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
                  JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_RETRIES=0 \
                  CURL_MODE="$mode" REQ_SINK="$T/req.txt"
           # shellcheck source=/dev/null
           . "$DIR/bin/jobs-client.sh"
           "$@" ) 2>/dev/null ); rc=$?
  echo "$rc" > "$T/rc.txt"
  printf '%s' "$out"
}
rcv() { cat "$T/rc.txt"; }
# awk, and the pipe spelled [|]: a reason field legitimately carries spaces, and
# `\|` inside an ERE is alternation on BSD sed — which silently truncated the
# body at its first space and made this helper lie about what was sent.
body_of() {
  grep -m1 "^$1 https://jobs.invalid$2" "$T/req.txt" \
    | awk '{ $1=""; $2=""; sub(/^ +/, ""); sub(/ [|] .*$/, ""); print }'
}

# --- 1. enqueue sends the file queue's own identity --------------------------
OUT=$(cl ok queue_put project-3 TK-109 109 fly 0)
[ "$(rcv)" = 0 ] && ok || bad "a good enqueue must exit 0, got $(rcv)"
[ "$OUT" = queued ] && ok || bad "a fresh enqueue must print 'queued', got '$OUT'"
B=$(body_of POST /api/queue)
[ "$(jq -r .project <<<"$B")" = project-3 ] && ok || bad "project must ride the body, got: $B"
[ "$(jq -r .key <<<"$B")" = TK-109 ] && ok || bad "the KEY is the identity — the same one the queue FILE is named for, got: $B"
[ "$(jq -r .ticket_id <<<"$B")" = 109 ] && ok || bad "ticket_id must ride along for the launch, got: $B"
[ "$(jq -r .target <<<"$B")" = fly ] && ok || bad "target must ride the body, got: $B"
[ "$(jq -r .attempt <<<"$B")" = 0 ] && ok || bad "attempt must be a NUMBER, not a string, got: $B"
[ "$(jq -r .requested_by <<<"$B")" = test-box ] && ok || bad "the enqueuing box must be recorded, got: $B"

# A non-numeric attempt is dropped rather than sent as a string: the column is
# an INTEGER and a "" would land as 0, quietly resetting a requeue counter.
B=$(cl ok queue_put project-3 TK-1 "" local "" >/dev/null; body_of POST /api/queue)
[ "$(jq -r '.attempt // "absent"' <<<"$B")" = absent ] && ok || bad "an empty attempt must be omitted, got: $B"
[ "$(jq -r '.ticket_id // "absent"' <<<"$B")" = absent ] && ok || bad "an empty ticket_id must be omitted, got: $B"

# --- 2. a duplicate is a normal answer, not a failure ------------------------
OUT=$(cl dup queue_put project-3 TK-109)
[ "$(rcv)" = 0 ] && ok || bad "a duplicate enqueue is not an error, got rc=$(rcv)"
[ "$OUT" = duplicate ] && ok || bad "a duplicate must say so, got '$OUT'"

# --- 3. claim: the three answers a caller must tell apart --------------------
OUT=$(cl ok queue_claim project-3 fly)
[ "$(rcv)" = 0 ] && ok || bad "a successful claim must exit 0, got $(rcv)"
[ "$(cut -f1 <<<"$OUT")" = TK-109 ] && ok || bad "the claim must print the key first, got '$OUT'"
[ "$(cut -f2 <<<"$OUT")" = 109 ] && ok || bad "the claim must print the ticket_id, got '$OUT'"
[ "$(cut -f4 <<<"$OUT")" = 1 ] && ok || bad "the claim must print the attempt, got '$OUT'"
B=$(body_of POST /api/queue/claim)
[ "$(jq -r .box <<<"$B")" = test-box ] && ok || bad "the claiming box must ride the body, got: $B"
[ "$(jq -r .target <<<"$B")" = fly ] && ok || bad "target must ride the claim, got: $B"
[ "$(jq -r '.key // "absent"' <<<"$B")" = absent ] && ok || bad "no key means take the oldest — an empty key must not be sent, got: $B"

# EMPTY QUEUE IS rc 2, NOT rc 1. This is the whole reason the worker answers a
# 404 here: a dispatcher must be able to tell "nothing to build" (normal, every
# tick, on every quiet project) from "the coordination DB is down" (rare, and
# the only one that should fall back to reading a directory).
cl empty queue_claim project-3 >/dev/null
[ "$(rcv)" = 2 ] && ok || bad "an empty queue must be rc 2 (a real answer), got $(rcv)"

# Losing the race is rc 9 — the same clean-skip rc job_open uses for a refusal.
cl lost queue_claim project-3 >/dev/null
[ "$(rcv)" = 9 ] && ok || bad "a lost claim race must be rc 9 (clean skip), got $(rcv)"

# A named key claims exactly that row.
cl ok queue_claim project-3 "" TK-8 >/dev/null
B=$(body_of POST /api/queue/claim)
[ "$(jq -r .key <<<"$B")" = TK-8 ] && ok || bad "a named key must ride the claim, got: $B"

# --- 4. complete and release -------------------------------------------------
cl ok queue_done project-3 TK-109 done PR_CREATED >/dev/null
[ "$(rcv)" = 0 ] && ok || bad "queue_done must exit 0, got $(rcv)"
B=$(body_of PATCH /api/queue)
[ "$(jq -r .status <<<"$B")" = done ] && ok || bad "queue_done must PATCH status=done, got: $B"
[ "$(jq -r .reason <<<"$B")" = PR_CREATED ] && ok || bad "the reason must ride along, got: $B"

cl ok queue_release project-3 TK-109 "push failed" >/dev/null
B=$(body_of PATCH /api/queue)
[ "$(jq -r .status <<<"$B")" = queued ] && ok || bad "a release must put the row back to queued, got: $B"

# --- 5. list -----------------------------------------------------------------
OUT=$(cl ok queue_list project-3 queued fly)
[ "$(cut -f2 <<<"$OUT")" = TK-1 ] && ok || bad "queue_list must print the key in column 2, got '$OUT'"
[ "$(cut -f7 <<<"$OUT")" = "-" ] && ok || bad "an unclaimed row must print '-' rather than shifting the columns, got '$OUT'"
grep -q 'GET https://jobs.invalid/api/queue?project=project-3&status=queued&target=fly' "$T/req.txt" \
  && ok || bad "the list filters must reach the query string: $(cat "$T/req.txt")"
# The REASON is column 9 (2026-09-11). bin/jobs-watchdog.sh sweeps rows closed
# carrying a deferral, and until now the one field that says so was dropped on
# the floor. Appended, never inserted: every other reader indexes 1-8.
[ "$(cut -f9 <<<"$OUT")" = "BUILD_DEFERRED REFUSED box :: box max 1 already running" ] \
  && ok || bad "column 9 must be the reason, flattened to one line, got '$(cut -f9 <<<"$OUT")'"
[ "$(wc -l <<<"$OUT")" = 1 ] \
  && ok || bad "a multi-line reason must not split one row into two: '$OUT'"
# Column 10 is the row's META, where a fly requeue keeps its `deferrals` count
# (stand-downs, counted apart from `attempt`, which is deaths). Absent prints
# "-" like every other field, so column 9 never shifts into it.
[ "$(cut -f10 <<<"$OUT")" = "-" ] \
  && ok || bad "a row with no meta must print '-' in column 10, got '$(cut -f10 <<<"$OUT")'"
# ...and the worker can be ASKED for only those rows, so a page of finished
# builds cannot bury today's deferral.
cl ok queue_list project-3 done "" deferred >/dev/null
grep -q 'reason_deferred=1' "$T/req.txt" \
  && ok || bad "the deferred filter never reached the query string: $(tail -1 "$T/req.txt")"
cl ok queue_list project-3 done >/dev/null
grep -q 'reason_deferred' <<<"$(tail -1 "$T/req.txt")" \
  && bad "an ordinary list must not filter on the reason: $(tail -1 "$T/req.txt")" || ok

# --- 6. FAIL OPEN — the contract every one of these inherits ------------------
# Three ways for the ledger to be unavailable. In each, the helper says nothing
# and returns nonzero, and the caller keeps its directory behaviour. None of
# them may ever look like "the queue is empty".
for MODE in down err500; do
  OUT=$(cl "$MODE" queue_claim project-3)
  [ "$(rcv)" = 1 ] && ok || bad "with the worker $MODE a claim must be rc 1 (outage), got $(rcv)"
  [ -z "$OUT" ] && ok || bad "an outage must print nothing, got '$OUT'"
  OUT=$(cl "$MODE" queue_put project-3 TK-1)
  [ "$(rcv)" = 1 ] && ok || bad "with the worker $MODE an enqueue must be rc 1, got $(rcv)"
  [ -z "$OUT" ] && ok || bad "an outage must print nothing, got '$OUT'"
done

# No secret on the box: same story, and quietly.
RC=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$T" JOBS_URL=https://jobs.invalid CURL_MODE=ok
        unset HARNESS_SECRET
        # shellcheck source=/dev/null
        . "$DIR/bin/jobs-client.sh"
        queue_claim project-3 >/dev/null 2>&1 ); echo $? )
[ "$RC" = 1 ] && ok || bad "a box with no HARNESS_SECRET must get rc 1, got $RC"

# Missing arguments are refused rather than sent as an empty-project request,
# which would claim somebody else's work.
cl ok queue_claim "" >/dev/null
[ "$(rcv)" = 1 ] && ok || bad "an empty project must refuse, got $(rcv)"
grep -q '/api/queue/claim' "$T/req.txt" && bad "an empty project must not reach the wire" || ok

# --- 7. NO SECRETS IN THE LOG ------------------------------------------------
cl err500 queue_put project-3 TK-9 >/dev/null
grep -q test-secret "$T/logs/jobs-client.log" 2>/dev/null \
  && bad "HARNESS_SECRET leaked into logs/jobs-client.log" || ok
grep -q test-secret "$T/logs/ALERTS.log" 2>/dev/null \
  && bad "HARNESS_SECRET leaked into logs/ALERTS.log" || ok

echo "queue-client-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
