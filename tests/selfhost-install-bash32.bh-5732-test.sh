#!/bin/bash
# tests/selfhost-install-bash32.bh-5732-test.sh — BH-5732: bin/selfhost-install.sh
# runs under stock macOS bash 3.2 (quickstart step 4). On a Mac it died with
# "declare: -A: invalid option" and then "SELFHOST_CF_ACCOUNT_ID: unbound
# variable", because S, LEDGER and SEC_IDS were associative arrays.
#
#   L1   the bash 3.2 lint finds no offender in the script
#   L2   the lint is live: an appended declare -A and a reverted guard are caught
#   L3   no associative array declaration at all
#   B1a  the template as shipped is refused, naming the blanks
#   B1b  a filled config plans, SUMMARY ... live_calls=0 writes=0, no stub called
#   B1c  the ledger path (was the LEDGER map) marks a row recorded
#   B1d  the SECRET path (was the SEC_IDS map) joins ids, no name twice
#   B1-live  B1a and B1b under a real bash 3.2 (a Mac's /bin/bash, or
#        SELFHOST_BASH32=<path>); skipped with one line when there is none
#   K1-K2  SELFHOST_CAPS_OFF=0 means caps on; other values still refuse
#
# B2 (re-exec) does not apply: BH-5732 took the bash 3.2-safe route.
#
# SELFHOST_INSTALL_SH=<file> points every case at another copy of the script
# (the red-first run against main's copy uses it).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/selfhost-install-bash32.bh-5732-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SH="${SELFHOST_INSTALL_SH:-$DIR/bin/selfhost-install.sh}"
TPL="$DIR/env-templates/selfhost.conf.example"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A copy of SH outside the repo cannot find ../catalog, so point it there.
export SELFHOST_CATALOG="$DIR/catalog/selfhost/resources.tsv"

# PATH stubs for every tool that could reach a network.
mkdir -p "$T/stubs"
for t in wrangler fly flyctl gh curl wget npx; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls.log"\nexit 0\n' "$t" "$T" > "$T/stubs/$t"
  chmod +x "$T/stubs/$t"
done
: > "$T/calls.log"
export PATH="$T/stubs:$PATH"

# conf <file> [KEY=VAL ...] — copied from tests/selfhost-install-dryrun.bh-4081-test.sh:
# the template with blanks filled by made-up values, then each KEY=VAL
# replacing that key's line (VAL may be empty).
conf() {
  local f="$1"; shift
  sed -e 's|^SELFHOST_CF_ACCOUNT_ID=$|SELFHOST_CF_ACCOUNT_ID=00000000000000000000000000000000|' \
      -e 's|^HARNESS_WORKERS_SUBDOMAIN=$|HARNESS_WORKERS_SUBDOMAIN=acme|' \
      -e 's|^CONSOLE_PAGES_PROJECT=$|CONSOLE_PAGES_PROJECT=acme-console|' \
      -e 's|^BACKUP_S3_BUCKET=$|BACKUP_S3_BUCKET=acme-backup|' \
      -e 's|^HARNESS_REPO=$|HARNESS_REPO=acme-org/acme-harness|' \
      -e 's|^HARNESS_OPERATOR_LOGIN=$|HARNESS_OPERATOR_LOGIN=acme-op|' \
      -e 's|^HARNESS_GIT_NAME=$|HARNESS_GIT_NAME=acme-op|' \
      -e 's|^HARNESS_GIT_EMAIL=$|HARNESS_GIT_EMAIL=op@acme.example|' \
      -e 's|^SELFHOST_GH_AUTH=$|SELFHOST_GH_AUTH=app|' \
      -e 's|^HARNESS_BOX_PREFIX=$|HARNESS_BOX_PREFIX=acme-|' \
      -e 's|^HARNESS_HUB_BOX=$|HARNESS_HUB_BOX=acme-hub|' \
      -e 's|^SELFHOST_HUB=$|SELFHOST_HUB=fly|' \
      -e 's|^FLY_ORG=$|FLY_ORG=acme-fly|' \
      -e 's|^SELFHOST_POOL=$|SELFHOST_POOL=fly|' \
      -e 's|^SELFHOST_PROJECTS=$|SELFHOST_PROJECTS=web=acme-org/web api=acme-org/api|' \
      -e 's|^SELFHOST_MODEL_AUTH=$|SELFHOST_MODEL_AUTH=oauth|' \
      "$TPL" > "$f"
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    awk -v k="$k" -v v="$v" 'BEGIN{FS="="} $1==k{print k "=" v; next} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
}
# run <bash> args... — the script under that bash; sets OUT, ERR, RC.
run() { local b="$1"; shift; OUT=$("$b" "$SH" "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }
has() { grep -qxF -- "$1" <<< "$OUT"; }

# b32_lint <file> <label> — a verbatim copy of lv_lint in
# tests/lead-verdict-bash32.bh-3565-test.sh (BH-3565). Prints
# `<label>:<line>: <why>` per offender; comment lines are skipped; the guard
# form ${x[@]+"${x[@]}"} is removed before the array check.
b32_lint() {
  awk -v P="$2" '
    /^[[:space:]]*#/ { next }
    { s = $0
      gsub(/\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\+"\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}"\}/, "", s)
      if (s ~ /\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]/) print P ":" NR ": unguarded array expansion"
      if (s ~ /(declare|local|typeset)[[:space:]]+-[A-Za-z]*[Ang]/ \
          || s ~ /(^|[^A-Za-z0-9_])(mapfile|readarray|coproc)([^A-Za-z0-9_]|$)/ \
          || s ~ /\$\{[A-Za-z_][A-Za-z0-9_]*(,,?|\^\^?|@[QEPAaUuLK])\}/ || s ~ /\[\[[[:space:]]+-v[[:space:]]/ \
          || s ~ /wait[[:space:]]+-n/ || s ~ /%\([^)]*\)T/ || s ~ /EPOCH(SECONDS|REALTIME)/ \
          || s ~ /(^|[^$A-Za-z0-9_])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]/ || s ~ /;;&/ || s ~ /&>>/ || s ~ /\|&/) print P ":" NR ": bash>=4 feature"
    }' "$1"
}

# ── L1-L3: the static bash 3.2 proof ─────────────────────────────────────────
R=$(b32_lint "$SH" selfhost-install.sh)
[ -z "$R" ] && ok || bad "L1 bash 3.2 lint offenders in bin/selfhost-install.sh:"$'\n'"$R"

{ cat "$SH"; echo 'declare -A S=()'; } > "$T/l2a.sh"
R=$(b32_lint "$T/l2a.sh" l2a)
[ "$R" = "l2a:$(wc -l < "$T/l2a.sh" | tr -d ' '): bash>=4 feature" ] && ok || bad "L2 an appended declare -A must be the only report, got: $R"
L60=$(grep -n 'for k in \${KNOWN\[@\]+"\${KNOWN\[@\]}"}' "$SH" | cut -d: -f1)
[ -n "$L60" ] && ok || bad "L2 the guarded KNOWN loop in is_known must exist"
sed 's/\${KNOWN\[@\]+"\${KNOWN\[@\]}"}/"${KNOWN[@]}"/' "$SH" > "$T/l2b.sh"
R=$(b32_lint "$T/l2b.sh" l2b)
[ "$R" = "l2b:${L60:-x}: unguarded array expansion" ] && ok || bad "L2 a reverted KNOWN guard must be reported at line $L60, got: $R"

R=$(grep -nE '(declare|local|typeset)[[:space:]]+-[A-Za-z]*A' "$SH")
[ -z "$R" ] && ok || bad "L3 an associative array (macOS bash 3.2: 'declare: -A: invalid option'): $R"

# ── B1: the dry-run, under a given bash ──────────────────────────────────────
conf "$T/full.conf"
mkdir -p "$T/st"
printf 'cloudflare\td1\tharness-jobs\tid\tx\n' > "$T/st/ledger.tsv"
b1() {  # b1 <bash> <label>
  local b="$1" L="$2" k
  run "$b" --config "$TPL" --dry-run
  [ "$RC" = 1 ] && ok || bad "$L B1a the template must be refused rc 1, got rc $RC: $ERR"
  grep -q 'refused' <<< "$ERR" && ok || bad "$L B1a stderr must say refused: $ERR"
  for k in SELFHOST_CF_ACCOUNT_ID HARNESS_REPO SELFHOST_HUB SELFHOST_PROJECTS; do
    grep -q "$k is blank" <<< "$ERR" && ok || bad "$L B1a stderr must name '$k is blank': $ERR"
  done
  grep -qE 'unbound variable|invalid option' <<< "$ERR" && bad "$L B1a bash error on the template: $ERR" || ok

  : > "$T/calls.log"
  run "$b" --config "$T/full.conf" --dry-run
  [ "$RC" = 0 ] && ok || bad "$L B1b a filled config must plan rc 0, got rc $RC: $ERR"
  [ -z "$ERR" ] && ok || bad "$L B1b stderr must be empty: $ERR"
  tail -n 1 <<< "$OUT" | grep -qE '^SUMMARY resources=[0-9]+ create=[0-9]+ recorded=0 skipped=[0-9]+ live_calls=0 writes=0$' \
    && ok || bad "$L B1b last line must be SUMMARY ... recorded=0 ... live_calls=0 writes=0, got: $(tail -n 1 <<< "$OUT")"
  [ ! -s "$T/calls.log" ] && ok || bad "$L B1b a live tool was called: $(cat "$T/calls.log")"
  grep -qE '^SECRET CLOUDFLARE_API_TOKEN needed-by=[^,]+(,[^,]+)+$' <<< "$OUT" && ok \
    || bad "$L B1d CLOUDFLARE_API_TOKEN must list >= 2 ids, got: $(grep '^SECRET CLOUDFLARE_API_TOKEN' <<< "$OUT")"
  R=$(grep '^SECRET' <<< "$OUT" | awk '{print $2}' | sort | uniq -d)
  [ -z "$R" ] && ok || bad "$L B1d a SECRET name appears twice: $R"

  run "$b" --config "$T/full.conf" --dry-run --state "$T/st"
  [ "$RC" = 0 ] && ok || bad "$L B1c --state must plan rc 0, got rc $RC: $ERR"
  has "RESOURCE cloudflare d1 harness-jobs recorded from=fixed" && ok || bad "$L B1c the ledger row must be recorded: $(grep harness-jobs <<< "$OUT")"
  tail -n 1 <<< "$OUT" | grep -q ' recorded=1 ' && ok || bad "$L B1c SUMMARY must say recorded=1: $(tail -n 1 <<< "$OUT")"
}
b1 bash "bash${BASH_VERSINFO[0]}"

B32="${SELFHOST_BASH32:-}"
if [ -z "$B32" ] && [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" = 3 ]; then B32=/bin/bash; fi
if [ -n "$B32" ]; then
  echo "B1-live: running B1 under $B32 ($("$B32" -c 'echo $BASH_VERSION'))"
  b1 "$B32" B1-live
else
  echo "B1-live skipped: no bash 3.2 here (set SELFHOST_BASH32=<path>)"
fi

# ── K1-K2: caps ──────────────────────────────────────────────────────────────
conf "$T/k.conf" SELFHOST_CAPS_OFF=0
run bash --config "$T/k.conf" --dry-run
[ "$RC" = 0 ] && ok || bad "K1 SELFHOST_CAPS_OFF=0 must plan rc 0, got rc $RC: $ERR"
has "CAP AGENT_CALL_BUDGET_USD=5" && has "CAP LLM_USD_CAP_DAY=20" && ok || bad "K1 SELFHOST_CAPS_OFF=0 keeps the caps on: $(grep '^CAP' <<< "$OUT")"
grep -q '^CAP off' <<< "$OUT" && bad "K1 SELFHOST_CAPS_OFF=0 must not turn the caps off" || ok

conf "$T/k2.conf" SELFHOST_CAPS_OFF=yes
run bash --config "$T/k2.conf" --dry-run
[ "$RC" = 1 ] && grep -qF 'SELFHOST_CAPS_OFF=yes: blank, 0 or 1 only' <<< "$ERR" && ok || bad "K2 SELFHOST_CAPS_OFF=yes must refuse rc 1 naming 'blank, 0 or 1 only', got rc $RC: $ERR"
conf "$T/k3.conf" SELFHOST_CAPS_OFF=0 SELFHOST_CAP_USD_PER_CALL=
run bash --config "$T/k3.conf" --dry-run
[ "$RC" = 1 ] && grep -qF "SELFHOST_CAP_USD_PER_CALL='' is not a positive dollar amount" <<< "$ERR" && ok || bad "K2 SELFHOST_CAPS_OFF=0 with a blank cap must refuse rc 1, got rc $RC: $ERR"

echo "selfhost-install-bash32 (BH-5732): $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
