#!/bin/bash
# tests/alert-triage-no-ssh.bh-2314-test.sh — the hub stops ssh-grabbing every
# box's quarantine when the alerts table claim works (BH-2366 / BH-2314.4), and
# alert-flush.sh re-marks the box entries whose quarantine mark missed.
#
# Runs the REAL bin/alert-triage.sh and bin/alert-flush.sh with only the harness
# root repointed. Stubbed: curl (the jobs worker and the console), ssh (records
# its argv, then drains a second tree), fleet-conf.sh --tailnet-ips (two fixed
# IPs), agent-call.sh, gh, timeout, flock.
#
# WHAT IS AT STAKE.
#   * s1: flag on + claim rc 0 → NO ssh invocation at all, while the hub's own
#     local grab and the claimed rows still reach the session.
#   * s2-s5: every other path — claim rc 1, 2, 9, or the flag off — runs the
#     per-box loop exactly as before. Skipping there loses box alerts.
#   * r1-r5: alert-flush stamps "dbrow":true ONLY when the quarantined PATCH
#     answered rc 0. A stamp on a failed mark would drop the entry from both
#     the table path and the 45m dead-man.
#   * r7: an overdue retraction is DROPPED while the flush claim works (its row
#     is closed; sent raw it pages a condition that is over) and sent raw as
#     before when the claim fails.
#   * r8: "N stamped" counts only lines really rewritten, and a line drained
#     between the snapshot and the stamp is not written back.
#
# Run from anywhere: tests/alert-triage-no-ssh.bh-2314-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=$(date -u +%s)
iso() { date -u -d "@$(( NOW - ${1:-0} ))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" \
         "$T/fakebin" "$T/calls" "$T/remote/state"
printf 'CONSOLE_URL=https://console.invalid\nJOBS_URL=https://jobs.invalid\nHARNESS_SECRET=testsecret\nJOBS_RETRIES=0\nBOX_NAME=hub\n' \
  > "$H/env/global.env"

for s in alert-triage.sh alert-flush.sh; do
  sed "s|/root/harness|$H|g" "$DIR/bin/$s" > "$H/bin/$s"; chmod +x "$H/bin/$s"
done
for s in jobs-client.sh triage-map.sh box-for.sh project-of.sh alert_family.py; do
  ln -sf "$DIR/bin/$s" "$H/bin/$s"
done
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
ln -sf "$DIR/bin/lib/alert-state.sh" "$H/bin/lib/alert-state.sh"
ln -sf "$DIR/bin/lib/env-path.sh" "$H/bin/lib/env-path.sh"
export FLEET_CONF="$DIR/fleet.conf"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/fleet-projects-or-alert.sh"; chmod +x "$H/bin/fleet-projects-or-alert.sh"
printf '#!/usr/bin/env python3\n' > "$H/bin/alerts-supersede.py"
# The box list: two fixed addresses. Anything else is the real registry read.
cat > "$H/bin/fleet-conf.sh" <<EOF
#!/bin/bash
case "\${1:-}" in
  --tailnet-ips) printf '10.0.0.1\n10.0.0.2\n' ;;
  *) exec "$DIR/bin/fleet-conf.sh" "\$@" ;;
esac
EOF
chmod +x "$H/bin/fleet-conf.sh"
triage_tick_setup "$H" || exit 1   # BH-5942: the triage lane is a dispatch + per-project runs

# --- stubs -------------------------------------------------------------------
# curl: records "METHOD URL BODY". The jobs host answers body\n<status>:
#   claim  → $T/claim.json at CLAIM_STATUS (200 | 500 → rc 1 | 404 → rc 2 | 409 → rc 9)
#   state  → STATE_STATUS, overridden per id by "$T/state-status" lines "<id> <status>"
#   flush  → {"alerts":[]} at FLUSH_STATUS (200 | 500 → the flush claim fails)
# The console answers the bare status, as the beat POSTs read it.
{ echo '#!/bin/bash'; echo "FIX=$T"; cat <<'CURLEOF'
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary|-d) BODY="$2"; shift 2 ;;
    -H) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  *jobs.invalid*)
    case "$METHOD $URL" in
      "POST "*/api/alerts/claim)    printf '%s\n%s\n' "$(cat "$FIX/claim.json")" "${CLAIM_STATUS:-200}" ;;
      "POST "*/api/alerts/flush)    printf '{"alerts":[]}\n%s\n' "${FLUSH_STATUS:-200}" ;;
      "GET "*/api/alerts/families*) printf '{"families":[]}\n200\n' ;;
      "PATCH "*/api/alerts/state)
        ID=$(printf '%s' "$BODY" | jq -r '.id' 2>/dev/null)
        ST=$(printf '%s' "$BODY" | jq -r '.state' 2>/dev/null)
        CODE=$(awk -v id="$ID" '$1 == id { print $2 }' "$FIX/state-status" 2>/dev/null | tail -1)
        # DRAIN_ON_PATCH: the queue is drained between the snapshot and the stamp.
        [ -n "${DRAIN_ON_PATCH:-}" ] && : > "$FIX/h/state/alert-quarantine.jsonl"
        printf '{"alert":{"id":"%s","state":"%s"}}\n%s\n' "$ID" "$ST" "${CODE:-${STATE_STATUS:-200}}" ;;
      *) printf '{"error":"not found"}\n404\n' ;;
    esac ;;
  *console.invalid/api/beat) printf '200' ;;
  *) echo '{}' ;;
esac
CURLEOF
} > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

# ssh: records its argv (one line per invocation), then runs the remote command
# against $T/remote, so the GRAB snippet really drains a remote file.
{ echo '#!/bin/bash'; echo "HROOT=$H"; echo "RROOT=$T/remote"; echo "ARGV=$T/ssh.argv"; cat <<'SSHEOF'
printf '%s\n' "$*" >> "$ARGV"
CMD="${!#}"
exec bash -c "${CMD//$HROOT/$RROOT}"
SSHEOF
} > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"

printf '#!/bin/sh\necho MERGED\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"

cat > "$H/bin/agent-call.sh" <<'CALLEOF'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-*.txt 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
echo "handled=1 escalated=0 noise=0" > "$5"
CALLEOF
chmod +x "$H/bin/agent-call.sh"

# --- harness -----------------------------------------------------------------
Q="$H/state/alert-quarantine.jsonl"
fresh() { rm -rf "$T/calls"; mkdir -p "$T/calls"; : > "$T/req.log"; rm -f "$T/ssh.argv" "$T/state-status"; }
lane() { # lane <script> — run one lane exactly as cron does, env knobs pass through
  # BH-5942: one triage tick is the dispatch, then each project's run.
  if [ "$1" = alert-triage.sh ]; then
    HARNESS="$H" CALLDIR="$T/calls" REQ_SINK="$T/req.log" PATH="$T/fakebin:$PATH" \
      triage_tick "$H/bin/$1" >/dev/null 2>&1
    return
  fi
  HARNESS="$H" CALLDIR="$T/calls" REQ_SINK="$T/req.log" PATH="$T/fakebin:$PATH" \
    bash "$H/bin/$1" >/dev/null 2>&1
}
reset_triage() { triage_tick_reset "$H"; : > "$H/logs/alert-triage.log"; echo '{}' > "$H/state/alert-families.json"
                 : > "$H/state/alert-triage-deferred.tsv"; : > "$Q"
                 : > "$T/remote/state/alert-quarantine.jsonl"; }
prompts() { cat "$T/calls"/prompt-*.txt 2>/dev/null; }
countof() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }
count()   { countof "$1" "$T/req.log"; }
sshn()    { countof . "$T/ssh.argv"; }
collect() { grep 'triage collect:' "$H/logs/alert-triage.log" 2>/dev/null; }
ncollect(){ countof 'triage collect:' "$H/logs/alert-triage.log"; }
flag_on()  { touch "$H/flags/alerts-db"; }
flag_off() { rm -f "$H/flags/alerts-db"; }
q() { # q <file> <age_s> <tag> <line> [extra-json]
  printf '%s\t{"kind":"fleet_alert","project":"p-%s","akey":"k-%s","line":"%s"%s}\n' \
    "$(( NOW - $2 ))" "$3" "$3" "$4" "${5:-}" >> "$1"; }
row() { # row <id> <line> — a claimed quarantined row
  printf '{"alerts":[{"id":"%s","family":"f","box":"project-9","project":"","state":"quarantined","count":1,"first_seen":"%s","last_seen":"%s","claimed_by":"alert-triage@hub","claimed_at":"%s","notified_at":"","severity":"warn","line":"%s"}]}\n' \
    "$1" "$(iso 600)" "$(iso 60)" "$(iso 0)" "$2" > "$T/claim.json"; }
echo '{"alerts":[]}' > "$T/claim.json"

seed_triage() { # seed_triage <tag>
  reset_triage
  row "claimed-$1" "the $1 claimed subsystem is unhappy #$1claimed"
  q "$Q" 300 "$1hub" "the $1 hub subsystem is unhappy #$1hub"
  q "$T/remote/state/alert-quarantine.jsonl" 300 "$1box" "the $1 box subsystem is unhappy #$1box"
}

# ============ s1 — claim ok: no ssh, hub-local grab + claimed rows run =======
flag_on; seed_triage s1; fresh
lane alert-triage.sh
[ "$(sshn)" = 0 ] && ok || bad "s1: a working claim must make ZERO ssh invocations (got $(sshn): $(cat "$T/ssh.argv" 2>/dev/null))"
P=$(prompts)
grep -q '#s1claimed' <<<"$P" && ok || bad "s1: the claimed row must still reach the session"
grep -q '#s1hub' <<<"$P" && ok || bad "s1: the hub's own local grab must still run"
! grep -q '#s1box' <<<"$P" && ok || bad "s1: a box entry reached the prompt, so the ssh grab ran"
[ "$(countof . "$T/remote/state/alert-quarantine.jsonl")" = 1 ] \
  && ok || bad "s1: the box quarantine must be left untouched for its own flush"
[ "$(ncollect)" = 1 ] && collect | grep -q 'per-box ssh grab skipped' \
  && ok || bad "s1: want exactly one 'triage collect: … skipped' line, got: $(collect)"

# ======= s2/s3/s4 — claim rc 1 / 2 / 9: the per-box loop runs as today =======
for c in "s2 500 1" "s3 404 2" "s4 409 9"; do
  set -- $c
  flag_on; seed_triage "$1"; fresh
  CLAIM_STATUS=$2 lane alert-triage.sh
  [ "$(sshn)" = 2 ] && grep -q 'root@10.0.0.1' "$T/ssh.argv" && grep -q 'root@10.0.0.2' "$T/ssh.argv" \
    && ok || bad "$1: claim http $2 must ssh both boxes (got $(sshn): $(cat "$T/ssh.argv" 2>/dev/null))"
  grep -q "#$1box" <<<"$(prompts)" && ok || bad "$1: the box entry must reach the session"
  [ "$(ncollect)" = 1 ] && collect | grep -q "triage collect: per-box ssh grab ran (claim rc=$3)" \
    && ok || bad "$1: want one 'per-box ssh grab ran (claim rc=$3)' line, got: $(collect)"
done

# ============ s5 — flag off: loop runs, no jobs request at all ===============
flag_off; seed_triage s5; fresh
lane alert-triage.sh
[ "$(sshn)" = 2 ] && ok || bad "s5: flag off must ssh both boxes (got $(sshn))"
[ "$(count 'jobs.invalid/api/alerts')" = 0 ] && ok || bad "s5: flag off made $(count 'jobs.invalid/api/alerts') jobs request(s)"
grep -q '#s5box' <<<"$(prompts)" && ok || bad "s5: the box entry must reach the session"
[ "$(ncollect)" = 1 ] && collect | grep -q 'triage collect: per-box ssh grab ran (flag off)' \
  && ok || bad "s5: want one 'per-box ssh grab ran (flag off)' line, got: $(collect)"

# ============================ alert-flush re-mark ============================
qe() { # qe <age_s> <payload-json>
  printf '%s\t%s\n' "$(( NOW - $1 ))" "$2" >> "$Q"; }
patches_q() { countof '"state":"quarantined"' "$T/req.log"; }
statelog() { cat "$H/logs/alerts-state.log" 2>/dev/null; }

# ---- r1: rc 0 stamps dbrow on the unmarked entry, leaves the marked one -----
flag_on; : > "$Q"; : > "$H/logs/alerts-state.log"; fresh
PA='{"kind":"fleet_alert","project":"p","akey":"k-a","alertid":"rm-1","line":"remark line a"}'
PB='{"kind":"fleet_alert","project":"p","akey":"k-b","alertid":"rm-2","dbrow":true,"line":"remark line b"}'
qe 60 "$PA"; qe 60 "$PB"
TSA=$(( NOW - 60 ))
STATE_STATUS=200 lane alert-flush.sh
LA=$(grep -F '"alertid":"rm-1"' "$Q")
[ "$(cut -f1 <<<"$LA")" = "$TSA" ] && ok || bad "r1: the stamped entry lost its timestamp: $LA"
[ "$(cut -f2- <<<"$LA" | jq -r '.dbrow' 2>/dev/null)" = "true" ] && ok || bad "r1: rc 0 must stamp dbrow:true: $LA"
[ "$(cut -f2- <<<"$LA" | jq -Sc 'del(.dbrow)' 2>/dev/null)" = "$(jq -Sc . <<<"$PA")" ] \
  && ok || bad "r1: the stamp must leave every other field intact: $LA"
[ "$(grep -F '"alertid":"rm-2"' "$Q")" = "$TSA	$PB" ] && ok || bad "r1: the already-marked entry must be untouched"
[ "$(countof . "$Q")" = 2 ] && ok || bad "r1: the queue must still hold both entries"
[ "$(patches_q)" = 1 ] && ok || bad "r1: want exactly one quarantined PATCH, got $(patches_q)"
PBODY=$(grep -m1 'PATCH .*/api/alerts/state' "$T/req.log" | sed 's/^[^ ]* [^ ]* //')
[ "$(jq -r '.id' <<<"$PBODY")" = "rm-1" ] && [ "$(jq -r '.state' <<<"$PBODY")" = "quarantined" ] \
  && ok || bad "r1: the PATCH must be {id:rm-1,state:quarantined}: $PBODY"
grep -q 'flush remark: 1 stamped, 0 left unmarked' <<<"$(statelog)" \
  && ok || bad "r1: want the summary line in alerts-state.log: $(statelog)"

# ---- r2: rc 1 leaves the file byte-identical; the dead-man still flushes ----
flag_on; : > "$Q"; fresh
qe 60 '{"kind":"fleet_alert","project":"p","akey":"k-c","alertid":"rm-3","line":"remark line c"}'
cp "$Q" "$T/before"
STATE_STATUS=500 lane alert-flush.sh
cmp -s "$Q" "$T/before" && ok || bad "r2: an outage must leave the queue byte-identical: $(cat "$Q")"
[ "$(patches_q)" = 1 ] && ok || bad "r2: the mark must have been attempted once (got $(patches_q))"
sed -i "s/^[0-9]*\t/$(( NOW - 3000 ))\t/" "$Q"
fresh
STATE_STATUS=500 lane alert-flush.sh
[ "$(count 'POST https://console.invalid/api/beat')" = 1 ] && grep -q 'UNTRIAGED 45m\] remark line c' "$T/req.log" \
  && ok || bad "r2: the unmarked entry must reach the 45m dead-man: $(grep console "$T/req.log")"

# ---- r2b: the pass stops at the first outage (one timed-out request, not N) --
flag_on; : > "$Q"; fresh
qe 60 '{"kind":"fleet_alert","project":"p","akey":"k-d","alertid":"rm-4","line":"remark line d"}'
qe 60 '{"kind":"fleet_alert","project":"p","akey":"k-e","alertid":"rm-5","line":"remark line e"}'
STATE_STATUS=500 lane alert-flush.sh
[ "$(patches_q)" = 1 ] && ok || bad "r2b: an outage must stop the pass (got $(patches_q) PATCHes)"

# ---- r3: rc 2 and rc 9 leave the entry unchanged and the pass continues -----
flag_on; : > "$Q"; fresh
qe 60 '{"kind":"fleet_alert","project":"p","akey":"k-f","alertid":"rm-404","line":"remark line f"}'
qe 60 '{"kind":"fleet_alert","project":"p","akey":"k-g","alertid":"rm-409","line":"remark line g"}'
cp "$Q" "$T/before"
printf 'rm-404 404\nrm-409 409\n' > "$T/state-status"
lane alert-flush.sh
cmp -s "$Q" "$T/before" && ok || bad "r3: rc 2 / rc 9 must not stamp: $(cat "$Q")"
grep -q '"id":"rm-404","state":"quarantined"' "$T/req.log" && grep -q '"id":"rm-409","state":"quarantined"' "$T/req.log" \
  && ok || bad "r3: both entries must have been attempted: $(grep PATCH "$T/req.log")"

# ---- r4: a retraction and an overdue entry are never re-marked ---------------
flag_on; : > "$Q"; fresh
qe 60   '{"kind":"fleet_alert","project":"p","akey":"k-h","alertid":"rm-res","resolved":true,"line":"remark line h"}'
qe 3000 '{"kind":"fleet_alert","project":"p","akey":"k-i","alertid":"rm-old","line":"remark line i"}'
lane alert-flush.sh
[ "$(patches_q)" = 0 ] && ok || bad "r4: neither the retraction nor the overdue entry may be PATCHed: $(grep PATCH "$T/req.log")"
grep -q 'UNTRIAGED 45m\] remark line i' "$T/req.log" && ok || bad "r4: the overdue entry must be escalated"
grep -qv '"dbrow"' <(grep -F '"alertid":"rm-res"' "$Q") && ok || bad "r4: the retraction must stay unstamped in the queue"

# ---- r5: no alertid → the state key of the line; an .alertstate entry is skipped
flag_on; : > "$Q"; fresh
LNK="remark line without an id"
qe 60 "{\"kind\":\"fleet_alert\",\"project\":\"p\",\"akey\":\"k-j\",\"line\":\"$LNK\"}"
qe 60 '{"kind":"fleet_alert","project":"p","akey":"k-k","alertstate":"new","line":"remark line with a state"}'
KEY=$(HARNESS="$H" bash -c '. "$1/bin/lib/alert-state.sh"; alert_state_key "$2"' _ "$H" "$LNK")
lane alert-flush.sh
[ -n "$KEY" ] && grep -q "\"id\":\"$KEY\",\"state\":\"quarantined\"" "$T/req.log" \
  && ok || bad "r5: an entry with no alertid must be marked under alert_state_key (key '$KEY'): $(grep PATCH "$T/req.log")"
[ "$(patches_q)" = 1 ] && ok || bad "r5: the .alertstate entry must not be PATCHed (got $(patches_q))"

# ---- r6: the flag off makes no request and changes nothing ------------------
flag_off; : > "$Q"; fresh
qe 60 '{"kind":"fleet_alert","project":"p","akey":"k-l","alertid":"rm-off","line":"remark line l"}'
cp "$Q" "$T/before"
lane alert-flush.sh
cmp -s "$Q" "$T/before" && [ "$(count 'jobs.invalid')" = 0 ] \
  && ok || bad "r6: flag off must make no request and change nothing"

# ---- r7: an overdue retraction is dropped with the claim ok, sent raw without --
RES='{"kind":"fleet_alert","project":"p","akey":"k-m","alertid":"rm-gone","alertstate":"resolve","resolved":true,"line":"remark line m RESOLVED"}'
flag_on; : > "$Q"; fresh
qe 3000 "$RES"
lane alert-flush.sh
[ "$(count 'console.invalid/api/beat')" = 0 ] \
  && ok || bad "r7: an overdue retraction must not page with the claim ok: $(grep console "$T/req.log")"
[ "$(countof . "$Q")" = 0 ] && ok || bad "r7: the overdue retraction must leave the queue: $(cat "$Q")"
flag_on; : > "$Q"; fresh
qe 3000 "$RES"
FLUSH_STATUS=500 lane alert-flush.sh
[ "$(count 'POST https://console.invalid/api/beat')" = 1 ] && grep -q 'UNTRIAGED 45m\] remark line m RESOLVED' "$T/req.log" \
  && ok || bad "r7: with the flush claim failed the retraction takes today's raw path: $(grep console "$T/req.log")"

# ---- r8: a line drained before the stamp is neither counted nor written back --
flag_on; : > "$Q"; : > "$H/logs/alerts-state.log"; fresh
qe 60 '{"kind":"fleet_alert","project":"p","akey":"k-n","alertid":"rm-drained","line":"remark line n"}'
DRAIN_ON_PATCH=1 lane alert-flush.sh
[ "$(patches_q)" = 1 ] && ok || bad "r8: the mark must have been attempted once (got $(patches_q))"
[ "$(countof . "$Q")" = 0 ] && ok || bad "r8: a drained line must not be written back: $(cat "$Q")"
grep -q 'flush remark: 0 stamped, 1 left unmarked' <<<"$(statelog)" \
  && ok || bad "r8: a line never rewritten must not count as stamped: $(statelog)"

echo "alert-triage-no-ssh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
