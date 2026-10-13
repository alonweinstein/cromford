#!/bin/bash
# bin/lib/mc-ci-timeout-budget.sh — ONE PAGE FOR THE REPO, AND NO RERUN THAT
# CANNOT SUCCEED (BH-3786, the budget slice of BH-3775). Sourced by
# bin/lib/mc-ci-timeout.sh after its stubs, so the cit_budget_step below
# replaces the contract's. Never executed.
#
# THE CASE. A required check on project-4 (`timeout-minutes: 10`) died at its
# limit on 29 of its last 40 runs. Each of 15 PRs bought one full rerun from the
# BH-636 flake ladder, and then each paged its own CI_FLAKE_TWICE. The cause was
# one line of YAML in the repo, and fifteen per-PR pages did not say so.
#
# THE RULE. A check FIRES on a repo when either
#   - the PR arm: its TIMEOUT lines in the ledger (written by the scan slice,
#     read-only here) inside MC_CI_TIMEOUT_WINDOW_S come from at least
#     MC_CI_TIMEOUT_MIN_PRS distinct PRs that are still open (this one counts;
#     a MERGED/CLOSED row or a key with no row does not), or
#   - the ratio arm, asked only when the PR arm did not fire: of the workflow's
#     last MC_CI_TIMEOUT_HISTORY_N completed runs (at least _HISTORY_MIN), at
#     least MC_CI_TIMEOUT_RATIO_PCT % were cancelled/timed_out at or past
#     T*60 - MC_CI_TIMEOUT_SLACK_S seconds.
# While a check fires, a run whose dead jobs are ALL TIMEOUT on firing checks is
# taken out of CIT_RUNS_LEFT (no rerun, so no CI_FLAKE_TWICE either), logged once
# per (PR, head) as CI_TIMEOUT_NO_RERUN, and the repo is paged ONCE per (repo,
# check, UTC day) as CI_TIMEOUT_BUDGET, in observe mode too (a page is not a
# GitHub write). Every firing that owned the page appends one line to
# CIT_FIRING_TSV. Anything else (one killed-runner job in the run, a check that
# is not firing) keeps its BH-636 rerun.
#
# WHAT LIES. Every failure reads as "did not fire": a history read that is not
# rc 0 (500, 404, 75) is cached as ERR for the tick and the ratio arm stays
# silent; a missing ledger counts only this PR. The PR arm undercounts on the
# first tick a repo is seen, because sibling workers have not written their
# ledger lines or rows yet; it converges on the next tick. The page names the
# check and the limit the scan resolved, so a matrix job whose limit fell back
# to MC_CI_TIMEOUT_DEFAULT_MIN names that default.

# cit_firing <slug> <check> <wfpath> <T> <key> — rc 0 when the check fires on
#   the repo. Sets CIT_HIT/CIT_OF (X of the last Y runs when the history read
#   succeeded and had runs, else the open-PR count and ""), CIT_PRS (`#n` list,
#   numeric order) and CIT_P50/CIT_P90 (nearest rank over the PR arm's ledger
#   durations, `-` when there are none). Never fires on an unreadable answer.
cit_firing() {
  local slug="$1" check="${2//$'\t'/ }" wfpath="$3" t="$4" key="$5"
  local now since lines k st keys="" durs="" n=0 pr_fire=1 f wfbase line x="" y="" lim
  CIT_HIT=""; CIT_OF=""; CIT_PRS=""; CIT_P50=-; CIT_P90=-
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  now=$(mc_now); since=$((now - MC_CI_TIMEOUT_WINDOW_S))
  # The PR arm: distinct open keys with a TIMEOUT line on this (repo, check).
  if [ -n "${CIT_LEDGER:-}" ] && [ -r "$CIT_LEDGER" ]; then
    lines=$(awk -F'\t' -v s="$since" -v r="$slug" -v c="$check" \
      '$1+0>=s+0 && $2==r && $3==c && $9=="TIMEOUT" {print $4 "\t" $7}' "$CIT_LEDGER" 2>/dev/null)
  else lines=""; fi
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    if [ "$k" != "$key" ]; then
      st=$(mc_row_field "$k" 2 2>/dev/null)
      case "$st" in ''|MERGED|CLOSED*) continue ;; esac
    fi
    keys+="$k"$'\n'
  done < <( { cut -f1 <<<"$lines"; printf '%s\n' "$key"; } | sort -u)
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    n=$((n + 1)); CIT_PRS+="${CIT_PRS:+ }#${k##*#}"
  done < <(printf '%s' "$keys" | awk -F'#' '{print $NF "\t" $0}' | sort -n | cut -f2-)
  durs=$(awk -F'\t' 'NR==FNR {if ($1 != "") ok[$1]=1; next} ($1 in ok) && $2 ~ /^[0-9]+$/ {print $2}' \
    <(printf '%s' "$keys") <(printf '%s\n' "$lines") | sort -n)
  if [ -n "$durs" ]; then
    local cnt; cnt=$(wc -l <<<"$durs")
    CIT_P50=$(sed -n "$(( (50*cnt + 99) / 100 ))p" <<<"$durs")
    CIT_P90=$(sed -n "$(( (90*cnt + 99) / 100 ))p" <<<"$durs")
  fi
  [ "$n" -ge "$MC_CI_TIMEOUT_MIN_PRS" ] || pr_fire=0
  # The history, read once per (repo, workflow, tick) under the cache file's own
  # lock, the identity block's shape: every worker of a repo gets here in the
  # same second, and unlocked each would buy its own read.
  wfbase=${wfpath##*/}
  lim=$((t * 60 - MC_CI_TIMEOUT_SLACK_S))
  if [ -n "$wfbase" ] && [ -n "${MC_TICK_DIR:-}" ]; then
    mkdir -p "$MC_TICK_DIR" 2>/dev/null
    f="$MC_TICK_DIR/$(mc_safe_name "${MC_TICK_ID:-notick}").cit-hist-$(mc_safe_name "$slug")-$(mc_safe_name "$wfbase")"
    line=$(
      ( flock 9 2>/dev/null
        if [ ! -s "$f" ]; then
          local hj xy
          if mc_rest_var hj gh_rest GET "repos/$slug/actions/workflows/$wfbase/runs?status=completed&per_page=$MC_CI_TIMEOUT_HISTORY_N" \
             && xy=$(jq -r --argjson lim "$lim" '
                  (.workflow_runs | if type == "array" then . else error("no workflow_runs") end) as $r
                  | ([$r[] | select((.conclusion == "cancelled" or .conclusion == "timed_out")
                        and (.run_started_at | type) == "string" and (.updated_at | type) == "string")
                      | ((.updated_at | sub("\\.[0-9]+"; "") | fromdateiso8601)
                         - (.run_started_at | sub("\\.[0-9]+"; "") | fromdateiso8601))
                      | select(. >= $lim)] | length) as $x
                  | "\($x)\t\($r | length)"' <<<"$hj" 2>/dev/null) && [ -n "$xy" ]; then
            printf '%s\n' "$xy" > "$f"
          else
            printf 'ERR\n' > "$f"
          fi
        fi
        cat "$f" ) 9>>"$f" 2>/dev/null )
    IFS=$'\t' read -r x y <<<"$line"
  fi
  case "$x:$y" in
    *[!0-9:]*|:*|*:) x=""; y="" ;;
  esac
  if [ -n "$y" ] && [ "$y" -gt 0 ]; then CIT_HIT=$x; CIT_OF=$y; else CIT_HIT=$n; CIT_OF=""; fi
  [ "$pr_fire" = 1 ] && return 0
  [ -n "$y" ] && [ "$y" -ge "$MC_CI_TIMEOUT_HISTORY_MIN" ] && [ $((x * 100)) -ge $((MC_CI_TIMEOUT_RATIO_PCT * y)) ] && return 0
  return 1
}

# cit_alert_once <slug> <key> <url> — page CI_TIMEOUT_BUDGET for CIT_CHECK once
#   per (repo, check, UTC day) across every worker, then record the firing.
#   The marker is not keyed by PR, so like BH-800's identityalert the check and
#   the append are ONE critical section on the lock mc_attempt_clear takes.
#   Mark-then-send: a send that fails after the mark loses today's page, never
#   doubles it.
cit_alert_once() {
  local slug="$1" key="$2" url="${3:-}" day ck own on npr prw dur="" xf=""
  day=$(date -u -d "@$(mc_now)" +%Y%m%d)
  ck=$(printf '%s' "$CIT_CHECK" | cksum | cut -d' ' -f1)
  own=$( ( flock 9 2>/dev/null
    grep -qxF "citimeout $slug $ck $day" "$MC_ATTEMPTS" 2>/dev/null && exit 0
    echo "citimeout $slug $ck $day" >> "$MC_ATTEMPTS"; printf 1
  ) 9>>"$MC_ATTEMPTS.lock" 2>/dev/null )
  [ "$own" = 1 ] || return 0
  npr=$(wc -w <<<"$CIT_PRS")
  prw="open PRs"; [ "$npr" = 1 ] && prw="open PR"
  if [ -n "$CIT_OF" ]; then on="$CIT_HIT of the last $CIT_OF runs"; else on="$npr $prw"; fi
  [ "$CIT_P50" != - ] && dur=" (durations p50 ${CIT_P50}s / p90 ${CIT_P90}s)"
  mc_alert "$key" WAIT_CI "CI_TIMEOUT_BUDGET: $slug \"$CIT_CHECK\" hit its $CIT_T-min timeout on $on$dur; every PR needing it is frozen ($npr $prw: $CIT_PRS). Raise timeout-minutes in $CIT_WF or shard the job${url:+: $url}"
  [ -n "${CIT_FIRING_TSV:-}" ] || return 0
  [ -n "$CIT_OF" ] && xf=$CIT_HIT
  mkdir -p "$(dirname "$CIT_FIRING_TSV")" 2>/dev/null || return 0
  ( flock 9 2>/dev/null
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(mc_now)" "$day" "$slug" "$CIT_CHECK" "$CIT_WF" "$CIT_T" \
      "${xf:--}" "${CIT_OF:--}" "$CIT_P50" "$CIT_P90" "$CIT_PRS" >> "$CIT_FIRING_TSV"
  ) 9>>"$CIT_FIRING_TSV.lock" 2>/dev/null
  return 0
}

# cit_budget_step <slug> <key> <head> <base> <num> <flake-runs> — the contract's
#   third step. Always rc 0: it only ever narrows CIT_RUNS_LEFT.
cit_budget_step() {
  local slug="$1" key="$2" head="$3" chk wt wf t fire="" first=0 ln id keep left="" withheld=0 c cls
  local s_check s_wf s_t s_hit s_of s_prs s_p50 s_p90
  while IFS= read -r chk; do
    [ -n "$chk" ] || continue
    wt=$(awk -F'\t' -v c="$chk" '$2==c {print $3 "\t" $4; exit}' <<<"$CIT_TIMEOUTS")
    IFS=$'\t' read -r wf t <<<"$wt"
    cit_firing "$slug" "$chk" "$wf" "$t" "$key" || continue
    fire+="$chk"$'\n'
    CIT_CHECK=$chk; CIT_WF=$wf; CIT_T=$t
    cit_alert_once "$slug" "$key" "${URL:-}"
    if [ "$first" = 0 ]; then
      first=1
      s_check=$chk; s_wf=$wf; s_t=$t; s_hit=$CIT_HIT; s_of=$CIT_OF; s_prs=$CIT_PRS; s_p50=$CIT_P50; s_p90=$CIT_P90
    fi
  done < <(cut -f2 <<<"$CIT_TIMEOUTS" | sort -u)
  [ "$first" = 1 ] || { CIT_CHECK=""; CIT_WF=""; CIT_T=""; CIT_HIT=""; CIT_OF=""; CIT_PRS=""; CIT_P50=""; CIT_P90=""; return 0; }
  CIT_FIRING=1; CIT_CHECK=$s_check; CIT_WF=$s_wf; CIT_T=$s_t
  CIT_HIT=$s_hit; CIT_OF=$s_of; CIT_PRS=$s_prs; CIT_P50=$s_p50; CIT_P90=$s_p90
  # Withhold a run only when every dead job we know of in it is a TIMEOUT on a
  # firing check: one killed-runner job keeps the whole run's rerun.
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    id=${ln%%|*}; keep=0
    c=$(awk -F'\t' -v r="$id" '$1==r {print $2}' <<<"$CIT_TIMEOUTS")
    if [ -z "$c" ]; then keep=1
    else
      while IFS= read -r chk; do grep -qxF -- "$chk" <<<"$fire" || keep=1; done <<<"$c"
    fi
    if [ "$keep" = 0 ] && [ -n "${CIT_LEDGER:-}" ] && [ -r "$CIT_LEDGER" ]; then
      while IFS=$'\t' read -r cls chk; do
        [ -n "$cls" ] || continue
        { [ "$cls" = TIMEOUT ] && grep -qxF -- "$chk" <<<"$fire"; } || keep=1
      done < <(awk -F'\t' -v s="$slug" -v r="$id" '$2==s && $6==r {print $9 "\t" $3}' "$CIT_LEDGER" 2>/dev/null)
    fi
    if [ "$keep" = 1 ]; then left+="$ln"$'\n'; else withheld=1; fi
  done <<<"$CIT_RUNS_LEFT"
  CIT_RUNS_LEFT=${left%$'\n'}
  [ "$withheld" = 1 ] || return 0
  if [ "${ACTIONS:-0}" = 1 ]; then
    mc_attempt_has "citskip $key $head" 2>/dev/null && return 0
    mc_attempt_put "citskip $key $head"
    mc_log "$key CI_TIMEOUT_NO_RERUN on ${head:0:8} ($CIT_CHECK dies at its ${CIT_T}-min limit; repo-level CI_TIMEOUT_BUDGET owns it)"
  else
    mc_log "$key CI_TIMEOUT_NO_RERUN would withhold the rerun on ${head:0:8} ($CIT_CHECK dies at its ${CIT_T}-min limit; repo-level CI_TIMEOUT_BUDGET owns it) — observe mode: nothing written"
  fi
  return 0
}
