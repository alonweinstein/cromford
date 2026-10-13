#!/bin/bash
# tests/d1-schema-split.bh-1555-test.sh — the splitter keeps a CREATE TRIGGER
# body (BEGIN … END;) as ONE statement, and d1_stmt_object names the object a
# CREATE statement defines.
# Run from anywhere: bash tests/d1-schema-split.bh-1555-test.sh (exit 0 = pass)
#
# WHY (BH-1555, review follow-up to BH-1538). d1_schema_statements ended a
# statement on any line whose code ends in `;` outside a string literal, so a
# trigger body cut into one fragment per inner `;` — four pieces for the
# fixture below, none of them valid SQL, and the apply would fail on the first
# one the day a trigger lands in a worker's schema.sql. The second half is the
# object identity the edited-definition alert compares on (I1): a CREATE head
# maps to `<kind> <name>`, everything else to nothing.
#
# The one file it writes (the SQL fed to the splitter) lives in the shared
# scratch tree from tests/lib/scratch.sh, which owns its cleanup
# (checks/tests-scratch-only R1).
set -uo pipefail
ROOT=$(readlink -f "$(dirname "$0")/..")
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# shellcheck source=bin/lib/d1-schema.sh
. "$ROOT/bin/lib/d1-schema.sh" || exit 1

# split <sql-text> — print one line per emitted statement with newlines shown
# as ` / `, so a case can assert on both the COUNT and the content.
nstmt() { printf '%s' "$1" > "$SQLF"; d1_schema_statements "$SQLF" | tr -dc '\0' | wc -c | tr -d ' '; }
stmt_n() { printf '%s' "$1" > "$SQLF"; d1_schema_statements "$SQLF" | tr '\0' '\001' | awk -v n="$2" 'BEGIN{RS="\001"} NR==n {printf "%s", $0}'; }
SQLF="$T/schema.sql"

TRG='CREATE TRIGGER IF NOT EXISTS trg AFTER INSERT ON t
BEGIN
  UPDATE t SET n = n + 1;
  INSERT OR IGNORE INTO log(id) VALUES (new.id);
END;
CREATE TABLE IF NOT EXISTS t2 (id INTEGER PRIMARY KEY);
'
# S1. the trigger and the table that follows it: exactly two statements, the
# first spanning BEGIN..END;.
C=$(nstmt "$TRG")
[ "$C" = 2 ] && ok || bad "S1: a trigger + a table must split into 2 statements, got $C"
S1=$(stmt_n "$TRG" 1)
case "$S1" in
  *BEGIN*"INSERT OR IGNORE INTO log"*END\;) ok ;;
  *) bad "S1: statement 1 must be the whole trigger BEGIN..END;, got: $(printf '%s' "$S1" | tr '\n' '/')" ;;
esac
S2=$(stmt_n "$TRG" 2)
case "$S2" in
  CREATE\ TABLE*t2*) ok ;;
  *) bad "S1: statement 2 must be the table, got: $S2" ;;
esac

# S2. lower case, and TEMP: the match is case-insensitive and allows TEMP.
LOW='create temp trigger trg2 after update on t
begin
  update t set n = 1;
end;
create table if not exists t3 (id integer primary key);
'
C=$(nstmt "$LOW")
[ "$C" = 2 ] && ok || bad "S2: a lower-case TEMP trigger must still be one statement, got $C statements"

# S3. a `-- … END;` comment inside the body must not close the trigger.
CMT='CREATE TRIGGER IF NOT EXISTS trg3 AFTER INSERT ON t
BEGIN
  UPDATE t SET n=1; -- END; here
  UPDATE t SET m=2;
END;
'
C=$(nstmt "$CMT")
[ "$C" = 1 ] && ok || bad "S3: an inline -- END; comment must not close a trigger, got $C statements"

# S4. a string literal 'END;' inside the body must not close it either.
LIT="CREATE TRIGGER IF NOT EXISTS trg4 AFTER INSERT ON t
BEGIN
  INSERT INTO log(msg) VALUES ('END;');
  UPDATE t SET m=2;
END;
"
C=$(nstmt "$LIT")
[ "$C" = 1 ] && ok || bad "S4: a literal 'END;' must not close a trigger, got $C statements"

# S5. an identifier that merely ENDS in end (weekend;) is not END.
IDT='CREATE TRIGGER IF NOT EXISTS trg5 AFTER INSERT ON t
BEGIN
  UPDATE t SET d = new.weekend;
  UPDATE t SET m = 2;
END;
'
C=$(nstmt "$IDT")
[ "$C" = 1 ] && ok || bad "S5: an identifier ending in end (weekend;) must not close a trigger, got $C statements"

# S6. regression: no trigger in the text, splitting is exactly as before.
PLAIN="CREATE TABLE IF NOT EXISTS a (id INTEGER PRIMARY KEY);
INSERT OR IGNORE INTO a(id) VALUES (1);
-- ids are ';'-joined
INSERT OR IGNORE INTO a(id) VALUES (2);
"
C=$(nstmt "$PLAIN")
[ "$C" = 3 ] && ok || bad "S6: ordinary statements must split as before, got $C of 3"

# ── d1_stmt_object ──────────────────────────────────────────────────────────
# O0 first: without the helper every O-case below would read empty and pass by
# accident, which is exactly the vacuous test D1 is about.
declare -F d1_stmt_object >/dev/null \
  && ok || bad "O0: bin/lib/d1-schema.sh must define d1_stmt_object"
obj() { d1_stmt_object "$1"; }
[ "$(obj 'CREATE TABLE IF NOT EXISTS build_queue (id INTEGER);')" = "table build_queue" ] \
  && ok || bad "O1: CREATE TABLE → table <name>, got '$(obj 'CREATE TABLE IF NOT EXISTS build_queue (id INTEGER);')'"
[ "$(obj 'CREATE UNIQUE INDEX IF NOT EXISTS ix_q ON build_queue(id);')" = "index ix_q" ] \
  && ok || bad "O2: CREATE UNIQUE INDEX → index <name>, got '$(obj 'CREATE UNIQUE INDEX IF NOT EXISTS ix_q ON build_queue(id);')'"
[ "$(obj 'create view v_recent as select 1;')" = "view v_recent" ] \
  && ok || bad "O3: a lower-case CREATE VIEW → view <name>, got '$(obj 'create view v_recent as select 1;')'"
[ "$(obj "$S1")" = "trigger trg" ] \
  && ok || bad "O4: a multi-line CREATE TRIGGER → trigger <name>, got '$(obj "$S1")'"
[ -z "$(obj "INSERT OR IGNORE INTO settings(k,v) VALUES ('a','b');")" ] \
  && ok || bad "O5: an INSERT names no object, got '$(obj "INSERT OR IGNORE INTO settings(k,v) VALUES ('a','b');")'"
[ "$(obj 'CREATE TABLE IF NOT EXISTS "build_queue" (id INTEGER);')" = "table build_queue" ] \
  && ok || bad "O6: a quoted name is printed unquoted, got '$(obj 'CREATE TABLE IF NOT EXISTS "build_queue" (id INTEGER);')'"
[ "$(obj 'CREATE INDEX ix_plain ON a(id);')" = "index ix_plain" ] \
  && ok || bad "O7: CREATE INDEX without IF NOT EXISTS still names its object"
# O8/O9 (lead review B1): the other two SQLite quoting forms. The first cut of
# the quote strip was a bracket expression with octal escapes that GNU awk (the
# fleet's awk) silently turned into a no-op, so "x" and x counted as two
# different objects on every Linux box and the edited-DDL alert never fired.
[ "$(obj 'CREATE TABLE IF NOT EXISTS `build_queue` (id INTEGER);')" = "table build_queue" ] \
  && ok || bad "O8: a backtick-quoted name is printed unquoted, got '$(obj 'CREATE TABLE IF NOT EXISTS `build_queue` (id INTEGER);')'"
[ "$(obj 'CREATE INDEX IF NOT EXISTS [ix_q] ON build_queue(id);')" = "index ix_q" ] \
  && ok || bad "O9: a bracket-quoted name is printed unquoted, got '$(obj 'CREATE INDEX IF NOT EXISTS [ix_q] ON build_queue(id);')'"

echo "d1-schema-split.bh-1555-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
