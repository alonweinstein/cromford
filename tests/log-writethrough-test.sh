#!/bin/bash
# tests/log-writethrough-test.sh — BH-436: write-through for the two append
# logs (decisions, findings) and rehydrate-on-empty for their three readers.
#
# Driven against the REAL bin/*.sh scripts with a stubbed curl, never against an
# extracted function: every claim below is about a file that was written, a
# request that was recorded, or an exit code.
#
# THE REHYDRATE FIXTURE IS THE WRITER'S OWN PAYLOAD. `$CURL_FINDINGS` /
# `$CURL_DECISIONS` are built by jq-transforming the POST body this suite just
# recorded into the `{rows,truncated,as_of}` envelope the worker serves
# (worker/jobs/src/index.js listLines). So "rehydrate re-emits what the writer
# wrote" is a real round trip, and the suite reads the wall clock zero times
# itself — every stamp in it came out of the script under test.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/flags" "$T/locks" "$T/stub" \
         "$T/state/rule-mining" "$T/builds"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"
: > "$T/fleet.conf"
: > "$T/req.log"

# flock is stubbed because rule-miner's `flock -n 9 || exit 0` would otherwise
# let this suite pass by doing nothing on a box where the lock is held; gh must
# never be reached in dry mode, so it fails loudly if it is.
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"; chmod +x "$T/stub/flock"
printf '#!/bin/sh\necho "gh called in dry mode" >&2\nexit 1\n' > "$T/stub/gh"; chmod +x "$T/stub/gh"

# curl shim: records METHOD URL BODY, then DISPATCHES ON URL. Every path that is
# not one of the two append-log routes answers 404 — which jobs-client reads as
# "no row", not as an outage — so the flag/lane lookups rule-miner makes on the
# way past never burn the daily ALERT flag this suite counts in B2.
cat > "$T/stub/curl" <<'SH'
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
case "$URL" in
  */api/findings*)
    if [ "$METHOD" = GET ]; then
      [ -n "${CURL_FINDINGS:-}" ] && [ -r "${CURL_FINDINGS:-}" ] && { cat "$CURL_FINDINGS"; exit 0; }
      printf '{"rows":[],"truncated":false,"as_of":"2026-01-01T00:00:00Z"}\n200\n'; exit 0
    fi
    printf '{"inserted":1,"ignored":0,"as_of":"2026-01-01T00:00:00Z"}\n200\n'; exit 0;;
  */api/decisions*)
    if [ "$METHOD" = GET ]; then
      [ -n "${CURL_DECISIONS:-}" ] && [ -r "${CURL_DECISIONS:-}" ] && { cat "$CURL_DECISIONS"; exit 0; }
      printf '{"rows":[],"truncated":false,"as_of":"2026-01-01T00:00:00Z"}\n200\n'; exit 0
    fi
    printf '{"inserted":1,"ignored":0,"as_of":"2026-01-01T00:00:00Z"}\n200\n'; exit 0;;
esac
printf '\n404\n'
SH
chmod +x "$T/stub/curl"

# JOBS_RETRIES=0: the one retry is a transport-blip policy that belongs to the
# client's own suite; here it would only add a sleep to every outage case.
# HARNESS_SECRET/JOBS_URL are pinned here, not inherited: jobs-client.sh only
# falls back to env/global.env when the secret is UNSET, so a box that has the
# real ones exported would point this suite at the production worker.
run() { # run <script-path> <args...>  (in $T as HARNESS, shim on PATH)
  ( export PATH="$T/stub:$PATH" HARNESS="$T" REQ_LOG="$T/req.log" JOBS_BOX=testbox \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
           JOBS_RETRIES=0 CURL_MODE="${CURL_MODE:-ok}" \
           CURL_FINDINGS="${CURL_FINDINGS:-}" CURL_DECISIONS="${CURL_DECISIONS:-}"
    bash "$@" )
}
reqcount() { local n; n=$(grep -cF -- "$1" "$T/req.log" 2>/dev/null); printf '%s' "${n:-0}"; }
lastbody() { grep -F -- "$1" "$T/req.log" | tail -1 | cut -d' ' -f3-; }
DLOG="$T/logs/decisions.log"
FLOG="$T/logs/findings.log"

# ── B1. decision-log.sh: file first, one POST /api/decisions ─────────────────
cat > "$T/out1.txt" <<'EOF'
Worked the queue this tick.
DECISION: TK-12 :: launch :: client confirmed mechanism in latest comment
DECISION: TK-40 :: skip :: waitingOn=client, triage questions unanswered
tickets=2 handled
EOF
run "$DIR/bin/decision-log.sh" p1 board-changed full "$T/out1.txt"; RC=$?
[ "$RC" = 0 ] && ok || bad "B1 decision-log rc=$RC"
grep -q '\[p1\] gate=board-changed scope=full TK-12 :: launch :: client confirmed' "$DLOG" \
  && grep -q 'TK-40 :: skip :: waitingOn=client' "$DLOG" \
  && ok || bad "B1 file shape changed (got: $(cat "$DLOG" 2>/dev/null))"
[ "$(wc -l < "$DLOG")" = 2 ] && ok || bad "B1 wrote $(wc -l < "$DLOG") lines, want 2"
N=$(reqcount 'POST https://jobs.test/api/decisions')
[ "$N" = 1 ] && ok || bad "B1 recorded $N POST /api/decisions, want 1"
BODY=$(lastbody 'POST https://jobs.test/api/decisions')
printf '%s' "$BODY" | jq -e '.project == "p1"' >/dev/null 2>&1 && ok || bad "B1 body .project: $BODY"
printf '%s' "$BODY" | jq -e '.rows | length == 2' >/dev/null 2>&1 && ok || bad "B1 body rows length: $BODY"
printf '%s' "$BODY" | jq -e '.rows | all(.line | startswith("[p1] gate="))' >/dev/null 2>&1 \
  && ok || bad "B1 row .line does not start with [p1] gate=: $BODY"
printf '%s' "$BODY" | jq -e '.rows[0].ticket == "TK-12" and .rows[1].ticket == "TK-40"' >/dev/null 2>&1 \
  && ok || bad "B1 row .ticket: $BODY"
printf '%s' "$BODY" | jq -e '.rows[0].gate == "board-changed" and .rows[0].scope == "full"' >/dev/null 2>&1 \
  && ok || bad "B1 row gate/scope: $BODY"
# The round-trip invariant: log_rehydrate re-emits `stamp + " " + line`, so that
# concatenation must equal the file line the same run appended.
printf '%s' "$BODY" | jq -r '.rows[] | .stamp + " " + .line' > "$T/b1-roundtrip.txt"
cmp -s "$T/b1-roundtrip.txt" "$DLOG" && ok \
  || bad "B1 stamp+line != file line (rows: $(cat "$T/b1-roundtrip.txt"); file: $(cat "$DLOG"))"
cp "$DLOG" "$T/b1-decisions.log"
# the GET fixture for B4c, built from what the writer actually sent
printf '%s' "$BODY" | jq -c '{rows:.rows,truncated:false,as_of:"2026-01-01T00:00:00Z"}' > "$T/get-decisions.json"
printf '\n200\n' >> "$T/get-decisions.json"

# no DECISION lines -> no POST at all, still rc 0
: > "$T/req.log"
echo "just a summary, no decisions block" > "$T/out2.txt"
run "$DIR/bin/decision-log.sh" p1 queue-pending queue "$T/out2.txt"; RC=$?
[ "$RC" = 0 ] && ok || bad "B1 empty-input rc=$RC"
[ ! -s "$T/req.log" ] && ok || bad "B1 empty input made a request: $(cat "$T/req.log")"
[ "$(wc -l < "$DLOG")" = 2 ] && ok || bad "B1 empty input appended to the file"

# ── B2. worker down: the file is written anyway, one ALERTS line ─────────────
: > "$T/req.log"; rm -f "$DLOG"
CURL_MODE=down run "$DIR/bin/decision-log.sh" p1 board-changed full "$T/out1.txt"; RC=$?
[ "$RC" = 0 ] && ok || bad "B2 outage rc=$RC (want 0)"
[ -s "$DLOG" ] && ok || bad "B2 outage lost the file write"
# identical to B1's file except for the 20-char stamp, which is the wall clock
cut -c21- < "$T/b1-decisions.log" > "$T/b1-nostamp.txt"
cut -c21- < "$DLOG" > "$T/b2-nostamp.txt"
cmp -s "$T/b1-nostamp.txt" "$T/b2-nostamp.txt" && ok \
  || bad "B2 outage file differs from B1's: $(cat "$DLOG")"
A=$(grep -c 'harness-jobs unreachable' "$T/logs/ALERTS.log" 2>/dev/null)
[ "${A:-0}" = 1 ] && ok || bad "B2 wrote ${A:-0} ALERTS lines, want exactly 1"
CURL_MODE=down run "$DIR/bin/decision-log.sh" p1 board-changed full "$T/out1.txt" >/dev/null 2>&1
A=$(grep -c 'harness-jobs unreachable' "$T/logs/ALERTS.log" 2>/dev/null)
[ "${A:-0}" = 1 ] && ok || bad "B2 second outage added an ALERTS line (now ${A:-0}) — daily flag broken"
rm -f "$DLOG"

# ── B3. findings-log.sh: rows appended, then one POST /api/findings ──────────
: > "$T/req.log"
B="$T/builds/b1"; mkdir -p "$B"
cp "$DIR/catalog/fixtures/findings/review-block.md" "$B/review.md"
run "$DIR/bin/findings-log.sh" "$B" project-2 TK-208; RC=$?
[ "$RC" = 0 ] && ok || bad "B3 findings-log rc=$RC"
grep -q 'ticket=TK-208 lens=general verdict=BLOCK rule=D14 family=[0-9a-f]\{12\} :: ' "$FLOG" \
  && ok || bad "B3 file shape changed (got: $(head -1 "$FLOG" 2>/dev/null))"
grep -q 'rule=D1 family=' "$FLOG" && ok || bad "B3 D1 citation missing from the file"
grep -q 'rule=D25 family=' "$FLOG" && ok || bad "B3 D25 citation missing from the file"
[ -f "$B/.findings-general" ] && ok || bad "B3 per-lens marker not written"
N=$(reqcount 'POST https://jobs.test/api/findings')
[ "$N" = 1 ] && ok || bad "B3 recorded $N POST /api/findings, want 1"
FBODY=$(lastbody 'POST https://jobs.test/api/findings')
printf '%s' "$FBODY" | jq -e '.project == "project-2"' >/dev/null 2>&1 \
  && ok || bad "B3 body .project: $FBODY"
LINES=$(wc -l < "$FLOG")
printf '%s' "$FBODY" | jq -e --argjson n "$LINES" '.rows | length == $n' >/dev/null 2>&1 \
  && ok || bad "B3 rows length != $LINES appended lines: $FBODY"
printf '%s' "$FBODY" | jq -e '.rows | all(.lens == "general" and .ticket == "TK-208")' >/dev/null 2>&1 \
  && ok || bad "B3 row lens/ticket: $FBODY"
printf '%s' "$FBODY" | jq -r '.rows[] | .stamp + " " + .line' > "$T/b3-roundtrip.txt"
cmp -s "$T/b3-roundtrip.txt" "$FLOG" && ok \
  || bad "B3 stamp+line != appended file lines (rows: $(cat "$T/b3-roundtrip.txt"))"
cp "$FLOG" "$T/b3-findings.log"
printf '%s' "$FBODY" | jq -c '{rows:.rows,truncated:false,as_of:"2026-01-01T00:00:00Z"}' > "$T/get-findings.json"
printf '\n200\n' >> "$T/get-findings.json"

# ── B4a. rule-miner.sh rehydrates findings.log, byte-identical ───────────────
: > "$T/req.log"; rm -f "$FLOG"
CURL_FINDINGS="$T/get-findings.json" RULE_MINER_DRY=1 run "$DIR/bin/rule-miner.sh" >/dev/null 2>&1
[ -s "$FLOG" ] && ok || bad "B4a rule-miner did not rehydrate findings.log"
cmp -s "$T/b3-findings.log" "$FLOG" && ok \
  || bad "B4a rehydrated findings.log is not byte-identical to B3's ($(diff "$T/b3-findings.log" "$FLOG" | head -4))"
N=$(reqcount 'GET https://jobs.test/api/findings')
[ "$N" = 1 ] && ok || bad "B4a recorded $N GET /api/findings, want 1"
grep -q 'GET https://jobs.test/api/findings?since=' "$T/req.log" && ok || bad "B4a rehydrate did not pass a since cursor"  # determinism: ok the cursor is jobs-client's own and this asserts presence, never a value
CURL_FINDINGS="$T/get-findings.json" RULE_MINER_DRY=1 run "$DIR/bin/rule-miner.sh" >/dev/null 2>&1
N=$(reqcount 'GET https://jobs.test/api/findings')
[ "$N" = 1 ] && ok || bad "B4a a non-empty findings.log still cost a GET (now $N)"

# ── B4b. repeat-family.sh rehydrates the same file ──────────────────────────
: > "$T/req.log"; rm -f "$FLOG"
OUT=$(CURL_FINDINGS="$T/get-findings.json" run "$DIR/bin/repeat-family.sh" --line 2>/dev/null)
[ -s "$FLOG" ] && ok || bad "B4b repeat-family did not rehydrate findings.log"
cmp -s "$T/b3-findings.log" "$FLOG" && ok || bad "B4b rehydrated file differs from B3's"
case "$OUT" in *"absent or empty"*) bad "B4b still reported 'absent or empty': $OUT";; *) ok;; esac
N=$(reqcount 'GET https://jobs.test/api/findings')
[ "$N" = 1 ] && ok || bad "B4b recorded $N GET /api/findings, want 1"
OUT=$(CURL_FINDINGS="$T/get-findings.json" run "$DIR/bin/repeat-family.sh" --line 2>/dev/null)
N=$(reqcount 'GET https://jobs.test/api/findings')
[ "$N" = 1 ] && ok || bad "B4b a non-empty findings.log still cost a GET (now $N)"

# ── B4c. fetch-log.sh decisions rehydrates decisions.log ────────────────────
: > "$T/req.log"; rm -f "$DLOG"
OUT=$(CURL_DECISIONS="$T/get-decisions.json" run "$DIR/bin/fetch-log.sh" hub decisions cid1 2>/dev/null)
[ -s "$DLOG" ] && ok || bad "B4c fetch-log did not rehydrate decisions.log"
cmp -s "$T/b1-decisions.log" "$DLOG" && ok \
  || bad "B4c rehydrated decisions.log is not byte-identical to B1's"
printf '%s' "$OUT" | jq -e '.missing == false' >/dev/null 2>&1 && ok || bad "B4c beat .missing: $OUT"
SZ=$(wc -c < "$DLOG" | tr -dc '0-9')
printf '%s' "$OUT" | jq -e --argjson b "$SZ" '.bytes == $b' >/dev/null 2>&1 \
  && ok || bad "B4c beat .bytes != $SZ: $OUT"
printf '%s' "$OUT" | jq -e '.kind == "log_tail" and .which == "decisions"' >/dev/null 2>&1 \
  && ok || bad "B4c beat shape changed: $OUT"
N=$(reqcount 'GET https://jobs.test/api/decisions')
[ "$N" = 1 ] && ok || bad "B4c recorded $N GET /api/decisions, want 1"
OUT=$(CURL_DECISIONS="$T/get-decisions.json" run "$DIR/bin/fetch-log.sh" hub decisions cid2 2>/dev/null)
N=$(reqcount 'GET https://jobs.test/api/decisions')
[ "$N" = 1 ] && ok || bad "B4c a non-empty decisions.log still cost a GET (now $N)"
# --path mode never reaches the network
: > "$T/req.log"
P=$(run "$DIR/bin/fetch-log.sh" --path decisions hub 2>/dev/null)
[ "$P" = "$T/logs/decisions.log" ] && ok || bad "B4c --path mode changed: $P"
[ ! -s "$T/req.log" ] && ok || bad "B4c --path mode made a request: $(cat "$T/req.log")"

# ── B5. mutation: row before file goes red on the outage case ───────────────
# The mutant is the ORDERING and nothing else: the unconditional `cat >> $FLOG`
# is deleted and re-attached to findings_put with `&&`, so a failed POST skips
# the append. It lives under $T; the checkout is never edited.
mkb5() { # mkb5 <harness-dir>
  mkdir -p "$1/bin" "$1/env" "$1/logs" "$1/flags" "$1/builds/b5"
  cp "$DIR/bin/jobs-client.sh" "$1/bin/jobs-client.sh"
  mkdir -p "$1/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$1/bin/lib/jobs/"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$1/env/global.env"
  cp "$DIR/catalog/fixtures/findings/review-block.md" "$1/builds/b5/review.md"
}
MUT="$T/mutant-findings-log.sh"
awk '
  /^[[:space:]]*cat "\$TMP\/rows\.txt" >> "\$FLOG"[[:space:]]*$/ { dropped++; next }
  /findings_put "\$P" "\$TMP\/rows\.json"/ {
      sub(/\|\| true/, "\\&\\& cat \"$TMP/rows.txt\" >> \"$FLOG\" || true")
      moved++
  }
  { print }
  END { if (dropped != 1 || moved != 1) exit 3 }
' "$DIR/bin/findings-log.sh" > "$MUT"
if [ $? -ne 0 ]; then
  bad "B5 could not build the mutant — the shipped ordering lines were not found (mutation unproven)"
else
  ok
  chmod +x "$MUT"
  mkb5 "$T/b5-mutant"; mkb5 "$T/b5-shipped"
  ( export PATH="$T/stub:$PATH" HARNESS="$T/b5-mutant" REQ_LOG="$T/b5.req.log" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
           JOBS_BOX=testbox JOBS_RETRIES=0 CURL_MODE=down
    bash "$MUT" "$T/b5-mutant/builds/b5" project-2 TK-208 ) >/dev/null 2>&1
  if [ -s "$T/b5-mutant/logs/findings.log" ]; then
    bad "B5 mutant kept the file write — the ordering is not what the test pins"
  else
    echo "mutant: red"; ok
  fi
  ( export PATH="$T/stub:$PATH" HARNESS="$T/b5-shipped" REQ_LOG="$T/b5.req.log" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
           JOBS_BOX=testbox JOBS_RETRIES=0 CURL_MODE=down
    bash "$DIR/bin/findings-log.sh" "$T/b5-shipped/builds/b5" project-2 TK-208 ) >/dev/null 2>&1
  if [ -s "$T/b5-shipped/logs/findings.log" ]; then
    echo "shipped: green"; ok
  else
    bad "B5 shipped findings-log.sh lost the file write when the POST failed"
  fi
fi

echo "log-writethrough-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
