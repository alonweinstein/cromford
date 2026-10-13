#!/bin/bash
# tests/cli-update-test.sh — bin/cli-update.sh brings claude/codex to latest
# whatever way they are installed, and its exit code means exactly one thing.
#
# DRIVEN, NOT GREPPED. Every claim here is about behaviour under a specific
# install shape the fleet has actually had, and a grep passes on a version that
# gets each of them wrong:
#   1. npm-only (the hub): npm updates, PATH sees the new version, a CSV row and
#      a DB push carry before/after, no secret reaches stdout/log/CSV.
#   2. a second run is a no-op with ok=1.
#   3. native + npm on one box (project-9's claude): the native launcher gets
#      `install latest`, the npm link in cron's PATH is repointed at the newer
#      native install (old link backed up), and `command -v` agrees afterwards.
#   4. EEXIST (project-9's codex: a hand-made link in npm's bin dir): retried
#      with --force ONCE, the legacy-prefix link relinked to the new install.
#   5. a network failure is NOT retried with --force and is not fatal.
#   6. WORSE afterwards -> exit 1; MISSING afterwards -> exit 1.
#   7. worker down -> the update still runs, exit 0, CSV row written.
# Run from anywhere: tests/cli-update-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
BASE="$T"
SECRET="test-secret-DO-NOT-LEAK-9f3a"
# coreutils for the runs, WITHOUT the machine's own claude/codex/npm/curl: the
# hub runs this test with a real claude in /usr/bin, and "missing" must mean
# missing. Built once, shared by every scratch box.
mkdir -p "$BASE/sysbin"
for f in /usr/bin/* /bin/*; do
  n=$(basename "$f"); case "$n" in claude|codex|npm|curl) continue ;; esac
  [ -e "$BASE/sysbin/$n" ] || ln -s "$f" "$BASE/sysbin/$n" 2>/dev/null
done

# --- a scratch box ----------------------------------------------------------
# $T/usr        npm's global prefix (lib/node_modules, bin/) = cron's PATH dir
# $T/usr/local  the legacy prefix + the login PATH dir
# $T/home       HOME, for the native launcher at .local/bin/claude
new_box() {
  local T; T=$(mktemp -d "$BASE/box-XXXXXX")
  mkdir -p "$T/harness/logs" "$T/harness/state" "$T/harness/env" "$T/harness/bin" "$T/harness/flags" \
           "$T/usr/bin" "$T/usr/lib/node_modules" "$T/usr/local/bin" "$T/usr/local/lib/node_modules" \
           "$T/home/.local/bin" "$T/home/.local/share/claude/versions" "$T/fakebin"
  ln -s "$BASE/sysbin" "$T/sysbin"
  cp "$DIR/bin/jobs-client.sh" "$T/harness/bin/jobs-client.sh"
  mkdir -p "$T/harness/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/harness/bin/lib/jobs/"
  echo "HARNESS_SECRET=$SECRET" > "$T/harness/env/global.env"
  echo "testbox" > "$T/harness/state/box-id"
  # fake npm: records calls; installs by writing the package's VERSION and its
  # bin link into the prefix it is told (NPM_PREFIX), per NPM_MODE_<cli>.
  cat > "$T/fakebin/npm" <<'NPM'
#!/bin/bash
echo "$*" >> "$NPM_CALLS"
[ "$1" = prefix ] && { echo "$NPM_PREFIX"; exit 0; }
FORCE=0; PKG=""
for a in "$@"; do case "$a" in --force) FORCE=1 ;; @*) PKG="${a%@latest}" ;; esac; done
case "$PKG" in *claude-code) CLI=claude; ENTRY=claude.exe ;; *codex) CLI=codex; ENTRY=codex.js ;; *) exit 1 ;; esac
MODE_VAR="NPM_MODE_$CLI"; MODE="${!MODE_VAR:-ok}"
LATEST_VAR="NPM_LATEST_$CLI"; LATEST="${!LATEST_VAR:-9.9.9}"
case "$MODE" in
  down) echo "npm ERR! code ENOTFOUND"; echo "npm ERR! network request to https://registry.npmjs.org failed"; exit 1 ;;
  eexist) if [ "$FORCE" = 0 ]; then echo "npm ERR! code EEXIST"; echo "npm ERR! path $NPM_PREFIX/bin/$CLI"; echo "npm ERR! EEXIST: file already exists"; exit 1; fi ;;
  downgrade) LATEST="0.0.1" ;;
esac
D="$NPM_PREFIX/lib/node_modules/$PKG"; mkdir -p "$D/bin"
printf '#!/bin/bash\ncase "$1" in --version) echo "$(cat "$(dirname "$(readlink -f "$0")")/../VERSION") (fake $CLI)";; esac\n' > "$D/bin/$ENTRY"
chmod +x "$D/bin/$ENTRY"; echo "$LATEST" > "$D/VERSION"
ln -sfn "$D/bin/$ENTRY" "$NPM_PREFIX/bin/$CLI"
echo "changed 1 package"
NPM
  chmod +x "$T/fakebin/npm"
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
# npm_pkg <box> <cli> <version> [prefix]  — an installed npm package + bin link
npm_pkg() {
  local T="$1" cli="$2" v="$3" P="${4:-$1/usr}" pkg entry
  case "$cli" in claude) pkg="@anthropic-ai/claude-code"; entry=claude.exe ;; codex) pkg="@openai/codex"; entry=codex.js ;; esac
  mkdir -p "$P/lib/node_modules/$pkg/bin" "$P/bin"
  printf '#!/bin/bash\ncase "$1" in --version) echo "$(cat "$(dirname "$(readlink -f "$0")")/../VERSION") (fake %s)";; esac\n' "$cli" > "$P/lib/node_modules/$pkg/bin/$entry"
  chmod +x "$P/lib/node_modules/$pkg/bin/$entry"; echo "$v" > "$P/lib/node_modules/$pkg/VERSION"
  ln -sfn "$P/lib/node_modules/$pkg/bin/$entry" "$P/bin/$cli"
}
# native_claude <box> <version> — the native launcher shape: ~/.local/bin/claude
# -> ~/.local/share/claude/versions/<v>; `install latest` adds NATIVE_LATEST.
native_claude() {
  local T="$1" v="$2" VD="$1/home/.local/share/claude/versions"
  cat > "$VD/$v" <<'NAT'
#!/bin/bash
ME=$(readlink -f "$0"); VD=$(dirname "$ME")
case "$1" in
  --version) echo "$(basename "$ME") (Claude Code)" ;;
  install) echo "install $2" >> "$NATIVE_CALLS"
           cp "$ME" "$VD/$NATIVE_LATEST"; ln -sfn "$VD/$NATIVE_LATEST" "$VD/../../../bin/claude"; echo "installed $NATIVE_LATEST" ;;
esac
NAT
  chmod +x "$VD/$v"; ln -sfn "$VD/$v" "$T/home/.local/bin/claude"
}
# run <box> [env...] -> OUT, RC; PATH = cron's view ($T/usr/bin) + shims only
run() {
  local T="$1"; shift
  # The seven cases below are claude/codex INSTALL SHAPES built around a fake
  # npm; grok is a native install with no npm package at all and its own suite
  # (tests/cli-update.bh-1494-test.sh). Without this pin every case would also
  # run grok's installer, which does not exist on this scratch box.
  OUT=$(env -i PATH="$T/usr/bin:$T/fakebin:$T/sysbin" HOME="$T/home" "$@" \
        CLI_UPDATE_CLIS="claude codex" \
        HARNESS="$T/harness" CLI_UPDATE_HOME="$T/home" CLI_UPDATE_NPM_PREFIX="$T/usr" \
        CLI_UPDATE_NPM_PREFIXES="$T/usr $T/usr/local" CLI_UPDATE_LINK_DIRS="$T/usr/local/bin $T/usr/bin" \
        NPM_PREFIX="$T/usr" NPM_CALLS="$T/npm.calls" NATIVE_CALLS="$T/native.calls" REQ_SINK="$T/req.log" \
        bash "$DIR/bin/cli-update.sh" 2>"$T/stderr"); RC=$?
}
no_leak() { # no_leak <box> <label>
  local T="$1"
  if grep -rq "$SECRET" "$T/harness/logs" "$T/stderr" 2>/dev/null || grep -q "$SECRET" <<<"$OUT"; then
    bad "$2: the secret leaked into stdout/log/CSV"
  else ok; fi
}

# ===========================================================================
# 1. npm-only (the hub's shape)
# ===========================================================================
T=$(new_box); npm_pkg "$T" claude 1.0.0; npm_pkg "$T" codex 0.150.1
run "$T" NPM_LATEST_claude=1.0.1 NPM_LATEST_codex=0.153.4
[ "$RC" = 0 ] && ok || bad "1: npm-only run rc=$RC ($OUT)"
grep -q '^claude 1.0.0 -> 1.0.1 method=npm ok=1' <<<"$OUT" && ok || bad "1: claude stdout line: $OUT"
grep -q '^codex 0.150.1 -> 0.153.4 method=npm ok=1' <<<"$OUT" && ok || bad "1: codex stdout line: $OUT"
CSV="$T/harness/logs/cli-versions.csv"
[ "$(head -1 "$CSV")" = "at,box,cli,version_before,version_after,method,ok,path,note" ] && ok || bad "1: CSV header: $(head -1 "$CSV")"
grep -q ',testbox,claude,1.0.0,1.0.1,npm,1,' "$CSV" && ok || bad "1: CSV claude row missing: $(cat "$CSV")"
[ "$(grep -c 'POST .*/api/metrics/cli-versions' "$T/req.log")" = 2 ] && ok || bad "1: expected 2 DB pushes: $(cat "$T/req.log")"
grep 'cli-versions' "$T/req.log" | head -1 | sed 's/^POST [^ ]* //' \
  | jq -e '.rows[0] | .box=="testbox" and .cli=="claude" and .version_before=="1.0.0" and .version_after=="1.0.1" and .method=="npm" and .ok=="1" and .source=="update"' >/dev/null \
  && ok || bad "1: DB row shape: $(head -1 "$T/req.log")"
grep -q 'Bearer' "$T/req.log" && bad "1: request log carries the bearer (curl stub should not see it in body)" || ok
no_leak "$T" "1"
[ "$(grep -c '@anthropic-ai/claude-code@latest' "$T/npm.calls")" = 1 ] && ok || bad "1: npm called $(cat "$T/npm.calls")"
grep -q -- '--force' "$T/npm.calls" && bad "1: --force used without an EEXIST" || ok

# 2. second run: nothing moves, still ok
run "$T" NPM_LATEST_claude=1.0.1 NPM_LATEST_codex=0.153.4
[ "$RC" = 0 ] && grep -q '^claude 1.0.1 -> 1.0.1 method=npm ok=1' <<<"$OUT" && ok || bad "2: idempotent run rc=$RC: $OUT"
grep -q 'relink' <<<"$OUT" && bad "2: a no-op run relinked something: $OUT" || ok

# ===========================================================================
# 3. native + npm on one box (project-9's claude, 2026-09-02..05)
#    login PATH:  /usr/local/bin/claude -> ~/.local/bin/claude (native 2.1.258)
#    cron PATH:   /usr/bin/claude -> npm 2.1.261
# ===========================================================================
T=$(new_box); npm_pkg "$T" claude 2.1.261; native_claude "$T" 2.1.258
ln -sfn "$T/home/.local/bin/claude" "$T/usr/local/bin/claude"
npm_pkg "$T" codex 0.153.4
run "$T" NPM_LATEST_claude=2.1.261 NPM_LATEST_codex=0.153.4 NATIVE_LATEST=2.1.262
[ "$RC" = 0 ] && ok || bad "3: rc=$RC ($OUT)"
grep -q 'install latest' "$T/native.calls" 2>/dev/null && ok || bad "3: native launcher never got 'install latest'"
[ "$(readlink -f "$T/home/.local/bin/claude")" = "$T/home/.local/share/claude/versions/2.1.262" ] && ok || bad "3: native not updated"
grep -q '^claude 2.1.261 -> 2.1.262 method=native+npm ok=1' <<<"$OUT" && ok || bad "3: stdout: $OUT"
# cron's link now follows the native launcher (so future native updates flow), old link backed up
[ "$(readlink "$T/usr/bin/claude")" = "$T/home/.local/bin/claude" ] && ok || bad "3: /usr/bin/claude not repointed: $(readlink "$T/usr/bin/claude")"
ls "$T/usr/bin"/claude.bak-* >/dev/null 2>&1 && ok || bad "3: no backup of the old /usr/bin/claude link"
grep -q 'relinked' <<<"$OUT" && ok || bad "3: relink not reported: $OUT"
# the login-view link was already on the native launcher: untouched
[ "$(readlink "$T/usr/local/bin/claude")" = "$T/home/.local/bin/claude" ] && ok || bad "3: /usr/local/bin/claude changed"
ls "$T/usr/local/bin"/claude.bak-* >/dev/null 2>&1 && bad "3: a link that was already right was backed up" || ok

# ===========================================================================
# 4. EEXIST (project-9's codex): package under the legacy /usr/local prefix,
#    hand-made /usr/bin/codex -> /usr/local/bin/codex in npm's own bin dir.
# ===========================================================================
T=$(new_box); npm_pkg "$T" claude 1.0.1; npm_pkg "$T" codex 0.150.1 "$T/usr/local"
ln -sfn "$T/usr/local/bin/codex" "$T/usr/bin/codex"
run "$T" NPM_LATEST_claude=1.0.1 NPM_LATEST_codex=0.153.4 NPM_MODE_codex=eexist
[ "$RC" = 0 ] && ok || bad "4: rc=$RC ($OUT)"
[ "$(grep -c 'codex@latest' "$T/npm.calls")" = 2 ] && ok || bad "4: expected exactly one retry: $(cat "$T/npm.calls")"
grep 'codex@latest' "$T/npm.calls" | tail -1 | grep -q -- '--force' && ok || bad "4: retry was not --force"
grep -q -- '--force' <<<"$(grep 'codex@latest' "$T/npm.calls" | head -1)" && bad "4: first attempt already forced" || ok
grep -q '^codex 0.150.1 -> 0.153.4 method=npm ok=1' <<<"$OUT" && ok || bad "4: stdout: $OUT"
grep -q 'npm-forced' <<<"$OUT" && ok || bad "4: forced retry not in the note: $OUT"
# the legacy login-PATH link followed the new install too
[ "$(readlink -f "$T/usr/local/bin/codex")" = "$T/usr/lib/node_modules/@openai/codex/bin/codex.js" ] && ok || bad "4: legacy /usr/local/bin/codex still -> $(readlink -f "$T/usr/local/bin/codex")"
grep -q "relinked $T/usr/local/bin/codex" "$T/harness/logs/cli-update.log" && ok || bad "4: relink of the legacy link not logged"
no_leak "$T" "4"

# ===========================================================================
# 5. a network failure: no --force, not fatal, old binary kept
# ===========================================================================
T=$(new_box); npm_pkg "$T" claude 1.0.0; npm_pkg "$T" codex 0.150.1
run "$T" NPM_MODE_claude=down NPM_LATEST_codex=0.153.4
[ "$RC" = 0 ] && ok || bad "5: a failed update with the old binary intact must not fail the tick (rc=$RC)"
grep -q '^claude 1.0.0 -> 1.0.0 method=npm ok=1.*npm-failed' <<<"$OUT" && ok || bad "5: stdout: $OUT"
grep -q -- '--force' "$T/npm.calls" && bad "5: --force after a network error" || ok
grep -q 'npm update FAILED' "$T/harness/logs/cli-update.log" && ok || bad "5: failure not logged"

# ===========================================================================
# 6. WORSE -> exit 1; MISSING -> exit 1
# ===========================================================================
T=$(new_box); npm_pkg "$T" claude 1.0.0; npm_pkg "$T" codex 0.150.1
run "$T" NPM_MODE_claude=downgrade NPM_LATEST_codex=0.153.4
[ "$RC" = 1 ] && ok || bad "6a: a downgrade must exit 1 (rc=$RC): $OUT"
grep -q '^claude 1.0.0 -> 0.0.1 method=npm ok=0' <<<"$OUT" && ok || bad "6a: stdout: $OUT"
grep -q '^codex 0.150.1 -> 0.153.4 method=npm ok=1' <<<"$OUT" && ok || bad "6a: the other CLI still updated: $OUT"
grep -q ',claude,1.0.0,0.0.1,npm,0,' "$T/harness/logs/cli-versions.csv" && ok || bad "6a: CSV ok=0 row missing"
T=$(new_box)   # nothing installed at all, npm down: bootstrap attempted, still missing
run "$T" NPM_MODE_claude=down NPM_MODE_codex=down
[ "$RC" = 1 ] && ok || bad "6b: missing CLIs must exit 1 (rc=$RC): $OUT"
grep -q '^claude missing -> missing method=npm ok=0' <<<"$OUT" && ok || bad "6b: stdout: $OUT"
grep -q 'bootstrapping through npm' "$T/harness/logs/cli-update.log" && ok || bad "6b: bootstrap path not taken"

# ===========================================================================
# 7. worker down: the update is not the DB's hostage
# ===========================================================================
T=$(new_box); npm_pkg "$T" claude 1.0.0; npm_pkg "$T" codex 0.150.1
run "$T" NPM_LATEST_claude=1.0.1 NPM_LATEST_codex=0.153.4 CURL_MODE=down
[ "$RC" = 0 ] && grep -q '^claude 1.0.0 -> 1.0.1 method=npm ok=1' <<<"$OUT" && ok || bad "7: rc=$RC: $OUT"
grep -q ',claude,1.0.0,1.0.1,npm,1,' "$T/harness/logs/cli-versions.csv" && ok || bad "7: CSV row missing with the worker down"
grep -q 'DB push skipped/failed' "$T/harness/logs/cli-update.log" && ok || bad "7: worker outage not logged"

# --- the shared version lib, the matrix the plan asked for ---------------------
# shellcheck source=bin/lib/cli-version.sh
. "$DIR/bin/lib/cli-version.sh"
cli_version_ge 2.1.259 2.1.250 && ok || bad "lib: 2.1.259 >= 2.1.250"
cli_version_ge 2.10.0 2.9.9   && ok || bad "lib: 2.10.0 >= 2.9.9"
cli_version_ge 3.0 2.99.99    && ok || bad "lib: 3.0 >= 2.99.99"
cli_version_ge 2.1 2.1.0      && ok || bad "lib: 2.1 == 2.1.0"
cli_version_ge 2.1.250 2.1.251 && bad "lib: 2.1.250 >= 2.1.251 must fail" || ok
cli_version_ge missing 1.0     && bad "lib: missing must compare older" || ok
cli_version_gt 2.1.261 2.1.261 && bad "lib: equal is not gt" || ok
[ "$(cli_version_parse 'codex-cli 0.153.4')" = 0.153.4 ] && ok || bad "lib: parse codex"
[ "$(cli_version_parse '2.1.261 (Claude Code)')" = 2.1.261 ] && ok || bad "lib: parse claude"
[ "$(cli_min_for_model "$DIR/catalog/cli-min-versions.json" claude-fable-5-1)" = "claude 2.1.251" ] && ok || bad "lib: catalog floor for fable"
cli_min_for_model "$DIR/catalog/cli-min-versions.json" no-such-model >/dev/null && bad "lib: unknown model must yield nothing" || ok

echo "cli-update-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
