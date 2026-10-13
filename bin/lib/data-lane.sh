# bin/lib/data-lane.sh — the ahead-of-merge data lane's contract (BH-4920; this
# slice BH-4923). Sourced, never executed. The siblings of BH-4920 import these
# names; bin/data-lane-apply.sh is the one entry point that acts on them. It
# builds no path from a harness root (D43): needs-human.sh loads from beside
# this file, and dl_candidate answers rc 2 when it did not.
#
# dl_prompt_field_note               prints the reviewer sentence (leading space)
# dl_candidate <review.md> [<diff-files>]
#                                    rc 0 "candidate<TAB><path>", rc 1 "none",
#                                    rc 2 unreadable (nothing printed)
# dl_reviewed_sha <build-dir>        the sha the final review round read (7-40
#                                    hex), rc 1 none
# dl_sha_is <reviewed> <head>        rc 0 when <reviewed> is a prefix of <head>
# dl_fp <statements-file>            sha1 of the file (40 hex), rc 2 unreadable
# dl_ledger_status <project> <file>  rc 0 present (prints status), 1 absent,
#                                    2 unknown — unknown is NEVER absent
# dl_probe_file <build-dir>          prints <build-dir>/data-lane-probe.md
# shellcheck shell=bash

[ -n "${_DL_LIB_LOADED:-}" ] && return 0
_DL_LIB_LOADED=1

_dl_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -r "$_dl_dir/needs-human.sh" ] && . "$_dl_dir/needs-human.sh" 2>/dev/null || true

# Algorithm constants, not settings: which path the lane may apply is policy.
DL_PATH_RE='^DATA_LANE: (scripts/migrations/[^ ]+\.sql|scripts/migrate-[^ /]+\.ts)$'
# A blocking finding is a line that STARTS with B<n>, BLOCK, BLOCKING or
# [BLOCK] after optional list/heading/bold markers. Case-sensitive, so
# "non-blocking" and "Blocking findings:" prose never count.
DL_BLOCK_RE='^[[:space:]]*([-*][[:space:]]+|[0-9]+\.[[:space:]]+|#+[[:space:]]*)?(\*\*)?(B[0-9]+|BLOCK|BLOCKING|\[BLOCK\])([^[:alnum:]_]|$)'

dl_prompt_field_note() {
  printf '%s\n' " If the diff adds or changes schema (scripts/migrations/*.sql or scripts/migrate-*.ts) and a BLOCK finding exists only because that migration is not yet applied to prod, write 'DATA_LANE: <repo-relative script path>' on its own line above the 'TIER:' line, and do NOT write a NEEDS_HUMAN line for that step. Write no DATA_LANE line otherwise."
}

# dl_candidate reads the FINAL round only (_nh_final) and never NEEDS_HUMAN text.
dl_candidate() {
  local f="${1:-}" diff="${2:-}" final lines path verdict n
  [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 2
  type _nh_final >/dev/null 2>&1 && type _nh_lines >/dev/null 2>&1 || return 2
  final=$(_nh_final "$f" | tr -d '\r')
  lines=$(printf '%s\n' "$final" | _nh_lines | grep -E '^DATA_LANE:' || true)
  path=$(printf '%s\n' "$lines" | sed -nE "s#$DL_PATH_RE#\1#p")
  verdict=$(printf '%s\n' "$final" | sed -nE 's/^[[:space:]]*VERDICT:[[:space:]]*(APPROVE|BLOCK)[[:space:]]*$/\1/p' | sed -n '$p')
  n=$(printf '%s\n' "$final" | _nh_lines | grep -cE "$DL_BLOCK_RE" || true)
  if [ -n "$lines" ] && [ "$(printf '%s\n' "$lines" | wc -l)" -eq 1 ] && [ -n "$path" ] \
     && case "$path" in /*|*..*|*'<'*) false ;; *) true ;; esac \
     && [ -n "$diff" ] && [ -r "$diff" ] && grep -qxF -- "$path" "$diff" \
     && [ "$verdict" = BLOCK ] && [ "$n" = 1 ]; then
    printf 'candidate\t%s\n' "$path"; return 0
  fi
  printf 'none\n'; return 1
}

# The final round's own head when it is a merged re-review, else review-head.
# Not reviewed-sha: that is the APPROVE gate's settlement, not the BLOCK round.
# The merged header carries the SHORT sha bin/lib/rb/review.sh writes
# (LENS_SHA=$(git rev-parse --short HEAD)), so 7 to 40 hex is read there; the
# caller matches it as a prefix of the PR head (dl_sha_is). review-head is the
# full sha.
dl_reviewed_sha() {
  local d="${1:-}" sha
  [ -n "$d" ] || return 1
  sha=$(grep -E '^=== ' "$d/review.md" 2>/dev/null | sed -n '$p' \
    | sed -nE 's/^=== MERGED RE-REVIEW .*\(head ([0-9a-f]{7,40})\) ===$/\1/p')
  [ -n "$sha" ] || sha=$(sed -n 1p "$d/review-head" 2>/dev/null | tr -d '[:space:]')
  [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || return 1
  printf '%s\n' "$sha"
}

# dl_sha_is <reviewed-sha> <full-head> — rc 0 when the reviewed sha (short or
# full) names that head: a prefix of it, at least 7 hex.
dl_sha_is() {
  [[ "${1:-}" =~ ^[0-9a-f]{7,40}$ ]] && [[ "${2:-}" =~ ^[0-9a-f]{40}$ ]] || return 1
  [ "${2:0:${#1}}" = "$1" ]
}

dl_fp() {
  [ -n "${1:-}" ] && [ -f "$1" ] && [ -r "$1" ] || return 2
  sha1sum < "$1" | cut -c1-40
}

# The three answers of ledger_has (bin/migration-autopilot.sh), except that no
# worker configured is UNKNOWN here: a pre-merge apply has no deploy gate and no
# app-side re-check behind it, so "cannot ask" must hold, never apply.
dl_ledger_status() {
  local out rc
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 2
  type job_ledger_get >/dev/null 2>&1 && [ -n "${HARNESS_SECRET:-}" ] || return 2
  out=$(job_ledger_get migration "$1 $2" 2>/dev/null); rc=$?
  case "$rc" in
    0) printf '%s\n' "$out"; return 0 ;;
    2) return 1 ;;
    *) return 2 ;;
  esac
}

dl_probe_file() {
  [ -n "${1:-}" ] || return 2
  printf '%s/data-lane-probe.md\n' "${1%/}"
}
