#!/bin/bash
# tests/fly-image-build-probe-test.sh — an app-existence probe that FAILS must
# never be read as "the app is missing".
#
# THE INCIDENT THIS PINS (2026-09-17 17:55Z -> 2026-09-18). Every fleet-propagate
# reported `0/10 pool images rebaked` and paged CRITICAL, while Fly, the token
# and the org were all healthy. bin/fly-image-build.sh runs `set -uo pipefail`
# and probed with `fly apps list --json | grep -q "<app>"`. grep -q exits on its
# first match; flyctl is still writing the ~67KB JSON, takes SIGPIPE (141), and
# pipefail turns a SUCCESSFUL match into a failed pipeline. An app that exists
# then reads as missing, the script calls `fly apps create`, Fly answers "Name
# has already been taken", and the run FATALs before building anything. Measured
# 9 of 10 concurrent probes losing that race (PIPESTATUS=[141 0]); serially it
# almost always passes, which is why it only showed up under the 10-way parallel
# bake in fleet-propagate.sh.
#
# The rule: read the list into a variable, fail CLOSED when the list fails, and
# treat "already taken" as a WARN — never as a fatal.
#
# Run from anywhere: tests/fly-image-build-probe-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/fly" "$H/env" "$H/state" "$T/stub" "$T/calls"
echo "FROM scratch" > "$H/fly/Dockerfile"
printf 'FLY_ORG=testorg\nFLY_API_TOKEN=stub\n' > "$H/env/fly.env"
sed "s|/root/harness|$H|g" "$DIR/bin/fly-image-build.sh" > "$H/bin/fly-image-build.sh"
chmod +x "$H/bin/fly-image-build.sh"
# BH-1517: no jobs-client.sh in this fixture, so fly-image-build.sh's DB lookup
# for cli.claude_code.version/cli.codex.version never fires and it falls back
# to cli_version_of (the shared parser, copied in below) probing THIS host's
# own claude/codex — stubbed on $T/stub below (exported onto PATH further
# down), same directory as the `fly` stub.
cp "$DIR/bin/lib/cli-version.sh" "$H/bin/lib/"
# BH-1528: the other baked dependencies. No jobs-client.sh, so no bake.* rows:
# the build pins what this project's last good image baked (state/fly/demo.bake).
cp "$DIR/bin/lib/bake-deps.sh" "$H/bin/lib/"
mkdir -p "$H/state/fly"
bash -c ". '$DIR/bin/lib/bake-deps.sh'; bake_dep_names" | sed 's/$/=1.0.0/' > "$H/state/fly/demo.bake"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "2.1.280 (Claude Code)"\n' > "$T/stub/claude"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "codex-cli 0.153.4"\n' > "$T/stub/codex"
chmod +x "$T/stub/claude" "$T/stub/codex"

# A payload big enough that grep -q matching early leaves the writer with a
# closed pipe — the exact shape of the real `fly apps list --json` output.
#
# Two properties this fixture MUST keep, or it stops testing anything (bh-806):
#   * the app we look for is on the FIRST line. grep -q exits at the match, so
#     only an early match leaves the producer with bytes still to write. With
#     the match at the END, grep reads the whole payload and no reader ever
#     closes the pipe — every broken probe shape passes.
#   * the payload is MULTI-LINE and past one pipe buffer. flyctl indents its
#     --json, and `printf '%s' "$VAR" | grep -q` only loses the race on
#     multi-line input (measured on bash 5.2, 20 runs: 67KB over 1004 lines
#     reads ABSENT 20/20; 749KB on ONE line, 0/20). A single-line fixture is
#     the one shape where the old pipeline always passes.
BIG="$T/apps.json"
{ printf '[\n  {"Name": "builder-demo", "Org": "testorg"},\n'
  for i in $(seq 1 40000); do printf '  {"Name": "filler-%s", "Org": "testorg"},\n' "$i"; done
  printf '  {"Name": "filler-last", "Org": "testorg"}\n]\n'
} > "$BIG"
[ "$(head -c 65537 "$BIG" | wc -c)" -gt 65536 ] && ok \
  || bad "the apps-list fixture must exceed one pipe buffer, or no probe shape can fail it"
[ "$(head -2 "$BIG" | grep -c 'builder-demo')" = 1 ] && ok \
  || bad "the app under test must be at the START of the fixture, or grep -q never exits early"

cat > "$T/stub/fly" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_CALLS/fly.calls"
case "$1 ${2:-}" in
  "apps list")
    [ "${STUB_LIST_RC:-0}" = 0 ] || exit "$STUB_LIST_RC"
    cat "$STUB_APPS_JSON" ;;
  "apps create")
    printf '%s\n' "${STUB_CREATE_MSG:-created}"
    exit "${STUB_CREATE_RC:-0}" ;;
  deploy*)
    echo "image: registry.fly.io/builder-demo:deployment-01TEST" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$T/stub/fly"
export PATH="$T/stub:$PATH"
export STUB_CALLS="$T/calls" STUB_APPS_JSON="$BIG"

run() { # run <label> ; leaves rc in RC and output in $T/out
  : > "$T/calls/fly.calls"
  FLEET_CONF="" WARM_BAKE=0 "$H/bin/fly-image-build.sh" demo > "$T/out" 2>&1; RC=$?
}

# 0. STRUCTURAL: the probe must not pipe flyctl into a reader at all. Whether
# the race is lost depends on how fast flyctl writes, so it cannot be pinned by
# timing inside a test — the pipeline itself is the defect, and its absence is
# what this asserts.
if grep -nE '"\$FLY" apps list[^|]*\|[^|]' "$DIR/bin/fly-image-build.sh" >/dev/null; then
  bad "the app-existence probe still pipes \`fly apps list\` into a reader (SIGPIPE + pipefail = exists reads as missing)"
else ok; fi
grep -q 'APPS_JSON=$("$FLY" apps list --json' "$DIR/bin/fly-image-build.sh" && ok \
  || bad "the listing is not captured into a variable before it is searched"
# Capturing it is only half the fix. `printf '%s' "$APPS_JSON" | grep -q` is
# still a pipeline, and a BUILTIN producer over ~64KB takes the same SIGPIPE.
if grep -nE '^[^#]*(printf|echo)[^|#]*"\$APPS_JSON"[^|#]*\|' "$DIR/bin/fly-image-build.sh" >/dev/null; then
  bad "the captured listing is searched through a pipeline again (a builtin producer past one pipe buffer dies of SIGPIPE too — use a here-string)"
else ok; fi

# 1. The app EXISTS and the listing is large: no create, and the build proceeds.
STUB_LIST_RC=0 STUB_CREATE_RC=0; export STUB_LIST_RC STUB_CREATE_RC
run
grep -q 'apps create' "$T/calls/fly.calls" && bad "created an app that already exists (the SIGPIPE regression)" || ok
grep -q 'FATAL' "$T/out" && bad "FATAL on a healthy existing app: $(grep FATAL "$T/out" | head -1)" || ok
[ "$RC" = 0 ] && ok || bad "rc=$RC on the healthy path"
grep -q 'building + pushing image' "$T/out" && ok || bad "never reached the build stage"

# 2. The app is genuinely missing and create loses a race: WARN, not FATAL.
export STUB_APPS_JSON="$T/empty.json"; echo '[{"Name":"someone-else"}]' > "$T/empty.json"
export STUB_CREATE_RC=1 STUB_CREATE_MSG="Error: Name has already been taken"
run
grep -q 'FATAL: apps create failed' "$T/out" && bad "'already been taken' FATALed instead of warning" || ok
grep -q 'WARN: builder-demo already exists' "$T/out" && ok || bad "no WARN line for the already-taken create"
[ "$RC" = 0 ] && ok || bad "rc=$RC after a tolerated already-taken create"

# 3. A create that fails for a REAL reason still stops the run.
export STUB_CREATE_RC=1 STUB_CREATE_MSG="Error: insufficient permissions"
run
grep -q 'FATAL: apps create failed' "$T/out" && ok || bad "a genuinely failed create did not FATAL"
[ "$RC" != 0 ] && ok || bad "rc=0 after a genuinely failed create"

# 4. A FAILED listing is not evidence of absence: fail closed, never create.
export STUB_APPS_JSON="$BIG" STUB_LIST_RC=1 STUB_CREATE_RC=0
run
grep -q 'apps create' "$T/calls/fly.calls" && bad "created an app on the strength of a FAILED list" || ok
grep -q 'FATAL: fly apps list failed' "$T/out" && ok || bad "a failed list did not fail closed"
[ "$RC" != 0 ] && ok || bad "rc=0 after a failed list"

echo "fly-image-build-probe-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
