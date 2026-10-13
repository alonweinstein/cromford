#!/bin/bash
# bin/lib/plan-hotspots.sh — the project's stored conflict hotspots, as the
# plan-time overlap gate reads them (BH-5268). Sourced, never executed; defines
# functions only, and nothing runs at source time.
#
# WHY. bin/planned-files.sh keeps only paths under a fixed directory allowlist
# (src/, tests/, docs/ ...), so a plan that names bin/deploy.sh, a cron file or
# a root next.config.js claims nothing, and the overlap gate can never see two
# plans collide there. Those are exactly the files that conflict most. The
# weekly conflict-hotspots lane (BH-5267) stores them per project as rows; this
# reads them, and finds which of them a plan names ANYWHERE outside its
# "## Sibling claims" section, however lightly. bin/plan-overlap.sh adds those
# mentions to both sides of its comparison and bin/lib/rb/plan.sh adds them to
# the published claim. planned-files.txt itself is never changed.
#
# The caller must already have sourced bin/jobs-client.sh: this uses its
# _jobs_req and never loads it. With no _jobs_req, or no harness root, every
# read is an outage.
#
# ph_conf <project>
#   Sets PH_TOP and PH_MIN. rc 1 = hotspots off for this run: TOP is 0, or a
#   knob is out of range (one stderr line PLAN_HOTSPOTS_BADKNOB <NAME>=<value>;
#   never clamped). Knobs: lib.plan-overlap-hotspots (catalog/lanes.d), read
#   through lib_env_apply when it is in scope, else env, else the code default.
# ph_hot_list <project> <out>
#   rc 0 = answered: <out> holds one hotspot path per line (maybe none), and
#   PH_SOURCE is rows (the worker answered) or cache (it did not, and the last
#   good answer for this project is in state/plan-hotspots/<project>.txt).
#   rc 1 = off or unread (stderr PLAN_HOTSPOTS_UNREAD <project>); PH_SOURCE=none.
#   An outage is never "no hotspots".
# ph_mentions <plan.md> <hotlist>
#   The hotspot paths plan.md names as whole path tokens, one per line.
# ph_union <a> <b> <out>
#   sort -u of both lists into <out>.

PH_SOURCE=none

ph__root() { printf '%s' "${HARNESS:-${H:-}}"; }

ph_conf() {
  local p="${1-}" v top="" min=""
  if command -v lib_env_apply >/dev/null 2>&1; then
    # In a subshell: lib_env_apply exports, and can exit on a required knob.
    v=$(lib_env_apply plan-overlap-hotspots "$p" >/dev/null 2>&1
        printf '%s\t%s' "${PLAN_OVERLAP_HOTSPOT_TOP-}" "${PLAN_OVERLAP_HOTSPOT_MIN-}") 2>/dev/null
    top=${v%%$'\t'*}; min=${v#*$'\t'}
  else
    top=${PLAN_OVERLAP_HOTSPOT_TOP-}; min=${PLAN_OVERLAP_HOTSPOT_MIN-}
  fi
  [ -n "$top" ] || top=50
  [ -n "$min" ] || min=2
  if ! [[ "$top" =~ ^[0-9]{1,4}$ ]] || [ "$((10#$top))" -gt 500 ]; then
    echo "PLAN_HOTSPOTS_BADKNOB PLAN_OVERLAP_HOTSPOT_TOP=$top" >&2; return 1
  fi
  if ! [[ "$min" =~ ^[0-9]{1,4}$ ]] || [ "$((10#$min))" -lt 1 ] || [ "$((10#$min))" -gt 1000 ]; then
    echo "PLAN_HOTSPOTS_BADKNOB PLAN_OVERLAP_HOTSPOT_MIN=$min" >&2; return 1
  fi
  PH_TOP=$((10#$top)); PH_MIN=$((10#$min))
  [ "$PH_TOP" -gt 0 ]
}

# A row's file is used as a literal path: repo-relative, no `..`, no empty
# segment, nothing a shell or awk could read as more than a path.
ph__safe_path() {
  local f="${1-}"
  [[ "$f" =~ ^[A-Za-z0-9._@()/+-]+$ ]] || return 1
  case "/$f/" in //*|*//*|*/../*) return 1 ;; esac
  return 0
}

ph_hot_list() {
  local p="${1-}" out="${2-}" root cache ans f tmp
  PH_SOURCE=none
  [ -n "$out" ] || return 1
  : > "$out" 2>/dev/null || return 1
  [[ "$p" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 1
  ph_conf "$p" || return 1
  root=$(ph__root)
  [ -n "$root" ] || { echo "PLAN_HOTSPOTS_UNREAD $p" >&2; return 1; }
  cache="$root/state/plan-hotspots/$p.txt"
  if command -v _jobs_req >/dev/null 2>&1 \
     && ans=$(_jobs_req GET "/api/conflict-hotspots?project=$p&limit=$PH_TOP" 2>/dev/null) \
     && printf '%s' "$ans" | jq -e '(.hotspots | type) == "array"' >/dev/null 2>&1; then
    while IFS= read -r f; do
      ph__safe_path "$f" && printf '%s\n' "$f"
    done < <(printf '%s' "$ans" | jq -r --argjson m "$PH_MIN" '.hotspots[]
        | select(type == "object" and (.conflicts | type) == "number" and .conflicts >= $m)
        | .file | select(type == "string" and (contains("\n") | not))' 2>/dev/null) \
      | awk '!seen[$0]++' | head -n "$PH_TOP" > "$out"
    PH_SOURCE=rows
    mkdir -p "$root/state/plan-hotspots" 2>/dev/null \
      && tmp=$(mktemp "$cache.XXXXXX" 2>/dev/null) \
      && cp "$out" "$tmp" 2>/dev/null && mv -f "$tmp" "$cache" 2>/dev/null \
      || rm -f "${tmp:-}" 2>/dev/null
    return 0
  fi
  if [ -f "$cache" ] && cp "$cache" "$out" 2>/dev/null; then
    echo "PLAN_HOTSPOTS_CACHED $p" >&2
    PH_SOURCE=cache
    return 0
  fi
  : > "$out" 2>/dev/null
  echo "PLAN_HOTSPOTS_UNREAD $p" >&2
  return 1
}

# The section skip is bin/planned-files.sh's: "## Sibling claims ..." is not
# scanned up to the next #/## heading, or a deeper heading not led by a ticket
# key. A mention is a whole path token: the characters on each side are not
# path characters, except that one trailing `.` ending a sentence is allowed.
ph_mentions() {
  local plan="${1-}" hot="${2-}"
  [ -s "$plan" ] && [ -s "$hot" ] || return 0
  awk 'NR==FNR { if ($0 != "") h[++nh] = $0; next }
       /^#+[[:space:]]/ {
         t = tolower($0)
         if (t ~ /^##?[[:space:]]/) skip = (t ~ /^##[[:space:]]+sibling claims/)
         else if (skip && t !~ /^#+[[:space:]]+[a-z][a-z0-9]*-[0-9]+/) skip = 0
       }
       skip { next }
       {
         for (i = 1; i <= nh; i++) {
           if (found[i]) continue
           s = $0; off = 0
           while ((k = index(s, h[i])) > 0) {
             pos = off + k; L = length(h[i])
             pre = (pos > 1) ? substr($0, pos - 1, 1) : ""
             nx = substr($0, pos + L, 1); nx2 = substr($0, pos + L + 1, 1)
             if (pre !~ /[A-Za-z0-9_.\/@-]/ &&
                 (nx !~ /[A-Za-z0-9_.\/@-]/ || (nx == "." && nx2 !~ /[A-Za-z0-9_.\/@-]/))) {
               found[i] = 1; break
             }
             s = substr(s, k + 1); off += k
           }
         }
       }
       END { for (i = 1; i <= nh; i++) if (found[i]) print h[i] }' "$hot" "$plan" | sort -u
}

ph_union() {
  sort -u "${1:-/dev/null}" "${2:-/dev/null}" 2>/dev/null | grep -v '^$' > "${3:?out}"
  return 0
}
