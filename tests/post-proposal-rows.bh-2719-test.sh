#!/bin/bash
# tests/post-proposal-rows.bh-2719-test.sh — BH-2719 (BH-2531 slice 3): the real
# bin/post-proposal.sh asks the product_proposals row before it creates the one
# thing the client sees, the [Proposal] board ticket, and a box whose ledger
# file was wiped does not post the same proposal twice.
#
#   P1     first post: claim `posting` BEFORE the create, then row + file `posted`
#   P2     fresh box (no ledger file), row `posted` -> zero board calls, exit 0
#   P3     row `posting` -> zero board calls, exit 1, one ALERTS line
#   P4     configured worker down -> zero board calls, exit 1, ALERTS
#   P4b    the claim PUT does not land -> no create, exit 1
#   P5     a refused create (422 / curl rc 7) hands the claim back
#   P6     JOBS_URL empty: the file's `posted` alone stops a re-post
#   P7     negatives that must NOT block a first post
#   P8     an unknown create outcome holds the row at `posting`; a re-approve
#          makes zero creates
#   B3     a ledger wipe after one post re-posts nothing (B3b: nor does a
#          ledger restored from an older copy)
#
# The only network is a stub `curl` first on PATH:
#   http://jobs.test   the harness-jobs worker, rows persisted under $T/db as
#                      <project>--<slug>.json; 503 while $T/db-down exists; PUT
#                      answers $T/put-code when that file exists
#   http://board.test  the client's board (project-1, /api/board): every call
#                      is logged to $T/board.log; the create answers
#                      {"id":"t-1"} or what $T/create-mode names
# Every request, jobs and board, is appended in order to $T/seq.
#
# Run from anywhere: tests/post-proposal-rows.bh-2719-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
# Never the live worker or board: drop anything inherited.
unset JOBS_URL HARNESS_SECRET JOBS_BOX JOBS_ALERT PROJECT_1_API_BASE PROJECT_1_INTERNAL_API_TOKEN

P=project-1
H="$T/h"; DB="$T/db"; BLOG="$T/board.log"; SEQ="$T/seq"
LEDGER="$H/state/product-$P.ledger.json"
ALERTS="$H/logs/ALERTS.log"
mkdir -p "$H/bin/lib/jobs" "$H/env" "$H/state" "$H/logs" "$T/stub" "$DB"

cp "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/proposal-rows.sh" "$H/bin/lib/"
cp "$DIR/bin/post-proposal.sh" "$H/bin/"
printf '#!/bin/bash\necho "beat $*" >> "%s/beat.log"\nexit 0\n' "$T" > "$H/bin/beat.sh"
chmod +x "$H"/bin/*.sh

cat > "$H/env/global.env" <<EOF
HARNESS_SECRET=test-secret
JOBS_URL=http://jobs.test
JOBS_RETRIES=0
JOBS_ALERT=0
EOF
cat > "$H/env/$P.env" <<EOF
PROJECT_1_API_BASE=http://board.test
PROJECT_1_INTERNAL_API_TOKEN=tok
EOF

cat > "$T/stub/curl" <<'CURL'
#!/bin/bash
M=GET; D=""; W=0; F=0; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M=$2; shift ;;
    -d|--data-binary) D=$2; shift ;;
    -w) W=1; shift ;;
    -H|-m|--max-time|--connect-timeout) shift ;;
    -sf|-fs|-f) F=1 ;;
    -*) ;;
    *) URL=$1 ;;
  esac
  shift
done
case "$D" in @*) D=$(cat "${D#@}") ;; esac
# ans <code> <body> [curl rc] — what real curl prints for -w / -f.
ans() {
  if [ "$F" = 1 ] && [ "$W" = 0 ] && [ "$1" -ge 400 ] 2>/dev/null; then exit 22; fi
  printf '%s' "$2"; [ "$W" = 1 ] && printf '\n%s' "$1"; exit "${3:-0}"
}
case "$URL" in
  http://jobs.test/*)
    echo "jobs $M ${URL#http://jobs.test} $(jq -r '.status // empty' <<<"${D:-{\}}" 2>/dev/null)" >> "$STUB_T/seq"
    [ -e "$STUB_T/db-down" ] && ans 503 '{"error":"product_proposals unavailable"}'
    path=${URL#http://jobs.test}; q=${path#*\?}; path=${path%%\?*}
    [ "$path" = /api/product-proposals ] || ans 404 '{"error":"unknown endpoint"}'
    if [ "$M" = PUT ]; then
      [ -e "$STUB_T/put-code" ] && ans "$(cat "$STUB_T/put-code")" '{"error":"stub put refused"}'
      p=$(jq -r .project <<<"$D"); s=$(jq -r .proposal_id <<<"$D"); f="$STUB_T/db/$p--$s.json"
      if [ "$(jq -r '.if_absent // false' <<<"$D")" = true ] && [ -f "$f" ]; then
        ans 200 "$(jq -c '{proposal: ., inserted: false}' "$f")"
      fi
      jq -c --arg u "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{project, proposal_id, status, record, updated_at: $u}' <<<"$D" > "$f"
      ans 200 "$(jq -c '{proposal: .}' "$f")"
    fi
    qp() { printf '%s' "$q" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
    p=$(qp project); s=$(qp proposal_id)
    if [ -n "$s" ]; then
      [ -f "$STUB_T/db/$p--$s.json" ] || ans 404 '{"error":"proposal not found"}'
      ans 200 "$(jq -c '{proposal: .}' "$STUB_T/db/$p--$s.json")"
    fi
    ans 200 "$(cat /dev/null "$STUB_T"/db/"$p"--*.json 2>/dev/null | jq -sc '{proposals: ., truncated: false, as_of: "t"}')"
    ;;
  http://board.test/*)
    echo "$M $URL" >> "$STUB_T/board.log"; echo "board $M $URL" >> "$STUB_T/seq"
    case "$M $URL" in
      "GET http://board.test/api/board/boards") ans 200 '[{"id":"b1"}]' ;;
      "POST http://board.test/api/board/boards/b1/tickets")
        case "$(cat "$STUB_T/create-mode" 2>/dev/null)" in
          422)   ans 422 '{"error":"title required"}' ;;
          rc7)   ans 000 '' 7 ;;
          rc28)  ans 000 '' 28 ;;
          500)   ans 500 '{"error":"upstream"}' ;;
          empty) ans 200 '{}' ;;
          *)     ans 201 '{"id":"t-1"}' ;;
        esac ;;
      "GET http://board.test/api/board/tickets/t-1") ans 200 '{"number":7}' ;;
      *attachments*) exit 22 ;;
      *) ans 200 '{}' ;;
    esac ;;
esac
exit 7
CURL
chmod +x "$T/stub/curl"
export STUB_T="$T"
RUNPATH="$T/stub:$PATH"

# ── fixtures ────────────────────────────────────────────────────────────────
idir() { local d="$T/ideas/$1"; mkdir -p "$d"; printf '<p>x</p>{{MOCKUP_BLOCK}}' > "$d/ticket.html"; printf '<html/>' > "$d/mockup.html"; echo "$d"; }
entry() { jq -nc --arg s "$1" --arg st "$2" --arg d "$(idir "$1")" \
  '{slug:$s,title:("T "+$s),status:$st,dir:$d,updated_at:"2026-09-20T00:00:00Z"}'; }
putrow() { local r; r=$(entry "$2" "$3"); jq -nc --arg p "$1" --arg s "$2" --arg st "$3" --argjson r "$r" \
  '{project:$p,proposal_id:$s,status:$st,record:$r,updated_at:"2026-09-20T00:00:00Z"}' > "$DB/$1--$2.json"; }
rowst() { jq -r .status "$DB/$1--$2.json" 2>/dev/null; }
fileset() { printf '%s\n' "$@" | jq -s . > "$LEDGER"; }
fst() { jq -r --arg s "$1" '[.[] | select(.slug == $s)] | last | .status // empty' "$LEDGER" 2>/dev/null; }
reset() {
  local x; for x in "$DB" "$T/db-down" "$T/put-code" "$T/create-mode" "$LEDGER"; do scratch_rm "$x"; done
  mkdir -p "$DB"; : > "$BLOG"; : > "$SEQ"; : > "$ALERTS"
}
creates() { grep -c '^POST http://board.test/api/board/boards/b1/tickets$' "$BLOG"; }
boardcalls() { grep -c . "$BLOG"; }
nalerts() { grep -c . "$ALERTS"; }
unconfigured() { sed -i 's/^JOBS_URL=.*/JOBS_URL=/' "$H/env/global.env"; }
configured() { sed -i 's|^JOBS_URL=.*|JOBS_URL=http://jobs.test|' "$H/env/global.env"; }
post() { HARNESS="$H" HARNESS_ENV_DIR="$H/env" PATH="$RUNPATH" bash "$H/bin/post-proposal.sh" "$@" > "$T/out.txt" 2>&1; }

# Safety gate, not the proof: a post-proposal.sh that ignores $HARNESS would run
# against the LIVE /root/harness (its ledger, env, ALERTS.log and board). Every
# case below fails instead of running it there.
if ! grep -qxF 'HARNESS="${HARNESS:-/root/harness}"' "$H/bin/post-proposal.sh"; then
  for c in P1 P2 P3 P4 P4b P5 P6 P7 P8 B3 B3b; do
    bad "$c: $DIR/bin/post-proposal.sh hardcodes HARNESS, so it cannot run under a scratch harness (not run against the live one)"
  done
  echo "post-proposal-rows: $PASS passed, $FAIL failed"
  exit 1
fi

# ── P1: first post ──────────────────────────────────────────────────────────
reset; fileset "$(entry foo gate_pending)"
post "$P" foo; RC=$?
[ "$RC" = 0 ] && ok || bad "P1: a first post exits 0 (rc=$RC): $(cat "$T/out.txt")"
[ "$(creates)" = 1 ] && ok || bad "P1: exactly one board create (got $(creates))"
[ "$(rowst "$P" foo)" = posted ] && ok || bad "P1: the row ends posted (got $(rowst "$P" foo))"
[ "$(jq -r .record.ticket_id "$DB/$P--foo.json" 2>/dev/null)" = t-1 ] && ok || bad "P1: the row carries ticket_id t-1: $(cat "$DB/$P--foo.json" 2>/dev/null)"
[ "$(fst foo)" = posted ] && ok || bad "P1: the file's last entry is posted (got $(fst foo))"
CLAIM_AT=$(grep -n '^jobs PUT /api/product-proposals posting$' "$SEQ" | head -1 | cut -d: -f1)
CREATE_AT=$(grep -n '^board POST .*/boards/b1/tickets$' "$SEQ" | head -1 | cut -d: -f1)
[ -n "$CLAIM_AT" ] && [ -n "$CREATE_AT" ] && [ "$CLAIM_AT" -lt "$CREATE_AT" ] && ok \
  || bad "P1: the posting claim must come before the create: $(cat "$SEQ")"
# The posted stamp lands before the first attachment call (best-effort work).
STAMP_AT=$(grep -n '^jobs PUT /api/product-proposals posted$' "$SEQ" | head -1 | cut -d: -f1)
ATT_AT=$(grep -n '^board POST .*attachments' "$SEQ" | head -1 | cut -d: -f1)
[ -n "$STAMP_AT" ] && [ -n "$ATT_AT" ] && [ "$STAMP_AT" -lt "$ATT_AT" ] && ok \
  || bad "P1: the row is stamped posted before the attachments: $(cat "$SEQ")"

# ── B3: P1's state, then the ledger is wiped, then the proposal is approved again
rm -f "$LEDGER"; : > "$ALERTS"
post "$P" foo; RC=$?
[ "$RC" = 0 ] && ok || bad "B3: the re-run after a wipe exits 0 (rc=$RC): $(cat "$T/out.txt")"
[ "$(creates)" = 1 ] && ok || bad "B3: a wiped ledger re-posts nothing (total creates $(creates), want 1)"
# B3b: the ledger comes back as an OLDER copy (a restore from backup): it still
# says gate_pending, the row says posted.
fileset "$(entry foo gate_pending)"
post "$P" foo; RC=$?
[ "$RC" = 0 ] && ok || bad "B3b: an older ledger copy exits 0 (rc=$RC): $(cat "$T/out.txt")"
[ "$(creates)" = 1 ] && ok || bad "B3b: an older ledger copy re-posts nothing (total creates $(creates), want 1)"

# ── P2: fresh box, row posted ───────────────────────────────────────────────
reset; putrow "$P" foo posted
post "$P" foo; RC=$?
[ "$RC" = 0 ] && ok || bad "P2: fresh box, row posted: exit 0 (rc=$RC): $(cat "$T/out.txt")"
[ "$(boardcalls)" = 0 ] && ok || bad "P2: fresh box, row posted: zero board calls (got: $(cat "$BLOG"))"
grep -q 'already posted' "$T/out.txt" && ok || bad "P2: says 'already posted': $(cat "$T/out.txt")"
[ "$(fst foo)" = posted ] && ok || bad "P2: the restore brought the wiped entry back (file: $(cat "$LEDGER" 2>/dev/null))"

# ── P3: row posting ─────────────────────────────────────────────────────────
reset; putrow "$P" foo posting; fileset "$(entry foo gate_pending)"
post "$P" foo; RC=$?
[ "$RC" = 1 ] && ok || bad "P3: a posting row exits 1 (rc=$RC)"
[ "$(boardcalls)" = 0 ] && ok || bad "P3: a posting row makes zero board calls (got: $(cat "$BLOG"))"
[ "$(nalerts)" = 1 ] && grep -q 'foo' "$ALERTS" && ok || bad "P3: exactly one ALERTS line naming the slug: $(cat "$ALERTS")"

# ── P4: configured worker down; P4b: the claim does not land ────────────────
reset; fileset "$(entry foo gate_pending)"; : > "$T/db-down"
post "$P" foo; RC=$?
[ "$RC" = 1 ] && ok || bad "P4: worker down (configured) exits 1 (rc=$RC)"
[ "$(boardcalls)" = 0 ] && ok || bad "P4: worker down makes zero board calls (got: $(cat "$BLOG"))"
[ "$(nalerts)" = 1 ] && grep -q 'foo' "$ALERTS" && ok || bad "P4: one ALERTS line naming the slug: $(cat "$ALERTS")"
reset; fileset "$(entry foo gate_pending)"; echo 503 > "$T/put-code"
post "$P" foo; RC=$?
[ "$RC" = 1 ] && ok || bad "P4b: a claim that did not land exits 1 (rc=$RC)"
[ "$(creates)" = 0 ] && ok || bad "P4b: a claim that did not land makes zero creates (got $(creates))"
grep -q 'foo.*claim' "$ALERTS" && ok || bad "P4b: an ALERTS line about the claim: $(cat "$ALERTS")"

# ── P5: a refused create hands the claim back ───────────────────────────────
for mode in 422 rc7; do
  reset; fileset "$(entry foo gate_pending)"; putrow "$P" foo gate_pending; echo "$mode" > "$T/create-mode"
  post "$P" foo; RC=$?
  [ "$RC" = 1 ] && ok || bad "P5 $mode: a refused create exits 1 (rc=$RC)"
  [ "$(rowst "$P" foo)" = gate_pending ] && ok || bad "P5 $mode: the row is back at gate_pending (got $(rowst "$P" foo))"
  [ "$(grep -c 'ticket create failed for foo' "$ALERTS")" = 1 ] && ok || bad "P5 $mode: one create-failed alert: $(cat "$ALERTS")"
done
grep -q 'ticket create failed for foo (curl rc 7, HTTP 000' "$ALERTS" && ok || bad "P5 rc7: the alert carries the curl rc: $(cat "$ALERTS")"
reset; fileset "$(entry foo gate_pending)"; putrow "$P" foo gate_pending; echo 422 > "$T/create-mode"
post "$P" foo
grep -q 'ticket create failed for foo (curl rc 0, HTTP 422' "$ALERTS" && ok || bad "P5 422: the alert carries curl rc and HTTP code: $(cat "$ALERTS")"

# ── P6: no worker configured, the file alone ────────────────────────────────
reset; unconfigured; fileset "$(entry foo posted)"
post "$P" foo; RC=$?
[ "$RC" = 0 ] && ok || bad "P6: no worker + file posted: exit 0 (rc=$RC): $(cat "$T/out.txt")"
[ "$(boardcalls)" = 0 ] && ok || bad "P6: no worker + file posted: zero board calls (got: $(cat "$BLOG"))"
reset; fileset "$(entry foo gate_pending)"
post "$P" foo; RC=$?
[ "$RC" = 0 ] && [ "$(creates)" = 1 ] && ok || bad "P6: no worker + file gate_pending posts once (rc=$RC creates=$(creates)): $(cat "$T/out.txt")"
[ "$(grep -c '^jobs ' "$SEQ")" = 0 ] && ok || bad "P6: no worker means no jobs request: $(cat "$SEQ")"
configured

# ── P7: negatives that must not block a first post ──────────────────────────
for case in gate_pending other-project neighbour-slug; do
  reset; fileset "$(entry foo gate_pending)"
  case "$case" in
    gate_pending)   putrow "$P" foo gate_pending ;;
    other-project)  putrow other foo posted ;;
    neighbour-slug) putrow "$P" foo-2 posted ;;
  esac
  post "$P" foo; RC=$?
  [ "$RC" = 0 ] && [ "$(creates)" = 1 ] && ok || bad "P7 $case: must post exactly once (rc=$RC creates=$(creates)): $(cat "$T/out.txt")"
done

# ── P8: an unknown create outcome holds the claim; a re-approve makes nothing
for mode in rc28 500 empty; do
  reset; fileset "$(entry foo gate_pending)"; putrow "$P" foo gate_pending; echo "$mode" > "$T/create-mode"
  post "$P" foo; RC=$?
  [ "$RC" = 1 ] && ok || bad "P8 $mode: an unknown-outcome create exits 1 (rc=$RC)"
  [ "$(rowst "$P" foo)" = posting ] && ok || bad "P8 $mode: the row stays posting (got $(rowst "$P" foo))"
  grep -q 'foo.*unknown outcome.*check the board' "$ALERTS" && ok || bad "P8 $mode: an alert to check the board: $(cat "$ALERTS")"
  scratch_rm "$T/create-mode"
  post "$P" foo; RC=$?
  [ "$RC" = 1 ] && ok || bad "P8 $mode: the re-approve exits 1 (rc=$RC)"
  [ "$(creates)" = 1 ] && ok || bad "P8 $mode: the re-approve makes zero creates (total $(creates))"
done

echo "post-proposal-rows: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
