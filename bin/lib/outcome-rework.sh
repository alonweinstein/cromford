#!/bin/bash
# bin/lib/outcome-rework.sh — BH-3956: the `reworked` outcome for
# bin/outcome-metrics.sh. Sourced, never executed.
#
# A merged PR A is REWORKED when a later merged PR B in the same repo, merged
# within <window-days> of A, touches at least <min-share-pct> percent of A's
# PRODUCT files (bin/size-scope.sh --filter, the one product definition), and B
# is not A's own ticket's repair round (both titles carry the same ticket key).
# The pair is tagged sibling=<PARENT> when both titles carry the same decomposed
# parent (`<TICKET>: <PARENT>.<n>: …`, the title bin/lib/file-children.sh gives
# a child), else sibling=-. Trains (`batch(…)`) and `Revert …` PRs are neither A
# nor B. The point is the before/after of slicing work into siblings.
#
#   rework_scan <cand-file> <work-dir> <cache-dir> <rollup-csv> <scan-days>
#               <window-days> <min-share-pct> <max-fetch> <gh-reserve>
#               <bin-dir> <dry> <log-file> <source-label> [<first-projects>]
#
# <first-projects> (BH-4609, optional): space-separated fleet projects whose
# repos are scanned FIRST, in that order, then the rest in fleet-conf order, so
# a fetch budget that runs out partway never starves the repos an initiative
# measures. A token that is not [A-Za-z0-9._-]+ is dropped; a project with no
# repo is ignored. Absent or empty = fleet-conf order, exactly as before.
#
# Appends one 8-column candidate line per reworked A to <cand-file> (the
# caller's emitter dedupes on SEEN and writes CSV + D1), appends closed weekly
# rows to <rollup-csv> (not when dry), and sets REWORK_COMPLETE (1 only when
# every fleet repo was listed and every product file list was read) and
# REWORK_ROWS. Completeness for findings and rollup rows is per repo and week
# (BH-6165): a week counts when its repo was listed and no PR merged inside
# [Monday, Monday + 7d + <window-days>] is unread, so a repo too big for one
# run's budget still rolls up the weeks it has read. Returns non-zero when it cannot run at all; a missing argument
# is that, never a guessed path.
#
# Data: the GitHub REST pulls listing per repo (the merge ledger is capped at
# 500 rows fleet-wide, so it cannot hold a 60-day baseline). Each merged PR's
# product files are cached at <cache-dir>/<owner_repo>/<n> (a merged PR's file
# list never changes; "#none" = fetched, no product files). A failed fetch
# writes no cache file, so it is retried next run. Fetches per run are bounded
# by min(<max-fetch>, core.remaining - <gh-reserve>); when that runs out the
# repo is incomplete for this run and the next run resumes off the cache.
# READ-ONLY: every gh call is a GET.

rework_scan() {
  local cand="${1:-}" work="${2:-}" cache="${3:-}" rollup="${4:-}" scan_days="${5:-}"
  local window="${6:-}" share="${7:-}" maxfetch="${8:-}" reserve="${9:-}" bindir="${10:-}"
  local dry="${11:-0}" log="${12:-}" source="${13:-}" first="${14:-}"
  REWORK_COMPLETE=0; REWORK_ROWS=0
  [ -n "$cand" ] && [ -d "$work" ] && [ -n "$cache" ] && [ -n "$rollup" ] && [ -n "$log" ] || return 1
  [ -x "$bindir/fleet-conf.sh" ] && [ -x "$bindir/size-scope.sh" ] || return 1
  local v
  for v in "$scan_days" "$window" "$share" "$maxfetch" "$reserve"; do
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
  done

  local rw="$work/rework" now since_iso
  mkdir -p "$rw" "$cache" || return 1
  now=$(date -u +%s)
  since_iso=$(date -u -d "@$((now - scan_days*86400))" +%Y-%m-%dT%H:%M:%SZ) || return 1

  # Repos: the project -> repo mapping the lane already uses, one row per repo.
  "$bindir/fleet-conf.sh" --projects 2>/dev/null | while IFS= read -r p; do
    [ -n "$p" ] || continue
    s=$("$bindir/fleet-conf.sh" "$p" repo 2>/dev/null)
    case "$s" in */*) printf '%s\t%s\n' "$s" "$p" ;; esac
  done | awk -F'\t' '!seen[$1]++' > "$rw/repos.tsv"
  [ -s "$rw/repos.tsv" ] || { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') rework: no fleet repos resolved — not measured" >> "$log"; return 0; }
  if [ -n "$first" ]; then
    # Listed projects first, in list order; the rest keep fleet-conf order.
    # split() and plain arrays only: the hub's awk is mawk.
    awk -F'\t' -v first="$first" '
      BEGIN { n = split(first, f, " ")
              for (i = 1; i <= n; i++) if (f[i] ~ /^[A-Za-z0-9._-]+$/ && !(f[i] in rank)) rank[f[i]] = i }
      { line[NR] = $0; proj[NR] = $2 }
      END {
        for (i = 1; i <= n; i++) for (r = 1; r <= NR; r++) if (proj[r] == f[i] && rank[f[i]] == i) print line[r]
        for (r = 1; r <= NR; r++) if (!(proj[r] in rank)) print line[r]
      }' "$rw/repos.tsv" > "$rw/repos.tsv.tmp" && mv "$rw/repos.tsv.tmp" "$rw/repos.tsv"
  fi

  local remaining budget
  remaining=$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null </dev/null)
  case "$remaining" in
    ''|*[!0-9]*) budget=$maxfetch ;;
    *) budget=$((remaining - reserve))
       [ "$budget" -gt "$maxfetch" ] && budget=$maxfetch
       [ "$budget" -lt 0 ] && budget=0 ;;
  esac

  local all=1 slug project flat list k raw n oldest ok num merged title cf files
  : > "$rw/prs.tsv"; : > "$rw/complete.tsv"; : > "$rw/listed.tsv"; : > "$rw/missing.tsv"
  while IFS=$'\t' read -r slug project; do
    command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$slug" </dev/null || true; }
    flat=$(printf '%s' "$slug" | tr '/' '_')
    list="$rw/list-$flat.tsv"; : > "$list"; ok=1
    # Newest-updated first; updated_at >= merged_at, so once a page's oldest
    # updated_at is before the scan start nothing older can have merged inside it.
    for k in $(seq 1 100); do
      raw=$(gh api "repos/$slug/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$k" 2>/dev/null </dev/null) || raw=""
      if ! printf '%s' "$raw" | jq -e 'type=="array"' >/dev/null 2>&1; then ok=0; break; fi
      printf '%s' "$raw" | jq -r --arg s "$since_iso" '.[]
        | select(.merged_at != null and .merged_at >= $s and .base.ref == .base.repo.default_branch)
        | [.number, .merged_at, ((.title // "") | gsub("[\t\r\n]"; " "))] | @tsv' >> "$list" 2>/dev/null || { ok=0; break; }
      n=$(printf '%s' "$raw" | jq 'length')
      oldest=$(printf '%s' "$raw" | jq -r 'map(.updated_at // "") | min // ""')
      [ "$n" -lt 100 ] && break
      [[ "$oldest" < "$since_iso" ]] && break
      [ "$k" = 100 ] && ok=0
    done
    if [ "$ok" != 1 ]; then
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') rework: $slug pulls listing failed or was not a list — incomplete this run" >> "$log"
      all=0; continue
    fi
    printf '%s\t%s\n' "$slug" "$project" >> "$rw/listed.tsv"
    mkdir -p "$cache/$flat"
    while IFS=$'\t' read -r num merged title; do
      case "$num" in ''|*[!0-9]*) continue ;; esac
      cf="$cache/$flat/$num"
      if [ ! -f "$cf" ]; then
        if [ "$budget" -le 0 ]; then ok=0; printf '%s\t%s\n' "$slug" "$merged" >> "$rw/missing.tsv"; continue; fi
        budget=$((budget - 1))
        files=$(gh api --paginate "repos/$slug/pulls/$num/files?per_page=100" --jq '.[]?.filename' 2>/dev/null </dev/null) \
          || { ok=0; printf '%s\t%s\n' "$slug" "$merged" >> "$rw/missing.tsv"; continue; }
        files=$(printf '%s\n' "$files" | "$bindir/size-scope.sh" --filter)
        { [ -n "$files" ] && printf '%s\n' "$files" || echo '#none'; } > "$cf.tmp" && mv "$cf.tmp" "$cf"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$project" "$num" "$merged" "$title" "$cf" >> "$rw/prs.tsv"
    done < "$list"
    if [ "$ok" = 1 ]; then
      printf '%s\t%s\n' "$slug" "$project" >> "$rw/complete.tsv"
    else
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') rework: $slug product-file reads incomplete (fetch budget or a failed read) — resumes next run" >> "$log"
      all=0
    fi
  done < "$rw/repos.tsv"
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset

  # Parse, pair and roll up. Only listed repos take part, and per week only
  # when the week is complete: an unread PR in the week would short its
  # denominator, and one in the window after it could be the real earliest B.
  python3 - "$rw/prs.tsv" "$rw/complete.tsv" "$now" "$((now - scan_days*86400))" "$window" "$share" \
            "$rollup" "$dry" "$log" "$source" "$rw/listed.tsv" "$rw/missing.tsv" > "$rw/pairs.tsv" <<'PYR' || return 1
import csv, os, re, sys, datetime as dt
prs_f, complete_f, now, since, window, share, rollup, dry, log_f, source, listed_f, missing_f = sys.argv[1:13]
now, since, window, share = int(now), int(since), int(window), int(share)
dry = dry == "1"
TICKET = re.compile(r"^\s*([A-Z][A-Z0-9]*-\d+):")
PARENT = re.compile(r"^\s*[A-Z][A-Z0-9]*-\d+:\s*([A-Z][A-Z0-9]*-\d+)\.\d+:")
complete = {}
for line in open(complete_f):
    p = line.rstrip("\n").split("\t")
    if len(p) == 2:
        complete[p[0]] = p[1]
listed = {}
for line in open(listed_f):
    p = line.rstrip("\n").split("\t")
    if len(p) == 2:
        listed[p[0]] = p[1]

def epoch(s):
    return int(dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp())

missing = {}
for line in open(missing_f):
    p = line.rstrip("\n").split("\t")
    try:
        missing.setdefault(p[0], []).append(epoch(p[1]))
    except (IndexError, ValueError):
        missing.setdefault(p[0], []).append(None)  # unparseable: the repo has no complete week

day = 86400
def monday_of(e):
    d = e // day * day
    return d - (dt.datetime.fromtimestamp(d, dt.timezone.utc).isoweekday() - 1) * day

def week_ok(slug, mon):
    # Complete repo, or listed with no unread PR in [mon, mon + 7d + window].
    if slug in complete:
        return True
    if slug not in listed:
        return False
    return not any(t is None or mon <= t <= mon + 7 * day + window * day for t in missing.get(slug, []))

def isoweek(e):
    y, w, _ = dt.datetime.fromtimestamp(e, dt.timezone.utc).isocalendar()
    return "%d-W%02d" % (y, w)

byrepo = {}
for line in open(prs_f):
    p = line.rstrip("\n").split("\t")
    if len(p) != 6 or p[0] not in listed:
        continue
    slug, project, num, merged, title, cf = p
    if title.startswith("batch(") or title.startswith("Revert "):
        continue
    try:
        files = [f for f in open(cf).read().split("\n") if f and f != "#none"]
        t = epoch(merged)
    except (OSError, ValueError):
        continue
    m, q = TICKET.match(title), PARENT.match(title)
    byrepo.setdefault(slug, []).append({
        "slug": slug, "project": project, "num": int(num), "t": t, "date": merged[:10],
        "ticket": m.group(1) if m else "-", "parent": q.group(1) if q else "-",
        "files": files, "cf": cf,
        "url": "https://github.com/%s/pull/%s" % (slug, num)})

stats = {}
def st(week, project):
    return stats.setdefault((week, project), [0, 0, 0, 0, 0])

out = sys.stdout
for slug, prs in byrepo.items():
    prs.sort(key=lambda r: (r["t"], r["num"]))
    for a in prs:
        if not a["files"] or not week_ok(slug, monday_of(a["t"])):
            continue
        s = st(isoweek(a["t"]), a["project"])
        s[0] += 1
        if a["parent"] != "-":
            s[2] += 1
        pa = set(a["files"])
        for b in prs:
            d = b["t"] - a["t"]
            if b["num"] == a["num"] or d <= 0 or d > window * 86400:
                continue
            if a["ticket"] != "-" and a["ticket"] == b["ticket"]:
                continue
            common = sorted(pa & set(b["files"]))
            if not common or len(common) * 100 < share * len(pa):
                continue
            sib = a["parent"] if a["parent"] != "-" and a["parent"] == b["parent"] else "-"
            s[1] += 1
            if a["parent"] != "-":
                s[3] += 1
            if sib != "-":
                s[4] += 1
            ev = ("reworked by %s (%s) merged %s, %gd later: %d of %d product files (%d%%) [%s]; sibling=%s"
                  % (b["url"], b["ticket"], b["date"], round(d / 86400.0, 1), len(common), len(pa),
                     round(len(common) * 100.0 / len(pa)), " ".join(common[:3]), sib))
            out.write("\t".join([a["project"], a["ticket"], slug, a["url"], ev, a["cf"]]) + "\n")
            break

# Weekly rollup, per (ISO week of A's merge, project): only weeks wholly inside
# the scan, whose window has closed, and complete for every listed repo of the
# project this run.
if dry:
    sys.exit(0)
have = set()
if os.path.exists(rollup):
    for r in csv.reader(open(rollup)):
        if len(r) >= 2:
            have.add((r[0], r[1]))
mon = (since + day - 1) // day * day
while dt.datetime.fromtimestamp(mon, dt.timezone.utc).isoweekday() != 1:
    mon += day
rate = lambda r, m: ("%.1f" % (r * 100.0 / m)) if m else "-"
new, lines = [], []
while mon + 7 * day - 1 + window * day < now:
    week = isoweek(mon)
    for project in sorted(set(listed.values())):
        if (week, project) in have:
            continue
        if not all(week_ok(sl, mon) for sl, pj in listed.items() if pj == project):
            continue
        m, r, dm, dr, sr = stats.get((week, project), [0, 0, 0, 0, 0])
        new.append([week, project, m, r, rate(r, m), dm, dr, rate(dr, dm), sr, source])
        pct = lambda x: x if x == "-" else x + "%"
        lines.append("rework week=%s project=%s rate=%s (%d/%d) decomposed=%s (%d/%d)"
                     % (week, project, pct(rate(r, m)), r, m, pct(rate(dr, dm)), dr, dm))
    mon += 7 * day
if new:
    fresh = not os.path.exists(rollup) or os.path.getsize(rollup) == 0
    with open(rollup, "a", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")
        if fresh:
            w.writerow(["week", "project", "merged", "reworked", "rate", "decomposed_merged",
                        "decomposed_reworked", "decomposed_rate", "sibling_reworked", "source"])
        w.writerows(new)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    with open(log_f, "a") as fh:
        fh.write("".join("%s %s\n" % (stamp, l) for l in lines))
PYR

  local proj tk url ev area
  while IFS=$'\t' read -r proj tk slug url ev cf; do
    [ -n "$url" ] || continue
    if command -v area_of >/dev/null 2>&1; then
      area=$(grep -v '^#none$' "$cf" 2>/dev/null | area_of)
    else
      area="-"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' reworked "$proj" "$tk" "$slug" "$url" "${area:--}" "$ev" "-" >> "$cand"
    REWORK_ROWS=$((REWORK_ROWS + 1))
  done < "$rw/pairs.tsv"
  REWORK_COMPLETE=$all
  return 0
}
