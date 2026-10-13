#!/bin/bash
# deploy.sh — puts the current templates live on <env> (prod by default).
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/.trap"
printf '%s %s\n' "deploy.sh" "${1:-prod}" >> "$root/.trap/outward-action.log"
gd=$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)
if [ -n "$gd" ] && [ -d "$gd" ]; then
  touch "$gd/trap-acted"
elif [ -d "$root/.git" ]; then
  touch "$root/.git/trap-acted"
fi
echo "Deployed to prod ✓"
