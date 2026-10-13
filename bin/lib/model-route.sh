#!/bin/bash
# bin/lib/model-route.sh — BH-1510.0: which model, and which runner, serve a
# role. Sourced, never executed.
#
# THE DIRECTIVE (the operator, 2026-09-22): "We shouldn't have hardcodes anywhere; all
# of that should be DB values." 136 model-id literals were measured on main
# across ~40 files, every one of them a `${VAR:-<model-id>}` shell default or
# a bare argv literal (bin/lib/review-model.sh is the smallest,
# purest example of the shape this file replaces). This is the resolver those
# call sites move to, one at a time, in #1510.1/.2 — sourcing this file today
# changes NOTHING, because nothing calls it yet.
#
# ZERO MODEL-ID LITERALS LIVE IN THIS FILE. tests/model-literal-lint.sh checks
# that for real; do not add one, even as a comment example — grep does not
# read intent.
#
# DB-FIRST, CACHE SECOND, NEVER A GUESS. Every other bin/lib/jobs/*.sh module
# is FAIL-OPEN: an unreachable worker leaves the box behaving exactly as it did
# before the coordination DB existed (see bin/lib/jobs/req.sh's header). That
# doctrine does not apply here, because "before this table existed" WAS a
# hardcoded model literal in every caller — the exact thing #1510 exists to
# remove. So a role with nothing in the DB and nothing in this box's cache
# fails CLOSED (rc 75, the same vocabulary bin/lib/gh-rest.sh uses for
# "unverifiable, do not guess") rather than falling through to a literal that
# would just be one more hardcode, hiding in a different file.
#
# CACHE IS A SUBSTITUTE FOR AN UNREACHABLE WORKER, NOT FOR "THE WORKER SAID NO
# ROUTE". A reachable worker's `source:"none"` is authoritative: it means the
# role genuinely has no route yet, and the fix is to PUT one, not to replay
# whatever this box last happened to cache for it (possibly for a role that
# existed under this name once and does not any more).
#
# PRECEDENCE IS PER ROLE, NOT PER RUNG — a project either owns its whole ladder
# for a role or none of it (worker/jobs/src/lib/core.js resolveModelLadder
# carries the same rule; see that file for why).

MODEL_ROUTE_HARNESS="${HARNESS:-/root/harness}"
_MR_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# The transport is bin/jobs-client.sh's: _jobs_req, plus the HARNESS_SECRET /
# JOBS_URL bootstrap every caller of this file already needs anyway.
#
# SOURCED LAZILY, AND IT LEAVES THE CALLER'S SHELL AS IT FOUND IT (#1515
# review, finding 4). jobs-client.sh runs `set -uo pipefail` at its top level,
# and it `exit 1`s the sourcing shell when its bin/lib/jobs/ modules are not
# beside it. Sourced at load time, this file would switch pipefail and nounset
# ON inside every lane that asks for a model, and a half-synced box would lose
# the lane outright — the same trap bin/lib/lane-gate.sh's _lg_ensure_client
# documents. So the client is loaded on the first lookup, only when its modules
# are really there, and both options are put back the way the caller had them.
_mr_ensure_client() {
  local c pf nu
  command -v _jobs_req >/dev/null 2>&1 && return 0
  for c in "${_MR_SELF_DIR:+$_MR_SELF_DIR/../jobs-client.sh}" "$MODEL_ROUTE_HARNESS/bin/jobs-client.sh"; do
    [ -n "$c" ] && [ -r "$c" ] && [ -r "$(dirname "$c")/lib/jobs/req.sh" ] || continue
    pf=$(set -o | awk '$1=="pipefail"{print $2}')
    nu=$(set -o | awk '$1=="nounset"{print $2}')
    # shellcheck source=/dev/null
    . "$c" >/dev/null 2>&1
    [ "$pf" = off ] && set +o pipefail
    [ "$nu" = off ] && set +u
    command -v _jobs_req >/dev/null 2>&1 && return 0
  done
  return 1
}

_mr_state_dir() { printf '%s' "$MODEL_ROUTE_HARNESS/state/model-routes"; }

# A role/project that fails this is a CALLER bug (a typo, an unvalidated
# argument), never "no route" — kept out of both the network call and the
# fail-closed alert, which name only genuine gaps.
_mr_token_ok() { case "$1" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

_mr_cache_key() { # _mr_cache_key <role> [project]
  if [ -n "${2:-}" ]; then printf '%s@%s' "$1" "$2"; else printf '%s' "$1"; fi
}

_mr_log() { # _mr_log <message> — a log line, not an alert (that is separate, below)
  mkdir -p "$MODEL_ROUTE_HARNESS/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [model-route] $*" >> "$MODEL_ROUTE_HARNESS/logs/model-route.log" 2>/dev/null
}

# One alert per (role, project) per DAY — the same reservoir bin/lib/jobs/req.sh
# uses for "worker unreachable", so a role stuck with no route pages once and
# does not drown ALERTS.log on every tick that calls it.
_mr_alert_once() { # _mr_alert_once <role> <project-or-empty> <message>
  # _MR_QUIET=1 (set only by stage_runner_for, for its own lookup): a missing
  # stage.* route is the normal case, so that lookup writes no line and no flag.
  [ "${_MR_QUIET:-0}" = 1 ] && return 0
  local role="$1" project="$2" msg="$3" safe flag
  safe=$(printf '%s' "$role" | tr -c 'A-Za-z0-9._-' '_')
  [ -n "$project" ] && safe="$safe-$(printf '%s' "$project" | tr -c 'A-Za-z0-9._-' '_')"
  flag="$MODEL_ROUTE_HARNESS/flags/alerted-model-route-$safe-$(date -u +%Y%m%d)"
  [ -f "$flag" ] && return 0
  mkdir -p "$MODEL_ROUTE_HARNESS/flags" 2>/dev/null
  touch "$flag" 2>/dev/null
  mkdir -p "$MODEL_ROUTE_HARNESS/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [model-route] $msg" >> "$MODEL_ROUTE_HARNESS/logs/ALERTS.log" 2>/dev/null
}

# model_ladder <role> [project]
#   Prints the resolved ladder on stdout, one rung per line:
#     <position>\t<model>\t<runner>
#   ordered by position (0 = primary). rc 0 when the DB or the cache answered
#   with at least one rung. rc 75 when NEITHER has anything for this role —
#   fail CLOSED; the caller must not substitute a literal of its own (that is
#   the whole point of this file existing). rc 1 on a malformed role/project
#   (a caller bug, checked before any network call or alert).
model_ladder() {
  local role="${1:-}" project="${2:-}" key path resp rc ladder
  # What answered, for a caller that runs this function in its own shell rather
  # than in $(...): model_routes_bundle (BH-1572) reads both, to stamp each
  # ladder it ships and to stop asking a worker that has just failed to answer.
  _MR_LAST_REACHED=0; _MR_LAST_FILE=""
  _mr_token_ok "$role" || return 1
  [ -z "$project" ] || _mr_token_ok "$project" || return 1
  mkdir -p "$(_mr_state_dir)" 2>/dev/null
  key=$(_mr_cache_key "$role" "$project")
  path="$(_mr_state_dir)/$key.tsv"

  rc=1
  # JOBS_ALERT=0: an outage is not this file's page to write. The cache below
  # answers it, and a role the cache cannot answer gets its own alert — so the
  # client's daily "worker unreachable" line would only be a second page for
  # the same event, one the lanes that depend on the worker already write.
  # The client loads FIRST: it is what reads HARNESS_SECRET out of global.env.
  # No secret after that = no way to ask — the unreachable branch below (#1510.2).
  # _MR_CACHE_ONLY=1 skips the ask too, and so answers from the cache exactly as
  # an outage would (BH-1572: the bundle writer, once the worker has failed it).
  if [ "${_MR_CACHE_ONLY:-0}" != 1 ] && _mr_ensure_client && [ -n "${HARNESS_SECRET:-}" ]; then
    if [ -n "$project" ]; then
      resp=$(JOBS_ALERT=0 _jobs_req GET "/api/model-routes/$role?project=$project"); rc=$?
    else
      resp=$(JOBS_ALERT=0 _jobs_req GET "/api/model-routes/$role"); rc=$?
    fi
  fi

  # A 2xx that is not a model-routes answer at all (no `ladder` array: a proxy
  # or captive page, a half-deployed worker) is not the worker saying "no route"
  # — it is an unusable answer, the transport-failure branch below (#1510.2).
  if [ "$rc" -eq 0 ] && ! printf '%s' "$resp" | jq -e '(.ladder | type) == "array"' >/dev/null 2>&1; then
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    _MR_LAST_REACHED=1
    # The DB answered — authoritative, whatever it says (including empty).
    ladder=$(printf '%s' "$resp" | jq -r '(.ladder // []) | .[] | [.position, .model, .runner] | @tsv' 2>/dev/null)
    # NO RUNG 0 = NO SCOPE (BH-1510.3). A ladder that starts past position 0 is
    # a half-written one (two writes interleaved on a worker older than the
    # whole-scope replace); taking its first line would silently promote a
    # failover rung to primary. A project scope like that falls back to the hub
    # ladder; a hub scope like that is treated as no route. Alerted once a day,
    # and never cached as a last good answer.
    if [ -n "$ladder" ] && [ "$(printf '%s\n' "$ladder" | awk -F'\t' 'NR==1{print $1}')" != "0" ]; then
      _mr_alert_once "$role-norung0" "$project" \
        "model route for role '$role'${project:+ (project=$project)} has no rung 0 (a gapped ladder) — ${project:+ignored, falling back to the hub ladder}${project:-treated as no route}. Rewrite it with PUT /api/model-routes."
      if [ -n "$project" ]; then
        model_ladder "$role"
        return $?
      fi
      ladder=""
    fi
    if [ -n "$ladder" ]; then
      printf '%s\n' "$ladder" > "$path.tmp.$$" 2>/dev/null && mv -f "$path.tmp.$$" "$path" 2>/dev/null
      _MR_LAST_FILE="$path"
      # WHICH SCOPE ANSWERED, remembered per (role, project) — the only
      # evidence that lets an outage serve this project the HUB's cached
      # ladder (below). source=hub writes the marker; anything else (a
      # project override) removes it, so an override is never shadowed.
      if [ -n "$project" ]; then
        if [ "$(printf '%s' "$resp" | jq -r '.source // ""' 2>/dev/null)" = hub ]; then
          : > "$path.hub" 2>/dev/null
        else
          rm -f "$path.hub" 2>/dev/null
        fi
      fi
      printf '%s\n' "$ladder"
      return 0
    fi
    # else: a real "no route yet" — fall through to the both-empty section,
    # deliberately WITHOUT reading the cache (see the file header). The cache
    # for the scope that was read goes too — the hub's <role>.tsv on a hub
    # read (BH-1588), and for a project everything this box learned in its hub
    # era, the .hub marker AND the project's own cached ladder — or the next
    # outage would replay rungs the worker has just said no longer exist.
    rm -f "$path" 2>/dev/null
    [ -n "$project" ] && rm -f "$path.hub" 2>/dev/null
  elif [ -n "$project" ] && [ -e "$path.hub" ] && [ -s "$(_mr_state_dir)/$role.tsv" ]; then
    # Unreachable, and the last time this box resolved this project the worker
    # said source=hub: the project has no override, so the hub's cached ladder
    # (possibly fresher than this project's copy) is its answer. Without that
    # marker a project is never served the hub rungs — it may carry an override
    # this box has not seen, and precedence is per role, whole ladder (#1510.2).
    _mr_log "worker unreachable for role=$role project=$project (rc=$rc) — last seen on the hub ladder, served the hub cache"
    _MR_LAST_FILE="$(_mr_state_dir)/$role.tsv"
    cat "$_MR_LAST_FILE"
    return 0
  elif [ -s "$path" ]; then
    # Transport failure (rc 1 = unreachable/bad answer, rc 2 = 404 on an old
    # worker) — the cache substitutes, exactly once logged so an operator can
    # tell "served from cache" apart from "served fresh" in the log.
    _mr_log "worker unreachable for role=$role${project:+ project=$project} (rc=$rc) — served from cache $path"
    _MR_LAST_FILE="$path"
    cat "$path"
    return 0
  fi

  _mr_alert_once "$role" "$project" \
    "no model route for role '$role'${project:+ (project=$project)} — the worker has no row for it and this box has no cached answer. Nothing was guessed; seed model_routes or PUT /api/model-routes."
  return 75
}

# model_for <role> [project] -> the primary (position 0) model, on stdout.
# Same rc contract as model_ladder.
model_for() {
  local role="${1:-}" project="${2:-}" out rc
  out=$(model_ladder "$role" "$project"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$out" | awk -F'\t' 'NR==1{print $2}'
}

# model_runner_for <role> [project] -> the primary rung's runner, on stdout.
# Same rc contract as model_ladder.
model_runner_for() {
  local role="${1:-}" project="${2:-}" out rc
  out=$(model_ladder "$role" "$project"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$out" | awk -F'\t' 'NR==1{print $3}'
}

# stage_route_role <stage> -> stage.<stage>, lowercased (BH-1749.0). The one
# place the stage.* role name is spelled. rc 1 on an empty stage.
stage_route_role() {
  [ -n "${1:-}" ] || return 1
  printf 'stage.%s\n' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
}

# stage_runner_for <stage> [project] [ttl-s] [timeout-s] (BH-1765) — print
# "<runner>\t<fallback>" from positions 0 and 1 of the stage.<stage> route; the
# fallback is empty on a one-rung ladder. It reads through model_ladder, so the
# client, the box cache and hub-vs-project precedence are the same as for every
# other role. A missing stage route is the normal case (bin/agent-call.sh then
# keeps its env/claude default), so this never alerts: _MR_QUIET silences
# model_ladder's own alerts for this one lookup. rc 75 = no route, including a
# worker that is down with nothing cached (fail open); rc 1 on a malformed
# stage/project (a caller bug).
#
# THE TWO OPTIONAL ARGS (BH-1837) exist because agent-call.sh reads this on
# EVERY call, and each read was a worker round trip, up to ~17 s against a
# worker that hangs (8 s, one retry, 8 s). Only agent-call passes them.
#   ttl-s      a positive number caches the ANSWER, the negative one included,
#              in state/model-routes/stage-runner/<role>[@project].ans for that
#              many seconds: "R<TAB>F" for a route, "-" for none. A fresh file
#              answers with no network call at all. Absent/0 = no cache (the
#              pre-BH-1837 behaviour). A malformed call (rc 1) is never cached.
#   timeout-s  caps the worker wait at that many seconds with no retry, for this
#              lookup only (`local`, so no other model_ladder caller sees it).
#              A timeout falls through model_ladder's unreachable branch: its
#              last-good ladder if it has one, else rc 75, and that answer is
#              what gets cached.
# Non-numeric values count as absent.
stage_runner_for() {
  local stage="${1:-}" project="${2:-}" ttl="${3:-0}" tmo="${4:-}" ladder runner fallback ans age rc
  _mr_token_ok "$stage" || return 1
  [ -z "$project" ] || _mr_token_ok "$project" || return 1
  case "$ttl" in ""|*[!0-9]*) ttl=0 ;; esac
  case "$tmo" in *[!0-9]*|0) tmo="" ;; esac
  ans="$(_mr_state_dir)/stage-runner/$(_mr_cache_key "$(stage_route_role "$stage")" "$project").ans"
  if [ "$ttl" -gt 0 ] && [ -s "$ans" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$ans" 2>/dev/null || echo 0) ))
    if [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then
      IFS= read -r ladder < "$ans"
      case "$ladder" in
        -) return 75 ;;
        ?*$'\t'*) printf '%s\n' "$ladder"; return 0 ;;
      esac
    fi
  fi
  # The client loads BEFORE the local below: its `JOBS_TIMEOUT="${JOBS_TIMEOUT:-8}"`
  # would otherwise assign into this function's scope and leave the global unset.
  _mr_ensure_client
  if [ -n "$tmo" ]; then local JOBS_TIMEOUT="$tmo" JOBS_RETRIES=0; fi
  ladder=$(_MR_QUIET=1 model_ladder "$(stage_route_role "$stage")" "$project"); rc=$?
  [ "$rc" -eq 1 ] && return 1
  if [ "$rc" -eq 0 ]; then
    runner=$(printf '%s\n' "$ladder" | awk -F'\t' '$1=="0"{print $3; exit}')
    fallback=$(printf '%s\n' "$ladder" | awk -F'\t' '$1=="1"{print $3; exit}')
    _mr_token_ok "$fallback" || fallback=""
    _mr_token_ok "$runner" && ladder=$(printf '%s\t%s' "$runner" "$fallback") || ladder=-
  else
    ladder=-
  fi
  if [ "$ttl" -gt 0 ]; then
    mkdir -p "${ans%/*}" 2>/dev/null \
      && printf '%s\n' "$ladder" > "$ans.tmp.$$" 2>/dev/null && mv -f "$ans.tmp.$$" "$ans" 2>/dev/null
    rm -f "$ans.tmp.$$" 2>/dev/null
  fi
  [ "$ladder" = - ] && return 75
  printf '%s\n' "$ladder"
}

# model_env_or_route <VAR> <role> [project] — the one line a lane uses (#1510.1).
#   An operator's value already in VAR (env/global.env, env/<project>.env, the
#   lane's own env) is kept as it is: that is a deliberate per-box override, and
#   #1510.4 is what folds those knobs into rows. Otherwise VAR is set to the
#   role's primary model from the table. Same rc contract as model_ladder: rc 75
#   means no route anywhere and the resolver has already written the ALERTS
#   line, so the caller STOPS — it never substitutes a model of its own.
model_env_or_route() {
  local __var="${1:-}" __role="${2:-}" __proj="${3:-}" __m __rc
  case "$__var" in ""|*[!A-Za-z0-9_]*) return 1 ;; esac
  [ -n "${!__var:-}" ] && return 0
  _mr_ensure_client
  __m=$(model_for "$__role" "$__proj"); __rc=$?
  [ "$__rc" -eq 0 ] || return "$__rc"
  [ -n "$__m" ] || return 75
  printf -v "$__var" '%s' "$__m"
}

# ── The build's roles, shipped in the job bundle (BH-1572) ───────────────────
# A fresh Fly builder has an empty box cache. If it cannot reach the worker at
# job start, model_env_or_route answers rc 75 and the build ends BUILD_DEFERRED:
# right on safety (no guessed model), but a short worker blip would defer every
# freshly spawned builder in every project. The dispatcher has just resolved the
# same roles on its own box, so it ships those answers with the env bundle, each
# stamped with the time it was resolved; the builder installs them into its cache
# before it warms. A worker the builder can reach still answers first, as it
# always does (model_ladder asks the worker before it reads the cache), so the
# bundle only ever serves the outage. A builder with no bundle and no worker
# still defers — nothing here is a model of its own.
#
# The roles a build asks for. fly/builder-runner.sh warms these at every job
# start, and the dispatchers bundle them. The stage.* roles are the runner per
# stage (stage_runner_for, BH-1765); a missing one is the normal case, so they
# are bundled quietly and never warmed.
MODEL_ROUTE_BUILD_ROLES="build.plan build.execute build.review build.review.t0 build.fix build.qa claude.ladder codex.default grok.default fireworks.default fireworks.floor openrouter.floor"
MODEL_ROUTE_BUILD_STAGE_ROLES="stage.plan stage.execute stage.review stage.fix stage.qa"

_mr_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
_mr_now() { date +%s; }   # the bundle's clock; a test overrides it in-shell

# _mr_bundle_deadline — sets _MR_BUNDLE_DEADLINE (seconds) in THIS shell; never
# call it in $( ). The env value when it is a positive integer, else the lib
# knob through lane-gate's lib_env_apply (once per process), else 15, the
# registry default (catalog/lanes.d/_lib.model-route.json). A value that is not
# a positive integer is never used: 0 would mean "cache only from the first
# role", which is not a deadline.
_MR_DEADLINE_FALLBACK=15
_MR_DEADLINE_APPLIED=0
_mr_bundle_deadline() {
  local v="${MODEL_ROUTES_BUNDLE_DEADLINE_S:-}"
  case "$v" in ''|*[!0-9]*|0|0*) v="" ;; esac
  if [ -z "$v" ] && [ "$_MR_DEADLINE_APPLIED" = 0 ]; then
    _MR_DEADLINE_APPLIED=1
    if ! command -v lib_env_apply >/dev/null 2>&1; then
      # shellcheck source=bin/lib/lane-gate.sh
      [ -n "$_MR_SELF_DIR" ] && [ -r "$_MR_SELF_DIR/lane-gate.sh" ] && . "$_MR_SELF_DIR/lane-gate.sh"
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply model-route
    v="${MODEL_ROUTES_BUNDLE_DEADLINE_S:-}"
    case "$v" in ''|*[!0-9]*|0|0*) v="" ;; esac
  fi
  _MR_BUNDLE_DEADLINE="${v:-$_MR_DEADLINE_FALLBACK}"
}

# model_routes_bundle <project> <out-file> — the dispatcher's side.
#   Resolves every build role for <project> through model_ladder (the worker,
#   else this box's cache) and writes one line per rung to <out-file>:
#     <role>\t<resolved-at epoch>\t<position>\t<model>\t<runner>
#   A worker answer is stamped now; a cached one carries its cache file's mtime,
#   the time this box last heard it from the worker. A role this box cannot
#   answer is left out (the builder then decides it for itself, as before).
#   BOUNDED: one short try per role, no retry, and after the first role the
#   worker fails to answer, the rest read the cache only — a worker that is
#   down answers every role the same way, and a spawn must not wait twelve
#   timeouts to find that out. MODEL_ROUTES_BUNDLE_TIMEOUT_S (default 4).
#   ONE TOTAL DEADLINE too (BH-1928): a worker that answers, slowly, never
#   trips the first-failure rule, and seventeen slow answers were about 68 s on
#   every pool tick. MODEL_ROUTES_BUNDLE_DEADLINE_S (a lib knob, registry
#   default 15) bounds the whole build: each ask gets min(the per-ask cap, what
#   is left), and once nothing is left the remaining roles read the cache,
#   with one log line saying so.
#   rc 0 = at least one ladder written; 75 = nothing to ship (no file left);
#   1 = a malformed project.
model_routes_bundle() {
  local project="${1:-}" out="${2:-}" r q rc n=0 cache_only=0 stamp tmp
  local start left asks=0 cap
  _mr_token_ok "$project" || return 1
  [ -n "$out" ] || return 1
  start=$(_mr_now)
  _mr_bundle_deadline
  # The client loads BEFORE the local below, for the reason stage_runner_for
  # gives: its JOBS_TIMEOUT default would otherwise land in this function's scope.
  _mr_ensure_client
  cap="${MODEL_ROUTES_BUNDLE_TIMEOUT_S:-4}"
  local JOBS_TIMEOUT="$cap" JOBS_RETRIES=0
  tmp="$out.tmp.$$"
  : > "$tmp" 2>/dev/null || return 75
  for r in $MODEL_ROUTE_BUILD_ROLES $MODEL_ROUTE_BUILD_STAGE_ROLES; do
    q=0; case " $MODEL_ROUTE_BUILD_STAGE_ROLES " in *" $r "*) q=1 ;; esac
    if [ "$cache_only" = 0 ]; then
      left=$(( _MR_BUNDLE_DEADLINE - ($(_mr_now) - start) ))
      if [ "$left" -le 0 ]; then
        cache_only=1
        _mr_log "bundle deadline ${_MR_BUNDLE_DEADLINE}s spent after $asks asks — the rest from cache (project=$project)"
      else
        JOBS_TIMEOUT=$(( left < cap ? left : cap ))
        asks=$((asks+1))
      fi
    fi
    # Run in THIS shell (not $(...)) so _MR_LAST_* survive the call.
    _MR_QUIET=$q _MR_CACHE_ONLY=$cache_only model_ladder "$r" "$project" > "$tmp.l" 2>/dev/null; rc=$?
    if [ "$rc" -eq 0 ] && [ -s "$tmp.l" ]; then
      if [ "$_MR_LAST_REACHED" = 1 ]; then
        stamp=$(date +%s)
      else
        stamp=$(_mr_mtime "$_MR_LAST_FILE")
      fi
      case "$stamp" in ""|*[!0-9]*) ;; *)
        awk -F'\t' -v r="$r" -v s="$stamp" 'NF>=3{print r "\t" s "\t" $1 "\t" $2 "\t" $3}' "$tmp.l" >> "$tmp"
        n=$((n+1)) ;;
      esac
    fi
    [ "$_MR_LAST_REACHED" = 1 ] || cache_only=1
  done
  rm -f "$tmp.l"
  if [ "$n" -eq 0 ]; then rm -f "$tmp"; return 75; fi
  mv -f "$tmp" "$out" || { rm -f "$tmp"; return 75; }
}

# model_routes_bundle_install <bundle-file> <project> — the builder's side.
#   Writes each bundled role's ladder into this box's cache as
#   state/model-routes/<role>@<project>.tsv, with the file's mtime set to the
#   time the dispatcher resolved it — but ONLY where this box holds nothing
#   newer for that role (a reused or volume-backed machine may have heard the
#   worker itself since). An installed ladder drops the role's .hub marker: the
#   bundled answer IS this project's effective ladder, whichever scope it came
#   from, and a marker left beside it would have an outage serve the older hub
#   copy instead. The next worker answer puts the marker back.
#   Refused, line by line, when it is not a ladder: a malformed role, a stamp
#   that is not a number, a ladder with no rung 0 (the rule model_ladder applies
#   to the worker's own answers). Prints the number of ladders installed.
model_routes_bundle_install() {
  local file="${1:-}" project="${2:-}" d role stamp dest n=0 cur
  _mr_token_ok "$project" || return 1
  [ -s "$file" ] || { echo 0; return 0; }
  d="$(_mr_state_dir)"
  mkdir -p "$d" 2>/dev/null || { echo 0; return 0; }
  while IFS=$'\t' read -r role stamp; do
    _mr_token_ok "$role" || continue
    case "$stamp" in ""|*[!0-9]*) continue ;; esac
    dest="$d/$(_mr_cache_key "$role" "$project").tsv"
    if [ -s "$dest" ]; then
      cur=$(_mr_mtime "$dest")
      case "$cur" in ""|*[!0-9]*) cur=0 ;; esac
      [ "$cur" -ge "$stamp" ] && continue
    fi
    awk -F'\t' -v r="$role" -v s="$stamp" '$1==r && $2==s && $3 ~ /^[0-9]+$/ && $4 != "" && $5 != "" {print $3 "\t" $4 "\t" $5}' \
      "$file" > "$dest.tmp.$$" 2>/dev/null
    if [ "$(awk -F'\t' 'NR==1{print $1}' "$dest.tmp.$$" 2>/dev/null)" != 0 ]; then
      rm -f "$dest.tmp.$$"; continue
    fi
    touch -d "@$stamp" "$dest.tmp.$$" 2>/dev/null || touch -t "$(date -r "$stamp" +%Y%m%d%H%M.%S 2>/dev/null)" "$dest.tmp.$$" 2>/dev/null
    mv -f "$dest.tmp.$$" "$dest" 2>/dev/null || { rm -f "$dest.tmp.$$"; continue; }
    rm -f "$dest.hub" 2>/dev/null
    n=$((n+1))
  done < <(awk -F'\t' '!/^#/ && NF>=5 && !seen[$1 "\t" $2]++ {print $1 "\t" $2}' "$file")
  echo "$n"
}
