#!/bin/bash
# tests/share-publish-clean.bh-795-test.sh — the commit as it stands must publish.
#
# bin/publish-share.sh builds a sanitized mirror and then refuses to push it if
# any gate finds an identifier or a credential. Those gates only ever ran in the
# publish workflow, so the tree drifted red without anybody noticing: three
# self-declaring fixtures, a new `.jsonl` fixture and a test stub address landed
# over two days in September 2026 and every scheduled publish since refused —
# 34 hits by the time somebody looked. Nothing in CI said so, because nothing
# in CI ran the gates.
#
# This test runs them, in the publisher's own order, over the same input the
# publisher uses: the COMMITTED tree (`git archive HEAD`), never the working
# tree, because a publish is a function of a sha. It is deliberately the slow
# kind of test (the sanitizer copies the whole tree, ~30s): the alternative is
# finding out on the next merge to main. The build itself comes from
# tests/lib/share-mirror.sh, which makes it once per tree and lets the other
# share suites read the same one (BH-5543).
#
# The export also gets one planted build record (BH-5055): a plan under
# .harness/specs/ with a KEY=value line gitleaks reads as a key. Every arm then
# runs over a tree carrying it, and the built mirror must have no .harness path.
#
# Run from anywhere: tests/share-publish-clean.bh-795-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/share-mirror.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Arm 4 may skip on a laptop with no gitleaks, never where GITLEAKS_REQUIRED is
# set (CI's shard step, BH-2059). It fails before the sanitize work: a runner
# missing a required tool is the headline, and the other arms can wait for it.
if [ -n "${GITLEAKS_REQUIRED:-}" ] && ! command -v gitleaks >/dev/null 2>&1; then
  echo "FAIL: gitleaks-gate: GITLEAKS_REQUIRED is set but gitleaks is not on PATH — CI must run the gate, never skip it (BH-2059)"
  echo "share-publish-clean.bh-795-test: 0 pass, 1 fail, 0 skip"
  exit 1
fi

# 0-1. the mirror the publisher would push, built from the committed tree at
#      HEAD the way publish-share.sh builds it, plus one planted build record
#      (BH-5055) whose value is built at run time, never spelled.
#      tests/lib/share-mirror.sh builds it once per tree and the other share
#      suites read the same build (BH-5543). An unapplied PATCH anchor fails
#      sanitize here too, which is the same failure the publisher would hit.
share_mirror_get "$DIR"
if [ $? -eq 3 ]; then
  echo "FAIL: cannot export HEAD — no tree to check"
  echo "share-publish-clean.bh-795-test: 0 pass, 1 fail, 0 skip"
  exit 1
fi
rc=$SM_SANITIZE_RC
if [ "$rc" -eq 0 ]; then ok; else
  bad "sanitize.py exited $rc — no mirror to scan"
  sed -n '1,30p' "$SM_SANITIZE_OUT"
  echo "share-publish-clean.bh-795-test: $PASS pass, $FAIL fail, $SKIP skip"
  exit 1
fi
M=$SM_MIRROR

# 1b. no build record reaches the mirror (BH-5055).
if [ -z "$(find "$M" \( -path "$M/.harness" -o -path "$M/.harness/*" \) | head -1)" ]; then ok
else bad "the mirror carries .harness/ — build records must not ship (BH-5055)"; fi

# 2. the publisher's own guard, over the built mirror.
#
#    The second half of this check is there because a clean guard is not by
#    itself proof that a real id was REWRITTEN: allowlisting one would also read
#    clean while the id shipped. So every hosting project id in the source tree's
#    registry has to be absent from the mirror, whatever the allowlists say. The
#    real ids are never spelled here — they are read out of the source tree.
python3 "$DIR/bin/share/leakcheck.py" "$M" > "$T/leak.out" 2>&1
rc=$?
survivors=0
while read -r id; do
  case "$id" in prj_EXAMPLE*|team_EXAMPLE*) continue ;; esac
  grep -rqF "$id" "$M" && survivors=$((survivors+1))
done < <(grep -hoE '\b(prj|team)_[A-Za-z0-9]{20,}' "$SM_SRC/vercel.conf" | sort -u)
if [ "$rc" -eq 0 ] && grep -q '^leakcheck: clean' "$T/leak.out" && [ "$survivors" -eq 0 ]; then
  ok
elif [ "$rc" -ne 0 ] || ! grep -q '^leakcheck: clean' "$T/leak.out"; then
  bad "leakcheck refused the built mirror (rc=$rc). Every line below would ship:"
  cat "$T/leak.out"
else
  # The ids are not printed: this output goes to CI logs.
  bad "$survivors real hosting project id(s) from vercel.conf reached the mirror unrewritten — each needs an ACCOUNT_IDS rewrite in bin/share/mapping.py, never an allowlist entry"
fi

# 3. the copy of the guard that SHIPS in the mirror, run against the mirror —
#    publish-share.sh runs exactly this, and a copy that allowlists less than
#    the publisher's refuses at the last step before the push.
bash "$M/tests/no-client-identifiers-test.sh" > "$T/shipped.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^PASS:' "$T/shipped.out"; then ok; else
  bad "the mirror's shipped guard refused the mirror (rc=$rc):"
  cat "$T/shipped.out"
fi

# 4. the second opinion. Counted as a SKIP when the binary is absent, never as
#    a pass: a scanner that reports clean because it never ran is the answer
#    this whole file exists to stop. The gate writes .gitleaksignore into the
#    tree it scans, so it runs on a private copy of the shared build.
if command -v gitleaks >/dev/null 2>&1; then
  share_mirror_copy "$T/mirror"
  python3 "$DIR/bin/share/gitleaks-gate.py" "$T/mirror" > "$T/gitleaks.out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then ok; else
    bad "gitleaks-gate refused the built mirror (rc=$rc):"
    cat "$T/gitleaks.out"
  fi
else
  SKIP=$((SKIP+1))
  echo "SKIP gitleaks-gate: gitleaks not on PATH (the publish workflow installs 8.30.1 and CI sets GITLEAKS_REQUIRED; run this suite with it on PATH before trusting a publish)"
fi

# 5. THE GENERATED INDEX REACHES THE MIRROR (BH-1175).
#    docs/verification-map/README.md is generated and git-ignored, so
#    bin/publish-share.sh builds it into the checkout before sanitizing. The
#    mirror tree is a copy of the repo, `.gitignore` included, so the publisher's
#    `git add -A` SKIPS the one file that step exists to produce — a reader of
#    the public mirror would land on 221 entry files and no index to read them
#    through. The publisher forces that one path; this drives the same two
#    commands over the real built mirror and asserts the file is staged. The
#    shared build ran the index build before sanitize, in the publisher's
#    order; `git init` writes, so this works on a private copy.
if [ -x "$SM_SRC/bin/verification-map-build.sh" ]; then
  share_mirror_copy "$T/mirror2"
  if [ -f "$T/mirror2/docs/verification-map/README.md" ]; then ok
  else bad "5 the sanitizer must carry the generated index into the mirror"; fi
  ( cd "$T/mirror2" && GIT_CONFIG_GLOBAL="$T/gitcfg5" GIT_CONFIG_NOSYSTEM=1 \
      git init --quiet -b main >/dev/null 2>&1 \
      && git -c user.email=t@example.com -c user.name=t add -A >/dev/null 2>&1 )
  # `add -A` ALONE must MISS it. This is the gap itself: if the mirror ever
  # stops inheriting .gitignore this assertion turns red and the `-f` below
  # becomes dead weight somebody should delete deliberately, rather than a line
  # nobody can explain.
  UNSTAGED5=$(cd "$T/mirror2" && GIT_CONFIG_GLOBAL="$T/gitcfg5" GIT_CONFIG_NOSYSTEM=1 \
      git ls-files -- docs/verification-map/README.md 2>/dev/null)
  if [ -z "$UNSTAGED5" ]; then ok
  else bad "5 'git add -A' already staged the index, so the mirror does not inherit .gitignore any more — the add -f in bin/publish-share.sh is now redundant, remove it on purpose"; fi
  # The publisher's own forcing line, run the same way it runs.
  ( cd "$T/mirror2" && GIT_CONFIG_GLOBAL="$T/gitcfg5" GIT_CONFIG_NOSYSTEM=1 \
      git add -f -- docs/verification-map/README.md >/dev/null 2>&1 )
  STAGED5=$(cd "$T/mirror2" && GIT_CONFIG_GLOBAL="$T/gitcfg5" GIT_CONFIG_NOSYSTEM=1 \
      git ls-files -- docs/verification-map/README.md 2>/dev/null)
  if [ -n "$STAGED5" ]; then ok
  else bad "5 the generated index must be STAGED in the mirror — the mirror inherits .gitignore, so add -A alone skips it"; fi
  # And the publisher must actually carry that line, or the two commands above
  # are a property of this test rather than of the publisher.
  if grep -q 'add -f -- docs/verification-map/README.md' "$DIR/bin/publish-share.sh"; then ok
  else bad "5 bin/publish-share.sh does not force the generated index into the mirror, so the mirror ships without an index"; fi
else
  SKIP=$((SKIP+1))
  echo "SKIP 5: no bin/verification-map-build.sh in the exported tree"
fi

echo "share-publish-clean.bh-795-test: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
