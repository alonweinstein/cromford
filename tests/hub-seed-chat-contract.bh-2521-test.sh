#!/bin/bash
# tests/hub-seed-chat-contract.bh-2521-test.sh — the /hub SEED REGISTRY and
# CHAT BINDINGS contract (BH-2521, slice BH-2675).
#
# This slice ships two panels that render nothing yet, the api methods they
# will call and the coord proxy rows for their two writes. What this file pins:
#   1. both panel modules exist and are named here by path (orphan ratchet),
#      and each export is a function. Both are filled in now (SeedRegistry by
#      BH-2677, ChatBindings by BH-2678), so they are imported only when
#      console-ui deps are installed (SeedRegistryPanel must take zero props),
#      else each export is checked in source.
#   2. Hub.js imports both and mounts them right after RestoreLabPanel.
#   3. the node suite console-ui/tests/registry-seed-proxy.bh-2521.test.js
#      (proxy rows + api methods), run for real when node is installed, and
#      console-ui/tests/hub-write-reason-proxy.bh-2995.test.js (BH-2995: both
#      rows refuse a blank reason).
# Run from anywhere: tests/hub-seed-chat-contract.bh-2521-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SEED="$DIR/console-ui/src/screens/hub/SeedRegistry.js"
CHAT="$DIR/console-ui/src/screens/hub/ChatBindings.js"
HUB="$DIR/console-ui/src/screens/Hub.js"

for f in "$SEED" "$CHAT" "$HUB"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 2: Hub.js imports and mount order --------------------------------------
grep -q "import { SeedRegistryPanel } from './hub/SeedRegistry.js';" "$HUB" && ok || bad "Hub.js must import SeedRegistryPanel"
grep -q "import { ChatBindingsPanel } from './hub/ChatBindings.js';" "$HUB" && ok || bad "Hub.js must import ChatBindingsPanel"
ORDER=$(awk '
  /<\$\{RestoreLabPanel\}/ && !r { r = NR }
  /<\$\{SeedRegistryPanel\}/ && !s { s = NR }
  /<\$\{ChatBindingsPanel\}/ && !c { c = NR }
  END { print (r > 0 && s > r && c > s) ? "ok" : "no r=" r " s=" s " c=" c }' "$HUB")
[ "$ORDER" = ok ] && ok || bad "Hub.js must mount RestoreLabPanel, then SeedRegistryPanel, then ChatBindingsPanel ($ORDER)"

if ! command -v node >/dev/null 2>&1; then
  echo "hub-seed-chat-contract: node checks SKIPPED — node is not installed on this box"
else
  # --- 1: the panels, imported --------------------------------------------
  # BH-2677 filled SeedRegistryPanel in and BH-2678 filled ChatBindingsPanel
  # in: both import preact and call hooks, so they load only where console-ui's
  # deps are installed and are never called outside a render. SeedRegistryPanel
  # takes zero props; ChatBindings' behaviour is pinned by
  # tests/chat-bindings-console.bh-2521-test.sh.
  if [ -d "$DIR/console-ui/node_modules/preact" ]; then
    OUT=$(node --input-type=module -e "
import { SeedRegistryPanel } from '$SEED';
import { ChatBindingsPanel } from '$CHAT';
console.log((typeof SeedRegistryPanel === 'function' && SeedRegistryPanel.length === 0 ? 'ok ' : 'no ') + 'SeedRegistryPanel');
console.log((typeof ChatBindingsPanel === 'function' ? 'ok ' : 'no ') + 'ChatBindingsPanel');
" 2>&1)
    [ -n "$OUT" ] || bad "panels: no output from node"
    while IFS= read -r line; do
      case "$line" in
        ok\ *) ok ;;
        no\ *) bad "panel: ${line#no } must be a function (SeedRegistryPanel taking zero props)" ;;
        *) [ -n "$line" ] && bad "panels: unexpected output: $line" ;;
      esac
    done <<< "$OUT"
  else
    echo "hub-seed-chat-contract: panel imports SKIPPED — console-ui dependencies are not installed; checking the exports in source instead"
    grep -qE '^export function SeedRegistryPanel\(\)' "$SEED" && ok || bad "SeedRegistry.js must export function SeedRegistryPanel()"
    grep -qE '^export function ChatBindingsPanel\(' "$CHAT" && ok || bad "ChatBindings.js must export function ChatBindingsPanel"
  fi

  # --- 3: the node suite ----------------------------------------------------
  for s in tests/registry-seed-proxy.bh-2521.test.js tests/hub-write-reason-proxy.bh-2995.test.js; do
    if NOUT=$(cd "$DIR/console-ui" && node --test "$s" 2>&1); then ok
    else bad "console-ui/$s failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
    fi
  done
fi

echo "hub-seed-chat-contract: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
