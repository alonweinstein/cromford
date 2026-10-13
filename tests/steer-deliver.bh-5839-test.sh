#!/bin/bash
# tests/steer-deliver.bh-5839-test.sh — BH-5839: the hub delivers the ticket
# page's "Add to the ticket" and "Hold, then tell it" notes.
#
# bin/lib/steer-deliver.sh reads the jobs worker's steer outbox and, per note:
#   ticket  posts ONE issue comment as the App
#   hold    holds the ticket through the REAL thc_run (bin/lib/ticket-hold-cmd.sh):
#           the hold label plus one App comment that carries the note; when the
#           label was already on, it posts the note itself
# and reports each one back (POST /api/steer/<id>/delivered). A note is never
# posted on the PAT: a PAT comment reads as a person's to hold_classify.
#
# `gh` is a stub on PATH that keeps the issue's labels across calls (the
# ticket-hold-cmd test's shape). _jobs_req, gh_auth_for, gh_auth_reset,
# job_ledger_put and hold_check are stubs defined after the libs are sourced.
#   D1 ticket note: one comment, as the App, carrying the text and the sender
#   D2 hold note: label added, one comment carrying the note, delivered
#   D3 hold note on a ticket already held: no label write, the note is posted
#   D4 no App token: nothing is posted, reported not ok with the reason
#   D4b the mint failed with an App token from elsewhere in the env: no post
#   D5 the comment POST fails: reported not ok with gh's error
#   D6 the outbox cannot be read: nothing is posted, rc 0
#   D7 a project that is not a GitHub-issues board: nothing posted, not ok
#   D8 bin/poll-commands.sh's marked block, RUN with the lease held: one outbox
#      read and one delivered report
#   D9 the same block on a box that does not hold the hub lease (rc 1) or
#      cannot tell (rc 2): no outbox read, no gh call (one box, one post)
#   D10 lease held but the lib is absent: rc 0, no read, no error output
#   D11 a ticket note whose marker comment is already on the issue (the report
#       was lost after a good post): no second post, reported ok
#   D12 a hold note whose thc_run comment is already on a held issue: no
#       second post, reported ok
#   D13 a hold with no App token: the label goes on but nobody sees the note,
#       so the report is not ok with "comment not posted"
#   D14 the claim is refused (another box has the note): no gh call, no report
#   D15 the issue's comments cannot be read: nothing posted, not ok
# Run from anywhere: tests/steer-deliver.bh-5839-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/steer-deliver.sh"
[ -r "$LIB" ] && ok || bad "D0 $LIB is missing"

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/stubbin" "$T/state"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/fleet-conf.sh"
cat > "$T/h/fleet.conf" <<'EOF'
# fixture
cromford example-org/cromford  -                     -                  1 hub
project-3       example-org/project-3        https://os.project-3.example  /api/feature-board 6 box-project-3-2
EOF
export FLEET_CONF="$T/h/fleet.conf" HARNESS="$T/h" GHLOG="$T/gh.log" GHSTATE="$T/state" JLOG="$T/jobs.log" LEDGER="$T/ledger"
cat > "$T/stubbin/gh" <<'EOF'
#!/bin/bash
method=GET; path=""; input=0; a=("$@")
for ((i=0; i<${#a[@]}; i++)); do
  case "${a[$i]}" in
    -X) method="${a[$((i+1))]}" ;;
    --input) input=1 ;;
    repos/*) path="${a[$i]}" ;;
  esac
done
body=-; [ "$input" = 1 ] && body=$(cat)
printf 'TOKEN=%s %s %s BODY=%s\n' "${GH_TOKEN:-}" "$method" "$path" "$body" >> "$GHLOG"
case "$method $path" in
  "GET repos/"*/comments*)
    [ "${GH_COMMENTS_READ_RC:-0}" = 0 ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    cat "$GHSTATE/comments.json" ;;
  "GET repos/"*/issues/[0-9]*) cat "$GHSTATE/issue.json" ;;
  "POST repos/"*/labels)
    jq -c '.labels += [{name:"hold"}]' "$GHSTATE/issue.json" > "$GHSTATE/i.tmp" && mv "$GHSTATE/i.tmp" "$GHSTATE/issue.json"
    echo '[{"name":"hold"}]' ;;
  "POST repos/"*/comments)
    [ "${GH_COMMENT_RC:-0}" = 0 ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    jq -c --argjson c "$body" '. + [$c]' "$GHSTATE/comments.json" > "$GHSTATE/c.tmp" && mv "$GHSTATE/c.tmp" "$GHSTATE/comments.json"
    echo '{"id":77}' ;;
  *) echo "gh stub: unexpected call $method $path" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/stubbin/gh"
export PATH="$T/stubbin:$PATH"

cat > "$T/stubs.sh" <<'EOF'
gh_auth_for() { printf 'gh_auth_for %s\n' "$1" >> "$GHLOG"; [ "${STUB_AUTH_RC:-0}" = 0 ] || return 1; export GH_TOKEN=ghs_stub; }
gh_auth_reset() { export GH_TOKEN=ghp_pat; }
job_ledger_put() { printf '%s\n' "$*" >> "$LEDGER"; JOBS_HTTP=200; return 0; }
hold_check() { printf 'held\thold label\n'; }
# The jobs worker: the outbox from $T/outbox.json, every delivered report logged.
_jobs_req() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$JLOG"
  case "$1 $2" in
    "GET /api/steer/outbox"*) [ -n "${OUTBOX_DOWN:-}" ] && { JOBS_HTTP=503; return 1; }; JOBS_HTTP=200; cat "$OUTBOX" ;;
    "POST /api/steer/"*/claim) [ -n "${CLAIM_409:-}" ] && { JOBS_HTTP=409; return 1; }; JOBS_HTTP=200; echo '{"note":{}}' ;;
    "POST /api/steer/"*/delivered) JOBS_HTTP=200; echo '{"note":{}}' ;;
    *) JOBS_HTTP=404; return 1 ;;
  esac
}
EOF

note() { # note <id> <mode> <text> [project] [ticket]
  jq -nc --argjson i "$1" --arg m "$2" --arg x "$3" --arg p "${4:-cromford}" --arg k "${5:-BH-4991}" \
    '{id:$i,project:$p,ticket:$k,job_id:null,mode:$m,text:$x,actor:"operator@example.com",status:"pending",attempts:0}'
}
outbox() { printf '%s\n' "$@" | jq -sc '{notes:.}' > "$T/outbox.json"; }
reset() { : > "$GHLOG"; : > "$JLOG"; : > "$LEDGER"; echo '{"number":4991,"state":"open","labels":[]}' > "$GHSTATE/issue.json"; echo '[]' > "$GHSTATE/comments.json"; }
tick() { # tick [VAR=VAL ...] -> steer_deliver_tick in a subshell with the real libs and the stubs
  ( export OUTBOX="$T/outbox.json" GH_TOKEN=ghp_fixture_pat "$@"
    . "$DIR/bin/lib/ticket-hold-cmd.sh"; . "$LIB"; . "$T/stubs.sh"
    steer_deliver_tick ) > "$T/out" 2>&1
  echo $?
}
comments() { grep -c ' POST repos/example-org/cromford/issues/4991/comments ' "$GHLOG" 2>/dev/null || true; }
reported() { grep "^POST /api/steer/$1/delivered " "$JLOG" | sed 's/^[^{]*//'; }

# D1 a ticket note: one App comment with the text and who sent it
reset; outbox "$(note 5 ticket 'Use the setup helper, not a hand copy.')"
r=$(tick)
[ "$r" = 0 ] && ok || bad "D1 rc $r: $(cat "$T/out")"
[ "$(comments)" = 1 ] && ok || bad "D1 comments $(comments), want 1: $(cat "$GHLOG")"
grep -q '^TOKEN=ghs_stub POST repos/example-org/cromford/issues/4991/comments ' "$GHLOG" && ok || bad "D1 the comment was not posted as the App"
grep -q 'Use the setup helper, not a hand copy.' "$GHLOG" && grep -q 'operator@example.com' "$GHLOG" && ok || bad "D1 the comment lacks the text or the sender: $(cat "$GHLOG")"
[ "$(reported 5 | jq -r .ok)" = true ] && ok || bad "D1 report: $(reported 5)"
grep -qx 'GET /api/steer/outbox ' "$JLOG" && ok || bad "D1 the outbox read is not a bare GET (the worker owns the page size): $(grep outbox "$JLOG")"
grep -qF '<!-- steer-note:5 -->' "$GHLOG" && ok || bad "D1 the comment lacks the note's marker"
[ "$(grep -n '^POST /api/steer/5/' "$JLOG" | cut -d' ' -f2 | tr '\n' ' ')" = '/api/steer/5/claim /api/steer/5/delivered ' ] && ok \
  || bad "D1 claim then report, in that order: $(grep '/api/steer/5/' "$JLOG")"

# D2 a hold note: the label, one comment with the note, delivered
reset; outbox "$(note 6 hold 'Wait for the schema answer.')"
r=$(tick)
grep -q ' POST repos/example-org/cromford/issues/4991/labels ' "$GHLOG" && ok || bad "D2 no label write: $(cat "$GHLOG")"
[ "$(comments)" = 1 ] && ok || bad "D2 comments $(comments), want 1"
grep -q '/issues/4991/comments .*Wait for the schema answer\.' "$GHLOG" && ok || bad "D2 the comment does not carry the note"
[ "$(reported 6 | jq -r .ok)" = true ] && ok || bad "D2 report: $(reported 6)"

# D3 already held: no label write, the note is still posted, once
reset; echo '{"number":4991,"state":"open","labels":[{"name":"hold"}]}' > "$GHSTATE/issue.json"
outbox "$(note 7 hold 'Also check the 375px layout.')"
r=$(tick)
grep -q ' /labels ' "$GHLOG" && bad "D3 a label write on a held ticket" || ok
[ "$(comments)" = 1 ] && grep -q '/issues/4991/comments .*Also check the 375px layout\.' "$GHLOG" && ok || bad "D3 comments $(comments): $(cat "$GHLOG")"
[ "$(reported 7 | jq -r .ok)" = true ] && ok || bad "D3 report: $(reported 7)"

# D4 no App token: nothing posted, not ok, the reason named
reset; outbox "$(note 8 ticket 'x')"
r=$(tick STUB_AUTH_RC=1)
[ "$(comments)" = 0 ] && ok || bad "D4 a comment was posted without the App token"
[ "$(reported 8 | jq -r .ok)" = false ] && reported 8 | jq -r .detail | grep -q 'no App token' && ok || bad "D4 report: $(reported 8)"
# D4b the mint failed but an App token from elsewhere is in the environment:
# it is not this repo's, so nothing is posted
reset; outbox "$(note 12 ticket 'x')"
r=$(tick STUB_AUTH_RC=1 GH_TOKEN=ghs_ambient_fixture)
[ "$(comments)" = 0 ] && ok || bad "D4b posted on an ambient token: $(cat "$GHLOG")"
[ "$(reported 12 | jq -r .ok)" = false ] && ok || bad "D4b report: $(reported 12)"

# D5 the comment POST fails: not ok, gh's error in the detail
reset; outbox "$(note 9 ticket 'x')"
r=$(tick GH_COMMENT_RC=1)
[ "$(reported 9 | jq -r .ok)" = false ] && reported 9 | jq -r .detail | grep -q '502' && ok || bad "D5 report: $(reported 9)"

# D6 the outbox cannot be read: nothing posted, rc 0
reset; outbox "$(note 10 ticket 'x')"
r=$(tick OUTBOX_DOWN=1)
[ "$r" = 0 ] && [ ! -s "$GHLOG" ] && ok || bad "D6 rc $r gh calls: $(cat "$GHLOG")"
grep -q '/delivered' "$JLOG" && bad "D6 a report without a read" || ok

# D7 an in-app board: nothing posted, not ok
reset; outbox "$(note 11 ticket 'x' project-3 TK-12)"
r=$(tick)
[ ! -s "$GHLOG" ] || ! grep -q ' POST ' "$GHLOG" && ok || bad "D7 posted to an in-app board: $(cat "$GHLOG")"
[ "$(reported 11 | jq -r .ok)" = false ] && reported 11 | jq -r .detail | grep -q '^refused: ' && ok || bad "D7 report: $(reported 11)"

# D8 poll-commands runs the deliverer from its marked block, on the lease holder
blk=$(awk '$0=="# >>> steer outbox (BH-5839)"{f=1;next} $0=="# <<< steer outbox"{exit} f' "$DIR/bin/poll-commands.sh")
[ -n "$blk" ] && ok || bad "D8 bin/poll-commands.sh has no '# >>> steer outbox (BH-5839)' block"
export LEASELOG="$T/lease.log"
lease_stub() { # lease_stub <harness>: bin/hub-lease.sh that logs its args and answers $LEASE_RC
  mkdir -p "$1/bin"
  printf '#!/bin/bash\necho "hub-lease $*" >> "$LEASELOG"\nexit "${LEASE_RC:-0}"\n' > "$1/bin/hub-lease.sh"
  chmod +x "$1/bin/hub-lease.sh"
}
lease_stub "$T/h"; lease_stub "$T/nolib"
scratch_install_closure bin/lib/steer-deliver.sh "$T/h" >/dev/null || bad "D8 could not install bin/lib/steer-deliver.sh"
run_block() { # run_block <harness> [VAR=VAL ...] -> the block's rc; its output in $T/out
  local h="$1"; shift
  ( export OUTBOX="$T/outbox.json" GH_TOKEN=ghp_fixture_pat "$@"; . "$T/stubs.sh"; HARNESS="$h"; eval "$blk" ) > "$T/out" 2>&1
  echo $?
}
reads() { grep -c '^GET /api/steer/outbox' "$JLOG" 2>/dev/null || true; }
reset; : > "$LEASELOG"; outbox "$(note 20 ticket 'From the block.')"
r=$(run_block "$T/h" LEASE_RC=0)
[ "$r" = 0 ] && ok || bad "D8 block rc $r: $(cat "$T/out")"
grep -q '^hub-lease check' "$LEASELOG" && ok || bad "D8 the block did not ask hub-lease.sh check: $(cat "$LEASELOG")"
[ "$(reads)" = 1 ] && ok || bad "D8 outbox reads $(reads), want 1: $(cat "$JLOG")"
[ "$(reported 20 | jq -r .ok)" = true ] && ok || bad "D8 report: $(reported 20)"
[ "$(comments)" = 1 ] && ok || bad "D8 comments $(comments), want 1"

# D9 not the lease holder (rc 1), or the lease cannot be read (rc 2): nothing
for rc in 1 2; do
  reset; : > "$LEASELOG"; outbox "$(note 21 ticket 'Not from here.')"
  r=$(run_block "$T/h" LEASE_RC=$rc)
  [ "$r" = 0 ] && ok || bad "D9 lease rc $rc: block rc $r"
  [ "$(reads)" = 0 ] && [ ! -s "$GHLOG" ] && ok || bad "D9 lease rc $rc: reads $(reads), gh calls: $(cat "$GHLOG")"
done

# D10 lease held, lib absent: rc 0, no read, quiet
reset; outbox "$(note 22 ticket 'x')"
r=$(run_block "$T/nolib" LEASE_RC=0)
[ "$r" = 0 ] && [ "$(reads)" = 0 ] && [ ! -s "$T/out" ] && ok || bad "D10 rc $r reads $(reads) out: $(cat "$T/out")"

# D11 the report was lost after a good post: the marker is found, no repost
reset; jq -nc '[{body:"Note from operator@example.com, sent from Mission Control:\n\nx\n\n<!-- steer-note:30 -->"}]' > "$GHSTATE/comments.json"
outbox "$(note 30 ticket 'x')"
r=$(tick)
[ "$(comments)" = 0 ] && ok || bad "D11 posted the same note twice: $(cat "$GHLOG")"
[ "$(reported 30 | jq -r .ok)" = true ] && reported 30 | jq -r .detail | grep -q 'already on' && ok || bad "D11 report: $(reported 30)"

# D12 a hold whose first delivery left thc_run's comment: no repost
reset; echo '{"number":4991,"state":"open","labels":[{"name":"hold"}]}' > "$GHSTATE/issue.json"
jq -nc '[{body:"Held from Mission Control by operator@example.com: Wait for it. The `hold` label stops every build."}]' > "$GHSTATE/comments.json"
outbox "$(note 31 hold 'Wait for it')"
r=$(tick)
[ "$(comments)" = 0 ] && ok || bad "D12 the hold note was posted again: $(cat "$GHLOG")"
[ "$(reported 31 | jq -r .ok)" = true ] && ok || bad "D12 report: $(reported 31)"

# D13 a hold with no App token: label on, note not shown, so not ok
reset; outbox "$(note 32 hold 'Nobody would see this.')"
r=$(tick STUB_AUTH_RC=1)
grep -q ' POST repos/example-org/cromford/issues/4991/labels ' "$GHLOG" && ok || bad "D13 no label write: $(cat "$GHLOG")"
[ "$(comments)" = 0 ] && ok || bad "D13 a comment was posted without the App token"
[ "$(reported 32 | jq -r .ok)" = false ] && reported 32 | jq -r .detail | grep -q 'comment not posted' && ok || bad "D13 report: $(reported 32)"

# D14 the claim is refused: nothing else happens to that note
reset; outbox "$(note 33 ticket 'x')"
r=$(tick CLAIM_409=1)
[ "$r" = 0 ] && [ ! -s "$GHLOG" ] && ok || bad "D14 rc $r gh calls on an unclaimed note: $(cat "$GHLOG")"
grep -q '/api/steer/33/delivered' "$JLOG" && bad "D14 an unclaimed note was reported" || ok

# D15 the comments cannot be read: no post, not ok
for m in ticket hold; do
  reset; outbox "$(note 34 "$m" 'x')"
  r=$(tick GH_COMMENTS_READ_RC=1)
  ! grep -q ' POST ' "$GHLOG" && ok || bad "D15 $m: wrote on an unread thread: $(cat "$GHLOG")"
  [ "$(reported 34 | jq -r .ok)" = false ] && ok || bad "D15 $m report: $(reported 34)"
done

echo "steer-deliver.bh-5839: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
