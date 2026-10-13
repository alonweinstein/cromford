#!/bin/bash
# tests/archie-fm-conflicts.bh-4585-test.sh — BH-4585 (BH-4574.3): Archie's
# rebase-repair playbook (the ticket's tests/archie-fm-conflicts-test.sh, keyed
# to the ticket per house rule), driven through the SHIPPED bin/archie-fm.sh.
#
# THE WORLD IS A REAL GIT REPO. $T/origin.git has `main` and ONE PR branch,
# ticket/bh-9005 (PR #5, base main), both cut from a base commit and then moved
# apart so `git merge origin/main` meets exactly the conflict a case names:
#   routes    worker/jobs/src/index.js, both sides add an import and a spread
#   seeds     worker/jobs/schema.sql, both sides append a seed
#   json      catalog/context-budgets.json, both append an object (the
#             6f3fcaba shape: the joining `},` neither side carries)
#   frag      worker/jobs/test/route-table.d/675-x.txt, both append a line
#   semantic  bin/lib/x.sh, both edit the same line of x_fn's body
#   offlist   worker/jobs/src/lib/core.js, insertion-only, OFF the allowlist
#   rtedit    worker/jobs/src/index.js, both edit the SAME existing line
#   drift     docs/render/src/ gains a file on each side; the rendered
#             docs/render/out.txt and docs/config-inventory/inventory.json go
#             stale without any conflict
# $T/repos/fixt is the hub clone. The conductor's park is a pr-state.tsv row
# written by the case. The repo carries a bin/test-impact-gate.sh that logs to
# $T/suites.log and answers rc from $T/suite.rcs (one line per run) or
# $T/suite.rc, naming $T/suite.red's suite when red.
#
# WHAT IS STUBBED, and only this (ARCHIE_FM_FIXTURE=$T/fx.sh, sandbox-only):
# _jobs_req (a jq model of the settings and archie_actions routes over
# $T/db.json, the worker's codes and _jobs_req's rc contract; the worker side
# runs for real in worker/jobs/test/archie-actions.bh-4585.test.js),
# gh_rest_pr_list_var ($T/prs.json), mc_git_auth (file:// origin),
# mc_hold_keeps_pr ($T/held), hold_push_verdict (clear), flaky_gate_set
# ($T/flaky.set). curl and gh fail and log.
#
# Cases: U1-U8 the union tool on real merges; C1-C12 the playbook; D1-D4
# drift; F1-F4 flaky re-run; R1-R6 the resolver's side; G1 the digest; X1-X7
# mutations, each turning a named case red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-fm-conflicts.bh-4585-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-fm-conflicts: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "archie-fm-conflicts: python3 is required"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "archie-fm-conflicts: node is required (the .js validator)"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "${ARCHIE_FM_TEST_VERBOSE:-}" = 1 ] && [ -n "${1:-}" ] && echo "ok: $1"; return 0; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }

# The product paths this ticket ships (D41).
for f in "$DIR/bin/lib/archie-fm-repair.sh" "$DIR/bin/lib/archie-fm-union.py" "$DIR/bin/archie-fm.sh" \
         "$DIR/bin/lib/archie-fm.sh" "$DIR/bin/blocked-resolver.sh" "$DIR/worker/jobs/src/routes/archie-actions.js"; do
  if [ -f "$f" ]; then ok "ships ${f#"$DIR"/}"; else bad "missing $f"; fi
done
if [ ! -f "$DIR/bin/lib/archie-fm-repair.sh" ] || [ ! -f "$DIR/bin/lib/archie-fm-union.py" ]; then
  echo "archie-fm-conflicts: $PASS passed, $FAIL failed"; exit 1
fi
PY="$DIR/bin/lib/archie-fm-union.py"

NOW=1791184500                       # 2026-10-05T07:15:00Z, read once
DAY=2026-10-05
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
       GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home" PYTHONDONTWRITEBYTECODE=1
mkdir -p "$T/home" "$T/tmp"

# ═════ U: the union tool on real merges ══════════════════════════════════════
# mkconf <dir> <path> <base> <ours> <theirs> — a repo whose `git merge main`
# into `br` leaves <path> conflicted (printf formats).
mkconf() {
  local d="$1" f="$2"
  scratch_rm "$d" || exit 1; mkdir -p "$d/$(dirname "$f")"; git init -q -b main "$d"
  printf "$3" > "$d/$f"; git -C "$d" add -A; git -C "$d" commit -qm base
  git -C "$d" checkout -qb br; printf "$4" > "$d/$f"; git -C "$d" commit -qam ours
  git -C "$d" checkout -q main; printf "$5" > "$d/$f"; git -C "$d" commit -qam theirs
  git -C "$d" checkout -q br; git -C "$d" merge -q main >/dev/null 2>&1
  grep -qxF "$f" <<<"$(git -C "$d" diff --name-only --diff-filter=U)"
}
union() { python3 "$PY" resolve "$1" "$2" > "$T/u.out" 2> "$T/u.err"; echo $? > "$T/u.rc"; }

mkconf "$T/u1" src/i.js 'import a from "a";\nexport const r = [\n  a,\n];\n' \
  'import a from "a";\nimport b from "b";\nexport const r = [\n  a,\n  b,\n];\n' \
  'import a from "a";\nimport c from "c";\nexport const r = [\n  a,\n  c,\n];\n' || bad "U1 setup: no conflict"
union "$T/u1" src/i.js
eq "U1 lines both-insert: rc 0, union-lines" "$(cat "$T/u.rc") $(cat "$T/u.out")" "0 shape=union-lines"
eq "U1 the file is both sides, ours first" "$(cat "$T/u1/src/i.js")" "$(printf 'import a from "a";\nimport b from "b";\nimport c from "c";\nexport const r = [\n  a,\n  b,\n  c,\n];')"
check "U1 node --check accepts it" 'cp "$T/u1/src/i.js" "$T/u1.mjs" && node --check "$T/u1.mjs"'
mkconf "$T/u2" src/i.js 'export const r = [\n  a,\n];\n' 'export const r = [\n  a1,\n];\n' 'export const r = [\n  a2,\n];\n' || bad "U2 setup"
union "$T/u2" src/i.js
check "U2 both changed one base line: rc 1 ($(cat "$T/u.err"))" '[ "$(cat "$T/u.rc")" = 1 ] && grep -q "same base lines" "$T/u.err"'
check "U2 ...the file still carries git's markers" 'grep -q "^<<<<<<<" "$T/u2/src/i.js"'
mkconf "$T/u3" s/schema.sql 'CREATE TABLE t (k TEXT);\n' \
  "CREATE TABLE t (k TEXT);\nATTACH DATABASE '$T/attached.db' AS x;\n" \
  "CREATE TABLE t (k TEXT);\nINSERT INTO t VALUES ('c');\n" || bad "U3 setup"
union "$T/u3" s/schema.sql
check "U3 a .sql union carrying ATTACH: rc 1 ($(cat "$T/u.err"))" '[ "$(cat "$T/u.rc")" = 1 ]'
check "U3 ...and no database file was created" '[ ! -e "$T/attached.db" ]'
mkconf "$T/u4" b/x.sh 'f() {\n  :\n}\n' 'f() {\n  :\n}\ng() { :; }\n' 'f() {\n  :\n}\nh() { if; }\n' || bad "U4 setup"
union "$T/u4" b/x.sh
check "U4 the validator rejects origin's own copy: rc 1, said so ($(cat "$T/u.err"))" \
  '[ "$(cat "$T/u.rc")" = 1 ] && grep -q "rejects origin" "$T/u.err"'
mkconf "$T/u5" c/a.json '{\n  "n": 1\n}\n' '{\n  "n": 2\n}\n' '{\n  "n": 3\n}\n' || bad "U5 setup"
union "$T/u5" c/a.json
eq "U5 JSON scalar changed on both sides: rc 1" "$(cat "$T/u.rc")" 1
mkconf "$T/u6" c/a.json '[\n  "a",\n  "b"\n]\n' '[\n  "b",\n  "a",\n  "x"\n]\n' '[\n  "a",\n  "b",\n  "y"\n]\n' || bad "U6 setup"
union "$T/u6" c/a.json
eq "U6 JSON reorder: rc 1" "$(cat "$T/u.rc")" 1
mkconf "$T/u7" c/a.json '[\n  {\n    "a": 1\n  }\n]\n' '[\n  {\n    "a": 1\n  },\n  {\n    "b": 2\n  }\n]\n' '[\n  {\n    "a": 1\n  },\n  {\n    "c": 3\n  }\n]\n' || bad "U7 setup"
union "$T/u7" c/a.json
check "U7 the junction comma neither side had: rc 0, three objects ($(cat "$T/u.err"))" \
  '[ "$(cat "$T/u.rc")" = 0 ] && [ "$(jq -c . "$T/u7/c/a.json")" = "[{\"a\":1},{\"b\":2},{\"c\":3}]" ]'
python3 "$PY" diagnose "$T/u2" src/i.js "a note" > "$T/u.diag"
check "U8 diagnose names the enclosing definition and both sides ($(head -c 300 "$T/u.diag" | tr '\n' '|'))" \
  'grep -q "^in: export const r = \[" "$T/u.diag" && grep -q "^    a1,$" "$T/u.diag" && grep -q "^    a2,$" "$T/u.diag" && grep -q "^note: a note$" "$T/u.diag"'
# untar: a symlink and a ../ member refuse the whole archive, nothing extracted.
mkdir -p "$T/tar1/docs/g" "$T/tar2/x" "$T/tarout1" "$T/tarout2"
echo ok > "$T/tar1/docs/g/a.txt"; ln -s /etc/hostname "$T/tar1/docs/g/link"
tar -cf "$T/t1.tar" -C "$T/tar1" docs/g
echo evil > "$T/tar2/evil.txt"; tar -cf "$T/t2.tar" -C "$T/tar2/x" --transform 's,^,../,' -P ../evil.txt 2>/dev/null \
  || python3 -c "import tarfile,sys; t=tarfile.open(sys.argv[1],'w'); t.add(sys.argv[2], arcname='docs/g/../../evil.txt'); t.close()" "$T/t2.tar" "$T/tar2/evil.txt"
python3 "$PY" untar "$T/t1.tar" "$T/tarout1" docs/g 2>"$T/u.err"; rc=$?
check "U8 untar: a symlink member refuses the archive, nothing extracted (rc $rc $(cat "$T/u.err"))" '[ "$rc" = 1 ] && [ -z "$(ls -A "$T/tarout1")" ]'
python3 "$PY" untar "$T/t2.tar" "$T/tarout2" docs/g 2>"$T/u.err"; rc=$?
check "U8 untar: a ../ member refuses the archive (rc $rc $(cat "$T/u.err"))" '[ "$rc" = 1 ] && [ -z "$(ls -A "$T/tarout2")" ] && [ ! -e "$T/evil.txt" ]'
# A symlink on the way: never followed by a root write.
mkdir -p "$T/outside"; ln -s "$T/outside" "$T/tarout3"
mkdir -p "$T/tar3/docs/g"; echo ok > "$T/tar3/docs/g/a.txt"; tar -cf "$T/t3.tar" -C "$T/tar3" docs/g
mkdir -p "$T/dest3/docs"; ln -s "$T/outside" "$T/dest3/docs/g"
python3 "$PY" untar "$T/t3.tar" "$T/dest3" docs/g 2>"$T/u.err"; rc=$?
check "U8 untar: a declared dir that is a symlink out of the tree refuses the archive (rc $rc $(cat "$T/u.err"))" '[ "$rc" = 1 ] && [ -z "$(ls -A "$T/outside")" ]'
rm -rf "$T/u9"; git init -q -b main "$T/u9"; printf 'a\n' > "$T/u9/f.json"; git -C "$T/u9" add -A; git -C "$T/u9" commit -qm base
git -C "$T/u9" checkout -qb br; rm "$T/u9/f.json"; ln -s "$T/u9-target" "$T/u9/f.json"; git -C "$T/u9" add -A; git -C "$T/u9" commit -qm link
git -C "$T/u9" checkout -q main; printf 'b\n' > "$T/u9/f.json"; git -C "$T/u9" commit -qam edit
git -C "$T/u9" checkout -q br; git -C "$T/u9" merge -q main >/dev/null 2>&1
union "$T/u9" f.json
check "U9 a conflict whose side is a symlink: refused, nothing written through it ($(cat "$T/u.err"))" '[ "$(cat "$T/u.rc")" = 1 ] && [ ! -e "$T/u9-target" ]'
check "U py_compile leaves no __pycache__ beside the tool" '[ ! -d "$DIR/bin/lib/__pycache__" ]'

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/catalog" "$H/env" "$H/logs" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
: > "$H/env/global.env"
rm -f "$H/bin/fleet-conf.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1" in
  --projects) echo fixt ;;
  --*) ;;
  *) [ "${2:-}" = repo ] && echo "acme/$1" ;;
esac
SH
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/alerts.log"\n' > "$H/bin/alert-line.sh"
cp "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
# gh: only wave 1's retarget PATCH is answered (F4); anything else fails.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/gh.log"
if [ "${1:-} ${2:-} ${3:-}" = "api -X PATCH" ] && [ "${5:-}" = -f ]; then
  n=${4##*/}; b=${6#base=}
  jq --argjson n "$n" --arg b "$b" 'map(if .number == $n then .base.ref = $b else . end)' "$FXT/prs.json" > "$FXT/prs.tmp" \
    && mv "$FXT/prs.tmp" "$FXT/prs.json"
  exit 0
fi
exit 1
SH
printf '#!/bin/bash\nprintf "curl %%s\\n" "$*" >> "$FXT/net.log"\nexit 7\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"

# The worker, modelled in jq over $T/db.json: the same answers as
# worker/jobs/src/routes/archie-actions.js and the settings route.
cat > "$T/fx.sh" <<'SH'
fx_clock() { date -u -d "@$ARCHIE_FM_NOW" +%Y-%m-%dT%H:%M:%SZ; }
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" out code=200 db="$FXT/db.json" key t
  JOBS_HTTP=""; JOBS_BODY=""
  case "$p" in /api/flags*|/api/lanes*) JOBS_HTTP=404; return 2 ;; esac
  [ "$p" = /api/settings ] && { printf '{"settings":[]}'; JOBS_HTTP=200; return 0; }
  printf '%s %s %s\n' "$m" "$p" "$b" >> "$FXT/reqlog"
  t=$(fx_clock)
  qp() { printf '%s' "$p" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p"; }
  case "$m ${p%%\?*}" in
    GET\ /api/settings/*)
      [ -f "$FXT/settings.down" ] && { JOBS_HTTP=503; return 1; }
      key=${p#/api/settings/}
      out=$(jq -c --arg k "$key" 'select(.settings | has($k)) | {setting: {key: $k, value: .settings[$k]}}' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; JOBS_BODY='{"error":"setting not found"}'; return 2; } ;;
    "POST /api/archie/actions")
      [ -f "$FXT/route.absent" ] && { JOBS_HTTP=404; return 2; }
      key=$(jq -r .dedupe_key <<<"$b")
      out=$(jq -c --arg k "$key" '.actions[] | select(.dedupe_key == $k)' "$db")
      if [ -z "$out" ]; then
        jq --argjson b "$b" --arg t "$t" '.actions += [$b + {id: ((.actions | length) + 1), day: $t[0:10], attempts: 1,
            evidence: ($b.evidence // {}), created_at: $t, updated_at: $t}]' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
        out=$(jq -c --arg k "$key" '{ok: true, created: true, action: (.actions[] | select(.dedupe_key == $k))}' "$db"); code=201
      elif jq -e --argjson b "$b" '.project == $b.project and .repo == $b.repo and .pr == $b.pr and .playbook == $b.playbook and .mode == $b.mode' <<<"$out" >/dev/null; then
        out=$(jq -c '{ok: true, existing: true, action: .}' <<<"$out")
      else
        out=$(jq -c '{error: "different payload", action: .}' <<<"$out"); JOBS_HTTP=409; JOBS_BODY=$out; printf '%s' "$out"; return 9
      fi ;;
    "POST /api/archie/actions/outcome")
      out=$(jq -c --argjson b "$b" '.actions[] | select(.id == $b.id and .dedupe_key == $b.dedupe_key)' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; return 2; }
      if ! jq -e --argjson b "$b" '(.outcome + ">" + $b.outcome) as $tr
           | ["started>done","started>requested","started>would","started>deferred","started>failed","deferred>started","deferred>failed"]
           | index($tr) != null' <<<"$out" >/dev/null || ! jq -e --argjson b "$b" '.updated_at == $b.expect_updated_at' <<<"$out" >/dev/null; then
        out=$(jq -c '{error: "stale or illegal", action: .}' <<<"$out"); JOBS_HTTP=409; JOBS_BODY=$out; printf '%s' "$out"; return 9
      fi
      jq --argjson b "$b" --arg t "$t" '.actions |= map(if .id == $b.id then
          (if .outcome == "deferred" and $b.outcome == "started" then .attempts += 1 else . end)
          | .outcome = $b.outcome | .action = ($b.action // .action) | .why = ($b.why // .why)
          | .evidence = ($b.evidence // .evidence) | .updated_at = $t else . end)' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out=$(jq -c --argjson b "$b" '{ok: true, action: (.actions[] | select(.id == $b.id))}' "$db") ;;
    "GET /api/archie/actions")
      [ -f "$FXT/route.absent" ] && { JOBS_HTTP=404; JOBS_BODY='{"error":"not found"}'; return 2; }
      local d pb s k cb; d=$(qp day); pb=$(qp playbook); s=$(qp summary); k=$(qp dedupe_key); cb=$(qp count_by)
      if [ -n "$k" ]; then
        k=$(printf '%b' "${k//%/\\x}")
        out=$(jq -c --arg k "$k" '.actions[] | select(.dedupe_key == $k) | {action: .}' "$db")
        [ -n "$out" ] || { JOBS_HTTP=404; JOBS_BODY='{"error":"archie action not found"}'; return 2; }
        JOBS_HTTP=200; JOBS_BODY="$out"; printf '%s' "$out"; return 0
      fi
      out=$(jq -c --arg d "$d" --arg pb "$pb" --arg s "$s" --arg cb "$cb" '[.actions[] | select(.day == $d and ($pb == "" or .playbook == $pb))] as $r
        | if $s == "1" then {ok: true, day: $d, total: ($r | length),
             restacked: ([$r[] | select(.mode == "on" and .action == "restack" and .outcome == "done")] | length),
             repaired: ([$r[] | select(.mode == "on" and .action == "repair" and .outcome == "done")] | length),
             fix_rounds: ([$r[] | select(.outcome == "requested")] | length),
             would: ([$r[] | select(.outcome == "would")] | length),
             deferred: ([$r[] | select(.outcome == "deferred")] | length),
             failed: ([$r[] | select(.outcome == "failed")] | length)}
          else {ok: true, day: $d, actions: $r,
             counts: (reduce $r[] as $x ({}; .[$x.playbook][$x.mode][if $cb == "action" then $x.action else $x.outcome end] += 1)),
             truncated: false} + (if $cb == "action" then {count_by: "action"} else {} end) end' "$db") ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=$code; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
gh_rest_pr_list_var() {
  local v="$1" slug="$2" state="$3" head="${4:-}" out
  printf 'list %s %s %s\n' "$slug" "$state" "$head" >> "$FXT/ghrest.log"
  if [ -n "$head" ]; then
    out=$(jq -c --arg h "${head#*:}" --arg st "$state" '[.[] | select(.head.ref == $h and ($st == "all" or .state == $st))]' "$FXT/prs.json")
  elif [ "$slug" = acme/fixt ]; then
    out=$(jq -c --arg st "$state" '[.[] | select(.state == $st)]' "$FXT/prs.json")
  else
    out='[]'
  fi
  printf -v "$v" '%s' "$out"; GH_REST_STATUS=200; return 0
}
mc_git_auth() { MC_REMOTE="file://$FXT/origin.git"; export MC_GIT_TOKEN=fixture-token GIT_ASKPASS=/nonexistent/askpass; return 0; }
mc_hold_keeps_pr() { [ -f "$FXT/held" ]; }
. "$HARNESS/bin/lib/hold-push.sh"
hold_push_verdict() { printf 'clear\tfixture\n'; return 0; }
flaky_gate_set() { [ -f "$FXT/flaky.down" ] && return 1; cat "$FXT/flaky.set" 2>/dev/null; return 0; }
SH

export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test \
       MC_REPOS="$T/repos" MC_REHYDRATE=0 TMPDIR="$T/tmp"
unset ARCHIE_FM_ENABLED ARCHIE_FM_RETRY_S ARCHIE_FM_MAX_ATTEMPTS ARCHIE_FM_SUITE_TIMEOUT_S ARCHIE_FM_PROJECTS_PER_TICK \
  ARCHIE_FM_NOW ARCHIE_FM_FIXTURE ARCHIE_FM_TIMED ARCHIE_FM_DEADLINE ARCHIE_FM_TICK_CEILING_S ARCHIE_FM_SUITE_AS 2>/dev/null || true

W="$T/work"
G() { git -C "$W" "$@" >/dev/null 2>&1; }
put() { mkdir -p "$(dirname "$W/$1")"; printf "$2" > "$W/$1"; }
add_line_after() { python3 -c "import sys; p,a,l=sys.argv[1:]; s=open(p).read(); i=s.index(a)+len(a); open(p,'w').write(s[:i]+l+s[i:])" "$W/$1" "$2" "$3"; }
# variant <name> <side: br|main> — the edit one side makes for a variant.
variant() {
  local v="$1" s="$2" x; [ "$s" = br ] && x=b || x=c
  case "$v" in
    routes)   add_line_after worker/jobs/src/index.js $'import { a } from "./routes/a.js";\n' "import { $x } from \"./routes/$x.js\";"$'\n'
              add_line_after worker/jobs/src/index.js $'  ...a,\n' "  ...$x,"$'\n' ;;
    seeds)    printf "INSERT OR IGNORE INTO seeds VALUES ('%s');\n" "$x" >> "$W/worker/jobs/schema.sql" ;;
    json)     python3 -c "import sys; p,x=sys.argv[1:]; s=open(p).read(); a='      \"note\": \"caf\\\\u00e9 \\\\u2014 keep\"\n    }'; assert a in s; open(p,'w').write(s.replace(a, a+',\n    {\n      \"stage\": \"'+x+'\"\n    }'))" "$W/catalog/context-budgets.json" "$x" ;;
    frag)     printf 'GET /api/%s\n' "$x" >> "$W/worker/jobs/test/route-table.d/675-x.txt" ;;
    semantic) sed -i "s/  echo base/  echo $([ "$s" = br ] && echo branch || echo main)/" "$W/bin/lib/x.sh" ;;
    offlist)  add_line_after worker/jobs/src/lib/core.js $'export function core() {\n' "  const $x = 2;"$'\n' ;;
    rtedit)   sed -i "s/^  \.\.\.a,$/  ...a$x,/" "$W/worker/jobs/src/index.js" ;;
    drift)    echo "$x" > "$W/docs/render/src/$x.txt"
              [ "$s" = main ] && { (cd "$W" && bash bin/render-fixture.sh && bash bin/inv.sh) >/dev/null 2>&1; } ;;
  esac
}
# world [variant...] — a fresh repo, PR #5, db and harness state. The PR's
# branch and main each make every named variant's edit, so the merge meets
# all of them at once.
world() {
  local p v
  for p in origin.git repos work db.json reqlog gh.log ghrest.log order.log suites.log suite.rc suite.rcs suite.red \
           alerts.log net.log held settings.down route.absent move.branch flaky.set flaky.down out rc prs.json; do
    scratch_rm "$T/$p" || exit 1
  done
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1
  scratch_rm "$H/logs/archie-fm.log" || exit 1; scratch_rm "$H/logs/merge-conductor.log" || exit 1
  mkdir -p "$W" "$T/repos" "$H/state/merge-conductor"
  git init -q -b main "$W"
  put worker/jobs/src/index.js 'import { a } from "./routes/a.js";\nexport const routes = [\n  ...a,\n];\n'
  put worker/jobs/schema.sql "CREATE TABLE IF NOT EXISTS seeds (k TEXT PRIMARY KEY);\nINSERT OR IGNORE INTO seeds VALUES ('base');\n"
  put catalog/context-budgets.json '{\n  "budgets": [\n    {\n      "stage": "base",\n      "note": "caf\\u00e9 \\u2014 keep"\n    }\n  ]\n}\n'
  put worker/jobs/test/route-table.d/675-x.txt 'GET /api/a\n'
  put worker/jobs/src/lib/core.js 'export function core() {\n  return 1;\n}\n'
  put bin/lib/x.sh 'x_fn() {\n  echo base\n}\n'
  put docs/render/src/a.txt 'a\n'
  put bin/render-fixture.sh 'cat docs/render/src/*.txt > docs/render/out.txt\n'
  put bin/inv.sh 'ls docs/render/src | jq -R . | jq -sc "{files: .}" > docs/config-inventory/inventory.json\n'
  put bin/inv-fail.sh 'echo partial > docs/config-inventory/inventory.json\nexit 3\n'
  put bin/inv-link.sh 'rm -f docs/config-inventory/inventory.json; ln -s /etc/hostname docs/config-inventory/inventory.json\n'
  put bin/inv-stamp.sh 'ls docs/render/src | jq -R . | jq -s --arg c "$(git rev-parse HEAD 2>/dev/null)" "{generated_at_commit: \\$c, files: .}" > docs/config-inventory/stamp.json\n'
  put docs/config-inventory/.keep ''
  put AGENT_ARCHITECTURE.md '# Fixture\n\n## Generated files\n\n| File | Regenerate with |\n|---|---|\n| `docs/render/out.txt` | `bash bin/render-fixture.sh` |\n'
  (cd "$W" && bash bin/render-fixture.sh && bash bin/inv.sh && bash bin/inv-stamp.sh)
  { printf '#!/bin/bash\nFXT=%q\n' "$T"; cat <<'SH'; } > "$W/bin/test-impact-gate.sh"
echo "run $*" >> "$FXT/suites.log"
if [ -f "$FXT/move.branch" ]; then
  d=$(mktemp -d)
  git clone -q "$FXT/origin.git" "$d" && git -C "$d" checkout -q ticket/bh-9005 \
    && echo moved > "$d/moved.txt" && git -C "$d" add -A \
    && git -C "$d" -c user.name=someone -c user.email=someone@example.invalid commit -qm "someone else" \
    && git -C "$d" push -q origin ticket/bh-9005
  rm -rf "$d"
fi
n=$(grep -c . "$FXT/suites.log")
rc=$(sed -n "${n}p" "$FXT/suite.rcs" 2>/dev/null)
[ -n "$rc" ] || rc=$(cat "$FXT/suite.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || echo "impact-gate: done $(cat "$FXT/suite.red" 2>/dev/null || echo tests/flaky-x.sh) rc=$rc"
exit "$rc"
SH
  chmod +x "$W/bin/test-impact-gate.sh"
  G add -A; G commit -qm base
  G checkout -q -b ticket/bh-9005
  for v in "$@"; do variant "$v" br; done
  echo own > "$W/own.txt"; G add -A; G commit -qm "BH-9005 own work"
  G checkout -q main
  for v in "$@"; do variant "$v" main; done
  echo main > "$W/main.txt"; G add -A; G commit -qm "main moves on"
  HEAD5=$(git -C "$W" rev-parse ticket/bh-9005)
  git init -q --bare -b main "$T/origin.git"
  G push -q "$T/origin.git" main ticket/bh-9005
  printf '#!/bin/sh\necho push >> "%s/order.log"\n' "$T" > "$T/origin.git/hooks/post-receive"
  chmod +x "$T/origin.git/hooks/post-receive"
  git clone -q "$T/origin.git" "$T/repos/fixt"
  jq -n --arg h "$HEAD5" '[{number: 5, state: "open", html_url: "https://github.com/acme/fixt/pull/5", merged_at: null,
     head: {ref: "ticket/bh-9005", sha: $h, repo: {full_name: "acme/fixt"}}, base: {ref: "main"}}]' > "$T/prs.json"
  jq -n '{settings: {"archie.manage": "on", "archie.cap.rebase-repair": "10",
           "archie.fm.regen": "docs/config-inventory/inventory.json=bash bin/inv.sh"}, actions: []}' > "$T/db.json"
  park "conflict-unresolvable: merge of origin/main conflicts in worker/jobs/src/index.js"
  : > "$T/reqlog"; : > "$T/gh.log"; : > "$T/order.log"; : > "$T/suites.log"
}
# park <reason> [head] [since] — the conductor's row for acme/fixt#5.
park() {
  printf 'acme/fixt#5\tBLOCKED_HUMAN\t%s\t%s\t-\t-\t%s\thttps://github.com/acme/fixt/pull/5\n' \
    "${3:-$((NOW - 120))}" "${2:-$HEAD5}" "$1" > "$H/state/merge-conductor/pr-state.tsv"
}
setting() { jq --arg k "$1" --arg v "$2" '.settings[$k] = $v' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"; }
tick() { # tick [VAR=value ...] — one tick of the shipped lane at NOW
  env HARNESS_TEST_SANDBOX=1 ARCHIE_FM_NOW="$NOW" ARCHIE_FM_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 ARCHIE_FM_SUITE_AS=self "$@" \
    bash "$H/bin/archie-fm.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
rows()   { jq '.actions | length' "$T/db.json"; }
row()    { jq -r --arg f "$1" '.actions[-1] | getpath($f | split(".")) // "null" | if type == "string" then . else tojson end' "$T/db.json"; }
oref()   { git -C "$T/origin.git" rev-parse "$1" 2>/dev/null; }
ofile()  { git -C "$T/origin.git" show "ticket/bh-9005:$1" 2>/dev/null; }
refs()   { git -C "$T/origin.git" for-each-ref; git -C "$T/repos/fixt" for-each-ref; git -C "$T/repos/fixt" worktree list --porcelain; }
pushes() { grep -c '^push$' "$T/order.log"; }
lastlog(){ grep ' projects=' "$H/logs/archie-fm.log" 2>/dev/null | tail -1; }
nruns()  { grep -c . "$T/suites.log"; }
prow()   { cat "$H/state/merge-conductor/pr-state.tsv" 2>/dev/null; }
nothing_done() { [ "$(rows)" = 0 ] && [ "$(oref ticket/bh-9005)" = "$HEAD5" ] && [ "$(pushes)" = 0 ] && [ ! -s "$T/suites.log" ]; }
# pushed_merge: origin's branch moved off HEAD5 by a merge whose first parent
# is HEAD5 (the lease held) and which contains origin/main.
pushed_merge() {
  local h; h=$(oref ticket/bh-9005)
  [ "$h" != "$HEAD5" ] && [ "$(pushes)" = 1 ] \
    && git -C "$T/origin.git" merge-base --is-ancestor "$HEAD5" "$h" \
    && git -C "$T/origin.git" merge-base --is-ancestor main "$h"
}

# ── C1: route lists, through the shipped tick ───────────────────────────────
c1_world_ticked() { world routes; tick; }
c1_repaired() {
  pushed_merge && [ "$(row playbook)/$(row mode)/$(row action)/$(row outcome)" = rebase-repair/on/repair/done ] \
    && lastlog | grep -q ' repaired=1$'
}
c1_world_ticked
check "C1 rc 0 and repaired=1 on the tick line ($(lastlog))" '[ "$(cat "$T/rc")" = 0 ] && lastlog | grep -qE " stuck=1 unclassified=0 .* repaired=1$"'
check "C1 ONE push, a merge on top of the listed head that contains main" 'pushed_merge'
check "C1 the pushed index.js carries both imports and both spreads, and parses" \
  'ofile worker/jobs/src/index.js > "$T/c1.mjs" && grep -q "import { b }" "$T/c1.mjs" && grep -q "import { c }" "$T/c1.mjs" && grep -q "^  \.\.\.b,$" "$T/c1.mjs" && grep -q "^  \.\.\.c,$" "$T/c1.mjs" && node --check "$T/c1.mjs"'
eq "C1 exactly one archie_actions row" "$(rows)" 1
eq "C1 the row" "$(row playbook) $(row mode) $(row action) $(row outcome)" "rebase-repair on repair done"
eq "C1 the dedupe key is head-bound" "$(row dedupe_key)" "rebase-repair:acme/fixt#5:$HEAD5:on"
eq "C1 evidence.shapes" "$(row evidence.shapes)" '["union-lines"]'
eq "C1 evidence.new_head = the origin tip" "$(row evidence.new_head)" "$(oref ticket/bh-9005)"
eq "C1 evidence.resolved" "$(row evidence.resolved)" '["worker/jobs/src/index.js"]'
eq "C1 the suites ran once" "$(nruns)" 1
eq "C1 main untouched" "$(git -C "$T/origin.git" log -1 --format=%s main)" "main moves on"
eq "C1 no worktree left on the hub clone" "$(git -C "$T/repos/fixt" worktree list | wc -l | tr -d ' ')" 1
check "C1 the claim is the first write (POST create before outcome)" \
  '[ "$(grep -n "^POST /api/archie/actions " "$T/reqlog" | head -1 | cut -d: -f1)" -lt "$(grep -n "^POST /api/archie/actions/outcome " "$T/reqlog" | head -1 | cut -d: -f1)" ]'
check "C1 no conductor write (the park ends when the head moves)" '[ "$(prow | cut -f2,4)" = "BLOCKED_HUMAN	$HEAD5" ]'

# ── C11: a second tick on the same state does nothing ───────────────────────
# The list still says HEAD5 and so does the park: the claim is replayed, the
# worker answers `existing`, and nothing else happens.
BEFORE=$(refs); DBB=$(cat "$T/db.json"); : > "$T/reqlog"; : > "$T/suites.log"
tick
check "C11 second tick: refs and db unchanged, no outcome write, no suites ($(cut -d' ' -f1,2 "$T/reqlog" | tr '\n' '|'))" \
  '[ "$(refs)" = "$BEFORE" ] && [ "$(cat "$T/db.json")" = "$DBB" ] && ! grep -q "^POST /api/archie/actions/outcome" "$T/reqlog" && [ ! -s "$T/suites.log" ]'
# ...and once the list carries the pushed head, the park is not this head's.
jq --arg h "$(oref ticket/bh-9005)" 'map(.head.sha = $h)' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
: > "$T/reqlog"; tick
# The only archie read left is wave 1's killed-tick ledger (afm_recover_load,
# BH-4784: once per project per tick, limit=500); nothing about this PR.
check "C11 the pushed head: the park is stale, no request about it" '! grep "/api/archie" "$T/reqlog" | grep -qv "^GET /api/archie/actions?day=[^ ]*&limit=500" && [ "$(cat "$T/db.json")" = "$DBB" ]'

# ── C2-C4: the other append-only shapes ─────────────────────────────────────
world seeds; park "rebase-gate-red: suites red after merging origin/main"; tick
check "C2 schema.sql seeds: done, pushed ($(row outcome) $(row why))" 'pushed_merge && [ "$(row outcome)" = done ]'
check "C2 both seeds, and the file applies in sqlite" \
  'ofile worker/jobs/schema.sql > "$T/c2.sql" && grep -q "VALUES ('"'"'b'"'"')" "$T/c2.sql" && grep -q "VALUES ('"'"'c'"'"')" "$T/c2.sql" && python3 -c "import sqlite3,sys; sqlite3.connect(\":memory:\").executescript(open(sys.argv[1]).read())" "$T/c2.sql"'
world json; park "conflict-unresolvable: catalog/context-budgets.json"; tick
ofile catalog/context-budgets.json > "$T/c3.json"
check "C3 context-budgets.json: done, union-json ($(row outcome) $(row evidence.shapes))" 'pushed_merge && [ "$(row evidence.shapes)" = "[\"union-json\"]" ]'
eq "C3 parses to base + ours + theirs" "$(jq -c '[.budgets[].stage]' "$T/c3.json" 2>/dev/null)" '["base","b","c"]'
check "C3 the non-canonical escapes outside the hunk are byte-identical" 'grep -qF "\"note\": \"caf\\u00e9 \\u2014 keep\"" "$T/c3.json"'
world frag; park "conflict-unresolvable: worker/jobs/test/route-table.d/675-x.txt"; tick
check "C4 a *.d/ fragment: done, both lines" \
  'pushed_merge && [ "$(ofile worker/jobs/test/route-table.d/675-x.txt | tr "\n" "|")" = "GET /api/a|GET /api/b|GET /api/c|" ]'

# ── C5: a union that validates but turns the suites red ─────────────────────
world routes; echo 1 > "$T/suite.rc"; echo tests/real-y.sh > "$T/suite.red"; tick
check "C5 suites red: requested / fix_round, no push ($(row outcome) $(row action))" \
  '[ "$(row outcome)/$(row action)" = requested/fix_round ] && [ "$(oref ticket/bh-9005)" = "$HEAD5" ] && [ "$(pushes)" = 0 ]'
check "C5 the diagnosis names the red suite" 'row evidence.diagnosis | grep -q "suites are red on the merged tree: tests/real-y.sh"'
check "C5 the tick counts a fix round ($(lastlog))" 'lastlog | grep -q " fix_rounds=1 "'

# ── C6: semantic conflicts go to a fix round with the diagnosis ─────────────
c6_world_ticked() { world semantic; park "conflict-unresolvable: bin/lib/x.sh"; tick; }
c6_fix_round() {
  [ "$(row outcome)/$(row action)" = requested/fix_round ] && [ "$(oref ticket/bh-9005)" = "$HEAD5" ] && [ "$(pushes)" = 0 ]
}
c6_world_ticked
PS6=$(prow)
check "C6 same function body: requested / fix_round, no push" 'c6_fix_round'
row evidence.diagnosis > "$T/c6.diag"
check "C6 the diagnosis names the file, the function and both sides ($(head -c 400 "$T/c6.diag" | tr '\n' '|'))" \
  'grep -qF -- "--- bin/lib/x.sh ---" "$T/c6.diag" && grep -q "^in: x_fn() {" "$T/c6.diag" && grep -q "echo branch" "$T/c6.diag" && grep -q "echo main" "$T/c6.diag"'
check "C6 ...and says it is off the allowlist" 'grep -q "not on the union allowlist" "$T/c6.diag"'
eq "C6 evidence.unresolved" "$(row evidence.unresolved)" '["bin/lib/x.sh"]'
eq "C6 no conductor write" "$(prow)" "$PS6"
eq "C6 the suites never ran" "$(nruns)" 0
eq "C6 no worktree left" "$(git -C "$T/repos/fixt" worktree list | wc -l | tr -d ' ')" 1
world offlist; tick
check "C6b insertion-only but off the allowlist (core.js): fix round ($(row outcome))" \
  'c6_fix_round && row evidence.diagnosis | grep -q "worker/jobs/src/lib/core.js"'
c6d_world_ticked() { world rtedit; tick; }
c6d_world_ticked
check "C6d an allowlisted index.js hunk that edits a base line: fix round, no push" \
  'c6_fix_round && row evidence.diagnosis | grep -q "both sides changed the same base lines"'
world routes semantic; tick
check "C6e every path is tried: x.sh unresolved, index.js resolved, no push" \
  'c6_fix_round && [ "$(row evidence.unresolved)" = "[\"bin/lib/x.sh\"]" ] && row evidence.diagnosis | grep -q "Resolved mechanically and NOT part of this brief: worker/jobs/src/index.js"'

# ── C7: observe ──────────────────────────────────────────────────────────────
world routes; setting archie.manage observe; BEFORE=$(refs)
tick
check "C7 observe: ONE would row, no git, no fetch, no suites" \
  '[ "$(rows)" = 1 ] && [ "$(row mode)/$(row action)/$(row outcome)" = observe/would_repair/would ] && [ "$(refs)" = "$BEFORE" ] && [ ! -e "$T/repos/fixt/.git/FETCH_HEAD" ] && [ ! -s "$T/suites.log" ]'
eq "C7 the observe key carries the mode" "$(row dedupe_key)" "rebase-repair:acme/fixt#5:$HEAD5:observe"

# ── C8: parks this playbook does not own ────────────────────────────────────
for R in "iron-law: hits unchanged on head" "head-not-reapproved" "red-ci-twice" "prequeue-red: tests/x.sh"; do
  world routes; park "$R"; tick
  check "C8 a '$R' park: no row, no git, counted unclassified ($(lastlog))" 'nothing_done && ! grep -q " stuck=" "$H/logs/archie-fm.log" 2>/dev/null'
done

# ── C9: the claim refused ───────────────────────────────────────────────────
world routes; : > "$T/route.absent"; tick
check "C9 route absent (404): no git, one log line" 'nothing_done && grep -q "archie_actions route absent" "$H/logs/archie-fm.log"'
world routes
jq --arg h "$HEAD5" --arg d "$DAY" '.actions += [{id: 1, dedupe_key: ("rebase-repair:acme/fixt#5:" + $h + ":on"), day: $d, project: "other",
   repo: "acme/fixt", pr: 5, playbook: "rebase-repair", mode: "on", action: "repair", outcome: "started", why: "x", evidence: {},
   attempts: 1, actor: "archie-fm", created_at: "2026-10-05T07:00:00Z", updated_at: "2026-10-05T07:00:00Z"}]' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
tick
check "C9 a different payload on the key (409): refused, no git" \
  '[ "$(rows)" = 1 ] && [ "$(oref ticket/bh-9005)" = "$HEAD5" ] && [ ! -s "$T/suites.log" ] && grep -q "different payload (409)" "$H/logs/archie-fm.log"'
c9b_world_ticked() { world routes; : > "$T/move.branch"; tick; }
c9b_world_ticked
check "C9b the push refused (the lease): deferred, never done ($(row outcome): $(row why))" \
  '[ "$(row outcome)" = deferred ] && [[ "$(row why)" == "the push was refused"* ]] && [ "$(git -C "$T/origin.git" log -1 --format=%s ticket/bh-9005)" = "someone else" ]'

# ── C10: the day cap ────────────────────────────────────────────────────────
world routes; setting archie.cap.rebase-repair 1
jq --arg d "$DAY" '.actions += [{id: 1, dedupe_key: "rebase-repair:acme/other#7:a:on", day: $d, project: "fixt", repo: "acme/other",
   pr: 7, playbook: "rebase-repair", mode: "on", action: "repair", outcome: "done", why: "x", evidence: {}, attempts: 1,
   actor: "archie-fm", created_at: "2026-10-05T01:00:00Z", updated_at: "2026-10-05T01:00:00Z"}]' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
tick
check "C10 cap reached: no claim, no git" '[ "$(rows)" = 1 ] && ! grep -q "^POST /api/archie/actions " "$T/reqlog" && [ "$(oref ticket/bh-9005)" = "$HEAD5" ] && grep -q "cap reached (1 of 1 rebase-repair" "$H/logs/archie-fm.log"'
world routes; setting archie.cap.rebase-repair 0; tick
check "C10 cap 0: the playbook is off" 'nothing_done && grep -q "archie.cap.rebase-repair=0" "$H/logs/archie-fm.log"'

# ── C12: the negatives ──────────────────────────────────────────────────────
world routes; park "conflict-unresolvable: x" 1111111111111111111111111111111111111111; tick
check "C12 a park on an older head: no row" 'nothing_done'
world routes; park "conflict-unresolvable: stacked child of parent=#4 (https://github.com/acme/fixt/pull/4) — rebase --onto main conflicts in: a (archie-fm)"; tick
check "C12 a stacked-child park (the restack's): no row" 'nothing_done'
world routes
jq 'map(.head.repo.full_name = "someone/fixt")' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"; tick
check "C12 a fork head: no row" 'nothing_done && grep -q "head lives in someone/fixt" "$H/logs/archie-fm.log"'
world routes; : > "$T/held"; tick
check "C12 HOLD: no row" 'nothing_done && grep -q "on HOLD" "$H/logs/archie-fm.log"'
world routes; mkdir -p "$H/locks"
flock "$H/locks/merge-conductor-fixt-5.lock" sleep 30 >/dev/null 2>&1 & LKP=$!
for _ in $(seq 1 50); do flock -n "$H/locks/merge-conductor-fixt-5.lock" true || break; sleep 0.1; done
tick
kill $(pgrep -P "$LKP" 2>/dev/null) "$LKP" 2>/dev/null; wait "$LKP" 2>/dev/null
check "C12 the conductor's PR lock held: no row" 'nothing_done && grep -q "holds its PR lock" "$H/logs/archie-fm.log"'
world routes; jq 'map(.base.ref = "release")' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"; tick
check "C12 a PR not based on the project's base: no row" 'nothing_done'

# ── D: generated-file drift, regenerated in place ───────────────────────────
world drift; park "rebase-gate-red: suites red after merging origin/main"; tick
check "D1 drift: done, pushed, the regenerate is its own commit ($(row outcome) $(row why))" \
  'pushed_merge && [ "$(git -C "$T/origin.git" log -1 --format=%s ticket/bh-9005)" = "regenerate docs/render/out.txt docs/config-inventory/inventory.json (archie-fm)" ]'
eq "D1 the settings row's inventory is the merged tree's" "$(ofile docs/config-inventory/inventory.json)" '{"files":["a.txt","b.txt","c.txt"]}'
eq "D2 the Generated-files table's committed render is the merged tree's" "$(ofile docs/render/out.txt | tr '\n' ' ')" "a b c "
check "D1 evidence: shapes + regenerated" \
  '[ "$(row evidence.shapes)" = "[\"regenerate\"]" ] && [ "$(row evidence.regenerated)" = "[\"docs/render/out.txt\",\"docs/config-inventory/inventory.json\"]" ]'
world drift; park "rebase-gate-red: x"; setting archie.fm.regen "docs/config-inventory/inventory.json=bash bin/inv-fail.sh"; tick
check "D3 a failing generator: evidence, not an outcome; nothing of it lands ($(row evidence.regen_failed))" \
  'pushed_merge && row evidence.regen_failed | grep -q "bash bin/inv-fail.sh (rc 3" && ! ofile docs/config-inventory/inventory.json | grep -q partial'
world drift; park "rebase-gate-red: x"; setting archie.fm.regen "docs/config-inventory/inventory.json=bash bin/inv-link.sh"; tick
check "D4 a generator emitting a symlink: the archive is refused, nothing extracted ($(row evidence.regen_failed))" \
  'pushed_merge && row evidence.regen_failed | grep -q "output refused" && [ "$(git -C "$T/origin.git" ls-tree ticket/bh-9005 docs/config-inventory/inventory.json | cut -c1-6)" = 100644 ]'

# D5: a generator that stamps the commit it ran on (bin/config-inventory.py's
# generated_at_commit) and finds no other drift: the snapshot's throwaway sha
# is not a change, so no regenerate commit and the stamp stays main's.
world routes; setting archie.fm.regen "docs/config-inventory/stamp.json=bash bin/inv-stamp.sh"; STAMP0=$(git -C "$W" show main:docs/config-inventory/stamp.json); tick
check "D5 a generated_at_commit-only change: pushed, no regenerate commit ($(row outcome) $(git -C "$T/origin.git" log -1 --format=%s ticket/bh-9005))" \
  'pushed_merge && [ "$(git -C "$T/origin.git" log -1 --format=%s ticket/bh-9005 | cut -c1-10)" != regenerate ] && [ "$(row evidence.regenerated)" = "[]" ]'
eq "D5 the stamp is main's, byte for byte" "$(ofile docs/config-inventory/stamp.json)" "$STAMP0"
world drift; park "rebase-gate-red: x"; setting archie.fm.regen "docs/config-inventory/stamp.json=bash bin/inv-stamp.sh"; tick
check "D6 real drift beside the stamp still regenerates ($(ofile docs/config-inventory/stamp.json))" \
  'pushed_merge && ofile docs/config-inventory/stamp.json | jq -e ".files == [\"a.txt\",\"b.txt\",\"c.txt\"]" >/dev/null'

# ── F: a known-flaky suite is re-run once before blame ──────────────────────
world routes; printf '1\n0\n' > "$T/suite.rcs"; echo tests/flaky-x.sh > "$T/flaky.set"; tick
check "F1 flaky red then green: pushed, done, flaky_rerun named ($(row evidence.suites))" \
  'pushed_merge && [ "$(row outcome)" = done ] && [ "$(row evidence.flaky_rerun)" = "[\"tests/flaky-x.sh\"]" ] && [ "$(nruns)" = 2 ]'
world routes; printf '1\n1\n' > "$T/suite.rcs"; echo tests/flaky-x.sh > "$T/flaky.set"; tick
check "F2 red twice: requested, no push, exactly 2 runs ($(nruns))" \
  '[ "$(row outcome)" = requested ] && [ "$(pushes)" = 0 ] && [ "$(nruns)" = 2 ] && row evidence.diagnosis | grep -q "re-run once: still red"'
f3_world_ticked() { world routes; printf '1\n0\n' > "$T/suite.rcs"; echo tests/real-y.sh > "$T/suite.red"; echo tests/flaky-x.sh > "$T/flaky.set"; tick; }
f3_one_run() { [ "$(row outcome)" = requested ] && [ "$(nruns)" = 1 ] && [ "$(pushes)" = 0 ]; }
f3_world_ticked
check "F3 a red that is not a known flake: one run, blamed ($(nruns))" 'f3_one_run'
world routes; printf '1\n0\n' > "$T/suite.rcs"; : > "$T/flaky.down"; tick
check "F3b an unreadable flaky set is empty: one run, blamed" 'f3_one_run'
# F4: wave 1's restack meets a flaky red and re-runs it once.
world routes
G checkout -q main; G checkout -q -b ticket/bh-9001; echo 1 > "$W/p.txt"; G add -A; G commit -qm "parent 1"
PHEAD=$(git -C "$W" rev-parse HEAD)
G checkout -q -b ticket/bh-9002; echo child > "$W/c.txt"; G add -A; G commit -qm "child own"
G checkout -q main; G merge --squash ticket/bh-9001; G commit -qm "BH-9001 squash"
G push -q "$T/origin.git" main ticket/bh-9001 ticket/bh-9002
git -C "$T/repos/fixt" fetch -q origin
jq -n --arg c "$(git -C "$W" rev-parse ticket/bh-9002)" --arg p "$PHEAD" '[
  {number: 2, state: "open", html_url: "https://github.com/acme/fixt/pull/2", merged_at: null,
   head: {ref: "ticket/bh-9002", sha: $c, repo: {full_name: "acme/fixt"}}, base: {ref: "ticket/bh-9001"}},
  {number: 1, state: "closed", html_url: "https://github.com/acme/fixt/pull/1", merged_at: "2026-10-05T06:00:00Z",
   head: {ref: "ticket/bh-9001", sha: $p, repo: {full_name: "acme/fixt"}}, base: {ref: "main"}}]' > "$T/prs.json"
setting archie.cap.stacked-parent-merged 20; : > "$H/state/merge-conductor/pr-state.tsv"
printf '1\n0\n' > "$T/suite.rcs"; echo tests/flaky-x.sh > "$T/flaky.set"; : > "$T/order.log"
tick
check "F4 wave 1's restack: a flaky red is re-run once and the child is restacked ($(row playbook) $(row outcome), runs $(nruns))" \
  '[ "$(row playbook)/$(row outcome)" = stacked-parent-merged/done ] && [ "$(nruns)" = 2 ] && [ "$(pushes)" = 1 ]'

# ── R: the resolver's side ──────────────────────────────────────────────────
# afm_first, sourced with the fixture worker and the conductor row it reads.
cat > "$T/first.sh" <<SH
. "$DIR/bin/lib/archie-fm.sh"; . "$DIR/bin/lib/archie-fm-repair.sh"; . "$T/fx.sh"
mc_row_get() { awk -F'\t' -v k="\$1" '\$1==k {print; exit}' "$H/state/merge-conductor/pr-state.tsv"; }
setting_get() { local r v; r=\$(_jobs_req GET "/api/settings/\$1") || return \$?; v=\$(jq -r '.setting.value // empty' <<<"\$r"); [ -n "\$v" ] || return 2; printf '%s' "\$v"; }
SH
first() { HARNESS_TEST_SANDBOX=1 ARCHIE_FM_NOW="$NOW" bash -c '. "$1"; shift; afm_first "$@"' _ "$T/first.sh" fixt acme/fixt 5 "$HEAD5" > "$T/first.out" 2>/dev/null; echo $?; }
addrow() { # addrow <outcome> <action> <updated_at> [diagnosis]
  jq --arg h "$HEAD5" --arg d "$DAY" --arg o "$1" --arg a "$2" --arg u "$3" --arg g "${4:-}" '.actions += [{id: 1,
     dedupe_key: ("rebase-repair:acme/fixt#5:" + $h + ":on"), day: $d, project: "fixt", repo: "acme/fixt", pr: 5,
     playbook: "rebase-repair", mode: "on", action: $a, outcome: $o, why: "w", evidence: (if $g == "" then {} else {diagnosis: $g} end),
     attempts: 1, actor: "archie-fm", created_at: $u, updated_at: $u}]' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
}
YOUNG=$(date -u -d "@$((NOW - 60))" +%FT%TZ); OLD=$(date -u -d "@$((NOW - 5000))" +%FT%TZ)
world routes; park "conflict-unresolvable: x" "$HEAD5" $((NOW - 60))
eq "R1 no row and a young park: rc 3 (Archie first)" "$(first)" 3
park "conflict-unresolvable: x" "$HEAD5" $((NOW - 5000))
eq "R3 no row and an old park: rc 1 (today's round)" "$(first)" 1
park "conflict-unresolvable: x" "$HEAD5" $((NOW - 60)); setting archie.fm.first_s 0
eq "R3 first_s=0: never wait" "$(first)" 1
world routes; park "conflict-unresolvable: x" "$HEAD5" $((NOW - 60)); setting archie.manage observe
eq "R4 observe: rc 1" "$(first)" 1
setting archie.manage off
eq "R4 off: rc 1" "$(first)" 1
setting archie.manage on; : > "$T/route.absent"
eq "R4 the route absent (404): rc 1" "$(first)" 1
rm -f "$T/route.absent"; : > "$T/settings.down"
eq "R4 the settings unreadable: rc 1" "$(first)" 1
rm -f "$T/settings.down"; park "red-ci-twice" "$HEAD5" $((NOW - 60)); : > "$T/reqlog"
check "R4 a park Archie does not own: rc 1, and no request at all" '[ "$(first)" = 1 ] && [ ! -s "$T/reqlog" ]'
park "conflict-unresolvable: x" "$HEAD5" $((NOW - 60))
addrow requested fix_round "$YOUNG" "DIAG: bin/lib/x.sh x_fn both sides"
eq "R2 a requested row: rc 0" "$(first)" 0
eq "R2 ...and stdout is its diagnosis" "$(cat "$T/first.out")" "DIAG: bin/lib/x.sh x_fn both sides"
world routes; addrow done repair "$YOUNG"
eq "R5 a fresh done/repair row: rc 3 (the head is stale)" "$(first)" 3
world routes; addrow done repair "$OLD"
eq "R5 an old done/repair row: rc 1 (bounded)" "$(first)" 1
world routes; addrow done noop "$YOUNG"
eq "R5 done/noop: rc 1 (nothing was pushed)" "$(first)" 1
world routes; addrow started repair "$YOUNG"
eq "R5 started: rc 3" "$(first)" 3
# The started/deferred defer is bounded by the row's age, max(first_s,
# ARCHIE_FM_RETRY_S) + first_s (1800 + 1200 = 3000 s by default): a lane that
# stopped ticking must not hold the park forever.
STALE=$(date -u -d "@$((NOW - 3100))" +%FT%TZ)
world routes; addrow started repair "$STALE"
eq "R5 a stale started row: rc 1 (bounded)" "$(first)" 1
world routes; addrow deferred repair "$YOUNG"
eq "R5 deferred: rc 3" "$(first)" 3
world routes; addrow deferred repair "$STALE"
eq "R5 a stale deferred row: rc 1 (bounded)" "$(first)" 1
world routes; addrow started repair "not-a-time"
eq "R5 a started row with an unreadable updated_at: rc 1" "$(first)" 1
world routes; addrow deferred repair "$YOUNG"
eq "R5 the lane off (ARCHIE_FM_ENABLED=0): rc 1" "$(ARCHIE_FM_ENABLED=0 first)" 1
eq "R5 the lane off (lane_paused archie-fm): rc 1" \
  "$(HARNESS_TEST_SANDBOX=1 ARCHIE_FM_NOW="$NOW" bash -c '. "$1"; shift; lane_paused() { [ "$1" = archie-fm ]; }; afm_first "$@"' _ "$T/first.sh" fixt acme/fixt 5 "$HEAD5" >/dev/null 2>&1; echo $?)" 1
world routes; addrow failed repair "$YOUNG"
eq "R5 failed: rc 1" "$(first)" 1

# R6: br_fix_round's hub half, the REAL function bodies lifted out by name and
# run against stubs for everything around them.
extract() { awk -v f="^$1\\\\(\\\\) *\\\\{" '$0 ~ f {p=1} p{print} p&&/^}$/{exit}' "$2"; }
mkhub() { # mkhub <blocked-resolver.sh> -> $T/hub.sh
  { extract br_archie_first "$1"; extract br_fix_round "$1"
    cat <<SH
. "$T/first.sh"
OBSERVE=0; LOG=$T/hub.log
say() { printf 'say %s\n' "\$*" >> "$T/hub.log"; }
br_cap_key() { echo ck; }
br_load() { cat "$T/rec.json"; }
br_num() { echo 0; }
br_cap_rows() { echo "\$4"; }
br_fix_cap() { echo 1; }
br_ladder_class() { echo conflict; }
br_slug_of_url() { echo acme/fixt; }
mc_num_of_url() { echo 5; }
mc_row_field() { mc_row_get "\$1" | cut -f"\$2"; }
br_set_field() { jq -c --arg k "\$3" --arg v "\$4" '.[\$k] = \$v' "$T/rec.json" > "$T/rec.tmp" && mv "$T/rec.tmp" "$T/rec.json"; }
hub_box_builds_here() { return 1; }
br_fix_remote() { printf 'remote %s\n' "\$*" >> "$T/hub.log"; cp "$T/rec.json" "$T/rec.sent"; }
SH
  } > "$T/hub.sh"
}
hubround() { : > "$T/hub.log"; rm -f "$T/rec.sent"; echo '{"project":"fixt"}' > "$T/rec.json"
  HARNESS_TEST_SANDBOX=1 ARCHIE_FM_NOW="$NOW" bash -c '. "$1"; br_fix_round fixt TK-5 conflict-unresolvable https://github.com/acme/fixt/pull/5 - -' _ "$T/hub.sh" >/dev/null 2>&1; }
mkhub "$DIR/bin/blocked-resolver.sh"
check "R6 setup: br_archie_first and br_fix_round lifted out" 'grep -q "^br_archie_first()" "$T/hub.sh" && grep -q "^br_fix_round()" "$T/hub.sh"'
r6_young() { world routes; park "conflict-unresolvable: x" "$HEAD5" $((NOW - 60)); hubround; }
r6_young
check "R6/R1 the hub, a young park, no row: the round is not queued, nothing marked ($(tr '\n' '|' < "$T/hub.log"))" \
  'grep -q "Archie (archie-fm) is working head ${HEAD5:0:8} first; offered again next tick" "$T/hub.log" && ! grep -q "^remote " "$T/hub.log" && [ "$(cat "$T/rec.json")" = "{\"project\":\"fixt\"}" ]'
world routes; park "conflict-unresolvable: x" "$HEAD5" $((NOW - 60)); addrow requested fix_round "$YOUNG" "DIAG-R6"; hubround
check "R6/R2 the hub, a requested row: queued, and the copy it hands the box carries the diagnosis and its head" \
  'grep -q "^remote fixt TK-5 " "$T/hub.log" && [ "$(jq -r .archie_diagnosis "$T/rec.sent")" = DIAG-R6 ] && [ "$(jq -r .archie_diagnosis_head "$T/rec.sent")" = "$HEAD5" ]'
world routes; park "conflict-unresolvable: x" "$HEAD5" $((NOW - 5000)); hubround
check "R6/R3 the hub, an old park, no row: today's round, no diagnosis" \
  'grep -q "^remote " "$T/hub.log" && [ "$(jq -r ".archie_diagnosis // \"none\"" "$T/rec.sent")" = none ]'

# R2 through the production entry: `blocked-resolver.sh --fix-here`, the way
# bin/fix-round-claim.sh runs a hopped round, with the record on stdin. The
# agent stub keeps the prompt it was handed.
# The fixture lib assigns T and H and exports PATH, GIT_CONFIG_GLOBAL,
# FLEET_CONF and GH_TOKEN, so all of it is saved here and put back after X4.
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
SAVE_T=$T; SAVE_H=$H; SAVE_PATH=$PATH; SAVE_HARNESS=$HARNESS
FT="$T/fh"; mkdir -p "$FT"
H="$FT/h"; mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/merge-conductor.sh" \
   "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$FT" || bad "R2 setup: fx_br_harness"
# fx_br_harness runs br_modules_install, so bin/lib/br/ travels with the copy.
[ -d "$H/bin/lib/br" ] || bad "R2 setup: bin/lib/br/ was not installed beside the copied lane"
scratch_install_closure bin/blocked-resolver.sh "$H" >/dev/null || exit 1
cp "$DIR/bin/lib/archie-fm-union.py" "$H/bin/lib/" || exit 1
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
fx_br_ladder_git "$DIR" "$FT" || bad "R2 setup: fx_br_ladder_git"
printf '#!/bin/bash\nprintf "%%s" "$6" > "%s/prompt.txt"\nexit 0\n' "$FT" > "$H/bin/agent-call.sh"
chmod +x "$H/bin/agent-call.sh"; printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
fixhere() { # fixhere <script> <record-json>
  rm -f "$FT/prompt.txt"; scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/tmp/brfix"
  git -C "$FT/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$FT/repos/tproj" for-each-ref --format='%(refname:short)' refs/heads/brfix/ \
    | while read -r b; do git -C "$FT/repos/tproj" branch -D "$b" >/dev/null 2>&1; done
  printf 'ticket/TK-91\n' > "$FT/prbranch"; osha ticket/TK-91 | tr -d '\n' > "$FT/prhead"
  printf '%s' "$2" > "$FT/rec-in.json"
  ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$FT/repos" BOX_NAME=box-tproj \
    bash "$1" --fix-here tproj dqw-1-abc conflict-unresolvable https://github.com/o/tproj/pull/91 - - < "$FT/rec-in.json" ) >"$FT/fh.out" 2>>"$FT/run.log"
}
PRH=$(osha ticket/TK-91 2>/dev/null | tr -d '\n')
DIAGTXT="--- bin/lib/x.sh --- shape: both sides changed the same base lines; in: x_fn() {"
REC=$(jq -nc --arg d "$DIAGTXT" --arg h "$PRH" '{project:"tproj",rkey:"dqw-1-abc",fixrounds:0,rebuilds:0,mechanicals:0,outcome:"",attempts:[],archie_diagnosis:$d,archie_diagnosis_head:$h}')
r2_has() { [ -s "$FT/prompt.txt" ] && grep -qF "ARCHIE'S DIAGNOSIS (bin/archie-fm.sh, deterministic, no model):" "$FT/prompt.txt" && grep -qF -- "$DIAGTXT" "$FT/prompt.txt"; }
fixhere "$H/bin/blocked-resolver.sh" "$REC"
check "R2 --fix-here: the round reached the agent ($(tail -2 "$H/logs/blocked-resolver.log" 2>/dev/null | tr '\n' '|'))" '[ -s "$FT/prompt.txt" ]'
check "R2 --fix-here: the prompt carries ARCHIE'S DIAGNOSIS and its text" 'r2_has'
REC2=$(jq -c '.archie_diagnosis_head = "2222222222222222222222222222222222222222"' <<<"$REC")
fixhere "$H/bin/blocked-resolver.sh" "$REC2"
check "R2 --fix-here: a diagnosis about another head is not used" '[ -s "$FT/prompt.txt" ] && ! grep -qF "ARCHIE'"'"'S DIAGNOSIS" "$FT/prompt.txt"'
# X4 (with the X block's other mutations below, but it needs this fixture):
# the resolver's append of the diagnosis deleted turns R2 red.
cat > "$FT/x4.py" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = '    && brief="$brief"$\'\\n\\n\'"ARCHIE\'S DIAGNOSIS'
assert a in s, 'the append line is not in bin/blocked-resolver.sh'
open(sys.argv[2], 'w').write(s.replace(a, '    && true || brief="$brief"$\'\\n\\n\'"ARCHIE\'S DIAGNOSIS'))
PY
python3 "$FT/x4.py" "$DIR/bin/blocked-resolver.sh" "$H/bin/blocked-resolver.mut.sh" 2>"$FT/x4.err" || bad "X4 mutation not applied ($(cat "$FT/x4.err"))"
if [ -f "$H/bin/blocked-resolver.mut.sh" ] && ! cmp -s "$H/bin/blocked-resolver.mut.sh" "$DIR/bin/blocked-resolver.sh"; then
  fixhere "$H/bin/blocked-resolver.mut.sh" "$REC"
  [ -s "$FT/prompt.txt" ] || bad "X4 the mutant's round never reached the agent (the kill would be vacuous)"
  if [ -s "$FT/prompt.txt" ] && ! r2_has; then ok "X4 RED: without the append R2 loses the diagnosis"; else bad "X4 deleting the append must break R2"; fi
fi
T=$SAVE_T; H=$SAVE_H; PATH=$SAVE_PATH; HARNESS=$SAVE_HARNESS
unset GIT_CONFIG_GLOBAL FLEET_CONF
export PATH HARNESS FXT="$T"

# ── G1: the digest line ─────────────────────────────────────────────────────
jq -n --arg d "$DAY" '{day: $d, factory_manager: {ok: true, day: $d, total: 3, restacked: 0, repaired: 1, fix_rounds: 1, would: 1, deferred: 0, failed: 0}}' > "$T/g1.json"
jq -n --arg d "$DAY" '{day: $d, factory_manager: {ok: true, day: $d, total: 1, restacked: 1, fix_rounds: 0, would: 0, deferred: 0, failed: 0}}' > "$T/g0.json"
dd() { bash -c '. "$1"; dd_render "$2" https://console.test - 0 5 -' _ "$DIR/bin/lib/daily-digest-render.sh" "$1" | grep '^Factory manager'; }
eq "G1 the digest counts repaired" "$(dd "$T/g1.json")" "Factory manager: 3 actions (0 restacked, 1 repaired, 1 fix rounds asked, 1 would-do in observe, 0 deferred, 0 failed) https://console.test/"
eq "G1 a pre-BH-4585 summary still renders, repaired 0" "$(dd "$T/g0.json")" "Factory manager: 1 actions (1 restacked, 0 repaired, 0 fix rounds asked, 0 would-do in observe, 0 deferred, 0 failed) https://console.test/"

# ═════ X: mutations, each must turn its case red ═════════════════════════════
mutate() { # mutate <file under bin/> <python-expr over s>
  rm -f "$H/bin/$1"
  python3 -c "import sys; s=open(sys.argv[1]).read(); $2; open(sys.argv[2],'w').write(s)" "$DIR/bin/$1" "$H/bin/$1"
  cmp -s "$H/bin/$1" "$DIR/bin/$1" && { echo "mutation did not change bin/$1"; return 1; }
  return 0
}
restore() { rm -f "$H/bin/$1"; ln -s "$DIR/bin/$1" "$H/bin/$1"; }
# X1: T1 accepts B != P+S. U2's case resolves, and C6d pushes.
if mutate lib/archie-fm-union.py 's=s.replace("if b != p + sfx:\n            raise Refuse", "if False:\n            raise Refuse")'; then
  python3 "$H/bin/lib/archie-fm-union.py" resolve "$T/u2" src/i.js >/dev/null 2>&1; rc=$?
  ( git -C "$T/u2" checkout -q -m -- src/i.js ) 2>/dev/null
  c6d_world_ticked
  if [ "$rc" = 0 ] || ! c6_fix_round; then ok "X1 RED: accepting B != P+S breaks U2/C6d"; else bad "X1 accepting B != P+S must break U2 or C6d"; fi
else bad "X1 mutation not applied"; fi
restore lib/archie-fm-union.py
# X2: the flaky check skipped: F3 re-runs a real red.
if mutate lib/archie-fm-repair.sh 's=s.replace("tr \x27 \x27 \x27\\n\x27 <<<\"$AFM_SUITES_RED\" | flaky_all_known \"$slug\" 2>/dev/null || return 1", "true || return 1")'; then
  f3_world_ticked
  if f3_one_run; then bad "X2 skipping the flaky check must break F3"; else ok "X2 RED: skipping the flaky check breaks F3"; fi
else bad "X2 mutation not applied"; fi
restore lib/archie-fm-repair.sh
# X3: a refused push closed as if it had landed: C9b.
if mutate lib/archie-fm-repair.sh 's=s.replace("AFM_RR_WHY=\"the push was refused (lease or hold); nothing pushed\"; return 4", "return 0")'; then
  c9b_world_ticked
  if [ "$(row outcome)" = deferred ]; then bad "X3 'done' without the push must break C9b"; else ok "X3 RED: done without a landed push breaks C9b"; fi
else bad "X3 mutation not applied"; fi
restore lib/archie-fm-repair.sh
# X7: the started/deferred defer unbounded again: R5's stale row holds the park.
if mutate lib/archie-fm-repair.sh 's=s.replace("[ $((now - ts)) -lt $((retry + first)) ] && return 3\n      return 1 ;;", "true; return 3 ;;")'; then
  world routes; park "conflict-unresolvable: x" "$HEAD5" $((NOW - 60)); addrow deferred repair "$STALE"
  r=$(HARNESS_TEST_SANDBOX=1 ARCHIE_FM_NOW="$NOW" bash -c '. "$1"; . "$2"; afm_first fixt acme/fixt 5 "$3"' _ "$T/first.sh" "$H/bin/lib/archie-fm-repair.sh" "$HEAD5" >/dev/null 2>&1; echo $?)
  if [ "$r" = 3 ]; then ok "X7 RED: without the bound a stale deferred row defers the park forever"; else bad "X7 removing the bound must break R5 (got rc $r)"; fi
else bad "X7 mutation not applied"; fi
restore lib/archie-fm-repair.sh
# X4 ran with R2 above, in the --fix-here fixture.
# X5: one_pr never asks afm_rr_classify: C1 goes red (the production call site, D2).
if mutate archie-fm.sh 's=s.replace("if afm_rr_classify \"$p\" \"$slug\" \"$pr\"; then", "if false; then")'; then
  c1_world_ticked
  if c1_repaired; then bad "X5 removing the call site must break C1"; else ok "X5 RED: without the call site C1 repairs nothing"; fi
else bad "X5 mutation not applied"; fi
restore archie-fm.sh
# X6: br_fix_round never asks Archie: R6/R1 queues the round at once.
sed 's/&& command -v br_archie_first >\/dev\/null 2>&1/\&\& false/' "$DIR/bin/blocked-resolver.sh" > "$T/br-x6.sh"
if cmp -s "$T/br-x6.sh" "$DIR/bin/blocked-resolver.sh"; then bad "X6 mutation not applied"
else
  mkhub "$T/br-x6.sh"; r6_young
  if grep -q "^remote " "$T/hub.log"; then ok "X6 RED: without the call br_fix_round queues a round Archie is still on"; else bad "X6 removing the call must break R6/R1"; fi
fi
check "X the restored libs are the shipped ones" \
  '[ "$(readlink "$H/bin/lib/archie-fm-repair.sh")" = "$DIR/bin/lib/archie-fm-repair.sh" ] && [ "$(readlink "$H/bin/archie-fm.sh")" = "$DIR/bin/archie-fm.sh" ] && [ "$(readlink "$H/bin/lib/archie-fm-union.py")" = "$DIR/bin/lib/archie-fm-union.py" ]'

echo "archie-fm-conflicts: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
