#!/bin/bash
# bin/ci-durations.sh merge|fetch|post|seed — the shard weights CI composes from
# its own runs (BH-5518 C1), and the jobs worker's ledger of them (BH-5653).
# docs/ci-durations.md has the design.
#
# catalog/ci-suite-durations.tsv was a committed file that every PR adding an
# always-run suite had to edit, so two such PRs conflicted on it, and a PR that
# forgot its row turned every merge-queue batch red in fast-lints-data D1. The
# file is a sort hint and nothing else (bin/lib/suite-runner.sh
# suite_shard_plan, bin/fast-lints.sh), so it now lives on a chain of CI
# artifacts and is git-ignored:
#
#   plan job      fetch -> artifact `ci-durations` (every shard reads this ONE file)
#   tests-shard   bin/test-trace-safety.sh --gate --timings -> `suite-timings-<n>`
#   decisions     merge (previous file + this run's timings) -> `ci-durations-next`
#   next run      fetch reads the newest `ci-durations-next` of a GREEN batch
#   ci-timings    post -> the jobs worker's ci_suite_durations (BH-5653): one
#                 POST per green batch, a rolling median per suite in D1
#   next run      fetch reads that table FIRST, then the chain above
#
# Format: `<suite>\t<seconds>\t<run>\t<v1,v2,v3>`, `#` comments. Readers use
# columns 1-2 only. The seed (the last committed copy) has no column 4.
#
#   merge --prev <file> --timings-dir <dir> --run <id> --root <checkout> --out <file>
#       A pure function of its inputs: the same inputs give the same bytes. Reads
#       every *.tsv under --timings-dir (`<suite>\t<seconds>\t<rc>`, rc 0 rows
#       only; a suite timed twice keeps its larger value). A measured suite gets
#       its new value first in its list, the 3 newest kept; <seconds> is their
#       median (two values: the mean), to 0.1 s; <run> is --run. An unmeasured
#       suite keeps its row byte for byte. A suite with no file under --root is
#       dropped. Rows are LC_ALL=C sorted under a fixed header (no clock).
#       rc 2 on a bad argument or an unreadable input.
#   fetch --out <file> [--root <checkout>]
#       Reads GitHub through ${CI_DURATIONS_GH:-gh} with the job's own token
#       (never the fleet PAT), CI_REPO and CI_WORKFLOW, three calls: the green
#       runs (event pull_request, conclusion success, head branch
#       mergify/merge-queue/*, name CI_WORKFLOW), the `ci-durations-next`
#       artifacts (newest unexpired one of those runs), and that artifact's zip.
#       Only the member `ci-durations.tsv` is read, into memory; no member path
#       ever reaches the disk. Every non-comment row needs a numeric column 2.
#       Writes `# source: artifact run <id>` and the member to --out.
#       Fallback, with one ::warning:: line naming the reason: the SEED, the
#       file's last committed copy (`git show <deleting commit>^:...`, found by
#       git log, so the checkout needs full history) under `# source: seed
#       <sha>`; else a header-only file, `# source: none`, which makes the split
#       round-robin. ALWAYS rc 0 (rc 2 only on a bad argument): the file is a
#       sort hint, and its absence must never stop CI.
#       THE WORKER FIRST (BH-5653). When the jobs worker is configured (below),
#       fetch reads GET /api/ci/suite-durations before the chain. A usable answer
#       (HTTP 200, JSON, a non-empty `rows`, not `truncated`, every row a
#       tests/ suite path with seconds 0..10800 and a positive source_run) is
#       written under `# source: api` and copied, by an atomic rename, to the
#       cache. Any other answer prints one ::warning:: and the cache (the last
#       usable answer, never overwritten by a bad one) is used under
#       `# source: cache`; with no cache, the chain above. Not configured: the
#       worker and the cache are both skipped, and nothing is sent.
#   post --run-id <id> --timings-dir <dir>
#       POSTs this run's timings (every *.tsv under <dir>, rc 0 rows only, a
#       suite timed twice keeps its larger value) to the worker as ONE body for
#       the run. The worker is idempotent per run id: the same rows again answer
#       "already posted", other rows answer 409. FAIL-OPEN: not configured, no
#       timings, an HTTP error, a 409 or a dead worker all exit 0, the last
#       three with one ::warning::. rc 2 on a bad argument.
#   seed [--file <tsv>] [--root <checkout>] [--dry-run]
#       Imports a durations file into the worker, one POST per source run
#       (column 3) with source "seed". Default file: the seed in git history,
#       as fetch finds it. --dry-run prints the bodies, one JSON per line, and
#       sends nothing. A re-run is a no-op ("already posted"). rc 1 when the
#       worker is not configured or any run is refused.
#
# The worker: JOBS_URL and a bearer, CI_DURATIONS_TOKEN (CI's scoped token) or
# HARNESS_SECRET. When JOBS_URL is not set at all, both are read from the
# harness env's global.env, as bin/jobs-client.sh does; a JOBS_URL that is set,
# even empty, is the caller's answer and no file is read. The token reaches
# curl through a mode-600 header file, never argv, and is never printed.
# The cache: CI_DURATIONS_CACHE, default <harness>/state/ci-durations/api.tsv.
#
# Knob: CI_DURATIONS_LOOKBACK, the per_page of the two list calls (default 50).
# CI plumbing, not a business parameter, so it is env with a code default.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REL=catalog/ci-suite-durations.tsv
die2() { echo "ci-durations: $*" >&2; exit 2; }
API_PATH=/api/ci/suite-durations
SUITE_RE='^tests/[A-Za-z0-9._/-]+[.]sh$'

# api_conf — set API_URL and API_TOK; rc 0 only when both are non-empty.
api_conf() {
  local url="${JOBS_URL-}" tok="${CI_DURATIONS_TOKEN:-${HARNESS_SECRET:-}}" gf
  if [ -z "${JOBS_URL+set}" ]; then
    . "$SELF_DIR/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }
    gf="$(harness_env_dir "${HARNESS:-/root/harness}")/global.env"
    if [ -r "$gf" ]; then
      url=$(sed -n 's/^JOBS_URL=//p' "$gf" | head -1 | tr -d "\"' ")
      [ -n "$tok" ] || tok=$(sed -n 's/^HARNESS_SECRET=//p' "$gf" | head -1 | tr -d "\"' ")
    fi
  fi
  API_URL="${url%/}"; API_TOK="$tok"
  [ -n "$API_URL" ] && [ -n "$API_TOK" ]
}

# api_hdr <file> — the bearer as a curl header file, mode 600.
api_hdr() { ( umask 077; printf 'Authorization: Bearer %s\n' "$API_TOK" > "$1" ); }

# seed_sha <root> — the commit that deleted the committed file, if any.
seed_sha() { git -C "$1" log -1 --format=%H --diff-filter=D -- "$REL" 2>/dev/null; }

# post_body <body file> <run id> <work dir> — one POST. Prints one line and sets
# POST_OUTCOME to posted | duplicate | conflict | failed.
post_body() {
  local body="$1" run="$2" w="$3" code crc ans
  api_hdr "$w/hdr"
  code=$(curl -sS --max-time 30 -o "$w/resp" -w '%{http_code}' -X POST -H @"$w/hdr" \
    -H 'content-type: application/json' --data-binary @"$body" "$API_URL$API_PATH" 2>"$w/curl.err"); crc=$?
  rm -f "$w/hdr"
  POST_OUTCOME=failed
  if [ "$crc" != 0 ]; then
    echo "::warning::ci-durations: post of run $run failed (curl rc $crc)"
  elif [ "$code" = 409 ]; then
    POST_OUTCOME=conflict
    echo "::warning::ci-durations: run $run was already posted with other rows (HTTP 409); nothing written"
  elif [ "$code" != 200 ]; then
    ans=$(python3 -I -c 'import json,sys; print(str(json.load(open(sys.argv[1])).get("error",""))[:120])' "$w/resp" 2>/dev/null)
    echo "::warning::ci-durations: post of run $run failed (HTTP $code${ans:+: $ans})"
  elif ! ans=$(python3 -I -c '
import json, sys
b = json.load(open(sys.argv[1]))
w = b.get("written")
if b.get("ok") is not True or isinstance(w, bool) or not isinstance(w, int): sys.exit(1)
print("duplicate" if b.get("duplicate") is True else "posted %d" % w)' "$w/resp" 2>/dev/null); then
    echo "::warning::ci-durations: post of run $run answered 200 with an unreadable body"
  elif [ "$ans" = duplicate ]; then
    POST_OUTCOME=duplicate
    echo "ci-durations: run $run already posted"
  else
    POST_OUTCOME=posted
    echo "ci-durations: posted run $run: ${ans#posted } rows"
  fi
}

# valid_file <file> — every non-comment, non-blank row has a suite and a
# numeric column 2, and there is at least one row.
valid_file() {
  awk -F'\t' '/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { n++; if ($1 == "" || $2 !~ /^[0-9]+(\.[0-9]+)?$/) bad = 1 }
    END { exit (bad || n == 0) }' "$1" 2>/dev/null
}

cmd_merge() {
  local prev="" tdir="" run="" root="" out="" w f k
  while [ $# -gt 0 ]; do
    case "$1" in
      --prev) prev="${2:-}"; shift ;;
      --timings-dir) tdir="${2:-}"; shift ;;
      --run) run="${2:-}"; shift ;;
      --root) root="${2:-}"; shift ;;
      --out) out="${2:-}"; shift ;;
      *) die2 "merge: unknown argument '$1'" ;;
    esac
    shift
  done
  [ -n "$prev" ] && [ -n "$tdir" ] && [ -n "$run" ] && [ -n "$root" ] && [ -n "$out" ] \
    || die2 "merge needs --prev, --timings-dir, --run, --root and --out"
  case "$run" in *[!A-Za-z0-9._-]*) die2 "merge: --run '$run' is not a run id" ;; esac
  [ -r "$prev" ] || die2 "merge: cannot read --prev '$prev'"
  [ -d "$tdir" ] || die2 "merge: no --timings-dir '$tdir'"
  [ -d "$root" ] || die2 "merge: no --root '$root'"
  w=$(mktemp -d) || die2 "merge: mktemp failed"
  # This run's timings, in a fixed order whatever the glob gave.
  find "$tdir" -type f -name '*.tsv' -print0 | xargs -0r cat \
    | awk -F'\t' '$3 == "0" && $1 ~ /^tests\/.*\.sh$/ && $2 ~ /^[0-9]+(\.[0-9]+)?$/ { print $1 "\t" $2 }' \
    | LC_ALL=C sort > "$w/new"
  local src
  src=$(sed -n 's/^# source: //p' "$prev" | head -1)
  awk -F'\t' -v newf="$w/new" -v run="$run" '
    function med(v, n,   a, i, j, x) {
      for (i = 1; i <= n; i++) a[i] = v[i] + 0
      for (i = 2; i <= n; i++) { x = a[i]; for (j = i - 1; j >= 1 && a[j] > x; j--) a[j + 1] = a[j]; a[j + 1] = x }
      if (n % 2) return a[(n + 1) / 2]
      return (a[n / 2] + a[n / 2 + 1]) / 2
    }
    BEGIN {
      while ((getline l < newf) > 0) {
        split(l, f, "\t")
        if (!(f[1] in nv) || f[2] + 0 > nv[f[1]] + 0) nv[f[1]] = f[2]
      }
      close(newf)
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $1 == "" || $2 !~ /^[0-9]+(\.[0-9]+)?$/ { next }
    { if (!($1 in nv)) { print; seen[$1] = 1; next }
      old[$1] = ($4 != "") ? $4 : $2 }
    END {
      for (s in nv) {
        lst = sprintf("%.1f", nv[s]); n = 1; v[1] = lst
        if (s in old) {
          m = split(old[s], o, ",")
          for (i = 1; i <= m && n < 3; i++) if (o[i] ~ /^[0-9]+(\.[0-9]+)?$/) { v[++n] = sprintf("%.1f", o[i]); lst = lst "," v[n] }
        }
        printf "%s\t%.1f\t%s\t%s\n", s, med(v, n), run, lst
      }
    }' "$prev" > "$w/rows" || { rm -rf "$w"; die2 "merge: cannot compose the rows"; }
  {
    echo "# ci-suite-durations.tsv — composed by bin/ci-durations.sh merge (BH-5518); never edit by hand."
    echo "# Columns: <suite>\t<seconds>\t<run>\t<newest values>. <seconds> is the median of up to 3 values."
    echo "# composed: run $run, from ${src:-an unnamed source}"
    LC_ALL=C sort -t"$(printf '\t')" -k1,1 "$w/rows" | while IFS= read -r line; do
      k=${line%%$'\t'*}
      [ -f "$root/$k" ] && printf '%s\n' "$line"
    done
  } > "$w/out"
  mkdir -p "$(dirname "$out")" && mv "$w/out" "$out" || { rm -rf "$w"; die2 "merge: cannot write '$out'"; }
  rm -rf "$w"
  echo "ci-durations: composed $(grep -vc '^#' "$out") rows for run $run into $out"
}

cmd_fetch() {
  local out="" root gh="${CI_DURATIONS_GH:-gh}" repo="${CI_REPO:-}" wf="${CI_WORKFLOW:-Harness CI}"
  local per="${CI_DURATIONS_LOOKBACK:-50}" w why="" runs arts pick id rid sha
  root="$(cd "$SELF_DIR/.." && pwd)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="${2:-}"; shift ;;
      --root) root="${2:-}"; shift ;;
      *) die2 "fetch: unknown argument '$1'" ;;
    esac
    shift
  done
  [ -n "$out" ] || die2 "fetch needs --out"
  case "$per" in ''|*[!0-9]*) per=50 ;; esac
  mkdir -p "$(dirname "$out")" || die2 "fetch: cannot create the directory of '$out'"
  w=$(mktemp -d) || die2 "fetch: mktemp failed"
  # gh_get <file> <path>: one read; GRC is its rc, the stderr head its reason.
  gh_get() { "$gh" api "$2" > "$1" 2>"$w/err"; GRC=$?; [ "$GRC" = 0 ]; }
  gh_why() { echo "$1 failed (rc $GRC: $(head -c 200 "$w/err" | tr '\n' ' '))"; }

  # 0: the jobs worker, then the cache of its last usable answer (BH-5653).
  local cache="${CI_DURATIONS_CACHE:-${HARNESS:-/root/harness}/state/ci-durations/api.tsv}" code crc awhy=""
  if api_conf; then
    api_hdr "$w/hdr"
    code=$(curl -sS --max-time 10 -o "$w/api.json" -w '%{http_code}' -H @"$w/hdr" "$API_URL$API_PATH" 2>"$w/api.err"); crc=$?
    rm -f "$w/hdr"
    if [ "$crc" != 0 ]; then awhy="curl rc $crc"
    elif [ "$code" != 200 ]; then awhy="HTTP $code"
    elif ! python3 -I -c '
import json, math, re, sys
SUITE = re.compile(sys.argv[2])
def fail(why):
    print(why); sys.exit(1)
try:
    b = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    fail("not JSON")
if not isinstance(b, dict): fail("not a JSON object")
if b.get("truncated") is True: fail("truncated")
rows = b.get("rows")
if not isinstance(rows, list) or not rows: fail("no rows")
seen, out = set(), []
for i, r in enumerate(rows):
    if not isinstance(r, dict): fail("row %d is not an object" % i)
    s, sec, run = r.get("suite"), r.get("seconds"), r.get("source_run")
    if not isinstance(s, str) or not SUITE.match(s) or ".." in s: fail("row %d: suite is not a tests/ path" % i)
    if s in seen: fail("row %d: %s twice" % (i, s))
    seen.add(s)
    if isinstance(sec, bool) or not isinstance(sec, (int, float)) or not math.isfinite(sec) or not 0 <= sec <= 10800:
        fail("row %d: seconds out of range" % i)
    if isinstance(run, bool) or not isinstance(run, int) or run <= 0: fail("row %d: source_run is not a run id" % i)
    out.append("%s\t%s\t%d" % (s, ("%.3f" % sec).rstrip("0").rstrip("."), run))
sys.stdout.write("\n".join(sorted(out)) + "\n")
' "$w/api.json" "$SUITE_RE" > "$w/api.rows" 2>/dev/null; then
      awhy=$(head -c 200 "$w/api.rows")
      awhy=${awhy:-the answer did not parse}
    fi
    if [ -z "$awhy" ]; then
      { echo "# source: api"
        echo "# ci-suite-durations.tsv from the jobs worker's ci_suite_durations (BH-5653); <suite>\t<seconds>\t<run>"
        cat "$w/api.rows"; } > "$w/out"
      # The cache is replaced only by a usable answer, and only whole.
      if ! { mkdir -p "$(dirname "$cache")" && cp "$w/out" "$cache.tmp.$$" && mv -f "$cache.tmp.$$" "$cache"; } 2>/dev/null; then
        rm -f "$cache.tmp.$$" 2>/dev/null
        echo "ci-durations: note: cannot write the cache $cache" >&2
      fi
    elif valid_file "$cache"; then
      echo "::warning::ci-durations: the jobs worker answer is unusable ($awhy); the shard weights are its last usable answer, from the cache"
      { echo "# source: cache"; grep -v '^# source:' "$cache"; } > "$w/out"
    else
      echo "::warning::ci-durations: the jobs worker answer is unusable ($awhy), and there is no cache; reading the CI artifact chain"
    fi
  fi

  # 1-3: the artifact chain. Any failure sets $why and falls through.
  if [ -f "$w/out" ]; then :
  elif [ -z "$repo" ]; then why="CI_REPO is not set"
  elif ! command -v "$gh" >/dev/null 2>&1; then why="'$gh' is not on this runner"
  elif ! gh_get "$w/runs" "repos/$repo/actions/runs?event=pull_request&status=success&per_page=$per"; then
    why=$(gh_why "the runs read")
  elif ! runs=$(jq -c --arg wf "$wf" '[.workflow_runs[]? | select(.event == "pull_request" and .conclusion == "success"
                  and .name == $wf and ((.head_branch // "") | startswith("mergify/merge-queue/"))) | .id]' "$w/runs" 2>/dev/null); then
    why="the runs answer is not JSON"
  elif ! gh_get "$w/arts" "repos/$repo/actions/artifacts?name=ci-durations-next&per_page=$per"; then
    why=$(gh_why "the artifacts read")
  elif ! pick=$(jq -r --argjson ok "$runs" '[.artifacts[]? | select(.name == "ci-durations-next" and (.expired | not)
                  and ((.workflow_run.id // -1) as $r | any($ok[]; . == $r)))] | sort_by(.created_at, .id) | last
                  | if . == null then "" else "\(.id) \(.workflow_run.id)" end' "$w/arts" 2>/dev/null); then
    why="the artifacts answer is not JSON"
  elif [ -z "$pick" ]; then
    why="no unexpired ci-durations-next artifact from a green merge-queue batch"
  else
    id=${pick% *}; rid=${pick#* }
    case "$id$rid" in *[!0-9]*) why="artifact ids are not numeric ('$pick')" ;; esac
  fi
  if [ -z "$why" ] && [ ! -f "$w/out" ]; then
    if ! gh_get "$w/zip" "repos/$repo/actions/artifacts/$id/zip"; then
      why=$(gh_why "the zip read of artifact $id")
    elif ! python3 -I -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    data = z.read("ci-durations.tsv")
sys.stdout.buffer.write(data)
' "$w/zip" > "$w/member" 2>/dev/null; then
      why="artifact $id has no readable ci-durations.tsv"
    elif ! valid_file "$w/member"; then
      why="artifact $id has a row with no numeric seconds"
    else
      { echo "# source: artifact run $rid"; cat "$w/member"; } > "$w/out"
    fi
  fi

  # Fallback 1: the seed, the file's last committed copy.
  if [ ! -f "$w/out" ]; then
    sha=$(seed_sha "$root")
    if [ -n "$sha" ] && git -C "$root" show "$sha^:$REL" > "$w/seed" 2>/dev/null && valid_file "$w/seed"; then
      { echo "# source: seed $sha"; cat "$w/seed"; } > "$w/out"
      echo "::warning::ci-durations: $why; the shard weights are the seed, the last committed copy (${sha:0:12})"
    else
      { echo "# source: none"
        echo "# ci-suite-durations.tsv — no artifact and no seed; every suite weighs the same."; } > "$w/out"
      echo "::warning::ci-durations: $why, and no seed in git history; every suite weighs the same (round-robin split)"
    fi
  fi
  if mv "$w/out" "$out"; then
    echo "ci-durations: $(head -1 "$out" | sed 's/^# //') -> $out ($(grep -vc '^#' "$out") rows)"
  else
    echo "::warning::ci-durations: cannot write $out"
  fi
  rm -rf "$w"
  return 0
}

cmd_post() {
  local run="" tdir="" w
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-id) run="${2:-}"; shift ;;
      --timings-dir) tdir="${2:-}"; shift ;;
      *) die2 "post: unknown argument '$1'" ;;
    esac
    shift
  done
  [ -n "$run" ] && [ -n "$tdir" ] || die2 "post needs --run-id and --timings-dir"
  case "$run" in 0*|*[!0-9]*) die2 "post: --run-id '$run' is not a positive run id" ;; esac
  if ! api_conf; then
    echo "ci-durations: post skipped, not configured (no JOBS_URL or token)"
    return 0
  fi
  w=$(mktemp -d) || die2 "post: mktemp failed"
  [ -d "$tdir" ] && find "$tdir" -type f -name '*.tsv' -print0 | LC_ALL=C sort -z | xargs -0r cat > "$w/rows"
  : >> "$w/rows"
  if ! python3 -I -c '
import json, re, sys
SUITE, NUM = re.compile(sys.argv[2]), re.compile(r"^[0-9]+(\.[0-9]+)?$")
best = {}
for line in open(sys.argv[3], encoding="utf-8", errors="replace"):
    f = line.rstrip("\n").split("\t")
    if len(f) < 3 or f[2] != "0" or not SUITE.match(f[0]) or ".." in f[0] or not NUM.match(f[1]):
        continue
    v = float(f[1])
    if f[0] not in best or v > best[f[0]]:
        best[f[0]] = v
if not best:
    sys.exit(3)
print(json.dumps({"run_id": int(sys.argv[1]), "source": "ci",
                  "rows": [{"suite": k, "seconds": best[k]} for k in sorted(best)]}))
' "$run" "$SUITE_RE" "$w/rows" > "$w/body" 2>/dev/null; then
    echo "ci-durations: post skipped, no timings"
    rm -rf "$w"; return 0
  fi
  post_body "$w/body" "$run" "$w"
  rm -rf "$w"
  return 0
}

cmd_seed() {
  local file="" root dry=0 w label sha runs rows posted=0 dup=0 refused=0 line run
  root="$(cd "$SELF_DIR/.." && pwd)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) file="${2:-}"; shift ;;
      --root) root="${2:-}"; shift ;;
      --dry-run) dry=1 ;;
      *) die2 "seed: unknown argument '$1'" ;;
    esac
    shift
  done
  w=$(mktemp -d) || die2 "seed: mktemp failed"
  if [ -n "$file" ]; then
    cp "$file" "$w/in" 2>/dev/null || { rm -rf "$w"; die2 "seed: cannot read --file '$file'"; }
    label="$file"
  else
    sha=$(seed_sha "$root")
    { [ -n "$sha" ] && git -C "$root" show "$sha^:$REL" > "$w/in" 2>/dev/null; } \
      || { rm -rf "$w"; die2 "seed: no seed in the git history of '$root' (give --file)"; }
    label="seed ${sha:0:12}"
  fi
  valid_file "$w/in" || { rm -rf "$w"; die2 "seed: $label has no rows, or a row with no numeric seconds"; }
  # One JSON body per source run (column 3), in run order. A row whose run is
  # not a positive integer, or whose suite the worker would refuse, is counted
  # and left out: one bad row would make the worker refuse its whole run.
  python3 -I -c '
import json, re, sys
SUITE = re.compile(sys.argv[2])
runs, skipped = {}, 0
for line in open(sys.argv[1], encoding="utf-8"):
    if line.lstrip().startswith("#") or not line.strip():
        continue
    f = line.rstrip("\n").split("\t")
    if len(f) < 3 or not re.fullmatch(r"[1-9][0-9]*", f[2]) or not SUITE.match(f[0]) or ".." in f[0]:
        skipped += 1
        continue
    v = float(f[1])
    runs.setdefault(int(f[2]), {})[f[0]] = int(v) if v.is_integer() else v
for run in sorted(runs):
    rows = runs[run]
    print(json.dumps({"run_id": run, "source": "seed", "rows": [{"suite": k, "seconds": rows[k]} for k in sorted(rows)]}))
print("skipped %d" % skipped, file=sys.stderr)
' "$w/in" "$SUITE_RE" > "$w/bodies" 2> "$w/skipped" || { rm -rf "$w"; die2 "seed: cannot build the bodies from $label"; }
  runs=$(grep -c . "$w/bodies")
  rows=$(python3 -I -c 'import json,sys; print(sum(len(json.loads(l)["rows"]) for l in open(sys.argv[1]) if l.strip()))' "$w/bodies")
  if [ "$dry" = 1 ]; then
    cat "$w/bodies"
    echo "ci-durations: seed --dry-run: $runs runs, $rows rows from $label, $(sed -n 's/^skipped //p' "$w/skipped") rows left out; nothing sent" >&2
    rm -rf "$w"; return 0
  fi
  if ! api_conf; then
    rm -rf "$w"
    echo "ci-durations: seed needs JOBS_URL and a token (CI_DURATIONS_TOKEN or HARNESS_SECRET)" >&2
    return 1
  fi
  echo "ci-durations: seed from $label, $(sed -n 's/^skipped //p' "$w/skipped") rows left out"
  while IFS= read -r line; do
    printf '%s\n' "$line" > "$w/body"
    run=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_id"])' "$w/body")
    post_body "$w/body" "$run" "$w"
    case "$POST_OUTCOME" in
      posted) posted=$((posted + 1)) ;;
      duplicate) dup=$((dup + 1)) ;;
      *) refused=$((refused + 1)) ;;
    esac
  done < "$w/bodies"
  rm -rf "$w"
  echo "ci-durations: seed: $runs runs, $rows rows: $posted posted, $dup already posted, $refused refused"
  [ "$refused" = 0 ]
}

case "${1:-}" in
  merge) shift; cmd_merge "$@" ;;
  fetch) shift; cmd_fetch "$@" ;;
  post) shift; cmd_post "$@" ;;
  seed) shift; cmd_seed "$@" ;;
  -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0" ;;
  *) die2 "usage: ci-durations.sh merge|fetch|post|seed ... (--help)" ;;
esac
