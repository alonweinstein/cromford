# The GitHub-Issues gate ignores the harness's own comments (BH-2133)

`bin/triage-gate.sh` → `fetch_fingerprint` → `gate_self_absorb` (`bin/lib/gate-self-comments.sh`), with the
allowlist in `bin/lib/harness-self.sh`.

## The loop

A GitHub-Issues board's gate fingerprint carries each `ai-build` issue's comment count and `updatedAt`. That arm
had no self-write absorption. A triage shard's note, posted as `cromford-board[bot]`, moved the row, and three
readers then bought another shard for the same ticket:
- the gate's board diff (`RUN board-changed`);
- the webhook delivery of that same comment (`RUN event-wake`, with the key kept in `bin/gate-diff.sh`'s scope);
- the per-ticket shard fingerprint, `_tsh_fp_pending`, which reads the pending row.

That shard posted another note. On 2026-09-24, #1389 collected six "still on hold" notes, and the board was
paused at 20:18Z.

## Who "we" are

`HARNESS_SELF_APPS` (catalog/lanes.d/_lib.harness-self.json) lists the fleet's GitHub App slugs, by default
`cromford cromford-board cromford-builders`. It has `settable: false`: it is a trust list, and
only `env/global.env` on the box moves it.

A comment is ours when either:
- its author is `<slug>[bot]` (or a `type: "Bot"` user named `<slug>`);
- its `performed_via_github_app.slug` is on the list.

Everything else is not ours:
- any other bot, such as `intercom[bot]` relaying a client;
- the PAT login, which is also the operator's hand.

An empty list makes nothing ours, and that is the behaviour before BH-2133.

## The rule

A row keeps the consumed fingerprint's `comments` and `updatedAt` when all of these hold:

- its number, state and title match the consumed row;
- the per-issue content hash in the fingerprint's top-level `meta` map is identical to the consumed one, and
  the consumed one exists. The hash covers the body, sorted label names, sorted assignees and milestone, all
  read from the same list response. This catches an edit made while a session was in flight, before its note
  (review of #2208, B1);
- its count went up by exactly the number of comments created after the consumed `updatedAt`
  (`GET issues/<n>/comments?since=<consumed updatedAt>`), and every one of them is ours;
- no comment that is not ours was updated after the consumed `updatedAt`. An edit to an old comment is a turn
  (N1);
- the issue's `updatedAt` is no more than `GATE_SELF_SLACK_S` (default 5 s) past the newest of ours.

Anything else keeps the live row and wakes the tick. That includes a deletion, a close or retitle, a read
failure, and more than 300 new comments. A principal `HOLD` is a human comment, so it wakes one tick. The bot
notes that follow it do not.

## Shape

`meta` sits outside the rows, so `bin/gate-diff.sh`, the shard fingerprint and the re-arm read what they read
before. Step 6 compares fingerprints with `meta` left out. When only `meta` moved, it stores the new
fingerprint and SKIPs. That is only the first tick after this ships, because otherwise `meta` moves only with an
`updatedAt` the rows already carry.

## Cost and visibility

- **Reads:** one REST read per row that moved, once. The verdict is remembered in `state/<project>.gate-self.json`,
  keyed on the live and consumed (count, `updatedAt`, hash). At most `GATE_SELF_MAX_ROWS` (default 10) rows are
  read per tick.
- **Fail-open streak:** a read that fails lets the tick run (fail-open). Consecutive fail-open ticks are counted in
  `state/<project>.gate-self.failopen`. At `GATE_SELF_FAILOPEN_ALERT` (default 6) one `ALERTS.log` line is written
  for the streak (I3), and a tick whose reads succeed resets the count.
- **PAT notes:** a triage tick on a GitHub-Issues board with no App installation token posts its notes with the PAT,
  and those cannot be told from the operator. `rt_gate_pat_note_alert` (`bin/lib/rt/gate.sh`) writes one `ALERTS.log`
  line per project per day when that happens (I2).

## Off switch

`flags/gate-self-absorb-off` or `GATE_SELF_ABSORB=0` restores the old behaviour exactly: no read and no memo.

## Tests

Verified by `tests/triage-gate-self-comments.bh-2133-test.sh`:
- G1, the loop: a bot-only bump SKIPs, the `--pending` diff is empty (rc 2), and the pending row equals the
  consumed one;
- G1b: memoized, 0 reads;
- G2: a human comment RUNs;
- G3: HOLD, then our notes, SKIP;
- G4: ours plus a human RUNs;
- G5: an unreadable thread RUNs;
- G6: a deletion RUNs;
- G7: `updatedAt` past the note RUNs;
- G8: a close or retitle RUNs;
- G9: `operator` is not ours;
- G10: the kill switch;
- G11: the lib passes through what it cannot use;
- G12 (B1): an edit to the body, labels, assignees or milestone before our note RUNs, and the control absorbs;
- G13 (I1): `intercom[bot]` RUNs, `performed_via_github_app` of ours absorbs, and an empty list absorbs nothing;
- G14 (N1): an edited old comment RUNs;
- G15: the one-time shape upgrade SKIPs, and no stored hash absorbs nothing;
- G16 (I3): one alert at the threshold, reset on a good read;
- G17 (I2): the PAT tick alerts once, an App-token tick does not.
