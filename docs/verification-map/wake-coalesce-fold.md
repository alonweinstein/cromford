# Coalesced wake keys are never orphaned

**What it is:** `bin/wake-loop.sh` coalesces issue wakes. Every issue row's key
goes into `state/wake-keys/pending-<project>` the moment it is read, and the
launch that eventually fires past `WAKE_COALESCE_S` carries the union — "a wake
held back is not a wake lost, it is the next tick's scope". The launch writes
those keys to `state/wake-keys-<project>` on the owning box and touches the
one-shot un-brake `state/wake-<project>`; `bin/triage-gate.sh` consumes the
un-brake as `RUN event-wake` and `bin/lib/rt/scope.sh` scopes that tick to the
keys file.

Two arms of `drain()` can take a project's `triage` cooldown: the issue arm and
the push arm. **Both must empty the pending list, because both spend the same
un-brake.** BH-1130 is what happens when only one does: an issue wake for 41
lands inside the window and is held; a push past the window releases child 332,
takes the same project's `triage` cooldown, and its launch consumes the un-brake
with a keys file naming 332 alone. The tick it bought is scoped to 332, the push
arm never `key_take`s, and 41 sits in the pending list until the NEXT issue wake
for that project — on a quiet board, possibly never. Since BH-1130 the push arm
takes the list too, and either side — a released child or a held key — is enough
to buy the launch.

**How an operator reaches it:** it is not a screen. It is the hub cron line
`* * * * * /root/harness/bin/wake-loop.sh` (`cron/hub.cron`), draining the
`wakes` doorbell table (`docs/EVENTS.md`).

| thing | where |
|---|---|
| the pending list | `state/wake-keys/pending-<project>` — `key_add` writes, `key_take` empties |
| the window | `WAKE_COALESCE_S` (default 120), overridden by `WAKE_TRIAGE_COOLDOWN_S`; the stamp is the `wake_cooldowns` row `(triage, <project>)` (BH-2525.2) |
| the keys the tick gets | `state/wake-keys-<project>` on the OWNING box, written there by that box's own `launch_triage` (every box runs the loop for its own projects since BH-2525.2) |
| the un-brake | `state/wake-<project>`, consumed one-shot by `bin/triage-gate.sh` |
| what reads the keys | `bin/lib/rt/scope.sh` `rt_scope()`, `event-wake` arm (`EW_KEYFILE`) |
| the fold line | `logs/wake-loop.log`: `push[<project>]: N coalesced key(s) fold into this tick` |
| the hold line | `logs/wake-loop.log`: `triage[<project>]: coalescing — N key(s) held for the next launch (window Ns)` |
| kill switches | `flags/wake-coalesce-off` (no pending list at all), `flags/wake-launch-off` (no triage launch at all), `flags/wake-loop-off` (no drain) |

**How to drive it:**

| what | how |
|---|---|
| the whole lane | `HARNESS_TEST_SANDBOX=1 bash tests/wake-loop-test.sh` |
| §20a the ticket's own sequence on the owning box: issue wake 41 held, push wake releases 332, one local launch carries both, no ssh | section 20a of that suite |
| §20b the local transport, and the half a released child cannot cover: a push that released nothing launches for the held key alone | section 20b |
| §20c the negative: a push that released nothing with nothing pending still buys nothing | section 20c |
| §20d a push HELD by the window takes no keys — the same orphan one arm over | section 20d |
| §20e `flags/wake-coalesce-off` is 2026-09-13 byte for byte | section 20e |
| the coalescing window itself | section 14 of the same suite |
| what the tick then does with the keys | `bash tests/event-wake-scope-test.sh`, `bash tests/reverse-dep-wake-test.sh` |

**On a live box (the hub):**

- `grep 'coalescing —' logs/wake-loop.log` — keys being held. Every one of those
  lines must be followed, within the window, by a launch line for the same
  project whose `keys=` names them (`triage[<p>]: launched …` /
  `asked <box> to run triage …` / `fastpath[<p>]: every key launched …`).
- `ls state/wake-keys/pending-*` — a pending file that survives several windows
  with no launch for that project is this bug back.
- force it: touch `state/wake-cooldown/triage-<p>` to `date +%s`, ring an issue
  wake, then back-date the stamp and ring a push wake. One launch, both keys.

**What must never regress:**

- **`key_take` runs under the loop's flock, in `drain()`, never in a detached
  child.** `drain()` is single-copy; a child of it is not, and two copies taking
  the list is the coalescing window losing a key.
- **`key_take` runs only AFTER `cooled triage` returned 0.** A launch that never
  happens must not empty the list — taking keys on the held path drops them on
  the floor, which is this same orphan in the other direction (§20d).
- **Either side buys the launch, and neither side alone invents one.** A
  released child, or a held key. A push with neither still buys nothing (§20c),
  so the fold cannot turn every merge into a session.
- **The issue arm keeps precedence.** A project with both an issue and a push
  wake in one drain is handled by the issue arm; the push arm `continue`s before
  `key_take`, so the list is emptied exactly once.
- **`flags/wake-coalesce-off` is still byte-for-byte the old loop.** With it set
  `key_add` writes nothing, `key_take` returns 1, and the push arm carries
  exactly what it carried before (§20e).
- **The folded keys get the issue arm's own closure expansion.** A coalesced key
  that turns out to be a CLOSE carries the tickets it released
  (`issue_closures` → `released_by`), and that runs BEFORE `launch_triage`
  because both halves write `state/wake-closed-<project>` and the tick it
  launches takes that file one-shot.
- **Nothing here is a dependency.** With the webhook uninstalled or this script
  not running, no wake is ever read and every lane fires on its own cron clock.
