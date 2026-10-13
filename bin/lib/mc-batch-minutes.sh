#!/bin/bash
# bin/lib/mc-batch-minutes.sh — THE QUEUE WASTE LEDGER (BH-5374, BH-5356.2).
# Sourced by bin/merge-conductor.sh, never executed. Every GitHub call here is
# a GET; the writes are one worker PUT per (draft, run), log lines and one
# attempt mark per draft.
#
#   bmin_tick <slug>   for each batch draft bres_drafts lists, read the timing of
#                      each completed CI run of its head and PUT one row to
#                      /api/queue-batch-minutes: outcome, measured minutes and
#                      the minutes #5368's reuse skipped. One line per row:
#                      `QUEUE_MINUTES draft=<n> outcome=<o> minutes=<m> reused=<r>`.
#
# OUTCOME, in this precedence: merged (bres says so) > bisect (its members are
# a strict subset of an EARLIER draft's: a Mergify split) > red (a completed run
# concluded failure) > reset (bres_tick logged `BATCH_RESET draft=<n>` for it)
# > closed. Every outcome but merged is minutes the queue threw away.
#
# MINUTES are measured, never estimated and never 0 for an unread: GitHub's
# run timing `.billable` summed and rounded up to the minute (source billable),
# or, when it is {} (self-hosted runners bill nothing), each job's
# completed_at - started_at rounded up and summed (source jobs). A timing that
# cannot be read is logged `QUEUE_MINUTES unread` and the draft is retried next
# tick, while bres_drafts still lists it (batch_reset.lookback_s).
#
# RETURNS the read rc when a read fails (75 = rate limited stays 75) and writes
# nothing after it; 0 otherwise. A failed PUT is logged `put-failed` and the
# draft stays unmarked, so the next tick re-sends the same (repo, draft_pr,
# run_id), which the worker upserts. The mark — `bmin <slug>#<n> <sha12>:<class>`
# with the class known BEFORE the run reads — is written only once every run of
# the draft has completed and PUT ok, and is checked before any read. A run
# still in progress is logged `QUEUE_MINUTES pending` and holds the mark back.
#
# REUSED comes from #5368 through one seam it defines:
#   sr_batch_skipped_minutes <slug> <draft> <head_sha>  -> a non-negative integer
# Absent, or anything else printed: reused_min 0 and reused_known 0. A draft's
# reuse rides on the row of its lowest run id, so a day's sum counts it once.
#
# Knob (settings row; the code default is the fallback):
#   batch_minutes.max_drafts  unmarked drafts read per tick (10); the rest wait
# The root is ${HARNESS:-${H:-}} and nothing else (D43): empty is not opted in.
[ -n "${_BMIN_LOADED:-}" ] && return 0
_BMIN_LOADED=1
command -v bres_drafts >/dev/null 2>&1 \
  || { [ -r "${BASH_SOURCE[0]%/*}/mc-batch-reset.sh" ] && . "${BASH_SOURCE[0]%/*}/mc-batch-reset.sh"; }

_bmin_knob() { # _bmin_knob <name> <default> — a positive integer
  local v=""
  command -v setting_get >/dev/null 2>&1 && v=$(setting_get "$1" 2>/dev/null)
  case "$v" in ''|*[!0-9]*|0) v="$2" ;; esac
  printf '%s' "$v"
}

# _bmin_classes <tsv-file> — one `draft<TAB>class<TAB>head_sha<TAB>closed_at`
# line per bres_drafts row, class merged|bisect|closed (reset is the caller's:
# it reads the log). Members are compared as sets; an empty set is never bisect.
_bmin_classes() {
  jq -R -s -r '[split("\n")[] | select(length > 0) | split("\t")
      | {n: .[0], o: .[1], sha: .[2], c: .[3], x: .[4],
         m: ((.[5] // "") | split(",") | map(select(length > 0)) | unique)}] as $all
    | $all[] | . as $d
    | (if $d.o == "merged" then "merged"
       elif ($d.m | length) > 0 and any($all[]; .c < $d.c and (.m | length) > ($d.m | length)
              and (. as $p | all($d.m[]; . as $x | $p.m | index($x) != null))) then "bisect"
       else "closed" end) as $k
    | [$d.n, $k, $d.sha, $d.x] | @tsv' "$1"
}

# _bmin_minutes <slug> <run id> — sets BMIN_MIN and BMIN_SRC. rc 0 read, 75
# rate limited (stop the tick), anything else unread (skip this run).
_bmin_minutes() {
  local slug="$1" id="$2" t j rc=0 m
  BMIN_MIN=""; BMIN_SRC=""
  mc_rest_var t gh_rest GET "repos/$slug/actions/runs/$id/timing" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  # billable entries each need a numeric total_ms; one without is unread, never 0.
  m=$(jq -er 'if (.billable | type) != "object" then error("no billable")
      elif (.billable | length) == 0 then "jobs"
      elif all(.billable[]; (.total_ms | type) == "number" and .total_ms >= 0)
        then ([.billable[].total_ms] | add / 60000 | ceil | tostring)
      else error("no total_ms") end' <<<"$t" 2>/dev/null) || return 1
  if [ "$m" != jobs ]; then BMIN_MIN=$m; BMIN_SRC=billable; return 0; fi
  mc_rest_var j gh_rest GET "repos/$slug/actions/runs/$id/jobs" -F per_page=100 || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  # every job needs both stamps, and a list cut at 100 is not the whole run.
  m=$(jq -er 'if (.jobs | type) != "array" or (.total_count // 0) > (.jobs | length) then error("partial")
      elif all(.jobs[]; (.started_at | type) == "string" and (.completed_at | type) == "string")
        then ([.jobs[] | ((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601)) / 60 | ceil] | add // 0 | tostring)
      else error("unstamped job") end' <<<"$j" 2>/dev/null) || return 1
  BMIN_MIN=$m; BMIN_SRC=jobs
}

bmin_tick() {
  local slug="${1:-}" root conf rc=0 max done_n=0 tmp draft class sha closed key runs ids id
  local outcome reused known r k body all_ok wf pending
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] && command -v bres_drafts >/dev/null 2>&1 || return 0
  # Opted in the way bres_tick is: reset verdicts only exist on these repos.
  conf="$root/config/mergify/repos/${slug#*/}.conf"
  [ -r "$conf" ] && grep -qx "slug=$slug" "$conf" 2>/dev/null && grep -q '^queue_mode=' "$conf" || return 0
  if [ -z "${HARNESS_SECRET:-}" ] || [ -z "${JOBS_URL:-}" ]; then
    mc_log "$slug QUEUE_MINUTES skip not-configured"
    return 0
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/bmin-drafts.XXXXXX") || return 75
  bres_drafts "$slug" > "$tmp" || rc=$?
  [ "$rc" = 0 ] || { rm -f "$tmp"; return "$rc"; }
  max=$(_bmin_knob batch_minutes.max_drafts 10)
  while IFS=$'\t' read -r draft class sha closed; do
    [ -n "$draft" ] || continue
    [ "$class" = closed ] && grep -qF " $slug BATCH_RESET draft=$draft " "${MC_LOG:-/dev/null}" 2>/dev/null && class=reset
    key="bmin $slug#$draft ${sha:0:12}:$class"
    mc_attempt_has "$key" && continue
    if [ "$done_n" -ge "$max" ]; then mc_log "$slug QUEUE_MINUTES deferred draft=$draft — over batch_minutes.max_drafts=$max this tick"; continue; fi
    done_n=$((done_n+1))
    rc=0; mc_rest_var runs gh_rest GET "repos/$slug/actions/runs" -f "head_sha=$sha" -F per_page=100 || rc=$?
    [ "$rc" = 0 ] || { rm -f "$tmp"; return "$rc"; }
    ids=$(jq -er 'if (.workflow_runs | type) != "array" or (.total_count // 0) > (.workflow_runs | length) then error("partial")
        else [.workflow_runs[] | select(.status == "completed")] | sort_by(.id) | .[] | "\(.id)\t\(.conclusion // "-")\t\(.name // "")" end' \
        <<<"$runs" 2>/dev/null) || { mc_log "$slug QUEUE_MINUTES unread draft=$draft run=- rc=runs-list"; continue; }
    # A run not completed yet (a sibling still being cancelled after the close):
    # its minutes are not known, so the draft is not marked and is read again.
    pending=$(jq -r '[.workflow_runs[] | select(.status != "completed") | .id] | sort | map(tostring) | join(",")' <<<"$runs" 2>/dev/null)
    # Nothing completed yet: nothing to record, and no mark, so it is read again.
    [ -n "$ids" ] || continue
    outcome=$class
    case "$class" in reset|closed) grep -q $'\tfailure\t' <<<"$ids" && outcome=red ;; esac
    reused=0; known=0
    if command -v sr_batch_skipped_minutes >/dev/null 2>&1; then
      r=$(sr_batch_skipped_minutes "$slug" "$draft" "$sha" 2>/dev/null) || r=""
      case "$r" in ''|*[!0-9]*) ;; *) reused=$((10#$r)); known=1 ;; esac
    fi
    all_ok=1; k=0
    while IFS=$'\t' read -r id _ wf; do
      rc=0; _bmin_minutes "$slug" "$id" </dev/null || rc=$?
      [ "$rc" = 75 ] && { rm -f "$tmp"; return 75; }
      [ "$rc" = 0 ] || { mc_log "$slug QUEUE_MINUTES unread draft=$draft run=$id rc=$rc"; all_ok=0; continue; }
      r=0; [ "$k" = 0 ] && r=$reused
      body=$(jq -nc --arg repo "$slug" --argjson d "$draft" --argjson id "$id" --arg o "$outcome" \
        --argjson m "$BMIN_MIN" --arg s "$BMIN_SRC" --argjson r "$r" --argjson kn "$known" --arg wf "$wf" \
        --arg sha "$sha" --arg x "$closed" --arg box "$(hostname 2>/dev/null)" \
        '{repo:$repo,draft_pr:$d,run_id:$id,outcome:$o,minutes:$m,source:$s,reused_min:$r,reused_known:$kn,
          workflow:(if $wf == "" then null else $wf end),head_sha:$sha,closed_at:$x,box:$box}') || { all_ok=0; continue; }
      if _jobs_req PUT /api/queue-batch-minutes "$body" >/dev/null </dev/null; then
        mc_log "$slug QUEUE_MINUTES draft=$draft outcome=$outcome minutes=$BMIN_MIN reused=$r"
        k=$((k+1))
      else
        mc_log "$slug QUEUE_MINUTES put-failed draft=$draft run=$id"
        all_ok=0
      fi
    done <<<"$ids"
    # The completed runs went in (a re-send next tick upserts the same rows);
    # the mark waits for the pending ones.
    if [ -n "$pending" ]; then
      mc_log "$slug QUEUE_MINUTES pending draft=$draft run=$pending"
      all_ok=0
    fi
    [ "$all_ok" = 1 ] && mc_attempt_put "$key"
  done < <(_bmin_classes "$tmp")
  rm -f "$tmp"
  return 0
}
