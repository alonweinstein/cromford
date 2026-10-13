#!/bin/bash
# tests/secret-read-guard.bh-3689-test.sh — the env/secret read tripwire, driven.
#
# BH-3689. On 2026-09-29 a review subagent grepped env/global.env and printed
# HARNESS_SECRET into its transcript. bin/secret-read-guard.py is a PreToolUse
# hook on Read|Grep|Bash that denies the obvious print verbs on env and secret
# files. This suite feeds the REAL hook real PreToolUse payloads on stdin and
# reads back its exit code, its stderr, and the argv a stub alert-line.sh was
# spawned with. The installer is run for real against real settings files, and
# the canonical box settings are read as parsed JSON.
#
# What must stay true:
#   1. Read/Grep/Bash reads of the listed secret paths are DENIED (rc 2)
#   2. `set -a; . env/…; set +a` and ordinary work are ALLOWED (rc 0)
#   3. every denial is logged with tool + path, never the pattern or content,
#      and the log spawn never holds the verdict up
#   4. a broken payload never blocks the fleet (rc 0 + a logged line)
#   5. rules/settings.json carries the hook and the installer merges it once
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

GUARD="$DIR/bin/secret-read-guard.py"
INSTALL="$DIR/bin/secret-read-guard-install.sh"

# A harness root whose env/ is a symlink to a real dir elsewhere — the box
# shape (/root/harness/env -> /etc/harness/env).
H="$T/h"; HM="$T/home"
mkdir -p "$H/bin" "$H/logs" "$T/realenv" "$HM/.orgo" "$HM/.aikido" "$T/work"
ln -s "$T/realenv" "$H/env"
echo 'HARNESS_SECRET=FIXTURE_VALUE_123' > "$T/realenv/global.env"
echo 'tok' > "$T/realenv/github-token"
echo 'machine x password FIXTURE_VALUE_123' > "$HM/.netrc"
echo 'https://u:FIXTURE_VALUE_123@github.com' > "$HM/.git-credentials"
echo 'k' > "$HM/.orgo/credentials"
echo 'k' > "$HM/.aikido/token"
# The stub alert-line records its argv, one arg per line, then a separator.
cat > "$H/bin/alert-line.sh" <<'STUB'
#!/bin/bash
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
{ printf '%s\n' "$@"; echo '--'; } >> "$HARNESS/alert-args"
STUB
chmod +x "$H/bin/alert-line.sh"

# guard <json payload> — prints the rc; stderr lands in $T/err.
guard() {
  printf '%s' "$1" | timeout 15 env HARNESS="$H" HOME="$HM" HARNESS_LANE=execute \
    "$GUARD" >/dev/null 2>"$T/err"
  echo $?
}
bashp() { jq -nc --arg c "$1" --arg d "${2:-$H}" '{hook_event_name:"PreToolUse",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}'; }
readp() { jq -nc --arg f "$1" --arg d "$H" '{hook_event_name:"PreToolUse",cwd:$d,tool_name:"Read",tool_input:{file_path:$f}}'; }
grepp() { jq -nc --arg p "$1" --arg g "${2:-}" --arg d "$H" '{hook_event_name:"PreToolUse",cwd:$d,tool_name:"Grep",tool_input:({pattern:"SEKRETPATTERN",path:$p} + (if $g=="" then {} else {glob:$g} end))}'; }
# Wait (bounded) for the detached stub to have written something.
wait_args() { local i; for i in $(seq 1 50); do [ -s "$H/alert-args" ] && return 0; sleep 0.1; done; return 1; }

expect() { # expect <want-rc> <label> <payload>
  local rc; rc=$(guard "$3")
  if [ "$rc" = "$1" ]; then ok; else bad "$2: want rc=$1 got rc=$rc ($(head -c 300 "$T/err"))"; fi
}

# --- A1: grep X env/global.env is denied, stderr names the path, no content ---
rc=$(guard "$(bashp 'grep X env/global.env')")
[ "$rc" = 2 ] && ok || bad "A1 grep X env/global.env not denied (rc=$rc)"
grep -q 'env/global.env' "$T/err" && ok || bad "A1 stderr does not name env/global.env: $(cat "$T/err")"
grep -q 'set -a' "$T/err" && ok || bad "A1 stderr does not tell the model how to source instead"
grep -q FIXTURE_VALUE_123 "$T/err" && bad "A1 stderr carries file content" || ok

# --- A2: cat ~/.netrc ----------------------------------------------------------
expect 2 "A2 cat ~/.netrc" "$(bashp 'cat ~/.netrc')"
expect 2 "A2 cat \$HOME/.netrc" "$(bashp 'cat $HOME/.netrc')"

# --- A3: sourcing stays allowed, and files no alert -----------------------------
rm -f "$H/alert-args"
expect 0 "A3 . env/global.env" "$(bashp '. env/global.env')"
expect 0 "A3 set -a; . env/…; set +a" "$(bashp 'set -a; . env/global.env; set +a')"
expect 0 "A3 source /etc-style env" "$(bashp "source $T/realenv/global.env")"
sleep 0.5
[ -e "$H/alert-args" ] && bad "A3 an allowed source spawned an alert: $(cat "$H/alert-args")" || ok

# --- A4: a normal source file is readable -------------------------------------
expect 0 "A4 Read bin/alert-line.sh" "$(readp "$DIR/bin/alert-line.sh")"
expect 0 "A4 Read README" "$(readp "$DIR/README.md")"

# --- A5: Read and Grep tools on secrets -----------------------------------------
expect 2 "A5 Read env/global.env (relative)" "$(readp 'env/global.env')"
expect 2 "A5 Read env/global.env (abs)" "$(readp "$H/env/global.env")"
expect 2 "A5 Grep path env/global.env" "$(grepp 'env/global.env')"
expect 2 "A5 Grep path env" "$(grepp 'env')"
expect 2 "A5 Grep glob *.env" "$(grepp "$DIR" '*.env')"
expect 2 "A5 Grep glob .netrc" "$(grepp "$HM" '.netrc')"

# --- A6: the path-class matrix ----------------------------------------------------
expect 2 "A6 .git-credentials" "$(bashp 'head -5 ~/.git-credentials')"
expect 2 "A6 ~/.orgo/credentials" "$(bashp 'sed -n 1p ~/.orgo/credentials')"
expect 2 "A6 ~/.aikido/token" "$(bashp 'tail ~/.aikido/token')"
expect 2 "A6 Read ~/.aikido/token" "$(readp '~/.aikido/token')"
expect 2 "A6 github-app.pem" "$(bashp 'cat /root/harness/env/github-app.pem')"
expect 2 "A6 github-app.pem anywhere" "$(bashp 'cat /tmp/github-app.pem')"
expect 2 "A6 *.private-key.pem" "$(bashp 'cat foo.2026-09-30.private-key.pem')"
expect 2 "A6 any .env" "$(bashp 'cat /srv/app/.env')"
expect 2 "A6 non-.env file inside the symlinked secret dir" "$(bashp 'cat env/github-token')"
expect 2 "A6 same file by its real path" "$(bashp "cat $T/realenv/github-token")"
expect 2 "A6 recursive grep of the secret dir" "$(bashp 'grep -r X env/')"
expect 2 "A6 redirect from a secret" "$(bashp 'while read l; do :; done < env/global.env')"
expect 2 "A6 \$HARNESS expanded" "$(bashp 'cat $HARNESS/env/global.env' "$T/work")"
expect 2 "A6 grep -e PATTERN secret" "$(bashp 'grep -e X env/global.env')"
expect 2 "A6 awk" "$(bashp "awk '{print}' env/global.env")"
expect 2 "A6 subshell" "$(bashp 'echo $(cat env/global.env)')"

# --- A7: wrappers and pipelines ---------------------------------------------------
expect 2 "A7 rtk grep" "$(bashp 'rtk grep X env/global.env')"
expect 2 "A7 rtk proxy cat" "$(bashp 'rtk proxy cat env/global.env')"
expect 2 "A7 sudo cat" "$(bashp 'sudo cat env/global.env')"
expect 2 "A7 FOO=1 head" "$(bashp 'FOO=1 head env/global.env')"
expect 2 "A7 cat | grep" "$(bashp 'cat env/global.env | grep X')"
expect 2 "A7 cat env/*" "$(bashp 'cat env/*')"
expect 2 "A7 after &&" "$(bashp 'cd /tmp && /bin/cat ~/.netrc')"
expect 2 "A7 timeout 5 cat" "$(bashp 'timeout 5 cat env/global.env')"
expect 2 "A7 on a second line" "$(bashp $'ls\ncat env/global.env')"

# --- A8: the adversarial negatives are allowed -------------------------------------
while IFS= read -r CMD; do
  [ -n "$CMD" ] || continue
  expect 0 "A8 $CMD" "$(bashp "$CMD" "$DIR")"
done <<'NEG'
grep -rn HARNESS_SECRET bin/
grep -rn global.env bin/
grep -n '\.env' README.md
echo "cat env/global.env"
ls env/
test -f ~/.netrc
cat env-templates/project.env.example
cat bin/lib/env-path.sh
git log -- env
sed -n 1,5p fleet.conf
echo x > out.env
NEG
expect 0 "A8 Grep tool over bin/ with no glob" "$(grepp "$DIR/bin")"
expect 0 "A8 some other tool" "$(jq -nc '{tool_name:"Edit",cwd:"/tmp",tool_input:{file_path:"/tmp/x.env"}}')"

# --- A9: logging carries tool + path, never pattern or content -------------------
rm -f "$H/alert-args"
expect 2 "A9 cat ~/.netrc" "$(bashp 'cat ~/.netrc')"
wait_args && ok || bad "A9 no alert-line spawned for a denial"
A=$(cat "$H/alert-args" 2>/dev/null)
grep -q 'secret-read-guard denied Bash cat' <<<"$A" && ok || bad "A9 alert text lacks tool+verb: $A"
grep -qF "$HM/.netrc" <<<"$A" && ok || bad "A9 alert text lacks the path: $A"
grep -qx -- '--severity' <<<"$A" && grep -qx warn <<<"$A" && ok || bad "A9 alert not --severity warn: $A"
rm -f "$H/alert-args"
expect 2 "A9 grep SEKRETPATTERN" "$(bashp 'grep SEKRETPATTERN env/global.env')"
wait_args && ok || bad "A9 no alert-line spawned for the grep denial"
A=$(cat "$H/alert-args" 2>/dev/null)
grep -q 'secret-read-guard denied Bash grep' <<<"$A" && ok || bad "A9 grep alert text lacks tool+verb: $A"
grep -q SEKRETPATTERN <<<"$A" && bad "A9 alert carries the grep pattern: $A" || ok
grep -q FIXTURE_VALUE_123 <<<"$A" && bad "A9 alert carries file content: $A" || ok
rm -f "$H/alert-args"
expect 2 "A9 Grep tool" "$(grepp 'env/global.env')"
wait_args && ok || bad "A9 no alert for the Grep tool denial"
A=$(cat "$H/alert-args" 2>/dev/null)
grep -q 'secret-read-guard denied Grep' <<<"$A" && ok || bad "A9 Grep alert text lacks tool: $A"
grep -q SEKRETPATTERN <<<"$A" && bad "A9 Grep alert carries the pattern: $A" || ok
# The Mac shape: no $HARNESS/logs, so the line lands in ~/.claude/logs.
M="$T/mac"; mkdir -p "$M/bin"; cp "$H/bin/alert-line.sh" "$M/bin/"
rc=$(printf '%s' "$(bashp 'grep SEKRETPATTERN ~/.netrc' /tmp)" | timeout 15 env HARNESS="$M" HOME="$HM" "$GUARD" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] && ok || bad "A9 mac-shape deny rc=$rc"
MLOG="$HM/.claude/logs/secret-read-guard.log"
grep -q "secret-read-guard denied Bash grep $HM/.netrc" "$MLOG" 2>/dev/null && ok || bad "A9 mac fallback log missing the line: $(cat "$MLOG" 2>&1)"
grep -q SEKRETPATTERN "$MLOG" 2>/dev/null && bad "A9 mac log carries the pattern" || ok
[ -e "$M/alert-args" ] && bad "A9 mac shape still called alert-line" || ok

# --- A10: degrade never blocks ------------------------------------------------------
rm -f "$H/alert-args"
expect 0 "A10 empty stdin" ""
wait_args && ok || bad "A10 empty stdin logged nothing"
grep -q 'secret-read-guard INERT' "$H/alert-args" 2>/dev/null && ok || bad "A10 empty-stdin line not INERT: $(cat "$H/alert-args" 2>&1)"
[ "$(grep -c '^--$' "$H/alert-args" 2>/dev/null)" = 1 ] && ok || bad "A10 empty stdin logged other than one line"
expect 0 "A10 non-JSON" "not json at all"
expect 0 "A10 no tool_name" '{"cwd":"/tmp","tool_input":{"file_path":"env/global.env"}}'
# CRASH: a payload shape the judge cannot handle fails closed only when the raw
# text names a secret-looking path.
expect 2 "A10 crash near a secret denies" '{"tool_name":"Read","cwd":"/tmp","tool_input":"env/global.env"}'
expect 0 "A10 crash elsewhere allows" '{"tool_name":"Read","cwd":"/tmp","tool_input":"README.md"}'

# --- A11: the canonical box settings carry the hook ----------------------------------
S="$DIR/rules/settings.json"
jq -e '.hooks.PreToolUse[] | select(.matcher=="Read|Grep|Bash") | .hooks[] | select(.command=="/root/harness/bin/secret-read-guard.py")' "$S" >/dev/null \
  && ok || bad "A11 rules/settings.json has no Read|Grep|Bash secret-read-guard entry"
jq -e '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.command=="/usr/local/bin/rtk hook claude")' "$S" >/dev/null \
  && ok || bad "A11 rules/settings.json lost the rtk entry"
[ -x "$GUARD" ] && ok || bad "A11 bin/secret-read-guard.py is not executable"

# --- A12: the installer --------------------------------------------------------------
cp "$S" "$T/s.json"
bash "$INSTALL" --settings "$T/s.json" >/dev/null 2>&1; r1=$?
bash "$INSTALL" --settings "$T/s.json" >/dev/null 2>&1; r2=$?
[ "$r1$r2" = 00 ] && ok || bad "A12 installer rc=$r1,$r2"
n=$(jq '[.hooks.PreToolUse[].hooks[] | select(.command|endswith("/bin/secret-read-guard.py"))] | length' "$T/s.json")
[ "$n" = 1 ] && ok || bad "A12 want exactly 1 guard entry after two runs, got $n"
jq -e --arg c "$DIR/bin/secret-read-guard.py" '.hooks.PreToolUse[] | select(.matcher=="Read|Grep|Bash") | .hooks[] | select(.command==$c and .timeout==10)' "$T/s.json" >/dev/null \
  && ok || bad "A12 installed entry is not the checkout's guard: $(jq -c .hooks.PreToolUse "$T/s.json")"
jq -e '.hooks.PreToolUse[] | .hooks[] | select(.command=="/usr/local/bin/rtk hook claude")' "$T/s.json" >/dev/null \
  && ok || bad "A12 installer dropped the rtk entry"
jq -e '.theme=="dark" and .enabledPlugins' "$T/s.json" >/dev/null && ok || bad "A12 installer dropped unrelated keys"
ls "$T"/s.json.bak-* >/dev/null 2>&1 && ok || bad "A12 no .bak-* backup written"
bash "$INSTALL" --settings "$T/new/dir/s.json" >/dev/null 2>&1; r=$?
[ "$r" = 0 ] && jq -e --arg c "$DIR/bin/secret-read-guard.py" '.hooks.PreToolUse[0].hooks[0].command==$c' "$T/new/dir/s.json" >/dev/null \
  && ok || bad "A12 missing file not created with the entry (rc=$r)"
printf '{ not json' > "$T/broken.json"; cp "$T/broken.json" "$T/broken.orig"
bash "$INSTALL" --settings "$T/broken.json" >/dev/null 2>&1; r=$?
[ "$r" = 1 ] && ok || bad "A12 unparseable JSON rc=$r, want 1"
cmp -s "$T/broken.json" "$T/broken.orig" && ok || bad "A12 unparseable JSON file was modified"
# The installed settings drive the real hook: its command, run as written, denies.
CMD=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Read|Grep|Bash") | .hooks[0].command' "$T/s.json")
rc=$(printf '%s' "$(bashp 'cat ~/.netrc')" | timeout 15 env HARNESS="$H" HOME="$HM" sh -c "$CMD" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] && ok || bad "A12 the installed command did not deny (rc=$rc)"

# --no-backup (the Fly call site) installs the same entry and leaves no .bak.
mkdir -p "$T/nb"; cp "$S" "$T/nb/s.json"
bash "$INSTALL" --settings "$T/nb/s.json" --no-backup >/dev/null 2>&1; r=$?
[ "$r" = 0 ] && jq -e --arg c "$DIR/bin/secret-read-guard.py" '.hooks.PreToolUse[] | .hooks[] | select(.command==$c)' "$T/nb/s.json" >/dev/null \
  && ok || bad "A12 --no-backup did not install (rc=$r)"
ls "$T"/nb/s.json.bak-* >/dev/null 2>&1 && bad "A12 --no-backup still wrote a .bak" || ok
grep -q 'secret-read-guard-install.sh" --settings /root/.claude/settings.json --no-backup' "$DIR/fly/builder-runner.sh" \
  && ok || bad "A12 fly/builder-runner.sh does not pass --no-backup"

# --- A14: heredoc bodies are stdin, not commands; a tokenize failure is not a CRASH ---
rm -f "$H/alert-args"
expect 0 "A14 heredoc body naming a secret read" "$(bashp $'cat > /tmp/note.md <<\'EOF\'\ncat env/global.env\nEOF')"
expect 0 "A14 apostrophe heredoc" "$(bashp $'cat > /tmp/x <<EOF\nit\'s fine\nEOF')"
expect 0 "A14 apostrophe heredoc mentioning .env" "$(bashp $'cat > /tmp/x <<EOF\nit\'s about .env files\nEOF')"
expect 0 "A14 <<- heredoc with tab-indented body" "$(bashp $'cat > /tmp/x <<-EOF\n\tcat env/global.env\n\tEOF')"
expect 0 "A14 unbalanced quote, no secret" "$(bashp "echo it's fine")"
sleep 0.5
[ -e "$H/alert-args" ] && bad "A14 an allowed heredoc/tokenize-failure spawned an alert: $(cat "$H/alert-args")" || ok
expect 2 "A14 the << line itself is still judged" "$(bashp $'cat env/global.env <<EOF\nx\nEOF')"
expect 2 "A14 a command after the terminator is judged" "$(bashp $'cat > /tmp/x <<EOF\nhi\nEOF\ncat env/global.env')"
expect 2 "A14 unbalanced quote does not hide a later read" "$(bashp "echo it's; cat env/global.env")"
expect 2 "A14 unterminated << is judged as written" "$(bashp $'cat <<EOF\ncat env/global.env')"
grep -q CRASH "$H/alert-args" 2>/dev/null && bad "A14 a tokenize failure was logged as CRASH: $(cat "$H/alert-args")" || ok

# --- A13: a slow alert-line never holds the verdict ----------------------------------
start=$(date +%s)
rc=$(printf '%s' "$(bashp 'cat ~/.netrc')" | STUB_SLEEP=20 timeout 15 env HARNESS="$H" HOME="$HM" "$GUARD" >/dev/null 2>&1; echo $?)
el=$(( $(date +%s) - start ))
[ "$rc" = 2 ] && [ "$el" -lt 10 ] && ok || bad "A13 deny with a 20s alert-line took ${el}s rc=$rc"

echo "secret-read-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
