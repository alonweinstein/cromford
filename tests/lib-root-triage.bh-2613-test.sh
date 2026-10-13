#!/bin/bash
# tests/lib-root-triage.bh-2613-test.sh — BH-2650 (BH-2613.2): the triage,
# hotfix, pause and heartbeat libs resolve their root as HARNESS, then H, and
# never fall back to a literal /root/harness
# (docs/notes/2026-09-26-BH-2613-lib-root-resolution.md, rules 1-6).
#
# Every "no root" case runs in a fresh `bash -c 'set -eu; …'` with HARNESS, H,
# JOBS_HARNESS, HB_DIR, HB_DB_CMD and HB_DB all unset, under xtrace, from an
# empty cwd. It asserts the answer, the rc, that nothing was written (the
# scratch root, the cwd and the filesystem root are listed before and after)
# and that the trace names /root/harness zero times. As root those children
# drop to nobody, so a lib that still reaches the literal cannot write into a
# live harness on the box running this suite.
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd -P)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The ten libs this child converts, by rooted path.
LIBS=(
  "$DIR/bin/lib/triage-shards-lib.sh" "$DIR/bin/lib/triage-hotfix-lib.sh"
  "$DIR/bin/lib/triage-throttle.sh" "$DIR/bin/lib/triage-gate-ledger.sh"
  "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/hotfix-migrate-workflow.sh"
  "$DIR/bin/lib/conf-row.sh" "$DIR/bin/lib/heartbeat.sh"
  "$DIR/bin/lib/issue-state-lib.sh" "$DIR/bin/lib/pause.sh"
)
for f in "${LIBS[@]}"; do [ -r "$f" ] || bad "missing $f"; done

# A private copy of bin/ the unprivileged child can read wherever the checkout
# lives. The libs are sourced from here, so their sibling sources resolve too.
NB="$T/nb"; L="$NB/bin/lib"
mkdir -p "$NB/cwd" "$NB/io" "$NB/sr/state" "$NB/sr/env" "$NB/sr/flags" "$NB/sr2"
cp -r "$DIR/bin" "$NB/bin"
SR="$NB/sr"        # the scratch root, for the HARNESS-only and H-only runs
unpriv() { "$@"; }
if [ "$(id -u)" = 0 ]; then
  if command -v setpriv >/dev/null 2>&1; then
    unpriv() { setpriv --reuid=65534 --regid=65534 --clear-groups -- "$@"; }
  else
    echo "SKIP: root without setpriv cannot drop to nobody, and a no-root run as root could write a live harness"
    exit 0
  fi
  chmod o+x "$T"; chmod -R a+rX "$NB"; chmod 777 "$NB/cwd" "$NB/io" "$SR" "$SR/state" "$SR/flags" "$NB/sr2"
fi

# snap — every path a no-root write could land on: the scratch roots, the
# cwd, and the filesystem root's would-be strays.
snap() {
  find "$SR" "$NB/sr2" "$NB/cwd" -mindepth 1 2>/dev/null | sort
  local p; for p in /state /flags /logs /-db /env; do [ -e "$p" ] && echo "STRAY $p"; done
  return 0
}

# nr <name> <script> — one no-root child. OUT, RC, and $NB/<name>.trace.
nr() {
  local name="$1" script="$2" before after
  before=$(snap)
  OUT=$(unpriv env -u BASH_ENV -u HARNESS -u H -u JOBS_HARNESS -u HB_DIR -u HB_DB_CMD -u HB_DB \
          -u HARNESS_ROOT -u HARNESS_STATE_DIR HOME="$NB/cwd" PS4='+ ' \
          bash -c "cd '$NB/cwd' || exit 98; set -eu; set -x; $script" 2>"$NB/$name.trace"); RC=$?
  after=$(snap)
  [ "$before" = "$after" ] || bad "$name wrote with no root: $(diff <(echo "$before") <(echo "$after") | grep '^[<>]' | head -5 | tr '\n' ' ')"
  local n; n=$(grep -c '/root/harness' "$NB/$name.trace")
  [ "$n" = 0 ] && ok || bad "$name: xtrace names /root/harness $n time(s): $(grep -m2 '/root/harness' "$NB/$name.trace" | tr '\n' ' ')"
  # A path built from an empty root (`/state/…`, `/flags/…`, `-db/…`) is as bad
  # as the literal, even where / is not writable and nothing lands.
  n=$(grep -cE "(^|[ '\"=])(/(state|flags|logs|env)(/|\$|[ '\"])|-db/)" "$NB/$name.trace")
  [ "$n" = 0 ] && ok || bad "$name: xtrace builds a path from an empty root $n time(s): $(grep -m2 -E "(^|[ '\"=])(/(state|flags|logs|env)(/|\$|[ '\"])|-db/)" "$NB/$name.trace" | tr '\n' ' ')"
}
# rr <name> <prefix-assignments> <script> — a run WITH a root (HARNESS or H
# set inside the child), same isolation. OUT and RC.
rr() {
  local name="$1" pre="$2" script="$3"
  OUT=$(unpriv env -u BASH_ENV -u HARNESS -u H -u JOBS_HARNESS -u HB_DIR -u HB_DB_CMD -u HB_DB \
          -u HARNESS_ROOT -u HARNESS_STATE_DIR HOME="$NB/cwd" PS4='+ ' \
          bash -c "cd '$NB/cwd' || exit 98; set -eu; $pre; set -x; $script" 2>"$NB/$name.trace"); RC=$?
}
eq() { [ "$1" = "$2" ] && ok || bad "$3: want [$2] got [$1] rc=$RC"; }

# ---------------------------------------------------------------- heartbeat
nr hb-resolve ". '$L/heartbeat.sh'; printf '[%s][%s][%s][%s]' \"\$(hb_dir)\" \"\$(hb_file lane 7)\" \"\$(_hb_db_stamp lane 7)\" \"\$(_hb_db_dir)\""
eq "$RC:$OUT" "0:[][][][]" "hb no root: hb_dir/hb_file/_hb_db_stamp/_hb_db_dir"
nr hb-dark ". '$L/heartbeat.sh'; rc=0; hb_db_enabled || rc=\$?; echo \$rc"
eq "$RC:$OUT" "0:1" "hb no root: hb_db_enabled is dark"
nr hb-write ". '$L/heartbeat.sh'; hb_start lane 60 600; hb_tick lane note; hb_done lane; echo survived"
eq "$RC:$OUT" "0:survived" "hb no root: hb_start/hb_tick/hb_done under set -eu"
rr hb-harness "export HARNESS='$SR'" ". '$L/heartbeat.sh'; hb_dir"
eq "$OUT" "$SR/state/heartbeat" "hb HARNESS only resolves to the scratch root"
rr hb-h "H='$SR'" ". '$L/heartbeat.sh'; hb_dir"
eq "$OUT" "$SR/state/heartbeat" "hb H only resolves to the scratch root"
rr hb-hbdir "export HARNESS='$SR' HB_DIR='$NB/sr2/hb'" ". '$L/heartbeat.sh'; hb_dir"
eq "$OUT" "$NB/sr2/hb" "hb HB_DIR stays ahead of HARNESS"
# HB_DB=1 with a stub client and no root: the beat is SENT, every time (no
# stamp rate-limits the second), and no stamp lands anywhere.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/io/beats"\n' "$NB" > "$NB/io/stub.sh"; chmod 755 "$NB/io/stub.sh"
: > "$NB/io/beats"; chmod 666 "$NB/io/beats"
nr hb-db ". '$L/heartbeat.sh'; export HB_DB=1 HB_DB_CMD='$NB/io/stub.sh'; hb_tick lane a; hb_tick lane b; echo sent"
for _ in $(seq 1 50); do [ "$(grep -c beat "$NB/io/beats")" -ge 2 ] && break; sleep 0.1; done
eq "$RC:$OUT:$(grep -c '^lane-proc-beat lane beat' "$NB/io/beats")" "0:sent:2" "hb no root + HB_DB_CMD: both beats sent, none rate-limited by a stamp"
# HB_DB_CMD keeps its place ahead of the root's jobs-client.
: > "$NB/io/beats"
rr hb-dbcmd "export HARNESS='$SR' HB_DB=1 HB_DB_CMD='$NB/io/stub.sh'" ". '$L/heartbeat.sh'; hb_start lane2 60 600"
for _ in $(seq 1 50); do grep -q start "$NB/io/beats" && break; sleep 0.1; done
eq "$(grep -c '^lane-proc-beat lane2 start' "$NB/io/beats")" "1" "hb HB_DB_CMD stays ahead of \$HARNESS/bin/jobs-client.sh"
scratch_rm "$SR/state/heartbeat"; scratch_rm "$SR/state/heartbeat-db"

# -------------------------------------------------------------------- pause
# ONE clock read for the file (bin/test-determinism-lint.sh); every age is an offset.
NOW=$(date +%s)
FUT=$(( NOW + 86400 ))
live_cache() { printf '{"pauses":[{"id":1,"scope":"fleet","what":"builds","reason":"r","actor":"a","created_at":"2026-01-01T00:00:00Z","expires_at":"%s","ended_at":null}]}' "$(date -u -d "@$FUT" +%Y-%m-%dT%H:%M:%SZ)"; }
nr pause-none ". '$L/pause.sh'; rc=0; pause_active p builds || rc=\$?; printf '%s[%s]' \$rc \"\$(pause_label p)\""
NOROOT="$RC:$OUT"
eq "$NOROOT" "0:1[]" "pause no root: not paused, no label"
rr pause-empty "export HARNESS='$SR'" ". '$L/pause.sh'; rc=0; pause_active p builds || rc=\$?; printf '%s[%s]' \$rc \"\$(pause_label p)\""
eq "$RC:$OUT" "$NOROOT" "pause no root is byte-for-byte a scratch root with no pauses.json"
live_cache > "$SR/state/pauses.json"; chmod 644 "$SR/state/pauses.json"
rr pause-live "export HARNESS='$SR'" ". '$L/pause.sh'; rc=0; pause_active p builds || rc=\$?; printf '%s[%s]' \$rc \"\$(pause_label p)\""
eq "$RC:$OUT" "0:0[PAUSED(builds) ]" "pause fixture is live under HARNESS (the negative below is not vacuous)"
rr pause-h "H='$SR'" ". '$L/pause.sh'; rc=0; pause_active p builds || rc=\$?; echo \$rc"
eq "$OUT" "0" "pause H only resolves to the scratch root"
nr pause-stale ". '$L/pause.sh'; rc=0; pause_active p builds || rc=\$?; printf '%s[%s]' \$rc \"\$(pause_label p)\""
eq "$RC:$OUT" "0:1[]" "pause no root never reads a pauses.json it was not pointed at"
rr pause-jh "export HARNESS='$SR' JOBS_HARNESS='$NB/sr2'" ". '$L/pause.sh'; rc=0; pause_active p builds || rc=\$?; echo \$rc"
eq "$OUT" "1" "pause JOBS_HARNESS stays ahead of HARNESS"
rm -f "$SR/state/pauses.json"
# pause_refresh with a stub client: both requests go out, nothing is written, rc 1.
: > "$NB/io/pcalls"; chmod 666 "$NB/io/pcalls"
nr pause-refresh ". '$L/pause.sh'; export JOBS_URL=http://stub
_jobs_req() { printf '%s %s\n' \"\$1\" \"\$2\" >> '$NB/io/pcalls'; case \"\$1\" in POST) echo '{\"expired\":[{\"scope\":\"fleet\",\"what\":\"builds\",\"reason\":\"r\",\"actor\":\"a\"}]}' ;; *) echo '{\"pauses\":[]}' ;; esac; }
rc=0; pause_refresh || rc=\$?; echo rc=\$rc"
eq "$RC:$OUT:$(tr '\n' ',' < "$NB/io/pcalls")" "0:rc=1:POST /api/pauses/expire,GET /api/pauses?active=1," "pause_refresh no root: sends both, writes nothing, rc 1"
nr pause-shapes ". '$L/pause.sh'; REVIEW_AUTOPILOT_DAILY_CAP=2 pause_env_shapes; echo end"
eq "$RC:$(echo "$OUT" | tr '\n' ',')" "0:env:review-cap=2,end," "pause_env_shapes no root: the env check still runs with the default knob"

# ---------------------------------------------------------------- hotfix-lib
nr hotfix-reads ". '$L/hotfix-lib.sh'; echo \$(hotfix_lane_on) \$(hotfix_label) \$(main_red_label) \$(priority_rank_labels_csv hotfix) \$(priority_rank_labels_csv fix-main-red) \$(priority_rank_labels_csv x)"
eq "$RC:$OUT" "0:1 hotfix fix-main-red 0 1 2" "hotfix no root: lane on, default labels, ranks"
nr hotfix-announce ". '$L/hotfix-lib.sh'; hotfix_announce '' p K seen txt; echo survived"
eq "$RC:$OUT" "0:survived" "hotfix_announce with no root writes nothing, rc 0"
nr hotfix-issue ". '$L/hotfix-lib.sh'; rc=0; hotfix_issue_is o/r 1 || rc=\$?; echo \$rc"
[ "$RC" = 0 ] && [ "$OUT" != 0 ] && ok || bad "hotfix_issue_is with no root must not answer hotfix: rc=$RC out=$OUT"
printf 'HOTFIX_LABEL=urgent\n' > "$SR/env/global.env"; chmod 644 "$SR/env/global.env"
rr hotfix-harness "export HARNESS='$SR'" ". '$L/hotfix-lib.sh'; hotfix_label"
eq "$OUT" "urgent" "hotfix HARNESS only reads the scratch root's env file"
rr hotfix-h "H='$SR'" ". '$L/hotfix-lib.sh'; hotfix_label"
eq "$OUT" "urgent" "hotfix H only reads the scratch root's env file"

# --------------------------------------------------------- triage-shards-lib
nr tsh-reads ". '$L/triage-shards-lib.sh'; echo \$(triage_shards_on) \$(triage_shards_max) \$(triage_shard_timeout) \$(triage_caps_on) \$(triage_shards_per_hour) \$(triage_shard_usd_per_hour) \$(triage_runner) \$(triage_shard_fp_ttl) \$(triage_prstates_ttl) \$(triage_prstates_prune_s)"
eq "$RC:$OUT" "0:1 0 10800 0 30 60 claude 14400 2700 604800" "triage-shards no root: every knob its default"
nr tsh-model ". '$L/triage-shards-lib.sh'; rc=0; out=\$(triage_model '' board-changed p) || rc=\$?; echo \"\$rc[\$out]\"; TRIAGE_MODEL=m triage_model '' board-changed p"
eq "$RC:$(echo "$OUT" | tr '\n' ',')" "0:75[],m," "triage_model no root: rc 75 and no model; the env var still answers"
nr tsh-write ". '$L/triage-shards-lib.sh'; rc=0; _tsh_prstates_put '' p 12 OPEN || rc=\$?; echo \$rc"
eq "$RC:$OUT" "0:1" "triage-shards prstates record with no root refuses (rc 1) and writes nothing"
printf 'TRIAGE_SHARDS_MAX=7\nRUNNER_TRIAGE=grok\n' > "$SR/env/global.env"
rr tsh-harness "export HARNESS='$SR'" ". '$L/triage-shards-lib.sh'; echo \$(triage_shards_max) \$(triage_runner)"
eq "$OUT" "7 grok" "triage-shards HARNESS only reads the scratch root"
rr tsh-h "H='$SR'" ". '$L/triage-shards-lib.sh'; echo \$(triage_shards_max) \$(triage_runner)"
eq "$OUT" "7 grok" "triage-shards H only reads the scratch root"

# --------------------------------------------------------- triage-hotfix-lib
nr thl-mark ". '$L/triage-hotfix-lib.sh'; PROJECT=p; printf 'BH-1\nBH-2\n' | triage_hot_mark queue"
eq "$RC:$(echo "$OUT" | tr '\n' ',')" "0:BH-1,BH-2," "triage_hot_mark with no root passes stdin through unchanged"
rr thl-h "H='$NB'" ". '$L/triage-hotfix-lib.sh'; command -v hotfix_lane_on"
eq "$OUT" "hotfix_lane_on" "triage-hotfix-lib H only sources hotfix-lib from the root"

# ----------------------------------------------------------- triage-throttle
: > "$NB/io/alerts"; chmod 666 "$NB/io/alerts"
nr tt-warn ". '$L/triage-throttle.sh'; echo \$(triage_health_on); triage_health_warn_once '' p why '$NB/io/alerts'; triage_health_warn_once '' p why '$NB/io/alerts'; triage_health_warn_once '' p why ''; echo survived"
eq "$RC:$(echo "$OUT" | tr '\n' ','):$(grep -c 'WARN \[triage-health\] \[p\] paid triage held: why' "$NB/io/alerts")" "0:1,survived,:2" "triage-throttle no root: health on, the hold is written every time, no flag stamped"
rr tt-harness "export HARNESS='$SR'" ". '$L/triage-throttle.sh'; triage_health_on >/dev/null"
grep -A1 -E "^\++ HARNESS=$SR\$" "$NB/tt-harness.trace" | grep -q "lane_switch triage-health-off" && ok || bad "triage_health_on HARNESS only asks lane_switch about the scratch root"
rr tt-h "H='$SR'" ". '$L/triage-throttle.sh'; triage_health_on >/dev/null"
grep -A1 -E "^\++ HARNESS=$SR\$" "$NB/tt-h.trace" | grep -q "lane_switch triage-health-off" && ok || bad "triage_health_on H only asks lane_switch about the scratch root"

# -------------------------------------------------------- triage-gate-ledger
nr tgl ". '$L/triage-gate-ledger.sh'; tgl_put_gate '' p; rc=0; tgl_read_gate '' p || rc=\$?; echo \$rc; command -v lt_put"
eq "$RC:$(echo "$OUT" | tr '\n' ',')" "0:1,lt_put," "triage-gate-ledger no root: sibling ledger-twin loaded, put is a no-op, read misses"

# ------------------------------------------------- hotfix-migrate-workflow
nr hmw ". '$L/hotfix-migrate-workflow.sh'; SLUG=o/r; hm_workflow_body() { echo body; return 3; }; rc=0; hm_workflow || rc=\$?; echo \$rc; command -v gh_auth_for || echo no-auth"
eq "$RC:$(echo "$OUT" | tr '\n' ',')" "0:body,3,no-auth," "hm_workflow no root: body runs on the caller's token, gh-app-auth not loaded"

# ------------------------------------------------------------------ conf-row
nr conf ". '$L/conf-row.sh'; conf_row_refused f k v /x/flags/ff; conf_rows_preload f; echo \"[\$(conf_rows f)]\"; rc=0; conf_row f k || rc=\$?; echo \$rc \$CONF_ROW_SRC"
eq "$RC:$(echo "$OUT" | tr '\n' ',')" "0:[],1 none," "conf-row no root: no rows, no row, nothing logged, lane-gate never loaded"
rr conf-h "H='$SR'" ". '$L/conf-row.sh'; conf_rows_preload f"
grep -q "local HARNESS=$SR\$" "$NB/conf-h.trace" && ok || bad "conf-row H only resolves to the scratch root"

# ------------------------------------------------------------ issue-state-lib
nr issue ". '$L/issue-state-lib.sh'; echo \$(_issue_switch '' SKIP_CLOSED skip-closed-off) \$(_issue_env '' ISSUE_CLOSE_GUARD_PAGES 5)"
eq "$RC:$OUT" "0:1 5" "issue-state-lib no root: switch on, knob default"
printf 'ISSUE_CLOSE_GUARD_PAGES=9\n' > "$SR/env/global.env"; : > "$SR/flags/skip-closed-off"; chmod 644 "$SR/flags/skip-closed-off"
rr issue-harness "export HARNESS='$SR'" ". '$L/issue-state-lib.sh'; echo \$(_issue_switch '' SKIP_CLOSED skip-closed-off)"
eq "$OUT" "0" "issue-state-lib HARNESS only reads the scratch root's flag"
rr issue-h "H='$SR'" ". '$L/issue-state-lib.sh'; echo \$(_issue_switch '' SKIP_CLOSED skip-closed-off)"
eq "$OUT" "0" "issue-state-lib H only reads the scratch root's flag"
rm -f "$SR/flags/skip-closed-off"

# ---------------------------------------- D2: bin/heartbeat-reaper.sh as shipped
# A scratch HARNESS, HB_DIR unset: the reaper finds the dead lane through the
# lib's own root resolution and every file it writes is under the scratch root.
RH="$T/rh"; mkdir -p "$RH/bin/lib" "$RH/logs" "$RH/state" "$RH/env"
cp "$DIR/bin/heartbeat-reaper.sh" "$DIR/bin/lane-alert.sh" "$DIR/bin/alert_family.py" "$RH/bin/" 2>/dev/null
cp "$DIR/bin/lib/heartbeat.sh" "$DIR/bin/lib/alert-state.sh" "$DIR/bin/lib/env-path.sh" "$RH/bin/lib/"
chmod +x "$RH/bin/"*.sh; : > "$RH/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$RH/bin/beat.sh"; chmod +x "$RH/bin/beat.sh"
( trap - EXIT; exec /bin/true ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null
( export HARNESS="$RH"; unset HB_DIR H
  . "$DIR/bin/lib/heartbeat.sh"
  HB_PID="$DEADPID" HB_NOW=$((NOW - 7200)) hb_start deadlane 60 600 )
[ -s "$RH/state/heartbeat/deadlane.$DEADPID.json" ] && ok || bad "D2 fixture: hb_start with HARNESS did not write under the scratch root"
( export HARNESS="$RH" HB_NOW="$NOW" PS4='+ '; unset HB_DIR H HB_DB HB_DB_CMD JOBS_HARNESS
  timeout 30 bash -x "$RH/bin/heartbeat-reaper.sh" ) >/dev/null 2>"$T/reaper.trace"; RC=$?
eq "$RC" "0" "D2 heartbeat-reaper.sh exits 0 on a scratch HARNESS"
grep -q 'deadlane' "$RH/logs/ALERTS.log" "$RH/logs/heartbeat-reaper.log" 2>/dev/null && ok \
  || bad "D2 the reaper did not find the dead lane under the scratch root: $(cat "$RH/logs/heartbeat-reaper.log" 2>/dev/null | tail -3)"
n=$(grep -c '/root/harness' "$T/reaper.trace"); eq "$n" "0" "D2 the reaper pass touches no /root/harness path"

echo "lib-root-triage.bh-2613: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
