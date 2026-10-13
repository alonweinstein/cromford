#!/bin/bash
# tests/state-backup-sigpipe.bh-4719-test.sh — a membership check on a big
# listing must not read as "missing" (BH-4719).
#
# bin/state-backup.sh and bin/state-restore.sh run under `set -uo pipefail`.
# `printf '%s\n' "$BIG" | grep -q X` stops reading at the first match; when X is
# on line 1 and $BIG is bigger than a pipe buffer, printf takes SIGPIPE (rc 141)
# and pipefail turns a present entry into a failed check. On the hub that was
# every backup run exiting 1 with `leak-check FAILED ... env.tar.age is not in
# it` (env.tar.age is always the tarball's first entry). This suite drives both
# production entry points with a listing far past 64KiB and asserts on what
# they really did:
#   S1  state-backup with a ~1.3MB tarball listing uploads, stamps
#       state/backup-last.json and writes no leak-check ALERTS line;
#   S2  the plaintext-env guard right after it still refuses a tarball that
#       carries env/ in the clear (the fix did not open the leak check);
#   S3  a listing with NO env.tar.age is still refused (the membership check
#       did not go blind);
#   R1  state-restore asked for the OLDEST of 5000 listed snapshots finds it
#       (it gets as far as get-object) instead of answering `no backup`;
#   R2  a ts that is not listed still answers `no backup`, rc 1.
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=1789514400            # 2026-09-15T23:20:00Z
KEY="small/20260915T232000Z.tar.zst"

mkdir -p "$T/fakebin"
if ! command -v age >/dev/null 2>&1; then
  printf '#!/bin/bash\nif [ "${1:-}" = "-d" ]; then exec base64 -d; fi\nexec base64\n' > "$T/fakebin/age"
  chmod +x "$T/fakebin/age"
fi
if ! command -v age-keygen >/dev/null 2>&1; then
  cat > "$T/fakebin/age-keygen" <<'SH'
#!/bin/bash
OUT=""
while [ $# -gt 0 ]; do case "$1" in -o) OUT="${2:-}"; shift 2 ;; *) shift ;; esac; done
[ -n "$OUT" ] && printf 'stand-in-key-material-not-a-real-identity\n' > "$OUT"
printf 'Public key: age1standin-recipient-not-a-real-key\n' >&2
SH
  chmod +x "$T/fakebin/age-keygen"
fi
if ! command -v zstd >/dev/null 2>&1; then
  printf '#!/bin/bash\nexec cat\n' > "$T/fakebin/zstd"; chmod +x "$T/fakebin/zstd"
fi
# aws s3api over a directory tree, plus a generated listing for the restore:
# $S3ROOT/list-n holds N, and list-objects-v2 then answers N keys under the
# prefix (one page; state-restore does not care how many a page holds), the
# oldest first. get-object always fails: R1 only needs to see the run get past
# the "which object" check.
cat > "$T/fakebin/aws" <<SH
#!/bin/bash
S3ROOT="$T/s3"
mkdir -p "\$S3ROOT"
VERB=""
if [ "\${1:-}" = s3api ]; then VERB="\${2:-}"; shift 2; fi
BUCKET=""; KEY=""; BODY=""; PREFIX=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --bucket) BUCKET="\${2:-}"; shift 2 ;;
    --key)    KEY="\${2:-}"; shift 2 ;;
    --body)   BODY="\${2:-}"; shift 2 ;;
    --prefix) PREFIX="\${2:-}"; shift 2 ;;
    --endpoint-url|--output|--region|--metadata|--delete|--continuation-token) shift 2 ;;
    *)        shift ;;
  esac
done
case "\$VERB" in
  put-object)
    mkdir -p "\$(dirname "\$S3ROOT/\$BUCKET/\$KEY")"
    cp "\$BODY" "\$S3ROOT/\$BUCKET/\$KEY" || exit 253
    printf '{"ETag":"stub"}\n' ;;
  head-object)
    [ -f "\$S3ROOT/\$BUCKET/\$KEY" ] || exit 254
    printf '{"ContentLength":%s}\n' "\$(stat -c%s "\$S3ROOT/\$BUCKET/\$KEY")" ;;
  list-objects-v2)
    N=\$(cat "\$S3ROOT/list-n" 2>/dev/null)
    case "\$N" in ''|*[!0-9]*) printf '{"Contents":[]}\n'; exit 0 ;; esac
    seq 0 \$((N - 1)) | awk -v p="\$PREFIX" '{ printf "%s20200101T%06dZ.tar.zst\n", p, \$1 }' \
      | jq -R -n -c '{Contents: [inputs | {Key: ., Size: 100}], IsTruncated: false}' ;;
  get-object) exit 255 ;;
  *) exit 252 ;;
esac
SH
chmod +x "$T/fakebin/aws"

AGEPUB=$(PATH="$T/fakebin:$PATH" age-keygen -o "$T/age.key" 2>&1 | sed -n 's/^Public key: //p')
[ -n "$AGEPUB" ] && ok || bad "setup: age-keygen gave no public key"

mkdir -p "$T/h/env" "$T/h/state/many" "$T/h/logs" "$T/h/flags" "$T/s3"
{
  printf 'BACKUP_S3_ENDPOINT=https://s3.test.invalid\n'
  printf 'BACKUP_S3_BUCKET=bkt\n'
  printf 'BACKUP_S3_ACCESS_KEY_ID=akid-4719\n'
  printf 'BACKUP_S3_SECRET_ACCESS_KEY=sak-4719\n'
  printf 'BACKUP_AGE_RECIPIENT=%s\n' "$AGEPUB"
} > "$T/h/env/global.env"
printf 'small\n' > "$T/h/state/box-id"
# 20000 empty files with 56-char names: a ~1.3MB listing, ~20x a 64KiB pipe.
PAD=$(printf '%050d' 0)
( cd "$T/h/state/many" && seq -w 1 20000 | sed "s/^/${PAD}-/" | xargs touch )
[ "$(find "$T/h/state/many" -type f | wc -l)" -eq 20000 ] && ok || bad "setup: the 20000-file tree did not build"

bk() {
  env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$T/h" HARNESS_CHECKOUT="$T/no-checkout" \
      ORCHESTRATOR_DIR="$T/no-orch" ETC_HARNESS_ENV="$T/no-such-etc" BACKUP_NOW="$NOW" \
      bash "$DIR/bin/state-backup.sh" > "$T/run.out" 2>&1
}

# ── S1: a big listing with env.tar.age on line 1 is a pass, not a leak ─────
bk; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S1: the backup run exited $RC ($(tail -3 "$T/run.out"))"
[ -f "$T/s3/bkt/$KEY" ] && ok || bad "S1: nothing landed at $KEY"
[ -f "$T/h/state/backup-last.json" ] && ok || bad "S1: state/backup-last.json was not stamped"
grep -q 'leak-check' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && bad "S1: a leak-check ALERTS line on a clean tarball: $(grep 'leak-check' "$T/h/logs/ALERTS.log")" || ok
LIST=$(PATH="$T/fakebin:$PATH" tar --zstd -tf "$T/s3/bkt/$KEY" 2>/dev/null | wc -c)
[ "${LIST:-0}" -gt 1000000 ] && ok || bad "S1: the uploaded listing is ${LIST:-0} bytes, too small to prove SIGPIPE"

# ── S2/S3: the two leak-check refusals still refuse on the same big listing ──
# A tar wrapper ahead of the real one bends ONLY the listing (`-t`) the check
# reads back; the archive that would upload is untouched. $T/tarmode says how:
#   plain-env  append a plaintext env/global.env entry  -> S2
#   no-age     drop the env.tar.age entry               -> S3
REALTAR=$(command -v tar)
mkdir -p "$T/tarbin"
cat > "$T/tarbin/tar" <<SH
#!/bin/bash
case " \$* " in
  *" -tf "*)
    MODE=\$(cat "$T/tarmode" 2>/dev/null)
    "$REALTAR" "\$@" | if [ "\$MODE" = no-age ]; then grep -vx 'env.tar.age'; else cat; fi
    [ "\$MODE" = plain-env ] && printf 'env/global.env\n'
    exit 0 ;;
esac
exec "$REALTAR" "\$@"
SH
chmod +x "$T/tarbin/tar"
bk2() {
  rm -rf "$T/s3/bkt" "$T/h/logs/ALERTS.log" "$T/h/state/backup-last.json"
  env PATH="$T/tarbin:$T/fakebin:$PATH" HARNESS_ROOT="$T/h" HARNESS_CHECKOUT="$T/no-checkout" \
      ORCHESTRATOR_DIR="$T/no-orch" ETC_HARNESS_ENV="$T/no-such-etc" BACKUP_NOW="$NOW" \
      bash "$DIR/bin/state-backup.sh" > "$T/run.out" 2>&1
}
printf 'plain-env\n' > "$T/tarmode"
bk2; RC=$?
[ "$RC" -ne 0 ] && ok || bad "S2: a tarball listing plaintext env/ exited 0"
[ ! -e "$T/s3/bkt/$KEY" ] && ok || bad "S2: a tarball listing plaintext env/ was uploaded"
grep -q 'leak-check FAILED (1 plaintext env entries' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "S2: no plaintext leak-check ALERTS line: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
printf 'no-age\n' > "$T/tarmode"
bk2; RC=$?
[ "$RC" -ne 0 ] && ok || bad "S3: a tarball with no env.tar.age exited 0"
[ ! -e "$T/s3/bkt/$KEY" ] && ok || bad "S3: a tarball with no env.tar.age was uploaded"
grep -q 'env.tar.age is not in it' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "S3: no missing-env.tar.age ALERTS line: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"

# ── R1: restore finds the oldest of 5000 listed snapshots ───────────────────
# Sorted, the oldest is row 1 of ~190KB of rows: grep -q's first-line exit.
printf '5000\n' > "$T/s3/list-n"
env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$T/h" ETC_HARNESS_ENV="$T/no-such-etc" \
    RESTORE_NOW="$NOW" bash "$DIR/bin/state-restore.sh" small 20200101T000000Z \
    --dest "$T/pull" --live "$T/live" > "$T/rr.out" 2>&1
grep -q '^no backup ' "$T/rr.out" \
  && bad "R1: a listed snapshot was called missing: $(head -3 "$T/rr.out")" || ok
grep -q 'REFUSED: get-object rc=255 for small/20200101T000000Z.tar.zst' "$T/rr.out" \
  && ok || bad "R1: the run did not reach get-object for the oldest key: $(head -3 "$T/rr.out")"
# R2: a ts that is not listed is still `no backup` (the check did not go blind).
env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$T/h" ETC_HARNESS_ENV="$T/no-such-etc" \
    RESTORE_NOW="$NOW" bash "$DIR/bin/state-restore.sh" small 20991231T235959Z \
    --dest "$T/pull2" --live "$T/live" > "$T/rr.out" 2>&1
RC=$?
[ "$RC" -eq 1 ] && grep -q '^no backup small/20991231T235959Z.tar.zst' "$T/rr.out" \
  && ok || bad "R2: an unlisted ts did not answer no backup (rc=$RC): $(head -3 "$T/rr.out")"

echo "state-backup-sigpipe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
