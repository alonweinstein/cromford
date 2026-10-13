#!/bin/bash
# bin/conflict-hotspots.sh [-C dir] [--ref REF] [--days N] [--now EPOCH]
#   [--branches REFPREFIX] [--include-mergify] [--no-remote-check] [--top N]
#   [--markdown] [--repo OWNER/NAME]
# Which files cause merge conflicts and rebases? (BH-4986, BH-4975.1)
#
# Ranks files by how many PRs hit a merge conflict on them, or had main move
# them underneath the branch, over a window (default the last 30 days):
#
#   path<TAB>conflicts<TAB>rebases<TAB>prs     header
#   <path><TAB><c><TAB><r><TAB>#2,#7,ticket/x  conflicts desc, rebases desc, path asc
#   # ref=<sha12> since=… until=… days=… pr_merges=… sync_merges=…
#     conflicted_syncs=… branches_scanned=… branches_conflicted=… merge_tree_errors=…
#     branches_mergify_skipped=… remote_check=on|off branches_stale_skipped=…
#
# WHY. Before a hotspot is split or serialized (BH-4975 waves 2 and 3), measure
# which files really collide. docs/CONFLICT_HOTSPOTS.md is this script's
# --markdown output for cromford.
#
# WHAT IT READS. The local git history, no fetch and no gh. It makes one
# `git ls-remote` call when the branch prefix is a configured remote's tracking
# namespace (see below). It never writes to the checkout. Fetch first. PRs land on REF as merge commits, and the harness brings a PR
# branch up to date by merging main INTO it (mc_rebase in bin/lib/mc/rebase.sh),
# so every such rebase leaves a "sync merge" on the branch.
#   - Window: committer dates in [NOW - DAYS*86400, NOW].
#   - PR merge: a merge on `git log --first-parent REF` in the window. Its id is
#     #N from "Merge pull request #N" or a trailing "(#N)", else the short sha.
#   - Sync merge of PR merge M: a merge X in M^1..M^2, committed in the window,
#     with exactly one parent already on M^1 (the main side). X is skipped when
#     its own subject is a PR-merge subject: that is a merge-train member, which
#     is counted as its own PR over its own range, and that range is taken out of
#     the train's.
#   - Unmerged branch: a ref under --branches (default refs/remotes/origin/;
#     '' turns it off) whose tip is not on REF and was committed in the window.
#     Its sync merges count the same way, and so does a merge-tree of its tip
#     against REF as REF stood when the tip was committed (its last first-parent
#     commit at or before the tip's committer date). Against REF today, every
#     branch abandoned weeks ago conflicts on whatever main changed since, which
#     measures how stale the branch is, not which files collide. Its id is the
#     ref name minus the prefix. Refs whose id starts with mergify/ (merge-queue
#     copies of real branches) are skipped unless --include-mergify is given,
#     and are then scanned after every other ref. An explicit
#     --branches refs/remotes/origin/mergify/ scans them, because the id is the
#     name minus that prefix.
#   - Stale refs: when --branches is refs/remotes/<remote>/ and <remote> is
#     configured, one `git ls-remote --heads <remote>` lists the live branches,
#     and a local ref the remote no longer has is skipped. A remote that cannot
#     be listed is rc 4, never a silent scan of stale refs. --no-remote-check
#     turns this off (offline use); any other prefix has no check.
#   - conflicts[file]: distinct PRs/branches where `git merge-tree` of a sync
#     merge's two parents (or of the branch tip and REF) conflicted on file.
#     Each sync merge is replayed once per run, and each branch tip sha once:
#     the first PR or ref that reaches it owns the count, so one merge seen
#     from several refs is one conflict, not one per ref.
#     Each replay reads .gitattributes from the commit the merge ran in (the
#     sync merge's first parent, or the branch tip), never from the working
#     tree, so a file that was merge=union THEN and merged cleanly is not a
#     conflict even after the union line is gone.
#   - rebases[file]: distinct PRs/branches with a sync merge where file changed
#     on both sides since the merge base, conflicted or not.
# Not counted: a branch rebuilt by force-push or by `git rebase --onto` (the
# stacked-child path) leaves no sync merge. A merge-tree that fails outright is
# counted in merge_tree_errors, never read as clean.
#
# --top N cuts the data rows (default all for TSV, 10 for --markdown).
# --repo makes the markdown PR ids links to https://github.com/<repo>/pull/N.
# rc: 0 the report printed (zero rows included), 1 not a git repo, REF does not
# resolve or git < 2.40, 2 bad arguments, 3 the repository is shallow, 4 the
# remote's branches cannot be listed (pass --no-remote-check).
set -uo pipefail
export LC_ALL=C

usage() {
  echo "usage: conflict-hotspots.sh [-C dir] [--ref REF] [--days N] [--now EPOCH] [--branches REFPREFIX] [--include-mergify] [--no-remote-check] [--top N] [--markdown] [--repo OWNER/NAME]" >&2
  exit 2
}
CMD="bin/conflict-hotspots.sh"
for a in "$@"; do
  case "$a" in *[!A-Za-z0-9._/:=@,+-]*|'') CMD="$CMD '$a'" ;; *) CMD="$CMD $a" ;; esac
done
GDIR=.; REF=origin/main; DAYS=30; NOW=""; BR=refs/remotes/origin/; TOP=""; MD=0; REPO=""; MERGIFY=0; RCHECK=1
while [ $# -gt 0 ]; do
  case "$1" in
    -C)         [ $# -ge 2 ] || usage; GDIR=$2; shift 2 ;;
    --ref)      [ $# -ge 2 ] || usage; REF=$2; shift 2 ;;
    --days)     [ $# -ge 2 ] || usage; DAYS=$2; shift 2 ;;
    --now)      [ $# -ge 2 ] || usage; NOW=$2; shift 2 ;;
    --branches) [ $# -ge 2 ] || usage; BR=$2; shift 2 ;;
    --top)      [ $# -ge 2 ] || usage; TOP=$2; shift 2 ;;
    --repo)     [ $# -ge 2 ] || usage; REPO=$2; shift 2 ;;
    --markdown) MD=1; shift ;;
    --include-mergify) MERGIFY=1; shift ;;
    --no-remote-check) RCHECK=0; shift ;;
    *)          usage ;;
  esac
done
[[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -gt 0 ] || usage
[ -z "$TOP" ] || { [[ "$TOP" =~ ^[0-9]+$ ]] && [ "$TOP" -gt 0 ]; } || usage
[ -z "$REPO" ] || [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage
[ -z "$NOW" ] || [[ "$NOW" =~ ^[0-9]+$ ]] || usage
[ -n "$NOW" ] || NOW=$(date -u +%s)
[ -n "$TOP" ] || { [ "$MD" = 1 ] && TOP=10; }
SINCE=$((NOW - DAYS * 86400))

die() { echo "conflict-hotspots: $1" >&2; exit "$2"; }
g() { git -C "$GDIR" -c core.quotePath=false "$@"; }
g rev-parse --git-dir >/dev/null 2>&1 || die "$GDIR is not a git repository" 1
GV=$(git version)
GV=${GV#git version }
GMAJ=${GV%%.*}; GMIN=${GV#*.}; GMIN=${GMIN%%.*}
[[ "$GMAJ" =~ ^[0-9]+$ && "$GMIN" =~ ^[0-9]+$ ]] && { [ "$GMAJ" -gt 2 ] || { [ "$GMAJ" -eq 2 ] && [ "$GMIN" -ge 40 ]; }; } \
  || die "git $GV is too old: merge-tree --write-tree with --attr-source needs git 2.40 or later" 1
[ "$(g rev-parse --is-shallow-repository)" = false ] \
  || die "$GDIR is a shallow clone, so old sync merges are missing; run git fetch --unshallow first" 3
TIP=$(g rev-parse --verify -q "$REF^{commit}") || die "ref $REF does not resolve" 1
SHA12=$(g rev-parse --short=12 "$TIP")

W=$(mktemp -d "${TMPDIR:-/tmp}/conflict-hotspots.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
: > "$W/ev"; : > "$W/claimed"; : > "$W/tips"
PRS=0; SYNCS=0; CSYNCS=0; BSCAN=0; BCONF=0; MTERR=0; BEXCL=0; BSTALE=0; RCK=off

PR_RE='^Merge pull request #([0-9]+)( |$)|\(#([0-9]+)\)$'
pr_id() { # <subject>: prints #N, or nothing for a non-PR subject
  [[ "$1" =~ $PR_RE ]] || return 1
  echo "#${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
}
anc() { g merge-base --is-ancestor "$1" "$2" 2>/dev/null; }

# mtree <id> <a> <b> <attr>: merge-tree a b with .gitattributes read from
# commit attr, C events for each conflicted path.
# rc 0 clean, 1 conflicted, 2 merge-tree failed.
mtree() {
  local out rc
  out=$(g --attr-source="$4" merge-tree --write-tree --name-only --no-messages "$2" "$3" 2>/dev/null); rc=$?
  case $rc in
    0) return 0 ;;
    1) printf '%s\n' "$out" | sed 1d | awk -v id="$1" 'NF { print "C\t" id "\t" $0 }' >> "$W/ev"; return 1 ;;
    *) MTERR=$((MTERR + 1)); return 2 ;;
  esac
}

# sync_merge <id> <x> <p1> <p2>: one sync merge X with parents p1 p2.
sync_merge() {
  local base
  SYNCS=$((SYNCS + 1))
  mtree "$1" "$3" "$4" "$3"; [ $? = 1 ] && CSYNCS=$((CSYNCS + 1))
  base=$(g merge-base "$3" "$4" 2>/dev/null) || return 0
  g diff --name-only "$base" "$3" | sort -u > "$W/d1"
  g diff --name-only "$base" "$4" | sort -u > "$W/d2"
  comm -12 "$W/d1" "$W/d2" | awk -v id="$1" 'NF { print "R\t" id "\t" $0 }' >> "$W/ev"
}

# syncs <id> <mainref> <range...>: every sync merge in range, in the window,
# not in $W/claimed, one parent on mainref. Claims what it reads.
syncs() {
  local id=$1 main=$2 x p1 p2 p3 ct s
  shift 2
  g log --merges --format='%H %P%x09%ct%x09%s' "$@" > "$W/cand" || return 0
  while IFS=$'\t' read -r x ct s; do
    read -r x p1 p2 p3 <<< "$x"
    [ -n "$p2" ] && [ -z "$p3" ] || continue
    [ "$ct" -ge "$SINCE" ] && [ "$ct" -le "$NOW" ] || continue
    grep -qxF "$x" "$W/claimed" && continue
    echo "$x" >> "$W/claimed"
    pr_id "$s" >/dev/null && continue
    if anc "$p1" "$main"; then anc "$p2" "$main" && continue
    else anc "$p2" "$main" || continue
    fi
    sync_merge "$id" "$x" "$p1" "$p2"
  done < "$W/cand"
}

# PR merges on REF's first-parent chain.
g log --first-parent --merges --format='%H %P%x09%ct%x09%s' "$TIP" > "$W/prs" || die "cannot read the history of $REF" 1
while IFS=$'\t' read -r m ct s; do
  [ "$ct" -le "$NOW" ] || continue
  [ "$ct" -ge "$SINCE" ] || continue
  read -r m p1 p2 _ <<< "$m"
  PRS=$((PRS + 1))
  id=$(pr_id "$s") || id=${m:0:8}
  # Merge-train members first: each is its own PR over its own range, and the
  # syncs it claims are then skipped for the train.
  g log --merges --format='%H %P%x09%s' "$p1..$p2" > "$W/members"
  while IFS=$'\t' read -r c s2; do
    read -r c c1 c2 _ <<< "$c"
    cid=$(pr_id "$s2") || continue
    anc "$c2" "$p1" && continue
    syncs "$cid" "$p1" "$c1..$c2"
  done < "$W/members"
  syncs "$id" "$p1" "$p1..$p2"
done < "$W/prs"

# Unmerged branches.
if [ -n "$BR" ]; then
  g log --first-parent --format='%H %ct' "$TIP" > "$W/fp" || die "cannot read the history of $REF" 1
  # The remote's live branches, when BR is a configured remote's namespace.
  RMT=""
  if [ "$RCHECK" = 1 ] && [[ "$BR" =~ ^refs/remotes/([^/]+)/$ ]]; then
    RMT=${BASH_REMATCH[1]}
    g remote get-url "$RMT" >/dev/null 2>&1 || RMT=""
  fi
  if [ -n "$RMT" ]; then
    TO=(); command -v timeout >/dev/null 2>&1 && TO=(timeout 120)
    ${TO[@]+"${TO[@]}"} git -C "$GDIR" ls-remote --heads "$RMT" > "$W/lsr" 2>"$W/lsr.err" \
      || die "cannot list $RMT's branches ($(head -1 "$W/lsr.err" | cut -c1-200)); pass --no-remote-check to scan the local refs as they are" 4
    awk '{ sub(/^refs\/heads\//, "", $2); print $2 }' "$W/lsr" > "$W/live"
    RCK=on
  fi
  g for-each-ref --format='%(objectname)%09%(committerdate:unix)%09%(refname)%09%(symref)' "$BR" > "$W/refs"
  # mergify/ copies go last, so the real branch owns a sync merge both reach.
  awk -F'\t' -v p="$BR" 'substr($3, length(p) + 1) ~ /^mergify\// { m[++n] = $0; next } { print }
    END { for (i = 1; i <= n; i++) print m[i] }' "$W/refs" > "$W/refs2"
  while IFS=$'\t' read -r b ct ref sym; do
    [ -z "$sym" ] || continue
    [ "$ct" -ge "$SINCE" ] && [ "$ct" -le "$NOW" ] || continue
    anc "$b" "$TIP" && continue
    name=${ref#"$BR"}
    if [ "$MERGIFY" = 0 ] && [[ "$name" == mergify/* ]]; then BEXCL=$((BEXCL + 1)); continue; fi
    if [ "$RCK" = on ] && ! grep -qxF -- "$name" "$W/live"; then BSTALE=$((BSTALE + 1)); continue; fi
    BSCAN=$((BSCAN + 1))
    syncs "$name" "$TIP" "$TIP..$b"
    grep -qxF "$b" "$W/tips" && continue
    echo "$b" >> "$W/tips"
    was=$(awk -v t="$ct" '$2 <= t { print $1; exit }' "$W/fp")
    [ -n "$was" ] || continue
    mtree "$name" "$b" "$was" "$b"; [ $? = 1 ] && BCONF=$((BCONF + 1))
  done < "$W/refs2"
fi

# Aggregate: distinct ids per (path, kind); ids #N numeric first, then names.
awk -F'\t' '
  function key(id) { return (id ~ /^#[0-9]+$/) ? sprintf("0%012d", substr(id, 2)) : "1" id }
  function add(list, id,   n, a, i, out) {
    n = split(list, a, ","); out = ""
    for (i = 1; i <= n; i++) if (key(a[i]) > key(id)) break; else out = out (out == "" ? "" : ",") a[i]
    out = out (out == "" ? "" : ",") id
    for (; i <= n; i++) out = out "," a[i]
    return out
  }
  !(($1, $2, $3) in seen) {
    seen[$1, $2, $3] = 1; p[$3] = 1
    if ($1 == "C") { c[$3]++; cl[$3] = add(cl[$3], $2) } else { r[$3]++; rl[$3] = add(rl[$3], $2) }
  }
  END {
    for (f in p) {
      ids = cl[f]; n = split(rl[f], a, ",")
      for (i = 1; i <= n; i++) if (index("," cl[f] ",", "," a[i] ",") == 0) ids = ids (ids == "" ? "" : ",") a[i]
      print f "\t" (c[f] + 0) "\t" (r[f] + 0) "\t" ids
    }
  }' "$W/ev" | sort -t$'\t' -k2,2nr -k3,3nr -k1,1 > "$W/rows"
[ -z "$TOP" ] || { head -n "$TOP" "$W/rows" > "$W/top"; mv "$W/top" "$W/rows"; }

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
SINCE_ISO=$(iso "$SINCE"); NOW_ISO=$(iso "$NOW")
if [ "$MD" = 0 ]; then
  printf 'path\tconflicts\trebases\tprs\n'
  cat "$W/rows"
  echo "# ref=$SHA12 since=$SINCE_ISO until=$NOW_ISO days=$DAYS pr_merges=$PRS sync_merges=$SYNCS conflicted_syncs=$CSYNCS branches_scanned=$BSCAN branches_conflicted=$BCONF merge_tree_errors=$MTERR branches_mergify_skipped=$BEXCL remote_check=$RCK branches_stale_skipped=$BSTALE"
  exit 0
fi

cat <<EOF
# Conflict hotspots

Generated by \`$CMD\` at \`$REF\` = \`$SHA12\`, over $SINCE_ISO to $NOW_ISO ($DAYS days), run on ${NOW_ISO%%T*}.

## How this is measured

Every PR lands on main as a merge commit, and every time the harness brings a PR branch up to date it merges main into the branch, so each rebase leaves a sync merge in the PR's history. Each sync merge committed in the window, on a PR merged in the window or on an unmerged branch, is replayed with \`git merge-tree\` under the \`.gitattributes\` of the commit the merge ran in, so a file that was \`merge=union\` at the time and merged cleanly is not a conflict. Conflicts counts the distinct PRs (and unmerged branches whose tip conflicts with the ref as it stood when the tip was committed) where a replay conflicted on the file, and Rebases counts the distinct PRs where both main and the branch had changed the file since their merge base, conflict or not. A branch rebuilt by force-push or by \`git rebase --onto\` leaves no sync merge, so it is not counted here, and a shallow clone is refused rather than undercounted.

EOF
if [ "$PRS" = 0 ] && [ "$BSCAN" = 0 ]; then
  echo "No PR merges and no unmerged branches in this window."
elif [ ! -s "$W/rows" ]; then
  echo "No file conflicted or was rebased in this window."
else
  echo "| # | File | Conflicts | Rebases | PRs involved |"
  echo "|---|---|---|---|---|"
  awk -F'\t' -v repo="$REPO" '
    function esc(s) { gsub(/\|/, "\\|", s); return s }
    {
      n = split($4, a, ","); ids = ""
      for (i = 1; i <= n; i++) {
        x = (a[i] ~ /^#[0-9]+$/ && repo != "") ? "[" a[i] "](https://github.com/" repo "/pull/" substr(a[i], 2) ")" : esc(a[i])
        ids = ids (i > 1 ? ", " : "") x
      }
      print "| " NR " | `" esc($1) "` | " $2 " | " $3 " | " ids " |"
    }' "$W/rows"
fi
cat <<EOF

Read $PRS PR merges and $SYNCS sync merges, $CSYNCS of which conflicted. Scanned $BSCAN unmerged branches, $BCONF of which conflict with the ref as it stood at their tip. $MTERR merge-tree replays failed outright and are not counted. Each sync merge and each branch tip counts once, for the first PR or branch that reaches it.

Skipped $BEXCL mergify/ refs (merge-queue copies; --include-mergify scans them).
EOF
if [ "$RCK" = on ]; then
  echo "Skipped $BSTALE local refs that $RMT no longer has (checked with git ls-remote)."
else
  echo "No remote check: local refs were scanned as they are."
fi
