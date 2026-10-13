#!/bin/bash
# tests/orphan-reconcile-needs-human.bh-3443-test.sh — bin/orphan-reconcile.sh
# leaves a ticket that is waiting on a human step alone, and says so in its log
# (BH-3443 T0.2). Drives the real reconciler with the fake GitHub REST + fake
# worker fixture of tests/orphan-reconcile-stranded.bh-3316-test.sh; run-build
# is stubbed to record launches.
#   §O  the placer's tagged Bot marker: OWNED hold:waiting-on-human, no launch
#   §L  one `reconcile: #41 skip :: waiting on human: <action>` line
#   §E  a person's HUMAN-STEP-DONE: over it: ORPHAN, launched once, no skip line
#   §F  the thread read fails: OWNED unverifiable:thread, no launch
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

NOW=$(date -u +%s)
AGO() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
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

# The comments arm serves fixture/comments-41.json, or HTTP 500 when
# fixture/comments-fail exists.
cat > "$T/fakebin/gh" <<'SH'
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
ARGS="$*"
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
[ "$PAGE" = 1 ] || SEND 200 '[]'
case "$ARGS" in
  *"api rate_limit"*) exit 1 ;;
  *"/issues/41/comments"*)
    [ -e "$HARNESS/fixture/comments-fail" ] && SEND 500 '{"message":"Server Error"}'
    SEND 200 "$(cat "$HARNESS/fixture/comments-41.json")" ;;
  *"/issues/"*"/comments"*) SEND 200 '[]' ;;
  *"/pulls"*) SEND 200 '[]' ;;
  *"/issues"*"state=all"*)
    SEND 200 "$(jq -c '[ .[] | {number, state:"open", closed_at:null} ]' "$HARNESS/fixture/open.json")" ;;
  *"/issues"*) SEND 200 "$(cat "$HARNESS/fixture/open.json")" ;;
  *) exit 1 ;;
esac
SH
cat > "$T/fakebin/curl" <<'SH'
URL="${!#}"
case "$URL" in
  */api/jobs*)  printf '{"jobs":[]}\n200\n' ;;
  */api/routing/*) printf '{"error":"no row"}\n404\n' ;;
  */api/queue*) printf '{"queue":[]}\n200\n' ;;
  */api/ledger*) printf '{"error":"not found"}\n404\n' ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

ACT='run vs_publish probe from the hub'
MARKER=$(jq -nc --arg b "NEEDS-HUMAN: $ACT

Builds of this ticket are paused until a person does the step above.
<!-- nh-fp:abc123def456 -->" --arg c "$(AGO 5400)" '{body:$b, created_at:$c, user:{type:"Bot"}}')
DONE=$(jq -nc --arg c "$(AGO 3600)" '{body:"HUMAN-STEP-DONE: ran it", created_at:$c, user:{type:"User"}}')
fixture() { # fixture <comments-json>
  printf '%s\n' "$1" > "$H/fixture/comments-41.json"
  jq -nc --arg u "$(AGO 7200)" --argjson n "$(jq length <<<"$1")" \
    '[{number:41, title:"TK-41 a ticket waiting on the hub", body:"## Scope", comments:$n, updated_at:$u, labels:[{name:"ai-build"}]}]' \
    > "$H/fixture/open.json"
  rm -f "$H"/state/orphan-reconcile/$P/*.enqueued "$H/fixture/comments-fail"
  : > "$H/launches.log"; : > "$H/logs/$P.log"
}
export ORPHAN_GRACE_MIN=0 ORPHAN_MAX_PER_RUN=20
run() { "$H/bin/orphan-reconcile.sh" "$P" --explain 2>/dev/null; }
row41() { awk -F'\t' '$1=="TK-41" {print $3"\t"$4}' <<<"$1"; }
skips() { grep -c 'skip :: waiting on human' "$H/logs/$P.log" || true; }

# ── §O / §L ────────────────────────────────────────────────────────────────
fixture "[$MARKER]"
OUT=$(run)
[[ "$(row41 "$OUT")" == "OWNED	hold:waiting-on-human "* ]] && ok \
  || bad "O: the tagged marker must read OWNED hold:waiting-on-human, got '$(row41 "$OUT")'"
[ -s "$H/launches.log" ] && bad "O: a ticket waiting on a human must not be launched: $(cat "$H/launches.log")" || ok
[ "$(grep -c "reconcile: #41 skip :: waiting on human: $ACT\$" "$H/logs/$P.log")" = 1 ] && ok \
  || bad "L: exactly one 'reconcile: #41 skip :: waiting on human: $ACT' line: $(grep -i human "$H/logs/$P.log")"

# ── §E: released ───────────────────────────────────────────────────────────
fixture "[$MARKER,$DONE]"
OUT=$(run)
[ "$(row41 "$OUT" | cut -f1)" = ORPHAN ] && ok || bad "E: a released ticket is an ORPHAN again, got '$(row41 "$OUT")'"
[ "$(grep -c 'TK-41' "$H/launches.log")" = 1 ] && ok || bad "E: …launched exactly once: $(cat "$H/launches.log")"
[ "$(skips)" = 0 ] && ok || bad "E: no skip line once released"

# ── §F: the thread read fails ──────────────────────────────────────────────
fixture "[$MARKER]"
: > "$H/fixture/comments-fail"
OUT=$(run)
[ "$(row41 "$OUT")" = "OWNED	unverifiable:thread" ] && ok || bad "F: an unread thread parks unverifiable:thread, got '$(row41 "$OUT")'"
[ -s "$H/launches.log" ] && bad "F: …and launches nothing" || ok

echo "orphan-reconcile-needs-human.bh-3443: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
