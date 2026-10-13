#!/bin/bash
# bin/lib/context-pack-compose.sh — composes one split child's context pack
# (BH-3478.2). Sourced, never run. bin/run-decompose.sh calls it once per child
# after the children are filed, and publishes the result through cp_put
# (bin/lib/context-pack.sh). No model call, no network, no clock: the same
# inputs give the same bytes.
#
#   cp_compose <parent-plan.md> <parent-planned-files> <child-body-file-or-empty> \
#              <child-key> <parent-key> <n> <N>
#     Prints the pack as markdown, in a fixed order: the header, `## Child scope`
#     (the child's spec body, or `read the ticket thread` on the board lane),
#     `## Parent file inventory` (bin/planned-files.sh's list, filtered to the
#     paths the body names), then the parent plan's System invariants,
#     ASSUMPTIONS, Files to touch, Edge cases and Regression sections, verbatim.
#     `Sibling claims` is never copied, at any heading level.
#     rc 0 printed the pack / 1 bad args or an unreadable plan / 3 still over
#     CP_MAX_BYTES (default 64000, the wire's 413 limit) after dropping
#     Regression, Edge cases, Files to touch and ASSUMPTIONS in that order.
#     rc 1 and rc 3 print nothing.
#
# No root is read at all, so there is no ${HARNESS} default here (D43).

# _cpc_sections <plan> <class> — every `##` section whose heading, lowercased,
# starts with <class>, in plan order, headings included. A section runs to the
# next `#`/`##` heading outside a ``` / ~~~ fence; `###` and deeper stay inside
# it, except a heading at ANY level starting `sibling claims`, which ends the
# copy so a nested claims list never reaches a child.
_cpc_sections() {
  awk -v cls="$2" '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; if (on) print; next }
    !fence && /^#+[[:space:]]/ {
      lvl = match($0, /[^#]/) - 1
      t = tolower($0); sub(/^#+[[:space:]]+/, "", t)
      if (index(t, "sibling claims") == 1) { on = 0; next }
      if (lvl <= 2) on = (lvl == 2 && index(t, cls) == 1)
    }
    on { print }
  ' "$1" 2>/dev/null
}

# _cpc_emit <dropped> — the pack with the first <dropped> classes of the drop
# order (Regression, Edge cases, Files to touch, ASSUMPTIONS) replaced by an
# `omitted:` line. Reads cp_compose's locals.
_cpc_emit() {
  local d="$1" i name sec
  printf '# Context pack: %s (%s of %s), split from %s\n' "$_c_child" "$_c_n" "$_c_total" "$_c_parent"
  printf "Deterministic extract of %s's plan written at decompose time. No timestamp.\n" "$_c_parent"
  printf '\n## Child scope\n%s\n' "$_c_scope"
  printf '\n## Parent file inventory\n%s\n' "$_c_inv"
  # Output order is fixed; i is each class's position in the DROP order.
  for i in 4 3 2 1 0; do
    case "$i" in
      4) name="System invariants"; sec="$_c_s4" ;;
      3) name="ASSUMPTIONS";       sec="$_c_s3" ;;
      2) name="Files to touch";    sec="$_c_s2" ;;
      1) name="Edge cases";        sec="$_c_s1" ;;
      0) name="Regression";        sec="$_c_s0" ;;
    esac
    [ -n "$sec" ] || continue
    if [ "$i" -lt 4 ] && [ "$i" -lt "$d" ]; then
      printf '\nomitted: %s (pack cap)\n' "$name"
    else
      printf '\n%s\n' "$sec"
    fi
  done
}

cp_compose() {
  local plan="${1:-}" pf="${2:-}" bodyf="${3:-}"
  local _c_child="${4:-}" _c_parent="${5:-}" _c_n="${6:-}" _c_total="${7:-}"
  local _c_scope _c_inv _c_s0 _c_s1 _c_s2 _c_s3 _c_s4 p k=0 m=0 all="" named="" d out cap
  [ -n "$plan" ] && [ -r "$plan" ] && [ -s "$plan" ] || return 1
  case "$_c_child" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$_c_parent" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$_c_n" in ""|*[!0-9]*) return 1 ;; esac
  case "$_c_total" in ""|*[!0-9]*) return 1 ;; esac
  cap="${CP_MAX_BYTES:-64000}"
  case "$cap" in ""|*[!0-9]*) cap=64000 ;; esac

  if [ -n "$bodyf" ] && [ -r "$bodyf" ] && [ -s "$bodyf" ]; then
    _c_scope=$(cat "$bodyf")
  else
    bodyf=""; _c_scope="read the ticket thread"
  fi

  if [ -n "$pf" ] && [ -r "$pf" ]; then
    while IFS= read -r p || [ -n "$p" ]; do
      [ -n "$p" ] || continue
      m=$((m + 1)); all="$all$p"$'\n'
      if [ -n "$bodyf" ] && grep -qF -- "$p" "$bodyf"; then
        k=$((k + 1)); named="$named$p"$'\n'
      fi
    done < "$pf"
  fi
  if [ "$m" -eq 0 ]; then
    _c_inv="unfiltered (0 paths)"
  elif [ "$k" -ge 1 ]; then
    _c_inv="${named}filtered: $k of $m"
  else
    _c_inv="${all}unfiltered"
  fi

  _c_s4=$(_cpc_sections "$plan" "system invariants")
  _c_s3=$(_cpc_sections "$plan" "assumptions")
  _c_s2=$(_cpc_sections "$plan" "files to touch")
  _c_s1=$(_cpc_sections "$plan" "edge cases")
  _c_s0=$(_cpc_sections "$plan" "regression")

  for d in 0 1 2 3 4; do
    out=$(_cpc_emit "$d")
    if [ "$(printf '%s\n' "$out" | LC_ALL=C wc -c | tr -d ' ')" -le "$cap" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  done
  return 3
}
