#!/bin/bash
# tests/selfhost-guide-commands.bh-4686-test.sh — BH-4686 (the ticket's
# tests/selfhost-guide-commands-test.sh, named per ticket): the fork-to-deploy
# guide cannot drift from the code it tells an outsider to run.
#
# It reads the real docs/SELF-HOST.md and the README's selfhost block, pulls
# every line out of their ```bash / ```sh fences, and checks each one against
# this checkout:
#
#   L1  at least one command is extracted (an extractor that finds nothing fails)
#   L2  the first word is bin/*, bash, cp, git, gh or python3
#   L3  every repo path it names exists; every bin/ script is executable
#   L4  every --flag of a bin/ command is a case arm or usage token of that
#       script, and a subcommand (harness-ctl.sh set) is a `set)` arm
#   L5  the guide's cp and dry-run lines run VERBATIM in a scratch root: the
#       template as copied is refused (rc 1); filled, the plan ends in
#       `SUMMARY ... live_calls=0 writes=0` (rc 0) and no network tool ran
#   L5b the dry-run prints the cap lines the guide's caps section states
#   L6  every template key is in the guide; every key row of the guide's
#       configure table is a template key, and the row count is the key count
#   L7  each troubleshooting string the guide quotes is what the installer
#       prints when its trigger is run
#   L8  bin/share/leakcheck.py passes the guide and the README block
#   COST no dollar range in the guide (the catalog has no price column)
#   N1-N6 fixture docs that MUST fail: unknown flag, missing script, dry-run
#       without --config, a template key dropped, a box hostname, no fences
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/selfhost-guide-commands.bh-4686-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GUIDE="$DIR/docs/SELF-HOST.md"
README="$DIR/README.md"
TPL="$DIR/env-templates/selfhost.conf.example"
SH="$DIR/bin/selfhost-install.sh"
LEAK="$DIR/bin/share/leakcheck.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# PATH stubs for every tool that could reach a network. The log must stay empty.
mkdir -p "$T/stubs"
for t in wrangler fly flyctl gh curl wget npx ssh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls.log"\nexit 0\n' "$t" "$T" > "$T/stubs/$t"
  chmod +x "$T/stubs/$t"
done
: > "$T/calls.log"
STUBPATH="$T/stubs:$PATH"

# extract <md-file>: every non-blank, non-comment line inside a ```bash or
# ```sh fence.
extract() {
  awk '/^```(bash|sh)[[:space:]]*$/{f=1; next} /^```/{f=0; next} f' "$1" \
    | grep -vE '^[[:space:]]*(#|$)' || true
}

# readme_block <out>: the lines between the README's selfhost markers.
readme_block() {
  awk '/<!-- selfhost:end -->/{f=0} f; /<!-- selfhost:begin -->/{f=1}' "$README" > "$1"
}

# fill <conf>: the shipped template's blanks filled with made-up values.
fill() {
  sed -i -e 's|^SELFHOST_CF_ACCOUNT_ID=$|SELFHOST_CF_ACCOUNT_ID=00000000000000000000000000000000|' \
      -e 's|^HARNESS_WORKERS_SUBDOMAIN=$|HARNESS_WORKERS_SUBDOMAIN=example-sub|' \
      -e 's|^CONSOLE_PAGES_PROJECT=$|CONSOLE_PAGES_PROJECT=example-console|' \
      -e 's|^BACKUP_S3_BUCKET=$|BACKUP_S3_BUCKET=example-backup|' \
      -e 's|^HARNESS_REPO=$|HARNESS_REPO=example-owner/example-harness|' \
      -e 's|^HARNESS_OPERATOR_LOGIN=$|HARNESS_OPERATOR_LOGIN=example-owner|' \
      -e 's|^HARNESS_GIT_NAME=$|HARNESS_GIT_NAME=example-owner|' \
      -e 's|^HARNESS_GIT_EMAIL=$|HARNESS_GIT_EMAIL=owner@example.com|' \
      -e 's|^SELFHOST_GH_AUTH=$|SELFHOST_GH_AUTH=app|' \
      -e 's|^HARNESS_BOX_PREFIX=$|HARNESS_BOX_PREFIX=example-|' \
      -e 's|^HARNESS_HUB_BOX=$|HARNESS_HUB_BOX=example-hub|' \
      -e 's|^SELFHOST_HUB=$|SELFHOST_HUB=fly|' \
      -e 's|^FLY_ORG=$|FLY_ORG=example-org|' \
      -e 's|^SELFHOST_POOL=$|SELFHOST_POOL=fly|' \
      -e 's|^SELFHOST_PROJECTS=$|SELFHOST_PROJECTS=web=example-owner/web|' \
      -e 's|^SELFHOST_MODEL_AUTH=$|SELFHOST_MODEL_AUTH=oauth|' \
      "$1"
}

# lint_cmds <md-file>: L1-L5 over that file's fenced commands. Prints one
# `Ln: reason` line per problem; rc 1 when there is any. DRY_OUT is left
# holding the last filled dry-run's stdout for L5b.
DRY_OUT=""
lint_cmds() {
  local doc="$1" errs=() cmds=() line w first sub tok flag script path run rc out ran=0
  mapfile -t cmds < <(extract "$doc")
  [ "${#cmds[@]}" -ge 1 ] || { echo "L1: no fenced bash/sh command in $doc"; return 1; }
  for line in "${cmds[@]}"; do
    read -r -a w <<< "$line"
    first="${w[0]}"
    case "$first" in
      bin/*|bash|cp|git|gh|python3) ;;
      *) errs+=("L2: '$first' is not an allowed first word: $line"); continue ;;
    esac
    for tok in "${w[@]}"; do
      case "$tok" in *'<'*|*'>'*|*'"'*) continue ;; esac
      case "$tok" in
        bin/*|tests/*|env-templates/*|catalog/*)
          [ -e "$DIR/$tok" ] || errs+=("L3: $tok does not exist: $line")
          case "$tok" in bin/*) [ ! -e "$DIR/$tok" ] || [ -x "$DIR/$tok" ] || errs+=("L3: $tok is not executable") ;; esac ;;
      esac
    done
    if [ "$first" = cp ]; then
      [ -e "$DIR/${w[1]:-}" ] || errs+=("L3: cp source ${w[1]:-<none>} does not exist: $line")
    fi
    case "$first" in bin/*) ;; *) continue ;; esac
    script="$DIR/$first"
    [ -f "$script" ] || continue
    sub="${w[1]:-}"
    if [[ "$sub" =~ ^[a-z][a-z-]*$ ]]; then
      grep -qE -- "(^|[[:space:]|(])$sub\)" "$script" || errs+=("L4: $first has no '$sub)' subcommand arm: $line")
    fi
    for tok in "${w[@]:1}"; do
      case "$tok" in --*) ;; *) continue ;; esac
      flag="${tok%%=*}"
      grep -qE -- "(^|[[:space:]|(\[])$flag([])|[:space:]]|$)" "$script" || errs+=("L4: $first has no $flag: $line")
    done
  done

  # L5: the cp and dry-run lines, verbatim, in a scratch root that looks like
  # a checkout (bin, catalog and env-templates linked in).
  run="$T/run.$(basename "$doc" .md)"; scratch_rm "$run"; mkdir -p "$run"
  for path in bin catalog env-templates; do ln -s "$DIR/$path" "$run/$path"; done
  for line in "${cmds[@]}"; do
    [[ "$line" == cp\ * ]] && [[ "$line" != *'<'* ]] && (cd "$run" && bash -c "$line")
  done
  [ -f "$run/selfhost.conf" ] || cp "$TPL" "$run/selfhost.conf"
  for line in "${cmds[@]}"; do
    [[ "$line" == bin/selfhost-install.sh* ]] || continue
    [[ "$line" == *'<'* ]] && continue
    ran=1
    out=$(cd "$run" && PATH="$STUBPATH" bash -c "$line" 2>&1); rc=$?
    [ "$rc" = 1 ] || errs+=("L5: the template as copied gave rc=$rc, want 1 (refused): $line :: $out")
  done
  fill "$run/selfhost.conf"
  for line in "${cmds[@]}"; do
    [[ "$line" == bin/selfhost-install.sh* ]] || continue
    [[ "$line" == *'<'* ]] && continue
    out=$(cd "$run" && PATH="$STUBPATH" bash -c "$line" 2>&1); rc=$?
    [ "$rc" = 0 ] || errs+=("L5: filled config gave rc=$rc, want 0: $line :: $out")
    grep -qE '^SUMMARY .* live_calls=0 writes=0$' <<< "$out" || errs+=("L5: no 'SUMMARY ... live_calls=0 writes=0' line: $line")
    DRY_OUT="$out"
  done
  [ -s "$T/calls.log" ] && errs+=("L5: a network tool was called: $(cat "$T/calls.log")")
  scratch_rm "$run"
  LINT_RAN_DRY=$ran
  if [ "${#errs[@]}" -gt 0 ]; then printf '%s\n' "${errs[@]}"; return 1; fi
  return 0
}

# check_keys <md-file>: L6 both ways. Every template key appears in the guide,
# and every row of the configure table (the `| `KEY` |` rows under the `## 3.`
# heading, up to the next `## `) is a template key. Secret NAMES such as
# HARNESS_SECRET are listed in that section too, on purpose, outside the table.
check_keys() {
  local doc="$1" errs=() k
  for k in $(grep -oE '^[A-Z][A-Z0-9_]*=' "$TPL" | tr -d =); do
    grep -qw -- "$k" "$doc" || errs+=("L6: template key $k is not in the guide")
  done
  for k in $(awk '/^## 3\./{f=1; next} /^## /{f=0} f' "$doc" | sed -nE 's/^\| `([A-Z][A-Z0-9_]*)` \|.*/\1/p' | sort -u); do
    grep -qE "^$k=" "$TPL" || errs+=("L6: the guide's configure table has a row for $k, which is not a template key")
  done
  if [ "${#errs[@]}" -gt 0 ]; then printf '%s\n' "${errs[@]}"; return 1; fi
}

# leak <dir>: L8. rc of bin/share/leakcheck.py, or 3 when it cannot run.
leak() {
  command -v python3 >/dev/null && [ -f "$LEAK" ] || return 3
  python3 "$LEAK" "$1" >"$T/leak.out" 2>&1
}

# ── L1-L5 on the real guide and the README block ─────────────────────────────
[ -f "$GUIDE" ] || { echo "FAIL: $GUIDE does not exist"; echo "FAILED: 1 (passed $PASS)"; exit 1; }
LINT_RAN_DRY=0
# Called directly, not in $(...), so DRY_OUT and LINT_RAN_DRY survive it.
if lint_cmds "$GUIDE" > "$T/guide.lint"; then ok; else bad "guide lint: $(cat "$T/guide.lint")"; fi
G_DRY_OUT="$DRY_OUT"
[ "$LINT_RAN_DRY" = 1 ] && ok || bad "L5 the guide has no runnable bin/selfhost-install.sh line"
n=$(extract "$GUIDE" | wc -l)
[ "$n" -ge 8 ] && ok || bad "L1 only $n commands extracted from the guide"

readme_block "$T/readme-block.md"
[ -s "$T/readme-block.md" ] && ok || bad "L1 README has no <!-- selfhost:begin -->/<!-- selfhost:end --> block"
if r=$(lint_cmds "$T/readme-block.md"); then ok; else bad "README block lint: $r"; fi
grep -q 'docs/SELF-HOST.md' "$T/readme-block.md" && ok || bad "README block does not link docs/SELF-HOST.md"
grep -qxF '| Run it on your own accounts, from a fork | [docs/SELF-HOST.md](docs/SELF-HOST.md) |' "$README" && ok || bad "README Read-next table has no SELF-HOST row"
[ "$(grep -c '^| See the dated notes this README used to be |' "$README")" = 1 ] && ok || bad "README lost the row bin/share/sanitize.py patches"

# ── L5b: the caps the guide states are the caps the dry-run prints ───────────
for c in 'CAP AGENT_CALL_BUDGET_USD=5' 'CAP LLM_USD_CAP_DAY=20'; do
  grep -qxF -- "$c" <<< "$G_DRY_OUT" && ok || bad "L5b the guide's dry-run does not print '$c'"
  grep -qF -- "$c" "$GUIDE" && ok || bad "L5b the guide does not state '$c'"
done
grep -qF 'SELFHOST_CAPS_OFF=1' "$GUIDE" && ok || bad "L5b the guide does not say how caps turn off"

# ── L6 ───────────────────────────────────────────────────────────────────────
if r=$(check_keys "$GUIDE"); then ok; else bad "keys: $r"; fi
nk=$(awk '/^## 3\./{f=1; next} /^## /{f=0} f' "$GUIDE" | grep -cE '^\| `[A-Z][A-Z0-9_]*` \|')
nt=$(grep -cE '^[A-Z][A-Z0-9_]*=' "$TPL")
[ "$nk" = "$nt" ] && ok || bad "L6 the configure table has $nk key rows, the template has $nt keys"

# ── L7: each quoted refusal is what the installer prints for its trigger ─────
trig() {  # trig <expected string> <rc> <args...> — run the installer, check both
  local want="$1" wrc="$2" out rc; shift 2
  out=$(PATH="$STUBPATH" bash "$SH" "$@" 2>&1); rc=$?
  [ "$rc" = "$wrc" ] && ok || bad "L7 '$want': rc=$rc, want $wrc"
  grep -qF -- "$want" <<< "$out" && ok || bad "L7 the installer did not print '$want': $out"
  grep -qF -- "$want" "$GUIDE" && ok || bad "L7 the guide does not quote '$want'"
}
cp "$TPL" "$T/c.conf"; fill "$T/c.conf"
trig 'SELFHOST_CF_ACCOUNT_ID is blank' 1 --config "$TPL" --dry-run
sed 's|^SELFHOST_CF_ACCOUNT_ID=.*|SELFHOST_CF_ACCOUNT_ID=abc123|' "$T/c.conf" > "$T/c2.conf"
trig 'SELFHOST_CF_ACCOUNT_ID is not 32 hex characters' 1 --config "$T/c2.conf" --dry-run
{ cat "$T/c.conf"; echo 'GH_TOKEN=not-a-real-token-example'; } > "$T/c3.conf"
trig 'GH_TOKEN looks like a secret; secrets never go in this file' 1 --config "$T/c3.conf" --dry-run
sed 's|^FLY_ORG=.*|FLY_ORG=|' "$T/c.conf" > "$T/c4.conf"
trig 'FLY_ORG is blank and the hub or the pool is on Fly' 1 --config "$T/c4.conf" --dry-run
trig '--apply is not built yet' 2 --config "$T/c.conf" --apply
trig '--config <file> is required' 2 --dry-run
[ ! -s "$T/calls.log" ] && ok || bad "L7 a network tool was called: $(cat "$T/calls.log")"

# ── L8: leak pass on the guide and the README block ──────────────────────────
mkdir -p "$T/leak"
cp "$GUIDE" "$T/leak/SELF-HOST.md"; cp "$T/readme-block.md" "$T/leak/README-selfhost.md"
leak "$T/leak"; rc=$?
if [ "$rc" = 3 ]; then echo "SKIP: L8 needs python3 and bin/share/leakcheck.py (absent here)"
else [ "$rc" = 0 ] && ok || bad "L8 leakcheck refused the guide or README block: $(cat "$T/leak.out")"; fi

# ── COST: no invented dollar range ───────────────────────────────────────────
rng=$(grep -nE '\$[0-9]+ *[-–] *\$?[0-9]+' "$GUIDE" || true)
[ -z "$rng" ] && ok || bad "COST the guide states a dollar range the catalog does not carry: $rng"

# ── N1-N6: fixtures the lint MUST refuse ─────────────────────────────────────
fx() { printf '# fixture\n\n```bash\n%s\n```\n' "$1" > "$T/$2.md"; }
neg() {  # neg <name> <file> <expected rule prefix>
  local r
  if r=$(lint_cmds "$2"); then bad "$1 passed the lint"
  else grep -q "^$3" <<< "$r" && ok || bad "$1 failed for the wrong reason: $r"; fi
}
fx 'bin/selfhost-install.sh --config selfhost.conf --nope' n1; neg N1 "$T/n1.md" L4
fx 'bin/does-not-exist.sh --config selfhost.conf' n2;          neg N2 "$T/n2.md" L3
fx 'bin/selfhost-install.sh --dry-run' n3;                     neg N3 "$T/n3.md" L5
fx 'bin/harness-ctl.sh sett <lane> LLM_USD_CAP_DAY <n>' n3b;  neg N3b "$T/n3b.md" L4
fx 'curl https://example.com/install.sh' n3c;                  neg N3c "$T/n3c.md" L2
grep -v 'BACKUP_S3_BUCKET' "$GUIDE" > "$T/n4.md"
if r=$(check_keys "$T/n4.md"); then bad "N4 a guide missing BACKUP_S3_BUCKET passed"
else grep -q 'BACKUP_S3_BUCKET' <<< "$r" && ok || bad "N4 wrong reason: $r"; fi
sed '/^## 3\./a | `SELFHOST_NOT_A_KEY` | x |' "$GUIDE" > "$T/n4b.md"
if r=$(check_keys "$T/n4b.md"); then bad "N4b a guide naming an unknown key passed"
else grep -q 'SELFHOST_NOT_A_KEY' <<< "$r" && ok || bad "N4b wrong reason: $r"; fi
printf '# fixture\n\nNo commands here.\n' > "$T/n6.md";        neg N6 "$T/n6.md" L1
if command -v python3 >/dev/null && [ -f "$LEAK" ]; then
  box=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from mapping import BOXES; print(BOXES[0][0])' "$DIR/bin/share")
  mkdir -p "$T/leak5"; fx "ssh root@$box" n5; cp "$T/n5.md" "$T/leak5/"
  leak "$T/leak5"; rc=$?
  [ "$rc" = 1 ] && ok || bad "N5 leakcheck passed a doc naming a box hostname (rc=$rc)"
else
  echo "SKIP: N5 needs python3 and bin/share/leakcheck.py (absent here)"
fi
[ ! -s "$T/calls.log" ] && ok || bad "a network tool was called: $(cat "$T/calls.log")"

echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
