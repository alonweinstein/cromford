#!/bin/bash
# tests/box-disk-alert.bh-4440-test.sh — BH-4440: the root-disk alert is ONE
# stable-id row per box that resolves when space recovers, and its text names
# the top 5 directories by size.
#
# What is proved here, driving the REAL bin/disk-guard.sh through the REAL
# bin/lane-alert.sh and bin/lib/alert-state.sh in a scratch harness (a fake df
# and du first on PATH, a fake curl so nothing leaves the box):
#   §1  df at 90%: exactly one state/alerts/disk-high-<host>.json, one ALERTS
#       line naming the id's text;
#   §2  a second run at 90%: still one state file and one ALERTS line (the
#       repeat is counted, not re-sent);
#   §3  df at 70%: the condition is resolved, with one RESOLVED line;
#   §4  the text carries the 5 largest depth-2 dirs in descending size and not
#       / or /root; a second firing inside DISK_TOP_DIRS_TTL_MIN does not run du
#       again; a du that outlives DISK_TOP_DIRS_TIMEOUT_S gives "unavailable".
# Run from anywhere: tests/box-disk-alert.bh-4440-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset DISK_ALERT_PCT DISK_BUILD_REFUSE_PCT DISK_TOP_DIRS_TTL_MIN DISK_TOP_DIRS_TIMEOUT_S 2>/dev/null || true
HOST=$(hostname)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$T/stub"
for s in beat.sh lane-alert.sh alert-digest.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
for l in alert-state.sh env-path.sh disk-guard.sh; do ln -sf "$DIR/bin/lib/$l" "$H/bin/lib/$l"; done
touch "$H/flags/alert-quarantine-disabled" "$H/flags/remediation-disabled"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\n' > "$H/env/global.env"
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
echo '{"ok":true}'
SH
cat > "$T/stub/df" <<'SH'
#!/bin/bash
printf 'Filesystem     1024-blocks     Used Available Capacity Mounted on\n/dev/root 41152736 30000000 2097152 %s%% /\n' "${FAKE_DF_PCT:-50}"
SH
# du -xk -d 2 /: seven depth-2 dirs, plus the depth-0 and depth-1 totals that
# must never be named. Every call is counted.
cat > "$T/stub/du" <<SH
#!/bin/bash
echo call >> "$T/du.calls"
[ -n "\${FAKE_DU_SLEEP:-}" ] && sleep "\$FAKE_DU_SLEEP"
printf '%s\t%s\n' 1000 /var/log 9000000 /root/.grok 300 /etc/ssl 4000000 /root/repos \\
  2500000 /usr/lib 52000000 /root 70000000 / 6000000 /var/lib 100 /opt/x
SH
chmod +x "$T/stub/"*

guard() { # guard [env...] — one tick of the shipped lane
  env PATH="$T/stub:$PATH" HARNESS="$H" HOME="$T" "$@" bash "$DIR/bin/disk-guard.sh" >/dev/null 2>&1
}
alerts_for() { grep -c "disk-high\|disk / on $HOST" "$H/logs/ALERTS.log" 2>/dev/null || echo 0; }
SF="$H/state/alerts/disk-high-$HOST.json"
ducalls() { [ -f "$T/du.calls" ] && wc -l < "$T/du.calls" | tr -d ' ' || echo 0; }

# ══ 1. fire once ═════════════════════════════════════════════════════════════
guard FAKE_DF_PCT=90; RC=$?
[ "$RC" = 0 ] && ok || bad "1 rc 0 (rc=$RC)"
[ "$(find "$H/state/alerts" -name 'disk-high-*.json' | wc -l)" = 1 ] && [ -s "$SF" ] && ok \
  || bad "1 exactly one state/alerts/disk-high-$HOST.json ($(ls "$H/state/alerts" 2>/dev/null))"
[ "$(alerts_for)" = 1 ] && ok || bad "1 one ALERTS.log line for the condition (got $(alerts_for): $(cat "$H/logs/ALERTS.log"))"

# ══ 2. a repeat is counted, not re-sent ══════════════════════════════════════
guard FAKE_DF_PCT=90
[ "$(find "$H/state/alerts" -name 'disk-high-*.json' | wc -l)" = 1 ] && ok || bad "2 still exactly one disk-high state file"
[ "$(alerts_for)" = 1 ] && ok || bad "2 still one ALERTS.log line after a second run (got $(alerts_for))"
[ "$(jq -r .count "$SF")" = 2 ] && ok || bad "2 the repeat is counted on the one row (count=$(jq -r .count "$SF"))"

# ══ 4a. the text: the 5 largest depth-2 dirs, in order (read off the row) ═════
LINE=$(jq -r .line "$SF")
case "$LINE" in
  *"top dirs: /root/.grok 8.6G, /var/lib 5.7G, /root/repos 3.8G, /usr/lib 2.4G, /var/log 1000K"*) ok ;;
  *) bad "4 the alert text must name the 5 largest depth-2 dirs in size order (got '$LINE')" ;;
esac
TOPS=""; case "$LINE" in *"top dirs: "*) TOPS="${LINE#*top dirs: }" ;; esac
case "$TOPS" in ''|*"/etc/ssl"*|*"/opt/x"*|"/ "*|*", / "*|"/root "*|*", /root "*) bad "4 the top-dirs list must exist and name nothing outside the top 5 or a depth-0/1 total ('$TOPS')" ;; *) ok ;; esac
[ "$(ducalls)" = 1 ] && ok || bad "4 two firings inside the TTL must run du once (ran $(ducalls))"

# ══ 3. resolve when space recovers ═══════════════════════════════════════════
guard FAKE_DF_PCT=70
[ "$(jq -r '.resolved_at // 0' "$SF")" != 0 ] && ok || bad "3 70% must resolve the row ($(cat "$SF"))"
[ "$(grep -c 'RESOLVED' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "3 exactly one RESOLVED line ($(cat "$H/logs/ALERTS.log"))"
guard FAKE_DF_PCT=70
[ "$(grep -c 'RESOLVED' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "3 a second healthy run resolves nothing again"

# ══ 4b. TTL expiry and timeout ═══════════════════════════════════════════════
TOP="$H/state/disk-guard/top-dirs"
[ -s "$TOP" ] && ok || bad "4 the top-dirs cache is written"
touch -d '-2 hours' "$TOP"
rm -f "$T/du.calls"
guard FAKE_DF_PCT=90
[ "$(ducalls)" = 1 ] && ok || bad "4 a cache older than the TTL is recomputed"
touch -d '-2 hours' "$TOP"
scratch_rm "$H/state/alerts"
guard FAKE_DF_PCT=90 FAKE_DU_SLEEP=5 DISK_TOP_DIRS_TIMEOUT_S=1
LINE=$(jq -r .line "$SF" 2>/dev/null)
case "$LINE" in *"top dirs: unavailable (du timed out)"*) ok ;; *) bad "4 a du past the timeout must read 'unavailable' (got '$LINE')" ;; esac
case "$LINE" in *"/root/.grok"*) bad "4 a timed-out du never yields a partial list ('$LINE')" ;; *) ok ;; esac

echo "box-disk-alert: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
