#!/bin/bash
# bin/lib/mc-ci-timeout-scan.sh — the SCAN step of the BH-3775 ci-timeout
# contract (BH-3785). Sourced by bin/lib/mc-ci-timeout.sh when readable; its
# cit_scan replaces the contract's fail-open stub. Never executed.
#
# For each run on the flake list the ladder is about to act on, it reads the
# run's dead jobs (cancelled / timed_out) and the workflow YAML at the PR head,
# and classifies every dead job: TIMEOUT when it ran to its own
# `timeout-minutes` (within MC_CI_TIMEOUT_SLACK_S), else FLAKE. Each classified
# job is one line in the contract's ledger (cit_ledger_put). A completed run's
# jobs never change, so a run already in the ledger is served from it and costs
# no REST read at all.
#
# EVERY READ FAILURE FAILS OPEN. A runs, jobs or contents read that answers
# non-0 (404, 5xx, 75 rate-limited) writes nothing, adds nothing to
# CIT_TIMEOUTS and is retried next tick. A failed read is never written down as
# FLAKE, because that would cement a transient error.
#
# Knobs are the contract's, already normalized when it was sourced. This file
# adds none.

# cit_classify <duration_s> <timeout_min> [slack_s] -> TIMEOUT | FLAKE, rc 0.
#   An empty or non-integer duration (incl. `-` and negatives) is FLAKE. An
#   empty or non-integer timeout (incl. `${{ … }}`) is MC_CI_TIMEOUT_DEFAULT_MIN.
cit_classify() {
  local d="${1:-}" t s="${3:-}"
  t=$(_cit_eff_t "${2:-}")
  if [ "${MC_CI_TIMEOUT:-}" != 1 ] || [ -z "$t" ]; then echo FLAKE; return 0; fi
  case "$d" in ''|*[!0-9]*) echo FLAKE; return 0 ;; esac
  [ "${#d}" -le 9 ] || { echo FLAKE; return 0; }
  case "$s" in ''|*[!0-9]*) s="${MC_CI_TIMEOUT_SLACK_S:-}" ;; esac
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  [ "${#s}" -le 9 ] || s=0
  if [ $((10#$d)) -ge $((10#$t * 60 - 10#$s)) ]; then echo TIMEOUT; else echo FLAKE; fi
  return 0
}

# _cit_eff_t <timeout_min> -> the limit the classifier uses: the value when it
#   is an integer, else MC_CI_TIMEOUT_DEFAULT_MIN; empty when neither is.
_cit_eff_t() {
  local t="${1:-}"
  case "$t" in ''|*[!0-9]*) t="${MC_CI_TIMEOUT_DEFAULT_MIN:-}" ;; esac
  case "$t" in ''|*[!0-9]*) return 0 ;; esac
  [ "${#t}" -le 9 ] || return 0
  printf '%s' "$((10#$t))"
}

# cit_job_timeout <yaml-text> <check-name> -> the job's own `timeout-minutes`,
#   or nothing. The job whose `name:` equals the check wins, else the job whose
#   key does. Only a direct child of the job counts, never a step's. The job-key
#   indent is read off the first indented line under `jobs:`. mawk-safe: no
#   gawk match(s, re, arr), gensub or IGNORECASE.
cit_job_timeout() {
  printf '%s\n' "${1:-}" | CIT_JT_CHECK="${2:-}" "${CIT_AWK:-awk}" '
    function ind(s) { match(s, /^ */); return RLENGTH }
    function val(s,   q, e) {
      sub(/^[^:]*:[ \t]*/, "", s)
      q = substr(s, 1, 1)
      if (q == "\"" || q == "'\''") {
        e = index(substr(s, 2), q)
        return e ? substr(s, 2, e - 1) : substr(s, 2)
      }
      sub(/[ \t]+#.*$/, "", s); sub(/[ \t]+$/, "", s)
      return s
    }
    { sub(/\r$/, "") }
    /^[ \t]*$/ || /^[ \t]*#/ { next }
    /^jobs:[ \t]*(#.*)?$/ { inj = 1; ji = -1; next }
    !inj { next }
    {
      i = ind($0)
      if (i == 0) { inj = 0; next }
      if (ji < 0) ji = i
      if (i < ji) { next }
      if (i == ji) {
        if ($0 ~ /^ *[A-Za-z0-9_-]+:/) { k = $0; sub(/^ */, "", k); sub(/:.*/, "", k); n++; key[n] = k; ci = -1 }
        next
      }
      if (!n) next
      if (ci < 0) ci = i
      if (i != ci) next
      if ($0 ~ /^ *name:/) nm[n] = val($0)
      else if ($0 ~ /^ *timeout-minutes:/) to[n] = val($0)
    }
    END {
      c = ENVIRON["CIT_JT_CHECK"]
      for (j = 1; j <= n; j++) if ((j in nm) && nm[j] == c) { print to[j]; exit }
      for (j = 1; j <= n; j++) if (key[j] == c) { print to[j]; exit }
    }'
}

# cit_flake_meta <slug> <sha> -> "<run-id>\t<workflow name>\t<path>\t<run_started_at>"
#   for the same latest-per-workflow cancelled/timed_out set as mc_ci_flake_runs
#   (bin/lib/mc/classify.sh), whose jq reduction this copies. Fails quiet:
#   nothing printed, rc 0.
cit_flake_meta() {
  local slug="${1:-}" sha="${2:-}" runs
  command -v mc_rest_var >/dev/null 2>&1 || return 0
  mc_rest_var runs gh_rest GET "repos/$slug/actions/runs?head_sha=$sha&per_page=50" || return 0
  runs=$(jq -r '[.workflow_runs[]? | {i: ((.id // "") | tostring),
                              n: ((.name // .workflow_id // "?") | tostring),
                              t: ((.run_started_at // .created_at) // ""),
                              a: (.run_attempt // 1),
                              s: (.status // ""), c: (.conclusion // ""),
                              p: (.path // ""),
                              r: (.run_started_at // .created_at // "")}]
        | group_by(.n) | map(sort_by(.t, .a) | last)
        | .[] | select(.s == "completed" and (.c == "cancelled" or .c == "timed_out"))
        | "\(.i)\t\(.n)\t\(.p)\t\(.r)"' <<<"$runs" 2>/dev/null) || return 0
  [ -n "$runs" ] && printf '%s\n' "$runs"
  return 0
}

# cit_run_jobs <slug> <run-id> -> "<job name>\t<conclusion>\t<duration_s>" per
#   job that ended cancelled/timed_out; `-` for the duration when a timestamp is
#   missing. rc 1 when the read (or its parse) failed, so the caller can tell
#   that apart from "no dead jobs". ONE page of 100: a run with more jobs is
#   classified on its first 100.
cit_run_jobs() {
  local slug="${1:-}" id="${2:-}" j
  command -v mc_rest_var >/dev/null 2>&1 || return 1
  mc_rest_var j gh_rest GET "repos/$slug/actions/runs/$id/jobs?per_page=100" || return 1
  j=$(jq -r '.jobs[]? | select(.conclusion == "cancelled" or .conclusion == "timed_out")
      | [((.name // "?") | tostring | gsub("[\t\n\r]"; " ")), .conclusion,
         (if (.started_at | type) == "string" and (.completed_at | type) == "string"
          then (try (((.completed_at | sub("\\.[0-9]+"; "") | fromdateiso8601)
                    - (.started_at | sub("\\.[0-9]+"; "") | fromdateiso8601)) | tostring) catch "-")
          else "-" end)] | join("\t")' <<<"$j" 2>/dev/null) || return 1
  [ -n "$j" ] && printf '%s\n' "$j"
  return 0
}

# cit_wf_yaml <slug> <path> <sha> -> the workflow YAML at that sha (the PR head:
#   the workflow that ran is the one in that tree). Cached on disk under
#   $MC_STATE_DIR/ci-timeout/yaml/, keyed on the immutable (slug, path, sha) and
#   written tmp+mv; no MC_STATE_DIR reads uncached. rc 1 on a failed or empty
#   read, which is never cached.
cit_wf_yaml() {
  local slug="${1:-}" path="${2:-}" sha="${3:-}" cache="" c y
  if [ -n "${MC_STATE_DIR:-}" ]; then
    cache="$MC_STATE_DIR/ci-timeout/yaml/$(printf '%s' "$slug" | tr -c 'A-Za-z0-9._-' '_')-$(printf '%s' "$path" | tr -c 'A-Za-z0-9._-' '_')-$(printf '%s' "$sha" | tr -c 'A-Za-z0-9._-' '_')"
    if [ -s "$cache" ]; then cat "$cache"; return 0; fi
  fi
  command -v mc_rest_var >/dev/null 2>&1 || return 1
  mc_rest_var c gh_rest GET "repos/$slug/contents/$path?ref=$sha" || return 1
  c=$(jq -r '.content // empty' <<<"$c" 2>/dev/null) || return 1
  [ -n "$c" ] || return 1
  # Same fallback as mc_queue_mergify_enabled: decode when it decodes, else the
  # text is the YAML itself.
  y=$(printf '%s' "$c" | tr -d '\n\r ' | base64 -d 2>/dev/null) || y=""
  [ -n "$y" ] || y="$c"
  if [ -n "$cache" ] && mkdir -p "${cache%/*}" 2>/dev/null; then
    printf '%s\n' "$y" > "$cache.tmp.$$" 2>/dev/null && mv -f "$cache.tmp.$$" "$cache" 2>/dev/null
    rm -f "$cache.tmp.$$" 2>/dev/null
  fi
  printf '%s\n' "$y"
}

# _cit_ledger_lines <slug> <run-id> -> the ledger lines for that run, read under
#   a shared flock.
_cit_ledger_lines() {
  [ -n "${CIT_LEDGER:-}" ] && [ -r "$CIT_LEDGER" ] || return 0
  ( flock -s 9 || exit 0
    awk -F'\t' -v s="$1" -v r="$2" '$2 == s && $6 == r' "$CIT_LEDGER"
  ) 9>>"$CIT_LEDGER.lock" 2>/dev/null
}

# cit_scan <slug> <key> <head> <base> <num> <flake-runs> — call it as a plain
#   command: it sets CIT_TIMEOUTS (run_id<TAB>check<TAB>wfpath<TAB>T<TAB>
#   run_started_at per TIMEOUT dead job) and CIT_CHECK/CIT_WF/CIT_T from the
#   first. The run ids come from <flake-runs> (id|name lines), the list the
#   ladder acts on. Always rc 0.
cit_scan() {
  local slug="${1:-}" key="${2:-}" head="${3:-}" runs="${6:-}"
  local id rest lines todo="" meta="" m path started jobs yaml name dur t cls out=""
  [ -n "$slug" ] && [ -n "$runs" ] && [ -n "${CIT_LEDGER:-}" ] || return 0
  while IFS='|' read -r id rest; do
    case "$id" in ''|*[!0-9]*) continue ;; esac
    lines=$(_cit_ledger_lines "$slug" "$id")
    if [ -n "$lines" ]; then
      lines=$(awk -F'\t' '$9 == "TIMEOUT" && !seen[$3]++ { printf "%s\t%s\t%s\t%s\t%s\n", $6, $3, $10, $8, $11 }' <<<"$lines")
      [ -n "$lines" ] && out+="$lines"$'\n'
    else
      todo+="$id"$'\n'
    fi
  done <<<"$runs"
  if [ -n "$todo" ] && command -v mc_now >/dev/null 2>&1; then
    meta=$(cit_flake_meta "$slug" "$head")
    while read -r id; do
      [ -n "$id" ] || continue
      # Tab is whitespace to `read`, so an empty field would shift the rest:
      # fields are cut by awk and by expansion, never by IFS.
      m=$(awk -F'\t' -v r="$id" '$1 == r { print $3 "\t" $4; exit }' <<<"$meta")
      path=${m%%$'\t'*}; started=${m#*$'\t'}
      [ -n "$path" ] || continue
      jobs=$(cit_run_jobs "$slug" "$id") || continue
      [ -n "$jobs" ] || continue
      yaml=$(cit_wf_yaml "$slug" "$path" "$head") || continue
      while IFS= read -r m; do
        [ -n "$m" ] || continue
        name=${m%%$'\t'*}; dur=${m##*$'\t'}
        t=$(_cit_eff_t "$(cit_job_timeout "$yaml" "$name")")
        cls=$(cit_classify "$dur" "$t")
        cit_ledger_put "$(mc_now)" "$slug" "$name" "$key" "$head" "$id" "$dur" "$t" "$cls" "$path" "$started" || true
        [ "$cls" = TIMEOUT ] && out+="$id"$'\t'"$name"$'\t'"$path"$'\t'"$t"$'\t'"$started"$'\n'
      done <<<"$jobs"
    done <<<"$todo"
  fi
  CIT_TIMEOUTS=${out%$'\n'}
  if [ -n "$CIT_TIMEOUTS" ]; then
    m=${CIT_TIMEOUTS%%$'\n'*}; m=${m#*$'\t'}
    CIT_CHECK=${m%%$'\t'*}; m=${m#*$'\t'}
    CIT_WF=${m%%$'\t'*}; m=${m#*$'\t'}
    CIT_T=${m%%$'\t'*}
  fi
  return 0
}
