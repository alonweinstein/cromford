#!/bin/bash
# bin/lib/lead-authority.sh — BH-3683: who may publish `lead-verdict: success`.
# Sourced (by bin/lib/verdict-status.sh, so every writer of the status has it),
# never executed.
#
# THE RULE. The hub's lead-review lane is the verdict authority: its MERGE
# publishes the gating status with no Mac involved. A PROTECTED PATH is a glob
# in catalog/lead-protected-paths.tsv (`<owner/repo>\t<glob>`) for the PR's
# repo, plus the space-separated globs of the settings row
# lead_protected_paths_extra.<owner>.<name>. The row can only ADD: removing a
# committed glob takes a PR to the catalog, which is itself protected. A glob
# cannot contain a space (the row's separator).
# What a protected path does depends on THE MODE (BH-4145), the settings row
# lead_authority_mode.<owner>.<name>, else the global lead_authority_mode:
#   lane   (the default: neither row exists) — a protected hit is REPORTED, not
#          withheld: rc 0 with LA_PROTECTED_HIT=1, LA_PROTECTED_PATHS and a
#          reason ending `cleared to merge on the lead verdict (lead_authority_mode=lane)`,
#          so the lane MERGE publishes. The authority row is not read.
#   human  the rule before BH-4145: two things take the lane's authority away
#          for one PR head, and then a `--source human` verdict is the one
#          writer that publishes success: 1. the PR touches a protected path; 2. the repo's authority
#          row lead_authority.<owner>.<name> is `human` (an operator) or
#          `human:precision` (bin/lead-review-precision.sh, after a precision
#          drop). No authority row, or `lane`, leaves the lane authoritative.
#          lead_authority.<owner>.<name> only bites under this mode.
#   An unreadable mode row, or a value other than lane|human after trimming and
#   lowercasing, is rc 2 (hold), never coerced to lane.
#   Set it: bin/jobs-client.sh setting-set lead_authority_mode[.<owner>.<name>] lane|human
# A repo with no catalog line is not governed at all: every other fleet repo is
# unchanged and costs no read (not even the mode row).
#
# la_decide <owner/repo> <pr> <head-sha> <lead|conductor|human>
#   rc 0  this writer may publish success. Under lane, LA_PROTECTED_HIT=1 when
#         the PR touches a protected path (empty otherwise), and
#         LA_PROTECTED_PATHS names up to five of them (`, +N more`).
#   rc 1  (mode human only) a human verdict is required; LA_REASON names the
#         protected path(s), or says the lane authority is revoked.
#   rc 2  could not decide; LA_REASON says what was unreadable. Callers publish
#         nothing on rc 2.
# _la_mode <owner/repo>   LA_MODE (lane|human) and LA_MODE_SRC; rc 2 unreadable.
#   source=human is rc 0 with no read. A BLOCK is never asked: failure is the
#   safe direction and any writer may publish it. For source=conductor a
#   standing human MERGE / MERGE-WITH-NOTES on this exact head is rc 0 (a human
#   already cleared it). The PR's files are read over REST (filename AND
#   previous_filename, so a rename or delete out of a protected path counts),
#   then its head is read again: a head that moved during the read is rc 2, so
#   the answer is bound to the sha being published.
# la_scope <owner/repo>   rc 0 governed, 1 not, 2 the catalog is unreadable.
# la_globs <owner/repo>   the globs in force, one per line (rc 2 = unreadable).
# la_human_needed <owner/repo> <pr> <head> <reason> <lane> — under mode lane,
#   rc 0 with no beat and no marker. Under human, or an unreadable mode, ONE warn beat per
#   head naming the command that publishes the status, deduped by
#   state/lead-authority/human-needed-<owner_name>-<pr>-<sha12>, written only
#   after lane-alert.sh returned 0. While the head still waits it beats again
#   once the marker is older than LA_HUMAN_REBEAT_S (default 86400, BH-3777:
#   the one beat on #3753/#3758 was buried among 270 open alerts), under an id
#   suffixed -r<YYYYMMDD> (lane-alert only counts a repeat of an open id), and
#   the marker is re-stamped only after that send returned 0.
#
# Bash 3.2 safe (the lead's Mac sources it through verdict-status.sh): no arrays,
# no mapfile, no ${x,,}. tests/lead-authority.bh-3683-test.sh pins it.
# gh-rest: no-graphql

_la_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_la_catalog() { printf '%s' "${LA_CATALOG:-${BASH_SOURCE[0]%/*}/../../catalog/lead-protected-paths.tsv}"; }

# _la_key <owner/repo> — `owner.name`, lowercased; rc 2 when the longer of the
# two keys built on it (the extras row) would not be a legal settings key.
_la_key() {
  local k
  [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  k=$(printf '%s' "$1" | tr 'A-Z/' 'a-z.')
  [ $(( ${#k} + 27 )) -le 64 ] || return 2
  printf '%s' "$k"
}

# _la_match <path> <glob> — `**` reads as `*`, and a bash `*` already crosses `/`.
_la_match() {
  local p="$1" g="$2"
  g="${g//\*\*/*}"
  # shellcheck disable=SC2053
  [[ $p == $g ]]
}

# _la_committed <owner/repo> — the catalog's globs for the repo. rc 2 = no catalog.
_la_committed() {
  local cat slug
  cat=$(_la_catalog)
  [ -r "$cat" ] || return 2
  slug=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  awk -F '\t' -v s="$slug" '/^[[:space:]]*#/ || NF < 2 { next } tolower($1) == s && $2 != "" { print $2 }' "$cat"
}

la_scope() {
  local g rc=0
  g=$(_la_committed "$1") || rc=$?
  [ "$rc" = 0 ] || return 2
  [ -n "$g" ]
}

# _la_extras <owner/repo> — the extras row's globs, one per line. rc 0 read
# (possibly none), rc 2 unreadable.
_la_extras() {
  local k v rc=0 g
  k=$(_la_key "$1") || return 2
  command -v setting_get >/dev/null 2>&1 || return 2
  v=$(setting_get "lead_protected_paths_extra.$k") || rc=$?
  case "$rc" in 0) ;; 2) return 0 ;; *) return 2 ;; esac
  # Split on whitespace with tr, never an unquoted $v: `docs/**` would glob.
  printf '%s\n' "$v" | tr -s ' \t' '\n\n' | awk 'NF'
}

la_globs() {
  local c e
  c=$(_la_committed "$1") || return 2
  e=$(_la_extras "$1") || return 2
  printf '%s\n' "$c"
  [ -z "$e" ] || printf '%s\n' "$e"
}

# _la_authority <owner/repo> — the authority row's value into LA_AUTH (`lane`
# when there is no row) and LA_AUTH_SRC (row|no row). rc 2 unreadable.
_la_authority() {
  local k v rc=0
  LA_AUTH=""; LA_AUTH_SRC=""
  k=$(_la_key "$1") || return 2
  command -v setting_get >/dev/null 2>&1 || return 2
  v=$(setting_get "lead_authority.$k") || rc=$?
  case "$rc" in
    0) LA_AUTH=$(printf '%s' "$v" | tr -d '[:space:]'); LA_AUTH_SRC=row ;;
    2) LA_AUTH=lane; LA_AUTH_SRC="no row" ;;
    *) return 2 ;;
  esac
}

# _la_mode <owner/repo> — BH-4145: the lead_authority_mode row in force into
# LA_MODE (`lane` when neither row exists) and LA_MODE_SRC (the key read, or
# `no row`). The per-repo row lead_authority_mode.<owner>.<name> beats the
# global lead_authority_mode. Trimmed and lowercased once, here. rc 2 when a
# read fails or the value is not exactly lane|human (LA_MODE keeps the value).
_la_mode() {
  local k v rc=0
  LA_MODE=""; LA_MODE_SRC=""
  k=$(_la_key "$1") || return 2
  command -v setting_get >/dev/null 2>&1 || return 2
  v=$(setting_get "lead_authority_mode.$k") || rc=$?
  case "$rc" in
    0) LA_MODE_SRC="lead_authority_mode.$k" ;;
    2) rc=0; v=$(setting_get lead_authority_mode) || rc=$?
       case "$rc" in
         0) LA_MODE_SRC=lead_authority_mode ;;
         2) v=lane; LA_MODE_SRC="no row" ;;
         *) return 2 ;;
       esac ;;
    *) return 2 ;;
  esac
  LA_MODE=$(printf '%s' "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr 'A-Z' 'a-z')
  case "$LA_MODE" in lane|human) return 0 ;; *) return 2 ;; esac
}

# _la_files <owner/repo> <pr> — every filename and previous_filename of the PR,
# one per line. rc 2 on a failed page, a non-array page or a full 30th page.
_la_files() {
  local f page n grc
  command -v gh_rest >/dev/null 2>&1 || return 2
  f=$(mktemp "${TMPDIR:-/tmp}/lead-authority.XXXXXX") || return 2
  for page in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    grc=0; GH_ETAG=0 gh_rest GET "repos/$1/pulls/$2/files?per_page=100&page=$page" > "$f" 2>/dev/null || grc=$?
    if [ "$grc" != 0 ] || ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then rm -f "$f"; return 2; fi
    jq -r '.[] | .filename, (.previous_filename // empty)' "$f" 2>/dev/null || { rm -f "$f"; return 2; }
    n=$(jq length "$f" 2>/dev/null)
    [ "${n:-0}" -lt 100 ] && { rm -f "$f"; return 0; }
  done
  rm -f "$f"
  return 2
}

la_decide() {
  local slug="${1:-}" pr="${2:-}" head="${3:-}" source="${4:-}" globs files line g hit="" n=0 live f grc
  LA_REASON=""; LA_PROTECTED_HIT=""; LA_PROTECTED_PATHS=""
  case "$source" in human) LA_REASON="a human verdict"; return 0 ;; lead|conductor) ;; *) LA_REASON="unknown source '$source'"; return 2 ;; esac
  head=$(printf '%s' "$head" | tr 'A-F' 'a-f')
  la_scope "$slug"
  case "$?" in
    0) ;;
    1) LA_REASON="not governed"; return 0 ;;
    *) LA_REASON="catalog $(_la_catalog) is unreadable"; return 2 ;;
  esac
  if [ "$source" = conductor ] && command -v vd_standing >/dev/null 2>&1; then
    line=$(vd_standing "$slug" "$pr" "$head" 2>/dev/null) || line=""
    if [ "$(printf '%s' "$line" | cut -f2)" = human ]; then
      case "$(printf '%s' "$line" | cut -f1)" in
        MERGE|MERGE-WITH-NOTES) LA_REASON="a human verdict stands on ${head:0:12}"; return 0 ;;
      esac
    fi
  fi
  _la_mode "$slug" || { LA_REASON="the mode row ${LA_MODE_SRC:-lead_authority_mode[.$(_la_key "$slug")]} could not be read or reads '$LA_MODE', not lane|human"; return 2; }
  # Under lane the authority row is not even read: it revokes nothing.
  if [ "$LA_MODE" = human ]; then
    _la_authority "$slug" || { LA_REASON="the authority row lead_authority.$(_la_key "$slug") could not be read"; return 2; }
    case "$LA_AUTH" in
      lane) ;;
      human|human:precision) LA_REASON="lane authority revoked (lead_authority.$(_la_key "$slug") = $LA_AUTH)"; return 1 ;;
      *) LA_REASON="the authority row lead_authority.$(_la_key "$slug") reads '$LA_AUTH', not lane|human|human:precision"; return 2 ;;
    esac
  fi
  globs=$(la_globs "$slug") || { LA_REASON="the protected-paths extras row could not be read"; return 2; }
  files=$(_la_files "$slug" "$pr") || { LA_REASON="the files of $slug#$pr could not be read whole"; return 2; }
  f=$(mktemp "${TMPDIR:-/tmp}/lead-authority.XXXXXX") || { LA_REASON="mktemp failed"; return 2; }
  grc=0; GH_ETAG=0 gh_rest GET "repos/$slug/pulls/$pr" > "$f" 2>/dev/null || grc=$?
  live=""; [ "$grc" = 0 ] && live=$(jq -r '.head.sha // ""' "$f" 2>/dev/null | tr 'A-F' 'a-f')
  rm -f "$f"
  [ -n "$live" ] || { LA_REASON="the head of $slug#$pr could not be re-read after its files"; return 2; }
  [ "$live" = "$head" ] || { LA_REASON="head moved during the file read (${live:0:12}, not ${head:0:12})"; return 2; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      if _la_match "$line" "$g"; then
        n=$((n + 1))
        [ "$n" -le 5 ] && hit="${hit:+$hit, }$line"
        break
      fi
    done <<EOF
$globs
EOF
  done <<EOF
$(printf '%s\n' "$files" | awk 'NF && !seen[$0]++')
EOF
  if [ "$n" -gt 0 ]; then
    [ "$n" -gt 5 ] && hit="$hit, +$((n - 5)) more"
    if [ "$LA_MODE" = lane ]; then
      LA_PROTECTED_HIT=1; LA_PROTECTED_PATHS="$hit"
      LA_REASON="touches protected paths: $hit; cleared to merge on the lead verdict (lead_authority_mode=lane)"
      return 0
    fi
    LA_REASON="touches protected paths: $hit"
    return 1
  fi
  LA_REASON="no protected path"
  return 0
}

la_human_needed() {
  local slug="$1" pr="$2" head="$3" reason="$4" lane="$5" root on mark
  root=$(_la_root)
  [ -n "$root" ] || return 1
  # BH-4145: under lane nobody is asked. An unreadable mode still pages.
  if _la_mode "$slug" && [ "$LA_MODE" = lane ]; then return 0; fi
  on=$(printf '%s' "$slug" | tr 'A-Z/' 'a-z_')
  mark="$root/state/lead-authority/human-needed-$on-$pr-${head:0:12}"
  local id="lead-human-needed-$on-$pr-${head:0:12}" again="" every
  if [ -e "$mark" ]; then
    every="${LA_HUMAN_REBEAT_S:-86400}"
    case "$every" in ''|*[!0-9]*) every=86400 ;; esac
    # find -mmin, not stat: stat's flags differ between GNU and BSD (the Mac).
    [ -n "$(find "$mark" -mmin +$((every / 60)) 2>/dev/null)" ] || return 0
    id="$id-r$(date -u +%Y%m%d)"; again="still waiting: "
  fi
  "$root/bin/lane-alert.sh" --severity warn --id "$id" "$lane" \
    "$again$slug#$pr @${head:0:12} needs a human verdict ($reason): a human verdict publishes lead-verdict: bin/lead-verdict.sh post $slug $pr $head MERGE --source human; https://github.com/$slug/pull/$pr" \
    >/dev/null 2>&1 || return 1
  mkdir -p "${mark%/*}" 2>/dev/null && touch "$mark" 2>/dev/null
  return 0
}
