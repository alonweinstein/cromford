#!/bin/bash
# tests/console-pages-lib.bh-3561-test.sh — bin/lib/console-pages.sh, the
# shared names the console-ui Pages deployer and drift detector read (BH-3554,
# slice BH-3561).
#
#   L1  the settings key, the project and the URL: defaults, env overrides,
#       every trailing `/` stripped, and sourcing under `set -u` is silent.
#   L2  console_pages_want answers main's FIRST-PARENT commit (the merge, never
#       the branch commit under it); rc 1 and empty output when history never
#       touched console-ui/, on an unknown ref (no stderr), and with no args.
#   L3  console_pages_account_id parses wrangler.jsonc past a `//`-commented
#       decoy; a non-empty CLOUDFLARE_ACCOUNT_ID wins; a missing file or a file
#       with no key gives rc 1 and empty output.
#   L4  the lib never names CLOUDFLARE_API_TOKEN.
# Run from anywhere: tests/console-pages-lib.bh-3561-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/console-pages.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }

[ -f "$LIB" ] || { echo "FAIL: missing $LIB"; echo "PASS=0 FAIL=1"; exit 1; }
. "$LIB" || exit 1

# --- L1: key, project, URL --------------------------------------------------
eq "L1 sha key" "${CONSOLE_PAGES_SHA_KEY:-}" "deploy.console-ui.sha"
out=$(unset CONSOLE_PAGES_PROJECT CONSOLE_PAGES_URL; console_pages_project; console_pages_url)
eq "L1 defaults" "$out" "mission-control
https://console.example.pages.dev"
out=$(CONSOLE_PAGES_PROJECT=mc-x CONSOLE_PAGES_URL=https://x.example// ; export CONSOLE_PAGES_PROJECT CONSOLE_PAGES_URL
      console_pages_project; console_pages_url)
eq "L1 overrides, many slashes stripped" "$out" "mc-x
https://x.example"
out=$(CONSOLE_PAGES_URL=https://y.example/ console_pages_url)
eq "L1 one slash stripped" "$out" "https://y.example"
out=$(bash -c 'set -u; . "$1"' _ "$LIB" 2>&1); rc=$?
eq "L1 source under set -u rc" "$rc" "0"
eq "L1 source under set -u output" "$out" ""

# --- L2: console_pages_want ---------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  echo "console-pages-lib: L2 SKIPPED — git is not installed on this box"
else
  G() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }
  R="$T/repo"; mkdir -p "$R"
  G "$R" init -q -b main
  echo 0 > "$R/a"; G "$R" add a; G "$R" commit -q -m C0
  G "$R" checkout -q -b feat
  mkdir -p "$R/console-ui"; echo x > "$R/console-ui/x"; G "$R" add console-ui; G "$R" commit -q -m B1
  b1=$(G "$R" rev-parse HEAD)
  G "$R" checkout -q main
  echo 1 > "$R/a"; G "$R" commit -q -am C1
  G "$R" merge -q --no-ff -m M feat
  m=$(G "$R" rev-parse HEAD)
  echo 2 > "$R/a"; G "$R" commit -q -am C2
  out=$(console_pages_want "$R" main); rc=$?
  eq "L2 merge rc" "$rc" "0"
  eq "L2 answers the merge commit" "$out" "$m"
  if [ "$out" != "$b1" ]; then ok; else bad "L2 answered the branch commit $b1"; fi

  R2="$T/repo2"; mkdir -p "$R2"
  G "$R2" init -q -b main
  echo 0 > "$R2/a"; G "$R2" add a; G "$R2" commit -q -m C0
  out=$(console_pages_want "$R2" main); rc=$?
  eq "L2 never touched rc" "$rc" "1"
  eq "L2 never touched output" "$out" ""

  out=$(console_pages_want "$R" nope 2>"$T/err"); rc=$?
  eq "L2 unknown ref rc" "$rc" "1"
  eq "L2 unknown ref output" "$out" ""
  eq "L2 unknown ref stderr" "$(cat "$T/err")" ""

  out=$(console_pages_want); rc=$?
  eq "L2 no args rc" "$rc" "1"
  eq "L2 no args output" "$out" ""
fi

# --- L3: console_pages_account_id ----------------------------------------------
mkdir -p "$T/tree/worker/jobs"
cat > "$T/tree/worker/jobs/wrangler.jsonc" <<'EOF'
// header
  // "account_id": "deadbeef",
{
  "name": "x",
  "account_id": "00000000000000000000000000000000", // trailing comment
}
EOF
out=$(unset CLOUDFLARE_ACCOUNT_ID; console_pages_account_id "$T/tree"); rc=$?
eq "L3 file rc" "$rc" "0"
eq "L3 file skips the commented decoy" "$out" "00000000000000000000000000000000"
out=$(CLOUDFLARE_ACCOUNT_ID=envid console_pages_account_id "$T/tree"); rc=$?
eq "L3 env wins rc" "$rc" "0"
eq "L3 env wins" "$out" "envid"
out=$(CLOUDFLARE_ACCOUNT_ID= console_pages_account_id "$T/tree")
eq "L3 empty env falls through to the file" "$out" "00000000000000000000000000000000"
out=$(unset CLOUDFLARE_ACCOUNT_ID; console_pages_account_id "$T/none"); rc=$?
eq "L3 missing tree rc" "$rc" "1"
eq "L3 missing tree output" "$out" ""
out=$(unset CLOUDFLARE_ACCOUNT_ID; console_pages_account_id); rc=$?
eq "L3 no args rc" "$rc" "1"
mkdir -p "$T/nokey/worker/jobs"
printf '// header\n{\n  "name": "x"\n}\n' > "$T/nokey/worker/jobs/wrangler.jsonc"
out=$(unset CLOUDFLARE_ACCOUNT_ID; console_pages_account_id "$T/nokey"); rc=$?
eq "L3 no key rc" "$rc" "1"
eq "L3 no key output" "$out" ""

# --- L4: the API token is never read here -------------------------------------
n=$(grep -c CLOUDFLARE_API_TOKEN "$LIB")
eq "L4 token never referenced" "$n" "0"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
