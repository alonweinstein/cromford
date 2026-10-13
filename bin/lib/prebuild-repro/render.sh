# bin/lib/prebuild-repro/render.sh — the pre-build repro gate's two renderers
# (BH-2042, a child of #2004). Function-only: bin/run-build.sh and
# bin/prebuild-repro.sh source it. Both read $build/prebuild-repro.txt (written
# by pr_record) and $build/prebuild-repro.md (the drive detail) and print to
# stdout only. A missing record, or one with no known REPRO_GATE word, prints
# nothing, so the plan prompt and the PR body stay byte-identical. Format and
# the gate-to-output table: docs/repro-gate/render.md.
# shellcheck shell=bash

_PR_RENDER_CAP=2000   # REPRO_OBSERVED's documented limit (docs/repro-gate.md)
_PR_RENDER_URL_CAP=500   # REPRO_URL's limit in the PR body (BH-2123)

# _pr_render_gate <build> — the record's gate word, only if it is a known one.
_pr_render_gate() {
  local g
  g=$(sed -n 's/^REPRO_GATE:[[:space:]]*//p' "$1/prebuild-repro.txt" 2>/dev/null | head -1)
  g="${g%$'\r'}"; g="${g%"${g##*[![:space:]]}"}"
  case "$g" in skip|cannot-drive|reproduced|not-reproduced|already-fixed|stop) printf '%s' "$g" ;; esac
}

# _pr_render_reason <build> — REPRO_REASON with one trailing `.` dropped.
_pr_render_reason() {
  local r
  r=$(sed -n 's/^REPRO_REASON:[[:space:]]*//p' "$1/prebuild-repro.txt" 2>/dev/null | head -1)
  r="${r%$'\r'}"; r="${r%.}"
  [ -n "$r" ] && [ "$r" != - ] || r="no reason recorded"
  printf '%s' "$r"
}

# _pr_render_md <build> <KEY> — one field of the detail file. A `REPRO_<X>:`
# line starts a field; the lines after it, up to the next such line, continue
# it. CRs are dropped, so a CRLF file reads the same.
_pr_render_md() {
  awk -v k="$2" '{ sub(/\r$/, "") }
    /^REPRO_[A-Z_]+:/ { f = (index($0, k ":") == 1)
                        if (f) { v = substr($0, length(k) + 2); sub(/^[ \t]+/, "", v) }
                        next }
    f { v = v "\n" $0 }
    END { printf "%s", v }' "$1/prebuild-repro.md" 2>/dev/null
}

# _pr_render_cap <text> <n> — the text cut to n characters, marked if cut.
_pr_render_cap() {
  if [ "${#1}" -gt "$2" ]; then printf '%s [truncated]' "${1:0:$2}"; else printf '%s' "$1"; fi
}

# _pr_render_ticks <text> — one more than the text's longest backtick run.
_pr_render_ticks() {
  printf '%s' "$1" | grep -o '`\+' | awk '{ if (length($0) > m) m = length($0) } END { print m + 1 }'
}

# _pr_render_block <text> — the text in a code fence one backtick longer than
# its longest backtick run (at least three), so nothing in it can close the
# fence, open a heading or read as a closing keyword. Empty is `not recorded`.
_pr_render_block() {
  local v="$1" n f
  [ -n "$(printf '%s' "$v" | tr -d '[:space:]')" ] || v="not recorded"
  n=$(_pr_render_ticks "$v")
  [ "$n" -ge 3 ] || n=3
  f=$(printf '%*s' "$n" '' | tr ' ' '`')
  printf '%s\n%s\n%s' "$f" "$v" "$f"
}

# _pr_render_span <text> — the text in an inline code span one backtick longer
# than its longest backtick run, padded with one space inside each delimiter
# (CommonMark strips exactly that), so a keyword or @mention in it stays inert
# and a backtick at either end can not close the span.
_pr_render_span() {
  local f
  f=$(printf '%*s' "$(_pr_render_ticks "$1")" '' | tr ' ' '`')
  printf '%s %s %s' "$f" "$1" "$f"
}

# pr_brief_line <build> — the plan-prompt fragment. Only a `reproduced` record
# with a non-empty detail file prints; the file is folded to one line and
# capped at 2000 characters, marker included.
pr_brief_line() {
  local b="${1:-}" md
  [ "$(_pr_render_gate "$b")" = reproduced ] || return 0
  md=$( { tr '\r\n\t' '   ' < "$b/prebuild-repro.md"; } 2>/dev/null)
  md="${md#"${md%%[![:space:]]*}"}"; md="${md%"${md##*[![:space:]]}"}"
  [ -n "$md" ] || return 0
  [ "${#md}" -le "$_PR_RENDER_CAP" ] || md="${md:0:$((_PR_RENDER_CAP - 12))} [truncated]"
  printf " THIS BUG WAS REPRODUCED ON PROD BEFORE THE BUILD. Use these steps and this observed result as the fix's acceptance check and put them in the plan's ## Reproduction: %s" "$md"
}

# pr_pr_section <build> — the PR-body markdown. It starts with a blank line so
# it never folds into the paragraph above it in PR_BODY_FOR.
pr_pr_section() {
  local b="${1:-}" g url steps obs
  g=$(_pr_render_gate "$b")
  case "$g" in
    reproduced)
      printf '\n\n## Reproduced on prod before build\n\n'
      if [ -z "$( { tr -d '[:space:]' < "$b/prebuild-repro.md"; } 2>/dev/null)" ]; then
        printf 'The drive recorded a reproduction but its detail file (prebuild-repro.md) is missing, so no steps are shown.'
        return 0
      fi
      url=$(_pr_render_md "$b" REPRO_URL | tr '\n\t' '  ')
      url="${url#"${url%%[![:space:]]*}"}"; url="${url%"${url##*[![:space:]]}"}"
      if [ -z "$url" ]; then url="not recorded"
      elif [ "${#url}" -gt "$_PR_RENDER_URL_CAP" ]; then url="$(_pr_render_span "${url:0:$_PR_RENDER_URL_CAP}") [truncated]"
      else url=$(_pr_render_span "$url"); fi
      steps=$(_pr_render_cap "$(_pr_render_md "$b" REPRO_STEPS)" "$_PR_RENDER_CAP")
      obs=$(_pr_render_cap "$(_pr_render_md "$b" REPRO_OBSERVED)" "$_PR_RENDER_CAP")
      printf 'URL: %s\n\nSteps:\n%s\n\nObserved:\n%s' "$url" \
        "$(_pr_render_block "$steps")" "$(_pr_render_block "$obs")" ;;
    cannot-drive|not-reproduced|already-fixed|stop)
      printf '\n\nNot reproduced before build: %s.' "$(_pr_render_reason "$b")" ;;
    skip)
      case "$(_pr_render_reason "$b")" in not-bug|knob-off) return 0 ;; esac
      printf '\n\nReproduction skipped: %s.' "$(_pr_render_reason "$b")" ;;
  esac
  return 0
}
