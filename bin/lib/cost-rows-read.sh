#!/bin/bash
# bin/lib/cost-rows-read.sh — the ONE reader of the harness-jobs `cost_rows`
# table, and the reason no cost lane needs an ssh session any more (BH-1032,
# State→DB slice 7).
#
# WHY THIS FILE EXISTS. Four hub lanes answer "what did the fleet spend" by
# reaching across the tailnet for each box's logs/cost.csv:
# bin/cost-rollup.sh ssh'd seven boxes twice an hour (~30 ssh/hr),
# bin/cap-loss-detector.sh scp's three files a day, bin/pipeline-health.sh
# tails 1500 lines per box, bin/cost-reconcile.sh diffs the CSVs. Every one of
# those reads the SAME rows the boxes have been mirroring into `cost_rows` since
# 2026-09-02, so the scrape is a second, slower, less complete copy of a fact
# the DB already holds — and the one that breaks first, because a box that is
# unreachable reads as a box that spent nothing.
#
# Callers: bin/cost-rollup.sh (BH-1032), and since BH-2527 the fleet ceiling in
# bin/pipeline-health.sh, bin/cap-loss-detector.sh (failovers are cost_rows
# fields: a claude row with rc != 0), bin/cost-report.sh and
# bin/cost-readout.sh. None of them reaches a box over the tailnet any more;
# tests/cost-readers-no-ssh.bh-2527-test.sh is the ratchet that keeps it so.
# bin/cost-reconcile.sh reads the same route through its own api_get.
#
# THE SHAPE IS THE CSV'S SHAPE, ON PURPOSE. cost_rows_fetch writes a file with
# bin/lib/cost-row.sh's COST_ROW_HDR header and rows in that column order, so a
# caller swaps ONE collection block and keeps its existing awk/csv.DictReader
# parsing byte for byte. tests/rollup-from-rows-test.sh pins exactly that: the
# rollup's fleet-cost.csv built from the DB equals the one built from the files.
#
# HOW A ROW COMES BACK EXACTLY AS IT WENT IN. cost_rows carries `raw`, the
# verbatim CSV line the box appended (added additively in this same slice). A
# row that has it is re-emitted verbatim — no float reformatting can turn a
# `4.00` into a `4` and no reader downstream can see a difference. A row pushed
# by a client that predates `raw` (every row already in the table) is
# RECONSTRUCTED from its columns and re-emitted, which is the honest degradation:
# the values are right, the text of a number may not be.
#
# FAIL LOUD, NEVER AS ZERO. Every function here returns non-zero and logs one
# line rather than printing a half file. There is no ssh fallback behind it any
# more (BH-2527): each caller NAMES the unreadable table instead — the rollup
# ALERTs and leaves state/cost/ untouched, the ceiling brakes on the local
# ledger labelled LOCAL ONLY, cap-loss logs the day as NOT measured, the
# reports exit 75. A zero that came from an unreachable table is the exact
# failure this file was written to delete.
#
#   cost_rows_db_enabled                       — is the DB read armed?
#   cost_rows_fetch <out> [since] [until] [box] — write a COST_ROW_HDR csv
#
# TWO SIDE FILES, BECAUSE A CALLER THAT ALSO HOLDS FILES HAS TO MERGE THEM.
# cost_rows_fetch writes, beside <out>:
#
#   <out>.boxes   one line per box seen in the window: `box\trows\tlatest_ts`.
#                 A box that is pushing is a box that appears here; a box with a
#                 cron line and no line here is a stuck push lane, and until
#                 BH-1032's review nothing named it (the failure this file's
#                 header calls out simply MOVED from the tailnet to the cursor).
#
# and reads, before it writes anything:
#
#   COST_ROWS_SKIP_HASHES=<file>   one row_hash per line. A row whose hash is in
#                 that set is NOT emitted — the caller already holds that exact
#                 line, verbatim, from a file. This is what keeps a merge of
#                 "the table" and "the files" from counting a call twice: the
#                 two copies are only collapsible by `sort -u` when their TEXT
#                 matches, and a row pushed before `raw` existed comes back
#                 RECONSTRUCTED (`1.250000` -> `1.25`, `0.000010` -> `1e-05`),
#                 so `sort -u` keeps both and every sum over the merged file is
#                 high. The hash is the table's own PK half — exact, no
#                 formatting guesswork — and the FILE's line wins, which is what
#                 keeps the merged file byte-identical to the scraped one.
#
# KNOBS (DB-driven, file as the derived cache — the harness flag convention):
#   COST_ROWS_FROM_DB=0                  env/global.env or the environment
#   switch.cost-rows-from-db-off[.<box>] a settings row (BH-2433), which wins;
#   flags/cost-rows-from-db-off          with no row, the file answers, for a
#                                        box you cannot restart
#   COST_ROWS_READ_LIMIT                 rows per request (default 2000, the
#                                        worker's own ceiling for this route,
#                                        and CLAMPED to it here: the route
#                                        answers Math.min(limit, 2000), so a
#                                        larger number made `got < lim` true on
#                                        a FULL page and stopped the walk after
#                                        one — a short window reported whole,
#                                        which is the exact failure this
#                                        reader's paging exists to prevent)
#   COST_ROWS_READ_PAGES                 page ceiling (default 200 = 400k rows
#                                        at the default limit), so a wide window
#                                        cannot loop forever. Sized ABOVE the
#                                        fleet's 30-day row count on purpose: a
#                                        ceiling the normal window trips is a
#                                        ceiling that turns the DB read off
#                                        permanently and silently.

# The canonical 26 names (guard_fp last, BH-2537). Sourced beside bin/lib/cost-row.sh this is already
# set; standalone (cap-loss-detector sources only this file) it must still be
# right, so the literal is carried here the same way bin/cost-rollup.sh carries
# its own copy — a box mid-sync must not have to guess.
COST_ROWS_READ_HDR="${COST_ROW_HDR:-ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp}"

# _cost_rows_root — HARNESS, else H, else (run directly only, contract rule 3)
# this file's own install root; "" when sourced with neither (BH-2649).
_CRR_SELF=""
[ "${BASH_SOURCE[0]}" = "$0" ] && _CRR_SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
_cost_rows_root() { printf '%s' "${HARNESS:-${H:-${_CRR_SELF:-}}}"; }

# One line into the box's own rules log, never stderr: these run under cron.
# No root, no log.
_cost_rows_log() {
  local _h; _h=$(_cost_rows_root)
  [ -n "$_h" ] || return 0
  mkdir -p "$_h/logs" 2>/dev/null
  { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [cost-rows-read] $*" >> "$_h/logs/agent-rules.log"; } 2>/dev/null || true
}

# lane-switch.sh loads on the first read, sibling-first like _cost_rows_client.
cost_rows_db_enabled() {
  if ! command -v lane_switch >/dev/null 2>&1; then
    local _p _r; _r=$(_cost_rows_root)
    for _p in "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" ${_r:+"$_r/bin/lib/lane-switch.sh"}; do
      # shellcheck source=bin/lib/lane-switch.sh
      [ -r "$_p" ] && { . "$_p" 2>/dev/null || true; break; }
    done
    # no lib: the file, as before; no root, no file (the switch is off)
    command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -n "$(_cost_rows_root)" ] && [ -f "$(_cost_rows_root)/flags/$1" ]; }
  fi
  lane_switch cost-rows-from-db-off file >/dev/null && return 1
  case "${COST_ROWS_FROM_DB:-1}" in 0|no|off|false|NO|OFF|FALSE) return 1 ;; esac
  return 0
}

# _cost_rows_client — source bin/jobs-client.sh once, for _jobs_req.
# Sibling-first, exactly like every other lib in this directory: a checkout runs
# the copy beside it, a live box runs $HARNESS's.
_cost_rows_client() {
  command -v _jobs_req >/dev/null 2>&1 && return 0
  local _p _r; _r=$(_cost_rows_root)
  for _p in "$(dirname "${BASH_SOURCE[0]}")/../jobs-client.sh" \
            ${_r:+"$_r/bin/jobs-client.sh"}; do
    # shellcheck source=/dev/null
    [ -r "$_p" ] && { . "$_p"; break; }
  done
  command -v _jobs_req >/dev/null 2>&1
}

# cost_rows_fetch <out-csv> [since-iso] [until-iso] [box]
#
# Writes <out-csv>: the COST_ROW_HDR header, then every matching row. rc 0 when
# the whole window was read, 1 when it could not be (and then <out-csv> is left
# EMPTY rather than short — a half-read window that looks whole is how a cost
# report understates a bill without anyone noticing).
#
# Rows come back newest-first, so a full page means there is more: the next
# request asks again with `until` = the oldest ts this page carried. The bound
# is INCLUSIVE (the worker's contract) and rows are deduped on (box, row_hash),
# which is the same PK the push side collapses on — so the rows sharing that
# one second are read once, not dropped and not doubled.
cost_rows_fetch() {
  local out="${1:-}" since="${2:-}" until="${3:-}" box="${4:-}"
  [ -n "$out" ] || return 1
  local lim="${COST_ROWS_READ_LIMIT:-2000}" maxp="${COST_ROWS_READ_PAGES:-200}"
  case "$lim"  in ''|*[!0-9]*) lim=2000 ;; esac
  case "$maxp" in ''|*[!0-9]*) maxp=200 ;; esac
  # The route clamps to 2000 (worker/jobs/src/index.js). Asking for more and
  # then deciding "a page smaller than what I asked for means the end" is how a
  # 2000-row page reads as the last one: clamp to the ceiling the answer is
  # actually bounded by, so a full page is recognisably full.
  [ "$lim" -gt 2000 ] 2>/dev/null && lim=2000
  [ "$lim" -lt 1 ] 2>/dev/null && lim=1

  if ! _cost_rows_client; then
    _cost_rows_log "bin/jobs-client.sh is missing — cannot read cost_rows, the caller reports the table unreadable"
    return 1
  fi

  local acc page tally resp q pages=0 got oldest
  acc=$(mktemp "${TMPDIR:-/tmp}/cost-rows-acc.XXXXXX") || return 1
  page=$(mktemp "${TMPDIR:-/tmp}/cost-rows-page.XXXXXX") || { rm -f "$acc"; return 1; }
  # Every row the window carried, skipped or not, tallied per box — the answer
  # to "who is the table hearing from", which is the question a stuck push lane
  # makes urgent and nothing else asks.
  tally=$(mktemp "${TMPDIR:-/tmp}/cost-rows-box.XXXXXX") || { rm -f "$acc" "$page"; return 1; }
  local skip="${COST_ROWS_SKIP_HASHES:-}"
  [ -n "$skip" ] && [ ! -r "$skip" ] && skip=""
  while :; do
    q="/api/metrics/cost-rows?limit=$lim"
    [ -n "$since" ] && q="$q&since=$since"
    [ -n "$until" ] && q="$q&until=$until"
    [ -n "$box" ]   && q="$q&box=$box"
    if ! resp=$(_jobs_req GET "$q" 2>/dev/null); then
      _cost_rows_log "GET $q failed (http=${JOBS_HTTP:-none}) — the caller reports the table unreadable"
      rm -f "$acc" "$page" "$tally"; return 1
    fi
    printf '%s' "$resp" > "$page"
    # "<rows-in-page> <oldest-ts>". The absorber's RC is read on its own line,
    # never through `read <<<$(...)`: a command substitution that produced
    # nothing still feeds `read` one empty line, so `read` answers 0 and an
    # unparseable body would arrive downstream as an EMPTY WINDOW — a fleet
    # that spent nothing. An unparseable body is a failed read; the two are
    # indistinguishable once they leave this loop, and only one of them is safe
    # to report as $0.
    local _absorbed _arc
    _absorbed=$(_cost_rows_absorb "$page" "$acc" "$skip" "$tally"); _arc=$?
    if [ "$_arc" != 0 ]; then
      _cost_rows_log "could not parse the cost-rows response for $q — the caller reports the table unreadable"
      rm -f "$acc" "$page" "$tally"; return 1
    fi
    read -r got oldest <<<"$_absorbed" || true
    pages=$((pages + 1))
    [ "${got:-0}" -ge "$lim" ] 2>/dev/null || break
    [ -n "$oldest" ] || break
    if [ "$pages" -ge "$maxp" ]; then
      _cost_rows_log "stopped at the $maxp-page ceiling (${lim} rows/page) reading $q — the window is wider than this reader will walk, so the caller reports it unreadable rather than a short one"
      rm -f "$acc" "$page" "$tally"; return 1
    fi
    until="$oldest"
  done
  rm -f "$page"
  # Whole file at once: a caller reading this path while it is written must not
  # see a header with no rows under it.
  { printf '%s\n' "$COST_ROWS_READ_HDR"; sort -u "$acc"; } > "$out.tmp.$$" \
    && mv -f "$out.tmp.$$" "$out" || { rm -f "$acc" "$tally" "$out.tmp.$$"; return 1; }
  rm -f "$acc"
  # <out>.boxes, same atomic shape. Written ONLY on a whole read, because a
  # presence check taken over a half window names boxes that are fine.
  awk -F'\t' '{ n[$1] += $2; if ($3 > t[$1]) t[$1] = $3 }
               END { for (b in n) printf "%s\t%d\t%s\n", b, n[b], t[b] }' \
      "$tally" 2>/dev/null | sort > "$out.boxes.tmp.$$" \
    && mv -f "$out.boxes.tmp.$$" "$out.boxes" \
    || rm -f "$out.boxes.tmp.$$"
  rm -f "$tally"
  return 0
}

# _cost_rows_absorb <page-json> <accumulator> [skip-hashes] [box-tally]
#   Append this page's rows as CSV lines to the accumulator and print
#   "<rows-in-page> <oldest-ts>". rc 1 when the body is not the shape this route
#   answers with.
#
#   <skip-hashes>  a file of row_hash values the CALLER already holds verbatim
#                  from a file; those rows are tallied and counted for paging,
#                  and not emitted (see COST_ROWS_SKIP_HASHES in the header).
#   <box-tally>    appended `box\trows\tlatest_ts` lines, one per box in THIS
#                  page, skipped rows included — presence is about the table,
#                  not about what this caller happened to need.
_cost_rows_absorb() {
  python3 - "$1" "$2" "${3:-}" "${4:-}" <<'PYEOF'
import hashlib, json, sys
COLS = ["ts", "host", "project", "stage", "runner", "model", "rc", "duration_s",
        "input_toks", "output_toks", "cache_read", "cache_write", "cost_usd",
        "billing_mode", "auth_fp", "auth_account",
        "session_id", "row_source", "result_usd", "ticket", "job_id", "pr",
        "run_id", "note"]
try:
    with open(sys.argv[1], errors="replace") as fh:
        body = json.load(fh)
except Exception:
    sys.exit(1)
rows = body.get("cost_rows")
if not isinstance(rows, list):
    sys.exit(1)

skip = set()
skip_path = sys.argv[3] if len(sys.argv) > 3 else ""
if skip_path:
    try:
        with open(skip_path, errors="replace") as fh:
            for ln in fh:
                ln = ln.strip()
                if ln:
                    skip.add(ln)
    except OSError:
        # Unreadable skip set = skip nothing. The caller's merge then carries a
        # duplicate it can see; the opposite default would DROP rows silently.
        skip = set()


def cell(v):
    # The write side (cost_csv_field) already guarantees no comma, quote or
    # newline reaches a column, so joining on "," reproduces the line. A value
    # that somehow carries one is scrubbed the same way rather than quoted:
    # every reader of this file splits on "," and a quoted field would parse
    # correctly in csv.reader and wrongly in awk.
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return str(v).replace('"', "").replace("\r", "").replace("\n", "").replace(",", " ")


oldest = ""
tally = {}
with open(sys.argv[2], "a") as out:
    for r in rows:
        if not isinstance(r, dict):
            continue
        ts = r.get("ts") or ""
        if ts and (not oldest or ts < oldest):
            oldest = ts
        box = str(r.get("box") or "").replace("\t", " ")
        seen = tally.setdefault(box, [0, ""])
        seen[0] += 1
        if ts > seen[1]:
            seen[1] = ts
        rh = r.get("row_hash") or ""
        if rh and rh in skip:
            # The caller holds this exact line already, from a file, in its
            # original text. Emitting our copy would put the SAME call in the
            # merged file twice whenever the two renderings differ.
            continue
        raw = r.get("raw")
        # VERBATIM WHERE WE HAVE IT, AND ONLY WHERE IT IS PROVABLY WHOLE.
        # `raw` is the line the box appended and `row_hash` is sha256 of that
        # same line, so the pair verifies itself: a `raw` that hashes to its own
        # row_hash is the line, byte for byte, and no float reformatting can
        # move a digit in it. A `raw` that does NOT (the column is capped at
        # 4096 bytes, and a truncated line would re-emit SHORT and still parse)
        # is dropped in favour of the reconstruction, which is at least
        # complete. Rows pushed before `raw` existed are reconstructed too, and
        # their numbers may read 4 where the file said 4.00 — the value is the
        # same, the text is not, and that is stated rather than hidden.
        line = ""
        if isinstance(raw, str) and raw.strip():
            cand = raw.replace("\r", "").replace("\n", "")
            if not rh or hashlib.sha256(
                    cand.encode("utf-8", "replace")).hexdigest() == rh:
                line = cand
        if not line:
            line = ",".join(cell(r.get(c)) for c in COLS)
        out.write(line + "\n")

tally_path = sys.argv[4] if len(sys.argv) > 4 else ""
if tally_path:
    try:
        with open(tally_path, "a") as bf:
            for b, (n, t) in tally.items():
                bf.write("%s\t%d\t%s\n" % (b, n, t))
    except OSError:
        pass
print(len(rows), oldest)
PYEOF
}
