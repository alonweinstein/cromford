#!/bin/bash
# bin/lib/build-caps.sh — the shared vocabulary of "how many builds may run".
#
# WHY A LIB (the operator, 2026-09-12). Five files hold a cap on build concurrency and
# nothing held the ARITHMETIC that combines them, so the effective ceiling of a
# project could only be worked out by reading all five and knowing which of them
# the routing actually reaches. That is how "the DB says repo/*/build = 1" and
# "project-5 ran twelve at once" were both true at the same time: the schema
# SEEDS 1 with INSERT OR IGNORE, the live row had been raised to 20, and the
# seed is the copy a reader finds.
#
# Everything here is a pure function over values the caller has already read, so
# it can be unit-driven and so the same answer reaches bin/concurrency-plan.sh,
# bin/concurrency-apply.sh and bin/pipeline-health.sh without any of them
# growing a second opinion.
#
# Sourced, never executed. Safe under `set -u`.

# THE SINGLE-MACHINE DISPATCHER'S PER-PROJECT WIP.
#
# bin/fly-dispatch.sh holds exactly one state/fly/<p>-active.json and will not
# claim a second job while it exists, so a project on that route builds one at a
# time. Until now that 1 lived only in a header comment ("one job at a time
# (wip=1)") and in the shape of the code, which means nothing could report it
# and nothing could notice if the shape changed. It is a value now, and the
# dispatcher reads it from here rather than restating it.
#
# Raising this alone would NOT make the dispatcher parallel — it holds one
# active file — so it is not a tuning knob; it is the dispatcher's own statement
# of its limit, in a place the plan can read.
FLY_DISPATCH_WIP=1

# caps_rule <rules-tsv-file> <scope> <selector> <kind>
#   -> the max_concurrent that BINDS, or "unlimited"
#
# The ladder is the worker's, walked in the worker's order —
# worker/jobs/src/index.js ruleFor(): [selector,kind], [selector,'*'],
# ['*',kind], ['*','*'], selector outranking kind. A second ladder that
# disagreed with that one is how a rule comes to bind somewhere nobody meant,
# which is the comment the schema itself carries; so this is a transcription of
# that function and must stay one.
#
# An empty or unreadable table is "unlimited", because that is what the worker
# does with zero rows: checkRules returns null before it looks at anything.
caps_rule() {
  local f="${1:-}" scope="${2:-}" sel="${3:-}" kind="${4:-}" s k line
  [ -r "$f" ] || { printf 'unlimited\n'; return 0; }
  for pair in "$sel|$kind" "$sel|*" "*|$kind" "*|*"; do
    s="${pair%%|*}"; k="${pair##*|}"
    line=$(awk -F'\t' -v sc="$scope" -v se="$s" -v ki="$k" \
      '$1==sc && $2==se && $3==ki { print $4; exit }' "$f" 2>/dev/null)
    case "$line" in ''|*[!0-9]*) continue ;; *) printf '%s\n' "$line"; return 0 ;; esac
  done
  printf 'unlimited\n'
}

# caps_rule_at <rules-tsv-file> <scope> <selector> <kind>
#   -> the updated_at of the row caps_rule BINDS on, or nothing
#
# WHEN DID THIS CAP LAST MOVE. There is no ledger entry for a rule-set:
# bin/jobs-client.sh rule-set PUTs /api/rules and the worker stamps
# concurrency_rules.updated_at (worker/jobs/src/routes/rules.js), and that stamp
# is the ONLY durable trace a cap change leaves. bin/concurrency-ceiling-watch.sh
# reads it to tell an operator lowering a ceiling from a schema seed
# resurrecting one — on 2026-09-21 the row that appeared from nowhere carried
# the seed's own 2026-08-29 stamp while the number had moved that morning.
#
# The ladder is caps_rule's, walked in the same order and binding on the same
# row (the first rung whose max is numeric), because an updated_at read off a
# DIFFERENT row than the one that binds is evidence about a cap nobody is
# looking at. Nothing, not "unknown", when no row binds or the column is absent:
# the caller decides what absent evidence means, and this must not invent a
# timestamp for it.
caps_rule_at() {
  local f="${1:-}" scope="${2:-}" sel="${3:-}" kind="${4:-}" pair s k line max at
  [ -r "$f" ] || return 0
  for pair in "$sel|$kind" "$sel|*" "*|$kind" "*|*"; do
    s="${pair%%|*}"; k="${pair##*|}"
    # Column 6 is job_rules' last field and carries no spaces (an ISO stamp), so
    # one space joins them unambiguously; the note in column 5 is not read.
    line=$(awk -F'\t' -v sc="$scope" -v se="$s" -v ki="$k" \
      '$1==sc && $2==se && $3==ki { print $4 " " $6; exit }' "$f" 2>/dev/null)
    max="${line%% *}"; at="${line#* }"
    [ "$at" = "$line" ] && at=""
    case "$max" in ''|*[!0-9]*) continue ;; *) printf '%s\n' "$at"; return 0 ;; esac
  done
  return 0
}

# caps_min <label:value> ...  -> "<n>\t<label>"  (or "unlimited\tno cap applies")
#
# The smallest cap wins and the LABEL comes back with it, because a bare number
# nobody can explain is exactly how this drifted for a year. "unlimited" and "?"
# entries are carried past: unlimited cannot bind, and "?" means a value this
# machine could not read, which must never be silently treated as zero.
caps_min() {
  local best="" why="" v l
  for a in "$@"; do
    l="${a%%:*}"; v="${a#*:}"
    case "$v" in ''|unlimited|'?'|*[!0-9]*) continue ;; esac
    if [ -z "$best" ] || [ "$v" -lt "$best" ]; then best="$v"; why="$l $v"
    elif [ "$v" -eq "$best" ]; then why="$why = $l $v"; fi
  done
  if [ -z "$best" ]; then printf 'unlimited\tno numeric cap applies\n'
  else printf '%s\t%s\n' "$best" "$why"; fi
}

# caps_route <harness> <project> -> pool | fly1 | local
#
# WHICH CAPS APPLY IS A ROUTING QUESTION, and getting that wrong is not a
# rounding error. bin/run-build.sh answers RESULT "QUEUED_FLY $KEY" inside its
# flags/builder-fly-$PROJECT enqueue gate and exits BEFORE the wip gate
# (flags/wip-limit-$PROJECT), before the box slot flock
# (locks/build-slot-$S.lock), before the per-key flock
# (locks/build-key-$PROJECT-$KEY.lock) and before job_open,
# so for a fly-routed project every local number answers a different question —
# the same mistake bin/free-slots.sh was written to stop making in the other
# direction, where a local count starved an idle pool.
#
#   pool   flags/builder-fly-<p> AND flags/fly-pool-<p>  — bin/fly-pool.sh owns
#          the queue, spawns up to bin/pool-cap.sh machines, and
#          bin/fly-dispatch.sh stands down entirely — dispatch_project() opens
#          with flag_on fly-pool "$p" && return 0.
#   fly1   flags/builder-fly-<p> only — the single-machine dispatcher.
#   local  neither — builds run on the box, under its flags.
caps_route() {
  local h="${1:-}" p="${2:-}"
  if command -v routing_builder >/dev/null 2>&1 && [ -n "$h" ] && [ "$h" = "${JOBS_HARNESS:-}" ] \
     && routing_builder "$p" 2>/dev/null; then
    return 0
  elif [ -f "$h/flags/builder-fly-$p" ]; then
    if [ -f "$h/flags/fly-pool-$p" ]; then printf 'pool\n'; else printf 'fly1\n'; fi
  else
    printf 'local\n'
  fi
}

# THE BOX'S BUILD SLOTS, AND WHY THE DEFAULT IS "NO CAP" (the operator, 2026-09-13:
# "change the rule so we never lock and serialize").
#
# bin/run-build.sh used to read flags/build-slots, default 1, and a build that
# found every slot flock held said BUILD_DEFERRED — so on a box with no flag one
# build at a time was the shipped behaviour, and the second ticket of a wave
# waited for the first to finish. That is a queue wearing a lock's clothes.
#
# The number is now BUILD_SLOTS, from env/global.env (or the environment), and
# its default is 0 = UNLIMITED: no slot lock is taken at all. A cap has to be
# asked for, in a file an operator edits, rather than arrived at by a script's
# fallback — "resource caps stay, but explicit and configurable".
#
# flags/build-slots is still honoured when BUILD_SLOTS is unset, so a box that
# deliberately set 2 keeps 2 until its global.env says otherwise. It is the
# legacy spelling, not the source of truth; nothing writes it any more.
#
# Reads the file rather than sourcing it: this is called from bin/run-build.sh
# BEFORE the pipeline loads env/global.env (the gate must not depend on the load
# order) and from reporters that must never inherit a fleet's secrets to answer
# an arithmetic question.
build_slots() { # build_slots [harness] -> N   (0 = unlimited)
  local h="${1:-${HARNESS:-/root/harness}}" v="${BUILD_SLOTS:-}"
  if [ -z "$v" ] && [ -r "$h/env/global.env" ]; then
    v=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}BUILD_SLOTS=//p' "$h/env/global.env" \
        | tr -d '"'"'"' \t' | tail -1)
  fi
  if [ -z "$v" ] && [ -r "$h/flags/build-slots" ]; then
    v=$(tr -dc '0-9' < "$h/flags/build-slots")
  fi
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s\n' "$v"
}
