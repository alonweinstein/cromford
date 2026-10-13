#!/bin/bash
# tests/lane-switch-readers-backup.bh-2438-test.sh — BH-2438 (BH-2410.2): the
# backup and vendor-spend kill switches are read through lane_switch
# (bin/lib/lane-switch.sh), so a settings row settles them before the file.
#
#   L6   bin/lib/backup-freshness.sh bf_facts_local: field 2 answers the
#        state-backup-off switch through the fixture's three cases
#   S1   the REAL bin/state-backup.sh: a row turns it off (`off: switch
#        state-backup-off`, rc 0) before the config check; a row of 0 beats
#        the file and the run reaches `not configured`
#   S2   the REAL bin/vendor-spend-pull.sh --vendor openrouter --dry-run: a row
#        turns it off before any curl; a row of 0 beats the file and curl runs
#   L7a  with no bin/lib/lane-switch.sh in the tree the loader's fallback keeps
#        the file's meaning: file present stops each reader, no file does not
#   L7b  sourcing backup-freshness.sh defines no lane_switch (the loader sits
#        inside bf_facts_local)
#   L7c  a junk-valued row, or another box's row, does not turn a switch on
#   D1   reverting any one of the three reads to its bare `[ -f ]` makes that
#        reader's case (ii) red and leaves the other two green
# Run from anywhere: tests/lane-switch-readers-backup.bh-2438-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/lane-switch-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

READERS="bin/lib/backup-freshness.sh bin/lib/env-path.sh bin/lib/endpoints.sh bin/state-backup.sh bin/vendor-spend-pull.sh"
SRC="$DIR"

# The fake curl: logs every URL, answers 404 with an empty body.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -H|-w|-m|--connect-timeout) shift 2 ;;
    -*) shift ;;
    *) URL="$1"; shift ;;
  esac
done
printf '%s\n' "$URL" >> "$CURL_LOG"
[ -n "$OUT" ] && : > "$OUT"
printf 404
SH
chmod +x "$T/fakebin/curl"
CURL_LOG="$T/curl.log"

# setup [root] — the scratch harness with every reader this suite drives, and an
# env dir of its own so nothing falls through to /etc/harness/env.
setup() {
  local keep="$DIR"
  DIR="${1:-$SRC}"
  lsf_setup $READERS || { DIR="$keep"; bad "lsf_setup failed from $DIR"; return 1; }
  DIR="$keep"
  mkdir -p "$H/env"
  printf 'OPENROUTER_API_KEY=sk-or-v1-FIXTUREKEYNOTREAL2438\n' > "$H/env/global.env"
}

# Probes — each runs inside _lsf_probe's subshell (HARNESS=$H exported).
probe_bf() {
  export HARNESS_ENV_DIR="$H/env"
  . "$H/bin/lib/backup-freshness.sh" || { echo no-lib; return; }
  bf_facts_local "$H" | cut -f2
}
probe_sb() {
  local rc log="$H/logs/state-backup.log"
  rm -f "$log"
  unset HARNESS_ROOT STATE_BACKUP BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID \
        BACKUP_S3_SECRET_ACCESS_KEY BACKUP_AGE_RECIPIENT
  HARNESS_ENV_DIR="$H/env" BACKUP_NOW=1789514400 bash "$H/bin/state-backup.sh" >/dev/null 2>&1
  rc=$?
  if grep -q 'off: switch state-backup-off' "$log" 2>/dev/null; then
    if [ "$rc" = 0 ] && ! grep -q 'not configured' "$log"; then echo off; else echo "off-rc$rc"; fi
  elif grep -q 'not configured' "$log" 2>/dev/null; then echo run
  else echo "other-rc$rc"
  fi
}
# probe_sb_src — the source state-backup.sh names in its off line.
probe_sb_src() {
  probe_sb >/dev/null
  sed -n 's/.*off: switch state-backup-off (\([^)]*\)).*/\1/p' "$H/logs/state-backup.log" 2>/dev/null
}
probe_vs() {
  : > "$CURL_LOG"
  unset VENDOR_SPEND VENDOR_SKIP
  CURL_LOG="$CURL_LOG" PATH="$T/fakebin:$PATH" HARNESS_ENV_DIR="$H/env" \
    ENDPOINT_OPENROUTER=https://openrouter.ai ENDPOINT_OPENAI=https://api.openai.com \
    ENDPOINT_FLY_MACHINES=https://api.machines.dev \
    bash "$H/bin/vendor-spend-pull.sh" --vendor openrouter --dry-run >/dev/null 2>&1
  if [ -s "$CURL_LOG" ]; then echo called; else echo quiet; fi
}

# case_ii <name> <probe> — row 0 plus the file, the case a bare read gets wrong.
case_ii() { lsf_reset; lsf_row "$1" 0; lsf_flag "$1"; _lsf_probe "$2"; }

setup || { echo "lane-switch-readers-backup: $PASS passed, $FAIL failed"; exit 1; }

# ── L6 / S1 / S2 — the three standard cases on each reader ───────────────────
lsf_cases state-backup-off probe_bf off "" && ok || bad "L6 bf_facts_local state-backup-off"
lsf_cases state-backup-off probe_sb off run && ok || bad "S1 bin/state-backup.sh state-backup-off"
lsf_cases vendor-spend-off probe_vs quiet called && ok || bad "S2 bin/vendor-spend-pull.sh vendor-spend-off"

lsf_reset; lsf_row state-backup-off 1
eq "S1 off line names the fleet row" "$(_lsf_probe probe_sb_src)" fleet-row
lsf_reset; lsf_flag state-backup-off
eq "S1 off line names the file (legacy-file, BH-2412)" "$(_lsf_probe probe_sb_src)" legacy-file

# No row, no file: every reader proceeds (the ordinary box).
lsf_reset
eq "L6 no row, no file" "$(_lsf_probe probe_bf)" ""
eq "S1 no row, no file" "$(_lsf_probe probe_sb)" run
eq "S2 no row, no file" "$(_lsf_probe probe_vs)" called

# The box row beats the fleet row.
lsf_reset; lsf_row state-backup-off 0; lsf_row state-backup-off 1 hub-1
eq "S1 box row 1 over fleet row 0" "$(_lsf_probe probe_sb)" off
lsf_reset; lsf_row vendor-spend-off 1; lsf_row vendor-spend-off 0 hub-1
eq "S2 box row 0 over fleet row 1" "$(_lsf_probe probe_vs)" called

# ── L7c — a junk row or another box's row is not ON ──────────────────────────
lsf_reset; lsf_row state-backup-off maybe
eq "L7c bf junk row, no file" "$(_lsf_probe probe_bf)" ""
lsf_reset; lsf_row state-backup-off 1 hub-2
eq "L7c bf other box's row, no file" "$(_lsf_probe probe_bf)" ""
lsf_reset; lsf_row vendor-spend-off maybe
eq "L7c vs junk row, no file" "$(_lsf_probe probe_vs)" called
lsf_reset; lsf_row vendor-spend-off 1 hub-2
eq "L7c vs other box's row, no file" "$(_lsf_probe probe_vs)" called

# ── L7b — sourcing the lib defines no lane_switch ────────────────────────────
env -i PATH="$PATH" HARNESS="$H" bash -c '. "$1"; command -v lane_switch' _ "$DIR/bin/lib/backup-freshness.sh" >/dev/null 2>&1
eq "L7b sourcing backup-freshness.sh defines lane_switch" "$?" 1

# ── L7a — no lane-switch.sh in the tree: the fallback reads the file ─────────
rm -f "$H/bin/lib/lane-switch.sh"
lsf_reset; lsf_flag state-backup-off
eq "L7a bf no lib, file" "$(_lsf_probe probe_bf)" off
eq "L7a sb no lib, file" "$(_lsf_probe probe_sb)" off
eq "L7a sb no lib, off line names legacy" "$(_lsf_probe probe_sb_src)" legacy
lsf_reset; lsf_flag vendor-spend-off
eq "L7a vs no lib, file" "$(_lsf_probe probe_vs)" quiet
lsf_reset
eq "L7a bf no lib, no file" "$(_lsf_probe probe_bf)" ""
eq "L7a sb no lib, no file" "$(_lsf_probe probe_sb)" run
eq "L7a vs no lib, no file" "$(_lsf_probe probe_vs)" called
# A row cannot be read without the lib: it is ignored, the file still decides.
lsf_reset; lsf_row state-backup-off 1
eq "L7a sb no lib, row 1 and no file" "$(_lsf_probe probe_sb)" run

# ── D1 — revert one read at a time; exactly its case (ii) goes red ───────────
# mutate <file> <converted text> <bare text>
mutate() {
  local m="$T/mut"
  scratch_rm "$m"; mkdir -p "$m"
  cp -r "$DIR/bin" "$DIR/catalog" "$m/" || return 1
  grep -qF "$2" "$m/$1" || { bad "D1 $1: converted text '$2' not found, nothing to revert"; return 1; }
  M_FROM="$2" M_TO="$3" perl -0pi -e 's/\Q$ENV{M_FROM}\E/$ENV{M_TO}/' "$m/$1"
  grep -qF "$2" "$m/$1" && { bad "D1 $1: revert did not apply"; return 1; }
  setup "$m"
}
d1() { # d1 <label> <file> <from> <to> <expected bf> <expected sb> <expected vs>
  mutate "$2" "$3" "$4" || return
  eq "D1 $1: bf case (ii)" "$(case_ii state-backup-off probe_bf)" "$5"
  eq "D1 $1: sb case (ii)" "$(case_ii state-backup-off probe_sb)" "$6"
  eq "D1 $1: vs case (ii)" "$(case_ii vendor-spend-off probe_vs)" "$7"
}
d1 "backup-freshness reverted" bin/lib/backup-freshness.sh \
   'HARNESS="$h" lane_switch state-backup-off' '[ -f "$h/flags/state-backup-off" ]' off run called
d1 "state-backup reverted" bin/state-backup.sh \
   'HARNESS="$H" lane_switch state-backup-off' '[ -f "$H/flags/state-backup-off" ]' "" off called
d1 "vendor-spend-pull reverted" bin/vendor-spend-pull.sh \
   'HARNESS="$H" lane_switch vendor-spend-off' '[ -f "$H/flags/vendor-spend-off" ]' "" run quiet

echo "lane-switch-readers-backup: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
