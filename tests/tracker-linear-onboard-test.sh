#!/bin/bash
# tests/tracker-linear-onboard-test.sh — what an admin needs to put a project
# on Linear instead of GitHub Issues: bin/load-project.sh --tracker linear
# --team <KEY>, the prompt it renders (prompts/TEMPLATE-LINEAR.md), and the
# session's CLI bin/tracker-cli.sh.
#
#   C1  tracker-cli list/read answer from Linear with the project's own key
#   C2  the team guard: another team's key is never sent, an issue Linear moved
#       to another team is refused before any read or write
#   C3  comment: stdin or a file, sent as the body; an empty body is refused;
#       TRK_DRY=1 sends nothing; the log never carries the key
#   C4  a GitHub-Issues project is rc 3 and Linear is never asked
#   L1  the loader's flags are checked before anything is written
#   L2  --tracker linear renders the Linear prompt (team, label), creates no
#       GitHub label and, without bootstrap, prints the rows team-first
#   L3  the default path is unchanged: the GitHub prompt and the ai-build label
#   L4  the box block writes an empty LINEAR_API_KEY= and the rows team, label,
#       adapter in that order, all before bootstrap-machine.sh; a failed row
#       write stops it before bootstrap
#
# No network: `curl`, `gh`, `git` and `ssh` are stubs.
#   HARNESS_TEST_SANDBOX=1 bash tests/tracker-linear-onboard-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

KEY=tok-FIXTURE-SENTINEL-4079
S="$T/ls"
mkdir -p "$T/h/bin" "$T/h/env" "$T/h/logs" "$T/stub" "$S"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
linproj  o/l  https://lin.example  -  9
ghp      o/r  https://gh.example   -  9
CONF
export HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/stub:$PATH"
export HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.example JOBS_RETRIES=0 JOBS_TIMEOUT=5
export TL_STATE="$S" TL_GATE="$DIR/tests/fixtures/tracker-linear-context" TL_FIX="$DIR/tests/fixtures/tracker-linear" TL_KEY_EXPECT="$KEY"

cat > "$T/stub/curl" <<'SH'
#!/bin/bash
S="$TL_STATE"; url=""; data=""; out=""; fmt=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X|-m|--max-time|--connect-timeout) shift ;;
    --data-binary|-d) data="${2#@}"; shift ;;
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -H) case "$2" in Authorization:*) auth="${2#Authorization: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
reply() {
  if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi
  printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"
  exit 0
}
case "$url" in
  https://jobs.example/api/settings/*)
    f="$S/setting-${url##*/}"
    [ -r "$f" ] && reply "$(head -1 "$f")" "$(sed -n '2,$p' "$f")"
    reply 404 '{"error":"no such setting"}' ;;
  https://jobs.example/*) reply 404 '{}' ;;
  https://api.linear.app/graphql) ;;
  *) echo "OFFBASE $url" >> "$S/reqs"; printf '000'; exit 7 ;;
esac
op=$(jq -r '.query // ""' "$data" 2>/dev/null | sed -nE '1s/^(query|mutation) ([A-Za-z]+).*/\2/p')
id=$(jq -r '.variables.id // ""' "$data" 2>/dev/null)
printf '%s %s\n' "$op" "$id" >> "$S/reqs"
[ "$auth" = "$TL_KEY_EXPECT" ] || reply 401 '{"errors":[{"message":"Authentication required"}]}'
case "$op" in
  TrkGate) [ -r "$TL_GATE/gate-$id.json" ] && reply 200 "$(cat "$TL_GATE/gate-$id.json")" ;;
  TrkIssue|TrkIssueMeta) [ -r "$TL_FIX/issue-$id.json" ] && reply 200 "$(cat "$TL_FIX/issue-$id.json")" ;;
  TrkIssues)
    [ "$(jq -r '.variables.after // ""' "$data")" = cursor-p1 ] && reply 200 "$(cat "$TL_FIX/issues-page2.json")"
    reply 200 "$(cat "$TL_FIX/issues-page1.json")" ;;
  TrkComment) jq -r '.variables.body' "$data" > "$S/comment-body"
    reply 200 '{"data":{"commentCreate":{"success":true,"comment":{"id":"c-new"}}}}' ;;
esac
reply 200 "$(cat "$TL_FIX/not-found.json")"
SH
printf '#!/bin/bash\nprintf "gh %%s\\n" "$*" >> "$TL_STATE/gh.log"\nexit 1\n' > "$T/stub/gh"
chmod +x "$T/stub/curl" "$T/stub/gh"

row()   { jq -n --arg k "$1" --arg v "$2" '{setting:{key:$k,value:$v}}' | { echo 200; cat; } > "$S/setting-$1"; }
fresh() { rm -f "$S/reqs" "$S/gh.log" "$S/comment-body"; }
printf 'LINEAR_API_KEY=%s\n' "$KEY" > "$T/h/env/linproj.env"
row tracker_adapter.linproj linear
row tracker_linear.linproj.team CRO
CLI="$DIR/bin/tracker-cli.sh"

# --- C1 -------------------------------------------------------------------
fresh
out=$("$CLI" linproj list); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | jq -e 'map(.key) == ["CRO-1", "CRO-2"]' >/dev/null 2>&1 && ok || bad "C1 list (rc=$rc): $out"
out=$("$CLI" linproj read CRO-1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | jq -e '.key == "CRO-1"' >/dev/null 2>&1 && ok || bad "C1 read CRO-1 (rc=$rc): $out"
[ "$(sed -n 1p "$S/reqs")" = "TrkIssues " ] && grep -q '^TrkGate CRO-1$' "$S/reqs" && grep -q '^TrkIssue CRO-1$' "$S/reqs" && ok \
  || bad "C1 the reads sent: $(cat "$S/reqs" 2>/dev/null)"

# --- C2 -------------------------------------------------------------------
fresh
"$CLI" linproj read OTH-88 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -s "$S/reqs" ] && ok || bad "C2 another team's key must never be sent (rc=$rc): $(cat "$S/reqs" 2>/dev/null)"
"$CLI" linproj comment 12 - <<<'hello' >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -s "$S/reqs" ] && ok || bad "C2 a bare number is not a ticket (rc=$rc)"
# gate-CRO-9.json is Linear answering CRO-9 with issue OTH-88: a moved issue.
printf 'body\n' > "$T/body"
"$CLI" linproj comment CRO-9 "$T/body" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ! grep -qE '^Trk(Comment|IssueMeta)' "$S/reqs" && ok || bad "C2 a moved issue gets no write (rc=$rc): $(cat "$S/reqs" 2>/dev/null)"
"$CLI" linproj read CRO-9 >/dev/null 2>&1; [ "$?" = 1 ] && ! grep -q '^TrkIssue ' "$S/reqs" && ok || bad "C2 a moved issue is not read"

# --- C3 -------------------------------------------------------------------
fresh
printf 'We have a question about the export format.\n' | "$CLI" linproj comment CRO-1 - >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'export format' "$S/comment-body" 2>/dev/null && ok || bad "C3 a comment from stdin is posted (rc=$rc)"
grep -q 'commentCreate' "$T/h/logs/tracker-cli.log" 2>/dev/null && ! grep -q "$KEY" "$T/h/logs/tracker-cli.log" && ok \
  || bad "C3 the write is logged, without the key: $(cat "$T/h/logs/tracker-cli.log" 2>/dev/null)"
fresh
: | "$CLI" linproj comment CRO-1 - >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ! grep -q '^TrkComment' "$S/reqs" && ok || bad "C3 an empty body is refused (rc=$rc)"
fresh
out=$(TRK_DRY=1 "$CLI" linproj comment CRO-1 "$T/body" 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^DRYRUN linear graphql commentCreate' && ! grep -q '^TrkComment' "$S/reqs" && ok \
  || bad "C3 a dry run sends no write (rc=$rc): $out"

# --- C4 -------------------------------------------------------------------
fresh
"$CLI" ghp list >/dev/null 2>"$T/c4.err"; rc=$?
[ "$rc" = 3 ] && [ ! -s "$S/reqs" ] && grep -q 'github-issues' "$T/c4.err" && ok || bad "C4 a GitHub project is rc 3 (rc=$rc): $(cat "$T/c4.err")"
"$CLI" linproj bogus >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "C4 an unknown verb is usage"

# --- the loader -------------------------------------------------------------
mkrepo() { # mkrepo <dir> — a scratch checkout the real loader runs inside
  local R="$1"
  mkdir -p "$R/bin/lib" "$R/prompts" "$R/fly" "$R/stub"
  cp "$DIR/bin/load-project.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$DIR/bin/render-crontab.sh" "$R/bin/"
  cp "$DIR/bin/lib/cron-lines.sh" "$DIR/bin/lib/deployment.sh" "$R/bin/lib/"
  cp "$DIR/prompts/TEMPLATE-GH.md" "$DIR/prompts/TEMPLATE-LINEAR.md" "$R/prompts/"
  printf '# project repo prod pfx off box\nalpha  example-org/alpha  -  -  1  box-small\n' > "$R/fleet.conf"
  cat > "$R/stub/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$LP/gh.log"
case "$*" in
  *"--json defaultBranchRef --jq"*) echo main ;;
  *"repo view"*) echo '{"name":"gamma","defaultBranchRef":{"name":"main"},"isArchived":false}' ;;
esac
exit 0
STUB
  cat > "$R/stub/git" <<'STUB'
#!/bin/bash
case "$1" in diff) case "$*" in *--quiet*) exit 1 ;; esac ;; rev-parse) echo deadbeef ;; esac
exit 0
STUB
  cat > "$R/stub/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$LP/ssh.args"; cat > "$LP/ssh.script"; exit 0
STUB
  chmod +x "$R/stub/gh" "$R/stub/git" "$R/stub/ssh"
}
load() { local R="$1"; shift; OUT=$(cd "$R" && LP="$R" PATH="$R/stub:$PATH" bash "$R/bin/load-project.sh" "$@" 2>&1); RC=$?; }

# --- L1 -------------------------------------------------------------------
R="$T/l1"; mkrepo "$R"; cp "$R/fleet.conf" "$T/l1.conf"
for args in "--tracker linear" "--tracker linear --team cro" "--tracker linear --team CRO --vmap-ticket" \
            "--tracker linear --team CRO --prefix XX" "--team CRO" "--tracker jira --team CRO"; do
  # shellcheck disable=SC2086
  load "$R" example-org/gamma $args --no-bootstrap
  [ "$RC" = 2 ] && [ ! -e "$R/gh.log" ] && [ ! -e "$R/prompts/gamma.md" ] && cmp -s "$R/fleet.conf" "$T/l1.conf" && ok \
    || bad "L1 '$args' is refused before anything is written (rc=$RC): $OUT"
done

# --- L2 -------------------------------------------------------------------
R="$T/l2"; mkrepo "$R"
load "$R" example-org/gamma --tracker linear --team CRO --label ai-ready --no-bootstrap
[ "$RC" = 0 ] && ok || bad "L2 --tracker linear --no-bootstrap (rc=$RC): $OUT"
P="$R/prompts/gamma.md"
head -1 "$P" 2>/dev/null | grep -q '(Linear board)' && grep -q 'Linear team `CRO`' "$P" && grep -q 'labelled \*\*`ai-ready`\*\*' "$P" \
  && grep -q 'tracker-cli.sh gamma read CRO-<n>' "$P" && ! grep -qE '<(TEAM|LABEL|PROJECT)>' "$P" && ok || bad "L2 the Linear prompt is rendered: $(head -3 "$P" 2>/dev/null)"
! grep -q 'run-build.sh gamma' "$P" && ok || bad "L2 the Linear prompt launches no build"
! grep -q 'label create' "$R/gh.log" && ok || bad "L2 no GitHub label is created: $(cat "$R/gh.log")"
grep -q '^gamma .* -  *[0-9]' "$R/fleet.conf" && ok || bad "L2 the registry row is the usual column-4 '-' row"
t=$(printf '%s\n' "$OUT" | grep -n 'setting-set tracker_linear.gamma.team CRO' | cut -d: -f1)
a=$(printf '%s\n' "$OUT" | grep -n 'setting-set tracker_adapter.gamma linear' | cut -d: -f1)
[ -n "$t" ] && [ -n "$a" ] && [ "$t" -lt "$a" ] && printf '%s\n' "$OUT" | grep -q 'tracker_linear.gamma.label ai-ready' && ok \
  || bad "L2 the rows are printed team first: $OUT"

# --- L3 -------------------------------------------------------------------
R="$T/l3"; mkrepo "$R"
load "$R" example-org/gamma --no-bootstrap
[ "$RC" = 0 ] && head -1 "$R/prompts/gamma.md" | grep -q '(GitHub Issues board)' && grep -q 'label create ai-build' "$R/gh.log" && ok \
  || bad "L3 the default path is the GitHub one (rc=$RC)"
! printf '%s\n' "$OUT" | grep -q -i linear && ok || bad "L3 the default path says nothing about Linear"

# --- L4 -------------------------------------------------------------------
R="$T/l4"; mkrepo "$R"
load "$R" example-org/gamma --tracker linear --team CRO --label ai-ready
[ -s "$R/ssh.script" ] && ok || bad "L4 the box block was sent (rc=$RC): $OUT"
B="$T/box"; mkdir -p "$B/root/harness/bin" "$B/root/harness/env" "$B/root/harness/prompts" "$B/root/harness-checkout/.git" "$B/root/harness-checkout/prompts"
: > "$B/root/harness/env/global.env"; : > "$B/root/harness/prompts/gamma.md"; : > "$B/root/harness-checkout/prompts/gamma.md"
cp "$R/fleet.conf" "$B/root/harness-checkout/fleet.conf"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls"\n[ "$1 $2" = "setting-set ${JC_FAIL:-none}" ] && exit 1\nexit 0\n' "$B" > "$B/root/harness/bin/jobs-client.sh"
printf '#!/bin/bash\nprintf "bootstrap %%s\\n" "$*" >> "%s/calls"\n' "$B" > "$B/root/harness/bin/bootstrap-machine.sh"
printf '#!/bin/bash\nexit 0\n' > "$B/root/harness/bin/harness-sync.sh"
chmod +x "$B/root/harness/bin/"*.sh
A=(); [ -r "$R/ssh.args" ] && mapfile -t A < "$R/ssh.args"
i=0; while [ "$i" -lt "${#A[@]}" ] && [ "${A[$i]}" != -- ]; do i=$((i+1)); done
boxrun() { sed "s#/root/#$B/root/#g" "$R/ssh.script" | (cd "$B" && PATH="$R/stub:$PATH" LP="$R" bash -s -- "${A[@]:$((i+1))}") >"$B/out" 2>&1; }
boxrun; rc=$?
[ "$rc" = 0 ] && ok || bad "L4 the box block runs (rc=$rc): $(cat "$B/out")"
grep -qx 'LINEAR_API_KEY=' "$B/root/harness/env/gamma.env" 2>/dev/null && ok || bad "L4 the env file defines an empty LINEAR_API_KEY: $(cat "$B/root/harness/env/gamma.env" 2>/dev/null)"
[ "$(cat "$B/calls" 2>/dev/null)" = "setting-set tracker_linear.gamma.team CRO
setting-set tracker_linear.gamma.label ai-ready
setting-set tracker_adapter.gamma linear
bootstrap gamma" ] && ok || bad "L4 rows team, label, adapter, then bootstrap: $(cat "$B/calls" 2>/dev/null)"
rm -f "$B/calls"
boxrun
[ "$(grep -c '^LINEAR_API_KEY=' "$B/root/harness/env/gamma.env")" = 1 ] && ok || bad "L4 a re-run adds no second key line"
rm -f "$B/calls"; JC_FAIL=tracker_linear.gamma.team; export JC_FAIL
boxrun; rc=$?; unset JC_FAIL
[ "$rc" != 0 ] && ! grep -q '^setting-set tracker_adapter' "$B/calls" && ! grep -q '^bootstrap' "$B/calls" && ok \
  || bad "L4 a failed team row stops before the adapter row and bootstrap (rc=$rc): $(cat "$B/calls" 2>/dev/null)"

echo "tracker-linear-onboard: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
