#!/bin/bash
# tests/merge-queue-db-test.sh — state/merge-queue/<project>/<pr> as rows.
#
# THE HOP THIS REMOVES. A tier-1 APPROVE from a fly build reaches the merge
# queue by bin/fly-pool.sh / bin/fly-results-ingest.sh `ssh`-ing into the OWNING
# box to `touch` a filename, because the queue that PR must join lives on that
# box. When the box is unreachable the approve is dropped with one log line.
#
# WHY DRIVEN AND NOT GREPPED. Three claims here are about control flow that
# fails silently: a parked PR must not be re-offered by the materialiser, a
# dequeued-because-closed PR must not be recorded as LANDED (that would put a
# lie in a ledger merges read), and an outage must leave the directory behaving
# exactly as it does now. None of those is visible in a grep.
#
# curl, gh, flock and git are stubbed; the queue is driven only as far as its
# per-PR state check, which is the decision under test.
# Run from anywhere: tests/merge-queue-db-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/state/merge-queue/project-3" "$T/h/env" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
# The queue's PR read goes through bin/lib/merge-conductor-lib.sh -> gh-rest.sh
# (BH-784), so the fixture tree carries both, exactly as a box does. Without them
# the queue's fail-closed shim answers "unverifiable" to every row and this suite
# would be green on a queue that never reads anything.
mkdir -p "$T/h/bin/lib"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
: > "$T/h/env/global.env"
printf 'project-3 example-org/project-3 - - 2 box-project-3-1\n' > "$T/h/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/deploy-request.sh"; chmod +x "$T/h/bin/deploy-request.sh"

# gh: the PR is CLOSED, so the serial loop dequeues it. That is the fast path
# through this script AND the one whose row transition is easiest to get wrong.
#
# THE READ IS REST NOW (BH-784): `gh api -i -X GET repos/<slug>/pulls/<n>`,
# judged on its HTTP status line. restpr prints the real pull shape — CLOSED is
# state "closed" with merged_at null, which is exactly what must NOT be read as
# a merge. tests/lib/rest-emit.sh is the emitter.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none" from a real read (not a fallback on an unreadable probe).
case "$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
case "$*" in
  *"api -i -X GET repos/"*"/pulls/"*) restpr CLOSED ticket-head ticket/x main "" ;;
  *)                                  echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-rows}" in
  down)   exit 7 ;;
  norows) case "$URL" in
            */api/merge-queue\?*) printf '{"merge_queue":[]}\n200\n' ;;
            *)                    printf '{"ok":true}\n200\n' ;;
          esac ;;
  *) case "$URL" in
       */api/merge-queue\?*) printf '{"merge_queue":[{"project":"project-3","pr":41,"status":"queued","repo":"example-org/project-3","enqueued_by":"hub","enqueued_at":"2026-09-10T01:00:00Z","reason":"tier-1 APPROVE from pool build TK-9"}]}\n200\n' ;;
       */api/merge-queue)    printf '{"merge":{"project":"project-3","pr":41,"status":"queued"},"duplicate":false}\n201\n' ;;
       */api/flags/*)        printf '{"error":"not found"}\n404\n' ;;
       *)                    printf '{"ok":true}\n200\n' ;;
     esac ;;
esac
EOF
chmod +x "$T/fakebin/curl"

mq() { # mq <curl-mode>
  : > "$T/req.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=box-project-3-1 JOBS_RETRIES=0 \
           CURL_MODE="$1" REQ_SINK="$T/req.txt"
    bash "$DIR/bin/merge-queue.sh" project-3 >/dev/null 2>&1 )
}
Q="$T/h/state/merge-queue/project-3"
body_of() {
  grep -m1 "^$1 https://jobs.invalid$2 " "$T/req.txt" \
    | awk '{ $1=""; $2=""; sub(/^ +/, ""); print }'
}

# ══ 1. A QUEUED ROW BECOMES A QUEUE ENTRY ON THIS BOX ═══════════════════════
mq rows
grep -q '#41 taken from the coordination DB' "$T/h/logs/merge-queue.log" 2>/dev/null \
  && ok || bad "a queued row must be materialised into this box's queue: $(cat "$T/h/logs/merge-queue.log" 2>/dev/null)"

# ...and the CLOSED PR is dequeued and recorded as DROPPED, never as landed.
# `landed` for a PR that closed without merging is a lie in the one ledger a
# merge decision reads.
[ ! -f "$Q/41" ] && ok || bad "a PR that is not OPEN must be dequeued"
B=$(body_of PATCH /api/merge-queue)
[ "$(jq -r .status <<<"$B")" = dropped ] && ok || bad "a dequeued-because-closed PR must be 'dropped', not 'landed'. Got: $B"
[ "$(jq -r .pr <<<"$B")" = 41 ] && ok || bad "the transition must name the PR as a NUMBER, got: $B"
grep -q 'state=CLOSED' <<<"$B" && ok || bad "the row must carry WHY it was dequeued — that is what a filename could not say: $B"

# ══ 2. A PARKED PR STAYS PARKED ═════════════════════════════════════════════
# .blocked is this queue's own record that a human was asked to look. Re-
# materialising over it would put the PR back in front of the merge machinery.
rm -f "$T/h/logs/merge-queue.log"
: > "$Q/41.blocked"
mq rows
[ ! -f "$Q/41" ] && ok || bad "a row must not be re-materialised over a .blocked entry"
rm -f "$Q/41.blocked"

# ══ 3. FAIL OPEN ════════════════════════════════════════════════════════════
# No rows, or no worker, and this reads exactly the directory it always did.
rm -f "$T/h/logs/merge-queue.log"
mq norows
[ ! -f "$Q/41" ] && ok || bad "an empty table must materialise nothing"
: > "$Q/77"
mq down
[ ! -f "$Q/77" ] && ok || bad "with the worker down the directory entry must still be processed (dequeued here, since the PR is CLOSED)"
grep -q '#77 dequeued' "$T/h/logs/merge-queue.log" 2>/dev/null \
  && ok || bad "with the worker down the queue must behave exactly as today: $(cat "$T/h/logs/merge-queue.log" 2>/dev/null)"

# BH-1366: section 4 drove bin/tier2-merge-sweep.sh and pinned that it wrote
# both the row and the file. That lane is retired; the enqueue happens at the
# APPROVE verdict now, and tests/merge-queue-enqueue-on-verdict.bh-1366-test.sh
# §A pins the row it writes and §A12 the file it falls back to.

# ══ 5. NO SECRETS ═══════════════════════════════════════════════════════════
grep -rq test-secret "$T/h/logs" 2>/dev/null && bad "HARNESS_SECRET leaked into a log" || ok

echo "merge-queue-db-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
