#!/bin/bash
# orphan-reconcile reads each ticket's OWN queue row, and only the owner-class
# queue rows for the ledger (2026-09-28).
#
# The worker's GET /api/queue is a page ordered `enqueued_at ASC LIMIT 200`
# (worker/jobs/src/routes/queue.js). The reconciler used to take ONE unfiltered
# page into queue.tsv and look both owners and the run-build refusal up in it,
# so once a project held 200+ old done/failed rows:
#   - a failed `ABANDONED by the blocked-resolver` row enqueued after them never
#     reached the file, the refusal skip never fired, and the ticket was
#     launched into a BUILD_REFUSED on every tick;
#   - a queued/claimed row enqueued after them never reached it either, so an
#     OWNED ticket read as an orphan and was launched a second time.
# The fake worker here answers like the real route: filtered by project,
# status and key, oldest first, default page 200, ceiling 500.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
P=project-5
cp "$DIR/bin/orphan-reconcile.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/hold.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$H/bin/lib/"
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
export FLEET_CONF="$DIR/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > x' > "$H/prompts/$P.md"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
printf '#!/bin/bash\n:\n' > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"

cat > "$H/bin/run-build.sh" <<'SH'
printf '%s\n' "$*" >> "$HARNESS/launches.log"
d="$HARNESS/builds/$1-$3-$(date +%s%N)"
mkdir -p "$d" && echo "BUILD_REFUSED refused by the fixture" > "$d/RESULT" && : > "$d/COMMENTED"
SH
chmod +x "$H/bin/run-build.sh"

cat > "$T/fakebin/gh" <<'SH'
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
ARGS="$*"
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
[ "$PAGE" = 1 ] || SEND 200 '[]'
case "$ARGS" in
  *"api rate_limit"*) exit 1 ;;
  *"/issues/"*"/comments"*) SEND 200 '[]' ;;
  *"/pulls"*) SEND 200 '[]' ;;
  *"/issues"*"state=all"*)
    SEND 200 "$(jq -c '[ .[] | {number, state:"open", closed_at:null} ]' "$HARNESS/fixture/open.json")" ;;
  *"/issues"*) SEND 200 "$(cat "$HARNESS/fixture/open.json")" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"

# The route's own semantics: WHERE project/status/key, ORDER BY enqueued_at
# ASC, LIMIT min(max(1, limit || 200), 500).
cat > "$T/fakebin/curl" <<'SH'
URL="${!#}"
qp() { printf '%s' "$URL" | sed -nE "s/.*[?&]$1=([^&]*).*/\\1/p"; }
case "$URL" in
  */api/jobs*)  printf '{"jobs":[]}\n200\n' ;;
  */api/queue*)
    printf '%s\n' "$URL" >> "$HARNESS/queue-gets.log"
    jq -c --arg p "$(qp project)" --arg s "$(qp status)" --arg k "$(qp key)" --arg l "$(qp limit)" '
      ([($l | tonumber? // 200), 1] | max | [., 500] | min) as $lim
      | {queue: ([ .queue[] | select(($p == "" or .project == $p)
                                   and ($s == "" or .status == $s)
                                   and ($k == "" or .ticket_key == $k)) ]
                 | sort_by(.enqueued_at) | .[0:$lim])}' "$HARNESS/fixture/queuerows.json"
    printf '200\n' ;;
  */api/ledger*) printf '{"error":"not found"}\n404\n' ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

AGO() { date -u -d "@$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
OLD=$(AGO 7200)
iss() { printf '{"number":%s,"title":"TK-%s %s","body":"## Scope","comments":0,"updated_at":"%s","labels":[{"name":"ai-build"}]}' "$1" "$1" "$2" "$OLD"; }
printf '[%s,%s,%s,%s,%s]\n' \
  "$(iss 1795 'abandoned behind 250 done rows')" \
  "$(iss 2091 'superseded behind 250 done rows')" \
  "$(iss 2400 'queued behind 250 done rows')" \
  "$(iss 2401 'claimed behind 250 done rows')" \
  "$(iss 2326 'plain orphan')" > "$H/fixture/open.json"

# 250 finished rows for OTHER keys, all enqueued before the rows that matter —
# more than a whole default page, so an unfiltered read sees none of the rest.
jq -n --arg t "$(AGO 90000)" '{queue: [range(0; 250) | {project:"project-5",
  ticket_key: ("TK-" + ((5000 + .) | tostring)), ticket_id: ((5000 + .) | tostring),
  status: (if . % 2 == 0 then "done" else "failed" end), target:"fly", attempt:1,
  claimed_by:null, enqueued_at: $t, reason:"BUILD_OK"}]}' > "$H/fixture/hist.json"
jq --arg t "$(AGO 3600)" '.queue += [
  {project:"project-5",ticket_key:"TK-1795",ticket_id:"1795",status:"failed",target:"fly",attempt:2,claimed_by:null,enqueued_at:$t,reason:"ABANDONED by the blocked-resolver: rebuilt fresh 3 times"},
  {project:"project-5",ticket_key:"TK-2091",ticket_id:"2091",status:"done",target:"fly",attempt:1,claimed_by:null,enqueued_at:$t,reason:"ticket TK-2091 already merged via https://github.com/example-org/project-5/pull/9, park is stale, nothing rebuilt"},
  {project:"project-5",ticket_key:"TK-2400",ticket_id:"2400",status:"queued",target:"fly",attempt:0,claimed_by:null,enqueued_at:$t},
  {project:"project-5",ticket_key:"TK-2401",ticket_id:"2401",status:"claimed",target:"fly",attempt:1,claimed_by:"fly-a",enqueued_at:$t}]' \
  "$H/fixture/hist.json" > "$H/fixture/queuerows.json"

export ORPHAN_GRACE_MIN=0 ORPHAN_MAX_PER_RUN=20
run() { "$H/bin/orphan-reconcile.sh" "$P" --explain 2>/dev/null; }
launched() { sort -u "$H/launches.log" 2>/dev/null; }
was_launched() { grep -qx "project-5 $1 TK-$1" <<<"$(launched)"; }

OUT=$(run)
verdict() { awk -F'\t' -v k="$1" '$1==k {print $3"\t"$4}' <<<"$OUT"; }

was_launched 1795 && bad "1: an ABANDONED queue row behind 250 older done/failed rows must still be skipped (read with queue_row, not from the page): launched=$(launched | tr '\n' ' ')" || ok
grep -q 'TK-1795:abandoned' "$H/logs/$P.log" && ok || bad "1: the run summary must name TK-1795's skip: $(grep -o 'reconcile: open.*' "$H/logs/$P.log" | tail -1)"
was_launched 2091 && bad "2: a superseded queue row behind 250 older rows must still be skipped" || ok
was_launched 2400 && bad "3: a QUEUED row behind 250 older rows owns its ticket — it must not be launched a second time: $(verdict TK-2400)" || ok
grep -q '^TK-2400	2400	OWNED	' <<<"$OUT" && ok || bad "3: TK-2400 must read OWNED by its queued row: $(verdict TK-2400)"
was_launched 2401 && bad "4: a CLAIMED row behind 250 older rows owns its ticket: $(verdict TK-2401)" || ok
was_launched 2326 && ok || bad "5: a plain orphan must still be launched: $(launched | tr '\n' ' ')"

# The owner read asks for the owner-class statuses, never the unfiltered page.
grep -q 'status=' "$H/queue-gets.log" && ok || bad "6: the owner-class queue read must filter by status: $(head -3 "$H/queue-gets.log")"
grep -vq 'status=\|key=' "$H/queue-gets.log" && bad "6: no unfiltered /api/queue page may be read: $(grep -v 'status=\|key=' "$H/queue-gets.log" | head -2)" || ok

# A FULL owner page may have been cut: enqueue nothing rather than guess.
jq --arg t "$(AGO 3600)" '.queue += [range(0; 500) | {project:"project-5",
  ticket_key: ("TK-" + ((7000 + .) | tostring)), ticket_id: ((7000 + .) | tostring),
  status:"queued", target:"fly", attempt:0, claimed_by:null, enqueued_at:$t}]' \
  "$H/fixture/queuerows.json" > "$H/fixture/q2" && mv "$H/fixture/q2" "$H/fixture/queuerows.json"
: > "$H/launches.log"
run >/dev/null
[ -z "$(launched)" ] && ok || bad "7: a full (possibly cut) owner page must enqueue nothing: $(launched | tr '\n' ' ')"
grep -q 'page may be cut' "$H/logs/$P.log" && ok || bad "7: the log must say why nothing was enqueued"

# `ready` is NOT an owner status (the classifier's LIVE set is queued/claimed/
# running): a full ready page must not stop the run. The stale-owed sweep can
# leave 500+ ready rows, and a fail-safe on them would enqueue nothing, ever.
jq --arg t "$(AGO 3600)" '.queue += [range(0; 600) | {project:"project-5",
  ticket_key: ("TK-" + ((8000 + .) | tostring)), ticket_id: ((8000 + .) | tostring),
  status:"ready", target:"fly", attempt:0, claimed_by:null, enqueued_at:$t}]' \
  "$H/fixture/hist.json" > "$H/fixture/queuerows.json"
: > "$H/launches.log"; : > "$H/queue-gets.log"
run >/dev/null
was_launched 2326 && ok || bad "8: 500+ READY rows must not stop an orphan being enqueued: launched=$(launched | tr '\n' ' ') log=$(tail -1 "$H/logs/$P.log")"
# Lifecycle order: ready, then queued, then claimed — a row that moves between
# two reads is then seen in its later status rather than in neither.
ORDER=$(grep -o 'status=[a-z]*' "$H/queue-gets.log" | cut -d= -f2 | tr '\n' ' ')
[ "$ORDER" = "ready queued claimed " ] && ok || bad "8: owner statuses must be read in lifecycle order ready, queued, claimed (got: $ORDER)"

echo "orphan-reconcile-queue-page: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
