#!/bin/bash
# tests/jobs-client-issue-stamp-test.sh — the BH-482 contract, driven for real.
#
# Two interfaces every other BH-482 slice imports, and both of them are shell,
# so the only honest check is to run them:
#
#   1. bin/jobs-client.sh `job_open` grew a 7th positional, issue_created_at.
#      A grep would prove the line exists; it would not prove the key reaches
#      the wire, and it would not prove the SIX-argument callers that exist
#      today (claim-rules, queue-producers, orphan-reconcile, every lane) send
#      a byte-identical body. curl is stubbed and the recorded request body is
#      read back with jq, so what is asserted is the payload, not the source.
#   2. bin/launch-fastpath.sh's CONTRACT — argv, exit code, stdout, log line
#      shape — which BH-482.0 wrote as a stub and BH-554's real launcher keeps
#      every line of. The script is executed exactly as its own header
#      documents it; which reason a decline names is that launcher's business
#      and is pinned per condition in tests/launch-fastpath-test.sh.
#
# No clock is read anywhere: the issue stamp is a literal, so this suite has
# nothing to pin a NOW against.
# Run from anywhere: tests/jobs-client-issue-stamp-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/fakebin" "$T/h/logs"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Fake curl: records the request body it was handed and answers a claim.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""
while [ $# -gt 0 ]; do case "$1" in --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2;; *) shift;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s\n' "$URL $BODY" >> "$REQ_SINK"
case "$URL" in
  */api/jobs) printf '{"job":{"id":"build-p-T-1"}}\n201\n' ;;
  *)          printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

open_body() { # open_body <job_open args...> -> prints the recorded POST body
  : > "$T/req.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
           JOBS_URL=http://jobs.test JOBS_BOX=box REQ_SINK="$T/req.txt"
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh"; job_open "$@" >/dev/null; echo "rc=$?" )
}

# --- 1. the 7th positional reaches the wire, untouched -----------------------
RC=$(open_body p T build plan lane '' 2026-09-16T05:53:02Z)
BODY=$(sed 's/^[^ ]* //' "$T/req.txt" | tail -1)
[ "$RC" = "rc=0" ] && ok || bad "job_open with an issue stamp exited $RC"
STAMP=$(printf '%s' "$BODY" | jq -r '.issue_created_at // "ABSENT"' 2>/dev/null)
[ "$STAMP" = "2026-09-16T05:53:02Z" ] \
  && ok || bad "the 7th arg did not arrive as .issue_created_at (got '$STAMP' from $BODY)"

# --- 2. every caller that exists today is byte-identical ----------------------
# Six args is what claim-rules, queue-producers and orphan-reconcile pass. An
# ABSENT key is the contract, not a null and not an empty string: the worker
# column is nullable and a "" would land as a real value in a REAL ledger row.
RC=$(open_body p T build plan lane '')
BODY6=$(sed 's/^[^ ]* //' "$T/req.txt" | tail -1)
[ "$RC" = "rc=0" ] && ok || bad "a six-argument job_open exited $RC"
HAS=$(printf '%s' "$BODY6" | jq -r 'has("issue_created_at")' 2>/dev/null)
[ "$HAS" = "false" ] && ok || bad "a six-argument job_open carried issue_created_at: $BODY6"

# --- 3. an explicitly empty 7th arg is the same as no 7th arg ----------------
RC=$(open_body p T build plan lane '' '')
BODY7=$(sed 's/^[^ ]* //' "$T/req.txt" | tail -1)
[ "$RC" = "rc=0" ] && ok || bad "job_open with an empty 7th arg exited $RC"
HAS=$(printf '%s' "$BODY7" | jq -r 'has("issue_created_at")' 2>/dev/null)
[ "$HAS" = "false" ] && ok || bad "an empty 7th arg became a key: $BODY7"
[ "$BODY7" = "$BODY6" ] \
  && ok || bad "an empty 7th arg changed the body: '$BODY7' vs '$BODY6'"

# --- 4. launch-fastpath.sh declines every key, and says so twice --------------
# Once on stdout (the caller's list) and once in the project log (the operator's
# record). Both halves of the contract, run verbatim from the header.
HARNESS="$T/h" bash "$DIR/bin/launch-fastpath.sh" project-5 900 901 > "$T/out"; RC=$?
[ "$RC" = 1 ] && ok || bad "the launcher must exit 1 while it declines everything, got $RC"
[ "$(cat "$T/out")" = "$(printf '900\n901')" ] \
  && ok || bad "declined keys go to stdout one per line, got: $(cat "$T/out")"
LOG="$T/h/logs/project-5.log"
[ "$(grep -c 'FASTPATH-DECLINED' "$LOG" 2>/dev/null)" = 2 ] \
  && ok || bad "expected two FASTPATH-DECLINED lines in $LOG, got: $(cat "$LOG" 2>/dev/null)"
# The reason is the launcher's own (BH-554 replaced the stub's "fastpath not
# implemented"); which reason a given scratch harness earns is pinned per
# condition in tests/launch-fastpath-test.sh. Here only the contract's SHAPE is
# held: one canonical line per key, `FASTPATH-DECLINED <key> :: <reason>`.
[ "$(grep -cE ' FASTPATH-DECLINED 900 :: [^:].*$' "$LOG" 2>/dev/null)" = 1 ] \
  && ok || bad "the declined line does not carry the contract's shape: $(cat "$LOG" 2>/dev/null)"

# --- 5. zero keys: exit 1 and write nothing ----------------------------------
# A stub that created a log directory on a no-op run would make the box's logs
# lie about having been asked.
HARNESS="$T/h2" bash "$DIR/bin/launch-fastpath.sh"; RC=$?
[ "$RC" = 1 ] && ok || bad "no args must exit 1, got $RC"
[ ! -e "$T/h2/logs" ] && ok || bad "a no-argument run created $T/h2/logs"
HARNESS="$T/h3" bash "$DIR/bin/launch-fastpath.sh" project-5; RC=$?
[ "$RC" = 1 ] && ok || bad "a project with zero keys must exit 1, got $RC"
[ ! -e "$T/h3/logs/project-5.log" ] \
  && ok || bad "a project with zero keys wrote a log line"

echo "jobs-client-issue-stamp-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
