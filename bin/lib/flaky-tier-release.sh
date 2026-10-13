#!/bin/bash
# gh-identity: app-token
# bin/lib/flaky-tier-release.sh — release suites from flaky quarantine after K
# clean scheduled nightly runs on main (BH-3686, slice BH-3702). Sourced, never
# executed. The lane (bin/flaky-tier.sh, BH-3686's lane sibling) calls it.
#
# ft_release <slug> <rows_tsv_file>
#   <rows_tsv_file> is metric_flake_quarantine_rows output (bin/lib/jobs/cost.sh):
#   test, active, actor, updated_at, reason, tab separated.
#   Output: one released suite per line. rc is 0 on every path; a path that
#   cannot decide says why on stderr and releases nothing.
#
# THE CALLER SOURCES THE HELPERS. This file sources nothing. Before calling it,
# source bin/lib/gh-ci-read.sh (gh_ci_api), bin/lib/gh-rest.sh (gh_rest_comment,
# and gh-rest-var.sh's gh_rest_issue_state_var) and bin/lib/jobs/cost.sh
# (metric_flake_quarantine_rows, metric_flake_quarantine_put). A missing one is
# a stderr line and nothing released. The root is ${HARNESS:-${H:-}} and nothing
# else; an empty root is a stderr line and nothing released.
#
# KNOBS (the lane registers them as settings rows; these are the fallbacks):
#   FLAKY_TIER_RELEASE_CLEAN   K, clean runs needed (default 5, 1..100)
#   FLAKY_TIER_NIGHTLY_RUNS    N, runs listed per tick (default 10, 1..100)
#   FLAKY_TIER_RELEASE_ACTORS  actors whose rows may be released (default
#                              "flaky-tier main-red-bisect"). A row any other
#                              actor wrote (an operator's console toggle) is
#                              never released.
#   FLAKY_TIER_DRY=1 or FLAKY_TIER_ACT=0: decide and print, no PUT, no comment.
#   A bad knob value is a stderr line and nothing released, never a default.
#
# THE DECISION. The last N completed scheduled runs of harness-nightly.yml on
# main are listed through gh_ci_api. Each run's nightly-verdict-<digits> zips are
# read once and cached as $root/state/flaky-tier/nightly/<run_id>.tsv: line 1
# `# created_at=<iso> sha=<sha>`, then `suite<TAB>rc` from the logs'
# `--- tests/<suite> rc=<n>` lines (a suite seen twice keeps any non-zero rc).
# Only a terminal answer read from a SUCCESSFUL artifact listing is cached as
# the one line `# unreadable created_at=<iso>` (with a stderr line) and never
# fetched again: an expired nightly-verdict artifact, no nightly-verdict-<digits>
# artifact at all, a listing body that does not parse, or a zip that downloaded
# but will not extract. Any non-zero rc from the artifact listing or a download
# (gh api exits 1 on a rate limit, a 5xx or a network error, not 75) caches
# nothing: the run is unknown this tick, the fetch loop stops, and it is fetched
# again next tick.
# For an active row with a release-list actor, the listed runs newer than its
# updated_at are walked newest first: rc 0 adds one, a non-zero rc or an
# unreadable run ends the streak, a run with no line for the suite is skipped
# (so a shard killed by the job's timeout-minutes, which prints no
# `--- tests/x rc=` line for the suite it hung in, is skipped, not counted red),
# and an unknown run stops the walk with no release this tick. At K the row is
# re-read from the worker, and only if it is unchanged is it PUT inactive with
# actor flaky-tier. After a PUT that succeeded, the fix ticket named by `fix #<n>`
# in the row's reason gets one comment if a fresh read says it is open. The
# ticket is never closed here.
#
# The artifact zip is downloaded with a raw `gh api … > file`, because
# gh_ci_api captures output in $( ), which drops a zip's NUL bytes. It follows
# gh_ci_api's ladder: on a refusal it retries once on the token
# $root/bin/gh-token.sh --read hands back, when that differs from GH_TOKEN.
# It has no PAT rung; a download that still fails is unknown, retried next tick.

_ftr_int() { # _ftr_int <value> — an integer from 1 to 100
  case "${1:-}" in ''|*[!0-9]*|0*) return 1 ;; esac
  [ "$1" -le 100 ]
}

_ftr_epoch() { # _ftr_epoch <iso> — epoch seconds, non-zero when unparseable
  local s="${1:-}" e
  [ -n "$s" ] && [ "$s" != - ] || return 1
  e=$(date -u -d "$s" +%s 2>/dev/null) || return 1
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$e"
}

_ftr_zip() { # _ftr_zip <root> <slug> <artifact_id> <outfile> — rc of the download
  local root="$1" slug="$2" aid="$3" f="$4" rc=0 tok
  gh api "repos/$slug/actions/artifacts/$aid/zip" > "$f" 2>/dev/null || rc=$?
  [ "$rc" = 0 ] && return 0
  [ -x "$root/bin/gh-token.sh" ] || return "$rc"
  tok=$("$root/bin/gh-token.sh" --read "$slug" 2>/dev/null) || return "$rc"
  [ -n "$tok" ] || return "$rc"
  case "$tok" in "${GH_TOKEN:-}"|"${GITHUB_TOKEN:-}") return "$rc" ;; esac
  rc=0
  GH_TOKEN="$tok" GITHUB_TOKEN="$tok" gh api "repos/$slug/actions/artifacts/$aid/zip" > "$f" 2>/dev/null || rc=$?
  return "$rc"
}

# _ftr_fetch <root> <slug> <cache> <id> <created_at> <sha> — read one run into
# its cache file. rc 0 = cached (readable or unreadable), 75 = unknown this tick
# (said on stderr here). A transport failure is never cached.
_ftr_fetch() {
  local root="$1" slug="$2" cache="$3" id="$4" at="$5" sha="$6"
  local out rc=0 arts tmp aid exp why="" part
  out=$(gh_ci_api "$slug" "repos/$slug/actions/runs/$id/artifacts?per_page=100") || rc=$?
  if [ "$rc" != 0 ]; then
    echo "ft_release: nightly run $id artifact listing failed (rc $rc), unknown this tick" >&2; return 75
  fi
  arts=$(printf '%s' "$out" | jq -r '(.artifacts | if type == "array" then . else error("no artifacts") end)
    | .[] | select((.name // "") | test("^nightly-verdict-[0-9]+$"))
    | [(.id | tostring), (.expired | tostring)] | @tsv' 2>/dev/null) || why="artifact listing unparseable"
  [ -n "$why" ] || [ -n "$arts" ] || why="no nightly-verdict artifact"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ftr.XXXXXX") || { echo "ft_release: no temp dir for nightly run $id, unknown this tick" >&2; return 75; }
  if [ -z "$why" ]; then
    while IFS=$'\t' read -r -u 3 aid exp; do
      case "$aid" in ''|*[!0-9]*) why="artifact id '$aid'"; break ;; esac
      [ "$exp" = false ] || { why="artifact $aid expired"; break; }
      rc=0; _ftr_zip "$root" "$slug" "$aid" "$tmp/$aid.zip" || rc=$?
      if [ "$rc" != 0 ]; then
        rm -rf "$tmp"
        echo "ft_release: nightly run $id artifact $aid download failed (rc $rc), unknown this tick" >&2; return 75
      fi
      python3 -m zipfile -e "$tmp/$aid.zip" "$tmp/x/$aid" >/dev/null 2>&1 || { why="artifact $aid does not extract"; break; }
    done 3<<< "$arts"
  fi
  mkdir -p "$cache" || { rm -rf "$tmp"; echo "ft_release: cannot create $cache, nightly run $id unknown this tick" >&2; return 75; }
  part="$cache/.$id.tsv.$$"
  if [ -n "$why" ]; then
    echo "ft_release: nightly run $id cached unreadable: $why" >&2
    printf '# unreadable created_at=%s\n' "$at" > "$part"
  else
    { printf '# created_at=%s sha=%s\n' "$at" "$sha"
      if [ -d "$tmp/x" ]; then find "$tmp/x" -type f -name '*.log' -print0 | xargs -0 -r awk '
        /^--- tests\/[^ ]+ rc=[0-9]+( |$)/ {
          s = $2; r = $3; sub(/^rc=/, "", r); r = r + 0
          if (!(s in m) || r != 0) m[s] = r
        }
        END { for (s in m) printf "%s\t%d\n", s, m[s] }' | sort; fi
    } > "$part"
  fi
  rc=$?
  [ -n "$tmp" ] && rm -rf "$tmp"
  if [ "$rc" != 0 ] || ! mv -f "$part" "$cache/$id.tsv"; then
    rm -f "$part"; echo "ft_release: cannot write the cache for nightly run $id, unknown this tick" >&2; return 75
  fi
  return 0
}

ft_release() {
  local slug="${1:-}" rows="${2:-}" root fn k n actors dry=0 cache out rc=0
  local runs id at sha e min_ue= oldest= eligible suite active actor upd reason ue
  local streak ids f v released fresh idsc tnum st body url
  root="${HARNESS:-${H:-}}"
  if [ -z "$root" ]; then echo "ft_release: no HARNESS root, releasing nothing" >&2; return 0; fi
  for fn in gh_ci_api gh_rest_issue_state_var gh_rest_comment metric_flake_quarantine_put metric_flake_quarantine_rows; do
    command -v "$fn" >/dev/null 2>&1 && continue
    echo "ft_release: $fn is not defined (the caller sources it), releasing nothing" >&2; return 0
  done
  case "$slug" in [A-Za-z0-9]*/[A-Za-z0-9._-]*) ;; *) echo "ft_release: bad slug '$slug'" >&2; return 0 ;; esac
  case "$slug" in */*/*|*[!A-Za-z0-9._/-]*) echo "ft_release: bad slug '$slug'" >&2; return 0 ;; esac
  k="${FLAKY_TIER_RELEASE_CLEAN:-5}"; n="${FLAKY_TIER_NIGHTLY_RUNS:-10}"
  _ftr_int "$k" || { echo "ft_release: FLAKY_TIER_RELEASE_CLEAN='$k' is not 1..100, releasing nothing" >&2; return 0; }
  _ftr_int "$n" || { echo "ft_release: FLAKY_TIER_NIGHTLY_RUNS='$n' is not 1..100, releasing nothing" >&2; return 0; }
  if [ "$k" -gt "$n" ]; then echo "ft_release: K=$k > N=$n, no row can reach K, releasing nothing" >&2; return 0; fi
  actors=" ${FLAKY_TIER_RELEASE_ACTORS:-flaky-tier main-red-bisect} "
  actors=$(printf '%s' "$actors" | tr -s '[:space:]' ' ')
  [ -r "$rows" ] || { echo "ft_release: rows file '$rows' unreadable, releasing nothing" >&2; return 0; }
  { [ "${FLAKY_TIER_DRY:-0}" = 1 ] || [ "${FLAKY_TIER_ACT:-1}" = 0 ]; } && dry=1

  # The eligible rows: active, a release-list actor, a parseable updated_at.
  eligible=""
  while IFS=$'\t' read -r -u 3 suite active actor upd reason; do
    [ -n "$suite" ] && [ "$active" = 1 ] || continue
    case "$actors" in *" $actor "*) ;; *) continue ;; esac
    ue=$(_ftr_epoch "$upd") || { echo "ft_release: $suite has updated_at '$upd', skipped" >&2; continue; }
    eligible+="$suite"$'\t'"$actor"$'\t'"$upd"$'\t'"$ue"$'\t'"$reason"$'\n'
    { [ -z "$min_ue" ] || [ "$ue" -lt "$min_ue" ]; } && min_ue="$ue"
  done 3< "$rows"
  [ -n "$eligible" ] || return 0

  out=$(gh_ci_api "$slug" "repos/$slug/actions/workflows/harness-nightly.yml/runs?branch=main&event=schedule&status=completed&per_page=$n") || rc=$?
  if [ "$rc" != 0 ]; then echo "ft_release: nightly run listing failed (rc $rc), releasing nothing" >&2; return 0; fi
  rc=0
  runs=$(printf '%s' "$out" | jq -er '(.workflow_runs | if type == "array" then . else error("no runs") end)
    | sort_by(.created_at) | reverse | .[]
    | [(.id | tostring), (.created_at // ""), ((.head_sha // "") | if . == "" then "-" else . end)] | @tsv' 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    4) return 0 ;;
    *) echo "ft_release: nightly run listing unparseable, releasing nothing" >&2; return 0 ;;
  esac
  # id, created_at, sha, epoch; one bad entry makes the whole listing unknown.
  local listed=""
  while IFS=$'\t' read -r id at sha; do
    case "$id" in ''|*[!0-9]*) echo "ft_release: listing has run id '$id', releasing nothing" >&2; return 0 ;; esac
    e=$(_ftr_epoch "$at") || { echo "ft_release: run $id has created_at '$at', releasing nothing" >&2; return 0; }
    listed+="$id"$'\t'"$at"$'\t'"$sha"$'\t'"$e"$'\n'
    oldest="$e"
  done <<< "$runs"

  # Fetch what is not cached, newest first. Only runs newer than some eligible
  # row can count, and after one unknown run nothing older can be reached by a
  # walk (the walk stops there), so the fetch stops too.
  cache="$root/state/flaky-tier/nightly"
  while IFS=$'\t' read -r -u 3 id at sha e; do
    [ -n "$id" ] || continue
    [ "$e" -gt "$min_ue" ] || break
    [ -f "$cache/$id.tsv" ] && continue
    _ftr_fetch "$root" "$slug" "$cache" "$id" "$at" "$sha" || break
  done 3<<< "$listed"

  # Prune: an unlisted run older than the oldest listed one is never listed again.
  for f in "$cache"/*.tsv; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .tsv)
    case "$listed" in "$id"$'\t'*|*$'\n'"$id"$'\t'*) continue ;; esac
    v=$(sed -n '1s/.*created_at=\([^ ]*\).*/\1/p' "$f")
    e=$(_ftr_epoch "$v") && [ "$e" -ge "$oldest" ] && continue
    rm -f "$f"
  done

  while IFS=$'\t' read -r -u 3 suite actor upd ue reason; do
    [ -n "$suite" ] || continue
    streak=0; ids=""; released=0
    while IFS=$'\t' read -r id at sha e; do
      [ -n "$id" ] || continue
      [ "$e" -gt "$ue" ] || break
      f="$cache/$id.tsv"
      [ -f "$f" ] || break
      case "$(sed -n 1p "$f")" in "# unreadable"*) break ;; esac
      v=$(awk -F'\t' -v s="$suite" '$1 == s { print $2; exit }' "$f")
      [ -n "$v" ] || continue
      [ "$v" = 0 ] || break
      streak=$((streak + 1)); ids+="${ids:+ }$id"
      [ "$streak" -ge "$k" ] && { released=1; break; }
    done <<< "$listed"
    [ "$released" = 1 ] || continue
    idsc=${ids// /,}
    if [ "$dry" = 1 ]; then
      echo "ft_release: dry, would release $suite after $k clean nightly runs $idsc" >&2
      printf '%s\n' "$suite"; continue
    fi
    rc=0; fresh=$(metric_flake_quarantine_rows "$slug") || rc=$?
    if [ "$rc" != 0 ]; then echo "ft_release: re-read of $slug quarantine failed, $suite left alone" >&2; continue; fi
    if ! printf '%s\n' "$fresh" | awk -F'\t' -v s="$suite" -v a="$actor" -v u="$upd" \
         '$1 == s && $2 == "1" && $3 == a && $4 == u { f = 1 } END { exit !f }'; then
      echo "ft_release: $suite changed since the rows were read, left alone" >&2; continue
    fi
    if ! metric_flake_quarantine_put "$slug" "$suite" 0 "auto-release (flaky-tier): $k clean nightly runs $idsc" flaky-tier; then
      echo "ft_release: release PUT for $suite failed" >&2; continue
    fi
    printf '%s\n' "$suite"
    [[ "$reason" =~ fix\ \#([0-9]+) ]] || continue
    tnum="${BASH_REMATCH[1]}"; st=""; rc=0
    gh_rest_issue_state_var st "$slug" "$tnum" || rc=$?
    [ "$rc" = 0 ] && [ "$st" = open ] || continue
    url=""
    for id in $ids; do url+="${url:+, }https://github.com/$slug/actions/runs/$id"; done
    body=$(mktemp "${TMPDIR:-/tmp}/ftr-body.XXXXXX") || { echo "ft_release: no temp file for the #$tnum comment" >&2; continue; }
    printf '`%s` passed its last %s scheduled nightly runs on main, so we took it out of quarantine. It runs in the merge batch again. Runs: %s. This ticket stays open until the flake itself is fixed.\n' \
      "$suite" "$k" "$url" > "$body"
    gh_rest_comment "$slug" "$tnum" "$body" || echo "ft_release: comment on #$tnum failed, not retried" >&2
    rm -f "$body"
  done 3<<< "$eligible"
  return 0
}
