#!/bin/bash
# tests/fly-provision-token-quoting-test.sh — the OTHER writer of a Fly token
# into env/fly.env must quote it too.
#
# BH-666's sweep (`grep -rn '>>.*\.env' bin/`) found one real second hit:
# bin/fly-provision.sh appended the same variable family (FLY_API_TOKEN_<PROJECT>)
# into the same file with an unquoted printf — `FLY_API_TOKEN_PROJ_X=FlyV1 fm2_…`.
# A Fly token CONTAINS A SPACE, so every script that sources env/fly.env read the
# token as `FlyV1` and then tried to run `fm2_…` as a command. The next new
# project onboarded through fly-provision.sh reproduced the defect byte for byte.
#
# The assertion is what a READER gets back, not what the line looks like: the
# fixture runs the real script against a scratch $HARNESS with flyctl stubbed,
# then sources the file the way bin/fly-api.sh and friends do.
# Run from anywhere: tests/fly-provision-token-quoting-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# provision_fixture <case-dir> — scratch $HARNESS + a flyctl that answers every
# call step 6 has to get past. BOTH stub names exist: the script resolves
# `command -v fly || command -v flyctl`, so a real fly elsewhere on PATH would
# otherwise shadow the stub. bin/fly-provision.sh reads its root through the
# `HARNESS="${HARNESS:-/root/harness}"` seam (BH-1057), so the script is copied
# verbatim and provision_run exports the scratch root — nothing in the file is
# rewritten. The seam is PINNED below: if it ever goes back to a hardcoded root,
# this fixture would append a stub token to the live env/fly.env, so the run
# refuses instead.
provision_fixture() {
  local F="$1"
  mkdir -p "$F/h/env" "$F/h/state/fly" "$F/h/locks" "$F/fb"
  printf 'FLY_ORG=testorg\nFLY_API_TOKEN="FlyV1 fm2_bootstrap"\n' > "$F/h/env/fly.env"
  cat > "$F/fb/flyctl" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "apps list")     printf '[]\n' ;;
  "apps create")   : ;;
  "volumes list")  printf '[{"id":"vol_aaa","name":"builder_data"}]\n' ;;
  "image show")    : ;;
  "machine list")  printf '[{"id":"0123456789abcd"}]\n' ;;
  "tokens create") [ -n "${DEPLOY_TOKEN:-}" ] && printf '%s\n' "$DEPLOY_TOKEN" ;;
esac
exit 0
STUB
  chmod 755 "$F/fb/flyctl"
  cp "$F/fb/flyctl" "$F/fb/fly"
  grep -q '^HARNESS="\${HARNESS:-/root/harness}"$' "$DIR/bin/fly-provision.sh" || {
    echo "FAIL: fly-provision.sh lost its HARNESS seam — refusing to run against a live root"; exit 1; }
  cp "$DIR/bin/fly-provision.sh" "$F/provision.sh"
}

# provision_run <case-dir> <project> — rc is the script's own exit status.
provision_run() {
  local F="$1"; shift
  ( export HARNESS="$F/h"; PATH="$F/fb:$PATH" bash "$F/provision.sh" "$@" ) >> "$F/run.out" 2>&1
}

# reader <env-file> <var> — exactly what the sourcing scripts do.
reader() { env -i bash -c 'set -a; . "$1" || exit 1; printf %s "${!2}"' _ "$1" "$2"; }

TOK='FlyV1 fm2_deploy,tok=='

# ---------- A. the minted deploy token comes back whole ----------
provision_fixture "$T/a"
export DEPLOY_TOKEN="$TOK"
provision_run "$T/a" proj-x

GOT=$(reader "$T/a/h/env/fly.env" FLY_API_TOKEN_PROJ_X)
SRC_RC=$?
[ "$SRC_RC" = 0 ] \
  && ok || bad "A env/fly.env must still source cleanly after the append (rc $SRC_RC)"
[ "$GOT" = "$TOK" ] \
  && ok || bad "A the deploy token must round-trip byte-for-byte (got: [$GOT])"
[ "$(grep -c '^FLY_API_TOKEN_PROJ_X=' "$T/a/h/env/fly.env")" = 1 ] \
  && ok || bad "A the token must be appended exactly once (got: $(grep -n FLY_API_TOKEN_PROJ_X "$T/a/h/env/fly.env"))"
grep -q 'deploy token stored' "$T/a/run.out" \
  && ok || bad "A the run must say it stored the token (got: $(tail -3 "$T/a/run.out"))"

# ---------- B. re-running does not append a second copy ----------
provision_run "$T/a" proj-x
[ "$(grep -c '^FLY_API_TOKEN_PROJ_X=' "$T/a/h/env/fly.env")" = 1 ] \
  && ok || bad "B a second pass must not re-mint over the quoted line (got: $(grep -n FLY_API_TOKEN_PROJ_X "$T/a/h/env/fly.env"))"
grep -q 'not re-minting' "$T/a/run.out" \
  && ok || bad "B the second pass must recognise the token it wrote itself (got: $(tail -3 "$T/a/run.out"))"
[ "$(reader "$T/a/h/env/fly.env" FLY_API_TOKEN_PROJ_X)" = "$TOK" ] \
  && ok || bad "B the token must still read back whole after the second pass"

# ---------- C. no token minted, nothing written ----------
provision_fixture "$T/c"
unset DEPLOY_TOKEN
provision_run "$T/c" proj-x
[ "$(grep -c FLY_API_TOKEN_PROJ_X "$T/c/h/env/fly.env")" = 0 ] \
  && ok || bad "C a mint that printed nothing must write no line (got: $(grep -n FLY_API_TOKEN_PROJ_X "$T/c/h/env/fly.env"))"
grep -q 'could not mint deploy token' "$T/c/run.out" \
  && ok || bad "C a failed mint must say so with the by-hand remediation (got: $(tail -3 "$T/c/run.out"))"

echo "fly-provision-token-quoting-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
