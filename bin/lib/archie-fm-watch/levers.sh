#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-fm-watch/levers.sh — BH-4586 (BH-4574.4): the five levers the
# watch may pull, and nothing else. Sourced by bin/archie-fm-watch.sh, never run.
# afw_pull (common.sh) is the only caller; each body sets AFW_OUT, AFW_WHY and
# AFW_EV and returns 0:
#   done       a synchronous lever succeeded, checked on its own rc / HTTP code
#   requested  a detached lane launch or a queued box command (rung STARTED)
#   failed     anything else, with the reason
# `done` is written only in a success arm (System invariants b).
# The root is ${HARNESS:-${H:-}} (D43).
# gh-rest: no-graphql

AFW_ISSUE_PAGES=10
AFW_CLEANUP_RC=""

afw_fail() { AFW_OUT=failed; AFW_WHY="$1"; return 0; }

# afw_detach <log-or-empty> <cmd...> — start <cmd> in its own session, stdin
#   /dev/null, this tick's fds 8 and 9 (its locks) closed, and never wait on it.
afw_detach() {
  local log="${1:-/dev/null}"; shift
  if command -v setsid >/dev/null 2>&1; then
    ( setsid "$@" </dev/null >>"$log" 2>&1 8>&- 9>&- & ) || return 1
  else
    ( nohup "$@" </dev/null >>"$log" 2>&1 8>&- 9>&- & ) || return 1
  fi
  return 0
}

# afw_kick_lane <lane> <project> <class> <incident> — run a lane now. Each
#   target takes its own flock -n, so a kick that meets a cron run is a no-op.
afw_kick_lane() {
  local lane="$1" p="$2" c="$3" inc="$4" r script box id resp rc
  r=$(afw_root); [ -n "$r" ] || { afw_fail "no harness root"; return 0; }
  case " $AFW_KICK_LANES " in *" $lane "*) ;; *)
    afw_log "refused kick_lane '$lane' ($c $inc): not on the lane list; nothing done"
    afw_fail "refused kick_lane '$lane': not on the lane list"; return 0 ;;
  esac
  case "$lane" in
    triage)
      afw_project_ok "$p" || { afw_fail "triage: '$p' is not a fleet.conf project"; return 0; }
      box=$("$r/bin/fleet-conf.sh" "$p" box 2>/dev/null)
      [[ $box =~ ^[A-Za-z0-9._-]+$ ]] || { afw_fail "triage: fleet.conf names no box for $p"; return 0; }
      id="afw-$(printf '%s' "watch:$c:$inc" | sha1sum | cut -c1-16)"
      rc=0; resp=$(box_ccmd_forward "$id" "$box" run_triage "$p" '{}') || rc=$?
      if [ "$rc" = 0 ]; then
        AFW_OUT=requested; AFW_WHY="run_triage $p queued for $box ($id)"
        AFW_EV=$(jq -nc --arg i "$id" --arg b "$box" --arg r "${resp:0:300}" '{command_id: $i, box: $b, answer: $r}')
      else
        afw_fail "run_triage $p for $box was not queued (rc=$rc http=${JOBS_HTTP:-none})"
      fi
      return 0 ;;
    review-rescue)   script=bin/review-rescue.sh ;;
    fleet-propagate) script=bin/fleet-propagate.sh ;;
    main-red-bisect) script=bin/main-red-bisect.sh ;;
    cost-rollup)     script=bin/cost-rollup.sh ;;
  esac
  [ -x "$r/$script" ] || { afw_fail "$script is not on this box"; return 0; }
  if [ "$lane" = review-rescue ]; then
    afw_project_ok "$p" || { afw_fail "review-rescue: '$p' is not a fleet.conf project"; return 0; }
    afw_detach "" env RESCUE_ONLY="$p" "$r/$script" || { afw_fail "$script could not be started"; return 0; }
  else
    afw_detach "" "$r/$script" || { afw_fail "$script could not be started"; return 0; }
  fi
  AFW_OUT=requested; AFW_WHY="$script started"
  AFW_EV=$(jq -nc --arg s "$script" --arg o "$([ "$lane" = review-rescue ] && printf 'RESCUE_ONLY=%s' "$p")" '{started: $s, env: $o}')
}

# afw_run_cleanup hub — the hub's own cleanup lane, foreground, bounded. It
#   deletes only what it owns. Once per tick: a second incident reuses the rc.
afw_run_cleanup() {
  local r rc
  [ "$1" = hub ] || { afw_log "refused run_cleanup '$1': hub only"; afw_fail "refused run_cleanup '$1': hub only"; return 0; }
  r=$(afw_root); [ -n "$r" ] || { afw_fail "no harness root"; return 0; }
  [ -x "$r/bin/disk-clean.sh" ] || { afw_fail "bin/disk-clean.sh is not on this box"; return 0; }
  if [ -n "$AFW_CLEANUP_RC" ]; then
    rc=$AFW_CLEANUP_RC
  else
    rc=0; timeout -k 30 900 "$r/bin/disk-clean.sh" </dev/null >/dev/null 2>&1 8>&- 9>&- || rc=$?
    AFW_CLEANUP_RC=$rc
  fi
  AFW_EV=$(jq -nc --argjson rc "$rc" '{ran: "bin/disk-clean.sh", rc: $rc}')
  if [ "$rc" = 0 ]; then AFW_OUT=done; AFW_WHY="bin/disk-clean.sh exited 0"
  else afw_fail "bin/disk-clean.sh exited $rc"; fi
}

# afw_rerun_deploy deployworkers|consolepages <alert-id> <evidence-json>
afw_rerun_deploy() {
  local shape="$1" aid="$2" ev="$3" r run slug f rc rc2 st
  r=$(afw_root); [ -n "$r" ] || { afw_fail "no harness root"; return 0; }
  case "$shape" in
    deployworkers)
      run=$(jq -r '.run_id // ""' <<<"$ev" 2>/dev/null); slug=$(jq -r '.repo // ""' <<<"$ev" 2>/dev/null)
      # Never a guess: no run id in the alert line, no rerun.
      [[ $run =~ ^[0-9]+$ ]] || { afw_fail "the alert line ($aid) names no run id; nothing re-run"; return 0; }
      [[ $slug =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { afw_fail "the alert line ($aid) names no repo; nothing re-run"; return 0; }
      f=$(mktemp "${TMPDIR:-/tmp}/afw-rerun.XXXXXX") || { afw_fail "mktemp failed"; return 0; }
      # A re-run reuses the ORIGINAL run's sha. Re-running a run that a newer
      # one superseded would roll the workers back over it, so the run must
      # still be the newest deploy-workers run on main (any status) AND sit on
      # main's current head. Anything unconfirmed re-runs nothing.
      local newest nsha head
      rc=0; gh_rest GET "repos/$slug/actions/workflows/deploy-workers.yml/runs?branch=main&per_page=1" > "$f" 2>/dev/null || rc=$?
      newest=""; nsha=""
      [ "$rc" = 0 ] && IFS=$'\t' read -r newest nsha < <(jq -r '.workflow_runs[0] // empty | [(.id | tostring), (.head_sha // "")] | @tsv' "$f" 2>/dev/null)
      rc2=0; gh_rest GET "repos/$slug/commits/main" > "$f" 2>/dev/null || rc2=$?
      head=""; [ "$rc2" = 0 ] && head=$(jq -r '.sha // ""' "$f" 2>/dev/null)
      if ! [[ ${newest:-} =~ ^[0-9]+$ ]] || ! [[ ${nsha:-} =~ ^[0-9a-f]{40}$ ]] || ! [[ ${head:-} =~ ^[0-9a-f]{40}$ ]]; then
        rm -f "$f"; afw_fail "could not confirm run $run is still the newest deploy on main's head ($slug, runs rc=$rc, main rc=$rc2); nothing re-run"; return 0
      fi
      if [ "$newest" != "$run" ]; then
        rm -f "$f"; AFW_EV=$(jq -nc --arg s "$slug" --arg r "$run" --arg n "$newest" '{repo: $s, run_id: $r, superseded_by: $n}')
        afw_fail "run $run is superseded by run $newest on $slug; nothing re-run"; return 0
      fi
      if [ "$nsha" != "$head" ]; then
        rm -f "$f"; AFW_EV=$(jq -nc --arg s "$slug" --arg r "$run" --arg a "$nsha" --arg m "$head" '{repo: $s, run_id: $r, run_sha: $a, main_sha: $m}')
        afw_fail "run $run deployed ${nsha:0:7} but main is at ${head:0:7} on $slug; nothing re-run"; return 0
      fi
      rc=0; gh_rest POST "repos/$slug/actions/runs/$run/rerun-failed-jobs" > "$f" 2>/dev/null || rc=$?
      st=${GH_REST_STATUS:-000}; rm -f "$f"
      AFW_EV=$(jq -nc --arg s "$slug" --arg r "$run" --arg h "$head" --arg st "$st" --argjson rc "$rc" '{repo: $s, run_id: $r, head_sha: $h, http: $st, rc: $rc}')
      # The 201 only queues the re-run: the same rung as a detached kick.
      if [ "$rc" = 0 ] && [ "$st" = 201 ]; then AFW_OUT=requested; AFW_WHY="queued a re-run of the failed jobs of run $run on $slug"
      else afw_fail "rerun of run $run on $slug answered HTTP $st (rc=$rc)"; fi ;;
    consolepages)
      [ -f "${AFW_HENV:-$r/env}/cloudflare.env" ] || { afw_fail "cloudflare.env is not on this box"; return 0; }
      [ -x "$r/bin/console-pages-deploy.sh" ] || { afw_fail "bin/console-pages-deploy.sh is not on this box"; return 0; }
      afw_detach "$r/logs/console-pages-deploy.log" "$r/bin/console-pages-deploy.sh" \
        || { afw_fail "bin/console-pages-deploy.sh could not be started"; return 0; }
      AFW_OUT=requested; AFW_WHY="bin/console-pages-deploy.sh started"
      AFW_EV='{"started": "bin/console-pages-deploy.sh"}' ;;
    *) afw_log "refused rerun_deploy '$shape'"; afw_fail "refused rerun_deploy '$shape'" ;;
  esac
}

# afw_ack_alert <alert-id> <note> — POST /api/alerts/actions {action: ack}.
#   200 done; 409 (already triaged or parked) done with the refusal kept;
#   404 failed "alert gone"; anything else failed.
afw_ack_alert() {
  local id="$1" note="${2:0:1000}" body resp rc
  [[ $id =~ ^[A-Za-z0-9_.-]{1,120}$ ]] || { afw_fail "no ackable alert id ('$id')"; return 0; }
  body=$(jq -nc --arg i "$id" --arg n "$note" '{id: $i, action: "ack", actor: "archie-fm-watch", note: $n}')
  rc=0; resp=$(_afm_req POST /api/alerts/actions "$body") || rc=$?
  case "$rc" in
    0) AFW_OUT=done; AFW_WHY="acked $id"; AFW_EV=$(jq -nc --arg i "$id" '{acked: $i}') ;;
    9) AFW_OUT=done; AFW_WHY="$id was already acked"
       AFW_EV=$(jq -nc --arg i "$id" --arg e "$(jq -r '.error // ""' <<<"$resp" 2>/dev/null)" '{acked: $i, refused: $e}') ;;
    2) if jq -e '.error == "no such alert"' <<<"$resp" >/dev/null 2>&1; then afw_fail "alert gone ($id)"
       else afw_fail "the alert actions route is not deployed"; fi ;;
    *) afw_fail "ack of $id failed (rc=$rc http=${JOBS_HTTP:-none})" ;;
  esac
}

# afw_class_name <class> -> the plain-English name a ticket uses.
afw_class_name() {
  case "$1" in
    build-stuck) printf 'a build stuck past its stage SLA' ;;
    review-unrescued) printf 'a review nobody rescued' ;;
    pool-idle) printf 'pool machines idle but billed' ;;
    disk) printf 'disk over threshold' ;;
    cron-install) printf "a merged lane whose cron is not installed" ;;
    deploy-drift) printf 'a deploy that is not on main' ;;
    main-red) printf 'main red' ;;
    pause-waiting) printf 'a paused project with work waiting' ;;
    triage-skip) printf 'a board with untriaged tickets' ;;
    cost-anomaly) printf 'a cost or quota anomaly' ;;
    *) printf '%s' "$1" ;;
  esac
}

# afw_file_ticket <class> <incident> <subject> <evidence-json> — ONE issue on
#   example-org/cromford, unlabelled, deduped on a body marker. The open
#   issues are read first (up to AFW_ISSUE_PAGES pages): a marker found is done
#   with that URL and no new issue; a read that fails, or a last page that is
#   still full, files nothing (fail closed: no duplicate on a guess).
afw_file_ticket() {
  local c="$1" inc="$2" subj="$3" ev="$4" repo=$AFW_REPO_DEFAULT mark f page rc st n url bf title from fo fat seen why
  mark="<!-- archie-fm-watch:$c:$(printf '%s' "$inc" | sha1sum | cut -c1-12) -->"
  f=$(mktemp "${TMPDIR:-/tmp}/afw-issues.XXXXXX") || { afw_fail "mktemp failed"; return 0; }
  url=""; page=1
  while [ "$page" -le "$AFW_ISSUE_PAGES" ]; do
    rc=0; gh_rest GET "repos/$repo/issues?state=open&per_page=100&page=$page" > "$f" 2>/dev/null || rc=$?
    st=${GH_REST_STATUS:-000}
    if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
      rm -f "$f"; afw_fail "the open issues of $repo could not be read (page $page, HTTP $st); nothing filed"; return 0
    fi
    url=$(jq -r --arg m "$mark" '[.[] | select(.pull_request == null) | select((.body // "") | contains($m))][0].html_url // empty' "$f")
    [ -n "$url" ] && break
    n=$(jq length "$f")
    [ "$n" -lt 100 ] && break
    page=$((page + 1))
  done
  rm -f "$f"
  if [ -n "$url" ]; then
    AFW_OUT=done; AFW_WHY="already filed: $url"
    AFW_EV=$(jq -nc --arg u "$url" '{issue: $u, existing: true}'); return 0
  fi
  if [ "$page" -gt "$AFW_ISSUE_PAGES" ]; then
    afw_fail "more than $AFW_ISSUE_PAGES pages of open issues on $repo; nothing filed (a duplicate could not be ruled out)"; return 0
  fi
  from=$(jq -r '.escalated_from.lever // ""' <<<"$ev" 2>/dev/null)
  fo=$(jq -r '.escalated_from.outcome // ""' <<<"$ev" 2>/dev/null)
  fat=$(jq -r '.escalated_from.at // ""' <<<"$ev" 2>/dev/null)
  seen=$(jq -r '.line // (if .sweep then (.sweep + " sweep: " + (del(.source, .sweep, .class, .incident, .subject, .escalated_from) | tostring)) else "" end)' <<<"$ev" 2>/dev/null)
  if [ -n "$from" ]; then
    title="Archie: $(afw_class_name "$c") on ${subj:0:80} still open after $from"
    why="We pulled $from at ${fat:-an earlier tick} (it ended $fo) and the problem is still there, so it needs a person."
  else
    title="Archie: $(afw_class_name "$c") on ${subj:0:80}"
    case "$c" in
      pool-idle) why="We don't stop pool machines on our own: a stop can kill a build that is still running. Please check which machines are idle and stop them." ;;
      pause-waiting) why="We never lift a pause on our own. Someone set it for a reason we can't see. Please check whether it can end, or whether the waiting work should move." ;;
      *) why="There is no safe lever for this one, so it needs a person." ;;
    esac
  fi
  bf=$(mktemp "${TMPDIR:-/tmp}/afw-body.XXXXXX") || { afw_fail "mktemp failed"; return 0; }
  {
    printf 'We saw %s on %s.\n\n' "$(afw_class_name "$c")" "$subj"
    printf 'What we saw: %s\n\n' "${seen:-see the evidence below}"
    printf '%s\n\n' "$why"
    printf 'Evidence (the archie_actions row has the same):\n\n```json\n%s\n```\n\n' "$(jq . <<<"$ev" 2>/dev/null | head -c 4000)"
    printf '%s\n' "$mark"
  } > "$bf"
  f=$(mktemp "${TMPDIR:-/tmp}/afw-issue.XXXXXX") || { rm -f "$bf"; afw_fail "mktemp failed"; return 0; }
  rc=0; gh_rest POST "repos/$repo/issues" -f "title=$title" -F "body=@$bf" > "$f" 2>/dev/null || rc=$?
  st=${GH_REST_STATUS:-000}
  url=$(jq -r '.html_url // empty' "$f" 2>/dev/null)
  rm -f "$f" "$bf"
  if [ "$rc" = 0 ] && [ "$st" = 201 ] && [ -n "$url" ]; then
    AFW_OUT=done; AFW_WHY="filed $url"; AFW_EV=$(jq -nc --arg u "$url" --arg t "$title" '{issue: $u, title: $t}')
  else
    afw_fail "filing the issue on $repo answered HTTP $st (rc=$rc)"
  fi
}
