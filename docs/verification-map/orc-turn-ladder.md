# Orchestrator turn ladder (which account pays, and what the survival banner says)

**What it is:** the failover ladder of one orchestrator turn — the reply the operator
gets on Telegram, Slack or web Mission Control. Rungs, in order: the picked max
account (fable → opus on its setup-token) → every further account
`bin/account-pick.sh` names, each at most once → the `env/orchestrator.env`
default token → the survival lanes (codex, grok) → the bash floor. Since BH-996
an account-class refusal cools the account down and re-picks instead of ending
the claude lane, and the survival banner states the MEASURED refusal (account,
class, and whether the default token was tried) instead of asserting "out of
credits".

**How an operator reaches it:** any inbound message → `bin/poll-commands.sh`
(`cron/hub.cron`) → `bin/orchestrate.sh <message-file>`. There is no other
caller and no flag to arm: every turn runs the ladder.

**Key files/blocks:**
- `bin/orchestrate.sh` `# >>> claude ladder` — the model ladder
  (`orc_model_ladder`), the account loop, the survival loop, the bash floor and
  the banner.
- `bin/orchestrate.sh` `# >>> survival lanes` — `survival_ready`,
  `SURVIVAL_BRIEF` and `run_survival` (the brief carries the `WHY YOU ARE
  ANSWERING:` line built from the same trail).
- `bin/lib/orc-account.sh` — `orc_pick_account` (which account pays),
  `orc_fail_class` / `orc_fail_phrase` (what the refusal was),
  `orc_account_refuse` / `orc_pin_clear` (what a refusal writes).

**Preconditions:** `ACCOUNT_ROUTING=1` and `env/tokens.d/<name>-setup-token.env`
for the account ladder to have anywhere to go; with routing off the turn runs on
`env/orchestrator.env` alone and only the banner wording differs. Kill switches
are unchanged: `ORC_ACCOUNT_ROUTING=0`, `flags/orc-account-routing-off`.

**How you drive it:**

| what | how |
|---|---|
| the whole ladder: classifier, cooldown+pin, the account loop, the banner, the brief | `HARNESS_TEST_SANDBOX=1 bash tests/orc-turn-ladder.bh-996-test.sh` |
| the pick itself (routing on/off, token form, fail-open cases) | `HARNESS_TEST_SANDBOX=1 bash tests/orchestrator-account-routing-test.sh` |
| the turn's dollar cap, which runs inside `run_turn` | `HARNESS_TEST_SANDBOX=1 bash tests/turn-budget-test.sh` |

**Live files on the hub (what shows it working):**
- `logs/failovers.log` — `turn account: max7 → refused(quota) → default
  (no-pick)` per re-pick, and `claude lane dead (<trail>, rc=N) — answering on
  the <lane> survival lane` when every claude rung refused.
- `state/quota/cooldown/claude/<account>` — the epoch stamp a refusal wrote, on
  the vendor-keyed path `bin/agent-call.sh` writes and
  `bin/account-pick.sh:account_cooling` reads (BH-940). A name under
  `state/quota/cooldown/.legacy/` instead means something wrote the pre-BH-940
  unscoped path and the cooldown was never honoured.
- `state/model-cooldown-<model>-<account>` — the fable→opus credits stamp, keyed
  to the account that ran, so one dry pool cannot skip fable fleet-wide.
- `state/quota/pins/orchestrator` — absent after a refused turn; present naming
  the account the next turn will stick to.
- `/root/orchestrator/last-reply.txt` — the banner as the operator read it;
  `/root/orchestrator/last-error.txt` — the vendor text it was classified from.

**Verify it works:** a turn that refuses on the pinned account is answered by
claude on another account or on the default token, with no survival banner at
all; a turn where every claude rung refuses carries a banner naming each account
and its class, and `out of credits` appears only when the vendor text said
credits/credit balance/spend limit.

**The reply ledger (BH-4995.0):** whichever rung answered, a turn whose
`.meta` sidecar carries a command id ends in exactly one strict, retried
`chat_reply` beat (`rkey chat:<id>`, `bin/lib/orc-reply-ledger.sh`) and then one
`answered:<iso>` ack on that command row (a turn the archie intercept answers
gets the beat but not the ack). Without `flags/orc-reply-via-console` Telegram
is still sent as before and the beat carries no `relay` key; under the flag the
beat is the relay. A turn with no command id posts neither. Drive it with
`HARNESS_TEST_SANDBOX=1 bash tests/orchestrate-reply-ledger.bh-4995-test.sh` and
`HARNESS_TEST_SANDBOX=1 bash tests/orc-reply-via-console-test.sh`. On the hub it
shows as the reply row in `GET /api/dash/chat?target=orchestrator`, the
`answered:<iso>` ack result on that command row (written through
`POST /api/commands/<id>/ack`; the console serves command rows at
`GET /api/dash/commands`), and, when every try failed, one `logs/ALERTS.log`
line naming the command id. Knobs: `ORC_REPLY_LEDGER_TRIES`,
`ORC_REPLY_LEDGER_BACKOFF_S`, `ORC_REPLY_LEDGER_MAX_CHARS`, `ORC_CMD_STATUS` on
the `orc-monitor` lane. Entry: `entries/BH-4995.0.md`.

**Manual-only / not automatable:** driving a real Telegram turn. Builds do not
run on the hub, and the suite fakes the claude and codex CLIs, so "a real
message got a real reply" is observed on the hub, never inside a build.
