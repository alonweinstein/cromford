#!/bin/bash
# tests/overlap-guard-preplan-source-test.sh — the overlap guard reads the SAME
# pre-plan source the builder will be handed, and never reports "no overlap"
# purely because it looked in an empty directory.
# Run from anywhere: tests/overlap-guard-preplan-source-test.sh  (exit 0 = pass)
#
# WHY (BH-658). bin/overlap-guard.sh:files_of read
# $HARNESS/plans/<project>-<KEY>/planned-files.txt. On the HUB — which is where
# bin/fly-dispatch.sh calls this guard from — that directory is empty by design:
# the hub is forbidden to pre-plan. So every Fly candidate answered "no
# files-to-touch list", the guard could not judge, and two builds were launched
# onto the same files. With the pre-plan published as a row, the list is
# readable from the hub too, and the guard judges what it could not see before.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin/lib" "$T/fakebin" "$T/env" "$T/flags" "$T/logs" "$T/plans" \
         "$T/state" "$T/builds" "$T/curl"
cp "$DIR/bin/overlap-guard.sh" "$DIR/bin/jobs-client.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/scheduler-conf.sh" "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$T/bin/lib/"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"  # TEST-CHANGE (BH-1585): REST list needs it
: > "$T/env/global.env"

cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in repo) echo example-org/proj ;; *) echo '-' ;; esac
SH
chmod +x "$T/bin/fleet-conf.sh"
# No open PRs — this suite is about the pre-plan source, and a real `gh` on the
# box would otherwise reach GitHub from a test.
# TEST-CHANGE (BH-1585): the open list is a REST read now (status line first).
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$*" in *"api -i"*) printf 'HTTP/2.0 200\r\n\r\n' ;; esac
echo '[]'
SH
chmod +x "$T/fakebin/gh"

# The same recording fake curl tests/preplan-relay-test.sh uses: it answers from
# $CURL_DIR/routes and logs every call, so "the guard never asked" is provable.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
D="${CURL_DIR:?CURL_DIR unset}"
M=GET; U=""; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M="$2"; shift 2 ;;
    --data-binary) BODY="$2"; shift 2 ;;
    -H|-m|--connect-timeout|-w|-o) shift 2 ;;
    -*) shift ;;
    *) U="$1"; shift ;;
  esac
done
printf '%s\t%s\n' "$M" "$U" >> "$D/calls"
CODE=404; FILE=""
if [ -s "$D/routes" ]; then
  while IFS=$'\t' read -r PAT C F; do
    [ -n "$PAT" ] || continue
    case "$U" in *"$PAT"*) CODE="$C"; FILE="$F"; break ;; esac
  done < "$D/routes"
fi
if [ -n "$FILE" ] && [ -r "$FILE" ]; then cat "$FILE"; else printf '{"error":"no route"}'; fi
printf '\n%s' "$CODE"
exit 0
SH
chmod +x "$T/fakebin/curl"

printf '{"jobs":[{"id":"build-proj-AB-2-1","project":"proj","kind":"build","ticket_id":"AB-2","status":"running"}]}' \
  > "$T/curl/jobs.json"
printf '{"preplans":[{"ticket_key":"AB-1","base_sha":"1234567","planned_files":"src/a.ts\\n","updated_at":"2026-09-17T10:00:00Z"}]}' \
  > "$T/curl/preplans.json"

# The sibling that is ALREADY building, with its own files-to-touch list on this
# box's disk — the half of the comparison that has always worked.
mkdir -p "$T/builds/proj-AB-2-202609171200"
printf 'src/a.ts\n' > "$T/builds/proj-AB-2-202609171200/planned-files.txt"

printf '{"jobs":[]}' > "$T/curl/jobs-none.json"

guard() { # guard <preplans-http-code> [jobs-fixture] -> verdict line + rc
  rm -f "$T/curl/calls" "$T/curl/routes"
  printf '/api/jobs\t200\t%s\n' "${2:-$T/curl/jobs.json}" > "$T/curl/routes"
  printf '/api/preplans\t%s\t%s\n' "$1" "$T/curl/preplans.json" >> "$T/curl/routes"
  ( export HARNESS="$T" PATH="$T/fakebin:$PATH" CURL_DIR="$T/curl" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0
    "$T/bin/overlap-guard.sh" proj AB-1; echo "rc=$?" )
}

# 1. the hub's plans/ dir is EMPTY and the row carries the list -> the guard
#    judges, and holds the ticket that would have landed on a live sibling.
#    This is the ticket's whole point, so it runs unconditionally: if the #773
#    contract (preplan_planned_files + preplan_index) ever goes missing from the
#    lib this suite copies, these four assertions FAIL. They do not skip.
OUT=$(guard 200)
grep -q '^DEFER AB-1 vs AB-2(building)' <<<"$OUT" \
  && ok || bad "with the pre-plan published, the guard must DEFER against the building sibling (got: $OUT)"
grep -q 'files=\[src/a.ts\]' <<<"$OUT" \
  && ok || bad "the DEFER must name the colliding file (got: $OUT)"
grep -q 'rc=1' <<<"$OUT" && ok || bad "a DEFER must exit 1 (got: $OUT)"
grep -q '/api/preplans' "$T/curl/calls" \
  && ok || bad "the guard must ask the DB for the candidate's file list (calls: $(cat "$T/curl/calls"))"

# 2. no row either -> the honest "cannot judge", never "no overlap"
OUT=$(guard 404)
grep -q '^LAUNCH AB-1 no files-to-touch list' <<<"$OUT" \
  && ok || bad "with no list anywhere the guard must LAUNCH saying it cannot judge (got: $OUT)"
grep -q 'rc=0' <<<"$OUT" && ok || bad "a LAUNCH must exit 0 (got: $OUT)"

# 3. a LOCAL pre-plan dir still wins, and costs no request — a watcher box's
#    behaviour must be byte-identical to what it is today.
mkdir -p "$T/plans/proj-AB-1"
printf 'src/z.ts\n' > "$T/plans/proj-AB-1/planned-files.txt"
OUT=$(guard 200)
grep -q '^LAUNCH AB-1 no collision' <<<"$OUT" \
  && ok || bad "the LOCAL list (src/z.ts, no collision) must win over the DB row (got: $OUT)"
# ...and with nothing else building, a box whose plans/ dir is populated asks
# the DB nothing at all: a watcher box's behaviour is what it was before.
OUT=$(guard 200 "$T/curl/jobs-none.json")
grep -q '^LAUNCH AB-1 no collision' <<<"$OUT" \
  && ok || bad "a quiet project with a local list must LAUNCH (got: $OUT)"
grep -q '/api/preplans' "$T/curl/calls" \
  && bad "a local pre-plan dir must cost no /api/preplans request (calls: $(cat "$T/curl/calls"))" || ok

echo "overlap-guard-preplan-source: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
