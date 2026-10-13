#!/bin/bash
# bin/lib/d1-schema.sh — split a worker's schema.sql into single statements and
# find the D1 database its wrangler config binds. Sourced, never executed.
# Side-effect-free: reads files, prints to stdout, touches no network and no env.
#
# WHY THIS EXISTS (BH-1000, the 2026-09-19 hub outage). `worker/*/schema.sql`
# was applied BY HAND. bin/harness-sync.sh deployed the worker and nothing
# applied the file, so #785's code reached production ahead of its `hub_lease`
# table, every lease read threw an uncaught D1 error (Cloudflare 1101) and the
# 52 `check &&` lanes on the hub stopped for half an hour without a page. The
# fix is to apply the schema in the deploy path — and `wrangler d1 execute
# --file` fails under the hub's OAuth login (`Authentication error [code:
# 10000]`), so the apply goes through `--command` — several statements per
# round trip since BH-1538, and one at a time when a batch fails so the
# statement that broke can be named. Either way it needs a splitter, and a
# splitter for SQL is exactly where a naive `;` split goes wrong.
#
# THE SPLIT RULE. A statement ends on a line whose last non-blank character is
# `;` AND whose accumulated text is not inside a string literal. Quote state is
# tracked across lines, and a `--` that sits outside a literal ends the line for
# the purposes of that test (inline comments stay in the emitted statement —
# SQLite reads them fine — but they never decide where a statement ends, and
# their apostrophes never flip the quote state: `-- the stage's exit code`
# appears in this very schema).
# So neither of these splits, which is the whole point:
#   ('repo', '*', 'build', 1, 'one build per repo at a time; raise this row', …)
#   -- ids are ';'-joined
#
# THE TRIGGER EXCEPTION (BH-1555). A trigger body is statements-inside-a-
# statement: `CREATE TRIGGER … BEGIN UPDATE …; INSERT …; END;` ends in `;`
# three times and only the last one ends the trigger. So while the accumulated
# statement is a CREATE [TEMP] TRIGGER, only a line whose code ends in a
# word-bounded `END;` closes it — an inner `;`, an `END;` inside a `--` comment
# or a string literal, and an identifier that merely ends in "end" (`weekend;`)
# all keep accumulating. Without this the first trigger to land in a worker's
# schema.sql would be sent to D1 as four fragments, none of them valid SQL, and
# the apply would fail on every run from then on.
# KNOWN LIMIT: a body line whose code ends in a CASE expression's `END;` (for
# example `SET x = CASE WHEN a THEN 1 END;`) closes the trigger early. That
# fails LOUD, not silent — D1 rejects the fragments, the ALERTS line names the
# statement and the deploy is skipped — and schema.sql has no trigger today.
# Put such a CASE on a line that does not end in `END;`, or teach this a
# CASE/END depth count when the first real trigger needs one.
# Statements come out NUL-delimited, so a caller reads them with
# `mapfile -t -d '' STMTS < <(d1_schema_statements file)` and never has to
# guess at a separator that cannot appear in SQL.

# d1_schema_statements <file> — print each statement, NUL-delimited.
# Full-line `--` comments (at any indent, outside a literal) are dropped;
# anything left at EOF without a closing `;` is emitted too, so a missing
# semicolon shows up as a failing statement rather than as silently lost SQL.
d1_schema_statements() {
  local file="${1:-}"
  [ -n "$file" ] && [ -r "$file" ] || return 1
  awk '
    function scan(l,   i, c, n, out) {
      # Return the code part of the line and update the cross-line quote state.
      out = ""; n = length(l)
      for (i = 1; i <= n; i++) {
        c = substr(l, i, 1)
        if (inq) { out = out c; if (c == "\047") inq = 0; continue }
        if (c == "\047") { inq = 1; out = out c; continue }
        if (c == "-" && substr(l, i + 1, 1) == "-") break   # comment to EOL
        out = out c
      }
      return out
    }
    function emit(   s) {
      s = stmt; stmt = ""
      sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s)
      if (s != "") printf "%s%c", s, 0
    }
    BEGIN { inq = 0; stmt = ""; intrg = 0 }
    {
      if (!inq && $0 ~ /^[ \t]*--/) next
      code = scan($0)
      stmt = (stmt == "" ? $0 : stmt "\n" $0)
      sub(/[ \t\r]+$/, "", code)
      # Trigger state is read off the ACCUMULATED statement, so the head may sit
      # on an earlier line than the BEGIN. `stmt` here is code+comments, but a
      # commented-out or quoted "CREATE TRIGGER" cannot reach the front of a
      # statement: full-line comments are dropped above and a literal can only
      # follow the verb.
      if (!intrg && toupper(stmt) ~ /^[ \t]*CREATE[ \t]+(TEMP[ \t]+|TEMPORARY[ \t]+)?TRIGGER[ \t]/) intrg = 1
      if (!inq && code ~ /;$/ && (!intrg || toupper(code) ~ /(^|[^A-Z0-9_])END[ \t]*;$/)) {
        intrg = 0
        emit()
      }
    }
    END { emit() }
  ' "$file"
}

# d1_stmt_object <statement> — print `<kind> <name>` for a statement that
# CREATEs an object (table / index / unique index / view / trigger), and
# nothing at all for anything else (INSERT OR IGNORE, PRAGMA, unknown).
#
# WHY (BH-1555). `CREATE ... IF NOT EXISTS` is a SILENT NO-OP on D1 when the
# object already exists, so an EDITED definition of a table D1 already has is
# sent, reports success and changes nothing. harness-sync compares the objects
# a delta defines against the objects the previous blob defined, and this is
# the identity it compares on. Pure: no files, no network, no state.
#
# Only the head matters, so the statement is flattened and cut to 200 chars
# first — a trigger body is longer than any head and holds verbs of its own.
# The name keeps its original case (SQLite identifiers are case-insensitive but
# an alert should quote what the file says) and loses any "" or `` quoting.
d1_stmt_object() {
  local head kind name
  head=$(printf '%s' "${1:-}" | tr '\n\t' '  ' | tr -s ' ' | cut -c1-200)
  read -r kind name < <(printf '%s\n' "$head" | awk '
    {
      s = toupper($0)
      if (s !~ /^[ \t]*CREATE[ \t]/) exit
      sub(/^[ \t]*[Cc][Rr][Ee][Aa][Tt][Ee][ \t]+/, "", $0)
      sub(/^[Uu][Nn][Ii][Qq][Uu][Ee][ \t]+/, "", $0)
      sub(/^([Tt][Ee][Mm][Pp]|[Tt][Ee][Mm][Pp][Oo][Rr][Aa][Rr][Yy])[ \t]+/, "", $0)
      k = toupper($1)
      if (k != "TABLE" && k != "INDEX" && k != "VIEW" && k != "TRIGGER") exit
      sub(/^[A-Za-z]+[ \t]+/, "", $0)
      sub(/^[Ii][Ff][ \t]+[Nn][Oo][Tt][ \t]+[Ee][Xx][Ii][Ss][Tt][Ss][ \t]+/, "", $0)
      n = $1
      sub(/[(;].*$/, "", n)
      if (n != "") printf "%s %s\n", tolower(k), n
    }')
  # The quoting ("x", `x`, [x]) is stripped HERE, in bash, not in the awk: the
  # first cut was an awk bracket expression of octal escapes that bwk awk (the
  # Mac) honours and GNU awk (every fleet box) silently turns into a no-op, so
  # "x" and x counted as two objects and I1 never fired in production.
  name=${name:-}; name=${name//[\"\`\[\]]/}
  [ -n "${kind:-}" ] && [ -n "${name:-}" ] && printf '%s %s\n' "$kind" "$name"
  return 0
}

# d1_database_name <worker-dir> — the first D1 database_name in the worker's
# wrangler config, or nothing when there is no D1 binding at all (that worker
# has no schema to apply, and deploys exactly as it always has).
#
# grep/sed, not jq: wrangler.jsonc is JSON *with comments* and jq refuses it.
# Lines that are themselves `//` comments are skipped so a commented-out binding
# never becomes the database we write to. The toml key is ANCHORED to the start
# of its line for the same reason: unanchored, `preview_database_name = "…"`
# matches first and the schema would be applied to the preview database.
d1_database_name() {
  local dir="${1:-}" name=""
  [ -n "$dir" ] || return 0
  if [ -f "$dir/wrangler.jsonc" ]; then
    name=$(grep -v '^[[:space:]]*//' "$dir/wrangler.jsonc" 2>/dev/null \
           | grep -o '"database_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
           | head -1 | sed -e 's/.*:[[:space:]]*"//' -e 's/"$//')
  fi
  if [ -z "$name" ] && [ -f "$dir/wrangler.toml" ]; then
    name=$(grep -v '^[[:space:]]*#' "$dir/wrangler.toml" 2>/dev/null \
           | grep -oE '^[[:space:]]*database_name[[:space:]]*=[[:space:]]*"[^"]*"' \
           | head -1 | sed -e 's/.*=[[:space:]]*"//' -e 's/"$//')
  fi
  [ -n "$name" ] && printf '%s\n' "$name"
  return 0
}

# ── BH-1538: batching, and how long an apply may run before it pages ─────────
# WHY. On 2026-09-22 worker/jobs's schema.sql had grown to 116 statements, the
# apply above sent them one `--command` round trip each (~5 s apiece), and
# harness-sync held its deploy lock for 30+ minutes after every schema change:
# the hub ran code 12 commits behind main for as long as the apply took. So an
# apply now sends only the statements that changed, several per round trip.
#
# THE CHUNK BOUNDS are wire limits, not business knobs: one `--command` value
# is one argv string (Linux caps a single argument at 128 KiB) and D1 caps a
# query at 100 KB, so a chunk stays under 60,000 bytes. The statement cap bounds
# the cost of a failed chunk, which is re-run one statement at a time so the
# ALERTS line can still name the statement that broke.
D1_BATCH_MAX_BYTES=60000
D1_BATCH_MAX_STMTS=40
# The code fallback for the alert threshold (bin/harness-sync.sh resolves it):
# under the `timeout 300` fleet-propagate gives harness-sync, so a slow apply
# pages BEFORE that timeout kills it mid-apply without a word.
# The knob is registered on the fleet-propagate lane
# (catalog/lanes.d/fleet-propagate.json), so an operator moves it with the
# settings row `lane.fleet-propagate.harness_sync_schema_alert_s`.
D1_APPLY_ALERT_S_DEFAULT=180

# d1_chunk_bounds [max-bytes] [max-stmts] — read NUL-delimited statements on
# stdin and print one `<first> <last>` line (0-based, inclusive) per chunk, in
# order. A statement bigger than max-bytes on its own still gets a chunk of its
# own: it was going to cost one round trip either way.
d1_chunk_bounds() {
  local maxb="${1:-$D1_BATCH_MAX_BYTES}" maxs="${2:-$D1_BATCH_MAX_STMTS}"
  local s i=0 first=0 bytes=0 n=0 len LC_ALL=C   # C: ${#s} counts BYTES
  while IFS= read -r -d '' s; do
    len=${#s}
    if [ "$n" -gt 0 ] && { [ $((bytes + len + 1)) -gt "$maxb" ] || [ "$n" -ge "$maxs" ]; }; then
      printf '%s %s\n' "$first" $((i - 1)); first=$i; bytes=0; n=0
    fi
    bytes=$((bytes + len + 1)); n=$((n + 1)); i=$((i + 1))
  done
  [ "$n" -gt 0 ] && printf '%s %s\n' "$first" $((i - 1))
  return 0
}
