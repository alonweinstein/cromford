#!/bin/bash
# tests/harness-sync-catalog-reset.bh-1042-test.sh — the budget catalog comes
# back after the worker's table is reset, not after someone notices (BH-1042.3).
#
# WHY. bin/harness-sync.sh pushes catalog/context-budgets.json into the worker's
# budget_catalog table only when state/catalog-synced differs from the manifest's
# tree sha. That stamp is a statement about a FILE, and it was being read as a
# statement about a TABLE. Reset the DB (a re-provision, a D1 wipe, a bad
# migration) and the stamp survives on the box, so nothing ever re-pushes: every
# lane silently falls back to the catalog file, forever, and the only symptom is
# numbers that come from a different resolver than the one we think we run.
#
# THE FIX IS A PROBE, and the probe has to be able to say THREE things, not two:
# "the row is there" (leave the stamp alone), "the worker says that lane resolves
# off the tier ladder, so the table has no row" (void the stamp, re-push), and
# "I could not ask" (leave the stamp alone). The third one is the whole reason
# this is a test and not a one-liner: an unreachable worker looks exactly like an
# empty table if you only check for success, and a box that re-pushes the catalog
# on every deploy during an outage is a worse bug than the one being fixed.
#
# So the negatives carry the weight here. B (transport down) and C (row present)
# must be green today AND after the fix; if a change makes them red it has turned
# an outage into a write. N is the same guard --check always needs: --check runs
# before every build on every box, and it must not open a socket to the worker.
#
# A is the defect, and it is RED until the fix lands: same sha, table emptied,
# and today's harness-sync makes no call at all.
#
# Run from anywhere: tests/harness-sync-catalog-reset.bh-1042-test.sh  (0 = pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/locks" "$T/prompts" "$T/fly" \
         "$T/catalog" "$T/checks" "$T/guardrails" "$T/config" "$T/env"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v git >/dev/null && command -v flock >/dev/null \
  && command -v rsync >/dev/null || { echo "jq/git/flock/rsync missing — skipping"; exit 0; }

CSTATE="$T/state/catalog-synced"
CALLS="$T/jc-calls.log"
LOG="$T/logs/update-runners.log"   # $LOG in bin/harness-sync.sh, line 38

# ── a real bare origin and a real clone ──────────────────────────────────────
git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/ck" 2>/dev/null
git -C "$T/ck" config user.email t@t; git -C "$T/ck" config user.name t
mkdir -p "$T/ck/bin" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog"
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"
printf 'p\n' > "$T/ck/prompts/p.md"
printf 'f\n' > "$T/ck/fly/f.txt"
printf 'fleet\n' > "$T/ck/fleet.conf"
printf '{"lanes":[{"lane":"plan","stage":"plan","ceiling_tokens":100000}]}\n' \
  > "$T/ck/catalog/context-budgets.json"

# The jobs-client STUB is committed into the checkout on purpose: harness-sync
# rsyncs $CHECKOUT/bin/ over $HARNESS/bin/ before it reaches the catalog block,
# and then invokes "$HARNESS/bin/jobs-client.sh" — a stub written only into
# $HARNESS/bin would be overwritten by the deploy it is meant to observe.
# It records every verb it is handed, so "which calls did the deploy make" is an
# artifact and not an inference.
cat > "$T/ck/bin/jobs-client.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$CALLS"
case "\${1:-}" in
  catalog-sync)  exit 0 ;;
  catalog-probe) exit "\${CATALOG_PROBE_RC:-0}" ;;
esac
exit 2
SH
chmod +x "$T/ck/bin/jobs-client.sh"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null
git -C "$T/ck" push -q origin main
git -C "$T/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1

sync() { # sync [--check] -> rc in $RC
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck"
    bash "$DIR/bin/harness-sync.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
shaof() { [ -f "$1" ] && sha256sum < "$1" | cut -d' ' -f1 || echo MISSING; }
nsync() { local n; n=$(grep -c '^catalog-sync ' "$CALLS" 2>/dev/null); echo "${n:-0}"; }
# A deploy from a clean slate: no stamp, so the existing push block runs and the
# stamp is written. Every case below starts from exactly this state.
baseline() { rm -f "$CSTATE"; : > "$CALLS"; : > "$LOG"; sync; }

# ── S0. SAFETY PROBE, and it runs before anything else ──────────────────────
# bin/harness-sync.sh's deploy path rsyncs $CHECKOUT/{bin,prompts,fly,catalog}
# and copies fleet.conf into $HARNESS. If it does not honour $HARNESS, every
# deploy below writes this fixture straight over the REAL /root/harness — and
# this fixture's bin/ is a one-line jobs-client stub, which would be the fleet's
# jobs-client. Behavioural probe, not a grep: a DIRTY checkout refuses at rc 30
# and writes its REFUSED line to $HARNESS/logs/ALERTS.log BEFORE any rsync. If
# that line is not in the scratch tree, abort without running a deploy.
echo probe >> "$T/ck/bin/x.sh"
sync
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$T/logs/ALERTS.log" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC, nothing in $T/logs/ALERTS.log) —"
  echo "      refusing to run the deploy path, which would rsync this fixture over the live /root/harness."
  echo "harness-sync-catalog-reset.bh-1042-test: 0 passed, 1 failed"
  exit 1
fi
ok
git -C "$T/ck" checkout -q -- bin/x.sh
: > "$T/logs/ALERTS.log"; rm -f "$T/state/harness-sync-last-refused"

# ============================================================================
# A. THE DEFECT. Same sha, table emptied underneath us: the deploy must ask,
#    hear "no row", void its own stamp and push again.
# ============================================================================
baseline
[ "$RC" = 0 ] && ok || bad "A: the first deploy must exit 0, got $RC: $(cat "$T/out.txt") $(cat "$T/err.txt")"
[ "$(nsync)" = 1 ] && ok || bad "A: a first deploy with no stamp must push the catalog exactly once, saw $(nsync): $(cat "$CALLS")"
[ -s "$CSTATE" ] && ok || bad "A: the first deploy must write state/catalog-synced"
: > "$LOG"

export CATALOG_PROBE_RC=2   # the worker answered off the tier ladder: no row
sync
unset CATALOG_PROBE_RC
[ "$RC" = 0 ] && ok || bad "A: the re-push deploy must exit 0, got $RC: $(cat "$T/out.txt") $(cat "$T/err.txt")"
[ "$(nsync)" = 2 ] && ok \
  || bad "A: a probe that says the budget_catalog row is GONE must void the stamp and re-push — expected 2 catalog-sync calls on the same sha, saw $(nsync). Calls: $(tr '\n' '|' < "$CALLS")"
[ -s "$CSTATE" ] && ok || bad "A: the re-push must leave state/catalog-synced written again"
grep -q 'budget catalog stamp voided' "$LOG" && ok \
  || bad "A: voiding the stamp must be on the record in $LOG, got: $(tr '\n' '|' < "$LOG")"

# ============================================================================
# B. NEGATIVE, and the one that matters most. The probe could not reach the
#    worker (rc 1). An outage is not a reset: the stamp stays, nothing is
#    pushed. Getting this wrong turns a blink into a PUT on every deploy.
# ============================================================================
baseline
B_STAMP=$(shaof "$CSTATE")
export CATALOG_PROBE_RC=1
sync
unset CATALOG_PROBE_RC
[ "$RC" = 0 ] && ok || bad "B: an unreachable probe must not fail the deploy, got $RC: $(cat "$T/out.txt")"
[ "$(nsync)" = 1 ] && ok \
  || bad "B: a probe that could not ask must NOT re-push (an outage is not a reset) — expected 1 catalog-sync call, saw $(nsync)"
[ "$(shaof "$CSTATE")" = "$B_STAMP" ] && ok \
  || bad "B: an unreachable probe must leave state/catalog-synced byte-identical"
grep -q 'budget catalog stamp voided' "$LOG" \
  && bad "B: an unreachable probe must not claim it voided anything" || ok

# ============================================================================
# C. NEGATIVE. The row is there (rc 0). This is the every-deploy case: a probe
#    that answered "catalog" must cost exactly nothing.
# ============================================================================
baseline
C_STAMP=$(shaof "$CSTATE")
export CATALOG_PROBE_RC=0
sync
unset CATALOG_PROBE_RC
[ "$RC" = 0 ] && ok || bad "C: a satisfied probe must not fail the deploy, got $RC: $(cat "$T/out.txt")"
[ "$(nsync)" = 1 ] && ok || bad "C: a row that is present must not be re-pushed, saw $(nsync) catalog-sync calls"
[ "$(shaof "$CSTATE")" = "$C_STAMP" ] && ok || bad "C: a satisfied probe must leave state/catalog-synced untouched"

# ============================================================================
# N. NEGATIVE. --check runs before every build on every box in the fleet. It
#    exits at line ~99 and must never reach the catalog block — not the probe,
#    not the push, not one byte of traffic to the worker.
# ============================================================================
: > "$CALLS"
sync --check
[ "$RC" = 0 ] && ok || bad "N: --check on a fresh checkout must exit 0, got $RC: $(cat "$T/out.txt")"
[ ! -s "$CALLS" ] && ok \
  || bad "N: --check must not call jobs-client.sh at all, it called: $(tr '\n' '|' < "$CALLS")"

# ============================================================================
# D. THE PROBE ITSELF, driven against the REAL bin/jobs-client.sh with a
#    stubbed curl. Every claim below is about a request that was made (or was
#    not made) and a return code — never about a log line.
#
#    The lane key is not ours to invent: catalogEntries() in
#    worker/jobs/src/index.js (~205) writes `<stage>/<project // "*">/<runner //
#    "*">` for each lanes[] entry with a NUMERIC ceiling_tokens, so the probe
#    has to ask about a key that side really wrote. Ask about a key that does
#    not exist and the worker falls back to the tier ladder — which is exactly
#    the answer that means "the table is empty", so a wrong key would report a
#    reset on a perfectly healthy worker, every deploy.
# ============================================================================
JCD="$T/jc"
mkdir -p "$JCD/bin" "$JCD/env" "$JCD/logs" "$JCD/state" "$JCD/fakebin"
cp "$DIR/bin/jobs-client.sh" "$JCD/bin/jobs-client.sh"
mkdir -p "$JCD/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$JCD/bin/lib/jobs/"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$JCD/env/global.env"
REQ_LOG_F="$JCD/req.log"; : > "$REQ_LOG_F"

# curl shim: records METHOD URL BODY, then returns $CURL_RESP body + status.
cat > "$JCD/fakebin/curl" <<'SH'
#!/bin/bash
URL=""; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; shift 2;;
    -H|-m|--connect-timeout|-w) shift 2;;
    -sS|-S|-s) shift;;
    *) URL="$1"; shift;;
  esac
done
[ -n "${REQ_LOG:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_LOG"
[ "${CURL_MODE:-ok}" = down ] && exit 7
[ -n "${CURL_RESP:-}" ] && [ -r "$CURL_RESP" ] && { cat "$CURL_RESP"; exit 0; }
printf '{"ok":true}\n200\n'
SH
chmod +x "$JCD/fakebin/curl"

jc() { # jc <verb> [args...] -> rc in $RC
  ( export PATH="$JCD/fakebin:$PATH" HARNESS="$JCD" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.test JOBS_BOX=testbox REQ_LOG="$REQ_LOG_F" \
           JOBS_RETRIES=0 CURL_RESP="${CURL_RESP:-}" CURL_MODE="${CURL_MODE:-ok}"
    bash "$JCD/bin/jobs-client.sh" "$@" ) >"$JCD/out.txt" 2>"$JCD/err.txt"
  RC=$?
}
firstreq() { awk 'NR==1{print $1" "$2}' "$REQ_LOG_F" 2>/dev/null; }

MAN="$JCD/context-budgets.json"
printf '{"lanes":[{"lane":"plan","stage":"plan","ceiling_tokens":100000}]}\n' > "$MAN"
MAN_BAD="$JCD/context-budgets-nonnumeric.json"
printf '{"lanes":[{"stage":"plan","ceiling_tokens":"lots"}]}\n' > "$MAN_BAD"

# D1. The row is served from the table: source=catalog -> rc 0, and the request
# is the GET for the key the worker writes for this lane.
printf '{"lane":"plan/*/*","matched":"plan/*/*","source":"catalog","budget_usd":1,"explicit":0}\n200\n' \
  > "$JCD/resp-catalog.json"
: > "$REQ_LOG_F"; CURL_RESP="$JCD/resp-catalog.json" CURL_MODE=ok jc catalog-probe "$MAN"
[ "$RC" = 0 ] && ok \
  || bad "D1: a lane served from the catalog table must exit 0, got $RC: $(head -c 90 "$JCD/err.txt")"
[ "$(firstreq)" = 'GET https://jobs.test/api/catalog/plan/*/*' ] && ok \
  || bad "D1: the probe must GET the key catalogEntries() writes for that lane, saw: $(firstreq)"

# D2. source=tier means the lane fell through to the ladder: the table has no
# row on it. rc 2 — and the request has to have HAPPENED, or "exit 2" is just
# the usage error an unknown verb already returns.
printf '{"lane":"plan/*/*","matched":null,"source":"tier","budget_usd":2}\n200\n' \
  > "$JCD/resp-tier.json"
: > "$REQ_LOG_F"; CURL_RESP="$JCD/resp-tier.json" CURL_MODE=ok jc catalog-probe "$MAN"
[ "$RC" = 2 ] && ok \
  || bad "D2: an answer that resolved off the tier ladder must exit 2, got $RC: $(head -c 90 "$JCD/err.txt")"
[ -s "$REQ_LOG_F" ] && ok || bad "D2: rc 2 must be a WORKER ANSWER, but no request was made at all"
[ "$(firstreq)" = 'GET https://jobs.test/api/catalog/plan/*/*' ] && ok \
  || bad "D2: the probe must GET the lane key, saw: $(firstreq)"

# D3. The worker is unreachable. rc 1, never 2: harness-sync treats 2 as "the
# table was reset" and would push the catalog on every deploy of an outage.
: > "$REQ_LOG_F"; CURL_RESP="$JCD/resp-catalog.json" CURL_MODE=down jc catalog-probe "$MAN"
[ "$RC" = 1 ] && ok \
  || bad "D3: an unreachable worker must exit 1 (never 2 — that means 'reset'), got $RC: $(head -c 90 "$JCD/err.txt")"

# D4. No lane in the manifest carries a numeric ceiling_tokens, so there is no
# key the worker would have written. Nothing to ask about: rc 1, and NOT ONE
# REQUEST — an empty answer to a question nobody can form is not evidence of a
# reset.
: > "$REQ_LOG_F"; CURL_RESP="$JCD/resp-catalog.json" CURL_MODE=ok jc catalog-probe "$MAN_BAD"
[ "$RC" = 1 ] && ok \
  || bad "D4: a manifest with no numeric ceiling_tokens must exit 1, got $RC: $(head -c 90 "$JCD/err.txt")"
[ ! -s "$REQ_LOG_F" ] && ok \
  || bad "D4: with no lane key to ask about the probe must make NO request, it made: $(tr '\n' '|' < "$REQ_LOG_F")"

echo "harness-sync-catalog-reset.bh-1042-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
