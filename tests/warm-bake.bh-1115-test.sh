#!/bin/bash
# tests/warm-bake.bh-1115-test.sh — BH-1115: fly/warm-bake.sh prints the repo sha
# it installed against and honours a per-project WARM_NPM_FLAGS.
#
# WHAT THIS PINS:
#   * the install runs FROM the repo directory, so the repo's own .npmrc is the
#     one npm reads (that is the whole of the ".npmrc is honoured" ask);
#   * WARM_NPM_FLAGS from fly/warm-env/<project>.env reaches `npm ci` and
#     `npm install`, and does NOT touch the pnpm path;
#   * no env file, or a WARM_ENV_FILE that does not exist, changes nothing and
#     still exits 0 — a missing override is not a failure;
#   * a git checkout prints `warm-bake: repo sha <40 hex>` (fleet-propagate greps
#     that line into pools.<p>.warm_sha), and a non-git directory prints no such
#     line and keeps its exit code.
#
# The package managers are stubs on PATH that record their argv and their $PWD.
#
# Run from anywhere: tests/warm-bake.bh-1115-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/fakebin" "$T/fixtures"
export PATH="$T/fakebin:$PATH"
cat > "$T/fakebin/npm" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$NPM_CALLS"
printf '%s\n' "$PWD" >> "$NPM_PWD"
exit "${NPM_RC:-0}"
STUB
cat > "$T/fakebin/corepack" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$PNPM_CALLS"
exit "${PNPM_RC:-0}"
STUB
chmod +x "$T/fakebin"/*
NPM_CALLS="$T/npm.calls"; NPM_PWD="$T/npm.pwd"; PNPM_CALLS="$T/pnpm.calls"
export NPM_CALLS NPM_PWD PNPM_CALLS

# fly/warm-env/<project>.env is the real shape: dummy values, set -a sourced.
cat > "$T/flags.env" <<'EOF'
# fly/warm-env/fixture.env — DUMMY VALUES ONLY.
WARM_NPM_FLAGS=--legacy-peer-deps
EOF

mk() { # mk <name> <lockfile|none> — a fixture repo dir
  local d="$T/fixtures/$1"
  mkdir -p "$d"; echo '{}' > "$d/package.json"
  [ "$2" = none ] || : > "$d/$2"
  printf '%s' "$d"
}
bake() { # bake <dir> [env-assignments...] — run the real warm-bake.sh
  local d="$1"; shift
  : > "$NPM_CALLS"; : > "$NPM_PWD"; : > "$PNPM_CALLS"
  env "$@" bash "$DIR/fly/warm-bake.sh" "$d" 2>&1
}

NPMLOCK=$(mk npm-lock package-lock.json)
PKGONLY=$(mk pkg-only none)
PNPMLOCK=$(mk pnpm-lock pnpm-lock.yaml)

# ══ 1. WARM_NPM_FLAGS reaches npm ci ════════════════════════════════════════
bake "$NPMLOCK" "WARM_ENV_FILE=$T/flags.env" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "1. npm-lock + env file must exit 0 (rc=$RC)"
[ "$(cat "$NPM_CALLS")" = "ci --legacy-peer-deps" ] && ok \
  || bad "1. npm ci must carry WARM_NPM_FLAGS (got '$(cat "$NPM_CALLS")')"

# ══ 2. and npm install ══════════════════════════════════════════════════════
bake "$PKGONLY" "WARM_ENV_FILE=$T/flags.env" >/dev/null
[ "$(cat "$NPM_CALLS")" = "install --legacy-peer-deps" ] && ok \
  || bad "2. npm install must carry WARM_NPM_FLAGS (got '$(cat "$NPM_CALLS")')"

# ══ 3. the pnpm path is unchanged ═══════════════════════════════════════════
bake "$PNPMLOCK" "WARM_ENV_FILE=$T/flags.env" >/dev/null
[ "$(cat "$PNPM_CALLS")" = "pnpm install --frozen-lockfile" ] && ok \
  || bad "3. pnpm must stay --frozen-lockfile, with no npm flags (got '$(cat "$PNPM_CALLS")')"
[ ! -s "$NPM_CALLS" ] && ok || bad "3. the pnpm path must not call npm (got '$(cat "$NPM_CALLS")')"

# ══ 4. no env file: exactly the command it always ran ═══════════════════════
bake "$NPMLOCK" >/dev/null
[ "$(cat "$NPM_CALLS")" = "ci" ] && ok \
  || bad "4. with no override npm ci must carry no trailing token (got '$(cat "$NPM_CALLS")')"

# ══ 5. a WARM_ENV_FILE that does not exist is not a failure ═════════════════
bake "$NPMLOCK" "WARM_ENV_FILE=$T/nope.env" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "5. a missing env file must not fail the bake (rc=$RC)"
[ "$(cat "$NPM_CALLS")" = "ci" ] && ok \
  || bad "5. a missing env file must leave the command alone (got '$(cat "$NPM_CALLS")')"
# The same for a project whose warm-env file was never written.
bake "$NPMLOCK" "WARM_PROJECT=no-such-project-bh1115" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "5. an unknown WARM_PROJECT must not fail the bake (rc=$RC)"

# ══ 6. the repo sha line ════════════════════════════════════════════════════
GITREPO=$(mk gitrepo package-lock.json)
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q "$GITREPO"
git -C "$GITREPO" add -A && git -C "$GITREPO" commit -qm init
HEAD_SHA=$(git -C "$GITREPO" rev-parse HEAD)
OUT=$(bake "$GITREPO"); RC=$?
[ "$RC" = 0 ] && ok || bad "6. a git fixture must exit 0 (rc=$RC)"
grep -q "^warm-bake: repo sha $HEAD_SHA$" <<<"$OUT" && ok \
  || bad "6. warm-bake must print the sha it installed against (got: $OUT)"
OUT=$(bake "$NPMLOCK"); RC=$?
[ "$RC" = 0 ] && ok || bad "6. a non-git fixture must still exit 0 (rc=$RC)"
grep -q 'repo sha' <<<"$OUT" && bad "6. a non-git fixture must print no sha line (got: $OUT)" || ok
OUT=$(bake "$PKGONLY" NPM_RC=3); RC=$?
[ "$RC" = 3 ] && ok || bad "6. the install's rc must still be the script's rc (rc=$RC)"

# ══ 7. the install runs in the repo directory (so its .npmrc is read) ═══════
bake "$NPMLOCK" "WARM_ENV_FILE=$T/flags.env" >/dev/null
[ "$(cat "$NPM_PWD")" = "$NPMLOCK" ] && ok \
  || bad "7. npm must run from the repo dir (got '$(cat "$NPM_PWD")', want '$NPMLOCK')"

echo "warm-bake.bh-1115-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
