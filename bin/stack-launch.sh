#!/bin/bash
# bin/stack-launch.sh <project>   (BH-3684 — stacked builds by default)
#
# stdin   bin/unblocked-children.sh output (the tick's reading list).
# stdout  the same lines, in order, minus the STACKABLE lines this run LAUNCHED
#         or HELD. Exit 0 always.
#
# WHY. A decomposition files its children with `Blocked-by: #<contract> (hard)`,
# so every sibling comes out of bin/unblocked-children.sh as a STACKABLE line
# the moment the contract child's PR opens. Until now that line was only an
# offer to a triage session, which launched it or not. A chain level is an
# hour of wall clock, so for a decomposition's own chain (the line carries
# `chain=#<master>`) this filter launches the child itself, stacked on the
# parent's branch, through bin/launch-fastpath.sh's stack mode. No LLM.
#
# Each STACKABLE line gets exactly one of four outcomes, first answer wins:
#   HELD    the stack ledger already launched this child on this base less than
#           6h ago (SL_RELAUNCH_S) — the line is dropped, the build owns it.
#   WAIT    the parent PR is BLOCKed (its build verdict is BLOCK, or
#           bin/lib/block-gate.sh's bg_scan_read finds a standing BLOCK) — the
#           line is dropped and comes back next tick to be judged again. This
#           one applies to every STACKABLE line, chain or not.
#   LAUNCH  a chain= line whose parent PR is open, clear, and on the line's
#           base, and fastpath launched it — dropped; ledgers(kind=stack) row.
#   PASS    anything else, including every uncertainty (a read that failed, a
#           block state nobody could read, a fastpath decline, a run cap): the
#           line is printed unchanged, which is exactly the behaviour before
#           this script existed.
#
# FAIL-OPEN IS STRUCTURAL. stdin is read whole before anything else; any setup
# failure (bad project name, no jq, a missing lib, a kill switch, not a
# GitHub-Issues board, a low gh budget) prints it back verbatim.
#
# Kill switches: `stack-default-off` (settings row switch.stack-default-off,
# else flags/stack-default-off) and the older `stacked-builds-off` /
# STACKED_BUILDS=0, either one turns this into `cat`.
#
# THE LEDGER. ledgers(kind=stack, key="<project> <KEY>"):
#   stacked        {chain,parent,parent_pr,base,depth[,depth_capped|depth_partial],
#                   stacked_at,parent_pr_opened_at}
#   parent-merged  the same plus parent_merged_at, saved_s, saved_basis —
#                  saved_s = parent merge - stacked launch, a LOWER bound: an
#                  unstacked child starts no earlier than its parent's merge.
#   parent-closed  the parent PR closed unmerged; saved_s null (the conductor's
#                  restack/retarget owns the child).
# Finalised once per run, at most SL_MAX_FINAL rows, rotating across runs.
#
# Log words (logs/<project>.log): STACK-LAUNCH, STACK-WAIT, STACK-HELD,
# STACK-PASS, STACK-SAVED, and STACK-LEDGER when a launch's row write failed.
#
# Bounds: SL_MAX_PARENTS distinct parent PRs read and SL_MAX_LAUNCH launches
# per run (over either, the line is PASSed, never dropped); depth walk at most
# SL_MAX_DEPTH levels. Loop bounds in the style of unblocked-children.sh's
# MAX_LINES, not business knobs.
#
# gh-rest: no-graphql
set -uo pipefail
PROJECT="${1:-}"
HARNESS="${HARNESS:-/root/harness}"
SL_MAX_PARENTS=5
SL_MAX_LAUNCH=5
SL_MAX_FINAL=5
SL_MAX_DEPTH=4
SL_RELAUNCH_S=21600

IN=$(cat; printf x); IN="${IN%x}"
passthru() { printf '%s' "$IN"; exit 0; }

case "$PROJECT" in ''|*[!A-Za-z0-9._-]*) passthru ;; esac
command -v jq >/dev/null 2>&1 || passthru

# shellcheck disable=SC1091
. "$HARNESS/bin/lib/env-path.sh" 2>/dev/null || passthru
HENV=$(harness_env_dir "$HARNESS")
if [ -f "$HENV/global.env" ]; then set -a
  # shellcheck disable=SC1091
  . "$HENV/global.env" 2>/dev/null; set +a; fi
[ "${STACKED_BUILDS:-1}" = 0 ] && passthru
# shellcheck disable=SC1091
. "$HARNESS/bin/lib/lane-switch.sh" 2>/dev/null || passthru
command -v ls_isolated >/dev/null 2>&1 || passthru
ls_isolated lane_switch stack-default-off file && passthru
ls_isolated lane_switch stacked-builds-off file && passthru

BP=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null || true)
[ "$BP" = "-" ] || passthru
REPO="${GH_ISSUES_REPO:-}"
[ -n "$REPO" ] || REPO=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || passthru
OWNER="${REPO%%/*}"

# shellcheck source=bin/lib/preplan-lib.sh
. "$HARNESS/bin/lib/preplan-lib.sh" 2>/dev/null || passthru
PFX=$(preplan_key_prefix "$HARNESS" "$PROJECT" 2>/dev/null) || passthru
[ -n "$PFX" ] || passthru
# shellcheck source=bin/lib/gh-rest.sh
. "$HARNESS/bin/lib/gh-rest.sh" 2>/dev/null || passthru
# shellcheck source=/dev/null
. "$HARNESS/bin/jobs-client.sh" 2>/dev/null || passthru
# shellcheck source=bin/lib/block-gate.sh
. "$HARNESS/bin/lib/block-gate.sh" 2>/dev/null || passthru
for f in gh_rest job_ledger_row job_ledger_put ledger_page job_verdict bg_scan_read; do
  command -v "$f" >/dev/null 2>&1 || passthru
done
[ -x "$HARNESS/bin/launch-fastpath.sh" ] || passthru
# The identity that can see this repo, as bin/unblocked-children.sh arms it.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh" 2>/dev/null
command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$REPO" || true; }
# shellcheck source=bin/lib/gh-budget.sh
[ -r "$HARNESS/bin/lib/gh-budget.sh" ] && . "$HARNESS/bin/lib/gh-budget.sh" 2>/dev/null
command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low stack-launch && passthru

NOW=$(date -u +%s)
TS=$(date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ')
NOW_ISO=$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ')
mkdir -p "$HARNESS/logs" 2>/dev/null
log() { printf '%s [%s] %s\n' "$TS" "$PROJECT" "$*" >> "$HARNESS/logs/$PROJECT.log" 2>/dev/null; }
TD=$(mktemp -d) || passthru
trap 'rm -rf "$TD"' EXIT

epoch() { [ -n "${1:-}" ] || return 1; date -u -d "$1" +%s 2>/dev/null; }

# parent_pr <N> — the parent PR's REST object into $TD/pr-N.json, once per run.
# rc 0 read, 44 absent, 75 unreadable, 3 over the per-run parent cap.
NPARENTS=0
parent_pr() {
  local n="$1" rc=0
  if [ -f "$TD/pr-$n.rc" ]; then return "$(cat "$TD/pr-$n.rc")"; fi
  [ "$NPARENTS" -lt "$SL_MAX_PARENTS" ] || return 3
  NPARENTS=$((NPARENTS + 1))
  gh_rest GET "repos/$REPO/pulls/$n" > "$TD/pr-$n.json" || rc=$?
  [ "$rc" = 0 ] && ! jq -e 'type == "object" and has("state")' "$TD/pr-$n.json" >/dev/null 2>&1 && rc=75
  echo "$rc" > "$TD/pr-$n.rc"
  return "$rc"
}

# block_state <N> <url> <sha> <parent-issue> — once per parent PR per run.
# Prints "<0|1|2>\t<why>": 0 clear, 1 BLOCKed, 2 nobody could read it.
block_state() {
  local n="$1" url="$2" sha="$3" p="$4" v jrc=0 out brc=0
  if [ -f "$TD/blk-$n" ]; then cat "$TD/blk-$n"; return 0; fi
  v=$(job_verdict "$url" 2>/dev/null) || jrc=$?
  if [ "$jrc" = 0 ] && [ "$(printf '%s' "$v" | cut -f1)" = BLOCK ]; then
    printf '1\tbuild-verdict' > "$TD/blk-$n"
  else
    # bg_scan_read, never bg_scan: this lane must not advance the merge
    # lanes' refusal streak.
    out=$(bg_scan_read "$REPO" "$n" "$url" "$sha" "$p" 2>/dev/null) || brc=$?
    case "$brc" in
      1) printf '1\tblock-gate: %s' "$(printf '%s' "$out" | cut -f1)" > "$TD/blk-$n" ;;
      0) if [ "$jrc" = 1 ]; then printf '2\tverdict read failed' > "$TD/blk-$n"
         else printf '0\tclear' > "$TD/blk-$n"; fi ;;
      *) printf '2\tblock-gate could not read %s' "${out:-the thread}" > "$TD/blk-$n" ;;
    esac
  fi
  cat "$TD/blk-$n"
}

DEFAULT_BRANCH=""
default_branch() {
  [ -n "$DEFAULT_BRANCH" ] && { printf '%s' "$DEFAULT_BRANCH"; return 0; }
  gh_rest GET "repos/$REPO" > "$TD/repo.json" || return 1
  DEFAULT_BRANCH=$(jq -r '.default_branch // empty' "$TD/repo.json" 2>/dev/null)
  [ -n "$DEFAULT_BRANCH" ] || return 1
  printf '%s' "$DEFAULT_BRANCH"
}

# depth_of <parent-base-ref> — "<depth> <extra-json-fields>"; never fails the
# launch: a read that fails mid-walk records what is known, flagged partial.
depth_of() {
  local ref="$1" d=1 def f
  if ! def=$(default_branch); then printf '1 ,"depth_partial":true'; return 0; fi
  while [ "$ref" != "$def" ]; do
    if [ "$d" -ge "$SL_MAX_DEPTH" ]; then printf '%s ,"depth_capped":true' "$d"; return 0; fi
    f="$TD/walk-$d.json"
    if ! gh_rest GET "repos/$REPO/pulls?state=open&head=$OWNER:$ref" > "$f"; then
      printf '%s ,"depth_partial":true' "$d"; return 0
    fi
    ref=$(jq -r '.[0].base.ref // empty' "$f" 2>/dev/null)
    [ -n "$ref" ] || { printf '%s ,"depth_partial":true' "$d"; return 0; }
    d=$((d + 1))
  done
  printf '%s ' "$d"
}

NLAUNCH=0
OUT=()
# judge <line> — rc 0 keep the line, rc 1 drop it. Logs its own outcome.
judge() {
  local line="$1" n base url prn p chain key row st det dbase dat age pj rc head sha pbase
  local bs bwhy dep extra detail opened
  [[ "$line" =~ STACKABLE\ ([0-9]+)\ .*\ base=([^ ]+)\ parent-pr=([^ ]+)(\ chain=#([0-9]+))?\ \(Blocked-by\ #([0-9]+) ]] || return 0
  n="${BASH_REMATCH[1]}"; base="${BASH_REMATCH[2]}"; url="${BASH_REMATCH[3]}"
  chain="${BASH_REMATCH[5]}"; p="${BASH_REMATCH[6]}"
  [[ "$url" =~ /pull/([0-9]+)$ ]] || return 0
  prn="${BASH_REMATCH[1]}"
  key="$PFX-$n"

  # 1. already launched on this base inside the window (dedupe before spend)
  if [ -n "$chain" ]; then
    rc=0; row=$(job_ledger_row stack "$PROJECT $key" 2>/dev/null) || rc=$?
    if [ "$rc" = 0 ]; then
      st=$(printf '%s' "$row" | jq -r '.status // empty' 2>/dev/null)
      det=$(printf '%s' "$row" | jq -r '.detail // empty' 2>/dev/null)
      dbase=$(printf '%s' "$det" | jq -r '.base // empty' 2>/dev/null)
      dat=$(printf '%s' "$det" | jq -r '.stacked_at // empty' 2>/dev/null)
      if [ "$st" = stacked ] && [ "$dbase" = "$base" ] && age=$(epoch "$dat") \
         && [ $((NOW - age)) -lt "$SL_RELAUNCH_S" ]; then
        log "STACK-HELD $key :: stacked on $base at $dat, the build owns it"
        return 1
      fi
    fi
  fi

  # 2. the parent PR, re-read
  rc=0; parent_pr "$prn" || rc=$?
  case "$rc" in
    0) ;;
    3) log "STACK-PASS $key :: over the $SL_MAX_PARENTS-parent run cap"; return 0 ;;
    44) log "STACK-PASS $key :: parent PR #$prn absent"; return 0 ;;
    *) log "STACK-PASS $key :: parent PR #$prn unreadable (HTTP ${GH_REST_STATUS:-000})"; return 0 ;;
  esac
  pj="$TD/pr-$prn.json"
  st=$(jq -r '.state // empty' "$pj"); head=$(jq -r '.head.ref // empty' "$pj")
  sha=$(jq -r '.head.sha // empty' "$pj"); pbase=$(jq -r '.base.ref // empty' "$pj")
  opened=$(jq -r '.created_at // empty' "$pj")
  if [ "$st" != open ]; then log "STACK-PASS $key :: parent PR #$prn is $st"; return 0; fi
  if [ "$(jq -r '.draft == true' "$pj")" = true ]; then log "STACK-PASS $key :: parent PR #$prn is a draft"; return 0; fi
  if [ "$head" != "$base" ]; then log "STACK-PASS $key :: parent PR #$prn head is $head, not $base"; return 0; fi

  # 3. a BLOCKed parent holds every child, chain or not
  IFS=$'\t' read -r bs bwhy <<<"$(block_state "$prn" "$url" "$sha" "$p")"
  case "$bs" in
    1) log "STACK-WAIT $key :: parent #$p PR #$prn is BLOCKed ($bwhy)"; return 1 ;;
    0) ;;
    *) [ -n "$chain" ] && log "STACK-PASS $key :: parent PR #$prn block state unreadable ($bwhy)"; return 0 ;;
  esac

  # 4. only a decomposition's own chain is launched by default
  [ -n "$chain" ] || return 0
  if [ "$NLAUNCH" -ge "$SL_MAX_LAUNCH" ]; then log "STACK-PASS $key :: over the $SL_MAX_LAUNCH-launch run cap"; return 0; fi

  # 5. depth, then 6. the launch
  dep=$(depth_of "$pbase"); extra="${dep#* }"; dep="${dep%% *}"
  NLAUNCH=$((NLAUNCH + 1))
  if ! FASTPATH_STACK_BASE="$base" FASTPATH_STACK_PARENT="$p" FASTPATH_STACK_PARENT_PR="$url" \
       "$HARNESS/bin/launch-fastpath.sh" "$PROJECT" "$n" >/dev/null 2>&1; then
    log "STACK-PASS $key :: fastpath declined"
    return 0
  fi
  log "STACK-LAUNCH $key base=$base parent=#$p pr=#$prn depth=$dep chain=#$chain"
  detail=$(jq -nc --argjson c "$chain" --argjson p "$p" --arg u "$url" --arg b "$base" --argjson d "$dep" \
             --arg t "$NOW_ISO" --arg o "$opened" --argjson x "{${extra#,}}" \
    '{chain:$c,parent:$p,parent_pr:$u,base:$b,depth:$d} + $x + {stacked_at:$t,parent_pr_opened_at:$o}' 2>/dev/null)
  job_ledger_put stack "$PROJECT $key" stacked "$detail" >/dev/null 2>&1 \
    || log "STACK-LEDGER $key :: stack row write failed (launch stands)"
  return 1
}

LAST_NL=0
case "$IN" in *$'\n') LAST_NL=1 ;; esac
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *" STACKABLE "*) judge "$line" && OUT+=("$line") ;;
    *) OUT+=("$line") ;;
  esac
done <<<"${IN%$'\n'}"
if [ -n "$IN" ] && [ "${#OUT[@]}" -gt 0 ]; then
  printf '%s' "${OUT[0]}"
  [ "${#OUT[@]}" -gt 1 ] && printf '\n%s' "${OUT[@]:1}"
  [ "$LAST_NL" = 1 ] && printf '\n'
fi

# ---- finalise: time saved --------------------------------------------------
# A stacked row whose parent PR merged records the saving; one that closed
# unmerged records that no saving is claimed. Rotating start so a stack of
# still-open parents cannot starve the rows behind it.
PAGE=$(ledger_page stack 50 2>/dev/null) || exit 0
printf '%s' "$PAGE" | jq -c --arg p "$PROJECT " \
  '[ .ledgers[]? | select((.key // "") | startswith($p)) | select(.status == "stacked") ]' \
  > "$TD/rows.json" 2>/dev/null || exit 0
CNT=$(jq 'length' "$TD/rows.json" 2>/dev/null); case "$CNT" in ''|*[!0-9]*) CNT=0 ;; esac
[ "$CNT" -gt 0 ] || exit 0
START=$(( (NOW / 60) % CNT ))
i=0
while [ "$i" -lt "$CNT" ] && [ "$i" -lt "$SL_MAX_FINAL" ]; do
  idx=$(( (START + i) % CNT )); i=$((i + 1))
  k=$(jq -r ".[$idx].key" "$TD/rows.json"); det=$(jq -r ".[$idx].detail // empty" "$TD/rows.json")
  u=$(printf '%s' "$det" | jq -r '.parent_pr // empty' 2>/dev/null)
  [[ "$u" =~ /pull/([0-9]+)$ ]] || continue
  prn="${BASH_REMATCH[1]}"
  # A parent PR this run already read is not read again.
  if [ "$(cat "$TD/pr-$prn.rc" 2>/dev/null)" != 0 ]; then
    gh_rest GET "repos/$REPO/pulls/$prn" > "$TD/pr-$prn.json" || continue
    echo 0 > "$TD/pr-$prn.rc"
  fi
  st=$(jq -r '.state // empty' "$TD/pr-$prn.json" 2>/dev/null)
  ma=$(jq -r '.merged_at // empty' "$TD/pr-$prn.json" 2>/dev/null)
  if [ -n "$ma" ]; then
    sa=$(printf '%s' "$det" | jq -r '.stacked_at // empty')
    if me=$(epoch "$ma") && se=$(epoch "$sa"); then saved=$((me - se)); [ "$saved" -lt 0 ] && saved=0
    else saved=null; fi
    nd=$(printf '%s' "$det" | jq -c --arg m "$ma" --argjson s "$saved" \
      '. + {parent_merged_at:$m, saved_s:$s, saved_basis:"parent merge minus stacked launch; an unstacked child starts no earlier than its parent merge, so this is a lower bound"}' 2>/dev/null) || continue
    job_ledger_put stack "$k" parent-merged "$nd" >/dev/null 2>&1 || continue
    [ "$saved" = null ] && sm="?" || sm=$((saved / 60))
    log "STACK-SAVED ${k#"$PROJECT "} depth=$(printf '%s' "$det" | jq -r '.depth // "?"') saved=${sm}m (parent #$(printf '%s' "$det" | jq -r '.parent // "?"') merged)"
  elif [ "$st" = closed ]; then
    nd=$(printf '%s' "$det" | jq -c '. + {saved_s:null}' 2>/dev/null) || continue
    job_ledger_put stack "$k" parent-closed "$nd" >/dev/null 2>&1 || true
  fi
done
exit 0
