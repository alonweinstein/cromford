#!/bin/bash
# tests/data-lane-apply.bh-4920-test.sh — the data lane's apply step (BH-4923,
# order 1 of BH-4920), through the REAL bin/data-lane-apply.sh: its gates in
# order, the one POST, the ledger row, the one alert. gh, curl, the jobs client
# and lane-alert are stubs that append to one $T/calls log, so ORDER is
# asserted; the PR head lives in a local bare "origin".
#   A1-A8, A13, A14  every gate refuses before any POST
#   A9               the observable outcome: applied, ledgered, one log line
#   A10-A12          failure → ledger first, one alert, no retry; success re-run
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SCRIPT="$DIR/bin/data-lane-apply.sh"
[ -x "$SCRIPT" ] && [ -r "$DIR/bin/lib/data-lane.sh" ] && ok || bad "D41: $SCRIPT or $DIR/bin/lib/data-lane.sh is missing"
H="$T/h"
for s in bin/data-lane-apply.sh bin/check-migration-appliable.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: closure install for $s"; exit 1; }
done
mkdir -p "$H/env" "$H/flags" "$H/logs" "$T/bin" "$T/b"
TOKEN=tok-fixture-SECRET-4920
printf 'HARNESS_SECRET=s\n' > "$H/env/global.env"
printf 'DATA_LANE_APP_BASE=http://app.invalid\nMIGRATION_TOKEN=%s\nDATA_LANE_REPO_DIR=%s\n' "$TOKEN" "$H/repo" > "$H/env/p.env"
printf 'p o/r https://app.invalid - 1 hub\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf" GH_ETAG=0

# The repo: main, then a PR branch adding the migration. The scratch clone
# carries main only, so the script has to fetch the head itself.
SQL=scripts/migrations/0001_add_col.sql
G() { git -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false "$@"; }
G init -q --bare -b main "$T/origin.git"
G init -q -b main "$T/w" && echo base > "$T/w/README" && G -C "$T/w" add -A && G -C "$T/w" commit -qm base
mkdir -p "$T/w/scripts/migrations"
printf 'ALTER TABLE "Client" ADD COLUMN "redtailStatus" TEXT;\n' > "$T/w/$SQL"
G -C "$T/w" checkout -qb pr && G -C "$T/w" add -A && G -C "$T/w" commit -qm "add col"
G -C "$T/w" push -q "$T/origin.git" main pr
HEAD=$(G -C "$T/w" rev-parse HEAD); H12=${HEAD:0:12}
FP=$(git -C "$T/w" show "$HEAD:$SQL" | sha1sum | cut -c1-40)
G clone -q --single-branch -b main "$T/origin.git" "$H/repo"

# Stubs. gh answers the PR as an HTTP response (gh_rest reads `gh api -i`).
# BH-4925: it routes on the path. A comments GET answers [], a comments POST
# appends the body to $T/comments and answers 201 (the probe step's comment).
cat > "$T/bin/gh" <<EOF
#!/bin/bash
echo "gh \$*" >> "$T/calls"
[ -e "$T/gh-fail" ] && exit 1
printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n' "\$( [ "\$4" = POST ] && echo '201 Created' || echo '200 OK')"
case "\$4 \$5" in
  "GET "*/comments) echo '[]' ;;
  "POST "*/comments) for a in "\$@"; do case "\$a" in body=@*) cat "\${a#body=@}" >> "$T/comments" ;; esac; done; echo '{"id":1}' ;;
  *) jq -nc --arg h "\${STUB_HEAD:-$HEAD}" '{head:{sha:\$h},base:{ref:"main"}}' ;;
esac
EOF
# curl routes on the URL (BH-4925): the apply answers STUB_RESP/STUB_CODE as
# before; the probe answers a passing probe for exactly the targets it was sent.
cat > "$T/bin/curl" <<EOF
#!/bin/bash
echo "curl \$*" >> "$T/calls"
out=""; body=""; url=""; while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift ;;
    -H) case "\$2" in @*) cat "\${2#@}" >> "$T/auth-seen" ;; esac; shift ;;
    --data-binary) body=\${2#@}; shift ;;
    -m|-X|-w) shift ;;
    http*) url=\$1 ;;
  esac; shift
done
case "\$url" in
  */migrations/probe) cp "\$body" "$T/probe-body.json"; jq -c '{ok:true,results:[.targets[]|{target:.,ok:true}]}' "\$body" > "\$out"; printf 200 ;;
  *) cp "\$body" "$T/body.json"
     printf '%s' "\${STUB_RESP:-{\"ok\":true,\"status\":\"applied\"}}" > "\$out"
     printf '%s' "\${STUB_CODE:-200}" ;;
esac
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
echo "lane-alert \$*" >> "$T/calls"
EOF
# The jobs client: the ledger is "<kind> <key>\t<status>" lines in $T/ledger.
cat > "$H/bin/jobs-client.sh" <<EOF
job_ledger_get() {
  echo "ledger_get \$*" >> "$T/calls"
  [ "\${STUB_LEDGER_MODE:-}" = unknown ] && return 1
  local row; row=\$(awk -F'\t' -v k="\$1 \$2" '\$1==k{s=\$2} END{print s}' "$T/ledger" 2>/dev/null)
  [ -n "\$row" ] || return 2
  printf '%s' "\$row"
}
job_ledger_put() {
  echo "ledger_put \$1 \$2 = \$3" >> "$T/calls"
  [ -e "$T/put-fail" ] && return 1
  grep -v "^\$1 \$2	" "$T/ledger" > "$T/ledger.n" 2>/dev/null; printf '%s %s\t%s\n' "\$1" "\$2" "\$3" >> "$T/ledger.n"; mv "$T/ledger.n" "$T/ledger"
}
job_open()   { echo "job_open \$*" >> "$T/calls"; printf 'job-1'; }
# flag_active as the real client answers it: rc 0 when the row is active, which
# this stub reads from \$T/row-<name> (BH-4153: no flags/ file for paused-*),
# else the flags/ file, as the client does with no row (lane-gate reads it too).
flag_active() { echo "flag_active \$*" >> "$T/calls"; [ -e "$T/row-\$1" ] || [ -e "$H/flags/\$1" ]; }
job_update() { echo "job_update \$*" >> "$T/calls"; }
job_event()  { echo "job_event \$*" >> "$T/calls"; }
EOF
chmod +x "$T/bin/gh" "$T/bin/curl" "$H/bin/lane-alert.sh"

# review <verdict-extra…> — a BLOCK review with one finding and a DATA_LANE line.
review() {
  { echo "# Review"; echo "- **B1.** The column is read but $SQL is not applied to prod yet."
    printf '%s\n' "$@"; echo "DATA_LANE: $SQL"; echo "TIER: 2"; echo "VERDICT: BLOCK"; } > "$T/b/review.md"
  echo "$HEAD" > "$T/b/review-head"
}
reset() { rm -f "$T/calls" "$T/ledger" "$T/body.json" "$T/probe-body.json" "$T/auth-seen" "$T/gh-fail" "$T/put-fail" "$T/comments" "$T/b/data-lane-probe.md" "$H/flags/"* "$H/logs/p.log"; review; }
RUN() { # RUN [args…] — the real script; sets OUT and RC
  OUT=$(cd "$T" && PATH="$T/bin:$PATH" HARNESS="$H" bash "$H/bin/data-lane-apply.sh" "$@" 2>"$T/err"); RC=$?
}
APPLY() { OUT=$(cd "$T" && PATH="$T/bin:$PATH" HARNESS="$H" bash "$H/bin/data-lane-apply.sh" p 7 "$T/b" 2>"$T/err"); RC=$?; }
n() { local c; c=$(grep -c "^$1" "$T/calls" 2>/dev/null); echo "${c:-0}"; } # n <call prefix> — how many times
want() { # want <label> <rc> <stdout> <apply POSTs> (the probe POST is BH-4925's suite)
  [ "$RC" = "$2" ] && [ "$OUT" = "$3" ] && [ "$(n 'curl .*migrations/apply')" = "$4" ] && ok \
    || bad "$1: want rc $2 '$3' apply=$4, got rc $RC '$OUT' apply=$(n 'curl .*migrations/apply'): $(cat "$T/err" 2>/dev/null | head -3)"
}

# A1: lane off → rc 0, nothing printed, nothing called.
reset; touch "$H/flags/lane-off-data-lane"; APPLY
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(n curl)" = 0 ] && [ "$(n gh)" = 0 ] && ok || bad "A1: lane off gave rc $RC '$OUT' curl=$(n curl) gh=$(n gh)"
# A2: a second BLOCK → not-candidate.
reset; review "- **B2.** an unrelated bug"; APPLY; want A2 3 not-candidate 0
# A3: the review read an older sha than the PR head.
reset; G -C "$T/w" rev-parse HEAD~1 > "$T/b/review-head"; APPLY; want A3 3 not-candidate 0
# A3b: the final merged round's header wins over a stale review-head. The
# header carries the short sha review.sh writes (git rev-parse --short HEAD).
reset; G -C "$T/w" rev-parse HEAD~1 > "$T/b/review-head"
{ printf '\n=== MERGED RE-REVIEW after the single fix round (head %s) ===\n' "$(G -C "$T/w" rev-parse --short HEAD)"
  echo "- **B1.** only the unapplied migration is left"; echo "DATA_LANE: $SQL"; echo "TIER: 2"; echo "VERDICT: BLOCK"; } >> "$T/b/review.md"
APPLY; want A3b 0 applied 1
# A3c: a short header sha that is NOT a prefix of the PR head → not-candidate.
reset; G -C "$T/w" rev-parse HEAD > "$T/b/review-head"
{ printf '\n=== MERGED RE-REVIEW after the single fix round (head %s) ===\n' "$(G -C "$T/w" rev-parse --short HEAD~1)"
  echo "- **B1.** only the unapplied migration is left"; echo "DATA_LANE: $SQL"; echo "TIER: 2"; echo "VERDICT: BLOCK"; } >> "$T/b/review.md"
APPLY; want A3c 3 not-candidate 0
# A4: a FLAGGED .sql → ledger flagged, rc 2, no POST.
reset
printf 'ALTER TABLE "Client" DROP COLUMN "x";\n' > "$T/w/$SQL"; G -C "$T/w" commit -qam drop; G -C "$T/w" push -q "$T/origin.git" pr
HEAD2=$(G -C "$T/w" rev-parse HEAD); FP2=$(git -C "$T/w" show "$HEAD2:$SQL" | sha1sum | cut -c1-40)
echo "$HEAD2" > "$T/b/review-head"
STUB_HEAD=$HEAD2 APPLY; want A4 2 flagged 0
grep -qxF "migration p $SQL	flagged PR#7 head=${HEAD2:0:12} fp=$FP2" "$T/ledger" && ok || bad "A4: ledger row: $(cat "$T/ledger" 2>/dev/null)"
G -C "$T/w" reset -q --hard HEAD~1; G -C "$T/w" push -qf "$T/origin.git" pr
# A5: ledger unknown → rc 75, no POST, exactly one alert.
reset; STUB_LEDGER_MODE=unknown APPLY; want A5 75 busy 0
[ "$(n lane-alert)" = 1 ] && grep -q "lane-alert --id data-lane-hold:p " "$T/calls" && ok || bad "A5: want 1 hold alert, got: $(grep lane-alert "$T/calls")"
# A6: not configured → rc 5, no POST, no ledger write.
reset; cp "$H/env/p.env" "$T/p.env.bak"; sed -i '/^DATA_LANE_APP_BASE=/d' "$H/env/p.env"
APPLY; want A6 5 no-path 0
[ "$(n ledger_put)" = 0 ] && [ "$(n lane-alert)" = 0 ] && ok || bad "A6: wrote the ledger or alerted"
cp "$T/p.env.bak" "$H/env/p.env"
# A7: the lock is held → rc 75 at once, never waits.
reset; mkdir -p "$H/locks"
exec 8>"$H/locks/data-lane-p-7.lock"; flock -n 8 || bad "A7: could not take the lock for the test"
S=$(date +%s); APPLY; E=$(( $(date +%s) - S ))
exec 8>&-
want A7 75 busy 0; [ "$E" -lt 5 ] && ok || bad "A7: waited ${E}s on a held lock"
# A8: project paused.
reset; touch "$H/flags/paused-p"; APPLY; want A8 75 paused 0
# A8b (BH-4153): paused through the harness_flags row, with NO flags/ file on
# the box. The lane must refuse exactly as A8 does: no POST, no ledger row.
reset; rm -f "$T"/row-*; touch "$T/row-paused-p"; APPLY; want A8b 75 paused 0
[ "$(n ledger_put)" = 0 ] && ok || bad "A8b: a paused project writes no ledger row ($(cat "$T/calls" 2>/dev/null))"
grep -q '^flag_active paused-p$' "$T/calls" && ok || bad "A8b: the pause is read through flag_active ($(cat "$T/calls" 2>/dev/null))"
rm -f "$T/row-paused-p"

# A9: the observable outcome.
reset; APPLY; want A9 0 applied 1
grep -qxF "migration p $SQL	applied PR#7 head=$H12 fp=$FP" "$T/ledger" && ok || bad "A9: ledger row: $(cat "$T/ledger" 2>/dev/null)"
[ "$(grep -c 'data-lane:' "$H/logs/p.log")" = 1 ] && grep -qF "data-lane: $SQL PR#7 applied" "$H/logs/p.log" \
  && ok || bad "A9: want one data-lane log line naming the file and PR#7: $(cat "$H/logs/p.log")"
jq -e --arg h "$HEAD" --arg f "$SQL" --rawfile s "$T/w/$SQL" \
  '.mode=="pre-merge" and .actor=="archie-data-lane" and .head_sha==$h and .file==$f and .pr==7 and .repo=="o/r" and .statements==$s' \
  "$T/body.json" >/dev/null && ok || bad "A9: POST body: $(cat "$T/body.json" 2>/dev/null)"
grep -q "^curl .*http://app.invalid/api/internal/migrations/apply" "$T/calls" && ok || bad "A9: POST did not go to the apply endpoint"
grep -qx "Authorization: Bearer $TOKEN" "$T/auth-seen" && ok || bad "A9: the token never reached the request"
! grep -rqF "$TOKEN" "$H/logs" "$T/calls" && ok || bad "A9: the token leaked into logs or argv"
# job_open (kind=migration) happens before the POST. gh sees the PR GET and,
# since BH-4925, the evidence comment's list + one POST: never a merge, review or release.
awk '/^job_open p scripts\/migrations\/0001_add_col.sql migration /{j=NR} /^curl /{c=NR} END{exit !(j && c && j<c)}' "$T/calls" \
  && ok || bad "A9: job_open is not before the POST: $(cat "$T/calls")"
[ "$(n gh)" = 3 ] && grep -q "^gh api -i -X GET repos/o/r/pulls/7" "$T/calls" \
  && [ "$(n 'gh api -i -X GET repos/o/r/issues/7/comments')" = 1 ] && [ "$(n 'gh api -i -X POST repos/o/r/issues/7/comments')" = 1 ] \
  && ok || bad "A9: gh calls: $(grep '^gh' "$T/calls")"
# A12: re-run after success → rc 0, no second POST.
rm -f "$T/calls"; APPLY; want A12 0 applied 0

# A10: HTTP 500 → rc 1; ledger "failed apply" BEFORE the single alert; one write.
reset; STUB_CODE=500 STUB_RESP='{"ok":false,"error":"boom"}' APPLY; want A10 1 failed 1
grep -qxF "migration p $SQL	failed apply PR#7 head=$H12 fp=$FP" "$T/ledger" && ok || bad "A10: ledger: $(cat "$T/ledger" 2>/dev/null)"
[ "$(n ledger_put)" = 1 ] && [ "$(n lane-alert)" = 1 ] && grep -qF "lane-alert --id data-lane:p:$SQL:$FP --severity warn data-lane" "$T/calls" \
  && ok || bad "A10: want 1 ledger write + 1 alert with the id: $(grep -E '^(ledger_put|lane-alert)' "$T/calls")"
awk '/^ledger_put .*failed apply/{l=NR} /^lane-alert /{a=NR} END{exit !(l && a && l<a)}' "$T/calls" && ok || bad "A10: alert came before the ledger write"
grep -q '^job_update job-1 status=parked' "$T/calls" && ok || bad "A10: job not parked"
! grep -qF "$TOKEN" "$T/calls" "$H/logs/p.log" && ok || bad "A10: token in the alert or log"
# A10b: re-run → rc 3, no POST, no new alert.
rm -f "$T/calls"; APPLY; want A10b 3 not-candidate 0
[ "$(n lane-alert)" = 0 ] && ok || bad "A10b: a re-run alerted again"
# A10c: the failure row could not be written → the alert says so.
reset; touch "$T/put-fail"; STUB_CODE=500 APPLY; want A10c 1 failed 1
grep -q '^lane-alert .*NOT recorded' "$T/calls" && ok || bad "A10c: the alert does not say the failure went unrecorded"
# A11: already-applied → rc 0, ledger already-applied.
reset; STUB_RESP='{"ok":true,"status":"already-applied"}' APPLY; want A11 0 already-applied 1
grep -qxF "migration p $SQL	already-applied PR#7 head=$H12 fp=$FP" "$T/ledger" && ok || bad "A11: ledger: $(cat "$T/ledger" 2>/dev/null)"
# A11b: anything but ok:true + a literal status is a failure.
for R in '{"ok":true}' '{"ok":false,"status":"applied"}' '{"alreadyApplied":true}' '{"ok":"true","status":"applied"}' 'not json'; do
  reset; STUB_RESP=$R APPLY; want "A11b $R" 1 failed 1
  grep -qF "failed apply PR#7" "$T/ledger" && ok || bad "A11b $R: ledger: $(cat "$T/ledger" 2>/dev/null)"
done
# A13: bad args → rc 2, nothing called.
reset; RUN p abc "$T/b"; [ "$RC" = 2 ] && [ ! -e "$T/calls" ] && ok || bad "A13: 'p abc' gave rc $RC"
# A13b: a zero-padded PR number is the same PR (one lock, a valid JSON number).
reset; rm -f "$H/locks/"*
OUT=$(cd "$T" && PATH="$T/bin:$PATH" HARNESS="$H" bash "$H/bin/data-lane-apply.sh" p 007 "$T/b" 2>"$T/err"); RC=$?
want A13b 0 applied 1; jq -e '.pr==7' "$T/body.json" >/dev/null && ok || bad "A13b: body pr: $(cat "$T/body.json" 2>/dev/null)"
[ "$(ls "$H/locks")" = data-lane-p-7.lock ] && ok || bad "A13b: lock names: $(ls "$H/locks")"
reset; RUN p; [ "$RC" = 2 ] && [ ! -e "$T/calls" ] && ok || bad "A13: missing args gave rc $RC"
# A14: the PR head is unreadable → rc 75, no POST.
reset; touch "$T/gh-fail"; APPLY; want A14 75 busy 0

echo "data-lane-apply: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
