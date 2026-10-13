#!/bin/bash
# tests/overlap-guard-stack-parent-test.sh — bin/overlap-guard.sh's open-PR
# judge (2026-09-28): a stacked child is never DEFERred against its OWN parent's
# PR, and a bare planned DIRECTORY entry is not a claim on every file an open PR
# changed under it.
#
# 1. A stacked child (STACK_BASE=<parent branch>, carried by the queue job file
#    or the environment) builds ON TOP of its parent's branch. Its planned files
#    overlap the parent's PR by construction — that overlap is the reason it is
#    stacked — so judging it against that PR deferred it every tick until the
#    parent merged, which is exactly the wait stacking exists to remove.
# 2. A planned entry such as tests/fixtures/root-fallback-baseline (a directory)
#    was a path-PREFIX of every file an open PR touched under it, so any PR that
#    changed one fixture there held the ticket. Against an open PR, whose list
#    is the files it really changed, only a file-level match counts. (Running
#    siblings are two PLANS, and keep the prefix rule — overlap-guard.bh-580
#    case 9 pins that.)
# A real overlap with an unrelated PR must still DEFER in both cases.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/proj
export HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/flags" "$T/h/state/build-queue/proj" "$T/h/plans" \
         "$T/h/builds" "$T/h/env" "$T/h/locks" "$T/fakebin"
cp "$DIR/bin/overlap-guard.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/planned-files.sh" "$T/h/bin/"
cp "$DIR/bin/lib/scheduler-conf.sh" "$DIR/bin/lib/gh-pr-list.sh" "$T/h/bin/lib/"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
printf 'proj %s https://proj.example /api/board 0 local -\n' "$SLUG" > "$T/h/fleet.conf"

cat > "$T/h/bin/jobs-client.sh" <<'EOF'
_jobs_req() { echo '{"jobs":[]}'; }
EOF

cat > "$T/fakebin/gh" <<EOF
case "\$*" in
  *"repos/$SLUG/pulls?"*)
    printf 'HTTP/2.0 200\r\n\r\n'
    jq -c --arg s "$SLUG" '[.[] | {number, html_url: .url, draft: (.isDraft // false), state: "open",
      user: {login: "operator", type: "User"}, labels: [], title: "t", body: "",
      created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z", merged_at: null, closed_at: null,
      head: {ref: .headRefName, sha: "x", repo: {full_name: \$s}}, base: {ref: "main", repo: {full_name: \$s}}}]' "$T/prs.json" ;;
  *"repos/$SLUG/pulls/"*"/files"*)
    n=\$(printf '%s\n' "\$*" | sed -nE 's#.*/pulls/([0-9]+)/files.*#\1#p')
    printf 'HTTP/2.0 200\r\n\r\n'
    jq -c --argjson n "\$n" '[.[] | select(.number == \$n) | .files[]? | {filename: .path}]' "$T/prs.json" ;;
  *"pr list -R $SLUG --state open --author operator"*) cat "$T/prs.json" ;;
  *"pr list"*) echo '[]' ;;
  *) echo '' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

G="$T/h/bin/overlap-guard.sh"
setplan() { local k="$1"; shift; mkdir -p "$T/h/plans/proj-$k"; printf '%s\n' "$@" > "$T/h/plans/proj-$k/planned-files.txt"; }
# pr <num> <branch> <file>... — one non-draft open PR, as the list returns it.
pr() { local n="$1" br="$2"; shift 2
  jq -nc --arg n "$n" --arg br "$br" --args '{number: ($n|tonumber),
    url: ("https://github.com/o/r/pull/"+$n), headRefName: $br, isDraft: false,
    files: [$ARGS.positional[] | {path: .}]}' "$@"; }
prs() { jq -s '.' > "$T/prs.json"; }
job() { # job <KEY> [stack_base] — the queue job file bin/fly-dispatch.sh hands over
  if [ -n "${2:-}" ]; then
    jq -nc --arg k "$1" --arg sb "$2" '{ticket_id:"1",key:$k,attempt:0,stack_base:$sb}'
  else
    jq -nc --arg k "$1" '{ticket_id:"1",key:$k,attempt:0}'
  fi > "$T/h/state/build-queue/proj/$1.json"
}
reset() { rm -rf "$T/h/state/overlap-guard"; : > "$T/h/logs/overlap-guard.log"; rm -f "$T/h/state/build-queue/proj/"*.json; }
run() { OUT=$(env -u STACK_BASE "$G" proj "$1" 2>/dev/null); RC=$?; }

PARENT=ticket/ab-4-contract

# 1. The stacked child vs ITS OWN parent's PR, stack base from the job file.
reset
setplan AB-5 src/lib/pay.ts src/lib/pay-ui.ts
job AB-5 "$PARENT"
pr 40 "$PARENT" src/lib/pay.ts src/lib/pay-ui.ts | prs
run AB-5
[ "$RC" = 0 ] && ok || bad "1: a stacked child overlapping ONLY its own parent's PR must not be deferred (rc $RC, out: $OUT)"
grep -q '^LAUNCH AB-5' <<<"$OUT" && ok || bad "1: it must print LAUNCH (got: $OUT)"
grep -q "PR#40" "$T/h/logs/overlap-guard.log" && ok || bad "1: the log must say the parent PR was skipped, not silently ignored: $(cat "$T/h/logs/overlap-guard.log")"

# 1b. The same, with the stack base in the environment (the local launch path).
reset
setplan AB-5 src/lib/pay.ts
pr 40 "$PARENT" src/lib/pay.ts | prs
OUT=$(STACK_BASE="$PARENT" "$G" proj AB-5 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "1b: STACK_BASE in the environment must exempt the parent PR too (rc $RC, out: $OUT)"

# 2. The same child, a real overlap with an UNRELATED PR: still DEFER.
reset
setplan AB-5 src/lib/pay.ts
job AB-5 "$PARENT"
{ pr 40 "$PARENT" src/lib/pay.ts; pr 41 ticket/ab-9-other src/lib/pay.ts; } | prs
run AB-5
[ "$RC" = 1 ] && ok || bad "2: an unrelated PR on the same file must still DEFER a stacked child (rc $RC, out: $OUT)"
grep -q 'vs PR#41' <<<"$OUT" && ok || bad "2: the DEFER must name the unrelated PR, not the parent (got: $OUT)"

# 3. NOT stacked: the same PR is somebody else's work, and it still DEFERs.
reset
setplan AB-5 src/lib/pay.ts
job AB-5
pr 40 "$PARENT" src/lib/pay.ts | prs
run AB-5
[ "$RC" = 1 ] && ok || bad "3: without a stack base the PR is a real overlap and must DEFER (rc $RC, out: $OUT)"

# 4. A bare directory entry vs an open PR that changed a file under it: LAUNCH.
reset
setplan AB-6 tests/fixtures/root-fallback-baseline src/root/fallback.ts
pr 42 ticket/ab-8-unrelated tests/fixtures/root-fallback-baseline/other.json src/far/away.ts | prs
run AB-6
[ "$RC" = 0 ] && ok || bad "4: a planned DIRECTORY must not collide with every PR file under it (rc $RC, out: $OUT)"

# 5. A file-level match against an open PR still DEFERs, directory or not.
reset
setplan AB-6 tests/fixtures/root-fallback-baseline/other.json src/root/fallback.ts
pr 42 ticket/ab-8-unrelated tests/fixtures/root-fallback-baseline/other.json | prs
run AB-6
[ "$RC" = 1 ] && ok || bad "5: the same FILE in the plan and an open PR must DEFER (rc $RC, out: $OUT)"
reset
setplan AB-6 tests/fixtures/root-fallback-baseline src/root/fallback.ts
pr 43 ticket/ab-8-unrelated src/root/fallback.ts | prs
run AB-6
[ "$RC" = 1 ] && ok || bad "5: a directory entry must not hide a real file overlap beside it (rc $RC, out: $OUT)"

# 6. The stacked-builds KILL SWITCH (flags/stacked-builds-off or
#    STACKED_BUILDS=0, read as bin/lib/rb/gates.sh reads it): with it set the
#    child builds on the project base, NOT on its parent's branch, so the parent
#    PR is a real overlap again and must DEFER.
reset
setplan AB-5 src/lib/pay.ts
job AB-5 "$PARENT"
pr 40 "$PARENT" src/lib/pay.ts | prs
touch "$T/h/flags/stacked-builds-off"
run AB-5
[ "$RC" = 1 ] && ok || bad "6: flags/stacked-builds-off means no stack — the parent PR must DEFER (rc $RC, out: $OUT)"
rm -f "$T/h/flags/stacked-builds-off"
reset
setplan AB-5 src/lib/pay.ts
job AB-5 "$PARENT"
pr 40 "$PARENT" src/lib/pay.ts | prs
OUT=$(STACKED_BUILDS=0 env -u STACK_BASE "$G" proj AB-5 2>/dev/null); RC=$?
[ "$RC" = 1 ] && ok || bad "6: STACKED_BUILDS=0 means no stack — the parent PR must DEFER (rc $RC, out: $OUT)"
OUT=$(STACKED_BUILDS=0 STACK_BASE="$PARENT" "$G" proj AB-5 2>/dev/null); RC=$?
[ "$RC" = 1 ] && ok || bad "6: STACKED_BUILDS=0 must win over an env STACK_BASE too (rc $RC, out: $OUT)"

# 7. bin/fly-dispatch.sh hands the guard the stack base FROM THE JOB IT PICKED.
#    Under rows-only the job is materialised at state/fly/.rowjob-<p>/<KEY>.json,
#    not in state/build-queue/<p>/, so the guard's own file fallback cannot see
#    it; the dispatcher must pass it. The guard is stubbed to record what it got.
mkdir -p "$T/h/state/fly"
cp "$DIR/bin/fly-dispatch.sh" "$T/h/bin/"
: > "$T/h/env/fly.env"
touch "$T/h/flags/builder-fly-proj"
printf '{"app":"builder-proj"}\n' > "$T/h/state/fly/proj.json"
for stub in fly-lock-guard.sh fly-sync-harness.sh fly-envbundle.sh beat.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$stub"; chmod +x "$T/h/bin/$stub"
done
printf '#!/bin/bash\necho started\n' > "$T/h/bin/fly-api.sh"; chmod +x "$T/h/bin/fly-api.sh"
mv "$T/h/bin/overlap-guard.sh" "$T/h/bin/overlap-guard.real"
{ printf '#!/bin/bash\n'
  printf 'printf "key=%%s stack_base=%%s\\n" "$2" "${STACK_BASE:-}" >> "%s"\n' "$T/guard-env.txt"
  printf 'echo "DEFER $2 stub"; exit 1\n'; } > "$T/h/bin/overlap-guard.sh"
chmod +x "$T/h/bin/overlap-guard.sh"
export FLY_API_TOKEN_PROJ=tok
dispatch_one() { # dispatch_one <job-json>
  : > "$T/guard-env.txt"
  rm -f "$T/h/state/build-queue/proj/"*.json "$T/h/state/fly/proj-active.json"
  printf '%s\n' "$1" > "$T/h/state/build-queue/proj/AB-5.json"
  ( cd "$T" && env -u STACK_BASE HARNESS="$T/h" bash "$T/h/bin/fly-dispatch.sh" >/dev/null 2>&1 )
}
dispatch_one "$(jq -nc --arg sb "$PARENT" '{ticket_id:"101",key:"AB-5",attempt:0,stack_base:$sb}')"
grep -qx "key=AB-5 stack_base=$PARENT" "$T/guard-env.txt" && ok \
  || bad "7: fly-dispatch must pass the picked job's stack_base to the guard as STACK_BASE (guard saw: $(cat "$T/guard-env.txt"))"
dispatch_one '{"ticket_id":"101","key":"AB-5","attempt":0}'
grep -qx "key=AB-5 stack_base=" "$T/guard-env.txt" && ok \
  || bad "7: an unstacked job must reach the guard with an empty STACK_BASE (guard saw: $(cat "$T/guard-env.txt"))"
mv -f "$T/h/bin/overlap-guard.real" "$T/h/bin/overlap-guard.sh"

echo "overlap-guard-stack-parent: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
