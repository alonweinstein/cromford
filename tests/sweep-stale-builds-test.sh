#!/bin/bash
# tests/sweep-stale-builds-test.sh — bin/sweep-stale-builds.sh against fixtures.
#
# This script MUTATES the ledger, so the properties worth pinning are the ones
# that stop it doing harm, not the happy path:
#   * a live build is never closed (the whole reason this is a hub job);
#   * no box is ssh'd to (BH-2522): the pool evidence is rows or local files;
#   * an empty feed or empty survivor set never reports a successful sweep;
#   * an unreadable feed sweeps nothing at all;
#   * closures are batched at 100 and every one leaves an audit line.
# Run from anywhere: tests/sweep-stale-builds-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$T" || exit 1
mkdir -p "$T/bin/lib" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/builds" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$DIR/bin/jobs-client.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/closeout-terminal.sh" "$T/bin/lib/"
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 local
remote-os Org/remote https://r.example /api/board 4 box-remote
EOF
export FLEET_CONF="$T/fleet.conf"
printf 'CONSOLE_URL=http://console.invalid\nHARNESS_SECRET=s3cret\n' > "$T/env/global.env"
printf '#!/bin/bash\ntrue\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"
# flock is Linux-only; the boxes have it, a macOS dev machine does not. Without a
# stand-in the script exits at the lock and every assertion below "passes" by
# observing a sweep that never ran.
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# curl stand-in: serves $T/FEED.json on the GET, records POST bodies.
mkcurl() {
  cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
for a; do case "\$a" in *api/builds/stale*) MODE=get;; *api/builds/close*) MODE=post;; *api/queue*) MODE=queue;; *api/ledger*|*api/verdict*) MODE=ledger;; esac; done
# The jobs ledger / PR-facts read behind bin/lib/closeout-terminal.sh. Without
# this branch every lookup fell through to the POST echo below and answered a
# junk 200, which is the one thing a fail-open terminal check must never see.
# No \$T/LEDGER.json means 404, which jobs-client reads as "no such row" (rc 2).
if [ "\${MODE:-}" = ledger ]; then
  if [ -f $T/LEDGER.json ]; then cat $T/LEDGER.json; printf '\n200\n'; else printf '\n404\n'; fi
  exit 0
fi
# The build_queue read. \$T/QUEUE.json is the whole table and ?status= is
# filtered FOR REAL, because "which statuses count as live" is the guarantee
# under test: a stub that returned every row would pass on a sweep that held
# back builds whose rows are already done.
if [ "\${MODE:-}" = queue ]; then
  [ "\${QUEUE_DOWN:-0}" = 1 ] && exit 7
  ST=""; for a; do case "\$a" in *status=*) ST="\${a##*status=}"; ST="\${ST%%&*}";; esac; done
  jq -c --arg s "\$ST" '{queue: [ .queue[] | select(\$s == "" or .status == \$s) ]}' $T/QUEUE.json
  printf '\n200\n'; exit 0
fi
if [ "\${MODE:-}" = get ]; then cat $T/FEED.json; exit 0; fi
BODY=""; P=0
for a; do [ "\$P" = 1 ] && { BODY="\$a"; P=0; }; [ "\$a" = "-d" ] && P=1; done
printf '%s\n' "\$BODY" >> $T/POSTS.jsonl
N=\$(printf '%s' "\$BODY" | jq '.closed | length')
printf '{"ok":true,"requested":%s,"updated":%s}\n' "\$N" "\$N"
EOF
  chmod +x "$T/fakebin/curl"
}
mkcurl
rm -f "$T/LEDGER.json"
# ssh stand-in: reachable by default, emits no live keys.
mkssh_ok()   { printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"; }
mkssh_dead() { printf '#!/bin/bash\nexit 255\n' > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"; }
mkssh_ok

feed() { jq -nc --argjson b "$1" '{ok:true,count:($b|length),builds:$b}' > "$T/FEED.json"; }
# queue_rows '[{"project":"alpha-os","ticket_key":"TK-1","status":"queued"}]'
queue_rows() { jq -nc --argjson q "$1" '{queue:$q}' > "$T/QUEUE.json"; }
queue_rows '[]'
run()  { : > "$T/POSTS.jsonl"; : > "$T/logs/sweep-stale-builds.log"
         HARNESS="$T" PATH="$T/fakebin:$PATH" HARNESS_SECRET=s3cret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           bash "$DIR/bin/sweep-stale-builds.sh" "$@" >/dev/null 2>&1; echo $?; }
posted() { cat "$T/POSTS.jsonl" 2>/dev/null | jq -r '.closed[]?' 2>/dev/null | sort; }
logged() { cat "$T/logs/sweep-stale-builds.log" 2>/dev/null; }

# ---------- 1. the happy path closes, and leaves an audit line each ----------
feed '[{"bkey":"b1","project":"alpha-os","ticket_key":"TK-1","stage":"executing","updated_at":"2026-08-20T00:00:00Z"},
       {"bkey":"b2","project":"alpha-os","ticket_key":"TK-2","stage":"pr_created","updated_at":"2026-08-20T00:00:00Z"}]'
RC=$(run)
[ "$RC" = 0 ] && [ "$(posted | tr '\n' ' ')" = "b1 b2 " ] && ok || bad "happy path should close both (rc=$RC posted=$(posted|tr '\n' ' '))"
[ "$(logged | grep -c '^.*CLOSED b[12] ')" -eq 2 ] && ok || bad "every closure needs its own audit line"
logged | grep -q 'CLOSED b1 project=alpha-os ticket=TK-1 was_stage=executing' \
  && ok || bad "audit line must carry project, ticket and the stage it came from"

# ---------- 2. a LIVE build is never closed ----------
# Three ways a box says "still working": a queue entry, a pool machine, and a
# build directory being written to.
mkdir -p "$T/state/build-queue/alpha-os"
echo '{"ticket_id":"t1","key":"TK-1","attempt":0}' > "$T/state/build-queue/alpha-os/TK-1.json"
RC=$(run)
[ "$(posted | tr '\n' ' ')" = "b2 " ] && ok || bad "a queued build must be held back (posted=$(posted|tr '\n' ' '))"
logged | grep -q 'HOLD b1 (alpha-os TK-1)' && ok || bad "the hold must be logged with a reason"
rm -rf "$T/state/build-queue"

mkdir -p "$T/state/fly-pool/alpha-os"
echo '{"machine":"148e2","key":"TK-2","ticket_id":"t2","attempt":0}' > "$T/state/fly-pool/alpha-os/148e2.json"
RC=$(run)
[ "$(posted | tr '\n' ' ')" = "b1 " ] && ok || bad "a pool build must be held back (posted=$(posted|tr '\n' ' '))"
rm -rf "$T/state/fly-pool"

mkdir -p "$T/builds/alpha-os-TK-1-202608240100"   # fresh dir = someone is writing
RC=$(run)
[ "$(posted | tr '\n' ' ')" = "b2 " ] && ok || bad "a build dir touched recently must be held back (posted=$(posted|tr '\n' ' '))"
rm -rf "$T/builds/alpha-os-TK-1-202608240100"

# ---------- 2b. the queue evidence is a ROW, not an ssh read ----------
# A watcher no longer writes state/build-queue/<p>/<KEY>.json once its row lands
# (2026-09-11), so the ssh read this used to do now returns EMPTY on exactly the
# boxes it was meant to cover — and a row the hub has not materialised yet exists
# on no box at all. Either way the sweep would have counted a queued build as
# dead and closed it.
feed '[{"bkey":"r1","project":"remote-os","ticket_key":"TK-9","stage":"executing","updated_at":"2026-08-20T00:00:00Z"}]'
queue_rows '[{"project":"remote-os","ticket_key":"TK-9","status":"queued"}]'
RC=$(run)
[ -z "$(posted)" ] && ok || bad "a QUEUED row must hold its build back even with no file on any box (posted=$(posted|tr '\n' ' '))"
logged | grep -q 'HOLD r1 (remote-os TK-9)' && ok || bad "the hold must name the row"

# `claimed` is the most alive a build gets before its dir exists: a dispatcher
# has taken custody and a machine is on it.
queue_rows '[{"project":"remote-os","ticket_key":"TK-9","status":"claimed"}]'
RC=$(run)
[ -z "$(posted)" ] && ok || bad "a CLAIMED row must hold its build back too"

# A TERMINAL row is not evidence of life — those keys are exactly the ones this
# sweep exists to close.
queue_rows '[{"project":"remote-os","ticket_key":"TK-9","status":"done"}]'
RC=$(run)
[ "$(posted | tr '\n' ' ')" = "r1 " ] && ok || bad "a done row must NOT hold a build back (posted=$(posted|tr '\n' ' '))"

# FAIL CLOSED. If the ledger cannot be read the live set is UNKNOWN, and unknown
# is not empty: the sweep does nothing rather than close a row on a guess.
queue_rows '[]'
: > "$T/POSTS.jsonl"; : > "$T/logs/sweep-stale-builds.log"   # run() does this; this call bypasses it
RC=$(QUEUE_DOWN=1 HARNESS="$T" PATH="$T/fakebin:$PATH" HARNESS_SECRET=s3cret \
     JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
     bash "$DIR/bin/sweep-stale-builds.sh" >/dev/null 2>&1; echo $?)
[ -z "$(posted)" ] && ok || bad "an unreadable coordination DB must sweep NOTHING (posted=$(posted|tr '\n' ' '))"
logged | grep -q 'queue evidence is UNKNOWN, NOT sweeping' \
  && ok || bad "the refusal must say why: $(logged | tail -2)"
grep -q 'coordination DB unreadable' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "a sweep skipped for lack of evidence must alert"
: > "$T/logs/ALERTS.log"
queue_rows '[]'

# ---------- 3. no ssh enumeration (BH-2522) ----------
# This used to pin "an unreachable box = UNKNOWN, its projects skipped". BH-2522
# deleted the ssh read that case guarded: the pool evidence is the machines rows
# (or, flag off, this box's own files), so there is no box to reach. The ssh
# stand-in now records every call and fails, and a full run must leave its log
# EMPTY and still close the remote project's row.
feed '[{"bkey":"r1","project":"remote-os","ticket_key":"TK-9","stage":"executing","updated_at":"2026-08-20T00:00:00Z"},
       {"bkey":"b1","project":"alpha-os","ticket_key":"TK-1","stage":"executing","updated_at":"2026-08-20T00:00:00Z"}]'
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/SSH.log"\nexit 255\n' "$T" > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"
: > "$T/SSH.log"
RC=$(run)
[ ! -s "$T/SSH.log" ] && ok || bad "the sweep must not ssh to any box: $(cat "$T/SSH.log")"
[ "$(posted | tr '\n' ' ')" = "b1 r1 " ] && ok || bad "a remote box's project is no longer held back by an ssh read (posted=$(posted|tr '\n' ' '))"
grep -q 'unreachable' <<<"$(logged)" && bad "nothing checks reachability any more, so nothing may say unreachable" || ok
mkssh_ok

# ---------- 4. never a green nothing ----------
feed '[]'
RC=$(run)
[ "$RC" = 0 ] && [ -z "$(posted)" ] && ok || bad "an empty feed must post nothing (rc=$RC)"
logged | grep -q 'not a clean sweep, it is an empty feed' \
  && ok || bad "an empty feed must say so, never imply a successful sweep"
grep -qE '^.*swept [0-9]+ of' <<<"$(logged)" && bad "an empty feed must NOT print a swept-N success line" || ok

# Everything alive -> zero survivors, same rule.
feed '[{"bkey":"b1","project":"alpha-os","ticket_key":"TK-1","stage":"executing","updated_at":"2026-08-20T00:00:00Z"}]'
mkdir -p "$T/state/build-queue/alpha-os"
echo '{"key":"TK-1"}' > "$T/state/build-queue/alpha-os/TK-1.json"
RC=$(run)
[ -z "$(posted)" ] && logged | grep -q '0 survivors' && ok || bad "all-live must sweep nothing and say so"
grep -qE 'swept [0-9]+ of' <<<"$(logged)" && bad "zero survivors must not print a success line" || ok
rm -rf "$T/state/build-queue"

# ---------- 5. an unreadable feed sweeps nothing ----------
printf 'upstream 502 bad gateway' > "$T/FEED.json"
RC=$(run)
[ "$RC" = 3 ] && [ -z "$(posted)" ] && ok || bad "an unreadable feed must abort without posting, rc 3 like every refusal (BH-1954) (rc=$RC)"
logged | grep -q 'unreadable' && ok || bad "an unreadable feed must be logged"

# ---------- 6. batching at 100 ----------
python3 - "$T" <<'PY'
import json,sys
t=sys.argv[1]
b=[{"bkey":f"k{i}","project":"alpha-os","ticket_key":f"TK-{i}","stage":"executing","updated_at":"2026-08-20T00:00:00Z"} for i in range(250)]
json.dump({"ok":True,"count":len(b),"builds":b}, open(f"{t}/FEED.json","w"))
PY
RC=$(run)
[ "$(grep -c . "$T/POSTS.jsonl")" -eq 3 ] && ok || bad "250 rows should post in 3 batches (got $(grep -c . "$T/POSTS.jsonl"))"
BIG=$(jq -r '.closed | length' "$T/POSTS.jsonl" | sort -rn | head -1)
[ "$BIG" -le 100 ] && ok || bad "no batch may exceed 100 (largest was $BIG)"
[ "$(posted | wc -l | tr -d ' ')" -eq 250 ] && ok || bad "all 250 should be closed across the batches"

# ---------- 7. --max is a brake ----------
RC=$(run --max 100)
[ "$RC" = 1 ] && [ -z "$(posted)" ] && ok || bad "exceeding --max must refuse to sweep at all (rc=$RC)"

# ---------- 8. --dry-run mutates nothing ----------
feed '[{"bkey":"b1","project":"alpha-os","ticket_key":"TK-1","stage":"executing","updated_at":"2026-08-20T00:00:00Z"}]'
RC=$(run --dry-run)
[ "$RC" = 0 ] && [ -z "$(posted)" ] && ok || bad "--dry-run must not POST (rc=$RC)"
logged | grep -q 'would close b1' && ok || bad "--dry-run must show what it would have closed"

# ---------- 9. the ledger's terminal verdict annotates, it never overrides ----
# bin/pipeline-health.sh checks 4 and 5 stopped paging for a record whose PR is
# already merged. This lane asks the SAME function (bin/lib/closeout-terminal.sh)
# so the two agree about what "over" means — but here it is a note on the audit
# line, not authority: a live build is still held, merged PR or not.
mkssh_ok
printf '{"ledger":{"status":"merged"}}' > "$T/LEDGER.json"
feed '[{"bkey":"b9","project":"alpha-os","ticket_key":"TK-9","stage":"pr_created","updated_at":"2026-08-20T00:00:00Z","pr_url":"https://github.com/Org/alpha/pull/9"}]'
RC=$(run)
[ "$RC" = 0 ] && [ "$(posted | tr '\n' ' ')" = "b9 " ] && ok || bad "a survivor with a merged PR is still swept (rc=$RC posted=$(posted|tr '\n' ' '))"
logged | grep -q 'CLOSED b9 project=alpha-os ticket=TK-9 was_stage=pr_created .*terminal=pr_merged' \
  && ok || bad "the audit line must record the ledger's verdict: $(logged | grep CLOSED)"
logged | grep -q 'terminal per ledger: 1' && ok || bad "the summary must count it: $(logged | tail -1)"

# A live build is held whatever the ledger says about its PR.
mkdir -p "$T/state/build-queue/alpha-os"
echo '{"key":"TK-9"}' > "$T/state/build-queue/alpha-os/TK-9.json"
RC=$(run)
[ -z "$(posted)" ] && logged | grep -q 'HOLD b9 (alpha-os TK-9)' \
  && ok || bad "terminal evidence must never override a HOLD (posted=$(posted|tr '\n' ' '))"
grep -q 'terminal=' <<<"$(logged)" && bad "a held row must not be annotated (it was never asked)" || ok
rm -rf "$T/state/build-queue"

# A row with no pr_url asks nothing, and the close POST body keeps its shape:
# bare bkeys, nothing about stages or tickets.
rm -f "$T/LEDGER.json"
feed '[{"bkey":"b1","project":"alpha-os","ticket_key":"TK-1","stage":"executing","updated_at":"2026-08-20T00:00:00Z"}]'
RC=$(run)
[ "$(jq -r 'keys | join(",")' "$T/POSTS.jsonl")" = "closed" ] \
  && ok || bad "the close POST body changed shape: $(cat "$T/POSTS.jsonl")"
grep -q 'terminal=' <<<"$(logged)" && bad "a row with no pr_url must not be annotated" || ok

echo "sweep-stale-builds-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
