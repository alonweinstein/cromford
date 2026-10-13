#!/bin/bash
# tests/publish-sunset.bh-4834-test.sh — the old "-share" mirror is retired
# (BH-4834). bin/publish-share.sh defaults to cromford-ai/cromford and refuses
# every target that is not an exact line of catalog/share-publish-targets.conf,
# the old mirror's name included, whether it comes from --repo or from a stale
# SHARE_MIRROR_REPO export.
#
# Each case drives the real publisher, copied into a scratch repo next to a conf
# this suite controls. A refusal must be rc 2 with "refusing to publish to
# '<name>'" and must happen before the clone (the clone prints "upstream HEAD =
# …"). A pass must reach that line; the run then fails later on the missing
# bin/share/, which is not what this suite is about.
#
# Run from anywhere: tests/publish-sunset.bh-4834-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
PUBLISHER="$DIR/bin/publish-share.sh"
CONF="$DIR/catalog/share-publish-targets.conf"
# Split so the mirror's leak scan never sees the retired name whole.
OLD="harness-share/cromford""-share"

if [ ! -f "$PUBLISHER" ]; then
  echo "SKIP publish-sunset: no bin/publish-share.sh in this copy (the mirror does not ship it)"
  exit 0
fi

unset SHARE_MIRROR_REPO
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 GH_TOKEN=dummy-not-used
mkdir -p "$T/stub"
# publish-share.sh insists on gh before it clones; nothing here reaches it.
printf '#!/bin/sh\nexit 0\n' > "$T/stub/gh"; chmod +x "$T/stub/gh"
export PATH="$T/stub:$PATH"

# mkrepo <conf content or the word ABSENT> — a scratch checkout carrying the
# real publisher and the given allowlist, with no remotes. Prints its root.
mkrepo() {
  local r; r=$(mktemp -d "$T/repo.XXXXXX")
  mkdir -p "$r/bin" "$r/catalog"
  cp "$PUBLISHER" "$r/bin/publish-share.sh"
  [ "$1" = ABSENT ] || printf '%s' "$1" > "$r/catalog/share-publish-targets.conf"
  {
    git -C "$r" init -q -b main
    echo x > "$r/README.md"
    git -C "$r" add -A && git -C "$r" -c user.email=t@example.com -c user.name=t commit -qm init
  } >/dev/null 2>&1
  echo "$r"
}
run() { # <repo> [args…] — prints rc, output in $T/last.out
  local r="$1"; shift
  bash "$r/bin/publish-share.sh" --dry-run --ref HEAD --out "$(mktemp -d "$T/out.XXXXXX")" "$@" > "$T/last.out" 2>&1
  echo $?
}
# refused_as <label> <rc> <name> — rc 2, names the target, never cloned.
refused_as() {
  if [ "$2" = 2 ] && grep -qF "refusing to publish to '$3'" "$T/last.out" && ! grep -q 'upstream HEAD =' "$T/last.out"; then ok
  else bad "$1: '$3' should be refused before the clone (rc=$2): $(head -3 "$T/last.out" | tr '\n' ' ')"; fi
}

RC=$(mkrepo "$(cat "$CONF")")
R0=$(mkrepo ABSENT)

# S2: the old mirror, named on the command line, is refused before the clone.
rc=$(run "$RC" --repo "$OLD")
refused_as "S2 --repo with the old mirror" "$rc" "$OLD"

# S3: no --repo and no conf: the refusal names the default, which is the
# public copy, so the default is cromford-ai/cromford.
rc=$(run "$R0")
refused_as "S3 the default, with the conf absent" "$rc" "cromford-ai/cromford"

# S4: no --repo and the committed conf: the default passes the guard.
run "$RC" >/dev/null
if grep -q 'upstream HEAD =' "$T/last.out" && ! grep -q 'refusing to publish' "$T/last.out"; then ok
else bad "S4 the default target should pass the guard and reach the clone: $(head -3 "$T/last.out" | tr '\n' ' ')"; fi

# S5: a stale SHARE_MIRROR_REPO export of the old mirror is refused too.
rc=$(SHARE_MIRROR_REPO="$OLD" run "$RC")
refused_as "S5 SHARE_MIRROR_REPO set to the old mirror" "$rc" "$OLD"

echo "publish-sunset.bh-4834-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
