#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/boxes.sh — BH-1031: the per-box facts a box states about ITSELF — backup freshness, and (BH-2529) the harness HEAD — written by the box and read back by the hub in one call. Sourced by bin/jobs-client.sh (JC_MODULES), never run.

# --- Backup freshness, re-homed off the ssh hop (BH-1031) ---------------------
# "When did this box last get a VERIFIED off-box copy" (#399, after the hub wipe
# #388) is a fact only the box can see. Until this slice the hub COLLECTED it,
# by splicing bin/lib/backup-freshness.sh's probe into the ssh hop
# bin/fleet-heartbeat.sh already made every 15 minutes — and that lane is
# deleted here, because it answered "can the hub reach the box", not "is the
# lane alive".
#
# So the direction reverses: the box states its own three facts on the tick that
# produced them (bin/state-backup.sh), and the hub reads every box's answer in
# ONE call instead of nine ssh hops. Same fact, same vocabulary, same library
# deciding what it means — one collector, and it is the machine that owns the
# fact.
#
# THREE RAW FACTS, NEVER A VERDICT. bf_facts_local emits "<ts>\t<off>\t<unc>"
# and that is what travels; bin/lib/backup-freshness.sh on the hub turns it into
# ok|off|unconfigured|missing|unknown. A box on an older bin/ therefore cannot
# answer in a vocabulary the hub has moved on from, which is the rule the ssh
# probe was built on and the reason it survives the move.
#
# FAIL-OPEN AND SILENT, like every other verb here: a box must never fail its
# backup — or slow it — because the ledger is unreachable. The hub notices the
# SILENCE (the row stops being refreshed and ages out of
# BF_RECORD_FRESH_MIN), which is the same thing a failed ssh used to mean.

# box_backup_set <ts> <off> <unconfigured> — this box's three facts, verbatim.
# Empty fields are REAL answers ("reachable, nothing stamped"), so they are sent
# as empty strings rather than dropped: the hub must be able to tell "answered,
# nothing there" from "did not answer", and only the presence of the ROW can
# carry that distinction.
box_backup_set() {
  local ts="${1:-}" off="${2:-}" unc="${3:-}" body
  body=$(jq -nc --arg b "$JOBS_BOX" --arg ts "$ts" --arg off "$off" --arg unc "$unc" \
    '{box:$b, ts:$ts, off:$off, unconfigured:$unc}' 2>/dev/null) || return 1
  _jobs_req POST /api/boxes/backup "$body" >/dev/null
}

# box_backups — every box's reported facts, as TSV:
#   box  ts  off  unconfigured  reported_at
# A box that has never reported produces NO line: the hub's materialiser writes
# a record only for a box that actually answered, exactly as the ssh collector
# did. reported_at is the COLLECTION clock and is what lets a box that stopped
# reporting age out, rather than be re-read for ever as if it had just answered.
box_backups() {
  local resp
  resp=$(_jobs_req GET /api/boxes) || return 1
  printf '%s' "$resp" | jq -r '
    .boxes[]? | select(.backup_reported_at != null)
    | [ .box, (.backup_ts // ""), (.backup_off // ""),
        (.backup_unconfigured // ""), .backup_reported_at ]
    | @tsv' 2>/dev/null
}

# box_heads — every box's harness HEAD as box_status holds it (BH-2529), TSV:
#   box  harness_commit  harness_reported_at
# The box writes it itself, hourly, through bin/lib/lane-gate.sh's liveness
# post, so the hub reads which commit each box runs from the DB rather than
# ssh-ing in. A box that never reported a commit produces NO line. rc 1 when
# the worker could not be asked: "no box reported" and "could not ask" differ.
box_heads() {
  local resp
  resp=$(_jobs_req GET /api/boxes) || return 1
  printf '%s' "$resp" | jq -r '
    .boxes[]? | select(.harness_commit != null and .harness_commit != "")
    | [ .box, .harness_commit, (.harness_reported_at // "") ]
    | @tsv' 2>/dev/null
}

# --- Self-report: CLI versions and the rules hash (BH-2532.0) ----------------
# box_self_report_set <cli_version> <codex_version> <rules_hash> — this box's
# own facts, stamped with the time it said them. Empty fields are sent as ""
# for the same reason as box_backup_set. Returns _jobs_req's rc: nonzero while
# POST /api/boxes/self-report is not deployed (it belongs to a sibling slice).
box_self_report_set() {
  local cli="${1:-}" codex="${2:-}" rules="${3:-}" body
  body=$(jq -nc --arg b "$JOBS_BOX" --arg c "$cli" --arg x "$codex" --arg r "$rules" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{box:$b, cli_version:$c, codex_version:$x, rules_hash:$r, at:$at}' 2>/dev/null) || return 1
  _jobs_req POST /api/boxes/self-report "$body" >/dev/null
}

# box_self_reports — every box that has self-reported, as TSV:
#   box  cli_version  codex_version  cli_checked_at  rules_hash  rules_reported_at
# A box with neither rules_reported_at nor cli_checked_at produces NO line.
# rc 1 when the worker could not be asked OR its answer did not parse, so
# "no box reported" (rc 0, nothing printed) is never an outage in disguise.
box_self_reports() {
  local resp
  resp=$(_jobs_req GET /api/boxes) || return 1
  printf '%s' "$resp" | jq -r '
    .boxes[]? | select((.rules_reported_at // "") != "" or (.cli_checked_at // "") != "")
    | [ .box, (.cli_version // ""), (.codex_version // ""), (.cli_checked_at // ""),
        (.rules_hash // ""), (.rules_reported_at // "") ]
    | @tsv' 2>/dev/null || return 1
}
