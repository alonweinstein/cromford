#!/bin/bash
# tests/pool-closeout-custody.bh-5006-test.sh — BH-5006 (scope 3 of #5006).
#
# Two ways a finished or queued pool build went quiet for good, both driven
# through the WHOLE bin/fly-pool.sh on a scratch harness:
#
#   A  BH-4764 queued-without-spawn. The terminal gate (a push-rejected branch
#      whose head has not moved) skipped the row every tick and said so only in
#      fly-pool.log. The row read `queued` on every surface for 26h. Now the
#      skip writes <KEY>.held, closes the row `failed` with the reason, and says
#      it ONCE on ALERTS and ONCE on the ticket.          (BT1-BT4)
#   B  pool results with no board close-out (pool-cromford-BH-4583-
#      202610050404). Three reap paths leave a hub pool dir with a RESULT and
#      no custody marker, and nothing revisits it. pool_custody_sweep gives
#      every such dir an owner on the next tick: SUPERSEDED, RELAYED (the ledger
#      has it), one push, or one ALERTS line with a reason.   (AT1-AT8)
#
# The file anchors wall-clock time in $NOW; every fixture mtime is derived from
# it with touch -d "@$((NOW-N))".
# Run from anywhere: bash tests/pool-closeout-custody.bh-5006-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
unset HOTFIX BUILDER_EXEC POOL_CUSTODY_SWEEP_S POOL_CUSTODY_SWEEP_MAX
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "pool-closeout-custody.bh-5006: jq absent — skipping"; exit 0; }
NOW=$(date +%s)

H="$T/h"; FB="$T/fakebin"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/state/fly" \
         "$H/state/fly-pool/p" "$H/state/build-queue/p" "$H/state/remote-results/p" \
         "$H/state/pool/p" "$H/builds" "$FB"
# The jobs client is a STUB, written before the closure is installed (the
# installer never overwrites a file that is already there): every queue and
# ledger answer is scripted per case from a file, and every call is recorded.
cat > "$H/bin/jobs-client.sh" <<'JC'
_jobs_req() { [ -n "${PSR_LOG:-}" ] && printf '%s %s %s\n' "$1" "$2" "$3" >> "$PSR_LOG"; return 1; }
# BT5: the pool_state_rows switch, on only when a case sets PSR_TEST=1, so the
# hold-row writes (PUT/PATCH /api/pool-state/holds) land in $PSR_LOG.
_flag_on_row() { [ "$1" = pool_state_rows ] && [ "${PSR_TEST:-0}" = 1 ]; }
queue_status() {
  printf 'queue_status %s %s\n' "$1" "$2" >> "$REQ_SINK"
  local st; st=$(cat "$QSTATUS_FILE" 2>/dev/null)
  case "$st" in OUTAGE) return 1 ;; '') return 2 ;; esac
  printf '%s' "$st"
}
queue_done()    { printf 'queue_done\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$REQ_SINK"; return 0; }
queue_put()     { printf 'queue_put %s\n' "$*" >> "$REQ_SINK"; return 0; }
queue_release() { printf 'queue_release %s\n' "$*" >> "$REQ_SINK"; return 0; }
# build_queue_rows_only, per tick from $ROWS_ONLY_TEST (BT4). When it is on, the
# queued rows are the queue: queue_list answers K-2 while $QSTATUS_FILE says
# queued, and only then, the way the worker lists `status=queued`.
build_queue_rows_only_on() { [ "${ROWS_ONLY_TEST:-0}" = 1 ]; }
queue_list() {
  printf 'queue_list %s\n' "$*" >> "$REQ_SINK"
  [ "$(cat "$QSTATUS_FILE" 2>/dev/null)" = queued ] || return 0
  printf 'p\tK-2\t2\tqueued\tfly\t1\t-\t-\t-\t{}\n'
}
queue_claim()   { printf 'queue_claim %s\n' "$*" >> "$REQ_SINK"; return 0; }
job_artifact_feed() {
  printf 'job_artifact_feed %s\n' "$*" >> "$REQ_SINK"
  case "$(cat "$LEDGER_FILE" 2>/dev/null)" in
    has)  local k; for k in $LEDGER_KEYS; do printf 'J1\tPR_CREATED x\tbox\tT1\tt\t{"key":"%s"}\n' "$k"; done ;;
    down) return 1 ;;
    *)    : ;;
  esac
}
JC
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "could not install the fly-pool closure"; exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/result-prefix-ok.sh" "$H/bin/"
mkdir -p "$H/bin/lib/jobs"
printf 'FLY_API_TOKEN_P=tok\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'p example-org/p - - 0 box1 10.0.0.13\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-p"
printf 'pool-p\n' > "$H/flags/fly-pool-app-p"
printf '{"app":"pool-p"}\n' > "$H/state/fly/p.json"
printf 'registry.fly.io/pool-p:deploy-01\n' > "$H/state/fly/p.image"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "${HARNESS}/logs/ALERTS.log"\n' > "$H/bin/alert-line.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$FB/timeout"
printf '#!/bin/bash\nexit 0\n' > "$FB/flock"
printf '#!/bin/bash\nexit 0\n' > "$FB/sleep"
# ssh records argv; SSH_RC (a file) decides whether the push lands.
cat > "$FB/ssh" <<'SH'
#!/bin/bash
printf 'ssh %s\n' "$*" >> "$SSH_SINK"
cat >/dev/null
exit "$(cat "$SSH_RC_FILE" 2>/dev/null || echo 0)"
SH
cat > "$FB/fly" <<'FLY'
#!/bin/bash
printf '%s\n' "$*" >> "$FLY_SINK"
case "$*" in
  *"machine status"*) echo "State: started" ;;
  *"machines list"*)  echo '[]' ;;
  *"machine run"*)    printf 'Machine ID: 1234567890abcd\n' ;;
esac
exit 0
FLY
# gh: REST only. The branch head of ticket/k-2 comes from $HEAD_FILE, there is
# never an open PR, the issue is open and carries ai-build (so the HOLD gate
# answers clear), and a REST comment POST is recorded and answers per
# $POST_RC_FILE.
cat > "$FB/gh" <<'GH'
#!/bin/bash
if [[ "$*" == *"issues/"*"/comments"* ]] && [[ "$*" == *"body=@"* ]]; then
  for a in "$@"; do case "$a" in body=@*) cp "${a#body=@}" "$GH_POST_BODY" 2>/dev/null ;; esac; done
  printf '%s\n' "$*" >> "$GH_POST"
  rc=$(cat "$POST_RC_FILE" 2>/dev/null || echo 0)
  [ "$rc" = 0 ] && echo '{"id":1}'
  exit "$rc"
fi
if [[ "$*" == *"--paginate"*"comments"* ]]; then
  if [ -s "$COMMENTS_FILE" ]; then cat "$COMMENTS_FILE"; else echo '[]'; fi; exit 0
fi
if [[ "$*" == *"issues/2"* ]] && [[ "$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"K-2 a ticket","body":"build it"}'; exit 0
fi
if [[ "$*" == *"-i"* ]]; then
  if [[ "$*" == *"git/ref/heads/ticket/k-2"* ]]; then
    printf 'HTTP/1.1 200 OK\n\n{"object":{"sha":"%s"}}\n' "$(cat "$HEAD_FILE")"; exit 0
  fi
  if [[ "$*" == *"pulls?state=open"* ]]; then printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0; fi
  if [[ "$*" == *"repos/example-org/p"* ]] && [[ "$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/p"}\n'; exit 0
  fi
  printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0
fi
exit 0
GH
cat > "$FB/base64" <<'B64'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in -d|-D) DEC=1 ;; -w0|-w) W0=1 ;; 0) ;; -*) ;; *) FILE="$a" ;; esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0); fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
B64
chmod +x "$H/bin"/*.sh "$FB"/*

# tick [VAR=val ...] — one whole pool tick. Sinks are NOT reset here: a case
# that counts across ticks resets them itself (sinks).
tick() {
  : > "$H/logs/fly-pool.log"
  ( export PATH="$FB:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" FLY_API_TOKEN_P=tok \
           FLY_BIN_DIR="$FB" REQ_SINK="$T/req.txt" SSH_SINK="$T/ssh.txt" FLY_SINK="$T/fly.txt" \
           GH_POST="$T/post.txt" GH_POST_BODY="$T/post-body.txt" HEAD_FILE="$T/head" \
           POST_RC_FILE="$T/post-rc" SSH_RC_FILE="$T/ssh-rc" QSTATUS_FILE="$T/qstatus" \
           LEDGER_FILE="$T/ledger" COMMENTS_FILE="$T/comments" LEDGER_KEYS="${LEDGER_KEYS:-K-1}" "$@"
    bash "$DIR/bin/fly-pool.sh" p >/dev/null 2>&1 )
}
sinks() { : > "$T/req.txt"; : > "$T/ssh.txt"; : > "$T/fly.txt"; : > "$T/post.txt"; : > "$H/logs/ALERTS.log"; }
reset_all() {
  local p
  for p in "$H/builds"/* "$H/state/build-queue/p"/* "$H/state/fly-pool/p"/* \
           "$H/state/pool/p"/* "$H/state/remote-results/p"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$T/comments"; echo 0 > "$T/ssh-rc"; echo 0 > "$T/post-rc"; echo none > "$T/ledger"; : > "$T/qstatus"
  echo abc > "$T/head"
  sinks
}
# mkres <basename> <age-s> [first-line] — a hub pool dir with a RESULT only.
mkres() {
  local d="$H/builds/$1"
  mkdir -p "$d"
  printf '%s\nTIER: 2\nBUILD_DIR: p-%s-m1\n' "${3:-PR_CREATED https://github.com/example-org/p/pull/77}" "$1" > "$d/RESULT"
  touch -d "@$((NOW-$2))" "$d/RESULT"
}
cnt() { grep -c "$1" "$2" 2>/dev/null | head -1; }
D1=pool-p-K-1-202610050404

# ═══ B. the custody sweep ════════════════════════════════════════════════════
# AT1 the ledger already carries it -> RELAYED, no push, no page.
reset_all; echo has > "$T/ledger"; mkres "$D1" 7200
tick
[ -f "$H/builds/$D1/RELAYED" ] && ok || bad "AT1: a result the ledger carries must be stamped RELAYED"
[ ! -s "$T/ssh.txt" ] && ok || bad "AT1: nothing may go over ssh: $(cat "$T/ssh.txt")"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "AT1: no ALERTS line: $(cat "$H/logs/ALERTS.log")"

# AT2 the ledger lacks it and the push lands -> RELAY_RETRIED + RELAYED, one push.
reset_all; echo none > "$T/ledger"; mkres "$D1" 7200
tick
[ -f "$H/builds/$D1/RELAY_RETRIED" ] && ok || bad "AT2: the one push must be recorded RELAY_RETRIED"
[ -f "$H/builds/$D1/RELAYED" ] && ok || bad "AT2: a push that landed must stamp RELAYED"
[ "$(cnt 'remote-results/p/K-1.json' "$T/ssh.txt")" = 1 ] && ok \
  || bad "AT2: exactly one remote-results/p/K-1.json write, got $(cnt 'remote-results/p/K-1.json' "$T/ssh.txt"): $(cat "$T/ssh.txt")"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "AT2: no ALERTS line: $(cat "$H/logs/ALERTS.log")"

# AT3 the push fails -> next tick alerts ONCE with a reason; never pushed twice.
reset_all; echo none > "$T/ledger"; echo 255 > "$T/ssh-rc"; mkres "$D1" 7200
tick
[ -f "$H/builds/$D1/RELAY_RETRIED" ] && ok || bad "AT3 tick1: RELAY_RETRIED must be written"
[ ! -f "$H/builds/$D1/RELAYED" ] && ok || bad "AT3 tick1: a failed push must not stamp RELAYED"
[ "$(wc -l < "$H/logs/ALERTS.log" | tr -d ' ')" = 1 ] && grep -q 'RELAY to .* FAILED' "$H/logs/ALERTS.log" && ok \
  || bad "AT3 tick1: only the existing RELAY … FAILED line: $(cat "$H/logs/ALERTS.log")"
PUSH1=$(cnt 'remote-results' "$T/ssh.txt")
: > "$H/logs/ALERTS.log"
tick
[ "$(wc -l < "$H/logs/ALERTS.log" | tr -d ' ')" = 1 ] && ok || bad "AT3 tick2: exactly one new ALERTS line: $(cat "$H/logs/ALERTS.log")"
for w in "$D1" finished 'no box has it' 'PR_CREATED https://github.com/example-org/p/pull/77'; do
  grep -qF "$w" "$H/logs/ALERTS.log" && ok || bad "AT3 tick2: the custody line must name '$w': $(cat "$H/logs/ALERTS.log")"
done
[ -f "$H/builds/$D1/CUSTODY_ALERTED" ] && ok || bad "AT3 tick2: CUSTODY_ALERTED must be written"
: > "$H/logs/ALERTS.log"
tick
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "AT3 tick3: no repeat page: $(cat "$H/logs/ALERTS.log")"
[ "$(cnt 'remote-results' "$T/ssh.txt")" = "$PUSH1" ] && [ "$PUSH1" = 1 ] && ok \
  || bad "AT3: one push in the dir's lifetime, got $(cnt 'remote-results' "$T/ssh.txt") (tick1 $PUSH1)"

# AT4 an outage is not absent: three ticks, nothing written, pushed or paged.
reset_all; echo down > "$T/ledger"; mkres "$D1" 7200
tick; tick; tick
[ "$(ls "$H/builds/$D1")" = RESULT ] && ok || bad "AT4: an unreadable ledger must write no marker: $(ls "$H/builds/$D1" | tr '\n' ' ')"
[ ! -s "$T/ssh.txt" ] && ok || bad "AT4: no ssh on an outage: $(cat "$T/ssh.txt")"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "AT4: no page on an outage: $(cat "$H/logs/ALERTS.log")"

# AT5 a newer exact-key result with custody supersedes the old one; K-10 never does.
reset_all; echo none > "$T/ledger"
mkres pool-p-K-1-202610050404 20000; mkres pool-p-K-1-202610050800 10000
: > "$H/builds/pool-p-K-1-202610050800/RELAYED"
mkres pool-p-K-3-202610050404 20000; mkres pool-p-K-30-202610050800 10000
: > "$H/builds/pool-p-K-30-202610050800/RELAYED"
# K-4-2 is a different key whose dir name the K-4 glob DOES match: only the
# exact key comparison keeps it from superseding pool-p-K-4-….
mkres pool-p-K-4-202610050404 20000; mkres pool-p-K-4-2-202610050800 10000
: > "$H/builds/pool-p-K-4-2-202610050800/RELAYED"
echo 255 > "$T/ssh-rc"
tick
grep -q 'pool-p-K-1-202610050800' "$H/builds/pool-p-K-1-202610050404/SUPERSEDED" 2>/dev/null && ok \
  || bad "AT5: the older dir must be SUPERSEDED naming the newer one: $(cat "$H/builds/pool-p-K-1-202610050404/SUPERSEDED" 2>&1)"
OUT=$( . "$DIR/bin/lib/closeout-terminal.sh" && closeout_terminal "" "$H/builds/pool-p-K-1-202610050404" ); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = superseded ] && ok || bad "AT5: closeout_terminal must read it superseded (rc=$RC out=$OUT)"
[ ! -f "$H/builds/pool-p-K-3-202610050404/SUPERSEDED" ] && ok \
  || bad "AT5: pool-p-K-30-… must never supersede pool-p-K-3-… (prefix guard)"
[ ! -f "$H/builds/pool-p-K-4-202610050404/SUPERSEDED" ] && ok \
  || bad "AT5: key K-4-2 must never supersede key K-4 (exact key, not a prefix)"
[ ! -f "$H/builds/pool-p-K-1-202610050404/RELAY_RETRIED" ] && ok \
  || bad "AT5: a superseded dir must not be pushed"

# AT6 the age floor and the knob.
reset_all; echo has > "$T/ledger"; mkres "$D1" 600
tick
[ ! -f "$H/builds/$D1/RELAYED" ] && ok || bad "AT6: a 10-minute-old dir is the reap's, not the sweep's"
reset_all; echo has > "$T/ledger"; mkres "$D1" 7200
tick POOL_CUSTODY_SWEEP_S=0
[ ! -f "$H/builds/$D1/RELAYED" ] && ok || bad "AT6: POOL_CUSTODY_SWEEP_S=0 turns the sweep off"
reset_all; echo has > "$T/ledger"; mkres "$D1" 7200
tick POOL_CUSTODY_SWEEP_S=abc
[ -f "$H/builds/$D1/RELAYED" ] && ok || bad "AT6: a non-numeric POOL_CUSTODY_SWEEP_S falls back to 3600"
reset_all; echo has > "$T/ledger"; mkres "$D1" 7200
tick POOL_CUSTODY_SWEEP_MAX=0
[ ! -f "$H/builds/$D1/RELAYED" ] && ok || bad "AT6: POOL_CUSTODY_SWEEP_MAX=0 turns the sweep off"

# AT7 a dir that already has an owner is left alone.
reset_all; echo down > "$T/ledger"
for m in COMMENTED DEFERRED TERMINAL RELAY_DEFERRED SUPERSEDED; do
  mkres "pool-p-O$m-1-202610050404" 7200; : > "$H/builds/pool-p-O$m-1-202610050404/$m"
done
mkres pool-p-ODEF-1-202610050404 7200 'BUILD_DEFERRED all 1 slots busy'
BEFORE=$(find "$H/builds" -type f | sort)
tick
[ "$(find "$H/builds" -type f | sort)" = "$BEFORE" ] && ok \
  || bad "AT7: owned dirs gained or lost a marker: $(diff <(echo "$BEFORE") <(find "$H/builds" -type f | sort))"
grep -q 'custody' "$H/logs/fly-pool.log" && bad "AT7: the sweep acted on an owned dir: $(grep custody "$H/logs/fly-pool.log")" || ok

# AT8 bounded: MAX dirs per tick, oldest RESULT first.
reset_all; echo has > "$T/ledger"
LEDGER_KEYS=""
for i in $(seq 1 12); do mkres "pool-p-M-$i-202610050404" $((7200 + i*100)); LEDGER_KEYS="$LEDGER_KEYS M-$i"; done
tick POOL_CUSTODY_SWEEP_MAX=10 LEDGER_KEYS="$LEDGER_KEYS"
N=$(ls "$H/builds"/pool-p-M-*/RELAYED 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 10 ] && ok || bad "AT8: exactly 10 dirs acted on, got $N"
[ ! -f "$H/builds/pool-p-M-1-202610050404/RELAYED" ] && [ ! -f "$H/builds/pool-p-M-2-202610050404/RELAYED" ] \
  && [ -f "$H/builds/pool-p-M-12-202610050404/RELAYED" ] && ok || bad "AT8: the OLDEST 10 must go first"
unset LEDGER_KEYS

# AT9 (review of 72b69292) a result older than CLOSEOUT_AGE_OUT_H is aged out
# with no network: SUPERSEDED "aged out", no ledger read, no ssh, no page. The
# sweep's backlog on a hub is weeks old, and check 4 already stopped counting it.
reset_all; echo none > "$T/ledger"; mkres "$D1" $((8 * 86400))
tick
grep -q '^aged out' "$H/builds/$D1/SUPERSEDED" 2>/dev/null && ok || bad "AT9: an 8-day-old dir must be SUPERSEDED 'aged out': $(cat "$H/builds/$D1/SUPERSEDED" 2>&1)"
grep -q 'job_artifact_feed' "$T/req.txt" && bad "AT9: the ledger was read for an aged-out dir: $(cat "$T/req.txt")" || ok
[ ! -s "$T/ssh.txt" ] && ok || bad "AT9: nothing may go over ssh: $(cat "$T/ssh.txt")"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "AT9: no ALERTS line: $(cat "$H/logs/ALERTS.log")"
# ...and the ceiling follows CLOSEOUT_AGE_OUT_H: at 240h the same dir is swept as usual
reset_all; echo has > "$T/ledger"; mkres "$D1" $((8 * 86400))
tick CLOSEOUT_AGE_OUT_H=240
[ -f "$H/builds/$D1/RELAYED" ] && [ ! -f "$H/builds/$D1/SUPERSEDED" ] && ok || bad "AT9: under CLOSEOUT_AGE_OUT_H=240 an 8-day-old dir is still swept"

# ═══ A. the terminal skip says why ═══════════════════════════════════════════
TERM="$H/state/pool/p/K-2.terminal"
seed_terminal() {
  jq -nc --arg ts "$(date -u -d "@$((NOW-86400))" '+%Y-%m-%dT%H:%M:%SZ')" \
    '{branch:"ticket/k-2",head_sha:"abc",reason:"push rejected",created_at:$ts}' > "$TERM"
  jq -nc '{ticket_id:"2",key:"K-2",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-06T01:47:00Z"}' \
    > "$H/state/build-queue/p/K-2.json"
}
# BT1 noted once: held marker, row closed failed, one page, one comment.
reset_all; seed_terminal; echo queued > "$T/qstatus"
tick
grep -q 'skipping K-2: terminal head unchanged' "$H/logs/fly-pool.log" && ok \
  || bad "BT1 fixture: the terminal gate was never reached: $(cat "$H/logs/fly-pool.log")"
HELD="$H/state/pool/p/K-2.held"
jq -e '(.why|test("terminal")) and (.why|test("ticket/k-2")) and .key=="K-2" and .ticket_id=="2"' "$HELD" >/dev/null 2>&1 && ok \
  || bad "BT1: K-2.held must name the terminal and the branch: $(cat "$HELD" 2>&1)"
FAILS=$(grep -c "^queue_done	p	K-2	failed	" "$T/req.txt")
[ "$FAILS" = 1 ] && ok || bad "BT1: one queue_done failed for K-2, got $FAILS: $(cat "$T/req.txt")"
R=$(grep "^queue_done	p	K-2	failed	" "$T/req.txt" | cut -f5)
[[ "$R" == *terminal* ]] && [[ "$R" != *died* ]] && ! [[ "$R" =~ deferred\ [0-9]+\ times ]] && ok \
  || bad "BT1: the reason must say terminal and never read as a rebuild trigger: $R"
[ "$(cnt 'queued but never spawned' "$H/logs/ALERTS.log")" = 1 ] && grep -q RETRY "$H/logs/ALERTS.log" && ok \
  || bad "BT1: one 'queued but never spawned' page naming RETRY: $(cat "$H/logs/ALERTS.log")"
[ "$(wc -l < "$T/post.txt" | tr -d ' ')" = 1 ] && grep -q 'repos/example-org/p/issues/2/comments' "$T/post.txt" && ok \
  || bad "BT1: one REST comment to issues/2/comments: $(cat "$T/post.txt")"
# Deleting the branch does NOT re-arm (branch_head_rest reads a 404 as empty,
# and pool_terminal_check treats empty as unchanged), so nothing may offer it.
grep -qiE 'delete (it|the branch)|or delete' "$T/post-body.txt" "$H/logs/ALERTS.log" 2>/dev/null && bad "BT1: the note offers deleting the branch, which never re-arms" || ok
grep -q 'ticket/k-2' "$T/post-body.txt" 2>/dev/null && grep -q RETRY "$T/post-body.txt" && ok \
  || bad "BT1: the comment must name the branch and RETRY: $(cat "$T/post-body.txt" 2>&1)"
[ -f "$H/state/build-queue/p/K-2.json" ] && ok || bad "BT1: the queue file stays so the next tick can re-arm"
grep -q 'machine run' "$T/fly.txt" && bad "BT1: no machine may be spawned for a terminal key" || ok
FIRST=$(jq -r .first_seen "$HELD" 2>/dev/null); LAST1=$(jq -r .last_seen "$HELD" 2>/dev/null)
# tick 2: the row is failed now; silent, but the marker is refreshed. And our
# OWN note comes back on the thread as a User comment (it may go out on a PAT):
# it says RETRY, and it must not re-arm the terminal it describes.
sinks; echo failed > "$T/qstatus"
jq -n --rawfile b "$T/post-body.txt" --arg at "$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ')" \
  '[{created_at:$at,body:$b,user:{type:"User"}}]' > "$T/comments" 2>/dev/null
jq --arg s "2000-01-01 00:00:00Z" '.last_seen=$s' "$HELD" > "$HELD.t" && mv "$HELD.t" "$HELD"
tick
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "BT1 tick2: no repeat page: $(cat "$H/logs/ALERTS.log")"
[ ! -s "$T/post.txt" ] && ok || bad "BT1 tick2: no repeat comment: $(cat "$T/post.txt")"
grep -q '^queue_done' "$T/req.txt" && bad "BT1 tick2: a failed row is not closed again: $(cat "$T/req.txt")" || ok
[ "$(jq -r .last_seen "$HELD" 2>/dev/null)" != "2000-01-01 00:00:00Z" ] && [ "$(jq -r .first_seen "$HELD")" = "$FIRST" ] && ok \
  || bad "BT1 tick2: .held last_seen refreshed, first_seen kept ($FIRST/$LAST1): $(cat "$HELD" 2>&1)"
[ -s "$T/comments" ] && [ -f "$TERM" ] && ! grep -q 'machine run' "$T/fly.txt" && ok \
  || bad "BT1 tick2: our own RETRY note re-armed the terminal (or the fixture is empty): $(grep 'terminal K-2' "$H/logs/fly-pool.log")"
: > "$T/comments"

# BT2 a moved head re-arms and clears every note.
sinks; echo def > "$T/head"
tick
for f in K-2.terminal K-2.terminal-noted K-2.terminal-alerted K-2.held; do
  [ ! -e "$H/state/pool/p/$f" ] && ok || bad "BT2: $f must be gone after a re-arm"
done
grep -q 'machine run' "$T/fly.txt" && ok || bad "BT2: the re-armed key must reach the spawn: $(cat "$H/logs/fly-pool.log")"
# ...and the row the note closed `failed` goes back to `queued`, so the spawn's
# queued->claimed claim can land and the ledger does not read failed mid-build.
grep -q '^queue_put p K-2 2 fly' "$T/req.txt" && ok \
  || bad "BT2: a re-arm must put the failed row back to queued: $(cat "$T/req.txt")"
# A re-arm over a row that is not failed enqueues nothing.
reset_all; seed_terminal; echo queued > "$T/qstatus"; echo def > "$T/head"
tick
grep -q '^queue_put' "$T/req.txt" && bad "BT2: a queued row must not be re-enqueued on re-arm: $(cat "$T/req.txt")" || ok
grep -q 'machine run' "$T/fly.txt" && ok || bad "BT2b fixture: the re-armed key must reach the spawn: $(cat "$H/logs/fly-pool.log")"

# BT3 a failed comment retries next tick without paging twice.
reset_all; seed_terminal; echo queued > "$T/qstatus"; echo 1 > "$T/post-rc"
tick
[ ! -e "$H/state/pool/p/K-2.terminal-noted" ] && ok || bad "BT3: no sentinel after a failed POST"
echo 0 > "$T/post-rc"
tick
[ "$(cnt 'queued but never spawned' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "BT3: one page in total across the retry: $(cat "$H/logs/ALERTS.log")"
[ "$(wc -l < "$T/post.txt" | tr -d ' ')" = 2 ] && ok || bad "BT3: two POST attempts, got $(wc -l < "$T/post.txt")"
[ -e "$H/state/pool/p/K-2.terminal-noted" ] && ok || bad "BT3: the sentinel lands once the POST does"

# BT4 build_queue_rows_only: the row IS the queue. Closing it `failed` would
# drop it from queue_list for good and nothing could re-arm it, so the row stays
# queued, the skip is still noted, and a moved head on a later tick re-arms.
reset_all; seed_terminal; rm -f "$H/state/build-queue/p/K-2.json"; echo queued > "$T/qstatus"
tick ROWS_ONLY_TEST=1
grep -q 'queue_list' "$T/req.txt" && grep -q 'skipping K-2: terminal head unchanged' "$H/logs/fly-pool.log" && ok \
  || bad "BT4 fixture: the rows-only tick never reached the terminal gate: $(cat "$H/logs/fly-pool.log")"
grep -q '^queue_done' "$T/req.txt" && bad "BT4: under rows-only the row must not be closed: $(cat "$T/req.txt")" || ok
[ -f "$H/state/pool/p/K-2.held" ] && [ "$(cnt 'queued but never spawned' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "BT4: the skip is still held and paged: $(cat "$H/logs/ALERTS.log")"
grep -q 'machine run' "$T/fly.txt" && bad "BT4: no machine for a terminal key" || ok
sinks; echo def > "$T/head"
tick ROWS_ONLY_TEST=1
[ ! -e "$TERM" ] && grep -q 'machine run' "$T/fly.txt" && ok \
  || bad "BT4: a moved head must re-arm under rows-only: $(cat "$H/logs/fly-pool.log")"

# BT5 (review of 72b69292) the fleet-page hold row is written ONCE for a
# terminal key and never flaps: tick 1 puts it, tick 2 neither clears nor
# re-puts it, and a re-arm (a moved head) clears it on that tick.
reset_all; seed_terminal; echo queued > "$T/qstatus"; : > "$T/psr.txt"
tick PSR_TEST=1 PSR_LOG="$T/psr.txt"
[ "$(cnt '^PUT /api/pool-state/holds' "$T/psr.txt")" = 1 ] && grep -q '"key":"K-2"' "$T/psr.txt" && ok \
  || bad "BT5 tick1: one hold row PUT for K-2: $(cat "$T/psr.txt")"
: > "$T/psr.txt"; sinks; echo failed > "$T/qstatus"
tick PSR_TEST=1 PSR_LOG="$T/psr.txt"
grep -q 'skipping K-2: terminal head unchanged' "$H/logs/fly-pool.log" && ok || bad "BT5 tick2 fixture: the terminal gate was not reached"
[ "$(cnt '^PATCH /api/pool-state/holds' "$T/psr.txt")" = 0 ] && ok || bad "BT5 tick2: the hold row was cleared on a terminal key: $(cat "$T/psr.txt")"
[ "$(cnt '^PUT /api/pool-state/holds' "$T/psr.txt")" = 0 ] && ok || bad "BT5 tick2: the hold row was put again: $(cat "$T/psr.txt")"
: > "$T/psr.txt"; sinks; echo def > "$T/head"
tick PSR_TEST=1 PSR_LOG="$T/psr.txt"
[ "$(cnt '^PATCH /api/pool-state/holds' "$T/psr.txt")" = 1 ] && grep -q 'PATCH /api/pool-state/holds .*"key":"K-2"' "$T/psr.txt" && ok \
  || bad "BT5 re-arm: the hold row is cleared on the re-arm tick: $(cat "$T/psr.txt")"

echo "pool-closeout-custody.bh-5006: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
