#!/bin/bash
# fly/entrypoint.sh — builder machine boot (Phase 1 of the Fly builder trial).
#
# Runs as PID-1 child of tini. Order (per plan "Phase 1 > fly/entrypoint.sh"):
#   1. tmpfs at /run/harness-env (mode 700) — secrets live in RAM only; a
#      stopped/crashed machine's volume never holds a client token.
#   2. tailscaled (state on the volume so node identity survives stop/start) +
#      `tailscale up` with TS_AUTHKEY (the machine's ONLY Fly secret).
#   3. Volume layout + compat symlinks so run-build.sh runs UNMODIFIED /root
#      paths against /data.
#   4. Volume health check — repo git broken => wipe + mark for re-warm (the
#      runner re-clones once env arrives; the volume is pure cache).
#   5. exec fly/builder-runner.sh.
#
# Open-detail decisions (simplest robust option, per task brief):
#   - PROJECT is derived from Fly's injected FLY_APP_NAME ("builder-<project>")
#     with a PROJECT env override for hand-runs. Fail loudly if neither yields a
#     project — a builder with no project identity must not proceed.
#   - The volume harness/env symlink points at the tmpfs so run-build.sh's
#     `. env/global.env` reads the RAM copy; nothing durable ever holds tokens.
#   - We set the OS hostname to builder-<project> so agent-call.sh's cost.csv
#     `$(hostname)` column tags rows host=builder-<project> (the plan's smoke
#     verify checks for exactly this).
#   - We prefer the volume copy of the runner scripts (/data/harness/fly, kept
#     fresh by harness sync) but fall back to the image copy at /opt/fly-boot so
#     a machine is bootable before its first sync.
set -uo pipefail

log() { echo "[entrypoint $(date -u '+%H:%M:%SZ')] $*"; }

# --- 0. identity --------------------------------------------------------------
PROJECT="${PROJECT:-}"
if [ -z "$PROJECT" ] && [ -n "${FLY_APP_NAME:-}" ]; then
  PROJECT="${FLY_APP_NAME#builder-}"
fi
if [ -z "$PROJECT" ]; then
  log "FATAL: no PROJECT (set PROJECT env or run as Fly app builder-<project>)"
  exit 1
fi
export PROJECT
# ONE BOX NAME PER MACHINE, not per pool (2026-09-11). bin/jobs-client.sh takes
# the box it reports to the ledger from $BOX_NAME, then state/box-name, then
# `hostname` — and a pool machine has neither of the first two (the hub's
# harness tarball carries bin/prompts/rules/fleet.conf, never state/), so this
# line IS the box column. Every pool machine answering "pool-<project>" made the
# ledger's `box * build 1` concurrency rule count the WHOLE POOL as one box:
# while one machine built, every other machine's claim came back "REFUSED box ::
# box max 1 already running" (project-5 TK-268/TK-270, project-4 TK-1515/1566/1571/
# 1576, all on 2026-09-11). The machine id makes the rule mean what it says —
# one build per MACHINE. Nothing keys on the exact old string: the box column is
# carried as DATA everywhere it is read (the worker's concurrency rules and its
# paused-box-<box> flag, the console's BOX column and its per-box grouping), and
# the `pool-<project>` build-dir and Fly-app names are a different namespace
# that this line never touched — grep over bin/, fly/, worker/ and console-ui/
# finds no match on the box string itself. An operator pausing a pool now pauses
# a MACHINE, which is the same shape as every other box in the fleet.
if [ "${POOL_MODE:-}" = "1" ]; then HOST="pool-$PROJECT-${FLY_MACHINE_ID:-$(hostname | tail -c 8)}"; else HOST="builder-$PROJECT"; fi
hostname "$HOST" 2>/dev/null || true
# THE COST-ROW IDENTITY, DECIDED ONCE, HERE (2026-09-14). fly/builder-runner.sh
# pushes this machine's logs/cost.csv into cost_rows under a box id, and
# bin/fly-pool.sh's reap pushes the reaped copy of the same rows under one too.
# They MUST be the same string or the PK dedupes nothing and the pool's bill is
# counted twice. Exported rather than re-derived so there is one expression in
# the tree that computes it; the runner falls back to `hostname` (which the line
# above just set to the same value) for a machine booted by an older image.
export COST_ROWS_BOX="$HOST"
log "boot for project=$PROJECT host=$HOST"

# --- 1. secrets tmpfs (RAM only) ---------------------------------------------
mkdir -p /run/harness-env /run/harness
if ! mountpoint -q /run/harness-env; then
  mount -t tmpfs -o size=16m,mode=700 tmpfs /run/harness-env \
    || { log "FATAL: could not mount tmpfs at /run/harness-env"; exit 1; }
fi
chmod 700 /run/harness-env
log "tmpfs mounted at /run/harness-env (RAM-only secrets)"

# --- 2. tailscale -------------------------------------------------------------
# POOL_MODE machines (wave 3) are ephemeral and volume-less: the hub pushes
# env + job and pulls RESULT over the Fly console, so they never join the
# tailnet and carry no TS_AUTHKEY. Skipping this block entirely is what lets
# a pool machine boot at all — the FATAL below is correct for builders.
if [ "${POOL_MODE:-}" = "1" ]; then
  log "POOL_MODE=1 — skipping tailscale (console push/pull only)"
else
if [ -z "${TS_AUTHKEY:-}" ]; then
  # A tagged node's state persists on the volume, so on a restart TS_AUTHKEY may
  # legitimately be absent while an existing state file re-authenticates. Only
  # fail if there is ALSO no prior state to fall back on.
  if [ ! -s /data/tailscaled.state ]; then
    log "FATAL: TS_AUTHKEY unset and no /data/tailscaled.state to resume from"
    exit 1
  fi
  log "TS_AUTHKEY unset; resuming from persisted /data/tailscaled.state"
fi

mkdir -p /data
# userspace-networking avoids needing a TUN device / NET_ADMIN on the Fly VM;
# hub->builder ssh works over it. --state on the volume => stable node identity.
tailscaled \
  --state=/data/tailscaled.state \
  --socket=/var/run/tailscale/tailscaled.sock \
  --tun=userspace-networking \
  >/var/log/tailscaled.log 2>&1 &
TAILSCALED_PID=$!
log "tailscaled started (pid $TAILSCALED_PID)"

# give the daemon a moment to open its socket
for _ in $(seq 1 20); do
  [ -S /var/run/tailscale/tailscaled.sock ] && break
  sleep 0.5
done

TS_UP_ARGS=(--hostname="$HOST" --ssh --accept-dns=false)
[ -n "${TS_AUTHKEY:-}" ] && TS_UP_ARGS+=(--authkey="$TS_AUTHKEY")
if tailscale up "${TS_UP_ARGS[@]}"; then
  log "tailscale up OK: $(tailscale ip -4 2>/dev/null | head -1)"
else
  # Per plan Failure-modes: on tailscale failure the builder can't be pushed a
  # job, but it CAN reach the console (outbound HTTPS) — post a fleet_alert and
  # exit so the machine autostops rather than hanging unreachable.
  log "FATAL: tailscale up failed — posting fleet_alert and exiting"
  if [ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ]; then
    curl -s --max-time 15 -X POST -H "Authorization: Bearer $HARNESS_SECRET" \
      -H 'Content-Type: application/json' \
      -d "{\"kind\":\"fleet_alert\",\"host\":\"$HOST\",\"detail\":\"tailscale up failed on builder $PROJECT\"}" \
      "$CONSOLE_URL/api/beat" >/dev/null 2>&1 || true
  fi
  exit 1
fi
fi # end non-POOL_MODE tailscale block

# --- 3. volume layout + compat symlinks --------------------------------------
# run-build.sh and its helpers hardcode /root paths; symlink them onto /data so
# the pipeline runs byte-identically. harness/env points at the tmpfs (RAM).
mkdir -p /data/repos /data/worktrees /data/harness \
         /data/pnpm-store /data/pw-cache
mkdir -p /data/harness/logs /data/harness/locks /data/harness/flags \
         /data/harness/builds /data/harness/state /data/harness/state/claims

ln_force() { # ln_force <target> <linkpath>
  local target="$1" link="$2"
  rm -rf "$link" 2>/dev/null || true
  ln -s "$target" "$link"
}
mkdir -p /root
ln_force /data/repos      /root/repos
ln_force /data/worktrees  /root/worktrees
ln_force /data/harness    /root/harness
# harness/env -> tmpfs (secrets never touch the durable volume)
ln_force /run/harness-env /data/harness/env
# Resolver override (rule 1 of bin/lib/env-path.sh): every child of the runner
# resolves the env dir to the tmpfs directly; the symlink above is only for
# readers not yet ported.
export HARNESS_ENV_DIR=/run/harness-env
# build-slots=1 (single machine = single slot, wip=1 per the plan)
echo 1 > /data/harness/flags/build-slots

# Prefer the tarball's runner — and WAIT for it. On volume-less pool machines
# the hub pushes the tarball ~20s after boot; exec-ing the image floor first
# meant every runner improvement shipped nowhere until an image rebuild (the
# 2026-08-15 HARNESS_CHECKOUT/TARGET_BRANCH class). Wait up to 120s for the
# sync to land, then fall back to the image floor — which stays only a floor.
mkdir -p /data/harness/bin /data/harness/fly
WAITED=0
while [ ! -x /data/harness/fly/builder-runner.sh ] && [ "$WAITED" -lt 120 ]; do
  sleep 5; WAITED=$((WAITED + 5))
done
if [ ! -x /data/harness/fly/builder-runner.sh ]; then
  log "no tarball runner after ${WAITED}s — using image floor"
  cp /opt/fly-boot/builder-runner.sh /data/harness/fly/builder-runner.sh
  chmod +x /data/harness/fly/builder-runner.sh
else
  log "tarball runner arrived after ${WAITED}s"
fi
RUNNER=/data/harness/fly/builder-runner.sh
log "volume layout ready; runner=$RUNNER"

# --- 4. volume health check ---------------------------------------------------
REPO_DIR="/data/repos/$PROJECT"
if [ -e "$REPO_DIR/.git" ]; then
  if git -C "$REPO_DIR" rev-parse HEAD >/dev/null 2>&1; then
    log "repo cache healthy at $REPO_DIR ($(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null))"
  else
    log "repo cache CORRUPT at $REPO_DIR — wiping for re-warm"
    rm -rf "$REPO_DIR"
  fi
else
  log "no warm repo at $REPO_DIR — runner will clone on first job (cold start)"
fi

# --- 5. hand off to the runner ------------------------------------------------
log "exec builder-runner"
exec "$RUNNER"
