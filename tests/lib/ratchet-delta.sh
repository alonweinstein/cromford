#!/bin/bash
# tests/lib/ratchet-delta.sh — judge a ratchet by THIS DIFF, never by an
# absolute count of the live tree. Sourced after tests/lib/scratch.sh (it needs
# $T), never executed.
#
# WHY. A ratchet that pins a count taken from the live tree ("bin/ has 39 bare
# switch reads, the floor is 38") goes red on every PR the moment main moves:
# PRs merge in parallel, each is fine on its own, and their sum lands in a
# merge-queue batch over the pin. In the 2026-09-25..28 window 25 of 33 sampled
# red batches failed only on suites of that shape. PR #2772 (BH-2648) fixed the
# first one by counting at the base and at HEAD and going red only when the
# diff raised a count; this file is that pattern, once, for every ratchet.
#
# THE CONTRACT every ratchet that sources this keeps:
#   delta   (the default; every PR, merge-queue and push run) — count per key at
#           the base and at HEAD (the working tree) and go red only when a key's
#           count went UP, a new key with a count included. Anything main landed
#           sits on both sides and cancels, so unrelated drift can never dequeue
#           a batch. A count that goes down is always fine and owes no file edit.
#   strict  (RATCHET_MODE=strict, or --strict) — the ratchet's old absolute
#           check against its committed baseline, for a scheduled or post-merge
#           run that wants the whole inventory to match.
#   A base that does not resolve, or no base at all, is RED, never a skip:
#   "this diff adds nothing" is a claim a run with nothing to diff has not made.
# Known blind spot, the same one #2772 names: a file renamed with its sites
# reads as a new key (red). Convert the sites instead of carrying them.
#
#   rd_mode [args...]        print delta|strict: --strict among the args wins,
#                            then RATCHET_MODE (default delta). rc 2 on any
#                            other RATCHET_MODE value.
#   rd_base <repo>           print the base commit: the merge-base of HEAD with
#                            RATCHET_BASE (else TI_BASE) when set, or with
#                            origin/main (else main), whichever is newer. CI
#                            may set RATCHET_BASE to pull_request.base.sha; the
#                            origin/main fallback gives the same answer on a
#                            fetch-depth-0 checkout. rc 1 + the reason on stdout.
#   rd_tree <repo> <ref> <dest> <path>...
#                            extract <path>s as they are at <ref> into <dest>
#                            (git archive, never a checkout). A path that does
#                            not exist at <ref> is simply absent there — it is
#                            new in this diff. rc 1 when git cannot read <ref>.
#   rd_delta <head.tsv> <base.tsv>
#                            rows are "<key>\t<count>". Prints
#                            "<key>\t<head>\t<base>" for every key whose count
#                            at HEAD is above its count at the base (a key
#                            missing at the base counts 0), rc 1 if any.
#   rd_fixture_repo <dir>    a hermetic git repo for a suite's drift cases:
#                            branch `work` at an initial commit B, and
#                            refs/remotes/origin/main = B. The caller writes
#                            its files first; see rd_git / rd_main_commit.
#   rd_git <dir> <git args>  git as a scratch identity, never the caller's config.
#   rd_main_commit <dir> <msg> <cmd...>
#                            land a commit on origin/main (run <cmd...> <dir> on
#                            a side branch, commit, move the ref) and return to
#                            `work`, leaving the branch behind it — main drift.

rd_mode() {
  local a
  for a in "$@"; do [ "$a" = --strict ] && { echo strict; return 0; }; done
  case "${RATCHET_MODE:-delta}" in
    delta|strict) echo "${RATCHET_MODE:-delta}" ;;
    *) echo "RATCHET_MODE='${RATCHET_MODE}': want delta or strict"; return 2 ;;
  esac
}

rd_base() {
  local repo="$1" want="${RATCHET_BASE:-${TI_BASE:-}}" mb="" m c
  if [ -n "$want" ]; then
    git -C "$repo" cat-file -e "$want^{commit}" 2>/dev/null \
      || { echo "base '$want' (RATCHET_BASE/TI_BASE) does not resolve to a commit in $repo"; return 1; }
    mb=$(git -C "$repo" merge-base HEAD "$want" 2>/dev/null) \
      || { echo "base '$want' shares no history with HEAD in $repo"; return 1; }
  fi
  for c in origin/main main; do
    git -C "$repo" cat-file -e "$c^{commit}" 2>/dev/null || continue
    m=$(git -C "$repo" merge-base HEAD "$c" 2>/dev/null) || continue
    if [ -z "$mb" ] || git -C "$repo" merge-base --is-ancestor "$mb" "$m"; then mb="$m"; fi
    break
  done
  [ -n "$mb" ] || { echo "no base to diff against in $repo: set RATCHET_BASE, or fetch origin/main"; return 1; }
  printf '%s\n' "$mb"
}

rd_tree() {
  local repo="$1" ref="$2" dest="$3" p have=()
  shift 3
  git -C "$repo" cat-file -e "$ref^{commit}" 2>/dev/null || { echo "cannot read $ref in $repo"; return 1; }
  mkdir -p "$dest" || return 1
  for p in "$@"; do
    git -C "$repo" cat-file -e "$ref:$p" 2>/dev/null && have+=("$p")
  done
  [ "${#have[@]}" -gt 0 ] || return 0
  git -C "$repo" archive "$ref" -- "${have[@]}" | tar -x -C "$dest" \
    || { echo "cannot extract ${have[*]} at $ref"; return 1; }
}

rd_delta() {
  # FILENAME, not NR == FNR: an EMPTY base file (no sites at the base at all)
  # would otherwise make every HEAD row read as a base row, and report nothing.
  awk -F'\t' -v basef="$2" '
    FILENAME == basef { if ($1 != "") base[$1] = $2 + 0; next }
    $1 != "" { b = ($1 in base) ? base[$1] : 0; if ($2 + 0 > b) { print $1 "\t" ($2 + 0) "\t" b; bad = 1 } }
    END { exit bad ? 1 : 0 }
  ' "$2" "$1"
}

rd_git() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=work "${@:2}"; }

rd_fixture_repo() {
  local R="$1"
  mkdir -p "$R" || return 1
  rd_git "$R" init -q -b work . || return 1
  [ -e "$R/README" ] || echo readme > "$R/README"
  rd_git "$R" add -A && rd_git "$R" commit -qm B && rd_git "$R" update-ref refs/remotes/origin/main HEAD
}

rd_main_commit() {
  local R="$1" msg="$2"
  shift 2
  rd_git "$R" checkout -q -b rd-main refs/remotes/origin/main || return 1
  "$@" "$R" || return 1
  rd_git "$R" add -A && rd_git "$R" commit -qm "$msg" && rd_git "$R" update-ref refs/remotes/origin/main HEAD || return 1
  rd_git "$R" checkout -q work && rd_git "$R" branch -qD rd-main
}
