#!/bin/bash
# tests/reconcile-prs-d1-memory.bh-1595-test.sh — reconcile-prs keeps what it
# has learned about PRs in D1 (reconcile_memory), not only in the owner box's
# files, so a NEW owner box starts warm (BH-1610, BH-1595.3).
#
# Driven, not grepped: the REAL lane runs whole (bin/reconcile-prs.sh, the real
# lane gate, the real jobs client) against a curl stub whose $FX/memory.json IS
# the reconcile_memory table — GET answers {rows,truncated,as_of} from it, PUT
# applies upserts (monotonic for open) and deletes to it — and a gh stub that
# COUNTS every GitHub call. What is proved:
#   1. a tick sends ONE PUT carrying the open watermarks and the settled
#      answers it learned, never a `failed` row and never a `del gone` for a
#      healthy repo (9);
#   2. a fresh box (state wiped, D1 kept) makes 0 single-PR reads, one list per
#      repo, and posts the same classification;
#   3. D1 down: same classification from GitHub, one log line per direction,
#      and the unsent changes are kept in journal.pending ...
#   7. ... and replayed on the next tick that reaches D1;
#   4. files with no D1 row are uploaded (the one-time migration) — but not when
#      the GET was truncated (4b);
#   5. a remembered CLOSED the page no longer agrees with is DELETED in D1;
#   6. a 404 repo's backoff survives a wiped box;
#   8. poisoned D1 rows (bad kind, path-like names) never become files;
#  10. more than 500 changes go out as more than one PUT;
#  11. the last change per key wins inside one tick (up then del sends the del).
# Run from anywhere: tests/reconcile-prs-d1-memory.bh-1595-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

ago() { python3 -c 'import sys,time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-int(sys.argv[1]))))' "$1"; }

H="$T/h"; FX="$T/fx"; export FX
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/mc" "$H/logs" "$H/locks" "$H/env" "$H/builds" "$H/state" "$H/flags" \
         "$T/fakebin" "$FX/pages" "$FX/prs"
cp "$DIR/bin/reconcile-prs.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
for f in merge-conductor-lib.sh gh-pr-list.sh gh-rest.sh gh-rest-var.sh gh-rest-etag.sh \
         lane-gate.sh hub-box.sh reconcile-read.sh reconcile-owner-beat.sh; do
  [ -r "$DIR/bin/lib/$f" ] && cp "$DIR/bin/lib/$f" "$H/bin/lib/"
done
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "could not render the lane registry"; exit 1; }
export LANE_REGISTRY="$T/lanes.json" LANE_GATE_CACHE_S=0 HUB_BOX_NAME=hub-x
cat > "$H/fleet.conf" <<'EOF'
alpha-os Example/alpha https://alpha.example /api/board 2 box-a
beta-os  Example/beta  https://beta.example  /api/board 2 box-a
gamma-os Example/gamma https://gamma.example /api/board 2 box-a
delta-os Example/delta https://delta.example /api/board 2 box-a
gone-os  Example/gone  https://gone.example  /api/board 2 box-a
EOF
printf 'CONSOLE_URL=https://console.example\nHARNESS_SECRET=shh\nJOBS_URL=https://jobs.example\n' > "$H/env/global.env"

printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/deploy-request.sh"; chmod +x "$H/bin/deploy-request.sh"

# The console and the jobs worker. $FX/memory.json is the reconcile_memory
# table ([{kind,name,value}]); $FX/memory.fail makes both memory routes answer
# 500, $FX/memory.truncated makes the GET say truncated:true. Every PUT body is
# appended to $FX/puts.jsonl.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; BODY=""; WANT=0; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary|--data|-d) BODY="$2"; shift 2 ;;
    -X) METHOD="$2"; shift 2 ;;
    -w) WANT=1; shift 2 ;;
    *) shift ;;
  esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
emit() { printf '%s' "$1"; [ "$WANT" = 1 ] && printf '\n%s' "${2:-200}"; printf '\n'; }
echo "$METHOD $URL" >> "$FX/curl.log"
M="$FX/memory.json"; [ -s "$M" ] || echo '[]' > "$M"
case "$URL" in
  *"/api/builds/unmerged") emit "$(cat "$FX/unmerged.json")" ;;
  *"/api/builds/reconcile") printf '%s\n' "$BODY" >> "$FX/reconciled.txt"; emit '{"ok":true}' ;;
  *"/api/settings") emit '{"settings":[]}' ;;
  *"/api/reconcile-prs/memory")
    if [ -e "$FX/memory.fail" ]; then emit '{"error":"reconcile_memory unavailable"}' 500; exit 0; fi
    if [ "$METHOD" = PUT ]; then
      printf '%s\n' "$BODY" >> "$FX/puts.jsonl"
      jq -c --argjson b "$BODY" '
        reduce ($b.deletes // [])[] as $d (.; map(select(.kind != $d.kind or .name != $d.name)))
        | reduce ($b.upserts // [])[] as $u (.;
            (map(select(.kind == $u.kind and .name == $u.name)) | first) as $old
            | if $old == null then . + [{kind:$u.kind,name:$u.name,value:$u.value}]
              elif $u.kind == "open" and ($u.value <= $old.value) then .
              else map(if .kind == $u.kind and .name == $u.name then .value = $u.value else . end) end)' \
        "$M" > "$M.new" && mv "$M.new" "$M"
      emit '{"ok":true}'
    else
      emit "$(jq -c --argjson tr "$([ -e "$FX/memory.truncated" ] && echo true || echo false)" \
        '{rows:., truncated:$tr, as_of:"2026-09-23T13:00:00Z"}' "$M")"
    fi ;;
  *) emit '{}' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/curl"

cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
P=""
for a in "$@"; do case "$a" in repos/*) P="$a" ;; esac; done
echo "$P" >> "$FX/gh.log"
KEY=$(sed -E 's|^repos/([^/]+)/([^/]+)/.*$|\1_\2|' <<<"$P")
case "$P" in
  repos/*/*/pulls)   F="$FX/pages/$KEY.json" ;;
  repos/*/*/pulls/*) F="$FX/prs/$KEY-${P##*/}.json" ;;
  *) exit 1 ;;
esac
if [ -e "$F.fail" ]; then printf 'HTTP/2.0 500 Internal Server Error\r\n\r\n{"message":"Server Error"}'
elif [ -r "$F" ]; then printf 'HTTP/2.0 200 OK\r\n\r\n%s' "$(cat "$F")"
else printf 'HTTP/2.0 404 Not Found\r\n\r\n{"message":"Not Found"}'; fi
exit 0
SH
chmod +x "$T/fakebin/gh"

pr() {
  jq -nc --argjson n "$1" --arg s "$2" --arg m "$3" --arg c "$4" --arg u "$5" --arg sha "${6:-}" \
    '{number:$n, state:$s, merged_at:(if $m=="null" then null else $m end),
      closed_at:(if $c=="null" then null else $c end), updated_at:$u,
      merge_commit_sha:(if $sha=="" then null else $sha end)}'
}
unmerged() {
  local p="$1" s="$2" n; shift 2
  for n in "$@"; do
    jq -nc --arg b "$p-TK-$n-202609230001" --arg u "https://github.com/$s/pull/$n" '{bkey:$b,pr_url:$u}'
  done
}
set_unmerged() { jq -sc '{builds:.}' > "$FX/unmerged.json"; }
fresh_box() {
  [ -e "$H/state/reconcile-prs" ] && scratch_rm "$H/state/reconcile-prs"
  [ -e "$H/state/reconcile-closed" ] && scratch_rm "$H/state/reconcile-closed"
  : > "$H/logs/reconcile.log"
}
tick() {
  : > "$FX/gh.log"; : > "$FX/curl.log"; : > "$FX/reconciled.txt"; : > "$FX/puts.jsonl"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" BOX_NAME=hub-x \
      JOBS_RETRIES=0 bash "$H/bin/reconcile-prs.sh" >/dev/null 2>"$T/tick.err" ) || true
}
gh_lists()  { grep -cE "^repos/${1:-[^/]+/[^/]+}/pulls$" "$FX/gh.log" 2>/dev/null || true; }
gh_single() { grep -cE "^repos/${1:-[^/]+/[^/]+}/pulls/[0-9]+$" "$FX/gh.log" 2>/dev/null || true; }
puts()      { grep -c '^PUT .*/api/reconcile-prs/memory$' "$FX/curl.log" 2>/dev/null || true; }
posted()    { jq -cS '{merged:(.merged|sort), closed:(.closed|sort)}' < <(tail -1 "$FX/reconciled.txt") 2>/dev/null; }
# put_has <jq-filter> — true when any PUT body this tick satisfies the filter.
put_has()   { jq -se "[.[] | $1] | any" "$FX/puts.jsonl" >/dev/null 2>&1; }
mem_has()   { jq -e --arg k "$1" --arg n "$2" 'any(.[]; .kind == $k and .name == $n)' "$FX/memory.json" >/dev/null 2>&1; }
S="$H/state/reconcile-prs"

# 46 tracked PRs in 4 repos.
#  alpha 1-20: short page; #3 merged, #5 closed-unmerged (settled), the rest open.
#  beta 101-112: empty closed set, all open.
#  gamma 201-205: a FULL page of other closures; #201 merged months ago and
#    202-205 open, all off the page — five single reads (the default cap) once.
#  delta 301-309: short page; #301 merged, the rest open.
{ unmerged alpha-os Example/alpha $(seq 1 20); unmerged beta-os Example/beta $(seq 101 112)
  unmerged gamma-os Example/gamma $(seq 201 205); unmerged delta-os Example/delta $(seq 301 309); } | set_unmerged
cp "$FX/unmerged.json" "$FX/unmerged-46.json"
{ pr 3 closed "$(ago 900)" "$(ago 900)" "$(ago 900)" alphasha
  pr 5 closed null "$(ago 800)" "$(ago 800)"; } | jq -sc 'sort_by(.updated_at)|reverse' > "$FX/pages/Example_alpha.json"
cp "$FX/pages/Example_alpha.json" "$FX/alpha-orig.json"
echo '[]' > "$FX/pages/Example_beta.json"
for n in $(seq 0 29); do pr $((1000 + n)) closed null "$(ago $((100 + n * 100)))" "$(ago $((100 + n * 100)))"; done \
  | jq -sc '.' > "$FX/pages/Example_gamma.json"
pr 201 closed "$(ago 7776000)" "$(ago 7776000)" "$(ago 7776000)" gammasha > "$FX/prs/Example_gamma-201.json"
for n in 202 203 204 205; do pr "$n" open null null "$(ago 432000)" > "$FX/prs/Example_gamma-$n.json"; done
pr 301 closed "$(ago 600)" "$(ago 600)" "$(ago 600)" deltasha | jq -sc '.' > "$FX/pages/Example_delta.json"

# ════════════════════════════════════════════════════════════════════════════
# 1 + 9. A TICK SENDS ONE PUT WITH WHAT IT LEARNED
# ════════════════════════════════════════════════════════════════════════════
echo '[]' > "$FX/memory.json"; fresh_box; tick
[ "$(puts)" = 1 ] && ok || bad "1a exactly one PUT /api/reconcile-prs/memory per tick, got $(puts): $(cat "$FX/curl.log")"
# beta's closed set is EMPTY, so its PRs are proved open with no GitHub time to
# mark (the lane has never watermarked them) — nothing to remember for them.
WANT_OPEN=$( { for n in $(seq 1 20); do case $n in 3|5) ;; *) echo "Example_alpha_$n" ;; esac; done
               for n in 202 203 204 205; do echo "Example_gamma_$n"; done
               for n in $(seq 302 309); do echo "Example_delta_$n"; done; } | sort)
GOT_OPEN=$(jq -r '.upserts[]? | select(.kind == "open") | .name' "$FX/puts.jsonl" 2>/dev/null | sort)
[ -n "$GOT_OPEN" ] && [ "$GOT_OPEN" = "$WANT_OPEN" ] \
  && ok || bad "1b the PUT carries an open watermark for each of the 30 watermarked open PRs: got $(wc -w <<<"$GOT_OPEN") ($(tr '\n' ' ' <<<"$GOT_OPEN" | head -c 300))"
GOT_TERM=$(jq -r '.upserts[]? | select(.kind == "terminal") | .name' "$FX/puts.jsonl" 2>/dev/null | sort | tr '\n' ' ')
[ "$GOT_TERM" = "Example_alpha_3 Example_alpha_5 Example_delta_301 Example_gamma_201 " ] \
  && ok || bad "1c ...and a terminal row for each settled PR (merged 3/201/301, closed 5), got '$GOT_TERM'"
put_has '(.upserts // [])[] | select(.kind == "terminal" and .name == "Example_gamma_201") | (.value | fromjson | .STATE == "MERGED" and .merge_commit_sha == "gammasha")' \
  && ok || bad "1d the terminal value is the settled answer itself (state + merge sha): $(cat "$FX/puts.jsonl" | head -c 400)"
put_has '((.upserts // []) + (.deletes // []))[] | select(.kind != "open" and .kind != "terminal" and .kind != "gone")' \
  && bad "1e no PUT entry has a kind outside terminal/open/gone (failed/ stays file-only)" || ok
put_has '(.deletes // [])[] | select(.kind == "gone")' \
  && bad "9 a healthy repo's page must not send a del gone every tick: $(cat "$FX/puts.jsonl")" || ok
CASE1=$(posted)
[ -n "$CASE1" ] && [ "$(jq -c '.merged' <<<"$CASE1")" = '["alpha-os-TK-3-202609230001","delta-os-TK-301-202609230001","gamma-os-TK-201-202609230001"]' ] \
  && ok || bad "1f setup: tick 1 classifies 3/201/301 merged: $CASE1"
[ "$(jq 'length' "$FX/memory.json")" = 34 ] && ok || bad "1g the table holds what was sent (30 watermarks + 4 settled answers): $(jq length "$FX/memory.json") rows"
tick
[ "$(puts)" -le 1 ] && ok || bad "1h a steady tick still sends at most one PUT, got $(puts)"
put_has '(.upserts // [])[] | select(.kind == "terminal")' \
  && bad "1i an unchanged settled answer is not re-sent every tick: $(head -c 300 "$FX/puts.jsonl")" || ok

# ════════════════════════════════════════════════════════════════════════════
# 2. A FRESH BOX STARTS FROM D1
# ════════════════════════════════════════════════════════════════════════════
fresh_box; tick
[ "$(gh_single)" = 0 ] && ok || bad "2a a fresh box with D1 behind it makes 0 single-PR reads, made $(gh_single): $(grep '/pulls/' "$FX/gh.log" | tr '\n' ' ')"
[ "$(gh_lists)" = 4 ] && ok || bad "2b ...and one list per repo (4), made $(gh_lists)"
[ "$(posted)" = "$CASE1" ] && ok || bad "2c ...and posts the same classification: $(posted) vs $CASE1"
[ -s "$S/terminal/Example_gamma_201" ] && [ -s "$S/open/Example_gamma_202" ] \
  && ok || bad "2d the files were written from the D1 rows"

# ════════════════════════════════════════════════════════════════════════════
# 3 + 7. D1 DOWN — GitHub still decides; the changes wait in journal.pending
# ════════════════════════════════════════════════════════════════════════════
touch "$FX/memory.fail"; fresh_box; tick
[ "$(posted)" = "$CASE1" ] && ok || bad "3a with D1 down the classification is unchanged: $(posted) vs $CASE1"
[ "$(grep -c 'memory GET failed' "$H/logs/reconcile.log")" = 1 ] \
  && ok || bad "3b one log line says the GET failed: $(cat "$H/logs/reconcile.log")"
[ "$(grep -c 'memory flush failed' "$H/logs/reconcile.log")" = 1 ] \
  && ok || bad "3c one log line says the flush failed: $(cat "$H/logs/reconcile.log")"
[ -s "$S/journal.pending" ] && ok || bad "3d the unsent changes are kept in journal.pending"
[ -s "$S/terminal/Example_gamma_201" ] && ok || bad "3e the box's own files are kept"

rm -f "$FX/memory.fail"; echo '[]' > "$FX/memory.json"; touch "$FX/memory.truncated"
tick
put_has '(.upserts // [])[] | select(.kind == "terminal" and .name == "Example_gamma_201")' \
  && ok || bad "7a the next tick that reaches D1 replays the pending changes (truncated GET, so not the migration): $(head -c 400 "$FX/puts.jsonl")"
[ -e "$S/journal.pending" ] && bad "7b journal.pending is removed once the PUT lands" || ok
rm -f "$FX/memory.truncated"

# ════════════════════════════════════════════════════════════════════════════
# 4. FILES WITH NO D1 ROW ARE UPLOADED — unless the GET was truncated (4b)
# ════════════════════════════════════════════════════════════════════════════
echo 1790000000 > "$S/gone/Example_retired"
echo '[]' > "$FX/memory.json"; touch "$FX/memory.truncated"; tick
put_has '(.upserts // [])[] | select(.kind == "gone" and .name == "Example_retired")' \
  && bad "4b a truncated GET must not trigger the migration upload: $(head -c 400 "$FX/puts.jsonl")" || ok
rm -f "$FX/memory.truncated"; echo '[]' > "$FX/memory.json"; tick
MISSING=""
for d in open terminal gone; do
  for f in "$S/$d"/*; do
    [ -e "$f" ] || continue
    n=$(basename "$f")
    # A gone file ends in a newline (echo); the value sent is the stamp without it.
    put_has "(.upserts // [])[] | select(.kind == \"$d\" and .name == \"$n\" and .value == $(jq -Rs 'rtrimstr("\n")' < "$f"))" || MISSING="$MISSING $d/$n"
  done
done
[ -z "$MISSING" ] && [ -e "$S/gone/Example_retired" ] && ok || bad "4a every local file with no D1 row is uploaded with its content; missing:$MISSING"
scratch_rm "$S/gone/Example_retired"

# ════════════════════════════════════════════════════════════════════════════
# 5. A REMEMBERED CLOSED THE PAGE NO LONGER AGREES WITH IS DELETED IN D1
# ════════════════════════════════════════════════════════════════════════════
mem_has terminal Example_alpha_5 && ok || bad "5a setup: #5's CLOSED answer is in D1"
jq -c '[.[] | select(.number != 5)]' "$FX/alpha-orig.json" > "$FX/pages/Example_alpha.json"
pr 5 open null null "$(ago 20)" > "$FX/prs/Example_alpha-5.json"
tick
put_has '(.deletes // [])[] | select(.kind == "terminal" and .name == "Example_alpha_5")' \
  && ok || bad "5b the PUT deletes the terminal row of a reopened PR: $(head -c 400 "$FX/puts.jsonl")"
mem_has terminal Example_alpha_5 && bad "5c ...and D1 no longer has it" || ok
cp "$FX/alpha-orig.json" "$FX/pages/Example_alpha.json"; rm -f "$FX/prs/Example_alpha-5.json"

# ════════════════════════════════════════════════════════════════════════════
# 6. A 404 REPO'S BACKOFF SURVIVES A WIPED BOX
# ════════════════════════════════════════════════════════════════════════════
unmerged gone-os Example/gone 41 42 | set_unmerged
fresh_box; tick
[ "$(gh_lists Example/gone)" = 1 ] && ok || bad "6a setup: the gone repo is listed once"
mem_has gone Example_gone && ok || bad "6b the 404 is written to D1 as a gone row: $(jq -c . "$FX/memory.json" | head -c 300)"
fresh_box; tick
[ "$(gh_lists Example/gone)" = 0 ] && [ "$(gh_single)" = 0 ] \
  && ok || bad "6c a wiped box inherits the backoff: $(tr '\n' ' ' < "$FX/gh.log")"

# ════════════════════════════════════════════════════════════════════════════
# 8. POISONED D1 ROWS NEVER BECOME FILES
# ════════════════════════════════════════════════════════════════════════════
cp "$FX/unmerged-46.json" "$FX/unmerged.json"
jq -c '. + [{kind:"terminal",name:"..",value:"x"},{kind:"failed",name:"Example_alpha_9",value:"1"},
            {kind:"open",name:"../../escaped",value:"2099-01-01T00:00:00Z"},{kind:"gone",name:"a/b",value:"1"},
            {kind:"gone",name:("x" * 129),value:"1"}]' "$FX/memory.json" > "$FX/m.new" && mv "$FX/m.new" "$FX/memory.json"
fresh_box; tick
[ -e "$H/state/escaped" ] || [ -e "$S/escaped" ] || [ -e "$S/failed/Example_alpha_9" ] || [ -e "$S/gone/a" ] \
  || [ -e "$S/gone/$(printf 'x%.0s' $(seq 1 129))" ] \
  && bad "8a a poisoned row became a file: $(find "$H/state" -maxdepth 3 | tr '\n' ' ' | head -c 400)" || ok
[ "$(posted)" = "$CASE1" ] && ok || bad "8b ...and the tick classifies normally: $(posted)"

# ════════════════════════════════════════════════════════════════════════════
# 10. MORE THAN 500 CHANGES GO OUT AS MORE THAN ONE PUT (+ failed/ file-only)
# ════════════════════════════════════════════════════════════════════════════
: > "$FX/prs/Example_gamma-203.json.fail"
fresh_box; mkdir -p "$S/gone"; echo '[]' > "$FX/memory.json"
for i in $(seq 1 501); do echo 1790000000 > "$S/gone/Example_old$i"; done
tick
[ "$(puts)" = 2 ] && ok || bad "10a 501+ changes are sent as 2 PUTs, got $(puts)"
[ "$(jq -s '[.[] | ((.upserts // []) + (.deletes // [])) | length] | max' "$FX/puts.jsonl")" -le 500 ] \
  && ok || bad "10b no PUT carries more than 500 entries"
[ "$(jq '[.[] | select(.kind == "gone" and (.name | startswith("Example_old")))] | length' "$FX/memory.json")" = 501 ] \
  && ok || bad "10c all 501 reached D1: $(jq '[.[] | select(.kind == "gone")] | length' "$FX/memory.json")"
[ -e "$S/failed/Example_gamma_203" ] && ok || bad "1j setup: a failed single read is stamped in failed/"
put_has '((.upserts // []) + (.deletes // []))[] | select(.name == "Example_gamma_203" and .kind != "open")' \
  && bad "1k a failed read's stamp is never sent to D1 (failed/ stays file-only)" || ok
rm -f "$FX/prs/Example_gamma-203.json.fail"

# ════════════════════════════════════════════════════════════════════════════
# 11. THE LAST CHANGE PER KEY WINS — a file the migration uploads and prune then
#     removes in the same tick must not end up in D1
# ════════════════════════════════════════════════════════════════════════════
echo '[]' > "$FX/memory.json"; fresh_box; mkdir -p "$S/open"
printf '%s' "$(ago 60)" > "$S/open/Example_alpha_999"
tick
[ -e "$S/open/Example_alpha_999" ] && bad "11a setup: prune removes the watermark of a PR the console no longer lists" || ok
mem_has open Example_alpha_999 && bad "11b ...and D1 must not keep it (an up then a del sends the del): $(head -c 300 "$FX/puts.jsonl")" || ok
put_has '(.upserts // [])[] | select(.name == "Example_alpha_999")' \
  && bad "11c the reduced journal sends only the del for that key" || ok

echo "reconcile-prs-d1-memory: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
