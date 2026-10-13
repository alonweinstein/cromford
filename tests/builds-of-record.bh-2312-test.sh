#!/bin/bash
# tests/builds-of-record.bh-2312-test.sh — THE BUILDS-OF-RECORD READER
# (BH-2347, slice 1 of BH-2312).
#
# bin/lib/builds-of-record.sh is the read side every BH-2312 lane will source:
# "which builds did this project record, and where are their PRs" from the jobs
# ledger instead of from builds/*/RESULT on one box. This suite drives the REAL
# lib over the REAL bin/jobs-client.sh and _jobs_req. The only stub is `curl`
# (the worker), which answers per `kind=` query from fixture JSON and logs every
# request, the same shape as tests/verdict-at-review.bh-858-test.sh §3.
#
#   A1 join on job_id, `-` with no pr_url row, exactly two feed requests
#   A2 newest row per build_dir        A3 pool-/fly- strip
#   A4 empty feed -> rc 2              A5 outage (either feed) / no client -> rc 1, nothing printed
#   A6 BOR_TRUNCATED at the limit, unset below it; BOR_LIMIT and the 500 default reach the query
#   A7 an escaped tab/newline in a ref stays one row of 7 columns
#   U1-U6 bor_union / bor_local_dir over a scratch $H/builds
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/builds-of-record.bh-2312-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }

mkdir -p "$T/fakebin" "$T/h/bin/lib/jobs" "$T/h/builds" "$T/fix"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/lib/builds-of-record.sh" "$T/h/bin/lib/builds-of-record.sh"
FIX="$T/fix"

# The stub worker: kind=result and kind=pr_url answer from their own fixture
# file; a missing file is an empty list. WORKER_DOWN=1 takes both down,
# WORKER_DOWN_KIND=<kind> only that one (curl rc 7 = transport failure).
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
printf 'GET %s\n' "$URL" >> "$REQ_SINK"
[ "${WORKER_DOWN:-0}" = 1 ] && exit 7
case "$URL" in *"kind=${WORKER_DOWN_KIND:-none}&"*) exit 7 ;; esac
F=""
case "$URL" in
  *kind=result\&*) F="$FIX/result" ;;
  *kind=pr_url\&*) F="$FIX/pr_url" ;;
esac
if [ -n "$F" ] && [ -f "$F" ]; then printf '%s\n200\n' "$(cat "$F")"; exit 0; fi
printf '{"artifacts":[]}\n200\n'
STUB
chmod +x "$T/fakebin/curl"

# lib <snippet>: the snippet runs in a subshell with the real client and the
# real lib sourced, H pointing at the scratch harness.
lib() {
  ( export PATH="$T/fakebin:$PATH" H="$T/h" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box FIX="$FIX" JOBS_RETRIES=0 \
           REQ_SINK="$T/req.txt" WORKER_DOWN="${WORKER_DOWN:-0}" \
           WORKER_DOWN_KIND="${WORKER_DOWN_KIND:-none}"
    unset JOB_ID JOB_PHASE_ID BOR_TRUNCATED
    # shellcheck source=/dev/null
    . "$T/h/bin/jobs-client.sh" || exit 99
    # shellcheck source=/dev/null
    . "$T/h/bin/lib/builds-of-record.sh" || exit 99
    eval "$1" )
}

# res_row <job> <ref> <box> <updated_at> <build_dir> [key] — one result artifact.
res_row() {
  jq -cn --arg j "$1" --arg r "$2" --arg b "$3" --arg u "$4" --arg d "$5" --arg k "${6:-}" \
    '{job_id:$j, artifact_ref:$r, box:$b, ticket_id:$k, updated_at:$u,
      detail:({build_dir:$d, job_status:"done"} + (if $k == "" then {} else {key:$k} end) | tojson)}'
}
pr_row() { # pr_row <job> <url> <updated_at>
  jq -cn --arg j "$1" --arg r "$2" --arg u "$3" '{job_id:$j, artifact_ref:$r, box:"box1", updated_at:$u}'
}
feed() { # feed <file> <row-json>... -> {"artifacts":[rows]}
  local f="$1"; shift
  printf '%s\n' "$@" | jq -cs '{artifacts: .}' > "$FIX/$f"
}
reset() { rm -f "$FIX"/* "$T/req.txt"; rm -rf "${T:?}/h/builds"; mkdir -p "$T/h/builds"; }
TAB=$'\t'
P1=https://github.com/o/p/pull/1

# ═════════════════════════════════════════════════════════════════════════════
# A1 — the join
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J1 'PR_CREATED x' box1 2026-09-20T00:00:02Z p-TK-1-1 TK-1)" \
            "$(res_row J2 'PLAN_BLOCKED y' box2 2026-09-20T00:00:01Z p-TK-2-1 TK-2)"
feed pr_url "$(pr_row J1 "$P1" 2026-09-20T00:00:02Z)"
OUT=$(lib 'bor_list p'); RC=$?
[ "$RC" = 0 ] && ok || bad "A1: rc 0 expected with rows, got $RC"
[ "$(printf '%s\n' "$OUT" | wc -l)" = 2 ] && ok || bad "A1: 2 lines expected, got: $OUT"
L1=$(printf '%s\n' "$OUT" | awk -F'\t' '$7 == "J1"')
[ "$L1" = "TK-1${TAB}p-TK-1-1${TAB}box1${TAB}2026-09-20T00:00:02Z${TAB}PR_CREATED x${TAB}${P1}${TAB}J1" ] \
  && ok || bad "A1: J1 row wrong, got '$L1'"
L2=$(printf '%s\n' "$OUT" | awk -F'\t' '$7 == "J2"')
[ "$(cut -f6 <<<"$L2")" = - ] && [ "$(cut -f1,2 <<<"$L2")" = "TK-2${TAB}p-TK-2-1" ] \
  && ok || bad "A1: J2 has no pr_url row, column 6 must be '-', got '$L2'"
[ "$(head -1 <<<"$OUT" | cut -f7)" = J1 ] && ok || bad "A1: feed order (newest first) must be kept, got: $OUT"
N=$(grep -c '/api/artifacts' "$T/req.txt")
[ "$N" = 2 ] && ok || bad "A1: exactly 2 feed requests expected, got $N"

# A pr_url row whose job has no result row is dropped, not emitted.
feed pr_url "$(pr_row J1 "$P1" 2026-09-20T00:00:02Z)" "$(pr_row J9 https://github.com/o/p/pull/9 2026-09-20T00:00:03Z)"
OUT=$(lib 'bor_list p')
grep -q J9 <<<"$OUT" && bad "A1: a pr_url with no result row must not produce a row: $OUT" || ok

# ═════════════════════════════════════════════════════════════════════════════
# A2 — newest row per build_dir; A3 — pool-/fly- strip
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J3 'PR_CREATED new' box1 2026-09-20T00:00:03Z p-TK-1-1 TK-1)" \
            "$(res_row J1 'PR_CREATED old' box1 2026-09-20T00:00:01Z p-TK-1-1 TK-1)"
OUT=$(lib 'bor_list p')
{ [ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && [ "$(cut -f7 <<<"$OUT")" = J3 ]; } \
  && ok || bad "A2: one row carrying J3 expected, got: $OUT"
# The newest wins even when the feed hands it second.
feed result "$(res_row J1 'PR_CREATED old' box1 2026-09-20T00:00:01Z p-TK-1-1 TK-1)" \
            "$(res_row J3 'PR_CREATED new' box1 2026-09-20T00:00:03Z pool-p-TK-1-1 TK-1)"
OUT=$(lib 'bor_list p')
{ [ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && [ "$(cut -f7 <<<"$OUT")" = J3 ]; } \
  && ok || bad "A2: newest updated_at must win regardless of feed order, got: $OUT"

reset
feed result "$(res_row J2 'PR_CREATED a' box1 2026-09-20T00:00:02Z pool-p-TK-2-1 TK-2)" \
            "$(res_row J3 'PR_CREATED b' box1 2026-09-20T00:00:01Z fly-p-TK-3-1 TK-3)" \
            "$(res_row J4 'PR_CREATED c' box1 2026-09-20T00:00:00Z '' TK-4)"
OUT=$(lib 'bor_list p')
[ "$(cut -f2 <<<"$OUT" | tr '\n' ' ')" = "p-TK-2-1 p-TK-3-1 " ] \
  && ok || bad "A3: pool-/fly- stripped and a row with no build_dir skipped, got: $OUT"

# A missing key in the detail is written '-'.
feed result "$(res_row J5 'PR_CREATED d' box1 2026-09-20T00:00:00Z p-TK-5-1)"
OUT=$(lib 'bor_list p')
[ "$(cut -f1 <<<"$OUT")" = - ] && ok || bad "A3: a detail with no key writes '-', got: $OUT"

# ═════════════════════════════════════════════════════════════════════════════
# A4 — empty feed; A5 — outage and a missing client
# ═════════════════════════════════════════════════════════════════════════════
reset
OUT=$(lib 'bor_list p'); RC=$?
{ [ "$RC" = 2 ] && [ -z "$OUT" ]; } && ok || bad "A4: empty feed must be rc 2 with no output, got rc $RC '$OUT'"

reset
feed result "$(res_row J1 'PR_CREATED x' box1 2026-09-20T00:00:02Z p-TK-1-1 TK-1)"
feed pr_url "$(pr_row J1 "$P1" 2026-09-20T00:00:02Z)"
OUT=$(WORKER_DOWN=1 lib 'bor_list p'); RC=$?
{ [ "$RC" = 1 ] && [ -z "$OUT" ]; } && ok || bad "A5: outage must be rc 1 with no output, got rc $RC '$OUT'"
OUT=$(WORKER_DOWN_KIND=pr_url lib 'bor_list p'); RC=$?
{ [ "$RC" = 1 ] && [ -z "$OUT" ]; } \
  && ok || bad "A5: pr_url feed down after result answered must be rc 1 with no output (a half join reads as 'no PR'), got rc $RC '$OUT'"
OUT=$(WORKER_DOWN_KIND=result lib 'bor_list p'); RC=$?
{ [ "$RC" = 1 ] && [ -z "$OUT" ]; } && ok || bad "A5: result feed down must be rc 1, got rc $RC '$OUT'"
OUT=$(lib 'unset -f job_artifact_feed; bor_list p'); RC=$?
{ [ "$RC" = 1 ] && [ -z "$OUT" ]; } && ok || bad "A5: no job_artifact_feed must be rc 1 with no output, got rc $RC '$OUT'"

# ═════════════════════════════════════════════════════════════════════════════
# A6 — truncation and the limit
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J1 'PR_CREATED x' box1 2026-09-20T00:00:02Z p-TK-1-1 TK-1)" \
            "$(res_row J2 'PR_CREATED y' box1 2026-09-20T00:00:01Z p-TK-2-1 TK-2)"
ERR=$(lib 'bor_list p "" 2 >/dev/null' 2>&1 >/dev/null)
grep -qx 'BOR_TRUNCATED=1' <<<"$ERR" && ok || bad "A6: a feed at the limit must write BOR_TRUNCATED=1 to stderr, got '$ERR'"
V=$(lib 'bor_list p "" 2 >/dev/null 2>&1; printf %s "${BOR_TRUNCATED:-unset}"')
[ "$V" = 1 ] && ok || bad "A6: BOR_TRUNCATED must be 1 after a direct call at the limit, got '$V'"
V=$(lib 'bor_list p "" 3 >/dev/null 2>&1; printf %s "${BOR_TRUNCATED:-unset}"')
[ "$V" = unset ] && ok || bad "A6: below the limit BOR_TRUNCATED must be unset, got '$V'"
V=$(lib 'export BOR_TRUNCATED=1; bor_list p "" 3 >/dev/null 2>&1; printf %s "${BOR_TRUNCATED:-unset}"')
[ "$V" = unset ] && ok || bad "A6: a BOR_TRUNCATED left by an earlier call must be cleared, got '$V'"
ERR=$(lib 'bor_list p "" 3 >/dev/null' 2>&1 >/dev/null)
[ -z "$ERR" ] && ok || bad "A6: below the limit stderr must be quiet, got '$ERR'"
# The pr_url feed at the limit truncates too: its dropped rows are PRs we lose.
feed result "$(res_row J1 'PR_CREATED x' box1 2026-09-20T00:00:02Z p-TK-1-1 TK-1)"
feed pr_url "$(pr_row J1 "$P1" 2026-09-20T00:00:02Z)" "$(pr_row J2 "$P1" 2026-09-20T00:00:01Z)"
V=$(lib 'bor_list p "" 2 >/dev/null 2>&1; printf %s "${BOR_TRUNCATED:-unset}"')
[ "$V" = 1 ] && ok || bad "A6: a pr_url feed at the limit must set BOR_TRUNCATED, got '$V'"

rm -f "$T/req.txt"
lib 'bor_list p >/dev/null 2>&1'
N=$(grep -cE 'limit=500(&|$)' "$T/req.txt")
[ "$N" = 2 ] && ok || bad "A6: no limit arg must query limit=500 on both feeds, got: $(cat "$T/req.txt")"
rm -f "$T/req.txt"
lib 'BOR_LIMIT=7 bor_list p >/dev/null 2>&1'
N=$(grep -cE 'limit=7(&|$)' "$T/req.txt")
[ "$N" = 2 ] && ok || bad "A6: BOR_LIMIT=7 must reach both queries, got: $(cat "$T/req.txt")"
rm -f "$T/req.txt"
lib 'bor_list p 2026-09-01T00:00:00Z >/dev/null 2>&1'
N=$(grep -c 'since=2026-09-01T00:00:00Z' "$T/req.txt")
[ "$N" = 2 ] && ok || bad "A6: since must reach both queries, got: $(cat "$T/req.txt")"

# ═════════════════════════════════════════════════════════════════════════════
# A7 — escaped tab/newline in a ref
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J1 "PR_CREATED a${TAB}b"$'\n'"c" box1 2026-09-20T00:00:02Z p-TK-1-1 TK-1)"
feed pr_url "$(pr_row J1 "https://x/pull/1${TAB}evil" 2026-09-20T00:00:02Z)"
OUT=$(lib 'bor_list p')
{ [ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && [ "$(awk -F'\t' '{print NF}' <<<"$OUT")" = 7 ]; } \
  && ok || bad "A7: an escaped tab/newline in a ref must stay one row of 7 columns, got: $OUT"
[ "$(cut -f5 <<<"$OUT")" = 'PR_CREATED a\tb\nc' ] && ok || bad "A7: the escape stays literal, got '$(cut -f5 <<<"$OUT")'"

# ═════════════════════════════════════════════════════════════════════════════
# U — bor_union and bor_local_dir
# ═════════════════════════════════════════════════════════════════════════════
reset
feed result "$(res_row J1 'PR_CREATED ledger1' box1 2026-09-20T00:00:03Z p-TK-1-1 TK-1)" \
            "$(res_row J2 'PR_CREATED ledger2' box1 2026-09-20T00:00:02Z p-TK-2-1 TK-2)" \
            "$(res_row J3 'PR_CREATED ledger3' box1 2026-09-20T00:00:01Z pool-p-TK-3-1 TK-3)"
feed pr_url "$(pr_row J2 "$P1" 2026-09-20T00:00:02Z)"
B="$T/h/builds"
mkdir -p "$B/p-TK-9-1" "$B/p-TK-2-1" "$B/pool-p-TK-3-1" "$B/p-os-TK-4-1" "$B/fly-p-TK-8-1" "$B/p-notes"
printf 'PR_CREATED local\nsecond line\n' > "$B/p-TK-9-1/RESULT"
printf 'PR_CREATED disk2\n' > "$B/p-TK-2-1/RESULT"
printf 'PR_CREATED disk3\n' > "$B/pool-p-TK-3-1/RESULT"
printf 'PR_CREATED other project\n' > "$B/p-os-TK-4-1/RESULT"
printf 'PR_CREATED fly%scopy\n' "$TAB" > "$B/fly-p-TK-8-1/RESULT"
printf 'x\n' > "$B/p-notes/RESULT"
touch -d '2026-01-02 03:04:05 UTC' "$B"/*/RESULT
OUT=$(lib 'bor_union p'); RC=$?
[ "$RC" = 0 ] && ok || bad "U: rc 0 expected, got $RC"
row() { printf '%s\n' "$OUT" | awk -F'\t' -v b="$1" '$2 == b'; }

# U1 local-only
L=$(row p-TK-9-1)
[ "$L" = "TK-9${TAB}p-TK-9-1${TAB}-${TAB}2026-01-02T03:04:05Z${TAB}PR_CREATED local${TAB}-${TAB}-" ] \
  && ok || bad "U1: local-only row wrong, got '$L'"
L=$(row p-TK-8-1)
{ [ "$(awk -F'\t' '{print NF}' <<<"$L")" = 7 ] && [ "$(cut -f5 <<<"$L")" = 'PR_CREATED fly copy' ]; } \
  && ok || bad "U1: a fly- copy is found, a tab in its RESULT becomes a space and 7 columns hold, got '$L'"
# U2 ledger-only
[ "$(cut -f7 <<<"$(row p-TK-1-1)")" = J1 ] && ok || bad "U2: ledger-only row must appear, got: $OUT"
LD=$(lib 'bor_local_dir p-TK-1-1'); RC=$?
{ [ "$RC" = 2 ] && [ -z "$LD" ]; } && ok || bad "U2: bor_local_dir for a ledger-only row: rc 2 and nothing, got rc $RC '$LD'"
# U3 both, once, ledger timestamp
[ "$(row p-TK-2-1 | wc -l)" = 1 ] && ok || bad "U3: a record on disk and in the ledger appears once, got: $OUT"
[ "$(row p-TK-2-1 | cut -f4,6,7)" = "2026-09-20T00:00:02Z${TAB}${P1}${TAB}J2" ] \
  && ok || bad "U3: it carries the ledger timestamp and job, got '$(row p-TK-2-1)'"
LD=$(lib 'bor_local_dir p-TK-2-1')
[ "$LD" = "$B/p-TK-2-1" ] && ok || bad "U3: bor_local_dir exact name, got '$LD'"
# U4 pool copy
[ "$(row p-TK-3-1 | wc -l)" = 1 ] && ok || bad "U4: a pool- copy is not doubled, got: $OUT"
grep -q pool- <<<"$(cut -f2 <<<"$OUT")" && bad "U4: no pool-/fly- name in column 2, got: $OUT" || ok
LD=$(lib 'bor_local_dir p-TK-3-1')
[ "$LD" = "$B/pool-p-TK-3-1" ] && ok || bad "U4: bor_local_dir must print the pool- path, got '$LD'"
LD=$(lib 'bor_local_dir p-TK-8-1')
[ "$LD" = "$B/fly-p-TK-8-1" ] && ok || bad "U4: bor_local_dir must print the fly- path, got '$LD'"
lib 'bor_local_dir ""' >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "U4: bor_local_dir with no arg is rc 1, got $RC"
# U6 prefix guard
{ [ -z "$(row p-os-TK-4-1)" ] && [ -z "$(row os-TK-4-1)" ] && [ -z "$(row p-notes)" ]; } \
  && ok || bad "U6: another project's dir (p-os-*) and a non-ticket dir must not appear for project p, got: $OUT"
[ "$(printf '%s\n' "$OUT" | wc -l)" = 5 ] && ok || bad "U: 5 rows expected (3 ledger + 2 local-only), got: $OUT"
[ "$(head -3 <<<"$OUT" | cut -f7 | tr '\n' ' ')" = "J1 J2 J3 " ] && ok || bad "U: ledger rows first in feed order, got: $OUT"
# project-4 must not see project-4-notes; project-4 must not see project-4-TK-1-1.
mkdir -p "$B/project-4-TK-1-1" "$B/project-4-notes"
printf 'x\n' > "$B/project-4-TK-1-1/RESULT"; printf 'x\n' > "$B/project-4-notes/RESULT"
rm -f "$FIX/result" "$FIX/pr_url"
OUT=$(lib 'bor_union project-4'); RC=$?
{ [ "$RC" = 2 ] && [ -z "$OUT" ]; } && ok || bad "U6: project project-4 must not take project-4-TK-1-1, got rc $RC '$OUT'"
OUT=$(lib 'bor_union project-4')
[ "$(cut -f2 <<<"$OUT")" = project-4-TK-1-1 ] && ok || bad "U6: project project-4 sees its own dir and not project-4-notes, got '$OUT'"

# U5 outage
OUT=$(WORKER_DOWN=1 lib 'bor_union p'); RC=$?
{ [ "$RC" = 1 ] && [ -z "$OUT" ]; } && ok || bad "U5: outage must be rc 1 with no output even with local dirs, got rc $RC '$OUT'"
# The truncation line still reaches the caller through bor_union.
feed result "$(res_row J1 'PR_CREATED x' box1 2026-09-20T00:00:02Z p-TK-1-1 TK-1)"
ERR=$(lib 'BOR_LIMIT=1 bor_union p >/dev/null' 2>&1 >/dev/null)
grep -qx 'BOR_TRUNCATED=1' <<<"$ERR" && ok || bad "U5: bor_union must pass the BOR_TRUNCATED stderr line through, got '$ERR'"

printf 'builds-of-record: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
