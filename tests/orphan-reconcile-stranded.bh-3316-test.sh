#!/bin/bash
# tests/orphan-reconcile-stranded.bh-3316-test.sh — a queued row whose target
# nothing will claim no longer owns its ticket; the reconciler reports the
# ticket STRANDED (stranded-target) and does not launch it (BH-3316).
#
# Five `target=local` rows on a pool-routed project sat queued 6h. Nothing
# claims a local row there (fly-dispatch and fly-pool claim `fly`), and the
# reconciler read each as `OWNED ledger:queue row queued`, so the one sweep
# meant to find unowned tickets stayed quiet. Drives the real
# bin/orphan-reconcile.sh with the fake GitHub REST + fake worker fixture of
# tests/orphan-reconcile-queue-page-test.sh; run-build is stubbed to record
# launches.
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
  */api/routing/*) printf '{"error":"no row"}\n404\n' ;;
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
printf '[%s,%s,%s]\n' \
  "$(iss 1174 'queued local on a pool project')" \
  "$(iss 2400 'queued fly')" \
  "$(iss 2326 'plain orphan')" > "$H/fixture/open.json"
jq -n --arg t "$(AGO 21000)" '{queue: [
  {project:"project-5",ticket_key:"TK-1174",ticket_id:"1174",status:"queued",target:"local",attempt:0,claimed_by:null,enqueued_at:$t,reason:null},
  {project:"project-5",ticket_key:"TK-2400",ticket_id:"2400",status:"queued",target:"fly",attempt:0,claimed_by:null,enqueued_at:$t}]}' \
  > "$H/fixture/queuerows.json"

export ORPHAN_GRACE_MIN=0 ORPHAN_MAX_PER_RUN=20
run() { "$H/bin/orphan-reconcile.sh" "$P" --explain 2>/dev/null; }
launched() { sort -u "$H/launches.log" 2>/dev/null; }
was_launched() { grep -qx "project-5 $1 TK-$1" <<<"$(launched)"; }
summary() { grep -o 'reconcile: open=.*' "$H/logs/$P.log" | tail -1; }

# --- 1. pool-routed project: the local row is stranded -----------------------
touch "$H/flags/builder-fly-$P" "$H/flags/fly-pool-$P"
: > "$H/launches.log"; : > "$H/logs/$P.log"
OUT=$(run)
verdict() { awk -F'\t' -v k="$1" '$1==k {print $3"\t"$4}' <<<"$OUT"; }
grep -q '^TK-1174	1174	STRANDED	stranded-target:queue row queued target=local$' <<<"$OUT" \
  && ok || bad "1: a queued local row on a pool project must read STRANDED stranded-target: $(verdict TK-1174)"
was_launched 1174 && bad "1: a STRANDED ticket must not be launched (the put would be a duplicate of its own row)" || ok
grep -q '^TK-2400	2400	OWNED	ledger:queue row queued$' <<<"$OUT" \
  && ok || bad "1: a queued fly row on a pool project still owns its ticket: $(verdict TK-2400)"
was_launched 2400 && bad "1: an owned ticket was launched" || ok
was_launched 2326 && ok || bad "1: a plain orphan must still be launched: $(launched | tr '\n' ' ')"
summary | grep -q ' stranded=1$' && ok || bad "1: the summary must count stranded=1: $(summary)"
grep -q 'reconcile: stranded-target — TK-1174(queue row queued target=local)' "$H/logs/$P.log" \
  && ok || bad "1: the log must name the stranded ticket: $(grep stranded "$H/logs/$P.log")"

# --- 2. the same row on a local project owns its ticket, as before ------------
rm -f "$H/flags/builder-fly-$P" "$H/flags/fly-pool-$P" "$H"/state/orphan-reconcile/$P/*.enqueued
: > "$H/launches.log"; : > "$H/logs/$P.log"
OUT=$(run)
grep -q '^TK-1174	1174	OWNED	ledger:queue row queued$' <<<"$OUT" \
  && ok || bad "2: a queued local row on a local project must stay OWNED: $(verdict TK-1174)"
was_launched 1174 && bad "2: an owned local row's ticket was launched" || ok
grep -q '^TK-2400	2400	OWNED	ledger:queue row queued$' <<<"$OUT" \
  && ok || bad "2: a fly row on a flagless project (the unknown-routing case) must stay OWNED: $(verdict TK-2400)"
summary | grep -q ' stranded=0$' && ok || bad "2: the summary must count stranded=0: $(summary)"
grep -q 'stranded-target —' "$H/logs/$P.log" && bad "2: no stranded line on a quiet run" || ok

# --- 3. halted pool: the fly row is stranded too ------------------------------
touch "$H/flags/builder-fly-$P" "$H/flags/fly-pool-$P" "$H/flags/pool-halt-$P"
rm -f "$H"/state/orphan-reconcile/$P/*.enqueued
: > "$H/launches.log"; : > "$H/logs/$P.log"
OUT=$(run)
grep -q '^TK-2400	2400	STRANDED	stranded-target:queue row queued target=fly$' <<<"$OUT" \
  && ok || bad "3: a queued fly row on a halted pool must read STRANDED: $(verdict TK-2400)"
was_launched 2400 && bad "3: a STRANDED ticket was launched" || ok

echo "orphan-reconcile-stranded.bh-3316: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
