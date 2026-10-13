#!/bin/bash
# tests/env-path-fly-test.sh — the Fly slice of the env-dir port (BH-453).
#
# Proves, by EXECUTION rather than by grep, that:
#   (a) fly/entrypoint.sh's exported override really resolves to the tmpfs, and
#       the compat symlink still precedes it;
#   (b) a real hub-side entry point (bin/fly-api.sh) with NO $HARNESS/env finds
#       fly.env in the etc dir through the resolver — observed as the token the
#       stubbed curl saw, not as a variable read out of the source;
#   (b2) the missing-file path is unchanged (die on today's $HARNESS/env path);
#   (b3) with bin/lib absent the inline fallback still prints today's path, so
#       the 44 copy-one-script suites keep passing;
#   (c) every file in the slice parses;
#   (d) the slice's allowlist exemption is gone;
#   (e) fly-dispatch.sh's machine-side push targets stayed literal.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/env-path-fly-test.sh   (exit 0 = all pass)
# Secrets: none. The only token strings here are the fixtures fixture-fly and
# fixture-inline, and the stub curl's log lives under $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-1941: the script under test resolves its vendor base URL through
# endpoint_url (env, else the registry default); this sandbox composes no
# registry, so the env carries today's URL — the registry default itself.
export ENDPOINT_FLY_MACHINES=https://api.machines.dev
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SLICE="fly/entrypoint.sh
bin/fly-api.sh
bin/fly-dispatch.sh
bin/fly-envbundle.sh
bin/fly-image-build.sh
bin/fly-machine-state.sh
bin/fly-pool-rollout.sh
bin/fly-pool.sh
bin/fly-provision.sh
bin/fly-results-ingest.sh
bin/fly-sync-harness.sh
bin/fly-trial-kill.sh"

# ---------------------------------------------------------------------------
# (a) the entrypoint override, EXECUTED
# ---------------------------------------------------------------------------
ENTRY="$DIR/fly/entrypoint.sh"
EXPORT_LINE=$(grep -m1 '^export HARNESS_ENV_DIR=' "$ENTRY" 2>/dev/null)
if [ -z "$EXPORT_LINE" ]; then
  bad "(a) no export HARNESS_ENV_DIR line in fly/entrypoint.sh"
else
  GOT=$(bash -c "$EXPORT_LINE; . \"$DIR/bin/lib/env-path.sh\"; harness_env_dir /nowhere" 2>/dev/null)
  [ "$GOT" = "/run/harness-env" ] && ok || bad "(a) exported override resolved to '$GOT', want /run/harness-env"
fi

# the compat symlink stays, and stays ABOVE the export (an override written
# before the symlink would still work, but the ticket pins the order and the
# comment reads as if the symlink came first)
LN_NO=$(grep -n '^ln_force /run/harness-env /data/harness/env$' "$ENTRY" | head -n 1 | cut -d: -f1)
EX_NO=$(grep -n '^export HARNESS_ENV_DIR=' "$ENTRY" | head -n 1 | cut -d: -f1)
if [ -n "$LN_NO" ] && [ -n "$EX_NO" ] && [ "$LN_NO" -lt "$EX_NO" ]; then
  ok
else
  bad "(a) symlink/export order wrong (ln_force line '$LN_NO', export line '$EX_NO')"
fi

# fly/builder-runner.sh owns the tmpfs itself and is NOT ported
RUNNER_N=$(grep -c '^ENVDIR=/run/harness-env$' "$DIR/fly/builder-runner.sh" 2>/dev/null)
[ "$RUNNER_N" = "1" ] && ok || bad "(a) builder-runner.sh ENVDIR count is $RUNNER_N, want 1"

# ---------------------------------------------------------------------------
# shared fixtures for (b)/(b2)/(b3): a stub curl that logs and answers stopped
# ---------------------------------------------------------------------------
mkdir -p "$T/stub"
cat > "$T/stub/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
printf '%s\n' '{"state":"stopped"}'
EOF
chmod 755 "$T/stub/curl"

# copy_fly_api <root> <with-lib:0|1>
copy_fly_api() {
  local root="$1" with_lib="$2"
  mkdir -p "$root/bin" "$root/state/fly"
  # TEST-CHANGE (BH-1941): fly-api.sh's line is now HARNESS="${HARNESS:-/root/harness}"
  # (it honours an exported HARNESS); the rewrite pins the same root as before.
  sed 's|^HARNESS="${HARNESS:-/root/harness}"$|HARNESS='"$root"'|' "$DIR/bin/fly-api.sh" > "$root/bin/fly-api.sh"
  chmod 755 "$root/bin/fly-api.sh"
  grep -q "^HARNESS=$root$" "$root/bin/fly-api.sh" || bad "fixture: HARNESS rewrite failed for $root"
  # BH-1941: the endpoint resolver ships beside fly-api.sh in every layout; the
  # with-lib switch below is about env-path.sh only.
  mkdir -p "$root/bin/lib"; cp "$DIR/bin/lib/endpoints.sh" "$root/bin/lib/"
  if [ "$with_lib" = "1" ]; then
    cp "$DIR/bin/lib/env-path.sh" "$root/bin/lib/env-path.sh"
  fi
  printf '{"app":"builder-demo","machine_id":"m1"}\n' > "$root/state/fly/demo.json"
}

# ---------------------------------------------------------------------------
# (b) real entry point, no $HARNESS/env, token comes from the etc dir
# ---------------------------------------------------------------------------
copy_fly_api "$T/a" 1
mkdir -p "$T/etc"
printf 'FLY_API_TOKEN_DEMO=fixture-fly\n' > "$T/etc/fly.env"
[ -d "$T/a/env" ] && bad "fixture: $T/a/env must not exist"

B_OUT=$(env PATH="$T/stub:$PATH" CURL_LOG="$T/curl-args.log" HARNESS_ENV_DIR= \
  ETC_HARNESS_ENV="$T/etc" bash "$T/a/bin/fly-api.sh" demo state 2>"$T/b-err.txt")
B_RC=$?
[ "$B_RC" = "0" ] && ok || bad "(b) fly-api.sh rc=$B_RC (stderr: $(cat "$T/b-err.txt"))"
[ "$B_OUT" = "stopped" ] && ok || bad "(b) fly-api.sh printed '$B_OUT', want stopped"
if grep -q 'Bearer fixture-fly' "$T/curl-args.log" 2>/dev/null; then
  ok
else
  bad "(b) curl never saw the etc-dir token (log: $(cat "$T/curl-args.log" 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
# (b2) nothing anywhere: the die stays on today's $HARNESS/env path
# ---------------------------------------------------------------------------
B2_OUT=$(env PATH="$T/stub:$PATH" CURL_LOG="$T/curl-args-b2.log" HARNESS_ENV_DIR= \
  ETC_HARNESS_ENV="$T/no-etc" bash "$T/a/bin/fly-api.sh" demo state 2>"$T/b2-err.txt")
B2_RC=$?
[ "$B2_RC" = "1" ] && ok || bad "(b2) rc=$B2_RC, want 1 (out: $B2_OUT)"
if grep -qF "$T/a/env/fly.env missing" "$T/b2-err.txt"; then
  ok
else
  bad "(b2) stderr did not name $T/a/env/fly.env: $(cat "$T/b2-err.txt")"
fi

# ---------------------------------------------------------------------------
# (b3) bin/lib absent: the inline fallback keeps the script on $HARNESS/env
#      even though an etc dir exists and holds a different token
# ---------------------------------------------------------------------------
copy_fly_api "$T/c" 0
mkdir -p "$T/c/env"
printf 'FLY_API_TOKEN_DEMO=fixture-inline\n' > "$T/c/env/fly.env"
B3_OUT=$(env PATH="$T/stub:$PATH" CURL_LOG="$T/curl-args-b3.log" HARNESS_ENV_DIR= \
  ETC_HARNESS_ENV="$T/etc" bash "$T/c/bin/fly-api.sh" demo state 2>"$T/b3-err.txt")
B3_RC=$?
[ "$B3_RC" = "0" ] && [ "$B3_OUT" = "stopped" ] && ok \
  || bad "(b3) rc=$B3_RC out='$B3_OUT' (stderr: $(cat "$T/b3-err.txt"))"
if grep -q 'Bearer fixture-inline' "$T/curl-args-b3.log" 2>/dev/null; then
  ok
else
  bad "(b3) inline fallback did not read $T/c/env/fly.env (log: $(cat "$T/curl-args-b3.log" 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
# (c) every file in the slice parses
# ---------------------------------------------------------------------------
SYNTAX_BAD=""
COUNTED=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  COUNTED=$((COUNTED + 1))
  [ -f "$DIR/$rel" ] || { SYNTAX_BAD="$SYNTAX_BAD $rel(missing)"; continue; }
  bash -n "$DIR/$rel" 2>/dev/null || SYNTAX_BAD="$SYNTAX_BAD $rel"
done <<< "$SLICE"
[ "$COUNTED" = "12" ] && ok || bad "(c) slice list has $COUNTED files, want 12"
[ -z "$SYNTAX_BAD" ] && ok || bad "(c) bash -n failed:$SYNTAX_BAD"

# ---------------------------------------------------------------------------
# (d) the slice's allowlist exemption is gone
# ---------------------------------------------------------------------------
[ ! -e "$DIR/tests/env-path-allowlist.d/fly.txt" ] && ok \
  || bad "(d) tests/env-path-allowlist.d/fly.txt is still present"

# ---------------------------------------------------------------------------
# (e) machine-side push targets in fly-dispatch.sh stay literal
# ---------------------------------------------------------------------------
# Three since BH-1572: global.env, <project>.env, and the model-routes bundle —
# all three machine-side paths, all three literal.
PUSH_N=$(grep -c '"/run/harness-env/' "$DIR/bin/fly-dispatch.sh")
[ "$PUSH_N" = "3" ] && ok || bad "(e) fly-dispatch.sh literal push targets: $PUSH_N, want 3"

echo "env-path-fly-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
