#!/bin/bash
# tests/lib/share-mirror.sh — ONE build of the public mirror per tree, shared
# by the share and publish suites (BH-5543). Sourced after tests/lib/scratch.sh
# (it needs $T), never executed.
#
# Three suites built the same mirror from the same tree: bh-795 (twice),
# share-mirror-clean and publish-cromford-brand, about 2 minutes each in CI.
# This library builds it once, the way bin/publish-share.sh builds it, and
# keeps it in a cache keyed on what the build is a function of:
#
#   * the committed tree (`git rev-parse HEAD^{tree}`);
#   * every file under <repo>/bin/share/ AS ON DISK — the suites execute those
#     tools from the checkout, so an uncommitted mapping.py edit is a new key;
#   * this file;
#   * the python3 on PATH (its realpath and sys.version).
#
# A python3 that cannot answer the fingerprint (a shim, a missing one) gets a
# PRIVATE build that is never cached and never answered from cache.
#
#   share_mirror_get <repo-dir> [--worktree | --or-copy]
#       Sets SM_DIR, SM_SRC, SM_MIRROR, SM_SANITIZE_RC, SM_SANITIZE_OUT,
#       SM_RENDER_RC, SM_SRC_BEFORE, SM_SRC_AFTER and SM_HOW (built | reused |
#       private | failed: built here, sanitize exited non-zero, not stored). rc 0 when a build exists, a failed sanitize included: the
#       caller reads SM_SANITIZE_RC. rc 3 when no source tree could be made.
#       --worktree  the checkout's files as git sees them; shares the HEAD
#                   build when the checkout is clean, private when it is dirty.
#       --or-copy   not a git checkout: copy the working tree minus .git and
#                   node_modules and drop the twelve renders (private).
#   share_mirror_copy <dest> [src]
#       A private writable copy of SM_MIRROR (or SM_SRC). The cached tree is
#       read-only (chmod a-w); anything that writes into it works on a copy.
#
# The build, in the publisher's order (bin/publish-share.sh steps 1-2):
#   1. the source tree; 2. the BH-5055 plant (.harness/specs/BH-5055-PLANT);
#   3. bin/verification-map-build.sh (best effort); 4. the three BH-1247
#   renders, with the file list before and after them; 5. sanitize.py, timed
#   alone. Every step runs without HARNESS_DEPLOYMENT_FILE, as the publisher
#   does, so the build is a function of the key alone.
#   The key does NOT cover the rest of the environment. The renders source
#   bin/lib/deployment.sh, whose knobs are `: "${X:=default}"`, so a suite must
#   never export one of those knobs before share_mirror_get: the first suite to
#   build a key decides the cached tree for every later suite.
#
# Cache: ${SHARE_MIRROR_CACHE:-$TMPDIR/bh-share-mirror}/<key>/, complete only
# when <key>/DONE exists. <key>.build is held (flock -x, at most
# SHARE_MIRROR_LOCK_WAIT_S, default 600) for the build alone; a suite that
# waits that long builds privately instead. <key>.use is held shared by every
# reader until it exits, and prune removes only what it can lock exclusively.
# Only a build whose sanitize exited 0 is stored; a failed one goes back to its
# caller and is deleted, so the next suite fails fresh. Prune keeps the newest
# SHARE_MIRROR_CACHE_KEEP (default 2) entries.
#
# Every call writes one line to stderr and to <cache>/share-mirror.log:
#   share-mirror: built|reused|failed|private (...) <key12> for <suite>: ...

__sm_lib_file=$(realpath "${BASH_SOURCE[0]}")

__sm_ms() { date +%s%3N; }
__sm_s()  { awk -v m="$1" 'BEGIN { printf "%.1f", m / 1000 }'; }

__sm_cache_root() {
  printf '%s' "${SHARE_MIRROR_CACHE:-$(realpath -m "${TMPDIR:-/tmp}")/bh-share-mirror}"
}

__sm_log() {
  local root
  echo "$1" >&2
  root=$(__sm_cache_root)
  mkdir -p "$root" 2>/dev/null && printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$root/share-mirror.log"
}

# __sm_key <repo> — rc 1: no tree; rc 2: python3 has no fingerprint.
__sm_key() {
  local repo="$1" tree py pyv files
  tree=$(git -C "$repo" rev-parse 'HEAD^{tree}' 2>/dev/null) || return 1
  py=$(command -v python3) || return 2
  py=$(realpath "$py") || return 2
  pyv=$(python3 -I -c 'import sys; print(sys.version)' 2>/dev/null) && [ -n "$pyv" ] || return 2
  files=$(cd "$repo/bin/share" 2>/dev/null && find . -type f ! -name '*.pyc' ! -path '*/__pycache__/*' | LC_ALL=C sort) || return 1
  {
    printf 'tree %s\n' "$tree"
    ( cd "$repo/bin/share" && while IFS= read -r f; do sha256sum -- "$f"; done <<< "$files" )
    printf 'lib %s\n' "$(sha256sum < "$__sm_lib_file")"
    printf 'python3 %s %s\n' "$py" "$pyv"
  } | sha256sum | cut -c1-64
}

# __sm_dirty <repo> — rc 0 when the checkout differs from HEAD in a file git sees.
__sm_dirty() {
  [ -n "$(git -C "$1" status --porcelain --untracked-files=normal 2>/dev/null)" ]
}

# __sm_build <repo> <out> <head|worktree|copy> — rc 3 when no source tree.
# Runs in a subshell: the environment it changes stays inside it.
__sm_build() (
  repo="$1"; out="$2"; mode="$3"; src="$out/src"
  unset HARNESS_DEPLOYMENT_FILE
  mkdir -p "$src" || exit 3
  case "$mode" in
    head)
      git -C "$repo" archive HEAD 2>/dev/null | tar -x -C "$src"
      ps=("${PIPESTATUS[@]}"); [ "${ps[0]}" = 0 ] && [ "${ps[1]}" = 0 ] || exit 3 ;;
    worktree)
      ( cd "$repo" && git ls-files -z --cached --others --exclude-standard \
          | while IFS= read -r -d '' f; do [ -f "$f" ] && printf '%s\0' "$f"; done \
          | tar --null -T - -cf - ) | tar -C "$src" -xf -
      ps=("${PIPESTATUS[@]}"); [ "${ps[0]}" = 0 ] && [ "${ps[1]}" = 0 ] || exit 3 ;;
    copy)
      ( cd "$repo" && tar -cf - --exclude=.git --exclude=node_modules . ) 2>/dev/null | tar -x -C "$src" 2>/dev/null
      ps=("${PIPESTATUS[@]}"); [ "${ps[1]}" = 0 ] || exit 3
      rm -f "$src/catalog/lanes.json" "$src/env-templates/global.env.example" "$src"/cron/*.cron ;;
  esac
  # BH-5055: a build record with a credential-shaped line. The value is built
  # here, never spelled: a spelled one would ship in the mirror as this file.
  plant=$(python3 -I -c 'import base64,hashlib
v = base64.b64encode(hashlib.sha256(b"bh5055-plant").digest()).decode()
print("".join(c for c in v if c.isalnum())[:32])' 2>/dev/null)
  mkdir -p "$src/.harness/specs/BH-5055-PLANT"
  printf '# plan\nRun it as: deploy_api_key = "%s" WAKE_LAUNCH=1 timeout 240\n' "$plant" \
    > "$src/.harness/specs/BH-5055-PLANT/plan.md"
  # Best effort, as the publisher runs it.
  if [ -x "$src/bin/verification-map-build.sh" ]; then
    "$src/bin/verification-map-build.sh" --repo "$src" >/dev/null 2>&1
    echo $? > "$out/index.rc"
  fi
  ( cd "$src" && find . -type f 2>/dev/null | LC_ALL=C sort ) > "$out/src-before.txt"
  rrc=0
  for r in "render-cron.sh --all" "lanes-build.sh --write" "render-env-example.sh --write"; do
    rs=${r%% *}; rf=${r#* }
    [ -x "$src/bin/$rs" ] || continue
    "$src/bin/$rs" --root "$src" "$rf" >/dev/null 2>&1 || rrc=1
  done
  echo "$rrc" > "$out/render.rc"
  ( cd "$src" && find . -type f 2>/dev/null | LC_ALL=C sort ) > "$out/src-after.txt"
  t0=$(__sm_ms)
  python3 "$repo/bin/share/sanitize.py" "$src" "$out/mirror" > "$out/sanitize.out" 2>&1
  echo $? > "$out/sanitize.rc"
  echo $(( $(__sm_ms) - t0 )) > "$out/sanitize.ms"
  exit 0
)

# __sm_set <dir> <how> — point the SM_* variables at a finished build.
__sm_set() {
  SM_DIR="$1"; SM_HOW="$2"
  SM_SRC="$1/src"; SM_MIRROR="$1/mirror"; SM_SANITIZE_OUT="$1/sanitize.out"
  SM_SRC_BEFORE="$1/src-before.txt"; SM_SRC_AFTER="$1/src-after.txt"
  SM_SANITIZE_RC=$(cat "$1/sanitize.rc" 2>/dev/null) || SM_SANITIZE_RC=99
  SM_RENDER_RC=$(cat "$1/render.rc" 2>/dev/null) || SM_RENDER_RC=1
}

# __sm_use <entry> — take a shared hold on a complete entry, kept until exit.
__sm_use() {
  local fd
  [ -f "$1/DONE" ] || return 1
  exec {fd}>>"$1.use" || return 1
  flock -s "$fd"
  [ -f "$1/DONE" ] && return 0
  exec {fd}>&-
  return 1
}

# __sm_prune <root> <keep-entry> — drop entries past the newest KEEP and dead
# temp builds, but only what nobody holds.
__sm_prune() {
  local root="$1" keep="${SHARE_MIRROR_CACHE_KEEP:-2}" n=0 d e base ufd bfd
  while IFS= read -r d; do
    e=${d%/DONE}
    n=$((n + 1))
    [ "$n" -le "$keep" ] && continue
    [ "$e" = "$2" ] && continue
    exec {ufd}>>"$e.use" {bfd}>>"$e.build"
    if flock -n -x "$ufd" && flock -n -x "$bfd"; then
      chmod -R u+w "$e" 2>/dev/null; rm -rf "$e"; rm -f "$e.use" "$e.build"
    fi
    exec {ufd}>&- {bfd}>&-
  done < <(ls -1t "$root"/*/DONE 2>/dev/null)
  while IFS= read -r d; do
    base=${d%.tmp.*}
    exec {bfd}>>"$base.build"
    if flock -n -x "$bfd"; then chmod -R u+w "$d" 2>/dev/null; rm -rf "$d"; fi
    exec {bfd}>&-
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name '*.tmp.*' -mmin +60 2>/dev/null)
}

# __sm_private <repo> <mode> <reason> <suite> <t0>
__sm_private() {
  local out="$T/share-mirror.private"
  rm -rf "$out"
  __sm_build "$1" "$out" "$2" || return 3
  __sm_set "$out" private
  __sm_log "share-mirror: private ($3) for $4: sanitize=$(__sm_s "$(cat "$out/sanitize.ms")")s total=$(__sm_s $(( $(__sm_ms) - $5 )))s"
}

share_mirror_get() {
  local repo="$1" opt="${2:-}" mode=head reason="" key root entry tmp bfd wait suite t0 rc
  suite=$(basename "$0"); t0=$(__sm_ms)
  SM_DIR=""; SM_SRC=""; SM_MIRROR=""; SM_SANITIZE_RC=""; SM_SANITIZE_OUT=""
  SM_RENDER_RC=""; SM_SRC_BEFORE=""; SM_SRC_AFTER=""; SM_HOW=""
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    reason="not a git checkout"
    [ "$opt" = --or-copy ] && mode=copy
  elif [ "$opt" = --worktree ] && __sm_dirty "$repo"; then
    reason="dirty worktree"; mode=worktree
  else
    key=$(__sm_key "$repo"); rc=$?
    case "$rc" in
      0) ;;
      2) reason="python3 fingerprint" ;;
      *) reason="no tree to key" ;;
    esac
  fi
  if [ -z "$reason" ]; then
    root=$(__sm_cache_root)
    mkdir -p "$root" 2>/dev/null || reason="cache dir unwritable"
  fi
  [ -n "$reason" ] && { __sm_private "$repo" "$mode" "$reason" "$suite" "$t0"; return; }

  entry="$root/$key"
  if __sm_use "$entry"; then
    __sm_set "$entry" reused
    __sm_log "share-mirror: reused ${key:0:12} for $suite (sanitize=$(__sm_s "$(cat "$entry/sanitize.ms")")s when built)"
    return 0
  fi
  wait=${SHARE_MIRROR_LOCK_WAIT_S:-600}
  exec {bfd}>>"$entry.build"
  if ! flock -x -w "$wait" "$bfd"; then
    exec {bfd}>&-
    __sm_private "$repo" head "lock wait ${wait}s" "$suite" "$t0"; return
  fi
  # Somebody else may have built it while this suite waited.
  if __sm_use "$entry"; then
    exec {bfd}>&-
    __sm_set "$entry" reused
    __sm_log "share-mirror: reused ${key:0:12} for $suite (sanitize=$(__sm_s "$(cat "$entry/sanitize.ms")")s when built)"
    return 0
  fi
  tmp="$entry.tmp.${BASHPID:-$$}"
  chmod -R u+w "$tmp" "$entry" 2>/dev/null; rm -rf "$tmp" "$entry"
  if ! __sm_build "$repo" "$tmp" head; then
    rm -rf "$tmp"; exec {bfd}>&-; return 3
  fi
  if [ "$(cat "$tmp/sanitize.rc")" != 0 ]; then
    # Never stored: the caller gets the failure, the next suite rebuilds.
    rm -rf "$T/share-mirror.failed"
    mv "$tmp" "$T/share-mirror.failed"; exec {bfd}>&-
    __sm_set "$T/share-mirror.failed" failed
    __sm_log "share-mirror: failed ${key:0:12} for $suite: sanitize rc=$SM_SANITIZE_RC, not stored, total=$(__sm_s $(( $(__sm_ms) - t0 )))s"
    return 0
  fi
  : > "$tmp/DONE"
  mv "$tmp" "$entry" && chmod -R a-w "$entry"
  __sm_use "$entry"
  exec {bfd}>&-
  __sm_set "$entry" built
  __sm_log "share-mirror: built ${key:0:12} for $suite: sanitize=$(__sm_s "$(cat "$entry/sanitize.ms")")s total=$(__sm_s $(( $(__sm_ms) - t0 )))s"
  __sm_prune "$root" "$entry"
  return 0
}

share_mirror_copy() {
  local dest="$1" from="$SM_MIRROR"
  [ "${2:-}" = src ] && from="$SM_SRC"
  [ -n "$from" ] && [ -d "$from" ] || { echo "share_mirror_copy: no build to copy (call share_mirror_get first)" >&2; return 1; }
  rm -rf "$dest"
  cp -a --reflink=auto "$from" "$dest" && chmod -R u+w "$dest"
}
