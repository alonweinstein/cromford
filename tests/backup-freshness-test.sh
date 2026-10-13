#!/bin/bash
# tests/backup-freshness-test.sh — a backup that stopped is the quietest
# failure in the fleet, so its AGE is a fleet signal (#399, after the hub wipe
# #388).
#
# WHAT IS UNDER TEST is the whole chain, not the arithmetic:
#   A. bin/fleet-status-push.sh really pushes `backups` per box, and the
#      absent-means-not-pushed convention really holds — a box with no marker
#      carries NO backup_age_min key rather than a fabricated 0 or -1.
#   B. bin/pipeline-health.sh's check, extracted VERBATIM by its markers and
#      run with the REAL alert() (TTL dedupe + ALERTS.log + pipeline-health.log
#      + beat) and the REAL retraction epilogue — so "once per hour per box"
#      and "retractable" mean the artifacts, not the intention.
#   C. the ssh probe the hub runs on a box and the local reader it is the twin
#      of agree field-for-field on one fixture tree. Two copies of that rule
#      would drift silently, and the drift would read as a healthy fleet.
#   D. every one of these is fail-open. The fleet-status push is the watchdog's
#      layer-2 dead-man signal; a lib that is not installed must cost the field
#      and never the push.
#   F. the COLLECTOR (BH-1031): the box states its own facts on the way out of
#      the tick that produced them, and the hub turns every box's row back into
#      the record above. Replaces the two cases that drove the deleted
#      bin/fleet-heartbeat.sh; both halves are mutated to prove they are load
#      bearing.
#
# THE STATES THAT MUST NOT PAGE are half the point. bin/state-backup.sh ships
# unconfigured (the BACKUP_* keys are a handoff, and it already alerts once per
# UTC day about it) and can be switched off on purpose. An hourly page per box
# for a state somebody already knows about is the page-fatigue that gets a
# channel muted — the exact failure the 05:26 phone-spam screenshot bought.
#
# Run from anywhere: tests/backup-freshness-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
[ -r "$(dirname "$0")/lib/scratch.sh" ] && . "$(dirname "$0")/lib/scratch.sh"
if [ -z "${T:-}" ]; then T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fi
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read. Every fixture age below is derived from it as an offset, so
# the file is internally consistent whatever the wall clock says.
NOW=$(date +%s)

mkdir -p "$T/bin/lib" "$T/logs" "$T/state/fleet-heartbeat" "$T/flags" "$T/env" \
         "$T/builds" "$T/fakebin" "$T/box"

cp "$DIR/bin/lib/backup-freshness.sh" "$T/bin/lib/" 2>/dev/null || true
[ -r "$T/bin/lib/backup-freshness.sh" ] \
  && ok || bad "bin/lib/backup-freshness.sh does not exist — the one reader of backup freshness"
# shellcheck source=/dev/null
[ -r "$T/bin/lib/backup-freshness.sh" ] && . "$T/bin/lib/backup-freshness.sh"

# A ts in the marker's own format (bin/state-backup.sh writes compact basic
# ISO-8601: 20260920T101500Z), N minutes before the anchor.
ts_ago() { date -u -d "@$(( NOW - $1 * 60 ))" +%Y%m%dT%H%M%SZ 2>/dev/null \
        || date -u -r "$(( NOW - $1 * 60 ))" +%Y%m%dT%H%M%SZ; }
# One heartbeat record: <ts>\t<off>\t<unconfigured>, the three raw facts the
# ssh hop brings back.
record() { printf '%s\t%s\t%s\n' "${2:-}" "${3:-}" "${4:-}" > "$T/state/fleet-heartbeat/backup-$1"; }
# backdate <file> <days> — an mtime older than the reader's unconfigured window.
# Derived from the one clock read above, so the fixture cannot rot.
backdate() {
  local stamp
  stamp=$(date -u -d "@$(( NOW - $2 * 86400 ))" +%Y%m%d%H%M 2>/dev/null) \
    || stamp=$(date -u -r "$(( NOW - $2 * 86400 ))" +%Y%m%d%H%M)
  touch -t "$stamp" "$1"
}
# backdate_min <file> <minutes> — the same, in minutes. A heartbeat record's
# mtime is WHEN THE HUB COLLECTED IT, so this is how a fixture says "the box
# answered this long ago and has not answered since".
backdate_min() {
  local stamp
  stamp=$(date -u -d "@$(( NOW - $2 * 60 ))" +%Y%m%d%H%M 2>/dev/null) \
    || stamp=$(date -u -r "$(( NOW - $2 * 60 ))" +%Y%m%d%H%M)
  touch -t "$stamp" "$1"
}

# ═══════════════════════════════════════════════════════════════════════════
# The fixture fleet. Three boxes the ticket names (5m, 45m, no marker) plus the
# three states that must stay silent, plus the hub's own row off local disk.
# ═══════════════════════════════════════════════════════════════════════════
record box-fresh  "$(ts_ago 5)"
record box-stale  "$(ts_ago 45)"
record box-gone   ""                         # reachable, never stamped
record box-unconf ""   ""      unconfigured
record box-off    "$(ts_ago 300)" off        # off wins over a stale stamp
record box-badts  "NOT-A-TIMESTAMP"          # a stamp we cannot read
: > "$T/state/fleet-heartbeat/backup-box-torn"  # a record with no fields
# The hub backs ITSELF up — #388 is the hub — so its row is read straight off
# this tree, not out of a heartbeat record.
printf '{"ts":"%s","key":"hub/x.tar.zst","bytes":10,"sha256":"deadbeef"}\n' "$(ts_ago 2)" \
  > "$T/state/backup-last.json"

# ═══════════════════════════════════════════════════════════════════════════
# A. the push
# ═══════════════════════════════════════════════════════════════════════════
printf 'HARNESS_SECRET=test-secret\nHUB_BOX_NAME=box-hub\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/env/global.env"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$T/bin/" 2>/dev/null || true
printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$T" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/bin/"
printf '#!/bin/bash\ncat > %s/PUSH.json\n' "$T" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
# EVERY FIXTURE BOX IS IN fleet.conf, because a record for a box the registry
# does not name is a ghost (section E). state/fleet-heartbeat keeps a file per
# box it ever saw and retired boxes leave theirs behind forever, so membership
# is part of "is this an answer", not decoration — the same rule bin/fleet-slo.sh
# learned on this exact directory on 2026-09-15.
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 box-fresh
beta-os Org/beta https://b.example /api/board 3 box-stale
gamma-os Org/gamma https://c.example /api/board 4 box-gone
delta-os Org/delta https://d.example /api/board 5 box-unconf
epsilon-os Org/epsilon https://e.example /api/board 6 box-off
zeta-os Org/zeta https://f.example /api/board 7 box-badts
eta-os Org/eta https://g.example /api/board 8 box-torn
theta-os Org/theta https://h.example /api/board 9 box-frozen
iota-os Org/iota https://i.example /api/board 10 box-offnet
EOF

push() { rm -f "$T/PUSH.json"; ( PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" \
  bash "$DIR/bin/fleet-status-push.sh" >/dev/null 2>&1 ); }
q() { jq -r "$1" "$T/PUSH.json" 2>/dev/null; }

push
jq -e . >/dev/null 2>&1 < "$T/PUSH.json" \
  && ok || bad "A0: the push must still be valid JSON with the backups block in it"

[ "$(q '.backups."box-fresh".backup_age_min')" = 5 ] \
  && ok || bad "A1: a 5-minute-old marker must push backup_age_min 5 (got: $(q '.backups|tojson'))"
[ "$(q '.backups."box-stale".backup_age_min')" = 45 ] \
  && ok || bad "A2: a 45-minute-old marker must push backup_age_min 45 (got: $(q '.backups|tojson'))"
# ABSENT MEANS NOT PUSHED. A fabricated 0 here reads as "backed up just now"
# forever, which is the healthy value for the very number the fleet alerts on.
[ "$(q '.backups."box-gone" | has("backup_age_min")')" = false ] \
  && ok || bad "A3: a box that never stamped must carry NO backup_age_min key (got: $(q '.backups."box-gone"|tojson'))"
[ "$(q '.backups."box-gone".state')" = missing \
] && ok || bad "A4: a reachable box with no marker is state=missing (got: $(q '.backups."box-gone"|tojson'))"
[ "$(q '.backups."box-unconf".state')" = unconfigured ] \
  && ok || bad "A5: an unconfigured box says so rather than looking like a dead one (got: $(q '.backups|tojson'))"
[ "$(q '.backups."box-unconf" | has("backup_age_min")')" = false ] \
  && ok || bad "A6: unconfigured carries no age (got: $(q '.backups."box-unconf"|tojson'))"
[ "$(q '.backups."box-off".state')" = off ] \
  && ok || bad "A7: a deliberately-off lane reads off, even holding a stale stamp (got: $(q '.backups|tojson'))"
# A ts we cannot parse is a bug in this lane, not a dead backup — and it must
# read as neither. Never an age (which would be invented), never `missing`
# (which would page for a parse bug).
[ "$(q '.backups."box-badts".state')" = unknown ] \
  && ok || bad "A7b: an unparseable ts is state=unknown (got: $(q '.backups."box-badts"|tojson'))"
[ "$(q '.backups."box-badts" | has("backup_age_min")')" = false ] \
  && ok || bad "A7c: an unparseable ts must never carry an age (got: $(q '.backups."box-badts"|tojson'))"
# A torn/empty record is not an answer this lane produced. It must read as
# unknown, NEVER as missing — missing pages, and a half-written file must not
# be able to page.
[ "$(q '.backups."box-torn".state')" = unknown ] \
  && ok || bad "A7d: a record with no fields is unknown, not missing (got: $(q '.backups."box-torn"|tojson'))"
[ "$(q '.backups."box-hub".backup_age_min')" = 2 ] \
  && ok || bad "A8: the hub's own backup must be in the snapshot — #388 IS the hub (got: $(q '.backups|tojson'))"
# The fields the watchdog already had must survive the addition.
[ "$(q '.projects."alpha-os" | type')" = object ] \
  && ok || bad "A9: the pre-existing snapshot fields must survive (got: $(q 'keys|tojson'))"
# THE THRESHOLD TRAVELS WITH THE READING. The console cannot reach the knob
# store, so a threshold compiled into the bundle means an operator who raises
# backup_stale_min to 45 gets no page at 40m and a red STALE pill anyway — two
# surfaces disagreeing about one number, which is the whole reason this lane has
# one library. It is pushed as a number, next to the ages it applies to.
[ "$(q '.backup_stale_min')" = 30 ] \
  && ok || bad "A10: the push must carry the threshold the alerts use (got: $(q '.backup_stale_min'))"
( export BACKUP_STALE_MIN=45; push )
[ "$(q '.backup_stale_min')" = 45 ] \
  && ok || bad "A11: a raised knob must reach the console too, not just the alert (got: $(q '.backup_stale_min'))"
push

# ═══════════════════════════════════════════════════════════════════════════
# D. fail-open: a second harness tree that does NOT carry the lib. The script
#    runs from inside it, so neither source path resolves — the shape of a box
#    that has not synced yet. Nothing in $DIR is touched.
# ═══════════════════════════════════════════════════════════════════════════
mkdir -p "$T/nolib/bin" "$T/nolib/logs" "$T/nolib/state" "$T/nolib/flags" "$T/nolib/env"
cp "$DIR/bin/fleet-status-push.sh" "$T/nolib/bin/"
cp "$T/bin/beat.sh" "$T/nolib/bin/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$T/nolib/bin/" 2>/dev/null || true
printf 'HARNESS_SECRET=test-secret\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/nolib/env/global.env"
mkdir -p "$T/nolib/bin/lib"; cp "$DIR/bin/lib/watchdog-url.sh" "$T/nolib/bin/lib/"
[ ! -e "$T/nolib/bin/lib/backup-freshness.sh" ] \
  && ok || bad "D0: the fail-open tree must not carry the lib"
rm -f "$T/PUSH.json"
( PATH="$T/fakebin:$PATH" HARNESS="$T/nolib" FLEET_CONF="$T/fleet.conf" \
  bash "$T/nolib/bin/fleet-status-push.sh" >/dev/null 2>&1 )
jq -e . >/dev/null 2>&1 < "$T/PUSH.json" \
  && ok || bad "D1: a missing bin/lib/backup-freshness.sh must never cost the dead-man push"
[ "$(q '.projects."alpha-os" | type')" = object ] \
  && ok || bad "D2: the pre-existing fields must survive a missing lib (got: $(q 'keys|tojson'))"

# ═══════════════════════════════════════════════════════════════════════════
# B. the alerts — the REAL block, the REAL alert(), the REAL epilogue
# ═══════════════════════════════════════════════════════════════════════════
grep '^RETRACT_NS=' "$DIR/bin/pipeline-health.sh"                                > "$T/p1.sh"
awk '/^# >>> alert emit cap/{f=1;next} /^# <<< alert emit cap/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/p0.sh"
awk '/^alert\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/pipeline-health.sh" > "$T/p2.sh"
awk '/^# >>> backup freshness/{f=1;next} /^# <<< backup freshness/{exit} f' \
  "$DIR/bin/pipeline-health.sh"                                                 > "$T/p3.sh"
awk '/^# ── Retraction epilogue/{f=1} f{print} /^rm -f "\$FIRED"$/&&f{exit}' \
  "$DIR/bin/pipeline-health.sh"                                                 > "$T/p4.sh"
[ -s "$T/p1.sh" ] && ok || bad "B0a: no RETRACT_NS= line in bin/pipeline-health.sh"
[ -s "$T/p2.sh" ] && ok || bad "B0b: could not extract alert() from bin/pipeline-health.sh"
[ -s "$T/p3.sh" ] && ok || bad "B0c: could not extract the backup block — # >>> backup freshness markers missing?"
[ -s "$T/p4.sh" ] && ok || bad "B0d: could not extract the retraction epilogue"
cat "$T/p1.sh" "$T/p0.sh" "$T/p2.sh" "$T/p3.sh" "$T/p4.sh" > "$T/block.sh"
bash -n "$T/block.sh" 2>/dev/null && ok || bad "B0e: the extracted block is not valid bash"
# Both namespaces must be retractable, or a backup that came back keeps paging.
grep -q 'backupstale' "$T/p1.sh"   && ok || bad "B0f: backupstale must be in RETRACT_NS"
grep -q 'backupmissing' "$T/p1.sh" && ok || bad "B0g: backupmissing must be in RETRACT_NS"

FIRED="$T/state/health-fired.test"
ACTIVE="$T/state/health-active.txt"
DEDUP="$T/state/health-alerted.json"
: > "$ACTIVE"; echo '{}' > "$DEDUP"

tick() { # one cron tick of the real block + the real epilogue
  : > "$FIRED"          # production truncates the fired set every run
  ( export HARNESS="$T" T="$T" NOW="$NOW" FIRED="$FIRED" ACTIVE="$ACTIVE" \
      BEATS="$T/beats.txt" PATH="$T/bin:$PATH"
    bash -c '
      set -uo pipefail
      H="$T"; DEDUP="$T/state/health-alerted.json"
      STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
      . "$0"' "$T/block.sh" >/dev/null 2>"$T/err.txt" )
  echo $? > "$T/rc.txt"
}
# grep -c prints 0 AND exits 1 on no match, so `|| echo 0` would print TWO
# lines and every "must not page" assertion would compare against "0\n0".
nlines() { local n; n=$(grep -c "$1" "$T/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }
allines() { local n; n=$(grep -c . "$T/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }

: > "$T/logs/ALERTS.log"; : > "$T/logs/pipeline-health.log"; : > "$T/beats.txt"; : > "$T/err.txt"
tick
[ "$(cat "$T/rc.txt")" = 0 ] && ok || bad "B1: the tick must not fail: rc=$(cat "$T/rc.txt") err=$(cat "$T/err.txt")"
[ ! -s "$T/err.txt" ] && ok || bad "B2: the tick must not write to stderr: $(cat "$T/err.txt")"
# Counted by BOX, not by dedupe key: the operator reads ALERTS.log, and the key
# lives in the beat and the TTL ledger, never in the line they see.
[ "$(nlines 'box-stale')" = 1 ] \
  && ok || bad "B3: exactly one backup-stale line for the 45-minute box (got: $(cat "$T/logs/ALERTS.log"))"
grep -q 'box-stale has no verified off-box backup' "$T/logs/ALERTS.log" \
  && ok || bad "B3b: the stale line must say what is wrong (got: $(cat "$T/logs/ALERTS.log"))"
[ "$(nlines 'box-gone')" = 1 ] \
  && ok || bad "B4: exactly one backup-missing line for the box that never stamped (got: $(cat "$T/logs/ALERTS.log"))"
grep -q 'box-gone has NEVER written' "$T/logs/ALERTS.log" \
  && ok || bad "B4b: the missing line must say the box has never stamped (got: $(cat "$T/logs/ALERTS.log"))"
# THE SILENT STATES. Every one of these already has an owner that says it once.
[ "$(nlines 'box-fresh')" = 0 ] \
  && ok || bad "B5: a 5-minute-old backup must not page (got: $(cat "$T/logs/ALERTS.log"))"
[ "$(nlines 'box-unconf')" = 0 ] \
  && ok || bad "B6: an unconfigured lane is state-backup.sh's daily alert, not an hourly page here (got: $(cat "$T/logs/ALERTS.log"))"
[ "$(nlines 'box-off')" = 0 ] \
  && ok || bad "B7: a deliberately-off lane must never page (got: $(cat "$T/logs/ALERTS.log"))"
[ "$(nlines 'box-badts')" = 0 ] \
  && ok || bad "B7b: an unparseable stamp must not page (got: $(cat "$T/logs/ALERTS.log"))"
# ...but it must not go quiet either: a parse bug that reports nothing is
# indistinguishable from a healthy box.
grep -q 'box-badts is unknown' "$T/logs/pipeline-health.log" \
  && ok || bad "B7c: an unparseable stamp must be said out loud in pipeline-health.log (got: $(cat "$T/logs/pipeline-health.log"))"
[ "$(nlines 'box-torn')" = 0 ] \
  && ok || bad "B7d: a torn record must not page (got: $(cat "$T/logs/ALERTS.log"))"
# The alert has to be actionable: name the box AND the number.
grep -q 'box-stale' "$T/logs/ALERTS.log" \
  && ok || bad "B8: the stale line must name the box (got: $(cat "$T/logs/ALERTS.log"))"
grep -qE 'box-stale.*45' "$T/logs/ALERTS.log" \
  && ok || bad "B9: the stale line must carry the age (got: $(cat "$T/logs/ALERTS.log"))"

# Once per hour per box: a second tick inside the window adds nothing.
BEFORE=$(allines)
tick
[ "$(allines)" = "$BEFORE" ] \
  && ok || bad "B10: a second tick inside the hour must add nothing (got: $(cat "$T/logs/ALERTS.log"))"

# Recovery closes the loop: the stale box stamps fresh, the epilogue retracts.
record box-stale "$(ts_ago 1)"
tick
grep -q 'RESOLVED backupstale:box-stale' "$T/logs/ALERTS.log" \
  && ok || bad "B11: a backup that came back must write a RESOLVED line (got: $(cat "$T/logs/ALERTS.log"))"
record box-stale "$(ts_ago 45)"

# The threshold is a knob, with the code constant as its documented fallback.
: > "$T/logs/ALERTS.log"; echo '{}' > "$DEDUP"; : > "$ACTIVE"
( export BACKUP_STALE_MIN=60; tick )
# STRENGTHENED in round 1 (was `nlines 'backupstale:box-stale'`): the
# dedupe KEY never appears in the operator's ALERTS line, only in the beat and
# the TTL ledger, so that pattern matched nothing whatever the threshold did and
# the assertion could not fail. Same box, same direction, real text.
[ "$(nlines 'box-stale')" = 0 ] \
  && ok || bad "B12: BACKUP_STALE_MIN=60 must put the 45-minute box back under the line (got: $(cat "$T/logs/ALERTS.log"))"

# THE DB HOP IS THE ONE PRODUCTION RUNS. bin/pipeline-health.sh sources
# bin/jobs-client.sh, so in prod bf_stale_min resolves `setting_get
# backup_stale_min` FIRST and only then the env/code fallback. Nothing above
# exercises that branch — B12 passes identically if the setting_get hop is
# deleted — so it is pinned here with setting_get as a real command on PATH
# (the block's `command -v setting_get` finds it exactly as it finds the
# sourced function in prod).
sg() { printf '#!/bin/bash\nprintf %%s\\\\n %s\n' "$1" > "$T/bin/setting_get"; chmod +x "$T/bin/setting_get"; }
sg_off() { rm -f "$T/bin/setting_get"; }

: > "$T/logs/ALERTS.log"; echo '{}' > "$DEDUP"; : > "$ACTIVE"
sg 60; ( unset BACKUP_STALE_MIN; tick )
[ "$(nlines 'box-stale')" = 0 ] \
  && ok || bad "B13: a DB row of 60 must put the 45-minute box under the line with no env var set (got: $(cat "$T/logs/ALERTS.log"))"

# A DB value that is not a number is refused, not clamped: the documented
# fallback still pages at 30, so an operator typo cannot silently mute the fleet.
: > "$T/logs/ALERTS.log"; echo '{}' > "$DEDUP"; : > "$ACTIVE"
sg abc; ( unset BACKUP_STALE_MIN; tick )
[ "$(nlines 'box-stale')" = 1 ] \
  && ok || bad "B14: a non-numeric DB value must fall through to the 30-minute default and still page (got: $(cat "$T/logs/ALERTS.log"))"

# DB beats env, in the direction that can be told apart: env alone would be
# quiet at 90, the DB row at 20 pages.
: > "$T/logs/ALERTS.log"; echo '{}' > "$DEDUP"; : > "$ACTIVE"
sg 20; ( export BACKUP_STALE_MIN=90; tick )
[ "$(nlines 'box-stale')" = 1 ] \
  && ok || bad "B15: the DB row must win over BACKUP_STALE_MIN (got: $(cat "$T/logs/ALERTS.log"))"
sg_off

# ═══════════════════════════════════════════════════════════════════════════
# C. the ssh probe and its local twin say the same thing about one tree
# ═══════════════════════════════════════════════════════════════════════════
mkdir -p "$T/box/state" "$T/box/flags" "$T/box/env"
probe_raw() { # run the REAL remote probe against a fixture tree, as a box would
  ( cd "$1" && sh -c "$(bf_remote_probe | sed "s#/root/harness#$1#g")" )
}
# The hub finds the probe's answer by its BF tag, never by line number: the
# command it rides on emits a VARIABLE number of lines before it (`stat` on a
# missing log prints nothing at all, not even a newline), so a positional read
# silently attributes someone else's line to this lane — or, worse, reads
# nothing and writes no record for a box that answered. C9 below is that box.
probe_on() { probe_raw "$1" | awk -F'\t' '$1=="BF"{sub(/^[^\t]*\t/,"");print;exit}'; }
if command -v bf_remote_probe >/dev/null 2>&1 && command -v bf_facts_local >/dev/null 2>&1; then
  printf '{"ts":"%s","key":"k","bytes":1,"sha256":"a"}\n' "$(ts_ago 7)" > "$T/box/state/backup-last.json"
  probe_raw "$T/box" | grep -q "^BF$(printf '\t')" \
    && ok || bad "C0a: the probe line must be self-identifying (BF-tagged), not found by position (got: '$(probe_raw "$T/box")')"
  [ "$(probe_raw "$T/box" | awk -F'\t' '$1=="BF"{print NF}')" = 4 ] \
    && ok || bad "C0b: the tagged probe line must carry the tag plus the three facts (got: '$(probe_raw "$T/box")')"
  rm -f "$T/box/state/backup-last.json"
  # (i) a stamped box
  printf '{"ts":"%s","key":"k","bytes":1,"sha256":"a"}\n' "$(ts_ago 7)" > "$T/box/state/backup-last.json"
  [ "$(probe_on "$T/box")" = "$(bf_facts_local "$T/box")" ] \
    && ok || bad "C1: probe and local reader disagree on a stamped box: '$(probe_on "$T/box")' vs '$(bf_facts_local "$T/box")'"
  [ "$(probe_on "$T/box" | cut -f1)" = "$(ts_ago 7)" ] \
    && ok || bad "C2: the probe must return the marker's ts (got: '$(probe_on "$T/box")')"
  # (ii) unconfigured
  rm -f "$T/box/state/backup-last.json"; touch "$T/box/state/state-backup-unconfigured-20260920"
  [ "$(probe_on "$T/box")" = "$(bf_facts_local "$T/box")" ] \
    && ok || bad "C3: probe and local reader disagree on an unconfigured box: '$(probe_on "$T/box")' vs '$(bf_facts_local "$T/box")'"
  [ "$(probe_on "$T/box" | cut -f3)" = unconfigured ] \
    && ok || bad "C4: the probe must report the unconfigured marker (got: '$(probe_on "$T/box")')"
  # (iii) switched off
  rm -f "$T/box/state/state-backup-unconfigured-20260920"; touch "$T/box/flags/state-backup-off"
  [ "$(probe_on "$T/box")" = "$(bf_facts_local "$T/box")" ] \
    && ok || bad "C5: probe and local reader disagree on an off box: '$(probe_on "$T/box")' vs '$(bf_facts_local "$T/box")'"
  [ "$(probe_on "$T/box" | cut -f2)" = off ] \
    && ok || bad "C6: the probe must report the kill switch (got: '$(probe_on "$T/box")')"
  # (iv) nothing at all — three empty fields, never a missing line
  rm -f "$T/box/flags/state-backup-off"
  [ "$(probe_on "$T/box" | awk -F'\t' '{print NF}')" = 3 ] \
    && ok || bad "C7: the probe always emits three fields, so the hub can tell empty from unanswered (got: '$(probe_on "$T/box")')"

  # (v) THE LATCH. bin/state-backup.sh writes state-backup-unconfigured-<DAY>
  # once per UTC day while the BACKUP_* keys are unset. Every box in the fleet
  # has run unconfigured for days, so every box already carries those files. A
  # reader that accepts ANY of them can never leave `unconfigured` again: the
  # day the keys land, a box whose uploader fails its first upload still reads
  # "backup not configured" on the console, and `backupmissing` — one of the two
  # alerts this lane exists to fire — is dead for the whole fleet.
  #
  # So the marker is evidence only while it is CURRENT. state-backup.sh rewrites
  # it every unconfigured day at 5,20,35,50, so a marker that has not been
  # refreshed inside the window means the lane is no longer saying it.
  rm -f "$T/box/state/state-backup-unconfigured-"*
  touch "$T/box/state/state-backup-unconfigured-oldday"
  backdate "$T/box/state/state-backup-unconfigured-oldday" 4
  [ "$(probe_on "$T/box" | cut -f3)" = "" ] \
    && ok || bad "C10: a marker nothing has refreshed for days must not still read unconfigured (got: '$(probe_on "$T/box")')"
  [ "$(probe_on "$T/box")" = "$(bf_facts_local "$T/box")" ] \
    && ok || bad "C11: probe and local reader disagree on a stale marker: '$(probe_on "$T/box")' vs '$(bf_facts_local "$T/box")'"
  # The point of C10, end to end: keys set, uploader never stamped, only an old
  # marker left behind. This box MUST reach `missing`, which is what pages.
  [ "$(bf_state_age "$(bf_facts_local "$T/box")" "$NOW" | cut -f1)" = missing ] \
    && ok || bad "C12: a configured box that never stamped must reach missing (and page), not latch on an old marker (got: '$(bf_state_age "$(bf_facts_local "$T/box")" "$NOW")')"
  # ...and the lane that IS unconfigured today stays silent, exactly as before.
  touch "$T/box/state/state-backup-unconfigured-today"
  [ "$(bf_state_age "$(bf_facts_local "$T/box")" "$NOW" | cut -f1)" = unconfigured ] \
    && ok || bad "C13: a marker written today must still read unconfigured and never page (got: '$(bf_state_age "$(bf_facts_local "$T/box")" "$NOW")')"
  rm -f "$T/box/state/state-backup-unconfigured-"*
else
  bad "C0: bf_remote_probe / bf_facts_local are not defined"
fi

# ═══════════════════════════════════════════════════════════════════════════
# F. THE COLLECTOR (BH-1031): the box STATES it, the hub WRITES the record.
#
# This section replaces the two cases that used to drive bin/fleet-heartbeat.sh
# (C8: an unreachable box must not have its record overwritten; C9: a box that
# answered must GET a record even when an earlier line of the ssh command
# printed nothing). That script is deleted in state→DB slice 6 — it answered
# "can the HUB REACH the box", not "is the lane alive" — and with it went the
# only thing writing state/fleet-heartbeat/backup-<box>. Every reader below
# would have gone blind for nine boxes while every assertion about the READING
# stayed green, which is precisely the shape of failure this whole file exists
# to make impossible.
#
# So the fact reverses direction and the record stays identical:
#   bin/state-backup.sh     states this box's three facts on the way out of the
#                           tick that produced them (box_backup_set)
#   bin/backup-records-sync.sh (hub, */5) writes every box's answer into the
#                           same file, same three fields, dated from the report
#
# WHAT THE OLD CASES WERE REALLY PINNING SURVIVES, re-expressed against the new
# path: a box that did not answer keeps whatever it last said (F9 — a stale
# report is not written at all, so the record ages out rather than being
# refreshed with old facts), and a box that DID answer always gets a record with
# all three fields (F6/F7).
#
# THE MUTATIONS ARE THE POINT (F5, F13). Both halves are best-effort and fail
# silent by contract, so "it wrote a record" passes just as happily on a fixture
# that would have written one anyway. Each half is therefore also run with its
# one load-bearing call removed, and must then produce nothing.
# ═══════════════════════════════════════════════════════════════════════════

# ---- F1–F5: the box side ---------------------------------------------------
# A scratch box whose jobs-client is a RECORDER: every report lands as a TSV
# line, so "reported once, with these facts" is a countable artifact rather than
# log archaeology.
new_box() {
  local B; B=$(mktemp -d "$T/sbox-XXXXXX")
  mkdir -p "$B/bin/lib" "$B/logs" "$B/state" "$B/flags" "$B/env" "$B/locks" "$B/tmp" "$B/fakebin"
  cp "$DIR/bin/state-backup.sh" "$B/bin/" 2>/dev/null
  cp "$DIR/bin/lib/backup-freshness.sh" "$B/bin/lib/" 2>/dev/null
  cp "$DIR/bin/lib/env-path.sh" "$B/bin/lib/" 2>/dev/null || true
  printf 'sb-box\n' > "$B/state/box-id"
  cat > "$B/bin/report-rec.sh" <<REC
#!/bin/bash
printf '%s\t%s\t%s\t%s\n' "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$B/report.log"
REC
  chmod +x "$B/bin/report-rec.sh"
  printf '%s' "$B"
}
# run_box <box-dir> [script] — the REAL script, its own tree, the recorder as
# its client. Returns the script's exit status, which is itself under test: an
# EXIT trap whose last command became the status would turn every failed backup
# into a success.
run_box() {
  local B="$1" SC="${2:-$1/bin/state-backup.sh}"
  ( cd "$B" && PATH="$B/fakebin:$PATH" HARNESS="$B" HARNESS_ROOT="$B" \
      BF_PUSH_CMD="$B/bin/report-rec.sh" BACKUP_NOW="$NOW" \
      bash "$SC" >/dev/null 2>&1 )
}
rep_field() { cut -f"$2" "$1/report.log" 2>/dev/null | tail -1; }

# F1 — THE DELIBERATE OFF STATE STILL REPORTS. `off` exits at the kill switch,
# long before anything else in the script runs, and a box that reports nothing
# is read by the hub as a box that went quiet — so a lane somebody switched off
# on purpose would age out of the fleet view and look like a machine in trouble.
BOFF=$(new_box)
: > "$BOFF/flags/state-backup-off"
printf '{"ts":"%s"}\n' "$(ts_ago 7)" > "$BOFF/state/backup-last.json"
run_box "$BOFF"; RCOFF=$?
[ -s "$BOFF/report.log" ] \
  && ok || bad "F1: a box switched off must still report its state (no report written)"
[ "$(rep_field "$BOFF" 1)" = box-backup-set ] \
  && ok || bad "F1b: the report must use the box-backup-set verb (got: '$(rep_field "$BOFF" 1)')"
[ "$(rep_field "$BOFF" 3)" = off ] \
  && ok || bad "F1c: the off switch must reach the hub as off (got: '$(rep_field "$BOFF" 3)')"
[ "$RCOFF" = 0 ] \
  && ok || bad "F1d: the report must not change the script's exit status (off path returned $RCOFF, expected 0)"

# F2 — THE TIMESTAMP IS THE ONE ON DISK AT EXIT, not the one that was there when
# the tick started. That is the whole reason the report lives in this script and
# not on a cron of its own: backups run every 15 minutes against a 30-minute
# stale threshold, so a reporter publishing the PREVIOUS run's stamp would sit
# on the threshold and flap.
[ "$(rep_field "$BOFF" 2)" = "$(ts_ago 7)" ] \
  && ok || bad "F2: the report must carry the stamp currently on disk (got: '$(rep_field "$BOFF" 2)', want '$(ts_ago 7)')"

# F3 — THE UNCONFIGURED STATE REPORTS, AND THE EXIT STATUS SURVIVES IT. The
# BACKUP_* keys are a handoff; the script says so once per UTC day and exits 1.
# The hub has a state for that which never pages — but only if it hears it.
BUNC=$(new_box)
run_box "$BUNC"; RCUNC=$?
[ "$(rep_field "$BUNC" 4)" = unconfigured ] \
  && ok || bad "F3: an unconfigured box must report unconfigured (got: '$(rep_field "$BUNC" 4)')"
[ "$RCUNC" = 1 ] \
  && ok || bad "F3b: the EXIT trap must preserve a failing status (unconfigured path returned $RCUNC, expected 1)"

# F4 — THE SECOND TRAP DID NOT SWALLOW THE FIRST. The staging block installs its
# own `trap ... EXIT`, which REPLACES the earlier one; if it did not also
# report, every configured box — i.e. every healthy box in the fleet — would go
# silent while the two states nobody needs to hear about kept reporting. Driven
# past the config gate with stub tools, then failed at the encrypt step, which
# is the first exit AFTER that second trap is installed.
BLATE=$(new_box)
for _C in zstd fakeaws; do printf '#!/bin/bash\nexit 0\n' > "$BLATE/fakebin/$_C"; done
printf '#!/bin/bash\nexit 1\n' > "$BLATE/fakebin/age"
chmod +x "$BLATE/fakebin"/*
printf '{"ts":"%s"}\n' "$(ts_ago 3)" > "$BLATE/state/backup-last.json"
cat > "$BLATE/env/global.env" <<'ENVV'
BACKUP_S3_ENDPOINT=https://example.invalid
BACKUP_S3_ACCESS_KEY_ID=k
BACKUP_S3_SECRET_ACCESS_KEY=s
BACKUP_AGE_RECIPIENT=age1test
BACKUP_S3_CLIENT=fakeaws
ENVV
run_box "$BLATE"; RCLATE=$?
[ -s "$BLATE/report.log" ] \
  && ok || bad "F4: a box that got past the config gate must still report — the staging trap replaced the first one and dropped it"
[ "$(rep_field "$BLATE" 2)" = "$(ts_ago 3)" ] \
  && ok || bad "F4b: the late path must report the stamp on disk (got: '$(rep_field "$BLATE" 2)')"
[ "$RCLATE" = 1 ] \
  && ok || bad "F4c: a failed encrypt must still exit 1 through the trap (got $RCLATE)"

# F5 — THE MUTATION. Every assertion above is satisfied by a script that reports
# for some other reason; none of them is satisfied by one that does not report
# at all. With the report stripped out of both traps and nothing else changed,
# the same fixture must produce nothing.
BMUT=$(new_box)
: > "$BMUT/flags/state-backup-off"
printf '{"ts":"%s"}\n' "$(ts_ago 7)" > "$BMUT/state/backup-last.json"
[ "$(grep -c 'bf_push' "$BMUT/bin/state-backup.sh" 2>/dev/null)" -ge 3 ] \
  && ok || bad "F5a: the shipped script must call the report from both traps and define it — nothing to mutate (found $(grep -c 'bf_push' "$BMUT/bin/state-backup.sh" 2>/dev/null))"
sed 's/BF_RC=\$?; bf_push; exit/BF_RC=$?; : ; exit/; s/BF_RC=\$?; cleanup; bf_push; exit/BF_RC=$?; cleanup; exit/' \
  "$BMUT/bin/state-backup.sh" > "$BMUT/bin/state-backup-mut.sh"
[ "$(grep -c 'bf_push' "$BMUT/bin/state-backup-mut.sh" 2>/dev/null)" = 1 ] \
  && ok || bad "F5b: the mutation must leave only the definition behind — the case below proves nothing (found $(grep -c 'bf_push' "$BMUT/bin/state-backup-mut.sh" 2>/dev/null))" 
run_box "$BMUT" "$BMUT/bin/state-backup-mut.sh"
[ ! -s "$BMUT/report.log" ] \
  && ok || bad "F5: with the report call removed the box must report nothing (got: '$(cat "$BMUT/report.log" 2>/dev/null)')"

# ---- F6–F13: the hub side --------------------------------------------------
# A scratch hub whose ledger is a file: bin/backup-records-sync.sh sources its
# client and calls box_backups, so a fake that defines that one function is the
# whole worker.
iso_ago() { date -u -d "@$(( NOW - $1 * 60 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
         || date -u -r "$(( NOW - $1 * 60 ))" +%Y-%m-%dT%H:%M:%SZ; }
new_hub() {
  local Hb; Hb=$(mktemp -d "$T/hbx-XXXXXX")
  mkdir -p "$Hb/bin/lib" "$Hb/logs" "$Hb/state/fleet-heartbeat" "$Hb/env"
  cp "$DIR/bin/backup-records-sync.sh" "$Hb/bin/" 2>/dev/null
  cp "$DIR/bin/lib/backup-freshness.sh" "$Hb/bin/lib/" 2>/dev/null
  cp "$DIR/bin/lib/env-path.sh" "$Hb/bin/lib/" 2>/dev/null || true
  printf 'box-hub\n' > "$Hb/state/box-name"
  : > "$Hb/rows.tsv"
  cat > "$Hb/bin/fake-client.sh" <<FAKE
#!/bin/bash
box_backups() { cat "$Hb/rows.tsv" 2>/dev/null; }
FAKE
  printf '%s' "$Hb"
}
hub_row() { printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" >> "$1/rows.tsv"; }
run_hub() {
  local Hb="$1" CLI="${2:-$1/bin/fake-client.sh}"
  ( HARNESS="$Hb" BACKUP_SYNC_CLIENT="$CLI" BACKUP_SYNC_NOW="$NOW" HUB_BOX_NAME=box-hub \
      bash "$Hb/bin/backup-records-sync.sh" >/dev/null 2>&1 )
}
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

HUB1=$(new_hub)
hub_row "$HUB1" box-alpha "$(ts_ago 9)" "" "" "$(iso_ago 3)"
hub_row "$HUB1" box-beta  "" "" unconfigured "$(iso_ago 2)"
hub_row "$HUB1" box-hub   "$(ts_ago 1)" "" "" "$(iso_ago 1)"
run_hub "$HUB1"

# F6 — A BOX THAT ANSWERED GETS A RECORD, with all three fields. This is C9's
# claim, re-homed: the failure it pinned was a box answering in full and having
# nothing stored for it, and the shape of the record is what makes "answered,
# nothing stamped" distinguishable from "no answer at all".
R1="$HUB1/state/fleet-heartbeat/backup-box-alpha"
[ -s "$R1" ] \
  && ok || bad "F6: a box with a current report got no record at all"
[ "$(awk -F'\t' '{print NF; exit}' "$R1" 2>/dev/null)" = 3 ] \
  && ok || bad "F6b: the record must always carry three fields (got: '$(cat "$R1" 2>/dev/null)')"
[ "$(cut -f1 "$R1" 2>/dev/null)" = "$(ts_ago 9)" ] \
  && ok || bad "F6c: the record must hold the reported ts (got: '$(cat "$R1" 2>/dev/null)')"
R2="$HUB1/state/fleet-heartbeat/backup-box-beta"
[ "$(cut -f3 "$R2" 2>/dev/null)" = unconfigured ] \
  && ok || bad "F6d: an empty ts with a marker must survive the trip as three fields (got: '$(cat "$R2" 2>/dev/null)')"

# F7 — THE READER AGREES. The record is only worth writing if bf_rows reads it,
# so the chain is closed here rather than asserted about in prose.
printf 'alpha-os\t-\t-\t-\t-\tbox-alpha\n' > "$HUB1/fleet.conf"
printf 'beta-os\t-\t-\t-\t-\tbox-beta\n'  >> "$HUB1/fleet.conf"
HROWS=$( ( export HUB_BOX_NAME=box-hub FLEET_CONF="$HUB1/fleet.conf"; bf_rows "$HUB1" "$NOW" ) )
[ "$(printf '%s\n' "$HROWS" | awk -F'\t' '$1=="box-alpha"{print $2}')" = ok ] \
  && ok || bad "F7: bf_rows must read the synced record as a real answer (rows: '$(printf '%s' "$HROWS" | tr '\n' '|')')"
[ "$(printf '%s\n' "$HROWS" | awk -F'\t' '$1=="box-beta"{print $2}')" = unconfigured ] \
  && ok || bad "F7b: bf_rows must read the synced marker as unconfigured (rows: '$(printf '%s' "$HROWS" | tr '\n' '|')')"

# F8 — THE MTIME IS THE MOMENT THE BOX SPOKE, not the moment this lane ran.
# bf_rows dates every record by its mtime and drops one older than
# BF_RECORD_FRESH_MIN; a lane stamping its own clock would re-date a stale box's
# facts every five minutes, so the record could never age out and an outage
# would page hourly with a frozen ts — the 2026-08 box-project-1-1 shape.
MT=$(mtime_of "$R1"); EXP=$(( NOW - 3 * 60 ))
[ -n "${MT:-}" ] && [ "$(( MT > EXP - 90 && MT < EXP + 90 ? 1 : 0 ))" = 1 ] \
  && ok || bad "F8: the record must be dated from the report ($MT, expected ~$EXP)"

# F9 — A STALE REPORT IS NOT WRITTEN AT ALL. This is C8's claim, re-homed: a box
# that stopped answering keeps whatever it last said, and — the other half of
# that promise — the kept record must then stop ageing. Rewriting it would hand
# bf_rows a fresh-looking file full of old facts.
HUB2=$(new_hub)
printf 'SEEDED\tx\ty\n' > "$HUB2/state/fleet-heartbeat/backup-box-gone"
touch -d "@$(( NOW - 7200 ))" "$HUB2/state/fleet-heartbeat/backup-box-gone" 2>/dev/null \
  || touch -t "$(date -u -d "@$(( NOW - 7200 ))" +%Y%m%d%H%M.%S 2>/dev/null)" "$HUB2/state/fleet-heartbeat/backup-box-gone" 2>/dev/null
hub_row "$HUB2" box-gone "$(ts_ago 400)" "" "" "$(iso_ago 300)"
run_hub "$HUB2"
[ "$(cut -f1 "$HUB2/state/fleet-heartbeat/backup-box-gone" 2>/dev/null)" = SEEDED ] \
  && ok || bad "F9: a report older than the collection window must not overwrite the record (got: '$(cat "$HUB2/state/fleet-heartbeat/backup-box-gone" 2>/dev/null)')"
[ "$(mtime_of "$HUB2/state/fleet-heartbeat/backup-box-gone")" -lt "$(( NOW - 3600 ))" ] \
  && ok || bad "F9b: a stale report must not refresh the record's mtime — it must be allowed to age out"

# F10 — A LEFTOVER unreachable-<box> MARKER IS CLEARED. bin/fleet-heartbeat.sh
# wrote that marker and removed it when a box answered again; nothing writes it
# any more, so one left behind on the live hub would drop its box from bf_rows
# for ever with nothing able to retract it.
HUB3=$(new_hub)
printf '%s\n' "$(( NOW - 9000 ))" > "$HUB3/state/fleet-heartbeat/unreachable-box-back"
hub_row "$HUB3" box-back "$(ts_ago 6)" "" "" "$(iso_ago 2)"
run_hub "$HUB3"
[ ! -e "$HUB3/state/fleet-heartbeat/unreachable-box-back" ] \
  && ok || bad "F10: a box that answered must have its stale unreachable marker cleared"

# F11 — THE HUB DOES NOT RECORD ITSELF. bf_rows reads the hub's own row straight
# off local disk every tick; a record of the same name would be the same box
# twice, once through a stale copy.
[ ! -e "$HUB1/state/fleet-heartbeat/backup-box-hub" ] \
  && ok || bad "F11: the hub must not write a heartbeat record about itself"

# F12 — FAIL-OPEN. No client at all: nothing is written and nothing existing is
# touched, so every record ages out on its own exactly as an ssh outage used to
# make it. A reader that cannot run must never be the reason the hub does less.
HUB4=$(new_hub)
printf 'KEPT\tx\ty\n' > "$HUB4/state/fleet-heartbeat/backup-box-keep"
touch -d "@$(( NOW - 600 ))" "$HUB4/state/fleet-heartbeat/backup-box-keep" 2>/dev/null || true
hub_row "$HUB4" box-keep "$(ts_ago 5)" "" "" "$(iso_ago 1)"
run_hub "$HUB4" "$HUB4/bin/no-such-client.sh"; RCH=$?
[ "$RCH" = 0 ] \
  && ok || bad "F12: a missing client must not fail the lane (got $RCH)"
[ "$(cut -f1 "$HUB4/state/fleet-heartbeat/backup-box-keep" 2>/dev/null)" = KEPT ] \
  && ok || bad "F12b: a lane that cannot read must not touch the records it cannot refresh"

# F13 — THE MUTATION, hub side. A report with no collection time cannot be
# dated, and an undatable record is one that can never age out; it must be
# dropped rather than defaulted. This is also what keeps F6 honest: the writer
# really is gated on the report, not writing a file for every row it sees.
# This case is dated by the wall clock (NOW), so it only ever exercised the
# defect BH-1308 found — `date -u -d ""` is today's midnight, so the row looked
# current for the 35 minutes after 00:00Z and F13 failed there and nowhere else.
# tests/backup-freshness.bh-1308-test.sh pins that window with the clock held.
HUB5=$(new_hub)
hub_row "$HUB5" box-nodate "$(ts_ago 5)" "" "" ""
run_hub "$HUB5"
[ ! -e "$HUB5/state/fleet-heartbeat/backup-box-nodate" ] \
  && ok || bad "F13: a row with no collection time must produce no record (got: '$(cat "$HUB5/state/fleet-heartbeat/backup-box-nodate" 2>/dev/null)')"

# ═══════════════════════════════════════════════════════════════════════════
# E. A RECORD THE HEARTBEAT IS NO LONGER REFRESHING IS NOT AN ANSWER.
#
# C8 pins the half that was already right: an unreachable box keeps whatever it
# last said, because inventing `missing` out of a failed ssh pages twice for one
# fault. The other half is this one — the kept record must then STOP AGEING. The
# hub reads these files every 10 minutes; a frozen `ts` read as if the box had
# just answered turns every ssh outage longer than the threshold into an hourly
# `backupstale` page whose text ("uploads are failing, not just slow") is false:
# the box is very likely still uploading, the hub simply cannot see it.
# box-project-1-1 was off the tailnet for 2+ days in 2026-08 with its own
# cron running fine — that is ~48 false pages on the channel this lane says must
# not be muted, and bin/fleet-heartbeat.sh skips its own watcher-stale check for
# exactly this reason.
#
# Three shapes, one root cause, one rule: a record counts only while it is
# CURRENT and only for a box fleet.conf still names.
#   E1 the hub could not reach the box (mtime frozen, the general case — it also
#      covers the heartbeat lane itself dying, which freezes EVERY record)
#   E2 a retired box's leftover file (bin/fleet-slo.sh SLO 4 measured two of
#      these on the hub on 2026-09-15; unfiltered they page forever, and a
#      machine that does not exist can never retract)
#   E3 the heartbeat's own unreachable-<box> marker, said out loud
# The hub's own row is read off local disk and is never bounded by any of this.
# ═══════════════════════════════════════════════════════════════════════════
rows() { ( export HUB_BOX_NAME=box-hub; bf_rows "$T" "$NOW" ); }
# DRAIN, THEN SELECT (BH-1308). `rows | awk '...{print;exit}'` closes the pipe
# on the first match while bf_rows is still printing later boxes; on an awk that
# exits promptly, and a runner with SIGPIPE ignored, every remaining printf
# reports `bin/lib/backup-freshness.sh: line 269: printf: write error: Broken
# pipe`. It changed no assertion here and the two production callers capture
# with $( ), but it is noise on top of a suite that was already being read as
# flaky. Reading into a variable first drains bf_rows completely before the
# selector can exit.
rowfor() { local all; all=$(rows); printf '%s\n' "$all" | awk -F'\t' -v b="$1" '$1==b{print;exit}'; }

# The control, first: without it every "must produce no row" below would pass on
# a bf_rows that returned nothing at all.
[ -n "$(rowfor box-stale)" ] \
  && ok || bad "E0: a box fleet.conf names, with a record the heartbeat just wrote, must still produce a row (got: '$(rows | tr '\n' '|')')"

# E1 — reachable 3h ago, stamp was 5 minutes old THEN. Nothing has refreshed it
# since, so the hub knows nothing about this box's backups now.
record box-frozen "$(ts_ago 5)"
backdate_min "$T/state/fleet-heartbeat/backup-box-frozen" 180
[ -z "$(rowfor box-frozen)" ] \
  && ok || bad "E1: a record nothing has refreshed for 3h must produce NO row — its ts is a memory, not a reading (got: '$(rowfor box-frozen)')"

# E2 — a box rotation (project-3 → project-3-2 was one) leaves the old file behind
# forever. fleet.conf does not name it, so it is not a box.
record box-retired "$(ts_ago 45)"
[ -z "$(rowfor box-retired)" ] \
  && ok || bad "E2: a backup record for a box fleet.conf does not name is a ghost and must produce NO row (got: '$(rowfor box-retired)')"

# E3 — the heartbeat says, in its own file, that it could not reach this box on
# the last hop. The record is fresh on disk only because C8 keeps it.
record box-offnet "$(ts_ago 45)"
touch "$T/state/fleet-heartbeat/unreachable-box-offnet"
[ -z "$(rowfor box-offnet)" ] \
  && ok || bad "E3: a box the heartbeat has marked unreachable must produce NO row — its UNREACHABLE alert already owns that fault (got: '$(rowfor box-offnet)')"

# The hub backs ITSELF up and reads its own disk every tick, so no collection
# window applies to it. #388 IS the hub: this row must never be filtered away.
[ "$(rowfor box-hub | cut -f2)" = ok ] \
  && ok || bad "E4: the hub's own row is read off local disk and must never be dropped by a record-freshness rule (got: '$(rowfor box-hub)')"

# End to end, through the REAL alert() — the artifacts, not the intention.
: > "$T/logs/ALERTS.log"; echo '{}' > "$DEDUP"; : > "$ACTIVE"
tick
[ "$(nlines 'box-frozen')" = 0 ] \
  && ok || bad "E5: an ssh outage must not page backupstale hourly with 'uploads are failing' (got: $(cat "$T/logs/ALERTS.log"))"
[ "$(nlines 'box-retired')" = 0 ] \
  && ok || bad "E6: a retired box's leftover record must not page forever (got: $(cat "$T/logs/ALERTS.log"))"
[ "$(nlines 'box-offnet')" = 0 ] \
  && ok || bad "E7: an unreachable box must not page a second time for one fault (got: $(cat "$T/logs/ALERTS.log"))"
[ "$(nlines 'box-stale')" = 1 ] \
  && ok || bad "E8: the tick must still page the box that IS behind — the filters must not silence the lane (got: $(cat "$T/logs/ALERTS.log"))"

# ...and the console half: absent means not pushed, so a frozen or ghost record
# must not render a tile line either.
push
[ "$(q '.backups | has("box-frozen")')" = false ] \
  && ok || bad "E9: a frozen record must not be pushed as a reading (got: $(q '.backups|tojson'))"
[ "$(q '.backups | has("box-retired")')" = false ] \
  && ok || bad "E10: a ghost box must not appear in the snapshot (got: $(q '.backups|tojson'))"
[ "$(q '.backups | has("box-offnet")')" = false ] \
  && ok || bad "E11: an unreachable box must not appear in the snapshot (got: $(q '.backups|tojson'))"
[ "$(q '.backups."box-fresh".backup_age_min')" = 5 ] \
  && ok || bad "E12: the boxes that ARE reporting must survive the filters (got: $(q '.backups|tojson'))"

echo "backup-freshness-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
