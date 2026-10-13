#!/bin/bash
# tests/job-abandon-cache.bh-2505-test.sh — an operator's ABANDON survives a
# worker outage on the box that already saw it (BH-2505).
#
# job_ticket_abandoned (bin/lib/jobs/jobs.sh) keeps a per-box cache of the
# ticket keys it last read as abandoned, under
# $JOBS_HARNESS/state/abandoned-tickets/<project>/<key>. A good read sets or
# clears the key; on rc 2 (worker down, answer unreadable) a cached key answers
# rc 0 with its job id. Every other ticket keeps today's rc 2.
#   A1-A6b, A10-A12, A14  the helper itself, over a stateful fake worker
#   A7/A8   the REAL QROW requeue (bin/fly-pool.sh): the ticket's red-first case
#   A9      production wiring: bin/jobs-client.sh supplies JOBS_HARNESS
#   A13     the REAL br_one (bin/blocked-resolver.sh)
# Run from anywhere: tests/job-abandon-cache.bh-2505-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "job-abandon-cache: SKIPPED — jq is not installed"; exit 0; }

JOBSLIB="$DIR/bin/lib/jobs/jobs.sh"
POOL="$DIR/bin/fly-pool.sh"
BR="$DIR/bin/blocked-resolver.sh"
CLIENT="$DIR/bin/jobs-client.sh"
for f in "$JOBSLIB" "$POOL" "$BR" "$CLIENT"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# A stateful fake worker. Its answer comes from the file $MODE, so one subshell
# can read an ABANDON and then take the worker down:
#   ABANDONED  the asked ticket's newest build row is abandoned (id job-<n>)
#   RUNNING    a newer build attempt for the asked ticket is running
#   EMPTY      no row at all
#   OTHER      an older worker ignoring the filter: BH-8's abandoned row
#   DOWN       no answer (rc 1)
#   JUNK       an unparseable answer
fake_worker() {
  _jobs_req() {
    local q="${2#*\?}" t
    t="${q#*ticket_id=}"; t="${t%%&*}"; t=$(printf '%b' "${t//%/\\x}")
    case "$(cat "$MODE")" in
      ABANDONED) jq -nc --arg t "$t" '{jobs:[{id:("job-"+($t|sub("^BH-";""))),project:"p1",ticket_id:$t,kind:"build",status:"abandoned"}]}' ;;
      RUNNING)   jq -nc --arg t "$t" '{jobs:[{id:"job-new",project:"p1",ticket_id:$t,kind:"build",status:"running"}]}' ;;
      EMPTY)     echo '{"jobs":[]}' ;;
      OTHER)     echo '{"jobs":[{"id":"job-8","project":"p1","ticket_id":"BH-8","kind":"build","status":"abandoned"}]}' ;;
      DOWN)      return 1 ;;
      JUNK)      echo 'not json' ;;
    esac
  }
}
mode() { echo "$1" > "$MODE"; }
ask() { # ask <project> <key> -> "rc|stdout"   (in the CALLER's shell)
  local out rc
  out=$(job_ticket_abandoned "$1" "$2"); rc=$?
  printf '%s|%s' "$rc" "$out"
}
MODE="$T/mode"
CACHE="state/abandoned-tickets"

# --- A1-A6b, A14: the helper over one box's cache ---------------------------------------
R=$( . "$JOBSLIB" 2>/dev/null; fake_worker; JOBS_HARNESS="$T/h1"
  mode ABANDONED; a1=$(ask p1 BH-9); f1=$(cat "$T/h1/$CACHE/p1/BH-9" 2>/dev/null)
  mode DOWN;      a2=$(ask p1 BH-9)
  mode JUNK;      a3=$(ask p1 BH-9)
  a14=""; mode DOWN; a14=$(ask p2 BH-9)
  printf '%s#%s#%s#%s#%s' "$a1" "$f1" "$a2" "$a3" "$a14" )
IFS='#' read -r A1 F1 A2 A3 A14 <<<"$R"
[ "$A1" = "0|job-9" ] && ok || bad "A1 an abandoned newest build row must answer rc 0 and print job-9 (got $A1)"
[ "$F1" = job-9 ] && ok || bad "A1 the good read must write job-9 to \$JOBS_HARNESS/$CACHE/p1/BH-9 (got '$F1')"
[ "$A2" = "0|job-9" ] && ok || bad "A2 worker DOWN after an ABANDON was read: must answer rc 0 job-9 from the cache (got $A2)"
[ "$A3" = "0|job-9" ] && ok || bad "A3 an unreadable answer after an ABANDON was read: must answer rc 0 job-9 (got $A3)"
[ "${A14%%|*}" = 2 ] && ok || bad "A14 p1's cached ABANDON must not answer for p2/BH-9 during an outage (got $A14)"

R=$( . "$JOBSLIB" 2>/dev/null; fake_worker; JOBS_HARNESS="$T/h4"
  mode ABANDONED; ask p1 BH-9 >/dev/null
  mode RUNNING;   a=$(ask p1 BH-9); [ -e "$T/h4/$CACHE/p1/BH-9" ] && e=present || e=gone
  mode DOWN;      b=$(ask p1 BH-9)
  printf '%s#%s#%s' "$a" "$e" "$b" )
IFS='#' read -r A4 E4 B4 <<<"$R"
[ "${A4%%|*}" = 1 ] && ok || bad "A4 a newer running build row must answer rc 1 (got $A4)"
[ "$E4" = gone ] && ok || bad "A4 a newer build attempt must clear the cache (file $E4)"
[ "${B4%%|*}" = 2 ] && ok || bad "A4 after the clear, an outage must answer rc 2 as today (got $B4)"

R=$( . "$JOBSLIB" 2>/dev/null; fake_worker; JOBS_HARNESS="$T/h5"
  mode DOWN; a=$(ask p1 BH-7)
  printf '%s#%s' "$a" "$(find "$T/h5" -type f 2>/dev/null | wc -l | tr -d ' ')" )
IFS='#' read -r A5 N5 <<<"$R"
[ "${A5%%|*}" = 2 ] && ok || bad "A5 an unknown ticket during an outage must answer rc 2 as today (got $A5)"
[ "$N5" = 0 ] && ok || bad "A5 an outage must never write the cache ($N5 files)"

R=$( . "$JOBSLIB" 2>/dev/null; fake_worker; JOBS_HARNESS="$T/h6"
  mode ABANDONED; ask p1 BH-9 >/dev/null
  mode OTHER;     a=$(ask p1 BH-9)
  [ -e "$T/h6/$CACHE/p1/BH-9" ] && e9=present || e9=gone
  [ -e "$T/h6/$CACHE/p1/BH-8" ] && e8=present || e8=absent
  mode DOWN;      b=$(ask p1 BH-9)
  printf '%s#%s#%s#%s' "$a" "$e9" "$e8" "$b" )
IFS='#' read -r A6 E69 E68 B6 <<<"$R"
[ "${A6%%|*}" = 1 ] && ok || bad "A6 another ticket's row must answer rc 1 as today (got $A6)"
[ "$E69" = present ] && ok || bad "A6 an answer about another ticket must leave BH-9's cache alone (file $E69)"
[ "$E68" = absent ] && ok || bad "A6 an answer about another ticket must not cache BH-8 either"
[ "$B6" = "0|job-9" ] && ok || bad "A6 BH-9 must still answer abandoned during the outage (got $B6)"

R=$( . "$JOBSLIB" 2>/dev/null; fake_worker; JOBS_HARNESS="$T/h6b"
  mode ABANDONED; ask p1 BH-9 >/dev/null
  mode EMPTY;     a=$(ask p1 BH-9); [ -e "$T/h6b/$CACHE/p1/BH-9" ] && e=present || e=gone
  mode DOWN;      b=$(ask p1 BH-9)
  printf '%s#%s#%s' "$a" "$e" "$b" )
IFS='#' read -r A6b E6b B6b <<<"$R"
[ "${A6b%%|*}" = 1 ] && ok || bad "A6b no row must answer rc 1 (got $A6b)"
[ "$E6b" = gone ] && ok || bad "A6b an authoritative empty answer must clear the cache (file $E6b)"
[ "${B6b%%|*}" = 2 ] && ok || bad "A6b after the clear, an outage must answer rc 2 (got $B6b)"

# --- A7/A8: the REAL pool requeue, the ticket's red-first case ---------------------------
QFN=$(awk '/^QROW\(\) \{/{on=1} on{print} on&&/^\}$/{exit}' "$POOL")
[ -n "$QFN" ] && ok || bad "A7 QROW not found in bin/fly-pool.sh"
H7="$T/h7"; mkdir -p "$H7/logs"
qrow() { # qrow <key> <tid> -> "rc|calls"; primes the cache when PRIME=1
  ( . "$JOBSLIB" 2>/dev/null; fake_worker; JOBS_HARNESS="$H7"
    HARNESS="$H7" P=p1 LOG="$H7/logs/pool.log"
    STAMP() { echo 2026-09-26T00:00:00Z; }
    say() { echo "$*" >> "$LOG"; }
    queue_done() { echo "done $*" >> "$H7/calls"; }
    queue_put()  { echo "put $*" >> "$H7/calls"; }
    eval "$QFN"
    if [ "${PRIME:-0}" = 1 ]; then mode ABANDONED; job_ticket_abandoned p1 "$1" >/dev/null; fi
    mode DOWN
    : > "$H7/calls"
    QROW requeue "$1" "machine m1 died" 2 '{}' "$2"; rc=$?
    printf '%s|%s' "$rc" "$(tr '\n' ';' < "$H7/calls")" )
}
R=$(PRIME=1 qrow BH-9 tid-9)
[ "${R%%|*}" = 1 ] && ok || bad "A7 abandoned then worker down: QROW requeue must refuse with rc 1 (got $R)"
case "$R" in *"put "*) bad "A7 an abandoned ticket was re-enqueued during the outage (got $R)" ;; *) ok ;; esac
LASTDONE=$(tr ';' '\n' <<<"${R#*|}" | grep '^done ' | tail -1)
case "$LASTDONE" in "done p1 BH-9 failed ABANDONED by an operator (job job-9)"*) ok ;; *) bad "A7 the row must close 'ABANDONED by an operator (job job-9)' (got $LASTDONE)" ;; esac
R=$(qrow BH-7 tid-7)
[ "${R%%|*}" = 0 ] && ok || bad "A8 an unknown ticket during the outage: QROW requeue must return 0 as today (got $R)"
case "$R" in *"put p1 BH-7 tid-7 fly 2 {}"*) ok ;; *) bad "A8 an unknown ticket during the outage must still enqueue (got $R)" ;; esac

# --- A9: production wiring through bin/jobs-client.sh ------------------------------------
H9="$T/h9"; mkdir -p "$H9"
R=$( HARNESS="$H9" JOBS_URL=; . "$CLIENT" 2>/dev/null || exit 9
  fake_worker
  mode ABANDONED; ask p1 BH-9 >/dev/null
  mode DOWN; a=$(ask p1 BH-9)
  printf '%s#%s' "$JOBS_HARNESS" "$a" )
IFS='#' read -r JH9 A9 <<<"$R"
[ "$JH9" = "$H9" ] && ok || bad "A9 bin/jobs-client.sh must set JOBS_HARNESS from HARNESS (got '$JH9')"
[ "$A9" = "0|job-9" ] && ok || bad "A9 sourced as production does, an ABANDON must survive the outage (got $A9)"

# --- A10: no JOBS_HARNESS, no cache ----------------------------------------------------
BEFORE=$(find "$T" -path "*abandoned-tickets*" 2>/dev/null | sort)
ROOTCACHE=$([ -e /state/abandoned-tickets ] && echo present || echo absent)
# set +u: a caller without nounset reaches the empty-JOBS_HARNESS path for real.
R=$( cd "$T" || exit 9; set +u; . "$JOBSLIB" 2>/dev/null; fake_worker; unset JOBS_HARNESS
  mode ABANDONED; a=$(ask p1 BH-9)
  mode DOWN;      b=$(ask p1 BH-9)
  printf '%s#%s' "$a" "$b" )
IFS='#' read -r A10a A10b <<<"$R"
[ "$A10a" = "0|job-9" ] && ok || bad "A10 the live answer is unchanged without JOBS_HARNESS (got $A10a)"
[ "${A10b%%|*}" = 2 ] && ok || bad "A10 without JOBS_HARNESS an outage must answer rc 2 as today (got $A10b)"
[ "$(find "$T" -path "*abandoned-tickets*" 2>/dev/null | sort)" = "$BEFORE" ] && ok || bad "A10 no cache may be written without JOBS_HARNESS"
[ "$ROOTCACHE" = present ] || { [ ! -e /state/abandoned-tickets ] && ok || bad "A10 an unset JOBS_HARNESS wrote /state/abandoned-tickets"; }

# --- A11: an unsafe project or key never touches the filesystem ---------------------------
for pk in "p1 ../x" "p1 a/b" "p1 .h" "p1 .." "../p BH-9" ".p BH-9"; do
  set -- $pk
  R=$( . "$JOBSLIB" 2>/dev/null; fake_worker; JOBS_HARNESS="$T/h11"
    mode ABANDONED; ask "$1" "$2" >/dev/null
    mode DOWN;      ask "$1" "$2" )
  [ "${R%%|*}" = 2 ] && ok || bad "A11 unsafe '$1' '$2': an outage must answer rc 2 (got $R)"
done
N11=$(find "$T/h11" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
[ "$N11" = 0 ] && ok || bad "A11 unsafe names must never be written: $(find "$T/h11" -mindepth 1 2>/dev/null | tr '\n' ' ')"
[ ! -e "$T/x" ] && [ ! -e "$T/state" ] && ok || bad "A11 an unsafe name escaped \$JOBS_HARNESS"

# --- A12: a corrupt cache file is not an ABANDON -----------------------------------------
for content in "" "bad id;rm"; do
  mkdir -p "$T/h12/$CACHE/p1"; printf '%s' "$content" > "$T/h12/$CACHE/p1/BH-9"
  R=$( . "$JOBSLIB" 2>/dev/null; fake_worker; JOBS_HARNESS="$T/h12"; mode DOWN; ask p1 BH-9 )
  [ "$R" = "2|" ] && ok || bad "A12 cache holding '$content' must answer rc 2 and print nothing (got $R)"
done

# --- A13: the REAL br_one ------------------------------------------------------------------
BFN=$(awk '/^br_one\(\) \{/{on=1} on{print} on&&/^\}$/{exit}' "$BR")
[ -n "$BFN" ] && ok || bad "A13 br_one not found in bin/blocked-resolver.sh"
H13="$T/h13"; mkdir -p "$H13/logs"
brone() { # brone <key> -> "rc|reached"; primes the cache when PRIME=1
  ( . "$JOBSLIB" 2>/dev/null; fake_worker; JOBS_HARNESS="$H13"
    H="$H13" LOG="$H13/logs/br.log"; : > "$H13/reached"
    STAMP() { echo T; }
    say() { echo "$*" >> "$LOG"; }
    br_action() { echo ladder; }
    br_use_token() { :; }
    br_reset_token() { :; }
    br_cap_key() { echo "$1-$3"; }
    br_load() { echo '{}'; }
    br_already_merged() { echo reached >> "$H13/reached"; return 0; }
    eval "$BFN"
    if [ "${PRIME:-0}" = 1 ]; then mode ABANDONED; job_ticket_abandoned p1 "$1" >/dev/null; fi
    mode DOWN
    br_one build-dead p1 "p1-$1" build-dead - - "$1"; rc=$?
    printf '%s|%s' "$rc" "$(wc -l < "$H13/reached" | tr -d ' ')" ) 2>/dev/null
}
R=$(PRIME=1 brone BH-9)
[ "$R" = "3|0" ] && ok || bad "A13 abandoned then worker down: br_one must take no rung, rc 3 (got $R)"
R=$(brone BH-7)
[ "$R" = "0|1" ] && ok || bad "A13 an unknown ticket during the outage: the ladder must run as today (got $R)"

echo "job-abandon-cache: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
