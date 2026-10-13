#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-fm-queue/reconcile.sh — BH-4584 (BH-4574.2): queue-reconcile,
# the playbook that corrects a conductor row GitHub disagrees with. Sourced by
# bin/archie-fm-queue.sh, never run.
#
# afq_reconcile <project> <slug> <mode> reads the conductor's rows for the repo
# (state/merge-conductor/pr-state.tsv) and corrects three disagreements:
#   (a) settle  a row that is not MERGED/CLOSED/ABANDONED, carries an ejection
#               (an `ejected <key> <head>` attempts line, or a reason that
#               still reads queue-ejected*) and whose PR GitHub says MERGED.
#               The conductor's own BH-4562 sequence settles it (conductor_settle
#               with MERGES=1, then mc_handoff_release), under the PR lock.
#   (b) dephold a READY row the PR-dependency gate has held (depwaithold, no
#               depwaitrelease) for archie.queue.dep_hold_stale_s. Its
#               dependencies are re-read with the gate's own parsers. When
#               every one that still holds is stale input, either
#                 b1 an Order sibling whose row is READY/QUEUED but whose PR
#                    GitHub says MERGED (settled as in (a)) or CLOSED (moved to
#                    CLOSED), so the held PR's next tick passes the gate, or
#                 b2 an open issue whose closing PR merged: no write to the
#                    issue, one `requested` row and ONE alert naming the fix.
#               A dependency that is genuinely open, or unreadable, is no
#               action and no row.
#   (c) kick    a WAIT_CI row older than archie.queue.wait_ci_stale_s whose
#               head is GitHub's, every check-run green, combined status
#               success, mergeable clean/unstable: ONE keyed conductor run
#               (MC_ONLY_PR=<key>) per head, under ARCHIE_FMQ_KICK_TIMEOUT_S.
# Each is an archie_actions row claimed before the write; the key binds the
# head, so a second tick on the same state does nothing.
# gh-rest: no-graphql

# afq_settle_locked <project> <slug> <key> <url> <head> <reviewed> <branch> <why>
#   BH-4562's parked-merged settle, verbatim, with the PR lock already held.
afq_settle_locked() {
  local p="$1" slug="$2" key="$3" url="$4" head="$5" rev="$6" br="$7" why="$8" rec v job MERGES=1
  rec=$(mc_record_for "$url" || true)
  IFS=$'\t' read -r v _ _ job _ <<<"$(mc_verdict "$url" "$rec")"
  conductor_settle "$key" "$url" "$p" "$slug" "$br" "$rec" "$job" "$head" "$rev" "$v" CLEAN "$why"
  mc_handoff_release "$key" merged
}

# afq_row_now <key> <state> -> rc 0 when the conductor row reads <state> NOW.
#   conductor_settle ignores mc_transition's rc, so a write is proven by
#   reading the row back, never by the call having returned.
afq_row_now() { [ "$(mc_row_get "$1" | cut -f2)" = "$2" ]; }

# afq_rec_settle <project> <slug> <key> <n> <state> <head> <reviewed> <reason> <mode> — (a).
afq_rec_settle() {
  local p="$1" slug="$2" key="$3" n="$4" st="$5" head="$6" rev="$7" why="$8" mode="$9" cur ejn ev ck
  if ! afq_pr_fresh "$slug" "$n"; then
    afq_log "$key: the pulls read failed (HTTP ${GH_REST_STATUS:-000}); not settled this tick"; AFQ_N_SKIPPED=$((AFQ_N_SKIPPED + 1)); return 0
  fi
  [ "$AFQ_PR_STATE" = closed ] && [ -n "$AFQ_PR_MERGED_AT" ] || return 0
  if [ "$mode" = on ] && ! afq_merges_on "$p"; then
    afq_log "$key: merged on GitHub, conductor row $st; merges are off or paused, so it is settled when they resume"
    AFQ_N_SKIPPED=$((AFQ_N_SKIPPED + 1)); return 0
  fi
  if ! afq_pr_lock "$p" "$n"; then
    afq_log "$key: the conductor holds its PR lock; skipped this tick"; AFQ_N_SKIPPED=$((AFQ_N_SKIPPED + 1)); return 0
  fi
  cur=$(mc_row_get "$key" | cut -f2)
  case "$cur" in MERGED|CLOSED|ABANDONED) afq_pr_unlock; return 0 ;; esac
  if [ "$mode" = on ] && ! afq_cap_ok queue-reconcile "$p"; then AFQ_N_CAPPED=$((AFQ_N_CAPPED + 1)); afq_pr_unlock; return 0; fi
  ejn=$(grep -cxF "ejected $key $head" "$MC_ATTEMPTS" 2>/dev/null); ejn=${ejn:-0}
  ev=$(jq -nc --arg s "$st" --arg r "$why" --arg m "$AFQ_PR_MERGED_AT" --argjson e "$ejn" --arg h "$head" \
    '{prev_state: $s, prev_reason: $r, merged_at: $m, eject_lines: $e, head: $h}')
  ck="queue-reconcile:$slug#$n:settle:$head:$mode"
  if [ "$mode" = on ]; then
    afq_claim queue-reconcile "$ck" "$p" "$slug" "$n" on settle_merged "merged on GitHub at $AFQ_PR_MERGED_AT; the conductor row says $st (${why:0:200})" "$ev" \
      || { afq_pr_unlock; return 0; }
  else
    afq_claim queue-reconcile "$ck" "$p" "$slug" "$n" observe would_settle_merged "would settle MERGED: merged on GitHub at $AFQ_PR_MERGED_AT, the conductor row says $st" "$ev" \
      || { afq_pr_unlock; return 0; }
    afq_log "$key: would settle MERGED (GitHub merged it at $AFQ_PR_MERGED_AT, the row says $st); observe mode, nothing written"
    AFQ_N_WOULD=$((AFQ_N_WOULD + 1)); afq_pr_unlock; return 0
  fi
  afq_settle_locked "$p" "$slug" "$key" "https://github.com/$slug/pull/$n" "$head" "$rev" "$AFQ_PR_REF" \
    "by:archie-fm-queue (merged on GitHub, logged ejected)"
  if ! afq_row_now "$key" MERGED; then
    afq_close queue-reconcile failed "" "the settle did not take: the row still says $(mc_row_get "$key" | cut -f2)" "$ev" || true
    afq_log "$key: the settle did not take (the row still says $(mc_row_get "$key" | cut -f2)); not retried on ${head:0:8}"
    afq_alert "$key merged on GitHub at $AFQ_PR_MERGED_AT but the conductor row would not move to MERGED (it says $(mc_row_get "$key" | cut -f2)); check state/merge-conductor/pr-state.tsv is writable on the hub"
    AFQ_N_FAILED=$((AFQ_N_FAILED + 1)); afq_pr_unlock; return 0
  fi
  afq_close queue-reconcile done settle_merged "settled MERGED: GitHub merged it at $AFQ_PR_MERGED_AT while the row said $st" "$ev" || true
  afq_log "$key: settled MERGED (merged on GitHub at $AFQ_PR_MERGED_AT; the row said $st, $ejn ejection line(s))"
  AFQ_N_SETTLED=$((AFQ_N_SETTLED + 1))
  afq_pr_unlock
  return 0
}

# afq_rec_kick <project> <slug> <key> <n> <head> <mode> — (c).
afq_rec_kick() {
  local p="$1" slug="$2" key="$3" n="$4" head="$5" mode="$6" rc sj ev ck krc post r left
  r=$(afq_root); [ -n "$r" ] || return 0
  afq_pr_fresh "$slug" "$n" || { afq_log "$key: the pulls read failed (HTTP ${GH_REST_STATUS:-000}); no kick this tick"; return 0; }
  [ "$AFQ_PR_STATE" = open ] && [ "$AFQ_PR_HEAD" = "$head" ] || return 0
  case "$AFQ_PR_MS" in clean|unstable) ;; *) return 0 ;; esac
  rc=0; afq_checks_green "$slug" "$head" || rc=$?
  [ "$rc" = 2 ] && { afq_log "$key: the check-runs could not be read; no kick this tick"; return 0; }
  [ "$rc" = 0 ] || return 0
  gh_rest_var sj GET "repos/$slug/commits/$head/status" || { afq_log "$key: the combined status could not be read; no kick this tick"; return 0; }
  jq -e '.state == "success" or (.total_count // -1) == 0' <<<"$sj" >/dev/null 2>&1 || return 0
  # The conductor working this PR right now is the same kick; a held lock is a skip.
  if ! afq_pr_lock "$p" "$n"; then afq_log "$key: the conductor holds its PR lock; no kick this tick"; AFQ_N_SKIPPED=$((AFQ_N_SKIPPED + 1)); return 0; fi
  afq_pr_unlock
  left=$(afq_time_left)
  if [ "$mode" = on ] && [ "$left" -lt $((AFQ_KICK_TIMEOUT_S + 60)) ]; then
    afq_log "$key: ${left}s left in this tick, under a kick bound; waits for the next tick"; AFQ_N_SKIPPED=$((AFQ_N_SKIPPED + 1)); return 0
  fi
  if [ "$mode" = on ] && ! afq_cap_ok queue-reconcile "$p"; then AFQ_N_CAPPED=$((AFQ_N_CAPPED + 1)); return 0; fi
  ev=$(jq -nc --arg h "$head" --arg ms "$AFQ_PR_MS" '{head: $h, mergeable_state: $ms, checks: "all green", status: "success"}')
  ck="queue-reconcile:$slug#$n:waitci:$head:$mode"
  if [ "$mode" != on ]; then
    afq_claim queue-reconcile "$ck" "$p" "$slug" "$n" observe would_kick_ci "would run the conductor keyed to $key: WAIT_CI with every check green on its head" "$ev" || return 0
    afq_log "$key: would run the conductor keyed to it (WAIT_CI, every check green on ${head:0:8}); observe mode, nothing run"
    AFQ_N_WOULD=$((AFQ_N_WOULD + 1)); return 0
  fi
  afq_claim queue-reconcile "$ck" "$p" "$slug" "$n" on kick_ci "WAIT_CI with every check green on its head; one keyed conductor run" "$ev" || return 0
  # The child must not inherit this lane's locks (fd 8 PR lock, fd 9 lane lock).
  timeout -k 30 "$AFQ_KICK_TIMEOUT_S" env MC_ONLY_PR="$key" WAKE_LAUNCH=1 bash "$r/bin/merge-conductor.sh" >/dev/null 2>&1 8>&- 9>&-
  krc=$?
  post=$(mc_row_get "$key" | cut -f2)
  ev=$(jq -c --arg ps "${post:--}" --argjson rc "$krc" '. + {post_state: $ps, conductor_rc: $rc, timed_out: ($rc == 124)}' <<<"$ev")
  afq_close queue-reconcile done kick_ci "one keyed conductor run (rc $krc); the row now says ${post:-nothing}" "$ev" || true
  afq_log "$key: one keyed conductor run (rc $krc), the row now says ${post:-nothing}"
  [ "$post" = WAIT_CI ] && afq_log "$key: still WAIT_CI after the keyed run; no second kick on ${head:0:8}"
  AFQ_N_KICKED=$((AFQ_N_KICKED + 1))
  return 0
}

# afq_closed_list <slug> — the repo's closed PRs (one page), read at most once
#   per project per tick into AFQ_CLOSED. rc 1 unreadable.
afq_closed_list() {
  local rc=0
  [ "${AFQ_CLOSED_FOR:-}" = "$1" ] && return 0
  gh_rest_pr_list_var AFQ_CLOSED "$1" closed "" 100 || rc=$?
  if [ "$rc" != 0 ] || ! jq -e 'type == "array"' <<<"$AFQ_CLOSED" >/dev/null 2>&1; then AFQ_CLOSED=""; return 1; fi
  AFQ_CLOSED_FOR="$1"
  [ "$(jq length <<<"$AFQ_CLOSED")" -ge 100 ] && afq_log "$1: the closed PR list is a full page (100), truncated; only what was read is acted on"
  return 0
}

# afq_issue <slug> <n> — AFQ_IS_STATE (open|closed) and AFQ_IS_PR (1 when the
#   number is a pull request). rc 1 unreadable.
afq_issue() {
  local j row
  AFQ_IS_STATE=""; AFQ_IS_PR=0
  gh_rest_var j GET "repos/$1/issues/$2" || return 1
  row=$(jq -r '[(.state // ""), (if .pull_request then "1" else "0" end)] | @tsv' <<<"$j" 2>/dev/null) || return 1
  IFS=$'\t' read -r AFQ_IS_STATE AFQ_IS_PR <<<"$row"
  case "$AFQ_IS_STATE" in open|closed) return 0 ;; esac
  return 1
}

# afq_closer_of <slug> <issue> -> the number of a MERGED PR that closes it (a
#   `Closes #<issue>` line, or the decomposer's ticket/<key>-<issue>[-rN]
#   branch), from the closed list; nothing when none. rc 1 unreadable.
afq_closer_of() {
  afq_closed_list "$1" || return 1
  jq -r --arg d "$2" '[.[] | select(.merged_at != null)
    | select(((.body // "") | test("(^|\n)[ \t#*_`]*closes[*_: \t]+#" + $d + "([^0-9]|$)"; "i"))
             or ((.head.ref // "") | test("^ticket/[a-z0-9]+-" + $d + "(-r[0-9]+)?$"; "i")))
    | .number] | first // empty' <<<"$AFQ_CLOSED" 2>/dev/null
}

# afq_rec_dephold <project> <slug> <key> <n> <head> <mode> — (b).
afq_rec_dephold() {
  local p="$1" slug="$2" key="$3" n="$4" head="$5" mode="$6" body issue deps="" tbody="" d closer ord line sib
  local b1="" b2="" NL=$'\n'
  afq_pr_fresh "$slug" "$n" || { afq_log "$key: the pulls read failed (HTTP ${GH_REST_STATUS:-000}); the dependency hold is re-read next tick"; return 0; }
  [ "$AFQ_PR_STATE" = open ] && [ "$AFQ_PR_HEAD" = "$head" ] || return 0
  body="$AFQ_PR_BODY"
  deps=$(_pdg_deps "$body")
  issue=$(_pdg_linked_issue "$body")
  if [ -n "$issue" ] && { ! command -v pdg_ticket_enabled >/dev/null 2>&1 || pdg_ticket_enabled; } && _pdg_issue_board "$slug"; then
    pdg_ticket_deps "$slug" "$issue" >/dev/null || { afq_log "$key: issue #$issue could not be read; the hold is re-read next tick"; return 0; }
    tbody="${_PDG_TBODY:-}"
    [ -z "${_PDG_TDEPS:-}" ] || deps="${deps:+$deps$NL}$_PDG_TDEPS"
  fi
  # Every declared dependency: closed passes the gate; an open PR or an open
  # issue nobody closed is a real hold (no action); an open issue whose
  # closing PR merged is stale input (b2).
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    afq_issue "$slug" "$d" || { afq_log "$key: dependency #$d could not be read; no action this tick"; return 0; }
    [ "$AFQ_IS_STATE" = closed ] && continue
    [ "$AFQ_IS_PR" = 1 ] && return 0
    closer=$(afq_closer_of "$slug" "$d") || { afq_log "$key: the closed PR list could not be read; no action this tick"; return 0; }
    [ -n "$closer" ] || return 0
    b2="${b2:+$b2$NL}$d $closer"
  done < <(printf '%s\n' "$deps" | awk 'NF && !seen[$0]++')
  # The Order siblings the gate holds behind: a sibling PR GitHub has merged
  # or closed is stale input (b1); one that is still open is a real hold.
  if [ -n "$tbody" ]; then
    ord=$(_pdg_order_of "$tbody")
    if [ -n "$ord" ] && [ "${ord#* }" -gt 1 ] 2>/dev/null; then
      _pdg_order_hold "$slug" "$issue" "${ord% *}" "${ord#* }" || { afq_log "$key: the Order siblings could not be read; no action this tick"; return 0; }
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        sib=$(grep -oE 'PR #[0-9]+' <<<"$line" | head -1 | tr -dc '0-9')
        [ -n "$sib" ] || return 0
        afq_pr_fresh "$slug" "$sib" || { afq_log "$key: sibling #$sib could not be read; no action this tick"; return 0; }
        [ "$AFQ_PR_STATE" = closed ] || return 0
        b1="${b1:+$b1$NL}$sib ${AFQ_PR_MERGED_AT:--} $AFQ_PR_HEAD $AFQ_PR_REF"
      done <<<"${_PDG_OHOLD:-}"
    fi
  fi
  [ -n "$b1$b2" ] || return 0
  local smerged shead sref
  while read -r sib smerged shead sref; do
    [ -n "$sib" ] && afq_dep_sibling "$p" "$slug" "$key" "$n" "$head" "$sib" "$smerged" "$shead" "$sref" "$mode"
  done <<<"$b1"
  while read -r d closer; do
    [ -n "$d" ] && afq_dep_report "$p" "$slug" "$key" "$n" "$head" "$d" "$closer" "$mode"
  done <<<"$b2"
  return 0
}

# afq_dep_sibling <project> <slug> <held-key> <n> <head> <sibling> <merged_at|-> <sib-head> <sib-branch> <mode> — b1.
afq_dep_sibling() {
  local p="$1" slug="$2" key="$3" n="$4" head="$5" sib="$6" merged="$7" shead="$8" sref="$9" mode="${10}"
  local skey="$2#$6" surl="https://github.com/$2/pull/$6" row sst word ev ck
  word=CLOSED; [ "$merged" != - ] && word=MERGED
  if [ "$mode" = on ] && [ "$word" = MERGED ] && ! afq_merges_on "$p"; then
    afq_log "$key: held behind #$sib, which merged; merges are off or paused, so its row is settled when they resume"
    AFQ_N_SKIPPED=$((AFQ_N_SKIPPED + 1)); return 0
  fi
  if ! afq_pr_lock "$p" "$sib"; then afq_log "$skey: the conductor holds its PR lock; skipped this tick"; AFQ_N_SKIPPED=$((AFQ_N_SKIPPED + 1)); return 0; fi
  row=$(mc_row_get "$skey"); sst=$(cut -f2 <<<"$row")
  case "$sst" in READY|QUEUED) ;; *) afq_pr_unlock; return 0 ;; esac
  if [ "$mode" = on ] && ! afq_cap_ok queue-reconcile "$p"; then AFQ_N_CAPPED=$((AFQ_N_CAPPED + 1)); afq_pr_unlock; return 0; fi
  ev=$(jq -nc --argjson s "$sib" --arg st "$sst" --arg w "$word" --arg m "$merged" --arg h "$head" \
    '{held_head: $h, sibling: $s, sibling_row: $st, github: $w, merged_at: (if $m == "-" then null else $m end)}')
  ck="queue-reconcile:$slug#$n:dephold:$head:$sib:$mode"
  if [ "$mode" != on ]; then
    afq_claim queue-reconcile "$ck" "$p" "$slug" "$n" observe would_release_dep_hold "would correct #$sib's row ($sst) to $word, which holds #$n behind it" "$ev" \
      || { afq_pr_unlock; return 0; }
    afq_log "$key: would correct sibling #$sib's row $sst -> $word (GitHub says so); observe mode, nothing written"
    AFQ_N_WOULD=$((AFQ_N_WOULD + 1)); afq_pr_unlock; return 0
  fi
  afq_claim queue-reconcile "$ck" "$p" "$slug" "$n" on release_dep_hold "held behind #$sib, whose row says $sst while GitHub says $word" "$ev" \
    || { afq_pr_unlock; return 0; }
  if [ "$word" = MERGED ]; then
    afq_settle_locked "$p" "$slug" "$skey" "$surl" "$shead" "$(cut -f5 <<<"$row")" "$sref" \
      "by:archie-fm-queue (merged on GitHub; its stale $sst row held #$n behind the dependency gate)"
  else
    mc_transition "$skey" CLOSED "closed on GitHub (archie-fm-queue)" "$shead" "$(cut -f5 <<<"$row")" "$surl" - UNKNOWN - >/dev/null
  fi
  if ! afq_row_now "$skey" "$word"; then
    afq_close queue-reconcile failed "" "#$sib's row did not move to $word: it still says $(mc_row_get "$skey" | cut -f2)" "$ev" || true
    afq_log "$key: #$sib's row did not move to $word (it still says $(mc_row_get "$skey" | cut -f2)); not retried on ${head:0:8}"
    afq_alert "$skey is $word on GitHub but its conductor row would not move off $sst, so #$n stays held behind it; check state/merge-conductor/pr-state.tsv is writable on the hub"
    AFQ_N_FAILED=$((AFQ_N_FAILED + 1)); afq_pr_unlock; return 0
  fi
  afq_close queue-reconcile done release_dep_hold "#$sib's row moved $sst -> $word; #$n passes the dependency gate on its next tick" "$ev" || true
  afq_log "$key: held behind #$sib, whose row said $sst; GitHub says $word, so its row now does too"
  AFQ_N_RELEASED=$((AFQ_N_RELEASED + 1))
  afq_pr_unlock
  return 0
}

# afq_dep_report <project> <slug> <held-key> <n> <head> <issue> <closer> <mode> — b2.
afq_dep_report() {
  local p="$1" slug="$2" key="$3" n="$4" head="$5" d="$6" closer="$7" mode="$8" ev ck
  if [ "$mode" = on ] && ! afq_cap_ok queue-reconcile "$p"; then AFQ_N_CAPPED=$((AFQ_N_CAPPED + 1)); return 0; fi
  ev=$(jq -nc --arg h "$head" --argjson i "$d" --argjson c "$closer" '{held_head: $h, open_issue: $i, merged_pr: $c}')
  ck="queue-reconcile:$slug#$n:depissue:$head:$d:$mode"
  if [ "$mode" != on ]; then
    afq_claim queue-reconcile "$ck" "$p" "$slug" "$n" observe would_report_dep_hold "would report: #$d is open although PR #$closer that closes it merged" "$ev" || return 0
    afq_log "$key: would report that its dependency #$d is open although PR #$closer merged; observe mode"
    AFQ_N_WOULD=$((AFQ_N_WOULD + 1)); return 0
  fi
  afq_claim queue-reconcile "$ck" "$p" "$slug" "$n" on report_dep_hold "held on #$d, which is open although PR #$closer that closes it merged" "$ev" || return 0
  afq_close queue-reconcile requested report_dep_hold "reported: #$d is open although PR #$closer merged; close it or drop the dependency" "$ev" || true
  afq_alert "$slug#$n is held by the PR-dependency gate on #$d, which is still open although PR #$closer that closes it merged. If #$d is fully shipped, close it (gh issue close $d -R $slug); otherwise drop that dependency line from the ticket: https://github.com/$slug/pull/$n"  # gh-guard-allow: the text an alert hands the operator, never run here
  afq_log "$key: held on #$d, open although PR #$closer merged; reported (one alert)"
  AFQ_N_REPORTED=$((AFQ_N_REPORTED + 1))
  return 0
}

# afq_reconcile <project> <slug> <mode> — the playbook, over the repo's rows.
afq_reconcile() {
  local p="$1" slug="$2" mode="$3" row key st since head rev _al why _url n waitci="" dephold="" age
  local -a rws
  mapfile -t rws < <(afq_rows_of "$slug")
  [ "${#rws[@]}" -gt 0 ] || return 0
  waitci=$(afq_setting_secs archie.queue.wait_ci_stale_s 2700) || waitci=""
  dephold=$(afq_setting_secs archie.queue.dep_hold_stale_s 1800) || dephold=""
  for row in "${rws[@]}"; do
    [ "$AFM_ROUTE_ABSENT" = 1 ] && return 0
    [ -n "$row" ] || continue
    IFS=$'\t' read -r key st since head rev _al why _url <<<"$row"
    n=${key##*#}
    [[ $n =~ ^[0-9]+$ ]] && [[ $head =~ ^[0-9a-f]{40}$ ]] || continue
    [ -z "${ONLY_PR:-}" ] || [ "$ONLY_PR" = "$key" ] || continue
    [[ $since =~ ^[0-9]+$ ]] || since=$NOW
    age=$(( NOW - since ))
    case "$st" in MERGED|CLOSED|ABANDONED|"") continue ;; esac
    if mc_attempt_has "ejected $key $head" 2>/dev/null || [[ $why == queue-ejected* ]]; then
      afq_rec_settle "$p" "$slug" "$key" "$n" "$st" "$head" "$rev" "$why" "$mode"
    elif [ "$st" = READY ] && [ -n "$dephold" ] && [ "$age" -ge "$dephold" ] \
         && mc_attempt_has "depwaithold $key $head" 2>/dev/null && ! mc_attempt_has "depwaitrelease $key $head" 2>/dev/null; then
      afq_rec_dephold "$p" "$slug" "$key" "$n" "$head" "$mode"
    elif [ "$st" = WAIT_CI ] && [ -n "$waitci" ] && [ "$age" -ge "$waitci" ]; then
      afq_rec_kick "$p" "$slug" "$key" "$n" "$head" "$mode"
    fi
  done
  return 0
}
