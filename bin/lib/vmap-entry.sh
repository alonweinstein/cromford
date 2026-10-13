#!/bin/bash
# bin/lib/vmap-entry.sh — read one verification-map entry, and find the entries
# a plan's screens need. Sourced, never executed. Pure functions, no
# network, safe under `set -u`. Every function returns 0.
#
# VMAP_LIES_HEADING  the text of the `**What usually lies:**` field in
#   docs/verification-map/TEMPLATE.md. The one place that text lives: the
#   renderer, the QA consumers and the draft lane key on this, never a literal.
#
# vmap_lies <entry.md>
#   Prints the bullet lines (`-` or `*`, plus indented continuation lines) under
#   `**What usually lies:**`, verbatim. The text on the heading line itself is
#   not printed. The field ends at the next `**Label:**` line or `#` heading.
#   Absent field, missing or unreadable file, no argument: prints nothing.
#
# vmap_plan_screens <plan.md>
#   Prints the routes in the plan's `## QA screens` section, one per line, with
#   the same extraction bin/postmerge-qa.sh's screens_for uses: app paths only,
#   system paths (/root, /tmp, /usr, /etc, /var, /home) dropped, sorted unique,
#   at most 5. Nothing when there is no file or no section; it never defaults
#   to `/`.
#
# vmap_entries_for <repo> <route...>
#   Prints the entry files, from both the `docs/verification-map/*.md` (minus
#   README.md and TEMPLATE.md) and the `docs/verification-map/entries/*.md`
#   layouts, whose Key routes contain one of the routes, as repo-relative paths,
#   sorted unique. An entry's routes are ONLY the backticked tokens starting
#   with `/` in its `**Key routes/screens:**` field (ended by the next
#   `**Label:**` line or `#` heading). Both sides drop `?query` / `#frag` and
#   one trailing `/`. Per-segment exact match; `[x]` matches exactly one
#   non-empty segment. No routes or no map: prints nothing.
#
# vmap_note <repo> <plan.md>
#   Prints exactly one of:
#     VERIFICATION MAP: <n> entr(y|ies) for this ticket's screens
#       followed by `--- <relpath> ---` and the content of the first 3 entries,
#       3000 content bytes in total (the last one shown is cut to fit). When
#       anything was dropped or cut the last line says so:
#       VERIFICATION MAP: truncated, showing <k> of <n> entries (cap 3 entries /
#       3000 bytes); not shown: <relpaths|none>[; cut short: <relpath>]
#     VERIFICATION MAP: no map entry for screens: /a /b (map has <m> entries)
#       (`(plan lists none)` stands in for the screens when the plan has none)
#     VERIFICATION MAP: none in this repo
VMAP_LIES_HEADING='What usually lies'

vmap_lies() {
  local f="${1:-}"
  { [ -n "$f" ] && [ -r "$f" ]; } || return 0
  awk -v h="**${VMAP_LIES_HEADING}:**" '
    index($0, h) == 1 { on = 1; blt = 0; next }
    !on { next }
    /^\*\*[^*]+:\*\*/ || /^#/ { on = 0; next }
    /^[[:space:]]*[-*][[:space:]]/ { print; blt = 1; next }
    /^[[:space:]]+[^[:space:]]/ && blt { print; next }
    { blt = 0 }
  ' "$f"
  return 0
}

vmap_plan_screens() {
  local f="${1:-}"
  { [ -n "$f" ] && [ -r "$f" ]; } || return 0
  sed -n '/^#\{1,6\}[[:space:]]*QA screens/I,/^#\{1,6\}[[:space:]]/p' "$f" 2>/dev/null \
    | grep -oE '(^|[[:space:]`("])/[A-Za-z0-9/_.-]*' \
    | tr -d '`("' | sed 's/^[[:space:]]*//' \
    | grep -vE '^/(root|tmp|usr|etc|var|home)(/|$)' \
    | sort -u | head -5
  return 0
}

# _vmap_candidates <repo> — the entry files, repo-relative, one per line.
_vmap_candidates() {
  local repo="${1:-}" f
  [ -n "$repo" ] && [ -d "$repo/docs/verification-map" ] || return 0
  for f in "$repo"/docs/verification-map/*.md "$repo"/docs/verification-map/entries/*.md; do
    [ -f "$f" ] || continue
    case "$f" in */docs/verification-map/README.md|*/docs/verification-map/TEMPLATE.md) continue ;; esac
    printf '%s\n' "${f#"$repo"/}"
  done
  return 0
}

vmap_entries_for() {
  local repo="${1:-}"
  [ $# -ge 2 ] || return 0
  shift
  local -a files=()
  local f
  while IFS= read -r f; do files+=("$f"); done < <(_vmap_candidates "$repo")
  [ "${#files[@]}" -gt 0 ] || return 0
  ( cd "$repo" && VMAP_ROUTES="$(printf '%s\n' "$@")" awk '
      function norm(p) { sub(/[?#].*/, "", p); if (length(p) > 1) sub(/\/$/, "", p); return p }
      function same(r, e,   a, b, nr, ne, i) {
        nr = split(r, a, "/"); ne = split(e, b, "/")
        if (nr != ne) return 0
        for (i = 1; i <= nr; i++) {
          if (a[i] == b[i]) continue
          if (a[i] != "" && length(b[i]) > 2 && substr(b[i], 1, 1) == "[" && substr(b[i], length(b[i])) == "]") continue
          return 0
        }
        return 1
      }
      function scan(s,   t, i) {
        while (!hit && match(s, /`\/[^`]*`/)) {
          t = norm(substr(s, RSTART + 1, RLENGTH - 2)); s = substr(s, RSTART + RLENGTH)
          for (i = 1; i <= nR; i++) if (same(R[i], t)) { print FILENAME; hit = 1; break }
        }
      }
      BEGIN {
        n = split(ENVIRON["VMAP_ROUTES"], raw, "\n")
        for (i = 1; i <= n; i++) if (raw[i] ~ /^\//) R[++nR] = norm(raw[i])
      }
      FNR == 1 { on = 0; hit = 0 }
      hit { next }
      index($0, "**Key routes/screens:**") == 1 { on = 1; scan(substr($0, 24)); next }
      on && (/^\*\*[^*]+:\*\*/ || /^#/) { on = 0; next }
      on { scan($0) }
    ' "${files[@]}" 2>/dev/null ) | sort -u
  return 0
}

vmap_note() {
  local repo="${1:-}" plan="${2:-}"
  local cap_entries=3 cap_bytes=3000   # fixed by BH-2005; prompt shaping, not a business knob
  local m screens
  m=$(_vmap_candidates "$repo" | grep -c . || true)
  if [ "${m:-0}" -eq 0 ]; then
    printf '%s\n' 'VERIFICATION MAP: none in this repo'
    return 0
  fi
  local -a sc=() hits=()
  local f
  while IFS= read -r f; do [ -n "$f" ] && sc+=("$f"); done < <(vmap_plan_screens "$plan")
  [ "${#sc[@]}" -gt 0 ] && while IFS= read -r f; do [ -n "$f" ] && hits+=("$f"); done < <(vmap_entries_for "$repo" "${sc[@]}")
  if [ "${#hits[@]}" -eq 0 ]; then
    screens="${sc[*]:-}"
    printf 'VERIFICATION MAP: no map entry for screens: %s (map has %s entries)\n' "${screens:-(plan lists none)}" "$m"
    return 0
  fi
  local n=${#hits[@]} k=0 left=$cap_bytes size cut="" dropped="" body
  if [ "$n" -eq 1 ]; then printf 'VERIFICATION MAP: 1 entry for this ticket'"'"'s screens\n'
  else printf "VERIFICATION MAP: %s entries for this ticket's screens\n" "$n"; fi
  for f in "${hits[@]}"; do
    if [ "$k" -ge "$cap_entries" ] || [ "$left" -le 0 ]; then dropped="${dropped:+$dropped }$f"; continue; fi
    size=$(wc -c < "$repo/$f" 2>/dev/null || echo 0)
    if [ "$size" -gt "$left" ]; then
      body=$(head -c "$left" "$repo/$f" 2>/dev/null || true); cut=$f; left=0
    else
      body=$(cat "$repo/$f" 2>/dev/null || true); left=$((left - size))
    fi
    printf -- '--- %s ---\n%s\n' "$f" "$body"
    k=$((k + 1))
  done
  if [ -n "$dropped" ] || [ -n "$cut" ]; then
    printf 'VERIFICATION MAP: truncated, showing %s of %s entries (cap %s entries / %s bytes); not shown: %s%s\n' \
      "$k" "$n" "$cap_entries" "$cap_bytes" "${dropped:-none}" "${cut:+; cut short: $cut}"
  fi
  return 0
}
