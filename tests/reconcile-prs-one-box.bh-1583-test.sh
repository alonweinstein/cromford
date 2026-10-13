#!/bin/bash
# tests/reconcile-prs-one-box.bh-1583-test.sh — reconcile-prs runs on ONE box and
# reads closed PRs per REPO, not per PR (BH-1583).
#
# THE COST THIS PINS (gh-reads audit, 2026-09-23). cron/lanes/040-reconcile-prs
# ran on the hub and all 8 boxes; every copy read the same fleet-wide
# /api/builds/unmerged list (~46 PRs) and made one GET pulls/<n> per PR, plus a
# second for each merged PR's merge sha: ~2,200 calls/h of a 6,600/h bucket.
#
# Driven, not grepped: the REAL lane runs whole, with the REAL lane gate and the
# REAL registry (bin/lanes-build.sh) resolving its knobs from a stub worker's
# settings rows, against a gh stub that COUNTS every call — the "stubbed gh_rest
# counter" the ticket asks for. What is proved:
#   1. a non-owner box makes ZERO GitHub calls (and no console read), and says
#      so once, not once per tick; the owner is a DB row (registry default hub);
#   2. the owner makes ONE list call per repo per tick with 46 tracked PRs, no
#      single-PR reads, and still classifies merged/closed/open exactly — the
#      merge sha for the deploy gate comes off the page, not a second read;
#   3. PRs closed long ago (off a FULL page) cost at most the cap of single
#      reads per tick, and once a PR is proved open it costs nothing again;
#   4. a 404 repo is hit once per backoff window, and none of its PRs is read;
#   5. no usable knob value -> the tick does not run and makes no call.
# Run from anywhere: tests/reconcile-prs-one-box.bh-1583-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# An ISO-8601 stamp <n> seconds in the past, without GNU date.
ago() { python3 -c 'import sys,time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-int(sys.argv[1]))))' "$1"; }

H="$T/h"; FX="$T/fx"; export FX
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/mc" "$H/logs" "$H/locks" "$H/env" "$H/builds" "$H/state" "$H/flags" \
         "$T/fakebin" "$FX/pages" "$FX/prs"
cp "$DIR/bin/reconcile-prs.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
for f in merge-conductor-lib.sh gh-pr-list.sh gh-rest.sh gh-rest-var.sh gh-rest-etag.sh \
         lane-gate.sh hub-box.sh reconcile-read.sh; do
  [ -r "$DIR/bin/lib/$f" ] && cp "$DIR/bin/lib/$f" "$H/bin/lib/"
done
# The registry the gate reads the knobs' defaults from — the one this branch
# ships, rendered exactly as a box renders it.
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "could not render the lane registry"; exit 1; }
export LANE_REGISTRY="$T/lanes.json" LANE_GATE_CACHE_S=0 HUB_BOX_NAME=hub-x
cat > "$H/fleet.conf" <<'EOF'
alpha-os Example/alpha https://alpha.example /api/board 2 box-a
beta-os  Example/beta  https://beta.example  /api/board 2 box-a
gamma-os Example/gamma https://gamma.example /api/board 2 box-a
gone-os  Example/gone  https://gone.example  /api/board 2 box-a
EOF
printf 'CONSOLE_URL=https://console.example\nHARNESS_SECRET=shh\nJOBS_URL=https://jobs.example\n' > "$H/env/global.env"
printf 'DEPLOY_HOOK_URL=https://hook.example/alpha\n' > "$H/env/alpha-os.env"

printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\t%%s\\t%%s\\n" "$1" "$2" "$3" >> "$FX/deploys.txt"\nexit 0\n' > "$H/bin/deploy-request.sh"
chmod +x "$H/bin/deploy-request.sh"

# The console, the jobs worker and its settings rows. $FX/settings.json is the
# `settings` table; the lane gate reads it through bin/jobs-client.sh.
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
emit() { printf '%s' "$1"; [ "$WANT" = 1 ] && printf '\n200'; printf '\n'; }
echo "$METHOD $URL" >> "$FX/curl.log"
case "$URL" in
  *"/api/builds/unmerged") emit "$(cat "$FX/unmerged.json")" ;;
  *"/api/builds/reconcile") printf '%s\n' "$BODY" >> "$FX/reconciled.txt"; emit '{"ok":true}' ;;
  *"/api/settings") emit "$(cat "$FX/settings.json" 2>/dev/null || echo '{"settings":[]}')" ;;
  *) emit '{}' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/curl"

# GitHub. Every call is COUNTED in $FX/gh.log (its repos/... path, one line per
# call). A list page is $FX/pages/<owner>_<repo>.json, a single PR is
# $FX/prs/<owner>_<repo>-<n>.json; anything missing answers 404.
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

# pr <num> <state> <merged-at|null> <closed-at|null> <updated-at> [sha]
pr() {
  jq -nc --argjson n "$1" --arg s "$2" --arg m "$3" --arg c "$4" --arg u "$5" --arg sha "${6:-}" \
    '{number:$n, state:$s, merged_at:(if $m=="null" then null else $m end),
      closed_at:(if $c=="null" then null else $c end), updated_at:$u,
      merge_commit_sha:(if $sha=="" then null else $sha end)}'
}
# unmerged <project> <slug> <num>... — the console's list, one row per PR.
unmerged() {
  local p="$1" s="$2" n; shift 2
  for n in "$@"; do
    jq -nc --arg b "$p-TK-$n-202609230001" --arg u "https://github.com/$s/pull/$n" '{bkey:$b,pr_url:$u}'
  done
}
set_unmerged() { jq -sc '{builds:.}' > "$FX/unmerged.json"; }
set_rows() { # set_rows key=value... — the operator rows in the settings table
  local kv out="[]"
  for kv in "$@"; do
    out=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"console"}]' <<<"$out")
  done
  printf '{"settings":%s}\n' "$out" > "$FX/settings.json"
}
fresh_box() { # the lane's own state is what a new box starts without
  [ -e "$H/state/reconcile-prs" ] && scratch_rm "$H/state/reconcile-prs"
  [ -e "$H/state/reconcile-closed" ] && scratch_rm "$H/state/reconcile-closed"
  : > "$H/logs/reconcile.log"
}
tick() { # tick <box-name> — one */10 pass on that box
  : > "$FX/gh.log"; : > "$FX/curl.log"; : > "$FX/reconciled.txt"; : > "$FX/deploys.txt"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" BOX_NAME="$1" \
      JOBS_RETRIES=0 bash "$H/bin/reconcile-prs.sh" >/dev/null 2>"$T/tick.err" ) || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$FX/deploys.txt" ] && break; [ -s "$FX/reconciled.txt" ] || break; sleep 0.2; done
}
gh_calls()  { grep -c . "$FX/gh.log" 2>/dev/null || true; }
gh_lists()  { grep -cE "^repos/${1:-[^/]+/[^/]+}/pulls$" "$FX/gh.log" 2>/dev/null || true; }
gh_single() { grep -cE "^repos/${1:-[^/]+/[^/]+}/pulls/[0-9]+$" "$FX/gh.log" 2>/dev/null || true; }
console_reads() { grep -c '/api/builds/unmerged' "$FX/curl.log" 2>/dev/null || true; }
posted() { jq -r "$1" < <(tail -1 "$FX/reconciled.txt") 2>/dev/null; }

# The fleet-wide list the audit measured: 46 tracked PRs, 30 in alpha, 16 in beta.
{ unmerged alpha-os Example/alpha $(seq 1 30); unmerged beta-os Example/beta $(seq 101 116); } | set_unmerged
# alpha's recent-closed page: #3 merged, #5 closed and never merged, #900 an
# untracked closure. Three items < per_page, so it is the WHOLE closed set.
{ pr 3 closed "$(ago 900)" "$(ago 900)" "$(ago 900)" feedfacecafe
  pr 5 closed null "$(ago 800)" "$(ago 800)"
  pr 900 closed null "$(ago 700)" "$(ago 700)"; } | jq -sc 'sort_by(.updated_at)|reverse' > "$FX/pages/Example_alpha.json"
echo '[]' > "$FX/pages/Example_beta.json"
cp "$FX/pages/Example_alpha.json" "$FX/alpha-orig.json"
set_rows

# ════════════════════════════════════════════════════════════════════════════
# 1. ONE BOX — the owner is a DB row, default hub; everyone else reads nothing
# ════════════════════════════════════════════════════════════════════════════
fresh_box
tick box-a
[ "$(gh_calls)" = 0 ] && ok || bad "1a a non-owner box must make ZERO GitHub calls, made $(gh_calls): $(tr '\n' ' ' < "$FX/gh.log")"
[ "$(console_reads)" = 0 ] && ok || bad "1b a non-owner box must not even read the console list (it is the same fleet-wide list the owner reads)"
tick box-a
[ "$(gh_calls)" = 0 ] && ok || bad "1c ...on every tick, made $(gh_calls)"
[ "$(grep -c 'not the reconcile owner' "$H/logs/reconcile.log")" = 1 ] \
  && ok || bad "1d the skip is said ONCE, not once per tick: $(cat "$H/logs/reconcile.log")"
tick hub-x
[ "$(console_reads)" = 1 ] && ok || bad "1e with no settings row the HUB owns the lane (registry default) and reads the console"
set_rows lane.reconcile-prs.reconcile_prs_owner=box-a
fresh_box; tick box-a
[ "$(console_reads)" = 1 ] && ok || bad "1f a settings row naming box-a makes box-a the owner"
tick hub-x
[ "$(gh_calls)" = 0 ] && [ "$(console_reads)" = 0 ] \
  && ok || bad "1g ...and then the hub reads nothing ($(gh_calls) gh call(s), $(console_reads) console read(s))"
set_rows

# ════════════════════════════════════════════════════════════════════════════
# 2. ONE LIST PER REPO — 46 tracked PRs, two repos, two calls
# ════════════════════════════════════════════════════════════════════════════
fresh_box; tick hub-x
[ "$(gh_lists Example/alpha)" = 1 ] && [ "$(gh_lists Example/beta)" = 1 ] \
  && ok || bad "2a exactly ONE list call per repo, got alpha=$(gh_lists Example/alpha) beta=$(gh_lists Example/beta)"
[ "$(gh_single)" = 0 ] && ok || bad "2b no per-PR read when the page answers every tracked PR, made $(gh_single)"
[ "$(gh_calls)" = 2 ] && ok || bad "2c 46 tracked PRs in 2 repos = 2 GitHub calls, made $(gh_calls): $(sort "$FX/gh.log" | uniq -c | tr '\n' ' ')"
[ "$(posted '.merged | join(",")')" = "alpha-os-TK-3-202609230001" ] \
  && ok || bad "2d the merged PR on the page is reconciled as merged: $(cat "$FX/reconciled.txt")"
[ "$(posted '.closed | join(",")')" = "alpha-os-TK-5-202609230001" ] \
  && ok || bad "2e the closed-unmerged PR on the page is reconciled as closed: $(cat "$FX/reconciled.txt")"
grep -q $'alpha-os\tExample/alpha\tfeedfacecafe' "$FX/deploys.txt" \
  && ok || bad "2f the deploy gate gets the merge sha off the page (no second read): $(cat "$FX/deploys.txt")"
tick hub-x
[ "$(gh_calls)" -le 2 ] && [ "$(gh_single)" = 0 ] \
  && ok || bad "2g the next tick is no dearer: $(gh_calls) call(s), $(gh_single) single"

# ════════════════════════════════════════════════════════════════════════════
# 3. CLOSED LONG AGO — a FULL page proves nothing about an absent PR, so the
#    capped single read answers it; a PR proved open costs nothing again
# ════════════════════════════════════════════════════════════════════════════
unmerged gamma-os Example/gamma $(seq 1 8) | set_unmerged
for n in $(seq 0 29); do pr $((1000 + n)) closed null "$(ago $((100 + n * 100)))" "$(ago $((100 + n * 100)))"; done \
  | jq -sc '.' > "$FX/pages/Example_gamma.json"
pr 1 closed "$(ago 7776000)" "$(ago 7776000)" "$(ago 7776000)" oldmergesha > "$FX/prs/Example_gamma-1.json"
for n in $(seq 2 8); do pr "$n" open null null "$(ago 432000)" > "$FX/prs/Example_gamma-$n.json"; done
set_rows lane.reconcile-prs.reconcile_prs_fallback_cap=3
fresh_box
T1=""; for k in 1 2 3 4; do
  tick hub-x
  T1="$T1 $(gh_single)"
  [ "$(gh_single)" -le 3 ] && ok || bad "3a tick $k: at most the cap (3, a settings row) of single reads, made $(gh_single)"
  [ "$(gh_lists Example/gamma)" = 1 ] && ok || bad "3b tick $k: still one list call, made $(gh_lists Example/gamma)"
  [ "$k" = 1 ] && M1=$(posted '.merged // [] | join(",")')
done
[ "$T1" = " 3 3 2 0" ] && ok || bad "3c 8 unproved PRs under a cap of 3 drain as 3,3,2 and then cost nothing, got:$T1"
[ "$M1" = "gamma-os-TK-1-202609230001" ] \
  && ok || bad "3d a PR merged months ago, off the page, is still reconciled from its single read: '$M1'"
grep -q 'wait for the next tick' "$H/logs/reconcile.log" \
  && ok || bad "3e a capped tick says what it left: $(cat "$H/logs/reconcile.log")"
set_rows

# ════════════════════════════════════════════════════════════════════════════
# 4. A 404 REPO — hit once per backoff window, never PR by PR
# ════════════════════════════════════════════════════════════════════════════
unmerged gone-os Example/gone 41 42 43 | set_unmerged
fresh_box; tick hub-x
[ "$(gh_calls)" = 1 ] && [ "$(gh_lists Example/gone)" = 1 ] \
  && ok || bad "4a a gone repo costs ONE list call and no per-PR reads, made: $(tr '\n' ' ' < "$FX/gh.log")"
tick hub-x
[ "$(gh_calls)" = 0 ] && ok || bad "4b inside the backoff window the repo is not read at all, made $(gh_calls)"
[ "$(grep -c 'answered 404' "$H/logs/reconcile.log")" = 1 ] \
  && ok || bad "4c the 404 is recorded once, not per tick: $(cat "$H/logs/reconcile.log")"
GONE=$(ls "$H/state/reconcile-prs/gone/" 2>/dev/null | head -1)
[ -n "$GONE" ] && echo $(( $(date +%s) - 30000 )) > "$H/state/reconcile-prs/gone/$GONE"
tick hub-x
[ "$(gh_lists Example/gone)" = 1 ] && [ "$(gh_single)" = 0 ] \
  && ok || bad "4d past the window (registry default 21600s) the repo is tried again, once: $(tr '\n' ' ' < "$FX/gh.log")"

wait_for() { # wait_for <file> <needle> — the deploy gate lands detached
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.2; done; return 1
}
PB5=alpha-os-TK-5-202609230001
CACHED5="$H/state/reconcile-prs/terminal/Example_alpha_5"

# ════════════════════════════════════════════════════════════════════════════
# 6. REOPEN THEN MERGE (review of #1593, the reviewer's probe) — a CLOSED
#    answer the lane remembered must never outrank what GitHub says now
# ════════════════════════════════════════════════════════════════════════════
unmerged alpha-os Example/alpha 3 5 | set_unmerged
cp "$FX/alpha-orig.json" "$FX/pages/Example_alpha.json"
fresh_box; tick hub-x
[ -s "$CACHED5" ] && ok || bad "6a setup: #5 closed 800s ago is settled and remembered"
# #5 is reopened, then merged 30s ago: it is back at the top of the closed page.
{ pr 5 closed "$(ago 30)" "$(ago 30)" "$(ago 30)" reopenmergesha; cat "$FX/alpha-orig.json" | jq -c '.[] | select(.number != 5)'; } \
  | jq -sc 'sort_by(.updated_at)|reverse' > "$FX/pages/Example_alpha.json"
tick hub-x
posted '.merged // [] | join(",")' | grep -q "$PB5" \
  && ok || bad "6b a PR reopened and merged is MERGED, whatever was remembered: $(cat "$FX/reconciled.txt")"
grep -q "$PB5" <<<"$(posted '.closed // [] | join(",")')" \
  && bad "6c ...and never posted CLOSED again: $(cat "$FX/reconciled.txt")" || ok
wait_for "$FX/deploys.txt" reopenmergesha \
  && ok || bad "6d the merge sha of the reopen-merge reaches the deploy gate: $(cat "$FX/deploys.txt")"

# ════════════════════════════════════════════════════════════════════════════
# 7. REOPEN, STILL OPEN — and a still-closed PR that fell off keeps its cache
# ════════════════════════════════════════════════════════════════════════════
# 7a: absent from a SHORT page (the whole closed set) = not closed any more.
cp "$FX/alpha-orig.json" "$FX/pages/Example_alpha.json"
fresh_box; tick hub-x
jq -c '[.[] | select(.number != 5)]' "$FX/alpha-orig.json" > "$FX/pages/Example_alpha.json"
pr 5 open null null "$(ago 20)" > "$FX/prs/Example_alpha-5.json"
tick hub-x
grep -q "$PB5" <<<"$(posted '.closed // [] | join(",")')" \
  && bad "7a a reopened PR (absent from the whole closed set) must not be posted CLOSED: $(cat "$FX/reconciled.txt")" || ok
[ -e "$CACHED5" ] && bad "7b ...and the remembered CLOSED answer is dropped" || ok
# 7c: absent from a FULL page whose cutoff is OLDER than #5's own updated_at —
# still closed, it would have to be on that page, so it was reopened.
cp "$FX/alpha-orig.json" "$FX/pages/Example_alpha.json"
fresh_box; tick hub-x
for n in $(seq 0 29); do pr $((2000 + n)) closed null "$(ago $((1000 + n * 100)))" "$(ago $((1000 + n * 100)))"; done \
  | jq -sc '.' > "$FX/pages/Example_alpha.json"
tick hub-x
grep -q "$PB5" <<<"$(posted '.closed // [] | join(",")')" \
  && bad "7c absent from a full page it would have to be on (cutoff older than its updated_at) = reopened, not CLOSED: $(cat "$FX/reconciled.txt")" || ok
[ "$(gh_single Example/alpha)" -ge 1 ] && ok || bad "7d ...and it is re-derived by a read, got $(gh_single Example/alpha)"
# 7e: absent from a FULL page whose cutoff is NEWER than #5's updated_at — it
# simply fell off while still closed: the remembered answer still saves the read.
cp "$FX/alpha-orig.json" "$FX/pages/Example_alpha.json"
rm -f "$FX/prs/Example_alpha-5.json"
fresh_box; tick hub-x
for n in $(seq 0 29); do pr $((3000 + n)) closed null "$(ago $((20 + n * 5)))" "$(ago $((20 + n * 5)))"; done \
  | jq -sc '.' > "$FX/pages/Example_alpha.json"
tick hub-x
[ "$(gh_single)" = 0 ] && ok || bad "7e a still-closed PR that fell off a full page costs no read, made $(gh_single)"
posted '.closed // [] | join(",")' | grep -q "$PB5" \
  && ok || bad "7f ...and is still posted CLOSED from what was remembered: $(cat "$FX/reconciled.txt")"

# ════════════════════════════════════════════════════════════════════════════
# 8. A PR WHOSE READ KEEPS FAILING DOES NOT STARVE THE OTHERS
# ════════════════════════════════════════════════════════════════════════════
unmerged gamma-os Example/gamma $(seq 1 8) | set_unmerged
for n in 1 2 3; do : > "$FX/prs/Example_gamma-$n.json.fail"; done
set_rows lane.reconcile-prs.reconcile_prs_fallback_cap=3
fresh_box; : > "$FX/read-all.txt"; LATER=""
for k in 1 2 3; do
  tick hub-x
  grep -E '^repos/Example/gamma/pulls/[0-9]+$' "$FX/gh.log" >> "$FX/read-all.txt"
  [ "$k" -gt 1 ] && LATER="$LATER$(grep -cE '^repos/Example/gamma/pulls/[123]$' "$FX/gh.log")"
done
MISSED=""; for n in 4 5 6 7 8; do grep -qx "repos/Example/gamma/pulls/$n" "$FX/read-all.txt" || MISSED="$MISSED #$n"; done
[ -z "$MISSED" ] && ok || bad "8a three always-failing reads under a cap of 3 must not starve the rest; never read:$MISSED"
[ "$LATER" = "00" ] && ok || bad "8b a failed read is backed off (registry default window), not retried every tick: retries per later tick '$LATER'"
rm -f "$FX"/prs/Example_gamma-*.json.fail
set_rows

# ════════════════════════════════════════════════════════════════════════════
# 9. THE PROOF'S NEGATIVE — closed AFTER the watermark and fallen off a full
#    page must NOT be proved open
# ════════════════════════════════════════════════════════════════════════════
unmerged beta-os Example/beta 101 | set_unmerged
pr 150 closed null "$(ago 2000)" "$(ago 2000)" | jq -sc '.' > "$FX/pages/Example_beta.json"
fresh_box; tick hub-x
[ -s "$H/state/reconcile-prs/open/Example_beta_101" ] && ok || bad "9a setup: #101 is proved open and watermarked"
for n in $(seq 0 29); do pr $((200 + n)) closed null "$(ago $((100 + n * 20)))" "$(ago $((100 + n * 20)))"; done \
  | jq -sc '.' > "$FX/pages/Example_beta.json"
pr 101 closed null "$(ago 1500)" "$(ago 1500)" > "$FX/prs/Example_beta-101.json"
tick hub-x
[ "$(gh_single Example/beta)" = 1 ] && ok || bad "9b closed after the watermark and off a full page: one read, made $(gh_single Example/beta)"
[ "$(posted '.closed // [] | join(",")')" = "beta-os-TK-101-202609230001" ] \
  && ok || bad "9c ...and it is reconciled CLOSED, not proved open: $(cat "$FX/reconciled.txt")"
echo '[]' > "$FX/pages/Example_beta.json"

# ════════════════════════════════════════════════════════════════════════════
# 5. NO USABLE KNOB — nothing is guessed and nothing is read
# ════════════════════════════════════════════════════════════════════════════
mv "$H/bin/lib/lane-gate.sh" "$T/lane-gate-parked.sh" 2>/dev/null
fresh_box; tick hub-x
[ "$(gh_calls)" = 0 ] && ok || bad "5a with no gate lib and no env the knobs have no value: zero calls, made $(gh_calls)"
grep -q 'tick NOT run' "$H/logs/reconcile.log" && ok || bad "5b ...and the log says why: $(cat "$H/logs/reconcile.log")"
tick hub-x
[ "$(grep -c 'tick NOT run' "$H/logs/reconcile.log")" = 1 ] \
  && ok || bad "5c the unusable-knob line is said once per value, not once per tick on nine boxes: $(cat "$H/logs/reconcile.log")"
mv "$T/lane-gate-parked.sh" "$H/bin/lib/lane-gate.sh" 2>/dev/null

echo "reconcile-prs-one-box: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
