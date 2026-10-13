#!/bin/bash
# tests/reconcile-prs-merge-fact.bh-3971-test.sh — reconcile reports a PR as
# merged only on GitHub's merge FACT (`merged_at`), never on the word MERGED.
#
# THE DEFECT THIS PINS (BH-3971). BH-866 made the lane classify off `merged_at`,
# but two places still trusted the word: `_rcr_cached` returned any remembered
# terminal whose STATE was MERGED without looking at its `merged_at`, and
# `_rcr_norm` passed a handed-in `.STATE` straight through. Either way a PR
# GitHub says was closed without merging could reach `{"merged":[…]}`, and the
# console stamps that row `merged=1, stage=pr_merged` for good (project-3 TK-166,
# PR #331, closed unmerged and shown as merged).
#
# Driven, not grepped: the real bin/reconcile-prs.sh runs whole against a gh
# stub that answers from fixture files and a console stub that records the
# reconcile POST. Assertions are on that POST, the beats, the terminal memo and
# the log.
# Run from anywhere: tests/reconcile-prs-merge-fact.bh-3971-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=$(date +%s)
# An ISO-8601 stamp <n> seconds before NOW. Every closure here is far outside
# the settle window, so nothing in this suite depends on when it runs.
ago() { python3 -c 'import sys,time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1])-int(sys.argv[2]))))' "$NOW" "$1"; }

H="$T/h"; FX="$T/fx"; export FX
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/mc" "$H/logs" "$H/locks" "$H/env" "$H/builds" "$H/state" \
         "$T/fakebin" "$FX/pages" "$FX/prs"
cp "$DIR/bin/reconcile-prs.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-etag.sh" "$H/bin/lib/"
. "$(dirname "$0")/lib/reconcile-fixture.sh" || exit 1
rcfx_arm "$H" "$DIR" || exit 1
printf 'demo-os Example/demo https://demo.example /api/board 2 box-a\n' > "$H/fleet.conf"
printf 'CONSOLE_URL=https://console.example\nHARNESS_SECRET=shh\nJOBS_URL=https://jobs.example\n' > "$H/env/global.env"

printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$FX/beats.txt"\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/deploy-request.sh"; chmod +x "$H/bin/deploy-request.sh"

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; BODY=""; WANT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary|--data|-d) BODY="$2"; shift 2 ;;
    -w) WANT=1; shift 2 ;;
    *) shift ;;
  esac
done
emit() { printf '%s' "$1"; [ "$WANT" = 1 ] && printf '\n200'; printf '\n'; }
case "$URL" in
  *"/api/builds/unmerged") emit "$(cat "$FX/unmerged.json")" ;;
  *"/api/builds/reconcile") printf '%s\n' "$BODY" >> "$FX/reconciled.txt"; emit '{"ok":true}' ;;
  *) emit '{}' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/curl"

# GitHub: a list page is $FX/pages/Example_demo.json, a single PR is
# $FX/prs/<n>.json; a missing file answers 404, a `.fail` page answers 500.
# Every call is logged to $FX/gh.log.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
P=""
for a in "$@"; do case "$a" in repos/*) P="$a" ;; esac; done
echo "$P" >> "$FX/gh.log"
case "$P" in
  repos/Example/demo/pulls)   F="$FX/pages/Example_demo.json" ;;
  repos/Example/demo/pulls/*) F="$FX/prs/${P##*/}.json" ;;
  *) exit 1 ;;
esac
if [ -e "$F.fail" ]; then printf 'HTTP/2.0 500 Internal Server Error\r\n\r\n{"message":"Server Error"}'
elif [ -r "$F" ]; then printf 'HTTP/2.0 200 OK\r\n\r\n%s' "$(cat "$F")"
else printf 'HTTP/2.0 404 Not Found\r\n\r\n{"message":"Not Found"}'; fi
exit 0
SH
chmod +x "$T/fakebin/gh"

# pr <num> <state> <merged-at|null> <closed-at|null> <updated-at> [sha]
pr() {
  jq -nc --argjson n "$1" --arg s "$2" --arg m "$3" --arg c "$4" --arg u "$5" --arg sha "${6:-}" \
    '{number:$n, state:$s, merged_at:(if $m=="null" then null else $m end),
      closed_at:(if $c=="null" then null else $c end), updated_at:$u,
      merge_commit_sha:(if $sha=="" then null else $sha end)}'
}
bkey() { printf 'demo-os-TK-%s-202610030001' "$1"; }
track() { # track <num>... — the console's unmerged list
  local n
  for n in "$@"; do
    jq -nc --arg b "$(bkey "$n")" --arg u "https://github.com/Example/demo/pull/$n" '{bkey:$b,pr_url:$u}'
  done | jq -sc '{builds:.}' > "$FX/unmerged.json"
}
fresh_box() {
  [ -e "$H/state" ] && scratch_rm "$H/state"
  mkdir -p "$H/state/reconcile-prs/terminal"
  [ -e "$FX/pages" ] && scratch_rm "$FX/pages"
  [ -e "$FX/prs" ] && scratch_rm "$FX/prs"
  mkdir -p "$FX/pages" "$FX/prs"
  : > "$H/logs/reconcile.log"
}
tick() {
  : > "$FX/gh.log"; : > "$FX/reconciled.txt"; : > "$FX/beats.txt"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" JOBS_RETRIES=0 \
      bash "$H/bin/reconcile-prs.sh" >/dev/null 2>"$T/tick.err" ) || true
}
in_list() { jq -e --arg l "$1" --arg b "$(bkey "$2")" '(.[$l] // []) | index($b) != null' \
              < <(tail -1 "$FX/reconciled.txt") >/dev/null 2>&1; }
posted() { tail -1 "$FX/reconciled.txt"; }
TERM_DIR="$H/state/reconcile-prs/terminal"

# ════════════════════════════════════════════════════════════════════════════
# R1. closed with merged_at null (on the page) -> `closed`, never `merged`
# R2. closed with merged_at set (on the page)  -> `merged`, ship beat (control)
# ════════════════════════════════════════════════════════════════════════════
fresh_box; track 1 2
{ pr 2 closed "$(ago 900)" "$(ago 900)" "$(ago 900)" feedfacecafe
  pr 1 closed null "$(ago 1000)" "$(ago 1000)"; } | jq -sc '.' > "$FX/pages/Example_demo.json"
tick
in_list closed 1 && ok || bad "R1 a PR closed with merged_at null must be reported under closed: $(posted)"
in_list merged 1 && bad "R1 a PR closed with merged_at null must NEVER be in merged: $(posted)" || ok
grep -q "shipped:$(bkey 1)" "$FX/beats.txt" && bad "R1 no ship beat for a closed-unmerged PR: $(cat "$FX/beats.txt")" || ok
in_list merged 2 && ok || bad "R2 a PR with merged_at set must still be reported merged: $(posted)"
grep -q "shipped:$(bkey 2)" "$FX/beats.txt" && ok || bad "R2 the real merge still rings its ship beat: $(cat "$FX/beats.txt")"

# ════════════════════════════════════════════════════════════════════════════
# R3 (THE DEFECT). A remembered terminal that says MERGED with merged_at null,
# for a PR that fell off a FULL closed page, while GitHub's own single read
# says closed-unmerged. The memo must not be trusted: no `merged`, the log says
# why, the MERGED memo is gone, and the PR is re-derived from GitHub (closed).
# ════════════════════════════════════════════════════════════════════════════
fresh_box; track 3
export RECONCILE_PRS_PAGE=2
{ pr 51 closed null "$(ago 100)" "$(ago 100)"
  pr 50 closed null "$(ago 200)" "$(ago 200)"; } | jq -sc '.' > "$FX/pages/Example_demo.json"
pr 3 closed null "$(ago 5000)" "$(ago 5000)" > "$FX/prs/3.json"
printf '{"STATE":"MERGED","closed_at":"%s","merged_at":null,"merge_commit_sha":null,"updated_at":"%s"}' \
  "$(ago 5000)" "$(ago 5000)" > "$TERM_DIR/Example_demo_3"
tick
in_list merged 3 && bad "R3 a remembered MERGED with merged_at null must NOT reach the merged list (TK-166): $(posted)" || ok
grep -q "shipped:$(bkey 3)" "$FX/beats.txt" && bad "R3 no ship beat from a memo with no merge fact: $(cat "$FX/beats.txt")" || ok
grep -q 'no merged_at' "$H/logs/reconcile.log" \
  && ok || bad "R3 the log must say the memo had no merged_at: $(cat "$H/logs/reconcile.log")"
grep -q '"MERGED"' "$TERM_DIR/Example_demo_3" 2>/dev/null \
  && bad "R3 the MERGED memo must be dropped: $(cat "$TERM_DIR/Example_demo_3")" || ok
in_list closed 3 && ok || bad "R3 re-derived from GitHub, the PR lands in closed: $(posted)"
# The next pass reads it from the (now CLOSED) memo and still never says merged.
tick
in_list merged 3 && bad "R3 the next pass must not say merged either: $(posted)" || ok
unset RECONCILE_PRS_PAGE; rcfx_arm "$H" "$DIR"

# ════════════════════════════════════════════════════════════════════════════
# R4. The word without the fact from GitHub itself: a page item carrying
# STATE "MERGED" with merged_at null, and a single read answering
# {"STATE":"MERGED"} with no merged_at at all. Neither is a merge.
# ════════════════════════════════════════════════════════════════════════════
fresh_box; track 4
jq -nc --arg c "$(ago 900)" '[{number:4, STATE:"MERGED", state:"closed", merged_at:null, closed_at:$c, updated_at:$c}]' \
  > "$FX/pages/Example_demo.json"
tick
in_list merged 4 && bad "R4a a page item that says STATE MERGED with merged_at null is not a merge: $(posted)" || ok
in_list closed 4 && ok || bad "R4a it is derived from .state instead (closed): $(posted)"

fresh_box; track 4
touch "$FX/pages/Example_demo.json.fail"
printf '{"STATE":"MERGED"}' > "$FX/prs/4.json"
tick
grep -q '^repos/Example/demo/pulls/4$' "$FX/gh.log" && ok || bad "R4b the single read must have been made: $(cat "$FX/gh.log")"
in_list merged 4 && bad "R4b a single read with no merged_at is not a merge: $(posted)" || ok
grep -q "shipped:$(bkey 4)" "$FX/beats.txt" && bad "R4b no ship beat: $(cat "$FX/beats.txt")" || ok

# ════════════════════════════════════════════════════════════════════════════
# R5. The memo still works for a REAL merge: a remembered MERGED that carries
# merged_at is used with no GitHub single read.
# ════════════════════════════════════════════════════════════════════════════
fresh_box; track 5
export RECONCILE_PRS_PAGE=2
{ pr 51 closed null "$(ago 100)" "$(ago 100)"
  pr 50 closed null "$(ago 200)" "$(ago 200)"; } | jq -sc '.' > "$FX/pages/Example_demo.json"
printf '{"STATE":"MERGED","closed_at":"%s","merged_at":"%s","merge_commit_sha":"abc123","updated_at":"%s"}' \
  "$(ago 5000)" "$(ago 5000)" "$(ago 5000)" > "$TERM_DIR/Example_demo_5"
tick
in_list merged 5 && ok || bad "R5 a remembered MERGED with merged_at is still a merge: $(posted)"
grep -q '^repos/Example/demo/pulls/5$' "$FX/gh.log" \
  && bad "R5 a proven merge memo must cost no single read: $(cat "$FX/gh.log")" || ok
[ -s "$TERM_DIR/Example_demo_5" ] && ok || bad "R5 the proven memo is kept"
unset RECONCILE_PRS_PAGE

echo "reconcile-prs-merge-fact (BH-3971): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
