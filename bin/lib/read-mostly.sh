#!/bin/bash
# bin/lib/read-mostly.sh — which planned paths does this project's history say
# the builds RUN but do not EDIT? Sourced, never executed. Safe under `set -u`.
#
# THE NUMBER (BH-6299, project-6-os 2026-10-12). Six tickets each planned the
# same six repo-wide guard tests and checks. A slice runs them; it almost never
# edits them (2 real commits across all six since 2026-10-09). The schedule
# still read each shared path as a COLLISION and put the six tickets in six
# waves.
#
# ONE RULE, TWO READERS (the BH-475 note). bin/overlap-schedule.sh and
# bin/overlap-guard.sh both call read_mostly_list and drop its paths before they
# compare two lists, so the two scripts cannot disagree about one path.
#
# read_mostly_list <project> [harness]
#   Prints the read-mostly paths, one per line, sorted. rc 0 always. Empty
#   output means no path qualifies, and both callers then judge every path as
#   before. A path is read-mostly when, over the newest READ_MOSTLY_WINDOW
#   builds that opened a PR, at least READ_MOSTLY_MIN_PLANS of them planned it
#   and edits/plans < READ_MOSTLY_MAX_RATE.
#
#   A counted build is a dir builds/<project>-<KEY>-* or
#   builds/pool-<project>-<KEY>-* whose RESULT line 1 is `PR_CREATED http...`
#   or `PR_MERGED http...`, with a non-empty planned-files.txt and
#   changed-files.txt. Only the newest dir per KEY counts. A changed file
#   equal to a planned path, or under it, is an edit of that path.
#
#   Cache: state/read-mostly/<project>.tsv (path, plans, edits), every path with
#   at least READ_MOSTLY_MIN_PLANS plans, reused while younger than
#   READ_MOSTLY_MAX_AGE seconds. It is a cache of a pure function of builds/:
#   losing it costs one recompute. The rate filter is applied when the cache is
#   read, so a changed READ_MOSTLY_MAX_RATE takes effect at once.
#
#   READ_MOSTLY_EDITED: a compute logs `<ISO> READ_MOSTLY_EDITED <file> <KEY>`
#   to logs/read-mostly.log for each counted build that edited a read-mostly
#   path, once per (KEY, file): state/read-mostly/<project>.edited dedupes it.
#   A line whose dedupe record cannot be written is not logged.
#
# KNOBS (bin/lib/scheduler-conf.sh: env, settings conf.scheduler.<lowercase>,
# flags/scheduler.conf, then the default):
#   READ_MOSTLY_WINDOW=50      counted builds read, newest first
#   READ_MOSTLY_MIN_PLANS=5    plans a path needs before it can qualify (floor 2)
#   READ_MOSTLY_MAX_RATE=0.2   edits/plans must be strictly below this; 0 = off
#   READ_MOSTLY_MAX_AGE=900    seconds the cache is reused; 0 = always recompute
#
# FAIL-OPEN: no root, no python3, no builds, an unreadable file. Each prints
# nothing, so the callers keep today's rule. Less history only makes fewer
# paths read-mostly.
# shellcheck shell=bash

command -v sched_num >/dev/null 2>&1 \
  || . "$(dirname "${BASH_SOURCE[0]}")/scheduler-conf.sh" 2>/dev/null || true

# _rm_pick <min-plans> <max-rate> — read `path<TAB>plans<TAB>edits` rows on
# stdin, print the read-mostly paths. THE decision, for a compute and for a
# cache read alike.
_rm_pick() {
  awk -F'\t' -v m="$1" -v r="$2" '$2+0 >= m && $2+0 > 0 && ($3+0)/($2+0) < r+0 {print $1}' | sort -u
}

read_mostly_list() {
  local project="${1:-}" h="${2:-${HARNESS:-${H:-}}}"
  local win minp maxr maxage sd cache age out tmp now
  [ -n "$project" ] && [ -n "$h" ] || return 0
  case "$project" in *[!A-Za-z0-9._-]*) return 0 ;; esac
  command -v python3 >/dev/null 2>&1 || return 0
  if command -v sched_num >/dev/null 2>&1; then
    win=$(sched_num READ_MOSTLY_WINDOW 50 "$h")
    minp=$(sched_num READ_MOSTLY_MIN_PLANS 5 "$h")
    maxr=$(sched_frac READ_MOSTLY_MAX_RATE 0.2 "$h")
    maxage=$(sched_num READ_MOSTLY_MAX_AGE 900 "$h")
  else
    win=50; minp=5; maxr=0.2; maxage=900
  fi
  # A floor of 2 for the same reason OVERLAP_HOT_MIN has one: a path one build
  # planned says nothing about how often it is edited.
  [ "$minp" -lt 2 ] && minp=2
  awk -v r="$maxr" 'BEGIN{exit !(r+0 > 0)}' || return 0

  sd="$h/state/read-mostly"; cache="$sd/$project.tsv"
  if [ "$maxage" -gt 0 ] && [ -f "$cache" ]; then
    now=$(date +%s); age=$(( now - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    if [ "$age" -ge 0 ] && [ "$age" -lt "$maxage" ]; then
      _rm_pick "$minp" "$maxr" < "$cache" 2>/dev/null
      return 0
    fi
  fi

  # The compute prints `P<TAB>path<TAB>plans<TAB>edits` for every path with
  # at least <min-plans> plans, and `E<TAB>KEY<TAB>file<TAB>path` for each
  # changed file of a counted build that is, or is under, such a path.
  # _rm_pick decides which of them are read-mostly.
  out=$(python3 - "$h/builds" "$project" "$win" "$minp" <<'PYEOF' 2>/dev/null
import json, os, re, sys

root, project, win, minp = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
KEYRE = re.compile(r"^[A-Z][A-Z0-9]*-[0-9][A-Za-z0-9._]*$")

def norm(p):
    p = p.strip().rstrip("/")
    if p.startswith("./"):
        p = p[2:]
    return p

def paths(f):
    out = set()
    with open(f) as fh:
        for line in fh:
            p = norm(line)
            if p and not p.upper().startswith("SOURCE:"):
                out.add(p)
    return out

dirs = []
try:
    names = os.listdir(root)
except Exception:
    sys.exit(0)
for n in names:
    for pre in (project + "-", "pool-" + project + "-"):
        if not n.startswith(pre):
            continue
        # <KEY>-<stamp>: the stamp is the last dash field, all digits. A
        # remainder that is not key-shaped belongs to another project whose
        # name starts with this one (project-6 vs project-6-os).
        rest = n[len(pre):]
        m = re.match(r"^(.*)-[0-9]+$", rest)
        if not m or not KEYRE.match(m.group(1)):
            continue
        d = os.path.join(root, n)
        try:
            dirs.append((os.path.getmtime(d), n, d, m.group(1)))
        except Exception:
            pass
        break
dirs.sort(key=lambda r: (-r[0], r[1]))

plans, edits, seen, counted = {}, {}, set(), []
for _, _, d, dkey in dirs:
    if len(counted) >= win:
        break
    try:
        with open(os.path.join(d, "RESULT")) as fh:
            first = fh.readline()
        if not re.match(r"^PR_(CREATED|MERGED) http", first):
            continue
        pf, cf = os.path.join(d, "planned-files.txt"), os.path.join(d, "changed-files.txt")
        if not (os.path.getsize(pf) > 0 and os.path.getsize(cf) > 0):
            continue
        key = dkey
        try:
            with open(os.path.join(d, "ticket-meta.json")) as fh:
                k = json.load(fh).get("key")
            if isinstance(k, str) and KEYRE.match(k):
                key = k
        except Exception:
            pass
        if key in seen:
            continue
        planned, changed = paths(pf), paths(cf)
    except Exception:
        continue
    seen.add(key)
    counted.append((key, changed))
    for p in planned:
        plans[p] = plans.get(p, 0) + 1
        if any(c == p or c.startswith(p + "/") for c in changed):
            edits[p] = edits.get(p, 0) + 1

known = sorted(p for p in plans if plans[p] >= minp)
for p in known:
    print("P\t%s\t%d\t%d" % (p, plans[p], edits.get(p, 0)))
for key, changed in counted:
    for c in sorted(changed):
        for p in known:
            if c == p or c.startswith(p + "/"):
                print("E\t%s\t%s\t%s" % (key, c, p))
PYEOF
) || out=""

  # The cache: temp file, then mv. A failed write keeps the old cache, and the
  # caller still gets the set computed in memory.
  if mkdir -p "$sd" 2>/dev/null && tmp=$(mktemp "$sd/.$project.XXXXXX" 2>/dev/null); then
    printf '%s\n' "$out" | awk -F'\t' '$1 == "P" {print $2 "\t" $3 "\t" $4}' > "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$cache" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
  fi

  local k f p rmset ed="$sd/$project.edited"
  rmset=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "P" {print $2 "\t" $3 "\t" $4}' | _rm_pick "$minp" "$maxr")
  while IFS=$'\t' read -r _ k f p; do
    [ -n "$k" ] && [ -n "$f" ] && grep -qxF -- "$p" <<<"$rmset" || continue
    grep -qxF "$k	$f" "$ed" 2>/dev/null && continue
    { printf '%s\t%s\n' "$k" "$f" >> "$ed"; } 2>/dev/null || continue
    { mkdir -p "$h/logs" && printf '%s READ_MOSTLY_EDITED %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$f" "$k" \
        >> "$h/logs/read-mostly.log"; } 2>/dev/null || :
  done < <(printf '%s\n' "$out" | awk -F'\t' '$1 == "E"')

  [ -n "$rmset" ] && printf '%s\n' "$rmset"
  return 0
}
