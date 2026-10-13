#!/bin/bash
# tests/fly-warm-build.bh-3463-test.sh — BH-3463: the warm `next build` inside
# the pool image bake has its own timeout, and a timeout never fails the image.
#
# THE INCIDENT. project-4 / project-1 `next build` hung inside BuildKit step
# [warm 5/5] with no timeout of its own. The whole remote build sat there until
# bin/fleet-propagate.sh's 1800 s outer timeout killed it, so NO image was
# pushed and the pool kept its old one. The warm layer is an optimization: it
# must never block the image.
#
#   A   fly/warm-build.sh under a short WARM_BUILD_TIMEOUT_S kills a hung build,
#       prints the sentinel, leaves both markers, exits 0 — well inside 40 s.
#   A2  a bad WARM_BUILD_TIMEOUT_S falls back to 600 and says so.
#   B   a build that works prints `warm build OK` and leaves no marker.
#   C   a build that fails is FAILED, not TIMED OUT.
#   D   fly/Dockerfile's warm stage declares the ARG and calls the script; the
#       final stage does neither.
#   E   the real bin/fly-image-build.sh passes WARM_BUILD_TIMEOUT_S from the
#       pool.warm_build_timeout_s row, then env, then 600, and records the ref.
#   E2  a cold bake (no slug) passes no timeout arg at all.
#
# Run from anywhere: tests/fly-warm-build.bh-3463-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

WB="$DIR/fly/warm-build.sh"
[ -f "$WB" ] || { echo "FAIL: $WB is missing"; exit 1; }

# A scratch repo with a .git dir and no lockfile: PM resolves to npm, but every
# case sets WARM_BUILD_CMD, so no package manager ever runs.
REPO="$T/repo"
mkdir -p "$REPO/.git"
: > "$T/empty.env"
wb() { # wb <cmd> <timeout> — runs the real script; output in $T/wb.out, rc in RC
  ( cd "$T" && WARM_ENV_FILE="$T/empty.env" WARM_BUILD_CMD="$1" WARM_BUILD_TIMEOUT_S="$2" \
      bash "$WB" "$REPO" ) > "$T/wb.out" 2>&1
  RC=$?
}

# ══ A a hung build is killed at its own timeout and the image still ships ════
rm -f "$REPO/.warm-build-failed" "$REPO/.warm-build-timeout"
T0=$(date +%s)
wb 'sleep 120' 2   # determinism: ok race-sleep the command IS the simulated hung build the 2s timeout kills; nothing synchronises on it
EL=$(( $(date +%s) - T0 ))
[ "$RC" = 0 ] && ok || bad "A a warm timeout must exit 0 — the warm layer never fails the image (rc=$RC): $(cat "$T/wb.out")"
[ "$EL" -lt 40 ] && ok || bad "A the build must be killed at its own 2s timeout, took ${EL}s"
grep -q '^warm-build: TIMED OUT after 2s' "$T/wb.out" && ok || bad "A the sentinel line is missing: $(cat "$T/wb.out")"
[ -f "$REPO/.warm-build-failed" ] && ok || bad "A a timeout must leave .warm-build-failed"
[ -f "$REPO/.warm-build-timeout" ] && ok || bad "A a timeout must leave .warm-build-timeout"
grep -qE '^warm-build: step build start timeout=2s' "$T/wb.out" && ok || bad "A the step start line is missing: $(cat "$T/wb.out")"
grep -qE '^warm-build: step build elapsed=[0-9]+s rc=(124|137)' "$T/wb.out" && ok || bad "A the step elapsed line is missing: $(cat "$T/wb.out")"
grep -q 'warm build OK' "$T/wb.out" && bad "A a timeout must not print OK" || ok

# ══ A2 a bad timeout value falls back to 600, loudly ═════════════════════════
wb 'true' abc
[ "$RC" = 0 ] && ok || bad "A2 rc=$RC"
grep -q 'warm-build: WARM_BUILD_TIMEOUT_S=abc is not a number of seconds — using 600' "$T/wb.out" && ok \
  || bad "A2 a bad value must be named with its fallback: $(cat "$T/wb.out")"
grep -q 'step build start timeout=600s' "$T/wb.out" && ok || bad "A2 the fallback must be 600: $(cat "$T/wb.out")"
wb 'true' 0
grep -q 'using 600' "$T/wb.out" && ok || bad "A2 0 is not a positive number of seconds: $(cat "$T/wb.out")"

# ══ B the ok path ════════════════════════════════════════════════════════════
touch "$REPO/.warm-build-failed" "$REPO/.warm-build-timeout"
wb 'true' 30
[ "$RC" = 0 ] && ok || bad "B rc=$RC"
grep -q '^warm build OK' "$T/wb.out" && ok || bad "B a working build must print 'warm build OK': $(cat "$T/wb.out")"
[ ! -f "$REPO/.warm-build-failed" ] && ok || bad "B an ok build must remove .warm-build-failed"
[ ! -f "$REPO/.warm-build-timeout" ] && ok || bad "B an ok build must remove .warm-build-timeout"
grep -q 'TIMED OUT' "$T/wb.out" && bad "B an ok build must not say TIMED OUT" || ok

# ══ C a failure is not a timeout ═════════════════════════════════════════════
rm -f "$REPO/.warm-build-failed" "$REPO/.warm-build-timeout"
wb 'exit 3' 30
[ "$RC" = 0 ] && ok || bad "C a failed warm build must still exit 0 (rc=$RC)"
grep -q '^warm build FAILED — baking checkout+node_modules only (rc=3)' "$T/wb.out" && ok \
  || bad "C a failed build must print FAILED with its rc: $(cat "$T/wb.out")"
grep -q 'TIMED OUT' "$T/wb.out" && bad "C a plain failure must not be called a timeout" || ok
[ -f "$REPO/.warm-build-failed" ] && ok || bad "C a failure must leave .warm-build-failed"
[ ! -f "$REPO/.warm-build-timeout" ] && ok || bad "C a failure must not leave .warm-build-timeout"

# ══ A3 no checkout: a no-op, exit 0 ══════════════════════════════════════════
( WARM_BUILD_CMD='touch '"$T"'/ran' bash "$WB" "$T/no-such-repo" ) > "$T/wb.out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "A3 no checkout must be a no-op exit 0 (rc=$RC)"
[ ! -f "$T/ran" ] && ok || bad "A3 no checkout must run nothing"

# ══ D the Dockerfile's warm stage calls the script under the ARG ═════════════
DF="$DIR/fly/Dockerfile"
stage() { awk -v s="$1" '/^FROM /{on=($0 ~ (" AS " s "$"))} on' "$DF"; }
W=$(stage warm); F=$(stage final)
[ -n "$W" ] && ok || bad "D no 'FROM base AS warm' stage in $DF"
[ -n "$F" ] && ok || bad "D no 'FROM base AS final' stage in $DF"
grep -qE '^ARG WARM_BUILD_TIMEOUT_S=600$' <<<"$W" && ok || bad "D the warm stage must declare ARG WARM_BUILD_TIMEOUT_S=600"
grep -q '^COPY warm-build.sh /opt/fly-boot/warm-build.sh$' <<<"$W" && ok || bad "D the warm stage must COPY warm-build.sh"
grep -qE '^[^#]*bash /opt/fly-boot/warm-build.sh /opt/warm/repo' <<<"$W" && ok || bad "D the warm stage must run warm-build.sh"
grep -q 'WARM_BUILD_TIMEOUT_S' <<<"$F" && bad "D the final stage must not carry the warm timeout" || ok
grep -q 'warm-build.sh' <<<"$F" && bad "D the final stage must not run warm-build.sh" || ok
# The un-timed build is gone: the RUN no longer runs the build command itself.
grep -qE '^[^#]*sh -c "\$\{WARM_BUILD_CMD' <<<"$W" && bad "D the warm stage still runs the build with no timeout" || ok

# ══ E the real fly-image-build.sh passes the timeout: row > env > 600 ════════
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/state/fly" "$T/stub" "$T/calls"
cp -r "$DIR/fly" "$H/fly"
printf 'FLY_ORG=testorg\nFLY_API_TOKEN=stub\n' > "$H/env/fly.env"
sed "s|/root/harness|$H|g" "$DIR/bin/fly-image-build.sh" > "$H/bin/fly-image-build.sh"
chmod +x "$H/bin/fly-image-build.sh"
cp "$DIR/bin/lib/cli-version.sh" "$DIR/bin/lib/bake-deps.sh" "$H/bin/lib/"
bash -c ". '$DIR/bin/lib/bake-deps.sh'; bake_dep_names" | sed 's/$/=1.0.0/' > "$H/state/fly/p.bake"
# setting_get stub: only the warm timeout row can answer; everything else is
# "no row" (rc 2), so the CLI/bake pins fall back to the host stubs and p.bake.
cat > "$H/bin/jobs-client.sh" <<'EOF'
setting_get() {
  if [ "$1" = pool.warm_build_timeout_s ] && [ -n "${STUB_WBT_ROW:-}" ]; then printf '%s' "$STUB_WBT_ROW"; return 0; fi
  return 2
}
EOF
printf '#!/bin/bash\n[ "$1" = --version ] && echo "2.1.280 (Claude Code)"\n' > "$T/stub/claude"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "codex-cli 0.153.4"\n' > "$T/stub/codex"
cat > "$T/stub/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$T/stub/fly" <<'EOF'
#!/bin/bash
case "$1 ${2:-}" in
  "apps list") echo '[{"Name": "builder-p"}]' ;;
  deploy*) printf '%s\n' "$@" > "$STUB_CALLS/deploy.argv"; echo "image: registry.fly.io/builder-p:deployment-X" ;;
esac
exit 0
EOF
chmod +x "$T/stub"/*
printf 'p Acme/p - - 2 box 10.0.0.1\n' > "$T/fleet.conf"
fib() { # fib — the real script; argv of the deploy in $T/calls/deploy.argv
  rm -f "$T/calls/deploy.argv" "$H/state/fly/p.image"
  ( export PATH="$T/stub:$PATH" STUB_CALLS="$T/calls"
    FLEET_CONF="$T/fleet.conf" GH_TOKEN=stubtok HARNESS="$H" "$H/bin/fly-image-build.sh" p ) > "$T/fib.out" 2>&1
  RC=$?
}
argv_has() { grep -qx -- "$1" "$T/calls/deploy.argv" 2>/dev/null; }

unset WARM_BUILD_TIMEOUT_S STUB_WBT_ROW
fib
[ "$RC" = 0 ] && ok || bad "E(a) the build must succeed (rc=$RC): $(tail -5 "$T/fib.out")"
argv_has 'WARM_REPO_SLUG=Acme/p' && ok || bad "E(a) the fixture must be a WARM bake (no slug arg): $(cat "$T/calls/deploy.argv" 2>/dev/null)"
argv_has 'WARM_BUILD_TIMEOUT_S=600' && ok || bad "E(a) no row, no env: the arg must be 600: $(grep WARM_BUILD "$T/calls/deploy.argv" 2>/dev/null)"
grep -q '== warm build timeout: 600s (default) ==' "$T/fib.out" && ok || bad "E(a) the resolved timeout must be echoed with its source: $(grep -i 'timeout' "$T/fib.out")"
[ "$(cat "$H/state/fly/p.image" 2>/dev/null)" = registry.fly.io/builder-p:deployment-X ] && ok \
  || bad "E the pushed ref must be recorded (got $(cat "$H/state/fly/p.image" 2>/dev/null))"

WARM_BUILD_TIMEOUT_S=90 fib
argv_has 'WARM_BUILD_TIMEOUT_S=90' && ok || bad "E(b) env 90 must reach the arg: $(grep WARM_BUILD "$T/calls/deploy.argv" 2>/dev/null)"

STUB_WBT_ROW=45 WARM_BUILD_TIMEOUT_S=90 fib
argv_has 'WARM_BUILD_TIMEOUT_S=45' && ok || bad "E(c) the settings row must win over env: $(grep WARM_BUILD "$T/calls/deploy.argv" 2>/dev/null)"
grep -q 'pool.warm_build_timeout_s' "$T/fib.out" && ok || bad "E(c) the source must be named: $(grep -i 'timeout' "$T/fib.out")"

STUB_WBT_ROW=soon WARM_BUILD_TIMEOUT_S=90 fib
argv_has 'WARM_BUILD_TIMEOUT_S=90' && ok || bad "E(d) a bad row must fall through to env: $(grep WARM_BUILD "$T/calls/deploy.argv" 2>/dev/null)"
grep -q 'WARN: pool.warm_build_timeout_s row "soon"' "$T/fib.out" && ok || bad "E(d) a bad row must be named in a WARN: $(grep -i warn "$T/fib.out")"

WARM_BUILD_TIMEOUT_S=x fib
argv_has 'WARM_BUILD_TIMEOUT_S=600' && ok || bad "E(e) a bad env must fall back to 600: $(grep WARM_BUILD "$T/calls/deploy.argv" 2>/dev/null)"
grep -q 'WARN: WARM_BUILD_TIMEOUT_S="x"' "$T/fib.out" && ok || bad "E(e) a bad env must be named in a WARN: $(grep -i warn "$T/fib.out")"

# ══ E2 a cold bake passes no timeout arg ═════════════════════════════════════
WARM_BUILD_TIMEOUT_S=90 WARM_BAKE=0 fib
[ "$RC" = 0 ] && ok || bad "E2 rc=$RC"
grep -q 'WARM_BUILD_TIMEOUT_S' "$T/calls/deploy.argv" 2>/dev/null && bad "E2 a cold bake must pass no warm timeout" || ok
grep -q 'WARM_REPO_SLUG' "$T/calls/deploy.argv" 2>/dev/null && bad "E2 fixture: WARM_BAKE=0 must be cold" || ok

echo "fly-warm-build.bh-3463-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
