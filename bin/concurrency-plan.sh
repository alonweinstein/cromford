#!/bin/bash
# bin/concurrency-plan.sh [project] [--json] — every build cap that applies to a
# project, and the one that actually binds.
#
#   bin/concurrency-plan.sh                 # the whole fleet, as a table
#   bin/concurrency-plan.sh project-5       # one project
#   bin/concurrency-plan.sh --json          # the same answer, machine-readable
#
# WHY THIS EXISTS (the operator, 2026-09-12). "The DB seeds repo/*/build = 1, so how did
# project-5 run twelve builds at once?" took three files and an ssh hop to
# answer, and the answer was that nothing had been bypassed: worker/jobs/schema.sql
# SEEDS 1 with INSERT OR IGNORE — deliberately, so a re-applied schema cannot
# reset a hand-raised cap — and the live row had been raised to 20 that morning.
# The seed is the copy a reader finds; the row is the one that binds. Five files
# hold a cap on this and none of them holds the answer:
#
#   concurrency_rules repo/<p>/build   the fleet-wide rule the worker enforces
#   the Fly pool cap (bin/pool-cap.sh)  how many pool machines may live at once
#   flags/wip-limit-<p>                per-project local builds
#   BUILD_SLOTS (env/global.env)       box-wide local build slots, 0 = unlimited
#   concurrency_rules box/*/build      the fleet-wide per-box rule
#
# ROUTING DECIDES WHICH OF THEM APPLY AT ALL, and that is the half that keeps
# being got wrong. bin/run-build.sh answers RESULT "QUEUED_FLY $KEY" inside its
# flags/builder-fly-$PROJECT enqueue gate and exits BEFORE the wip gate
# (flags/wip-limit-$PROJECT), before the box slot flock
# (locks/build-slot-$S.lock), before the per-key flock
# (locks/build-key-$PROJECT-$KEY.lock) and before job_open —
# so a fly-routed project is gated by no local number whatsoever, and quoting one
# for it is not conservative, it is the wrong question. bin/free-slots.sh was
# written after that mistake starved an idle pool; this is the same lesson for
# the ceiling rather than for the next launch.
#
# WHAT IT DOES NOT DO. It reads flags on THIS machine, and flags describe the box
# they sit on: BUILD_SLOTS and flags/wip-limit-<p> live on each project's
# own watcher, flags/fly-pool-<p> on the hub. Run from somewhere else those
# columns are that machine's, so the table names the box it read and every
# consumer should treat an off-box local number as unverified rather than as a
# promise. The DB rules and the pool cap are fleet-wide and correct from
# anywhere, and on the pool route they are the only caps that bind — which is
# why the project-5 answer is right from a laptop and the project-1 one is not.
#
# Always exits 0. A launch rule or a health check that cannot read this must
# fall back to its own judgement, never to a stack trace — bin/free-slots.sh's
# contract, for the same reason.
set -uo pipefail
H="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || HERE="$H/bin"

# shellcheck source=bin/lib/build-caps.sh
if   [ -r "$HERE/lib/build-caps.sh" ]; then . "$HERE/lib/build-caps.sh"
elif [ -r "$H/bin/lib/build-caps.sh" ]; then . "$H/bin/lib/build-caps.sh"
else echo "concurrency-plan.sh: bin/lib/build-caps.sh not found" >&2; exit 0; fi

ONLY=""; JSON=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    --*) echo "concurrency-plan.sh: unknown option $a" >&2; exit 0 ;;
    *) ONLY="$a" ;;
  esac
done

# --- the rules, once ----------------------------------------------------------
# job_rules prints TSV (scope, selector, kind, max, note) — bin/jobs-client.sh.
# Fail-open in the worker's own shape: no rows means no rules means unlimited,
# which is what checkRules does before it looks at anything. RULES_TSV is a TEST
# override; cron sets it nowhere.
RT=$(mktemp 2>/dev/null) || RT=""
trap '[ -n "${RT:-}" ] && rm -f "$RT"' EXIT
if [ -n "${RULES_TSV:-}" ]; then
  cat "$RULES_TSV" > "$RT" 2>/dev/null || : > "$RT"
elif [ -r "$H/bin/jobs-client.sh" ]; then
  # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh" 2>/dev/null || true
  if command -v job_rules >/dev/null 2>&1; then job_rules > "$RT" 2>/dev/null || : > "$RT"; fi
fi
[ -s "$RT" ] || : > "${RT:-/dev/null}"

BOX=$( { [ -x "$H/bin/box-name.sh" ] && "$H/bin/box-name.sh"; } 2>/dev/null || hostname 2>/dev/null || echo unknown )

PROJECTS=""
if [ -n "$ONLY" ]; then PROJECTS="$ONLY"
elif [ -r "$H/fleet.conf" ]; then
  PROJECTS=$(awk '$1 !~ /^#/ && NF >= 2 { print $1 }' "$H/fleet.conf" 2>/dev/null)
fi

num() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
jstr() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

ROWS=""
for P in $PROJECTS; do
  ROUTE=$(caps_route "$H" "$P")

  DBRULE=$(caps_rule "$RT" repo "$P" build)
  # WHEN the binding repo rule last moved, off the same row caps_rule binds on.
  # A cap and the moment it was set are one fact: bin/concurrency-ceiling-watch.sh
  # compares this against its previous observation to tell an operator's
  # rule-set from a schema seed resurrecting a row (BH-1300). Empty when no row
  # binds or the client is an older five-column one, and empty means NO
  # evidence — never "recently".
  DBRULE_AT=$(caps_rule_at "$RT" repo "$P" build)
  BOXRULE=$(caps_rule "$RT" box "$BOX" build)
  TKTRULE=$(caps_rule "$RT" ticket "$P" build)

  # The pool cap goes through bin/pool-cap.sh and nowhere else. A second copy of
  # its resolution order (flag number -> the reviewed conf -> unlimited, trimmed
  # by POOL_CAP_MAX) is precisely how the flag and the conf came to be able to
  # disagree.
  POOL="-"
  if [ "$ROUTE" = pool ] && [ -x "$H/bin/pool-cap.sh" ]; then
    POOL=$(num "$("$H/bin/pool-cap.sh" "$P" 2>/dev/null | tr -dc '0-9')" 3)
    # 0 is that script's word for NO CEILING since 2026-09-14 (pool autoscale:
    # the machine count follows queue depth). It enters this table as
    # `unlimited` for the same reason BUILD_SLOTS=0 does below — a 0 inside
    # caps_min would read as "no builds allowed" and bind the whole row at zero.
    [ "$POOL" = 0 ] && POOL=unlimited
  elif [ "$ROUTE" = pool ]; then POOL="?"; fi

  WIP=$(cat "$H/flags/wip-limit-$P" 2>/dev/null | tr -dc '0-9'); [ -n "$WIP" ] || WIP="-"
  # The box slot count through the one resolver (BUILD_SLOTS in env/global.env,
  # the legacy flag only when that is unset). 0 means run-build.sh takes no slot
  # lock at all, which is "unlimited" in this table's vocabulary and must never
  # enter the minimum as a zero — a cap of 0 would read as "no builds allowed".
  SLOTS=$(build_slots "$H"); [ "$SLOTS" = 0 ] && SLOTS=unlimited
  DISP="-"; [ "$ROUTE" = fly1 ] && DISP="$FLY_DISPATCH_WIP"

  # Which caps are REACHED on this route. This is the whole point of the table:
  # a number that run-build.sh never evaluates must not be in the minimum.
  A_POOL=false; A_DISP=false; A_WIP=false; A_SLOT=false; A_BOXR=false
  case "$ROUTE" in
    pool)
      # run-build.sh returns QUEUED_FLY above every local gate; the pool spawns
      # up to pool-cap machines and each one is its own box, so box/*/build caps
      # a MACHINE, not the project's total.
      A_POOL=true
      CAND="pool-cap:$POOL repo-rule:$DBRULE" ;;
    fly1)
      # bin/fly-dispatch.sh holds one <p>-active.json: one job at a time,
      # whatever the repo rule says.
      A_DISP=true
      CAND="fly-dispatch-wip:$DISP repo-rule:$DBRULE" ;;
    *)
      # Local builds pass every gate in order, and box/*/build is one of them:
      # a box rule of 1 caps a box with BUILD_SLOTS=2 at one build, so a table
      # that reported 2 would promise a slot job_open then refuses.
      A_WIP=true; A_SLOT=true; A_BOXR=true
      CAND="wip-limit:$WIP box-slots:$SLOTS box-rule:$BOXRULE repo-rule:$DBRULE" ;;
  esac

  # shellcheck disable=SC2086
  MIN=$(caps_min $CAND)
  EFF=$(printf '%s' "$MIN" | cut -f1)
  WHY=$(printf '%s' "$MIN" | cut -f2)
  [ "$ROUTE" = pool ] || WHY="$WHY (route: $ROUTE)"
  [ "$ROUTE" = pool ] && WHY="$WHY (route: pool, on $BOX's view of the flags)"

  # DBRULE_AT goes LAST so the human table's reader keeps absorbing everything
  # past the columns it prints in its own `_rest`.
  ROWS="$ROWS$P	$ROUTE	$DBRULE	$POOL	$DISP	$WIP	$SLOTS	$BOXRULE	$TKTRULE	$EFF	$WHY	$A_POOL	$A_DISP	$A_WIP	$A_SLOT	$A_BOXR	$DBRULE_AT
"
done

if [ "$JSON" = 1 ]; then
  printf '[\n'; first=1
  printf '%s' "$ROWS" | while IFS=$'\t' read -r p route dbr pool disp wip slot boxr tkt eff why ap ad aw as ab dbat; do
    [ -n "$p" ] || continue
    [ "$first" = 1 ] || printf ',\n'; first=0
    printf '  {"project":"%s","box_read":"%s","route":"%s","db_rule":"%s","db_rule_updated_at":"%s","pool_cap":"%s",' \
      "$(jstr "$p")" "$(jstr "$BOX")" "$route" "$dbr" "$(jstr "$dbat")" "$pool"
    printf '"fly_dispatch_wip":"%s","wip_limit":"%s","box_slots":"%s","box_rule":"%s","ticket_rule":"%s",' \
      "$disp" "$wip" "$(jstr "$slot")" "$boxr" "$tkt"
    printf '"effective":"%s","bound_by":"%s",' "$eff" "$(jstr "$why")"
    printf '"applies":{"pool_cap":%s,"fly_dispatch_wip":%s,"wip_limit":%s,"box_slots":%s,"box_rule":%s,"db_rule":true}}' \
      "$ap" "$ad" "$aw" "$as" "$ab"
  done
  printf '\n]\n'
  exit 0
fi

printf 'PROJECT              ROUTE  RULE  POOL  DISP  WIP  SLOT  BOX  TKT   EFF  BOUND BY\n'
printf '%s' "$ROWS" | while IFS=$'\t' read -r p route dbr pool disp wip slot boxr tkt eff why _rest; do
  [ -n "$p" ] || continue
  printf '%-20.20s %-6.6s %5.5s %5.5s %5.5s %4.4s %5.5s %4.4s %4.4s %5.5s  %s\n' \
    "$p" "$route" "$dbr" "$pool" "$disp" "$wip" "$slot" "$boxr" "$tkt" "$eff" "$why"
done
printf '\n'
printf 'RULE/BOX/TKT = concurrency_rules repo|box|ticket (the fleet-wide DB, bin/jobs-client.sh rules).\n'
printf 'POOL = bin/pool-cap.sh. DISP = the single-machine fly dispatcher (bin/lib/build-caps.sh).\n'
printf 'WIP/SLOT = flags/wip-limit-<p> and BUILD_SLOTS (0 = unlimited) ON %s — a project whose watcher is\n' "$BOX"
printf 'elsewhere shows THIS box%s values for those two, and on the local route they are unverified.\n' "'"
printf -- '- = does not apply on this route.  ? = this machine could not read it.\n'
exit 0
