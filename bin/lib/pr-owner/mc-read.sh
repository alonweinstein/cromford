#!/bin/bash
# bin/lib/pr-owner/mc-read.sh — where bin/pr-owner-sweep.sh gets the merge
# conductor's rows from (BH-5124). Sourced, never executed; no side effects at
# source time.
#
# WHY. The sweep used to grep state/merge-conductor/pr-state.tsv on whatever box
# it ran on. Only the conductor's box writes that file, so everywhere else it was
# a copy of nothing or a stale leftover, and a missing row read exactly like "the
# conductor does not own this PR": box-small counted every harness PR
# with no ledger row ORPHAN off a file last written hours earlier.
#
# po_mc_read <slug> <outfile> [<detailfile>] — write `<slug>#<num>\t<state>` lines
#   to <outfile> (and, when given, `<slug>#<num>\t<state>\t<reason>\t<head>\t<since
#   epoch>` lines from the same source to <detailfile>, `-` for an empty field:
#   the enroll hook's PO_MC_* context, BH-3933), and answer rc 0 with PO_MC_SRC set
#   (`rows` | `file:<age>s`), or rc 1 with PO_MC_WHY set and both files empty. In
#   order:
#   1. The D1 pr_state view, when the conductor's own gate (pr_rows_on, the
#      pr-state-rows flag) is up. Page rc 2 is "this repo has no conductor
#      rows", a real answer. A failed page, a malformed page or the 5-page bound
#      falls through to (2): a partial read is not an answer.
#   2. The file, only on the conductor's box (is_hub_box, bin/lib/hub-box.sh)
#      and only while its mtime is within PO_MC_MAX_AGE_S (the caller's ph_knob
#      read of pr_owner.mc_max_age_s / PR_OWNER_MC_MAX_AGE_S; 0 = never).
#   3. Otherwise refuse.
#   Call it in the caller's own shell, never in $( ): it sets globals, and
#   pr_rows_on's trip latch lives in that shell.

# shellcheck disable=SC2034  # PO_MC_SRC / PO_MC_WHY are read by the caller
po_mc_read() {
  local slug="${1:-}" out="${2:-}" det="${3:-}" root="${HARNESS:-${H:-}}" f max now mt age box
  PO_MC_SRC=""; PO_MC_WHY=""
  [ -n "$out" ] || { PO_MC_WHY="no outfile"; return 1; }
  : > "$out"; [ -z "$det" ] || : > "$det"
  [ -n "$slug" ] || { PO_MC_WHY="no repo"; return 1; }
  if type pr_rows_on >/dev/null 2>&1 && type pr_state_page >/dev/null 2>&1 && pr_rows_on; then
    _po_mc_rows "$slug" "$out" "$det" && { PO_MC_SRC=rows; return 0; }
    : > "$out"; [ -z "$det" ] || : > "$det"
  fi
  [ -n "$root" ] || { PO_MC_WHY="no harness root"; return 1; }
  if ! type is_hub_box >/dev/null 2>&1 || ! type local_box_name >/dev/null 2>&1; then
    PO_MC_WHY="cannot tell where the conductor runs (bin/lib/hub-box.sh not loaded)"; return 1
  fi
  box=$(local_box_name)
  if ! is_hub_box "$box"; then
    PO_MC_WHY="not the conductor's box (${box:-unnamed}; conductor runs on $(hub_box_name 2>/dev/null))"; return 1
  fi
  max="${PO_MC_MAX_AGE_S:-900}"
  case "$max" in ''|*[!0-9]*) max=900 ;; esac
  if [ "$max" -eq 0 ]; then PO_MC_WHY="PR_OWNER_MC_MAX_AGE_S=0 (file read off)"; return 1; fi
  f="$root/state/merge-conductor/pr-state.tsv"
  [ -f "$f" ] || { PO_MC_WHY="no state/merge-conductor/pr-state.tsv"; return 1; }
  now=$(date -u +%s); mt=$(stat -c %Y "$f" 2>/dev/null) || mt=""
  [[ "$mt" =~ ^[0-9]+$ ]] || { PO_MC_WHY="pr-state.tsv mtime unreadable"; return 1; }
  age=$((now - mt)); [ "$age" -lt 0 ] && age=0   # a future mtime is the conductor box's own clock
  if [ "$age" -gt "$max" ]; then PO_MC_WHY="pr-state.tsv is ${age}s old (limit ${max}s)"; return 1; fi
  grep "^$slug#" "$f" 2>/dev/null | cut -f1,2 > "$out"
  # pr-state.tsv: key state since head reviewed alerted reason url
  [ -z "$det" ] || grep "^$slug#" "$f" 2>/dev/null | awk -F'\t' -v OFS='\t' '{print $1,$2,$7,$4,$3}' > "$det"
  PO_MC_SRC="file:${age}s"
  return 0
}

# _po_mc_rows <slug> <outfile> [<detailfile>] — the same paged read as _swf_cond_read in
# bin/lib/stuck-work/facts-pr.sh (private to that lane, so copied and named):
# at most 5 pages of 1000. rc 0 = read to the end, 1 = failed or bounded.
_po_mc_rows() {
  local slug="$1" out="$2" det="${3:-}" before="" page=0 resp rc n
  while [ "$page" -lt 5 ]; do
    page=$((page+1))
    resp=$(pr_state_page 1000 "$before" "$slug"); rc=$?
    case "$rc" in 0) ;; 2) return 0 ;; *) return 1 ;; esac
    printf '%s' "$resp" | jq -r --arg s "$slug" '.rows[] | "\($s)#\(.number)\t\(.state // "-")"' >> "$out" 2>/dev/null || return 1
    [ -z "$det" ] || printf '%s' "$resp" | jq -r --arg s "$slug" '.rows[]
      | def d: if . == null or . == "" then "-" else tostring end;
        [($s + "#" + (.number | tostring)), (.state | d), (.reason | d), (.head | d),
         ((.since // "") | (try fromdateiso8601 catch null) | d)] | @tsv' >> "$det" 2>/dev/null || return 1
    n=$(printf '%s' "$resp" | jq -r '.rows | length' 2>/dev/null)
    before=$(printf '%s' "$resp" | jq -r '.rows[-1].id // empty' 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] && [[ "$before" =~ ^[0-9]+$ ]] || return 1
    [ "$n" -lt 1000 ] && return 0
  done
  return 1
}
