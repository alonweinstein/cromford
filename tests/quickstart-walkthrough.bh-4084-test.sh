#!/bin/bash
# tests/quickstart-walkthrough.bh-4084-test.sh — the quickstart, followed from
# `git clone` to filing a ticket, by a clean user against stubs (BH-4084).
#
# It builds the dry-run mirror with bin/publish-share.sh (--ref HEAD, so the
# pages on this branch are the ones followed), serves that mirror as the
# quickstart's clone URL through a git insteadOf, and runs every fenced bash
# line of the MIRROR's docs/quickstart.md, in order, in ONE bash process, with
# step 7's enroll command taken from the mirror's onboarding-a-repo.md. Every
# network tool is a PATH stub; HOME and the harness env dirs are empty scratch
# dirs, so nothing on this box (tokens, env files) reaches the run.
#
#   W1  the clone line runs verbatim, rc 0, and gives cromford/bin/selfhost-install.sh
#   W2  the step-2 leak guard rc 0
#   W3  cp rc 0; the dry-run line rc 1 on the template as copied; after the
#       step-3 hand fill, rc 0 ending `SUMMARY ... live_calls=0 writes=0`
#   W4  bin/load-project.sh rc 0: a widgets row in the clone's fleet.conf, the
#       commit pushed to the scratch origin, `gh label create` called
#   W5  step 8's `gh issue create -R acme/widgets --label ai-build` was called
#   W6  no wrangler, fly, flyctl, curl or wget call: nothing reached an account
#   W7  one rc= line per `$` line, and every extracted command was run
#   W8  a <placeholder> the fill map does not cover is a named failure
#   W9  no bearer token in the transcript or the call log
#   M1  a quickstart whose dry-run line carries --no-such-flag turns W3 red
#
# Step 5 (create the resources) and step 6 (connect a board) have no command;
# the transcript logs them as hand steps. The first-PR rung needs a live
# model, hub and board, and is not run here.
#
# The transcript is printed at the end, and copied to $HARNESS_WALKTHROUGH_OUT
# when that is set.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/quickstart-walkthrough.bh-4084-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
done_() { echo "quickstart-walkthrough: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }

mkdir -p "$T/stubs" "$T/home" "$T/empty/env"
for t in gh wrangler fly flyctl curl wget npx ssh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls.log"\nexit 0\n' "$t" "$T" > "$T/stubs/$t"
  chmod +x "$T/stubs/$t"
done

# ── the dry-run mirror ──────────────────────────────────────────────────────
# GIT_CONFIG_GLOBAL points github.com at a path that does not exist, so the
# publisher's read of the published head fails here and its dry-run says so
# instead of reaching GitHub. GH_TOKEN keeps it off this box's PAT ladder.
# HARNESS_DEPLOYMENT_FILE is unset as a real publish has it: scratch.sh points
# it at THIS checkout's defaults, and sanitize's crontab render inside the
# mirror would then read upstream box names against the mirror's fleet.conf.
printf '[url "file://%s/no-such-remote/"]\n\tinsteadOf = https://github.com/\n' "$T" > "$T/ps.gitconfig"
PS_OUT=$(cd "$DIR" && env -u HARNESS_DEPLOYMENT_FILE GIT_CONFIG_GLOBAL="$T/ps.gitconfig" GH_TOKEN=walkthrough-no-token \
  PATH="$T/stubs:$PATH" bin/publish-share.sh --dry-run --ref HEAD --out "$T/mirror" 2>&1)
PS_RC=$?
if [ "$PS_RC" = 0 ]; then
  ok
elif [ "$PS_RC" = 1 ] && ! command -v gitleaks >/dev/null 2>&1 && [ -z "${GITLEAKS_REQUIRED:-}" ] \
     && grep -q '^gitleaks-gate: gitleaks is not installed' <<< "$PS_OUT" \
     && grep -q '^leakcheck: clean' <<< "$PS_OUT"; then
  # The same rule as share-publish-clean's gitleaks arm: a box without the
  # binary may go on with the mirror the publisher built and leak-checked, and
  # says so; CI sets GITLEAKS_REQUIRED and has gitleaks, so there rc 1 is red.
  ok
  echo "NOTE: gitleaks not on PATH; publish-share built and leak-checked the mirror, then refused at its gitleaks gate (rc 1). CI runs the gate."
else
  bad "publish-share.sh --dry-run rc=$PS_RC: $(tail -n 5 <<< "$PS_OUT")"
fi
[ -f "$T/mirror/docs/quickstart.md" ] || { bad "the dry-run mirror has no docs/quickstart.md"; done_; }
grep -q '^\*\*Programs\.\*\*' "$T/mirror/docs/optional-services.md" \
  || { bad "the mirror is not this branch's tree (no Programs line in optional-services.md)"; done_; }

rm -rf "$T/mirror/.git"
git -C "$T/mirror" init -q -b main \
  && git -C "$T/mirror" add -A \
  && git -C "$T/mirror" -c user.name=walk -c user.email=walk@example.com commit -qm mirror \
  && git clone -q --bare "$T/mirror" "$T/origin.git" \
  || { bad "could not make the mirror a clonable origin"; done_; }

# The clean user's git: the quickstart's clone URL resolves to the mirror.
git config --file "$T/home/.gitconfig" url."file://$T/origin.git".insteadOf https://github.com/cromford-ai/cromford
git config --file "$T/home/.gitconfig" user.name walk
git config --file "$T/home/.gitconfig" user.email walk@example.com

# ── extraction ──────────────────────────────────────────────────────────────
# fenced <md>: every non-blank, non-comment line inside a ```bash/```sh fence,
# prefixed with the quickstart step it sits under (0 before step 1).
fenced() {
  awk '/^\*\*[0-9]+\./{ s=$0; sub(/^\*\*/, "", s); sub(/\..*/, "", s); step=s+0 }
       /^```(bash|sh)[[:space:]]*$/{f=1; next} /^```/{f=0; next}
       f && $0 !~ /^[[:space:]]*(#|$)/ { print (step+0) "\t" $0 }' "$1"
}
# enroll <md>: the fenced lines under onboarding's "## Enroll it on the hub".
enroll() {
  awk '/^## /{e=($0 == "## Enroll it on the hub")} e' "$1" \
    | awk '/^```(bash|sh)[[:space:]]*$/{f=1; next} /^```/{f=0; next} f && $0 !~ /^[[:space:]]*(#|$)/'
}

# plan <docs-dir> <out>: the walkthrough as records, `CMD\t<line>` or
# `HAND\t<what>`, in the order a reader follows the quickstart.
plan() {
  local docs="$1" out="$2" step line prev=0
  : > "$out"
  while IFS=$'\t' read -r step line; do
    while [ "$prev" -lt "$step" ]; do
      prev=$((prev+1))
      case "$prev" in
        5) printf 'HAND\tstep 5: create the resources by hand (no command; --apply is not built)\n' ;;
        6) printf 'HAND\tstep 6: GitHub Issues is the default board (no command)\n' ;;
        8) enroll "$docs/onboarding-a-repo.md" | sed 's/^/CMD\t/' ;;
      esac >> "$out"
    done
    printf 'CMD\t%s\n' "$line" >> "$out"
    if [ "$step" = 4 ] && [[ "$line" == *--dry-run* ]]; then
      printf 'HAND\tstep 3: fill in selfhost.conf\n' >> "$out"
      printf 'CMD\t%s\n' "$line" >> "$out"
    fi
  done < <(fenced "$docs/quickstart.md")
}

# The placeholder map. Anything else in <...> is W8.
fill_placeholders() {
  sed -e 's|<owner/repo>|acme/widgets|g' -e 's|<name>|widgets|g' -e 's|<box>|hub1|g' \
      -e 's|<title>|Fix the footer year|g' -e 's|<what you want built>|The footer says 2024. It should say the current year.|g'
}

# The step-3 hand fill: the template's blanks, filled with made-up values.
FILL='sed -i -e "s|^SELFHOST_CF_ACCOUNT_ID=\$|SELFHOST_CF_ACCOUNT_ID=00000000000000000000000000000000|" \
  -e "s|^HARNESS_WORKERS_SUBDOMAIN=\$|HARNESS_WORKERS_SUBDOMAIN=example-sub|" \
  -e "s|^CONSOLE_PAGES_PROJECT=\$|CONSOLE_PAGES_PROJECT=example-console|" \
  -e "s|^BACKUP_S3_BUCKET=\$|BACKUP_S3_BUCKET=example-backup|" \
  -e "s|^HARNESS_REPO=\$|HARNESS_REPO=acme/cromford|" \
  -e "s|^HARNESS_OPERATOR_LOGIN=\$|HARNESS_OPERATOR_LOGIN=acme|" \
  -e "s|^HARNESS_GIT_NAME=\$|HARNESS_GIT_NAME=acme|" \
  -e "s|^HARNESS_GIT_EMAIL=\$|HARNESS_GIT_EMAIL=owner@example.com|" \
  -e "s|^SELFHOST_GH_AUTH=\$|SELFHOST_GH_AUTH=app|" \
  -e "s|^HARNESS_BOX_PREFIX=\$|HARNESS_BOX_PREFIX=example-|" \
  -e "s|^HARNESS_HUB_BOX=\$|HARNESS_HUB_BOX=hub1|" \
  -e "s|^SELFHOST_HUB=\$|SELFHOST_HUB=fly|" \
  -e "s|^FLY_ORG=\$|FLY_ORG=example-org|" \
  -e "s|^SELFHOST_POOL=\$|SELFHOST_POOL=fly|" \
  -e "s|^SELFHOST_PROJECTS=\$|SELFHOST_PROJECTS=widgets=acme/widgets|" \
  -e "s|^SELFHOST_MODEL_AUTH=\$|SELFHOST_MODEL_AUTH=oauth|" selfhost.conf'

# walk <docs-dir> <run-dir>: run the walkthrough. Leaves <run-dir>/transcript.txt,
# <run-dir>/rc.tsv (`n\trc\tcmd`), <run-dir>/out/<n> and <run-dir>/calls.log.
walk() {
  local docs="$1" R="$2" kind line n=0
  mkdir -p "$R/work" "$R/out"
  plan "$docs" "$R/plan.tsv"
  {
    echo 'set +e'
    echo "TR=$(printf '%q' "$R/transcript.txt"); : > \"\$TR\"; : > $(printf '%q' "$R/rc.tsv")"
    while IFS=$'\t' read -r kind line; do
      if [ "$kind" = HAND ]; then
        printf 'printf "# hand step: %%s\\n" %q >> "$TR"\n' "$line"
        [[ "$line" == "step 3: fill"* ]] && printf '%s\n' "$FILL"
        continue
      fi
      n=$((n+1))
      line=$(fill_placeholders <<< "$line")
      printf 'printf "$ %%s\\n" %q >> "$TR"\n' "$line"
      printf '{ %s\n} > %q 2>&1 < /dev/null\n' "$line" "$R/out/$n"
      printf 'rc=$?; cat %q >> "$TR"; echo "rc=$rc" >> "$TR"; printf "%%s\\t%%s\\t%%s\\n" %s "$rc" %q >> %q\n' \
        "$R/out/$n" "$n" "$line" "$R/rc.tsv"
    done < "$R/plan.tsv"
  } > "$R/walk.sh"
  : > "$T/calls.log"
  ( cd "$R/work" && env -i HOME="$T/home" PATH="$T/stubs:/usr/bin:/bin" LANG=C.UTF-8 \
      HARNESS="$T/empty" HARNESS_ENV_DIR="$T/empty/env" ETC_HARNESS_ENV="$T/empty/env" \
      bash "$R/walk.sh" )
  cp "$T/calls.log" "$R/calls.log"
}

# rc_of <run-dir> <pattern> [<nth>]: the rc and out file of the nth command
# matching an ERE. Sets RC_ and OUT_; RC_ is "none" when there is no such line.
rc_of() {
  local row
  row=$(awk -F'\t' -v p="$2" '$3 ~ p' "$1/rc.tsv" | sed -n "${3:-1}p")
  RC_=$(cut -f2 <<< "$row"); OUT_="$1/out/$(cut -f1 <<< "$row")"
  [ -n "$row" ] || RC_=none
}

# check_w3 <run-dir>: rc 0 when the cp and both dry-run lines behaved.
check_w3() {
  local r1 r2
  rc_of "$1" '^cp env-templates/selfhost.conf.example selfhost.conf$'
  [ "$RC_" = 0 ] || { echo "W3: cp rc=$RC_"; return 1; }
  rc_of "$1" '^bin/selfhost-install.sh .*--dry-run' 1; r1=$RC_
  rc_of "$1" '^bin/selfhost-install.sh .*--dry-run' 2; r2=$RC_
  [ "$r1" = 1 ] || { echo "W3: dry-run on the template as copied rc=$r1, want 1"; return 1; }
  [ "$r2" = 0 ] || { echo "W3: dry-run on the filled config rc=$r2, want 0: $(tail -n 3 "$OUT_" 2>/dev/null)"; return 1; }
  grep -qE '^SUMMARY .*live_calls=0 writes=0' "$OUT_" || { echo "W3: no 'SUMMARY ... live_calls=0 writes=0' line"; return 1; }
}

# ── the walkthrough ─────────────────────────────────────────────────────────
W="$T/walk"
walk "$T/mirror/docs" "$W"
TR="$W/transcript.txt"

# W1
rc_of "$W" '^git clone https://github.com/cromford-ai/cromford$'
[ "$RC_" = 0 ] && [ -x "$W/work/cromford/bin/selfhost-install.sh" ] && ok \
  || bad "W1 clone rc=$RC_ or no cromford/bin/selfhost-install.sh"
# W2
rc_of "$W" '^bash tests/no-client-identifiers-test.sh$'
[ "$RC_" = 0 ] && ok || bad "W2 leak guard rc=$RC_"
# W3
msg=$(check_w3 "$W") && ok || bad "$msg"
# W4
rc_of "$W" '^bin/load-project.sh acme/widgets --project widgets --box hub1$'
[ "$RC_" = 0 ] && ok || bad "W4 load-project rc=$RC_: $(tail -n 3 "$OUT_" 2>/dev/null)"
grep -qE '^widgets[[:space:]]+acme/widgets[[:space:]]' "$W/work/cromford/fleet.conf" 2>/dev/null && ok \
  || bad "W4 no widgets row in the clone's fleet.conf"
origin_log=$(git -C "$T/origin.git" log --format=%s main 2>/dev/null)
grep -q '^load-project: widgets ' <<<"$origin_log" && ok \
  || bad "W4 the load-project commit did not reach the origin"
grep -q '^gh label create ai-build -R acme/widgets' "$W/calls.log" && ok || bad "W4 no 'gh label create ai-build -R acme/widgets' call"
# W5
grep -q '^gh issue create -R acme/widgets --label ai-build ' "$W/calls.log" && ok \
  || bad "W5 no 'gh issue create -R acme/widgets --label ai-build' call"
# W6
net=$(grep -E '^(wrangler|fly|flyctl|curl|wget) ' "$W/calls.log" || true)
[ -z "$net" ] && ok || bad "W6 a call that reaches an account: $net"
# W7
n_cmd=$(grep -c '^\$ ' "$TR"); n_rc=$(grep -c '^rc=' "$TR")
[ "$n_cmd" -ge 1 ] && [ "$n_cmd" = "$n_rc" ] && ok || bad "W7 $n_cmd commands but $n_rc rc= lines"
missing=""
while IFS=$'\t' read -r _ line; do
  line=$(fill_placeholders <<< "$line")
  grep -qxF -- "\$ $line" "$TR" || missing+=" [$line]"
done < <(fenced "$T/mirror/docs/quickstart.md"; enroll "$T/mirror/docs/onboarding-a-repo.md" | sed 's/^/7\t/')
[ -z "$missing" ] && ok || bad "W7 extracted but never run:$missing"
# W8
left=$(cut -f3 "$W/rc.tsv" | grep -oE '<[^<> ][^<>]*>' | sort -u | tr '\n' ' ')
[ -z "$left" ] && ok || bad "W8 placeholders the fill map does not cover: $left"
# W9
tok=$(grep -hiE 'bearer [A-Za-z0-9]' "$TR" "$W/calls.log" || true)
[ -z "$tok" ] && ok || bad "W9 a bearer token reached the transcript or the call log"

# M1: the same extractor and runner over a copy of the mirror's pages whose
# dry-run line carries an unknown flag. W3 must go red.
mkdir -p "$T/mut/docs"
cp "$T/mirror/docs/quickstart.md" "$T/mirror/docs/onboarding-a-repo.md" "$T/mut/docs/"
sed -i 's|^\(bin/selfhost-install.sh .*--dry-run\)$|\1 --no-such-flag|' "$T/mut/docs/quickstart.md"
grep -q -- '--dry-run --no-such-flag$' "$T/mut/docs/quickstart.md" || bad "M1 the mutation did not apply"
walk "$T/mut/docs" "$T/mutwalk"
if msg=$(check_w3 "$T/mutwalk"); then bad "M1 W3 stayed green with --no-such-flag on the dry-run line"
else ok; fi

echo "transcript: $TR"
[ -n "${HARNESS_WALKTHROUGH_OUT:-}" ] && cp "$TR" "$HARNESS_WALKTHROUGH_OUT"
echo "----- transcript -----"
cat "$TR"
echo "----- end transcript -----"
done_
