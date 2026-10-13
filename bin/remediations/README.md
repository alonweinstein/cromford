# bin/remediations/ — pre-emptive alert handlers

One handler per alert `akey` namespace. `bin/beat.sh` looks for
`<field1>-<field2>.sh` then `<field1>.sh` and runs it with
`timeout 60 <handler> "<akey>" "<line>" "<payload-json>" </dev/null`.

Exit codes: **0** = remediated (alert suppressed), **10** = terminal/expected
end state (suppressed, logged as terminal), **anything else** = fail open, the
alert pages exactly as it does today.

Handlers are READ-ONLY probes. They may query GitHub, Fly, ssh a box or read
local state. They may never merge, push, write a production database, post to a
board, apply a migration or destroy a machine. Suppress only on positive
evidence; when unsure, exit non-zero and let it page.

These are TIER 1. When no handler matches an akey, or a handler fails open,
`bin/beat.sh` falls through to TIER 2 — `bin/remediate-agent.sh`, an LLM
remediator that may try to FIX rather than only verify, behind the opt-in flag
`flags/remediation-agent-enabled`. Its authority contract is
`prompts/remediator.md`; its tool policy is `bin/remediator-settings.json`.

Full contract, mapping table and how to add one: `docs/ALERT-REMEDIATION.md`.
