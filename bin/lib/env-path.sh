#!/bin/bash
# bin/lib/env-path.sh — resolve the harness env directory.
# Side-effect-free: sources no env files, prints only a path, never a secret.
# POSIX sh compatible; safe under the caller's `set -u`.

harness_env_dir() {
  local root="${1:-${HARNESS:-/root/harness}}"

  if [ -n "${HARNESS_ENV_DIR:-}" ]; then
    printf '%s\n' "$HARNESS_ENV_DIR"
    return 0
  fi

  if [ -d "$root/env" ] && [ ! -L "$root/env" ]; then
    printf '%s\n' "$root/env"
    return 0
  fi

  local etc="${ETC_HARNESS_ENV:-/etc/harness/env}"
  if [ -d "$etc" ]; then
    printf '%s\n' "$etc"
    return 0
  fi

  printf '%s\n' "$root/env"
}
