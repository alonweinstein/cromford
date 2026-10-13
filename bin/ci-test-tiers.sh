#!/bin/bash
# bin/ci-test-tiers.sh fetch|put — catalog/test-tiers.tsv as data in the jobs
# worker (BH-5653 slice C1). docs/ci-test-tiers.md has the design.
#
# A tier SET is one whole snapshot of the tier file plus the git blob sha of
# the committed catalog/test-tiers.tsv it was based on. The worker keeps every
# set and answers the newest (GET/PUT /api/ci/test-tiers).
#
#   fetch --out <file> [--root <checkout>]
#       Writes ONE tier file in the catalog's own 5-column format for
#       bin/ci-plan.sh (CI_PLAN_TIER_FILE). First line `# source: <what>`:
#         api set <id> base <blob>    the worker's newest set, USED only when
#                                     its base_blob is <blob>, the blob of
#                                     catalog/test-tiers.tsv at HEAD of --root,
#                                     and `bin/test-tiers.sh check` accepts it.
#                                     It is then copied to the cache by an
#                                     atomic rename.
#         cache set <id> base <blob>  the worker answer was unusable (HTTP
#                                     error, not JSON, a dead worker, a failed
#                                     check) and the cache names <blob> and
#                                     passes check.
#         committed <blob>            everything else: not configured (no
#                                     request is sent), `{"set":null}` (one
#                                     ::notice::), a set on another blob (the
#                                     committed file changed since; one
#                                     ::warning:: naming both), or an unusable
#                                     answer with no usable cache (one
#                                     ::warning::). A bad answer never
#                                     overwrites the cache.
#       ALWAYS rc 0 (rc 2 only on a bad argument): the tier file decides which
#       suites a batch skips, so every unknown falls back to the reviewed copy
#       in git, and a dead worker never stops CI.
#   put [--file <tsv>] [--root <checkout>] [--source seed|operator] [--dry-run]
#       Stores <tsv> (default: <root>/catalog/test-tiers.tsv) as a new set,
#       base_blob the blob of catalog/test-tiers.tsv at HEAD of --root, actor
#       this host's name, source default `seed`. Runs `bin/test-tiers.sh check`
#       on it first and refuses (rc 1) on a fail. --dry-run prints the JSON body
#       and sends nothing. Prints `stored set <id>` on a 201, `duplicate: set
#       <id>` when the newest set is already this one (rc 0 both); anything else
#       is rc 1. Needs HARNESS_SECRET: CI's scoped token can only read.
#
# The worker: JOBS_URL and a bearer. fetch uses CI_DURATIONS_TOKEN (CI's scoped
# token) or HARNESS_SECRET; put uses HARNESS_SECRET only. When JOBS_URL is not
# set at all, both are read from the harness env's global.env, as
# bin/ci-durations.sh does; a JOBS_URL that is set, even empty, is the caller's
# answer and no file is read. The bearer reaches curl through a mode-600 header
# file, never argv, and is never printed.
# The cache: CI_TEST_TIERS_CACHE, default <harness>/state/ci-test-tiers/api.tsv.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REL=catalog/test-tiers.tsv
API_PATH=/api/ci/test-tiers
die2() { echo "ci-test-tiers: $*" >&2; exit 2; }

# api_conf <fetch|put> — set API_URL and API_TOK; rc 0 only when both are set.
api_conf() {
  local url="${JOBS_URL-}" tok gf
  if [ "$1" = put ]; then tok="${HARNESS_SECRET:-}"; else tok="${CI_DURATIONS_TOKEN:-${HARNESS_SECRET:-}}"; fi
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

# tiers_ok <file> <root> — bin/test-tiers.sh check accepts the file.
tiers_ok() { "$SELF_DIR/test-tiers.sh" check --tiers "$1" --root "$2" >/dev/null 2>&1; }

cmd_fetch() {
  local out="" root w blob="" code crc awhy="" src="" sid sbase
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
  mkdir -p "$(dirname "$out")" || die2 "fetch: cannot create the directory of '$out'"
  w=$(mktemp -d) || die2 "fetch: mktemp failed"
  local cache="${CI_TEST_TIERS_CACHE:-${HARNESS:-/root/harness}/state/ci-test-tiers/api.tsv}"
  blob=$(git -C "$root" rev-parse "HEAD:$REL" 2>/dev/null) || blob=""

  if [ -z "$blob" ]; then
    echo "::warning::ci-test-tiers: no blob for $REL at HEAD of $root; using the file as it is"
  elif api_conf fetch; then
    api_hdr "$w/hdr"
    code=$(curl -sS --max-time 10 -o "$w/api.json" -w '%{http_code}' -H @"$w/hdr" "$API_URL$API_PATH" 2>"$w/api.err"); crc=$?
    rm -f "$w/hdr"
    if [ "$crc" != 0 ]; then awhy="curl rc $crc"
    elif [ "$code" != 200 ]; then awhy="HTTP $code"
    # Prints `null`, or `<id> <base_blob>` and writes the rows to api.rows.
    elif ! sid=$(python3 -I -c '
import json, re, sys
SUITE, BLOB = re.compile(r"^tests/[A-Za-z0-9._/-]+\.sh$"), re.compile(r"^[0-9a-f]{40}$")
def fail(why):
    print(why); sys.exit(1)
try:
    b = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    fail("not JSON")
if not isinstance(b, dict) or "set" not in b: fail("no set in the answer")
s = b["set"]
if s is None:
    print("null"); sys.exit(0)
if not isinstance(s, dict): fail("set is not an object")
sid, base, rows = s.get("id"), s.get("base_blob"), s.get("rows")
if isinstance(sid, bool) or not isinstance(sid, int) or sid <= 0: fail("set id is not a positive integer")
if not isinstance(base, str) or not BLOB.match(base): fail("set %d: base_blob is not a blob sha" % sid)
if not isinstance(rows, list) or not rows: fail("set %d has no rows" % sid)
out = []
for i, r in enumerate(rows):
    if not isinstance(r, dict): fail("row %d is not an object" % i)
    f = [r.get("suite"), r.get("tier"), r.get("runtime_s"), r.get("paths"), r.get("reason")]
    if not isinstance(f[0], str) or not SUITE.match(f[0]) or ".." in f[0]: fail("row %d: suite is not a tests/ path" % i)
    if isinstance(f[2], bool) or not isinstance(f[2], int) or f[2] < 0: fail("row %d: runtime_s is not whole seconds" % i)
    f[2] = str(f[2])
    for v in (f[1], f[3], f[4]):
        if not isinstance(v, str) or not v or any(c in v for c in "\t\r\n"): fail("row %d: a field is empty or has a tab or newline" % i)
    out.append("\t".join(f))
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write("\n".join(sorted(out)) + "\n")
print("%d %s" % (sid, base))
' "$w/api.json" "$w/api.rows" 2>/dev/null); then
      awhy=${sid:-the answer did not parse}
    elif [ "$sid" = null ]; then
      echo "::notice::ci-test-tiers: no tier set in the worker; using the committed $REL"
    else
      sbase=${sid#* }; sid=${sid%% *}
      if [ "$sbase" != "$blob" ]; then
        echo "::warning::ci-test-tiers: tier set $sid is based on $sbase; the committed file changed (now $blob), so the committed $REL is used"
      else
        { echo "# source: api set $sid base $blob"
          echo "# test-tiers.tsv from the jobs worker's ci_test_tier_sets (BH-5653); <suite>\t<tier>\t<runtime_s>\t<paths>\t<reason>"
          cat "$w/api.rows"; } > "$w/api.tsv"
        if tiers_ok "$w/api.tsv" "$root"; then
          src=api
          cp "$w/api.tsv" "$w/out"
          # The cache is replaced only by a usable answer, and only whole.
          if ! { mkdir -p "$(dirname "$cache")" && cp "$w/out" "$cache.tmp.$$" && mv -f "$cache.tmp.$$" "$cache"; } 2>/dev/null; then
            rm -f "$cache.tmp.$$" 2>/dev/null
            echo "ci-test-tiers: note: cannot write the cache $cache" >&2
          fi
        else
          awhy="tier set $sid fails bin/test-tiers.sh check"
        fi
      fi
    fi
    if [ -n "$awhy" ]; then
      # The cache: its first line must name this blob, and it must still pass check.
      if [ "$(sed -n '1s/^# source: api set [0-9]* base //p' "$cache" 2>/dev/null)" = "$blob" ] && tiers_ok "$cache" "$root"; then
        src=cache
        { sed -n '1s/^# source: api /# source: cache /p' "$cache"; tail -n +2 "$cache"; } > "$w/out"
        echo "::warning::ci-test-tiers: the jobs worker answer is unusable ($awhy); using the cache of its last usable answer"
      else
        echo "::warning::ci-test-tiers: the jobs worker answer is unusable ($awhy); using the committed $REL"
      fi
    fi
  fi

  if [ -z "$src" ]; then
    if [ -r "$root/$REL" ]; then
      { echo "# source: committed ${blob:-(no blob)}"; cat "$root/$REL"; } > "$w/out"
    else
      # No tier file at all: every suite is batch (bin/test-tiers.sh's fail-safe).
      echo "# source: none" > "$w/out"
      echo "::warning::ci-test-tiers: no $REL under $root; every suite runs in the batch"
    fi
  fi
  if mv "$w/out" "$out"; then
    echo "ci-test-tiers: $(head -1 "$out" | sed 's/^# //') -> $out ($(grep -Ecv '^[[:space:]]*(#|$)' "$out") rows)"
  else
    echo "::warning::ci-test-tiers: cannot write $out"
  fi
  rm -rf "$w"
  return 0
}

cmd_put() {
  local file="" root source=seed dry=0 w blob actor code crc ans
  root="$(cd "$SELF_DIR/.." && pwd)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) file="${2:-}"; shift ;;
      --root) root="${2:-}"; shift ;;
      --source) source="${2:-}"; shift ;;
      --dry-run) dry=1 ;;
      *) die2 "put: unknown argument '$1'" ;;
    esac
    shift
  done
  case "$source" in seed|operator) ;; *) die2 "put: --source must be seed or operator (got '$source')" ;; esac
  file="${file:-$root/$REL}"
  if ! "$SELF_DIR/test-tiers.sh" check --tiers "$file" --root "$root" > /dev/null 2>"/dev/null"; then
    echo "ci-test-tiers: put refused: bin/test-tiers.sh check fails on $file:"
    "$SELF_DIR/test-tiers.sh" check --tiers "$file" --root "$root" 2>&1 | sed 's/^/  /'
    return 1
  fi
  blob=$(git -C "$root" rev-parse "HEAD:$REL" 2>/dev/null) \
    || { echo "ci-test-tiers: put refused: no blob for $REL at HEAD of $root"; return 1; }
  actor=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9._@-' | cut -c1-64)
  w=$(mktemp -d) || die2 "put: mktemp failed"
  if ! python3 -I -c '
import json, sys
rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    if not line.strip() or line.lstrip().startswith("#"): continue
    f = line.rstrip("\n").split("\t")
    rows.append({"suite": f[0], "tier": f[1], "runtime_s": int(f[2]), "paths": f[3], "reason": f[4]})
print(json.dumps({"base_blob": sys.argv[2], "source": sys.argv[3], "actor": sys.argv[4],
                  "rows": sorted(rows, key=lambda r: r["suite"])}))
' "$file" "$blob" "$source" "${actor:-unknown}" > "$w/body" 2>"$w/err"; then
    echo "ci-test-tiers: put refused: cannot read the rows of $file: $(tail -1 "$w/err")"
    rm -rf "$w"; return 1
  fi
  if [ "$dry" = 1 ]; then
    cat "$w/body"; rm -rf "$w"; return 0
  fi
  if ! api_conf put; then
    if [ -z "$API_TOK" ]; then echo "ci-test-tiers: put needs HARNESS_SECRET (CI's scoped token can only read)"
    else echo "ci-test-tiers: put needs JOBS_URL"; fi
    rm -rf "$w"; return 1
  fi
  api_hdr "$w/hdr"
  code=$(curl -sS --max-time 30 -o "$w/resp" -w '%{http_code}' -X PUT -H @"$w/hdr" \
    -H 'content-type: application/json' --data-binary @"$w/body" "$API_URL$API_PATH" 2>"$w/curl.err"); crc=$?
  rm -f "$w/hdr"
  # `stored <id>` on a 201, `duplicate <id>` on a 200 duplicate; nothing else.
  ans=$(python3 -I -c '
import json, sys
b, code = json.load(open(sys.argv[1])), sys.argv[2]
i = b.get("id")
if isinstance(i, bool) or not isinstance(i, int) or i <= 0: sys.exit(1)
if code == "201": print("stored %d" % i)
elif code == "200" and b.get("duplicate") is True: print("duplicate %d" % i)
else: sys.exit(1)' "$w/resp" "$code" 2>/dev/null)
  local rc=0 n
  n=$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["rows"]))' "$w/body")
  if [ "$crc" != 0 ]; then
    echo "ci-test-tiers: put failed (curl rc $crc)"; rc=1
  elif [ "${ans%% *}" = stored ]; then
    echo "ci-test-tiers: stored set ${ans#* } ($n rows, base $blob, source $source)"
  elif [ "${ans%% *}" = duplicate ]; then
    echo "ci-test-tiers: duplicate: set ${ans#* } is already these $n rows on base $blob; nothing written"
  else
    ans=$(python3 -I -c 'import json,sys; print(str(json.load(open(sys.argv[1])).get("error",""))[:160])' "$w/resp" 2>/dev/null)
    echo "ci-test-tiers: put failed (HTTP $code${ans:+: $ans})"; rc=1
  fi
  rm -rf "$w"
  return "$rc"
}

case "${1:-}" in
  fetch) shift; cmd_fetch "$@" ;;
  put) shift; cmd_put "$@" ;;
  -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
  *) die2 "usage: bin/ci-test-tiers.sh fetch --out <file> [--root <dir>] | put [--file <tsv>] [--root <dir>] [--source seed|operator] [--dry-run]" ;;
esac
