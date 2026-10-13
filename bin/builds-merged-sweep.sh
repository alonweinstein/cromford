#!/bin/bash
# bin/builds-merged-sweep.sh [--apply] [--rows-file F] [--project P] [--max-reads N]
#
# BH-3971: re-check every console `builds` row that says merged=1 against
# GitHub's merge fact (merged_at), and correct the rows whose PR was closed
# WITHOUT merging to stage `pr_closed`, merged=0.
#
# WHY. Before BH-866 (#881, 2026-09-21) bin/reconcile-prs.sh put CLOSED and
# MERGED PRs in the one `merged` list, so a closed-unmerged PR became a
# merged=1/pr_merged console row (project-3 TK-166, PR #331). Nothing ever looked
# at those rows again: /api/builds/unmerged offers merged=0 rows only. This is
# the one-time (and safely re-runnable) sweep that does. It is NOT a cron lane;
# an operator runs it on the hub, where env/cloudflare.env lives.
#
#   dry run (default) : reads and classifies, writes no beat and no ledger row.
#   --apply           : one BEAT_STRICT=1 build beat per keyed closed-unmerged
#                       row, then the jobs-ledger merge row is set `closed` when
#                       (and only when) it said `merged`.
#   --rows-file F     : a JSON array of builds rows replaces the D1 read.
#   --project P       : only rows of project P (a bound D1 param).
#   --max-reads N     : cap on single GitHub PR reads this run (default 300).
#
# Classes (bms_classify, the merge fact is merged_at and nothing else):
#   merged           merged_at non-empty          -> kept (remembered as proven)
#   closed_unmerged  state=closed, merged_at null -> corrected (keyed) | reported (keyless)
#   open             state=open, merged_at null   -> reported
#   unknown          anything else, 404, 44/75    -> skipped, NEVER corrected
#
# Writes: logs/builds-merged-sweep.log (one line per row + one summary line),
# state/builds-merged-sweep/run-<stamp>-<pid>.tsv (the per-run record),
# state/builds-merged-sweep/verified-merged.tsv (URLs proven merged; merged is
# final, so a re-run never reads them again), and at most one ALERTS line.
#
# The Cloudflare token is sourced inside a subshell and reaches curl on STDIN
# (`-H @-`), never argv, never a log.
#
# Exit: 0 the run finished (corrections or not), 1 the builds read failed,
# 2 bad arguments.
#
# gh-rest: no-graphql
set -uo pipefail

# bms_classify <pull-json> -> merged|closed_unmerged|open|unknown (pure, jq only).
# A `merged:true` with no merged_at is a contradiction and stays unknown; so is
# a bare `STATE:"MERGED"` (the GraphQL word without the fact).
bms_classify() {
  local c
  c=$(printf '%s' "${1:-}" | jq -r '
    if type != "object" then "unknown"
    else (.merged_at) as $m
      | if ($m | type) == "string" and $m != "" then "merged"
        elif ($m != null and $m != "") then "unknown"
        elif .merged == true then "unknown"
        elif .state == "closed" then "closed_unmerged"
        elif .state == "open" then "open"
        else "unknown" end
    end' 2>/dev/null) || c=""
  case "$c" in merged|closed_unmerged|open) printf '%s\n' "$c" ;; *) printf 'unknown\n' ;; esac
}

# bms_pr_url_ok <url> — rc 0 for https://github.com/<owner>/<repo>/pull/<n>
bms_pr_url_ok() {
  [[ "${1:-}" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$ ]]
}

[ "${BMS_LIB_ONLY:-}" = 1 ] && return 0 2>/dev/null

HARNESS="${HARNESS:-/root/harness}"
APPLY=0; ROWS_FILE=""; PROJECT=""; MAX_READS=300
usage() { echo "usage: builds-merged-sweep.sh [--apply] [--rows-file F] [--project P] [--max-reads N]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --rows-file) [ $# -ge 2 ] || usage; ROWS_FILE="$2"; shift 2 ;;
    --project) [ $# -ge 2 ] && [ -n "$2" ] || usage; PROJECT="$2"; shift 2 ;;
    --max-reads) [ $# -ge 2 ] || usage; MAX_READS="$2"; shift 2 ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    *) usage ;;
  esac
done
case "$MAX_READS" in ''|*[!0-9]*) echo "builds-merged-sweep: --max-reads needs a whole number, got '$MAX_READS'" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "builds-merged-sweep: jq missing" >&2; exit 2; }

LIB="$HARNESS/bin/lib"
# shellcheck source=bin/lib/env-path.sh
. "$LIB/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
# shellcheck source=bin/lib/gh-rest-list.sh
. "$LIB/gh-rest-list.sh" 2>/dev/null
command -v gh_rest_pr_list_all >/dev/null 2>&1 || { echo "builds-merged-sweep: bin/lib/gh-rest-list.sh missing" >&2; exit 2; }
# shellcheck source=bin/lib/console-pages.sh
. "$LIB/console-pages.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$LIB/gh-app-auth.sh" ] && . "$LIB/gh-app-auth.sh" 2>/dev/null
# shellcheck source=bin/jobs-client.sh
[ -r "$HARNESS/bin/jobs-client.sh" ] && [ -d "$HARNESS/bin/lib/jobs" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null

SDIR="$HARNESS/state/builds-merged-sweep"
LOG="$HARNESS/logs/builds-merged-sweep.log"
mkdir -p "$SDIR" "$HARNESS/logs" || { echo "builds-merged-sweep: cannot create $SDIR" >&2; exit 2; }
MEMO="$SDIR/verified-merged.tsv"; touch "$MEMO"
RUN_TSV="$SDIR/run-$(date -u +%Y%m%dT%H%M%SZ)-$$.tsv"
MODE=dry; [ "$APPLY" = 1 ] && MODE=apply
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bms.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { printf '%s %s\n' "$(stamp)" "$*" >> "$LOG"; }
alert() { # alert <id-suffix> <text>
  local id="$1"; shift
  "$HARNESS/bin/alert-line.sh" --severity warn --id "builds-merged-sweep-$id" "$*" >/dev/null 2>&1 || true; }

# ── read the merged=1 rows ──────────────────────────────────────────────────
ROWS="$WORK/rows.json"
if [ -n "$ROWS_FILE" ]; then
  # Not a JSON array is a bad argument: no reads, no writes (D11).
  jq -e 'type == "array"' "$ROWS_FILE" >/dev/null 2>&1 \
    || { echo "builds-merged-sweep: --rows-file $ROWS_FILE is not a JSON array" >&2; exit 2; }
  jq -c --arg p "$PROJECT" '[ .[] | select(type == "object")
      | select(.merged == 1 or .merged == true or .merged == "1")
      | select($p == "" or .project == $p) ]' "$ROWS_FILE" > "$ROWS" 2>/dev/null || exit 2
else
  CFENV="$(harness_env_dir "$HARNESS")/cloudflare.env"
  D1_ID="${CONSOLE_D1_ID:-00000000-0000-0000-0000-000000000001}"
  ACCT=$(console_pages_account_id "$HARNESS" 2>/dev/null) || ACCT=""
  read_fail() { # read_fail <http code> <why>
    alert read "[builds-merged-sweep] cannot read harness-console-db (HTTP $1): the hub's CLOUDFLARE_API_TOKEN needs D1 read on harness-console-db, or pass --rows-file${2:+ ($2)}"
    log "read failed (HTTP $1)${2:+ $2} - nothing checked, nothing corrected"
    exit 1
  }
  [ -n "$ACCT" ] || read_fail 000 "no Cloudflare account id"
  [ -r "$CFENV" ] || read_fail 000 "no $CFENV"
  SQL_P="SELECT id, bkey, project, ticket_key, stage, tier, verdict, pr_url, merged FROM builds WHERE merged = 1 AND id > ? AND project = ? ORDER BY id LIMIT 500"
  SQL_A="SELECT id, bkey, project, ticket_key, stage, tier, verdict, pr_url, merged FROM builds WHERE merged = 1 AND id > ? ORDER BY id LIMIT 500"
  : > "$WORK/rows.jsonl"
  CURSOR=0; PAGES=0
  while :; do
    PAGES=$((PAGES+1))
    # 400 pages x 500 rows is far past any console; a cursor that never ends is a bug, not data (D21).
    [ "$PAGES" -le 400 ] || read_fail 000 "cursor did not end after 400 pages"
    if [ -n "$PROJECT" ]; then
      jq -nc --arg s "$SQL_P" --arg c "$CURSOR" --arg p "$PROJECT" '{sql:$s, params:[($c|tonumber), $p]}' > "$WORK/q.json"
    else
      jq -nc --arg s "$SQL_A" --arg c "$CURSOR" '{sql:$s, params:[($c|tonumber)]}' > "$WORK/q.json"
    fi
    CODE=$( set -a; . "$CFENV" >/dev/null 2>&1; set +a
      [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { printf 'notoken'; exit 0; }
      printf 'Authorization: Bearer %s\n' "$CLOUDFLARE_API_TOKEN" \
        | curl -sS --max-time 30 -X POST -H @- -H 'Content-Type: application/json' \
            --data-binary "@$WORK/q.json" -o "$WORK/page.json" -w '%{http_code}' \
            "https://api.cloudflare.com/client/v4/accounts/$ACCT/d1/database/$D1_ID/query" 2>/dev/null
    ) || CODE="${CODE:-000}"
    [ "$CODE" = notoken ] && read_fail 000 "no CLOUDFLARE_API_TOKEN in $CFENV"
    case "$CODE" in 2??) ;; *) read_fail "${CODE:-000}" ;; esac
    jq -e '.success == true and ((.result[0].success // true) == true) and ((.result[0].results // null) | type == "array")' \
      "$WORK/page.json" >/dev/null 2>&1 || read_fail "$CODE" "success != true"
    N=$(jq '.result[0].results | length' "$WORK/page.json")
    [ "$N" -gt 0 ] || break
    LAST=$(jq -r '.result[0].results[-1].id' "$WORK/page.json")
    case "$LAST" in ''|*[!0-9]*) read_fail "$CODE" "a row with no numeric id" ;; esac
    [ "$LAST" -gt "$CURSOR" ] || read_fail "$CODE" "cursor did not advance"
    jq -c '.result[0].results[]' "$WORK/page.json" >> "$WORK/rows.jsonl" || read_fail "$CODE" "page unreadable"
    CURSOR="$LAST"
    [ "$N" -ge 500 ] || break
  done
  jq -c -s '.' "$WORK/rows.jsonl" > "$ROWS" || read_fail 000 "rows unreadable"
fi

# ── the merge fact per PR ───────────────────────────────────────────────────
# url|class|closed_at|why — '|' and not a tab: read's IFS collapses empty tab fields.
FACTS="$WORK/facts.psv"; : > "$FACTS"
READS=0; CAPPED=0
fact_put() { printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-}" "${4:-}" >> "$FACTS"; }
fact_get() { awk -F'|' -v u="$1" '$1 == u { r = $0 } END { if (r != "") print r }' "$FACTS"; }
bms_auth() {
  if command -v gh_default_auth_for_slug >/dev/null 2>&1; then gh_default_auth_for_slug "$1" >/dev/null 2>&1 || true; fi
}

jq -r '.[] | (.pr_url // "")' "$ROWS" | sort -u > "$WORK/urls"
PRS=0
while IFS= read -r u; do
  bms_pr_url_ok "$u" || continue
  PRS=$((PRS+1))
  if grep -qxF "$u" "$MEMO"; then fact_put "$u" merged "" memo; else printf '%s\n' "$u" >> "$WORK/todo"; fi
done < "$WORK/urls"

# One closed list per repo first (<= 10 pages), so most rows cost no single read.
if [ -s "$WORK/todo" ]; then
  sed -E 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#' "$WORK/todo" | sort -u > "$WORK/slugs"
  while IFS= read -r slug; do
    bms_auth "$slug"
    rc=0; gh_rest_pr_list_all "$slug" closed 1000 > "$WORK/list.json" || rc=$?
    if [ "$rc" != 0 ]; then
      log "prefetch $slug closed list unreadable (rc $rc, HTTP ${GH_REST_STATUS:-000}) - falling back to single reads"
      continue
    fi
    jq -c '.[] | select(type == "object" and (.html_url // "") != "")' "$WORK/list.json" 2>/dev/null > "$WORK/list.jsonl"
    while IFS= read -r pr; do
      pu=$(printf '%s' "$pr" | jq -r '.html_url')
      grep -qxF "$pu" "$WORK/todo" || continue
      fact_put "$pu" "$(bms_classify "$pr")" "$(printf '%s' "$pr" | jq -r '.closed_at // ""')" list
    done < "$WORK/list.jsonl"
  done < "$WORK/slugs"
  # Then one single read per PR the list did not answer, capped.
  while IFS= read -r u; do
    [ -n "$(fact_get "$u")" ] && continue
    if [ "$READS" -ge "$MAX_READS" ]; then CAPPED=$((CAPPED+1)); fact_put "$u" unknown "" capped; continue; fi
    READS=$((READS+1))
    slug=$(printf '%s' "$u" | sed -E 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#')
    bms_auth "$slug"
    rc=0; gh_rest GET "repos/$slug/pulls/${u##*/}" > "$WORK/pr.json" || rc=$?
    case "$rc" in
      0) b=$(cat "$WORK/pr.json"); fact_put "$u" "$(bms_classify "$b")" "$(printf '%s' "$b" | jq -r '.closed_at // ""' 2>/dev/null)" read ;;
      44) fact_put "$u" unknown "" 404 ;;
      *) fact_put "$u" unknown "" "rc$rc-http${GH_REST_STATUS:-000}" ;;
    esac
  done < "$WORK/todo"
fi

# Proven merges are remembered; merged is final.
awk -F'|' '$2 == "merged" && $4 != "memo" { print $1 }' "$FACTS" | while IFS= read -r u; do
  grep -qxF "$u" "$MEMO" || printf '%s\n' "$u" >> "$MEMO"
done

# ── act per row ─────────────────────────────────────────────────────────────
ledger_close() { # ledger_close <url> — only a ledger row that says merged is flipped
  local k st rc
  command -v job_ledger_get >/dev/null 2>&1 || { log "ledger $1 not checked: bin/jobs-client.sh not loaded"; return 0; }
  for k in merge pr_merged; do
    rc=0; st=$(job_ledger_get "$k" "$1") || rc=$?
    if [ "$rc" = 0 ] && [ "$st" = merged ]; then
      if job_ledger_put "$k" "$1" closed "BH-3971 sweep: closed unmerged"; then log "ledger $k $1 said merged, now closed"
      else log "ledger $k $1 still says merged: the put failed (re-run to retry)"; fi
    elif [ "$rc" = 1 ]; then log "ledger $k $1 unreadable - not changed"
    fi
  done
}

printf 'bkey\tproject\tticket_key\tpr_url\tclass\toutcome\tclosed_at\n' > "$RUN_TSV"
ROWS_N=0; N_MERGED=0; N_CU=0; N_CORR=0; N_WOULD=0; N_FAIL=0; N_OPEN=0; N_UNK=0; N_KEYLESS=0; N_NOURL=0
# One jq for every row: fields joined on \x1f (not a tab, which read collapses when empty).
while IFS=$'\x1f' read -r bkey url proj tk row; do
  ROWS_N=$((ROWS_N+1))
  cls=-; closed=""; why=""
  if ! bms_pr_url_ok "$url"; then
    out=skipped:no-url; N_NOURL=$((N_NOURL+1))
  else
    IFS='|' read -r _ cls closed why <<<"$(fact_get "$url")"
    [ -n "$cls" ] || { cls=unknown; why=noread; }
    case "$cls" in
      merged) out=kept; N_MERGED=$((N_MERGED+1)) ;;
      open) out=reported; N_OPEN=$((N_OPEN+1)) ;;
      closed_unmerged)
        N_CU=$((N_CU+1))
        if [ -z "$bkey" ]; then out=reported:keyless; N_KEYLESS=$((N_KEYLESS+1))
        elif [ "$APPLY" != 1 ]; then out="corrected(dry)"; N_WOULD=$((N_WOULD+1))
        else
          detail="BH-3971 sweep: GitHub says $url was closed without merging (closed ${closed:-unknown}, merged_at null); this row said merged"
          payload=$(jq -c --arg d "$detail" '{kind:"build", bkey, project, ticket_key, stage:"pr_closed",
              tier, verdict, pr_url, merged:false, detail:$d}' <<<"$row")
          brc=0; BEAT_STRICT=1 "$HARNESS/bin/beat.sh" "$payload" >/dev/null 2>&1 || brc=$?
          case "$brc" in
            0) out=corrected; N_CORR=$((N_CORR+1)); ledger_close "$url" ;;
            2) out=failed:no-console; N_FAIL=$((N_FAIL+1)) ;;
            *) out=failed; N_FAIL=$((N_FAIL+1)) ;;
          esac
        fi ;;
      *) cls=unknown; out="skipped:${why:-unknown}"; N_UNK=$((N_UNK+1)) ;;
    esac
  fi
  log "${bkey:-<no-bkey>} ${url:-<no-url>} $cls -> $out"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$bkey" "$proj" "$tk" "$url" "$cls" "$out" "$closed" >> "$RUN_TSV"
done < <(jq -r '.[] | [(.bkey // "" | tostring), (.pr_url // "" | tostring), (.project // "" | tostring),
                        (.ticket_key // "" | tostring), tojson] | join("\u001f")' "$ROWS")

SUMMARY="mode=$MODE rows=$ROWS_N prs=$PRS merged=$N_MERGED closed_unmerged=$N_CU corrected=$N_CORR would_correct=$N_WOULD failed=$N_FAIL open=$N_OPEN unknown=$N_UNK keyless=$N_KEYLESS no_url=$N_NOURL reads=$READS capped=$CAPPED"
[ "$CAPPED" -gt 0 ] && SUMMARY="$SUMMARY INCOMPLETE: --max-reads $MAX_READS hit, re-run to continue"
log "summary $SUMMARY tsv=$RUN_TSV"
echo "$SUMMARY"
echo "report: $RUN_TSV"
if [ $((N_OPEN + N_KEYLESS + N_FAIL)) -gt 0 ]; then
  alert report "[builds-merged-sweep] $MODE run: $((N_OPEN + N_KEYLESS + N_FAIL)) console row(s) say merged=1 but GitHub does not, and were not corrected (open=$N_OPEN keyless=$N_KEYLESS failed=$N_FAIL) - see $RUN_TSV"
fi
exit 0
