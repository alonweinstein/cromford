#!/bin/bash
# tests/cli-update.bh-1494-test.sh — bin/cli-update.sh treats grok as a
# first-class runner CLI: it updates daily like claude and codex, it is read the
# way the LANES resolve it, and its exit code means exactly one thing.
#
# WHY A SECOND SUITE AND NOT MORE CASES IN tests/cli-update-test.sh. That suite
# is seven claude/codex INSTALL SHAPES (npm-only, native+npm, EEXIST, network
# failure, downgrade, bootstrap, worker down) built around a fake npm. grok has
# no npm package at all — xAI ships a native binary at ~/.grok/bin/grok ->
# ~/.grok/downloads/grok-linux-x64 and the update mechanism is re-running the
# installer — so every case here needs a different scaffold, and bolting it onto
# the npm one would make both harder to read.
#
# THE FAILURE THIS PINS (BH-1494, 2026-09-22): the fleet's grok CLIs sat at
# 0.2.118 on six boxes, 1.0.5 on project-6, 1.0.13 on project-1-1 and MISSING on
# small, while xAI's current release was 1.0.40 and Grok 4.7 had already shipped
# as Grok Build's default model. Nothing updated them, and nothing said so.
#
# DRIVEN, NOT GREPPED. Every case runs the real bin/cli-update.sh against a
# scratch box with a fake installer on PATH, and reads stdout, the CSV, the DB
# request log and the on-disk ~/.grok tree back afterwards.
#   0. grok is in the DEFAULT CLI list (no CLI_UPDATE_CLIS set) — red on main.
#   1. old -> new: stdout line, CSV row, DB push, previous release retained,
#      no secret anywhere.
#   2. the installer REMOVES the binary -> ok=0 and rc 1.
#   3. the installer downgrades -> ok=0, rc 1, the newer release kept for the
#      one-mv rollback.
#   4. the installer fails with the old binary intact -> ok=1, rc 0, logged.
#   5. a no-op day must not clobber the rollback copy.
#   6. nothing installed at all: bootstrap, and a dead installer is still fatal.
#   7. the shared version lib parses grok's own --version line and the catalog
#      floor for grok-4.7.
#   8. the installer transcript is redacted on the way to the log.
# Run from anywhere: tests/cli-update.bh-1494-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
BASE="$T"
SECRET="grok-secret-DO-NOT-LEAK-71bd"
# Assembled at runtime, never written as a literal: this tree is published to a
# public mirror and bin/share/leakcheck refuses any key-shaped string in it
# (tests/share-mirror-clean-test.sh). The VALUE is a real `sk-ant-…` shape, so
# §8 still exercises the actual redact() regex in bin/cli-update.sh.
INSTALLER_TOKEN="sk-$(printf ant)-api03-FAKE-INSTALLER-TRANSCRIPT-TOKEN"

# coreutils WITHOUT the machine's own claude/codex/npm/curl/grok: this suite
# runs on boxes that have a real grok in /usr/local/bin, and "missing" must mean
# missing.
mkdir -p "$BASE/sysbin"
for f in /usr/bin/* /bin/*; do
  n=$(basename "$f"); case "$n" in claude|codex|npm|curl|grok) continue ;; esac
  [ -e "$BASE/sysbin/$n" ] || ln -s "$f" "$BASE/sysbin/$n" 2>/dev/null
done

# --- a scratch box ----------------------------------------------------------
new_box() {
  local T; T=$(mktemp -d "$BASE/box-XXXXXX")
  mkdir -p "$T/harness/logs" "$T/harness/state" "$T/harness/env" "$T/harness/bin" \
           "$T/usr/bin" "$T/usr/local/bin" "$T/home/.local/bin" "$T/fakebin"
  ln -s "$BASE/sysbin" "$T/sysbin"
  cp "$DIR/bin/jobs-client.sh" "$T/harness/bin/jobs-client.sh"
  mkdir -p "$T/harness/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/harness/bin/lib/jobs/"
  echo "HARNESS_SECRET=$SECRET" > "$T/harness/env/global.env"
  echo "testbox" > "$T/harness/state/box-id"
  # The fake xAI installer, standing in for `curl -fsSL https://x.ai/cli/install.sh
  # | bash`. It writes exactly what the real one writes — the downloads binary
  # and the ~/.grok/bin/grok symlink into it — and never touches /usr/bin,
  # which is the whole reason cli-update.sh reads the launcher before PATH.
  cat > "$T/fakebin/install.sh" <<INSTALL
#!/bin/bash
DL="\$HOME/.grok/downloads"; BIN="\$HOME/.grok/bin"
echo "xai grok installer (fake) auth=$INSTALLER_TOKEN"
case "\${INSTALL_MODE:-ok}" in
  down)      echo "curl: (6) Could not resolve host: x.ai" >&2; exit 1 ;;
  fail)      echo "install: downloaded binary failed --version verification" >&2; exit 1 ;;
  remove)    rm -f "\$DL/grok-linux-x64" "\$BIN/grok"; echo "removed"; exit 0 ;;
  downgrade) V=0.9.0 ;;
  *)         V="\${INSTALL_LATEST:-1.0.40}" ;;
esac
mkdir -p "\$DL" "\$BIN"
printf '#!/bin/bash\n[ "\$1" = --version ] && echo "grok %s (eb1a2256660d)"\nexit 0\n' "\$V" > "\$DL/grok-linux-x64"
chmod +x "\$DL/grok-linux-x64"
ln -sfn "\$DL/grok-linux-x64" "\$BIN/grok"
echo "installed grok \$V"
INSTALL
  chmod +x "$T/fakebin/install.sh"
  cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
printf '{"accepted":1,"inserted":1}\n200\n'
CURL
  chmod +x "$T/fakebin/curl"
  echo "$T"
}

# grok_at <box> <version> — the shape a real box carries: the downloads binary
# plus the launcher symlink into it. No /usr/bin link, exactly like xAI's
# installer leaves it.
grok_at() {
  local T="$1" v="$2"
  mkdir -p "$T/home/.grok/downloads" "$T/home/.grok/bin"
  printf '#!/bin/bash\n[ "$1" = --version ] && echo "grok %s (eb1a2256660d)"\nexit 0\n' "$v" \
    > "$T/home/.grok/downloads/grok-linux-x64"
  chmod +x "$T/home/.grok/downloads/grok-linux-x64"
  ln -sfn "$T/home/.grok/downloads/grok-linux-x64" "$T/home/.grok/bin/grok"
}
grok_ver() { # grok_ver <binary> -> its version, or "-"
  [ -x "$1" ] || { echo -; return 0; }
  "$1" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1
}

# run <box> [env...] -> OUT, RC; PATH is cron's view plus the shims only.
run() {
  local T="$1"; shift
  OUT=$(env -i PATH="$T/usr/bin:$T/fakebin:$T/sysbin" HOME="$T/home" "$@" \
        HARNESS="$T/harness" CLI_UPDATE_HOME="$T/home" CLI_UPDATE_NPM_PREFIX="$T/usr" \
        CLI_UPDATE_NPM_PREFIXES="$T/usr $T/usr/local" CLI_UPDATE_LINK_DIRS="$T/usr/local/bin $T/usr/bin" \
        CLI_UPDATE_GROK_INSTALLER="install.sh" REQ_SINK="$T/req.log" \
        bash "$DIR/bin/cli-update.sh" 2>"$T/stderr"); RC=$?
}
no_leak() { # no_leak <box> <label>
  local T="$1"
  if grep -rq "$SECRET" "$T/harness/logs" "$T/stderr" 2>/dev/null || grep -q "$SECRET" <<<"$OUT"; then
    bad "$2: the secret leaked into stdout/log/CSV"
  else ok; fi
}

# ===========================================================================
# 0. grok is in the DEFAULT list. Red on main: CLIS defaults to "claude codex",
#    so no grok line is printed at all. rc is NOT asserted here — claude and
#    codex are genuinely missing on this scratch box, which is their own rc 1.
# ===========================================================================
T0BOX=$(new_box); grok_at "$T0BOX" 1.0.5
run "$T0BOX" INSTALL_LATEST=1.0.40
grep -q '^grok 1.0.5 -> 1.0.40 ' <<<"$OUT" && ok \
  || bad "0: grok must be updated with NO CLI_UPDATE_CLIS set (default list): $OUT"

# ===========================================================================
# 1. the upgrade: 1.0.5 -> 1.0.40
# ===========================================================================
T=$(new_box); grok_at "$T" 1.0.5
run "$T" CLI_UPDATE_CLIS=grok INSTALL_LATEST=1.0.40
[ "$RC" = 0 ] && ok || bad "1: rc=$RC ($OUT)"
grep -q '^grok 1.0.5 -> 1.0.40 method=native ok=1' <<<"$OUT" && ok || bad "1: stdout: $OUT"
CSV="$T/harness/logs/cli-versions.csv"
[ "$(head -1 "$CSV")" = "at,box,cli,version_before,version_after,method,ok,path,note" ] && ok || bad "1: CSV header: $(head -1 "$CSV")"
grep -q ',testbox,grok,1.0.5,1.0.40,native,1,' "$CSV" && ok || bad "1: CSV row: $(cat "$CSV")"
[ "$(grep -c 'POST .*/api/metrics/cli-versions' "$T/req.log")" = 1 ] && ok || bad "1: expected one DB push: $(cat "$T/req.log")"
grep 'cli-versions' "$T/req.log" | head -1 | sed 's/^POST [^ ]* //' \
  | jq -e '.rows[0] | .box=="testbox" and .cli=="grok" and .version_before=="1.0.5" and .version_after=="1.0.40" and .method=="native" and .ok=="1" and .source=="update"' >/dev/null \
  && ok || bad "1: DB row shape: $(head -1 "$T/req.log")"
# the launcher the lanes run is the one that moved
[ "$(grok_ver "$T/home/.grok/bin/grok")" = 1.0.40 ] && ok || bad "1: launcher still $(grok_ver "$T/home/.grok/bin/grok")"
# ...and the previous release is one mv away
[ "$(grok_ver "$T/home/.grok/downloads.prev/grok-linux-x64")" = 1.0.5 ] && ok \
  || bad "1: downloads.prev must hold 1.0.5, holds $(grok_ver "$T/home/.grok/downloads.prev/grok-linux-x64")"
[ -e "$T/home/.grok/downloads.prev.tmp" ] && bad "1: the snapshot staging dir was left behind" || ok
grep -q 'rollback: mv ' "$T/harness/logs/cli-update.log" && ok || bad "1: the rollback command is not in the log"
no_leak "$T" "1"

# ===========================================================================
# 2. the installer REMOVES the binary (acceptance bullet 1, second case)
# ===========================================================================
T=$(new_box); grok_at "$T" 1.0.40
run "$T" CLI_UPDATE_CLIS=grok INSTALL_MODE=remove
[ "$RC" = 1 ] && ok || bad "2: a CLI missing after the update must exit 1 (rc=$RC): $OUT"
grep -q '^grok 1.0.40 -> missing method=native ok=0' <<<"$OUT" && ok || bad "2: stdout: $OUT"
grep -q ',testbox,grok,1.0.40,missing,native,0,' "$T/harness/logs/cli-versions.csv" && ok || bad "2: CSV ok=0 row: $(cat "$T/harness/logs/cli-versions.csv")"

# ===========================================================================
# 3. the installer downgrades (xAI pulled a build)
# ===========================================================================
T=$(new_box); grok_at "$T" 1.0.40
run "$T" CLI_UPDATE_CLIS=grok INSTALL_MODE=downgrade
[ "$RC" = 1 ] && ok || bad "3: a downgrade must exit 1 (rc=$RC): $OUT"
grep -q '^grok 1.0.40 -> 0.9.0 method=native ok=0' <<<"$OUT" && ok || bad "3: stdout: $OUT"
grep -q 'WORSE after update' "$T/harness/logs/cli-update.log" && ok || bad "3: WORSE not logged"
[ "$(grok_ver "$T/home/.grok/downloads.prev/grok-linux-x64")" = 1.0.40 ] && ok \
  || bad "3: the pulled-back release must be recoverable: downloads.prev holds $(grok_ver "$T/home/.grok/downloads.prev/grok-linux-x64")"

# ===========================================================================
# 4. the installer fails, the old binary is intact: a log line, not a fatal
# ===========================================================================
T=$(new_box); grok_at "$T" 1.0.40
run "$T" CLI_UPDATE_CLIS=grok INSTALL_MODE=fail
[ "$RC" = 0 ] && ok || bad "4: a failed update that kept the old binary must not fail the tick (rc=$RC): $OUT"
grep -q '^grok 1.0.40 -> 1.0.40 method=native ok=1.*installer-failed' <<<"$OUT" && ok || bad "4: stdout: $OUT"
grep -q 'installer FAILED' "$T/harness/logs/cli-update.log" && ok || bad "4: the failure is not in the log"
[ -e "$T/home/.grok/downloads.prev.tmp" ] && bad "4: the snapshot staging dir survived a failed run" || ok

# ===========================================================================
# 5. a NO-OP day must not clobber the rollback copy. Snapshotting every run
#    would overwrite the real previous release with a copy of the current one,
#    and the one-mv rollback would restore the broken build.
# ===========================================================================
T=$(new_box); grok_at "$T" 1.0.5
run "$T" CLI_UPDATE_CLIS=grok INSTALL_LATEST=1.0.40
[ "$(grok_ver "$T/home/.grok/downloads.prev/grok-linux-x64")" = 1.0.5 ] && ok || bad "5: setup did not retain 1.0.5"
run "$T" CLI_UPDATE_CLIS=grok INSTALL_LATEST=1.0.40
grep -q '^grok 1.0.40 -> 1.0.40 method=native ok=1' <<<"$OUT" && ok || bad "5: the no-op run: $OUT"
[ "$(grok_ver "$T/home/.grok/downloads.prev/grok-linux-x64")" = 1.0.5 ] && ok \
  || bad "5: a no-op day overwrote the rollback copy (now $(grok_ver "$T/home/.grok/downloads.prev/grok-linux-x64"))"
[ -e "$T/home/.grok/downloads.prev.tmp" ] && bad "5: staging dir left behind on a no-op day" || ok

# ===========================================================================
# 6. nothing installed at all (small's shape on 2026-09-22)
# ===========================================================================
T=$(new_box)
run "$T" CLI_UPDATE_CLIS=grok INSTALL_LATEST=1.0.40
[ "$RC" = 0 ] && ok || bad "6: bootstrap rc=$RC: $OUT"
grep -q '^grok missing -> 1.0.40 method=native ok=1' <<<"$OUT" && ok || bad "6: bootstrap stdout: $OUT"
T=$(new_box)
run "$T" CLI_UPDATE_CLIS=grok INSTALL_MODE=down
[ "$RC" = 1 ] && ok || bad "6: a CLI still missing after a dead installer must exit 1 (rc=$RC): $OUT"
grep -q '^grok missing -> missing method=native ok=0' <<<"$OUT" && ok || bad "6: dead-installer stdout: $OUT"

# ===========================================================================
# 7. the shared version lib: grok's own --version line and the catalog floor
# ===========================================================================
# shellcheck source=bin/lib/cli-version.sh
. "$DIR/bin/lib/cli-version.sh"
[ "$(cli_version_parse 'grok 1.0.40 (eb1a2256660d)')" = 1.0.40 ] && ok || bad "7: parse grok --version"
[ "$(cli_min_for_model "$DIR/catalog/cli-min-versions.json" grok-4.7)" = "grok 1.0.40" ] && ok \
  || bad "7: catalog floor for grok-4.7: got '$(cli_min_for_model "$DIR/catalog/cli-min-versions.json" grok-4.7)'"
[ "$(cli_min_for_model "$DIR/catalog/cli-min-versions.json" grok-4.6)" = "grok 1.0.40" ] && ok \
  || bad "7: catalog floor for grok-4.6: got '$(cli_min_for_model "$DIR/catalog/cli-min-versions.json" grok-4.6)'"

# ===========================================================================
# 8. an installer transcript is a transcript of an installer, and installers
#    echo their environment when they fail.
# ===========================================================================
T=$(new_box); grok_at "$T" 1.0.5
run "$T" CLI_UPDATE_CLIS=grok INSTALL_LATEST=1.0.40
grep -q "$INSTALLER_TOKEN" "$T/harness/logs/cli-update.log" && bad "8: the installer's token reached the log verbatim" || ok
grep -q 'REDACTED' "$T/harness/logs/cli-update.log" && ok || bad "8: the installer transcript never reached the log at all"

echo "cli-update.bh-1494-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
