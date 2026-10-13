#!/bin/bash
# tests/post-proposal-allowlist.bh-4065-test.sh — BH-4065 (the operator's rebuild notes,
# 2026-10-04, N1): an Approve on an Archie proposal files an `ai-build` issue
# ONLY for a repo on the settings row lane.archie-research.approve_files_issue_repos
# (default example-org/cromford). Every other GitHub-Issues project keeps
# main's behaviour: `post-proposal: unknown project`, exit 1, nothing filed.
#
#   P1  no row: cromford files exactly one issue, the row goes posted
#   P2  a repeat Approve files none, exit 0
#   P3  project-5, no row: exit 1, zero gh calls, no `posting` claim
#   P4  the row decides, not code: row=project-5 blocks cromford; a row
#       naming both lets project-5 file one on its own repo
#   P5  matcher negatives: case, prefixes, suffixes, separator-only values, a
#       fleet.conf repo that only shares a prefix, glob rows (`example-org/*`)
#       run from a CWD that holds example-org/cromford/
#   P6  the row is unreadable while a worker is configured: fail closed, one
#       ALERTS line through bin/alert-line.sh
#   P7  JOBS_URL empty on purpose: the documented default applies
#
# Drives the REAL bin/post-proposal.sh under a scratch HARNESS. The only
# network is a stub `curl` (the jobs worker) and a stub `gh` (GitHub).
# Run from anywhere: tests/post-proposal-allowlist.bh-4065-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2], want [$3]"; fi; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
unset JOBS_URL HARNESS_SECRET JOBS_BOX JOBS_ALERT GH_TOKEN GITHUB_TOKEN

H="$T/h"; DB="$T/db"; SEQ="$T/seq"; GHC="$T/gh.calls"
ALERTS="$H/logs/ALERTS.log"
mkdir -p "$H/env" "$H/state" "$H/logs" "$T/stub" "$DB" "$T/cwd/example-org/cromford"
cp -rs "$DIR/bin" "$H/bin"
rm -f "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.jsonl"\nexit 0\n' "$T" > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
cat > "$H/fleet.conf" <<'EOF'
cromford example-org/cromford - - 3 box-small
project-5 example-org/project-5 - - 3 box-small
bhfork example-org/cromford-fork - - 3 box-small
EOF
KEY=lane.archie-research.approve_files_issue_repos

# The jobs worker: product_proposals rows persisted under $T/db, the settings
# row answered from $T/setting (404 when absent, 500 while $T/settings-down).
cat > "$T/stub/curl" <<'CURL'
#!/bin/bash
M=GET; D=""; W=0; F=0; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M=$2; shift ;;
    -d|--data-binary) D=$2; shift ;;
    -w) W=1; shift ;;
    -H|-m|--max-time|--connect-timeout|-o) shift ;;
    -sf|-fs|-f) F=1 ;;
    -*) ;;
    *) URL=$1 ;;
  esac
  shift
done
case "$D" in @*) D=$(cat "${D#@}") ;; esac
ans() {
  if [ "$F" = 1 ] && [ "$W" = 0 ] && [ "$1" -ge 400 ] 2>/dev/null; then exit 22; fi
  printf '%s' "$2"; [ "$W" = 1 ] && printf '\n%s' "$1"; exit "${3:-0}"
}
case "$URL" in
  http://jobs.test/*)
    path=${URL#http://jobs.test}; q=${path#*\?}; path=${path%%\?*}
    echo "jobs $M $path $(jq -r '.status // empty' <<<"${D:-{\}}" 2>/dev/null)" >> "$STUB_T/seq"
    case "$path" in
      /api/settings/*)
        [ -e "$STUB_T/settings-down" ] && ans 500 '{"error":"settings unavailable"}'
        [ -f "$STUB_T/setting" ] || ans 404 '{"error":"setting not found"}'
        ans 200 "$(jq -nc --arg k "${path#/api/settings/}" --rawfile v "$STUB_T/setting" '{setting:{key:$k,value:($v|rtrimstr("\n"))}}')" ;;
      /api/product-proposals) ;;
      *) ans 404 '{"error":"unknown endpoint"}' ;;
    esac
    if [ "$M" = PUT ]; then
      p=$(jq -r .project <<<"$D"); s=$(jq -r .proposal_id <<<"$D"); f="$STUB_T/db/$p--$s.json"
      if [ "$(jq -r '.if_absent // false' <<<"$D")" = true ] && [ -f "$f" ]; then
        ans 200 "$(jq -c '{proposal: ., inserted: false}' "$f")"
      fi
      jq -c '{project, proposal_id, status, record, updated_at: "2026-10-04T00:00:00Z"}' <<<"$D" > "$f"
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
esac
echo "net $URL" >> "$STUB_T/net.log"
exit 7
CURL
# GitHub: every call logged; an issue create answers 201 with a number.
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_T/gh.calls"
case "$*" in
  *"-X POST repos/"*"/issues"*)
    printf 'HTTP/2.0 201 Created\r\n\r\n{"number":77,"html_url":"https://github.com/x/y/issues/77"}\n' ;;
  *) printf 'HTTP/2.0 404 Not Found\r\n\r\n{}\n' ;;
esac
SH
chmod +x "$T/stub/curl" "$T/stub/gh"
export STUB_T="$T"

# reset: a fresh box state, one gate_pending proposal per project in the ledger.
reset() {
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/logs" || exit 1; scratch_rm "$DB" || exit 1
  mkdir -p "$H/state" "$H/logs" "$DB"
  rm -f "$GHC" "$SEQ" "$T/setting" "$T/settings-down" "$T/beats.jsonl" "$T/net.log"
  printf 'JOBS_URL=http://jobs.test\nHARNESS_SECRET=test-secret\nJOBS_RETRIES=0\nJOBS_ALERT=0\n' > "$H/env/global.env"
  for p in cromford project-5 bhfork; do
    mkdir -p "$T/ideas/$p"
    printf '<p>idea</p>{{MOCKUP_BLOCK}}' > "$T/ideas/$p/ticket.html"; printf '<div>mock</div>' > "$T/ideas/$p/mockup.html"
    jq -nc --arg d "$T/ideas/$p" '[{slug:"archie-0123456789ab",title:"Try X",status:"gate_pending",dir:$d,updated_at:"2026-10-04T00:00:00Z"}]' \
      > "$H/state/product-$p.ledger.json"
  done
}
setrow() { printf '%s' "$1" > "$T/setting"; }
approve() { # approve <project>: rc in $RC, stdout in $T/out
  # Run from a CWD that holds example-org/cromford/, so a row that globbed
  # (`example-org/*`) would expand to the candidate and fail open (P5).
  ( cd "$T/cwd" && env HARNESS="$H" FLEET_CONF="$H/fleet.conf" PATH="$T/stub:$PATH" GH_APP_TOKENS=0 \
    bash "$H/bin/post-proposal.sh" "$1" archie-0123456789ab > "$T/out" 2>&1 )
  RC=$?
}
# A missing log is zero lines, not an empty answer.
lines() { cat "$1" 2>/dev/null | grep -c -- "$2"; }
creates() { lines "$GHC" "-X POST repos/$1/issues"; }
ghn() { lines "$GHC" .; }
claimed() { lines "$SEQ" "^jobs PUT /api/product-proposals posting$"; }
rowst() { jq -r .status "$DB/$1--archie-0123456789ab.json" 2>/dev/null; }

# ── P1 / P2 ────────────────────────────────────────────────────────────────
reset
approve cromford
eq "P1 no settings row: cromford exits 0 ($(cat "$T/out"); $(cat "$ALERTS" 2>/dev/null))" "$RC" 0
eq "P1 exactly one issue create on example-org/cromford" "$(creates example-org/cromford)" 1
eq "P1 the row is posted" "$(rowst cromford)" posted
grep -q "^jobs GET /api/settings/$KEY " "$SEQ" && ok || bad "P1 the allowlist was never read from the settings row"
approve cromford
eq "P2 a repeat Approve exits 0" "$RC" 0
eq "P2 a repeat Approve files none" "$(creates example-org/cromford)" 1
grep -q 'already posted' "$T/out" && ok || bad "P2 the repeat did not say already posted ($(cat "$T/out"))"

# ── P3 ──────────────────────────────────────────────────────────────────────
reset
approve project-5
eq "P3 project-5, no row: exit 1" "$RC" 1
eq "P3 project-5: zero gh calls" "$(ghn)" 0
grep -q '\[project-5\] post-proposal: unknown project' "$ALERTS" 2>/dev/null && ok || bad "P3 no 'unknown project' ALERTS line ($(cat "$ALERTS" 2>/dev/null))"
eq "P3 project-5: no posting claim" "$(claimed)" 0
eq "P3 project-5: the row is not touched" "$(rowst project-5)" ""

# ── P4 ──────────────────────────────────────────────────────────────────────
reset; setrow 'example-org/project-5'
approve cromford
eq "P4a row=project-5: cromford exits 1" "$RC" 1
eq "P4a row=project-5: cromford makes zero gh calls" "$(ghn)" 0
eq "P4a no posting claim" "$(claimed)" 0
reset; setrow 'example-org/cromford, example-org/project-5'
approve project-5
eq "P4b row names project-5: it exits 0 ($(cat "$T/out"); $(cat "$ALERTS" 2>/dev/null))" "$RC" 0
eq "P4b one create on example-org/project-5" "$(creates example-org/project-5)" 1
eq "P4b nothing on cromford" "$(creates example-org/cromford)" 0

# ── P5: matcher negatives ───────────────────────────────────────────────────
for v in 'example-org/cromford-old' 'example-org/cromford' 'example-org/board' 'example-org/*' 'example-org/board-harnes?' '*' '*/*' ',' ' , ' 'example-org/cromford.'; do
  reset; setrow "$v"
  approve cromford
  eq "P5 row='$v': cromford exits 1" "$RC" 1
  eq "P5 row='$v': zero gh calls" "$(ghn)" 0
done
reset
approve bhfork
eq "P5 example-org/cromford-fork with the default row: exit 1" "$RC" 1
eq "P5 example-org/cromford-fork: zero gh calls" "$(ghn)" 0
# Whitespace and newline separators are accepted, exact entries still match.
reset; setrow $'example-org/project-5\nexample-org/cromford'
approve cromford
eq "P5 a newline-separated list still matches cromford" "$(creates example-org/cromford)" 1

# ── P6: outage fails closed ─────────────────────────────────────────────────
reset; : > "$T/settings-down"
approve cromford
eq "P6 settings outage: exit 1" "$RC" 1
eq "P6 settings outage: zero gh calls" "$(ghn)" 0
eq "P6 settings outage: no posting claim" "$(claimed)" 0
eq "P6 one 'allowlist unreadable' ALERTS line" "$(grep -c 'allowlist unreadable' "$ALERTS" 2>/dev/null || true)" 1
ls "$H/state/alert-line-sent/"* >/dev/null 2>&1 && ok || bad "P6 the outage line did not go through bin/alert-line.sh (no state/alert-line-sent marker)"

# ── P7: no worker configured ───────────────────────────────────────────────
reset; printf 'JOBS_URL=\n' > "$H/env/global.env"
approve cromford
eq "P7 JOBS_URL empty: the default lets cromford file ($(cat "$T/out"); $(cat "$ALERTS" 2>/dev/null))" "$(creates example-org/cromford)" 1
reset; printf 'JOBS_URL=\n' > "$H/env/global.env"
approve project-5
eq "P7 JOBS_URL empty: project-5 still files nothing" "$(ghn)" 0

[ ! -s "$T/net.log" ] && ok || bad "something reached the network: $(cat "$T/net.log")"
echo "post-proposal-allowlist: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
