#!/bin/bash
# tests/alert-triage-close.bh-2544-test.sh — the CLOSE slice of BH-2544
# (BH-2570): rows the alert-triage lane claimed from the D1 `alerts` table are
# resolved through alert_resolve once a positive re-verify shows the condition
# cleared, and never otherwise.
#
#   A1       bin/triage-spool-retire.sh hands off only NOISE-STALE dbrow ids;
#            summary, archive and workfile equal a run without the hand-off.
#   A1-arch  an unwritable archive hands off nothing.
#   A2       triage_close_ids dedupes, drops a malformed id, slices at 90 and
#            logs the worker's count; rc 75 logs `close rc=75`, no retry.
#   A2-off   ALERTS_DB off: no request, one `close skipped` line per process.
#   A3u      triage_settled_ids: resolved:/superseded:/verify: dbrow only.
#   A3       the REAL bin/alert-triage.sh tick closes a MERGED-PR dbrow row and
#            a settled `resolved:` dbrow row with zero agent-calls; with the
#            hand-off removed from the retire script the MERGED-PR id is gone.
#   A3-neg   EXPIRED-AGE, EXPIRED-CONDSTATE, stale-akey and non-dbrow ids are
#            in no resolve body.
#   A3-off   flags/triage-close-off: zero resolve requests.
#
#   bash tests/alert-triage-close.bh-2544-test.sh     exit 0 = all pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/triage-close.sh"
RETIRE="$DIR/bin/triage-spool-retire.sh"
NOW=1790467200   # 2026-09-26T22:40:00Z

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$T/fakebin" "$T/calls" "$T/tmp"
printf 'CONSOLE_URL=https://console.invalid\nJOBS_URL=https://jobs.invalid\nHARNESS_SECRET=testsecret\nJOBS_RETRIES=0\nJOBS_ALERT=0\n' \
  > "$H/env/global.env"

# gh-pr-state.sh: the state of a PR url from $T/prmap, rc 75 when unknown.
cat > "$H/bin/gh-pr-state.sh" <<STUB
#!/bin/bash
S=\$(awk -v u="\$1" '\$1==u {print \$2}' "$T/prmap")
[ -n "\$S" ] || exit 75
echo "\$S"
STUB
chmod +x "$H/bin/gh-pr-state.sh"
printf 'https://github.com/example-org/project-5/pull/5001 MERGED\nhttps://github.com/example-org/project-5/pull/5002 MERGED\nhttps://github.com/example-org/project-5/pull/5003 OPEN\n' > "$T/prmap"

# Lines in the collector's shape. A dbrow payload is built the way the lane's
# claim loop builds it (jq, same field order), never typed (D4).
dbrow() { # dbrow <id> <age_s> <line>
  printf 'hub\t%s\t%s\n' "$((NOW - $2))" "$(jq -nc --arg p project-5 --arg id "$1" --arg sev warn --arg line "$3" \
    '{kind:"fleet_alert",project:$p,akey:("orclane:"+$id),alertid:$id,severity:$sev,line:$line,dbrow:true}')"
}
beat() { # beat <id> <age_s> <line> — a beat served over ssh that names an alertid
  printf 'hub\t%s\t%s\n' "$((NOW - $2))" "$(jq -nc --arg id "$1" --arg line "$3" \
    '{kind:"fleet_alert",project:"project-5",akey:("k-"+$id),alertid:$id,line:$line}')"
}
# Everything a run leaves in state/, except the model-route cache the fixture
# put there (the lane stops rc 75 without it).
state_reset() { local e; for e in "$H"/state/*; do [ "${e##*/}" = model-routes ] || scratch_rm "$e"; done; }
DAY=$(date -u -d "@$NOW" +%Y%m%d)
resp() { echo "RESPONDER: $1 waits on https://github.com/example-org/project-5/pull/$2: OPEN/CLEAN"; }

# ================= A1 — the retire step's hand-off =================
fixture_a1() {
  {
    dbrow a1 300 "$(resp one 5001)"
    beat  b1 300 "$(resp two 5002)"
    dbrow a2 $((25 * 3600)) "the widget lane is unhappy"
    dbrow a3 $((7 * 3600)) "[merge-conductor] conductor: project-5#77 WAIT_CI — 420m in WAIT_CI: waiting https://github.com/example-org/project-5/pull/5003"
    dbrow a4 300 "$(resp four 5003)"
  } > "$1"
}
retire_run() { # retire_run <tag> [ids-out] — runs the retire step on a fresh copy
  state_reset
  fixture_a1 "$T/a1-$1.work"
  if [ -n "${2:-}" ]; then
    HARNESS="$H" TRIAGE_NOW="$NOW" TRIAGE_RETIRE_IDS_OUT="$2" "$RETIRE" "$T/a1-$1.work" > "$T/a1-$1.sum" 2>"$T/a1-$1.err"
  else
    HARNESS="$H" TRIAGE_NOW="$NOW" "$RETIRE" "$T/a1-$1.work" > "$T/a1-$1.sum" 2>"$T/a1-$1.err"
  fi
  cat "$H"/state/alert-triage-expired-*.tsv > "$T/a1-$1.arch" 2>/dev/null || : > "$T/a1-$1.arch"
}
: > "$T/ids-a1"
retire_run with "$T/ids-a1"
retire_run without
[ "$(cat "$T/ids-a1")" = "a1" ] && ok \
  || bad "A1: the ids file must hold exactly the MERGED-PR dbrow id a1 (got: $(tr '\n' ' ' < "$T/ids-a1"))"
grep -q 'stale=2 ' "$T/a1-with.sum" && grep -q 'aged=1 condstate=1 ' "$T/a1-with.sum" && ok \
  || bad "A1: the fixture must retire one of each reason, else A1 is vacuous (summary: $(cat "$T/a1-with.sum"))"
grep -q 'NOISE-STALE' "$T/a1-with.arch" && grep -q '"alertid":"b1"' "$T/a1-with.arch" && ok \
  || bad "A1: b1 (non-dbrow) must be retired NOISE-STALE too, so its absence from the ids is the dbrow rule"
for f in sum arch work; do
  cmp -s "$T/a1-with.$f" "$T/a1-without.$f" && ok \
    || bad "A1: the $f must be byte-identical with and without TRIAGE_RETIRE_IDS_OUT: $(diff "$T/a1-with.$f" "$T/a1-without.$f" | head -4)"
done
[ ! -s "$T/a1-with.err" ] && ok || bad "A1: nothing on stderr (got: $(cat "$T/a1-with.err"))"

# A1-arch — the archive cannot be written: the lines go back, no id goes out.
state_reset; mkdir -p "$H/state/alert-triage-expired-$DAY.tsv"
fixture_a1 "$T/a1-arch.work"; : > "$T/ids-arch"
HARNESS="$H" TRIAGE_NOW="$NOW" TRIAGE_RETIRE_IDS_OUT="$T/ids-arch" "$RETIRE" "$T/a1-arch.work" > "$T/a1-arch.sum" 2>"$T/a1-arch.err"
grep -q 'archive unwritable' "$T/a1-arch.err" && ok || bad "A1-arch: the fixture must hit the unwritable archive (stderr: $(cat "$T/a1-arch.err"))"
[ ! -s "$T/ids-arch" ] && ok || bad "A1-arch: an unwritable archive hands off nothing (got: $(cat "$T/ids-arch"))"
state_reset

# ================= A2 — triage_close_ids =================
# The real alert_resolve over a recording _jobs_req. The stub answers one LESS
# than it was sent, so a `resolved=` equal to the sent count would be the
# lane counting m, not reading the worker's answer.
cat > "$T/a2-stub.sh" <<STUB
_jobs_req() {
  printf '%s\n' "\$3" >> "$T/a2-reqs"
  [ "\${STUB_RC:-0}" = 0 ] || return "\$STUB_RC"
  printf '{"resolved":%s}\n' "\$(( \$(jq '.ids|length' <<<"\$3") - 1 ))"
}
STUB
{
  for i in $(seq 1 150); do echo "id-$i"; done
  for i in 1 2 3 40 150; do echo "id-$i"; done   # duplicates
  echo 'bad id!'                                   # fails the worker's id regex
  echo ''
} > "$T/ids-150"
a2() { # a2 <ALERTS_DB> <STUB_RC> <idsfile>...
  local db="$1" rc="$2"; shift 2
  : > "$T/a2-reqs"; : > "$T/a2-log"
  ( . "$DIR/bin/lib/jobs/alerts.sh"; . "$T/a2-stub.sh"; . "$LIB"
    ALERTS_DB="$db"; LOG="$T/a2-log"; export STUB_RC="$rc"
    for f in "$@"; do triage_close_ids step0 "$f" || exit 9; done )
  A2RC=$?
}
a2 1 0 "$T/ids-150"
[ "$A2RC" = 0 ] && ok || bad "A2: triage_close_ids returns 0 (got $A2RC)"
[ "$(jq -c '.ids|length' "$T/a2-reqs" | tr '\n' ' ')" = "90 60 " ] && ok \
  || bad "A2: 150 unique valid ids go out as two requests of 90 and 60 (got: $(jq -c '.ids|length' "$T/a2-reqs" | tr '\n' ' '))"
[ "$(jq -r '.ids[]' "$T/a2-reqs" | sort | uniq -d | wc -l)" = 0 ] && ok || bad "A2: an id is sent at most once"
! grep -q 'bad' <<<"$(jq -r '.ids[]' "$T/a2-reqs")" && ok || bad "A2: the malformed id is dropped, never sent"
grep -q 'CLOSED (no model call) reason=step0 resolved=89 of 90$' "$T/a2-log" \
  && grep -q 'CLOSED (no model call) reason=step0 resolved=59 of 60$' "$T/a2-log" && ok \
  || bad "A2: one CLOSED line per slice carrying the WORKER's count (log: $(cat "$T/a2-log"))"

a2 1 75 "$T/ids-150"
[ "$(wc -l < "$T/a2-reqs" | tr -d ' ')" = 2 ] && ok || bad "A2: rc 75 is not retried — one request per slice (got $(wc -l < "$T/a2-reqs"))"
grep -q 'close rc=75 for 90 id(s) — rows stay quarantined' "$T/a2-log" && ok \
  || bad "A2: rc 75 logs 'close rc=75 for 90 id(s)' (log: $(cat "$T/a2-log"))"
! grep -q 'resolved=' "$T/a2-log" && ok || bad "A2: a failed close is never counted as resolved"
[ "$A2RC" = 0 ] && ok || bad "A2: a failed close still returns 0 (got $A2RC)"

# A2-off — the flag off: no request, said once per process, idle says nothing.
a2 0 0 "$T/ids-150" "$T/ids-150"
[ ! -s "$T/a2-reqs" ] && ok || bad "A2-off: ALERTS_DB=0 makes no request"
[ "$(grep -c 'close skipped: ALERTS_DB off — 150 id(s) not resolved' "$T/a2-log")" = 1 ] && [ "$(wc -l < "$T/a2-log" | tr -d ' ')" = 1 ] && ok \
  || bad "A2-off: exactly one 'close skipped' line for two calls (log: $(cat "$T/a2-log"))"
: > "$T/ids-empty"
a2 0 0 "$T/ids-empty"; [ ! -s "$T/a2-log" ] && ok || bad "A2-off: an empty ids file writes no line (got: $(cat "$T/a2-log"))"
a2 1 0 "$T/ids-empty" "$T/nonexistent"; [ ! -s "$T/a2-reqs" ] && [ ! -s "$T/a2-log" ] && ok \
  || bad "A2: empty or missing ids file = no request, no line"

# ================= A3u — triage_settled_ids =================
# Settled lines in the splitter's own format: reason<TAB>line with the line's
# tabs turned into spaces (bin/alert-triage.sh settled_rows writer).
settled() { printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t' ' ')"; }
{
  settled "resolved: the newest line in this family is the emitter's own retraction" "$(dbrow r1 60 'RESOLVED: widget')"
  settled "superseded: a newer beat with the same akey (orclane:s1) is in this same batch, 60s after it" "$(dbrow s1 120 'widget stuck')"
  settled "verify:widget: probe says clear" "$(dbrow v1 60 'widget down')"
  settled "stale-akey: 7200s old against a 3600s TTL, and akey orclane:k1 is opted in by TRIAGE_STALE_AKEYS as an emitter that re-raises faster than that" "$(dbrow k1 7200 'widget flap')"
  settled "resolved: the newest line in this family is the emitter's own retraction" "$(beat n1 60 'RESOLVED: widget')"
  settled "verify:widget: probe says clear" "$(dbrow v1 30 'widget down again')"
} > "$T/settled"
echo stale > "$T/ids-settled"
( . "$LIB"; triage_settled_ids "$T/settled" "$T/ids-settled" )
[ "$(tr '\n' ' ' < "$T/ids-settled")" = "r1 s1 v1 " ] && ok \
  || bad "A3u: resolved:/superseded:/verify: dbrow ids only, deduped (got: $(tr '\n' ' ' < "$T/ids-settled"))"
( . "$LIB"; triage_settled_ids "$T/nonexistent" "$T/ids-settled" )
[ -f "$T/ids-settled" ] && [ ! -s "$T/ids-settled" ] && ok || bad "A3u: a missing settled file truncates <idsout>"

# ================= A3 — the real tick =================
sed "s|/root/harness|$H|g" "$DIR/bin/alert-triage.sh" > "$H/bin/alert-triage.sh"; chmod +x "$H/bin/alert-triage.sh"
sed "s|/root/harness|$H|g" "$RETIRE" > "$T/retire-real.sh"; chmod +x "$T/retire-real.sh"
# THE MUTANT: the same retire script with its id hand-off cut. A mutation that
# changed nothing would prove nothing, so it is checked to differ.
sed 's/os\.environ\.get("TRIAGE_RETIRE_IDS_OUT")/None/' "$T/retire-real.sh" > "$T/retire-mutant.sh"; chmod +x "$T/retire-mutant.sh"
cmp -s "$T/retire-real.sh" "$T/retire-mutant.sh" && bad "A3: the mutation did not change the retire script — the check below would be vacuous"
cp "$LIB" "$H/bin/lib/triage-close.sh"
for s in jobs-client.sh triage-map.sh fleet-conf.sh box-for.sh project-of.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
for s in alert-state.sh env-path.sh brake-ledger.sh; do ln -sf "$DIR/bin/lib/$s" "$H/bin/lib/$s"; done
export FLEET_CONF="$DIR/fleet.conf"
triage_tick_setup "$H" || exit 1   # BH-5942: the tick is a dispatch, then the project-5 run

# The jobs worker: claim hands out nothing (the rows are already on the spool,
# where a deferred dbrow line lives), the ledger is empty, and resolve records
# its body and answers the number of ids it was sent.
{ echo '#!/bin/bash'; cat <<'CURLEOF'
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary|-d) BODY="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "$METHOD $URL" in
  "POST "*jobs.invalid/api/alerts/resolve) printf '{"resolved":%s}\n200\n' "$(jq '.ids|length' <<<"$BODY")" ;;
  "POST "*jobs.invalid/api/alerts/claim)   printf '{"alerts":[]}\n200\n' ;;
  "GET "*jobs.invalid/api/ledger*)         printf '{"ledgers":[]}\n200\n' ;;
  "PUT "*jobs.invalid/api/ledger*)         printf '{"ledger":{}}\n200\n' ;;
  "GET "*jobs.invalid/api/alerts/families*) printf '{"families":[]}\n200\n' ;;
  *jobs.invalid*)                          printf '{"error":"not found"}\n404\n' ;;
  *) echo '{}' ;;
esac
CURLEOF
} > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
printf '#!/bin/sh\nexit 255\n' > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
echo call >> "$CALLDIR/agent-calls"
echo "handled=1 escalated=0 noise=0" > "$5"
STUB
chmod +x "$H/bin/agent-call.sh"

SPOOL="$H/state/alert-triage-deferred.tsv"
tick() { # tick <retire-script>
  state_reset; scratch_rm "$T/calls"; mkdir -p "$T/calls"
  cp "$1" "$H/bin/triage-spool-retire.sh"
  : > "$H/logs/alert-triage.log"; : > "$H/logs/ALERTS.log"; : > "$T/req.log"
  echo '{}' > "$H/state/alert-families.json"; : > "$H/state/alert-quarantine.jsonl"
  {
    dbrow a1 300 "$(resp one 5001)"                              # NOISE-STALE -> close
    dbrow r1 60 "[pipeline-health] RESOLVED: the widget lane recovered"  # settled resolved: -> close
    dbrow a2 $((25 * 3600)) "the widget lane is unhappy"          # EXPIRED-AGE -> never
    dbrow a3 $((7 * 3600)) "[merge-conductor] conductor: project-5#77 WAIT_CI — 420m in WAIT_CI: waiting https://github.com/example-org/project-5/pull/5003"  # EXPIRED-CONDSTATE -> never
    beat  b1 300 "$(resp two 5002)"                               # non-dbrow NOISE-STALE -> never
    dbrow k1 7200 "[flappy] the otter queue flapped"              # stale-akey: -> never
  } > "$SPOOL"
  TMPDIR="$T/tmp" TRIAGE_NOW="$NOW" TRIAGE_STALE_AKEYS="orclane:k" TRIAGE_STALE_TTL=3600 \
    CALLDIR="$T/calls" REQ_SINK="$T/req.log" PATH="$T/fakebin:$PATH" \
    triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1
  TRC=$?
  grep '^POST https://jobs.invalid/api/alerts/resolve ' "$T/req.log" | sed 's/^[^{]*//' | jq -r '.ids[]' | sort > "$T/resolved"
}
ncalls() { cat "$T/calls/agent-calls" 2>/dev/null | wc -l | tr -d ' '; }

touch "$H/flags/alerts-db"
tick "$T/retire-real.sh"
[ "$TRC" = 0 ] && ok || bad "A3: the tick exits 0 (got $TRC)"
[ "$(tr '\n' ' ' < "$T/resolved")" = "a1 r1 " ] && ok \
  || bad "A3: the tick resolves exactly the MERGED-PR row a1 and the settled row r1 (got: $(tr '\n' ' ' < "$T/resolved"); log: $(grep -E 'CLOSED|close|STEP 0|settled' "$H/logs/alert-triage.log" | head -8))"
[ "$(ncalls)" = 0 ] && ok || bad "A3: nothing is left for a session, so zero agent-calls (got $(ncalls))"
grep -q 'CLOSED (no model call) reason=step0 resolved=1 of 1$' "$H/logs/alert-triage.log" \
  && grep -q 'CLOSED (no model call) reason=settle resolved=1 of 1$' "$H/logs/alert-triage.log" && ok \
  || bad "A3: one CLOSED line each for step0 and settle (log: $(grep CLOSED "$H/logs/alert-triage.log"))"
S0=$(grep -n 'STEP 0 aged=' "$H/logs/alert-triage.log" | head -1 | cut -d: -f1)
C0=$(grep -n 'reason=step0' "$H/logs/alert-triage.log" | head -1 | cut -d: -f1)
[ -n "$S0" ] && [ -n "$C0" ] && [ "$S0" -lt "$C0" ] && ok || bad "A3: the STEP 0 line is logged before the step0 close"
# A3-neg
for id in a2 a3 b1 k1; do
  ! grep -qx "$id" "$T/resolved" && ok || bad "A3-neg: $id must never be resolved"
done
grep -q 'stale-akey:' "$H/logs/alert-triage.log" && grep -q 'EXPIRED-CONDSTATE' "$H"/state/alert-triage-expired-*.tsv && ok \
  || bad "A3-neg: the fixture must actually settle k1 stale-akey and retire a3 EXPIRED-CONDSTATE (vacuous otherwise)"

# Mutation: the hand-off cut from the retire script -> a1 is no longer closed.
tick "$T/retire-mutant.sh"
! grep -qx a1 "$T/resolved" && grep -qx r1 "$T/resolved" && ok \
  || bad "A3-mutant: without the retire hand-off a1 must NOT be resolved (got: $(tr '\n' ' ' < "$T/resolved"))"

# A3-off — the switch.
touch "$H/flags/triage-close-off"
tick "$T/retire-real.sh"
[ "$(grep -c '/api/alerts/resolve' "$T/req.log")" = 0 ] && ok \
  || bad "A3-off: triage-close-off makes zero resolve requests (got $(grep -c '/api/alerts/resolve' "$T/req.log"))"
rm -f "$H/flags/triage-close-off"

echo "alert-triage-close.bh-2544: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
