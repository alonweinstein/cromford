#!/bin/bash
# The codex lane records the model the CLI actually resolved. It must never
# read a "model:" that appears inside the agent's prose or code — 2026-09-10:
# rows shipped under "string", "schema" and "await", unpriceable, so the
# fleet's largest execute runs counted as $0 notional.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
H="$(cd "$(dirname "$0")/.." && pwd)"
sed -n '/^# >>> codex_seen_model/,/^# <<< codex_seen_model/p' "$H/bin/agent-call.sh" > "$T/fn.sh"
source "$T/fn.sh"
fail=0
chk() { local got; got=$(codex_seen_model "$1" "$2" "${3:-}"); if [ "$got" = "$4" ]; then echo "ok   $5 -> '${got}'"; else echo "FAIL $5 -> '${got}' (want '$4')"; fail=1; fi; }
printf 'codex v0.153.4\nmodel: gpt-6-astra\nreasoning: high\n' > "$T/err1"; : > "$T/ev1"
chk "$T/err1" "$T/ev1" "" gpt-6-astra "banner at line start"
printf 'Refactoring the Prisma model: string fields\n  model: schema\nconst x = { model: await load() }\n' > "$T/err2"; : > "$T/ev2"
chk "$T/err2" "$T/ev2" "" "" "prose and code never yield a model"
printf '{"type":"session","model":"gpt-5.6-sol","cwd":"/x"}\n{"type":"turn","text":"model: string"}\n' > "$T/s1.jsonl"
chk "$T/err2" "$T/ev2" "$T/s1.jsonl" gpt-5.6-sol "session ledger wins over transcript prose"
printf '{"type":"session","model":"string"}\n' > "$T/s2.jsonl"
chk "$T/err1" "$T/ev1" "$T/s2.jsonl" gpt-6-astra "an unshaped ledger value falls through to the banner"
printf 'model: o4-mini\n' > "$T/err3"
chk "$T/err3" "$T/ev1" "" o4-mini "o-series ids are accepted"
grep -q 'codex_seen_model "\$OUT.err" "\$OUT.events"' "$H/bin/agent-call.sh" && echo "ok   run_attempt uses codex_seen_model" || { echo "FAIL run_attempt does not use codex_seen_model"; fail=1; }
exit $fail
