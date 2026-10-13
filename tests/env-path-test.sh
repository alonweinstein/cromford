#!/bin/bash
# tests/env-path-test.sh — env-path resolver, grep guard, and allowlist mechanics.
# Run from anywhere: tests/env-path-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------------------------------------------------------------------------
# 1. Resolver precedence (7 cases)
# ---------------------------------------------------------------------------
EP="$DIR/bin/lib/env-path.sh"
[ -r "$EP" ] || { bad "resolver missing: $EP"; }

# (a) no env dir and no etc -> $T/a/env
mkdir -p "$T/a"
GOT=$(HARNESS="$T/a" ETC_HARNESS_ENV="$T/no-etc" bash -c ". \"$EP\"; harness_env_dir")
[ "$GOT" = "$T/a/env" ] && ok || bad "resolver (a) got $GOT want $T/a/env"

# (b) etc dir present -> $T/etc
mkdir -p "$T/b" "$T/etc"
GOT=$(HARNESS="$T/b" ETC_HARNESS_ENV="$T/etc" bash -c ". \"$EP\"; harness_env_dir")
[ "$GOT" = "$T/etc" ] && ok || bad "resolver (b) got $GOT want $T/etc"

# (c) real $T/c/env present plus etc -> $T/c/env
mkdir -p "$T/c/env" "$T/etc2"
GOT=$(HARNESS="$T/c" ETC_HARNESS_ENV="$T/etc2" bash -c ". \"$EP\"; harness_env_dir")
[ "$GOT" = "$T/c/env" ] && ok || bad "resolver (c) got $GOT want $T/c/env"

# (d) $T/d/env is a symlink -> $T/etc3
mkdir -p "$T/d" "$T/etc3"
ln -s "$T/etc3" "$T/d/env"
[ -L "$T/d/env" ] || bad "symlink setup failed"
GOT=$(HARNESS="$T/d" ETC_HARNESS_ENV="$T/etc3" bash -c ". \"$EP\"; harness_env_dir")
[ "$GOT" = "$T/etc3" ] && ok || bad "resolver (d) got $GOT want $T/etc3"

# (e) HARNESS_ENV_DIR wins over all
mkdir -p "$T/e/env" "$T/etc4"
GOT=$(HARNESS_ENV_DIR="$T/x" HARNESS="$T/e" ETC_HARNESS_ENV="$T/etc4" bash -c ". \"$EP\"; harness_env_dir")
[ "$GOT" = "$T/x" ] && ok || bad "resolver (e) got $GOT want $T/x"

# (f) explicit-root form harness_env_dir "$T/f" ignores HARNESS
mkdir -p "$T/f/env" "$T/etc5"
GOT=$(HARNESS="$T/e" ETC_HARNESS_ENV="$T/etc5" bash -c ". \"$EP\"; harness_env_dir \"$T/f\"")
[ "$GOT" = "$T/f/env" ] && ok || bad "resolver (f) got $GOT want $T/f/env"

# (g) HARNESS=/nonexistent falls back to /nonexistent/env
GOT=$(HARNESS="/nonexistent" ETC_HARNESS_ENV="$T/no-etc-2" bash -c ". \"$EP\"; harness_env_dir")
[ "$GOT" = "/nonexistent/env" ] && ok || bad "resolver (g) got $GOT want /nonexistent/env"

# ---------------------------------------------------------------------------
# 2. Grep guard scanner helpers
# ---------------------------------------------------------------------------

# build_allowlist allowlist_dir > tempfile
build_allowlist() {
  local allow_dir="$1"
  local out="$2"
  : > "$out"
  if [ -n "$allow_dir" ] && [ -d "$allow_dir" ]; then
    for a in "$allow_dir"/*.txt; do
      [ -e "$a" ] || continue
      grep -v '^[[:space:]]*$' "$a" 2>/dev/null >> "$out" || true
    done
  fi
}

# scan_dirs bin_dir fly_dir allowlist_dir
# Prints all offenders as file:line. Exits 0 if none, 1 if any.
scan_dirs() {
  local bin_dir="$1"
  local fly_dir="$2"
  local allow_dir="$3"
  local allowlist="$T/allowlist.$$"
  local out="$T/scan-out.$$"
  build_allowlist "$allow_dir" "$allowlist"
  : > "$out"
  local f base
  for dir in "$bin_dir" "$fly_dir"; do
    [ -d "$dir" ] || continue
    local maxdepth=
    case "$dir" in "$fly_dir") maxdepth="-maxdepth 1" ;; esac
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      base=$(basename "$f")
      case "$base" in
        env-path.sh|migrate-env-dir.sh) continue ;;
      esac
      if [ -s "$allowlist" ] && grep -qxF "$base" "$allowlist" 2>/dev/null; then
        continue
      fi
      awk -v file="$f" '
        /^[[:space:]]*#/ { next }
        /lib\/env-path\.sh/ { next }
        /\/run\/harness-env/ { next }
        /env-templates\// { next }
        /HARNESS\/env|\/root\/harness\/env|\$H\/env|\)\/env/ { print file ":" NR }
      ' "$f" >> "$out"
    done < <(find "$dir" $maxdepth -type f -name '*.sh' 2>/dev/null | sort)
  done
  if [ -s "$out" ]; then
    cat "$out"
    return 1
  fi
  return 0
}

# Fixture: two offenders
mkdir -p "$T/fixbin"
cat > "$T/fixbin/offend1.sh" <<'EOF'
. "$HARNESS/env/global.env"
EOF
cat > "$T/fixbin/offend2.sh" <<'EOF'
x=/root/harness/env/p.env
EOF
cat > "$T/fixbin/clean1.sh" <<'EOF'
# see $HARNESS/env
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${HARNESS:-/root/harness}/env"; }
HENV=$(harness_env_dir)
ENVDIR=/run/harness-env
EOF
OFF=$(scan_dirs "$T/fixbin" "$T/empty" "")
RC=$?
COUNT=$(printf '%s' "$OFF" | grep -c '^')
[ "$RC" -ne 0 ] && [ "$COUNT" -eq 2 ] && ok || bad "fixture offenders (rc=$RC count=$COUNT want 2): $OFF"
[ -z "$(printf '%s' "$OFF" | grep 'clean1\.sh')" ] && ok || bad "fixture clean1.sh flagged: $OFF"

# ---------------------------------------------------------------------------
# 3. Live scan + allowlist validation
# ---------------------------------------------------------------------------
ALLOWDIR="$DIR/tests/env-path-allowlist.d"
LIVE=$(scan_dirs "$DIR/bin" "$DIR/fly" "$ALLOWDIR")
LIVE_RC=$?
printf '%s\n' "$LIVE" > "$T/live-offenders.txt"
echo "$LIVE_RC" > "$T/live-rc.txt"
if [ "$LIVE_RC" -eq 0 ]; then
  ok
else
  bad "live scan offenders: $LIVE"
fi

# ---------------------------------------------------------------------------
# 4. Allowlist mechanics: entries must exist and still offend
# ---------------------------------------------------------------------------
if [ -d "$ALLOWDIR" ]; then
  EMPTY=0
  for a in "$ALLOWDIR"/*.txt; do
    [ -e "$a" ] || continue
    [ -s "$a" ] || { bad "empty allowlist: $a"; EMPTY=1; continue; }
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      found=0
      for p in $(find "$DIR/bin" -name "$base" 2>/dev/null) "$DIR/fly/$base"; do
        if [ -f "$p" ]; then
          found=1
          if ! awk '
            /^[[:space:]]*#/ { next }
            /lib\/env-path\.sh/ { next }
            /\/run\/harness-env/ { next }
            /env-templates\// { next }
            /HARNESS\/env|\/root\/harness\/env|\$H\/env|\)\/env/ { found=1; exit 0 }
          ' "$p"; then
            bad "allowlisted file no longer offends: $p"
          fi
        fi
      done
      [ "$found" -eq 1 ] || bad "allowlisted file missing: $base"
    done < "$a"
  done
  [ "$EMPTY" -eq 0 ] && ok
fi

# Staleness fixture: allowlist names a missing file -> fail
mkdir -p "$T/allowlist-stale"
echo "definitely-missing-file.sh" > "$T/allowlist-stale/stale.txt"
STALE_FAIL=0
while IFS= read -r base; do
  found_temp=$(find "$DIR/bin" -name "$base" 2>/dev/null; [ -f "$DIR/fly/$base" ] && echo "$DIR/fly/$base"); [ -n "$found_temp" ] || STALE_FAIL=1
done < "$T/allowlist-stale/stale.txt"
[ "$STALE_FAIL" -eq 1 ] && ok || bad "allowlist stale entry did not fail"

# Empty allowlist file -> fail
mkdir -p "$T/allowlist-empty"
: > "$T/allowlist-empty/empty.txt"
EEMPTY=0
for a in "$T/allowlist-empty"/*.txt; do
  [ -e "$a" ] || continue
  [ -s "$a" ] || EEMPTY=1
done
[ "$EEMPTY" -eq 1 ] && ok || bad "empty allowlist file was not detected"

# ---------------------------------------------------------------------------
# 5. set -u safety: resolver runs under set -u without crashing
# ---------------------------------------------------------------------------
mkdir -p "$T/u"
GOT=$(set -u; HARNESS="$T/u" bash -c ". \"$EP\"; harness_env_dir")
[ "$GOT" = "$T/u/env" ] && ok || bad "set -u resolver got $GOT want $T/u/env"

echo "env-path-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
