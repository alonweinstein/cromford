#!/bin/bash
# bin/lib/hotfix-lib.sh — the shared vocabulary of "is this ticket the
# emergency one", and the one way the fleet says so out loud.
#
# WHY A LIB (#368, hotfix lane 1/3). The contract is ONE label, `hotfix`, on an
# `ai-build` issue, and six places have to agree on it before that sentence is
# true: bin/preplan-candidates.sh (plan it first), bin/run-build.sh (skip the
# WIP cap, label the PR, open the body with it), bin/fly-pool.sh and
# bin/fly-dispatch.sh (build it first, one machine past the cap),
# fly/builder-runner.sh (carry the answer onto the machine) and
# bin/hotfix-seen.sh (say so when it is first filed). Six local answers to
# "is this a hotfix" is five chances for a ticket to be urgent in one lane and
# ordinary in the next — which is the silent half of this feature, because a
# hotfix that is only sometimes a hotfix still ships, just late, and nothing
# logs a word about the difference.
#
# So the predicates live here and the callers read them. Sourced, never
# executed. Safe under `set -u`. Nothing here writes or calls GitHub EXCEPT the
# two functions that say so in their own names (hotfix_issue_is reads, and
# hotfix_announce writes) — every other function answers a question and the
# CALLER decides what that means.
#
# FAIL-OPEN IS "NOT A HOTFIX". Every uncertain answer — no jq, no gh, an
# unreadable file, a broken JSON payload — is the PLAIN path, which is exactly
# today's behaviour for every ticket. The cost of a wrong negative is an
# emergency that builds at ordinary speed; the cost of a wrong positive is a
# cap exceeded and a queue jumped for a ticket nobody declared urgent.

# shellcheck source=bin/lib/lane-switch.sh
command -v lane_switch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/lane-switch.sh" 2>/dev/null || lane_switch() { [ -n "${HARNESS:-${H:-}}" ] && [ -e "${HARNESS:-${H:-}}/flags/$1" ]; }

# _hotfix_env <harness> <VAR> <default> -> the value
#   Environment first, then env/global.env, then the default. READS the env file
#   rather than sourcing it, exactly as bin/lib/dep-verify-lib.sh:_dep_env does
#   and for the same reason: a predicate answering a yes/no question must never
#   inherit a box's secrets to answer it.
#
# gh-rest: no-graphql
#
_hotfix_env() {
  local h="${1:-}" var="${2:-}" def="${3:-}" v=""
  eval "v=\${$var:-}"
  if [ -z "$v" ] && [ -n "$h" ] && [ -r "$h/env/global.env" ]; then
    v=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$var=//p" "$h/env/global.env" \
        | tr -d '"'"'"' \t' | tail -1)
  fi
  [ -n "$v" ] || v="$def"
  printf '%s\n' "$v"
}

# hotfix_lane_on [harness] -> 1 | 0     (DEFAULT 1 — the lane is ON)
#
# THE KILL FLAG. 0 makes every predicate below answer "not a hotfix" and
# hotfix_announce a no-op, which puts the whole fleet back to its pre-#368
# behaviour without editing a script: no reordering, no cap exemption, no PR
# label, no announcements. flags/hotfix-lane-off (or the `switch.hotfix-lane-off`
# settings row) is honoured beside the env var
# because an operator killing this at 3am should not have to edit
# env/global.env on every box (same shape as dep_verify_on).
hotfix_lane_on() {
  local h="${1:-${HARNESS:-${H:-}}}" v
  [ -n "$h" ] && HARNESS="$h" lane_switch hotfix-lane-off file && { printf '0\n'; return 0; }
  v=$(_hotfix_env "$h" HOTFIX_LANE 1)
  case "$v" in 0|no|off|false) printf '0\n' ;; *) printf '1\n' ;; esac
}

# hotfix_label [harness] -> the label name (default `hotfix`)
#
# The one knob. It prints its answer even when the lane is off, because it is a
# NAME, not a verdict — the docs line and the ALERTS text still want to say
# which label they mean.
hotfix_label() {
  local h="${1:-${HARNESS:-${H:-}}}" v
  v=$(_hotfix_env "$h" HOTFIX_LABEL hotfix)
  printf '%s\n' "$v"
}

# hotfix_labels_json_has <json> [harness] -> rc 0 when the label is present
#
# <json> is either a gh `--json labels` array ([{"name":"hotfix"}], or a bare
# array of strings) or an object carrying one under `.labels`.
#
# EXACT WHOLE-NAME MATCH, case-insensitive, trimmed. The adversarial names are
# the point: `hotfix-candidate` is somebody ASKING whether this is urgent,
# `not-hotfix` is somebody saying it is not, and a substring match would read
# both as an emergency and spend a cap exemption on them. The word "hotfix" in
# a title or body is not a label and is not matched here either.
hotfix_labels_json_has() {
  local json="${1:-}" h="${2:-${HARNESS:-${H:-}}}" lbl
  [ "$(hotfix_lane_on "$h")" = 1 ] || return 1
  [ -n "$json" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  lbl=$(hotfix_label "$h" | tr '[:upper:]' '[:lower:]')
  printf '%s' "$json" | jq -e --arg l "$lbl" '
      (if type == "object" then (.labels // []) else . end)
      | (if type == "array" then . else [] end)
      | map(if type == "object" then (.name // "") else (. | tostring) end)
      | map(ascii_downcase | gsub("^[[:space:]]+|[[:space:]]+$"; ""))
      | index($l) != null' >/dev/null 2>&1
}

# hotfix_labels_csv_has <labels-csv> [harness] -> rc 0 when the label is present
#
# THE SAME ANSWER AS hotfix_labels_json_has, FOR CALLERS THAT ALREADY HAVE THE
# LABELS AS A LIST. bin/merge-conductor.sh reads every open PR of a repo in one
# `gh pr list --json labels` and carries the names down its tsv as
# `merge-queue,queued` — one comma-separated field, `-` when there are none. It
# would be a jq call per PR per tick to turn that back into JSON just to ask a
# yes/no question, and this needs no jq at all, which matters because the box
# that has no jq must still answer "not a hotfix" rather than crash.
#
# Whole-name match after trim + lowercase, exactly as the JSON reader: the
# adversarial names (`hotfix-candidate`, `not-hotfix`, `hotfixes`) are NOT
# matches, and here they gate MERGE ORDER — a false positive holds every other
# PR of that repo back for a tick.
hotfix_labels_csv_has() {
  local csv="${1:-}" h="${2:-${HARNESS:-${H:-}}}" lbl one
  [ "$(hotfix_lane_on "$h")" = 1 ] || return 1
  # `-` is the tsv's placeholder for "no labels" (an empty field would be eaten
  # by IFS), so it means the same thing as an empty string here.
  [ -n "$csv" ] && [ "$csv" != "-" ] || return 1
  lbl=$(hotfix_label "$h" | tr '[:upper:]' '[:lower:]')
  local IFS=',' parts=()
  # `read -a`, never `for one in $csv`: an unquoted expansion would glob, and a
  # label may legitimately contain a `*`.
  read -r -a parts <<<"$csv"
  for one in ${parts[@]+"${parts[@]}"}; do
    one=$(printf '%s' "$one" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
    [ "$one" = "$lbl" ] && return 0
  done
  return 1
}

# hotfix_meta_is <ticket-meta.json> [harness] -> rc 0 when the file's labels
#   carry the hotfix label. bin/run-build.sh already fetches the issue into
#   $BUILD/ticket-meta.json, so the PR-time check costs no API call.
hotfix_meta_is() {
  local f="${1:-}" h="${2:-${HARNESS:-${H:-}}}"
  [ -s "$f" ] || return 1
  hotfix_labels_json_has "$(cat "$f" 2>/dev/null)" "$h"
}

# hotfix_pr_is <labels-csv> <record-dir> [harness] -> rc 0 when this PULL
#   REQUEST is the emergency: its own `hotfix` label, or — for a harness PR
#   opened before the PR label was written — the label on the ISSUE it was built
#   from, which bin/run-build.sh already saved to the build record as
#   ticket-meta.json. NO GitHub call either way.
#
#   FAIL-OPEN IS STILL "NOT A HOTFIX": no record, an unreadable one, broken
#   JSON, no jq, lane off — all of them answer no, which is the plain path.
hotfix_pr_is() {
  local csv="${1:-}" rec="${2:-}" h="${3:-${HARNESS:-${H:-}}}"
  hotfix_labels_csv_has "$csv" "$h" && return 0
  [ -n "$rec" ] || return 1
  hotfix_meta_is "$rec/ticket-meta.json" "$h"
}

# hotfix_issue_is <repo-slug> <issue-number> [harness] -> THREE answers, not
#   two. One `gh issue view --json labels`.
#     rc 0 — the issue carries the label.
#     rc 1 — a definite no: the issue is not labelled, or a precondition was
#            never met (the lane is off, there is no gh binary, the repo slug
#            or the number is empty).
#     rc 2 — the CALL ITSELF failed (dead token, rate limit, a number that is
#            not an issue), so the answer is UNKNOWN rather than "ordinary".
#            An expired token that answers "not urgent" for every ticket in the
#            fleet is precisely the silent failure this lane cannot afford, and
#            a single falsy rc is what buys it.
#   rc 2 is STILL FALSY for every `&&` caller, so nothing that does not care
#   about the difference has to change; bin/run-build.sh is the caller that
#   decides what 2 means.
hotfix_issue_is() {
  local repo="${1:-}" n="${2:-}" h="${3:-${HARNESS:-${H:-}}}" out
  [ -n "$repo" ] && [ -n "$n" ] || return 1
  [ "$(hotfix_lane_on "$h")" = 1 ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  # THE LABELS COLLECTION, OVER REST (BH-781). `gh issue view --json labels` is
  # GraphQL, and on 2026-09-18 a rate-limited one answered an empty string that
  # a decision path read as a state. The library's three exit codes make that
  # impossible: 44 (no such issue) and 75 (refused, unreadable) both land on
  # rc 2 — UNKNOWN — because an expired token answering "not urgent" for every
  # ticket in the fleet is the silent failure this lane cannot afford.
  # hotfix_labels_json_has already accepts the bare array /labels returns.
  # No root = gh-rest is not loaded from one (BH-2650); unloaded is rc 2 below.
  command -v gh_rest >/dev/null 2>&1 || { [ -n "$h" ] && [ -r "$h/bin/lib/gh-rest.sh" ] && . "$h/bin/lib/gh-rest.sh"; }
  command -v gh_rest >/dev/null 2>&1 || return 2
  local t
  t=$(mktemp "${TMPDIR:-/tmp}/hotfix-labels.XXXXXX") || return 2
  gh_rest GET "repos/$repo/issues/$n/labels" > "$t" || { rm -f "$t"; return 2; }
  out=$(cat "$t" 2>/dev/null); rm -f "$t"
  hotfix_labels_json_has "$out" "$h"
}

# hotfix_key_is <harness> <project> <KEY> -> rc 0 when this build's ticket
#   carries the label.
#
# GitHub-Issues lanes only (fleet.conf board prefix "-"): the label lives on a
# GitHub issue, and an in-app product board has no such field in v1 (#368 puts
# the board-side priority field out of scope). So every board project answers
# "not a hotfix" here and is byte-identical to what it is today.
#
# This function ENDS with the hotfix_issue_is call, so that function's rc 2
# (the GitHub read failed, answer UNKNOWN) propagates out of here unchanged.
hotfix_key_is() {
  local h="${1:-}" p="${2:-}" key="${3:-}" here bp repo n
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$key" ] || return 1
  [ "$(hotfix_lane_on "$h")" = 1 ] || return 1
  here="$h/bin"
  bp=$("$here/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || return 1
  [ "$bp" = "-" ] || return 1
  n=$(printf '%s' "$key" | sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p')
  [ -n "$n" ] || return 1
  repo="${GH_ISSUES_REPO:-$("$here/fleet-conf.sh" "$p" repo 2>/dev/null || true)}"
  [ -n "$repo" ] || return 1
  hotfix_issue_is "$repo" "$n" "$h"
}

# hotfix_job_is <job.json> [harness] -> rc 0 when the queued job carries the
#   flag. The pool machine's own gate: the answer travelled with the job, so a
#   builder never has to ask GitHub a second time (and cannot get a different
#   answer than the watcher did).
#
#   The JSON boolean `true` and nothing else. The string "true" is a different
#   value, written by a different code path than the one that decided this, and
#   a cap exemption granted on a type coercion is one nobody wrote down.
hotfix_job_is() {
  local f="${1:-}" h="${2:-${HARNESS:-${H:-}}}"
  [ -s "$f" ] || return 1
  [ "$(hotfix_lane_on "$h")" = 1 ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '.hotfix == true' "$f" >/dev/null 2>&1
}

# ── PRIORITY RANK (#643 slice 1, BH-644) ─────────────────────────────────────
#
# ONE VOCABULARY, THREE RANKS, ASCENDING: 0 the hotfix label, 1 the main-red
# label (the fix that unblocks everybody else's merges), 2 every ordinary
# ticket. The whole reason this lives here and not in each selector is the same
# reason the predicates above do: four children of #643 that each decide what a
# label means is three chances for a ticket to be urgent in one lane and
# ordinary in the next.
#
# These PRINT a rank and ALWAYS return 0 — the answer is on stdout, never in
# the rc, so a caller can write `r=$(priority_rank_labels_csv "$csv")` under
# `set -e` without the shell deciding rank 2 is an error.
#
# FAIL-OPEN IS ALWAYS 2. Lane off, no jq, a broken payload, an unreadable file
# — all of them rank 2, which is where every ticket in the fleet sits today, so
# an uncertain answer changes nothing rather than promoting or demoting work
# nobody declared. Rank 0 is checked FIRST, so a ticket carrying both labels is
# a hotfix (and so is one whose MAIN_RED_LABEL was set to the hotfix label).
#
# This lib does NOT read HOTFIX: a caller that already holds HOTFIX=1 takes
# rank 0 itself. Nothing here reads flags/main-red-<slug> either — that flag
# says main is broken for a REPO, and reading it as a ticket rank would make
# every build yield to every other one (rejected in #643's plan).

# main_red_label [harness] -> the label name (default `fix-main-red`)
#
# The second knob, and a NAME rather than a verdict, so like hotfix_label it
# prints even when the lane is off. ONE KNOB SINCE BH-1770: the answer is
# bin/lib/main-red-label.sh's main_red_label_resolve, the same one every merge
# lane's MC_MAIN_RED_LABEL comes from (bin/lib/main-red-gate.sh) — the settings
# row lib.main-red-label.mc_main_red_label, then MC_MAIN_RED_LABEL, then the
# deprecated alias MAIN_RED_LABEL, env before env/global.env. Before it, this
# read MAIN_RED_LABEL alone, and setting either name without the other made the
# builds and the merge lanes disagree about which PRs are main-red.
#
# A box whose sync has not landed the lib (or a fixture that copied this file
# alone) gets the same four env tiers without the row.
main_red_label() {
  local h="${1:-${HARNESS:-${H:-}}}" v lib
  lib="$(dirname "${BASH_SOURCE[0]}")/main-red-label.sh"
  if ! command -v main_red_label_resolve >/dev/null 2>&1 && [ -r "$lib" ]; then
    # shellcheck source=bin/lib/main-red-label.sh
    . "$lib"
  fi
  # No root = no settings row to read, so the env tiers answer (BH-2650).
  if [ -n "$h" ] && command -v main_red_label_resolve >/dev/null 2>&1; then
    main_red_label_resolve "$h"
    return 0
  fi
  v="${MC_MAIN_RED_LABEL:-${MAIN_RED_LABEL:-}}"
  [ -n "$v" ] || v=$(_hotfix_env "$h" MC_MAIN_RED_LABEL "")
  [ -n "$v" ] || v=$(_hotfix_env "$h" MAIN_RED_LABEL fix-main-red)
  printf '%s\n' "$v"
}

# priority_rank_labels_csv <labels-csv> [harness] -> prints 0 | 1 | 2, rc always 0
#
# For the callers that already hold the labels as one comma-separated field
# (bin/merge-conductor.sh's tsv, `-` when there are none). Whole-name match
# after trim + lowercase, exactly like hotfix_labels_csv_has, which the rank-0
# half simply delegates to — and like it, this needs no jq, because the box
# without jq must still be able to order its work.
priority_rank_labels_csv() {
  local csv="${1:-}" h="${2:-${HARNESS:-${H:-}}}" lbl one
  hotfix_labels_csv_has "$csv" "$h" && { printf '0\n'; return 0; }
  [ "$(hotfix_lane_on "$h")" = 1 ] || { printf '2\n'; return 0; }
  [ -n "$csv" ] && [ "$csv" != "-" ] || { printf '2\n'; return 0; }
  lbl=$(main_red_label "$h" | tr '[:upper:]' '[:lower:]')
  local IFS=',' parts=()
  # `read -a`, never `for one in $csv`: an unquoted expansion would glob, and a
  # label may legitimately contain a `*`.
  read -r -a parts <<<"$csv"
  for one in ${parts[@]+"${parts[@]}"}; do
    one=$(printf '%s' "$one" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
    [ "$one" = "$lbl" ] && { printf '1\n'; return 0; }
  done
  printf '2\n'
  return 0
}

# priority_rank_labels_json <json> [harness] -> prints 0 | 1 | 2, rc always 0
#
# <json> is what hotfix_labels_json_has takes: a gh `--json labels` array, a
# bare array of strings, or an object carrying one under `.labels`. Rank 0 is
# that function; rank 1 is ONE jq call of the identical shape against the
# main-red name, so the two ranks cannot come to disagree about what "the same
# label" means. No jq, or jq refusing the payload, is rank 2.
priority_rank_labels_json() {
  local json="${1:-}" h="${2:-${HARNESS:-${H:-}}}" lbl
  hotfix_labels_json_has "$json" "$h" && { printf '0\n'; return 0; }
  [ "$(hotfix_lane_on "$h")" = 1 ] || { printf '2\n'; return 0; }
  [ -n "$json" ] || { printf '2\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '2\n'; return 0; }
  lbl=$(main_red_label "$h" | tr '[:upper:]' '[:lower:]')
  printf '%s' "$json" | jq -e --arg l "$lbl" '
      (if type == "object" then (.labels // []) else . end)
      | (if type == "array" then . else [] end)
      | map(if type == "object" then (.name // "") else (. | tostring) end)
      | map(ascii_downcase | gsub("^[[:space:]]+|[[:space:]]+$"; ""))
      | index($l) != null' >/dev/null 2>&1 && { printf '1\n'; return 0; }
  printf '2\n'
  return 0
}

# priority_rank_meta <ticket-meta.json> [harness] -> prints 0 | 1 | 2, rc always 0
#
# bin/run-build.sh already saves the issue to $BUILD/ticket-meta.json, so a
# build's own rank costs no API call. Missing, empty or unreadable file -> 2.
priority_rank_meta() {
  local f="${1:-}" h="${2:-${HARNESS:-${H:-}}}"
  [ -s "$f" ] || { printf '2\n'; return 0; }
  priority_rank_labels_json "$(cat "$f" 2>/dev/null)" "$h"
}

# priority_sort_tsv <rank-column> -> stdin sorted by that column, ascending
#
# THE ONLY SORT EVERY SELECTOR USES. `-s` is load-bearing: within one rank the
# order the rows arrived in IS the FIFO every lane promises, and GNU sort's
# last-resort whole-line comparison would quietly re-order a tie by ticket text
# instead — oldest-first becomes alphabetical, and nothing says a word.
#
# A rank column that is not a positive integer passes stdin through unchanged
# (fail-open = discovery order), because a selector whose sort key is wrong
# should still emit its candidates rather than nothing.
priority_sort_tsv() {
  local n="${1:-}"
  case "$n" in ''|*[!0-9]*) cat; return 0 ;; esac
  [ "$n" -ge 1 ] 2>/dev/null || { cat; return 0; }
  sort -s -t$'\t' -k"$n","$n"n
  return 0
}

# hotfix_announce <harness> <project> <KEY> <event> <text> -> always rc 0
#   event ∈ seen | pr_open | merged
#
# THE EXISTING CHANNEL, NOT A NEW ONE (#368: "do not add a new sink"). An
# ALERTS.log line plus one fleet_alert beat, which is the path bin/lane-alert.sh
# already takes to reach the console and Telegram. `seen`, `pr_open` and
# `merged` are the ALERTS.log line only (BH-2337, BH-2381); any other event
# still beats.
#
# ORDER IS THE DESIGN. The ALERTS line is written FIRST because it is local and
# durable — if the beat fails, the fleet still has the record. The marker is
# written LAST, so a crash between the two costs one DUPLICATE line and never a
# missed one: an emergency announced twice is noise, an emergency announced
# never is the thing this exists to prevent.
#
# `triaged:true` is deliberate and is the whole reason this is not a plain
# fleet_alert. bin/beat.sh quarantines an UNTRIAGED fleet_alert for the 10-min
# medic and bin/alert-flush.sh force-escalates it after 45 minutes; an
# emergency ticket announced 10-45 minutes late is the wrong shape for the one
# lane whose entire purpose is speed. The akey is the fingerprint
# (project, KEY, event), so the console dedupes on the same identity the marker
# does.
hotfix_announce() {
  local h="${1:-}" p="${2:-}" key="${3:-}" ev="${4:-}" txt="${5:-}" mdir mark line
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$key" ] && [ -n "$ev" ] || return 0
  [ "$(hotfix_lane_on "$h")" = 1 ] || return 0
  mdir="$h/state/hotfix-announced/$p"
  mark="$mdir/$key.$ev"
  [ -f "$mark" ] && return 0
  line="[$p/$key] HOTFIX $ev: $txt"
  mkdir -p "$h/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $line" >> "$h/logs/ALERTS.log" 2>/dev/null
  # seen, pr_open and merged are NOTICES (BH-2337, BH-2381): progress on the
  # hotfix, nothing is wrong. Their ALERTS line is the record and they open no
  # row; bin/lib/alert-state.sh's logonly table drops the re-beat. Any other
  # event still beats.
  case "$ev" in
    seen|pr_open|merged) ;;
    *)
      if command -v jq >/dev/null 2>&1 && [ -x "$h/bin/beat.sh" ]; then
        "$h/bin/beat.sh" "$(jq -nc --arg p "$p" --arg akey "hotfix:$p:$key:$ev" --arg l "$line" \
          '{kind:"fleet_alert",project:$p,akey:$akey,line:$l,triaged:true}')" >/dev/null 2>&1 || true
      fi ;;
  esac
  mkdir -p "$mdir" 2>/dev/null && : > "$mark" 2>/dev/null
  return 0
}
