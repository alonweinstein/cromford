#!/bin/bash
# tests/restore-merge-test.sh — bin/restore-merge.sh against real fixture trees.
# Pure local: no stubs, no network, no PATH games. Every section builds a fresh
# snapshot/live pair under $T and drives the script through its own CLI.
#
# WHY THE SCRIPT EXISTS (2026-09-15, example-org/cromford#388). The hub's
# /root/harness/{env,bin,prompts,logs,builds} vanished under a running system.
# The recovery merged a backup snapshot back over what survived, and the merge
# policy that did it was never committed. This is that policy, and these are the
# rules it has to keep: never overwrite live with older snapshot content, merge
# ledgers history-first, back up every file it replaces, and move the alerts
# cursor to the END of the merged ALERTS.log — the recovery forgot that last one
# and poll-commands re-beat every historical alert it found behind the cursor.
#
# What is proved here:
#   A0 dry run writes nothing at all and exits 0;
#   A1 a missing nested file (with a space in its path) is added, mode preserved;
#   A2 ledger merge is history-first and exact-line, live is backed up first;
#   A2b a second apply over the merged result is byte-identical (idempotent);
#   A3 pr-state.tsv unions, header once from live, live key wins, and a
#      snapshot-only header is never grafted onto a headerless live file;
#   A4 env/, state/quota/, state/wake-cursor and any other differing file are
#      KEEP-LIVE, and no file CONTENT is ever printed;
#   A5 the backup dir holds every replaced file and nothing else, and is not
#      created when nothing is replaced;
#   A6 the cursor is the byte size of the merged ALERTS.log, also when it was
#      added, and a stale larger cursor is overwritten;
#   A7 orchestrator/ maps to --orchestrator-live, not under --live;
#   A8 the near-miss paths (logs/x.log.gz, logs/sub/x.log, state/pr-owners/*.json,
#      pr-state.tsv.lock, builds/a/b/pipeline.log) are KEEP-LIVE, not merged;
#   A9 a copy that cannot land exits 1, names the file, and does not stop the
#      files after it from landing.
# Run from anywhere: tests/restore-merge-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The clock is pinned so the default backup path this script prints is the same
# string on every run and on every box (the script reads RESTORE_NOW).
NOW=1757980800
export RESTORE_NOW=$NOW
TS=$(date -u -d "@$NOW" +%Y%m%dT%H%M%SZ)
RM="$DIR/bin/restore-merge.sh"

# A fresh, independent pair per section: no section can see another's leftovers.
fixture() {
  S=$(mktemp -d "$T/snap-XXXXXX")
  L=$(mktemp -d "$T/live-XXXXXX")
}

# Contents AND modes of a whole tree, so "wrote nothing" is a real claim.
tree_hash() {
  {
    find "$1" -type f -print0 | sort -z | xargs -0 -r sha256sum
    find "$1" -printf '%p %m\n' | sort
  } | sha256sum
}

has()  { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# ── A0 — dry run writes nothing ──────────────────────────────────────────────
fixture
mkdir -p "$S/logs" "$S/state/merge-conductor" "$S/env" "$S/meta" "$S/builds/x"
printf 'S1\nS2\n'            > "$S/logs/decisions.log"
printf 'key\tstate\nk1\tsnap\n' > "$S/state/merge-conductor/pr-state.tsv"
printf 'FOO=placeholder\n'   > "$S/env/global.env"
printf 'MAILTO=""\n'         > "$S/meta/crontab.txt"
printf 'P0\n'                > "$S/builds/x/pipeline.log"
printf 'new\n'               > "$S/state/new.json"
mkdir -p "$L/logs" "$L/state/merge-conductor" "$L/env"
printf 'L1\n'                > "$L/logs/decisions.log"
printf 'k1\tlive\n'          > "$L/state/merge-conductor/pr-state.tsv"
printf 'FOO=live\n'          > "$L/env/global.env"
H0=$(tree_hash "$L")
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --backup-dir "$T/bk0"); rc=$?
[ "$rc" -eq 0 ] || bad "A0 dry run exit $rc, want 0"; [ "$rc" -eq 0 ] && ok
[ "$(tree_hash "$L")" = "$H0" ] && ok || bad "A0 dry run changed the live tree"
[ -e "$L/flags/.alerts-cursor" ] && bad "A0 dry run wrote the cursor" || ok
[ -e "$T/bk0" ] && bad "A0 dry run created the backup dir" || ok
has 'SUMMARY mode=dry-run' "$OUT" && ok || bad "A0 no dry-run summary: $OUT"
has 'META meta/crontab.txt' "$OUT" && ok || bad "A0 meta/ not reported: $OUT"
[ -e "$L/meta" ] && bad "A0 meta/ was applied" || ok
NFILES=$(find "$S" -type f | wc -l)
NLINES=$(printf '%s\n' "$OUT" | grep -c '^\(SAME\|ADD\|LEDGER\|UNION\|KEEP-LIVE\|META\) ')
[ "$NLINES" -eq "$NFILES" ] && ok || bad "A0 $NLINES verb lines for $NFILES snapshot files"

# ── A1 — add-missing, nested, spaces in the path, mode preserved ─────────────
fixture
mkdir -p "$S/state/pr-owners/a b"
printf '{"o":1}\n' > "$S/state/pr-owners/a b/x.json"
chmod 640 "$S/state/pr-owners/a b/x.json"
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --apply --backup-dir "$T/bk1"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A1 exit $rc, want 0: $OUT"
cmp -s "$S/state/pr-owners/a b/x.json" "$L/state/pr-owners/a b/x.json" && ok \
  || bad "A1 nested file with a space did not land"
[ "$(stat -c %a "$L/state/pr-owners/a b/x.json" 2>/dev/null)" = "640" ] && ok \
  || bad "A1 mode not preserved: $(stat -c %a "$L/state/pr-owners/a b/x.json" 2>/dev/null)"
has 'ADD state/pr-owners/a b/x.json' "$OUT" && ok || bad "A1 no ADD line: $OUT"

# ── A2 — ledger history-first ────────────────────────────────────────────────
fixture
mkdir -p "$S/logs" "$S/builds/x" "$L/logs" "$L/builds/x"
printf 'S1\nS2\nL1\n' > "$S/logs/decisions.log"
printf 'L1\nL2\n'     > "$L/logs/decisions.log"
printf 'P0\n'         > "$S/builds/x/pipeline.log"
printf 'P1\n'         > "$L/builds/x/pipeline.log"
printf 'A0\n'         > "$S/logs/a b.log"
printf 'A1\n'         > "$L/logs/a b.log"
OLD=$(cat "$L/logs/decisions.log")
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --apply --backup-dir "$T/bk2"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A2 exit $rc, want 0: $OUT"
[ "$(cat "$L/logs/decisions.log")" = "$(printf 'S1\nS2\nL1\nL2')" ] && ok \
  || bad "A2 decisions.log merged wrong: $(cat "$L/logs/decisions.log")"
[ "$(cat "$L/builds/x/pipeline.log")" = "$(printf 'P0\nP1')" ] && ok \
  || bad "A2 pipeline.log merged wrong: $(cat "$L/builds/x/pipeline.log")"
[ "$(cat "$L/logs/a b.log")" = "$(printf 'A0\nA1')" ] && ok \
  || bad "A2 ledger with a space in the name merged wrong"
[ "$(cat "$T/bk2/logs/decisions.log")" = "$OLD" ] && ok \
  || bad "A2 backup is not the pre-merge live file"
has 'LEDGER logs/decisions.log' "$OUT" && ok || bad "A2 no LEDGER line: $OUT"

# A2b — a second apply over the merged result changes nothing
H2=$(tree_hash "$L")
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --apply --backup-dir "$T/bk2b"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A2b exit $rc, want 0: $OUT"
[ "$(tree_hash "$L")" = "$H2" ] && ok || bad "A2b re-apply changed the live tree"
has 'SAME logs/decisions.log' "$OUT" && ok || bad "A2b not reported SAME: $OUT"
[ -e "$T/bk2b" ] && bad "A2b backed up a file it did not replace" || ok

# ── A3 — pr-state.tsv union ──────────────────────────────────────────────────
fixture
mkdir -p "$S/state/merge-conductor" "$L/state/merge-conductor"
printf 'key\tstate\nk1\tsnap\nk2\tsnap\n' > "$S/state/merge-conductor/pr-state.tsv"
printf 'key\tstate\nk1\tlive\n'           > "$L/state/merge-conductor/pr-state.tsv"
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --apply --backup-dir "$T/bk3"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A3 exit $rc, want 0: $OUT"
GOT=$(cat "$L/state/merge-conductor/pr-state.tsv")
[ "$GOT" = "$(printf 'key\tstate\nk1\tlive\nk2\tsnap')" ] && ok || bad "A3 union wrong: $GOT"
[ "$(grep -c '^key' "$L/state/merge-conductor/pr-state.tsv")" = "1" ] && ok \
  || bad "A3 header not kept exactly once"
has 'UNION state/merge-conductor/pr-state.tsv' "$OUT" && ok || bad "A3 no UNION line: $OUT"

# A3b — live has NO header (today's shape on the hub): a snapshot-only header is
# dropped, never grafted onto a headerless live file, or the first live row of
# every future reader is a column name.
fixture
mkdir -p "$S/state/merge-conductor" "$L/state/merge-conductor"
printf 'key\tstate\nk1\tsnap\nk2\tsnap\n' > "$S/state/merge-conductor/pr-state.tsv"
printf 'k1\tlive\n'                           > "$L/state/merge-conductor/pr-state.tsv"
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --apply --backup-dir "$T/bk3b"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A3b exit $rc, want 0: $OUT"
GOT=$(cat "$L/state/merge-conductor/pr-state.tsv")
[ "$GOT" = "$(printf 'k1\tlive\nk2\tsnap')" ] && ok || bad "A3b union wrong: $GOT"
[ "$(grep -c '^key' "$L/state/merge-conductor/pr-state.tsv")" = "0" ] && ok \
  || bad "A3b a snapshot header was grafted onto a headerless live file"

# ── A4 — keep-live, and no file content on stdout ────────────────────────────
fixture
mkdir -p "$S/env" "$S/state/quota" "$S/state" "$L/env" "$L/state/quota" "$L/state"
printf 'SNAPVALUE=never-printed-by-restore-merge\n' > "$S/env/global.env"
printf 'FOO=live\n'      > "$L/env/global.env"
printf '{"q":0}\n'       > "$S/state/quota/a.json"
printf '{"q":9}\n'       > "$L/state/quota/a.json"
printf '10\n'            > "$S/state/wake-cursor"
printf '99\n'            > "$L/state/wake-cursor"
printf '{"s":1}\n'       > "$S/state/other.json"
printf '{"s":2}\n'       > "$L/state/other.json"
H4=$(tree_hash "$L")
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --apply --backup-dir "$T/bk4"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A4 exit $rc, want 0: $OUT"
[ "$(tree_hash "$L")" = "$H4" ] && ok || bad "A4 keep-live tree was modified"
for R in env/global.env state/quota/a.json state/wake-cursor state/other.json; do
  has "KEEP-LIVE $R" "$OUT" && ok || bad "A4 no KEEP-LIVE line for $R: $OUT"
done
has 'never-printed-by-restore-merge' "$OUT" && bad "A4 printed snapshot file content" || ok
[ -e "$T/bk4" ] && bad "A4 backed up a file it did not replace" || ok

# ── A5 — the backup dir holds every replaced file and nothing else ───────────
fixture
mkdir -p "$S/logs" "$S/builds/x" "$S/state/merge-conductor" "$S/env" "$S/state"
mkdir -p "$L/logs" "$L/builds/x" "$L/state/merge-conductor" "$L/env"
printf 'S1\n' > "$S/logs/decisions.log";        printf 'L1\n' > "$L/logs/decisions.log"
printf 'P0\n' > "$S/builds/x/pipeline.log";     printf 'P1\n' > "$L/builds/x/pipeline.log"
printf 'k2\tsnap\n' > "$S/state/merge-conductor/pr-state.tsv"
printf 'k1\tlive\n' > "$L/state/merge-conductor/pr-state.tsv"
printf 'FOO=placeholder\n' > "$S/env/global.env"; printf 'FOO=live\n' > "$L/env/global.env"
printf 'add\n' > "$S/state/added.json"
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --apply --backup-dir "$T/bk5"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A5 exit $rc, want 0: $OUT"
GOT=$(cd "$T/bk5" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')
WANT="builds/x/pipeline.log logs/decisions.log state/merge-conductor/pr-state.tsv "
[ "$GOT" = "$WANT" ] && ok || bad "A5 backup dir holds [$GOT], want [$WANT]"
# an apply whose snapshot only ADDs creates no backup dir at all
fixture
mkdir -p "$S/state"; printf 'only\n' > "$S/state/only-add.json"
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --apply --backup-dir "$T/bk5b"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A5b exit $rc, want 0: $OUT"
[ -e "$T/bk5b" ] && bad "A5b created a backup dir with nothing replaced" || ok
# the default backup path is printed (RESTORE_NOW-pinned) and not created
OUT=$(bash "$RM" --snapshot "$S" --live "$L"); rc=$?
has "backup=/root/restore-merge-backup/$TS" "$OUT" && ok \
  || bad "A5c default backup path not in summary: $OUT"
[ -e "/root/restore-merge-backup/$TS" ] && bad "A5c dry run created the default backup dir" || ok

# ── A6 — the alerts cursor ───────────────────────────────────────────────────
fixture
mkdir -p "$S/logs" "$L/logs"
printf 'a1\na2\na3\n' > "$S/logs/ALERTS.log"
printf 'b1\nb2\n'     > "$L/logs/ALERTS.log"
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --apply --backup-dir "$T/bk6"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A6 exit $rc, want 0: $OUT"
N=$(wc -c < "$L/logs/ALERTS.log")
[ "$(cat "$L/flags/.alerts-cursor")" = "$N" ] && ok \
  || bad "A6 cursor is $(cat "$L/flags/.alerts-cursor" 2>/dev/null), want $N"
has "CURSOR flags/.alerts-cursor -> $N" "$OUT" && ok || bad "A6 no CURSOR line: $OUT"
# (ii) ALERTS.log added rather than merged
fixture
mkdir -p "$S/logs"
printf 'a1\na2\n' > "$S/logs/ALERTS.log"
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --apply --backup-dir "$T/bk6b"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A6b exit $rc, want 0: $OUT"
N=$(wc -c < "$L/logs/ALERTS.log")
[ "$(cat "$L/flags/.alerts-cursor")" = "$N" ] && ok \
  || bad "A6b cursor after ADD is $(cat "$L/flags/.alerts-cursor" 2>/dev/null), want $N"
# (iii) a stale larger cursor is overwritten
fixture
mkdir -p "$S/logs" "$L/logs" "$L/flags"
printf 'a1\n' > "$S/logs/ALERTS.log"
printf 'a1\nb2\n' > "$L/logs/ALERTS.log"
printf '999999\n' > "$L/flags/.alerts-cursor"
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --apply --backup-dir "$T/bk6c"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A6c exit $rc, want 0: $OUT"
N=$(wc -c < "$L/logs/ALERTS.log")
[ "$(cat "$L/flags/.alerts-cursor")" = "$N" ] && ok \
  || bad "A6c stale cursor not overwritten: $(cat "$L/flags/.alerts-cursor")"

# ── A7 — orchestrator/ maps to --orchestrator-live ───────────────────────────
fixture
O=$(mktemp -d "$T/orch7-XXXXXX")
mkdir -p "$S/orchestrator"
printf '{"o":1}\n' > "$S/orchestrator/orch.json"
printf 'snap\n'    > "$S/orchestrator/keep.json"
printf 'live\n'    > "$O/keep.json"
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --apply --orchestrator-live "$O" --backup-dir "$T/bk7"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A7 exit $rc, want 0: $OUT"
cmp -s "$S/orchestrator/orch.json" "$O/orch.json" && ok || bad "A7 orch.json did not land in the orchestrator tree"
[ -e "$L/orchestrator" ] && bad "A7 orchestrator/ landed under --live" || ok
[ "$(cat "$O/keep.json")" = "live" ] && ok || bad "A7 orchestrator keep.json was overwritten"
has 'KEEP-LIVE orchestrator/keep.json' "$OUT" && ok || bad "A7 no KEEP-LIVE line: $OUT"

# ── A8 — the near misses are KEEP-LIVE, never merged ─────────────────────────
fixture
NEG="logs/x.log.gz state/pr-owners/r.json logs/sub/x.log state/merge-conductor/pr-state.tsv.lock logs/ALERTS.log.1 builds/a/b/pipeline.log builds/x/plan.md"
for R in $NEG; do
  mkdir -p "$S/$(dirname "$R")" "$L/$(dirname "$R")"
  printf 'snap\n' > "$S/$R"
  printf 'live\n' > "$L/$R"
done
H8=$(tree_hash "$L")
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --apply --backup-dir "$T/bk8"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A8 exit $rc, want 0: $OUT"
[ "$(tree_hash "$L")" = "$H8" ] && ok || bad "A8 a near-miss path was rewritten"
for R in $NEG; do
  has "KEEP-LIVE $R" "$OUT" && ok || bad "A8 $R was not KEEP-LIVE: $OUT"
done
[ -e "$T/bk8" ] && bad "A8 backed up a near-miss path" || ok

# ── A9 — a copy that cannot land ─────────────────────────────────────────────
fixture
mkdir -p "$S/state/sub"
printf 'n\n'  > "$S/state/sub/new.txt"
printf 'ok\n' > "$S/state/ok.txt"
printf 'zz\n' > "$S/state/zz.txt"
mkdir -p "$L/state"
printf 'i am a file, not a directory\n' > "$L/state/sub"
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --apply --backup-dir "$T/bk9"); rc=$?
[ "$rc" -eq 1 ] && ok || bad "A9 exit $rc, want 1: $OUT"
has 'FAILED state/sub/new.txt' "$OUT" && ok || bad "A9 summary does not name the file: $OUT"
has 'failed=1' "$OUT" && ok || bad "A9 failed count wrong: $OUT"
[ -f "$L/state/ok.txt" ] && ok || bad "A9 stopped at the failure — state/ok.txt did not land"
[ -f "$L/state/zz.txt" ] && ok || bad "A9 stopped at the failure — state/zz.txt did not land"

# ── usage errors ─────────────────────────────────────────────────────────────
OUT=$(bash "$RM" --snapshot "$T/nope" --live "$L" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok || bad "usage: missing snapshot dir exit $rc, want 2"
OUT=$(bash "$RM" --snapshot "$S" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok || bad "usage: missing --live exit $rc, want 2"
OUT=$(bash "$RM" --snapshot "$S" --live "$L" --wat 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok || bad "usage: unknown flag exit $rc, want 2"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
