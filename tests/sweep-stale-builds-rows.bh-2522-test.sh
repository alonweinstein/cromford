#!/bin/bash
# tests/sweep-stale-builds-rows.bh-2522-test.sh — BH-2522: bin/sweep-stale-builds.sh
# takes its pool evidence from the machines rows once fly_machines_rows is on,
# from this box's own pool files while it is off, and never ssh's anywhere.
#
# The curl stub plays both the console (stale feed, close POST) and the jobs
# worker (build_queue, machines). GET /api/machines honours ?live=1 the way
# worker/jobs/src/routes/machines.js does (state not destroyed/gone), so a
# closed row is not evidence of life here either.
# Run from anywhere: tests/sweep-stale-builds-rows.bh-2522-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$T" || exit 1
mkdir -p "$T/bin/lib/jobs" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/builds" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$DIR/bin/jobs-client.sh" "$T/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/closeout-terminal.sh" "$T/bin/lib/"
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 local
remote-os Org/remote https://r.example /api/board 4 box-remote
EOF
export FLEET_CONF="$T/fleet.conf"
unset FLY_MACHINES_ROWS
printf 'CONSOLE_URL=http://console.invalid\nHARNESS_SECRET=s3cret\n' > "$T/env/global.env"
printf '#!/bin/bash\ntrue\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
# Every ssh is recorded, and every one fails: a sweep that still enumerated
# boxes would both leave a line here and hold back what the dead box owns.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/SSH.log"\nexit 255\n' "$T" > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
MODE=""; URL=""
for a; do case "\$a" in *api/builds/stale*) MODE=get;; *api/builds/close*) MODE=post;; *api/queue*) MODE=queue;; *api/machines*) MODE=machines; URL="\$a";; *api/ledger*|*api/verdict*) MODE=ledger;; esac; done
if [ "\$MODE" = ledger ]; then printf '\n404\n'; exit 0; fi
if [ "\$MODE" = queue ]; then printf '{"queue":[]}\n200\n'; exit 0; fi
if [ "\$MODE" = machines ]; then
  printf '%s\n' "\${URL#*api/machines}" >> $T/MQ.log
  [ -f $T/MACHINES_DOWN ] && exit 7
  if [ -f $T/MACHINES_FULL ]; then
    jq -nc '{machines: [range(500) | {machine_id:"f\(.)",project:"alpha-os",app:"pool-a",role:"pool",key:"F-\(.)",state:"started"}]}'
    printf '\n200\n'; exit 0
  fi
  LV=0; case "\$URL" in *live=1*) LV=1;; esac
  jq -c --argjson l "\$LV" '{machines: [ .[] | select(\$l == 0 or (.state != "destroyed" and .state != "gone")) ]}' $T/MACHINES.json
  printf '\n200\n'; exit 0
fi
if [ "\$MODE" = get ]; then cat $T/FEED.json; exit 0; fi
BODY=""; P=0
for a; do [ "\$P" = 1 ] && { BODY="\$a"; P=0; }; [ "\$a" = "-d" ] && P=1; done
printf '%s\n' "\$BODY" >> $T/POSTS.jsonl
N=\$(printf '%s' "\$BODY" | jq '.closed | length')
printf '{"ok":true,"requested":%s,"updated":%s}\n' "\$N" "\$N"
EOF
chmod +x "$T/fakebin/curl"

feed() { jq -nc --argjson b "$1" '{ok:true,count:($b|length),builds:$b}' > "$T/FEED.json"; }
rows() { printf '%s' "$1" > "$T/MACHINES.json"; }
THREE='[{"bkey":"b1","project":"alpha-os","ticket_key":"TK-1","stage":"executing","updated_at":"2026-08-20T00:00:00Z"},
        {"bkey":"b2","project":"alpha-os","ticket_key":"TK-2","stage":"executing","updated_at":"2026-08-20T00:00:00Z"},
        {"bkey":"r1","project":"remote-os","ticket_key":"TK-9","stage":"executing","updated_at":"2026-08-20T00:00:00Z"}]'
run() { # run <FLY_MACHINES_ROWS> [args]
  local fl="$1"; shift
  : > "$T/POSTS.jsonl"; : > "$T/logs/sweep-stale-builds.log"; : > "$T/logs/ALERTS.log"; : > "$T/MQ.log"; : > "$T/SSH.log"
  HARNESS="$T" PATH="$T/fakebin:$PATH" HARNESS_SECRET=s3cret FLY_MACHINES_ROWS="$fl" \
    JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
    bash "$DIR/bin/sweep-stale-builds.sh" "$@" >/dev/null 2>&1; echo $?; }
posted() { jq -r '.closed[]?' "$T/POSTS.jsonl" 2>/dev/null | sort | tr '\n' ' '; }
logged() { cat "$T/logs/sweep-stale-builds.log" 2>/dev/null; }
nalerts() { grep -c '\[sweep\]' "$T/logs/ALERTS.log" 2>/dev/null || true; }

# ---------- S1 flag on: a live ROW holds its build, with no file anywhere ----------
feed "$THREE"
rows '[{"machine_id":"m2","project":"alpha-os","app":"pool-a","role":"pool","key":"TK-2","state":"started"},
       {"machine_id":"m7","project":"alpha-os","app":"pool-a","role":"pool","key":"TK-1","state":"destroyed"},
       {"machine_id":"m8","project":"alpha-os","app":"pool-a","role":"pool","key":null,"state":"started"}]'
RC=$(run on)
[ "$RC" = 0 ] && [ "$(posted)" = "b1 r1 " ] && ok || bad "S1 a live row must hold TK-2 and only TK-2 (rc=$RC posted=$(posted))"
logged | grep -q 'HOLD b2 (alpha-os TK-2)' && ok || bad "S1 the hold must be logged: $(logged)"
grep -qx '?live=1' "$T/MQ.log" && [ "$(grep -c . "$T/MQ.log")" = 1 ] && ok || bad "S1 one fleet-wide live read of the rows: $(cat "$T/MQ.log")"
logged | grep -q 'pool evidence: 1 live key(s) from machines rows' && ok || bad "S1 the log must name the row evidence: $(logged)"
# With the flag on the files are not the evidence any more: a lingering file
# with no live row does not hold its build.
mkdir -p "$T/state/fly-pool/alpha-os"
echo '{"machine":"m1","key":"TK-1","ticket_id":"t1"}' > "$T/state/fly-pool/alpha-os/m1.json"
RC=$(run on)
[ "$(posted)" = "b1 r1 " ] && ok || bad "S1 with the flag on a pool file is not evidence (posted=$(posted))"
rm -rf "$T/state/fly-pool"

# ---------- S2 flag on, rows unreadable: fail closed ----------
: > "$T/MACHINES_DOWN"
RC=$(run on)
[ "$RC" = 3 ] && [ -z "$(posted)" ] && ok || bad "S2 an unreadable machines table must refuse with rc 3 and no POST (rc=$RC posted=$(posted))"
[ "$(nalerts)" = 1 ] && grep -q 'machines rows unreadable' "$T/logs/ALERTS.log" && ok || bad "S2 one ALERTS line naming the rows: $(cat "$T/logs/ALERTS.log")"
rm -f "$T/MACHINES_DOWN"

# ---------- S3 flag on, a full page: fail closed ----------
: > "$T/MACHINES_FULL"
RC=$(run on)
[ "$RC" = 3 ] && [ -z "$(posted)" ] && ok || bad "S3 a 500-row page must refuse with rc 3 and no POST (rc=$RC posted=$(posted))"
[ "$(nalerts)" = 1 ] && grep -q 'full page' "$T/logs/ALERTS.log" && ok || bad "S3 one ALERTS line naming the full page: $(cat "$T/logs/ALERTS.log")"
rm -f "$T/MACHINES_FULL"

# ---------- S4 no ssh, ever ----------
rows '[]'
RC=$(run on)
[ ! -s "$T/SSH.log" ] && ok || bad "S4 flag on: the sweep must not ssh: $(cat "$T/SSH.log")"
[ "$(posted)" = "b1 b2 r1 " ] && ok || bad "S4 a remote box's project is no longer held back by an ssh read (posted=$(posted))"
RC=$(run off)
[ ! -s "$T/SSH.log" ] && ok || bad "S4 flag off: the sweep must not ssh either: $(cat "$T/SSH.log")"
[ "$(posted)" = "b1 b2 r1 " ] && ok || bad "S4 flag off, nothing live: all three close (posted=$(posted))"
grep -q 'unreachable' <<<"$(logged)" && bad "S4 nothing checks reachability any more, so nothing may say unreachable: $(logged)" || ok

# ---------- S5 flag off: this box's pool files are the evidence ----------
mkdir -p "$T/state/fly-pool/alpha-os"
echo '{"machine":"m2","key":"TK-2","ticket_id":"t2"}' > "$T/state/fly-pool/alpha-os/m2.json"
RC=$(run off)
[ "$(posted)" = "b1 r1 " ] && ok || bad "S5 flag off: a hub-local pool file must hold its build (posted=$(posted))"
[ ! -s "$T/MQ.log" ] && ok || bad "S5 flag off: the machines table is not read: $(cat "$T/MQ.log")"
logged | grep -q "fly_machines_rows off — pool evidence from this box's files" && ok || bad "S5 the log must name the off state: $(logged)"
rm -rf "$T/state/fly-pool"

echo "sweep-stale-builds-rows.bh-2522-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
