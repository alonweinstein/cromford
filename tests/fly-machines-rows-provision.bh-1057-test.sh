#!/bin/bash
# tests/fly-machines-rows-provision.bh-1057-test.sh — the two one-shot Fly state
# writers also write their row twin (BH-1035.3 / #1057).
#
# Drives the REAL bin/fly-provision.sh and bin/fly-image-refresh.sh against a
# scratch $HARNESS, a recording flyctl stub and a recording curl stub, with the
# REAL bin/jobs-client.sh sourced from the scratch root. Nothing here asserts on
# source text: every case reads the state file on disk, the request the stub
# recorded, the log lines, and the script's own exit code.
#
# The contract under test: file first, row second, fail-open. A worker that is
# down, refuses, or has fly_machines_rows off never changes either script's exit
# code and never changes what lands on disk.
#
# Run from anywhere: tests/fly-machines-rows-provision.bh-1057-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# Both scripts are driven VERBATIM against a scratch root, which only works
# because each reads its root through a `${HARNESS:-/root/harness}` seam. If a
# seam is ever lost the run would drive the LIVE /root/harness — rebuilding real
# pool images, appending a stub token to the real env/fly.env. So it refuses.
grep -q '^HARNESS="\${HARNESS:-/root/harness}"$' "$DIR/bin/fly-provision.sh" || {
  echo "FAIL: bin/fly-provision.sh lost its HARNESS seam — refusing to run against a live root"; exit 1; }
grep -q '^H="\${HARNESS:-/root/harness}"$' "$DIR/bin/fly-image-refresh.sh" || {
  echo "FAIL: bin/fly-image-refresh.sh lost its HARNESS seam — refusing to run against a live root"; exit 1; }

mkdir -p "$T/fakebin"

# --- stubs -------------------------------------------------------------------
# curl: records `METHOD URL file=<yes|no> BODY` so a case can read the body back
# AND tell whether the state file already existed when the request went out
# (that is the "file first, row second" assertion). Answers the settings GET
# from $SETTING_JSON; CURL_MODE=down is a transport failure, CURL_MODE=put404 a
# worker without the routes slice.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2;;
    *) shift;;
  esac
done
FILEFLAG=no
[ -s "${STATE_PROBE:-/nonexistent}" ] && FILEFLAG=yes
[ -n "${REQ_SINK:-}" ] && printf '%s %s file=%s %s\n' "$METHOD" "$URL" "$FILEFLAG" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
  put404) case "$METHOD" in PUT|PATCH) printf '{"error":"not found"}\n404\n'; exit 0;; esac ;;
esac
case "$METHOD $URL" in
  "GET "*/api/settings/*)
    if [ -s "${SETTING_JSON:-/nonexistent}" ]; then cat "$SETTING_JSON"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  "PUT "*/api/machines) printf '{"ok":true}\n200\n' ;;
  "PUT "*/api/settings) printf '{"ok":true}\n200\n' ;;
  *) printf '{}\n404\n' ;;
esac
CURL
chmod 755 "$T/fakebin/curl"

# flyctl: answers every call fly-provision.sh has to get past. BOTH names exist
# because the script resolves `command -v fly || command -v flyctl`.
cat > "$T/fakebin/flyctl" <<'FLY'
#!/bin/bash
case "$1 $2" in
  "apps list")     printf '[{"Name":"builder-tproj"}]\n' ;;
  "volumes list")  printf '[{"name":"builder_data","id":"vol_1"}]\n' ;;
  "machine list")
    if [ "${FLY_MACHINE_LIST_EMPTY:-0}" = 1 ]; then printf '[]\n'
    else printf '[{"id":"148e2a1b3c4d5e"}]\n'; fi ;;
  "tokens create") printf 'FlyV1 fm2_x\n' ;;
esac
exit 0
FLY
chmod 755 "$T/fakebin/flyctl"
cp "$T/fakebin/flyctl" "$T/fakebin/fly"

# --- fixture -----------------------------------------------------------------
mkroot() { # mkroot <case-dir> — a scratch $HARNESS with the REAL jobs-client.
  local F="$1"
  mkdir -p "$F/h/env" "$F/h/state/fly" "$F/h/logs" "$F/h/locks" "$F/h/flags" "$F/h/bin/lib"
  cp "$DIR/bin/jobs-client.sh"  "$F/h/bin/jobs-client.sh"
  cp "$DIR/bin/alert-line.sh" "$F/h/bin/"
  mkdir -p "$F/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$F/h/bin/lib/jobs/"
  cp "$DIR/bin/lib/env-path.sh" "$F/h/bin/lib/env-path.sh"
  printf 'FLY_ORG=o\nFLY_API_TOKEN="t"\n' > "$F/h/env/fly.env"
  printf 'HARNESS_SECRET=test-secret\n'   > "$F/h/env/global.env"
  rows_off "$F"
}
rows_on()  { printf '{"setting":{"key":"fly_machines_rows","value":"on"}}'  > "$1/setting.json"; }
rows_off() { printf '{"setting":{"key":"fly_machines_rows","value":"off"}}' > "$1/setting.json"; }

# image_build_stub <case-dir> — the thing fly-image-refresh.sh shells out to.
image_build_stub() {
  cat > "$1/h/bin/fly-image-build.sh" <<'IB'
#!/bin/bash
echo x >> "$IMAGE_BUILD_CALLS"
[ "${IMAGE_BUILD_SILENT:-0}" = 1 ] || echo "image: registry.fly.io/builder-$1:deployment-77"
exit "${IMAGE_BUILD_RC:-0}"
IB
  chmod 755 "$1/h/bin/fly-image-build.sh"
  : > "$1/calls"
}

run_provision() { # run_provision <case-dir> <project> [VAR=VAL ...]
  local F="$1" P="$2"; shift 2
  ( export HARNESS="$F/h" PATH="$T/fakebin:$PATH" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
           SETTING_JSON="$F/setting.json" REQ_SINK="$F/req.log" \
           STATE_PROBE="$F/h/state/fly/$P.json" "$@"
    bash "$DIR/bin/fly-provision.sh" "$P" > "$F/run.out" 2>&1
    echo "$?" > "$F/rc" )
}

run_refresh() { # run_refresh <case-dir> <state-probe-project> [VAR=VAL ...]
  local F="$1" P="$2"; shift 2
  ( export HARNESS="$F/h" PATH="$T/fakebin:$PATH" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
           SETTING_JSON="$F/setting.json" REQ_SINK="$F/req.log" \
           STATE_PROBE="$F/h/state/fly/$P.image" \
           IMAGE_BUILD_CALLS="$F/calls" "$@"
    bash "$DIR/bin/fly-image-refresh.sh" > "$F/run.out" 2>&1
    echo "$?" > "$F/rc" )
}

rc_of()   { cat "$1/rc" 2>/dev/null || echo missing; }
nreq()    { if [ -f "$1/req.log" ]; then grep -c "^$2" "$1/req.log"; else echo 0; fi; }
reqbody() { grep -m1 "^$2" "$1/req.log" 2>/dev/null | cut -d' ' -f4-; }
reqfile() { grep -m1 "^$2" "$1/req.log" 2>/dev/null | cut -d' ' -f3; }
jqb()     { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }
nlines()  { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# =============================================================================
# §8 — bin/fly-provision.sh writes the builder row after the state file
# =============================================================================

# --- 8.1 row on: state file AND exactly one PUT /api/machines, file first -----
mkroot "$T/c81"; rows_on "$T/c81"
run_provision "$T/c81" tproj
BODY=$(reqbody "$T/c81" "PUT https://jobs.invalid/api/machines ")
if [ "$(rc_of "$T/c81")" = 0 ] \
  && [ "$(jq -r '.machine_id' "$T/c81/h/state/fly/tproj.json" 2>/dev/null)" = "148e2a1b3c4d5e" ] \
  && [ "$(nreq "$T/c81" "PUT https://jobs.invalid/api/machines ")" -eq 1 ] \
  && [ "$(jqb "$BODY" '.role')"       = "builder" ] \
  && [ "$(jqb "$BODY" '.machine_id')" = "148e2a1b3c4d5e" ] \
  && [ "$(jqb "$BODY" '.app')"        = "builder-tproj" ] \
  && [ "$(jqb "$BODY" '.project')"    = "tproj" ] \
  && [ "$(jqb "$BODY" '.state')"      = "stopped" ] \
  && [ "$(jqb "$BODY" '.image')"      = "registry.fly.io/builder-tproj:latest" ] \
  && [ "$(jqb "$BODY" 'has("key")')"  = "false" ] \
  && [ -n "$(jqb "$BODY" '.actor // empty')" ] \
  && [ "$(reqfile "$T/c81" "PUT https://jobs.invalid/api/machines ")" = "file=yes" ]; then
  ok
else bad "8.1 provision row-on rc=$(rc_of "$T/c81") puts=$(nreq "$T/c81" "PUT https://jobs.invalid/api/machines ") file=$(reqfile "$T/c81" "PUT https://jobs.invalid/api/machines ") body='$BODY'"; fi

# --- 8.2 row off: same state file, no write request --------------------------
mkroot "$T/c82"; rows_off "$T/c82"
run_provision "$T/c82" tproj
if [ "$(rc_of "$T/c82")" = 0 ] \
  && [ "$(jq -r '.machine_id' "$T/c82/h/state/fly/tproj.json" 2>/dev/null)" = "148e2a1b3c4d5e" ] \
  && [ "$(jq -r '.app' "$T/c82/h/state/fly/tproj.json" 2>/dev/null)" = "builder-tproj" ] \
  && [ "$(nreq "$T/c82" "PUT ")" -eq 0 ]; then
  ok
else bad "8.2 provision row-off rc=$(rc_of "$T/c82") puts=$(nreq "$T/c82" "PUT ")"; fi

# --- 8.3 forced on + worker down: file written, log line, exit code unchanged -
mkroot "$T/c83"; rows_off "$T/c83"
run_provision "$T/c83" tproj FLY_MACHINES_ROWS=on CURL_MODE=down
if [ "$(rc_of "$T/c83")" = 0 ] \
  && [ -s "$T/c83/h/state/fly/tproj.json" ] \
  && grep -q 'machines row not written' "$T/c83/run.out"; then
  ok
else bad "8.3 provision worker-down rc=$(rc_of "$T/c83") out='$(tail -3 "$T/c83/run.out")'"; fi

# --- 8.4 the .image pointer is read through $STATE_DIR (same file, same path) -
mkroot "$T/c84"; rows_on "$T/c84"
printf 'registry.fly.io/builder-tproj:deployment-9\n' > "$T/c84/h/state/fly/tproj.image"
run_provision "$T/c84" tproj
BODY=$(reqbody "$T/c84" "PUT https://jobs.invalid/api/machines ")
if [ "$(rc_of "$T/c84")" = 0 ] \
  && [ "$(jqb "$BODY" '.image')" = "registry.fly.io/builder-tproj:deployment-9" ]; then
  ok
else bad "8.4 provision .image pointer rc=$(rc_of "$T/c84") body='$BODY'"; fi

# --- 8.5 row on + worker without the routes slice (404 on PUT) ---------------
mkroot "$T/c85"; rows_on "$T/c85"
run_provision "$T/c85" tproj CURL_MODE=put404
if [ "$(rc_of "$T/c85")" = 0 ] \
  && [ -s "$T/c85/h/state/fly/tproj.json" ] \
  && grep -q 'machines row not written' "$T/c85/run.out"; then
  ok
else bad "8.5 provision PUT-404 rc=$(rc_of "$T/c85") out='$(tail -3 "$T/c85/run.out")'"; fi

# --- 8.6 flag unreadable: silent skip, no row, exit code unchanged -----------
mkroot "$T/c86"; rows_on "$T/c86"
run_provision "$T/c86" tproj CURL_MODE=down
if [ "$(rc_of "$T/c86")" = 0 ] \
  && [ -s "$T/c86/h/state/fly/tproj.json" ] \
  && [ "$(nreq "$T/c86" "PUT ")" -eq 0 ] \
  && ! grep -q 'machines row not written' "$T/c86/run.out"; then
  ok
else bad "8.6 provision flag-unreadable rc=$(rc_of "$T/c86") puts=$(nreq "$T/c86" "PUT ") out='$(tail -3 "$T/c86/run.out")'"; fi

# --- 8.7 empty machine id: state file as today, no row, and NOT reported as a
#     failed write — there was nothing to write, so the log line would be false.
mkroot "$T/c87"; rows_on "$T/c87"
run_provision "$T/c87" tproj FLY_MACHINE_LIST_EMPTY=1
if [ "$(rc_of "$T/c87")" = 0 ] \
  && [ "$(jq -r '.machine_id' "$T/c87/h/state/fly/tproj.json" 2>/dev/null)" = "" ] \
  && [ "$(nreq "$T/c87" "PUT ")" -eq 0 ] \
  && ! grep -q 'machines row not written' "$T/c87/run.out"; then
  ok
else bad "8.7 provision empty MID rc=$(rc_of "$T/c87") mid='$(jq -r '.machine_id' "$T/c87/h/state/fly/tproj.json" 2>/dev/null)' puts=$(nreq "$T/c87" "PUT ") out='$(tail -3 "$T/c87/run.out")'"; fi

# =============================================================================
# §9 — bin/fly-image-refresh.sh writes the image ref's settings twin
# =============================================================================

# --- 9.1 row on: .image file AND exactly one PUT /api/settings, file first ----
mkroot "$T/c91"; rows_on "$T/c91"; image_build_stub "$T/c91"
touch "$T/c91/h/flags/fly-pool-tproj"
run_refresh "$T/c91" tproj
BODY=$(reqbody "$T/c91" "PUT https://jobs.invalid/api/settings ")
if [ "$(rc_of "$T/c91")" = 0 ] \
  && [ "$(cat "$T/c91/h/state/fly/tproj.image" 2>/dev/null)" = "registry.fly.io/builder-tproj:deployment-77" ] \
  && [ "$(nreq "$T/c91" "PUT https://jobs.invalid/api/settings ")" -eq 1 ] \
  && [ "$(jqb "$BODY" '.key')"   = "fly_image.tproj" ] \
  && [ "$(jqb "$BODY" '.value')" = "registry.fly.io/builder-tproj:deployment-77" ] \
  && [ -n "$(jqb "$BODY" '.note // empty')" ] \
  && [ "$(reqfile "$T/c91" "PUT https://jobs.invalid/api/settings ")" = "file=yes" ] \
  && grep -q 'tproj refreshed: registry.fly.io/builder-tproj:deployment-77' "$T/c91/h/logs/fly-image-refresh.log"; then
  ok
else bad "9.1 refresh row-on rc=$(rc_of "$T/c91") img='$(cat "$T/c91/h/state/fly/tproj.image" 2>/dev/null)' puts=$(nreq "$T/c91" "PUT https://jobs.invalid/api/settings ") body='$BODY'"; fi

# --- 9.2 row off: file written, no write request ------------------------------
mkroot "$T/c92"; rows_off "$T/c92"; image_build_stub "$T/c92"
touch "$T/c92/h/flags/fly-pool-tproj"
run_refresh "$T/c92" tproj
if [ "$(rc_of "$T/c92")" = 0 ] \
  && [ "$(cat "$T/c92/h/state/fly/tproj.image" 2>/dev/null)" = "registry.fly.io/builder-tproj:deployment-77" ] \
  && [ "$(nreq "$T/c92" "PUT ")" -eq 0 ]; then
  ok
else bad "9.2 refresh row-off rc=$(rc_of "$T/c92") puts=$(nreq "$T/c92" "PUT ")"; fi

# --- 9.3 both build attempts fail: no .image, no request, one ALERTS line -----
mkroot "$T/c93"; rows_on "$T/c93"; image_build_stub "$T/c93"
touch "$T/c93/h/flags/fly-pool-tproj"
run_refresh "$T/c93" tproj IMAGE_BUILD_RC=1
if [ "$(rc_of "$T/c93")" = 0 ] \
  && [ "$(nlines "$T/c93/calls")" -eq 2 ] \
  && [ ! -e "$T/c93/h/state/fly/tproj.image" ] \
  && [ "$(nreq "$T/c93" "PUT ")" -eq 0 ] \
  && [ "$(nlines "$T/c93/h/logs/ALERTS.log")" -eq 1 ] \
  && grep -q 'nightly builder-image rebuild FAILED' "$T/c93/h/logs/ALERTS.log"; then
  ok
else bad "9.3 refresh build-failed rc=$(rc_of "$T/c93") calls=$(nlines "$T/c93/calls") puts=$(nreq "$T/c93" "PUT ") alerts=$(nlines "$T/c93/h/logs/ALERTS.log")"; fi

# --- 9.4 illegal settings key: file written, refused write, the same log line -
mkroot "$T/c94"; rows_on "$T/c94"; image_build_stub "$T/c94"
touch "$T/c94/h/flags/fly-pool-Bad_Proj"
run_refresh "$T/c94" Bad_Proj
if [ "$(rc_of "$T/c94")" = 0 ] \
  && [ "$(cat "$T/c94/h/state/fly/Bad_Proj.image" 2>/dev/null)" = "registry.fly.io/builder-Bad_Proj:deployment-77" ] \
  && [ "$(nreq "$T/c94" "PUT ")" -eq 0 ] \
  && grep -q 'Bad_Proj image row not written' "$T/c94/h/logs/fly-image-refresh.log"; then
  ok
else bad "9.4 refresh bad key rc=$(rc_of "$T/c94") puts=$(nreq "$T/c94" "PUT ") log='$(tail -2 "$T/c94/h/logs/fly-image-refresh.log" 2>/dev/null)'"; fi

# --- 9.5 ref not parsed: no file, no request, the existing log line -----------
mkroot "$T/c95"; rows_on "$T/c95"; image_build_stub "$T/c95"
touch "$T/c95/h/flags/fly-pool-tproj"
run_refresh "$T/c95" tproj IMAGE_BUILD_SILENT=1
if [ "$(rc_of "$T/c95")" = 0 ] \
  && [ ! -e "$T/c95/h/state/fly/tproj.image" ] \
  && [ "$(nreq "$T/c95" "PUT ")" -eq 0 ] \
  && grep -q 'tproj refreshed: ref-not-parsed' "$T/c95/h/logs/fly-image-refresh.log"; then
  ok
else bad "9.5 refresh ref-not-parsed rc=$(rc_of "$T/c95") puts=$(nreq "$T/c95" "PUT ") log='$(tail -2 "$T/c95/h/logs/fly-image-refresh.log" 2>/dev/null)'"; fi

# --- 9.6 the fly-pool-app-* flag is still skipped ------------------------------
mkroot "$T/c96"; rows_on "$T/c96"; image_build_stub "$T/c96"
touch "$T/c96/h/flags/fly-pool-app-tproj"
run_refresh "$T/c96" tproj
if [ "$(rc_of "$T/c96")" = 0 ] \
  && [ "$(nlines "$T/c96/calls")" -eq 0 ] \
  && [ "$(nreq "$T/c96" "PUT ")" -eq 0 ]; then
  ok
else bad "9.6 refresh app-flag skip rc=$(rc_of "$T/c96") calls=$(nlines "$T/c96/calls") puts=$(nreq "$T/c96" "PUT ")"; fi

echo "fly-machines-rows-provision.bh-1057-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
