#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-fm-queue/culprit.sh — BH-4584 (BH-4574.2): queue-culprit. A
# failed Mergify batch is re-run one member at a time, each merged ALONE onto
# current main with only the batch's failing suites, on the CI pool; only a
# member that reproduces gets a head-bound BLOCK verdict and one PR comment
# naming the suite. Sourced by bin/archie-fm-queue.sh, never run.
#
# afq_culprit <project> <slug> <mode>, on a Mergify repo only:
#   1. failed batches: closed, unmerged mergify/merge-queue/* drafts updated
#      within ARCHIE_FMQ_BATCH_WINDOW_S (the closed list, one read per
#      project), with a `failure` run on the draft's head (a cancelled run is
#      not a failed batch). Members from the draft title (bej_draft_members);
#      a stacked draft or one over MC_BATCH_SOLO_MAX_MEMBERS is not solo-run.
#   2. the failing suites: flaky_run_tests_strict over each failed run. Only
#      tests/(mc/)?<x>.sh paths; a job:-only answer, a test title or an
#      unreadable log is "suites unknown" and no solo run.
#   3. per member, the solo verdict lives in the conductor's shared pre-queue
#      store, pq_key <slug> <n> <head> <main> <fp> (fp = sha1 of the sorted
#      suites, first 12 hex: #4550's key), so a run either lane paid for is
#      never paid for twice. A miss is ONE pq_dispatch (#4548's
#      prequeue-gate.yml, suites=S) claimed first as a queue-solo row and
#      capped by archie.cap.queue-solo; a pending entry is read back with
#      pq_read_run. Nothing waits: results are read on later ticks.
#      MAIN IS PINNED PER BATCH: the main of the batch's earliest entry on
#      that store (any member's head, the same fp, dispatched inside
#      ARCHIE_FMQ_BATCH_WINDOW_S), and the current tip only when there is none.
#      So a main that moves between ticks (Mergify merging the innocents of its
#      own split) neither orphans a pending run nor pays for it again.
#   4. THE WITNESS RULE (#4550's). A red main fails every member, so a red
#      member is blamed only once no member is pending and at least one member
#      is green. A member Mergify already merged passed CI on main, and counts
#      as green. A batch of one has no other member, so its witness is main
#      itself: no main-red freeze in force (main_red_flag), read fail closed (an
#      unloaded reader is no witness). Then each red member gets
#      `bin/lead-verdict.sh post <slug> <n> <head> BLOCK --source lead`, and
#      only after the verdict is recorded, one PR comment. Green members are
#      counted innocent and nothing is written on them: no verdict, comment,
#      label or dequeue.
# Without #4550's fp-keyed runner on the box the playbook does nothing, one
# log line per tick. #4548's pq_dispatch alone is NOT enough: it drops the fp
# and writes the plain pre-queue gate's key, where the conductor would read a
# suite-subset run as the full gate's verdict. So the playbook needs
# pq_dispatch, pq_read_run and pq_run_title AND bs_batch (#4550's
# mc-prequeue.d/batch-solo.sh, which ships with the fp-honouring pq_dispatch)
# or PQ_DISPATCH_FP=1. After a dispatch the fp key must read pending; if it
# does not, the row closes failed, ONE alert, and no member is dispatched again
# this tick.
# gh-rest: no-graphql

AFQ_SUITE_RE='^tests/(mc/)?[A-Za-z0-9._-]+\.sh$'

# afq_main_tip <slug> <base> — AFQ_MAIN, the base branch's tip sha, read at
#   most once per project per tick. rc 1 unreadable.
afq_main_tip() {
  local j
  [ -n "${AFQ_MAIN:-}" ] && return 0
  gh_rest_var j GET "repos/$1/commits/$2" || return 1
  AFQ_MAIN=$(jq -r '.sha // empty' <<<"$j" 2>/dev/null | tr 'A-F' 'a-f')
  [[ $AFQ_MAIN =~ ^[0-9a-f]{40}$ ]] || { AFQ_MAIN=""; return 1; }
}

# afq_batch_main <slug> <fp> <member:head ...> — AFQ_BMAIN, the main the batch
#   is pinned to: the main of the earliest pq_key entry for any listed member
#   head and this fp, dispatched within AFQ_BATCH_WINDOW_S. rc 1: none, and
#   the caller reads the current tip.
afq_batch_main() {
  local slug="$1" fp="$2" mh f pre m at best=""
  local -i bat=0
  AFQ_BMAIN=""
  shift 2
  for mh in "$@"; do
    pre=$(pq_key "$slug" "${mh%%:*}" "${mh#*:}" "")
    for f in "${pre%_}"_*_"$fp"; do
      [ -f "$f" ] || continue
      m=${f#"${pre%_}"_}; m=${m%_"$fp"}
      [[ $m =~ ^[0-9a-f]{40}$ ]] || continue
      read -r _ at _ <<<"$(pq_cache_get "$f")"
      [[ $at =~ ^[0-9]+$ ]] && [ "$at" -ge $(( NOW - AFQ_BATCH_WINDOW_S )) ] || continue
      if [ -z "$best" ] || [ "$at" -lt "$bat" ]; then best=$m; bat=$at; fi
    done
  done
  [ -n "$best" ] || return 1
  AFQ_BMAIN=$best
}

# afq_member_word <project> <slug> <mode> <n> <head> <main> <suites> <fp> <draft>
#   AFQ_WORD: green | red | could-not-run | pending | would | capped, and
#   AFQ_RUN the solo run id (or empty).
afq_member_word() {
  local p="$1" slug="$2" mode="$3" n="$4" h="$5" main="$6" suites="$7" fp="$8" d="$9"
  local path st at id rest line rrc drc ev ck
  AFQ_WORD=could-not-run; AFQ_RUN=""
  path=$(pq_key "$slug" "$n" "$h" "$main" "$fp")
  read -r st at id rest <<<"$(pq_cache_get "$path")"
  if [ -z "$st" ]; then
    ev=$(jq -nc --arg h "$h" --arg m "$main" --arg s "$suites" --argjson d "$d" '{head: $h, main: $m, suites: ($s | split(",")), draft: $d}')
    ck="queue-solo:$slug#$n:$h:${main:0:12}:$fp:$mode"
    if [ "$mode" != on ]; then
      afq_claim queue-solo "$ck" "$p" "$slug" "$n" observe would_solo_run "would run $suites on #$n merged alone onto main ${main:0:12} (batch #$d)" "$ev" \
        && afq_log "$slug#$n: would solo-run $suites on main ${main:0:12} (batch #$d); observe mode, nothing dispatched" \
        && AFQ_N_WOULD=$((AFQ_N_WOULD + 1))
      AFQ_WORD=would; return 0
    fi
    [ "${AFQ_FP_BROKEN:-0}" = 1 ] && return 0
    afq_cap_ok queue-solo "$p" || { AFQ_N_CAPPED=$((AFQ_N_CAPPED + 1)); AFQ_WORD=capped; return 0; }
    # A claim that is not ours with nothing on disk is a dispatch that never
    # wrote its pending line: a billed key is not dispatched again.
    afq_claim queue-solo "$ck" "$p" "$slug" "$n" on solo_run "batch #$d failed $suites; run it on #$n merged alone onto main ${main:0:12}" "$ev" || return 0
    drc=0; pq_dispatch "$slug" "$n" "$h" "$main" "$suites" "$fp" || drc=$?
    if [ "$drc" = 0 ] && [ -z "$(pq_cache_get "$path")" ]; then
      AFQ_FP_BROKEN=1
      afq_close queue-solo failed "" "pq_dispatch answered rc 0 but wrote nothing on the fp key; the dispatch ignored its fp" \
        "$(jq -c '. + {dispatch_rc: 0, fp_key: "empty"}' <<<"$ev")" || true
      afq_log "$slug#$n: pq_dispatch wrote nothing on the fp key ${fp}; queue-culprit stops dispatching this tick"
      afq_alert "queue-culprit: pq_dispatch on $slug#$n (head ${h:0:12}, main ${main:0:12}) answered rc 0 but wrote nothing on its suites key (fp $fp), so it most likely wrote the plain pre-queue gate's key with a suite-subset run. Check \$MC_STATE_DIR/prequeue/ for that PR and remove the plain entry, and set archie.manage.<project>=observe until the fp-keyed pq_dispatch (#4550) is on the hub"
      AFQ_N_FAILED=$((AFQ_N_FAILED + 1))
      return 0
    fi
    case "$drc" in
      0|3)
        afq_close queue-solo done solo_run "dispatched prequeue-gate.yml with suites=$suites (rc $drc); read on a later tick" \
          "$(jq -c --argjson rc "$drc" '. + {dispatch_rc: $rc}' <<<"$ev")" || true
        afq_log "$slug#$n: solo run of $suites on main ${main:0:12} dispatched (batch #$d)"
        AFQ_WORD=pending ;;
      *)
        afq_close queue-solo failed "" "pq_dispatch rc $drc; no solo run for this head and main" "$(jq -c --argjson rc "$drc" '. + {dispatch_rc: $rc}' <<<"$ev")" || true
        afq_log "$slug#$n: the solo run was not dispatched (pq_dispatch rc $drc)"
        AFQ_N_FAILED=$((AFQ_N_FAILED + 1)) ;;
    esac
    return 0
  fi
  if [ "$st" = pending ]; then
    rrc=0; line=$(pq_read_run "$slug" "$(pq_run_title "$n" "$h" "$main")") || rrc=$?
    [ "$rrc" = 0 ] || { AFQ_WORD=pending; return 0; }
    [[ $at =~ ^[0-9]+$ ]] || at=0
    if [ -z "$line" ]; then
      [ $(( NOW - at )) -lt "$AFQ_SOLO_TIMEOUT_S" ] && { AFQ_WORD=pending; return 0; }
      line="could-not-run - - deadline"
    fi
    read -r st id rest _ <<<"$line"
    [ "$rest" = - ] && rest=""
    pq_cache_put "$path" "$st" "$at" "$id" "$rest" || afq_log "$slug#$n: could not record the solo result $st for ${h:0:8}"
  fi
  rest="${rest#alerted}"; rest="${rest# }"
  [ "${id:-}" != - ] && AFQ_RUN="${id:-}"
  case "$st" in
    red) [ -n "$rest" ] && AFQ_WORD=red ;;
    green) AFQ_WORD=green ;;
    pending) AFQ_WORD=pending ;;
    *) AFQ_WORD=could-not-run ;;
  esac
  return 0
}

# afq_main_green <project> <slug> — rc 0 only when the main-red freeze reader
#   is loaded and no main-red flag is in force: the witness for a batch of one.
afq_main_green() {
  declare -F main_red_flag >/dev/null || return 1
  ! main_red_flag "$1" "$2" >/dev/null
}

# afq_comment_body <file> <slug> <suites> <main> <draft> <witness> <run>
#   witness: only (a batch of one), solo (a member passed alone) or merged
#   (the only witness is a member Mergify merged since).
afq_comment_body() {
  local f="$1" slug="$2" s="$3" main="$4" d="$5" wit="$6" run="$7" list that
  list=$(tr ',' '\n' <<<"$s" | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g')
  that="That suite failed"; [[ $s == *,* ]] && that="Those suites failed"
  {
    if [ "$wit" = only ]; then
      printf 'This PR fails %s when it is merged alone onto main at %s. %s merge queue batch #%s, where it was the only member, so I'"'"'ve blocked this head with a lead verdict.\n' \
        "$list" "${main:0:12}" "$that" "$d"
    elif [ "$wit" = merged ]; then
      printf 'This PR fails %s when it is merged alone onto main at %s. %s merge queue batch #%s, and another member of that batch has merged since, so I'"'"'ve blocked this head with a lead verdict and left the rest of the batch alone.\n' \
        "$list" "${main:0:12}" "$that" "$d"
    else
      printf 'This PR fails %s when it is merged alone onto main at %s. %s merge queue batch #%s, and the other members pass it on their own, so I'"'"'ve blocked this head with a lead verdict and left the rest of the batch alone.\n' \
        "$list" "${main:0:12}" "$that" "$d"
    fi
    [[ $run =~ ^[0-9]+$ ]] && printf '\nSolo run: https://github.com/%s/actions/runs/%s\n' "$slug" "$run"
    printf '\nPush a fix and the new head goes back through review. (archie-fm-queue)\n'
  } > "$f"
}

# afq_block <project> <slug> <mode> <n> <head> <main> <suites> <draft> <witness> <run>
afq_block() {
  local p="$1" slug="$2" mode="$3" n="$4" h="$5" main="$6" s="$7" d="$8" wit="$9" run="${10}" r ev ck note out lrc f crc=0 cw=ok
  r=$(afq_root); [ -n "$r" ] || return 0
  if [ "$mode" = on ] && ! afq_cap_ok queue-culprit "$p"; then AFQ_N_CAPPED=$((AFQ_N_CAPPED + 1)); return 0; fi
  ev=$(jq -nc --arg h "$h" --arg m "$main" --arg s "$s" --argjson d "$d" --arg r "$run" \
    '{head: $h, main: $m, suites: ($s | split(",")), draft: $d, run: (if $r == "" then null else $r end)}')
  ck="queue-culprit:$slug#$n:block:$h:$d:$mode"
  if [ "$mode" != on ]; then
    afq_claim queue-culprit "$ck" "$p" "$slug" "$n" observe would_block_verdict "would BLOCK ${h:0:12}: it reproduces $s alone on main ${main:0:12} (batch #$d)" "$ev" || return 0
    afq_log "$slug#$n: would BLOCK ${h:0:8}, it reproduces $s alone on main ${main:0:12} (batch #$d); observe mode, nothing posted"
    AFQ_N_WOULD=$((AFQ_N_WOULD + 1)); return 0
  fi
  afq_claim queue-culprit "$ck" "$p" "$slug" "$n" on block_verdict "reproduces $s alone on main ${main:0:12} (batch #$d)" "$ev" || return 0
  note="reproduces $s when merged alone onto main ${main:0:12} (batch #$d); the next push is re-reviewed (archie-fm-queue)"
  lrc=0; out=$(HARNESS="$r" "$r/bin/lead-verdict.sh" post "$slug" "$n" "$h" BLOCK --source lead --reviewer archie-fm-queue --note "$note" 2>&1 8>&- 9>&-) || lrc=$?
  out=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)
  case "$lrc" in
    0|4)
      # The verdict is recorded (rc 4: the lead-verdict status was not
      # published, and the block gate still reads the row). Only now the comment.
      f=$(mktemp "${TMPDIR:-/tmp}/afq-comment.XXXXXX") || f=""
      if [ -n "$f" ]; then
        afq_comment_body "$f" "$slug" "$s" "$main" "$d" "$wit" "$run"
        gh_rest_comment "$slug" "$n" "$f" || crc=$?
        rm -f "$f"
      else crc=1; fi
      if [ "$crc" != 0 ]; then cw=failed; afq_log "$slug#$n: the BLOCK is recorded but the PR comment failed (rc $crc); not re-posted"; fi
      afq_close queue-culprit done block_verdict "BLOCK on ${h:0:12}: reproduces $s alone on main ${main:0:12} (batch #$d)" \
        "$(jq -c --argjson rc "$lrc" --arg c "$cw" '. + {verdict_rc: $rc, comment: $c}' <<<"$ev")" || true
      afq_log "$slug#$n: BLOCK on ${h:0:8}, it reproduces $s alone on main ${main:0:12} (batch #$d)"
      AFQ_N_BLOCKED=$((AFQ_N_BLOCKED + 1)) ;;
    3)
      afq_close queue-culprit failed "" "the head moved before the verdict; nothing posted" "$ev" || true
      afq_log "$slug#$n: the head moved before the BLOCK; nothing posted"
      AFQ_N_FAILED=$((AFQ_N_FAILED + 1)) ;;
    *)
      afq_close queue-culprit failed "" "bin/lead-verdict.sh refused (rc $lrc): ${out:-no answer}" "$ev" || true
      afq_log "$slug#$n: the BLOCK was refused (rc $lrc): ${out:-no answer}; no comment"
      if grep -qiE '403|lead token|lead_verdict_token' <<<"$out"; then
        afq_alert "$slug#$n reproduces $s alone on main ${main:0:12} (batch #$d), but this box cannot post a lead verdict (403, no lead token): set LEAD_VERDICT_TOKEN_FILE on the hub, or post it by hand: bin/lead-verdict.sh post $slug $n $h BLOCK --source lead"
      fi
      AFQ_N_FAILED=$((AFQ_N_FAILED + 1)) ;;
  esac
  return 0
}

# afq_batch <project> <slug> <mode> <draft> <title> <draft-head> <base>
afq_batch() {
  local p="$1" slug="$2" mode="$3" d="$4" title="$5" dh="$6" pbase="$7"
  local mem members stacked nm max rj ids id names all="" tag name job=0 other=0 suites fp m green=0 solo=0 pend=0 i bmain="" wit=""
  local -a nums heads words runs open
  mem=$(bej_draft_members "$title") || return 0
  IFS=$'\t' read -r members _ _ stacked <<<"$mem"
  if [ -n "${ONLY_PR:-}" ]; then
    [ "${ONLY_PR%#*}" = "$slug" ] && [[ " $members " == *" ${ONLY_PR##*#} "* ]] || return 0
  fi
  [ "$stacked" = 1 ] && { afq_log "$slug batch #$d is stacked on another draft; not solo-run"; return 0; }
  nm=$(wc -w <<<"$members" | tr -d ' ')
  max=13; command -v pq_knob >/dev/null 2>&1 && max=$(pq_knob MC_BATCH_SOLO_MAX_MEMBERS)
  [[ $max =~ ^[0-9]+$ ]] || max=13
  if [ "$nm" -gt "$max" ]; then afq_log "$slug batch #$d has $nm members, over MC_BATCH_SOLO_MAX_MEMBERS=$max; not solo-run"; return 0; fi
  [[ $dh =~ ^[0-9a-f]{40}$ ]] || return 0
  gh_rest_var rj GET "repos/$slug/actions/runs?head_sha=$dh&per_page=100" || { afq_log "$slug batch #$d: its runs could not be read; no solo run this tick"; return 0; }
  ids=$(jq -r 'if (.total_count // 0) > (.workflow_runs | length) then error("partial")
    else .workflow_runs[] | select(.conclusion == "failure") | .id end' <<<"$rj" 2>/dev/null) \
    || { afq_log "$slug batch #$d: its runs could not be read in full; no solo run this tick"; return 0; }
  [ -n "$ids" ] || return 0
  for id in $ids; do
    names=$(flaky_run_tests_strict "$slug" "$id" 2>/dev/null) && [ -n "$names" ] \
      || { afq_log "$slug batch #$d: suites unknown (run $id's log could not be read in full); no solo run"; return 0; }
    all+="$names"$'\n'
  done
  while IFS=$'\t' read -r tag name; do
    [ -n "$tag" ] || continue
    case "$tag" in
      J) job=1 ;;
      P) [[ $name =~ $AFQ_SUITE_RE ]] && [[ $name != *..* ]] || other=1 ;;
      *) other=1 ;;
    esac
  done <<<"$all"
  [ "$job" = 1 ] && { afq_log "$slug batch #$d: suites unknown (the failed run names only job: lines); no solo run"; return 0; }
  [ "$other" = 1 ] && { afq_log "$slug batch #$d: suites unknown (a failing name is not a tests/ suite path); no solo run"; return 0; }
  suites=$(awk -F'\t' '$1 == "P" { print $2 }' <<<"$all" | sort -u | paste -sd, -)
  [ -n "$suites" ] || return 0
  fp=$(tr ',' '\n' <<<"$suites" | sha1sum | cut -c1-12)
  for m in $members; do
    if ! afq_pr_fresh "$slug" "$m"; then nums+=("$m"); heads+=(-); words+=(could-not-run); runs+=(""); continue; fi
    if [ "$AFQ_PR_STATE" = closed ] && [ -n "$AFQ_PR_MERGED_AT" ]; then
      nums+=("$m"); heads+=(-); words+=(merged); runs+=(""); green=$((green + 1)); continue
    fi
    [ "$AFQ_PR_STATE" = open ] && [[ $AFQ_PR_HEAD =~ ^[0-9a-f]{40}$ ]] || continue
    nums+=("$m"); heads+=("$AFQ_PR_HEAD"); words+=(""); runs+=("")
    open+=("$m:$AFQ_PR_HEAD")
  done
  if [ "${#open[@]}" -gt 0 ]; then
    if afq_batch_main "$slug" "$fp" "${open[@]}"; then bmain=$AFQ_BMAIN
    else
      afq_main_tip "$slug" "$pbase" || { afq_log "$slug: the $pbase tip could not be read; no solo run this tick"; return 0; }
      bmain=$AFQ_MAIN
    fi
  fi
  for i in "${!nums[@]}"; do
    [ -z "${words[$i]}" ] || continue
    afq_member_word "$p" "$slug" "$mode" "${nums[$i]}" "${heads[$i]}" "$bmain" "$suites" "$fp" "$d"
    words[i]=$AFQ_WORD; runs[i]=$AFQ_RUN
    case "$AFQ_WORD" in
      green) green=$((green + 1)); solo=$((solo + 1)) ;;
      pending|would|capped) pend=$((pend + 1)) ;;
    esac
  done
  [ "${#nums[@]}" -gt 0 ] || return 0
  if [ "$pend" -gt 0 ]; then
    AFQ_N_PENDING=$((AFQ_N_PENDING + pend))
    afq_log "$slug batch #$d: $pend of ${#nums[@]} solo run(s) not in yet; no verdict until every member has one"
    return 0
  fi
  for i in "${!nums[@]}"; do
    [ -z "${ONLY_PR:-}" ] || [ "$ONLY_PR" = "$slug#${nums[$i]}" ] || continue
    case "${words[$i]}" in
      green)
        afq_log "$slug#${nums[$i]}: innocent, $suites pass with it merged alone onto main ${bmain:0:12} (batch #$d); nothing written"
        AFQ_N_INNOCENT=$((AFQ_N_INNOCENT + 1)) ;;
      merged)
        afq_log "$slug#${nums[$i]}: merged since batch #$d, so it passed CI on main; a green witness, nothing written"
        AFQ_N_INNOCENT=$((AFQ_N_INNOCENT + 1)) ;;
      red)
        wit=""
        if [ "$solo" -gt 0 ]; then wit=solo
        elif [ "$green" -gt 0 ]; then wit=merged
        elif [ "$nm" = 1 ] && afq_main_green "$p" "$slug"; then wit=only
        fi
        if [ -n "$wit" ]; then
          afq_block "$p" "$slug" "$mode" "${nums[$i]}" "${heads[$i]}" "$bmain" "$suites" "$d" "$wit" "${runs[$i]}"
        elif [ "$nm" = 1 ]; then
          afq_log "$slug#${nums[$i]}: reproduces $suites alone in batch #$d of one, but main is red (${MRG_FLAG:-freeze reader not loaded}); no witness, no verdict"
        else
          afq_log "$slug#${nums[$i]}: reproduces $suites alone, but so does every member of batch #$d; main itself is the likely cause, no verdict"
        fi ;;
      *) afq_log "$slug#${nums[$i]}: no solo verdict (${words[$i]}) for batch #$d; Mergify's own split is the backstop" ;;
    esac
  done
  return 0
}

# afq_culprit <project> <slug> <mode> — the playbook.
afq_culprit() {
  local p="$1" slug="$2" mode="$3" pbase d title dh
  [ "$(afq_provider "$slug")" = mergify ] || return 0
  if ! declare -F pq_dispatch >/dev/null || ! declare -F pq_read_run >/dev/null || ! declare -F pq_run_title >/dev/null \
     || { ! declare -F bs_batch >/dev/null && [ "${PQ_DISPATCH_FP:-}" != 1 ]; }; then
    if [ "${AFQ_POOL_SAID:-0}" != 1 ]; then
      afq_log "queue-culprit: the fp-keyed CI-pool solo runner (#4550's pq_dispatch with bin/lib/mc-prequeue.d/batch-solo.sh) is not on this box; no failed batch is solo-run"
      AFQ_POOL_SAID=1
    fi
    return 0
  fi
  afq_closed_list "$slug" || { afq_log "$p: the closed PR list could not be read; no batch read this tick"; return 0; }
  pbase=$(mc_project_base "$p")
  while IFS=$'\t' read -r d dh title; do
    [ "$AFM_ROUTE_ABSENT" = 1 ] && return 0
    [[ $d =~ ^[0-9]+$ ]] || continue
    afq_batch "$p" "$slug" "$mode" "$d" "$title" "$dh" "$pbase"
  done < <(jq -r --argjson now "$NOW" --argjson w "$AFQ_BATCH_WINDOW_S" '.[]
      | select((.head.ref // "") | startswith("mergify/merge-queue/")) | select(.merged_at == null)
      | select(((.updated_at // "") | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch 0)) >= ($now - $w))
      | [(.number | tostring), (.head.sha // "-"), (.title // "")] | @tsv' <<<"$AFQ_CLOSED")
  return 0
}
