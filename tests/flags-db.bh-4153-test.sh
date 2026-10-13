#!/bin/bash
# tests/flags-db.bh-4153-test.sh — BH-4153 (BH-4141.1): the three most-read flag
# families live in the DB. `paused-*`, `automerge-disabled[-*]` and
# `lanedown-*` are harness_flags ROWS read DB-first with a last-good cache in
# state/flags-cache/, and a configured box writes no flags/ file for them.
#
#   A  set / has / clear through the REAL bin/lib/flags.sh + bin/jobs-client.sh,
#      scope, and no file written
#   B  a read error is rc 2 (never "off"), the cache answers an outage, a
#      malformed 200 is the outage path, a stop switch fails closed, and a box
#      with no worker configured keeps the legacy file semantics
#   C  --hold-local: a failed write that must still pause the box, and the
#      BH-1370 recency rule that lets a later row win
#   D  bin/flags-import.sh: idempotent, row wins, failed keeps the file, the 409
#      guard, the lazy import, the update-runners block, and (D7) ownership:
#      only a flag this box owns per fleet.conf is ever published as a row
#   E  the readers: the REAL bin/run-triage.sh pauses and resumes from a row
#      (the ticket's observable outcome), the rb/pr.sh tier-1 hold, and the
#      pipeline-health cost halt with the worker down
#   F  lanedown-*: bin/lib/lane-down.sh and bin/fleet-status-push.sh's LANES_DOWN
#   G  FLAG_PORTED_RE is the same list in shell and in the worker
#   Q  bin/quiesce-for-resize.sh pauses THIS box only (a local hold, no row)
#      and --resume lifts only that
#   P  fleet-status-push's pause_flags list comes from the rows
#   K  poll-commands' "auto-merge enabled" reply reads the fleet kill switch row
#
# The worker is a stateful PATH `curl` stub keeping rows in $ST/rows/<scope>/,
# switchable to down (rc 7) or malformed ({} 200), with its own clock so every
# row stamp is deterministic. No network, no model. Exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

command -v jq >/dev/null 2>&1 || { echo "flags-db.bh-4153: jq missing, cannot run"; exit 1; }

NOW=$(date -u +%s)
TODAY=$(date -u -d "@$NOW" +%Y%m%d)
S="$T/h"; ST="$T/stub"
mkdir -p "$S/bin/lib/jobs" "$S/flags" "$S/state" "$S/logs" "$S/env" "$ST" "$T/fakebin"
: > "$S/env/global.env"
for s in bin/jobs-client.sh bin/lib/lane-down.sh bin/lib/flags.sh bin/flags-import.sh; do
  scratch_install_closure "$s" "$S" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
cp "$DIR/bin/alert-line.sh" "$S/bin/"
# The registry the import judges ownership by: boxa owns p, r, s and x-os; q is
# boxb's. box-hub is the hub.
for s in bin/fleet-conf.sh bin/box-for.sh; do scratch_install_closure "$s" "$S" >/dev/null || { echo "closure install failed for $s"; exit 1; }; done
for p in p r s x-os; do printf '%s org/%s https://x.example /api/board 2 boxa\n' "$p" "$p"; done > "$S/fleet.conf"
printf 'q org/q https://x.example /api/board 2 boxb\n' >> "$S/fleet.conf"

# --- the worker ---------------------------------------------------------------
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
ST="${STUB_DIR:?}"
URL="${!#}"; METHOD=GET; DATA=""
while [ $# -gt 1 ]; do
  case "$1" in -X) METHOD="$2"; shift 2 ;; --data-binary) DATA="$2"; shift 2 ;; *) shift ;; esac
done
case "$DATA" in @*) DATA=$(cat "${DATA#@}") ;; esac
printf '%s %s %s\n' "$METHOD" "${URL#http://stub}" "$DATA" >> "$ST/curl.log"
MODE=$(cat "$ST/mode" 2>/dev/null); MODE=${MODE:-up}
case "$MODE" in down) exit 7 ;; malformed) printf '{}\n200'; exit 0 ;; esac
P=${URL#http://stub}; PTH=${P%%\?*}; Q=""; case "$P" in *\?*) Q=${P#*\?} ;; esac
qget() { local v; v=$(printf '%s' "$Q" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1); v=${v//+/ }; printf '%b' "${v//%/\\x}"; }
tick() { local c; c=$(( $(cat "$ST/clock") + 1 )); echo "$c" > "$ST/clock"; date -u -d "@$c" +%Y-%m-%dT%H:%M:%SZ; }
legacy() { jq -c '. + {active:(if .cleared_at == null then 1 else 0 end), actor:.set_by, updated_at:(.cleared_at // .set_at)}'; }
answer() { printf '%s\n%s' "$1" "$2"; exit 0; }
case "$METHOD $PTH" in
  "GET /api/flags/"*)
    n=${PTH#/api/flags/}; s=$(qget scope); s=${s:-fleet}; f="$ST/rows/$s/$n.json"
    [ -f "$f" ] && answer "{\"flag\":$(legacy < "$f")}" 200
    answer '{"error":"not found"}' 404 ;;
  "GET /api/flags")
    px=$(qget prefix); s=$(qget scope); a=$(qget active)
    rows=$(cat "$ST"/rows/*/*.json 2>/dev/null | jq -sc --arg p "$px" --arg s "$s" --arg a "$a" \
      '[.[] | select((.name | startswith($p)) and ($s == "" or .scope == $s) and ($a != "1" or .cleared_at == null))]
       | map(. + {active:(if .cleared_at == null then 1 else 0 end), actor:.set_by, updated_at:(.cleared_at // .set_at)})')
    answer "{\"flags\":${rows:-[]}}" 200 ;;
  "PUT /api/flags")
    n=$(jq -r .name <<<"$DATA"); s=$(jq -r '.scope // "fleet"' <<<"$DATA"); f="$ST/rows/$s/$n.json"
    if [ -f "$ST/conflict-once" ]; then rm -f "$ST/conflict-once"; [ -f "$ST/race.sh" ] && . "$ST/race.sh"; answer '{"error":"flag moved"}' 409; fi
    cur=""; [ -f "$f" ] && cur=$(jq -r '.cleared_at // .set_at' "$f")
    if jq -e 'has("expected_set_at")' >/dev/null <<<"$DATA"; then
      [ "$(jq -r .expected_set_at <<<"$DATA")" = "$cur" ] || answer '{"error":"flag moved"}' 409
    fi
    t=$(tick); mkdir -p "$ST/rows/$s"
    old='{}'; [ -f "$f" ] && old=$(cat "$f")
    jq -c --arg t "$t" --arg s "$s" --argjson o "$old" \
      '{scope:$s, name, value:(.value // null), set_by:(.actor // null), reason:(.reason // null)}
       + (if (.active == 1 or .active == true) then {set_at:$t, cleared_at:null} else {set_at:($o.set_at // $t), cleared_at:$t} end)' \
      <<<"$DATA" > "$f"
    answer "{\"flag\":$(legacy < "$f")}" 200 ;;
  "DELETE /api/flags")
    n=$(qget name); s=$(qget scope); s=${s:-fleet}; f="$ST/rows/$s/$n.json"
    [ -f "$f" ] || answer '{"error":"not found"}' 404
    if [ "$(jq -r .cleared_at "$f")" = null ]; then
      t=$(tick); jq -c --arg t "$t" '.cleared_at = $t' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
    answer "{\"flag\":$(legacy < "$f")}" 200 ;;
  "POST /api/jobs") answer '{"job":{"id":"triage-project-3-1","budget_usd":1}}' 201 ;;
esac
[ "${STUB_OTHER:-404}" = 200 ] && answer '{}' 200
answer '{}' 404
EOF
chmod +x "$T/fakebin/curl"

reset_stub() { for p in rows mode conflict-once race.sh; do scratch_rm "$ST/$p"; done; : > "$ST/curl.log"; echo "$NOW" > "$ST/clock"; }
reset_box()  { scratch_rm "$S/flags"; scratch_rm "$S/state/flags-cache"; mkdir -p "$S/flags"; : > "$S/logs/jobs-client.log"; }
mode()  { echo "$1" > "$ST/mode"; }
iso()   { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
row()   { # row <scope> <name> <set_at-epoch> [cleared_at-epoch] — a worker row, as the console would leave it
  mkdir -p "$ST/rows/$1"
  jq -nc --arg s "$1" --arg n "$2" --arg a "$(iso "$3")" --arg c "${4:+$(iso "${4:-0}")}" \
    '{scope:$s, name:$n, value:null, set_by:"console", reason:"test", set_at:$a, cleared_at:(if $c == "" then null else $c end)}' \
    > "$ST/rows/$1/$2.json"
}
puts()  { grep -c '^PUT ' "$ST/curl.log" 2>/dev/null || true; }
# lib <script>: run <script> in a child bash with the REAL client loaded through
# bin/lib/flags.sh, configured against the stub (JU= for "no worker here").
lib() {
  env HARNESS="$S" JOBS_URL="${JU-http://stub}" HARNESS_SECRET=x JOBS_BOX="${JB:-boxa}" JOBS_RETRIES=0 \
      STUB_DIR="$ST" PATH="$T/fakebin:$PATH" FLEET_CONF="${FC-$S/fleet.conf}" HUB_BOX_NAME=box-hub \
      bash -c '. "$HARNESS/bin/lib/flags.sh" || exit 99; '"$1" 2>>"$T/stderr"
}

# =========================== A. set / has / clear ===========================
reset_stub; reset_box
eq "A1 flag_set rc" "$(lib 'flag_set paused-p on r; echo $?')" "0"
grep -q '^PUT /api/flags .*"name":"paused-p"' "$ST/curl.log" && ok || bad "A1 the stub must see PUT /api/flags: $(cat "$ST/curl.log")"
eq "A1 the PUT is fleet-scoped and active" "$(grep '^PUT /api/flags ' "$ST/curl.log" | head -1 | cut -d' ' -f3- | jq -c '{scope,active}')" '{"scope":"fleet","active":1}'
eq "A1 flag_has after set" "$(lib 'flag_has paused-p; echo "$? $FLAG_SRC"')" "0 db"
eq "A1 flag_clear rc" "$(lib 'flag_clear paused-p r2; echo $?')" "0"
grep -q '^DELETE /api/flags?name=paused-p&scope=fleet' "$ST/curl.log" && ok || bad "A1 the stub must see DELETE /api/flags?name=paused-p&scope=fleet: $(grep DELETE "$ST/curl.log")"
eq "A1 flag_has after clear" "$(lib 'flag_has paused-p; echo "$? $FLAG_SRC"')" "1 db"
# The public CLI verbs answer the same.
eq "A1 jobs-client.sh flag-has" "$(env HARNESS="$S" JOBS_URL=http://stub HARNESS_SECRET=x JOBS_BOX=boxa JOBS_RETRIES=0 STUB_DIR="$ST" PATH="$T/fakebin:$PATH" bash "$S/bin/jobs-client.sh" flag-has paused-p 2>/dev/null; echo $?)" "1"

# A2 value + scope: a lanedown row is box-scoped, and flag_has finds it without --scope.
eq "A2 box-scoped set" "$(lib "flag_set --scope boxa lanedown-boxa-codex-$TODAY on; echo \$?")" "0"
[ -f "$ST/rows/boxa/lanedown-boxa-codex-$TODAY.json" ] && ok || bad "A2 the row must be scope boxa: $(ls -R "$ST/rows")"
eq "A2 has resolves the scope to JOBS_BOX" "$(lib "flag_has lanedown-boxa-codex-$TODAY; echo \"\$? \$FLAG_SRC\"")" "0 db"
eq "A2 a value is stored" "$(lib 'flag_set automerge-disabled-x-os held-for-review why; echo $?')" "0"
eq "A2 the row carries the value" "$(jq -r .value "$ST/rows/fleet/automerge-disabled-x-os.json")" "held-for-review"
# A3 no file written; the cache is.
eq "A3 no file under flags/" "$(find "$S/flags" -type f | wc -l | tr -d ' ')" "0"
[ -s "$S/state/flags-cache/fleet/paused-p" ] && ok || bad "A3 state/flags-cache/fleet/paused-p must exist"
eq "A3 the cache line is JSON" "$(jq -r '.on' "$S/state/flags-cache/fleet/paused-p" 2>/dev/null)" "false"

# =========================== B. outage, cache, rc 2 =========================
reset_stub; reset_box; mode down
eq "B1 rc 2 on outage, no cache" "$(lib 'flag_has paused-q; echo $?')" "2"
eq "B1 flag_list rc 2 on outage, no cache" "$(lib 'flag_list paused- >/dev/null; echo $?')" "2"
reset_stub; reset_box; row fleet paused-p "$((NOW-100))"; row fleet paused-o "$((NOW-200))" "$((NOW-100))"
lib 'flag_has paused-p; flag_has paused-o' >/dev/null
mode down
eq "B2 cached ON answers the outage" "$(lib 'flag_has paused-p; echo "$? $FLAG_SRC"')" "0 cache"
eq "B2 cached OFF answers the outage" "$(lib 'flag_has paused-o; echo "$? $FLAG_SRC"')" "1 cache"
eq "B2 flag_list from cache on outage" "$(lib 'flag_list paused-; echo "rc=$?"' | tr '\n' ' ')" "rc=2 "
reset_stub; reset_box; row fleet paused-p "$((NOW-100))"
lib 'flag_list paused- >/dev/null'
mode down
eq "B2 flag_list after a good list answers from cache" "$(lib 'flag_list paused-; echo "rc=$?"' | tr '\n' ' ')" "paused-p rc=0 "
# A row the console clears drops out of the next good list, and so out of the cache.
mode up; row fleet paused-p "$((NOW-100))" "$((NOW-50))"
eq "B2 a cleared row leaves the list" "$(lib 'flag_list paused-; echo "rc=$?"' | tr '\n' ' ')" "rc=0 "
mode down
eq "B2 and stays out of the cached list" "$(lib 'flag_list paused-; echo "rc=$?"' | tr '\n' ' ')" "rc=0 "
# B3 malformed 200
reset_stub; reset_box; mode malformed
eq "B3 malformed with no cache is rc 2, never off" "$(lib 'flag_has paused-p; echo $?')" "2"
grep -q 'flag paused-p' "$S/logs/jobs-client.log" && ok || bad "B3 one jobs-client.log line for the unreadable row: $(cat "$S/logs/jobs-client.log")"
reset_stub; reset_box; row fleet paused-p "$((NOW-100))"; lib 'flag_has paused-p' >/dev/null; mode malformed
eq "B3 malformed with a cache answers from the cache" "$(lib 'flag_has paused-p; echo "$? $FLAG_SRC"')" "0 cache"
# B4 a stop switch fails closed; a non-ported name is legacy.
reset_stub; reset_box; mode down
eq "B4 automerge-disabled unknown reads ON" "$(lib 'flag_active automerge-disabled; echo $?')" "0"
grep -q 'flag automerge-disabled: unknown .*read as ON' "$S/logs/jobs-client.log" && ok || bad "B4 the read-as-ON line: $(cat "$S/logs/jobs-client.log")"
eq "B4 non-ported alerts-db stays legacy (off, no file)" "$(lib 'flag_active alerts-db; echo $?')" "1"
eq "B4 paused-* fails closed too" "$(lib 'flag_active paused-zz; echo $?')" "0"
# B5 no worker configured: the legacy file, no curl at all.
reset_stub; reset_box
eq "B5 no client: set" "$(JU='' lib 'flag_set paused-p on r >/dev/null; flag_has paused-p; echo $?')" "0"
[ -f "$S/flags/paused-p" ] && ok || bad "B5 no client: flags/paused-p must be touched (legacy)"
eq "B5 no curl call" "$(grep -c . "$ST/curl.log")" "0"
eq "B5 no client: clear removes the file" "$(JU='' lib 'flag_clear paused-p; flag_has paused-p; echo $?'; [ -e "$S/flags/paused-p" ] && echo still)" "1"

# =========================== C. --hold-local ================================
reset_stub; reset_box; mode down
eq "C1 hold-local set during outage is rc 1" "$(lib 'flag_set --hold-local paused-p on brake; echo $?')" "1"
eq "C1 the hold answers ON" "$(lib 'flag_has paused-p; echo "$? $FLAG_SRC"')" "0 local"
[ -e "$S/flags/paused-p" ] && bad "C1 a hold is a cache entry, not a file" || ok
mode up
eq "C1 worker back, no row: the hold stands" "$(lib 'flag_has paused-p; echo "$? $FLAG_SRC"')" "0 local"
row fleet paused-p "$((NOW+3000))" "$((NOW+3600))"
eq "C1 a row cleared after the hold wins" "$(lib 'flag_has paused-p; echo "$? $FLAG_SRC"')" "1 db"
eq "C1 the hold is dropped" "$(jq -r .src "$S/state/flags-cache/fleet/paused-p")" "db"
reset_stub; reset_box; mode down
eq "C2 a plain set during outage is rc 1" "$(lib 'flag_set paused-p on x; echo $?')" "1"
eq "C2 nothing local: rc 2" "$(lib 'flag_has paused-p; echo $?')" "2"
[ -e "$S/flags/paused-p" ] && bad "C2 no file may be written" || ok

# =========================== D. import =======================================
run_import() { env HARNESS="$S" JOBS_URL="${JU-http://stub}" HARNESS_SECRET=x JOBS_BOX="${JB:-boxa}" JOBS_RETRIES=0 \
  STUB_DIR="$ST" PATH="$T/fakebin:$PATH" FLEET_CONF="${FC-$S/fleet.conf}" HUB_BOX_NAME=box-hub \
  bash "$S/bin/flags-import.sh" "$@" 2>>"$T/stderr"; }
reset_stub; reset_box
# Every one of these is boxa's (fleet.conf puts x-os on boxa); the fleet
# automerge-disabled is the hub's, and D7 covers it.
touch -d "@$((NOW-600))" "$S/flags/paused-p" "$S/flags/automerge-disabled-x-os" "$S/flags/lanedown-boxa-codex-$TODAY" "$S/flags/alerts-db"
OUT=$(run_import); RC=$?
eq "D1 import rc" "$RC" "0"
eq "D1 three imported lines" "$(grep -c '^imported ' <<<"$OUT")" "3"
grep -q "^imported lanedown-boxa-codex-$TODAY boxa$" <<<"$OUT" && ok || bad "D1 lanedown imported box-scoped: $OUT"
eq "D1 the ported files are gone, the rest stay" "$(ls "$S/flags" | tr '\n' ' ')" "alerts-db "
eq "D1 rows active" "$(jq -r '.cleared_at' "$ST/rows/fleet/paused-p.json" "$ST/rows/fleet/automerge-disabled-x-os.json" "$ST/rows/boxa/lanedown-boxa-codex-$TODAY.json" | tr '\n' ' ')" "null null null "
grep -q 'imported from flags/paused-p on boxa' "$ST/rows/fleet/paused-p.json" && ok || bad "D1 the reason names the import: $(cat "$ST/rows/fleet/paused-p.json")"
P1=$(puts); OUT=$(run_import); RC=$?
eq "D1 second run" "$OUT" "nothing to import"
eq "D1 second run rc" "$RC" "0"
eq "D1 second run makes no PUT" "$(puts)" "$P1"
# D2 the row wins when it is newer than the file.
reset_stub; reset_box; row fleet paused-r "$((NOW-900))" "$((NOW-60))"; touch -d "@$((NOW-600))" "$S/flags/paused-r"
eq "D2 kept-row" "$(run_import)" "kept-row paused-r"
[ -e "$S/flags/paused-r" ] && bad "D2 the file must be removed" || ok
eq "D2 no PUT" "$(puts)" "0"
eq "D2 still cleared" "$(lib 'flag_has paused-r; echo $?')" "1"
# D3 a failed import keeps the file, and the file still pauses.
reset_stub; reset_box; touch -d "@$((NOW-600))" "$S/flags/paused-p"; mode down
OUT=$(run_import); RC=$?
case "$RC" in 1|75) ok ;; *) bad "D3 rc must be 1 or 75, got $RC" ;; esac
grep -q '^failed paused-p' <<<"$OUT" && ok || bad "D3 a failed line: $OUT"
[ -e "$S/flags/paused-p" ] && ok || bad "D3 the file must stay"
eq "D3 the file still pauses" "$(lib 'flag_has paused-p; echo "$? $FLAG_SRC"')" "0 local"
# D3b removing the file is still a resume: the hold it seeded goes with it.
rm -f "$S/flags/paused-p"
eq "D3b rm of the file drops its hold (worker down, nothing else known)" "$(lib 'flag_has paused-p; echo $?')" "2"
[ -e "$S/state/flags-cache/fleet/paused-p" ] && bad "D3b the seeded hold must be gone" || ok
mode up
eq "D3b worker back, no row: off" "$(lib 'flag_has paused-p; echo "$? $FLAG_SRC"')" "1 db"
# ...but a --hold-local hold is not a file's and does not go with one.
mode down; lib 'flag_set --hold-local paused-h on x' >/dev/null
eq "D3b a hold-local hold survives a flags/ rm" "$(lib 'rm -f "$HARNESS/flags/paused-h"; flag_has paused-h; echo "$? $FLAG_SRC"')" "0 local"
eq "D3b the hold-local entry is still cached" "$(jq -r '.src + ":" + (.from // "")' "$S/state/flags-cache/fleet/paused-h" 2>/dev/null)" "local:"
# D4 a 409: the console clears the row between the import's GET and its PUT.
# The GET sees no row, the PUT carries expected_set_at "" and is refused 409,
# and the re-read finds the newer clear: the row wins, nothing is overwritten.
reset_stub; reset_box; touch -d "@$((NOW-600))" "$S/flags/paused-p"; : > "$ST/conflict-once"
row fleet paused-p "$((NOW-900))" "$((NOW-60))"; mv "$ST/rows/fleet/paused-p.json" "$T/held.json"
printf 'mkdir -p "%s"; cp "%s" "%s"\n' "$ST/rows/fleet" "$T/held.json" "$ST/rows/fleet/paused-p.json" > "$ST/race.sh"
eq "D4 the newer clear wins after the 409" "$(run_import)" "kept-row paused-p"
eq "D4 still cleared" "$(jq -r .cleared_at "$ST/rows/fleet/paused-p.json")" "$(iso "$((NOW-60))")"
eq "D4 one PUT, the refused one" "$(puts)" "1"
rm -f "$ST/race.sh"
# D5 the lazy import: flag_has imports a file it still sees.
reset_stub; reset_box; touch -d "@$((NOW-600))" "$S/flags/paused-s"
eq "D5 flag_has imports" "$(lib 'flag_has paused-s; echo $?')" "0"
grep -q '^PUT /api/flags .*"name":"paused-s"' "$ST/curl.log" && ok || bad "D5 the PUT must be seen: $(cat "$ST/curl.log")"
[ -e "$S/flags/paused-s" ] && bad "D5 the file must be gone" || ok
# D6 the update-runners block, extracted by marker.
awk '/^# >>> flags import/{f=1;next} /^# <<< flags import/{exit} f' "$DIR/bin/update-runners.sh" > "$T/ur-block.sh"
[ -s "$T/ur-block.sh" ] && ok || bad "D6 the # >>> flags import block must exist in bin/update-runners.sh"
ur() { # ur <rc> <output> — the block over a stand-in import
  printf '#!/bin/bash\nprintf "%%s\\n" %q\nexit %s\n' "$2" "$1" > "$T/stub-import.sh"; chmod +x "$T/stub-import.sh"
  : > "$T/ur.log"; : > "$S/logs/ALERTS.log"
  env HARNESS="$S" FLAGS_IMPORT="$T/stub-import.sh" LOG="$T/ur.log" BOX_TAG=boxa CHECKOUT="$T/co" CRON_RC=sentinel \
    bash -c 'set -uo pipefail; STAMP(){ echo TS; }; . "$1"; echo "CRON_RC=$CRON_RC"' _ "$T/ur-block.sh" 2>/dev/null
}
eq "D6 rc 0 leaves CRON_RC" "$(ur 0 'imported paused-p fleet')" "CRON_RC=sentinel"
grep -q '^TS flags-import: imported paused-p fleet$' "$T/ur.log" && ok || bad "D6 rc 0 logs the lines: $(cat "$T/ur.log")"
eq "D6 rc 0 no alert" "$(grep -c . "$S/logs/ALERTS.log")" "0"
ur 1 "failed paused-q http" >/dev/null
eq "D6 rc 1 exactly one alert" "$(grep -c . "$S/logs/ALERTS.log")" "1"
grep -q 'failed paused-q' "$S/logs/ALERTS.log" && ok || bad "D6 the alert names the failed flag: $(cat "$S/logs/ALERTS.log")"
ur 75 "failed paused-q worker-unreachable" >/dev/null
eq "D6 rc 75 no alert" "$(grep -c . "$S/logs/ALERTS.log")" "0"
grep -q 'rc=75' "$T/ur.log" && ok || bad "D6 rc 75 is a log line: $(cat "$T/ur.log")"

# D7 ownership: a legacy file only ever paused the box it sat on, so the
# import publishes it only where it acted: a project fleet.conf puts on this
# box, the fleet automerge-disabled on the hub, lanedown-*. Anything else stays
# this box's local hold and never becomes a fleet row.
reset_stub; reset_box
touch -d "@$((NOW-600))" "$S/flags/paused-q" "$S/flags/automerge-disabled-q" "$S/flags/automerge-disabled" "$S/flags/paused-p"
eq "D7 dry-run says which would stay local" "$(run_import --dry-run | sort | tr '\n' '|')" \
  "kept-local automerge-disabled not-owned|kept-local automerge-disabled-q not-owned|kept-local paused-q not-owned|would-import paused-p fleet|"
OUT=$(run_import); RC=$?
eq "D7 import rc with not-owned files" "$RC" "0"
eq "D7 lines" "$(sort <<<"$OUT" | tr '\n' '|')" \
  "imported paused-p fleet|kept-local automerge-disabled not-owned|kept-local automerge-disabled-q not-owned|kept-local paused-q not-owned|"
eq "D7 only the owned flag was PUT" "$(grep '^PUT ' "$ST/curl.log" | cut -d' ' -f3- | jq -r .name | tr '\n' ' ')" "paused-p "
for n in paused-q automerge-disabled-q automerge-disabled; do
  [ -e "$ST/rows/fleet/$n.json" ] && bad "D7 $n must not become a fleet row" || ok
  [ -e "$S/flags/$n" ] && ok || bad "D7 flags/$n stays on this box"
done
eq "D7 a not-owned file still pauses THIS box" "$(lib 'flag_has paused-q; echo "$? $FLAG_SRC"')" "0 local"
eq "D7 ...and the lazy import published nothing" "$(grep -c '^PUT ' "$ST/curl.log")" "1"
grep -q 'flag import: kept-local' "$S/logs/jobs-client.log" && bad "D7 kept-local is not logged on every read" || ok
eq "D7 the fleet switch is the hub's to publish" "$(JB=box-hub run_import | grep automerge-disabled | sort | tr '\n' '|')" \
  "imported automerge-disabled fleet|kept-local automerge-disabled-q not-owned|"
# A row at or after a not-owned file's mtime still wins and removes the file.
reset_stub; reset_box; row fleet paused-q "$((NOW-900))" "$((NOW-60))"; touch -d "@$((NOW-600))" "$S/flags/paused-q"
eq "D7 a newer row removes a not-owned file" "$(run_import)" "kept-row paused-q"
[ -e "$S/flags/paused-q" ] && bad "D7 the not-owned file is gone once a row covers it" || ok
# A registry this box cannot read owns nothing.
# TEST-CHANGE: bin/fleet-conf.sh falls back to the fleet.conf beside its own
# tree ($S/fleet.conf) when FLEET_CONF does not exist, so "no registry" must
# hide that file too. Before, this case read $S/fleet.conf and saw p owned.
reset_stub; reset_box; touch -d "@$((NOW-600))" "$S/flags/paused-p"
mv "$S/fleet.conf" "$T/fleet.conf.aside"
eq "D7 no registry: kept-local" "$(FC="$T/nope.conf" run_import)" "kept-local paused-p not-owned"
eq "D7 no registry: no PUT" "$(puts)" "0"
mv "$T/fleet.conf.aside" "$S/fleet.conf"

# =========================== E. readers ======================================
# E1 the REAL bin/run-triage.sh (the tests/run-triage-pause.bh-1672-test.sh recipe).
H="$T/rt"
mkdir -p "$H/bin/lib/rt" "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/prompts" "$H/builds" "$H/fixture" "$T/calls" "$T/repos"
: > "$H/env/global.env"
echo "SOP for project-3." > "$H/prompts/project-3.md"
printf 'project-3   example-org/project-3    https://board.example  /api/board  2 boxa 10.0.0.1\n' > "$T/fleet.conf"
sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/run-triage.sh" > "$H/bin/run-triage.sh"; chmod +x "$H/bin/run-triage.sh"
for s in "$DIR"/bin/lib/rt/*.sh; do sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"; done
for s in fleet-conf.sh project-of.sh decision-log.sh; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
for s in bin/lib/triage-shards-lib.sh bin/lib/pause.sh bin/lib/pause-rows.sh bin/jobs-client.sh bin/lib/flags.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
echo 'pause_refresh(){ return 0; }' >> "$H/bin/lib/pause.sh"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
model_routes_fixture "$H" project-3 || exit 1
printf '#!/bin/bash\n[ "${2:-}" = --pending ] && exit 0\n[ "${2:-}" = --buildable ] && { echo OK; exit 0; }\necho "RUN board-changed"\n' > "$H/bin/triage-gate.sh"
sed -e "s|/root/harness|$H|g" "$DIR/bin/gate-diff.sh" > "$H/bin/gate-diff.sh"
for s in unblocked-children.sh decompose-parent-close.sh beat.sh lane-alert.sh hotfix-seen.sh box-name.sh; do printf '#!/bin/sh\nexit 0\n' > "$H/bin/$s"; done
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"
printf '#!/bin/bash\nmktemp "%s/prompt-XXXXXXXX.txt" >/dev/null\necho "tickets=1 done" > "$5"\nexit 0\n' "$T/calls" > "$H/bin/agent-call.sh"
chmod +x "$H"/bin/*.sh
tri() { env PATH="$T/fakebin:$PATH" FLEET_CONF="$T/fleet.conf" TRIAGE_SHARDS=0 STUB_DIR="$ST" STUB_OTHER=200 \
  HARNESS_SECRET=x JOBS_URL=http://stub JOBS_BOX=boxa JOBS_RETRIES=0 "$H/bin/run-triage.sh" project-3 >/dev/null 2>&1; echo $?; }
rtlib() { env HARNESS="$H" JOBS_URL=http://stub HARNESS_SECRET=x JOBS_BOX=boxa JOBS_RETRIES=0 STUB_DIR="$ST" PATH="$T/fakebin:$PATH" \
  bash -c '. "$HARNESS/bin/jobs-client.sh" || exit 99; '"$1" 2>/dev/null; }
npaused() { grep -c 'paused via console, skipping' "$H/logs/project-3.log" 2>/dev/null || true; }
reset_stub
eq "E1 the console sets paused-project-3" "$(rtlib 'flag_set paused-project-3 on "from the console"; echo $?')" "0"
eq "E1 the paused tick exits 0" "$(tri)" "0"
eq "E1 one paused via console line" "$(npaused)" "1"
grep -q '"kind":"paused"' "$ST/curl.log" && ok || bad "E1 the lane tick is a paused tick"
eq "E1 the agent was not called" "$(ls "$T/calls" | grep -c . || true)" "0"
eq "E1 the console clears it" "$(rtlib 'flag_clear paused-project-3 "resume"; echo $?')" "0"
: > "$ST/curl.log"
eq "E1 the resumed tick exits 0" "$(tri)" "0"
eq "E1 no new paused line" "$(npaused)" "1"
grep -q '"kind":"paused"' "$ST/curl.log" && bad "E1 the resumed tick must not be a paused tick" || ok
eq "E1 the agent ran on the resumed tick" "$(ls "$T/calls" | grep -c . || true)" "1"
[ -e "$H/flags/paused-project-3" ] && bad "E1 no flags/paused-project-3 at any point" || ok

# E2 the rb/pr.sh tier-1 hold, from the flattened pipeline text.
rb_all "$DIR" "$T/rb.sh" >/dev/null
awk '/^# >>> automerge pause/{f=1;next} /^# <<< automerge pause/{exit} f' "$T/rb.sh" > "$T/am-block.sh"
[ -s "$T/am-block.sh" ] && ok || bad "E2 the # >>> automerge pause block must exist in the pipeline"
am() { rtlib 'TIER=1; PROJECT=project-3; KEY=K; BUILD='"$T"'; STAMP(){ echo TS; }; . '"$T/am-block.sh"'; echo "$TIER"'; }
reset_stub; row fleet automerge-disabled "$((NOW-100))"
eq "E2 an active automerge-disabled row demotes" "$(am)" "2"
reset_stub; row fleet automerge-disabled "$((NOW-200))" "$((NOW-100))"
eq "E2 a cleared row leaves tier 1" "$(am)" "1"

# E3 pipeline-health's cost halt with the worker down: fail, no file, no hold.
awk '/^ *# >>> cb halt/{f=1;next} /^ *# <<< cb halt/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/cb-block.sh"
[ -s "$T/cb-block.sh" ] && ok || bad "E3 the # >>> cb halt block must exist in bin/pipeline-health.sh"
reset_stub; reset_box; mode down
# CB_HOLD_PREFIX is set above the block in bin/pipeline-health.sh (BH-5526).
eq "E3 CB_HALT with the worker down" "$(lib 'H='"$S"'; NOW='"$NOW"'; CB_HOLD_PREFIX=spend-hold-; cb_knob(){ echo "$2"; }; cb_autohalt_off(){ return 1; }; . '"$T/cb-block.sh"'; cb_halt project-3 "why"; echo "$CB_HALT"')" "fail"
# TEST-CHANGE (BH-5526): the halt is the hold spend-hold-<p>, not paused-<p>.
# A failed PUT leaves neither flag: no file and no cache hold for either name.
for n in paused-project-3 spend-hold-project-3; do
  [ -e "$S/flags/$n" ] && bad "E3 no flags/$n" || ok
  [ -e "$S/state/flags-cache/fleet/$n" ] && bad "E3 no cache hold for $n" || ok
done

# =========================== F. lanedown =====================================
reset_stub; reset_box
eq "F1 ld_mark" "$(lib '. "$HARNESS/bin/lib/lane-down.sh"; ld_mark "$HARNESS" boxb-codex 10.0.0.2 "boom" '"$NOW"'; echo $?')" "0"
[ -f "$ST/rows/boxa/lanedown-boxb-codex-$TODAY.json" ] && ok || bad "F1 a row scoped to this box: $(ls -R "$ST/rows" 2>/dev/null)"
eq "F1 no flags/lanedown file" "$(ls "$S/flags" | grep -c lanedown || true)" "0"
lib '. "$HARNESS/bin/lib/lane-down.sh"; ld_clear "$HARNESS" boxb-codex '"$NOW"'' >/dev/null
eq "F1 ld_clear clears the row" "$(jq -r '.cleared_at != null' "$ST/rows/boxa/lanedown-boxb-codex-$TODAY.json")" "true"
reset_stub; reset_box
for k in 0 1 2; do row boxa "lanedown-boxb-codex-$(date -u -d "@$((NOW - k*86400))" +%Y%m%d)" "$((NOW-k*86400))"; done
OLDEST=$(date -u -d "$(date -u -d "@$((NOW-2*86400))" +%Y%m%d)" +%s)
eq "F1 since from three day rows" "$(lib '. "$HARNESS/bin/lib/lane-down.sh"; _ld_since_from_flags "$HARNESS" boxb-codex '"$NOW"'')" "$OLDEST"
# F2 fleet-status-push's LANES_DOWN, extracted by marker.
awk '/^# >>> lanes down/{f=1;next} /^# <<< lanes down/{exit} f' "$DIR/bin/fleet-status-push.sh" > "$T/ld-block.sh"
[ -s "$T/ld-block.sh" ] && ok || bad "F2 the # >>> lanes down block must exist in bin/fleet-status-push.sh"
lanes_down() { lib 'H="$HARNESS"; . '"$T/ld-block.sh"'; echo "$LANES_DOWN"'; }
reset_stub; reset_box
row boxa "lanedown-boxb-codex-$TODAY" "$NOW"; row boxa "lanedown-boxc-grok-$(date -u -d "@$((NOW-86400))" +%Y%m%d)" "$((NOW-86400))"
eq "F2 today's rows only" "$(lanes_down)" '{"boxb":["codex"]}'
mode down
eq "F2 worker down, cache from the last list" "$(lanes_down)" '{"boxb":["codex"]}'
reset_box
printf '%s\n' '{"boxz":["grok"]}' > "$S/state/fleet-status-last-lanes-down.json"
eq "F2 worker down, no cache: the last pushed value, never {}" "$(lanes_down)" '{"boxz":["grok"]}'

# =========================== G. one list =====================================
SH_RE=$(sed -n "s/^FLAG_PORTED_RE='\(.*\)'$/\1/p" "$DIR/bin/lib/jobs/flags.sh")
JS_RE=$(sed -n 's|^export const FLAG_PORTED_RE = /\(.*\)/;$|\1|p' "$DIR/worker/jobs/src/lib/harness-flags.js")
[ -n "$SH_RE" ] && ok || bad "G1 FLAG_PORTED_RE missing from bin/lib/jobs/flags.sh"
eq "G1 the shell and worker lists are one list" "$SH_RE" "$JS_RE"

# =========================== Q. quiesce ======================================
printf '#!/bin/bash\necho p; echo q\n' > "$S/bin/fleet-projects-or-alert.sh"; chmod +x "$S/bin/fleet-projects-or-alert.sh"
cp "$DIR/bin/quiesce-for-resize.sh" "$S/bin/"
awk '/# >>> pause all/{f=1;next} /# <<< pause all/{exit} f' "$DIR/bin/quiesce-for-resize.sh" > "$T/q-block.sh"
[ -s "$T/q-block.sh" ] && ok || bad "Q the # >>> pause all block must exist in bin/quiesce-for-resize.sh"
quiesce() { lib 'H="$HARNESS"; LOG="$HARNESS/logs/quiesce.log"; STAMP(){ echo TS; }; . '"$T/q-block.sh"; }
resume()  { env HARNESS="$S" JOBS_URL=http://stub HARNESS_SECRET=x JOBS_BOX=boxa JOBS_RETRIES=0 STUB_DIR="$ST" \
  PATH="$T/fakebin:$PATH" FLEET_CONF="$S/fleet.conf" bash "$S/bin/quiesce-for-resize.sh" --resume 2>>"$T/stderr"; }
reset_stub; reset_box; row fleet paused-q "$((NOW-900))"   # a console pause on q, before the resize
quiesce
eq "Q1 quiesce writes no row" "$(puts)" "0"
[ -e "$ST/rows/fleet/paused-p.json" ] && bad "Q1 no fleet paused-p row" || ok
eq "Q1 this box is paused" "$(lib 'flag_has paused-p; echo "$? $FLAG_SRC"')" "0 local"
eq "Q1 no file either" "$(find "$S/flags" -type f | wc -l | tr -d ' ')" "0"
eq "Q2 --resume" "$(resume)" "RESUMED"
eq "Q2 --resume writes no row" "$(grep -cE '^(PUT|DELETE) ' "$ST/curl.log")" "0"
eq "Q2 this box resumes (no row)" "$(lib 'flag_has paused-p; echo "$? $FLAG_SRC"')" "1 db"
eq "Q2 a console pause written as a row is not lifted" "$(lib 'flag_has paused-q; echo "$? $FLAG_SRC"')" "0 db"
# Worker down at resume: the hold goes, but nothing is guessed "off".
reset_stub; reset_box; quiesce; mode down; resume >/dev/null
eq "Q3 resume with the worker down: unknown, read as ON" "$(lib 'flag_active paused-p; echo $?')" "0"
mode up
eq "Q3 worker back: resumed" "$(lib 'flag_has paused-p; echo $?')" "1"

# =========================== P. pause_flags push ============================
awk '/^# >>> pause flags/{f=1;next} /^# <<< pause flags/{exit} f' "$DIR/bin/fleet-status-push.sh" > "$T/pf-block.sh"
[ -s "$T/pf-block.sh" ] && ok || bad "P the # >>> pause flags block must exist in bin/fleet-status-push.sh"
pf() { lib 'H="$HARNESS"; . '"$T/pf-block.sh"'; echo "$PAUSED"'; }
reset_stub; reset_box; scratch_rm "$S/state/fleet-status-last-pause-flags.json"
row fleet paused-p "$((NOW-100))"; row fleet paused-o "$((NOW-200))" "$((NOW-100))"
row fleet automerge-disabled "$((NOW-100))"; row fleet automerge-disabled-x-os "$((NOW-100))"
touch "$S/flags/codex-disabled"
eq "P1 the rows, plus the non-ported *disabled* files" "$(pf)" '["automerge-disabled","automerge-disabled-x-os","codex-disabled","paused-p"]'
mode down
eq "P1 worker down: the cached lists" "$(pf)" '["automerge-disabled","automerge-disabled-x-os","codex-disabled","paused-p"]'
reset_box; touch "$S/flags/codex-disabled"
eq "P1 worker down, no cache: the last pushed list, never []" "$(pf)" '["automerge-disabled","automerge-disabled-x-os","codex-disabled","paused-p"]'
grep -q 'pause_flags unknown' "$S/logs/fleet-status-push.log" && ok || bad "P1 one log line for the unknown list"
mode up; reset_stub; reset_box
eq "P2 no worker: the files, as before" "$(touch "$S/flags/paused-z" "$S/flags/codex-disabled"; JU='' pf)" '["codex-disabled","paused-z"]'

# =========================== K. kill-switch reply ===========================
awk '/^    # >>> automerge handlers/{f=1;next} /^    # <<< automerge handlers/{exit} f{print}' "$DIR/bin/poll-commands.sh" \
  | sed -e '1s/^    automerge_off|automerge_on)//' -e '$s/ ;;$//' > "$T/am-h.sh"
awk '/^set_flag\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/poll-commands.sh" > "$T/setflag.sh"
[ -s "$T/am-h.sh" ] && [ -s "$T/setflag.sh" ] && ok || bad "K the automerge handler and set_flag must extract"
am_on() { lib 'TYPE=automerge_on; PROJECT=p; PAYLOAD="{}"; OK=false; RESULT=""; . '"$T/setflag.sh"'; . '"$T/am-h.sh"'; echo "$RESULT"'; }
reset_stub; reset_box; row fleet automerge-disabled "$((NOW-100))"
grep -q 'fleet kill switch automerge-disabled is still on' <<<"$(am_on)" && ok || bad "K1 a fleet switch row is reported still on: $(am_on)"
[ -e "$S/flags/automerge-disabled" ] && bad "K1 no file" || ok
reset_stub; reset_box; row fleet automerge-disabled "$((NOW-200))" "$((NOW-100))"
grep -q 'kill switch' <<<"$(am_on)" && bad "K2 a cleared switch is not mentioned: $(am_on)" || ok
reset_stub; reset_box; mode down
grep -q 'could not be read' <<<"$(am_on)" && ok || bad "K3 an unreadable switch is said so: $(am_on)"

echo "flags-db.bh-4153: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
