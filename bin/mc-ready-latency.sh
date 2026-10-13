#!/bin/bash
# bin/mc-ready-latency.sh — how long a READY PR waited to be enqueued (BH-5521).
#
#   bin/mc-ready-latency.sh [--since <YYYY-MM-DD[THH:MM]>] [--until <...>]
#                           [--repo <owner/repo>] [--max <n>] [--target-s <s>] [--no-github]
#
# A REPORT, not a gate: read-only, it writes no state, sends no alert and
# changes no row. Defaults: the last 24 h, every repo, --max 40, --target-s 120.
#
# WHAT IT READS. Every `<prev> -> QUEUED head=<h8>` transition in
# logs/merge-conductor.log inside the window (the writer is mc_transition in
# bin/lib/mc/settle.sh), one row per (PR, head), the first QUEUED line kept.
#   ready_log_s  QUEUED time minus the first `-> READY head=<same h8>` line of
#                that PR at or before it; `-` when there is none. The conductor
#                writes that line in the same tick that enqueues, so it hides
#                the wait for the tick.
#   green_s      QUEUED time minus the moment the head's last gate went green on
#                GitHub: the latest successful commit status (never
#                prequeue-verdict, which the conductor publishes itself at read
#                time), green check run, or this PR's pre-queue run for the head,
#                at or before the enqueue. `unread` when a read failed, `capped`
#                past --max, `-` with --no-github or when no gate went green.
#                An unread row is never counted as 0 s.
#
# OUTPUT. A header, one TSV row per PR (newest first), then one line:
#   READY_TO_QUEUED window=<since>..<until> n= measured= unread= capped=
#     p50= p90= max= over_<t>s= target_p90_<t>s=<met|missed> nogreen= [INCOMPLETE]
# Percentiles are nearest-rank over the measured rows only. `met` needs at
# least one measured row. INCOMPLETE is added on any unread or capped row.
# No QUEUED transition in the window: `INCOMPLETE: no QUEUED transition in the
# window`, rc 3. The log is the current file only; a window older than it is
# that same answer, never an invented number.
#
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
SINCE=""; UNTIL=""; REPO=""; MAX=40; TARGET=120; GH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --since)    [ $# -ge 2 ] || usage; SINCE="$2"; shift 2 ;;
    --until)    [ $# -ge 2 ] || usage; UNTIL="$2"; shift 2 ;;
    --repo)     [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --max)      [ $# -ge 2 ] || usage; MAX="$2"; shift 2 ;;
    --target-s) [ $# -ge 2 ] || usage; TARGET="$2"; shift 2 ;;
    --no-github) GH=0; shift ;;
    -h|--help)  usage ;;
    *) echo "mc-ready-latency: unknown argument '$1'" >&2; usage ;;
  esac
done
[[ "$MAX" =~ ^[0-9]+$ ]] || { echo "mc-ready-latency: --max must be a number" >&2; exit 2; }
[[ "$TARGET" =~ ^[0-9]+$ ]] || { echo "mc-ready-latency: --target-s must be a number" >&2; exit 2; }
[ -z "$REPO" ] || [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "mc-ready-latency: --repo must be owner/repo" >&2; exit 2; }

epoch() { [ -n "$1" ] || return 1; date -u -d "$1" +%s 2>/dev/null; }
NOW_S=$(date -u +%s)
if [ -n "$UNTIL" ]; then U_S=$(epoch "$UNTIL") || { echo "mc-ready-latency: cannot read --until '$UNTIL'" >&2; exit 2; }; else U_S=$NOW_S; fi
if [ -n "$SINCE" ]; then S_S=$(epoch "$SINCE") || { echo "mc-ready-latency: cannot read --since '$SINCE'" >&2; exit 2; }; else S_S=$((U_S - 86400)); fi
WIN="$(date -u -d "@$S_S" +%FT%TZ)..$(date -u -d "@$U_S" +%FT%TZ)"

LOG="$H/logs/merge-conductor.log"
# key  head8  queued_epoch  ready_epoch|-   (newest QUEUED first)
ROWS=$(awk -v s="$S_S" -v u="$U_S" -v repo="${REPO,,}" '
  # Days from 1970-01-01 for a civil date (no mktime: mawk has none).
  function ep(d, t,   a, b, y, m, era, yoe, doy, doe) {
    split(d, a, "-"); split(t, b, ":"); sub(/Z$/, "", b[3])
    y = a[1] - (a[2] <= 2); m = a[2] + 0
    era = int(y / 400); yoe = y - era * 400
    doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + a[3] - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return (era * 146097 + doe - 719468) * 86400 + b[1] * 3600 + b[2] * 60 + b[3]
  }
  $5 == "->" && $7 ~ /^head=/ {
    key = $3; k = tolower(key); rp = k; sub(/#[0-9]+$/, "", rp)
    if (repo != "" && rp != repo) next
    h = substr($7, 6); t = ep($1, $2)
    if ($6 == "READY" && !((k, h) in ready)) ready[k, h] = t
    if ($6 == "QUEUED" && t >= s && t <= u && !((k, h) in seen)) {
      seen[k, h] = 1; n++; K[n] = key; Hd[n] = h; Q[n] = t
      R[n] = ((k, h) in ready && ready[k, h] <= t) ? ready[k, h] : "-"
    }
  }
  END { for (i = n; i >= 1; i--) printf "%s\t%s\t%s\t%s\n", K[i], Hd[i], Q[i], R[i] }' "$LOG" 2>/dev/null)

if [ -z "$ROWS" ]; then echo "INCOMPLETE: no QUEUED transition in the window"; exit 3; fi

if [ "$GH" = 1 ]; then
  # shellcheck source=bin/lib/env-path.sh
  . "$SELF/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
  HENV=$(harness_env_dir "$H")
  # shellcheck disable=SC1091
  [ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
  # shellcheck source=bin/lib/gh-rest.sh
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || { echo "mc-ready-latency: bin/lib/gh-rest.sh unavailable — use --no-github" >&2; exit 2; }
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/mc-ready-latency.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

# green_at <slug> <n> <h8> <queued-epoch> — print the epoch of the latest green
# gate on the head at or before the enqueue, `-` for none; rc 2 on a failed read.
green_at() {
  local slug="$1" n="$2" h="$3" q="$4" st ck pq runs_f
  gh_rest GET "repos/$slug/commits/$h/status" > "$TMP/st" || return 2
  gh_rest GET "repos/$slug/commits/$h/check-runs?per_page=100" > "$TMP/ck" || return 2
  runs_f="$TMP/runs-$(printf %s "$slug" | tr '/' '_')"
  if [ ! -f "$runs_f" ]; then
    gh_rest GET "repos/$slug/actions/workflows/prequeue-gate.yml/runs?event=workflow_dispatch&per_page=100" > "$runs_f.tmp" \
      || { rm -f "$runs_f.tmp"; return 2; }
    mv -f "$runs_f.tmp" "$runs_f"
  fi
  st=$(jq -r '.statuses[]? | select(.state=="success" and .context!="prequeue-verdict") | .updated_at // empty' "$TMP/st" 2>/dev/null) || return 2
  ck=$(jq -r '.check_runs[]? | select(.conclusion=="success" or .conclusion=="neutral" or .conclusion=="skipped") | .completed_at // empty' "$TMP/ck" 2>/dev/null) || return 2
  pq=$(jq -r --arg p "prequeue pr=$n head=$h" '.workflow_runs[]? | select(.conclusion=="success")
         | select((.display_title // "") | startswith($p)) | .updated_at // empty' "$runs_f" 2>/dev/null) || return 2
  printf '%s\n%s\n%s\n' "$st" "$ck" "$pq" | grep -E '^[0-9]{4}-' | while IFS= read -r t; do epoch "$t"; done \
    | awk -v q="$q" '$1 <= q && $1 > m { m = $1 } END { print (m ? m : "-") }'
}

printf 'key\thead\tqueued_at\tready_log_s\tgreen_s\n'
n=0; measured=0; unread=0; capped=0; nogreen=0; : > "$TMP/vals"
while IFS=$'\t' read -r key h8 q r; do
  [ -n "$key" ] || continue
  n=$((n+1))
  rl="-"; [ "$r" != "-" ] && rl=$((q - r))
  g="-"
  if [ "$GH" = 1 ]; then
    if [ "$n" -gt "$MAX" ]; then g=capped; capped=$((capped+1))
    elif tg=$(green_at "${key%#*}" "${key##*#}" "$h8" "$q"); then
      if [ "$tg" = "-" ]; then nogreen=$((nogreen+1))
      else g=$((q - tg)); [ "$g" -lt 0 ] && g=0; measured=$((measured+1)); echo "$g" >> "$TMP/vals"; fi
    else g=unread; unread=$((unread+1)); fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$h8" "$(date -u -d "@$q" +%FT%TZ)" "$rl" "$g"
done <<<"$ROWS"

# Nearest-rank percentiles over the measured rows only.
read -r p50 p90 mx over < <(sort -n "$TMP/vals" | awk -v t="$TARGET" '
  { v[NR] = $1; if ($1 > t) o++ }
  function nr(p,   k) { k = int((p * NR + 99) / 100); if (k < 1) k = 1; return v[k] }
  END { if (NR == 0) { print "- - - 0"; exit } print nr(50), nr(90), v[NR], o + 0 }')
target=missed
[ "$measured" -ge 1 ] && [ "$p90" -le "$TARGET" ] && target=met
line="READY_TO_QUEUED window=$WIN n=$n measured=$measured unread=$unread capped=$capped p50=$p50 p90=$p90 max=$mx over_${TARGET}s=$over target_p90_${TARGET}s=$target nogreen=$nogreen"
[ $((unread + capped)) -gt 0 ] && line="$line INCOMPLETE"
echo "$line"
exit 0
