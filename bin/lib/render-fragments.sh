#!/bin/bash
# bin/lib/render-fragments.sh: the ONE spelling of what this repo renders from what, and of the exit
# codes every renderer answers with. The crontab, env-example and rules renderers and the freshness
# guardrail will source it as they land; nothing sources it yet, and nothing else may spell it twice.
# Sourced only, never executed: no `set -e`, no `exit`, nothing runs at source time. Results go to
# stdout, reasons to stderr; only rf_write_atomic writes, and only the temp file it is handed. Callers
# run under `set -euo pipefail` (bin/render-crontab.sh:48): no pipeline in here may fail on a happy path.
# Exit codes every renderer follows: 0 = rendered, or --check found no drift; 1 = --check found drift;
# 2 = cannot render (missing/empty fragment dir, bad arguments), and --check maps ANY render failure to
# 2, never to 0: a renderer that did not run never reports "no drift"; 3 = a fragment was refused, with
# file and line on stderr.
rf_fail() {
  printf 'render-fragments: %s\n' "$*" >&2
  return 3
}

# <rendered path or glob> TAB <input paths> TAB <render command>
rf_registry() {
  printf '%s\t%s\t%s\n' \
    'cron/*.cron' 'cron/lanes/ cron/boxes/ fleet.conf bin/lib/cron-lines.sh' 'bin/render-crontab.sh --from-fragments --all --write' \
    'env-templates/global.env.example' 'env-templates/lanes/' 'bin/render-env-example.sh --write' \
    'rules/CLAUDE.md' 'rules/topics/' 'bin/render-rules.sh --write' \
    'docs/PR-OWNERSHIP.md' 'docs/PR-OWNERSHIP.d/' 'bin/render-doc-sections.sh --write'
}

# Prints <dir>/<name> per match in LC_ALL=C order, <dir> exactly as passed. Every match is CR-scanned
# before any path is printed, so a refusal leaves stdout empty (a \r line is preserved AND regenerated, so the lane it defines would run twice forever).
rf_fragments() {
  local dir="${1:-}" glob="${2:-}" f n
  local -a found=()
  [ -n "$dir" ] && [ -n "$glob" ] || { printf 'render-fragments: rf_fragments needs <dir> <glob>\n' >&2; return 2; }
  [ -d "$dir" ] || { printf 'render-fragments: no fragment dir %s\n' "$dir" >&2; return 2; }
  # shellcheck disable=SC2086  # $glob is expanded here on purpose; -f drops a non-match
  for f in "$dir"/$glob; do [ -f "$f" ] || continue; found+=("$f"); done
  [ "${#found[@]}" -gt 0 ] || { printf 'render-fragments: no fragments matching %s in %s\n' "$glob" "$dir" >&2; return 2; }
  for f in "${found[@]}"; do
    # -a: a NUL or non-UTF-8 byte must not hide the CR. `|| n=`: a clean fragment is grep rc 1, which would abort an errexit caller.
    n=$(grep -a -n -m1 $'\r' -- "$f" | cut -d: -f1) || n=
    [ -z "$n" ] || { rf_fail "$f:$n: CR byte (CRLF) refused"; return 3; }
  done
  printf '%s\n' "${found[@]}" | LC_ALL=C sort
}

# Callers render to a temp file and hand it over, so a failed render never leaves a half-written committed file (across filesystems mv degrades to copy+unlink, still whole).
rf_write_atomic() {
  local dst="${1:-}" tmp="${2:-}"
  [ -n "$dst" ] && [ -f "$tmp" ] || { printf 'render-fragments: rf_write_atomic needs <dst> <existing-tmpfile>\n' >&2; return 2; }
  mkdir -p -- "$(dirname -- "$dst")" && mv -f -- "$tmp" "$dst"
}

# A missing committed file is drift (1), never an error: it diffs against /dev/null so the preview still
# shows what would land. `|| :` keeps the answer 1 under errexit + pipefail, where diff's rc 1 (or head's
# SIGPIPE on a long diff) would otherwise be the status.
rf_check() {
  local c="${1:-}" r="${2:-}" base=/dev/null
  [ -n "$c" ] && [ -f "$r" ] || { printf 'render-fragments: rf_check needs <committed-path> <rendered-tmp>\n' >&2; return 2; }
  if [ -f "$c" ]; then cmp -s -- "$c" "$r" && return 0; base=$c; fi
  printf 'DRIFT %s\n' "$c"
  diff -- "$base" "$r" | head -25 || :
  return 1
}
