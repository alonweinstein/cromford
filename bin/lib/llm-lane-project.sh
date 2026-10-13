# shellcheck shell=bash
# bin/lib/llm-lane-project.sh — an LLM alert lane on the per-project runner
# (BH-5942, wave 2 of #5938). alert-triage, alerts-medic and watchdog-responder
# call it. The runner itself is bin/lib/project-lanes.sh (BH-5913).
#
#   llp_is_dispatch [arg]          rc 0 when the lane was started with no
#                                  argument or with --dispatch.
#   llp_dispatch <lane>            pl_dispatch one run per project of the lane
#                                  script ($0), spread over
#                                  LLM_LANE_DISPATCH_SPREAD_SECS (default 300,
#                                  0 = all at once). Prints pl_dispatch's line
#                                  on stdout and appends it to LLP_LOG. Returns
#                                  pl_dispatch's rc. Never exits.
#   llp_enter <lane> <word> [arg]  the whole entry. No arg or --dispatch:
#                                  llp_dispatch, then EXIT with its rc. A name
#                                  that fails pl_name_ok: one stderr line, exit
#                                  2. A project: keep the runner's lock when the
#                                  runner started this run, else take
#                                  locks/<lane>-<project>.lock on fd 9 (held:
#                                  one stdout line, exit 0). Sets LLP_LANE,
#                                  LLP_PROJECT, LLP_WORD and LLP_STATE (the
#                                  runner's PL_STATE_DIR, or
#                                  state/<lane>/<project> for a hand run).
#   llp_arm                        call AFTER env/global.env and lane_env_apply:
#                                  re-arms the project's GitHub App token
#                                  (pl_token; none on this box = GH_TOKEN
#                                  unchanged, one LLP_LOG line) and exports
#                                  ACCOUNT_PROJECT_FOR_LANE=<word>=<project>,
#                                  which bin/lib/project-account.sh reads so the
#                                  lane's claude call runs on the project's
#                                  pinned account while its cost row keeps the
#                                  lane word.
#   llp_home_project               the run that owns an item with no project:
#                                  LLM_LANE_HOME_PROJECT, default cromford.
#   llp_route <project-field>      the project whose run owns the field: the
#                                  field itself when it is a fleet.conf project
#                                  (exact string), else the home project.
#   llp_owns <project-field>       rc 0 when llp_route of the field is
#                                  LLP_PROJECT.
#
# The caller sets LLP_LOG (default logs/<lane>.log) before llp_enter. Needs $H.
# Defines functions only. Nothing runs on source.

_llp_root() { printf '%s' "${HARNESS:-${H:-}}"; }

_llp_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

_llp_log() {
  local h; h=$(_llp_root)
  [ -n "$h" ] || return 0
  printf '%s %s\n' "$(_llp_stamp)" "$*" >> "${LLP_LOG:-$h/logs/${LLP_LANE:-llm-lane}.log}" 2>/dev/null
  return 0
}

# _llp_need_runner — load bin/lib/project-lanes.sh when it is not loaded.
_llp_need_runner() {
  local h; h=$(_llp_root)
  command -v pl_dispatch >/dev/null 2>&1 && return 0
  [ -n "$h" ] && [ -r "$h/bin/lib/project-lanes.sh" ] || return 1
  # shellcheck source=bin/lib/project-lanes.sh
  . "$h/bin/lib/project-lanes.sh"
}

# _llp_knobs — the two knobs of this lib, from their settings rows when the
# lane gate is loaded (catalog/lanes.d/_lib.llm-lane-project.json).
_llp_knobs() {
  [ "${_LLP_KNOBS_DONE:-0}" = 1 ] && return 0
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply llm-lane-project >/dev/null 2>&1
  _LLP_KNOBS_DONE=1
}

llp_is_dispatch() {
  case "${1:-}" in ''|--dispatch) return 0 ;; esac
  return 1
}

llp_dispatch() {
  local lane="${1:-}" spread self line rc=0 h
  h=$(_llp_root)
  [ -n "$h" ] || { echo "llp_dispatch: no harness root" >&2; return 2; }
  _llp_need_runner || { echo "llp_dispatch: bin/lib/project-lanes.sh is not loaded — no project run started" >&2; return 2; }
  LLP_LANE="$lane"
  _llp_knobs
  spread="${LLM_LANE_DISPATCH_SPREAD_SECS:-300}"
  case "$spread" in
    *[!0-9]*|'')
      _llp_log "$lane: LLM_LANE_DISPATCH_SPREAD_SECS='$spread' is not a number of seconds — using 300"
      spread=300 ;;
  esac
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  line=$(pl_dispatch "$lane" "$spread" bash "$self") || rc=$?
  printf '%s\n' "$line"
  _llp_log "$line"
  # Items with no project go to the home project's run. A home that fleet.conf
  # does not name gets no run, so those items wait: say so on every dispatch.
  if [ "$rc" = 0 ] && ! _llp_in_fleet "$(llp_home_project)"; then
    _llp_log "$lane: the home project '$(llp_home_project)' (LLM_LANE_HOME_PROJECT) is not in fleet.conf — no run owns items with no project; they wait until it is"
  fi
  return "$rc"
}

llp_enter() {
  local lane="${1:-}" word="${2:-}" arg="${3:-}" h rc
  h=$(_llp_root)
  [ -n "$h" ] || { echo "llp_enter: no harness root" >&2; exit 2; }
  if llp_is_dispatch "$arg"; then
    llp_dispatch "$lane"
    exit $?
  fi
  _llp_need_runner || { echo "llp_enter: bin/lib/project-lanes.sh is not loaded" >&2; exit 2; }
  if ! pl_name_ok "$arg"; then
    echo "$lane: '$arg' is not a project name" >&2
    exit 2
  fi
  LLP_LANE="$lane"; LLP_PROJECT="$arg"; LLP_WORD="$word"
  if [ "${PL_LANE:-}" = "$lane" ] && [ "${PL_PROJECT:-}" = "$arg" ] \
     && [ -n "${PL_LOCK_FD:-}" ] && { : >&"$PL_LOCK_FD"; } 2>/dev/null; then
    LLP_STATE="${PL_STATE_DIR:-$h/state/$lane/$arg}"
  else
    pl_lock_take "$lane" "$arg" 9; rc=$?
    if [ "$rc" = 1 ]; then
      echo "$(_llp_stamp) $lane: a run of $arg is still live (locks/$lane-$arg.lock held) — this run starts nothing"
      exit 0
    fi
    [ "$rc" = 0 ] || { echo "$lane: cannot take locks/$lane-$arg.lock (rc=$rc)" >&2; exit 2; }
    LLP_STATE="$h/state/$lane/$arg"
  fi
  mkdir -p "$LLP_STATE" 2>/dev/null
  export LLP_LANE LLP_PROJECT LLP_WORD LLP_STATE
  return 0
}

llp_arm() {
  local h slug
  h=$(_llp_root)
  [ -n "${LLP_PROJECT:-}" ] || return 1
  _llp_knobs
  if [ -z "${PL_SLUG:-}" ] && [ -n "$h" ]; then
    slug=$("$h/bin/fleet-conf.sh" "$LLP_PROJECT" repo 2>/dev/null) || slug=""
    case "$slug" in */*) PL_SLUG="$slug" ;; esac
  fi
  export PL_SLUG="${PL_SLUG:-}"
  if ! pl_token; then
    _llp_log "${LLP_LANE:-}: no GitHub App token for ${LLP_PROJECT} (${PL_SLUG:-no repo}) on this box — GH_TOKEN stays the box token"
  fi
  export ACCOUNT_PROJECT_FOR_LANE="${LLP_WORD:-$LLP_LANE}=$LLP_PROJECT"
  return 0
}

llp_home_project() {
  local p="${LLM_LANE_HOME_PROJECT:-cromford}"
  case "$p" in .*|*[!A-Za-z0-9._-]*) p=cromford ;; esac
  printf '%s' "$p"
}

# _llp_fleet_load — fleet.conf's projects into _LLP_FLEET, read once per
# process. Called in the current shell, never in a $(...) or <(...), so the
# cache survives to the next call.
_llp_fleet_load() {
  local h
  [ -n "${_LLP_FLEET_READ:-}" ] && return 0
  h=$(_llp_root)
  _LLP_FLEET=""
  [ -n "$h" ] && _LLP_FLEET=$("$h/bin/fleet-conf.sh" --projects 2>/dev/null)
  _LLP_FLEET_READ=1
}

# _llp_in_fleet <name> — rc 0 when <name> is exactly a fleet.conf project.
_llp_in_fleet() {
  local p
  [ -n "${1-}" ] || return 1
  _llp_fleet_load
  while IFS= read -r p; do
    [ -n "$p" ] && [ "$p" = "$1" ] && return 0
  done <<<"$_LLP_FLEET"
  return 1
}

llp_route() {
  local f="${1-}"
  if [ "$f" != harness ] && _llp_in_fleet "$f"; then printf '%s' "$f"; return 0; fi
  llp_home_project
}

llp_owns() {
  [ -n "${LLP_PROJECT:-}" ] || return 1
  [ "$(llp_route "${1-}")" = "$LLP_PROJECT" ]
}
