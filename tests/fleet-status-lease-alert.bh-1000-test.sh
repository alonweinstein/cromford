#!/bin/bash
# tests/fleet-status-lease-alert.bh-1000-test.sh — the fleet-status snapshot
# must render a missing hub lease as an ALERT, never as a blank (BH-1000).
#
# On 2026-09-19 the hub's `hub_lease` D1 table was never applied, the jobs
# worker 500'd on every read, no cache was ever written, and the fleet-status
# console showed `hub: holder null, epoch null`. Two nulls beside eight healthy
# vitals read as "nobody has filled that in yet" — so a 29-minute outage that
# stopped 52 cron lanes looked, on the one screen built to show it, fine.
#
# What this locks, against the real script writing a real snapshot through a
# fake curl, with a fake bin/lane-alert.sh recording its full argv:
#   1. no cache file            → .hub.lease_alert == "holder null", one WARN
#                                 alert, and the marker file written;
#   2. a fresh held lease       → lease_alert null, and with the marker present
#                                 exactly one --resolve, marker removed after;
#   3. a fresh held lease, no marker → ZERO calls. A healthy hub is silent every
#                                 10 minutes, forever;
#   4. updated_at 700s old      → "lease stale (age 7xxs, holder ...)";
#   5. updated_at unparseable   → "lease age unknown (holder ...)" — never the
#                                 healthy null, which is how a portability bug
#                                 becomes a silent outage.
# The alert is WARN and never --critical: bin/hub-lease.sh owns the critical
# page for this outage under a different id, and a second DM every 10 minutes
# is noise.
# Run from anywhere: tests/fleet-status-lease-alert.bh-1000-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# One clock read for the whole file; every fixture stamp is derived from it, so
# the suite cannot pick its own red minute.
NOW=$(date -u +%s)
iso_at() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; }

mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$T/bin/"
printf 'HARNESS_SECRET=test-secret\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/env/global.env"
printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$T" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\ncat > %s/PUSH.json\n' "$T" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
# The fake alert path records its FULL argv, one line per call: the assertions
# below are on what the script actually invoked, not on what the source says.
cat > "$T/bin/lane-alert.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/LANEALERT.log"
exit 0
SH
chmod +x "$T/bin/lane-alert.sh"
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 box-alpha
EOF

MARK="$T/flags/alerted-hub-lease-fleet-status"
run()   { rm -f "$T/PUSH.json" "$T/BEAT.json" "$T/LANEALERT.log"
          PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" bash "$DIR/bin/fleet-status-push.sh"; }
q()     { jq -r "$1" "$T/PUSH.json" 2>/dev/null; }
calls() { if [ -f "$T/LANEALERT.log" ]; then grep -c . "$T/LANEALERT.log"; else echo 0; fi; }
argv()  { cat "$T/LANEALERT.log" 2>/dev/null; }
# Write the lease cache with updated_at $1 seconds before NOW (or the literal
# string given as $2, for the unparseable case).
lease() {
  local upd="${2:-}"
  [ -n "$upd" ] || upd=$(iso_at "$(( NOW - $1 ))")
  jq -nc --arg u "$upd" '{holder:"box-hub", epoch:7, expired:false,
    expires_at:"2026-09-19T19:00:00Z", updated_at:$u, as_of:$u, held:1, fetched_at:0}' \
    > "$T/state/hub-lease.json"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. NO CACHE FILE — the incident itself
# ─────────────────────────────────────────────────────────────────────────────
rm -f "$T/state/hub-lease.json" "$MARK"
run
jq -e . >/dev/null 2>&1 < "$T/PUSH.json" && ok || bad "1: the push must still be valid JSON"
[ "$(q '.hub.lease_alert')" = "holder null" ] \
  && ok || bad "1: an absent lease cache must render as 'holder null' (got: $(q '.hub|tojson'))"
[ "$(calls)" = 1 ] \
  && ok || bad "1: exactly one lane-alert call, got $(calls): $(argv)"
case "$(argv)" in
  *"--id hub-lease-fleet-status"*) ok ;;
  *) bad "1: the call must carry --id hub-lease-fleet-status (got: $(argv))" ;;
esac
case "$(argv)" in
  *"--severity warn"*) ok ;;
  *) bad "1: the call must be --severity warn (got: $(argv))" ;;
esac
case "$(argv)" in
  *--critical*) bad "1: never --critical — hub-lease.sh owns that page (got: $(argv))" ;;
  *) ok ;;
esac
case "$(argv)" in
  *"hub lease: holder null"*) ok ;;
  *) bad "1: the alert text must name the condition (got: $(argv))" ;;
esac
[ -f "$MARK" ] && ok || bad "1: the fired marker must exist so the resolve fires exactly once"

# ─────────────────────────────────────────────────────────────────────────────
# 2. RECOVERY — a fresh held lease WITH the marker resolves exactly once
# ─────────────────────────────────────────────────────────────────────────────
lease 20
run
[ "$(q '.hub.lease_alert')" = null ] \
  && ok || bad "2: a fresh held lease is not an alert (got: $(q '.hub|tojson'))"
[ "$(q '.hub.holder')" = "box-hub" ] \
  && ok || bad "2: the holder itself must still be carried (got: $(q '.hub|tojson'))"
[ "$(calls)" = 1 ] \
  && ok || bad "2: recovery must make exactly one call, got $(calls): $(argv)"
case "$(argv)" in
  *"--resolve"*) ok ;;
  *) bad "2: the recovery call must be --resolve (got: $(argv))" ;;
esac
case "$(argv)" in
  *"--id hub-lease-fleet-status"*) ok ;;
  *) bad "2: the resolve must close the SAME id (got: $(argv))" ;;
esac
[ ! -e "$MARK" ] && ok || bad "2: the marker must be removed after the resolve"

# ─────────────────────────────────────────────────────────────────────────────
# 3. HEALTHY AND SILENT — no marker, no call, nothing written
# ─────────────────────────────────────────────────────────────────────────────
lease 20
run
[ "$(q '.hub.lease_alert')" = null ] \
  && ok || bad "3: still healthy (got: $(q '.hub|tojson'))"
[ "$(calls)" = 0 ] \
  && ok || bad "3: a healthy hub with nothing open must call nothing, got $(calls): $(argv)"
[ ! -e "$MARK" ] && ok || bad "3: a healthy hub must not write the marker"

# ─────────────────────────────────────────────────────────────────────────────
# 4. STALE — held, but the row stopped moving 700s ago
# ─────────────────────────────────────────────────────────────────────────────
lease 700
run
case "$(q '.hub.lease_alert')" in
  "lease stale (age 7"*"s, holder box-hub)") ok ;;
  *) bad "4: a 700s-old lease must read as stale with its age and holder (got: $(q '.hub.lease_alert'))" ;;
esac
[ "$(calls)" = 1 ] \
  && ok || bad "4: a stale lease must alert once, got $(calls): $(argv)"
case "$(argv)" in
  *"--severity warn"*) ok ;;
  *) bad "4: stale alerts are warn too (got: $(argv))" ;;
esac
case "$(argv)" in
  *--critical*) bad "4: never --critical (got: $(argv))" ;;
  *) ok ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# 5. UNPARSEABLE updated_at — unknown, never a healthy null
# ─────────────────────────────────────────────────────────────────────────────
rm -f "$MARK"
lease 0 "not-a-date"
run
case "$(q '.hub.lease_alert')" in
  "lease age unknown (holder box-hub)") ok ;;
  *) bad "5: an unparseable updated_at must say the age is unknown (got: $(q '.hub.lease_alert'))" ;;
esac
[ "$(q '.hub.lease_age_s')" = "-1" ] \
  && ok || bad "5: the age sentinel stays -1 (got: $(q '.hub.lease_age_s'))"
[ "$(calls)" = 1 ] \
  && ok || bad "5: unknown age must alert once, got $(calls): $(argv)"

# ─────────────────────────────────────────────────────────────────────────────
# 6. AN ABSENT lane-alert.sh MUST NOT COST THE PUSH
# ─────────────────────────────────────────────────────────────────────────────
rm -f "$T/bin/lane-alert.sh" "$T/state/hub-lease.json"
run
RC=$?
[ "$RC" = 0 ] && ok || bad "6: the push must not fail when lane-alert.sh is absent (rc $RC)"
[ "$(q '.hub.lease_alert')" = "holder null" ] \
  && ok || bad "6: the snapshot still carries the verdict without an alert path (got: $(q '.hub|tojson'))"

# ─────────────────────────────────────────────────────────────────────────────
# 7. NO flags/ DIRECTORY — the marker must still land (BH-1000 fix round 1).
#    `touch "$MARK" 2>/dev/null` on a box whose flags/ was never created is a
#    silent no-op, and a marker that never lands means the --resolve in case 2
#    never fires: the console alert would stay open for the rest of the box's
#    life. The hub always has flags/, which is exactly why this one goes unseen.
# ─────────────────────────────────────────────────────────────────────────────
# case 6 removed the alert path; put it back — this case is about the marker.
cat > "$T/bin/lane-alert.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/LANEALERT.log"
exit 0
SH
chmod +x "$T/bin/lane-alert.sh"
rm -f "$T/state/hub-lease.json" "$MARK"
rm -rf "$T/flags"
run
[ "$(q '.hub.lease_alert')" = "holder null" ] \
  && ok || bad "7: the verdict is unchanged without flags/ (got: $(q '.hub|tojson'))"
[ "$(calls)" = 1 ] && ok || bad "7: the warn still fires, got $(calls): $(argv)"
[ -f "$MARK" ] \
  && ok || bad "7: the marker must be created even when flags/ does not exist yet, or the resolve can never fire"
# and the recovery that the marker exists for still closes it
lease 20
run
[ "$(calls)" = 1 ] && ok || bad "7: recovery after a flags-less fire must resolve once, got $(calls): $(argv)"
[ ! -e "$MARK" ] && ok || bad "7: and the marker is removed again"

echo "fleet-status-lease-alert.bh-1000-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
