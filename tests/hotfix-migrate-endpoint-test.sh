#!/bin/bash
# tests/hotfix-migrate-endpoint-test.sh — the hotfix go-live stage, endpoint shape
# (BH-375 / BH-370.1).
#
# WHY THIS TEST EXISTS. This stage is the one place in the harness where a build
# session causes a WRITE to a client production database. Everything else it does
# is reversible: a PR can be closed, a comment edited, a tier demoted. An applied
# migration cannot be un-applied from here. So the interesting assertions are not
# "does the happy path work" but "does every unhappy path refuse to touch the
# endpoint": a flagged statement, a red check run, a checks read nobody could
# make, a lock the cron tick already owns, a status word we do not recognise.
# Each of those is driven here against stub `gh` and `curl` binaries, and the
# proof in every case is $T/posts.log — the literal list of filenames that
# reached POST /apply. An empty posts.log is the assertion, not a side note.
#
# Run from anywhere: tests/hotfix-migrate-endpoint-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v perl >/dev/null || { echo "perl missing — skipping"; exit 0; }

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/env" "$T/h/builds" "$T/fakebin"
for f in hotfix-migrate.sh apply-migrations.sh check-migration-appliable.sh; do
  [ -f "$DIR/bin/$f" ] && cp "$DIR/bin/$f" "$T/h/bin/$f"
done
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-ci-read.sh" "$T/h/bin/lib/"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/gh-token.sh"; chmod +x "$T/h/bin/gh-token.sh"
: > "$T/h/env/global.env"
printf 'PROJECT_1_API_BASE=http://stub\nMIGRATION_TOKEN=t\n' > "$T/h/env/project-1.env"
: > "$T/h/env/x-os.env"

# ---------------------------------------------------------------------------
# stubs. gh records EVERY argv line; curl records every filename that was POSTed.
# ---------------------------------------------------------------------------
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$*" in
  "api repos/"*"/issues/"*"/comments"*)
    for a in "\$@"; do case "\$a" in body=@*) cp "\${a#body=@}" "$T/comment.md" ;; esac; done
    if [ -f "$T/comment.fail" ]; then echo "gh: could not post" >&2; exit 1; fi
    echo 4242; exit 0 ;;
  "api repos/"*"/actions/runs"*)
    cat "$T/runs.json" 2>/dev/null || echo '{"workflow_runs":[]}'; exit 0 ;;
  "api repos/"*) echo 1; exit 0 ;;
  "pr checks"*)
    cat "$T/checks.out" 2>/dev/null
    # --watch hangs on a check that never settles; $T/checks.hang makes the stub
    # do exactly that so the real \`timeout\` path (rc 124) gets exercised. exec
    # so the hang IS this process and the stage's timeout kills it, no orphan.
    [ -f "$T/checks.hang" ] && exec sleep infinity
    exit "\$(cat "$T/checks.rc" 2>/dev/null || echo 1)" ;;
  "pr list"*) echo "https://github.com/o/p/pull/9"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
url=""; body=""; prev=""
for a in "\$@"; do
  case "\$a" in http*) url="\$a" ;; esac
  [ "\$prev" = "-d" ] && body="\$a"
  prev="\$a"
done
case "\$url" in
  */status) cat "$T/status.json" 2>/dev/null; exit 0 ;;
  */apply)
    f=\$(printf '%s' "\$body" | sed -E 's/.*"filename":"([^"]*)".*/\1/')
    printf '%s\n' "\$f" >> "$T/posts.log"
    cat "$T/apply-\$f.json" 2>/dev/null || printf '{"ok":true,"status":"applied"}\n'
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"

echo 0 > "$T/checks.rc"; printf 'build\tpass\t1s\n' > "$T/checks.out"
echo '{"workflow_runs":[]}' > "$T/runs.json"

# ---------------------------------------------------------------------------
# a scratch repo that looks like an endpoint project's worktree
# ---------------------------------------------------------------------------
mkwt() { # mkwt <dir> <branch>   (leaves the branch checked out, origin = o/p)
  local d="$1" b="$2"
  git init -q -b main "$d" 2>/dev/null
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo readme > "$d/README.md"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm init
  git -C "$d" remote add origin https://github.com/o/p.git
  git -C "$d" checkout -q -b "$b"
  mkdir -p "$d/scripts/migrations"
}
commit_wt() { git -C "$1" add -A >/dev/null; git -C "$1" commit -qm sql; }

WT="$T/wt"; mkwt "$WT" ticket/bh-9
cat > "$WT/scripts/migrations/2026-09-15-a.sql" <<'SQL'
CREATE TABLE "Alpha" ("id" TEXT NOT NULL);
ALTER TABLE "Alpha" ENABLE ROW LEVEL SECURITY;
SQL
cat > "$WT/scripts/migrations/2026-09-15-b.sql" <<'SQL'
CREATE TABLE "Beta" ("id" TEXT NOT NULL);
ALTER TABLE "Beta" ENABLE ROW LEVEL SECURITY;
SQL
commit_wt "$WT"

# a worktree whose SQL the appliability gate must FLAG
WTD="$T/wt-drop"; mkwt "$WTD" ticket/bh-9
cat > "$WTD/scripts/migrations/2026-09-15-a.sql" <<'SQL'
CREATE TABLE "Gamma" ("id" TEXT NOT NULL);
DROP TABLE "Old";
SQL
commit_wt "$WTD"

# data-edit worktrees, for the revert-line contract
WTR="$T/wt-revert"; mkwt "$WTR" ticket/bh-9
cat > "$WTR/scripts/migrations/2026-09-15-a.sql" <<'SQL'
-- revert: UPDATE t SET x=1 WHERE id=7;
UPDATE t SET x=2 WHERE id=7;
SQL
commit_wt "$WTR"

WTN="$T/wt-norevert"; mkwt "$WTN" ticket/bh-9
cat > "$WTN/scripts/migrations/2026-09-15-a.sql" <<'SQL'
UPDATE t SET x=2 WHERE id=7;
SQL
commit_wt "$WTN"

# the negative for the data-edit detector: column names that merely CONTAIN
# "update"/"insert", and a comment that mentions INSERT.
WTC="$T/wt-columns"; mkwt "$WTC" ticket/bh-9
cat > "$WTC/scripts/migrations/2026-09-15-a.sql" <<'SQL'
-- INSERT later, once the backfill lands
CREATE TABLE "t" ("updated_at" TIMESTAMPTZ, "inserted_by" TEXT);
ALTER TABLE "t" ENABLE ROW LEVEL SECURITY;
SQL
commit_wt "$WTC"

# a worktree with no migration files at all
WTE="$T/wt-empty"; mkwt "$WTE" ticket/bh-9
echo hi > "$WTE/README2.md"; commit_wt "$WTE"

B="$T/h/builds/project-1-BH-9-202609150001"; mkdir -p "$B"
BX="$T/h/builds/x-os-BH-9-202609150001"; mkdir -p "$BX"

reset() {
  : > "$T/posts.log"; : > "$T/gh.log"
  rm -f "$T/comment.md" "$T/comment.fail" "$T/apply-"*.json
  rm -f "$B/hotfix-migrate.json" "$BX/hotfix-migrate.json"
  rm -rf "$T/h/locks"; mkdir -p "$T/h/locks"
  # the driver's terminal-refusal memory is per (file, checksum) and survives a
  # run on purpose — each case starts from a clean one so cases cannot leak.
  : > "$T/h/state/migrations-refused-project-1.txt"
  echo 0 > "$T/checks.rc"; printf 'build\tpass\t1s\n' > "$T/checks.out"
  rm -f "$T/checks.hang"
}

run_hm() { # run_hm <project> <build> <worktree> [VAR=VAL ...] -> prints rc
  local p="$1" b="$2" w="$3"; shift 3
  ( cd "$T" && PATH="$T/fakebin:$PATH" env HARNESS="$T/h" WT="$w" BASE=main SLUG=o/p \
      BRANCH=ticket/bh-9 PR_URL=https://github.com/o/p/pull/9 HOTFIX_CI_WAIT=2 \
      "$@" bash "$T/h/bin/hotfix-migrate.sh" "$p" "$b" > "$T/hm.out" 2> "$T/hm.err" )
  echo $?
}
marker() { head -n1 "$T/comment.md" 2>/dev/null; }
nposts() { local n; n=$(grep -c . "$T/posts.log" 2>/dev/null); echo "${n:-0}"; }

cat > "$T/status.json" <<'JSON'
{"applied":[{"filename":"old.sql"}],
 "pending":[{"filename":"2026-09-15-a.sql","checksum":"c1"},
            {"filename":"2026-09-15-b.sql","checksum":"c2"},
            {"filename":"2026-09-15-c.sql","checksum":"c3"}]}
JSON

# ===========================================================================
# 1. the happy endpoint path: both files applied, in file order, c never touched
# ===========================================================================
reset
RC=$(run_hm project-1 "$B" "$WT")
[ "$RC" = 0 ] || bad "1: applied path must exit 0 (got $RC; $(head -c 200 "$T/hm.err"))"
[ "$RC" = 0 ] && ok
printf '2026-09-15-a.sql\n2026-09-15-b.sql\n' > "$T/want-posts"
diff -q "$T/want-posts" "$T/posts.log" >/dev/null 2>&1 && ok \
  || bad "1: POST order must be exactly a then b, and never c (got: $(tr '\n' ' ' < "$T/posts.log"))"
FP=$(jq -r '.fp' "$B/hotfix-migrate.json" 2>/dev/null)
[ -n "$FP" ] && [ "$FP" != null ] && ok || bad "1: the ledger must carry a fingerprint"
[ "$(marker)" = "<!-- hotfix-migrate-proof fp=$FP decision=applied -->" ] && ok \
  || bad "1: comment line 1 must be the proof marker with decision=applied (got '$(marker)')"
grep -q '2026-09-15-a.sql' "$T/comment.md" && grep -q '2026-09-15-b.sql' "$T/comment.md" && ok \
  || bad "1: the proof must name both files"
# the Shared contract asks for the quiet-window decision PER FILE, so BH-370.2
# reads one shape whichever slice posted the proof.
[ "$(grep -c ': quiet window: not needed (endpoint shape)' "$T/comment.md")" = 2 ] && ok \
  || bad "1: the proof must carry one quiet-window line per file (got $(grep -c 'quiet window' "$T/comment.md"))"
grep -q '"status":"applied"' "$T/comment.md" && ok \
  || bad "1: the proof must carry the endpoint's own status JSON"
[ "$(jq -r '.decision' "$B/hotfix-migrate.json")" = applied ] && ok || bad "1: ledger decision must be applied"
[ "$(jq -r '.posted_comment_id' "$B/hotfix-migrate.json")" = 4242 ] && ok \
  || bad "1: the ledger must be rewritten with the posted comment id"
[ "$(jq -r '.after_deploy' "$B/hotfix-migrate.json")" = null ] && ok || bad "1: after_deploy must be null in this slice"
[ "$(jq -r '.files|length' "$B/hotfix-migrate.json")" = 2 ] && ok || bad "1: the ledger must record both files"
[ "$(jq -r '.mode' "$B/hotfix-migrate.json")" = endpoint ] && ok || bad "1: mode must be endpoint for project-1"
# the token probe must happen before anything is posted
grep -n 'api repos/o/p ' "$T/gh.log" >/dev/null 2>&1 && ok || bad "1: the run must probe the repo token via gh_repo_use_token"

# ===========================================================================
# 2. nothing pending yet (the merge is not deployed): defer, do not apply
# ===========================================================================
reset
echo '{"applied":[],"pending":[]}' > "$T/status.json"
RC=$(run_hm project-1 "$B" "$WT")
[ "$RC" = 0 ] && ok || bad "2: deferred-to-deploy must exit 0 (got $RC)"
[ "$(nposts)" = 0 ] && ok || bad "2: nothing is pending, so nothing may be POSTed (got $(nposts))"
grep -q 'decision=deferred-to-deploy' <<<"$(marker)" && ok || bad "2: marker must say deferred-to-deploy (got '$(marker)')"
[ "$(jq -r '[.files[].status]|unique|join(",")' "$B/hotfix-migrate.json")" = not-pending ] && ok \
  || bad "2: both files must be recorded not-pending"

# ===========================================================================
# 3. the appliability gate flags the SQL: never reach an apply path
# ===========================================================================
reset
cat > "$T/status.json" <<'JSON'
{"applied":[],"pending":[{"filename":"2026-09-15-a.sql","checksum":"c1"}]}
JSON
RC=$(run_hm project-1 "$B" "$WTD")
[ "$RC" = 2 ] && ok || bad "3: a FLAGGED gate report must exit 2 (got $RC)"
[ "$(nposts)" = 0 ] && ok || bad "3: flagged SQL must never reach POST /apply (got $(nposts))"
grep -q 'decision=flagged' <<<"$(marker)" && ok || bad "3: marker must say decision=flagged (got '$(marker)')"
grep -q 'FLAGGED (destructive statement' "$T/comment.md" && ok \
  || bad "3: the proof must carry the gate's own report"
[ "$(grep -c 'quiet window' "$T/comment.md")" = 1 ] && ok \
  || bad "3: nothing was applied, so the flagged proof keeps one quiet-window line, not one per file"

# ===========================================================================
# 4. no path: neither endpoint nor workflow; then workflow with no lib; then a lib
# ===========================================================================
reset
RC=$(run_hm x-os "$BX" "$WT")
[ "$RC" = 5 ] && ok || bad "4a: an unknown project has no path — exit 5 (got $RC)"
grep -q 'decision=no-path' <<<"$(marker)" && ok || bad "4a: marker must say decision=no-path (got '$(marker)')"
grep -q 'this project has neither /api/internal/migrations nor a dispatchable migration workflow; set HOTFIX_MIGRATE_WORKFLOW or ship the endpoint' "$T/comment.md" && ok \
  || bad "4a: the no-path proof must name what is missing, in the agreed sentence"
[ "$(nposts)" = 0 ] && ok || bad "4a: no-path must POST nothing"

reset
RC=$(run_hm x-os "$BX" "$WT" HOTFIX_MIGRATE_MODE=workflow HOTFIX_MIGRATE_GLOB='scripts/migrations/*.sql')
[ "$RC" = 5 ] && ok || bad "4b: workflow mode with no lib must exit 5 (got $RC)"
grep -q 'bin/lib/hotfix-migrate-workflow.sh missing' "$T/comment.md" && ok \
  || bad "4b: the proof must name the missing lib"

reset
printf 'hm_workflow() { exit 42; }\n' > "$T/h/bin/lib/hotfix-migrate-workflow.sh"
RC=$(run_hm x-os "$BX" "$WT" HOTFIX_MIGRATE_MODE=workflow HOTFIX_MIGRATE_GLOB='scripts/migrations/*.sql')
rm -f "$T/h/bin/lib/hotfix-migrate-workflow.sh"
[ "$RC" = 42 ] && ok || bad "4c: the lib's hm_workflow owns the exit code (want 42, got $RC)"
[ -f "$T/comment.md" ] && bad "4c: this script must post nothing when the lib takes over" || ok

# ===========================================================================
# 5. bin/apply-migrations.sh --files, driven directly
# ===========================================================================
reset
cat > "$T/status.json" <<'JSON'
{"applied":[{"filename":"old.sql"}],
 "pending":[{"filename":"2026-09-15-a.sql","checksum":"c1"},
            {"filename":"2026-09-15-b.sql","checksum":"c2"}]}
JSON
bash -n "$T/h/bin/apply-migrations.sh" 2>/dev/null && ok || bad "5: apply-migrations.sh must parse (bash -n)"
am() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" bash "$T/h/bin/apply-migrations.sh" "$@" ); }
OUT=$(am project-1 --files 2026-09-15-b.sql 2026-09-15-a.sql zzz.sql); ARC=$?
printf '2026-09-15-b.sql\n2026-09-15-a.sql\n' > "$T/want-posts"
diff -q "$T/want-posts" "$T/posts.log" >/dev/null 2>&1 && ok \
  || bad "5: --files must POST in the order given, b then a (got: $(tr '\n' ' ' < "$T/posts.log"))"
[ "$(jq -r 'select(.filename=="2026-09-15-b.sql")|.status' <<<"$OUT")" = applied ] && ok || bad "5: b must report applied"
[ "$(jq -r 'select(.filename=="zzz.sql")|.status' <<<"$OUT")" = not-pending ] && ok || bad "5: zzz.sql must report not-pending"
[ "$ARC" != 0 ] && ok || bad "5: a not-pending file means the run did NOT do what was asked — nonzero rc"
: > "$T/posts.log"
OUT=$(am project-1 --files old.sql); ARC=$?
[ "$(jq -r '.status' <<<"$OUT")" = already-applied ] && ok || bad "5: an applied file must report already-applied (got '$OUT')"
[ "$ARC" = 0 ] && ok || bad "5: already-applied is success — rc 0 (got $ARC)"
[ "$(nposts)" = 0 ] && ok || bad "5: an already-applied file must not be re-POSTed"
# the cron path is unchanged: same log line, same silence
: > "$T/posts.log"; : > "$T/h/logs/migrations.log"
am project-1 >/dev/null 2>&1; CRC=$?
[ "$CRC" = 0 ] && ok || bad "5: the no-arg cron path still exits 0 (got $CRC)"
grep -q 'apply 2026-09-15-a.sql: status=applied ok=true' "$T/h/logs/migrations.log" && ok \
  || bad "5: the cron log line must be unchanged (got: $(tail -1 "$T/h/logs/migrations.log"))"
[ "$(nposts)" = 2 ] && ok || bad "5: the cron path still POSTs every pending file (got $(nposts))"
# a refused file is NOT success, whatever the endpoint says beside the word
: > "$T/posts.log"
echo '{"ok":true,"status":"refused","reason":"classifier"}' > "$T/apply-2026-09-15-a.sql.json"
OUT=$(am project-1 --files 2026-09-15-a.sql); ARC=$?
[ "$(jq -r '.status' <<<"$OUT")" = refused ] && ok || bad "5: a refused apply must report the word refused (got '$OUT')"
[ "$ARC" != 0 ] && ok || bad "5: --files must exit nonzero when a file came back refused (got $ARC)"
rm -f "$T/apply-2026-09-15-a.sql.json"; : > "$T/h/state/migrations-refused-project-1.txt"
# a project with no endpoint: loud under --files, silent under cron
OUT=$(am x-os --files whatever.sql); XRC=$?
[ "$(jq -r '.status' <<<"$OUT")" = no-endpoint ] && ok || bad "5: unknown project --files must say no-endpoint (got '$OUT')"
[ "$XRC" = 5 ] && ok || bad "5: unknown project --files must exit 5 (got $XRC)"
OUT=$(am x-os); XRC=$?
[ "$XRC" = 0 ] && [ -z "$OUT" ] && ok \
  || bad "5: the cron path on a non-endpoint project must stay a silent exit 0 (rc $XRC, out '$OUT')"
# the cron tick owns the lock -> --files yields at once, it never queues
: > "$T/posts.log"
( flock -n 8 || exit 1; exec sleep 3 ) 8>"$T/h/locks/apply-migrations-project-1.lock" &
LPID=$!; wait_holder "$LPID"
am project-1 --files 2026-09-15-a.sql >/dev/null 2>&1; LRC=$?
wait $LPID 2>/dev/null
[ "$LRC" = 75 ] && ok || bad "5: --files must exit 75 when the cron tick owns the lock (got $LRC)"
[ "$(nposts)" = 0 ] && ok || bad "5: a busy lock means zero POSTs"

# ===========================================================================
# 6. bin/run-build.sh's hotfix stage block, extracted by its markers and driven
# ===========================================================================
awk '/^# >>> hotfix migrate stage/{f=1;next} /^# <<< hotfix migrate stage/{exit} f' \
  "$RB_ALL" > "$T/hstage.sh"
[ -s "$T/hstage.sh" ] && ok || bad "6: could not extract the hotfix migrate stage — markers missing?"
# it must sit OUTSIDE the tier-1 markers the conductor test extracts
awk '/^# >>> tier-1 merge gate/{f=1;next} /^# <<< tier-1 merge gate/{exit} f' \
  "$RB_ALL" > "$T/t1.sh"
grep -q 'hotfix migrate stage' "$T/t1.sh" && bad "6: the hotfix block must not live inside the tier-1 merge gate markers" || ok
mkdir -p "$T/h2/bin" "$T/h2/bin/lib" "$T/h2/env" "$T/h2/flags" "$T/h2/builds/b"
SB="$T/h2/builds/b"
# STAGE_LIB=1 puts the REAL bin/lib/hotfix-lib.sh where the block looks for it
# (the shape a live run-build always has, since it sources the lib at detect
# time); 0 leaves it absent so the block's jq fallback is the code under test.
STAGE_LIB=0
run_stage() { # run_stage <stub-rc> <ledger-json|-> <meta-json|-> [VAR=VAL...]
  local rc="$1" led="$2" meta="$3"; shift 3
  : > "$T/stage-calls.txt"; rm -f "$SB/hotfix-migrate.json" "$SB/ticket-meta.json"
  [ "$led" = - ] || printf '%s\n' "$led" > "$SB/hotfix-migrate.json"
  [ "$meta" = - ] || printf '%s\n' "$meta" > "$SB/ticket-meta.json"
  if [ "$STAGE_LIB" = 1 ]; then cp "$DIR/bin/lib/hotfix-lib.sh" "$T/h2/bin/lib/hotfix-lib.sh"
  else rm -f "$T/h2/bin/lib/hotfix-lib.sh"; fi
  printf '#!/bin/bash\nprintf "called\\n" >> %s/stage-calls.txt\nexit %s\n' "$T" "$rc" > "$T/h2/bin/hotfix-migrate.sh"
  chmod +x "$T/h2/bin/hotfix-migrate.sh"
  ( cd "$T" && PATH="$T/fakebin:$PATH" env HARNESS="$T/h2" BUILD="$SB" PROJECT=p KEY=BH-9 \
      TIER=1 PR_URL=https://github.com/o/p/pull/9 QA_NOTE="" WT="$T/wt" BRANCH=ticket/bh-9 \
      BASE=main SLUG=o/p "$@" \
      bash -c 'set -uo pipefail
        STAMP() { echo TS; }
        . "$0"
        printf "TIER=%s\nNOTE=%s\nHOTFIX=%s\n" "$TIER" "$QA_NOTE" "${HOTFIX:-}"' "$T/hstage.sh" 2>/dev/null )
}
LBL='{"title":"t","labels":[{"name":"ai-build"},{"name":"hotfix"}]}'
OUT=$(run_stage 3 - "$LBL")
grep -q '^TIER=2$' <<<"$OUT" && ok || bad "6: a hold (rc 3) must force tier 2 (got: $(tr '\n' ' ' <<<"$OUT"))"
grep -q 'HOTFIX-MIGRATE: hold' <<<"$OUT" && ok || bad "6: the note must name the word hold (got: $(tr '\n' ' ' <<<"$OUT"))"
OUT=$(run_stage 0 '{"decision":"deferred-to-deploy"}' "$LBL")
grep -q '^TIER=1$' <<<"$OUT" && ok || bad "6: rc 0 must leave the tier alone (got: $(tr '\n' ' ' <<<"$OUT"))"
grep -q 'HOTFIX-MIGRATE: deferred-to-deploy' <<<"$OUT" && ok \
  || bad "6: rc 0 must name the ledger's decision (got: $(tr '\n' ' ' <<<"$OUT"))"
OUT=$(run_stage 4 - "$LBL")
grep -q '^TIER=1$' <<<"$OUT" && ok || bad "6: rc 4 (no migration files) must change nothing"
grep -q '^NOTE=$' <<<"$OUT" && ok || bad "6: rc 4 must add no note (got: $(tr '\n' ' ' <<<"$OUT"))"
OUT=$(run_stage 5 - "$LBL"); grep -q 'HOTFIX-MIGRATE: no-path' <<<"$OUT" && ok || bad "6: rc 5 must say no-path"
OUT=$(run_stage 75 - "$LBL"); grep -q 'HOTFIX-MIGRATE: busy' <<<"$OUT" && ok || bad "6: rc 75 must say busy"
OUT=$(run_stage 2 - "$LBL"); grep -q 'HOTFIX-MIGRATE: flagged' <<<"$OUT" && ok || bad "6: rc 2 must say flagged"
# the label match is exact: a near-miss label and a title that says hotfix do not fire
OUT=$(run_stage 3 - '{"title":"hotfix for the thing","labels":[{"name":"ai-build"},{"name":"hotfix-candidate"}]}')
[ -s "$T/stage-calls.txt" ] && bad "6: only an exact 'hotfix' label may run the stage" || ok
grep -q '^TIER=1$' <<<"$OUT" && ok || bad "6: an unlabelled ticket must not be demoted"
OUT=$(run_stage 3 - - HOTFIX_ISSUE=1)
[ -s "$T/stage-calls.txt" ] && ok || bad "6: HOTFIX_ISSUE=1 must run the stage even with no ticket-meta.json"
# no PR means nothing to prove, and nothing may run
OUT=$(run_stage 3 - "$LBL" PR_URL=)
[ -s "$T/stage-calls.txt" ] && bad "6: with no PR URL the stage must not run" || ok

# --- the block READS main's settled HOTFIX global, it never writes it --------
# (#368 computes HOTFIX at detect time and again at pr-open; the tier-1 merged
# announcement below this block reads it. A block that re-derives it either
# steps over the lane kill flag or loses the announcement on a resumed build.)
NEAR='{"title":"t","labels":[{"name":"ai-build"},{"name":"hotfix-candidate"}]}'
# (a) the env answer alone is enough — a resumed build has no ticket-meta.json
OUT=$(run_stage 3 - - HOTFIX=1)
[ -s "$T/stage-calls.txt" ] && ok || bad "6: HOTFIX=1 from the build's own detect must run the stage with no ticket-meta.json"
grep -q '^TIER=2$' <<<"$OUT" && ok || bad "6: the stage's hold must still force tier 2 on the HOTFIX=1 path"
# (b) the settled 1 survives the block untouched, even when the meta disagrees
OUT=$(run_stage 0 '{"decision":"applied"}' "$NEAR" HOTFIX=1)
[ -s "$T/stage-calls.txt" ] && ok || bad "6: HOTFIX=1 must beat a near-miss label, not be overruled by it"
grep -q '^HOTFIX=1$' <<<"$OUT" && ok || bad "6: the block must leave HOTFIX=1 as it found it (got: $(tr '\n' ' ' <<<"$OUT"))"
# (c) the lane-off answer ("" from detect) survives too: the label may run the
#     stage, but the merged-announce guard must read exactly what detect left
OUT=$(run_stage 0 '{"decision":"applied"}' "$LBL" HOTFIX=)
[ -s "$T/stage-calls.txt" ] && ok || bad "6: an exact label must still run the stage when HOTFIX is empty"
grep -q '^HOTFIX=$' <<<"$OUT" && ok \
  || bad "6: the block must not write HOTFIX — an empty one stays empty (got: $(tr '\n' ' ' <<<"$OUT"))"
# (d) the kill flag beats the label AND the hand-run override
STAGE_LIB=1
: > "$T/h2/flags/hotfix-lane-off"
OUT=$(run_stage 3 - "$LBL" HOTFIX_ISSUE=1)
[ -s "$T/stage-calls.txt" ] && bad "6: flags/hotfix-lane-off must stop the stage even with the label and HOTFIX_ISSUE=1" || ok
grep -q '^TIER=1$' <<<"$OUT" && ok || bad "6: a lane-off build must not be demoted by this stage"
grep -q '^NOTE=$' <<<"$OUT" && ok || bad "6: a lane-off build gets no hotfix note (got: $(tr '\n' ' ' <<<"$OUT"))"
rm -f "$T/h2/flags/hotfix-lane-off"
# (e) the lib owns the label NAME, so HOTFIX_LABEL applies here too
echo 'HOTFIX_LABEL=urgent' > "$T/h2/env/global.env"
OUT=$(run_stage 3 - '{"title":"t","labels":[{"name":"ai-build"},{"name":"urgent"}]}')
[ -s "$T/stage-calls.txt" ] && ok || bad "6: HOTFIX_LABEL=urgent must make an 'urgent' label run the stage"
OUT=$(run_stage 3 - "$LBL")
[ -s "$T/stage-calls.txt" ] && bad "6: with HOTFIX_LABEL=urgent a 'hotfix' label is not the hotfix label" || ok
rm -f "$T/h2/env/global.env"
STAGE_LIB=0

# the stage never touches the PR itself
grep -q 'pr close\|pr merge\|pr edit' "$T/gh.log" && bad "6: the hotfix stage must never act on the PR" || ok

# ===========================================================================
# 7. revert lines for data-edit files
# ===========================================================================
reset
cat > "$T/status.json" <<'JSON'
{"applied":[],"pending":[{"filename":"2026-09-15-a.sql","checksum":"c1"}]}
JSON
RC=$(run_hm project-1 "$B" "$WTR")
grep -q 'UPDATE t SET x=1 WHERE id=7;' "$T/comment.md" && ok \
  || bad "7: a data-edit file's own -- revert: line must ride in the proof verbatim"
reset
RC=$(run_hm project-1 "$B" "$WTN")
grep -q 'REVERT: none declared in file - write one before applying by hand' "$T/comment.md" && ok \
  || bad "7: a data-edit file with no declared revert must say so, in the agreed sentence"
reset
RC=$(run_hm project-1 "$B" "$WTC")
grep -qi 'revert' "$T/comment.md" && bad "7: 'updated_at'/'inserted_by' columns and a '-- INSERT' comment are not data edits" || ok

# ===========================================================================
# 8. idempotence: a ledger that already says applied for this fingerprint
# ===========================================================================
reset
cat > "$T/status.json" <<'JSON'
{"applied":[],"pending":[{"filename":"2026-09-15-a.sql","checksum":"c1"},
                         {"filename":"2026-09-15-b.sql","checksum":"c2"}]}
JSON
RC=$(run_hm project-1 "$B" "$WT")   # fills the ledger with the real FP
FP=$(jq -r '.fp' "$B/hotfix-migrate.json")
reset
jq -n --arg fp "$FP" '{fp:$fp,mode:"endpoint",decision:"applied",files:[],posted_comment_id:1,after_deploy:null}' \
  > "$B/hotfix-migrate.json"
RC=$(run_hm project-1 "$B" "$WT")
[ "$RC" = 0 ] && ok || bad "8: a re-run of an already-applied fingerprint must exit 0 (got $RC)"
[ "$(nposts)" = 0 ] && ok || bad "8: a re-run must POST nothing (got $(nposts))"
grep -q 'issues/9/comments' "$T/gh.log" && bad "8: a re-run must not post a second proof" || ok
grep -q "$FP" "$T/hm.out" && ok || bad "8: a re-run must print the ledger it is standing on"

# ===========================================================================
# 9. the per-fingerprint lock is dedupe, never a queue
# ===========================================================================
reset
cat > "$T/status.json" <<'JSON'
{"applied":[],"pending":[{"filename":"2026-09-15-a.sql","checksum":"c1"},
                         {"filename":"2026-09-15-b.sql","checksum":"c2"}]}
JSON
RC=$(run_hm project-1 "$B" "$WT"); FP=$(jq -r '.fp' "$B/hotfix-migrate.json")
reset
( flock -n 9 || exit 1; exec sleep 3 ) 9>"$T/h/locks/hotfix-migrate-project-1-$FP.lock" &
LPID=$!; wait_holder "$LPID"
RC=$(run_hm project-1 "$B" "$WT")
wait $LPID 2>/dev/null
[ "$RC" = 75 ] && ok || bad "9: a held fingerprint lock must exit 75 at once (got $RC)"
[ "$(nposts)" = 0 ] && ok || bad "9: a busy run must POST nothing"
[ -f "$T/comment.md" ] && bad "9: a busy run must post no proof" || ok

# zero migration files: nothing to prove, nothing to say
reset
RC=$(run_hm project-1 "$B" "$WTE")
[ "$RC" = 4 ] && ok || bad "9: a PR with no migration files must exit 4 (got $RC)"
[ -f "$T/comment.md" ] && bad "9: exit 4 must post nothing" || ok
[ -f "$B/hotfix-migrate.json" ] && bad "9: exit 4 must write no ledger" || ok

# ===========================================================================
# 10. checks that are not green: hold, and never touch the database
# ===========================================================================
reset
cat > "$T/status.json" <<'JSON'
{"applied":[],"pending":[{"filename":"2026-09-15-a.sql","checksum":"c1"},
                         {"filename":"2026-09-15-b.sql","checksum":"c2"}]}
JSON
echo 1 > "$T/checks.rc"; : > "$T/checks.out"
echo '{"workflow_runs":[{"status":"completed","conclusion":"failure"}]}' > "$T/runs.json"
RC=$(run_hm project-1 "$B" "$WT")
[ "$RC" = 3 ] && ok || bad "10: red checks must hold, exit 3 (got $RC)"
[ "$(nposts)" = 0 ] && ok || bad "10: red checks must POST nothing (got $(nposts))"
grep -q 'decision=hold' <<<"$(marker)" && ok || bad "10: marker must say decision=hold (got '$(marker)')"
grep -q 'checks not green' "$T/comment.md" && ok || bad "10: the proof must say the checks were not green"
# a checks read NOBODY could make is a hold too — never a green by default
reset
echo 1 > "$T/checks.rc"; : > "$T/checks.out"
echo '{"workflow_runs":[]}' > "$T/runs.json"
RC=$(run_hm project-1 "$B" "$WT" HOTFIX_CI_WAIT=1)
[ "$RC" = 3 ] && ok || bad "10: an unreadable checks answer must hold, never pass (got $RC)"
[ "$(nposts)" = 0 ] && ok || bad "10: an unreadable checks answer must POST nothing"
# the fallback DOES accept a genuinely green Actions answer
reset
echo 1 > "$T/checks.rc"; : > "$T/checks.out"
echo '{"workflow_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"skipped"}]}' > "$T/runs.json"
RC=$(run_hm project-1 "$B" "$WT")
[ "$RC" = 0 ] && ok || bad "10: green Actions runs must let the apply proceed (got $RC)"
[ "$(nposts)" = 2 ] && ok || bad "10: a green fallback read must apply both files (got $(nposts))"
# the answer this fleet actually gets today: no branch protection, so
# `--required` reports nothing at all, rc 1. That is "nobody could read it", it
# must reach the Actions fallback, and a green one must still be allowed to
# apply. If this case ever starts holding, every hotfix on the fleet is stuck.
reset
echo 1 > "$T/checks.rc"
printf "no required checks reported on the 'ticket/bh-9' branch\n" > "$T/checks.out"
echo '{"workflow_runs":[{"status":"completed","conclusion":"success"}]}' > "$T/runs.json"
RC=$(run_hm project-1 "$B" "$WT")
[ "$RC" = 0 ] && ok || bad "10: 'no required checks reported' must fall back, not hold (got $RC)"
[ "$(nposts)" = 2 ] && ok || bad "10: the fallback's green read must apply both files (got $(nposts))"

# a RED primary read is an ANSWER, and the weaker fallback may never overrule
# it. The required checks on a real PR here include rows that are NOT workflow
# runs (Vercel, Mergify, CodeRabbit), so "every Actions run on the sha is green"
# says nothing about the one that failed.
reset
echo 1 > "$T/checks.rc"; printf 'build\tpass\t1s\nVercel\tfail\t3s\n' > "$T/checks.out"
echo '{"workflow_runs":[{"status":"completed","conclusion":"success"}]}' > "$T/runs.json"
RC=$(run_hm project-1 "$B" "$WT")
[ "$RC" = 3 ] && ok || bad "10: a fail row must hold even when every Actions run is green (got $RC)"
[ "$(nposts)" = 0 ] && ok || bad "10: a fail row must POST nothing (got $(nposts))"
grep -q 'failing required check' "$T/comment.md" && ok \
  || bad "10: the proof must say the primary read reported a failing required check"
# the read that never settles is the ticket's "timeout -> hold", and it holds
# even when the workflow runs on the sha are all green.
reset
touch "$T/checks.hang"; echo 0 > "$T/checks.rc"; : > "$T/checks.out"
echo '{"workflow_runs":[{"status":"completed","conclusion":"success"}]}' > "$T/runs.json"
RC=$(run_hm project-1 "$B" "$WT" HOTFIX_CI_WAIT=1)
[ "$RC" = 3 ] && ok || bad "10: a checks read that hit the deadline must hold (got $RC)"
[ "$(nposts)" = 0 ] && ok || bad "10: a timed-out checks read must POST nothing (got $(nposts))"
echo 0 > "$T/checks.rc"; printf 'build\tpass\t1s\n' > "$T/checks.out"

# ===========================================================================
# 11. the proof failed to post: the ledger must NOT claim delivery
# ===========================================================================
reset
touch "$T/comment.fail"
RC=$(run_hm project-1 "$B" "$WT")
[ "$RC" = 3 ] && ok || bad "11: an applied migration whose proof never posted is a hold (got $RC)"
[ "$(nposts)" = 2 ] && ok || bad "11: the apply really happened — the ledger must record it (got $(nposts))"
[ "$(jq -r '.posted_comment_id' "$B/hotfix-migrate.json")" = null ] && ok \
  || bad "11: a failed post must leave posted_comment_id null"
[ "$(jq -r '.decision' "$B/hotfix-migrate.json")" = applied ] && ok \
  || bad "11: the ledger still records what really happened to the database"
# and the next run re-posts the proof without re-applying anything
rm -f "$T/comment.fail"; : > "$T/posts.log"; : > "$T/gh.log"; rm -rf "$T/h/locks"; mkdir -p "$T/h/locks"
RC=$(run_hm project-1 "$B" "$WT")
[ "$(nposts)" = 0 ] && ok || bad "12: the re-post must not re-apply anything (got $(nposts))"
[ "$(jq -r '.posted_comment_id' "$B/hotfix-migrate.json")" = 4242 ] && ok \
  || bad "12: the re-post must land the comment id in the ledger"
[ "$(grep -c ': quiet window: not needed (endpoint shape)' "$T/comment.md")" = 2 ] && ok \
  || bad "12: the re-posted proof must carry the same per-file quiet-window shape as the first one"

# ===========================================================================
# 12. the status WORD decides, never ok:true; and hold beats defer
# ===========================================================================
reset
echo '{"ok":true,"status":"refused","reason":"classifier"}' > "$T/apply-2026-09-15-a.sql.json"
RC=$(run_hm project-1 "$B" "$WT")
[ "$RC" = 3 ] && ok || bad "12: a refused apply is a hold even when ok is true (got $RC)"
grep -q 'decision=hold' <<<"$(marker)" && ok || bad "12: refused must mark the proof decision=hold"
reset
cat > "$T/status.json" <<'JSON'
{"applied":[],"pending":[{"filename":"2026-09-15-a.sql","checksum":"c1"}]}
JSON
echo '{"ok":false,"status":"refused"}' > "$T/apply-2026-09-15-a.sql.json"
RC=$(run_hm project-1 "$B" "$WT")
[ "$RC" = 3 ] && ok || bad "12: one refused file beside one not-pending file is a hold, never a defer (got $RC)"
grep -q 'decision=hold' <<<"$(marker)" && ok || bad "12: hold wins over deferred-to-deploy"
reset
cat > "$T/status.json" <<'JSON'
{"applied":[],"pending":[{"filename":"2026-09-15-a.sql","checksum":"c1"},
                         {"filename":"2026-09-15-b.sql","checksum":"c2"}]}
JSON
echo '{"ok":true,"status":"in-progress"}' > "$T/apply-2026-09-15-a.sql.json"
RC=$(run_hm project-1 "$B" "$WT")
[ "$RC" = 3 ] && ok || bad "12: in-progress is not a success word — hold (got $RC)"
reset
# a 200 carrying a maintenance page or a WAF interstitial passes `curl -sf`. It
# is a failed read, not an empty pending list: reading it as "nothing of yours
# is pending" would record deferred-to-deploy and exit 0.
printf '<html><body>Service temporarily unavailable</body></html>\n' > "$T/status.json"
RC=$(run_hm project-1 "$B" "$WT")
[ "$RC" = 3 ] && ok || bad "12: an unparseable /status body must hold, never defer (got $RC)"
[ "$(nposts)" = 0 ] && ok || bad "12: an unparseable /status body must POST nothing (got $(nposts))"
grep -q 'decision=hold' <<<"$(marker)" && ok \
  || bad "12: an unparseable /status body must not become deferred-to-deploy (got '$(marker)')"
grep -q 'request failed' "$T/comment.md" && ok \
  || bad "12: the proof must say the request failed for each file"

# ===========================================================================
# 13. the seams the sibling slices depend on
# ===========================================================================
SRC="$DIR/bin/hotfix-migrate.sh"
[ -s "$SRC" ] && ok || bad "13: bin/hotfix-migrate.sh must exist"
for fn in hm_wait_checks hm_post_proof hm_write_ledger hm_revert_lines; do
  ( HM_SOURCE_ONLY=1 HARNESS="$T/h" bash -c '. "$0"; declare -F '"$fn"' >/dev/null' "$SRC" ) 2>/dev/null \
    && ok || bad "13: sourcing with HM_SOURCE_ONLY=1 must define $fn for the workflow lib"
done
# the positive control for the two source pins below: if this grep stops matching,
# the pins are checking a file that no longer says anything, and would pass empty.
[ "$(grep -c 'hm_post_proof' "$SRC")" -gt 0 ] && ok || bad "13: source pins are vacuous — hm_post_proof is not in the file"
[ "$(grep -c -- '--after-deploy' "$SRC")" = 0 ] && ok || bad "13: --after-deploy belongs to BH-370.4, not here"
# BH-370.3 has shipped, so this pin is now positive: the workflow lib exists and
# sourcing the stage with it in place defines hm_workflow. The scratch tree above
# deliberately does NOT carry the lib (4b/4c test the not-installed shape), so it
# is copied in for this one check and removed again.
if [ -f "$DIR/bin/lib/hotfix-migrate-workflow.sh" ]; then
  ok
  cp "$DIR/bin/lib/hotfix-migrate-workflow.sh" "$T/h/bin/lib/"
  ( HM_SOURCE_ONLY=1 HARNESS="$T/h" bash -c '. "$0"; declare -F hm_workflow >/dev/null' "$SRC" ) 2>/dev/null \
    && ok || bad "13: with the workflow lib installed, sourcing the stage must define hm_workflow"
  rm -f "$T/h/bin/lib/hotfix-migrate-workflow.sh"
else
  bad "13: bin/lib/hotfix-migrate-workflow.sh (BH-370.3's file) must exist"
fi
# The appliability gate this stage calls still behaves the same on .sql. This
# used to be a `git diff --quiet main` pin on bin/check-migration-appliable.sh
# ("stays exactly as it is in this slice"); BH-4924 is the slice that changes it,
# for .ts only, and tests/migrate-ts-lint.bh-4924-test.sh P1 pins the .sql path
# byte for byte against the base. Here: the copy this suite installed, alone in
# $T/h/bin, still flags a DROP and passes an ADD COLUMN, silently.
mkdir -p "$T/gate13"
printf 'DROP TABLE "Old";\n' > "$T/gate13/drop.sql"
printf 'ALTER TABLE "C" ADD COLUMN "a" TEXT;\n' > "$T/gate13/add.sql"
OUT13=$("$T/h/bin/check-migration-appliable.sh" p "$T/gate13" "$T/gate13/drop.sql" 2>&1); RC13=$?
[ "$RC13" = 1 ] && [[ "$OUT13" == *"drop.sql: FLAGGED (destructive statement"* ]] \
  && ok || bad "13: the appliability gate still flags a .sql DROP (rc $RC13): $OUT13"
OUT13=$("$T/h/bin/check-migration-appliable.sh" p "$T/gate13" "$T/gate13/add.sql" 2>&1); RC13=$?
[ "$RC13" = 0 ] && [ -z "$OUT13" ] \
  && ok || bad "13: the appliability gate still passes a .sql ADD COLUMN with no output (rc $RC13): $OUT13"

echo "hotfix-migrate-endpoint-test: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
