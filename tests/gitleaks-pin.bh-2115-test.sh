#!/bin/bash
# tests/gitleaks-pin.bh-2115-test.sh — BH-2115: THE POOL'S PRE-PR GATE RUNS
# GITLEAKS, AND THE PUBLISHER VERIFIES THE ONE IT DOWNLOADS.
#
# #2104 (BH-2059) made CI install a checksum-verified gitleaks 8.30.1 and set
# GITLEAKS_REQUIRED=1, so share-publish-clean fails instead of skipping its
# gitleaks arm. The pool's gate (bin/test-impact-gate.sh --runner isolated)
# still skipped it: the suites run under `env -i` with no REQUIRED and no
# gitleaks on the builder. And publish-cromford.yml unpacked its download unchecked.
#
#   P1  the pin (version AND sha256) is the same in bin/lib/gitleaks-pin.sh,
#       harness-ci.yml's install step and publish-cromford.yml's install step
#   W1  publish-cromford.yml's install step, EXECUTED with a curl that serves the
#       wrong tarball: nonzero, sha256sum says FAILED, sudo install never runs
#   W2  in that step the sha256 check comes before tar
#   E1  gitleaks_pin_ensure: the pinned binary already on PATH is used, no curl
#   E2  a tarball whose sha is not the pin is refused, nothing extracted, and
#       nothing left in the cache
#   E3  the download path: verified, extracted, cached; a second call is served
#       from the cache
#   E4  a corrupted cache is re-verified, refused and deleted
#   E5  an ambient gitleaks at another version is not used; the pin is fetched
#   G1  through the gate (--runner isolated, real root): a suite that probes
#       gitleaks sees the pinned binary from the snapshot's tools/
#   G2  ... and sees GITLEAKS_REQUIRED=1
#   G3  a selection with no gitleaks probe downloads nothing
#   G4  an install that cannot happen is rc 125 with the step named, no suite ran
#
# curl is always a stub: this suite never touches the network. G1-G4 need real
# root and a setpriv that can switch to nobody; elsewhere each is a named SKIP.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP $1"; }
BASH_BIN=$(command -v bash)
LIB="$DIR/bin/lib/gitleaks-pin.sh"
CI="$DIR/.github/workflows/harness-ci.yml"
PUB="$DIR/.github/workflows/publish-cromford.yml"

# step_body <workflow> <step-name-prefix> — the `run: |` body of the first step
# whose name starts with the prefix (case-insensitive), dedented. rc 1 if none.
step_body() {
  python3 - "$1" "$2" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
want = sys.argv[2].lower()
for i, l in enumerate(lines):
    m = re.match(r"^(\s*)- name:\s*(.*)$", l)
    if not (m and m.group(2).lower().startswith(want)):
        continue
    ind = len(m.group(1))
    for j in range(i + 1, len(lines)):
        s = lines[j]
        if re.match(r"^\s*- ", s) and len(s) - len(s.lstrip()) <= ind:
            break
        r = re.match(r"^(\s*)run:\s*\|\s*$", s)
        if not r:
            continue
        rind, body = len(r.group(1)), []
        for t in lines[j + 1:]:
            if t.strip() and len(t) - len(t.lstrip()) <= rind:
                break
            body.append(t)
        mi = min(len(t) - len(t.lstrip()) for t in body if t.strip())
        print("\n".join(t[mi:] for t in body).rstrip("\n"))
        sys.exit(0)
sys.exit(1)
PY
}

# A PATH with every directory that holds a gitleaks replaced by a symlink farm
# without it (the shape tests/share-gitleaks-required.bh-2059-test.sh uses).
no_gitleaks_path() {
  local out="" d i=0 f
  local IFS=:
  for d in $PATH; do
    [ -n "$d" ] || continue
    i=$((i+1))
    if [ -e "$d/gitleaks" ]; then
      mkdir -p "$T/shadow/$i"
      for f in "$d"/*; do
        [ "${f##*/}" = gitleaks ] || ln -sf "$f" "$T/shadow/$i/" 2>/dev/null
      done
      d="$T/shadow/$i"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}
NOGL=$(no_gitleaks_path)

# ── stubs ───────────────────────────────────────────────────────────────────
# curl: logs every call to $CURL_LOG, exits 22 under CURL_FAIL, otherwise copies
# $CURL_SERVE to the -o path.
mkdir -p "$T/curlbin" "$T/gl-pin" "$T/gl-old" "$T/fakepkg"
cat > "$T/curlbin/curl" <<SH
#!$BASH_BIN
echo "curl \$*" >> "\${CURL_LOG:-/dev/null}"
[ -n "\${CURL_FAIL:-}" ] && { echo "curl: (22) stub failure" >&2; exit 22; }
out=""
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { out=\$2; shift; }; shift; done
[ -n "\$out" ] || { echo "curl stub: no -o" >&2; exit 2; }
cp "\$CURL_SERVE" "\$out"
SH
printf '#!%s\necho "gitleaks version 8.30.1"\n' "$BASH_BIN" > "$T/gl-pin/gitleaks"
printf '#!%s\necho "gitleaks version 8.18.0"\n' "$BASH_BIN" > "$T/gl-old/gitleaks"
# The fake release: a tarball holding a gitleaks that reports 8.30.1. Its sha is
# NOT the pin, which is what E2 and W1 need; E3-E5 bless it in their own shell.
printf '#!/bin/bash\necho "8.30.1"\n' > "$T/fakepkg/gitleaks"
chmod +x "$T/curlbin/curl" "$T/gl-pin/gitleaks" "$T/gl-old/gitleaks" "$T/fakepkg/gitleaks"
FAKE_TGZ="$T/fake.tgz"
tar -czf "$FAKE_TGZ" -C "$T/fakepkg" gitleaks
FAKE_SHA=$(sha256sum "$FAKE_TGZ" | cut -d' ' -f1)
lines() { if [ -f "$1" ]; then grep -c . < "$1"; else echo 0; fi; }

# ── P1. one pin, three copies ───────────────────────────────────────────────
PIN=$( [ -f "$LIB" ] && env -i PATH="$PATH" "$BASH_BIN" -c '. "$1" && echo "$GITLEAKS_PIN_VERSION $GITLEAKS_PIN_SHA256"' _ "$LIB" 2>/dev/null)
CI_BODY=$(step_body "$CI" "install gitleaks")
PUB_BODY=$(step_body "$PUB" "install gitleaks")
CI_PIN="$(printf '%s\n' "$CI_BODY" | sed -n 's/^V=\([0-9][0-9.]*\).*/\1/p' | head -1) $(printf '%s\n' "$CI_BODY" | sed -n 's/^SHA=\([0-9a-f]\{64\}\)$/\1/p' | head -1)"
PUB_PIN="$(printf '%s\n' "$PUB_BODY" | sed -n 's/^V=\([0-9][0-9.]*\).*/\1/p' | head -1) $(printf '%s\n' "$PUB_BODY" | sed -n 's/^SHA=\([0-9a-f]\{64\}\)$/\1/p' | head -1)"
if ! grep -qE '^[0-9]+\.[0-9]+\.[0-9]+ [0-9a-f]{64}$' <<<"$PIN"; then
  bad "P1: bin/lib/gitleaks-pin.sh must define GITLEAKS_PIN_VERSION and a 64-hex GITLEAKS_PIN_SHA256 (got '$PIN')"
elif [ "$PIN" = "$CI_PIN" ] && [ "$PIN" = "$PUB_PIN" ]; then ok
else bad "P1: the gitleaks pin differs — lib '$PIN', harness-ci.yml '$CI_PIN', publish-cromford.yml '$PUB_PIN'"
fi

# ── W1/W2. publish-cromford.yml's install step, executed ───────────────────────
# The step writes fixed /tmp paths; they are moved under $T so a run of this
# suite cannot collide with anything else on the box. Nothing else is changed.
mkdir -p "$T/wtmp" "$T/wbin"
printf '#!%s\necho "sudo $*" >> "%s"\n' "$BASH_BIN" "$T/sudo.log" > "$T/wbin/sudo"
chmod +x "$T/wbin/sudo"
if [ -z "$PUB_BODY" ]; then
  bad "W1: could not extract publish-cromford.yml's 'Install gitleaks' run body"
  bad "W2: could not extract publish-cromford.yml's 'Install gitleaks' run body"
else
  printf '%s\n' "$PUB_BODY" | sed "s#/tmp/#$T/wtmp/#g" > "$T/w1.sh"
  : > "$T/sudo.log"
  env PATH="$T/wbin:$T/curlbin:$NOGL" CURL_SERVE="$FAKE_TGZ" CURL_LOG="$T/w1.curl" \
    "$BASH_BIN" -e "$T/w1.sh" > "$T/w1.out" 2>&1; RC=$?
  [ "$RC" != 0 ] && ok || bad "W1: a tarball that is not the pinned release must fail the step (rc $RC: $(tr '\n' '|' < "$T/w1.out"))"
  grep -q 'FAILED' "$T/w1.out" && ok || bad "W1: sha256sum must report the mismatch (got: $(tr '\n' '|' < "$T/w1.out"))"
  [ -s "$T/sudo.log" ] && bad "W1: an unverified gitleaks must never be installed (sudo ran: $(tr '\n' '|' < "$T/sudo.log"))" || ok
  [ "$(lines "$T/w1.curl")" = 1 ] && ok || bad "W1: the step must have downloaded once (curl calls: $(lines "$T/w1.curl"))"
  SHA_LN=$(printf '%s\n' "$PUB_BODY" | grep -n 'sha256sum -c' | grep '\$SHA' | grep '/tmp/gl.tgz' | head -1 | cut -d: -f1)
  TAR_LN=$(printf '%s\n' "$PUB_BODY" | grep -n '^tar ' | head -1 | cut -d: -f1)
  if [ -n "$SHA_LN" ] && [ -n "$TAR_LN" ] && [ "$SHA_LN" -lt "$TAR_LN" ]; then ok
  else bad "W2: 'echo \"\$SHA  /tmp/gl.tgz\" | sha256sum -c -' must come before tar (sha line '$SHA_LN', tar line '$TAR_LN')"
  fi
fi

# ── E1-E5. gitleaks_pin_ensure ──────────────────────────────────────────────
# ensure <case> <PATH> [sha-override] — runs the function in a fresh shell,
# dest $T/<case>/dest, cache $T/<case>/cache unless ENSURE_CACHE is set.
ensure() {
  local c="$1" p="$2" sha="${3:-}"
  mkdir -p "$T/$c/dest"
  env -i PATH="$p" HOME="$T" CURL_SERVE="$FAKE_TGZ" CURL_LOG="$T/$c/curl.log" CURL_FAIL="${CURL_FAIL:-}" \
      GITLEAKS_PIN_CACHE="${ENSURE_CACHE:-$T/$c/cache}" \
    "$BASH_BIN" -c '. "$1" || exit 99
                    [ -n "$2" ] && GITLEAKS_PIN_SHA256=$2
                    gitleaks_pin_ensure "$3"' _ "$LIB" "$sha" "$T/$c/dest" \
    > "$T/$c/out" 2> "$T/$c/err"
}

ensure e1 "$T/gl-pin:$T/curlbin:$NOGL"; RC=$?
[ "$RC" = 0 ] && ok || bad "E1: the pinned gitleaks on PATH must satisfy ensure (rc $RC: $(cat "$T/e1/err"))"
[ -x "$T/e1/dest/gitleaks" ] && ok || bad "E1: the pinned binary must be placed in the dest dir"
[ "$(lines "$T/e1/curl.log")" = 0 ] && ok || bad "E1: nothing may be downloaded when the pin is already on PATH (curl calls: $(lines "$T/e1/curl.log"))"

if [ "$(uname -sm)" != "Linux x86_64" ]; then
  for c in E2 E3 E4 E5; do skip "$c: the pinned asset is linux_x64 and this is $(uname -sm)"; done
else
  ensure e2 "$T/curlbin:$NOGL"; RC=$?
  [ "$RC" = 1 ] && ok || bad "E2: a tarball whose sha is not the pin must be refused with rc 1 (got $RC: $(cat "$T/e2/err"))"
  grep -q 'sha256' "$T/e2/err" && ok || bad "E2: the refusal must name the sha256 check (got: $(cat "$T/e2/err"))"
  [ -e "$T/e2/dest/gitleaks" ] && bad "E2: nothing may be extracted from an unverified tarball" || ok
  [ -n "$(ls -A "$T/e2/cache" 2>/dev/null)" ] && bad "E2: an unverified tarball must not stay in the cache (left: $(ls -A "$T/e2/cache"))" || ok

  ensure e3 "$T/curlbin:$NOGL" "$FAKE_SHA"; RC=$?
  [ "$RC" = 0 ] && ok || bad "E3: a verified download must install (rc $RC: $(cat "$T/e3/err"))"
  [ "$("$T/e3/dest/gitleaks" version 2>/dev/null)" = 8.30.1 ] && ok || bad "E3: the extracted gitleaks must be the release's"
  [ -f "$T/e3/cache/gitleaks_8.30.1_linux_x64.tar.gz" ] && ok || bad "E3: the verified tarball must be cached (cache: $(ls -A "$T/e3/cache" 2>/dev/null))"
  rm -rf "$T/e3/dest"
  ensure e3 "$T/curlbin:$NOGL" "$FAKE_SHA"; RC=$?
  [ "$RC" = 0 ] && [ -x "$T/e3/dest/gitleaks" ] && ok || bad "E3: the second call must install from the cache (rc $RC: $(cat "$T/e3/err"))"
  [ "$(lines "$T/e3/curl.log")" = 1 ] && ok || bad "E3: the second call must not download again (curl calls: $(lines "$T/e3/curl.log"))"

  # E4: the cache E3 left, corrupted; the network is gone.
  mkdir -p "$T/e4"
  echo junk >> "$T/e3/cache/gitleaks_8.30.1_linux_x64.tar.gz"
  rm -rf "$T/e4/dest"
  CURL_FAIL=1 ENSURE_CACHE="$T/e3/cache" ensure e4 "$T/curlbin:$NOGL" "$FAKE_SHA"; RC=$?
  [ "$RC" = 1 ] && ok || bad "E4: a corrupted cache must be refused (rc $RC: $(cat "$T/e4/err"))"
  [ -e "$T/e3/cache/gitleaks_8.30.1_linux_x64.tar.gz" ] && bad "E4: the corrupted cache entry must be deleted" || ok
  [ -e "$T/e4/dest/gitleaks" ] && bad "E4: nothing may be extracted from a corrupted cache" || ok

  ensure e5 "$T/gl-old:$T/curlbin:$NOGL" "$FAKE_SHA"; RC=$?
  [ "$RC" = 0 ] && ok || bad "E5: an ambient 8.18.0 must not stop the pinned install (rc $RC: $(cat "$T/e5/err"))"
  [ "$(lines "$T/e5/curl.log")" = 1 ] && ok || bad "E5: an ambient 8.18.0 is not the pin and must be replaced by a download (curl calls: $(lines "$T/e5/curl.log"))"
  [ "$("$T/e5/dest/gitleaks" version 2>/dev/null)" = 8.30.1 ] && ok || bad "E5: the dest gitleaks must be the pinned one, not the ambient 8.18.0"
fi

# ── G1-G4. through bin/test-impact-gate.sh --runner isolated ────────────────
if [ "$(id -u)" != 0 ] || ! command -v setpriv >/dev/null 2>&1 \
   || ! setpriv --reuid="$(id -u nobody 2>/dev/null)" --regid="$(id -g nobody 2>/dev/null)" --clear-groups true >/dev/null 2>&1; then
  for c in G1 G2 G3 G4; do skip "$c: the isolated runner needs real root and a setpriv that can switch to nobody"; done
else
  NOW=$(date +%s)
  export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"
  R="$T/repo"
  mkdir -p "$R/bin/lib" "$R/tests" "$T/live-harness" "$T/state"
  for f in bin/test-impact.sh bin/test-impact-gate.sh bin/test-suite-run.sh bin/lib/suite-runner.sh \
           bin/lib/train-shape.sh bin/lib/gitleaks-pin.sh bin/ci-tool-present.sh; do
    [ -f "$DIR/$f" ] && cp "$DIR/$f" "$R/$f"
  done
  chmod +x "$R/bin/"*.sh 2>/dev/null
  printf '#!/bin/bash\necho "base: 1 passed, 0 failed"\n' > "$R/tests/base-test.sh"
  gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
  gitc init -q; gitc add -A; gitc commit -qm base
  BASE=$(git -C "$R" rev-parse HEAD)
  # The probing suite, as share-publish-clean probes.
  gitc checkout -q -b probe
  cat > "$R/tests/gl-probe-test.sh" <<'SH'
#!/bin/bash
if p=$(command -v gitleaks); then echo "GL_PATH=$p"; echo "GL_VER=$(gitleaks version)"; else echo "GL_PATH=none"; fi
echo "GITLEAKS_REQUIRED=${GITLEAKS_REQUIRED:-unset}"
echo "gl-probe: 1 passed, 0 failed"
SH
  gitc add -A; gitc commit -qm probe
  # A suite that only TALKS about gitleaks.
  gitc checkout -q -b comment "$BASE"
  cat > "$R/tests/gl-comment-test.sh" <<'SH'
#!/bin/bash
# This suite mentions gitleaks in a comment and never looks for it.
echo "GITLEAKS_REQUIRED=${GITLEAKS_REQUIRED:-unset}"
echo "gl-comment: 1 passed, 0 failed"
SH
  gitc add -A; gitc commit -qm comment
  gate() { # gate <case> <branch> <PATH> [VAR=value ...]
    local c="$1" b="$2" p="$3"; shift 3
    gitc checkout -q -f "$b"
    # HARNESS points at scratch so the gate never sources the live harness's
    # lane-gate.sh, whose settings reads would reach the curl stub as well.
    ( cd "$R" && env -u HARNESS_SECRET "$@" HARNESS="$T/h" PATH="$p" CURL_SERVE="$FAKE_TGZ" CURL_LOG="$T/$c.curl" \
        GITLEAKS_PIN_CACHE="$T/$c.cache" HARNESS_STATE_DIR="$T/state" \
        TEST_IMPACT_DURATIONS_FILE="$T/state/durations.tsv" HARNESS_ROOT_OVERRIDE="$T/live-harness" \
        bin/test-impact-gate.sh --base "$BASE" --runner isolated ) > "$T/$c.out" 2>&1
  }

  gate g1 probe "$T/gl-pin:$T/curlbin:$NOGL"; RC=$?
  [ "$RC" = 0 ] && ok || bad "G1: a pinned gitleaks on the builder must run the probing suite green (rc $RC: $(tail -5 "$T/g1.out" | tr '\n' '|'))"
  grep -q '^GL_PATH=.*/iso/tools/gitleaks$' "$T/g1.out" && ok || bad "G1: the suite must see the gate's pinned copy in the snapshot's tools/ (got: $(grep '^GL_' "$T/g1.out" | tr '\n' '|'))"
  grep -q '^GL_VER=gitleaks version 8.30.1$' "$T/g1.out" && ok || bad "G1: the suite's gitleaks must report 8.30.1 (got: $(grep '^GL_VER' "$T/g1.out"))"
  grep -q 'impact-gate: gitleaks 8.30.1 ready' "$T/g1.out" && ok || bad "G1: the gate must say gitleaks is ready (got: $(grep -i gitleaks "$T/g1.out" | head -3 | tr '\n' '|'))"
  [ "$(lines "$T/g1.curl")" = 0 ] && ok || bad "G1: the pin on PATH must not be downloaded again (curl calls: $(lines "$T/g1.curl"); gate: $(grep -i gitleaks "$T/g1.out" | grep -v '^GL_' | tr '\n' '|'))"
  # G2
  grep -qx 'GITLEAKS_REQUIRED=1' "$T/g1.out" && ok || bad "G2: the isolated runner must hand the suites GITLEAKS_REQUIRED=1 (got: $(grep '^GITLEAKS_REQUIRED' "$T/g1.out"))"

  gate g3 comment "$T/curlbin:$NOGL"; RC=$?
  [ "$RC" = 0 ] && ok || bad "G3: a selection with no gitleaks probe must run as before (rc $RC: $(tail -5 "$T/g3.out" | tr '\n' '|'))"
  grep -q 'impact-gate: done tests/gl-comment-test.sh rc=0' "$T/g3.out" && ok || bad "G3: the comment-only suite must have run (got: $(grep 'impact-gate: done' "$T/g3.out" | tr '\n' '|'))"
  [ "$(lines "$T/g3.curl")" = 0 ] && ok || bad "G3: nothing may be downloaded for a selection that never probes gitleaks (curl calls: $(lines "$T/g3.curl"))"
  grep -q 'gitleaks .* ready' "$T/g3.out" && bad "G3: no gitleaks install may run for a selection that never probes gitleaks" || ok
  grep -qx 'GITLEAKS_REQUIRED=1' "$T/g3.out" && ok || bad "G2: GITLEAKS_REQUIRED=1 must reach every isolated suite, triggered or not (got: $(grep '^GITLEAKS_REQUIRED' "$T/g3.out"))"

  gate g4 probe "$T/curlbin:$NOGL" CURL_FAIL=1; RC=$?
  [ "$RC" = 125 ] && ok || bad "G4: an install that cannot happen must be rc 125, never a pass or a red suite (got $RC: $(tail -5 "$T/g4.out" | tr '\n' '|'))"
  grep -q 'gitleaks 8.30.1 could not be installed' "$T/g4.out" && ok || bad "G4: the refusal must name the gitleaks step (got: $(tail -3 "$T/g4.out" | tr '\n' '|'))"
  grep -q 'impact-gate: done' "$T/g4.out" && bad "G4: no suite may run when gitleaks could not be installed" || ok
  [ "$(lines "$T/g4.curl")" = 1 ] && ok || bad "G4: the gate must have tried the download (curl calls: $(lines "$T/g4.curl"))"
fi

echo "gitleaks-pin.bh-2115-test: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
