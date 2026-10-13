#!/bin/bash
# tests/load-project-newline-test.sh — the registry append must never glue the
# new row onto the last one.
#
# THE INCIDENT THIS PINS (harness-console onto cromford, 2026-09-16, hand
# split in 00a9911). fleet.conf's last byte was not a newline, so the registry
# step's `printf ... >> fleet.conf` landed the new row on the END of the last
# one: the old row's box column read "box-smallharness-console", the
# new project had no row at all, and the loader committed it, pushed it and
# exited 0. Everything behind bin/fleet-conf.sh then read a fleet that was
# missing one project and lying about another.
#
# Every assertion here is on ARTIFACTS — the bytes of fleet.conf and what
# bin/fleet-conf.sh reads back out of it — and the real bin/load-project.sh is
# driven end to end (D2/D3). Nothing touches a real box: gh and the network
# verbs of git are stubs on a prepended PATH, and the whole fleet lives in $T.
#
# Run from anywhere: tests/load-project-newline-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

REAL_GIT=$(command -v git); export REAL_GIT

# ── stubs: gh, and the network verbs of git ─────────────────────────────────
mkdir -p "$T/stub"
cat > "$T/stub/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *defaultBranchRef.name*) echo main ;;
  "repo view"*)            echo "{}" ;;
  *)                       echo "[]" ;;
esac
exit 0
STUB
cat > "$T/stub/git" <<'STUB'
#!/bin/bash
# Only pull/push/fetch are faked: everything else is the REAL git against the
# scratch checkout, so the commit the loader makes is a real commit.
case "$1" in
  pull|push|fetch) exit 0 ;;
  rev-parse) case "$*" in *origin/*) exec "$REAL_GIT" rev-parse HEAD ;; esac ;;
esac
exec "$REAL_GIT" "$@"
STUB
chmod +x "$T/stub/gh" "$T/stub/git"

ROW_A='alpha         Acme/alpha                 -                                    -   2  box-small'
ROW_B='beta          Acme/beta                  -                                    -   4  box-small'

mkrepo() { # mkrepo <dir> <fleet.conf file> — a scratch cromford checkout
  local R="$1" CONF="$2"
  mkdir -p "$R/prompts"
  cp -r "$DIR/bin" "$R/bin"
  cp "$DIR/prompts/TEMPLATE-GH.md" "$R/prompts/TEMPLATE-GH.md"
  cp "$CONF" "$R/fleet.conf"
  (
    cd "$R" || exit 1
    "$REAL_GIT" init -q .
    "$REAL_GIT" config user.email t@t
    "$REAL_GIT" config user.name t
    "$REAL_GIT" add -A
    "$REAL_GIT" commit -qm base
  ) >/dev/null 2>&1
}

load() { # load <repo dir> [args...] — run the real loader, capture rc + output
  local R="$1"; shift
  ( cd "$R" && PATH="$T/stub:$PATH" HARNESS="$T/h" bash bin/load-project.sh "$@" ) >"$T/out" 2>&1
  echo $?
}

rows() { awk 'END{print NR}' "$1"; }   # counts an unterminated last line too
conf() { FLEET_CONF="$2" "$1/bin/fleet-conf.sh" "${@:3}" 2>/dev/null; }

# ── A. the incident: fleet.conf with NO trailing newline ────────────────────
printf '%s\n%s' "$ROW_A" "$ROW_B" > "$T/confA"
mkrepo "$T/a" "$T/confA"
BEFORE=$(rows "$T/a/fleet.conf")
RC=$(load "$T/a" acme/widget --project widget --box zzz-box --no-bootstrap)
eq "A rc" "$RC" "0"
eq "A row count" "$(rows "$T/a/fleet.conf")" "$((BEFORE + 1))"
eq "A the old last row is untouched" "$(tail -2 "$T/a/fleet.conf" | head -1)" "$ROW_B"
case "$(tail -1 "$T/a/fleet.conf")" in
  'widget '*) ok ;;
  *) bad "A the new row must start its own line, got '$(tail -1 "$T/a/fleet.conf")'" ;;
esac
eq "A no blank line was introduced" "$(grep -c '^$' "$T/a/fleet.conf")" "0"
# the columns the glue corrupts, read back through the production reader
eq "A beta offset"  "$(conf "$T/a" "$T/a/fleet.conf" beta offset)"  "4"
eq "A beta box"     "$(conf "$T/a" "$T/a/fleet.conf" beta box)"     "box-small"
eq "A widget offset" "$(conf "$T/a" "$T/a/fleet.conf" widget offset)" "1"
eq "A widget repo"   "$(conf "$T/a" "$T/a/fleet.conf" widget repo)"   "acme/widget"
eq "A widget box"    "$(conf "$T/a" "$T/a/fleet.conf" widget box)"    "zzz-box"

# ── B. negative: a fleet.conf that already ends in a newline gains no blank ──
printf '%s\n%s\n' "$ROW_A" "$ROW_B" > "$T/confB"
mkrepo "$T/b" "$T/confB"
BEFORE=$(rows "$T/b/fleet.conf")
RC=$(load "$T/b" acme/widget --project widget --box zzz-box --no-bootstrap)
eq "B rc" "$RC" "0"
eq "B row count" "$(rows "$T/b/fleet.conf")" "$((BEFORE + 1))"
eq "B no blank lines" "$(grep -c '^$' "$T/b/fleet.conf")" "0"
eq "B beta box" "$(conf "$T/b" "$T/b/fleet.conf" beta box)" "box-small"
eq "B widget offset" "$(conf "$T/b" "$T/b/fleet.conf" widget offset)" "1"

# ── C. idempotent: a second run adds nothing ────────────────────────────────
BEFORE=$(rows "$T/b/fleet.conf")
RC=$(load "$T/b" acme/widget --project widget --box zzz-box --no-bootstrap)
eq "C rc" "$RC" "0"
eq "C row count unchanged" "$(rows "$T/b/fleet.conf")" "$BEFORE"
grep -q 'row exists' "$T/out" && ok || bad "C the loader must say the row exists: $(cat "$T/out")"

echo "load-project-newline-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
