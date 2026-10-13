#!/bin/bash
# tests/restore-lab.bh-1944-test.sh — the hub's restore-lab lane (BH-1944,
# BH-1909.2): bin/restore-lab.sh claims one console-requested run, dry-run
# restores it into a /tmp scratch dir with bin/state-restore.sh, judges it and
# posts the verdict back.
#
# Runs the REAL bin/restore-lab.sh, bin/jobs-client.sh (+ bin/lib/jobs/*),
# bin/lib/lane-gate.sh, bin/lib/cron-lines.sh and bin/lib/restore-drill-steps.sh
# in a scratch harness root. Stubbed: curl (answers the worker by path and logs
# every restore-lab request to $T/requests.log), ssh (touches SSH_CALLED and
# fails), $H/bin/state-restore.sh (records argv, prints scripted output) and
# $H/bin/restore-drill.sh (touches DRILL_CALLED).
#
# Run from anywhere: tests/restore-lab.bh-1944-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/state" "$H/tmp" "$H/env" "$T/fakebin" "$T/scratch"
cp "$DIR/bin/restore-lab.sh" "$H/bin/" || { echo "FAIL: missing bin/restore-lab.sh"; exit 1; }
cp "$DIR/bin/jobs-client.sh" "$H/bin/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || exit 1
for f in lane-gate lanes-registry cron-lines restore-drill-steps env-path; do
  cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/" || { echo "FAIL: missing bin/lib/$f.sh"; exit 1; }
done
: > "$H/env/global.env"
: > "$H/logs/ALERTS.log"
echo keep > "$H/tmp/keep"

cat > "$H/bin/state-restore.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$STUB_DIR/sr.argv"
dest=""; prev=""
for a in "$@"; do [ "$prev" = --dest ] && dest=$a; prev=$a; done
[ -n "${SR_SLEEP:-}" ] && sleep "$SR_SLEEP"
[ -n "${SR_TREE:-}" ] && mkdir -p "$dest/$1/20260924T120000Z/tree" && echo x > "$dest/$1/20260924T120000Z/tree/x"
[ -n "${SR_EMPTY_TREE:-}" ] && mkdir -p "$dest/$1/20260924T120000Z/tree"
printf '%s' "${SR_OUT:-}"
exit "${SR_RC:-0}"
EOF
cat > "$H/bin/restore-drill.sh" <<'EOF'
#!/bin/bash
touch "$STUB_DIR/DRILL_CALLED"
EOF
chmod +x "$H/bin/state-restore.sh" "$H/bin/restore-drill.sh"

cat > "$T/fakebin/ssh" <<'EOF'
#!/bin/bash
touch "$STUB_DIR/SSH_CALLED"; exit 1
EOF
# The worker, by path. -w '\n%{http_code}' is what _jobs_req asks for.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
method=GET; body=""; url=""; prev=""
for a in "$@"; do
  case "$prev" in -X) method=$a ;; --data-binary|-d) body=$a ;; esac
  case "$a" in http*://*) url=$a ;; esac
  prev=$a
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
path="/${url#*://*/}"; path="${path%%\?*}"
case "$path" in
  /api/hub/restore-lab/claim)
    printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_DIR/requests.log"
    [ -n "${CLAIM_RC:-}" ] && exit "$CLAIM_RC"
    printf '%s\n%s' "$(cat "$STUB_DIR/claim.json")" "${CLAIM_CODE:-200}" ;;
  /api/hub/restore-lab/*/result)
    printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_DIR/requests.log"
    printf '%s\n%s' '{"ok":true}' "${RESULT_CODE:-200}" ;;
  *)
    printf '%s %s\n' "$method" "$path" >> "$STUB_DIR/other.log"
    printf '%s\n%s' '{}' 404 ;;
esac
EOF
chmod +x "$T/fakebin/ssh" "$T/fakebin/curl"

export STUB_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s3cret
export JOBS_URL=https://jobs.test JOBS_BOX=hub JOBS_RETRIES=0 RESTORE_LAB_TMPDIR="$T/scratch"

SHA=$(printf 'b%.0s' $(seq 64))
RUN7='{"run":{"id":7,"box":"box-project-3-2","snapshot":"latest","status":"claimed","claimed_by":"hub"}}'
OK_OUT="pulled project-3/20260924T120000Z.tar.zst -> /x/project-3/20260924T120000Z/snapshot.tar.zst
sha256 ok $SHA
extracted project-3/20260924T120000Z.tar.zst -> /x/tree
"
reset() {
  rm -f "$T/requests.log" "$T/other.log" "$T/sr.argv" "$T/SSH_CALLED" "$T/DRILL_CALLED"
  rm -rf "$T/scratch"; mkdir -p "$T/scratch"
  rm -f "$H/flags/lane-off-restore-lab"
  printf '%s' "$RUN7" > "$T/claim.json"
  unset SR_OUT SR_RC SR_TREE SR_EMPTY_TREE SR_SLEEP CLAIM_CODE CLAIM_RC RESULT_CODE RESTORE_LAB_TIMEOUT_S
  export RESTORE_LAB_TMPDIR="$T/scratch"
}
lab() { bash "$H/bin/restore-lab.sh" > "$T/out" 2>&1; }
nclaims()  { grep -c ' /api/hub/restore-lab/claim ' "$T/requests.log" 2>/dev/null || true; }
nresults() { grep -c ' /api/hub/restore-lab/7/result ' "$T/requests.log" 2>/dev/null || true; }
result()   { grep ' /api/hub/restore-lab/7/result ' "$T/requests.log" | tail -1 | cut -d' ' -f3-; }
alerts()   { wc -l < "$H/logs/ALERTS.log"; }
scratch_left() { find "$T/scratch" -mindepth 1 -maxdepth 1 | wc -l; }
never() { # never <case>: the negatives every run must hold
  [ ! -e "$T/SSH_CALLED" ] && ok || bad "$1: ssh was called"
  [ ! -e "$T/DRILL_CALLED" ] && ok || bad "$1: restore-drill.sh was called"
  if [ -f "$T/sr.argv" ]; then grep -q -- '--apply' "$T/sr.argv" && bad "$1: --apply passed" || ok; fi
}

# ── C2-S1 happy path ─────────────────────────────────────────────────────
reset
export SR_OUT="$OK_OUT" SR_TREE=1
A0=$(alerts)
lab; RC=$?
[ "$RC" = 0 ] && ok || bad "S1 rc=$RC ($(cat "$T/out"))"
S=$(sed -n 's/^project-3 latest --dest \(.*\)\/tree --live .*$/\1/p' "$T/sr.argv")
[ "$(cat "$T/sr.argv")" = "project-3 latest --dest $S/tree --live $S/empty-live" ] && [ -n "$S" ] && ok \
  || bad "S1 state-restore argv: $(cat "$T/sr.argv" 2>/dev/null)"
case "$S" in "$T/scratch/restore-lab."*) ok ;; *) bad "S1 scratch not under RESTORE_LAB_TMPDIR: $S" ;; esac
[ -n "$S" ] && [ ! -e "$S" ] && ok || bad "S1 scratch dir $S left behind"
[ "$(nclaims)" = 1 ] && [ "$(nresults)" = 1 ] && ok || bad "S1 requests: $(cat "$T/requests.log")"
grep -q '/claim {"claimer":"hub"}' "$T/requests.log" && ok || bad "S1 claim body: $(cat "$T/requests.log")"
R=$(result)
[ "$(jq -r '.ok' <<<"$R")" = true ] && [ "$(jq -r '.sha256' <<<"$R")" = "$SHA" ] \
  && [ "$(jq -r '.snapshot_ts' <<<"$R")" = 20260924T120000Z ] && [ "$(jq -r '.claimer' <<<"$R")" = hub ] \
  && [ "$(jq -r '.ok|type' <<<"$R")" = boolean ] && ok || bad "S1 result body: $R"
[ "$(alerts)" = "$A0" ] && ok || bad "S1 ALERTS grew: $(tail -2 "$H/logs/ALERTS.log")"
grep -q 'run 7 .*ok' "$H/logs/restore-lab.log" 2>/dev/null && ok || bad "S1 no log line: $(cat "$H/logs/restore-lab.log" 2>/dev/null)"
never S1

# ── C2-S2 failure verdicts ───────────────────────────────────────────────
fail_case() { # fail_case <name> <detail substring>
  local R; R=$(result)
  [ "$RC" = 0 ] && ok || bad "$1 rc=$RC ($(cat "$T/out"))"
  [ "$(nresults)" = 1 ] && ok || bad "$1 result posts: $(cat "$T/requests.log")"
  [ "$(jq -r '.ok' <<<"$R")" = false ] && ok || bad "$1 not ok:false: $R"
  jq -r '.detail' <<<"$R" | grep -qF -- "$2" && ok || bad "$1 detail lacks '$2': $R"
  [ "$(scratch_left)" = 0 ] && ok || bad "$1 scratch left: $(ls "$T/scratch")"
  never "$1"
}
reset; export SR_RC=1 SR_OUT="pulled project-3/20260924T120000Z.tar.zst -> /x
REFUSED: sha256 mismatch for project-3/20260924T120000Z.tar.zst (stored a, downloaded b)
"
lab; RC=$?; fail_case "S2a refused" "REFUSED: sha256 mismatch"

reset; export SR_OUT="sha256 ok $SHA
" SR_TREE=1
lab; RC=$?; fail_case "S2b no pulled line" "pulled"

reset; export SR_OUT="pulled project-3/20260924T120000Z.tar.zst -> /x
sha256 unverified (no metadata)
" SR_TREE=1
lab; RC=$?; fail_case "S2c sha unverified" "sha256"

reset; export SR_OUT="$OK_OUT" SR_EMPTY_TREE=1
lab; RC=$?; fail_case "S2d empty tree" "tree"

reset; export SR_RC=1 SR_OUT="not configured - missing: BACKUP_S3_ENDPOINT
"
lab; RC=$?; fail_case "S2 not configured" "not configured"

reset; export SR_OUT="$OK_OUT" SR_TREE=1 SR_SLEEP=5 RESTORE_LAB_TIMEOUT_S=1
lab; RC=$?; fail_case "S2 timeout" "timed out after 1s"

# (e) the result POST fails: the run stays claimed, one ALERTS line, rc 1.
reset; export SR_OUT="$OK_OUT" SR_TREE=1 RESULT_CODE=500
A0=$(alerts)
lab; RC=$?
[ "$RC" = 1 ] && ok || bad "S2e rc=$RC"
[ "$(( $(alerts) - A0 ))" = 1 ] && ok || bad "S2e ALERTS lines added: $(( $(alerts) - A0 ))"
tail -1 "$H/logs/ALERTS.log" | grep -q 'run 7.*re-offered' && ok || bad "S2e ALERTS line: $(tail -1 "$H/logs/ALERTS.log")"
[ "$(scratch_left)" = 0 ] && ok || bad "S2e scratch left"
never S2e

# ── C2-S3 the scratch guard ──────────────────────────────────────────────
guard_case() { # guard_case <name> <tmpdir>
  local before after A0
  reset; export SR_OUT="$OK_OUT" SR_TREE=1 RESTORE_LAB_TMPDIR="$2"
  before=$(cd "$H" && find tmp bin -print0 | sort -z | xargs -0 sha256sum 2>/dev/null; find tmp bin | sort)
  A0=$(alerts)
  lab; RC=$?
  after=$(cd "$H" && find tmp bin -print0 | sort -z | xargs -0 sha256sum 2>/dev/null; find tmp bin | sort)
  [ "$RC" = 2 ] && ok || bad "$1 rc=$RC ($(cat "$T/out"))"
  [ ! -s "$T/requests.log" ] && ok || bad "$1 claimed anyway: $(cat "$T/requests.log")"
  [ ! -e "$T/sr.argv" ] && ok || bad "$1 state-restore ran"
  [ "$(( $(alerts) - A0 ))" = 1 ] && ok || bad "$1 ALERTS lines added: $(( $(alerts) - A0 ))"
  tail -1 "$H/logs/ALERTS.log" | grep -qF "$H" && ok || bad "$1 ALERTS line does not name the path: $(tail -1 "$H/logs/ALERTS.log")"
  [ "$before" = "$after" ] && ok || bad "$1 tmp/ or bin/ under \$H changed"
  [ -z "$(find "$H" -name 'restore-lab.??????')" ] && ok || bad "$1 scratch created inside \$H: $(find "$H" -name 'restore-lab.*')"
  never "$1"
}
ln -s "$H/tmp" "$T/link-into-h"
guard_case "S3 symlink into \$H/tmp" "$T/link-into-h"
guard_case "S3 \$H/tmp" "$H/tmp"
guard_case "S3 \$H itself" "$H"

# ── C2-S4 quiet exits ────────────────────────────────────────────────────
reset; printf '{"run":null}' > "$T/claim.json"
lab; RC=$?
[ "$RC" = 0 ] && [ "$(nclaims)" = 1 ] && [ "$(nresults)" = 0 ] && [ ! -e "$T/sr.argv" ] && ok \
  || bad "S4 run:null rc=$RC requests=$(cat "$T/requests.log" 2>/dev/null) sr=$([ -e "$T/sr.argv" ] && echo ran)"
[ "$(scratch_left)" = 0 ] && ok || bad "S4 run:null scratch left"

reset; export CLAIM_CODE=503
lab; RC=$?
[ "$RC" = 0 ] && [ "$(nresults)" = 0 ] && [ ! -e "$T/sr.argv" ] && ok || bad "S4 worker 503 rc=$RC"

reset; : > "$H/flags/lane-off-restore-lab"
lab; RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/requests.log" ] && [ ! -e "$T/sr.argv" ] && ok \
  || bad "S4 lane-off rc=$RC requests=$(cat "$T/requests.log" 2>/dev/null)"
rm -f "$H/flags/lane-off-restore-lab"

reset; export SR_OUT="$OK_OUT" SR_TREE=1
exec 8>"$H/locks/restore-lab.lock"; flock -n 8 || bad "S4 could not take the lock in the test"
lab; RC=$?
exec 8>&-
[ "$RC" = 0 ] && [ ! -s "$T/requests.log" ] && [ ! -e "$T/sr.argv" ] && ok \
  || bad "S4 lock held rc=$RC requests=$(cat "$T/requests.log" 2>/dev/null)"

echo "restore-lab.bh-1944: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
