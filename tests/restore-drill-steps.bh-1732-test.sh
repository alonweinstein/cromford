#!/bin/bash
# tests/restore-drill-steps.bh-1732-test.sh — the on-box steps of the weekly
# restore drill (BH-1732, BH-400.2): drill_on_box in
# bin/lib/restore-drill-steps.sh.
#
# Sources the REAL bin/lib/restore-drill-orgo.sh (orgo, remote) and the REAL
# steps lib in a scratch harness root. Only curl and the hub's bin/gh-token.sh
# are stubbed. The curl stub stores each /bash command body as its own file in
# $T/calls/ (001, 002, ...) and answers by substring, so what the box was sent,
# in what order, and what drill_on_box concluded are the assertions.
#
# Run from anywhere: tests/restore-drill-steps.bh-1732-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$T/fakebin" "$T/calls"
for f in restore-drill-orgo restore-drill-steps deployment; do
  cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/" || { echo "FAIL: missing bin/lib/$f.sh"; exit 1; }
done

cat > "$H/bin/gh-token.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/ghtoken.argv"
[ "${GHTOK_RC:-0}" = 0 ] || exit "$GHTOK_RC"
echo tok
EOF
chmod +x "$H/bin/gh-token.sh"

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/curl.argv"
cmd=""
if [ ! -t 0 ]; then cmd=$(jq -r '.command // empty' 2>/dev/null); fi
n=$(find "$STUB_DIR/calls" -type f | wc -l)
f=$(printf '%s/calls/%03d' "$STUB_DIR" $((n+1)))
printf '%s' "$cmd" > "$f"
rc=0; out=""
case "$cmd" in
  *state-restore.sh*)
    if [ -n "${SR_OUT:-}" ]; then out=$SR_OUT; else
      out="pulled hub-test/$(date -u -d "@$(( $(date -u +%s) - 10800 ))" +%Y%m%dT%H%M%SZ).tar.zst -> /x"$'\n'
    fi
    rc=${SR_RC:-0} ;;
  *healthcheck.sh*) rc=${HC_RC:-0} ;;
  *fleet-conf.sh*) [ -n "${FC_EMPTY:-}" ] || out=$'proj1\n' ;;
  *jobs-client.sh*) [ -n "${JL_EMPTY:-}" ] || out=$'row\n' ;;
esac
if [ -n "${NO_RC_ON:-}" ] && [[ "$cmd" == *"$NO_RC_ON"* ]]; then
  full=$out
else
  full="${out}__RC=$rc"$'\n'
fi
printf '%s\n%s' "$(jq -nc --arg o "$full" '{output:$o}')" 200
EOF
chmod +x "$T/fakebin/curl"
export STUB_DIR="$T" PATH="$T/fakebin:$PATH"

printf 'AGE-SECRET-KEY-1IDENTVALUE\n' > "$T/identity"
export H ORGO_API_KEY=K3Y
export BACKUP_S3_ENDPOINT=https://r2.example BACKUP_S3_ACCESS_KEY_ID=AKID
export BACKUP_S3_SECRET_ACCESS_KEY="R2S3CRET'\$x y"
export RESTORE_DRILL_HEALTH_PROJECT=hp RESTORE_DRILL_IDENTITY_FILE="$T/identity"

# shellcheck source=bin/lib/restore-drill-orgo.sh
. "$H/bin/lib/restore-drill-orgo.sh" || exit 1
# shellcheck source=bin/lib/restore-drill-steps.sh
. "$H/bin/lib/restore-drill-steps.sh" || exit 1

reset() {
  rm -rf "$T/calls" "$T/curl.argv" "$T/ghtoken.argv"; mkdir -p "$T/calls"
  unset SR_OUT SR_RC HC_RC NO_RC_ON GHTOK_RC FC_EMPTY JL_EMPTY
  export RESTORE_DRILL_IDENTITY_FILE="$T/identity"
}
nrec() { find "$T/calls" -type f | wc -l; }
# idx <substring>: number of the first record containing it, or 0.
idx() {
  local f
  for f in "$T"/calls/*; do
    [ -f "$f" ] || continue
    if grep -qF -- "$1" "$f"; then echo $((10#${f##*/})); return; fi
  done
  echo 0
}
has() { [ "$(idx "$1")" != 0 ]; }
rec() { cat "$T/calls/$(printf %03d "$1")" 2>/dev/null; }
DETAILS=""
run() { drill_on_box c1 hub-test; RC=$?; DETAILS="$DETAILS|$DRILL_DETAIL"; }

# --- C1 order / OK ------------------------------------------------------------
reset; run
[ "$RC" = 0 ] && ok || bad "C1 rc=$RC detail=[$DRILL_DETAIL]"
[ "$DRILL_VERDICT" = OK ] && ok || bad "C1 DRILL_VERDICT=$DRILL_VERDICT"
r1=$(rec 1)
case "$r1" in *'crontab -r'*tailscaled.state*) ok ;; *) bad "C1 record 1 is not the fence: [$r1]" ;; esac
case "$r1" in */root/harness*) bad "C1 fence touches /root/harness" ;; *) ok ;; esac
prev=1
for s in 'git clone' '/root/.drill/identity' \
         'state-restore.sh hub-test latest --apply --identity /root/.drill/identity' \
         'CONSOLE_URL|TELEGRAM_' 'healthcheck.sh hp' 'fleet-conf.sh --projects' \
         'jobs-client.sh ledger-list build 1' 'gh auth status'; do
  i=$(idx "$s")
  if [ "$i" -gt "$prev" ]; then ok; else bad "C1 [$s] at record $i, not after $prev"; fi
  prev=$i
done
[ "$(nrec)" = 9 ] && ok || bad "C1 expected 9 records, got $(nrec)"
if [[ "$DRILL_RPO_S" =~ ^[0-9]+$ ]] && [ "$DRILL_RPO_S" -ge 10680 ] && [ "$DRILL_RPO_S" -le 10920 ]; then ok
else bad "C1 DRILL_RPO_S=[$DRILL_RPO_S] not ~10800"; fi
grep -qx -- '--read example-org/cromford' "$T/ghtoken.argv" 2>/dev/null && ok || bad "C1 hub gh-token.sh not called with --read example-org/cromford"
b=$(rec "$(idx 'git clone')")
case "$b" in *'x-access-token:tok@github.com/example-org/cromford.git'*) ok ;; *) bad "C1 clone does not carry the hub token" ;; esac
case "$b" in *'--depth 1'*'--branch main'*) ok ;; *) bad "C1 clone is not a shallow clone of main" ;; esac
case "$b" in *'touch /root/harness/flags/remediation-disabled'*) ok ;; *) bad "C1 bootstrap does not set remediation-disabled" ;; esac
has all-off && bad "C1 a record mentions all-off" || ok
rec "$(idx /root/.drill/identity)" | grep -qF IDENTVALUE && ok || bad "C1 identity content not sent"
case "$(rec "$(idx /root/.drill/identity)")" in *'chmod 600 /root/.drill/identity'*) ok ;; *) bad "C1 identity not chmod 600" ;; esac
# Only remote: every curl call is POST /computers/c1/bash.
if [ -s "$T/curl.argv" ] && ! grep -vqE -- '-X POST .*/computers/c1/bash$' "$T/curl.argv"; then ok
else bad "C1 a curl call other than POST /computers/c1/bash"; fi

# --- C2 healthcheck fails ------------------------------------------------------
reset; export HC_RC=1; run
[ "$RC" = 1 ] && ok || bad "C2 rc=$RC"
[ "$DRILL_VERDICT" = FAIL ] && ok || bad "C2 DRILL_VERDICT=$DRILL_VERDICT"
case "$DRILL_DETAIL" in *healthcheck*) ok ;; *) bad "C2 DRILL_DETAIL=[$DRILL_DETAIL]" ;; esac
{ has fleet-conf.sh || has jobs-client.sh || has 'gh auth'; } && bad "C2 a later smoke ran" || ok

# --- C7 no identity ------------------------------------------------------------
reset; export RESTORE_DRILL_IDENTITY_FILE=""; run
[ "$RC" = 1 ] && ok || bad "C7 rc=$RC"
[ "$DRILL_VERDICT" = FAIL ] && ok || bad "C7 DRILL_VERDICT=$DRILL_VERDICT"
case "$DRILL_DETAIL" in *'env not decrypted'*) ok ;; *) bad "C7 DRILL_DETAIL=[$DRILL_DETAIL]" ;; esac
case "$(rec "$(idx state-restore.sh)")" in *--identity*) bad "C7 restore sent --identity" ;; '') bad "C7 no restore record" ;; *) ok ;; esac
has /root/.drill/identity && bad "C7 an identity record exists" || ok
[ -n "$DRILL_RPO_S" ] && ok || bad "C7 DRILL_RPO_S empty after a pull"
{ has healthcheck.sh || has CONSOLE_URL; } && bad "C7 ran past the restore" || ok

# --- C-norpo: no pulled line ---------------------------------------------------
reset; export SR_OUT=$'restored ok\n'; run
[ "$RC" = 1 ] && ok || bad "C-norpo rc=$RC"
[ "$DRILL_VERDICT" = FAIL ] && ok || bad "C-norpo DRILL_VERDICT=$DRILL_VERDICT"
case "$DRILL_DETAIL" in *'RPO unknown'*) ok ;; *) bad "C-norpo DRILL_DETAIL=[$DRILL_DETAIL]" ;; esac
[ -z "$DRILL_RPO_S" ] && ok || bad "C-norpo DRILL_RPO_S=[$DRILL_RPO_S]"
{ has CONSOLE_URL || has healthcheck.sh; } && bad "C-norpo ran past the restore" || ok
# A pulled line for another box is not this box's RPO.
reset; export SR_OUT=$'pulled other-box/20260101T000000Z.tar.zst -> /x\n'; run
case "$DRILL_DETAIL" in *'RPO unknown'*) ok ;; *) bad "C-norpo other box DRILL_DETAIL=[$DRILL_DETAIL]" ;; esac

# --- C-restore-rc: restore fails -----------------------------------------------
reset; export SR_OUT=$'REFUSED: sha256 mismatch\n' SR_RC=1; run
[ "$RC" = 1 ] && ok || bad "C-restore-rc rc=$RC"
case "$DRILL_DETAIL" in 'restore rc=1'*'REFUSED: sha256 mismatch'*) ok ;; *) bad "C-restore-rc DRILL_DETAIL=[$DRILL_DETAIL]" ;; esac

# --- C-norc (D9): an answer with no __RC line ----------------------------------
reset; export NO_RC_ON=fleet-conf.sh; run
[ "$RC" = 1 ] && ok || bad "C-norc rc=$RC"
[ "$DRILL_VERDICT" = FAIL ] && ok || bad "C-norc DRILL_VERDICT=$DRILL_VERDICT"
case "$DRILL_DETAIL" in fleet-conf*) ok ;; *) bad "C-norc DRILL_DETAIL=[$DRILL_DETAIL]" ;; esac
has jobs-client.sh && bad "C-norc jobs-client was sent" || ok

# --- C-empty: a list smoke that answers rc 0 with nothing is not a pass ------
reset; export FC_EMPTY=1; run
[ "$RC" = 1 ] && ok || bad "C-empty fleet-conf rc=$RC"
[ "$DRILL_DETAIL" = "fleet-conf: empty output" ] && ok || bad "C-empty fleet-conf DRILL_DETAIL=[$DRILL_DETAIL]"
has jobs-client.sh && bad "C-empty jobs-client was sent" || ok
reset; export JL_EMPTY=1; run
[ "$RC" = 1 ] && ok || bad "C-empty jobs-ledger rc=$RC"
[ "$DRILL_DETAIL" = "jobs-ledger: empty output" ] && ok || bad "C-empty jobs-ledger DRILL_DETAIL=[$DRILL_DETAIL]"
has 'gh auth' && bad "C-empty gh auth was sent" || ok

# --- C-fence-fail --------------------------------------------------------------
reset; export NO_RC_ON=crontab; run
[ "$RC" = 1 ] && ok || bad "C-fence-fail rc=$RC"
case "$DRILL_DETAIL" in fence*) ok ;; *) bad "C-fence-fail DRILL_DETAIL=[$DRILL_DETAIL]" ;; esac
[ "$(nrec)" = 1 ] && ok || bad "C-fence-fail $(nrec) records"

# --- C-token: the hub cannot mint a read token ---------------------------------
reset; export GHTOK_RC=1; run
[ "$RC" = 1 ] && ok || bad "C-token rc=$RC"
case "$DRILL_DETAIL" in bootstrap*) ok ;; *) bad "C-token DRILL_DETAIL=[$DRILL_DETAIL]" ;; esac
[ "$(nrec)" = 1 ] && ok || bad "C-token $(nrec) records"

# --- C-stale: globals from a previous call never survive -----------------------
reset; export NO_RC_ON=crontab
DRILL_VERDICT=OK DRILL_RPO_S=5; run
[ "$DRILL_VERDICT" = FAIL ] && ok || bad "C-stale DRILL_VERDICT=$DRILL_VERDICT"
[ -z "$DRILL_RPO_S" ] && ok || bad "C-stale DRILL_RPO_S=[$DRILL_RPO_S]"

# --- C-envseed / C-secret (on a full OK run) ------------------------------------
reset; run
n=0; for f in "$T"/calls/*; do grep -qF global.env "$f" && n=$((n+1)); done
[ "$n" = 1 ] && [ "$(idx global.env)" = "$(idx CONSOLE_URL)" ] && ok || bad "C-envseed $n records mention global.env"
grep -lF '>>' "$T"/calls/* >/dev/null 2>&1 && bad "C-envseed a record appends to a file" || ok
n=0; for f in "$T"/calls/*; do grep -qF BACKUP_S3_SECRET_ACCESS_KEY= "$f" && n=$((n+1)); done
[ "$n" = 1 ] && [ "$(idx BACKUP_S3_SECRET_ACCESS_KEY=)" = "$(idx state-restore.sh)" ] && ok || bad "C-envseed the R2 secret rides $n records"
q=$(printf %q "$BACKUP_S3_SECRET_ACCESS_KEY")
case "$(rec "$(idx state-restore.sh)")" in *"BACKUP_S3_SECRET_ACCESS_KEY=$q "*) ok ;; *) bad "C-secret restore record does not carry the %q-quoted secret" ;; esac
[ -s "$H/logs/restore-drill.log" ] && ok || bad "C-secret restore-drill.log was never written"
grep -qF R2S3CRET "$H/logs/restore-drill.log" && bad "C-secret R2 secret in restore-drill.log" || ok
grep -qF IDENTVALUE "$H/logs/restore-drill.log" && bad "C-secret identity in restore-drill.log" || ok
case "$DETAILS" in *R2S3CRET*|*IDENTVALUE*|*tok@*) bad "C-secret a secret reached DRILL_DETAIL" ;; *) ok ;; esac
grep -qE '^[a-z-]+ rc=[0-9]+$' "$H/logs/restore-drill.log" && ! grep -qvE '^[a-z-]+ rc=[0-9]+$' "$H/logs/restore-drill.log" \
  && ok || bad "C-secret restore-drill.log has a line other than <label> rc=<n>"

# --- C-noknobs: the lib reads no ${X:-} defaults ---------------------------------
[ -s "$DIR/bin/lib/restore-drill-steps.sh" ] || bad "C-noknobs lib missing"
knobs=$(grep -v '^[[:space:]]*#' "$DIR/bin/lib/restore-drill-steps.sh" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:-')
[ -z "$knobs" ] && ok || bad "C-noknobs lib reads defaults: $knobs"

echo "restore-drill-steps.bh-1732: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
