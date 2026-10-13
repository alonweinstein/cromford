#!/bin/bash
# tests/data-lane-probe.bh-4925-test.sh — the data lane's probe and evidence
# comment (BH-4925, order 2 of BH-4920), through the REAL bin/data-lane-apply.sh.
# An apply that answers applied/already-applied is proven by a read-only probe
# before the ledger row, the evidence file <build-dir>/data-lane-probe.md and
# one tag-deduped DATA-LANE-APPLIED: comment. gh, curl, the jobs client and
# lane-alert are stubs that append to one $T/calls log, so ORDER is asserted.
#   P1, P1b      the candidate path: apply probe ledger comment, the file, no token
#   P2, P2b, P7  a probe miss: ledger first, one alert, no file, no comment, no retry
#   P3, P8       already-applied, and the ledger short-circuit with no probe file
#   P4, P4b      re-run and the exact-tag dedupe
#   P5, P6       the targets sent, and a file with no complete target set
#   P9, P9b      the comment is pending (rc 75) until it is confirmed posted
#   P10          no evidence file written -> comment-pending 75, no comment
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SCRIPT="$DIR/bin/data-lane-apply.sh"
[ -x "$SCRIPT" ] && ok || bad "D41: $SCRIPT is missing"
H="$T/h"
for s in bin/data-lane-apply.sh bin/check-migration-appliable.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: closure install for $s"; exit 1; }
done
mkdir -p "$H/env" "$H/flags" "$H/logs" "$T/bin" "$T/b"
# The value names itself a fixture (bin/share/mapping.py FIXTURE_MARKERS): the
# public mirror's gitleaks gate refused `tok-SECRET-4925` as a generic API key.
# It is still one unique string, so P1b's "never written" greps are as strict.
TOKEN=tok-fixture-4925-migration
printf 'HARNESS_SECRET=s\n' > "$H/env/global.env"
printf 'DATA_LANE_APP_BASE=http://app.invalid\nMIGRATION_TOKEN=%s\nDATA_LANE_REPO_DIR=%s\n' "$TOKEN" "$H/repo" > "$H/env/p.env"
printf 'p o/r https://app.invalid - 1 hub\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf" GH_ETAG=0

SQL=scripts/migrations/0002_redtail.sql
G() { git -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false "$@"; }
G init -q --bare -b main "$T/origin.git"
G init -q -b main "$T/w" && echo base > "$T/w/README" && G -C "$T/w" add -A && G -C "$T/w" commit -qm base
mkdir -p "$T/w/scripts/migrations"
printf -- '-- adds the redtail status\nALTER TABLE "Client" ADD COLUMN "redtailStatus" TEXT;\nCREATE INDEX IF NOT EXISTS "c_rs" ON "Client"("redtailStatus");\n' > "$T/w/$SQL"
G -C "$T/w" checkout -qb pr && G -C "$T/w" add -A && G -C "$T/w" commit -qm "add col"
G -C "$T/w" push -q "$T/origin.git" main pr
HEAD=$(G -C "$T/w" rev-parse HEAD); H12=${HEAD:0:12}
FP=$(git -C "$T/w" show "$HEAD:$SQL" | sha1sum | cut -c1-40)
G clone -q --single-branch -b main "$T/origin.git" "$H/repo"
T1='SELECT "redtailStatus" FROM "Client" LIMIT 0'
T2='SELECT 1 FROM "Client" LIMIT 0'
PF="$T/b/data-lane-probe.md"
TAG="<!-- dl-fp:$FP -->"

# gh: `gh api -i -X <method> <path> …`. The PR GET answers the PR; a comments
# GET answers the posted bodies as a JSON array (page 1 only); a comments POST
# stores its -F body=@file and answers 201, or 500 when $T/post-fail exists.
cat > "$T/bin/gh" <<EOF
#!/bin/bash
echo "gh \$*" >> "$T/calls"
m=\$4; p=\$5
hdr() { printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n' "\$1"; }
case "\$m \$p" in
  "GET "*/pulls/7) hdr "200 OK"; jq -nc --arg h "\${STUB_HEAD:-$HEAD}" '{head:{sha:\$h},base:{ref:"main"}}' ;;
  "GET "*/comments)
    [ -e "$T/list-fail" ] && { hdr "500 Internal"; echo '{}'; exit 1; }
    [ -e "$T/list-obj" ] && { hdr "200 OK"; echo '{}'; exit 0; }
    hdr "200 OK"
    case " \$* " in *" page=1 "*) ;; *) echo '[]'; exit 0 ;; esac
    mkdir -p "$T/comments"
    for f in "$T/comments"/*; do [ -f "\$f" ] && jq -Rs '{body:.}' "\$f"; done | jq -sc . ;;
  "POST "*/comments)
    [ -e "$T/post-fail" ] && { hdr "500 Internal"; echo '{}'; exit 1; }
    for a in "\$@"; do case "\$a" in body=@*) mkdir -p "$T/comments"; cp "\${a#body=@}" "$T/comments/c\$(date +%s%N)" ;; esac; done
    hdr "201 Created"; echo '{"id":1}' ;;
  *) hdr "404 Not Found"; echo '{}'; exit 1 ;;
esac
EOF
# curl routes on the URL: apply answers STUB_RESP/STUB_CODE; probe answers a
# passing probe for the targets it was sent, or STUB_PROBE/STUB_PROBE_CODE.
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
  */migrations/apply) cp "\$body" "$T/body.json"
    printf '%s' "\${STUB_RESP:-{\"ok\":true,\"status\":\"applied\"}}" > "\$out"; printf '%s' "\${STUB_CODE:-200}" ;;
  */migrations/probe) cp "\$body" "$T/probe-body.json"
    if [ -n "\${STUB_PROBE:-}" ]; then printf '%s' "\$STUB_PROBE" > "\$out"
    else jq -c '{ok:true,results:[.targets[]|{target:.,ok:true}]}' "\$body" > "\$out"; fi
    printf '%s' "\${STUB_PROBE_CODE:-200}" ;;
  *) exit 6 ;;
esac
EOF
# mv fails onto the probe file while $T/mv-fail exists: the evidence file
# cannot be written (a full or unwritable build dir; root ignores chmod).
cat > "$T/bin/mv" <<EOF
#!/bin/bash
[ -e "$T/mv-fail" ] && [ "\${!#}" = "$PF" ] && exit 1
exec /bin/mv "\$@"
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
echo "lane-alert \$*" >> "$T/calls"
EOF
cat > "$H/bin/jobs-client.sh" <<EOF
job_ledger_get() {
  echo "ledger_get \$*" >> "$T/calls"
  local row; row=\$(awk -F'\t' -v k="\$1 \$2" '\$1==k{s=\$2} END{print s}' "$T/ledger" 2>/dev/null)
  [ -n "\$row" ] || return 2
  printf '%s' "\$row"
}
job_ledger_put() {
  echo "ledger_put \$1 \$2 = \$3" >> "$T/calls"
  grep -v "^\$1 \$2	" "$T/ledger" > "$T/ledger.n" 2>/dev/null; printf '%s %s\t%s\n' "\$1" "\$2" "\$3" >> "$T/ledger.n"; mv "$T/ledger.n" "$T/ledger"
}
job_open()   { echo "job_open \$*" >> "$T/calls"; printf 'job-1'; }
job_update() { echo "job_update \$*" >> "$T/calls"; }
job_event()  { echo "job_event \$*" >> "$T/calls"; }
EOF
chmod +x "$T/bin/gh" "$T/bin/curl" "$T/bin/mv" "$H/bin/lane-alert.sh"

review() {
  { echo "# Review"; echo "- **B1.** The column is read but $SQL is not applied to prod yet."
    echo "DATA_LANE: $SQL"; echo "TIER: 2"; echo "VERDICT: BLOCK"; } > "$T/b/review.md"
  echo "$HEAD" > "$T/b/review-head"
}
reset() { rm -rf "$T/calls" "$T/ledger" "$T/body.json" "$T/probe-body.json" "$T/auth-seen" "$T/comments" \
  "$T/post-fail" "$T/list-obj" "$T/list-fail" "$T/mv-fail" "$PF" "$H/flags/"* "$H/logs/p.log"; review; }
APPLY() { OUT=$(cd "$T" && PATH="$T/bin:$PATH" HARNESS="$H" bash "$H/bin/data-lane-apply.sh" p 7 "$T/b" 2>"$T/err"); RC=$?; }
n() { local c; c=$(grep -cE "^$1" "$T/calls" 2>/dev/null); echo "${c:-0}"; }
NA() { n 'curl .*migrations/apply'; }
NP() { n 'curl .*migrations/probe'; }
NC() { n 'gh api -i -X POST repos/o/r/issues/7/comments'; }
ncomments() { find "$T/comments" -type f 2>/dev/null | wc -l | tr -d ' '; }
want() { # want <label> <rc> <stdout> <apply POSTs> <probe POSTs> <comment POSTs>
  [ "$RC" = "$2" ] && [ "$OUT" = "$3" ] && [ "$(NA)" = "$4" ] && [ "$(NP)" = "$5" ] && [ "$(NC)" = "$6" ] && ok \
    || bad "$1: want rc $2 '$3' apply=$4 probe=$5 comment=$6, got rc $RC '$OUT' apply=$(NA) probe=$(NP) comment=$(NC): $(head -3 "$T/err" 2>/dev/null)"
}
# Was every line in "$@" seen in $T/calls, in that order (first match after the last)?
inorder() { awk -v pats="$(printf '%s\n' "$@")" 'BEGIN{n=split(pats,p,"\n"); i=1} i<=n && $0 ~ p[i] {i++} END{exit !(i>n)}' "$T/calls"; }

# P1: the candidate path.
reset; APPLY; want P1 0 applied 1 1 1
inorder '^curl .*migrations/apply' '^curl .*migrations/probe' "^ledger_put migration p $SQL = applied PR#7 head=$H12 fp=$FP\$" '^gh api -i -X POST repos/o/r/issues/7/comments' \
  && ok || bad "P1: call order is not apply probe ledger comment: $(grep -E '^(curl|ledger_put|gh)' "$T/calls")"
[ "$(n ledger_put)" = 1 ] && ok || bad "P1: want 1 ledger write, got $(n ledger_put)"
grep -qxF "fp=$FP" "$PF" && grep -qxF "head=$HEAD" "$PF" && grep -qxF "project=p" "$PF" && grep -qxF "pr=7" "$PF" \
  && ok || bad "P1: probe file keys: $(cat "$PF" 2>/dev/null)"
grep -qxF -- "- ok  $T1" "$PF" && grep -qxF -- "- ok  $T2" "$PF" && ok || bad "P1: probe file rows: $(cat "$PF" 2>/dev/null)"
grep -qxF 'ALTER TABLE "Client" ADD COLUMN "redtailStatus" TEXT;' "$PF" && grep -qF '"status":"applied"' "$PF" \
  && ok || bad "P1: probe file lacks the statements or the apply response"
C1=$(find "$T/comments" -type f 2>/dev/null | head -1)
[ "$(ncomments)" = 1 ] && [ "$(head -1 "$C1")" = "DATA-LANE-APPLIED: $SQL" ] && grep -qxF "$TAG" "$C1" \
  && grep -qxF -- "- ok  $T1" "$C1" && grep -qF "$H12" "$C1" && ! grep -q '—' "$C1" \
  && ok || bad "P1: comment: $(cat "$C1" 2>/dev/null)"
grep -q '^job_update job-1 status=done' "$T/calls" && ok || bad "P1: job not closed done"
# P1b: the token is in none of the file, the comment, the log or the call log.
! grep -rqF "$TOKEN" "$PF" "$T/comments" "$H/logs" "$T/calls" "$T/probe-body.json" && grep -qx "Authorization: Bearer $TOKEN" "$T/auth-seen" \
  && ok || bad "P1b: the token leaked or never reached the request"
# P5: the probe body.
jq -e --arg f "$SQL" --arg h "$HEAD" --arg a "$T1" --arg b "$T2" '.file==$f and .head_sha==$h and .targets==[$a,$b] and (keys|length)==3' \
  "$T/probe-body.json" >/dev/null && ok || bad "P5: probe body: $(cat "$T/probe-body.json" 2>/dev/null)"

# P4: re-run after P1 → no apply, no probe, no comment.
rm -f "$T/calls"; APPLY; want P4 0 applied 0 0 0
[ "$(ncomments)" = 1 ] && [ "$(n lane-alert)" = 0 ] && ok || bad "P4: comments=$(ncomments) alerts=$(n lane-alert)"

# P4b: a comment that mentions the fp without the exact tag does not count.
reset; mkdir -p "$T/comments"; printf 'we will tag it dl-fp:%s later\n' "$FP" > "$T/comments/c0"
APPLY; want P4b 0 applied 1 1 1
[ "$(ncomments)" = 2 ] && ok || bad "P4b: want 2 comments, got $(ncomments)"

# P2 / P2b / P7 / P7b: every shape of a probe miss.
miss() { # miss <label>  (after APPLY with a bad probe stub)
  want "$1" 1 failed 1 1 0
  [ "$(n ledger_put)" = 1 ] && grep -qxF "ledger_put migration p $SQL = failed probe PR#7 head=$H12 fp=$FP" "$T/calls" \
    && ok || bad "$1: ledger writes: $(grep '^ledger_put' "$T/calls")"
  [ "$(n lane-alert)" = 1 ] && grep -qF "lane-alert --id data-lane:p:$SQL:$FP --severity warn data-lane" "$T/calls" \
    && ok || bad "$1: alerts: $(grep '^lane-alert' "$T/calls")"
  inorder '^ledger_put .*failed probe' '^lane-alert ' && ok || bad "$1: the alert came before the ledger write"
  [ ! -e "$PF" ] && [ "$(ncomments)" = 0 ] && ok || bad "$1: a probe file or a comment exists after a miss"
  grep -q '^job_update job-1 status=parked' "$T/calls" && ok || bad "$1: job not parked"
  ! grep -qF "$TOKEN" "$T/calls" && ok || bad "$1: token in the alert"
}
reset; STUB_PROBE='{"ok":true,"status":"applied"}' APPLY; miss P2
# P2 second run: rc 3, no curl at all, no new alert.
rm -f "$T/calls"; APPLY; want P2-rerun 3 not-candidate 0 0 0
[ "$(n curl)" = 0 ] && [ "$(n lane-alert)" = 0 ] && ok || bad "P2-rerun: curl=$(n curl) alerts=$(n lane-alert)"
reset; STUB_PROBE=$(jq -nc --arg a "$T1" '{ok:true,results:[{target:$a,ok:true}]}') APPLY; miss P2b
reset; STUB_PROBE_CODE=500 APPLY; miss P7
reset; STUB_PROBE=$(jq -nc --arg a "$T1" '{ok:true,results:[{target:$a,ok:true},{target:"SELECT 1 FROM \"Other\" LIMIT 0",ok:true}]}') APPLY; miss P7b
reset; STUB_PROBE=$(jq -nc --arg a "$T1" --arg b "$T2" '{ok:false,results:[{target:$a,ok:true},{target:$b,ok:true}]}') APPLY; miss P7c
reset; STUB_PROBE=$(jq -nc --arg a "$T1" --arg b "$T2" '{ok:true,results:[{target:$a,ok:true},{target:$b,ok:false}]}') APPLY; miss P7d

# P3: the apply answers already-applied.
reset; STUB_RESP='{"ok":true,"status":"already-applied"}' APPLY; want P3 0 already-applied 1 1 1
grep -qxF "migration p $SQL	already-applied PR#7 head=$H12 fp=$FP" "$T/ledger" && grep -qxF "fp=$FP" "$PF" \
  && ok || bad "P3: ledger $(cat "$T/ledger" 2>/dev/null) / probe file $(test -e "$PF" && echo present || echo absent)"

# P8: ledger already applied, no probe file → one probe, no apply, file, comment.
reset; printf 'migration p %s\tapplied PR#7 head=%s fp=%s\n' "$SQL" "$H12" "$FP" > "$T/ledger"
APPLY; want P8 0 applied 0 1 1
grep -qxF "fp=$FP" "$PF" && grep -qxF "ledger: applied" "$PF" && [ "$(n ledger_put)" = 0 ] \
  && ok || bad "P8: probe file $(cat "$PF" 2>/dev/null) ledger_put=$(n ledger_put)"
# P8b: the same, with a probe file for another fp → probed again, file rewritten.
reset; printf 'migration p %s\tapplied PR#7 head=%s fp=%s\n' "$SQL" "$H12" "$FP" > "$T/ledger"
printf 'fp=%s\n' "0000000000000000000000000000000000000000" > "$PF"
APPLY; want P8b 0 applied 0 1 1
grep -qxF "fp=$FP" "$PF" && ok || bad "P8b: probe file not rewritten for this fp"
# P8c: ledger applied, probe misses → failed probe row, one alert, rc 1.
reset; printf 'migration p %s\tapplied PR#7 head=%s fp=%s\n' "$SQL" "$H12" "$FP" > "$T/ledger"
STUB_PROBE='{"ok":false}' APPLY; want P8c 1 failed 0 1 0
grep -qxF "migration p $SQL	failed probe PR#7 head=$H12 fp=$FP" "$T/ledger" && [ "$(n lane-alert)" = 1 ] && [ ! -e "$PF" ] \
  && ok || bad "P8c: ledger $(cat "$T/ledger") alerts=$(n lane-alert)"

# P6: no complete probe target set → rc 3 before any POST or ledger write.
# Every input here passes check-migration-appliable, so it reaches the gate.
G -C "$T/w" checkout -q pr
for BADSQL in 'ALTER TABLE "Client" ADD CONSTRAINT "c_u" UNIQUE ("redtailStatus");' \
              'CREATE INDEX ON "Client"("redtailStatus");' \
              'CREATE INDEX "i" ON public."Client"("redtailStatus");' \
              'ALTER TABLE public."Client" ADD COLUMN "z" TEXT;' \
              'CREATE TABLE "x y" (id int);'; do
  printf '%s\n' "$BADSQL" > "$T/w/$SQL"; G -C "$T/w" commit -qam bad; G -C "$T/w" push -q "$T/origin.git" pr
  HB=$(G -C "$T/w" rev-parse HEAD)
  reset; echo "$HB" > "$T/b/review-head"; STUB_HEAD=$HB APPLY
  want "P6 $BADSQL" 3 not-candidate 0 0 0
  [ "$(n curl)" = 0 ] && [ "$(n ledger_put)" = 0 ] && [ "$(n job_open)" = 0 ] && ok || bad "P6 $BADSQL: curl=$(n curl) ledger_put=$(n ledger_put)"
  G -C "$T/w" reset -q --hard HEAD~1; G -C "$T/w" push -qf "$T/origin.git" pr
done
# P5b: CREATE TABLE and unquoted, mixed-case statements produce the right
# targets. A bare name is folded to lower case, as Postgres folds it, so
# ALTER TABLE Client ADD COLUMN Status probes "status" on "client".
printf 'create table if not exists "Note" (id int);\nalter table "Note" add column if not exists body text;\nALTER TABLE Client ADD COLUMN Status text;\n' > "$T/w/$SQL"
G -C "$T/w" commit -qam good; G -C "$T/w" push -q "$T/origin.git" pr; HB=$(G -C "$T/w" rev-parse HEAD)
reset; echo "$HB" > "$T/b/review-head"; STUB_HEAD=$HB APPLY; want P5b 0 applied 1 1 1
jq -e '.targets==["SELECT 1 FROM \"Note\" LIMIT 0","SELECT \"body\" FROM \"Note\" LIMIT 0","SELECT \"status\" FROM \"client\" LIMIT 0"]' "$T/probe-body.json" >/dev/null \
  && ok || bad "P5b: targets: $(jq -c .targets "$T/probe-body.json" 2>/dev/null)"
G -C "$T/w" reset -q --hard HEAD~1; G -C "$T/w" push -qf "$T/origin.git" pr

# P9: the comment POST fails → rc 75 comment-pending, file present, no alert;
# the next run posts it without another apply or probe.
reset; touch "$T/post-fail"; APPLY; want P9 75 comment-pending 1 1 1
[ -e "$PF" ] && grep -qxF "migration p $SQL	applied PR#7 head=$H12 fp=$FP" "$T/ledger" && [ "$(n lane-alert)" = 0 ] && [ "$(ncomments)" = 0 ] \
  && ok || bad "P9: file/ledger/alert: $(cat "$T/ledger" 2>/dev/null) alerts=$(n lane-alert)"
rm -f "$T/post-fail" "$T/calls"; APPLY; want P9-rerun 0 applied 0 0 1
[ "$(ncomments)" = 1 ] && ok || bad "P9-rerun: want 1 comment, got $(ncomments)"
# P9b: the comment list is not an array → unknown → rc 75, no POST.
reset; touch "$T/list-obj"; APPLY; want P9b 75 comment-pending 1 1 0
[ "$(n lane-alert)" = 0 ] && ok || bad "P9b: alerted on a pending comment"
# P9c: the comment list read fails → rc 75, no POST.
reset; touch "$T/list-fail"; APPLY; want P9c 75 comment-pending 1 1 0

# P10: the evidence file cannot be written → rc 75 comment-pending, ledger
# applied, no file, no comment, no alert; the next run probes again (no apply),
# writes the file, then posts the comment.
reset; touch "$T/mv-fail"; APPLY; want P10 75 comment-pending 1 1 0
[ ! -e "$PF" ] && grep -qxF "migration p $SQL	applied PR#7 head=$H12 fp=$FP" "$T/ledger" && [ "$(n lane-alert)" = 0 ] && [ "$(ncomments)" = 0 ] \
  && ok || bad "P10: file $(test -e "$PF" && echo present || echo absent) ledger $(cat "$T/ledger" 2>/dev/null) alerts=$(n lane-alert) comments=$(ncomments)"
rm -f "$T/mv-fail" "$T/calls"; APPLY; want P10-rerun 0 applied 0 1 1
grep -qxF "fp=$FP" "$PF" && [ "$(ncomments)" = 1 ] && ok || bad "P10-rerun: file/comment: $(ncomments) comments"
# P10b: the same on the ledger short-circuit (applied row, no file).
reset; printf 'migration p %s\tapplied PR#7 head=%s fp=%s\n' "$SQL" "$H12" "$FP" > "$T/ledger"
touch "$T/mv-fail"; APPLY; want P10b 75 comment-pending 0 1 0
[ ! -e "$PF" ] && [ "$(ncomments)" = 0 ] && ok || bad "P10b: a file or comment exists without the evidence file write"

echo "data-lane-probe: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
