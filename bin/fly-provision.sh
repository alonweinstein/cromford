#!/bin/bash
# bin/fly-provision.sh <project> [--rebuild] — provision the per-project Fly
# builder (Phase 1 of the Fly builder trial). Runs on the HUB only.
#
# Creates (idempotently, per plan "Phase 1 > bin/fly-provision.sh"):
#   - Fly app  builder-<project>  in org $FLY_ORG (board-builders)
#   - Volume   builder_data  40GB in region iad
#   - Image    pushed to registry.fly.io/builder-<project> (fly deploy --build-only)
#   - Machine  from the sized image, -v builder_data:/data --restart no
#   - Secret   TS_AUTHKEY (staged; --rebuild does NOT touch it)
#   - state/fly/<project>.json  {app,machine_id,volume_id,size,region}
#   - Per-app deploy token appended to env/fly.env as FLY_API_TOKEN_<PROJECT>
#
# --rebuild: destroys + recreates ONLY the volume (corruption recovery); leaves
#            the app, secrets, and deploy token intact.
#
# Credentials: FLY_ORG and (bootstrap) FLY_API_TOKEN come from
# /root/harness/env/fly.env (chmod 600) — NEVER hardcoded. TS_AUTHKEY per project
# comes from env/fly.env as TS_AUTHKEY_<PROJECT> (minted in Phase 0, Tailscale).
#
# Open-detail decisions (simplest robust option, per task brief):
#   - Sizing table lives in one place (size_for) so Phase 3's A/B is a one-line
#     edit; project-3 (Phase-1 pilot) and the default are performance-4x/16GB per plan.
#   - flyctl drives create/volume/deploy/machine/secrets/tokens (the plan says
#     provisioning uses flyctl; only the runtime start/stop uses the raw API).
#   - The image build+push is delegated to bin/fly-image-build.sh, which the
#     operator runs where docker exists; provisioning ASSUMES the image is in the
#     app registry and machine-run references it. We check and fail loudly with
#     the exact remediation if the registry image is absent, rather than trying
#     to build here (no docker on the hub).
#   - Idempotency is achieved by treating "already exists" as success on each
#     create step and by keying the deploy-token write on FLY_API_TOKEN_<PROJECT>
#     absence in env/fly.env (never appends a duplicate).
#   - We DO NOT run this script from the harness; it is operator/orchestrator-run.
set -uo pipefail

PROJECT="${1:?usage: fly-provision.sh <project> [--rebuild]}"
REBUILD=""
[ "${2:-}" = "--rebuild" ] && REBUILD=1

HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
FLYENV="$HENV/fly.env"
STATE_DIR="$HARNESS/state/fly"
APP="builder-$PROJECT"
VOLUME="builder_data"
REGION="iad"

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
die()   { echo "$(STAMP) [fly-provision/$PROJECT] FATAL: $*" >&2; exit 1; }
log()   { echo "$(STAMP) [fly-provision/$PROJECT] $*"; }

command -v fly >/dev/null 2>&1 || command -v flyctl >/dev/null 2>&1 || die "flyctl not installed on this host"
FLY=$(command -v fly || command -v flyctl)
command -v jq >/dev/null 2>&1 || die "jq required"

[ -f "$FLYENV" ] || die "$FLYENV missing (create it chmod 600 with FLY_ORG, FLY_API_TOKEN, TS_AUTHKEY_<PROJECT>)"
set -a; . "$FLYENV"; set +a
[ -n "${FLY_ORG:-}" ] || die "FLY_ORG unset in $FLYENV"

# The bootstrap FLY_API_TOKEN (org-scoped, from fly.env) authorizes app/token
# creation; per-app deploy tokens are minted below for the runtime dispatcher.
[ -n "${FLY_API_TOKEN:-}" ] || die "FLY_API_TOKEN unset in $FLYENV (org-scoped bootstrap token)"
export FLY_API_TOKEN
export FLY_ACCESS_TOKEN="$FLY_API_TOKEN"   # flyctl honors either name

# per-project tailscale auth key (minted tagged in Phase 0)
PU=$(echo "$PROJECT" | tr '[:lower:].-' '[:upper:]__')
TS_VAR="TS_AUTHKEY_$PU"
TS_AUTHKEY="${!TS_VAR:-}"

size_for() { # size_for <project>  -> "cpu-kind cpus memory"
  case "$1" in
    project-1) echo "performance 8 32768" ;;   # Phase-3 A/B (busiest); provision now only if invoked
    *)           echo "performance 4 16384" ;;    # default incl. project-3 pilot
  esac
}
read -r CPU_KIND CPUS MEM_MB <<<"$(size_for "$PROJECT")"
SIZE_LABEL="$CPU_KIND-${CPUS}x/${MEM_MB}MB"

mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/$PROJECT.json"

# --- image presence guard -----------------------------------------------------
IMAGE="registry.fly.io/$APP:latest"
# Prefer the exact ref recorded by fly-image-build.sh (build-only pushes get
# deployment-XXXX tags; :latest is never created).
# BH-2523: the fly_images row's active digest first, then the file, then :latest.
# shellcheck source=bin/lib/fly-image-row.sh
[ -r "$HARNESS/bin/lib/fly-image-row.sh" ] && . "$HARNESS/bin/lib/fly-image-row.sh" 2>/dev/null
ROW_IMAGE=""
declare -F fir_digest >/dev/null 2>&1 && { ROW_IMAGE=$(fir_digest "$PROJECT" 2>/dev/null) || ROW_IMAGE=""; }
if [ -n "$ROW_IMAGE" ]; then IMAGE="$ROW_IMAGE"
elif [ -s "$STATE_DIR/$PROJECT.image" ]; then IMAGE=$(cat "$STATE_DIR/$PROJECT.image"); fi

# --- rebuild path: volume only ------------------------------------------------
if [ -n "$REBUILD" ]; then
  log "--rebuild: destroying + recreating volume $VOLUME on $APP"
  # Stop machine first (volume can't be destroyed while attached to a running machine).
  MID=$(jq -r '.machine_id // ""' "$STATE_FILE" 2>/dev/null)
  [ -n "$MID" ] && "$FLY" machine stop "$MID" -a "$APP" 2>/dev/null || true
  [ -n "$MID" ] && "$FLY" machine destroy "$MID" -a "$APP" --force 2>/dev/null || true
  # destroy all existing builder_data volumes on this app
  for vid in $("$FLY" volumes list -a "$APP" --json 2>/dev/null | jq -r '.[] | select(.name=="'"$VOLUME"'") | .id'); do
    log "destroying volume $vid"
    "$FLY" volumes destroy "$vid" -a "$APP" -y 2>/dev/null || true
  done
fi

# --- 1. app -------------------------------------------------------------------
if "$FLY" apps list --json 2>/dev/null | jq -e '.[] | select(.Name=="'"$APP"'" or .name=="'"$APP"'")' >/dev/null 2>&1; then
  log "app $APP already exists"
else
  log "creating app $APP in org $FLY_ORG"
  "$FLY" apps create "$APP" --org "$FLY_ORG" || die "apps create failed"
fi

# --- 2. secret: TS_AUTHKEY (staged; applied at first deploy/machine-run) -------
if [ -z "$REBUILD" ]; then
  if [ -n "$TS_AUTHKEY" ]; then
    log "staging TS_AUTHKEY secret on $APP"
    "$FLY" secrets set "TS_AUTHKEY=$TS_AUTHKEY" -a "$APP" --stage || die "secrets set failed"
  else
    log "WARN: $TS_VAR not set in $FLYENV — machine will only boot if a prior tailscaled.state exists on the volume"
  fi
fi

# --- 3. volume ----------------------------------------------------------------
VOL_ID=$("$FLY" volumes list -a "$APP" --json 2>/dev/null | jq -r '.[] | select(.name=="'"$VOLUME"'") | .id' | head -1)
if [ -n "$VOL_ID" ]; then
  log "volume $VOLUME already exists ($VOL_ID)"
else
  log "creating volume $VOLUME 40GB in $REGION"
  "$FLY" volumes create "$VOLUME" -s 40 -r "$REGION" -a "$APP" -y || die "volumes create failed"
  VOL_ID=$("$FLY" volumes list -a "$APP" --json 2>/dev/null | jq -r '.[] | select(.name=="'"$VOLUME"'") | .id' | head -1)
fi

# --- 4. image presence (built + pushed by bin/fly-image-build.sh) -------------
if ! "$FLY" image show -a "$APP" >/dev/null 2>&1; then
  # image not yet in the app registry — the operator must build+push it first.
  log "no image in $APP registry."
  die "image $IMAGE not present. Run bin/fly-image-build.sh $PROJECT on a docker host FIRST, then re-run this."
fi

# --- 5. machine ---------------------------------------------------------------
MID=$("$FLY" machine list -a "$APP" --json 2>/dev/null | jq -r '.[0].id // ""')
if [ -n "$MID" ] && [ -z "$REBUILD" ]; then
  log "machine already exists ($MID) — leaving in place"
else
  log "creating machine size=$SIZE_LABEL image=$IMAGE"
  "$FLY" machine run "$IMAGE" \
    -a "$APP" \
    -r "$REGION" \
    --vm-cpu-kind "$CPU_KIND" \
    --vm-cpus "$CPUS" \
    --vm-memory "$MEM_MB" \
    -v "$VOLUME:/data" \
    --restart no \
    --autostart=false \
    --autostop=off \
    --env "PROJECT=$PROJECT" \
    || die "machine run failed"
  MID=$("$FLY" machine list -a "$APP" --json 2>/dev/null | jq -r '.[0].id // ""')
  # A freshly-run machine starts; stop it so it sits idle until the dispatcher wakes it.
  [ -n "$MID" ] && "$FLY" machine stop "$MID" -a "$APP" 2>/dev/null || true
fi

# --- 6. per-app deploy token (dispatcher credential; one app of blast radius) --
if grep -q "^FLY_API_TOKEN_$PU=" "$FLYENV" 2>/dev/null; then
  log "deploy token FLY_API_TOKEN_$PU already in $FLYENV — not re-minting"
else
  log "minting per-app deploy token -> FLY_API_TOKEN_$PU"
  TOK=$("$FLY" tokens create deploy -a "$APP" 2>/dev/null | tail -1)
  if [ -n "$TOK" ]; then
    # env/fly.env is immutable (+i) once bin/harden-state.sh has armed the box,
    # and under +i both the append and the chmod are EPERM. So: release, append,
    # chmod, rearm — chmod BETWEEN the two, never after — holding
    # harden-state.lock (fd 8) across the three, never across the token mint
    # above. A group redirect rather than `exec 8>` so a lock dir this process
    # cannot create skips the wrap instead of killing the run.
    mkdir -p "$HARNESS/locks" 2>/dev/null
    {
      flock -w 30 8 || true
      [ -x "$HARNESS/bin/harden-state.sh" ] && "$HARNESS"/bin/harden-state.sh --release "$FLYENV"
      umask 077
      # QUOTED (BH-666): a Fly token is `FlyV1 fm2_…` and CONTAINS A SPACE.
      # Unquoted, every script that sources this file read the token as `FlyV1`
      # and then tried to run `fm2_…` as a command — the same defect
      # bin/fly-pool-rollout.sh carried, in the same file, for the same readers.
      printf 'FLY_API_TOKEN_%s="%s"\n' "$PU" "$TOK" >> "$FLYENV"
      chmod 600 "$FLYENV"
      [ -x "$HARNESS/bin/harden-state.sh" ] && "$HARNESS"/bin/harden-state.sh --rearm "$FLYENV"
    } 8>"$HARNESS/locks/harden-state.lock"
    log "deploy token stored (chmod 600)"
  else
    log "WARN: could not mint deploy token — mint by hand: fly tokens create deploy -a $APP"
  fi
fi

# --- 7. state file ------------------------------------------------------------
umask 022
jq -nc \
  --arg app "$APP" \
  --arg mid "$MID" \
  --arg vol "${VOL_ID:-}" \
  --arg size "$SIZE_LABEL" \
  --arg region "$REGION" \
  '{app:$app, machine_id:$mid, volume_id:$vol, size:$size, region:$region}' > "$STATE_FILE"
log "wrote $STATE_FILE"

# --- 7b. registry row (BH-1035.3): the state file's DB twin ------------------
# File first, row second, fail-open: a worker that is down, refuses, or has
# fly_machines_rows off never changes this script's exit code, and the state
# file stays authoritative this cycle. `stopped` because step 5 stops the
# machine it just ran.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
if command -v machines_rows_on >/dev/null 2>&1 && machines_rows_on && [ -n "$MID" ]; then
  machine_put "$PROJECT" "$APP" "$MID" builder "" "" "" "$IMAGE" stopped \
    || log "machines row not written (worker unreachable or refused) — state file is authoritative this cycle"
fi

log "DONE. app=$APP machine=$MID volume=${VOL_ID:-?} size=$SIZE_LABEL"
log "next: bin/fly-api.sh $PROJECT start  (Phase-1 verify), then push a SMOKE job"
