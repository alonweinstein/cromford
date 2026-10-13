#!/bin/bash
# bin/lib/self-heal.sh — BH-4724 (BH-4717.4): one notice for a fix the harness
# already made. Sourced, never executed.
#
#   self_heal_note <source> <stable-key> <text>
#
# Two callers: bin/context-gate.sh (`BUILD RESTARTED on the fresh harness`,
# key <project>:<build-dir basename>) and bin/review-rescue.sh (`rescued review
# = APPROVE`, key <project>/<KEY>:<candidate basename>). Both used to page as
# critical, because alert-line's default severity is critical and neither
# passed one, for something nobody has to act on.
#
#   a. alert-line.sh --severity info <text>: the ALERTS.log line is kept, and
#      beat.sh logs `info-only` and sends nothing (docs/ALERTS-STATE-MACHINE.md
#      "Severity routing"). This always runs first and never waits on (b).
#   b. a detached `jobs-client.sh ledger-put self_heal <source>:<stable-key>
#      logged <text, 300 chars>`, so the daily digest can count them
#      (worker/jobs/src/lib/daily-digest/state-sections.js `self_heals`). The
#      key is the caller's event fingerprint, never a timestamp: a re-put keeps
#      the row's created_at, so one event is counted once. Never waited on, its
#      rc never read; fd 9 is closed so it cannot hold a caller's flock.
#
# Root is ${HARNESS:-${H:-}} only (D43). An empty root returns 1 before any
# write, so the caller's raw alert-line fallback runs. Every other path is 0.
self_heal_note() {
  local root="${HARNESS:-${H:-}}" src="${1:-}" key="${2:-}" text="${3:-}"
  [ -n "$root" ] || return 1
  HARNESS="$root" "$root/bin/alert-line.sh" --severity info "$text" || true
  if [ -x "$root/bin/jobs-client.sh" ]; then
    ( exec 9>&-; JOBS_TIMEOUT=5 JOBS_RETRIES=0 \
        "$root/bin/jobs-client.sh" ledger-put self_heal "$src:$key" logged "${text:0:300}" >/dev/null 2>&1 & ) 2>/dev/null
  fi
  return 0
}
