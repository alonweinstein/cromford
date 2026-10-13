#!/bin/bash
# tests/lib/fly-rollout-fixture.sh — the shared scratch harness the four
# bin/fly-pool-rollout.sh suites drive (BH-666).
#
# The rollout mints a Fly org token, pushes an image, boots a real pool machine
# and flips routing flags. None of that can run in CI, so the fixture replaces
# flyctl, ssh and the harness scripts the rollout shells out to with capture
# stubs and runs the REAL script — unmodified, straight out of bin/ — through
# the seams it already ships for exactly this (HARNESS, FLYCTL_DIR,
# ROLLOUT_BOOT_WAIT, ROLLOUT_POLL_WAIT; BH-662). Nothing here rewrites the
# script's source, so what these suites prove is what the hub runs.
#
# Every assertion in the suites is on an artifact the run left behind —
# mint.env, machine-run.*, state/fly/<p>.image, flags/, logs/ALERTS.log, the
# exit code — never on the script's source text.
#
# FLYCTL_DIR is what keeps a real flyctl out of the run: the rollout PREPENDS
# that directory to PATH, so pointing it at the stub dir means the stub wins.
#
# This file lives under tests/lib/ so neither CI's `tests/*.sh` glob nor
# checks/tests-scratch-only/check.sh --tree treats it as a test of its own.
#
# usage:
#   . "$(dirname "$0")/lib/scratch.sh" || exit 1
#   . "$DIR/tests/lib/fly-rollout-fixture.sh"
#   rollout_fixture "$T/caseA" "$DIR"        # <case dir> <repo root>
#   MINT_TOKEN='FlyV1 fm2_minted' SMOKE_RESULT=SMOKE_OK rollout_run "$T/caseA" proj-x
#
# Knobs the stubs read from the environment (all optional):
#   MINT_TOKEN        what `flyctl tokens create org` prints (unset = mint fails)
#   MINT_STDERR       what it writes to stderr
#   MACHINE_STATE     the state `flyctl machines list` reports (default started)
#   MOVE_POINTER_TO   an image ref `machines list` writes into state/fly/<p>.image
#                     as a side effect — how a nightly refresh racing the probe
#                     is reproduced
#   SMOKE_RESULT      what /run/harness/RESULT holds (unset = the probe never
#                     returns a result)
#   IMAGE_BUILD_FAIL  non-empty = the image build stub exits 1
#   BUILD_TAG         the deployment tag the image build stub records
#   FIXTURE_PROJECT   project name the stubs use for per-project paths
#   MKTEMP_FAIL_FLYENV non-empty = `mktemp /dev/shm/flyenv.XXXX` fails (no
#                     /dev/shm, ENOSPC) and every other mktemp still works —
#                     how "the env backup never landed" is reproduced

# rollout_fixture <case-dir> <repo-root>
rollout_fixture() {
  local F="$1" R="$2"
  ROLLOUT_REPO="$R"
  mkdir -p "$F/h/bin" "$F/h/env" "$F/h/logs" "$F/h/state/fly" "$F/h/flags" "$F/h/locks" "$F/fb"

  # The org, plus the LIMITED bootstrap token that must never reach the mint.
  printf 'FLY_ORG=testorg\nFLY_API_TOKEN="FlyV1 fm2_limited"\n' > "$F/h/env/fly.env"

  cat > "$F/fb/flyctl" <<'STUB'
#!/bin/bash
# fixture flyctl — answers from the knobs above and records what it was asked.
FT=__FT__
P=${FIXTURE_PROJECT:-proj-x}
case "$1 $2" in
  "tokens create")
    env > "$FT/mint.env"
    [ -n "${MINT_STDERR:-}" ] && printf '%s\n' "$MINT_STDERR" >&2
    [ -n "${MINT_TOKEN:-}" ] || exit 1
    printf '%s\n' "$MINT_TOKEN"
    exit 0 ;;
  "apps create") exit 0 ;;
  "machine run")
    env > "$FT/machine-run.env"
    printf '%s\n' "$3" > "$FT/machine-run.args"
    echo "Machine ID: 0123456789abcd"
    exit 0 ;;
  "machines list")
    [ -n "${MOVE_POINTER_TO:-}" ] && printf '%s\n' "$MOVE_POINTER_TO" > "$FT/h/state/fly/$P.image"
    printf '[{"id":"0123456789abcd","state":"%s"}]\n' "${MACHINE_STATE:-started}"
    exit 0 ;;
  "machine destroy") exit 0 ;;
  "ssh console")
    CMD=""
    while [ "$#" -gt 0 ]; do
      [ "$1" = "-C" ] && { CMD="${2:-}"; break; }
      shift
    done
    case "$CMD" in
      *"/run/harness/RESULT"*) [ -n "${SMOKE_RESULT:-}" ] && printf '%s\n' "$SMOKE_RESULT" ;;
    esac
    exit 0 ;;
esac
case "$1" in
  status) exit 0 ;;
esac
exit 0
STUB

  printf '#!/bin/bash\nexit 0\n' > "$F/fb/ssh"

  # Only the env-backup template fails, and only when the knob is set: the
  # rollout's other mktemp calls (the flyctl no-leak wrapper, the smoke bundle
  # dir) have to keep working or the case would prove nothing.
  cat > "$F/fb/mktemp" <<'STUB'
#!/bin/bash
if [ -n "${MKTEMP_FAIL_FLYENV:-}" ]; then
  for A in "$@"; do case "$A" in *flyenv.XXXX) exit 1 ;; esac; done
fi
exec __MKTEMP__ "$@"
STUB
  chmod 755 "$F/fb/flyctl" "$F/fb/ssh" "$F/fb/mktemp"

  # The image builder writes BOTH artifacts the real bin/fly-image-build.sh
  # writes: the log line the rollout greps, and the state pointer it publishes
  # one step before the probe.
  cat > "$F/h/bin/fly-image-build.sh" <<'STUB'
#!/bin/bash
FT=__FT__
[ -n "${IMAGE_BUILD_FAIL:-}" ] && exit 1
REF="registry.fly.io/builder-$1:${BUILD_TAG:-deployment-01BBBBBBBBBBBBBBBBBBBBBBBB}"
echo "image: $REF"
printf '%s\n' "$REF" > "$FT/h/state/fly/$1.image"
exit 0
STUB

  cat > "$F/h/bin/fly-envbundle.sh" <<'STUB'
#!/bin/bash
mkdir -p "$2"
printf 'GLOBAL=1\n' > "$2/global.env"
printf 'PROJECT=%s\n' "$1" > "$2/$1.env"
exit 0
STUB

  # The rollout's preflight skips a project with no tailnet_ip BEFORE the mint,
  # so the registry lookup has to answer with a real address or every case would
  # stop one step short of what it tests.
  printf '#!/bin/bash\necho 10.9.9.9\n' > "$F/h/bin/fleet-conf.sh"
  # pool-cap.sh prints nothing here, which is the autoscale default: the flag
  # file is written empty and bin/pool-cap.sh resolves the ceiling later.
  printf '#!/bin/bash\nexit 0\n' > "$F/h/bin/pool-cap.sh"
  printf '#!/bin/bash\nexit 0\n' > "$F/h/bin/beat.sh"
  cp "$R/bin/result-prefix-ok.sh" "$F/h/bin/result-prefix-ok.sh"
  chmod 755 "$F/h/bin/fly-image-build.sh" "$F/h/bin/fly-envbundle.sh" \
            "$F/h/bin/fleet-conf.sh" "$F/h/bin/pool-cap.sh" "$F/h/bin/beat.sh" \
            "$F/h/bin/result-prefix-ok.sh"

  sed -i "s|__FT__|$F|g" "$F/fb/flyctl" "$F/h/bin/fly-image-build.sh"
  # Resolved before the fake PATH is in play, so the stub cannot exec itself.
  sed -i "s|__MKTEMP__|$(command -v mktemp)|" "$F/fb/mktemp"
}

# rollout_reset_knobs — clear every stub knob so one case cannot inherit the
# previous case's setup (a leaked MINT_TOKEN is a green test that proved
# nothing).
rollout_reset_knobs() {
  unset MINT_TOKEN MINT_STDERR MACHINE_STATE MOVE_POINTER_TO SMOKE_RESULT \
        IMAGE_BUILD_FAIL BUILD_TAG FIXTURE_PROJECT MKTEMP_FAIL_FLYENV
}

# rollout_run <case-dir> <project...>  — rc is the rollout's own exit status.
# The production script, byte for byte, pointed at the scratch tree by the same
# env seams bin/fly-onboard.sh and cron leave unset.
rollout_run() {
  local F="$1"; shift
  # HARNESS_SECRET and JOBS_URL are dropped too: the rollout writes the
  # fly_images row through the jobs client (BH-2523), and a secret inherited
  # from a hub shell with no JOBS_URL would send it to the fleet worker. A case
  # that wants the worker writes its own $F/h/env/global.env.
  ( env -u HARNESS_ENV_DIR -u HARNESS_SECRET -u JOBS_URL HARNESS="$F/h" FLYCTL_DIR="$F/fb" \
        ROLLOUT_BOOT_WAIT=0 ROLLOUT_POLL_WAIT=0 PATH="$F/fb:$PATH" \
        bash "$ROLLOUT_REPO/bin/fly-pool-rollout.sh" "$@" ) \
    > "$F/run.out" 2> "$F/run.err"
}

# rollout_alerts <case-dir> — the ALERTS lines this case wrote, or nothing.
rollout_alerts() { cat "$1/h/logs/ALERTS.log" 2>/dev/null; }

# rollout_log <case-dir> — the rollout's own log, or nothing.
rollout_log() { cat "$1/h/logs/fly-pool-rollout.log" 2>/dev/null; }
