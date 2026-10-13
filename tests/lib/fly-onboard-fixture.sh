#!/bin/bash
# tests/lib/fly-onboard-fixture.sh — a scratch harness that bin/fly-onboard.sh
# and the REAL bin/fly-pool-rollout.sh can be executed against (BH-662).
#
# Sourced by tests/fly-onboard-*-test.sh. It is a fixture BUILDER, not a test:
# it copies the production scripts in unmodified and stubs only the things that
# leave the machine — flyctl, ssh, the image build, the env bundle, the beat.
# The rollout itself runs for real, which is the whole point: the guards being
# tested are guards over that script's side effects (flag files, machine runs,
# an ssh to another box), and a paraphrase of it would prove nothing.
#
# It needs $DIR (repo root) from the caller, and the caller owns $T.

# fly_onboard_fixture <dir> — build <dir> as a harness root and export the
# environment that points every production script at it.
fly_onboard_fixture() {
  FX="$1"
  mkdir -p "$FX/bin/lib" "$FX/logs" "$FX/flags" "$FX/locks" "$FX/env" "$FX/fly" \
           "$FX/state/fly" "$FX/state/fly-pool" "$FX/fakebin"

  # REAL code — nothing in this list is rewritten or re-typed.
  cp "$DIR/bin/fly-onboard.sh" "$DIR/bin/fly-pool-rollout.sh" "$DIR/bin/fleet-conf.sh" \
     "$DIR/bin/box-for.sh" "$DIR/bin/box-name.sh" "$DIR/bin/pool-cap.sh" \
     "$DIR/bin/free-slots.sh" "$DIR/bin/count-builds.sh" "$DIR/bin/result-prefix-ok.sh" \
     "$FX/bin/"
  cp "$DIR/bin/lib/hub-box.sh" "$DIR/bin/lib/build-caps.sh" "$FX/bin/lib/"
  cp "$DIR/bin/alert-line.sh" "$FX/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh

  # Stubs for the steps that would touch a builder, a registry or a box.
  printf '#!/bin/bash\necho "image: registry.fly.io/builder-$1:deployment-TEST"\nexit 0\n' \
    > "$FX/bin/fly-image-build.sh"
  printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' \
    > "$FX/bin/fly-envbundle.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logs/beats.log"\nexit 0\n' "$FX" \
    > "$FX/bin/beat.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logs/harden-state.log"\nexit 0\n' "$FX" \
    > "$FX/bin/harden-state.sh"
  chmod +x "$FX/bin"/*.sh

  # Two projects, so "never touch another project's anything" is testable.
  # box-small is deliberately NOT the hub name.
  cat > "$FX/fleet.conf" <<'CONF'
# project      repo                       prod                                 pfx off box                     tailnet_ip
alpha          example-org/alpha            -                                    -   1  box-small     10.0.0.13
beta           example-org/beta             -                                    -   3  box-small     10.0.0.13
CONF
  # Fake tokens, in the literal shape the rollout expects (a space in the value
  # is why fly-pool-rollout.sh quotes it when it appends one).
  cat > "$FX/env/fly.env" <<'ENV'
FLY_ORG=testorg
FLY_API_TOKEN_ALPHA="FlyV1 test-token-not-real"
FLY_API_TOKEN_BETA="FlyV1 test-token-not-real-b"
ENV
  : > "$FX/env/global.env"

  # flyctl: every invocation is recorded, so "zero flyctl calls" and "never
  # named project B" are assertions about a file rather than about intent.
  cat > "$FX/fakebin/flyctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$FLY_CALLS"
case "$*" in
  *"machine run"*)   [ "${MACHINE_RUN_SILENT:-0}" = 1 ] || echo "Machine ID: e8aaaaaaaaaaaa" ;;
  *"machines list"*) echo '[{"id":"e8aaaaaaaaaaaa","state":"started"}]' ;;
  *"/run/harness/RESULT"*) printf '%s\n' "${SMOKE_RESULT:-SMOKE_OK}" ;;
  *) : ;;
esac
exit 0
STUB
  cat > "$FX/fakebin/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_LOG"
exit 0
STUB
  # GNU timeout shim (same reason as tests/hub-no-build-lanes-test.sh): the
  # production lines wrap every flyctl call in one, and a fixture must not
  # depend on the host having it.
  printf '#!/bin/bash\nshift\nexec "$@"\n' > "$FX/fakebin/timeout"
  chmod +x "$FX/fakebin"/*

  export HARNESS="$FX"
  export FLEET_CONF="$FX/fleet.conf"
  export FLYCTL_DIR="$FX/fakebin"
  export ROLLOUT_BOOT_WAIT=0 ROLLOUT_POLL_WAIT=0
  export FLY_CALLS="$FX/logs/flyctl-calls.log"
  export SSH_LOG="$FX/logs/ssh.log"
  export PATH="$FX/fakebin:$PATH"
}
