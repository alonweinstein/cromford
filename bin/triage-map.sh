#!/bin/bash
# bin/triage-map.sh render — the harness's own static map, rendered from real
# sources, for injection into the triage lanes' prompts.
#
# WHY (2026-08-25, from a turn-by-turn reconstruction of a real 56-turn triage
# session): 14 of those 56 turns went on re-deriving facts that are identical in
# every session — where the logs live, which boxes exist, how a ticket fetch
# authenticates. Another 8 went hunting a Railway fix on a host that has neither
# a railway CLI nor a railway credential: a dead end that was knowable at turn 0
# and cost a full session's worth of turns to discover.
#
# So the map is HOISTED into the prompt. Two rules make that safe:
#   1. Nothing here is hand-written prose. A hand-maintained map goes stale and
#      then LIES, which is worse than no map. Every line below is derived at
#      render time from the file or probe that is already the harness's source
#      of truth for that fact, and each section cites it.
#   2. Nothing here is left to the model to rediscover. LLM adherence is
#      probabilistic; deterministic code managing the LLM is the standing
#      principle of this wave.
#
# Contract: plain bash, no new dependencies, well under a second, read-only, and
# safe on the hub. Callers treat a nonzero exit as "no map" and say so out loud
# (see the ORIENTATION MAP block in alert-triage.sh / alerts-medic.sh) — the map
# must never block triage, and must never be silently omitted either.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")

# ── capability probes ───────────────────────────────────────────────────────
# Three outcomes, never two. A probe that cannot answer renders UNKNOWN; it must
# never render a CAN we did not verify (sends the lane down a path that 403s) or
# a CANNOT we did not verify (kills a fix the lane could actually have made).
#
# run_probe <fn> [args] -> yes | no | unknown
#   the probe function prints yes/no and exits 0; ANY other exit code or output
#   is an inconclusive probe.
run_probe() {
  local out rc
  out=$("$@" 2>/dev/null); rc=$?
  case "$rc:$out" in
    0:yes) echo yes ;;
    0:no)  echo no ;;
    *)     echo unknown ;;
  esac
}

have_cli() { command -v "$1" >/dev/null 2>&1 && echo yes || echo no; }

command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
# gh distinguishes "not logged in" (documented exit 1) from any other failure.
# Collapsing the two would render a confident CANNOT for a gh that is merely
# broken. stdout is discarded: `gh auth token` prints the token itself.
gh_authed() {
  # timeout where the host has it (Linux boxes do): this renders on every triage
  # tick, and a probe that hangs would stall the lane it was meant to speed up.
  # A timeout exits 124 -> UNKNOWN, which is the correct answer for "no idea".
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 gh auth token >/dev/null 2>&1
  else
    gh auth token >/dev/null 2>&1
  fi
  case "$?" in
    0) echo yes ;;
    # C2 (2026-09-24): a box whose keyring was logged out still authenticates —
    # bin/gh-ledger/gh hands every example-org call an App installation token
    # (bin/lib/gh-app-default.sh). "Not logged in" is only CANNOT when that
    # route is absent too; the probe is file tests, never a mint.
    1) if [ -r "$HENV/github-app.env" ] && [ -x "$HARNESS/bin/gh-token.sh" ] \
          && [ -r "$HARNESS/bin/lib/gh-app-default.sh" ] && ! lane_switch gh-app-default-off; then
         echo yes
       else
         echo no
       fi ;;
    *) return 9 ;;
  esac
}

have_env()  { [ -n "${!1:-}" ] && echo yes || echo no; }
have_file() { [ -e "$1" ] && echo yes || echo no; }

# PROBE WHAT THE CONSUMER READS, not what the variable is "obviously" called.
# A credential that lives in a file the lanes never source is invisible to a
# bare `have_env`, and the map then renders a confident CANNOT for a capability
# that works — which is the harmful direction, because a CANNOT here is read as
# a documented dead end rather than as "check it yourself". So a credential kept
# in a side env file is probed by grepping that file for the variable the
# consuming script actually dereferences.
# have_env_file <file> <ERE matching the var at line start>
have_env_file() {
  [ -f "$1" ] || { echo no; return 0; }
  grep -qE "$2" "$1"
  case "$?" in
    0) echo yes ;;
    1) echo no ;;
    *) return 9 ;;   # grep ERRORED (unreadable, bad pattern) — that is not "absent"
  esac
}

# flyctl_where -> "<onpath|offpath> <absolute path>", or nonzero if truly absent.
# PATH first, then the installer's own directory — the location six scripts here
# already hardcode as `export PATH="/root/.fly/bin:$PATH"` because cron's PATH
# lacks it. $HOME rather than a literal /root so a fixture can stand in for it.
flyctl_where() {
  local c p
  for c in fly flyctl; do
    if p=$(command -v "$c" 2>/dev/null) && [ -n "$p" ]; then echo "onpath $p"; return 0; fi
  done
  for p in "${HOME:-/root}/.fly/bin/flyctl" "${HOME:-/root}/.fly/bin/fly"; do
    [ -x "$p" ] && { echo "offpath $p"; return 0; }
  done
  return 1
}

# Any project env file carrying the var (used for per-project credentials).
# have_project_env <ERE>
have_project_env() {
  local f
  for f in "$HENV"/*.env; do
    [ -f "$f" ] || continue
    grep -qE "$1" "$f" && { echo yes; return 0; }
  done
  echo no
}

# an ssh key in any of the standard locations — the fleet lanes ssh as root with
# BatchMode (alert-triage.sh's collector loop; alerts-medic.sh's SOP bounds).
have_ssh_key() {
  local d="${HOME:-/root}/.ssh"
  for k in "$d/id_ed25519" "$d/id_rsa" "$d/id_ecdsa"; do
    [ -f "$k" ] && { echo yes; return 0; }
  done
  echo no
}

# cap <tool> <cli:yes|no|unknown> <cred:yes|no|unknown> <can-note> <cannot-note>
cap() {
  local tool="$1" cli="$2" cred="$3" cannote="$4" cantnote="$5"
  if [ "$cli" = unknown ] || [ "$cred" = unknown ]; then
    echo "  UNKNOWN: $tool (probe failed) — verify before relying on it either way"
  elif [ "$cli" = yes ] && [ "$cred" = yes ]; then
    echo "  CAN: $tool ($cannote)"
  else
    echo "  CANNOT: $tool ($cantnote) — escalate instead of hunting"
  fi
}

render_map() {
  echo "=== HARNESS ORIENTATION (deterministically rendered — do NOT re-derive any of this) ==="
  echo "Rendered $(date -u '+%Y-%m-%d %H:%M:%SZ') by bin/triage-map.sh from fleet.conf and live probes on this host. It is current; spending turns rediscovering it is waste."

  # FLEET — every field from fleet.conf via bin/fleet-conf.sh (the registry's own
  # reader); the owning box via bin/box-for.sh, which is what fleet-heartbeat.sh
  # and sweep-stale-builds.sh already use to resolve an ssh target for a project.
  echo
  echo "FLEET (project | repo | board API | owning box, ssh root@<box>)"
  local p repo prod prefix box board
  for p in $("$HERE/fleet-conf.sh" --projects 2>/dev/null); do
    repo=$("$HERE/fleet-conf.sh" "$p" repo 2>/dev/null || echo '?')
    prod=$("$HERE/fleet-conf.sh" "$p" prod 2>/dev/null || echo '-')
    prefix=$("$HERE/fleet-conf.sh" "$p" board_prefix 2>/dev/null || echo '-')
    box=$("$HERE/box-for.sh" "$p" 2>/dev/null || echo '?')
    if [ "$prod" = '-' ] || [ "$prefix" = '-' ]; then
      board='no board API (see prompts/'"$p"'.md)'
    else
      board="$prod$prefix"
    fi
    printf '  %s | %s | %s | %s\n' "$p" "$repo" "$board" "$box"
  done

  # GEOGRAPHY — the paths are identical on the hub and every worker box. Each is
  # named once here with the script that owns it, so a lane never has to go find
  # out where something lives.
  echo
  echo "GEOGRAPHY (identical on hub and every box; H=$HARNESS)"
  echo "  H/logs/ALERTS.log  fleet alert stream | H/logs/<project>.log  watcher log, mtime = box liveness"
  echo "  H/logs/alert-triage.log + H/logs/medic.log  the two lanes' own ledgers"
  echo "  H/state/alert-quarantine.jsonl  pre-triage beat queue (beat.sh writes it, alert-triage drains it)"
  echo "  H/state/build-queue/<project>/ and H/state/fly-pool/<project>/  queued builds"
  echo "  H/builds/<pool-project-KEY-n>/  a build's working dir (RESULT, review.md, logs)"
  echo "  H/env/global.env fleet-wide + H/env/<project>.env per project (secrets; never echo them)"
  echo "  READ CAPPED: tail -c 20000 on any log; never cat a rolling one."

  # RECIPES — one line each, taken from the scripts' own headers.
  echo
  echo "RECIPES (already built — do not reimplement inline)"
  echo "  ticket fetch: H/bin/board-fetch.sh <url> [--full] [--last N] — trims the thread before it costs"
  echo "    context and authenticates itself with the project's <PREFIX>_INTERNAL_API_TOKEN. No headers to assemble."
  echo "  escalate: H/bin/beat.sh '{\"kind\":\"fleet_alert\",\"project\":\"<p>\",\"triaged\":true,\"akey\":\"<k>\",\"line\":\"<...>\"}'"
  echo "    — without \"triaged\":true it is re-quarantined, not delivered."
  echo "  box resolve: H/bin/box-for.sh <project> -> hostname, or \"local\" for the hub."

  # CAPABILITIES — probed on this host, right now. The CANNOT lines are the
  # point of this whole block: on 2026-08-25 a session burned 8 turns looking
  # for a Railway fix on a host with no railway CLI and no railway credential.
  echo
  echo "CAPABILITIES (probed on this host just now — a CANNOT is a dead end, not a challenge)"

  # gh: named in both lanes' SOP (STEP 0 re-verify, `gh pr view --json state`).
  local gh_cli gh_auth
  gh_cli=$(run_probe have_cli gh)
  if [ "$gh_cli" = yes ]; then gh_auth=$(run_probe gh_authed); else gh_auth=no; fi
  cap "gh" "$gh_cli" "$gh_auth" "CLI present, authed — PR/issue state lookups are one call" \
      "CLI or auth missing"

  # ssh to worker boxes: alert-triage.sh's collector loop; medic SOP "ALLOWED: ssh to worker boxes".
  cap "ssh to fleet boxes" "$(run_probe have_cli ssh)" "$(run_probe have_ssh_key)" \
      "key present — ssh root@<box> from the FLEET table above" \
      "no client or no key"

  # curl / jq / python3: used by every lane and by beat.sh, alerts-groom.sh, the
  # family brakes. Probed individually, reported as one line — a missing one is
  # the interesting case and it names itself.
  local base b missing=""
  for b in curl jq python3; do
    base=$(run_probe have_cli "$b")
    [ "$base" = yes ] || missing="$missing $b($base)"
  done
  if [ -z "$missing" ]; then
    echo "  CAN: curl, jq, python3 (all present)"
  else
    echo "  CANNOT: base tools —$missing not usable; work around them rather than installing anything"
  fi

  # sentry-lookup.sh: SOP says SENTRY FIRST for app errors. CONSUMER:
  # bin/sentry-lookup.sh:22 reads $SENTRY_API_TOKEN from the environment, and the
  # lanes export env/global.env with `set -a` — so the bare env probe is the
  # right one here, and the script no-ops without it.
  cap "sentry-lookup.sh" "$(run_probe have_file "$HERE/sentry-lookup.sh")" "$(run_probe have_env SENTRY_API_TOKEN)" \
      "run it before theorising about any 500/timeout on an owned app" \
      "script or SENTRY_API_TOKEN missing — it would silently no-op"

  # console alert-resolve API. CONSUMER: bin/beat.sh:31 and alerts-medic.sh:19
  # both read $CONSOLE_URL / $HARNESS_SECRET from the exported global.env.
  local con sec
  con=$(run_probe have_env CONSOLE_URL); sec=$(run_probe have_env HARNESS_SECRET)
  cap "console API" "$con" "$sec" \
      "POST \$CONSOLE_URL/api/alerts/resolve with Bearer \$HARNESS_SECRET to settle verified alerts" \
      "CONSOLE_URL or HARNESS_SECRET unset"

  # fly builder pool. CONSUMER: bin/fly-api.sh:37-41 sources $HENV/fly.env
  # and dereferences a PER-APP FLY_API_TOKEN_<PROJECT> — it never reads a bare
  # FLY_API_TOKEN, and the lanes source only global.env, so an env probe for the
  # bare name renders CANNOT on a host whose fly pool is fully operational. That
  # false CANNOT is worse than no line at all: it converts "I should check" into
  # "documented dead end". Probe the file the consumer sources.
  #
  # TWO ARMS, AND THEY ARE NOT THE SAME CAPABILITY (live-hub finding, 2026-08-25).
  # ANDing them was wrong for the majority of what "fly" means here: fly-api.sh —
  # the machine start/stop/state consumer — is pure curl plus the per-app token
  # and contains ZERO flyctl references. Only fly-dispatch/fly-pool/fly-image/
  # fly-sync-harness shell out to the binary. So the TOKEN arm alone decides
  # CAN/CANNOT, and the binary only qualifies the note.
  #
  # And the binary is PATH-blind: flyctl's installer puts it in ~/.fly/bin, which
  # cron's PATH lacks — which is why six scripts in this very repo open with
  # `export PATH="/root/.fly/bin:$PATH"` (fly-dispatch.sh:30 says so out loud).
  # A `command -v` probe therefore reported "no flyctl" on a host with a live fly
  # pool, and the AND turned that into a blanket CANNOT — a wrong dead end, which
  # produces a wrong escalation to the operator and is worse than the hunt it replaced.
  # Same precedent agent-call.sh uses for grok ($HOME/.grok/bin).
  #
  # When it is found off PATH the line NAMES the path. Orientation is the job:
  # "the binary is at X, not on your PATH" is a saved turn; "CANNOT" is a lie.
  local fly_tok fly_at
  fly_tok=$(run_probe have_env_file "$HENV/fly.env" '^[[:space:]]*(export[[:space:]]+)?FLY_API_TOKEN_')
  fly_at=$(flyctl_where || true)
  if [ "$fly_tok" = unknown ]; then
    echo "  UNKNOWN: fly (probe failed) — verify before relying on it either way"
  elif [ "$fly_tok" = no ]; then
    echo "  CANNOT: fly ($HENV/fly.env carries no FLY_API_TOKEN_<PROJECT> line, so neither the API nor the CLI can authenticate) — escalate instead of hunting"
  elif [ -z "$fly_at" ]; then
    echo "  CAN: fly API (per-app tokens in env/fly.env; bin/fly-api.sh is pure curl — machine start/stop/state works). No flyctl on this host: dispatch/pool/image ops that shell out to it are NOT available."
  elif [ "${fly_at%% *}" = offpath ]; then
    echo "  CAN: fly (per-app tokens in env/fly.env; flyctl at ${fly_at#* } — NOT on PATH, invoke it by full path)"
  else
    echo "  CAN: fly (per-app tokens in env/fly.env; flyctl on PATH at ${fly_at#* })"
  fi

  # vercel deploys. CONSUMER: bin/deploy-verify.sh:29 and bin/deploy-train.sh:36
  # POST a project's $DEPLOY_HOOK_URL, read from $HENV/<project>.env.
  # NOTHING in this harness shells out to a `vercel` CLI or reads VERCEL_TOKEN —
  # probing that name was probing a variable with no consumer. Saying which
  # mechanism DOES exist kills the "go find the vercel CLI" detour.
  cap "vercel deploys" "$(run_probe have_project_env '^[[:space:]]*(export[[:space:]]+)?DEPLOY_HOOK_URL=.')" yes \
      "fire the project's DEPLOY_HOOK_URL from $HENV/<project>.env — that is the harness's only deploy path; there is no CLI" \
      "no project env carries a DEPLOY_HOOK_URL, and there is no vercel CLI path in this harness"

  # railway: project-5's worker runs on Railway (prompts/project-5.md), and this
  # is the exact dead end that cost 8 turns. NO CONSUMER EXISTS — no script in
  # bin/ reads a railway credential or shells out to the CLI — so this CANNOT is
  # structural, not a missing token, and stays a CANNOT unless both a CLI and a
  # credential appear.
  cap "railway" "$(run_probe have_cli railway)" "$(run_probe have_env RAILWAY_TOKEN)" \
      "CLI and token present — but no harness script uses them; verify before relying on it" \
      "no CLI, no credential, and no harness script that would use one — a Railway-side fix is not available from here; escalate it"

  echo
  echo "=== END HARNESS ORIENTATION ==="
}

case "${1:-render}" in
  render) render_map ;;
  *) echo "usage: triage-map.sh render" >&2; exit 2 ;;
esac
