#!/bin/bash
# bin/ci-shellcheck.sh — the lint job's shellcheck, pinned and cached (BH-1200).
#
# WHAT WAS ACTUALLY SLOW. After the CI shards (#1197) the whole run's critical
# path was "Syntax + shellcheck + config integrity" at ~12 minutes, and the
# ticket's guess was `apt-get install shellcheck`. It is not. On run
# 35593567939 the step ran 11m42s of an 11m50s job and emitted nothing at all,
# and the same corpus takes 3m17s on an idle M-series laptop with `user` time
# equal to `real` — ShellCheck is single-threaded, 367 files is simply that much
# work, and a contended shared vCPU turns three minutes into twelve. Caching the
# BINARY alone would have saved seconds and left the ticket's own acceptance
# ("under 4 minutes") unmet on every run.
#
# So this script attacks the work, not the install, in three layers:
#
#   1. THE FINDINGS ARE CACHED PER FILE, keyed on the ShellCheck version the
#      binary REPORTS, the flags, the path, and the sha256 of the file's
#      contents. An unchanged file is never re-linted. Keying the whole corpus
#      with one hash would have been easier and useless: every PR touches a
#      script, and one touched script would have invalidated all 367.
#   2. THE MISSES RUN IN PARALLEL. ShellCheck uses one core no matter how many
#      files it is handed, so the cold run — the first PR after the cache is
#      cold, and nothing else — is split across `--jobs` processes.
#   3. THE BINARY IS PINNED AND NEVER apt-INSTALLED. The pinned release tarball
#      is fetched from the koalaman GitHub release with its sha256 verified
#      here, then kept in the cache directory. `apt-get` is not reachable from
#      this file.
#
# WHY PER-FILE CACHING IS SOUND. The cache key is (version, flags, path,
# contents). That is safe because ShellCheck at `--severity=error` has no
# check that depends on definitions imported from a sourced file: the same
# file produces the same error-level findings whether it is checked alone or
# alongside its sources. It is NOT safe at warning severity, where cross-file
# checks such as SC2128 do depend on sourced definitions; that is why this
# script only ever caches `--severity=error`. The assumption is not taken on
# faith: tests/ci-shellcheck-cache.bh-1200-test.sh measures it against the real
# binary, and tests/ci-shellcheck-cross-file.bh-1246-test.sh keeps a canary
# pair that goes red if a future severity bump ever makes the per-file key
# unsound.
#
# WHY --format=gcc. The default tty format ends each INVOCATION with a "For
# more information:" footer listing the codes it saw. One footer per file is not
# the same bytes as one footer per run, so per-file results could never be
# replayed faithfully in that format. `gcc` is one finding per line with no
# per-run trailer, which is both cacheable and easier to grep in a log.
#
# THE KEY IS THE REPORTED VERSION, NOT THE PIN. A cache keyed on the constant
# below would be reused across a binary that reports something else — exactly
# the silent-staleness this is supposed to prevent. The version is read out of
# the binary that is about to run.
#
# THREE OUTCOMES, NEVER TWO. rc 0 (clean) and rc 1 (findings) are both real
# verdicts and both cached. rc >= 2 is ShellCheck failing to run — a broken
# binary, an unreadable file — and is NEVER cached, or one bad run would pin a
# fake "clean" forever.
#
#   ci-shellcheck.sh [--jobs N] [--cache-dir DIR] <file>...
#
# Env: SHELLCHECK_BIN     use exactly this binary (skips resolution)
#      BH_SHELLCHECK_JOBS default for --jobs
#      BH_SHELLCHECK_CACHE default for --cache-dir
#
# It writes only under the cache directory, which defaults inside $RUNNER_TEMP —
# docs/CI-RUNNERS.md: a job may write under $RUNNER_TEMP or the checkout and
# nowhere else, because the Fly runners share a 7.8 GB rootfs.
set -uo pipefail

SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
DIR=$(cd "$(dirname "$0")/.." && pwd)

# The pin. Bump these three together — the sha256s are of the release tarballs
# at github.com/koalaman/shellcheck/releases/download/v<PIN>/ and a mismatch is
# fatal rather than a warning.
SHELLCHECK_PIN=0.11.0
SHELLCHECK_SHA256_x86_64=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
SHELLCHECK_SHA256_aarch64=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588

# The flags are part of the cache key, so they live in one string rather than
# being spelled at the call site: a flag changed in one place and not the other
# would replay findings that were produced under different rules.
SC_FLAGS="--severity=error --format=gcc"

die() { echo "ci-shellcheck: $*" >&2; exit 2; }

# sha256sum (Linux/CI) or shasum -a 256 (macOS, where the gates are also run).
if command -v sha256sum >/dev/null 2>&1; then
  sha256_stdin() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_stdin() { shasum -a 256 | cut -d' ' -f1; }
else
  die "no sha256sum and no shasum — cannot key the cache or verify a download"
fi
sha256_file() { sha256_stdin < "$1"; }

# ── the child half: lint exactly one file and record the verdict ────────────
# Re-entry from xargs. Kept in this file so there is one definition of the key
# and one definition of the record format; a second script would drift.
if [ "${1:-}" = "--lint-one" ]; then
  F="$2"
  SC="${BH_SC_BIN:?}"; VER="${BH_SC_VER:?}"; CACHE="${BH_SC_CACHE:?}"
  KEY=$(printf '%s\037%s\037%s\037%s' "$VER" "$SC_FLAGS" "$F" "$(sha256_file "$F")" | sha256_stdin)
  OUT=$("$SC" $SC_FLAGS "$F" 2>&1); RC=$?
  if [ "$RC" -ge 2 ]; then
    # Tool failure. Never cached, and loud: a silent skip here is a file that
    # stops being linted and nobody notices.
    printf '%s\n' "$OUT" > "$CACHE/fatal/$KEY"
    exit "$RC"
  fi
  # Written aside and moved: several of these run at once and a half-written
  # record read by the next run would replay truncated findings as the truth.
  printf 'rc %s\n' "$RC" > "$CACHE/results/.tmp.$KEY.$$"
  [ -n "$OUT" ] && printf '%s\n' "$OUT" >> "$CACHE/results/.tmp.$KEY.$$"
  mv -f "$CACHE/results/.tmp.$KEY.$$" "$CACHE/results/$KEY"
  exit 0
fi

# ── arguments ───────────────────────────────────────────────────────────────
JOBS="${BH_SHELLCHECK_JOBS:-}"
CACHE="${BH_SHELLCHECK_CACHE:-${RUNNER_TEMP:-/tmp}/bh-shellcheck-cache}"
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) JOBS="${2:?--jobs needs a number}"; shift 2 ;;
    --cache-dir) CACHE="${2:?--cache-dir needs a path}"; shift 2 ;;
    --) shift; while [ $# -gt 0 ]; do FILES+=("$1"); shift; done ;;
    -*) die "unknown option $1" ;;
    *) FILES+=("$1"); shift ;;
  esac
done
[ ${#FILES[@]} -gt 0 ] || die "no files named — usage: ci-shellcheck.sh [--jobs N] [--cache-dir DIR] <file>..."

if [ -z "$JOBS" ]; then
  # Capped at 4 on purpose. Up to twelve runners share one Fly machine
  # (docs/CI-RUNNERS.md), so `nproc` is the machine's cores, not this job's
  # share, and -P nproc from every job at once is slower than -P 4 from each.
  N=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
  JOBS=$(( N > 4 ? 4 : N ))
  [ "$JOBS" -ge 1 ] || JOBS=1
fi

# ── resolve the binary: env, PATH at the pin, cache, then download ──────────
mkdir -p "$CACHE/results" "$CACHE/fatal" "$CACHE/bin" || die "cannot create cache under $CACHE"
BINDIR="$CACHE/bin/shellcheck-$SHELLCHECK_PIN"

resolve() {
  if [ -n "${SHELLCHECK_BIN:-}" ]; then
    [ -x "$SHELLCHECK_BIN" ] || die "SHELLCHECK_BIN=$SHELLCHECK_BIN is not executable"
    SC="$SHELLCHECK_BIN"; SRC="SHELLCHECK_BIN"; return 0
  fi
  # The same presence helper every other install step in the workflow uses
  # (BH-1206): on PATH AND reporting exactly the pin, or it does not count.
  if "$DIR/bin/ci-tool-present.sh" shellcheck "$SHELLCHECK_PIN" >/dev/null 2>&1; then
    SC=$(command -v shellcheck); SRC="PATH"; return 0
  fi
  if [ -x "$BINDIR/shellcheck" ] &&
     PATH="$BINDIR:$PATH" "$DIR/bin/ci-tool-present.sh" shellcheck "$SHELLCHECK_PIN" >/dev/null 2>&1; then
    SC="$BINDIR/shellcheck"; SRC="cache"; return 0
  fi
  download
}

download() {
  local arch want url tmp got
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)  arch=x86_64;  want="$SHELLCHECK_SHA256_x86_64" ;;
    aarch64|arm64) arch=aarch64; want="$SHELLCHECK_SHA256_aarch64" ;;
    *) die "no pinned ShellCheck $SHELLCHECK_PIN tarball for $arch — pin one before CI runs there" ;;
  esac
  command -v curl >/dev/null 2>&1 || die "curl is unavailable and ShellCheck $SHELLCHECK_PIN is not present"
  url="https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_PIN/shellcheck-v$SHELLCHECK_PIN.linux.$arch.tar.xz"
  tmp="$CACHE/bin/.dl.$$"
  rm -rf "$tmp"; mkdir -p "$tmp" || die "cannot stage a download under $CACHE/bin"
  curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/sc.tar.xz" "$url" || { rm -rf "$tmp"; die "download failed: $url"; }
  got=$(sha256_file "$tmp/sc.tar.xz")
  if [ "$got" != "$want" ]; then
    rm -rf "$tmp"
    die "sha256 mismatch for $url — expected $want, got $got"
  fi
  tar -xJf "$tmp/sc.tar.xz" -C "$tmp" || { rm -rf "$tmp"; die "cannot unpack $url"; }
  mkdir -p "$BINDIR"
  install -m 755 "$tmp/shellcheck-v$SHELLCHECK_PIN/shellcheck" "$BINDIR/shellcheck" ||
    { rm -rf "$tmp"; die "cannot install the downloaded ShellCheck into $BINDIR"; }
  rm -rf "$tmp"
  SC="$BINDIR/shellcheck"; SRC="download"
}

resolve

# The version the binary REPORTS, which is what the key is built from. A binary
# that cannot say what it is has no business producing cached verdicts.
VER=$("$SC" --version 2>&1 | sed -n 's/^version: *//p' | head -1)
[ -n "$VER" ] || die "$SC did not report a version — refusing to key a cache on an unknown ShellCheck"
echo "ci-shellcheck: ShellCheck $VER ($SRC: $SC), flags '$SC_FLAGS', cache $CACHE, jobs $JOBS"

# ── split the corpus into hits and misses ───────────────────────────────────
# KFILES is KEYS' twin and exists only so the two stay in step: an unmatched
# glob is dropped below, and indexing FILES by a KEYS index after a drop would
# name the wrong file in every message from here on.
KEYS=(); KFILES=(); MISS=()
for F in "${FILES[@]}"; do
  if [ ! -f "$F" ]; then
    # The workflow passes globs; a glob that matched nothing arrives literally
    # and is not a lint failure. A named file that vanished is.
    case "$F" in *'*'*) continue ;; esac
    die "not a file: $F"
  fi
  K=$(printf '%s\037%s\037%s\037%s' "$VER" "$SC_FLAGS" "$F" "$(sha256_file "$F")" | sha256_stdin)
  KEYS+=("$K"); KFILES+=("$F")
  [ -f "$CACHE/results/$K" ] || MISS+=("$F")
done
[ ${#KEYS[@]} -gt 0 ] || die "every path named matched nothing — refusing to report a clean lint over an empty corpus"

NHIT=$(( ${#KEYS[@]} - ${#MISS[@]} ))
rm -f "$CACHE"/fatal/* 2>/dev/null

if [ ${#MISS[@]} -gt 0 ]; then
  printf '%s\0' "${MISS[@]}" |
    BH_SC_BIN="$SC" BH_SC_VER="$VER" BH_SC_CACHE="$CACHE" \
      xargs -0 -P "$JOBS" -n 1 "$SELF" --lint-one
  # xargs exits 123 when a child did; the child only exits nonzero on rc >= 2,
  # which is ShellCheck failing to run rather than finding something.
  XRC=$?
  FATAL=$(ls -1 "$CACHE/fatal" 2>/dev/null | head -1)
  if [ -n "$FATAL" ]; then
    echo "ci-shellcheck: ShellCheck FAILED TO RUN (not a finding) — nothing was cached:" >&2
    cat "$CACHE/fatal"/* >&2
    exit 2
  fi
  [ "$XRC" = 0 ] || die "the parallel lint exited $XRC with no recorded failure — refusing to report a verdict"
fi

# ── replay every verdict in the order the files were named ──────────────────
RC=0
for I in "${!KEYS[@]}"; do
  REC="$CACHE/results/${KEYS[$I]}"
  [ -f "$REC" ] || die "no result recorded for ${KFILES[$I]} — the cache is inconsistent"
  read -r _ FRC < "$REC"
  [ "$FRC" = 0 ] || RC=1
  tail -n +2 "$REC"
done

echo "ci-shellcheck: ${#KEYS[@]} files, $NHIT from cache, ${#MISS[@]} linted"
exit "$RC"
