# The head-bound re-review is claude-only and never re-arms while the lane is down

**What it is:** the merge conductor buys ONE adversarial Claude read per
(PR, head) when a PR's head moves past the sha its approval is bound to. The
read is metered, and its own gate refuses a verdict that a non-Claude lane
produced (`bin/lib/review-provenance.sh`) — so until BH-1019 a claude outage
descended the survival ladder, bought a grok/kimi/openrouter review, and binned
it on arrival. cromford#818 is that loop written out: eight spawns on one
pull request, five of them paid, no commit pushed in between any of them.

Three separate mechanisms now stop it, and they are independent on purpose:

| what | where | what it stops |
|---|---|---|
| the call names the lanes it will accept (`AGENT_CALL_RUNNERS=claude`) | `mc_rereview` in `bin/lib/mc/rebase.sh`, honoured by `bin/agent-call.sh` (`runner_allowed`, the refusal above the promote block, and the three survival-tier gates) | buying a verdict the provenance gate will reject; with no claude lane at all the call is refused with rc 2 having invoked nothing |
| the read cap is keyed on the ACCOUNT'S HEALTH, and no read is bought while the account that would pay is marked down | `mc_lane_epoch` / `mc_lane_down_for_next_review` / `mc_rr_lanefail_note` in `bin/lib/mc/locks.sh`, read by the spawn gate in `headbound_review` in `bin/merge-conductor.sh` | spending the whole `MC_RR_LANEFAIL_MAX` cap against one outage, and re-spawning every 5 minutes for as long as the paying account is down; a healthy default account must not mask a routed-account cooldown |
| a `no-verdict` park records the sha AND the lane-health epoch it parked under | `mc_hb_park` / `mc_hb_parked` + the `MC_HB_PARKED` clause in the drift branch of `mc_classify` | the BLOCKED_HUMAN → HEAD_MOVED reconciliation re-arming the spawn on a head nobody has pushed to — and, in the other direction, a park that nothing ever releases |

**Where the lane's health comes from, and why it takes two sources per account.**
`bin/claude-auth-check.sh` lists a box in `state/claude-auth-down.txt` only on
positive AUTH evidence (`not logged in`, 401, the oauth shapes). A 429 session
limit, a weekly or monthly spend limit and exhausted credits are classified
`inconclusive` and deliberately never touch that file — and that is the #818
outage class. So the conductor keeps a second marker, written from evidence it
already holds: the reason line of a refused read (`mc_lane_account_fact`).
With account routing, markers are per-account: `state/merge-conductor/lane-down`
for the default account and `state/merge-conductor/lane-down.d/<account>` for
routed accounts. `mc_claude_lane_down` is the OR of the default marker and the
fleet monitor line; `mc_lane_down_for_next_review` consults the account that
`bin/account-pick.sh` says would pay for the next re-review, and `mc_lane_epoch`
asks the same question — so the epoch counts transitions of THAT account's
health (its marker, plus the fleet monitor line when it is the default), not
only the default's. With routing off every one of these is the default account,
so the whole mechanism reads exactly as it did before routing existed.

**The release events are events, and every marker has one.** A marker whose only
clearer is a read the gate refuses to buy is a deadlock, not a gate:

- a commit — a new head carries no park record and buys its read;
- a Claude answer anywhere on the box through `mc_rereview` (the conductor's own
  job, or `bin/blocked-resolver.sh`'s re-ask) — `mc_lane_up`, for the account
  that answered;
- the hourly end-to-end canary in `bin/claude-auth-check.sh` answering `ok`,
  which clears the DEFAULT account's marker for this box. During a quota outage
  the conductor buys no reads, so this probe is the only thing on the box still
  asking the vendor — without it the marker would have no way back up;
- for a ROUTED account, which that canary does not probe (it runs on the box
  login, not on a registry credential), the marker expires after
  `MC_LANE_ROUTED_RETRY_SECS` and the next gate check removes it, un-gating the
  parked heads. The first read to land answers (`mc_lane_up`, marker gone) or
  fails the same way (a fresh marker, and the hour restarts) — a bounded,
  unbilled hold rather than one only an operator's `rm` could end.

  **What that hour does and does not bound** (BH-1090 review round 2): it
  bounds the HOLD ON THIS BOX, not a re-ask of the exhausted account. The freed
  read goes to whatever `bin/account-pick.sh` hands back, and an account whose
  429 also stamped `state/quota/cooldown/<vendor>/<account>` is skipped there
  for `ACCOUNT_COOLDOWN_SECS` (21600, 6h) — so the cooldown, not the marker, is
  what decides when that account is asked again. And "one read" is the shape,
  not the count: the gate is per parked head, so up to `MC_REREVIEW_BUDGET` (2)
  reads per project per tick get through before the first failure re-writes the
  marker.

`bin/blocked-resolver.sh` is the second caller of `mc_rereview`, so its
`no-verdict` re-ask is claude-only too, and its own `lanefails` cap is bound to
the same epoch: a lane that comes back gives that rung its failures back.

**How an operator reaches it:** there is no UI. The lane is
`bin/merge-conductor.sh` from `cron/hub.cron` every 5 minutes;
`bin/blocked-resolver.sh` runs there too. The health signals are
`state/claude-auth-down.txt` (hourly, `bin/claude-auth-check.sh`) and
`state/merge-conductor/lane-down` (the conductor's own).

**Knobs:**

| knob | default | what it does |
|---|---|---|
| `AGENT_CALL_RUNNERS` | unset | a caller's list of acceptable lanes. Unset = the full ladder, exactly as before, for every other caller in the fleet |
| `MC_RR_RUNNERS` | `claude` | what the re-review asks for. Empty restores the full survival ladder for this lane |
| `MC_LANE_BOX` | `hub` | which line of `state/claude-auth-down.txt` describes the lane this conductor buys on |
| `MC_LANE_DOWN_FILE` | `state/claude-auth-down.txt` | where that file is |
| `MC_RR_LANEFAIL_MAX` | 5 | reads of ONE head within ONE lane-health epoch |
| `MC_LANE_DOWN_MARKER` | `state/merge-conductor/lane-down` | the conductor's own lane-health marker |
| `MC_LANE_EXHAUST_RE` | the ladder's exhaustion vocabulary | which lane-failure reasons count as an ACCOUNT fact |
| `ACCOUNT_EXHAUST_REGEX` | unset | additive override: OR'd with the built-in exhaustion vocabulary — here AND in `bin/agent-call.sh`'s ladder (`LADDER_EXHAUST_REGEX`), so one knob means one thing on a box (BH-1090) |
| `MC_LANE_ROUTED_RETRY_SECS` | `3600` | how long a ROUTED account's marker stands before the gate un-gates the parked heads and this tick's `MC_REREVIEW_BUDGET` is spent asking again. Which account those reads land on is `bin/account-pick.sh`'s call, bounded by `ACCOUNT_COOLDOWN_SECS` (21600). The default account's marker is the canary's to clear and is never timed |
| `BR_LANEFAIL_MAX` | 5 | the resolver's own lane-failure cap, now per epoch |

**How to drive it:**

| what | how |
|---|---|
| the three mechanisms end to end (a stub lane that would serve fireworks, the lane-down marker, the park that must not re-arm) | `bash tests/merge-conductor-rereview-lanefail-test.sh` |
| `AGENT_CALL_RUNNERS` against real lanes: claude-only descends nowhere, and an absent claude is rc 2 with no runner invoked | `bash tests/agent-call-provider-order-test.sh` |
| the lanefail cap, its ledger row and the park it ends in | `bash tests/merge-conductor-test.sh` (section 4d-bis) |
| the provenance rejection this exists to stop paying for | `bash tests/review-provenance-test.sh` |
| the canary clearing the conductor's marker, in the `ok` arm and for this box only | `bash tests/auth-probe-classify-test.sh` |
| per-account lane-down marker, additive `ACCOUNT_EXHAUST_REGEX`, and spawn gate account awareness | `bash tests/merge-conductor-account-fact.bh-1090-test.sh` |

**Files it writes on a live box:**

- `state/merge-conductor/attempts.txt` — `lanefail <key> <head> <epoch>`, one
  per read bought under that outage; `lanedown <key> <head> <epoch>`, the
  said-once record of a refused spawn; `hbpark <key> <head>`, the sha a
  `no-verdict` park is bound to.
- `state/merge-conductor/lane-epoch` — `<n> up|down`, bumped only on a
  transition of either health source.
- `state/merge-conductor/lane-down` — the default account's marker, holding the
  reason it was set from. Removed by a Claude answer on the default account or
  by the hourly canary (which only exercises the default account).
- `state/merge-conductor/lane-down.d/<account>` — routed-account markers. A
  healthy default canary must not clear them; they are removed by a Claude
  answer on that account, or by the gate itself once they are older than
  `MC_LANE_ROUTED_RETRY_SECS` (which un-gates the parked heads for this tick's
  re-review budget).
- `state/blocked-resolver/<project>/<key>.json` — `lanefails` and
  `lanefail_epoch`, so that cap forgets an outage the lane has recovered from.
- `logs/merge-conductor.log` — `… re-review LANE FAILED on <sha8> (read N of M
  in lane epoch E): <why>`, and `… re-review of <sha8> not spawned — this box's
  claude review lane is marked down …`.
- `logs/failovers.log` — `… refused: the caller restricted the lanes to
  'claude' and claude is not installed/authed on this box — nothing was called
  and nothing was billed`.

**What must never regress:**

- **No vendor call on a lane the gate will reject.** A re-review that reaches
  grok, openrouter or fireworks is a purchase made to be thrown away.
- **A refusal is terminal state, not silence.** Every non-success exit writes
  the job's `lane-failed` status and its reason, or the cap can never become
  true and the next tick re-bills (`~/.claude/rules/metered-api-dedup.md`).
- **The park never closes a PR.** `no-verdict` is the reason
  `bin/blocked-resolver.sh` owns, and silence from our own reviewer is not a
  failed build.
- **Every stop has a release event.** A park, a read cap or a lane-down marker
  with no way back up strands the whole moved-head backlog the moment a quota
  window closes — which is worse than the loop it replaced. If a change adds a
  stop here, it names the event that ends it.

**Manual-only / not automatable:** the suites drive the real code against stub
lanes. Nothing here has been exercised against a genuine hub-wide claude
outage — the first real one is what proves the lane-down arm end to end.
