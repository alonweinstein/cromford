#!/bin/bash
# bin/mergify-sync.sh — is each fleet repo's live .mergify.yml what the harness
# template renders from its config/mergify/repos/<repo>.conf? (BH-1699, BH-1673.2)
#
#   bin/mergify-sync.sh [check] [slug…]   read-only; the daily hub lane runs this
#   bin/mergify-sync.sh apply [slug…]     opens a PR for each DRIFT repo, nothing else
#
# Opt-in: only a repo with a conf is ever read. One line per repo on stdout and
# in logs/mergify-sync.log, `<slug> <OUTCOME>`, OUTCOME one of IN_SYNC,
# OVERRIDE <reason>, DRIFT, MISSING, UNREADABLE <why>, PR_OPEN <url>,
# PR_CREATED <url>, PR_FAILED <what>. Nothing but a comparator rc 0 prints
# IN_SYNC; a read that failed in any way is UNREADABLE.
#
# check: DRIFT, MISSING and UNREADABLE each write ONE ALERTS.log line per repo
# per UTC day, deduped by state/mergify-sync/<owner_repo>.<YYYYMMDD>, and the
# marker is written only after the append succeeded.
#
# apply: acts on DRIFT only. It renders the template, branches
# harness/mergify-sync-<sha8 of the rendered bytes> off the default-branch head
# (a 422 on the ref create is reuse only if the ref then reads back), PUTs the
# file on THAT branch and opens a PR. An open PR on the branch is PR_OPEN and no
# write. It never merges, never writes the default branch, and never creates a
# MISSING file: a new .mergify.yml flips mc_queue_provider (docs/MERGIFY.md §1).
#
# Exit: 0 when every repo is IN_SYNC or OVERRIDE (apply also accepts PR_OPEN and
# PR_CREATED), 1 otherwise, 2 on a usage error. No confs at all is rc 0.
#
# Comparator: "${MERGIFY_TEMPLATE_BIN:-$HARNESS_ROOT/bin/mergify-template.sh}"
# render|compare|marker, the BH-1697 contract (compare rc 3 = cannot compare).
# Tests: HARNESS (sandbox root), MERGIFY_TEMPLATE_BIN, a `gh` stub on PATH.
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — lane_gate_or_exit exits 0 when flags/all-off or
# flags/lane-off-mergify-sync (or a pause_flags row driving either) is set.
# Fails OPEN. Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off mergify-sync.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit mergify-sync
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    mergify-sync
HERE="$(cd "$(dirname "$0")" && pwd)"
HARNESS_ROOT="$(cd "$HERE/.." && pwd)"
TPL="${MERGIFY_TEMPLATE_BIN:-$HARNESS_ROOT/bin/mergify-template.sh}"
CONFS="$H/config/mergify/repos"
LOG="$H/logs/mergify-sync.log"
ALERTS="$H/logs/ALERTS.log"
MARKS="$H/state/mergify-sync"
TITLE="Sync .mergify.yml from the harness template"
NOTE="max_parallel_checks multiplies CI runner minutes; it is capped at 8 (docs/CI-RUNNERS.md; bin/mergify-template.sh has the ceiling)."
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# shellcheck source=bin/lib/gh-rest.sh
[ -r "$HERE/lib/gh-rest.sh" ] && . "$HERE/lib/gh-rest.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$HERE/lib/gh-repo-token.sh" ] && . "$HERE/lib/gh-repo-token.sh" 2>/dev/null

usage() { echo "usage: mergify-sync.sh [check|apply] [owner/repo…]" >&2; exit 2; }
MODE=check
case "${1:-}" in
  check|apply) MODE="$1"; shift ;;
  ''|*/*) ;;
  *) usage ;;
esac
mkdir -p "$H/logs" 2>/dev/null
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mergify-sync.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# PARSED, NEVER SOURCED: the first `key=` line, value trimmed.
conf_get() { sed -n "/^[[:space:]]*$1[[:space:]]*=/{s/^[^=]*=[[:space:]]*//;s/[[:space:]]*\$//;p;q;}" "$2"; }

# gh_rest as a plain command into a file, so GH_REST_STATUS/REASON stay in this shell.
rest() { RC=0; gh_rest "$2" "$3" "${@:4}" > "$1" || RC=$?; }
why() {
  if [ "$RC" = 75 ] && [ "${GH_REST_REASON:-}" = rate-limit ]; then echo rate-limited
  else echo "http ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}"; fi
}

classify() { # classify <slug> <conf> -> OUT, DEF; leaves $TMP/live.yml and $TMP/diff
  local slug="$1" conf="$2" ov reason rc
  OUT=""; DEF=""; rm -f "$TMP"/*
  ov=$(conf_get override "$conf")
  if [ -n "$ov" ]; then OUT="OVERRIDE $ov"; return; fi
  if ! command -v gh_rest >/dev/null 2>&1; then OUT="UNREADABLE no gh-rest lib"; return; fi
  if ! command -v gh_repo_use_token >/dev/null 2>&1 || ! gh_repo_use_token "$slug"; then OUT="UNREADABLE no token"; return; fi
  rest "$TMP/repo.json" GET "repos/$slug"
  if [ "$RC" != 0 ]; then OUT="UNREADABLE $(why)"; return; fi
  DEF=$(jq -er '.default_branch | select(type=="string" and . != "")' "$TMP/repo.json" 2>/dev/null) \
    || { OUT="UNREADABLE no default branch"; return; }
  rest "$TMP/live.json" GET "repos/$slug/contents/.mergify.yml?ref=$DEF"
  if [ "$RC" = 44 ]; then OUT=MISSING; return; fi
  if [ "$RC" != 0 ]; then OUT="UNREADABLE $(why)"; return; fi
  if ! jq -er '.content' "$TMP/live.json" 2>/dev/null | base64 -d > "$TMP/live.yml" 2>/dev/null \
     || [ ! -s "$TMP/live.yml" ]; then OUT="UNREADABLE undecodable"; return; fi
  if reason=$("$TPL" marker "$TMP/live.yml" 2>/dev/null); then OUT="OVERRIDE ${reason:-marker}"; return; fi
  rc=0; "$TPL" compare "$conf" "$TMP/live.yml" > "$TMP/diff" 2>/dev/null || rc=$?
  case "$rc" in
    0) OUT=IN_SYNC ;;
    1) OUT=DRIFT ;;
    3) OUT="UNREADABLE cannot-compare" ;;
    *) OUT="UNREADABLE comparator rc $rc" ;;
  esac
}

alert_once() { # alert_once <slug> — check mode only
  local slug="$1" m line d
  m="$MARKS/${slug//\//_}.$(date -u +%Y%m%d)"
  [ -e "$m" ] && return 0
  case "$OUT" in
    DRIFT)
      d=$(awk '/^[+-]/ && !/^(\+\+\+|---)/ {printf "%s%s", (n++ ? "; " : ""), $0; if (n == 3) exit}' "$TMP/diff" 2>/dev/null | cut -c1-300)
      line="DRIFT: ${d:-live file differs from the template render}; fix: bin/mergify-sync.sh apply $slug" ;;
    MISSING) line="MISSING: no .mergify.yml on $DEF; apply never creates one, onboard per docs/MERGIFY.md §1" ;;
    *) line="$OUT; re-run bin/mergify-sync.sh check once it clears" ;;
  esac
  if printf '%s [mergify-sync] %s %s\n' "$(STAMP)" "$slug" "$line" 2>/dev/null >> "$ALERTS"; then
    mkdir -p "$MARKS" 2>/dev/null && : > "$m"
  fi
}

# The only branch apply ever writes: harness-owned and never the default.
guard_branch() { case "$1" in harness/mergify-sync-?*) [ "$1" != "$DEF" ] ;; *) return 1 ;; esac; }

apply_one() { # apply_one <slug> <conf> — OUT is DRIFT on entry
  local slug="$1" conf="$2" rc br head st bsha url
  rc=0; "$TPL" render "$conf" > "$TMP/rendered.yml" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then OUT="PR_FAILED render rc $rc"; return; fi
  if [ ! -s "$TMP/rendered.yml" ]; then OUT="PR_FAILED render empty"; return; fi
  br="harness/mergify-sync-$(sha256sum "$TMP/rendered.yml" | cut -c1-8)"
  guard_branch "$br" || { OUT="PR_FAILED unsafe branch $br"; return; }
  rest "$TMP/open.json" GET "repos/$slug/pulls?state=open&head=${slug%%/*}:$br"
  if [ "$RC" != 0 ]; then OUT="UNREADABLE $(why)"; return; fi
  jq -e 'type == "array"' "$TMP/open.json" >/dev/null 2>&1 || { OUT="UNREADABLE open-pr list not a list"; return; }
  url=$(jq -r '.[0].html_url // empty' "$TMP/open.json")
  if [ -n "$url" ]; then OUT="PR_OPEN $url"; return; fi
  rest "$TMP/head.json" GET "repos/$slug/git/ref/heads/$DEF"
  if [ "$RC" != 0 ] || ! head=$(jq -er '.object.sha' "$TMP/head.json" 2>/dev/null); then
    OUT="PR_FAILED head $(why)"; return; fi
  jq -nc --arg r "refs/heads/$br" --arg s "$head" '{ref:$r, sha:$s}' > "$TMP/ref.in"
  rest "$TMP/ref.out" POST "repos/$slug/git/refs" --input "$TMP/ref.in"
  if [ "$RC" != 0 ]; then
    # gh_rest drops non-2xx bodies, so "already exists" is proven by reading the ref back.
    st="${GH_REST_STATUS:-000}"
    [ "$st" = 422 ] && rest "$TMP/ref2.json" GET "repos/$slug/git/ref/heads/$br"
    if [ "$st" != 422 ] || [ "$RC" != 0 ]; then OUT="PR_FAILED ref $st"; return; fi
  fi
  rest "$TMP/blob.json" GET "repos/$slug/contents/.mergify.yml?ref=$br"
  if [ "$RC" != 0 ] || ! bsha=$(jq -er '.sha' "$TMP/blob.json" 2>/dev/null); then
    OUT="PR_FAILED contents-read $(why)"; return; fi
  jq -nc --arg m "$TITLE" --arg c "$(base64 -w0 < "$TMP/rendered.yml")" --arg s "$bsha" --arg b "$br" \
    '{message:$m, content:$c, sha:$s, branch:$b}' > "$TMP/put.in"
  rest "$TMP/put.out" PUT "repos/$slug/contents/.mergify.yml" --input "$TMP/put.in"
  if [ "$RC" != 0 ]; then OUT="PR_FAILED contents $(why)"; return; fi
  { printf 'The live `.mergify.yml` on `%s` differs from what `bin/mergify-template.sh render` makes of this repo'"'"'s conf in cromford. This PR sets it to the render.\n\n```diff\n' "$DEF"
    cat "$TMP/diff"; printf '```\n\n%s\n\nOpened by bin/mergify-sync.sh apply. It never merges.\n' "$NOTE"; } > "$TMP/body.md"
  # >>> pr trailers (BH-3987)
  [ -r "${H:-}/bin/lib/pr-trailers.sh" ] && . "$H/bin/lib/pr-trailers.sh"
  if command -v pr_trailers_apply >/dev/null 2>&1; then
    pr_trailers_apply "$TMP/body.md" lane:mergify-sync none \
      || printf '%s %s pr trailers: could not write %s — PR opened without trailers\n' "$(STAMP)" "$slug" "$TMP/body.md" >> "$LOG" 2>/dev/null
  fi
  jq -nc --arg t "$TITLE" --arg h "$br" --arg b "$DEF" --rawfile body "$TMP/body.md" \
    '{title:$t, head:$h, base:$b, body:$body}' > "$TMP/pr.in"
  rest "$TMP/pr.out" POST "repos/$slug/pulls" --input "$TMP/pr.in"
  # <<< pr trailers
  if [ "$RC" = 0 ] && url=$(jq -er '.html_url | select(type == "string" and startswith("https://"))' "$TMP/pr.out" 2>/dev/null); then
    OUT="PR_CREATED $url"
  else
    OUT="PR_FAILED pulls $(why)$( [ "$RC" = 0 ] && echo ' no html_url')"
  fi
}

FAIL=0
report() { # report <slug>
  printf '%s %s\n' "$1" "$OUT"
  printf '%s %s %s\n' "$(STAMP)" "$1" "$OUT" >> "$LOG" 2>/dev/null
  case "$MODE:$OUT" in
    *:IN_SYNC|*:OVERRIDE*|apply:PR_OPEN*|apply:PR_CREATED*) ;;
    *) FAIL=1 ;;
  esac
}

shopt -s nullglob
confs=("$CONFS"/*.conf)
if [ "${#confs[@]}" -eq 0 ] && [ $# -eq 0 ]; then
  printf '%s %s no confs under %s\n' "$(STAMP)" "$MODE" "$CONFS" >> "$LOG" 2>/dev/null
  exit 0
fi
declare -A want=() done_=()
for s in "$@"; do want[$s]=1; done
for conf in "${confs[@]}"; do
  slug=$(conf_get slug "$conf")
  if [ -z "$slug" ]; then
    [ $# -gt 0 ] && continue
    OUT="UNREADABLE bad conf $(basename "$conf")"
    [ "$MODE" = check ] && alert_once "$(basename "$conf")"
    report "$(basename "$conf")"; continue
  fi
  [ $# -gt 0 ] && [ -z "${want[$slug]:-}" ] && continue
  done_[$slug]=1
  classify "$slug" "$conf"
  if [ "$MODE" = apply ]; then
    [ "$OUT" = DRIFT ] && apply_one "$slug" "$conf"
  else
    case "$OUT" in DRIFT|MISSING|UNREADABLE*) alert_once "$slug" ;; esac
  fi
  report "$slug"
done
for s in "$@"; do
  [ -n "${done_[$s]:-}" ] || { OUT="UNREADABLE no conf"; report "$s"; }
done
exit "$FAIL"
